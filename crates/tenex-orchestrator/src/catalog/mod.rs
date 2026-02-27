use std::collections::HashMap;

use anyhow::{bail, Result};
use serde::Deserialize;

use crate::config::ProviderEntry;

/// Fetch available model names from a provider.
pub async fn fetch_models(
    provider: &str,
    providers: &HashMap<String, ProviderEntry>,
) -> Result<Vec<String>> {
    match provider {
        "ollama" => {
            let base_url = providers
                .get("ollama")
                .and_then(|p| p.primary_key())
                .map(|k| k.trim().to_string())
                .filter(|u| !u.is_empty())
                .unwrap_or_else(|| "http://localhost:11434".into());
            fetch_ollama_models(&base_url).await
        }
        "openrouter" => {
            let api_key = providers
                .get("openrouter")
                .and_then(|p| p.primary_key())
                .map(|k| k.trim().to_string())
                .filter(|k| !k.is_empty());
            match api_key {
                Some(key) => fetch_openrouter_models(&key).await,
                None => bail!("OpenRouter API key is missing"),
            }
        }
        _ => Ok(vec![]),
    }
}

async fn fetch_ollama_models(base_url: &str) -> Result<Vec<String>> {
    let url = format!("{}/api/tags", base_url.trim_end_matches('/'));
    let resp = reqwest::get(&url).await?;

    if !resp.status().is_success() {
        bail!("Could not load Ollama models from {}", base_url);
    }

    let body: OllamaTagsResponse = resp.json().await?;
    let mut models: Vec<String> = body
        .models
        .into_iter()
        .map(|m| m.name)
        .filter(|n| !n.is_empty())
        .collect();
    models.sort();
    Ok(models)
}

async fn fetch_openrouter_models(api_key: &str) -> Result<Vec<String>> {
    let client = reqwest::Client::new();
    let resp = client
        .get("https://openrouter.ai/api/v1/models")
        .header("Authorization", format!("Bearer {}", api_key))
        .send()
        .await?;

    if !resp.status().is_success() {
        bail!("Could not load OpenRouter models with the provided API key");
    }

    let body: OpenRouterModelsResponse = resp.json().await?;
    let mut models: Vec<String> = body
        .data
        .into_iter()
        .map(|m| m.id)
        .filter(|id| !id.is_empty())
        .collect();
    models.sort();
    Ok(models)
}

#[derive(Deserialize)]
struct OllamaTagsResponse {
    models: Vec<OllamaModel>,
}

#[derive(Deserialize)]
struct OllamaModel {
    name: String,
}

#[derive(Deserialize)]
struct OpenRouterModelsResponse {
    data: Vec<OpenRouterModel>,
}

#[derive(Deserialize)]
struct OpenRouterModel {
    id: String,
}
