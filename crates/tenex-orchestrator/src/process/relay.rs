use std::collections::VecDeque;
use std::io::{BufRead, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use async_trait::async_trait;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{error, info, warn};

use crate::config::ConfigStore;

use super::{
    graceful_shutdown_pid, which_exists, LogLine, ProcessManager, ProcessStatus,
    GRACEFUL_SHUTDOWN_SECS, MAX_LOG_LINES,
};

const READINESS_ATTEMPTS: u32 = 50;
const READINESS_INTERVAL_MS: u64 = 100;
const HEALTH_CHECK_INTERVAL_SECS: u64 = 10;
const MAX_CONSECUTIVE_FAILURES: u32 = 3;
const LOG_TAIL_INTERVAL_MS: u64 = 500;

/// Manages the Khatru-based local Nostr relay as a persistent daemon process.
///
/// The relay process is detached via `setsid` so it survives the parent TUI exiting.
/// A PID file at `~/.tenex/relay/relay.pid` tracks the running process, allowing
/// subsequent launches to adopt an already-running relay instead of spawning a new one.
pub struct RelayManager {
    repo_root: Option<PathBuf>,
    config_store: Arc<ConfigStore>,
    port: RwLock<u16>,
    sync_relays: RwLock<Vec<String>>,
    status: Arc<RwLock<ProcessStatus>>,
    last_error: Arc<RwLock<Option<String>>>,
    logs: Arc<Mutex<VecDeque<LogLine>>>,
    health_abort: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
    log_tail_abort: Mutex<Option<tokio::sync::watch::Sender<bool>>>,
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
            health_abort: Mutex::new(None),
            log_tail_abort: Mutex::new(None),
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

    // ── Path helpers ──────────────────────────────────────────────────

    fn relay_dir(&self) -> PathBuf {
        self.config_store.base_dir().join("relay")
    }

    fn pid_path(&self) -> PathBuf {
        self.relay_dir().join("relay.pid")
    }

    fn log_path(&self) -> PathBuf {
        self.relay_dir().join("relay.log")
    }

    // ── PID file management ───────────────────────────────────────────

    /// Read PID from file and verify the process is still alive.
    fn read_pid(&self) -> Option<i32> {
        let path = self.pid_path();
        let content = std::fs::read_to_string(&path).ok()?;
        let pid: i32 = content.trim().parse().ok()?;

        // Check process is alive via kill(pid, 0)
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        if alive {
            Some(pid)
        } else {
            // Stale PID file — clean it up
            let _ = std::fs::remove_file(&path);
            None
        }
    }

    fn write_pid(&self, pid: u32) -> Result<()> {
        let dir = self.relay_dir();
        std::fs::create_dir_all(&dir)
            .with_context(|| format!("Failed to create relay dir {:?}", dir))?;
        std::fs::write(self.pid_path(), pid.to_string())
            .with_context(|| "Failed to write relay PID file")?;
        Ok(())
    }

    fn remove_pid(&self) {
        let _ = std::fs::remove_file(self.pid_path());
    }

    // ── Status / config helpers ───────────────────────────────────────

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

    fn write_relay_config(&self, port: u16, sync_relays: &[String], nip42_auth: bool) -> Result<PathBuf> {
        let relay_dir = self.relay_dir();
        let data_dir = relay_dir.join("data");
        std::fs::create_dir_all(&data_dir)
            .with_context(|| format!("Failed to create relay data dir {:?}", data_dir))?;

        let mut supported_nips = vec![1, 2, 4, 9, 11, 12, 16, 20, 22, 33, 40, 77];
        if nip42_auth {
            supported_nips.push(42);
        }
        supported_nips.sort();

        let config_path = relay_dir.join("relay.json");
        let config = serde_json::json!({
            "port": port,
            "bind_address": "127.0.0.1",
            "data_dir": data_dir.to_string_lossy(),
            "nip11": {
                "name": "TENEX Local Relay",
                "description": "Local Nostr relay for TENEX",
                "pubkey": "",
                "contact": "",
                "supported_nips": supported_nips,
                "software": "tenex-khatru-relay",
                "version": "0.1.0"
            },
            "limits": {
                "max_message_length": 524288,
                "max_subscriptions": 100,
                "max_filters": 50,
                "max_event_tags": 2500,
                "max_content_length": 102400,
                "default_query_limit": 100,
                "max_query_limit": 500,
                "max_query_window_hours": 168
            },
            "sync": {
                "relays": sync_relays,
                "kinds": [4199, 14199, 4129, 4200, 4201, 4202, 34199]
            }
        });

        let json = serde_json::to_string_pretty(&config)?;
        std::fs::write(&config_path, json)?;
        Ok(config_path)
    }

    // ── Health checks ─────────────────────────────────────────────────

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

    // ── Adopt a running relay via PID file ────────────────────────────

    /// Try to adopt an already-running relay process found via PID file + health check.
    async fn adopt_running(&self) -> bool {
        let pid = match self.read_pid() {
            Some(pid) => pid,
            None => return false,
        };

        let port = *self.port.read().await;
        if !self.check_health(port).await {
            info!("PID {} is alive but relay not healthy on port {}, removing stale PID", pid, port);
            self.remove_pid();
            return false;
        }

        info!("Adopted running relay (PID {}) on port {}", pid, port);
        self.set_status(ProcessStatus::Running);
        self.start_health_monitoring().await;
        self.start_log_tail().await;
        true
    }

    // ── Health monitoring ─────────────────────────────────────────────

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

    // ── Log tail ──────────────────────────────────────────────────────

    /// Spawn a background task that tails relay.log and feeds lines into the log buffer.
    async fn start_log_tail(&self) {
        self.stop_log_tail().await;

        let (abort_tx, mut abort_rx) = tokio::sync::watch::channel(false);
        *self.log_tail_abort.lock().await = Some(abort_tx);

        let log_path = self.log_path();
        let log_tx = self.log_tx.clone();
        let logs = self.logs.clone();

        tokio::spawn(async move {
            // Open the log file, seek to end, then poll for new lines
            let file = match std::fs::File::open(&log_path) {
                Ok(f) => f,
                Err(_) => return,
            };
            let mut reader = std::io::BufReader::new(file);
            // Seek to end so we only get new output
            let _ = reader.seek(SeekFrom::End(0));

            loop {
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_millis(LOG_TAIL_INTERVAL_MS)) => {},
                    _ = abort_rx.changed() => break,
                }

                let mut line = String::new();
                loop {
                    line.clear();
                    match reader.read_line(&mut line) {
                        Ok(0) => break, // no new data
                        Ok(_) => {
                            let trimmed = line.trim_end();
                            if trimmed.is_empty() {
                                continue;
                            }
                            let entry = LogLine::new(trimmed);
                            let _ = log_tx.send(entry.clone());
                            let mut buf = logs.lock().await;
                            if buf.len() >= MAX_LOG_LINES {
                                buf.pop_front();
                            }
                            buf.push_back(entry);
                        }
                        Err(_) => break,
                    }
                }
            }
        });
    }

    async fn stop_log_tail(&self) {
        if let Some(tx) = self.log_tail_abort.lock().await.take() {
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
        // Already running in our state?
        {
            let status = *self.status.read().await;
            if status == ProcessStatus::Running || status == ProcessStatus::Starting {
                return Ok(());
            }
        }

        // Try to adopt an already-running daemon
        if self.adopt_running().await {
            return Ok(());
        }

        let executable = self
            .resolve_executable()
            .context("Cannot find relay binary")?;

        let port = *self.port.read().await;
        if !Self::is_port_available(port) {
            // Port in use but we couldn't adopt — maybe a stale process or different service
            let msg = format!("Port {} is already in use", port);
            *self.last_error.write().await = Some(msg.clone());
            self.set_status(ProcessStatus::Failed);
            bail!("{}", msg);
        }

        self.set_status(ProcessStatus::Starting);
        *self.last_error.write().await = None;
        self.logs.lock().await.clear();

        let sync_relays = self.sync_relays.read().await.clone();
        let launcher = self.config_store.load_launcher();
        let nip42_auth = launcher
            .local_relay
            .as_ref()
            .and_then(|lr| lr.nip42_auth)
            .unwrap_or(true);
        let config_path = self.write_relay_config(port, &sync_relays, nip42_auth)?;

        // Open log file for stdout/stderr redirection
        let relay_dir = self.relay_dir();
        std::fs::create_dir_all(&relay_dir)?;
        let log_file = std::fs::File::create(self.log_path())
            .with_context(|| "Failed to create relay log file")?;
        let log_file_err = log_file.try_clone()
            .with_context(|| "Failed to clone log file handle")?;

        // Spawn as a detached daemon using std::process::Command
        let child = {
            use std::os::unix::process::CommandExt;

            let mut cmd = std::process::Command::new(&executable);
            cmd.args(["-config", &config_path.to_string_lossy()])
                .stdin(std::process::Stdio::null())
                .stdout(log_file)
                .stderr(log_file_err);

            // Create a new session so the relay survives parent exit
            unsafe {
                cmd.pre_exec(|| {
                    libc::setsid();
                    Ok(())
                });
            }

            cmd.spawn()
                .with_context(|| format!("Failed to start relay: {}", executable))?
        };

        let pid = child.id();
        self.write_pid(pid)?;

        // Drop the Child handle — the process is detached and will keep running
        drop(child);

        if self.wait_for_readiness(port).await {
            self.set_status(ProcessStatus::Running);
            self.start_health_monitoring().await;
            self.start_log_tail().await;
            info!("Relay daemon started (PID {}) on port {}", pid, port);
        } else {
            self.set_status(ProcessStatus::Failed);
            *self.last_error.write().await =
                Some("Relay failed to become ready within timeout".into());
            // Kill the orphaned daemon
            if let Some(read_pid) = self.read_pid() {
                graceful_shutdown_pid(read_pid, GRACEFUL_SHUTDOWN_SECS).await;
            }
            self.remove_pid();
            bail!("Relay failed readiness check");
        }

        Ok(())
    }

    async fn stop(&self) -> Result<()> {
        self.stop_health_monitoring().await;
        self.stop_log_tail().await;

        if let Some(pid) = self.read_pid() {
            graceful_shutdown_pid(pid, GRACEFUL_SHUTDOWN_SECS).await;
        }
        self.remove_pid();

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
