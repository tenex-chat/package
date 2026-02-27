use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::theme::ColorfulTheme;
use dialoguer::{Confirm, FuzzySelect, Input, Password, Select};
use indicatif::ProgressBar;
use tenex_orchestrator::config::*;
use tenex_orchestrator::provider;

use crate::display;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    let theme = display::theme();
    loop {
        display::section("Settings");

        // Grouped menu — dialoguer doesn't support section headers natively,
        // so we embed them as disabled-looking items.
        let choices = vec![
            format!("{}", style("── AI ──").dim()),
            "  Providers       — API keys and connections".into(),
            "  LLMs            — Model configurations".into(),
            "  Roles           — Which model handles what task".into(),
            "  Embeddings      — Text embedding model".into(),
            "  Image Gen       — Image generation model".into(),
            format!("{}", style("── Agents ──").dim()),
            "  Escalation      — Route ask() through an agent first".into(),
            "  Intervention    — Auto-review when you're idle".into(),
            format!("{}", style("── Network ──").dim()),
            "  Relays          — Nostr relay connections".into(),
            "  Local Relay     — Run a relay on this machine".into(),
            format!("{}", style("── Conversations ──").dim()),
            "  Compression     — Token limits and sliding window".into(),
            "  Summarization   — Auto-summary timing".into(),
            format!("{}", style("── Advanced ──").dim()),
            "  Identity        — Authorized pubkeys".into(),
            "  System Prompt   — Global prompt for all projects".into(),
            "  Logging         — Log level and file path".into(),
            "  Telemetry       — OpenTelemetry tracing".into(),
            "  ↩ Back to dashboard".into(),
        ];

        let selection = Select::with_theme(&theme)
            .with_prompt("What would you like to configure?")
            .items(&choices)
            .default(1)
            .interact_opt()?;

        match selection {
            Some(1) => settings_providers(config_store, &theme).await?,
            Some(2) => settings_llms(config_store, &theme).await?,
            Some(3) => settings_roles(config_store, &theme)?,
            Some(4) => settings_embeddings(config_store, &theme)?,
            Some(5) => settings_image(config_store, &theme)?,
            Some(7) => settings_escalation(config_store, &theme)?,
            Some(8) => settings_intervention(config_store, &theme)?,
            Some(10) => settings_relays(config_store, &theme)?,
            Some(11) => settings_local_relay(config_store, &theme)?,
            Some(13) => settings_compression(config_store, &theme)?,
            Some(14) => settings_summarization(config_store, &theme)?,
            Some(16) => settings_identity(config_store, &theme)?,
            Some(17) => settings_system_prompt(config_store, &theme)?,
            Some(18) => settings_logging(config_store, &theme)?,
            Some(19) => settings_telemetry(config_store, &theme)?,
            Some(20) | None => break,
            _ => continue, // Section headers — no-op
        }
    }

    Ok(())
}

async fn settings_providers(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut providers = store.load_providers();
    let display_names = provider::provider_display_names();

    display::section("Providers");

    if providers.providers.is_empty() {
        display::context("No providers connected.");
    } else {
        println!("  Currently connected:");
        for (id, entry) in &providers.providers {
            let name = display_names
                .get(id.as_str())
                .copied()
                .unwrap_or(id.as_str());
            let masked = display::mask_key(entry.primary_key().unwrap_or("none"));
            println!(
                "    {} {:<16}{}",
                style("✓").green(),
                name,
                style(masked).dim()
            );
        }
    }
    display::blank();

    let choices = vec!["Add a provider", "Remove a provider", "Back"];
    let selection = Select::with_theme(theme)
        .with_prompt("What do you want to do?")
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match selection {
        Some(0) => {
            let available: Vec<&str> = provider::PROVIDER_LIST_ORDER
                .iter()
                .filter(|&&id| !providers.providers.contains_key(id))
                .copied()
                .collect();

            if available.is_empty() {
                display::context("All providers already connected.");
                return Ok(());
            }

            let names: Vec<&str> = available
                .iter()
                .map(|&id| display_names.get(id).copied().unwrap_or(id))
                .collect();

            let sel = Select::with_theme(theme)
                .with_prompt("Which provider?")
                .items(&names)
                .interact_opt()?;

            if let Some(idx) = sel {
                let provider_id = available[idx];
                if provider::requires_api_key(provider_id) {
                    let key: String = Password::with_theme(theme)
                        .with_prompt("API key")
                        .interact()?;
                    providers
                        .providers
                        .insert(provider_id.to_string(), ProviderEntry::new(key));
                } else {
                    providers
                        .providers
                        .insert(provider_id.to_string(), ProviderEntry::new("none"));
                }
                store.save_providers(&providers)?;
                display::success(&format!("{} connected.", names[idx]));
            }
        }
        Some(1) => {
            if providers.providers.is_empty() {
                display::context("Nothing to remove.");
                return Ok(());
            }
            let keys: Vec<String> = providers.providers.keys().cloned().collect();
            let names: Vec<&str> = keys
                .iter()
                .map(|id| {
                    display_names
                        .get(id.as_str())
                        .copied()
                        .unwrap_or(id.as_str())
                })
                .collect();

            let sel = Select::with_theme(theme)
                .with_prompt("Remove which provider?")
                .items(&names)
                .interact_opt()?;

            if let Some(idx) = sel {
                providers.providers.remove(&keys[idx]);
                store.save_providers(&providers)?;
                display::success(&format!("{} removed.", names[idx]));
            }
        }
        _ => {}
    }

    Ok(())
}

