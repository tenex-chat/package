use std::path::PathBuf;

use serde::Deserialize;

/// A credential extracted from OpenClaw.
#[derive(Debug, Clone)]
pub struct OpenClawCredential {
    pub provider: String,
    pub api_key: String,
}

/// Detection result for OpenClaw installation.
#[derive(Debug, Clone)]
pub struct OpenClawDetected {
    pub state_dir: PathBuf,
    pub credentials: Vec<OpenClawCredential>,
    pub primary_model: Option<String>,
}

const CONFIG_NAMES: &[&str] = &[
    "openclaw.json",
    "clawdbot.json",
    "moldbot.json",
    "moltbot.json",
];

const STATE_DIR_NAMES: &[&str] = &[".openclaw", ".clawdbot", ".moldbot", ".moltbot"];

/// Detect OpenClaw installation and extract credentials.
pub fn detect() -> Option<OpenClawDetected> {
    let state_dir = find_state_dir()?;
    Some(OpenClawDetected {
        credentials: read_credentials(&state_dir),
        primary_model: read_primary_model(&state_dir),
        state_dir,
    })
}

fn find_state_dir() -> Option<PathBuf> {
    // Check environment variable first
    if let Ok(env_path) = std::env::var("OPENCLAW_STATE_DIR") {
        let path = PathBuf::from(env_path);
        if has_config(&path) {
            return Some(path);
        }
    }

    // Check home directory
    let home = dirs::home_dir()?;
    for name in STATE_DIR_NAMES {
        let candidate = home.join(name);
        if has_config(&candidate) {
            return Some(candidate);
        }
    }

    None
}

fn has_config(dir: &PathBuf) -> bool {
    CONFIG_NAMES.iter().any(|name| dir.join(name).exists())
}

fn read_credentials(state_dir: &PathBuf) -> Vec<OpenClawCredential> {
    let path = state_dir.join("agents/main/agent/auth-profiles.json");
    let contents = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };

    let file: AuthProfilesFile = match serde_json::from_str(&contents) {
        Ok(f) => f,
        Err(_) => return vec![],
    };

    let mut credentials = Vec::new();
    let mut sorted_profiles: Vec<_> = file.profiles.into_iter().collect();
    sorted_profiles.sort_by(|a, b| {
        let a_default = a.0.ends_with(":default");
        let b_default = b.0.ends_with(":default");
        b_default.cmp(&a_default).then(a.0.cmp(&b.0))
    });

    for (_, profile) in sorted_profiles {
        let key = match profile.profile_type.as_str() {
            "token" => profile.token,
            "api_key" => profile.key,
            "oauth" => profile.access,
            _ => None,
        };

        if let (Some(provider), Some(api_key)) = (profile.provider, key) {
            if !api_key.is_empty()
                && !credentials.iter().any(|c: &OpenClawCredential| c.provider == provider)
            {
                credentials.push(OpenClawCredential { provider, api_key });
            }
        }
    }

    credentials
}

fn read_primary_model(state_dir: &PathBuf) -> Option<String> {
    for name in CONFIG_NAMES {
        let path = state_dir.join(name);
        let contents = std::fs::read_to_string(&path).ok()?;
        let config: OpenClawConfig = serde_json::from_str(&contents).ok()?;
        if let Some(model) = config
            .agents
            .and_then(|a| a.defaults)
            .and_then(|d| d.model)
            .and_then(|m| m.primary)
        {
            return Some(convert_model_format(&model));
        }
    }
    None
}

/// Convert "provider/model" to "provider:model" format.
fn convert_model_format(model: &str) -> String {
    model.replacen('/', ":", 1)
}

// =============================================================================
// Decodable helpers
// =============================================================================

#[derive(Deserialize)]
struct AuthProfilesFile {
    profiles: std::collections::HashMap<String, AuthProfile>,
}

#[derive(Deserialize)]
struct AuthProfile {
    #[serde(rename = "type")]
    profile_type: String,
    provider: Option<String>,
    token: Option<String>,
    key: Option<String>,
    access: Option<String>,
}

#[derive(Deserialize)]
struct OpenClawConfig {
    agents: Option<AgentsSection>,
}

#[derive(Deserialize)]
struct AgentsSection {
    defaults: Option<DefaultsSection>,
}

#[derive(Deserialize)]
struct DefaultsSection {
    model: Option<ModelSection>,
}

#[derive(Deserialize)]
struct ModelSection {
    primary: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn convert_model_format_works() {
        assert_eq!(
            convert_model_format("anthropic/claude-sonnet-4-6"),
            "anthropic:claude-sonnet-4-6"
        );
        assert_eq!(convert_model_format("plain-model"), "plain-model");
    }
}
