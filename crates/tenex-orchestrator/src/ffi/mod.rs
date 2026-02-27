mod config_api;
mod lifecycle_api;
mod onboarding_api;
mod process_api;
mod provider_api;

use std::sync::Arc;

use tokio::sync::{Mutex, RwLock};

use crate::config::ConfigStore;
use crate::onboarding::OnboardingStateMachine;
use crate::process::daemon::DaemonManager;
use crate::process::ngrok::NgrokManager;
use crate::process::relay::RelayManager;

/// Error type exposed via UniFFI.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum OrchestratorError {
    #[error("{message}")]
    General { message: String },
    #[error("Config error: {message}")]
    Config { message: String },
    #[error("Process error: {message}")]
    Process { message: String },
}

impl From<anyhow::Error> for OrchestratorError {
    fn from(err: anyhow::Error) -> Self {
        OrchestratorError::General {
            message: err.to_string(),
        }
    }
}

/// Core orchestrator object exposed via UniFFI.
/// Manages all TENEX system services and configuration.
#[derive(uniffi::Object)]
pub struct OrchestratorCore {
    config_store: Arc<ConfigStore>,
    daemon: Arc<DaemonManager>,
    relay: Arc<RelayManager>,
    ngrok: Arc<NgrokManager>,
    onboarding: Arc<Mutex<OnboardingStateMachine>>,
    runtime: Arc<RwLock<Option<tokio::runtime::Runtime>>>,
}
