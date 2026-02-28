use std::collections::HashMap;

use crate::config::*;

/// Steps in the onboarding wizard.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnboardingStep {
    Identity,
    OpenClawImport,
    Relay,
    Providers,
    LLMs,
    ProjectAndAgents,
    NudgesSkills,
    MobilePairing,
    Done,
}

/// Relay connection mode chosen during onboarding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayMode {
    Remote,
    Local,
}

/// State machine for the onboarding flow.
pub struct OnboardingStateMachine {
    pub step: OnboardingStep,
    pub has_openclaw: bool,
}

impl OnboardingStateMachine {
    pub fn new(has_openclaw: bool) -> Self {
        Self {
            step: OnboardingStep::Identity,
            has_openclaw,
        }
    }

    /// Advance to the next step.
    pub fn next(&mut self) {
        self.step = match self.step {
            OnboardingStep::Identity => {
                if self.has_openclaw {
                    OnboardingStep::OpenClawImport
                } else {
                    OnboardingStep::Relay
                }
            }
            OnboardingStep::OpenClawImport => OnboardingStep::Relay,
            OnboardingStep::Relay => OnboardingStep::Providers,
            OnboardingStep::Providers => OnboardingStep::LLMs,
            OnboardingStep::LLMs => OnboardingStep::ProjectAndAgents,
            OnboardingStep::ProjectAndAgents => OnboardingStep::NudgesSkills,
            OnboardingStep::NudgesSkills => OnboardingStep::MobilePairing,
            OnboardingStep::MobilePairing => OnboardingStep::Done,
            OnboardingStep::Done => OnboardingStep::Done, // terminal
        };
    }

    /// Go back to the previous step.
    pub fn back(&mut self) {
        self.step = match self.step {
            OnboardingStep::Identity => OnboardingStep::Identity, // can't go back further
            OnboardingStep::OpenClawImport => OnboardingStep::Identity,
            OnboardingStep::Relay => {
                if self.has_openclaw {
                    OnboardingStep::OpenClawImport
                } else {
                    OnboardingStep::Identity
                }
            }
            OnboardingStep::Providers => OnboardingStep::Relay,
            OnboardingStep::LLMs => OnboardingStep::Providers,
            OnboardingStep::ProjectAndAgents => OnboardingStep::LLMs,
            OnboardingStep::NudgesSkills => OnboardingStep::ProjectAndAgents,
            OnboardingStep::MobilePairing => OnboardingStep::NudgesSkills,
            OnboardingStep::Done => OnboardingStep::MobilePairing,
        };
    }

    /// Whether onboarding is complete.
    pub fn is_complete(&self) -> bool {
        self.step == OnboardingStep::Done
    }
}

/// Check if onboarding is needed based on config state.
pub fn needs_onboarding(store: &ConfigStore) -> bool {
    store.needs_onboarding()
}

/// Seed default LLM configurations based on connected providers.
/// Returns true if any configurations were added.
pub fn seed_default_llms(llms: &mut TenexLLMs, providers: &TenexProviders) -> bool {
    let connected: std::collections::HashSet<&String> = providers.providers.keys().collect();

    // Skip seeding if Standard configs for connected providers already exist
    let has_standard_for_connected = llms.configurations.values().any(|cfg| {
        matches!(cfg, LLMConfiguration::Standard(s) if connected.contains(&s.provider))
    });
    if has_standard_for_connected {
        return false;
    }

    // Prefer claude-code (local CLI), fall back to anthropic API key
    let anthropic_provider = if connected.contains(&"claude-code".to_string()) {
        Some("claude-code")
    } else if connected.contains(&"anthropic".to_string()) {
        Some("anthropic")
    } else {
        None
    };

    if let Some(provider) = anthropic_provider {
        llms.configurations.insert(
            "Sonnet".into(),
            LLMConfiguration::Standard(StandardLLM::new(provider, "claude-sonnet-4-6")),
        );
        llms.configurations.insert(
            "Opus".into(),
            LLMConfiguration::Standard(StandardLLM::new(provider, "claude-opus-4-6")),
        );
        llms.configurations.insert(
            "Auto".into(),
            LLMConfiguration::Meta(MetaLLM {
                provider: "meta".into(),
                variants: HashMap::from([
                    (
                        "fast".into(),
                        MetaVariant {
                            model: "claude-haiku-4-5-20251001".into(),
                            keywords: None,
                            description: Some("Fast, lightweight tasks".into()),
                            system_prompt: None,
                            tier: Some(1),
                        },
                    ),
                    (
                        "balanced".into(),
                        MetaVariant {
                            model: "claude-sonnet-4-6".into(),
                            keywords: None,
                            description: Some("Good balance of speed and capability".into()),
                            system_prompt: None,
                            tier: Some(2),
                        },
                    ),
                    (
                        "powerful".into(),
                        MetaVariant {
                            model: "claude-opus-4-6".into(),
                            keywords: None,
                            description: Some("Most capable, complex reasoning".into()),
                            system_prompt: None,
                            tier: Some(3),
                        },
                    ),
                ]),
                default_variant: "balanced".into(),
            }),
        );
        llms.default_config = Some("Auto".into());
    }

    if connected.contains(&"openai".to_string()) {
        llms.configurations.insert(
            "GPT-4o".into(),
            LLMConfiguration::Standard(StandardLLM::new("openai", "gpt-4o")),
        );
        if anthropic_provider.is_none() {
            llms.default_config = Some("GPT-4o".into());
        }
    }

    !llms.configurations.is_empty()
}

