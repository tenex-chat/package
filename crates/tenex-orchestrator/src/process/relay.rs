use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use tokio::process::Command;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{error, info, warn};

use crate::config::ConfigStore;

use super::{
    graceful_shutdown, read_lines, which_exists, LogLine, ProcessManager, ProcessStatus,
    GRACEFUL_SHUTDOWN_SECS, MAX_LOG_LINES,
};

const READINESS_ATTEMPTS: u32 = 50;
const READINESS_INTERVAL_MS: u64 = 100;
const HEALTH_CHECK_INTERVAL_SECS: u64 = 10;
const MAX_CONSECUTIVE_FAILURES: u32 = 3;

/// Manages the Khatru-based local Nostr relay process.
pub struct RelayManager {
    repo_root: Option<PathBuf>,
    config_store: Arc<ConfigStore>,
    port: RwLock<u16>,
    sync_relays: RwLock<Vec<String>>,
    status: Arc<RwLock<ProcessStatus>>,
    last_error: Arc<RwLock<Option<String>>>,
    logs: Arc<Mutex<VecDeque<LogLine>>>,
    child: Arc<Mutex<Option<tokio::process::Child>>>,
    health_abort: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
    status_tx: broadcast::Sender<ProcessStatus>,
    log_tx: broadcast::Sender<LogLine>,
}

impl RelayManager {
    pub fn new(repo_root: Option<PathBuf>, config_store: Arc<ConfigStore>) -> Self {
        let (status_tx, _) = broadcast::channel(64);
        let (log_tx, _) = broadcast::channel(256);

        Self {
            repo_root,
            config_store,
            port: RwLock::new(7777),
            sync_relays: RwLock::new(vec!["wss://tenex.chat".into()]),
            status: Arc::new(RwLock::new(ProcessStatus::Stopped)),
            last_error: Arc::new(RwLock::new(None)),
            logs: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_LOG_LINES))),
            child: Arc::new(Mutex::new(None)),
            health_abort: Mutex::new(None),
            status_tx,
            log_tx,
        }
    }

    pub async fn configure(&self, port: u16, sync_relays: Vec<String>) {
        *self.port.write().await = port;
        *self.sync_relays.write().await = sync_relays;
    }

    pub async fn port(&self) -> u16 {
        *self.port.read().await
    }

    pub async fn local_relay_url(&self) -> String {
        format!("ws://127.0.0.1:{}", self.port.read().await)
    }

    fn set_status(&self, status: ProcessStatus) {
        if let Ok(mut s) = self.status.try_write() {
            *s = status;
        }
        let _ = self.status_tx.send(status);
    }

    fn resolve_executable(&self) -> Option<String> {
        let arch = current_arch();
        let binary_name = format!("tenex-relay-{}", arch);

        if let Some(root) = &self.repo_root {
            let dev_path = root.join(format!("relay/dist/{}", binary_name));
            if dev_path.exists() {
                return Some(dev_path.to_string_lossy().into());
            }

            let generic = root.join("relay/dist/tenex-relay");
            if generic.exists() {
                return Some(generic.to_string_lossy().into());
            }
        }

        if which_exists(&binary_name) {
            return Some(binary_name);
        }
        if which_exists("tenex-relay") {
            return Some("tenex-relay".into());
        }

        None
    }

    fn write_relay_config(&self, port: u16, sync_relays: &[String]) -> Result<PathBuf> {
        let base_dir = self.config_store.base_dir();
        let relay_dir = base_dir.join("relay");
        let data_dir = relay_dir.join("data");
        std::fs::create_dir_all(&data_dir)
            .with_context(|| format!("Failed to create relay data dir {:?}", data_dir))?;

        let config_path = base_dir.join("relay.json");
        let config = serde_json::json!({
            "port": port,
            "data_dir": data_dir.to_string_lossy(),
            "nip11": {
                "name": "TENEX Local Relay",
                "description": "Local Nostr relay for TENEX",
                "pubkey": "",
                "contact": "",
                "supported_nips": [1, 2, 4, 9, 11, 12, 16, 20, 22, 33, 40, 42, 77],
                "software": "tenex-khatru-relay",
                "version": "0.1.0"
            },
            "limits": {
                "max_message_length": 524288,
                "max_subscriptions": 100,
                "max_filters": 50,
                "max_event_tags": 2500,
                "max_content_length": 102400
            },
            "sync": {
                "relays": sync_relays,
                "kinds": [4199, 4129, 4200, 4201, 4202, 34199]
            }
        });

        let json = serde_json::to_string_pretty(&config)?;
        std::fs::write(&config_path, json)?;
        Ok(config_path)
    }

    async fn check_health(&self, port: u16) -> bool {
        let url = format!("http://127.0.0.1:{}/health", port);
        reqwest::get(&url)
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
    }

    async fn wait_for_readiness(&self, port: u16) -> bool {
        for _ in 0..READINESS_ATTEMPTS {
            if self.check_health(port).await {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(READINESS_INTERVAL_MS)).await;
        }
        false
    }

    fn is_port_available(port: u16) -> bool {
        std::net::TcpListener::bind(("127.0.0.1", port)).is_ok()
    }

    async fn start_health_monitoring(&self) {
        self.stop_health_monitoring().await;

        let (abort_tx, mut abort_rx) = tokio::sync::watch::channel(false);
        *self.health_abort.lock().await = Some(abort_tx);

        let status_arc = self.status.clone();
        let last_error_arc = self.last_error.clone();
        let status_tx = self.status_tx.clone();
        let port = *self.port.read().await;

        tokio::spawn(async move {
            let mut consecutive_failures: u32 = 0;

            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(HEALTH_CHECK_INTERVAL_SECS)) => {},
                    _ = abort_rx.changed() => break,
                }

                let current = *status_arc.read().await;
                if current != ProcessStatus::Running {
                    continue;
                }

                let url = format!("http://127.0.0.1:{}/health", port);
                let healthy = reqwest::get(&url)
                    .await
                    .map(|r| r.status().is_success())
                    .unwrap_or(false);

                if healthy {
                    consecutive_failures = 0;
                } else {
                    consecutive_failures += 1;
                    warn!(
                        "Relay health check failed ({}/{})",
                        consecutive_failures, MAX_CONSECUTIVE_FAILURES
                    );

                    if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                        let msg = format!(
                            "Health check failed {} consecutive times",
                            MAX_CONSECUTIVE_FAILURES
                        );
                        error!("{}", msg);
                        *last_error_arc.write().await = Some(msg);
                        *status_arc.write().await = ProcessStatus::Failed;
                        let _ = status_tx.send(ProcessStatus::Failed);
                        break;
                    }
                }
            }
        });
    }

    async fn stop_health_monitoring(&self) {
        if let Some(tx) = self.health_abort.lock().await.take() {
            let _ = tx.send(true);
        }
    }
}

