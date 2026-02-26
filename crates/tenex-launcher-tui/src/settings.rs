use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, Input, Password, Select};
use tenex_orchestrator::config::*;
use tenex_orchestrator::provider;

use crate::display;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
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

        let selection = Select::new()
            .with_prompt(format!(
                "{} What would you like to configure?",
                style("?").blue().bold()
            ))
            .items(&choices)
            .default(1)
            .interact_opt()?;

        match selection {
            Some(1) => settings_providers(config_store).await?,
            Some(2) => settings_llms(config_store)?,
            Some(3) => settings_roles(config_store)?,
            Some(4) => settings_embeddings(config_store)?,
            Some(5) => settings_image(config_store)?,
            Some(7) => settings_escalation(config_store)?,
            Some(8) => settings_intervention(config_store)?,
            Some(10) => settings_relays(config_store)?,
            Some(11) => settings_local_relay(config_store)?,
            Some(13) => settings_compression(config_store)?,
            Some(14) => settings_summarization(config_store)?,
            Some(16) => settings_identity(config_store)?,
            Some(17) => settings_system_prompt(config_store)?,
            Some(18) => settings_logging(config_store)?,
            Some(19) => settings_telemetry(config_store)?,
            Some(20) | None => break,
            _ => continue, // Section headers — no-op
        }
    }

    Ok(())
}

