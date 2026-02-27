use std::io::Write;
use std::process::{Command as SysCommand, Stdio};
use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, FuzzySelect, Input, MultiSelect, Password, Select};
use indicatif::{ProgressBar, ProgressStyle};
use serde::Deserialize;
use tenex_orchestrator::config::{
    ConfigStore, LLMConfiguration, LauncherConfig, ProviderEntry, StandardLLM, TenexConfig,
    TenexLLMs, TenexProviders,
};
use tenex_orchestrator::onboarding::{
    OnboardingStateMachine, RelayMode, build_relay_config, seed_default_llms,
};
use tenex_orchestrator::openclaw;
use tenex_orchestrator::provider;

use crate::display;
use crate::nostr::{self, FetchResults};

/// Maximum items to show in a MultiSelect list before truncating.
const MAX_LIST_ITEMS: usize = 30;

/// Format an Ollama model for display in a list: name + params + quant + size.
fn ollama_model_label(m: &provider::OllamaModel) -> String {
    let name = format!("{:<32}", m.name);
    let params = m
        .parameter_size
        .as_deref()
        .map(|p| format!("{:<6}", p))
        .unwrap_or_else(|| "      ".to_string());
    let quant = m
        .quantization
        .as_deref()
        .map(|q| format!("{:<10}", q))
        .unwrap_or_else(|| "          ".to_string());
    let size = m.size_display();
    format!(
        "{} {} {} {}",
        style(name).color256(display::ACCENT),
        style(params).color256(display::INFO),
        style(quant).dim(),
        style(size).dim(),
    )
}

fn openrouter_model_label(m: &provider::OpenRouterModel) -> String {
    let id = format!("{:<50}", m.id);
    let ctx = format!("{:>6}", m.context_display());
    let price = m.price_display();
    format!(
        "{} {}  {}",
        style(id).color256(display::ACCENT),
        style(ctx).dim(),
        style(price).color256(display::INFO),
    )
}

fn codex_model_label(m: &provider::CodexModel) -> String {
    let id = format!("{:<30}", m.id);
    let desc = if m.is_default {
        format!("{} (default)", m.display_name)
    } else {
        m.display_name.clone()
    };
    format!(
        "{} {}",
        style(id).color256(display::ACCENT),
        style(desc).dim(),
    )
}

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    display::welcome();

    let has_openclaw = openclaw::detect().is_some();
    let mut sm = OnboardingStateMachine::new(has_openclaw);
    let mut config = config_store.load_config();
    let mut providers = config_store.load_providers();
    let mut launcher = config_store.load_launcher();

    let total_steps = if has_openclaw { 9 } else { 8 };
    let mut current_step = 1;

    step_identity(&mut config, config_store, current_step, total_steps)?;
    sm.next();
    current_step += 1;

    if has_openclaw {
        step_openclaw(&mut providers, config_store, current_step, total_steps)?;
        sm.next();
        current_step += 1;
    }

    step_relay(
        &mut config,
        &mut launcher,
        config_store,
        current_step,
        total_steps,
    )?;
    sm.next();
    current_step += 1;

    // Kick off Nostr fetch in the background now that we have relay URLs.
    // The user still has providers, models, and project steps ahead — plenty of time.
    let relay_urls = config.relays.clone().unwrap_or_default();
    let nostr_handle = if !relay_urls.is_empty() {
        Some(tokio::spawn(async move {
            nostr::fetch_from_relays(&relay_urls).await
        }))
    } else {
        None
    };

    let providers_step = current_step;
    let llms_step = current_step + 1;

    loop {
        step_providers(&mut providers, config_store, providers_step, total_steps).await?;
        step_llms(&mut providers, config_store, llms_step, total_steps).await?;

        let llms = config_store.load_llms();
        if !llms.configurations.is_empty() {
            break;
        }

        display::blank();
        display::context(
            "No AI models configured. Your agents won't be able to do anything without one.",
        );
        display::blank();

        let theme = display::theme();
        let choices = vec![
            "Go back and configure a provider + model",
            "Skip anyway (not recommended)",
        ];
        let selection = Select::with_theme(&theme)
            .with_prompt("How do you want to proceed?")
            .items(&choices)
            .default(0)
            .interact()?;

        if selection == 1 {
            break;
        }
    }

    sm.next(); // Providers
    sm.next(); // LLMs
    current_step += 2;

    step_first_project(&config, current_step, total_steps)?;
    sm.next();
    current_step += 1;

    // Await the background Nostr fetch. If it's still running, show a brief spinner.
    let fetched = await_nostr_fetch(nostr_handle).await;

    step_hire_agents(
        &fetched,
        has_openclaw,
        current_step,
        total_steps,
    )?;
    sm.next();
    current_step += 1;

    step_nudges_skills(
        &mut launcher,
        config_store,
        &fetched,
        current_step,
        total_steps,
    )?;
    sm.next();

    step_done(&config, &providers, &launcher)?;
    Ok(())
}

fn spinner() -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    pb.set_style(
        ProgressStyle::default_spinner()
            .tick_chars("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            .template("{spinner:.color256(222)} {msg}")
            .unwrap_or_else(|_| ProgressStyle::default_spinner()),
    );
    pb.enable_steady_tick(std::time::Duration::from_millis(80));
    pb
}