async fn settings_llms(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    loop {
        let mut llms = store.load_llms();
        display::section("LLMs");

        // Build item list: one row per config + Add + Back
        let mut names: Vec<String> = llms.configurations.keys().cloned().collect();
        names.sort();

        let mut items: Vec<String> = names
            .iter()
            .map(|n| {
                let cfg = &llms.configurations[n];
                let padded = format!("{:<20}", n);
                format!(
                    "{} {} {}",
                    style(padded).color256(display::ACCENT),
                    style(cfg.display_model()).bold(),
                    style(format!("({})", cfg.provider())).dim(),
                )
            })
            .collect();
        items.push(format!("{}", style("+ Add new LLM").color256(display::INFO)));
        items.push(format!("{}", style("↩ Back").dim()));

        let add_idx = items.len() - 2;
        let back_idx = items.len() - 1;

        let sel = Select::with_theme(theme)
            .with_prompt("Select an LLM to edit, or add a new one")
            .items(&items)
            .default(back_idx)
            .interact_opt()?;

        match sel {
            None => break,
            Some(i) if i == back_idx => break,
            Some(i) if i == add_idx => {
                if let Some(new_name) = llm_add(store, theme, &llms).await? {
                    display::success(&format!("\"{}\" added.", new_name));
                }
            }
            Some(i) => {
                let cfg_name = names[i].clone();
                llm_edit(store, theme, &mut llms, &cfg_name).await?;
            }
        }
    }
    Ok(())
}

/// Prompt to create a new LLM configuration. Returns the name if one was created.
async fn llm_add(
    store: &Arc<ConfigStore>,
    theme: &ColorfulTheme,
    llms: &tenex_orchestrator::config::TenexLLMs,
) -> Result<Option<String>> {
    use tenex_orchestrator::config::{LLMConfiguration, StandardLLM};

    let providers = store.load_providers();
    if providers.providers.is_empty() {
        display::context("No providers connected. Add a provider first.");
        return Ok(None);
    }

    let name: String = Input::with_theme(theme)
        .with_prompt("Config name (e.g. \"GPT-4o\", \"Local\")")
        .interact_text()?;
    if name.is_empty() {
        return Ok(None);
    }
    if llms.configurations.contains_key(&name) {
        display::context(&format!("\"{}\" already exists.", name));
        return Ok(None);
    }

    let provider_ids: Vec<&str> = provider::PROVIDER_LIST_ORDER
        .iter()
        .copied()
        .filter(|&id| providers.providers.contains_key(id))
        .collect();
    let display_names = provider::provider_display_names();
    let provider_labels: Vec<&str> = provider_ids
        .iter()
        .map(|&id| display_names.get(id).copied().unwrap_or(id))
        .collect();

    let prov_sel = Select::with_theme(theme)
        .with_prompt("Provider")
        .items(&provider_labels)
        .default(0)
        .interact_opt()?;
    let Some(pidx) = prov_sel else {
        return Ok(None);
    };
    let provider_id = provider_ids[pidx];

    let model = pick_model(theme, provider_id, &providers).await?;
    let Some(model) = model else {
        return Ok(None);
    };

    let mut llms = store.load_llms();
    llms.configurations
        .insert(name.clone(), LLMConfiguration::Standard(StandardLLM::new(provider_id, &model)));
    if llms.default_config.is_none() {
        llms.default_config = Some(name.clone());
    }
    store.save_llms(&llms)?;
    Ok(Some(name))
}