async fn settings_providers(store: &Arc<ConfigStore>) -> Result<()> {
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
    let selection = Select::new()
        .with_prompt(format!(
            "{} What do you want to do?",
            style("?").blue().bold()
        ))
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

            let sel = Select::new()
                .with_prompt(format!(
                    "{} Which provider?",
                    style("?").blue().bold()
                ))
                .items(&names)
                .interact_opt()?;

            if let Some(idx) = sel {
                let provider_id = available[idx];
                if provider::requires_api_key(provider_id) {
                    let key: String = Password::new()
                        .with_prompt(format!("{} API key", style("?").blue().bold()))
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

            let sel = Select::new()
                .with_prompt(format!(
                    "{} Remove which provider?",
                    style("?").blue().bold()
                ))
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

fn settings_llms(store: &Arc<ConfigStore>) -> Result<()> {
    let llms = store.load_llms();
    display::section("LLMs");
    for (name, config) in &llms.configurations {
        display::config_item(name, &config.display_model(), config.provider());
    }
    display::blank();
    display::context("LLM editing coming soon. Use config files directly for now.");
    Ok(())
}

fn settings_roles(store: &Arc<ConfigStore>) -> Result<()> {
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

    let sel = Select::new()
        .with_prompt(format!(
            "{} Edit a role assignment?",
            style("?").blue().bold()
        ))
        .items(&role_choices)
        .interact_opt()?;

    if let Some(idx) = sel {
        if idx < role_names.len() {
            let mut model_choices = config_names.clone();
            model_choices.push("(unset)".into());
            let model_sel = Select::new()
                .with_prompt(format!(
                    "{} Assign {} to which model?",
                    style("?").blue().bold(),
                    role_names[idx]
                ))
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

fn settings_embeddings(store: &Arc<ConfigStore>) -> Result<()> {
    let mut embed = store.load_embed();
    display::section("Embeddings");
    println!(
        "  Current: {} — {}",
        embed.provider.as_deref().unwrap_or("local"),
        embed.model.as_deref().unwrap_or("Xenova/all-MiniLM-L6-v2")
    );
    display::blank();

    let providers = vec!["local", "openai", "openrouter"];
    let sel = Select::new()
        .with_prompt(format!("{} Provider", style("?").blue().bold()))
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

        let model_sel = Select::new()
            .with_prompt(format!("{} Model", style("?").blue().bold()))
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

fn settings_image(store: &Arc<ConfigStore>) -> Result<()> {
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
    let sel = Select::new()
        .with_prompt(format!("{} Model", style("?").blue().bold()))
        .items(&models)
        .default(0)
        .interact_opt()?;

    if let Some(idx) = sel {
        image.provider = Some("openrouter".to_string());
        image.model = Some(models[idx].to_string());

        let ratios = vec!["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"];
        let ratio_sel = Select::new()
            .with_prompt(format!(
                "{} Default aspect ratio",
                style("?").blue().bold()
            ))
            .items(&ratios)
            .default(0)
            .interact_opt()?;

        if let Some(ridx) = ratio_sel {
            image.default_aspect_ratio = Some(ratios[ridx].to_string());
        }

        let sizes = vec!["1K", "2K", "4K"];
        let size_sel = Select::new()
            .with_prompt(format!(
                "{} Default image size",
                style("?").blue().bold()
            ))
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

fn settings_escalation(store: &Arc<ConfigStore>) -> Result<()> {
    let mut config = store.load_config();
    display::section("Escalation");
    let current = config
        .escalation
        .as_ref()
        .and_then(|e| e.agent.as_deref())
        .unwrap_or("not configured");
    println!("  Current escalation agent: {}", current);
    display::blank();

    let agent: String = Input::new()
        .with_prompt(format!(
            "{} Agent slug (empty to disable)",
            style("?").blue().bold()
        ))
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

fn settings_intervention(store: &Arc<ConfigStore>) -> Result<()> {
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

    let enabled = Confirm::new()
        .with_prompt(format!(
            "{} Enable intervention?",
            style("?").blue().bold()
        ))
        .default(intervention.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let agent: String = Input::new()
            .with_prompt(format!("{} Agent slug", style("?").blue().bold()))
            .default(intervention.agent.unwrap_or_default())
            .interact_text()?;

        let timeout: String = Input::new()
            .with_prompt(format!(
                "{} Review timeout (ms)",
                style("?").blue().bold()
            ))
            .default(intervention.review_timeout.unwrap_or(300000).to_string())
            .interact_text()?;

        let skip_within: String = Input::new()
            .with_prompt(format!(
                "{} Skip if active within (seconds)",
                style("?").blue().bold()
            ))
            .default(
                intervention
                    .skip_if_active_within
                    .unwrap_or(120)
                    .to_string(),
            )
            .interact_text()?;

        config.intervention = Some(InterventionConfig {
            enabled: Some(true),
            agent: Some(agent),
            review_timeout: timeout.parse().ok(),
            skip_if_active_within: skip_within.parse().ok(),
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

fn settings_relays(store: &Arc<ConfigStore>) -> Result<()> {
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
    let sel = Select::new()
        .with_prompt(format!(
            "{} What do you want to do?",
            style("?").blue().bold()
        ))
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match sel {
        Some(0) => {
            let url: String = Input::new()
                .with_prompt(format!(
                    "{} Relay URL (ws:// or wss://)",
                    style("?").blue().bold()
                ))
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
                let sel = Select::new()
                    .with_prompt(format!(
                        "{} Remove which relay?",
                        style("?").blue().bold()
                    ))
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

fn settings_local_relay(store: &Arc<ConfigStore>) -> Result<()> {
    let mut launcher = store.load_launcher();
    let lr = launcher.local_relay.clone().unwrap_or_default();
    display::section("Local Relay");
    println!("  Enabled: {}", lr.enabled.unwrap_or(false));
    println!("  Port: {}", lr.port.unwrap_or(7777));
    println!("  Ngrok: {}", lr.ngrok_enabled.unwrap_or(false));
    display::blank();

    let enabled = Confirm::new()
        .with_prompt(format!(
            "{} Enable local relay?",
            style("?").blue().bold()
        ))
        .default(lr.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let port: String = Input::new()
            .with_prompt(format!("{} Port", style("?").blue().bold()))
            .default(lr.port.unwrap_or(7777).to_string())
            .interact_text()?;

        let ngrok = Confirm::new()
            .with_prompt(format!(
                "{} Enable ngrok tunnel?",
                style("?").blue().bold()
            ))
            .default(lr.ngrok_enabled.unwrap_or(false))
            .interact()?;

        launcher.local_relay = Some(LocalRelayConfig {
            enabled: Some(true),
            auto_start: Some(true),
            port: port.parse().ok(),
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

fn settings_compression(store: &Arc<ConfigStore>) -> Result<()> {
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

    let enabled = Confirm::new()
        .with_prompt(format!(
            "{} Enable compression?",
            style("?").blue().bold()
        ))
        .default(comp.enabled.unwrap_or(true))
        .interact()?;

    if enabled {
        let threshold: String = Input::new()
            .with_prompt(format!(
                "{} Token threshold",
                style("?").blue().bold()
            ))
            .default(comp.token_threshold.unwrap_or(50000).to_string())
            .interact_text()?;

        let budget: String = Input::new()
            .with_prompt(format!("{} Token budget", style("?").blue().bold()))
            .default(comp.token_budget.unwrap_or(40000).to_string())
            .interact_text()?;

        let window: String = Input::new()
            .with_prompt(format!(
                "{} Sliding window size",
                style("?").blue().bold()
            ))
            .default(comp.sliding_window_size.unwrap_or(50).to_string())
            .interact_text()?;

        config.compression = Some(CompressionConfig {
            enabled: Some(true),
            token_threshold: threshold.parse().ok(),
            token_budget: budget.parse().ok(),
            sliding_window_size: window.parse().ok(),
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

fn settings_summarization(store: &Arc<ConfigStore>) -> Result<()> {
    let mut config = store.load_config();
    let summ = config.summarization.clone().unwrap_or_default();
    display::section("Summarization");
    println!(
        "  Inactivity timeout: {}ms ({}min)",
        summ.inactivity_timeout.unwrap_or(300000),
        summ.inactivity_timeout.unwrap_or(300000) / 60000
    );
    display::blank();

    let timeout: String = Input::new()
        .with_prompt(format!(
            "{} Inactivity timeout (ms)",
            style("?").blue().bold()
        ))
        .default(summ.inactivity_timeout.unwrap_or(300000).to_string())
        .interact_text()?;

    config.summarization = Some(SummarizationConfig {
        inactivity_timeout: timeout.parse().ok(),
    });
    store.save_config(&config)?;
    display::success("Summarization config saved.");
    Ok(())
}

fn settings_identity(store: &Arc<ConfigStore>) -> Result<()> {
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
    let sel = Select::new()
        .with_prompt(format!(
            "{} What do you want to do?",
            style("?").blue().bold()
        ))
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match sel {
        Some(0) => {
            let pk: String = Input::new()
                .with_prompt(format!(
                    "{} Pubkey (hex or npub)",
                    style("?").blue().bold()
                ))
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
                let sel = Select::new()
                    .with_prompt(format!(
                        "{} Remove which pubkey?",
                        style("?").blue().bold()
                    ))
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

fn settings_system_prompt(store: &Arc<ConfigStore>) -> Result<()> {
    let mut config = store.load_config();
    let prompt = config.global_system_prompt.clone().unwrap_or_default();
    display::section("System Prompt");
    println!("  Enabled: {}", prompt.enabled.unwrap_or(false));
    if let Some(content) = &prompt.content {
        let preview = if content.len() > 80 {
            format!("{}...", &content[..80])
        } else {
            content.clone()
        };
        println!("  Content: {}", style(preview).dim());
    }
    display::blank();

    let enabled = Confirm::new()
        .with_prompt(format!(
            "{} Enable global system prompt?",
            style("?").blue().bold()
        ))
        .default(prompt.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let content: String = Input::new()
            .with_prompt(format!(
                "{} System prompt text",
                style("?").blue().bold()
            ))
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

fn settings_logging(store: &Arc<ConfigStore>) -> Result<()> {
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

    let sel = Select::new()
        .with_prompt(format!("{} Log level", style("?").blue().bold()))
        .items(&levels)
        .default(current_idx)
        .interact_opt()?;

    if let Some(idx) = sel {
        let log_file: String = Input::new()
            .with_prompt(format!(
                "{} Log file path (empty for stdout)",
                style("?").blue().bold()
            ))
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

fn settings_telemetry(store: &Arc<ConfigStore>) -> Result<()> {
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

    let enabled = Confirm::new()
        .with_prompt(format!(
            "{} Enable telemetry?",
            style("?").blue().bold()
        ))
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
