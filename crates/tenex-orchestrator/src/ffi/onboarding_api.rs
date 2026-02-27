use super::{OrchestratorCore, OrchestratorError};
use crate::onboarding;

/// Onboarding step as a simple string for FFI.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum FfiOnboardingStep {
    Identity,
    OpenClawImport,
    Relay,
    Providers,
    LLMs,
    FirstProject,
    HireAgents,
    NudgesSkills,
    MobilePairing,
    Done,
}

impl From<onboarding::OnboardingStep> for FfiOnboardingStep {
    fn from(s: onboarding::OnboardingStep) -> Self {
        match s {
            onboarding::OnboardingStep::Identity => FfiOnboardingStep::Identity,
            onboarding::OnboardingStep::OpenClawImport => FfiOnboardingStep::OpenClawImport,
            onboarding::OnboardingStep::Relay => FfiOnboardingStep::Relay,
            onboarding::OnboardingStep::Providers => FfiOnboardingStep::Providers,
            onboarding::OnboardingStep::LLMs => FfiOnboardingStep::LLMs,
            onboarding::OnboardingStep::FirstProject => FfiOnboardingStep::FirstProject,
            onboarding::OnboardingStep::HireAgents => FfiOnboardingStep::HireAgents,
            onboarding::OnboardingStep::NudgesSkills => FfiOnboardingStep::NudgesSkills,
            onboarding::OnboardingStep::MobilePairing => FfiOnboardingStep::MobilePairing,
            onboarding::OnboardingStep::Done => FfiOnboardingStep::Done,
        }
    }
}

#[uniffi::export]
impl OrchestratorCore {
    /// Get the current onboarding step.
    pub fn onboarding_step(&self) -> FfiOnboardingStep {
        self.onboarding.blocking_lock().step.into()
    }

    /// Advance to the next onboarding step.
    pub fn onboarding_next(&self) {
        self.onboarding.blocking_lock().next();
    }

    /// Go back to the previous onboarding step.
    pub fn onboarding_back(&self) {
        self.onboarding.blocking_lock().back();
    }

    /// Check if onboarding is complete.
    pub fn onboarding_is_complete(&self) -> bool {
        self.onboarding.blocking_lock().is_complete()
    }

    /// Seed default LLM configurations based on connected providers.
    /// Returns true if any configs were added.
    pub fn seed_default_llms(&self) -> Result<bool, OrchestratorError> {
        let providers = self.config_store.load_providers();
        let mut llms = self.config_store.load_llms();

        let changed = onboarding::seed_default_llms(&mut llms, &providers);

        if changed {
            self.config_store
                .save_llms(&llms)
                .map_err(|e| OrchestratorError::Config {
                    message: e.to_string(),
                })?;
        }

        Ok(changed)
    }

    /// Save relay configuration from onboarding.
    /// `mode` should be "remote" or "local".
    pub fn save_onboarding_relay(
        &self,
        mode: String,
        remote_url: String,
        ngrok_enabled: bool,
    ) -> Result<(), OrchestratorError> {
        let relay_mode = match mode.as_str() {
            "local" => onboarding::RelayMode::Local,
            _ => onboarding::RelayMode::Remote,
        };

        let mut config = self.config_store.load_config();
        let mut launcher = self.config_store.load_launcher();
        onboarding::build_relay_config(&mut config, &mut launcher, relay_mode, &remote_url, ngrok_enabled);
        self.config_store
            .save_config(&config)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })?;
        self.config_store
            .save_launcher(&launcher)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Detect OpenClaw installation. Returns JSON with credentials if found, or empty string.
    pub fn detect_openclaw(&self) -> String {
        match crate::openclaw::detect() {
            Some(detected) => {
                let json = serde_json::json!({
                    "stateDir": detected.state_dir.to_string_lossy(),
                    "credentials": detected.credentials.iter().map(|c| {
                        serde_json::json!({
                            "provider": c.provider,
                            "apiKey": c.api_key,
                        })
                    }).collect::<Vec<_>>(),
                    "primaryModel": detected.primary_model,
                });
                serde_json::to_string_pretty(&json).unwrap_or_default()
            }
            None => String::new(),
        }
    }

    /// Import OpenClaw credentials into providers config.
    pub fn import_openclaw_credentials(&self) -> Result<bool, OrchestratorError> {
        let detected = match crate::openclaw::detect() {
            Some(d) => d,
            None => return Ok(false),
        };

        if detected.credentials.is_empty() {
            return Ok(false);
        }

        let mut providers = self.config_store.load_providers();
        for cred in &detected.credentials {
            providers.providers.insert(
                cred.provider.clone(),
                crate::config::ProviderEntry::new(&cred.api_key),
            );
        }

        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })?;

        Ok(true)
    }
}