#[async_trait]
impl ProcessManager for RelayManager {
    fn name(&self) -> &str {
        "Relay"
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

        let executable = self
            .resolve_executable()
            .context("Cannot find relay binary")?;

        let port = *self.port.read().await;
        if !Self::is_port_available(port) {
            let msg = format!("Port {} is already in use", port);
            *self.last_error.write().await = Some(msg.clone());
            self.set_status(ProcessStatus::Failed);
            bail!("{}", msg);
        }

        self.set_status(ProcessStatus::Starting);
        *self.last_error.write().await = None;
        self.logs.lock().await.clear();

        let sync_relays = self.sync_relays.read().await.clone();
        let config_path = self.write_relay_config(port, &sync_relays)?;

        let mut child = Command::new(&executable)
            .args(["-config", &config_path.to_string_lossy()])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("Failed to start relay: {}", executable))?;

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

        if self.wait_for_readiness(port).await {
            self.set_status(ProcessStatus::Running);
            self.start_health_monitoring().await;
            info!("Relay started on port {}", port);
        } else {
            self.set_status(ProcessStatus::Failed);
            *self.last_error.write().await =
                Some("Relay failed to become ready within timeout".into());
            if let Some(ref mut c) = *self.child.lock().await {
                let _ = c.kill().await;
            }
            *self.child.lock().await = None;
            bail!("Relay failed readiness check");
        }

        Ok(())
    }

    async fn stop(&self) -> Result<()> {
        self.stop_health_monitoring().await;

        let mut child_guard = self.child.lock().await;
        if let Some(ref mut child) = *child_guard {
            graceful_shutdown(child, GRACEFUL_SHUTDOWN_SECS).await;
        }
        *child_guard = None;
        drop(child_guard);

        self.set_status(ProcessStatus::Stopped);
        *self.last_error.write().await = None;
        Ok(())
    }
}

fn current_arch() -> &'static str {
    #[cfg(target_arch = "aarch64")]
    {
        "arm64"
    }
    #[cfg(target_arch = "x86_64")]
    {
        "x86_64"
    }
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    {
        "unknown"
    }
}
