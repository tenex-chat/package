use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, Input, Password, Select};
use tenex_orchestrator::config::{ConfigStore, LauncherConfig, ProviderEntry, TenexConfig, TenexProviders};
use tenex_orchestrator::onboarding::{OnboardingStateMachine, RelayMode, build_relay_config, seed_default_llms};
use tenex_orchestrator::openclaw;
use tenex_orchestrator::provider;

use crate::display;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    display::welcome();

    let has_openclaw = openclaw::detect().is_some();
    let mut sm = OnboardingStateMachine::new(has_openclaw);
    let mut config = config_store.load_config();
    let mut providers = config_store.load_providers();
    let mut launcher = config_store.load_launcher();

    // Step 1: Identity
    step_identity(&mut config, config_store)?;
    sm.next();

    // Step 2: OpenClaw Import (conditional)
    if has_openclaw {
        step_openclaw(&mut providers, config_store)?;
        sm.next();
    }

    // Step 3: Relay
    step_relay(&mut config, &mut launcher, config_store)?;
    sm.next();

    // Step 4: Providers
    step_providers(&mut providers, config_store).await?;
    sm.next();

    // Step 5: LLMs
    step_llms(&providers, config_store)?;
    sm.next();

    // Step 6: First Project
    step_first_project(&config)?;
    sm.next();

    // Step 7: Hire Agents (stub)
    step_hire_agents()?;
    sm.next();

    // Step 8: Nudges & Skills (stub)
    step_nudges_skills()?;
    sm.next();

    // Step 9: Done
    step_done(&config, &providers)?;
    Ok(())
}

fn step_identity(config: &mut TenexConfig, store: &Arc<ConfigStore>) -> Result<()> {
    display::section("Identity");
    display::context("Your Nostr identity is how agents and other users recognize you.");
    display::context("You need a keypair to authenticate with TENEX.");
    display::blank();

    let choices = vec!["Create new Nostr identity", "I have an existing key (nsec)"];
    let selection = Select::new()
        .with_prompt(format!(
            "{} How do you want to authenticate?",
            style("?").blue().bold()
        ))
        .items(&choices)
        .default(0)
        .interact()?;

    if selection == 0 {
        // Generate new keypair: random 32-byte hex key
        use std::fmt::Write;
        let mut rng_bytes = [0u8; 32];
        getrandom::getrandom(&mut rng_bytes)
            .map_err(|e| anyhow::anyhow!("RNG failed: {}", e))?;
        let mut hex = String::with_capacity(64);
        for b in &rng_bytes {
            write!(hex, "{:02x}", b).unwrap();
        }
        config.tenex_private_key = Some(hex);
        config.whitelisted_pubkeys = Some(vec![]);
        store.save_config(config)?;
        display::success("Generated new keypair. Private key saved.");
    } else {
        let nsec: String = Password::new()
            .with_prompt(format!(
                "{} Enter your nsec",
                style("?").blue().bold()
            ))
            .interact()?;
        config.tenex_private_key = Some(nsec);
        store.save_config(config)?;
        display::success("Identity saved.");
    }

    Ok(())
}

fn step_openclaw(providers: &mut TenexProviders, store: &Arc<ConfigStore>) -> Result<()> {
    let detected = match openclaw::detect() {
        Some(d) => d,
        None => return Ok(()),
    };

    display::section("OpenClaw Import");
    display::context(&format!(
        "Looks like you have OpenClaw installed at {}",
        detected.state_dir.display()
    ));
    display::blank();

    let import = Confirm::new()
        .with_prompt(format!(
            "{} Import credentials?",
            style("?").blue().bold()
        ))
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
        display::success(&format!("Imported {} provider credentials.", count));
    } else {
        display::context("Skipped import.");
    }

    Ok(())
}

fn step_relay(
    config: &mut TenexConfig,
    launcher: &mut LauncherConfig,
    store: &Arc<ConfigStore>,
) -> Result<()> {
    display::section("Relay");
    display::context("The relay connects you to the Nostr network where your agents communicate.");
    display::blank();

    let choices = vec![
        "Remote relay — connect to a relay server",
        "Local relay — run a relay on this machine",
    ];
    let selection = Select::new()
        .with_prompt(format!(
            "{} How should TENEX connect to Nostr?",
            style("?").blue().bold()
        ))
        .items(&choices)
        .default(0)
        .interact()?;

    if selection == 0 {
        let url: String = Input::new()
            .with_prompt(format!("{} Relay URL", style("?").blue().bold()))
            .default("wss://tenex.chat".into())
            .interact_text()?;

        build_relay_config(config, launcher, RelayMode::Remote, &url, false);
    } else {
        let ngrok = Confirm::new()
            .with_prompt(format!(
                "{} Enable ngrok tunnel for mobile access?",
                style("?").blue().bold()
            ))
            .default(false)
            .interact()?;

        build_relay_config(config, launcher, RelayMode::Local, "", ngrok);
    }

    store.save_config(config)?;
    store.save_launcher(launcher)?;

    let relay_desc = config
        .relays
        .as_ref()
        .and_then(|r| r.first())
        .map(|s| s.as_str())
        .unwrap_or("configured");
    display::success(&format!("Relay configured: {}", relay_desc));
    Ok(())
}

