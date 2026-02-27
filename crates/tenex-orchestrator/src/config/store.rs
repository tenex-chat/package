use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tracing::{error, info, warn};

use super::models::*;

/// Manages reading and writing TENEX configuration files from `~/.tenex/`.
/// Respects `TENEX_BASE_DIR` environment variable for directory override.
pub struct ConfigStore {
    base_dir: PathBuf,
}

impl ConfigStore {
    pub fn new() -> Self {
        Self {
            base_dir: Self::resolve_base_dir(),
        }
    }

    pub fn with_base_dir(base_dir: PathBuf) -> Self {
        Self { base_dir }
    }

    pub fn base_dir(&self) -> &Path {
        &self.base_dir
    }

    fn resolve_base_dir() -> PathBuf {
        if let Ok(override_dir) = std::env::var("TENEX_BASE_DIR") {
            return PathBuf::from(override_dir);
        }
        dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join(".tenex")
    }

    // =========================================================================
    // Load
    // =========================================================================

    pub fn load_all(&self) -> ConfigBundle {
        self.migrate_launcher_config();
        ConfigBundle {
            config: self.load_config(),
            providers: self.load_providers(),
            llms: self.load_llms(),
            embed: self.load_embed(),
            image: self.load_image(),
            launcher: self.load_launcher(),
        }
    }

    pub fn load_config(&self) -> TenexConfig {
        self.load("config.json").unwrap_or_default()
    }

    pub fn load_providers(&self) -> TenexProviders {
        self.load("providers.json").unwrap_or_default()
    }

    pub fn load_llms(&self) -> TenexLLMs {
        self.load("llms.json").unwrap_or_default()
    }

    pub fn load_embed(&self) -> TenexEmbedConfig {
        self.load("embed.json").unwrap_or_default()
    }

    pub fn load_image(&self) -> TenexImageConfig {
        self.load("image.json").unwrap_or_default()
    }

    pub fn load_launcher(&self) -> LauncherConfig {
        self.load("launcher.json").unwrap_or_default()
    }

    fn load<T: serde::de::DeserializeOwned>(&self, filename: &str) -> Option<T> {
        let path = self.base_dir.join(filename);
        if !path.exists() {
            return None;
        }

        match fs::read_to_string(&path) {
            Ok(contents) => match serde_json::from_str(&contents) {
                Ok(value) => Some(value),
                Err(e) => {
                    error!("Failed to parse {}: {}", filename, e);
                    None
                }
            },
            Err(e) => {
                error!("Failed to read {}: {}", filename, e);
                None
            }
        }
    }

    // =========================================================================
    // Save
    // =========================================================================

    pub fn save_config(&self, config: &TenexConfig) -> Result<()> {
        self.save_merged(config, "config.json")
    }

    pub fn save_providers(&self, providers: &TenexProviders) -> Result<()> {
        self.save_merged(providers, "providers.json")
    }

    pub fn save_llms(&self, llms: &TenexLLMs) -> Result<()> {
        self.save(llms, "llms.json")
    }

    pub fn save_embed(&self, embed: &TenexEmbedConfig) -> Result<()> {
        self.save(embed, "embed.json")
    }

    pub fn save_image(&self, image: &TenexImageConfig) -> Result<()> {
        self.save(image, "image.json")
    }

    pub fn save_launcher(&self, launcher: &LauncherConfig) -> Result<()> {
        self.save(launcher, "launcher.json")
    }

    /// Merge-on-save: reads existing JSON from disk, overlays struct values on top,
    /// preserving unknown keys the backend may have written.
    fn save_merged<T: serde::Serialize>(&self, value: &T, filename: &str) -> Result<()> {
        fs::create_dir_all(&self.base_dir)
            .with_context(|| format!("Failed to create directory {:?}", self.base_dir))?;

        let struct_value = serde_json::to_value(value)
            .with_context(|| format!("Failed to serialize {}", filename))?;

        let final_path = self.base_dir.join(filename);

        // Read existing file as raw JSON Value, merge struct on top
        let merged = if final_path.exists() {
            match fs::read_to_string(&final_path) {
                Ok(contents) => match serde_json::from_str::<serde_json::Value>(&contents) {
                    Ok(mut disk_value) => {
                        if let (Some(disk_obj), Some(struct_obj)) =
                            (disk_value.as_object_mut(), struct_value.as_object())
                        {
                            // Struct keys win, unknown keys preserved
                            for (k, v) in struct_obj {
                                disk_obj.insert(k.clone(), v.clone());
                            }
                            // Remove keys that the struct explicitly excludes
                            // (keys present on disk but not in struct serialization with skip_serializing_if)
                            // We don't remove unknown keys — that's the whole point.
                        }
                        disk_value
                    }
                    Err(_) => struct_value,
                },
                Err(_) => struct_value,
            }
        } else {
            struct_value
        };

        let json = serde_json::to_string_pretty(&merged)
            .with_context(|| format!("Failed to serialize merged {}", filename))?;

        let tmp_path = self.base_dir.join(format!("{}.tmp", filename));
        fs::write(&tmp_path, json.as_bytes())
            .with_context(|| format!("Failed to write {}", tmp_path.display()))?;
        fs::rename(&tmp_path, &final_path)
            .with_context(|| format!("Failed to rename {} to {}", tmp_path.display(), final_path.display()))?;

        info!("Saved {} (merged)", filename);
        Ok(())
    }