/// Await the background Nostr fetch handle. Only shows a spinner if it's still in progress.
async fn await_nostr_fetch(
    handle: Option<tokio::task::JoinHandle<Result<FetchResults>>>,
) -> Option<FetchResults> {
    let handle = handle?;

    // Check if already done (non-blocking)
    if !handle.is_finished() {
        let sp = spinner();
        sp.set_message("Waiting for network data...");
        let result = handle.await;
        sp.finish_and_clear();
        return match result {
            Ok(Ok(f)) => Some(f),
            Ok(Err(e)) => {
                tracing::warn!("Nostr fetch failed: {}", e);
                None
            }
            Err(e) => {
                tracing::warn!("Nostr fetch task panicked: {}", e);
                None
            }
        };
    }

    match handle.await {
        Ok(Ok(f)) => Some(f),
        _ => None,
    }
}

fn step_identity(
    config: &mut TenexConfig,
    store: &Arc<ConfigStore>,
    step: usize,
    total: usize,
) -> Result<()> {
    display::step(step, total, "Identity");

    display::stream_context(
        "Your identity is how your agents know you, and how others can reach you.",
    );
    display::blank();

    let theme = display::theme();
    let choices = vec![
        "Create a new identity",
        "I have an existing one (import nsec)",
    ];
    let selection = Select::with_theme(&theme)
        .with_prompt("How do you want to set up your identity?")
        .items(&choices)
        .default(0)
        .interact()?;

    if selection == 0 {
        let keys = nostr_sdk::Keys::generate();
        let privkey_hex = keys.secret_key().to_secret_hex();
        let pubkey_hex = keys.public_key().to_hex();
        config.tenex_private_key = Some(privkey_hex);
        config.whitelisted_pubkeys = Some(vec![pubkey_hex]);
        store.save_config(config)?;
        display::blank();
        display::success("Identity created and saved.");
    } else {
        display::blank();
        let nsec: String = Password::with_theme(&theme)
            .with_prompt("Paste your nsec (hidden)")
            .interact()?;

        let keys = nostr_sdk::Keys::parse(&nsec)
            .map_err(|e| anyhow::anyhow!("Invalid nsec: {}", e))?;
        let privkey_hex = keys.secret_key().to_secret_hex();
        let pubkey_hex = keys.public_key().to_hex();
        config.tenex_private_key = Some(privkey_hex);
        config.whitelisted_pubkeys = Some(vec![pubkey_hex]);
        store.save_config(config)?;
        display::blank();
        display::success("Identity imported and saved.");
    }

    Ok(())
}

fn step_openclaw(
    providers: &mut TenexProviders,
    store: &Arc<ConfigStore>,
    step: usize,
    total: usize,
) -> Result<()> {
    let detected = match openclaw::detect() {
        Some(d) => d,
        None => return Ok(()),
    };

    display::step(step, total, "OpenClaw Import");

    display::stream_context("Found an existing OpenClaw installation with API keys.");
    display::blank();

    let theme = display::theme();
    let import = Confirm::with_theme(&theme)
        .with_prompt("Import your existing credentials?")
        .default(true)
        .interact()?;

    if import {
        let mut count = 0;
        for cred in &detected.credentials {
            if !providers.providers.contains_key(&cred.provider) {
                providers
                    .providers
                    .insert(cred.provider.clone(), ProviderEntry::new(&cred.api_key));
                count += 1;
            }
        }
        store.save_providers(providers)?;
        display::blank();
        display::success(&format!(
            "Imported {} provider credentials. Nice.",
            count
        ));
    } else {
        display::blank();
        display::context("No worries, you can add providers manually next.");
    }

    Ok(())
}

fn step_relay(
    config: &mut TenexConfig,
    launcher: &mut LauncherConfig,
    store: &Arc<ConfigStore>,
    step: usize,
    total: usize,
) -> Result<()> {
    display::step(step, total, "Communication");

    display::stream_context(
        "Your agents need a server to communicate through. You can use ours or run\nyour own locally.",
    );
    display::blank();

    let theme = display::theme();
    let choices = vec![
        "Use tenex.chat (recommended)",
        "Run locally, private to this machine",
        "Run locally, accessible from anywhere",
    ];
    let selection = Select::with_theme(&theme)
        .with_prompt("Where should your agents communicate?")
        .items(&choices)
        .default(0)
        .interact()?;

    match selection {
        0 => {
            display::blank();
            let url: String = Input::with_theme(&theme)
                .with_prompt("Server URL")
                .default("wss://tenex.chat".into())
                .interact_text()?;

            build_relay_config(config, launcher, RelayMode::Remote, &url, false);
        }
        1 => {
            build_relay_config(config, launcher, RelayMode::Local, "", false);
        }
        _ => {
            build_relay_config(config, launcher, RelayMode::Local, "", true);
        }
    }

    store.save_config(config)?;
    store.save_launcher(launcher)?;

    let relay_desc = config
        .relays
        .as_ref()
        .and_then(|r| r.first())
        .map(|s| s.as_str())
        .unwrap_or("configured");
    display::blank();
    display::success(&format!(
        "Relay set to {}",
        style(relay_desc).color256(117)
    ));
    Ok(())
}

