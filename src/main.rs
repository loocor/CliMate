use anyhow::Context;
use axum::Json;
use axum::Router;
use axum::extract::State;
use axum::http::Method;
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::response::sse::Event;
use axum::response::sse::KeepAlive;
use axum::response::sse::Sse;
use axum::routing::get;
use axum::routing::post;
use clap::Parser;
use clap::Subcommand;
use futures_util::Stream;
use serde_json::Value as JsonValue;
use std::collections::HashMap;
use std::convert::Infallible;
use std::net::IpAddr;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::AsyncBufReadExt;
use tokio::io::AsyncWriteExt;
use tokio::io::BufReader;
use tokio::process::Child;
use tokio::process::ChildStdin;
use tokio::process::ChildStdout;
use tokio::sync::Mutex;
use tokio::sync::broadcast;
use tokio::sync::oneshot;
use tower_http::cors::Any;
use tower_http::cors::CorsLayer;

#[derive(Debug)]
struct AppError(anyhow::Error);

impl From<anyhow::Error> for AppError {
    fn from(value: anyhow::Error) -> Self {
        Self(value)
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> axum::response::Response {
        let msg = format!("{:#}", self.0);
        (StatusCode::INTERNAL_SERVER_ERROR, msg).into_response()
    }
}

type AppResult<T> = Result<T, AppError>;

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
    /// Start an HTTP+SSE bridge to `codex app-server` and expose it over Tailscale Serve.
    Up {
        /// Path to the `codex` binary.
        #[arg(long, default_value = "codex")]
        codex_bin: PathBuf,

        /// Path to the `tailscale` binary.
        #[arg(long, default_value = "tailscale")]
        tailscale_bin: PathBuf,

        /// IP address to bind the local HTTP server to.
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
    let local_base = format!("http://{bind_ip}:{port}");

    tailscale::serve_tcp(&tailscale_bin, port, bind_ip, port).await?;

    let connect_hint = tailscale::best_effort_connect_hint(&tailscale_bin, port).await;

    println!("CliMate is up.");
    println!("- local http: {local_base}");
    if let Some(hint) = connect_hint {
        println!("- iOS base URL: {hint}");
    } else {
        println!("- iOS base URL: http://100.x.y.z:{port}");
    }
    println!("Press Ctrl+C to stop.");

    let state = AppState::new(codex_bin);
    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/rpc", post(rpc))
        .route("/events", get(events))
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods([Method::GET, Method::POST])
                .allow_headers(Any),
        )
        .with_state(state);

    let listener = tokio::net::TcpListener::bind((bind_ip, port))
        .await
        .with_context(|| format!("failed to bind {local_base}"))?;

    axum::serve(listener, app)
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await
        .context("http server failed")?;

    let _ = tailscale::serve_tcp_off(&tailscale_bin, port).await;
    Ok(())
}

async fn healthz() -> &'static str {
    "ok"
}

async fn rpc(
    State(state): State<AppState>,
    Json(payload): Json<JsonValue>,
) -> AppResult<impl IntoResponse> {
    if let Some(method) = payload.get("method").and_then(|v| v.as_str()) {
        let id = payload
            .get("id")
            .map(|v| v.to_string())
            .unwrap_or_else(|| "-".to_string());
        eprintln!("[rpc] method={method} id={id}");
    }
    let session = state.ensure_session().await?;
    let response = session.send_rpc(payload).await?;
    Ok(Json(response))
}

