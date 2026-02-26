use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;

use anyhow::{Context, Result};
use async_trait::async_trait;
use tokio::process::Command;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{error, info};

use super::{
    find_bun, graceful_shutdown, read_lines, which_exists, LogLine, ProcessManager, ProcessStatus,
    GRACEFUL_SHUTDOWN_SECS, MAX_LOG_LINES,
};

/// Manages the TENEX daemon process lifecycle.
///
/// Resolution order for daemon binary:
/// 1. Compiled binary at `<repo_root>/deps/backend/dist/tenex-daemon`
/// 2. Run via bun from source: `bun run <repo_root>/deps/backend/src/index.ts daemon`
/// 3. `tenex-daemon` on system PATH
pub struct DaemonManager {
    repo_root: Option<PathBuf>,
    status: Arc<RwLock<ProcessStatus>>,
    last_error: Arc<RwLock<Option<String>>>,
    logs: Arc<Mutex<VecDeque<LogLine>>>,
    child: Arc<Mutex<Option<tokio::process::Child>>>,
    status_tx: broadcast::Sender<ProcessStatus>,
    log_tx: broadcast::Sender<LogLine>,
}

impl DaemonManager {
    pub fn new(repo_root: Option<PathBuf>) -> Self {
        let (status_tx, _) = broadcast::channel(64);
        let (log_tx, _) = broadcast::channel(256);

        Self {
            repo_root,
            status: Arc::new(RwLock::new(ProcessStatus::Stopped)),
            last_error: Arc::new(RwLock::new(None)),
            logs: Arc::new(Mutex::new(VecDeque::with_capacity(MAX_LOG_LINES))),
            child: Arc::new(Mutex::new(None)),
            status_tx,
            log_tx,
        }
    }

    fn set_status(&self, status: ProcessStatus) {
        if let Ok(mut s) = self.status.try_write() {
            *s = status;
        }
        let _ = self.status_tx.send(status);
    }

    fn resolve_executable(&self) -> Option<(String, Vec<String>)> {
        if let Some(root) = &self.repo_root {
            let compiled = root.join("deps/backend/dist/tenex-daemon");
            if compiled.exists() {
                return Some((compiled.to_string_lossy().into(), vec!["daemon".into()]));
            }

            if let Some(bun) = find_bun() {
                let entrypoint = root.join("deps/backend/src/index.ts");
                if entrypoint.exists() {
                    return Some((
                        bun,
                        vec![
                            "run".into(),
                            entrypoint.to_string_lossy().into(),
                            "daemon".into(),
                        ],
                    ));
                }
            }
        }

        if which_exists("tenex-daemon") {
            return Some(("tenex-daemon".into(), vec!["daemon".into()]));
        }

        None
    }

    fn build_env(&self) -> Vec<(String, String)> {
        let mut env: Vec<(String, String)> = std::env::vars().collect();

        if let Some(root) = &self.repo_root {
            let node_bin = root
                .join("deps/backend/node_modules/.bin")
                .to_string_lossy()
                .to_string();
            if let Some(pos) = env.iter().position(|(k, _)| k == "PATH") {
                env[pos].1 = format!("{}:{}", node_bin, env[pos].1);
            }
        }

        env
    }
}

#[async_trait]
impl ProcessManager for DaemonManager {
    fn name(&self) -> &str {
        "Daemon"
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

        let (executable, arguments) = self.resolve_executable().context(
            "Cannot find tenex daemon binary. Looked for: deps/backend/dist/tenex-daemon, bun + deps/backend/src/index.ts",
        )?;

        self.set_status(ProcessStatus::Starting);
        *self.last_error.write().await = None;
        self.logs.lock().await.clear();

        let env = self.build_env();

        let mut cmd = Command::new(&executable);
        cmd.args(&arguments)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .envs(env)
            .kill_on_drop(true);

        if let Some(root) = &self.repo_root {
            cmd.current_dir(root.join("deps/backend"));
        }

        let mut child = cmd
            .spawn()
            .with_context(|| format!("Failed to start daemon: {} {}", executable, arguments.join(" ")))?;

        info!("Daemon started: {} {}", executable, arguments.join(" "));

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

        let status_arc = self.status.clone();
        let last_error_arc = self.last_error.clone();
        let status_tx = self.status_tx.clone();
        let child_arc = self.child.clone();

        *self.child.lock().await = Some(child);

        // Spawn termination watcher
        tokio::spawn(async move {
            let exit_status = {
                let mut guard = child_arc.lock().await;
                if let Some(ref mut c) = *guard {
                    c.wait().await.ok()
                } else {
                    None
                }
            };

            let current = *status_arc.read().await;
            if current == ProcessStatus::Running || current == ProcessStatus::Starting {
                let code = exit_status.and_then(|s| s.code()).unwrap_or(-1);
                if code == 0 {
                    *status_arc.write().await = ProcessStatus::Stopped;
                    let _ = status_tx.send(ProcessStatus::Stopped);
                } else {
                    let msg = format!("Daemon exited with code {}", code);
                    error!("{}", msg);
                    *last_error_arc.write().await = Some(msg);
                    *status_arc.write().await = ProcessStatus::Failed;
                    let _ = status_tx.send(ProcessStatus::Failed);
                }
            }
        });

        self.set_status(ProcessStatus::Running);
        Ok(())
    }

    async fn stop(&self) -> Result<()> {
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