    fn save<T: serde::Serialize>(&self, value: &T, filename: &str) -> Result<()> {
        fs::create_dir_all(&self.base_dir)
            .with_context(|| format!("Failed to create directory {:?}", self.base_dir))?;

        let json = serde_json::to_string_pretty(value)
            .with_context(|| format!("Failed to serialize {}", filename))?;

        let final_path = self.base_dir.join(filename);
        let tmp_path = self.base_dir.join(format!("{}.tmp", filename));

        // Atomic write: write to .tmp, then rename
        fs::write(&tmp_path, json.as_bytes())
            .with_context(|| format!("Failed to write {}", tmp_path.display()))?;

        fs::rename(&tmp_path, &final_path)
            .with_context(|| format!("Failed to rename {} to {}", tmp_path.display(), final_path.display()))?;

        info!("Saved {}", filename);
        Ok(())
    }

    // =========================================================================
    // Convenience
    // =========================================================================

    pub fn config_exists(&self) -> bool {
        self.base_dir.join("config.json").exists()
    }

    pub fn providers_exist(&self) -> bool {
        self.base_dir.join("providers.json").exists()
    }

    pub fn llms_exist(&self) -> bool {
        self.base_dir.join("llms.json").exists()
    }

    pub fn tenex_directory_exists(&self) -> bool {
        self.base_dir.is_dir()
    }

    pub fn needs_onboarding(&self) -> bool {
        !self.config_exists()
    }

    // =========================================================================
    // Migration
    // =========================================================================

    /// Migrate launcher-specific fields from config.json → launcher.json.
    /// Only runs if launcher.json doesn't exist yet and config.json has the fields.
    pub fn migrate_launcher_config(&self) {
        let launcher_path = self.base_dir.join("launcher.json");
        if launcher_path.exists() {
            return;
        }

        let config_path = self.base_dir.join("config.json");
        if !config_path.exists() {
            return;
        }

        let contents = match fs::read_to_string(&config_path) {
            Ok(c) => c,
            Err(_) => return,
        };

        let mut raw: serde_json::Value = match serde_json::from_str(&contents) {
            Ok(v) => v,
            Err(_) => return,
        };

        let obj = match raw.as_object_mut() {
            Some(o) => o,
            None => return,
        };

        let has_launcher_fields = obj.contains_key("localRelay")
            || obj.contains_key("launchAtLogin")
            || obj.contains_key("tenexPublicKey");

        if !has_launcher_fields {
            return;
        }

        // Extract fields into launcher config
        let mut launcher = serde_json::Map::new();
        if let Some(v) = obj.remove("localRelay") {
            launcher.insert("localRelay".into(), v);
        }
        if let Some(v) = obj.remove("launchAtLogin") {
            launcher.insert("launchAtLogin".into(), v);
        }
        if let Some(v) = obj.remove("tenexPublicKey") {
            launcher.insert("tenexPublicKey".into(), v);
        }

        // Write launcher.json
        if let Ok(launcher_json) = serde_json::to_string_pretty(&serde_json::Value::Object(launcher)) {
            if let Err(e) = fs::write(&launcher_path, launcher_json.as_bytes()) {
                warn!("Failed to write launcher.json during migration: {}", e);
                return;
            }
        }

        // Write updated config.json (without the migrated fields)
        if let Ok(config_json) = serde_json::to_string_pretty(&raw) {
            if let Err(e) = fs::write(&config_path, config_json.as_bytes()) {
                warn!("Failed to update config.json during migration: {}", e);
            }
        }

        info!("Migrated launcher fields from config.json to launcher.json");
    }
}

/// All config files loaded at once.
pub struct ConfigBundle {
    pub config: TenexConfig,
    pub providers: TenexProviders,
    pub llms: TenexLLMs,
    pub embed: TenexEmbedConfig,
    pub image: TenexImageConfig,
    pub launcher: LauncherConfig,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn save_and_load_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        let config = TenexConfig {
            backend_name: Some("test".into()),
            relays: Some(vec!["wss://tenex.chat".into()]),
            ..Default::default()
        };
        store.save_config(&config).unwrap();

