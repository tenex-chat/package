use super::{OrchestratorCore, OrchestratorError};

#[uniffi::export]
impl OrchestratorCore {
    /// Load all config as a JSON string.
    pub fn load_config_json(&self) -> String {
        serde_json::to_string_pretty(&self.config_store.load_config()).unwrap_or_default()
    }

    /// Save config from a JSON string.
    pub fn save_config_json(&self, json: String) -> Result<(), OrchestratorError> {
        let config = serde_json::from_str(&json).map_err(|e| OrchestratorError::Config {
            message: format!("Invalid config JSON: {}", e),
        })?;
        self.config_store
            .save_config(&config)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Load providers as a JSON string.
    pub fn load_providers_json(&self) -> String {
        serde_json::to_string_pretty(&self.config_store.load_providers()).unwrap_or_default()
    }

    /// Save providers from a JSON string.
    pub fn save_providers_json(&self, json: String) -> Result<(), OrchestratorError> {
        let providers =
            serde_json::from_str(&json).map_err(|e| OrchestratorError::Config {
                message: format!("Invalid providers JSON: {}", e),
            })?;
        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Load LLMs as a JSON string.
    pub fn load_llms_json(&self) -> String {
        serde_json::to_string_pretty(&self.config_store.load_llms()).unwrap_or_default()
    }

    /// Save LLMs from a JSON string.
    pub fn save_llms_json(&self, json: String) -> Result<(), OrchestratorError> {
        let llms = serde_json::from_str(&json).map_err(|e| OrchestratorError::Config {
            message: format!("Invalid LLMs JSON: {}", e),
        })?;
        self.config_store
            .save_llms(&llms)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Load embed config as a JSON string.
    pub fn load_embed_json(&self) -> String {
        serde_json::to_string_pretty(&self.config_store.load_embed()).unwrap_or_default()
    }

    /// Save embed config from a JSON string.
    pub fn save_embed_json(&self, json: String) -> Result<(), OrchestratorError> {
        let embed = serde_json::from_str(&json).map_err(|e| OrchestratorError::Config {
            message: format!("Invalid embed JSON: {}", e),
        })?;
        self.config_store
            .save_embed(&embed)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Load image config as a JSON string.
    pub fn load_image_json(&self) -> String {
        serde_json::to_string_pretty(&self.config_store.load_image()).unwrap_or_default()
    }

    /// Save image config from a JSON string.
    pub fn save_image_json(&self, json: String) -> Result<(), OrchestratorError> {
        let image = serde_json::from_str(&json).map_err(|e| OrchestratorError::Config {
            message: format!("Invalid image JSON: {}", e),
        })?;
        self.config_store
            .save_image(&image)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Load launcher config as a JSON string.
    pub fn load_launcher_json(&self) -> String {
        serde_json::to_string_pretty(&self.config_store.load_launcher()).unwrap_or_default()
    }

    /// Save launcher config from a JSON string.
    pub fn save_launcher_json(&self, json: String) -> Result<(), OrchestratorError> {
        let launcher =
            serde_json::from_str(&json).map_err(|e| OrchestratorError::Config {
                message: format!("Invalid launcher JSON: {}", e),
            })?;
        self.config_store
            .save_launcher(&launcher)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Run config migration (launcher fields from config.json → launcher.json).
    pub fn migrate_config(&self) {
        self.config_store.migrate_launcher_config();
    }

    /// Add a key to an existing provider. Creates the provider if it doesn't exist.
    pub fn add_provider_key(
        &self,
        provider_id: String,
        api_key: String,
    ) -> Result<(), OrchestratorError> {
        let mut providers = self.config_store.load_providers();
        if let Some(entry) = providers.providers.get_mut(&provider_id) {
            entry.api_keys.push(api_key);
        } else {
            providers
                .providers
                .insert(provider_id, crate::config::ProviderEntry::new(api_key));
        }
        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Remove a key from a provider by index.
    pub fn remove_provider_key(
        &self,
        provider_id: String,
        index: u32,
    ) -> Result<(), OrchestratorError> {
        let mut providers = self.config_store.load_providers();
        if let Some(entry) = providers.providers.get_mut(&provider_id) {
            let idx = index as usize;
            if idx < entry.api_keys.len() {
                entry.api_keys.remove(idx);
            }
        }
        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Reorder a key within a provider's key list.
    pub fn reorder_provider_key(
        &self,
        provider_id: String,
        from_index: u32,
        to_index: u32,
    ) -> Result<(), OrchestratorError> {
        let mut providers = self.config_store.load_providers();
        if let Some(entry) = providers.providers.get_mut(&provider_id) {
            let from = from_index as usize;
            let to = to_index as usize;
            if from < entry.api_keys.len() && to < entry.api_keys.len() {
                let key = entry.api_keys.remove(from);
                entry.api_keys.insert(to, key);
            }
        }
        self.config_store
            .save_providers(&providers)
            .map_err(|e| OrchestratorError::Config {
                message: e.to_string(),
            })
    }

    /// Check if config file exists.
    pub fn config_exists(&self) -> bool {
        self.config_store.config_exists()
    }

    /// Check if providers file exists.
    pub fn providers_exist(&self) -> bool {
        self.config_store.providers_exist()
    }

    /// Check if LLMs file exists.
    pub fn llms_exist(&self) -> bool {
        self.config_store.llms_exist()
    }
}