/// Edit or delete an existing LLM configuration.
async fn llm_edit(
    store: &Arc<ConfigStore>,
    theme: &ColorfulTheme,
    llms: &mut tenex_orchestrator::config::TenexLLMs,
    cfg_name: &str,
) -> Result<()> {
    use tenex_orchestrator::config::{LLMConfiguration, StandardLLM};

    let is_meta = llms.configurations.get(cfg_name).map(|c| c.is_meta()).unwrap_or(false);

    let mut actions = vec![];
    if !is_meta {
        actions.push("Change provider");
        actions.push("Change model");
    }
    actions.push("Rename");
    actions.push("Delete");
    actions.push("Back");

    let sel = Select::with_theme(theme)
        .with_prompt(format!("{}", style(cfg_name).color256(display::ACCENT).bold()))
        .items(&actions)
        .default(0)
        .interact_opt()?;

    match sel {
        None => {}
        Some(i) => match actions[i] {
            "Change provider" => {
                let providers = store.load_providers();
                let provider_ids: Vec<&str> = provider::PROVIDER_LIST_ORDER
                    .iter()
                    .copied()
                    .filter(|&id| providers.providers.contains_key(id))
                    .collect();
                let display_names = provider::provider_display_names();
                let labels: Vec<&str> = provider_ids
                    .iter()
                    .map(|&id| display_names.get(id).copied().unwrap_or(id))
                    .collect();

                if let Some(pidx) = Select::with_theme(theme)
                    .with_prompt("New provider")
                    .items(&labels)
                    .interact_opt()?
                {
                    let provider_id = provider_ids[pidx];
                    if let Some(model) = pick_model(theme, provider_id, &providers).await? {
                        llms.configurations.insert(
                            cfg_name.to_string(),
                            LLMConfiguration::Standard(StandardLLM::new(provider_id, &model)),
                        );
                        store.save_llms(llms)?;
                        display::success("Provider and model updated.");
                    }
                }
            }
            "Change model" => {
                let providers = store.load_providers();
                let current_provider = llms.configurations[cfg_name].provider().to_string();
                if let Some(model) = pick_model(theme, &current_provider, &providers).await? {
                    if let LLMConfiguration::Standard(s) =
                        llms.configurations.get_mut(cfg_name).unwrap()
                    {
                        s.model = model;
                    }
                    store.save_llms(llms)?;
                    display::success("Model updated.");
                }
            }
            "Rename" => {
                let new_name: String = Input::with_theme(theme)
                    .with_prompt("New name")
                    .default(cfg_name.to_string())
                    .interact_text()?;
                if !new_name.is_empty() && new_name != cfg_name {
                    let cfg = llms.configurations.remove(cfg_name).unwrap();
                    // Update any role references
                    let old = cfg_name.to_string();
                    for role in [
                        &mut llms.default_config,
                        &mut llms.summarization,
                        &mut llms.supervision,
                        &mut llms.search,
                        &mut llms.prompt_compilation,
                        &mut llms.compression,
                    ] {
                        if role.as_deref() == Some(&old) {
                            *role = Some(new_name.clone());
                        }
                    }
                    llms.configurations.insert(new_name.clone(), cfg);
                    store.save_llms(llms)?;
                    display::success(&format!("Renamed to \"{}\".", new_name));
                }
            }
            "Delete" => {
                llms.configurations.remove(cfg_name);
                // Clear role references
                for role in [
                    &mut llms.default_config,
                    &mut llms.summarization,
                    &mut llms.supervision,
                    &mut llms.search,
                    &mut llms.prompt_compilation,
                    &mut llms.compression,
                ] {
                    if role.as_deref() == Some(cfg_name) {
                        *role = None;
                    }
                }
                store.save_llms(llms)?;
                display::success(&format!("\"{}\" deleted.", cfg_name));
            }
            _ => {}
        },
    }

    Ok(())
}

