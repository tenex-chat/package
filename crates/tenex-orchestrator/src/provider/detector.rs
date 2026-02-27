use std::collections::HashMap;
use std::process::Stdio;

use crate::config::{ProviderEntry, TenexProviders};

/// Ordered list of all known providers.
pub const PROVIDER_LIST_ORDER: &[&str] = &[
    "openrouter",
    "anthropic",
    "openai",
    "ollama",
    "claude-code",
    "gemini-cli",
    "codex-app-server",
];

/// Maps provider ID to the shell command needed.
pub fn local_command_providers() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("claude-code", "claude"),
        ("codex-app-server", "codex"),
        ("gemini-cli", "gemini"),
    ])
}

/// Human-readable display names for providers.
pub fn provider_display_names() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("openrouter", "OpenRouter"),
        ("anthropic", "Anthropic"),
        ("openai", "OpenAI"),
        ("ollama", "Ollama"),
        ("claude-code", "Claude Code"),
        ("gemini-cli", "Gemini CLI"),
        ("codex-app-server", "Codex App Server"),
    ])
}

/// Maps provider ID to the environment variable containing an API key.
pub fn api_key_env_vars() -> HashMap<&'static str, &'static str> {
    HashMap::from([
        ("anthropic", "ANTHROPIC_API_KEY"),
        ("openai", "OPENAI_API_KEY"),
        ("openrouter", "OPENROUTER_API_KEY"),
    ])
}

/// Check if an API key is an OAuth setup token (Claude Max subscription).
pub fn is_oauth_setup_token(key: &str) -> bool {
    key.starts_with("sk-ant-oat")
}

/// Result of provider availability detection.
pub struct DetectionResult {
    /// Provider ID → whether available on this system.
    pub availability: HashMap<String, bool>,
}

/// Detect which providers are available on the local system.
pub async fn detect_providers() -> DetectionResult {
    let mut availability = HashMap::new();

    // Check local command providers
    for (provider, command) in local_command_providers() {
        availability.insert(provider.to_string(), command_exists(command));
    }

    // Check Ollama
    if command_exists("ollama") {
        availability.insert(
            "ollama".to_string(),
            ollama_reachable("http://localhost:11434").await,
        );
    } else {
        availability.insert("ollama".to_string(), false);
    }

    // API key providers are always "available" for manual entry
    for provider in ["openrouter", "anthropic", "openai"] {
        availability.insert(provider.to_string(), true);
    }

    DetectionResult { availability }
}

/// Auto-connect providers that are detected on the system.
/// Returns true if any providers were added.
pub async fn auto_connect_detected(providers: &mut TenexProviders) -> bool {
    let detection = detect_providers().await;
    let mut changed = false;

    // Auto-connect local command providers
    for (provider, _) in local_command_providers() {
        if detection.availability.get(provider) == Some(&true)
            && !providers.providers.contains_key(provider)
        {
            providers
                .providers
                .insert(provider.to_string(), ProviderEntry::new("none"));
            changed = true;
        }
    }

    // Auto-connect Ollama if available
    if detection.availability.get("ollama") == Some(&true)
        && !providers.providers.contains_key("ollama")
    {
        providers.providers.insert(
            "ollama".to_string(),
            ProviderEntry::new("http://localhost:11434"),
        );
        changed = true;
    }

    // Auto-connect from environment variables
    for (provider, env_var) in api_key_env_vars() {
        if !providers.providers.contains_key(provider) {
            if let Ok(api_key) = std::env::var(env_var) {
                if !api_key.is_empty() {
                    providers
                        .providers
                        .insert(provider.to_string(), ProviderEntry::new(api_key));
                    changed = true;
                }
            }
        }
    }

    // Auto-connect Anthropic from ANTHROPIC_AUTH_TOKEN (OAuth setup-token)
    if !providers.providers.contains_key("anthropic") {
        if let Ok(auth_token) = std::env::var("ANTHROPIC_AUTH_TOKEN") {
            if !auth_token.is_empty() {
                providers
                    .providers
                    .insert("anthropic".to_string(), ProviderEntry::new(auth_token));
                changed = true;
            }
        }
    }

    changed
}

