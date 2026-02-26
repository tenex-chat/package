use std::collections::VecDeque;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use tokio::process::Command;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{error, info};

use super::{
    graceful_shutdown, read_lines, LogLine, ProcessManager, ProcessStatus, MAX_LOG_LINES,
};

const POLL_MAX_ATTEMPTS: u32 = 60;
const POLL_INTERVAL_MS: u64 = 500;

/// Manages the ngrok tunnel process for exposing the local relay.
pub struct NgrokManager {
    port: RwLock<u16>,
    tunnel_url: Arc<RwLock<Option<String>>>,
    status: Arc<RwLock<ProcessStatus>>,
    last_error: Arc<RwLock<Option<String>>>,
    logs: Arc<Mutex<VecDeque<LogLine>>>,
    child: Arc<Mutex<Option<tokio::process::Child>>>,
    status_tx: broadcast::Sender<ProcessStatus>,
    log_tx: broadcast::Sender<LogLine>,
}

impl NgrokManager {
    pub fn new() -> Self {
        let (status_tx, _) = broadcast::channel(64);
        let (log_tx, _) = broadcast::channel(256);

        Self {
            port: RwLock::new(7777),
            tunnel_url: Arc::new(RwLock::new(None)),
            status: Arc::new(RwLock::new(ProcessStatus::Stopped)),
            last_error: Arc::new(RwLock::new(None)),
            logs: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_LOG_LINES))),
            child: Arc::new(Mutex::new(None)),
            status_tx,
            log_tx,
        }
    }

    pub async fn configure(&self, port: u16) {
        *self.port.write().await = port;
    }

    pub async fn tunnel_url(&self) -> Option<String> {
        self.tunnel_url.read().await.clone()
    }

    pub async fn wss_url(&self) -> Option<String> {
        self.tunnel_url
            .read()
            .await
            .as_ref()
            .map(|url| url.replace("https://", "wss://"))
    }

    fn set_status(&self, status: ProcessStatus) {
        if let Ok(mut s) = self.status.try_write() {
            *s = status;
        }
        let _ = self.status_tx.send(status);
    }

    async fn poll_for_url(&self) -> Option<String> {
        for _ in 0..POLL_MAX_ATTEMPTS {
            if let Some(url) = fetch_tunnel_url().await {
                return Some(url);
            }
            tokio::time::sleep(Duration::from_millis(POLL_INTERVAL_MS)).await;
        }
        None
    }
}

#[async_trait]
impl ProcessManager for NgrokManager {
    fn name(&self) -> &str {
        "Ngrok"
    }

    async fn status(&self) -> ProcessStatus {
        *self.status.read().await
    }

    async fn last_error(&self) -> Option<String> {
        self.last_error.read().await.clone()
    }

    async fn log_buffer(&self) -> Vec<LogLine> {
        self.logs.lock().await.iter().cloned().collect()
    }

    fn subscribe_status(&self) -> broadcast::Receiver<ProcessStatus> {
        self.status_tx.subscribe()
    }

    fn subscribe_logs(&self) -> broadcast::Receiver<LogLine> {
        self.log_tx.subscribe()
    }

    async fn start(&self) -> Result<()> {
        {
            let status = *self.status.read().await;
            if status == ProcessStatus::Running || status == ProcessStatus::Starting {
                return Ok(());
            }
        }

        self.set_status(ProcessStatus::Starting);
        *self.last_error.write().await = None;
        *self.tunnel_url.write().await = None;

        let port = *self.port.read().await;

        let mut child = Command::new("ngrok")
            .args(["http", &port.to_string(), "--log", "stdout"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("Failed to start ngrok. Is ngrok installed?")?;

        if let Some(stdout) = child.stdout.take() {
            let tx = self.log_tx.clone();
            let logs = self.logs.clone();
            tokio::spawn(read_lines(stdout, tx, logs));
        }
        if let Some(stderr) = child.stderr.take() {
            let tx = self.log_tx.clone();
            let logs = self.logs.clone();
            tokio::spawn(read_lines(stderr, tx, logs));
        }

        *self.child.lock().await = Some(child);

        info!("ngrok process started, polling for tunnel URL...");

        if let Some(url) = self.poll_for_url().await {
            *self.tunnel_url.write().await = Some(url.clone());
            self.set_status(ProcessStatus::Running);
            info!("ngrok tunnel established: {}", url);
        } else {
            let msg = "Timed out waiting for ngrok tunnel URL";
            *self.last_error.write().await = Some(msg.into());
            self.set_status(ProcessStatus::Failed);
            error!("{}", msg);
            bail!("{}", msg);
        }

        Ok(())
    }

    async fn stop(&self) -> Result<()> {
        let mut child_guard = self.child.lock().await;
        if let Some(ref mut child) = *child_guard {
            graceful_shutdown(child, 3).await;
        }
        *child_guard = None;
        drop(child_guard);

        self.set_status(ProcessStatus::Stopped);
        *self.tunnel_url.write().await = None;
        Ok(())
    }
}

async fn fetch_tunnel_url() -> Option<String> {
    let resp = reqwest::get("http://localhost:4040/api/tunnels")
        .await
        .ok()?;

    if !resp.status().is_success() {
        return None;
    }

    let json: serde_json::Value = resp.json().await.ok()?;
    let tunnels = json.get("tunnels")?.as_array()?;

    for tunnel in tunnels {
        if let Some(public_url) = tunnel.get("public_url").and_then(|v| v.as_str()) {
            if public_url.starts_with("https://") {
                return Some(public_url.to_string());
            }
        }
    }

    None
}