async fn step_providers(providers: &mut TenexProviders, store: &Arc<ConfigStore>) -> Result<()> {
    display::section("Providers");
    display::context("These are the AI services your agents will use.");
    display::blank();

    // Auto-detect providers from environment and local commands
    provider::auto_connect_detected(providers).await;

    // Show what's connected
    let display_names = provider::provider_display_names();
    if !providers.providers.is_empty() {
        println!("  Connected:");
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
        display::blank();
    }

    loop {
        let mut choices = vec!["Skip — looks good".to_string()];
        for &provider_id in provider::PROVIDER_LIST_ORDER {
            if !providers.providers.contains_key(provider_id) {
                let name = display_names
                    .get(provider_id)
                    .copied()
                    .unwrap_or(provider_id);
                let subtitle = provider::provider_subtitle(provider_id, false, None, 0);
                choices.push(format!("{} — {}", name, subtitle));
            }
        }

        if choices.len() == 1 {
            display::context("All known providers are connected.");
            break;
        }

        let selection = Select::new()
            .with_prompt(format!("{} Add a provider?", style("?").blue().bold()))
            .items(&choices)
            .default(0)
            .interact()?;

        if selection == 0 {
            break;
        }

        // Map selection back to provider ID
        let mut unconnected: Vec<&str> = Vec::new();
        for &provider_id in provider::PROVIDER_LIST_ORDER {
            if !providers.providers.contains_key(provider_id) {
                unconnected.push(provider_id);
            }
        }
        let provider_id = unconnected[selection - 1];

        if provider::requires_api_key(provider_id) {
            let api_key: String = Password::new()
                .with_prompt(format!(
                    "{} {} API key",
                    style("?").blue().bold(),
                    display_names
                        .get(provider_id)
                        .copied()
                        .unwrap_or(provider_id)
                ))
                .interact()?;

            providers
                .providers
                .insert(provider_id.to_string(), ProviderEntry::new(api_key));
        } else {
            providers
                .providers
                .insert(provider_id.to_string(), ProviderEntry::new("none"));
        }

        store.save_providers(providers)?;
        let name = display_names
            .get(provider_id)
            .copied()
            .unwrap_or(provider_id);
        display::success(&format!("{} connected.", name));
    }

    store.save_providers(providers)?;
    Ok(())
}

fn step_first_project(config: &TenexConfig) -> Result<()> {
    display::section("Your First Project");
    display::context("TENEX organizes work into projects. Each project is a container");
    display::context("for a team of AI agents focused on a shared concern.");
    display::context("Agents can belong to multiple projects and collaborate across them.");
    display::blank();
    display::context("We recommend starting with a \"Meta\" project — a project about");
    display::context("managing your other projects. Think of it as your command center.");
    display::blank();

    let create = Confirm::new()
        .with_prompt(format!(
            "{} Create your Meta project?",
            style("?").blue().bold()
        ))
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
        display::success(
            "Created project \"meta\". The daemon will publish it to Nostr on first start.",
        );
    } else {
        display::context("You can create projects later from the dashboard.");
    }

    Ok(())
}

fn step_hire_agents() -> Result<()> {
    display::section("Hiring Agents");
    display::context("Agents are AI personas with specific roles and skills.");
    display::context("You can browse and hire agents from the Nostr network.");
    display::blank();
    display::context("Agent discovery requires the daemon to be running.");
    display::context("You can hire agents after setup from the dashboard.");
    display::blank();
    display::success("Skipping agent hiring for now — available after first launch.");

    Ok(())
}

fn step_nudges_skills() -> Result<()> {
    display::section("Nudges & Skills");
    display::context("Nudges shape how your agents behave — like standing instructions.");
    display::context("Skills give them specific capabilities they can reach for when needed.");
    display::blank();
    display::context("Nudge and skill discovery requires the daemon to be running.");
    display::context("You can configure these after setup from Settings.");
    display::blank();
    display::success("Skipping for now — available after first launch.");

    Ok(())
}

fn step_done(config: &TenexConfig, providers: &TenexProviders) -> Result<()> {
    display::section("Done");
    display::blank();

    if let Some(relays) = &config.relays {
        if let Some(url) = relays.first() {
            println!("  {:<16}{}", style("Relay:").dim(), url);
        }
    }

    let provider_names: Vec<&str> = providers
        .providers
        .keys()
        .map(|s| s.as_str())
        .collect();
    if !provider_names.is_empty() {
        println!(
            "  {:<16}{}",
            style("Providers:").dim(),
            provider_names.join(", ")
        );
    }

    display::blank();
    display::success("Setup complete! Starting dashboard...");
    display::blank();
    Ok(())
}

fn step_llms(providers: &TenexProviders, store: &Arc<ConfigStore>) -> Result<()> {
    display::section("LLMs");

    let mut llms = store.load_llms();
    let seeded = seed_default_llms(&mut llms, providers);

    if seeded {
        display::context("Here are the model configs I've set up based on your providers:");
        display::blank();
        for (name, config) in &llms.configurations {
            display::config_item(name, &config.display_model(), config.provider());
        }
        display::blank();

        let keep = Confirm::new()
            .with_prompt(format!(
                "{} Continue with these defaults?",
                style("?").blue().bold()
            ))
            .default(true)
            .interact()?;

        if keep {
            store.save_llms(&llms)?;
            display::success("LLM configs saved.");
        } else {
            display::context("You can configure models in Settings > LLMs after setup.");
            store.save_llms(&llms)?;
        }
    } else if llms.configurations.is_empty() {
        display::context("No providers connected — you can configure models later in Settings.");
    } else {
        display::context("Existing LLM configurations found. Keeping them.");
    }

    Ok(())
}
