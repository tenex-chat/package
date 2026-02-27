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

pub async fn run(force_onboarding: bool) -> Result<()> {
    let config_store = Arc::new(ConfigStore::new());
    let needs_onboarding = force_onboarding || config_store.needs_onboarding();

    if needs_onboarding {
        onboarding::run(&config_store).await?;
    }

    let repo_root = tenex_orchestrator::process::detect_repo_root();
    let daemon = Arc::new(DaemonManager::new(repo_root.clone(), config_store.clone()));
    let relay = Arc::new(RelayManager::new(repo_root, config_store.clone()));
    let ngrok = Arc::new(NgrokManager::new());

    start_services(&config_store, &daemon, &relay, &ngrok).await;

    dashboard::run(&config_store, &daemon, &relay, &ngrok).await
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
