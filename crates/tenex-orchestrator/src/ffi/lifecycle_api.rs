use std::path::PathBuf;
use std::sync::Arc;

use tokio::sync::{Mutex, RwLock};

use super::{OrchestratorCore, OrchestratorError};
use crate::config::ConfigStore;
use crate::onboarding::OnboardingStateMachine;
use crate::openclaw;
use crate::process::daemon::DaemonManager;
use crate::process::ngrok::NgrokManager;
use crate::process::relay::RelayManager;
use crate::process::ProcessManager;

#[uniffi::export]
impl OrchestratorCore {
    /// Create a new OrchestratorCore instance.
    /// `repo_root` is the path to the TENEX repository root (for dev binary resolution).
    /// Pass `None` in production when binaries are bundled.
    #[uniffi::constructor]
    pub fn new(repo_root: Option<String>) -> Self {
        let config_store = Arc::new(ConfigStore::new());
        let repo_path = repo_root.map(PathBuf::from);

        let daemon = Arc::new(DaemonManager::new(repo_path.clone(), config_store.clone()));
        let relay = Arc::new(RelayManager::new(repo_path, config_store.clone()));
        let ngrok = Arc::new(NgrokManager::new());

        let has_openclaw = openclaw::detect().is_some();
        let onboarding = Arc::new(Mutex::new(OnboardingStateMachine::new(has_openclaw)));

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .ok();

        Self {
            config_store,
            daemon,
            relay,
            ngrok,
            onboarding,
            runtime: Arc::new(RwLock::new(runtime)),
        }
    }

    /// Initialize the orchestrator: load config, configure services from stored settings.
    pub fn init(&self) -> Result<(), OrchestratorError> {
        // Run migration before anything else
        self.config_store.migrate_launcher_config();

        let launcher = self.config_store.load_launcher();

        // Configure relay from launcher config
        if let Some(ref local_relay) = launcher.local_relay {
            let port = local_relay.port.unwrap_or(7777);
            let sync = local_relay
                .sync_relays
                .clone()
                .unwrap_or_else(|| vec!["wss://tenex.chat".into()]);

            if let Some(ref rt) = *self.runtime.blocking_read() {
                let relay = self.relay.clone();
                rt.block_on(async move {
                    relay.configure(port, sync).await;
                });
            }

            if let Some(port) = local_relay.port {
                if let Some(ref rt) = *self.runtime.blocking_read() {
                    let ngrok = self.ngrok.clone();
                    rt.block_on(async move {
                        ngrok.configure(port).await;
                    });
                }
            }
        }

        Ok(())
    }

    /// Shut down all managed services.
    pub fn shutdown(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let daemon = self.daemon.clone();
            let relay = self.relay.clone();
            let ngrok = self.ngrok.clone();

            rt.block_on(async move {
                let _ = ngrok.stop().await;
                let _ = relay.stop().await;
                let _ = daemon.stop().await;
            });
        }

        Ok(())
    }

    /// Check if onboarding is needed.
    pub fn needs_onboarding(&self) -> bool {
        self.config_store.needs_onboarding()
    }
}