async fn step_providers(
    providers: &mut TenexProviders,
    store: &Arc<ConfigStore>,
    step: usize,
    total: usize,
) -> Result<()> {
    display::step(step, total, "AI Providers");

    display::stream_context(
        "Connect the AI services your agents will use. You need at least one.",
    );
    display::blank();

    // Auto-detect providers from environment and local commands
    provider::auto_connect_detected(providers).await;

    let display_names = provider::provider_display_names();
    let theme = display::theme();

    loop {
        // Build unified list: all known providers, connected or not, plus Done
        let mut items: Vec<String> = provider::PROVIDER_LIST_ORDER
            .iter()
            .map(|&id| {
                let name = display_names.get(id).copied().unwrap_or(id);
                match providers.providers.get(id) {
                    Some(entry) => {
                        let masked = display::mask_key(entry.primary_key().unwrap_or("?"));
                        let key_count = entry.api_keys.len();
                        let keys_note = if key_count > 1 {
                            format!(" ({} keys)", key_count)
                        } else {
                            String::new()
                        };
                        format!(
                            "{} {:<18} {}{}",
                            style("[✓]").color256(display::SELECTED).bold(),
                            style(name).color256(display::ACCENT),
                            style(masked).dim(),
                            style(keys_note).dim(),
                        )
                    }
                    None => {
                        let subtitle = provider::provider_subtitle(id, false, None, 0);
                        format!(
                            "{} {:<18} {}",
                            style("[ ]").color256(240),
                            name,
                            style(subtitle).dim(),
                        )
                    }
                }
            })
            .collect();
        items.push(format!("{}", style("Done — move on").color256(display::ACCENT)));

        let done_idx = items.len() - 1;
        let selection = Select::with_theme(&theme)
            .with_prompt("Select a provider to connect, update, or remove")
            .items(&items)
            .default(done_idx)
            .interact_opt()?;

        let Some(idx) = selection else { break };
        if idx == done_idx {
            break;
        }

        let provider_id = provider::PROVIDER_LIST_ORDER[idx];
        let name = display_names.get(provider_id).copied().unwrap_or(provider_id);

        if providers.providers.contains_key(provider_id) {
            // Already connected — manage keys (or just disconnect if no key required)
            if !provider::requires_api_key(provider_id) {
                providers.providers.remove(provider_id);
                store.save_providers(providers)?;
                display::success(&format!("{} disconnected.", name));
                display::blank();
                continue;
            }

            let key_count = providers.providers[provider_id].api_keys.len();
            let mut actions = vec![
                "Update primary key".to_string(),
                "Add another key".to_string(),
            ];
            if key_count > 1 {
                actions.push("Remove a key".to_string());
            }
            actions.push("Back".to_string());

            let action = Select::with_theme(&theme)
                .with_prompt(format!("{}", style(name).color256(display::ACCENT).bold()))
                .items(&actions)
                .default(0)
                .interact_opt()?;

            match action {
                Some(0) => {
                    let key: String = Password::with_theme(&theme)
                        .with_prompt(format!("{} new primary key (hidden)", name))
                        .interact()?;
                    providers.providers.entry(provider_id.to_string()).and_modify(|e| {
                        if e.api_keys.is_empty() {
                            e.api_keys.push(key);
                        } else {
                            e.api_keys[0] = key;
                        }
                    });
                    store.save_providers(providers)?;
                    display::success(&format!("{} key updated.", name));
                }
                Some(1) => {
                    let key: String = Password::with_theme(&theme)
                        .with_prompt(format!("{} additional key (hidden)", name))
                        .interact()?;
                    providers.providers.entry(provider_id.to_string()).and_modify(|e| {
                        e.api_keys.push(key);
                    });
                    store.save_providers(providers)?;
                    display::success(&format!("{} key added.", name));
                }
                Some(i) if key_count > 1 && i == 2 => {
                    // "Remove a key"
                    let entry = &providers.providers[provider_id];
                    let key_labels: Vec<String> = entry
                        .api_keys
                        .iter()
                        .enumerate()
                        .map(|(i, k)| {
                            let label = if i == 0 {
                                "primary".to_string()
                            } else {
                                format!("key {}", i + 1)
                            };
                            format!("{} {}", label, style(display::mask_key(k)).dim())
                        })
                        .collect();
                    let key_sel = Select::with_theme(&theme)
                        .with_prompt("Remove which key?")
                        .items(&key_labels)
                        .interact_opt()?;
                    if let Some(kidx) = key_sel {
                        providers.providers.entry(provider_id.to_string()).and_modify(|e| {
                            e.api_keys.remove(kidx);
                        });
                        store.save_providers(providers)?;
                        display::success("Key removed.");
                    }
                }
                _ => {}
            }
        } else {
            // Not connected — connect it
            if provider::requires_api_key(provider_id) {
                let key: String = Password::with_theme(&theme)
                    .with_prompt(format!("{} API key (hidden)", name))
                    .interact()?;
                providers.providers.insert(provider_id.to_string(), ProviderEntry::new(key));
            } else {
                providers.providers.insert(provider_id.to_string(), ProviderEntry::new("none"));
            }
            store.save_providers(providers)?;
            display::success(&format!("{} connected.", name));
        }
        display::blank();
    }

    store.save_providers(providers)?;
    Ok(())
}