/// For a given provider, show a pick-list or fuzzy search; fall back to text input.
async fn pick_model(
    theme: &ColorfulTheme,
    provider_id: &str,
    providers: &tenex_orchestrator::config::TenexProviders,
) -> Result<Option<String>> {
    match provider_id {
        "ollama" => {
            let base_url = providers
                .providers
                .get("ollama")
                .and_then(|e| e.primary_key())
                .unwrap_or("http://localhost:11434");
            let models = provider::fetch_ollama_models(base_url).await;
            if models.is_empty() {
                display::context("No Ollama models found. Run `ollama pull <model>` first.");
                return Ok(None);
            }
            let items: Vec<String> = models.iter().map(|m| ollama_model_label(m)).collect();
            let sel = Select::with_theme(theme)
                .with_prompt("Model")
                .items(&items)
                .default(0)
                .interact_opt()?;
            return Ok(sel.map(|i| models[i].name.clone()));
        }
        "openrouter" => {
            let spinner = fetch_spinner("Fetching OpenRouter models...");
            let api_key = providers
                .providers
                .get("openrouter")
                .and_then(|e| e.primary_key())
                .unwrap_or("")
                .to_string();
            let models = provider::fetch_openrouter_models(&api_key).await;
            spinner.finish_and_clear();

            if models.is_empty() {
                display::context("Could not fetch model list. Enter the model ID manually.");
                let model: String = Input::with_theme(theme)
                    .with_prompt("Model ID (e.g. anthropic/claude-3-5-sonnet)")
                    .interact_text()?;
                return Ok(if model.is_empty() { None } else { Some(model) });
            }

            let items: Vec<String> = models.iter().map(|m| openrouter_model_label(m)).collect();
            let sel = FuzzySelect::with_theme(theme)
                .with_prompt("Search models (type to filter)")
                .items(&items)
                .default(0)
                .interact_opt()?;
            return Ok(sel.map(|i| models[i].id.clone()));
        }
        "codex-app-server" => {
            let spinner = fetch_spinner("Fetching Codex models...");
            let models = provider::fetch_codex_models().await;
            spinner.finish_and_clear();

            if models.is_empty() {
                let model: String = Input::with_theme(theme)
                    .with_prompt("Model name")
                    .default("gpt-5.1-codex-max".to_string())
                    .interact_text()?;
                return Ok(if model.is_empty() { None } else { Some(model) });
            }

            let items: Vec<String> = models.iter().map(|m| codex_model_label(m)).collect();
            let default_idx = models.iter().position(|m| m.is_default).unwrap_or(0);
            let sel = Select::with_theme(theme)
                .with_prompt("Model")
                .items(&items)
                .default(default_idx)
                .interact_opt()?;
            return Ok(sel.map(|i| models[i].id.clone()));
        }
        _ => {}
    }

    let model: String = Input::with_theme(theme)
        .with_prompt("Model name")
        .interact_text()?;
    Ok(if model.is_empty() { None } else { Some(model) })
}

fn fetch_spinner(msg: &str) -> ProgressBar {
    let sp = ProgressBar::new_spinner();
    sp.set_message(msg.to_string());
    sp.enable_steady_tick(std::time::Duration::from_millis(80));
    sp
}

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

