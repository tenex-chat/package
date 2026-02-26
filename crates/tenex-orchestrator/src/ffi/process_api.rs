use super::{OrchestratorCore, OrchestratorError};
use crate::process::ProcessManager;

/// Process status as a simple string for FFI.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum FfiProcessStatus {
    Stopped,
    Starting,
    Running,
    Failed,
}

impl From<crate::process::ProcessStatus> for FfiProcessStatus {
    fn from(s: crate::process::ProcessStatus) -> Self {
        match s {
            crate::process::ProcessStatus::Stopped => FfiProcessStatus::Stopped,
            crate::process::ProcessStatus::Starting => FfiProcessStatus::Starting,
            crate::process::ProcessStatus::Running => FfiProcessStatus::Running,
            crate::process::ProcessStatus::Failed => FfiProcessStatus::Failed,
        }
    }
}

/// Status snapshot of all three services.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ServiceStatusSnapshot {
    pub daemon_status: FfiProcessStatus,
    pub daemon_error: Option<String>,
    pub relay_status: FfiProcessStatus,
    pub relay_error: Option<String>,
    pub ngrok_status: FfiProcessStatus,
    pub ngrok_error: Option<String>,
    pub ngrok_tunnel_url: Option<String>,
    pub relay_url: Option<String>,
}

#[uniffi::export]
impl OrchestratorCore {
    /// Get a snapshot of all service statuses.
    pub fn service_status(&self) -> ServiceStatusSnapshot {
        let rt_guard = self.runtime.blocking_read();
        let Some(ref rt) = *rt_guard else {
            return ServiceStatusSnapshot {
                daemon_status: FfiProcessStatus::Stopped,
                daemon_error: None,
                relay_status: FfiProcessStatus::Stopped,
                relay_error: None,
                ngrok_status: FfiProcessStatus::Stopped,
                ngrok_error: None,
                ngrok_tunnel_url: None,
                relay_url: None,
            };
        };

        let daemon = self.daemon.clone();
        let relay = self.relay.clone();
        let ngrok = self.ngrok.clone();

        rt.block_on(async move {
            ServiceStatusSnapshot {
                daemon_status: daemon.status().await.into(),
                daemon_error: daemon.last_error().await,
                relay_status: relay.status().await.into(),
                relay_error: relay.last_error().await,
                ngrok_status: ngrok.status().await.into(),
                ngrok_error: ngrok.last_error().await,
                ngrok_tunnel_url: ngrok.tunnel_url().await,
                relay_url: Some(relay.local_relay_url().await),
            }
        })
    }

    /// Start the daemon.
    pub fn start_daemon(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let daemon = self.daemon.clone();
            rt.block_on(async move { daemon.start().await })?;
        }
        Ok(())
    }

    /// Stop the daemon.
    pub fn stop_daemon(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let daemon = self.daemon.clone();
            rt.block_on(async move { daemon.stop().await })?;
        }
        Ok(())
    }

    /// Start the relay.
    pub fn start_relay(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let relay = self.relay.clone();
            rt.block_on(async move { relay.start().await })?;
        }
        Ok(())
    }

    /// Stop the relay.
    pub fn stop_relay(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let relay = self.relay.clone();
            rt.block_on(async move { relay.stop().await })?;
        }
        Ok(())
    }

    /// Start ngrok.
    pub fn start_ngrok(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let ngrok = self.ngrok.clone();
            rt.block_on(async move { ngrok.start().await })?;
        }
        Ok(())
    }

    /// Stop ngrok.
    pub fn stop_ngrok(&self) -> Result<(), OrchestratorError> {
        if let Some(ref rt) = *self.runtime.blocking_read() {
            let ngrok = self.ngrok.clone();
            rt.block_on(async move { ngrok.stop().await })?;
        }
        Ok(())
    }

    /// Get recent daemon logs.
    pub fn daemon_logs(&self) -> Vec<String> {
        let Some(ref rt) = *self.runtime.blocking_read() else {
            return vec![];
        };
        let daemon = self.daemon.clone();
        rt.block_on(async move {
            daemon.log_buffer().await.into_iter().map(|l| l.text).collect()
        })
    }

    /// Get recent relay logs.
    pub fn relay_logs(&self) -> Vec<String> {
        let Some(ref rt) = *self.runtime.blocking_read() else {
            return vec![];
        };
        let relay = self.relay.clone();
        rt.block_on(async move {
            relay.log_buffer().await.into_iter().map(|l| l.text).collect()
        })
    }

    /// Get recent ngrok logs.
    pub fn ngrok_logs(&self) -> Vec<String> {
        let Some(ref rt) = *self.runtime.blocking_read() else {
            return vec![];
        };
        let ngrok = self.ngrok.clone();
        rt.block_on(async move {
            ngrok.log_buffer().await.into_iter().map(|l| l.text).collect()
        })
    }
}