async fn step_llms(
    providers: &mut TenexProviders,
    store: &Arc<ConfigStore>,
    step: usize,
    total: usize,
) -> Result<()> {
    display::step(step, total, "Models");

    display::stream_context(
        "Choose which AI models your agents use for different types of work.",
    );
    display::blank();

    let mut llms = store.load_llms();
    // seed_default_llms handles anthropic / openai / claude-code
    let mut seeded = seed_default_llms(&mut llms, providers);

    // Ollama: fetch locally available models and let the user pick (multi-select)
    if providers.providers.contains_key("ollama")
        && !llms.configurations.values().any(|c| c.provider() == "ollama")
    {
        let base_url = providers.providers["ollama"]
            .primary_key()
            .unwrap_or("http://localhost:11434");
        let models = provider::fetch_ollama_models(base_url).await;
        if models.is_empty() {
            display::context("Ollama is connected but no models are installed.");
            display::hint("Run `ollama pull <model>` then re-run setup.");
        } else {
            let theme = display::theme();
            let items: Vec<String> = models.iter().map(|m| ollama_model_label(m)).collect();
            let selections = MultiSelect::with_theme(&theme)
                .with_prompt("Which Ollama models do you want? (space to select)")
                .items(&items)
                .interact()?;
            let mut first = true;
            for idx in selections {
                let model = &models[idx];
                llms.configurations.insert(
                    model.name.clone(),
                    LLMConfiguration::Standard(StandardLLM::new("ollama", &model.name)),
                );
                if first && llms.default_config.is_none() {
                    llms.default_config = Some(model.name.clone());
                    first = false;
                }
                seeded = true;
            }
        }
    }

    // OpenRouter: fuzzy-search the full model catalog, pick one
    if providers.providers.contains_key("openrouter")
        && !llms.configurations.values().any(|c| c.provider() == "openrouter")
    {
        let sp = spinner();
        sp.set_message("Fetching OpenRouter models...");
        let api_key = providers.providers["openrouter"]
            .primary_key()
            .unwrap_or("")
            .to_string();
        let models = provider::fetch_openrouter_models(&api_key).await;
        sp.finish_and_clear();

        if models.is_empty() {
            display::hint(
                "Couldn't fetch OpenRouter model list. Add models in Settings > LLMs.",
            );
        } else {
            let theme = display::theme();
            display::hint("Pick your primary OpenRouter model (type to search):");
            let items: Vec<String> = models.iter().map(|m| openrouter_model_label(m)).collect();
            let sel = FuzzySelect::with_theme(&theme)
                .with_prompt("Search OpenRouter models")
                .items(&items)
                .default(0)
                .interact_opt()?;
            if let Some(idx) = sel {
                let model = &models[idx];
                let config_name = format!(
                    "OR/{}",
                    model.id.split('/').last().unwrap_or(&model.id)
                );
                llms.configurations.insert(
                    config_name.clone(),
                    LLMConfiguration::Standard(StandardLLM::new("openrouter", &model.id)),
                );
                if llms.default_config.is_none() {
                    llms.default_config = Some(config_name);
                }
                seeded = true;
            }
        }
    }

    // Codex App Server: select from the local model list
    if providers.providers.contains_key("codex-app-server")
        && !llms.configurations.values().any(|c| c.provider() == "codex-app-server")
    {
        let sp = spinner();
        sp.set_message("Fetching Codex models...");
        let models = provider::fetch_codex_models().await;
        sp.finish_and_clear();

        let theme = display::theme();
        let chosen_id = if models.is_empty() {
            let model: String = Input::with_theme(&theme)
                .with_prompt("Codex model name")
                .default("gpt-5.1-codex-max".to_string())
                .interact_text()?;
            if model.is_empty() { None } else { Some(model) }
        } else {
            let items: Vec<String> = models.iter().map(|m| codex_model_label(m)).collect();
            let default_idx = models.iter().position(|m| m.is_default).unwrap_or(0);
            let sel = Select::with_theme(&theme)
                .with_prompt("Codex model")
                .items(&items)
                .default(default_idx)
                .interact_opt()?;
            sel.map(|i| models[i].id.clone())
        };

        if let Some(model_id) = chosen_id {
            let config_name = format!(
                "Codex/{}",
                model_id.split('.').next().unwrap_or(&model_id)
            );
            llms.configurations.insert(
                config_name.clone(),
                LLMConfiguration::Standard(StandardLLM::new("codex-app-server", &model_id)),
            );
            if llms.default_config.is_none() {
                llms.default_config = Some(config_name);
            }
            seeded = true;
        }
    }

    if seeded {
        display::hint("Based on your providers, here's what I'd suggest:");
        display::blank();
        for (name, config) in &llms.configurations {
            display::config_item(name, &config.display_model(), config.provider());
        }
        display::blank();

        let theme = display::theme();
        let keep = Confirm::with_theme(&theme)
            .with_prompt("Look good? (you can always tweak these later in Settings)")
            .default(true)
            .interact()?;

        if keep {
            store.save_llms(&llms)?;
            display::blank();
            display::success("Model configs locked in.");
        } else {
            display::blank();
            edit_llms_interactive(&mut llms, providers, store)?;
            store.save_llms(&llms)?;
            display::blank();
            display::success("Model configs saved.");
        }

        // Test the first Standard LLM to verify the configuration works
        test_llm_connection(&llms, providers, store).await;
    } else if llms.configurations.is_empty() {
        display::context("No providers connected yet, so no models to configure.");
        display::hint("Once you add a provider, come back to Settings > LLMs to set these up.");
    } else {
        display::success("Found existing model configs. Keeping them.");
    }

    Ok(())
}

