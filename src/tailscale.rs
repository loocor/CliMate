use anyhow::Context;
use serde::Deserialize;
use std::net::IpAddr;
use std::path::Path;

pub async fn serve_tcp(
    tailscale_bin: &Path,
    remote_port: u16,
    local_ip: IpAddr,
    local_port: u16,
) -> anyhow::Result<()> {
    // tailscale serve --bg --yes --tcp <port> tcp://IP:PORT
    // Note: passing --yes avoids interactive prompts.
    let local_target = format!("tcp://{local_ip}:{local_port}");

    let output = tokio::process::Command::new(tailscale_bin)
        .arg("serve")
        .arg("--bg")
        .arg("--yes")
        .arg("--tcp")
        .arg(remote_port.to_string())
        .arg(local_target)
        .output()
        .await
        .with_context(|| format!("failed to run `{}`", tailscale_bin.display()))?;

    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    anyhow::bail!("tailscale serve failed: {stderr}");
}

pub async fn serve_tcp_off(tailscale_bin: &Path, remote_port: u16) -> anyhow::Result<()> {
    // Best-effort: some versions support `off`, others rely on reset/clear.
    let output = tokio::process::Command::new(tailscale_bin)
        .arg("serve")
        .arg("--yes")
        .arg("--tcp")
        .arg(remote_port.to_string())
        .arg("off")
        .output()
        .await
        .with_context(|| format!("failed to run `{}`", tailscale_bin.display()))?;

    if output.status.success() {
        return Ok(());
    }

    // Do not fail shutdown cleanup.
    Ok(())
}

pub async fn best_effort_connect_hint(tailscale_bin: &Path, port: u16) -> Option<String> {
    let output = tokio::process::Command::new(tailscale_bin)
        .arg("status")
        .arg("--json")
        .output()
        .await
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let status: StatusJson = serde_json::from_slice(&output.stdout).ok()?;

    if let Some(ip) = status
        .self_node
        .tailscale_ips
        .as_ref()
        .and_then(|ips| ips.iter().find(|ip| ip.starts_with("100.")))
    {
        return Some(format!("http://{ip}:{port}"));
    }

    let mut dns_name = status.self_node.dns_name?;
    if let Some(stripped) = dns_name.strip_suffix('.') {
        dns_name = stripped.to_string();
    }
    Some(format!("http://{dns_name}:{port}"))
}

#[derive(Debug, Deserialize)]
struct StatusJson {
    #[serde(rename = "Self")]
    self_node: SelfNode,
}

#[derive(Debug, Deserialize)]
struct SelfNode {
    #[serde(rename = "DNSName")]
    dns_name: Option<String>,

    #[serde(rename = "TailscaleIPs")]
    tailscale_ips: Option<Vec<String>>,
}