/// Check if a command exists on the system using `command -v`.
pub fn command_exists(command: &str) -> bool {
    let cmd_str = format!("command -v {} >/dev/null 2>&1", command);
    let shell = if cfg!(target_os = "macos") {
        "/bin/zsh"
    } else {
        "/bin/sh"
    };
    let flag = if cfg!(target_os = "macos") {
        "-lc"
    } else {
        "-c"
    };

    std::process::Command::new(shell)
        .args([flag, &cmd_str])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Check if Ollama is reachable at the given base URL.
pub async fn ollama_reachable(base_url: &str) -> bool {
    let url = format!("{}/api/tags", base_url.trim_end_matches('/'));
    reqwest::get(&url)
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// Metadata for an OpenRouter model fetched from the public API.
pub struct OpenRouterModel {
    pub id: String,
    pub name: String,
    pub context_length: u64,
    /// Cost per 1 million input tokens in USD.
    pub prompt_price_per_million: f64,
    /// Cost per 1 million output tokens in USD.
    pub completion_price_per_million: f64,
}

impl OpenRouterModel {
    pub fn price_display(&self) -> String {
        if self.prompt_price_per_million == 0.0 && self.completion_price_per_million == 0.0 {
            return "free".to_string();
        }
        format!(
            "${:.2}/${:.2}/1M",
            self.prompt_price_per_million, self.completion_price_per_million
        )
    }

    pub fn context_display(&self) -> String {
        if self.context_length >= 1_000_000 {
            format!("{}M", self.context_length / 1_000_000)
        } else if self.context_length >= 1_000 {
            format!("{}K", self.context_length / 1_000)
        } else {
            format!("{}", self.context_length)
        }
    }
}

/// Fetch all available models from the OpenRouter public API.
pub async fn fetch_openrouter_models(api_key: &str) -> Vec<OpenRouterModel> {
    let client = reqwest::Client::new();
    let mut req = client
        .get("https://openrouter.ai/api/v1/models")
        .header("Accept", "application/json");
    if !api_key.is_empty() {
        req = req.header("Authorization", format!("Bearer {}", api_key));
    }
    let Ok(resp) = req.send().await else {
        return vec![];
    };
    let Ok(json) = resp.json::<serde_json::Value>().await else {
        return vec![];
    };
    json["data"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let id = m["id"].as_str()?.to_string();
                    let name = m["name"].as_str().unwrap_or(&id).to_string();
                    let context_length = m["context_length"].as_u64().unwrap_or(0);
                    let prompt_price = m["pricing"]["prompt"]
                        .as_str()
                        .and_then(|s| s.parse::<f64>().ok())
                        .unwrap_or(0.0)
                        * 1_000_000.0;
                    let completion_price = m["pricing"]["completion"]
                        .as_str()
                        .and_then(|s| s.parse::<f64>().ok())
                        .unwrap_or(0.0)
                        * 1_000_000.0;
                    Some(OpenRouterModel {
                        id,
                        name,
                        context_length,
                        prompt_price_per_million: prompt_price,
                        completion_price_per_million: completion_price,
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Metadata for a model available from the local Codex app server.
pub struct CodexModel {
    pub id: String,
    pub display_name: String,
    pub description: String,
    pub is_default: bool,
}

/// Fetch available models from the local Codex app server via JSON-RPC over stdio.
/// Returns empty vec if codex is not installed or communication fails.
pub async fn fetch_codex_models() -> Vec<CodexModel> {
    fetch_codex_models_inner().await.unwrap_or_default()
}

async fn fetch_codex_models_inner() -> Option<Vec<CodexModel>> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::process::Command as TokioCommand;
    use tokio::time::{Duration, timeout};

    let mut child = TokioCommand::new("codex")
        .args(["app-server"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    let mut stdin = child.stdin.take()?;
    let mut lines = BufReader::new(child.stdout.take()?).lines();

    // Send initialize request
    let init_req = serde_json::json!({
        "id": "init-1",
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "tenex-launcher",
                "title": "Tenex Launcher",
                "version": "1.0.0"
            }
        }
    });
    let init_line = format!("{}\n", serde_json::to_string(&init_req).ok()?);
    stdin.write_all(init_line.as_bytes()).await.ok()?;

    // Wait for initialization response
    timeout(Duration::from_secs(5), lines.next_line())
        .await
        .ok()? // timeout
        .ok()? // io::Result
        ?; // Option<String>

    // Send initialized notification
    let notif = serde_json::json!({"method": "initialized", "params": {}});
    let notif_line = format!("{}\n", serde_json::to_string(&notif).ok()?);
    stdin.write_all(notif_line.as_bytes()).await.ok()?;

    // Request model list
    let list_req = serde_json::json!({"id": "models-1", "method": "model/list", "params": {}});
    let list_line = format!("{}\n", serde_json::to_string(&list_req).ok()?);
    stdin.write_all(list_line.as_bytes()).await.ok()?;

    // Read responses until we get the model list or timeout
    let mut models: Vec<CodexModel> = vec![];
    let read_result = timeout(Duration::from_secs(10), async {
        loop {
            match lines.next_line().await {
                Ok(Some(line)) => {
                    let Ok(msg) = serde_json::from_str::<serde_json::Value>(&line) else {
                        continue;
                    };
                    if msg.get("id").and_then(|v| v.as_str()) != Some("models-1") {
                        continue;
                    }
                    if let Some(arr) = msg["result"]["data"].as_array() {
                        for m in arr {
                            let id = m["id"].as_str().unwrap_or("").to_string();
                            if id.is_empty() {
                                continue;
                            }
                            models.push(CodexModel {
                                id: id.clone(),
                                display_name: m["displayName"].as_str().unwrap_or(&id).to_string(),
                                description: m["description"].as_str().unwrap_or("").to_string(),
                                is_default: m["isDefault"].as_bool().unwrap_or(false),
                            });
                        }
                    }
                    return;
                }
                _ => return,
            }
        }
    })
    .await;

    child.kill().await.ok();

    if read_result.is_err() {
        return None;
    }

    Some(models)
}

/// Metadata for a locally available Ollama model.
pub struct OllamaModel {
    pub name: String,
    pub parameter_size: Option<String>,
    pub quantization: Option<String>,
    pub size_bytes: Option<u64>,
}

impl OllamaModel {
    /// Human-readable disk size: "1.9 GB", "423 MB", etc.
    pub fn size_display(&self) -> String {
        match self.size_bytes {
            None => String::new(),
            Some(b) if b >= 1_073_741_824 => {
                format!("{:.1} GB", b as f64 / 1_073_741_824.0)
            }
            Some(b) => format!("{} MB", b / 1_048_576),
        }
    }
}

/// Fetch metadata for all locally available Ollama models.
pub async fn fetch_ollama_models(base_url: &str) -> Vec<OllamaModel> {
    let url = format!("{}/api/tags", base_url.trim_end_matches('/'));
    let Ok(resp) = reqwest::get(&url).await else {
        return vec![];
    };
    let Ok(json) = resp.json::<serde_json::Value>().await else {
        return vec![];
    };
    json["models"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let name = m["name"].as_str()?.to_string();
                    let details = &m["details"];
                    Some(OllamaModel {
                        name,
                        parameter_size: details["parameter_size"]
                            .as_str()
                            .map(str::to_string),
                        quantization: details["quantization_level"]
                            .as_str()
                            .map(str::to_string),
                        size_bytes: m["size"].as_u64(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Get a subtitle string for a provider's current state.
pub fn provider_subtitle(provider: &str, connected: bool, api_key: Option<&str>, key_count: usize) -> String {
    if connected {
        let suffix = if key_count > 1 {
            format!(" ({} keys)", key_count)
        } else {
            String::new()
        };

        match provider {
            "anthropic" => {
                if let Some(key) = api_key {
                    if is_oauth_setup_token(key) {
                        return format!("Connected with setup-token (Max subscription){}", suffix);
                    }
                }
                format!("Connected with API key{}", suffix)
            }
            "openrouter" | "openai" => format!("Connected with API key{}", suffix),
            "ollama" => format!(
                "Connected local endpoint ({})",
                api_key.unwrap_or("http://localhost:11434")
            ),
            "claude-code" => "Connected from local `claude` command".into(),
            "codex-app-server" => "Connected from local `codex` command".into(),
            "gemini-cli" => "Connected from local `gemini` command".into(),
            _ => "Connected".into(),
        }
    } else {
        match provider {
            "openrouter" => "Use API key to access hosted models".into(),
            "openai" => "Use OpenAI API key".into(),
            "anthropic" => "API key or setup-token from `claude setup-token`".into(),
            "ollama" => "Connect to your local Ollama endpoint".into(),
            "claude-code" => "Requires local `claude` command".into(),
            "codex-app-server" => "Requires local `codex` command".into(),
            "gemini-cli" => "Requires local `gemini` command".into(),
            _ => "Not configured".into(),
        }
    }
}

/// Whether a provider requires an API key (vs being auto-detected).
pub fn requires_api_key(provider: &str) -> bool {
    matches!(provider, "openrouter" | "openai" | "anthropic" | "ollama")
}
