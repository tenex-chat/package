use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;

use crate::dashboard;
use crate::onboarding;

pub async fn run(force_onboarding: bool) -> Result<()> {
    let config_store = Arc::new(ConfigStore::new());
    let needs_onboarding = force_onboarding || config_store.needs_onboarding();

    if needs_onboarding {
        onboarding::run(&config_store).await?;
    }

    let daemon = Arc::new(DaemonManager::new(None));
    let relay = Arc::new(RelayManager::new(None, config_store.clone()));
    let ngrok = Arc::new(NgrokManager::new());

    dashboard::run(&config_store, &daemon, &relay, &ngrok).await
}
