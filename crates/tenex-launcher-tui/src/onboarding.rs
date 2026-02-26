use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, Password, Select};
use tenex_orchestrator::config::{ConfigStore, ProviderEntry, TenexConfig, TenexProviders};
use tenex_orchestrator::onboarding::OnboardingStateMachine;
use tenex_orchestrator::openclaw;

use crate::display;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    display::welcome();

    let has_openclaw = openclaw::detect().is_some();
    let mut sm = OnboardingStateMachine::new(has_openclaw);
    let mut config = config_store.load_config();
    let mut providers = config_store.load_providers();
    let _launcher = config_store.load_launcher();

    // Step 1: Identity
    step_identity(&mut config, config_store)?;
    sm.next();

    // Step 2: OpenClaw Import (conditional)
    if has_openclaw {
        step_openclaw(&mut providers, config_store)?;
        sm.next();
    }

    // Remaining steps added in subsequent tasks
    display::blank();
    display::context("Remaining steps coming soon.");
    display::blank();
    display::success("Setup complete!");
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