fn settings_roles(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let llms = store.load_llms();
    display::section("Roles");
    let roles = [
        ("default", &llms.default_config),
        ("summarization", &llms.summarization),
        ("supervision", &llms.supervision),
        ("search", &llms.search),
        ("promptCompilation", &llms.prompt_compilation),
        ("compression", &llms.compression),
    ];
    for (role, value) in &roles {
        let val = value.as_deref().unwrap_or("(not set)");
        println!("    {:<20} → {}", style(role).bold(), val);
    }
    display::blank();

    let config_names: Vec<String> = llms.configurations.keys().cloned().collect();
    if config_names.is_empty() {
        display::context("No LLM configs to assign. Configure LLMs first.");
        return Ok(());
    }

    let role_names: Vec<&str> = roles.iter().map(|(name, _)| *name).collect();
    let mut role_choices: Vec<String> = role_names
        .iter()
        .map(|&name| {
            let current = match name {
                "default" => llms.default_config.as_deref(),
                "summarization" => llms.summarization.as_deref(),
                "supervision" => llms.supervision.as_deref(),
                "search" => llms.search.as_deref(),
                "promptCompilation" => llms.prompt_compilation.as_deref(),
                "compression" => llms.compression.as_deref(),
                _ => None,
            };
            format!(
                "{:<20} currently: {}",
                name,
                current.unwrap_or("(not set)")
            )
        })
        .collect();
    role_choices.push("Back".into());

    let sel = Select::with_theme(theme)
        .with_prompt("Edit a role assignment?")
        .items(&role_choices)
        .interact_opt()?;

    if let Some(idx) = sel {
        if idx < role_names.len() {
            let mut model_choices = config_names.clone();
            model_choices.push("(unset)".into());
            let model_sel = Select::with_theme(theme)
                .with_prompt(format!("Assign {} to which model?", role_names[idx]))
                .items(&model_choices)
                .interact_opt()?;

            if let Some(midx) = model_sel {
                let mut llms = store.load_llms();
                let value = if midx < config_names.len() {
                    Some(config_names[midx].clone())
                } else {
                    None
                };
                match role_names[idx] {
                    "default" => llms.default_config = value,
                    "summarization" => llms.summarization = value,
                    "supervision" => llms.supervision = value,
                    "search" => llms.search = value,
                    "promptCompilation" => llms.prompt_compilation = value,
                    "compression" => llms.compression = value,
                    _ => {}
                }
                store.save_llms(&llms)?;
                display::success(&format!("{} role updated.", role_names[idx]));
            }
        }
    }

    Ok(())
}

fn settings_embeddings(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut embed = store.load_embed();
    display::section("Embeddings");
    println!(
        "  Current: {} — {}",
        embed.provider.as_deref().unwrap_or("local"),
        embed.model.as_deref().unwrap_or("Xenova/all-MiniLM-L6-v2")
    );
    display::blank();

    let providers = vec!["local", "openai", "openrouter"];
    let sel = Select::with_theme(theme)
        .with_prompt("Provider")
        .items(&providers)
        .default(0)
        .interact_opt()?;

    if let Some(idx) = sel {
        embed.provider = Some(providers[idx].to_string());

        let models = match providers[idx] {
            "local" => vec![
                "Xenova/all-MiniLM-L6-v2",
                "Xenova/all-mpnet-base-v2",
                "Xenova/paraphrase-multilingual-MiniLM-L12-v2",
            ],
            "openai" | "openrouter" => vec![
                "text-embedding-3-small",
                "text-embedding-3-large",
                "text-embedding-ada-002",
            ],
            _ => vec![],
        };

        let model_sel = Select::with_theme(theme)
            .with_prompt("Model")
            .items(&models)
            .default(0)
            .interact_opt()?;

        if let Some(midx) = model_sel {
            embed.model = Some(models[midx].to_string());
            store.save_embed(&embed)?;
            display::success("Embedding config saved.");
        }
    }

    Ok(())
}

fn settings_image(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut image = store.load_image();
    display::section("Image Generation");
    println!(
        "  Current: {} — {}",
        image.provider.as_deref().unwrap_or("(not set)"),
        image.model.as_deref().unwrap_or("(not set)")
    );
    if let Some(ar) = &image.default_aspect_ratio {
        println!(
            "  Aspect ratio: {}    Size: {}",
            ar,
            image.default_image_size.as_deref().unwrap_or("(not set)")
        );
    }
    display::blank();

    let models = vec![
        "black-forest-labs/flux.2-pro",
        "black-forest-labs/flux.2-max",
        "black-forest-labs/flux.2-klein-4b",
        "google/gemini-2.5-flash-image",
    ];
    let sel = Select::with_theme(theme)
        .with_prompt("Model")
        .items(&models)
        .default(0)
        .interact_opt()?;

    if let Some(idx) = sel {
        image.provider = Some("openrouter".to_string());
        image.model = Some(models[idx].to_string());

        let ratios = vec!["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"];
        let ratio_sel = Select::with_theme(theme)
            .with_prompt("Default aspect ratio")
            .items(&ratios)
            .default(0)
            .interact_opt()?;

        if let Some(ridx) = ratio_sel {
            image.default_aspect_ratio = Some(ratios[ridx].to_string());
        }

        let sizes = vec!["1K", "2K", "4K"];
        let size_sel = Select::with_theme(theme)
            .with_prompt("Default image size")
            .items(&sizes)
            .default(1)
            .interact_opt()?;

        if let Some(sidx) = size_sel {
            image.default_image_size = Some(sizes[sidx].to_string());
        }

        store.save_image(&image)?;
        display::success("Image generation config saved.");
    }

    Ok(())
}