/// Pick the first Standard LLM config and make a test API call.
/// Interactive model editor — lets the user add, edit, remove, and reorder model configs.
fn edit_llms_interactive(
    llms: &mut TenexLLMs,
    providers: &TenexProviders,
    store: &Arc<ConfigStore>,
) -> Result<()> {
    let theme = display::theme();

    loop {
        display::blank();

        let mut names: Vec<String> = llms.configurations.keys().cloned().collect();
        names.sort();

        let mut items: Vec<String> = names
            .iter()
            .map(|name| {
                let config = &llms.configurations[name];
                let is_default = llms.default_config.as_deref() == Some(name.as_str());
                let default_tag = if is_default {
                    format!(" {}", style("[default]").color256(display::SELECTED))
                } else {
                    String::new()
                };
                format!(
                    "{:<20} {:<30} {}{}",
                    style(name).color256(display::ACCENT),
                    style(config.display_model()).color256(display::INFO),
                    style(config.provider()).dim(),
                    default_tag
                )
            })
            .collect();

        let add_idx = items.len();
        items.push(format!("{}", style("Add a model").color256(display::INFO)));
        let done_idx = items.len();
        items.push(format!("{}", style("Done").color256(display::ACCENT)));

        let selection = Select::with_theme(&theme)
            .with_prompt("Edit models")
            .items(&items)
            .default(done_idx)
            .interact_opt()?;

        let Some(idx) = selection else { break };
        if idx == done_idx {
            break;
        }

        if idx == add_idx {
            let name: String = Input::with_theme(&theme)
                .with_prompt("Label for this model (e.g. \"GPT-4o-mini\")")
                .interact_text()?;
            if name.trim().is_empty() {
                continue;
            }
            let model_id: String = Input::with_theme(&theme)
                .with_prompt("Model ID (e.g. \"gpt-4o-mini\")")
                .interact_text()?;

            let provider_ids: Vec<&str> =
                providers.providers.keys().map(|s| s.as_str()).collect();
            if provider_ids.is_empty() {
                display::context("No providers connected. Connect a provider first.");
                continue;
            }
            let provider_sel = Select::with_theme(&theme)
                .with_prompt("Provider")
                .items(&provider_ids)
                .default(0)
                .interact()?;
            let provider = provider_ids[provider_sel].to_string();

            let set_default = llms.default_config.is_none()
                || Confirm::with_theme(&theme)
                    .with_prompt(format!("Set \"{}\" as the default?", name))
                    .default(false)
                    .interact()?;

            llms.configurations.insert(
                name.clone(),
                LLMConfiguration::Standard(StandardLLM::new(&provider, &model_id)),
            );
            if set_default {
                llms.default_config = Some(name.clone());
            }
            store.save_llms(llms)?;
            display::success(&format!("Added \"{}\".", name));
            continue;
        }

        let name = names[idx].clone();
        let is_default = llms.default_config.as_deref() == Some(name.as_str());
        let is_meta = llms.configurations[&name].is_meta();

        let mut actions: Vec<&str> = Vec::new();
        if !is_meta {
            actions.push("Edit model ID");
        }
        if !is_default {
            actions.push("Set as default");
        }
        actions.push("Remove");
        actions.push("Back");

        let action = Select::with_theme(&theme)
            .with_prompt(format!("{}", style(&name).color256(display::ACCENT).bold()))
            .items(&actions)
            .default(0)
            .interact_opt()?;

        match action.map(|i| actions[i]) {
            Some("Edit model ID") => {
                if let LLMConfiguration::Standard(s) = &llms.configurations[&name] {
                    let current = s.model.clone();
                    let new_model: String = Input::with_theme(&theme)
                        .with_prompt("Model ID")
                        .default(current)
                        .interact_text()?;
                    if let LLMConfiguration::Standard(s) =
                        llms.configurations.get_mut(&name).unwrap()
                    {
                        s.model = new_model;
                    }
                    store.save_llms(llms)?;
                    display::success(&format!("\"{}\" updated.", name));
                }
            }
            Some("Set as default") => {
                llms.default_config = Some(name.clone());
                store.save_llms(llms)?;
                display::success(&format!("\"{}\" is now the default.", name));
            }
            Some("Remove") => {
                llms.configurations.remove(&name);
                if llms.default_config.as_deref() == Some(name.as_str()) {
                    llms.default_config = llms.configurations.keys().next().cloned();
                }
                store.save_llms(llms)?;
                display::success(&format!("\"{}\" removed.", name));
            }
            _ => {}
        }
    }

    Ok(())
}

