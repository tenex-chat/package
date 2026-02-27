use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashMap;

// =============================================================================
// config.json
// =============================================================================

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TenexConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub whitelisted_pubkeys: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tenex_private_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub backend_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub projects_base: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relays: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blossom_server_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub logging: Option<LoggingConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub telemetry: Option<TelemetryConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub global_system_prompt: Option<GlobalSystemPrompt>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summarization: Option<SummarizationConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compression: Option<CompressionConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub escalation: Option<EscalationConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub intervention: Option<InterventionConfig>,
}

// =============================================================================
// launcher.json
// =============================================================================

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LauncherConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub launch_at_login: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_relay: Option<LocalRelayConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tenex_public_key: Option<String>,
    /// Nostr event IDs of agents selected during onboarding, to be hired when daemon starts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_agent_ids: Option<Vec<String>>,
    /// Nostr event IDs of nudges selected during onboarding, to be activated when daemon starts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_nudge_ids: Option<Vec<String>>,
    /// Nostr event IDs of skills selected during onboarding, to be activated when daemon starts.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pending_skill_ids: Option<Vec<String>>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalRelayConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auto_start: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sync_relays: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ngrok_enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ngrok_url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoggingConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub log_file: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub service_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GlobalSystemPrompt {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SummarizationConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inactivity_timeout: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompressionConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_threshold: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_budget: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sliding_window_size: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EscalationConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InterventionConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub review_timeout: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skip_if_active_within: Option<u64>,
}

// =============================================================================
// embed.json
// =============================================================================

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TenexEmbedConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

// =============================================================================
// image.json
// =============================================================================

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TenexImageConfig {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_aspect_ratio: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_image_size: Option<String>,
}

// =============================================================================
// providers.json
// =============================================================================

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TenexProviders {
    pub providers: HashMap<String, ProviderEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderEntry {
    #[serde(
        rename = "apiKey",
        deserialize_with = "deserialize_string_or_array",
        serialize_with = "serialize_as_array"
    )]
    pub api_keys: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<HashMap<String, serde_json::Value>>,
}

impl ProviderEntry {
    pub fn new(api_key: impl Into<String>) -> Self {
        Self {
            api_keys: vec![api_key.into()],
            base_url: None,
            timeout: None,
            options: None,
        }
    }

    pub fn primary_key(&self) -> Option<&str> {
        self.api_keys.first().map(|s| s.as_str())
    }
}

fn deserialize_string_or_array<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: Deserializer<'de>,
{
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum StringOrArray {
        Single(String),
        Array(Vec<String>),
    }

    match StringOrArray::deserialize(deserializer)? {
        StringOrArray::Single(s) => Ok(vec![s]),
        StringOrArray::Array(v) => Ok(v),
    }
}

fn serialize_as_array<S>(keys: &Vec<String>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    keys.serialize(serializer)
}

// =============================================================================
// llms.json
// =============================================================================

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TenexLLMs {
    pub configurations: HashMap<String, LLMConfiguration>,
    #[serde(rename = "default", skip_serializing_if = "Option::is_none")]
    pub default_config: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub summarization: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub supervision: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub search: Option<String>,
    #[serde(rename = "promptCompilation", skip_serializing_if = "Option::is_none")]
    pub prompt_compilation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compression: Option<String>,
}

/// A configuration is either a standard model reference or a meta model with variants.
/// Discriminated by checking if `provider == "meta"` and `variants` is present.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum LLMConfiguration {
    Meta(MetaLLM),
    Standard(StandardLLM),
}

impl LLMConfiguration {
    pub fn provider(&self) -> &str {
        match self {
            LLMConfiguration::Standard(s) => &s.provider,
            LLMConfiguration::Meta(_) => "meta",
        }
    }

    pub fn display_model(&self) -> String {
        match self {
            LLMConfiguration::Standard(s) => s.model.clone(),
            LLMConfiguration::Meta(m) => format!("meta ({})", m.default_variant),
        }
    }