fn settings_escalation(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    display::section("Escalation");
    let current = config
        .escalation
        .as_ref()
        .and_then(|e| e.agent.as_deref())
        .unwrap_or("not configured");
    println!("  Current escalation agent: {}", current);
    display::blank();

    let agent: String = Input::with_theme(theme)
        .with_prompt("Agent slug (empty to disable)")
        .allow_empty(true)
        .interact_text()?;

    if agent.is_empty() {
        config.escalation = None;
    } else {
        config.escalation = Some(EscalationConfig {
            agent: Some(agent),
        });
    }
    store.save_config(&config)?;
    display::success("Escalation config saved.");
    Ok(())
}

fn settings_intervention(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    display::section("Intervention");
    let intervention = config.intervention.clone().unwrap_or_default();
    println!("  Enabled: {}", intervention.enabled.unwrap_or(false));
    if let Some(agent) = &intervention.agent {
        println!("  Agent: {}", agent);
    }
    println!(
        "  Review timeout: {}ms",
        intervention.review_timeout.unwrap_or(300000)
    );
    println!(
        "  Skip if active within: {}s",
        intervention.skip_if_active_within.unwrap_or(120)
    );
    display::blank();

    let enabled = Confirm::with_theme(theme)
        .with_prompt("Enable intervention?")
        .default(intervention.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let agent: String = Input::with_theme(theme)
            .with_prompt("Agent slug")
            .default(intervention.agent.unwrap_or_default())
            .interact_text()?;

        let timeout: u64 = Input::with_theme(theme)
            .with_prompt("Review timeout (ms)")
            .default(intervention.review_timeout.unwrap_or(300000))
            .interact_text()?;

        let skip_within: u64 = Input::with_theme(theme)
            .with_prompt("Skip if active within (seconds)")
            .default(intervention.skip_if_active_within.unwrap_or(120))
            .interact_text()?;

        config.intervention = Some(InterventionConfig {
            enabled: Some(true),
            agent: Some(agent),
            review_timeout: Some(timeout),
            skip_if_active_within: Some(skip_within),
        });
    } else {
        config.intervention = Some(InterventionConfig {
            enabled: Some(false),
            ..intervention
        });
    }

    store.save_config(&config)?;
    display::success("Intervention config saved.");
    Ok(())
}

fn settings_relays(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    display::section("Relays");
    let relays = config.relays.clone().unwrap_or_default();
    if relays.is_empty() {
        display::context("No relays configured.");
    } else {
        for relay in &relays {
            println!("    {} {}", style("●").cyan(), relay);
        }
    }
    display::blank();

    let choices = vec!["Add a relay", "Remove a relay", "Back"];
    let sel = Select::with_theme(theme)
        .with_prompt("What do you want to do?")
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match sel {
        Some(0) => {
            let url: String = Input::with_theme(theme)
                .with_prompt("Relay URL (ws:// or wss://)")
                .interact_text()?;
            let mut relays = config.relays.unwrap_or_default();
            relays.push(url);
            config.relays = Some(relays);
            store.save_config(&config)?;
            display::success("Relay added.");
        }
        Some(1) => {
            if relays.is_empty() {
                display::context("Nothing to remove.");
            } else {
                let sel = Select::with_theme(theme)
                    .with_prompt("Remove which relay?")
                    .items(&relays)
                    .interact_opt()?;
                if let Some(idx) = sel {
                    let mut relays = config.relays.unwrap_or_default();
                    relays.remove(idx);
                    config.relays = Some(relays);
                    store.save_config(&config)?;
                    display::success("Relay removed.");
                }
            }
        }
        _ => {}
    }

    Ok(())
}

