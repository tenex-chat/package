pub mod daemon;
pub mod ngrok;
pub mod relay;

use std::collections::VecDeque;
use std::fmt;
use std::process::Stdio;
use std::sync::Arc;
use std::time::SystemTime;

use async_trait::async_trait;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Child;
use tokio::sync::{broadcast, Mutex};

/// Status shared by all managed processes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessStatus {
    Stopped,
    Starting,
    Running,
    Failed,
}

impl fmt::Display for ProcessStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProcessStatus::Stopped => write!(f, "Stopped"),
            ProcessStatus::Starting => write!(f, "Starting..."),
            ProcessStatus::Running => write!(f, "Running"),
            ProcessStatus::Failed => write!(f, "Failed"),
        }
    }
}

/// A single log line captured from a managed process.
#[derive(Debug, Clone)]
pub struct LogLine {
    pub timestamp: SystemTime,
    pub text: String,
}

impl LogLine {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            timestamp: SystemTime::now(),
            text: text.into(),
        }
    }
}

/// Common interface for all managed processes (daemon, relay, ngrok).
#[async_trait]
pub trait ProcessManager: Send + Sync {
    fn name(&self) -> &str;
    async fn status(&self) -> ProcessStatus;
    async fn last_error(&self) -> Option<String>;
    async fn log_buffer(&self) -> Vec<LogLine>;
    fn subscribe_status(&self) -> broadcast::Receiver<ProcessStatus>;
    fn subscribe_logs(&self) -> broadcast::Receiver<LogLine>;
    async fn start(&self) -> anyhow::Result<()>;
    async fn stop(&self) -> anyhow::Result<()>;
}

/// Shared constants for process management.
pub const MAX_LOG_LINES: usize = 200;
pub const GRACEFUL_SHUTDOWN_SECS: u64 = 5;

// =============================================================================
// Shared helpers used by daemon, relay, and ngrok managers
// =============================================================================

/// Read lines from an async reader and push them into the log buffer + broadcast.
pub(crate) async fn read_lines<R: tokio::io::AsyncRead + Unpin>(
    reader: R,
    log_tx: broadcast::Sender<LogLine>,
    logs: Arc<Mutex<VecDeque<LogLine>>>,
) {
    let mut lines = BufReader::new(reader).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if line.is_empty() {
            continue;
        }
        let entry = LogLine::new(line);
        let _ = log_tx.send(entry.clone());
        let mut buf = logs.lock().await;
        if buf.len() >= MAX_LOG_LINES {
            buf.pop_front();
        }
        buf.push_back(entry);
    }
}

/// Check if a command exists on the system PATH.
pub(crate) fn which_exists(cmd: &str) -> bool {
    std::process::Command::new("which")
        .arg(cmd)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Find the bun runtime binary.
pub(crate) fn find_bun() -> Option<String> {
    let candidates = ["/opt/homebrew/bin/bun", "/usr/local/bin/bun"];

    for c in &candidates {
        if std::path::Path::new(c).exists() {
            return Some(c.to_string());
        }
    }

    if let Some(home) = dirs::home_dir() {
        let bun_home = home.join(".bun/bin/bun");
        if bun_home.exists() {
            return Some(bun_home.to_string_lossy().into());
        }
    }

    None
}

/// Send SIGTERM to a child process, wait for graceful shutdown, then SIGKILL.
pub(crate) async fn graceful_shutdown(child: &mut Child, timeout_secs: u64) {
    #[cfg(unix)]
    {
        if let Some(pid) = child.id() {
            // SAFETY: libc::kill with SIGTERM is safe for valid PIDs
            unsafe {
                libc::kill(pid as i32, libc::SIGTERM);
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = child.start_kill();
    }

    let timeout =
        tokio::time::timeout(std::time::Duration::from_secs(timeout_secs), child.wait()).await;

    if timeout.is_err() {
        tracing::warn!(
            "Process did not exit after {}s, force killing",
            timeout_secs
        );
        let _ = child.kill().await;
    }
}