async fn events(
    State(state): State<AppState>,
) -> AppResult<Sse<impl Stream<Item = Result<Event, Infallible>>>> {
    let session = state.ensure_session().await?;
    let mut rx = session.events.subscribe();

    eprintln!("[events] connected");

    let stream = async_stream::stream! {
        struct OnDrop<F: FnOnce()>(Option<F>);
        impl<F: FnOnce()> Drop for OnDrop<F> {
            fn drop(&mut self) {
                if let Some(f) = self.0.take() {
                    f();
                }
            }
        }
        let _guard = OnDrop(Some(|| {
            eprintln!("[events] disconnected");
        }));

        loop {
            match rx.recv().await {
                Ok(line) => {
                    yield Ok(Event::default().data(line));
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    // Drop lagged messages.
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    };

    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(std::time::Duration::from_secs(15))))
}

#[derive(Clone)]
struct AppState {
    inner: Arc<Mutex<Option<Session>>>,
    codex_bin: Arc<PathBuf>,
}

impl AppState {
    fn new(codex_bin: PathBuf) -> Self {
        Self {
            inner: Arc::new(Mutex::new(None)),
            codex_bin: Arc::new(codex_bin),
        }
    }

    async fn ensure_session(&self) -> anyhow::Result<Session> {
        let mut guard = self.inner.lock().await;
        if let Some(session) = guard.as_ref() {
            return Ok(session.clone());
        }
        let session = Session::spawn(&self.codex_bin).await?;
        *guard = Some(session.clone());
        Ok(session)
    }
}

#[derive(Clone)]
struct Session {
    stdin: Arc<Mutex<ChildStdin>>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<JsonValue>>>>,
    events: broadcast::Sender<String>,
    _child: Arc<Mutex<Child>>,
}

impl Session {
    async fn spawn(codex_bin: &Path) -> anyhow::Result<Self> {
        let mut child = tokio::process::Command::new(codex_bin)
            .arg("app-server")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::inherit())
            .spawn()
            .with_context(|| format!("failed to start `{}` app-server", codex_bin.display()))?;

        let stdin = child
            .stdin
            .take()
            .context("codex app-server stdin unavailable")?;
        let stdout = child
            .stdout
            .take()
            .context("codex app-server stdout unavailable")?;

        let (events_tx, _) = broadcast::channel::<String>(1024);
        let pending: Arc<Mutex<HashMap<String, oneshot::Sender<JsonValue>>>> =
            Arc::new(Mutex::new(HashMap::new()));

        let session = Self {
            stdin: Arc::new(Mutex::new(stdin)),
            pending: pending.clone(),
            events: events_tx.clone(),
            _child: Arc::new(Mutex::new(child)),
        };

        tokio::spawn(read_stdout_loop(stdout, events_tx, pending));

        Ok(session)
    }

    async fn send_rpc(&self, payload: JsonValue) -> anyhow::Result<JsonValue> {
        let id_key = payload.get("id").and_then(json_id_key);
        let is_request = payload.get("method").is_some() && id_key.is_some();

        let (tx, rx) = if is_request {
            let key = id_key.clone().expect("checked");
            let (tx, rx) = oneshot::channel();
            self.pending.lock().await.insert(key.clone(), tx);
            (Some(key), Some(rx))
        } else {
            (None, None)
        };

        let line = serde_json::to_string(&payload).context("failed to serialize rpc payload")?;
        {
            let mut stdin = self.stdin.lock().await;
            stdin.write_all(line.as_bytes()).await?;
            stdin.write_all(b"\n").await?;
            stdin.flush().await?;
        }

        if let Some(rx) = rx {
            match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
                Ok(Ok(resp)) => Ok(resp),
                Ok(Err(_)) => anyhow::bail!("rpc response channel closed"),
                Err(_) => {
                    if let Some(key) = tx {
                        self.pending.lock().await.remove(&key);
                    }
                    anyhow::bail!("rpc timed out")
                }
            }
        } else {
            Ok(serde_json::json!({"ok": true}))
        }
    }
}

async fn read_stdout_loop(
    stdout: ChildStdout,
    events: broadcast::Sender<String>,
    pending: Arc<Mutex<HashMap<String, oneshot::Sender<JsonValue>>>>,
) {
    let mut lines = BufReader::new(stdout).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        let _ = events.send(line.clone());

        let Ok(json) = serde_json::from_str::<JsonValue>(&line) else {
            continue;
        };
        let Some(id) = json.get("id").and_then(json_id_key) else {
            continue;
        };
        let Some(tx) = pending.lock().await.remove(&id) else {
            continue;
        };
        let _ = tx.send(json);
    }
}

fn json_id_key(id: &JsonValue) -> Option<String> {
    match id {
        JsonValue::String(s) => Some(s.clone()),
        JsonValue::Number(n) => Some(n.to_string()),
        _ => None,
    }
}