fn settings_local_relay(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut launcher = store.load_launcher();
    let lr = launcher.local_relay.clone().unwrap_or_default();
    display::section("Local Relay");
    println!("  Enabled: {}", lr.enabled.unwrap_or(false));
    println!("  Port: {}", lr.port.unwrap_or(7777));
    println!("  Ngrok: {}", lr.ngrok_enabled.unwrap_or(false));
    display::blank();

    let enabled = Confirm::with_theme(theme)
        .with_prompt("Enable local relay?")
        .default(lr.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let port: u16 = Input::with_theme(theme)
            .with_prompt("Port")
            .default(lr.port.unwrap_or(7777))
            .interact_text()?;

        let ngrok = Confirm::with_theme(theme)
            .with_prompt("Enable ngrok tunnel?")
            .default(lr.ngrok_enabled.unwrap_or(false))
            .interact()?;

        launcher.local_relay = Some(LocalRelayConfig {
            enabled: Some(true),
            auto_start: Some(true),
            port: Some(port),
            ngrok_enabled: Some(ngrok),
            ..lr
        });
    } else {
        launcher.local_relay = Some(LocalRelayConfig {
            enabled: Some(false),
            ..lr
        });
    }

    store.save_launcher(&launcher)?;
    display::success("Local relay config saved.");
    Ok(())
}

fn settings_compression(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    let comp = config.compression.clone().unwrap_or_default();
    display::section("Compression");
    println!("  Enabled: {}", comp.enabled.unwrap_or(true));
    println!(
        "  Token threshold: {}",
        comp.token_threshold.unwrap_or(50000)
    );
    println!("  Token budget: {}", comp.token_budget.unwrap_or(40000));
    println!(
        "  Sliding window: {} messages",
        comp.sliding_window_size.unwrap_or(50)
    );
    display::blank();

    let enabled = Confirm::with_theme(theme)
        .with_prompt("Enable compression?")
        .default(comp.enabled.unwrap_or(true))
        .interact()?;

    if enabled {
        let threshold: u64 = Input::with_theme(theme)
            .with_prompt("Token threshold")
            .default(comp.token_threshold.unwrap_or(50000))
            .interact_text()?;

        let budget: u64 = Input::with_theme(theme)
            .with_prompt("Token budget")
            .default(comp.token_budget.unwrap_or(40000))
            .interact_text()?;

        let window: u64 = Input::with_theme(theme)
            .with_prompt("Sliding window size")
            .default(comp.sliding_window_size.unwrap_or(50))
            .interact_text()?;

        config.compression = Some(CompressionConfig {
            enabled: Some(true),
            token_threshold: Some(threshold),
            token_budget: Some(budget),
            sliding_window_size: Some(window),
        });
    } else {
        config.compression = Some(CompressionConfig {
            enabled: Some(false),
            ..comp
        });
    }

    store.save_config(&config)?;
    display::success("Compression config saved.");
    Ok(())
}

fn settings_summarization(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    let summ = config.summarization.clone().unwrap_or_default();
    display::section("Summarization");
    println!(
        "  Inactivity timeout: {}ms ({}min)",
        summ.inactivity_timeout.unwrap_or(300000),
        summ.inactivity_timeout.unwrap_or(300000) / 60000
    );
    display::blank();

    let timeout: u64 = Input::with_theme(theme)
        .with_prompt("Inactivity timeout (ms)")
        .default(summ.inactivity_timeout.unwrap_or(300000))
        .interact_text()?;

    config.summarization = Some(SummarizationConfig {
        inactivity_timeout: Some(timeout),
    });
    store.save_config(&config)?;
    display::success("Summarization config saved.");
    Ok(())
}

