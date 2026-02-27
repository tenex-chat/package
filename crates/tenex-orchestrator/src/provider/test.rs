use anyhow::{bail, Result};

/// Make a minimal LLM API call to verify the provider configuration works.
/// Returns the model's response text on success.
pub async fn test_provider_connection(
    provider: &str,
    model: &str,
    api_key: &str,
    base_url: Option<&str>,
) -> Result<String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    match provider {
        "anthropic" => {
            let resp = client
                .post("https://api.anthropic.com/v1/messages")
                .header("x-api-key", api_key)
                .header("anthropic-version", "2023-06-01")
                .json(&serde_json::json!({
                    "model": model,
                    "max_tokens": 32,
                    "messages": [{"role": "user", "content": "Say hi in one sentence."}]
                }))
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                bail!("Anthropic API returned {}: {}", status, body);
            }

            let body: serde_json::Value = resp.json().await?;
            Ok(body["content"][0]["text"]
                .as_str()
                .unwrap_or("")
                .to_string())
        }

        "openai" => {
            let resp = client
                .post("https://api.openai.com/v1/chat/completions")
                .header("Authorization", format!("Bearer {}", api_key))
                .json(&serde_json::json!({
                    "model": model,
                    "max_tokens": 32,
                    "messages": [{"role": "user", "content": "Say hi in one sentence."}]
                }))
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                bail!("OpenAI API returned {}: {}", status, body);
            }

            let body: serde_json::Value = resp.json().await?;
            Ok(body["choices"][0]["message"]["content"]
                .as_str()
                .unwrap_or("")
                .to_string())
        }

        "openrouter" => {
            let resp = client
                .post("https://openrouter.ai/api/v1/chat/completions")
                .header("Authorization", format!("Bearer {}", api_key))
                .json(&serde_json::json!({
                    "model": model,
                    "max_tokens": 32,
                    "messages": [{"role": "user", "content": "Say hi in one sentence."}]
                }))
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                bail!("OpenRouter API returned {}: {}", status, body);
            }

            let body: serde_json::Value = resp.json().await?;
            Ok(body["choices"][0]["message"]["content"]
                .as_str()
                .unwrap_or("")
                .to_string())
        }

        "ollama" => {
            let url = format!(
                "{}/api/generate",
                base_url
                    .unwrap_or("http://localhost:11434")
                    .trim_end_matches('/')
            );
            let resp = client
                .post(&url)
                .json(&serde_json::json!({
                    "model": model,
                    "prompt": "Say hi in one sentence.",
                    "stream": false
                }))
                .send()
                .await?;

            if !resp.status().is_success() {
                let status = resp.status();
                let body = resp.text().await.unwrap_or_default();
                bail!("Ollama returned {}: {}", status, body);
            }

            let body: serde_json::Value = resp.json().await?;
            Ok(body["response"].as_str().unwrap_or("").to_string())
        }

        // CLI-based providers — just verify the command runs
        "claude-code" | "gemini-cli" | "codex-app-server" => {
            let cmd = match provider {
                "claude-code" => "claude",
                "gemini-cli" => "gemini",
                "codex-app-server" => "codex",
                _ => unreachable!(),
            };

            if super::command_exists(cmd) {
                Ok(format!("{} is available", cmd))
            } else {
                bail!("`{}` command not found", cmd)
            }
        }

        _ => bail!("Unknown provider: {}", provider),
    }
}