/// Build relay config during onboarding.
/// Writes relay URLs to config and local relay settings to launcher.
pub fn build_relay_config(
    config: &mut TenexConfig,
    launcher: &mut LauncherConfig,
    mode: RelayMode,
    remote_url: &str,
    ngrok_enabled: bool,
) {
    match mode {
        RelayMode::Remote => {
            config.relays = Some(vec![remote_url.to_string()]);
            launcher.local_relay = Some(LocalRelayConfig {
                enabled: Some(false),
                ..Default::default()
            });
        }
        RelayMode::Local => {
            config.relays = Some(vec!["ws://localhost:7777".into()]);
            launcher.local_relay = Some(LocalRelayConfig {
                enabled: Some(true),
                auto_start: Some(true),
                port: Some(7777),
                sync_relays: Some(vec!["wss://tenex.chat".into()]),
                ngrok_enabled: Some(ngrok_enabled),
                ngrok_url: None,
                nip42_auth: Some(true),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn step_progression_no_openclaw() {
        let mut sm = OnboardingStateMachine::new(false);
        assert_eq!(sm.step, OnboardingStep::Identity);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::Relay);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::Providers);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::LLMs);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::ProjectAndAgents);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::NudgesSkills);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::MobilePairing);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::Done);
        assert!(sm.is_complete());
    }

    #[test]
    fn step_progression_with_openclaw() {
        let mut sm = OnboardingStateMachine::new(true);
        sm.next();
        assert_eq!(sm.step, OnboardingStep::OpenClawImport);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::Relay);
    }

    #[test]
    fn back_navigation() {
        let mut sm = OnboardingStateMachine::new(true);
        sm.next(); // → OpenClawImport
        sm.next(); // → Relay
        sm.back(); // → OpenClawImport
        assert_eq!(sm.step, OnboardingStep::OpenClawImport);

        sm.back(); // → Identity
        assert_eq!(sm.step, OnboardingStep::Identity);

        sm.back(); // stays at Identity
        assert_eq!(sm.step, OnboardingStep::Identity);
    }

    #[test]
    fn step_progression_full_flow() {
        let mut sm = OnboardingStateMachine::new(false);
        assert_eq!(sm.step, OnboardingStep::Identity);

        sm.next(); // -> Relay (skips OpenClaw)
        assert_eq!(sm.step, OnboardingStep::Relay);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::Providers);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::LLMs);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::ProjectAndAgents);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::NudgesSkills);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::MobilePairing);

        sm.next();
        assert_eq!(sm.step, OnboardingStep::Done);
        assert!(sm.is_complete());

        // Done is terminal — next() stays at Done
        sm.next();
        assert_eq!(sm.step, OnboardingStep::Done);
    }

    #[test]
    fn seed_anthropic_provider() {
        let mut llms = TenexLLMs::default();
        let providers = TenexProviders {
            providers: HashMap::from([
                ("anthropic".into(), ProviderEntry::new("sk-test")),
            ]),
        };

        assert!(seed_default_llms(&mut llms, &providers));
        assert_eq!(llms.configurations.len(), 3); // Sonnet, Opus, Auto
        assert_eq!(llms.default_config.as_deref(), Some("Auto"));

        match &llms.configurations["Sonnet"] {
            LLMConfiguration::Standard(s) => assert_eq!(s.provider, "anthropic"),
            _ => panic!("Expected Standard"),
        }
    }

    #[test]
    fn seed_prefers_claude_code() {
        let mut llms = TenexLLMs::default();
        let providers = TenexProviders {
            providers: HashMap::from([
                ("anthropic".into(), ProviderEntry::new("sk-test")),
                ("claude-code".into(), ProviderEntry::new("none")),
            ]),
        };

        seed_default_llms(&mut llms, &providers);

        match &llms.configurations["Sonnet"] {
            LLMConfiguration::Standard(s) => assert_eq!(s.provider, "claude-code"),
            _ => panic!("Expected Standard"),
        }
    }

    #[test]
    fn seed_openai_only() {
        let mut llms = TenexLLMs::default();
        let providers = TenexProviders {
            providers: HashMap::from([("openai".into(), ProviderEntry::new("sk-test"))]),
        };

        seed_default_llms(&mut llms, &providers);
        assert_eq!(llms.configurations.len(), 1);
        assert_eq!(llms.default_config.as_deref(), Some("GPT-4o"));
    }

    #[test]
    fn seed_skips_if_connected_provider_configured() {
        let mut llms = TenexLLMs {
            configurations: HashMap::from([(
                "Existing".into(),
                LLMConfiguration::Standard(StandardLLM::new("anthropic", "test-model")),
            )]),
            ..Default::default()
        };
        let providers = TenexProviders {
            providers: HashMap::from([("anthropic".into(), ProviderEntry::new("sk-test"))]),
        };

        assert!(!seed_default_llms(&mut llms, &providers));
        assert_eq!(llms.configurations.len(), 1); // unchanged
    }

    #[test]
    fn build_relay_config_remote() {
        let mut config = TenexConfig::default();
        let mut launcher = LauncherConfig::default();
        build_relay_config(&mut config, &mut launcher, RelayMode::Remote, "wss://tenex.chat", false);

        assert_eq!(config.relays.as_ref().unwrap(), &["wss://tenex.chat"]);
        assert_eq!(launcher.local_relay.as_ref().unwrap().enabled, Some(false));
    }

    #[test]
    fn build_relay_config_local() {
        let mut config = TenexConfig::default();
        let mut launcher = LauncherConfig::default();
        build_relay_config(&mut config, &mut launcher, RelayMode::Local, "", true);

        assert_eq!(config.relays.as_ref().unwrap(), &["ws://localhost:7777"]);
        let lr = launcher.local_relay.as_ref().unwrap();
        assert_eq!(lr.enabled, Some(true));
        assert_eq!(lr.port, Some(7777));
        assert_eq!(lr.ngrok_enabled, Some(true));
    }
}