fn settings_identity(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    display::section("Identity");
    let pubkeys = config.whitelisted_pubkeys.clone().unwrap_or_default();
    if pubkeys.is_empty() {
        display::context("No authorized pubkeys.");
    } else {
        println!("  Authorized pubkeys:");
        for pk in &pubkeys {
            println!("    {}", pk);
        }
    }
    display::blank();

    let choices = vec!["Add a pubkey", "Remove a pubkey", "Back"];
    let sel = Select::with_theme(theme)
        .with_prompt("What do you want to do?")
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match sel {
        Some(0) => {
            let pk: String = Input::with_theme(theme)
                .with_prompt("Pubkey (hex or npub)")
                .interact_text()?;
            let mut pubkeys = config.whitelisted_pubkeys.unwrap_or_default();
            pubkeys.push(pk);
            config.whitelisted_pubkeys = Some(pubkeys);
            store.save_config(&config)?;
            display::success("Pubkey added.");
        }
        Some(1) => {
            if pubkeys.is_empty() {
                display::context("Nothing to remove.");
            } else {
                let sel = Select::with_theme(theme)
                    .with_prompt("Remove which pubkey?")
                    .items(&pubkeys)
                    .interact_opt()?;
                if let Some(idx) = sel {
                    let mut pubkeys = config.whitelisted_pubkeys.unwrap_or_default();
                    pubkeys.remove(idx);
                    config.whitelisted_pubkeys = Some(pubkeys);
                    store.save_config(&config)?;
                    display::success("Pubkey removed.");
                }
            }
        }
        _ => {}
    }

    Ok(())
}

fn settings_system_prompt(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    let prompt = config.global_system_prompt.clone().unwrap_or_default();
    display::section("System Prompt");
    println!("  Enabled: {}", prompt.enabled.unwrap_or(false));
    if let Some(content) = &prompt.content {
        let preview = if content.chars().count() > 80 {
            let truncated: String = content.chars().take(80).collect();
            format!("{}...", truncated)
        } else {
            content.clone()
        };
        println!("  Content: {}", style(preview).dim());
    }
    display::blank();

    let enabled = Confirm::with_theme(theme)
        .with_prompt("Enable global system prompt?")
        .default(prompt.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let content: String = Input::with_theme(theme)
            .with_prompt("System prompt text")
            .default(prompt.content.unwrap_or_default())
            .interact_text()?;

        config.global_system_prompt = Some(GlobalSystemPrompt {
            enabled: Some(true),
            content: Some(content),
        });
    } else {
        config.global_system_prompt = Some(GlobalSystemPrompt {
            enabled: Some(false),
            ..prompt
        });
    }

    store.save_config(&config)?;
    display::success("System prompt config saved.");
    Ok(())
}

fn settings_logging(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    let logging = config.logging.clone().unwrap_or_default();
    display::section("Logging");
    println!("  Level: {}", logging.level.as_deref().unwrap_or("info"));
    println!(
        "  Log file: {}",
        logging.log_file.as_deref().unwrap_or("(stdout)")
    );
    display::blank();

    let levels = vec!["silent", "error", "warn", "info", "debug"];
    let current_idx = levels
        .iter()
        .position(|&l| l == logging.level.as_deref().unwrap_or("info"))
        .unwrap_or(3);

    let sel = Select::with_theme(theme)
        .with_prompt("Log level")
        .items(&levels)
        .default(current_idx)
        .interact_opt()?;

    if let Some(idx) = sel {
        let log_file: String = Input::with_theme(theme)
            .with_prompt("Log file path (empty for stdout)")
            .default(logging.log_file.unwrap_or_default())
            .allow_empty(true)
            .interact_text()?;

        config.logging = Some(LoggingConfig {
            level: Some(levels[idx].to_string()),
            log_file: if log_file.is_empty() {
                None
            } else {
                Some(log_file)
            },
        });
        store.save_config(&config)?;
        display::success("Logging config saved.");
    }

    Ok(())
}

fn settings_telemetry(store: &Arc<ConfigStore>, theme: &ColorfulTheme) -> Result<()> {
    let mut config = store.load_config();
    let telemetry = config.telemetry.clone().unwrap_or_default();
    display::section("Telemetry");
    println!("  Enabled: {}", telemetry.enabled.unwrap_or(true));
    println!(
        "  Service name: {}",
        telemetry
            .service_name
            .as_deref()
            .unwrap_or("tenex-daemon")
    );
    println!(
        "  Endpoint: {}",
        telemetry
            .endpoint
            .as_deref()
            .unwrap_or("http://localhost:4318/v1/traces")
    );
    display::blank();

    let enabled = Confirm::with_theme(theme)
        .with_prompt("Enable telemetry?")
        .default(telemetry.enabled.unwrap_or(true))
        .interact()?;

    config.telemetry = Some(TelemetryConfig {
        enabled: Some(enabled),
        ..telemetry
    });
    store.save_config(&config)?;
    display::success("Telemetry config saved.");
    Ok(())
}