    pub fn is_meta(&self) -> bool {
        matches!(self, LLMConfiguration::Meta(_))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StandardLLM {
    pub provider: String,
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_effort: Option<String>,
}

impl StandardLLM {
    pub fn new(provider: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            provider: provider.into(),
            model: model.into(),
            temperature: None,
            max_tokens: None,
            top_p: None,
            reasoning_effort: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaLLM {
    pub provider: String,
    pub variants: HashMap<String, MetaVariant>,
    #[serde(rename = "default")]
    pub default_variant: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MetaVariant {
    pub model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tier: Option<u32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_roundtrip() {
        let config = TenexConfig {
            whitelisted_pubkeys: Some(vec!["abc123".into()]),
            backend_name: Some("test backend".into()),
            relays: Some(vec!["wss://tenex.chat".into()]),
            compression: Some(CompressionConfig {
                enabled: Some(true),
                token_threshold: Some(4000),
                token_budget: Some(2000),
                sliding_window_size: Some(10),
            }),
            ..Default::default()
        };

        let json = serde_json::to_string_pretty(&config).unwrap();
        let parsed: TenexConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.backend_name.as_deref(), Some("test backend"));
        assert!(json.contains("whitelistedPubkeys"));
        // local_relay and launch_at_login should NOT be in config anymore
        assert!(!json.contains("localRelay"));
        assert!(!json.contains("launchAtLogin"));
    }

    #[test]
    fn launcher_config_roundtrip() {
        let launcher = LauncherConfig {
            launch_at_login: Some(true),
            local_relay: Some(LocalRelayConfig {
                enabled: Some(true),
                auto_start: Some(true),
                port: Some(7777),
                sync_relays: Some(vec!["wss://tenex.chat".into()]),
                ngrok_enabled: Some(false),
                ngrok_url: None,
            }),
            tenex_public_key: Some("abc123".into()),
            pending_agent_ids: Some(vec!["aabb00".into()]),
            pending_nudge_ids: None,
            pending_skill_ids: None,
        };

        let json = serde_json::to_string_pretty(&launcher).unwrap();
        let parsed: LauncherConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.launch_at_login, Some(true));
        assert_eq!(parsed.local_relay.as_ref().unwrap().port, Some(7777));
        assert_eq!(parsed.tenex_public_key.as_deref(), Some("abc123"));
        assert_eq!(parsed.pending_agent_ids.as_ref().unwrap(), &["aabb00"]);
        assert!(parsed.pending_nudge_ids.is_none());
        assert!(json.contains("pendingAgentIds"));
        assert!(json.contains("localRelay"));
        assert!(json.contains("autoStart"));
        assert!(json.contains("launchAtLogin"));
    }

    #[test]
    fn providers_roundtrip() {
        let providers = TenexProviders {
            providers: {
                let mut map = HashMap::new();
                map.insert(
                    "anthropic".into(),
                    ProviderEntry::new("sk-ant-api03-test"),
                );
                map.insert(
                    "ollama".into(),
                    ProviderEntry {
                        api_keys: vec!["http://localhost:11434".into()],
                        base_url: None,
                        timeout: Some(30),
                        options: None,
                    },
                );
                map
            },
        };

        let json = serde_json::to_string_pretty(&providers).unwrap();
        let parsed: TenexProviders = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.providers.len(), 2);
        assert_eq!(
            parsed.providers["anthropic"].primary_key(),
            Some("sk-ant-api03-test")
        );
        assert!(json.contains("apiKey"));
    }

    #[test]
    fn provider_entry_deserialize_single_string() {
        // Old format: "apiKey": "sk-..."
        let json = r#"{"apiKey": "sk-test-123"}"#;
        let entry: ProviderEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.api_keys, vec!["sk-test-123"]);
        assert_eq!(entry.primary_key(), Some("sk-test-123"));
    }

    #[test]
    fn provider_entry_deserialize_array() {
        // New format: "apiKey": ["sk-...", "sk-..."]
        let json = r#"{"apiKey": ["sk-first", "sk-second"]}"#;
        let entry: ProviderEntry = serde_json::from_str(json).unwrap();
        assert_eq!(entry.api_keys, vec!["sk-first", "sk-second"]);
        assert_eq!(entry.primary_key(), Some("sk-first"));
    }

    #[test]
    fn provider_entry_serializes_as_array() {
        let entry = ProviderEntry::new("sk-test");
        let json = serde_json::to_string(&entry).unwrap();
        // Should serialize as array: "apiKey":["sk-test"]
        assert!(json.contains(r#""apiKey":["sk-test"]"#));
    }

    #[test]
    fn llms_standard_roundtrip() {
        let llms = TenexLLMs {
            configurations: {
                let mut map = HashMap::new();
                map.insert(
                    "Sonnet".into(),
                    LLMConfiguration::Standard(StandardLLM::new("anthropic", "claude-sonnet-4-6")),
                );
                map
            },
            default_config: Some("Sonnet".into()),
            ..Default::default()
        };

        let json = serde_json::to_string_pretty(&llms).unwrap();
        let parsed: TenexLLMs = serde_json::from_str(&json).unwrap();

        assert!(json.contains("\"default\""));
        assert!(!json.contains("defaultConfig"));

        match &parsed.configurations["Sonnet"] {
            LLMConfiguration::Standard(s) => {
                assert_eq!(s.provider, "anthropic");
                assert_eq!(s.model, "claude-sonnet-4-6");
            }
            _ => panic!("Expected Standard"),
        }
    }

    #[test]
    fn llms_meta_roundtrip() {
        let llms = TenexLLMs {
            configurations: {
                let mut map = HashMap::new();
                map.insert(
                    "Auto".into(),
                    LLMConfiguration::Meta(MetaLLM {
                        provider: "meta".into(),
                        variants: {
                            let mut v = HashMap::new();
                            v.insert(
                                "fast".into(),
                                MetaVariant {
                                    model: "claude-haiku-4-5-20251001".into(),
                                    keywords: None,
                                    description: Some("Fast tasks".into()),
                                    system_prompt: None,
                                    tier: Some(1),
                                },
                            );
                            v.insert(
                                "balanced".into(),
                                MetaVariant {
                                    model: "claude-sonnet-4-6".into(),
                                    keywords: None,
                                    description: Some("Balanced".into()),
                                    system_prompt: None,
                                    tier: Some(2),
                                },
                            );
                            v
                        },
                        default_variant: "balanced".into(),
                    }),
                );
                map
            },
            default_config: Some("Auto".into()),
            ..Default::default()
        };

        let json = serde_json::to_string_pretty(&llms).unwrap();
        let parsed: TenexLLMs = serde_json::from_str(&json).unwrap();

        match &parsed.configurations["Auto"] {
            LLMConfiguration::Meta(m) => {
                assert_eq!(m.provider, "meta");
                assert_eq!(m.default_variant, "balanced");
                assert_eq!(m.variants.len(), 2);
                assert_eq!(m.variants["fast"].tier, Some(1));
            }
            _ => panic!("Expected Meta"),
        }
    }

    #[test]
    fn embed_image_roundtrip() {
        let embed = TenexEmbedConfig {
            provider: Some("openai".into()),
            model: Some("text-embedding-3-small".into()),
        };
        let json = serde_json::to_string_pretty(&embed).unwrap();
        let parsed: TenexEmbedConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.provider.as_deref(), Some("openai"));

        let image = TenexImageConfig {
            provider: Some("openai".into()),
            model: Some("dall-e-3".into()),
            default_aspect_ratio: Some("16:9".into()),
            default_image_size: Some("1024x1024".into()),
        };
        let json = serde_json::to_string_pretty(&image).unwrap();
        assert!(json.contains("defaultAspectRatio"));
        let parsed: TenexImageConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.default_image_size.as_deref(), Some("1024x1024"));
    }
}