/// On failure, let the user re-enter the API key and retry.
async fn test_llm_connection(
    llms: &TenexLLMs,
    providers: &mut TenexProviders,
    store: &Arc<ConfigStore>,
) {
    // Find a testable Standard LLM
    let (name, provider_id, model) = match llms.configurations.iter().find_map(|(name, config)| {
        if let LLMConfiguration::Standard(s) = config {
            if matches!(
                s.provider.as_str(),
                "claude-code" | "gemini-cli" | "codex-app-server"
            ) {
                return None;
            }
            providers.providers.get(&s.provider)?;
            Some((name.clone(), s.provider.clone(), s.model.clone()))
        } else {
            None
        }
    }) {
        Some(t) => t,
        None => return,
    };

    let theme = display::theme();
    let display_names = provider::provider_display_names();

    loop {
        let entry = match providers.providers.get(&provider_id) {
            Some(e) => e,
            None => return,
        };
        let api_key = match entry.primary_key() {
            Some(k) => k.to_string(),
            None => return,
        };
        let base_url = entry.base_url.clone();

        display::blank();
        let sp = spinner();
        sp.set_message(format!("Testing {} ({})...", name, model));

        let result = provider::test_provider_connection(
            &provider_id,
            &model,
            &api_key,
            base_url.as_deref(),
        )
        .await;

        sp.finish_and_clear();

        match result {
            Ok(response) => {
                let trimmed = response.trim();
                if trimmed.is_empty() {
                    display::success(&format!("{} is working.", name));
                } else {
                    display::success(&format!("{}: \"{}\"", name, trimmed));
                }
                return;
            }
            Err(e) => {
                display::context(&format!("Test failed for {}: {}", name, e));
                display::blank();

                let provider_name = display_names
                    .get(provider_id.as_str())
                    .copied()
                    .unwrap_or(provider_id.as_str());

                let retry = Confirm::with_theme(&theme)
                    .with_prompt(format!("Re-enter API key for {}?", provider_name))
                    .default(true)
                    .interact()
                    .unwrap_or(false);

                if !retry {
                    display::hint("You can fix it later in Settings > Providers.");
                    return;
                }

                let new_key: String = match Password::with_theme(&theme)
                    .with_prompt(format!("{} API key (hidden)", provider_name))
                    .interact()
                {
                    Ok(k) => k,
                    Err(_) => return,
                };

                providers
                    .providers
                    .insert(provider_id.clone(), ProviderEntry::new(new_key));
                store.save_providers(providers).ok();
            }
        }
    }
}

fn step_first_project(config: &TenexConfig, step: usize, total: usize) -> Result<()> {
    display::step(step, total, "Your First Project");

    display::stream_context(
        "Projects organize what your agents work on. We suggest starting with a\n\"Meta\" project — a command center where agents track everything else.",
    );
    display::blank();

    let theme = display::theme();
    let create = Confirm::with_theme(&theme)
        .with_prompt("Create a Meta project?")
        .default(true)
        .interact()?;

    if create {
        let projects_base = config.projects_base.clone().unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_default()
                .join("tenex")
                .to_string_lossy()
                .into()
        });
        let meta_dir = std::path::Path::new(&projects_base).join("meta");
        std::fs::create_dir_all(&meta_dir).ok();
        display::blank();
        display::success("Created \"meta\" project.");
    } else {
        display::blank();
        display::context("Sure thing. You can create projects anytime from the dashboard.");
    }

    Ok(())
}

/// A single OpenClaw agent entry as returned by `tenex agent import openclaw --dry-run --json`.
#[derive(Deserialize)]
struct OpenClawAgentEntry {
    name: String,
    slug: String,
}

/// Resolve the tenex-daemon backend binary path.
///
/// Resolution order:
/// 1. `TENEX_BACKEND` environment variable
/// 2. Sibling binary next to the current executable
/// 3. `deps/backend/dist/tenex-daemon` found by walking up the directory tree (dev)
/// 4. `tenex-daemon` on `$PATH`
fn resolve_backend_bin() -> Option<std::path::PathBuf> {
    // 1. TENEX_BACKEND env var
    if let Ok(val) = std::env::var("TENEX_BACKEND") {
        let path = std::path::PathBuf::from(&val);
        if path.exists() {
            return Some(path);
        }
    }

    // 2. Sibling binary next to current exe
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sibling = dir.join("tenex-daemon");
            if sibling.exists() {
                return Some(sibling);
            }
        }
    }

    // 3. deps/backend/dist/tenex-daemon — walk up from exe to find repo root
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(|p| p.to_path_buf());
        for _ in 0..8 {
            if let Some(d) = dir {
                let candidate = d.join("deps/backend/dist/tenex-daemon");
                if candidate.exists() {
                    return Some(candidate);
                }
                dir = d.parent().map(|p| p.to_path_buf());
            } else {
                break;
            }
        }
    }

    // 4. which tenex-daemon on PATH
    if let Ok(out) = SysCommand::new("which").arg("tenex-daemon").output() {
        if out.status.success() {
            let path_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !path_str.is_empty() {
                return Some(std::path::PathBuf::from(path_str));
            }
        }
    }

    None
}

