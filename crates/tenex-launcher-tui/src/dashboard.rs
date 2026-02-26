use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;

use crate::display;

pub async fn run(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) -> Result<()> {
    display::dashboard_greeting();
    println!("  Dashboard coming soon.");
    Ok(())
}
