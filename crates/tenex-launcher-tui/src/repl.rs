use std::ffi::CString;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use indicatif::{ProgressBar, ProgressStyle};
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;
use tenex_orchestrator::process::ProcessManager;

use crate::dashboard;
use crate::display;
use crate::onboarding;

pub async fn run(force_onboarding: bool, backend_override: Option<String>) -> Result<()> {
    let config_store = Arc::new(ConfigStore::new());
    let needs_onboarding = force_onboarding || config_store.needs_onboarding();

    let launch_repl = if needs_onboarding {
        let choice = onboarding::run(&config_store, backend_override.as_deref()).await?;
        matches!(choice, onboarding::ClientChoice::Repl)
    } else {
        false
    };

    let repo_root = tenex_orchestrator::process::detect_repo_root();
    let daemon = Arc::new(DaemonManager::new(repo_root.clone(), config_store.clone()));
    let relay = Arc::new(RelayManager::new(repo_root, config_store.clone()));
    let ngrok = Arc::new(NgrokManager::new());

    // After fresh onboarding, auto-boot the meta project so it starts immediately.
    if needs_onboarding {
        daemon.set_boot_patterns(vec!["meta".into()]);
    }

    start_services(&config_store, &daemon, &relay, &ngrok).await;

    if launch_repl {
        launch_tenex_repl()?;
    }

    dashboard::run(&config_store, &daemon, &relay, &ngrok).await
}

/// Find and launch the tenex-repl chat client, replacing the current process.
fn launch_tenex_repl() -> Result<()> {
    let bin = resolve_repl_bin().ok_or_else(|| {
        anyhow::anyhow!(
            "Cannot find tenex-repl binary. Build it with: \
             cd deps/tui && cargo build --bin tenex-repl"
        )
    })?;

    display::blank();
    display::context("Launching REPL client…");

    let c_bin = CString::new(bin.as_str())
        .map_err(|e| anyhow::anyhow!("Invalid binary path: {}", e))?;
    let argv = [c_bin.as_ptr(), std::ptr::null()];

    // execvp replaces this process — only returns on error
    unsafe { libc::execvp(c_bin.as_ptr(), argv.as_ptr()) };

    Err(anyhow::anyhow!(
        "Failed to exec tenex-repl: {}",
        std::io::Error::last_os_error()
    ))
}

/// Resolve the tenex-repl binary path.
///
/// 1. `deps/tui/target/debug/tenex-repl` or `deps/tui/target/release/tenex-repl` (dev)
/// 2. Next to the current executable
/// 3. `tenex-repl` on $PATH
fn resolve_repl_bin() -> Option<String> {
    // 1. Dev build — walk up from current exe to find repo root
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(|p| p.to_path_buf());
        for _ in 0..8 {
            if let Some(d) = dir {
                for profile in &["release", "debug"] {
                    let candidate = d.join(format!("deps/tui/target/{}/tenex-repl", profile));
                    if candidate.exists() {
                        return Some(candidate.to_string_lossy().into());
                    }
                }
                dir = d.parent().map(|p| p.to_path_buf());
            } else {
                break;
            }
        }
    }

    // 2. Next to current executable
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sibling = dir.join("tenex-repl");
            if sibling.exists() {
                return Some(sibling.to_string_lossy().into());
            }
        }
    }

    // 3. On PATH
    if let Ok(out) = std::process::Command::new("which")
        .arg("tenex-repl")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
    {
        if out.status.success() {
            let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !path.is_empty() {
                return Some(path);
            }
        }
    }

    None
}

async fn start_services(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) {
    let launcher = config_store.load_launcher();
    let relay_enabled = launcher
        .local_relay
        .as_ref()
        .map(|r| r.enabled == Some(true) && r.auto_start != Some(false))
        .unwrap_or(false);
    let ngrok_enabled = launcher
        .local_relay
        .as_ref()
        .map(|r| r.ngrok_enabled == Some(true))
        .unwrap_or(false);

    // 1. Relay first — daemon connects to it on startup
    if relay_enabled {
        // Configure relay with port/sync_relays from launcher config
        if let Some(ref lr) = launcher.local_relay {
            let port = lr.port.unwrap_or(7777);
            let sync_relays = lr.sync_relays.clone().unwrap_or_else(|| vec!["wss://tenex.chat".into()]);
            relay.configure(port, sync_relays).await;
        }

        let sp = spinner("Starting relay...");
        if let Err(e) = relay.start().await {
            sp.finish_and_clear();
            display::context(&format!("Relay failed to start: {}", e));
        } else {
            sp.finish_and_clear();
        }
    }

    // 2. Daemon after relay is ready
    {
        let sp = spinner("Starting daemon...");
        if let Err(e) = daemon.start().await {
            sp.finish_and_clear();
            display::context(&format!("Daemon failed to start: {}", e));
        } else {
            sp.finish_and_clear();
        }
    }

    // 3. Ngrok after relay if configured
    if relay_enabled && ngrok_enabled {
        let sp = spinner("Starting ngrok tunnel...");
        if let Err(e) = ngrok.start().await {
            sp.finish_and_clear();
            display::context(&format!("Ngrok failed to start: {}", e));
        } else {
            sp.finish_and_clear();
        }
    }
}

fn spinner(msg: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .tick_chars("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            .template("{spinner:.color256(222)} {msg}")
            .unwrap_or_else(|_| ProgressStyle::default_spinner()),
    );
    pb.set_message(msg.to_string());
    pb.enable_steady_tick(Duration::from_millis(80));
    pb
}
