use super::{OrchestratorCore, OrchestratorError};
use crate::provider;

/// Information about a detected provider.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ProviderInfo {
    pub id: String,
    pub display_name: String,
    pub available: bool,
    pub connected: bool,
    pub subtitle: String,
}

#[uniffi::export]
impl OrchestratorCore {
    /// Detect all providers and return their status.
    pub fn detect_providers(&self) -> Vec<ProviderInfo> {
        let providers = self.config_store.load_providers();

        let detection = if let Some(ref rt) = *self.runtime.blocking_read() {
            rt.block_on(provider::detect_providers())
        } else {
            // Fallback: no async runtime
            provider::DetectionResult {
                availability: std::collections::HashMap::new(),
            }
        };

        let display_names = provider::provider_display_names();

        provider::PROVIDER_LIST_ORDER
            .iter()
            .map(|&id| {
                let connected = providers.providers.contains_key(id);
                let available = detection.availability.get(id).copied().unwrap_or(false);
                let entry = providers.providers.get(id);
                let api_key = entry.and_then(|p| p.primary_key());
                let key_count = entry.map(|p| p.api_keys.len()).unwrap_or(0);

                ProviderInfo {
                    id: id.to_string(),
                    display_name: display_names
                        .get(id)
                        .unwrap_or(&id)
                        .to_string(),
                    available,
                    connected,
                    subtitle: provider::provider_subtitle(id, connected, api_key, key_count),
                }
            })
            .collect()
    }

    /// Auto-connect detected providers. Returns true if any were added.
    pub fn auto_connect_providers(&self) -> Result<bool, OrchestratorError> {
        let mut providers = self.config_store.load_providers();

        let changed = if let Some(ref rt) = *self.runtime.blocking_read() {
            rt.block_on(provider::auto_connect_detected(&mut providers))
        } else {
            false
        };

        if changed {
            self.config_store
                .save_providers(&providers)
                .map_err(|e| OrchestratorError::Config {
                    message: e.to_string(),
                })?;
        }

        Ok(changed)
    }

    /// Connect a provider with the given API key/credential.
    pub fn connect_provider(
        &self,
        provider_id: String,
        api_key: String,
    ) -> Result<(), OrchestratorError> {
        let mut providers = self.config_store.load_providers();
        providers.providers.insert(
            provider_id,
            crate::config::ProviderEntry::new(api_key),
        );
        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Disconnect a provider.
    pub fn disconnect_provider(&self, provider_id: String) -> Result<(), OrchestratorError> {
        let mut providers = self.config_store.load_providers();
        providers.providers.remove(&provider_id);
        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Fetch available models from a provider (Ollama or OpenRouter).
    pub fn fetch_models(&self, provider_id: String) -> Result<Vec<String>, OrchestratorError> {
        let providers = self.config_store.load_providers();

        if let Some(ref rt) = *self.runtime.blocking_read() {
            let result = rt.block_on(crate::catalog::fetch_models(
                &provider_id,
                &providers.providers,
            ));
            result.map_err(|e| OrchestratorError::General {
                message: e.to_string(),
            })
        } else {
            Ok(vec![])
        }
    }
}
