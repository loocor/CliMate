use anyhow::Context;
use clap::Parser;
use clap::Subcommand;
use futures_util::SinkExt;
use futures_util::StreamExt;
use std::net::IpAddr;
use std::path::Path;
use std::path::PathBuf;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncWriteExt;
use tokio::io::BufReader;
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::tungstenite::Message as WebSocketMessage;

mod tailscale;

#[derive(Debug, Parser)]
#[command(name = "climate")]
#[command(about = "CliMate: minimal Codex app-server remote wrapper", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Start a WebSocket<->stdio bridge to `codex app-server` and expose it over Tailscale Serve.
    Up {
        /// Path to the `codex` binary.
        #[arg(long, default_value = "codex")]
        codex_bin: PathBuf,

        /// Path to the `tailscale` binary.
        #[arg(long, default_value = "tailscale")]
        tailscale_bin: PathBuf,

        /// IP address to bind the WebSocket bridge to.
        ///
        /// Use loopback and rely on `tailscale serve` to publish tailnet-only.
        #[arg(long, default_value = "127.0.0.1")]
        bind_ip: IpAddr,

        /// Port to bind and serve.
        #[arg(long, default_value_t = 4500)]
        port: u16,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Up {
            codex_bin,
            tailscale_bin,
            bind_ip,
            port,
        } => up(codex_bin, tailscale_bin, bind_ip, port).await,
    }
}

async fn up(
    codex_bin: PathBuf,
    tailscale_bin: PathBuf,
    bind_ip: IpAddr,
    port: u16,
) -> anyhow::Result<()> {
    let listen_url = format!("ws://{bind_ip}:{port}");

    tailscale::serve_tcp(&tailscale_bin, port, bind_ip, port).await?;

    let connect_hint = tailscale::best_effort_connect_hint(&tailscale_bin, port).await;
    println!("CliMate is up.");
    println!("- websocket bridge: {listen_url}");
    if let Some(hint) = connect_hint {
        println!("- iOS connect URL: {hint}");
    } else {
        println!("- iOS connect URL: ws://<your-mac>.<tailnet>.ts.net:{port}");
    }
    println!("Press Ctrl+C to stop.");

    let listener = TcpListener::bind((bind_ip, port))
        .await
        .with_context(|| format!("failed to bind {listen_url}"))?;

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                break;
            }
            accept_result = listener.accept() => {
                let (stream, peer) = accept_result.context("failed to accept websocket client")?;
                eprintln!("[client connected: {peer}]");
                if let Err(err) = handle_ws_client(&codex_bin, stream).await {
                    eprintln!("[client session ended with error: {err}]");
                } else {
                    eprintln!("[client session ended]");
                }
            }
        }
    }

    let _ = tailscale::serve_tcp_off(&tailscale_bin, port).await;
    Ok(())
}

async fn handle_ws_client(codex_bin: &Path, stream: tokio::net::TcpStream) -> anyhow::Result<()> {
    // Spawn a fresh app-server per websocket connection so reconnects don't hit
    // app-server initialization preconditions.
    let mut child = tokio::process::Command::new(codex_bin)
        .arg("app-server")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .spawn()
        .with_context(|| format!("failed to start `{}` app-server", codex_bin.display()))?;

    let mut child_stdin = child
        .stdin
        .take()
        .context("codex app-server stdin unavailable")?;
    let child_stdout = child
        .stdout
        .take()
        .context("codex app-server stdout unavailable")?;

    let ws = accept_async(stream)
        .await
        .context("websocket handshake failed")?;
    let (mut ws_tx, mut ws_rx) = ws.split();
    let mut stdout_lines = BufReader::new(child_stdout).lines();

    loop {
        tokio::select! {
            maybe_msg = ws_rx.next() => {
                match maybe_msg {
                    Some(Ok(WebSocketMessage::Text(text))) => {
                        child_stdin.write_all(text.as_bytes()).await?;
                        child_stdin.write_all(b"\n").await?;
                        child_stdin.flush().await?;
                    }
                    Some(Ok(WebSocketMessage::Close(_))) => {
                        break;
                    }
                    Some(Ok(_)) => {
                        // Ignore non-text frames.
                    }
                    Some(Err(err)) => {
                        return Err(err).context("websocket receive failed");
                    }
                    None => break,
                }
            }
            line_result = stdout_lines.next_line() => {
                match line_result {
                    Ok(Some(line)) => {
                        ws_tx.send(WebSocketMessage::Text(line.into())).await?;
                    }
                    Ok(None) => break,
                    Err(err) => return Err(err).context("failed reading codex app-server stdout"),
                }
            }
        }
    }

    let _ = child.kill().await;
    Ok(())
}