fn step_hire_agents(
    fetched: &Option<FetchResults>,
    openclaw_detected: bool,
    step: usize,
    total: usize,
) -> Result<()> {
    display::step(step, total, "Hire Your Team");

    display::stream_context(
        "Pick a pre-built agent team or choose individual agents.",
    );
    display::blank();

    let has_nostr_agents = fetched.as_ref().map_or(false, |f| !f.agents.is_empty());

    if !openclaw_detected && !has_nostr_agents {
        display::context("No agents available right now.");
        display::hint("You can browse and hire agents later from the dashboard.");
        return Ok(());
    }

    let backend_bin = resolve_backend_bin();
    if backend_bin.is_none() {
        display::context("Backend binary not found — agents cannot be installed during setup.");
        display::hint("Start the daemon and hire agents from the dashboard.");
        return Ok(());
    }
    let bin = backend_bin.unwrap();

    let theme = display::theme();
    let mut installed_count = 0usize;

    // ── Section A: OpenClaw agents ────────────────────────────────────────────
    if openclaw_detected {
        let dry_run_out = SysCommand::new(&bin)
            .args(["agent", "import", "openclaw", "--dry-run", "--json"])
            .output();

        if let Ok(out) = dry_run_out {
            let openclaw_agents: Vec<OpenClawAgentEntry> =
                serde_json::from_slice(&out.stdout).unwrap_or_default();

            if !openclaw_agents.is_empty() {
                display::hint("Found your OpenClaw agents:");
                display::blank();

                let items: Vec<String> = openclaw_agents
                    .iter()
                    .map(|a| style(&a.name).color256(display::ACCENT).to_string())
                    .collect();
                let all_checked = vec![true; openclaw_agents.len()];

                let selections = MultiSelect::with_theme(&theme)
                    .with_prompt(
                        "Import your OpenClaw agents? (space to toggle, enter to confirm)",
                    )
                    .items(&items)
                    .defaults(&all_checked)
                    .interact()?;

                if !selections.is_empty() {
                    let slugs: Vec<&str> = selections
                        .iter()
                        .map(|&i| openclaw_agents[i].slug.as_str())
                        .collect();
                    let slugs_arg = slugs.join(",");

                    let status = SysCommand::new(&bin)
                        .args(["agent", "import", "openclaw", "--slugs", &slugs_arg])
                        .status();

                    match status {
                        Ok(s) if s.success() => {
                            installed_count += selections.len();
                        }
                        _ => {
                            display::context(
                                "OpenClaw import encountered an issue — check daemon logs.",
                            );
                        }
                    }
                }
                display::blank();
            }
        }
    }

    // ── Section B: Nostr agents ───────────────────────────────────────────────
    if let Some(fetched) = fetched.as_ref().filter(|f| !f.agents.is_empty()) {
        // If teams exist, offer team selection first
        if !fetched.teams.is_empty() {
            let mut choices: Vec<String> = fetched
                .teams
                .iter()
                .map(|t| {
                    let agent_count = fetched.agents_for_team(t).len();
                    if t.description.is_empty() {
                        format!("{} ({} agents)", t.title, agent_count)
                    } else {
                        format!(
                            "{} — {} ({} agents)",
                            t.title,
                            style(&t.description).dim(),
                            agent_count
                        )
                    }
                })
                .collect();
            choices.push("Pick individual agents instead".into());

            let selection = Select::with_theme(&theme)
                .with_prompt("Choose a team")
                .items(&choices)
                .default(0)
                .interact()?;

            if selection < fetched.teams.len() {
                let team = &fetched.teams[selection];
                let team_agents = fetched.agents_for_team(team);

                if !team_agents.is_empty() {
                    display::blank();
                    display::hint(&format!("Agents in {}:", team.title));
                    for a in &team_agents {
                        println!(
                            "    {} {:<20} {}",
                            style("●").color256(117),
                            style(&a.name).bold(),
                            style(&a.role).dim()
                        );
                    }

                    let names: Vec<&str> = team_agents.iter().map(|a| a.name.as_str()).collect();
                    let count = install_nostr_agents(&bin, team_agents.as_slice())?;
                    installed_count += count;

                    display::blank();
                    display::success(&format!(
                        "Team \"{}\" installed: {}",
                        team.title,
                        names.join(", ")
                    ));
                    // Done — skip individual selection
                    if installed_count > 0 {
                        display::blank();
                        display::success(&format!(
                            "{} agent(s) ready.",
                            installed_count
                        ));
                    }
                    return Ok(());
                }
            }
            // Fall through to individual selection
        }

        // Individual agent selection
        let agents = &fetched.agents;
        let capped = agents.len() > MAX_LIST_ITEMS;
        let display_agents = if capped { &agents[..MAX_LIST_ITEMS] } else { agents };

        let items: Vec<String> = display_agents
            .iter()
            .map(|a| {
                let padded = format!("{:<20}", a.name);
                if a.role.is_empty() {
                    format!(
                        "{} {}",
                        style(padded).color256(display::ACCENT),
                        style(&a.description).dim()
                    )
                } else {
                    format!(
                        "{} {} — {}",
                        style(padded).color256(display::ACCENT),
                        style(&a.role).color256(display::INFO),
                        style(&a.description).dim()
                    )
                }
            })
            .collect();

        if capped {
            display::hint(&format!(
                "Showing {} of {} agents. Browse all from the dashboard.",
                MAX_LIST_ITEMS,
                agents.len()
            ));
            display::blank();
        }

        let selections = MultiSelect::with_theme(&theme)
            .with_prompt("Which agents do you want? (space to select, enter to confirm)")
            .items(&items)
            .interact()?;

        if selections.is_empty() {
            display::blank();
            display::context("No agents selected. You can hire agents anytime from the dashboard.");
        } else {
            let selected_agents: Vec<&nostr::FetchedAgent> =
                selections.iter().map(|&i| &display_agents[i]).collect();
            let names: Vec<&str> = selected_agents.iter().map(|a| a.name.as_str()).collect();
            let count = install_nostr_agents(&bin, &selected_agents)?;
            installed_count += count;

            display::blank();
            display::success(&format!(
                "Installed {} agent(s): {}",
                count,
                names.join(", ")
            ));
        }
    }

    if installed_count > 0 {
        display::blank();
        display::success(&format!("{} agent(s) ready.", installed_count));
    }

    Ok(())
}