        let loaded = store.load_config();
        assert_eq!(loaded.backend_name.as_deref(), Some("test"));
        assert_eq!(loaded.relays.as_ref().unwrap().len(), 1);
    }

    #[test]
    fn save_and_load_providers() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        let providers = TenexProviders {
            providers: {
                let mut map = HashMap::new();
                map.insert("anthropic".into(), ProviderEntry::new("sk-test"));
                map
            },
        };
        store.save_providers(&providers).unwrap();

        let loaded = store.load_providers();
        assert_eq!(loaded.providers["anthropic"].primary_key(), Some("sk-test"));
    }

    #[test]
    fn merge_on_save_preserves_unknown_keys() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        // Write config.json with unknown keys the backend might add
        let raw_json = r#"{
            "backendName": "test",
            "apns": {"endpoint": "https://apns.example.com", "key": "xxx"},
            "nip46": {"enabled": true}
        }"#;
        fs::write(dir.path().join("config.json"), raw_json).unwrap();

        // Save via ConfigStore (only knows about backendName)
        let config = TenexConfig {
            backend_name: Some("updated".into()),
            ..Default::default()
        };
        store.save_config(&config).unwrap();

        // Read back raw JSON and verify unknown keys survived
        let saved = fs::read_to_string(dir.path().join("config.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&saved).unwrap();
        assert_eq!(parsed["backendName"], "updated");
        assert!(parsed["apns"].is_object(), "apns key should survive merge");
        assert!(parsed["nip46"].is_object(), "nip46 key should survive merge");
    }

    #[test]
    fn migration_moves_launcher_fields() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        // Write old-style config.json with launcher fields
        let raw_json = r#"{
            "backendName": "test",
            "relays": ["wss://tenex.chat"],
            "localRelay": {"enabled": true, "port": 7777},
            "launchAtLogin": true,
            "tenexPublicKey": "abc123",
            "apns": {"key": "preserved"}
        }"#;
        fs::write(dir.path().join("config.json"), raw_json).unwrap();

        // Run migration
        store.migrate_launcher_config();

        // Verify launcher.json was created with extracted fields
        let launcher = store.load_launcher();
        assert_eq!(launcher.launch_at_login, Some(true));
        assert_eq!(launcher.local_relay.as_ref().unwrap().port, Some(7777));
        assert_eq!(launcher.tenex_public_key.as_deref(), Some("abc123"));

        // Verify config.json no longer has launcher fields but keeps others
        let config_raw = fs::read_to_string(dir.path().join("config.json")).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&config_raw).unwrap();
        assert_eq!(parsed["backendName"], "test");
        assert!(parsed["apns"].is_object(), "unknown keys preserved");
        assert!(parsed.get("localRelay").is_none(), "localRelay should be removed");
        assert!(parsed.get("launchAtLogin").is_none(), "launchAtLogin should be removed");
        assert!(parsed.get("tenexPublicKey").is_none(), "tenexPublicKey should be removed");
    }

    #[test]
    fn migration_skips_when_launcher_exists() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        // Write old config with launcher fields
        let config_json = r#"{"launchAtLogin": true, "backendName": "test"}"#;
        fs::write(dir.path().join("config.json"), config_json).unwrap();

        // Pre-create launcher.json
        let launcher_json = r#"{"launchAtLogin": false}"#;
        fs::write(dir.path().join("launcher.json"), launcher_json).unwrap();

        // Migration should be skipped
        store.migrate_launcher_config();

        // Existing launcher.json should be unchanged
        let launcher = store.load_launcher();
        assert_eq!(launcher.launch_at_login, Some(false));
    }

    #[test]
    fn needs_onboarding_without_config() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());
        assert!(store.needs_onboarding());

        store
            .save_config(&TenexConfig::default())
            .unwrap();
        assert!(!store.needs_onboarding());
    }

    #[test]
    fn atomic_write_no_partial() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        let config = TenexConfig {
            backend_name: Some("first".into()),
            ..Default::default()
        };
        store.save_config(&config).unwrap();

        // Overwrite — no .tmp file should remain
        let config2 = TenexConfig {
            backend_name: Some("second".into()),
            ..Default::default()
        };
        store.save_config(&config2).unwrap();

        assert!(!dir.path().join("config.json.tmp").exists());
        let loaded = store.load_config();
        assert_eq!(loaded.backend_name.as_deref(), Some("second"));
    }

    #[test]
    fn load_missing_file_returns_default() {
        let dir = tempfile::tempdir().unwrap();
        let store = ConfigStore::with_base_dir(dir.path().to_path_buf());

        let config = store.load_config();
        assert!(config.backend_name.is_none());

        let providers = store.load_providers();
        assert!(providers.providers.is_empty());
    }
}