/// Install Nostr agents by piping raw event JSON to `tenex agent add` via stdin.
/// Returns the number successfully installed.
fn install_nostr_agents(bin: &std::path::Path, agents: &[&nostr::FetchedAgent]) -> Result<usize> {
    let mut count = 0usize;
    for agent in agents {
        if agent.raw_json.is_empty() {
            tracing::warn!("Skipping agent {} — no raw JSON available", agent.id);
            continue;
        }
        let mut child = match SysCommand::new(bin)
            .args(["agent", "add"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("Failed to spawn agent add for {}: {}", agent.id, e);
                continue;
            }
        };

        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(agent.raw_json.as_bytes()).ok();
        }

        if let Ok(status) = child.wait() {
            if status.success() {
                count += 1;
            } else {
                tracing::warn!("agent add failed for {}", agent.id);
            }
        }
    }
    Ok(count)
}

fn step_nudges_skills(
    launcher: &mut LauncherConfig,
    store: &Arc<ConfigStore>,
    fetched: &Option<FetchResults>,
    step: usize,
    total: usize,
) -> Result<()> {
    display::step(step, total, "Nudges & Skills");

    // --- Nudges ---
    display::stream_context(
        "Nudges modify agent behavior and grant or restrict capabilities — tools they can use, how they respond, what they're allowed to do.",
    );
    display::blank();

    let theme = display::theme();
    let has_nudges = matches!(fetched, Some(f) if !f.nudges.is_empty());
    if has_nudges {
        let nudges = &fetched.as_ref().unwrap().nudges;
        let capped = nudges.len() > MAX_LIST_ITEMS;
        let display_nudges = if capped {
            &nudges[..MAX_LIST_ITEMS]
        } else {
            nudges
        };

        let nudge_items: Vec<String> = display_nudges
            .iter()
            .map(|n| {
                let padded = format!("{:<24}", n.title);
                format!("{} {}", style(padded).color256(display::ACCENT), style(&n.description).dim())
            })
            .collect();

        if capped {
            display::hint(&format!(
                "Showing {} of {}. Browse all from the dashboard.",
                MAX_LIST_ITEMS,
                nudges.len()
            ));
            display::blank();
        }

        let nudge_selections = MultiSelect::with_theme(&theme)
            .with_prompt("Pick nudges for your team (space to select)")
            .items(&nudge_items)
            .interact()?;

        if !nudge_selections.is_empty() {
            let ids: Vec<String> = nudge_selections
                .iter()
                .map(|&i| display_nudges[i].id.clone())
                .collect();
            let names: Vec<&str> = nudge_selections
                .iter()
                .map(|&i| display_nudges[i].title.as_str())
                .collect();
            launcher.pending_nudge_ids = Some(ids);
            display::blank();
            display::success(&format!("Nudges selected: {}", names.join(", ")));
        }
    } else {
        display::context("No nudges available right now.");
        display::hint("You can browse and enable nudges later from the dashboard.");
    }
    display::blank();

    // --- Skills ---
    display::stream_context("Skills are capabilities your agents can use when needed.");
    display::blank();

    let has_skills = matches!(fetched, Some(f) if !f.skills.is_empty());
    if has_skills {
        let skills = &fetched.as_ref().unwrap().skills;
        let capped = skills.len() > MAX_LIST_ITEMS;
        let display_skills = if capped {
            &skills[..MAX_LIST_ITEMS]
        } else {
            skills
        };

        let skill_items: Vec<String> = display_skills
            .iter()
            .map(|s| {
                let padded = format!("{:<24}", s.title);
                format!("{} {}", style(padded).color256(display::ACCENT), style(&s.description).dim())
            })
            .collect();

        if capped {
            display::hint(&format!(
                "Showing {} of {}. Browse all from the dashboard.",
                MAX_LIST_ITEMS,
                skills.len()
            ));
            display::blank();
        }

        let skill_selections = MultiSelect::with_theme(&theme)
            .with_prompt("Pick skills to enable (space to select)")
            .items(&skill_items)
            .interact()?;

        if !skill_selections.is_empty() {
            let ids: Vec<String> = skill_selections
                .iter()
                .map(|&i| display_skills[i].id.clone())
                .collect();
            let names: Vec<&str> = skill_selections
                .iter()
                .map(|&i| display_skills[i].title.as_str())
                .collect();
            launcher.pending_skill_ids = Some(ids);
            display::blank();
            display::success(&format!("Skills enabled: {}", names.join(", ")));
        }
    } else {
        display::context("No skills available right now.");
        display::hint("You can browse and enable skills later from the dashboard.");
    }

    store.save_launcher(launcher)?;
    display::blank();

    Ok(())
}

fn step_done(
    config: &TenexConfig,
    providers: &TenexProviders,
    launcher: &LauncherConfig,
) -> Result<()> {
    display::setup_complete();

    if let Some(relays) = &config.relays {
        if let Some(url) = relays.first() {
            display::summary_line("Relay", url);
        }
    }

    let display_names = provider::provider_display_names();
    let provider_labels: Vec<&str> = providers
        .providers
        .keys()
        .map(|id| {
            display_names
                .get(id.as_str())
                .copied()
                .unwrap_or(id.as_str())
        })
        .collect();
    if !provider_labels.is_empty() {
        display::summary_line("Providers", &provider_labels.join(", "));
    }

    if let Some(nudges) = &launcher.pending_nudge_ids {
        if !nudges.is_empty() {
            display::summary_line("Nudges", &format!("{} selected", nudges.len()));
        }
    }

    if let Some(skills) = &launcher.pending_skill_ids {
        if !skills.is_empty() {
            display::summary_line("Skills", &format!("{} enabled", skills.len()));
        }
    }

    display::blank();
    display::hint("Launching the dashboard...");
    display::blank();
    Ok(())
}
