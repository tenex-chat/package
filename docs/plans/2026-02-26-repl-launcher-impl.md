# REPL Launcher Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the full-screen ratatui TUI in `tenex-launcher-tui` with an inline REPL using `dialoguer` + `console`, covering onboarding (9 steps), dashboard (hybrid status + menu), and grouped settings.

**Architecture:** The TUI crate drops `ratatui`/`crossterm` entirely. New modules: `repl.rs` (top-level loop), `onboarding.rs` (steps 1-9), `dashboard.rs` (status + actions), `settings.rs` (grouped categories), `display.rs` (styled helpers). The `tenex-orchestrator` crate's `OnboardingStateMachine` is updated with 3 new steps (FirstProject, HireAgents, NudgesSkills). Process managers (`DaemonManager`, `RelayManager`, `NgrokManager`) are reused as-is.

**Tech Stack:** Rust, dialoguer 0.11, console 0.15, indicatif 0.17, tenex-orchestrator (existing), tokio (existing)

**Design doc:** `docs/plans/2026-02-26-repl-launcher-design.md`

---

### Task 1: Update Dependencies

**Files:**
- Modify: `Cargo.toml` (workspace root)
- Modify: `crates/tenex-launcher-tui/Cargo.toml`

**Step 1: Update workspace Cargo.toml**

Remove `ratatui` and `crossterm` from workspace dependencies. Add `dialoguer`, `console`, `indicatif`:

```toml
# Remove these two lines:
# ratatui = "0.29"
# crossterm = { version = "0.28", features = ["event-stream"] }

# Add:
dialoguer = { version = "0.11", features = ["history"] }
console = "0.15"
indicatif = "0.17"
```

**Step 2: Update tenex-launcher-tui Cargo.toml**

Replace `ratatui` and `crossterm` with the new deps:

```toml
[dependencies]
tenex-orchestrator = { path = "../tenex-orchestrator" }
anyhow.workspace = true
serde.workspace = true
serde_json.workspace = true
tokio.workspace = true
futures.workspace = true
tracing.workspace = true
tracing-subscriber.workspace = true
dialoguer.workspace = true
console.workspace = true
indicatif.workspace = true
```

**Step 3: Verify it compiles (will fail — that's expected, old code references ratatui)**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo check -p tenex-launcher-tui 2>&1 | head -5`
Expected: Compilation errors about missing ratatui/crossterm imports.

**Step 4: Commit**

```bash
git add Cargo.toml crates/tenex-launcher-tui/Cargo.toml
git commit -m "chore: swap ratatui/crossterm for dialoguer/console/indicatif"
```

---

### Task 2: Update OnboardingStateMachine

**Files:**
- Modify: `crates/tenex-orchestrator/src/onboarding/state_machine.rs`

**Step 1: Write tests for new steps**

Add tests for the 3 new steps to the existing test module in `state_machine.rs`:

```rust
#[test]
fn step_progression_full_flow() {
    let mut sm = OnboardingStateMachine::new(false);
    assert_eq!(sm.step, OnboardingStep::Identity);

    sm.next(); // → Relay (skips OpenClaw)
    assert_eq!(sm.step, OnboardingStep::Relay);

    sm.next();
    assert_eq!(sm.step, OnboardingStep::Providers);

    sm.next();
    assert_eq!(sm.step, OnboardingStep::LLMs);

    sm.next();
    assert_eq!(sm.step, OnboardingStep::FirstProject);

    sm.next();
    assert_eq!(sm.step, OnboardingStep::HireAgents);

    sm.next();
    assert_eq!(sm.step, OnboardingStep::NudgesSkills);

    sm.next();
    assert_eq!(sm.step, OnboardingStep::Done);
    assert!(sm.is_complete());
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo test -p tenex-orchestrator onboarding 2>&1 | tail -10`
Expected: FAIL — `OnboardingStep::FirstProject` doesn't exist.

**Step 3: Update the enum and state machine**

In `state_machine.rs`, replace `MobileSetup` with three new steps + `Done`:

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnboardingStep {
    Identity,
    OpenClawImport,
    Relay,
    Providers,
    LLMs,
    FirstProject,
    HireAgents,
    NudgesSkills,
    Done,
}
```

Update `next()`:
```rust
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
        OnboardingStep::LLMs => OnboardingStep::FirstProject,
        OnboardingStep::FirstProject => OnboardingStep::HireAgents,
        OnboardingStep::HireAgents => OnboardingStep::NudgesSkills,
        OnboardingStep::NudgesSkills => OnboardingStep::Done,
        OnboardingStep::Done => OnboardingStep::Done,
    };
}
```

Update `back()` similarly. Update `is_complete()`:
```rust
pub fn is_complete(&self) -> bool {
    self.step == OnboardingStep::Done
}
```

**Step 4: Update existing tests that reference MobileSetup**

Replace all `OnboardingStep::MobileSetup` references with the new flow. The `step_progression_no_openclaw` test should end at `Done`. The `step_progression_with_openclaw` test stays the same (OpenClawImport → Relay). The `back_navigation` test needs updating.

**Step 5: Run tests to verify they pass**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo test -p tenex-orchestrator onboarding`
Expected: All PASS.

**Step 6: Commit**

```bash
git add crates/tenex-orchestrator/src/onboarding/state_machine.rs
git commit -m "feat(onboarding): add FirstProject, HireAgents, NudgesSkills steps"
```

---

### Task 3: Create display.rs (Styled Output Helpers)

**Files:**
- Create: `crates/tenex-launcher-tui/src/display.rs`

**Step 1: Create the display module**

This module wraps `console` crate styling into reusable helpers matching the conversational design.

```rust
use console::{style, Term};

pub fn term() -> Term {
    Term::stderr()
}

/// Print a section header with separator line.
///   ─── Identity ───────────────────────
pub fn section(title: &str) {
    let rule_len = 40usize.saturating_sub(title.len() + 2);
    let rule = "─".repeat(rule_len);
    println!();
    println!(
        "  {} {} {}",
        style("───").dim(),
        style(title).bold(),
        style(rule).dim()
    );
    println!();
}

/// Print dim context/explanation text.
pub fn context(text: &str) {
    for line in text.lines() {
        println!("  {}", style(line).dim());
    }
}

/// Print a success message: ✓ text
pub fn success(text: &str) {
    println!("  {} {}", style("✓").green().bold(), text);
}

/// Print a warning message.
pub fn warn(text: &str) {
    println!("  {} {}", style("⚠").yellow(), text);
}

/// Print an error message.
pub fn error(text: &str) {
    println!("  {} {}", style("✗").red().bold(), text);
}

/// Print a status line: service  ● running  detail
pub fn service_status(name: &str, running: bool, detail: &str) {
    let (indicator, status_text) = if running {
        (style("●").green().bold(), style("running").green())
    } else {
        (style("○").dim(), style("stopped").dim())
    };
    println!(
        "    {:<10}{} {:<12}{}",
        name, indicator, status_text, style(detail).dim()
    );
}

/// Print a config item: ● name   value (provider)
pub fn config_item(name: &str, value: &str, detail: &str) {
    println!(
        "    {} {:<12}{} {}",
        style("●").cyan(),
        style(name).bold(),
        value,
        style(format!("({})", detail)).dim()
    );
}

/// Print a blank line.
pub fn blank() {
    println!();
}

/// Print the welcome banner.
pub fn welcome() {
    println!();
    println!(
        "  {}",
        style("Welcome to TENEX!").bold()
    );
    println!(
        "  {}",
        style("Let's get you set up.").dim()
    );
    println!();
}

/// Print the dashboard greeting.
pub fn dashboard_greeting() {
    println!();
    println!(
        "  {}",
        style("Hey! Here's what's running:").bold()
    );
    println!();
}

/// Mask an API key for display: sk-ant-•••••7f2
pub fn mask_key(key: &str) -> String {
    if key.len() <= 8 {
        return "•".repeat(key.len());
    }
    let prefix_len = key.find('-').map(|i| i + 1).unwrap_or(3).min(8);
    let suffix_len = 3;
    let prefix = &key[..prefix_len.min(key.len())];
    let suffix = &key[key.len().saturating_sub(suffix_len)..];
    format!("{}•••••{}", prefix, suffix)
}
```

**Step 2: Verify it compiles**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo check -p tenex-launcher-tui 2>&1 | head -5`
Note: This won't compile yet because main.rs still references old modules. That's fine — we're building incrementally.

**Step 3: Commit**

```bash
git add crates/tenex-launcher-tui/src/display.rs
git commit -m "feat(tui): add display.rs styled output helpers"
```

---

### Task 4: Replace main.rs, Create repl.rs — Core REPL Loop

**Files:**
- Rewrite: `crates/tenex-launcher-tui/src/main.rs`
- Create: `crates/tenex-launcher-tui/src/repl.rs`
- Delete: `crates/tenex-launcher-tui/src/app.rs`
- Delete: `crates/tenex-launcher-tui/src/render.rs`
- Delete: `crates/tenex-launcher-tui/src/input.rs`
- Delete: `crates/tenex-launcher-tui/src/runtime.rs`
- Delete: `crates/tenex-launcher-tui/src/ui/` (entire directory)

**Step 1: Delete old modules**

Remove all the ratatui-based files:
```bash
rm crates/tenex-launcher-tui/src/app.rs
rm crates/tenex-launcher-tui/src/render.rs
rm crates/tenex-launcher-tui/src/input.rs
rm crates/tenex-launcher-tui/src/runtime.rs
rm -rf crates/tenex-launcher-tui/src/ui/
```

**Step 2: Rewrite main.rs**

```rust
mod dashboard;
mod display;
mod onboarding;
mod repl;
mod settings;

use anyhow::Result;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .with_target(false)
        .init();

    let force_onboarding = std::env::args().nth(1).as_deref() == Some("onboard");
    repl::run(force_onboarding).await
}
```

**Step 3: Create repl.rs**

```rust
use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;

use crate::dashboard;
use crate::onboarding;

pub async fn run(force_onboarding: bool) -> Result<()> {
    let config_store = Arc::new(ConfigStore::new());
    let needs_onboarding = force_onboarding || config_store.needs_onboarding();

    if needs_onboarding {
        onboarding::run(&config_store).await?;
    }

    let daemon = Arc::new(DaemonManager::new(None));
    let relay = Arc::new(RelayManager::new(None, config_store.clone()));
    let ngrok = Arc::new(NgrokManager::new());

    dashboard::run(&config_store, &daemon, &relay, &ngrok).await
}
```

**Step 4: Create stub onboarding.rs**

```rust
use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;

use crate::display;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    display::welcome();
    display::success("Onboarding complete! (stub)");
    Ok(())
}
```

**Step 5: Create stub dashboard.rs**

```rust
use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;

use crate::display;

pub async fn run(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) -> Result<()> {
    display::dashboard_greeting();
    println!("  Dashboard coming soon.");
    Ok(())
}
```

**Step 6: Create stub settings.rs**

```rust
use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    println!("  Settings coming soon.");
    Ok(())
}
```

**Step 7: Verify it compiles and runs**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo build -p tenex-launcher-tui 2>&1 | tail -5`
Expected: BUILD SUCCESS

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo run -p tenex-launcher-tui -- onboard 2>&1`
Expected: Prints welcome message, "Onboarding complete! (stub)", then dashboard stub.

**Step 8: Commit**

```bash
git add -A crates/tenex-launcher-tui/src/
git commit -m "feat(tui): replace ratatui with REPL skeleton"
```

---

### Task 5: Onboarding Steps 1-2 (Identity + OpenClaw)

**Files:**
- Modify: `crates/tenex-launcher-tui/src/onboarding.rs`

**Step 1: Implement identity step**

```rust
use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, Input, Password, Select};
use tenex_orchestrator::config::{ConfigStore, ProviderEntry, TenexConfig, TenexProviders};
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

    // ... remaining steps added in subsequent tasks

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
        .with_prompt(format!("{} How do you want to authenticate?", style("?").blue().bold()))
        .items(&choices)
        .default(0)
        .interact()?;

    if selection == 0 {
        // Generate new keypair
        // For now, generate a random private key hex string
        // In production this would use nostr key generation
        use std::fmt::Write;
        let mut rng_bytes = [0u8; 32];
        getrandom::getrandom(&mut rng_bytes).map_err(|e| anyhow::anyhow!("RNG failed: {}", e))?;
        let mut hex = String::with_capacity(64);
        for b in &rng_bytes {
            write!(hex, "{:02x}", b).unwrap();
        }
        config.tenex_private_key = Some(hex.clone());
        config.whitelisted_pubkeys = Some(vec![]);
        store.save_config(config)?;
        display::success(&format!("Generated new keypair. Private key saved."));
    } else {
        let nsec: String = Password::new()
            .with_prompt(format!("{} Enter your nsec", style("?").blue().bold()))
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
        .with_prompt(format!("{} Import credentials?", style("?").blue().bold()))
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
```

**Step 2: Add `getrandom` dependency for key generation**

Add to `crates/tenex-launcher-tui/Cargo.toml`:
```toml
getrandom = "0.2"
```

And to workspace `Cargo.toml`:
```toml
getrandom = "0.2"
```

**Step 3: Verify it compiles**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo check -p tenex-launcher-tui`
Expected: Compiles.

**Step 4: Commit**

```bash
git add crates/tenex-launcher-tui/src/onboarding.rs Cargo.toml crates/tenex-launcher-tui/Cargo.toml
git commit -m "feat(onboarding): implement identity and openclaw import steps"
```

---

### Task 6: Onboarding Steps 3-5 (Relay + Providers + LLMs)

**Files:**
- Modify: `crates/tenex-launcher-tui/src/onboarding.rs`

**Step 1: Add relay step to onboarding.rs**

```rust
fn step_relay(
    config: &mut TenexConfig,
    launcher: &mut tenex_orchestrator::config::LauncherConfig,
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
        .with_prompt(format!("{} How should TENEX connect to Nostr?", style("?").blue().bold()))
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
```

**Step 2: Add providers step**

```rust
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
            let name = display_names.get(id.as_str()).copied().unwrap_or(id.as_str());
            let masked = display::mask_key(entry.primary_key().unwrap_or("none"));
            println!("    {} {:<16}{}", style("✓").green(), name, style(masked).dim());
        }
        display::blank();
    }

    loop {
        let mut choices = vec!["Skip — looks good".to_string()];
        for &provider_id in provider::PROVIDER_LIST_ORDER {
            if !providers.providers.contains_key(provider_id) {
                let name = display_names.get(provider_id).copied().unwrap_or(provider_id);
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
                    display_names.get(provider_id).copied().unwrap_or(provider_id)
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
        let name = display_names.get(provider_id).copied().unwrap_or(provider_id);
        display::success(&format!("{} connected.", name));
    }

    store.save_providers(providers)?;
    Ok(())
}
```

**Step 3: Add LLMs step**

```rust
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
            .with_prompt(format!("{} Continue with these defaults?", style("?").blue().bold()))
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
```

**Step 4: Wire steps into the `run()` function**

Update the `run()` function in `onboarding.rs` to call steps 3-5 after steps 1-2:

```rust
    // Step 3: Relay
    step_relay(&mut config, &mut launcher, config_store)?;
    sm.next();

    // Step 4: Providers
    step_providers(&mut providers, config_store).await?;
    sm.next();

    // Step 5: LLMs
    step_llms(&providers, config_store)?;
    sm.next();
```

**Step 5: Verify it compiles**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo check -p tenex-launcher-tui`

**Step 6: Commit**

```bash
git add crates/tenex-launcher-tui/src/onboarding.rs
git commit -m "feat(onboarding): implement relay, providers, and LLMs steps"
```

---

### Task 7: Onboarding Steps 6-8 (Project + Agents + Nudges)

**Files:**
- Modify: `crates/tenex-launcher-tui/src/onboarding.rs`

These steps need Nostr connectivity to query kind 4199/4201/4202 events. Since the orchestrator crate doesn't have a Nostr client, these steps will be implemented as skippable stubs that print educational context and offer to skip. Full Nostr integration is a follow-up task.

**Step 1: Add project creation step (stub)**

```rust
fn step_first_project(config: &TenexConfig, store: &Arc<ConfigStore>) -> Result<()> {
    display::section("Your First Project");
    display::context("TENEX organizes work into projects. Each project is a container");
    display::context("for a team of AI agents focused on a shared concern.");
    display::context("Agents can belong to multiple projects and collaborate across them.");
    display::blank();
    display::context("We recommend starting with a \"Meta\" project — a project about");
    display::context("managing your other projects. Think of it as your command center.");
    display::blank();

    let create = Confirm::new()
        .with_prompt(format!("{} Create your Meta project?", style("?").blue().bold()))
        .default(true)
        .interact()?;

    if create {
        // Project creation requires publishing a kind 31933 Nostr event.
        // This needs the daemon running with Nostr connectivity.
        // For now, we note the intent and the daemon will create it on first start.
        let projects_base = config
            .projects_base
            .clone()
            .unwrap_or_else(|| {
                dirs::home_dir()
                    .unwrap_or_default()
                    .join("tenex")
                    .to_string_lossy()
                    .into()
            });
        let meta_dir = std::path::Path::new(&projects_base).join("meta");
        std::fs::create_dir_all(&meta_dir).ok();
        display::success("Created project \"meta\". The daemon will publish it to Nostr on first start.");
    } else {
        display::context("You can create projects later from the dashboard.");
    }

    Ok(())
}
```

**Step 2: Add agent hiring step (stub)**

```rust
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
```

**Step 3: Add nudges & skills step (stub)**

```rust
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
```

**Step 4: Add the done summary step**

```rust
fn step_done(config: &TenexConfig, providers: &TenexProviders) -> Result<()> {
    display::section("Done");
    display::blank();

    // Summary
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
        println!("  {:<16}{}", style("Providers:").dim(), provider_names.join(", "));
    }

    display::blank();
    display::success("Setup complete! Starting dashboard...");
    display::blank();
    Ok(())
}
```

**Step 5: Wire steps 6-9 into `run()`**

```rust
    // Step 6: First Project
    step_first_project(&config, config_store)?;
    sm.next();

    // Step 7: Hire Agents (stub)
    step_hire_agents()?;
    sm.next();

    // Step 8: Nudges & Skills (stub)
    step_nudges_skills()?;
    sm.next();

    // Step 9: Done
    step_done(&config, &providers)?;
```

**Step 6: Verify it compiles and runs**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo run -p tenex-launcher-tui -- onboard`
Expected: Full onboarding flow with all 9 steps visible.

**Step 7: Commit**

```bash
git add crates/tenex-launcher-tui/src/onboarding.rs
git commit -m "feat(onboarding): add project creation, agent hiring, nudges steps (stubs)"
```

---

### Task 8: Dashboard — Status Display + Action Menu

**Files:**
- Modify: `crates/tenex-launcher-tui/src/dashboard.rs`

**Step 1: Implement the dashboard loop**

```rust
use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::Select;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;
use tenex_orchestrator::process::{ProcessManager, ProcessStatus};

use crate::display;
use crate::settings;

enum Action {
    Status,
    Services,
    Settings,
    Quit,
}

pub async fn run(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) -> Result<()> {
    loop {
        print_status(config_store, daemon, relay, ngrok);

        let choices = vec![
            "Check status",
            "Start/stop services",
            "Settings",
            "Quit",
        ];
        let selection = Select::new()
            .with_prompt(format!("{} What do you want to do?", style("?").blue().bold()))
            .items(&choices)
            .default(0)
            .interact_opt()?;

        match selection {
            Some(0) => continue,
            Some(1) => handle_services(daemon, relay, ngrok).await?,
            Some(2) => settings::run(config_store).await?,
            Some(3) | None => break,
            _ => continue,
        }
    }

    Ok(())
}

fn print_status(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) {
    display::dashboard_greeting();

    let config = config_store.load_config();
    let relay_url = config
        .relays
        .as_ref()
        .and_then(|r| r.first())
        .map(|s| s.as_str())
        .unwrap_or("not configured");

    display::service_status(
        "daemon",
        daemon.status() == ProcessStatus::Running,
        &format_process_detail(daemon.status()),
    );
    display::service_status(
        "relay",
        relay.status() == ProcessStatus::Running,
        relay_url,
    );
    display::service_status(
        "ngrok",
        ngrok.status() == ProcessStatus::Running,
        if ngrok.status() == ProcessStatus::Running {
            "tunnel active"
        } else {
            "start it to expose your agent"
        },
    );
    display::blank();
}

fn format_process_detail(status: ProcessStatus) -> String {
    match status {
        ProcessStatus::Running => "pid active".into(),
        ProcessStatus::Starting => "starting...".into(),
        ProcessStatus::Stopped => "not running".into(),
        ProcessStatus::Failed => "failed — check logs".into(),
    }
}

async fn handle_services(
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) -> Result<()> {
    let services: Vec<(&str, ProcessStatus, &Arc<dyn ProcessManager>)> = vec![
        ("daemon", daemon.status(), daemon as &Arc<dyn ProcessManager>),
        ("relay", relay.status(), relay as &Arc<dyn ProcessManager>),
        ("ngrok", ngrok.status(), ngrok as &Arc<dyn ProcessManager>),
    ];

    let choices: Vec<String> = services
        .iter()
        .map(|(name, status, _)| format!("{} — currently {}", name, status))
        .collect();

    let selection = Select::new()
        .with_prompt(format!("{} Which service?", style("?").blue().bold()))
        .items(&choices)
        .interact_opt()?;

    let Some(idx) = selection else {
        return Ok(());
    };

    let (name, status, manager) = &services[idx];

    match status {
        ProcessStatus::Running => {
            let stop = dialoguer::Confirm::new()
                .with_prompt(format!("{} Stop {}?", style("?").blue().bold(), name))
                .default(false)
                .interact()?;
            if stop {
                let spinner = indicatif::ProgressBar::new_spinner();
                spinner.set_message(format!("Stopping {}...", name));
                spinner.enable_steady_tick(std::time::Duration::from_millis(80));
                manager.stop().await?;
                spinner.finish_and_clear();
                display::success(&format!("{} stopped.", name));
            }
        }
        _ => {
            let start = dialoguer::Confirm::new()
                .with_prompt(format!("{} Start {}?", style("?").blue().bold(), name))
                .default(true)
                .interact()?;
            if start {
                let spinner = indicatif::ProgressBar::new_spinner();
                spinner.set_message(format!("Starting {}...", name));
                spinner.enable_steady_tick(std::time::Duration::from_millis(80));
                manager.start().await?;
                spinner.finish_and_clear();
                display::success(&format!("{} started.", name));
            }
        }
    }

    Ok(())
}
```

Note: The `services` vec with trait objects may need adjustment depending on how `ProcessManager` trait is implemented. If the Arc types don't coerce cleanly, use three separate blocks with an if/else chain instead.

**Step 2: Verify it compiles**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo check -p tenex-launcher-tui`

**Step 3: Commit**

```bash
git add crates/tenex-launcher-tui/src/dashboard.rs
git commit -m "feat(tui): implement dashboard with status display and action menu"
```

---

### Task 9: Settings — Grouped Menu + Provider Settings

**Files:**
- Modify: `crates/tenex-launcher-tui/src/settings.rs`

**Step 1: Implement the grouped settings menu**

```rust
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
            format!("{}",          style("── AI ──").dim()),
            "  Providers       — API keys and connections".into(),
            "  LLMs            — Model configurations".into(),
            "  Roles           — Which model handles what task".into(),
            "  Embeddings      — Text embedding model".into(),
            "  Image Gen       — Image generation model".into(),
            format!("{}",          style("── Agents ──").dim()),
            "  Escalation      — Route ask() through an agent first".into(),
            "  Intervention    — Auto-review when you're idle".into(),
            format!("{}",          style("── Network ──").dim()),
            "  Relays          — Nostr relay connections".into(),
            "  Local Relay     — Run a relay on this machine".into(),
            format!("{}",          style("── Conversations ──").dim()),
            "  Compression     — Token limits and sliding window".into(),
            "  Summarization   — Auto-summary timing".into(),
            format!("{}",          style("── Advanced ──").dim()),
            "  Identity        — Authorized pubkeys".into(),
            "  System Prompt   — Global prompt for all projects".into(),
            "  Logging         — Log level and file path".into(),
            "  Telemetry       — OpenTelemetry tracing".into(),
            "  ↩ Back to dashboard".into(),
        ];

        let selection = Select::new()
            .with_prompt(format!("{} What would you like to configure?", style("?").blue().bold()))
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
            let name = display_names.get(id.as_str()).copied().unwrap_or(id.as_str());
            let masked = display::mask_key(entry.primary_key().unwrap_or("none"));
            println!("    {} {:<16}{}", style("✓").green(), name, style(masked).dim());
        }
    }
    display::blank();

    let choices = vec!["Add a provider", "Remove a provider", "Back"];
    let selection = Select::new()
        .with_prompt(format!("{} What do you want to do?", style("?").blue().bold()))
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
                .with_prompt(format!("{} Which provider?", style("?").blue().bold()))
                .items(&names)
                .interact_opt()?;

            if let Some(idx) = sel {
                let provider_id = available[idx];
                if provider::requires_api_key(provider_id) {
                    let key: String = Password::new()
                        .with_prompt(format!("{} API key", style("?").blue().bold()))
                        .interact()?;
                    providers.providers.insert(
                        provider_id.to_string(),
                        ProviderEntry::new(key),
                    );
                } else {
                    providers.providers.insert(
                        provider_id.to_string(),
                        ProviderEntry::new("none"),
                    );
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
                .map(|id| display_names.get(id.as_str()).copied().unwrap_or(id.as_str()))
                .collect();

            let sel = Select::new()
                .with_prompt(format!("{} Remove which provider?", style("?").blue().bold()))
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
```

**Step 2: Add stub implementations for remaining settings categories**

Each settings function follows the same pattern: load config → display current state → offer actions → save. Implement each as a minimal but functional handler:

```rust
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
            format!("{:<20} currently: {}", name, current.unwrap_or("(not set)"))
        })
        .collect();
    role_choices.push("Back".into());

    let sel = Select::new()
        .with_prompt(format!("{} Edit a role assignment?", style("?").blue().bold()))
        .items(&role_choices)
        .interact_opt()?;

    if let Some(idx) = sel {
        if idx < role_names.len() {
            let mut model_choices = config_names.clone();
            model_choices.push("(unset)".into());
            let model_sel = Select::new()
                .with_prompt(format!("{} Assign {} to which model?", style("?").blue().bold(), role_names[idx]))
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
        println!("  Aspect ratio: {}    Size: {}", ar, image.default_image_size.as_deref().unwrap_or("(not set)"));
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
            .with_prompt(format!("{} Default aspect ratio", style("?").blue().bold()))
            .items(&ratios)
            .default(0)
            .interact_opt()?;

        if let Some(ridx) = ratio_sel {
            image.default_aspect_ratio = Some(ratios[ridx].to_string());
        }

        let sizes = vec!["1K", "2K", "4K"];
        let size_sel = Select::new()
            .with_prompt(format!("{} Default image size", style("?").blue().bold()))
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
        .with_prompt(format!("{} Agent slug (empty to disable)", style("?").blue().bold()))
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
        .with_prompt(format!("{} Enable intervention?", style("?").blue().bold()))
        .default(intervention.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let agent: String = Input::new()
            .with_prompt(format!("{} Agent slug", style("?").blue().bold()))
            .default(intervention.agent.unwrap_or_default())
            .interact_text()?;

        let timeout: String = Input::new()
            .with_prompt(format!("{} Review timeout (ms)", style("?").blue().bold()))
            .default(intervention.review_timeout.unwrap_or(300000).to_string())
            .interact_text()?;

        let skip_within: String = Input::new()
            .with_prompt(format!("{} Skip if active within (seconds)", style("?").blue().bold()))
            .default(intervention.skip_if_active_within.unwrap_or(120).to_string())
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
        .with_prompt(format!("{} What do you want to do?", style("?").blue().bold()))
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match sel {
        Some(0) => {
            let url: String = Input::new()
                .with_prompt(format!("{} Relay URL (ws:// or wss://)", style("?").blue().bold()))
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
                    .with_prompt(format!("{} Remove which relay?", style("?").blue().bold()))
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
        .with_prompt(format!("{} Enable local relay?", style("?").blue().bold()))
        .default(lr.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let port: String = Input::new()
            .with_prompt(format!("{} Port", style("?").blue().bold()))
            .default(lr.port.unwrap_or(7777).to_string())
            .interact_text()?;

        let ngrok = Confirm::new()
            .with_prompt(format!("{} Enable ngrok tunnel?", style("?").blue().bold()))
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
    println!("  Token threshold: {}", comp.token_threshold.unwrap_or(50000));
    println!("  Token budget: {}", comp.token_budget.unwrap_or(40000));
    println!("  Sliding window: {} messages", comp.sliding_window_size.unwrap_or(50));
    display::blank();

    let enabled = Confirm::new()
        .with_prompt(format!("{} Enable compression?", style("?").blue().bold()))
        .default(comp.enabled.unwrap_or(true))
        .interact()?;

    if enabled {
        let threshold: String = Input::new()
            .with_prompt(format!("{} Token threshold", style("?").blue().bold()))
            .default(comp.token_threshold.unwrap_or(50000).to_string())
            .interact_text()?;

        let budget: String = Input::new()
            .with_prompt(format!("{} Token budget", style("?").blue().bold()))
            .default(comp.token_budget.unwrap_or(40000).to_string())
            .interact_text()?;

        let window: String = Input::new()
            .with_prompt(format!("{} Sliding window size", style("?").blue().bold()))
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
        .with_prompt(format!("{} Inactivity timeout (ms)", style("?").blue().bold()))
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
        .with_prompt(format!("{} What do you want to do?", style("?").blue().bold()))
        .items(&choices)
        .default(0)
        .interact_opt()?;

    match sel {
        Some(0) => {
            let pk: String = Input::new()
                .with_prompt(format!("{} Pubkey (hex or npub)", style("?").blue().bold()))
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
                    .with_prompt(format!("{} Remove which pubkey?", style("?").blue().bold()))
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
    println!(
        "  Enabled: {}",
        prompt.enabled.unwrap_or(false)
    );
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
        .with_prompt(format!("{} Enable global system prompt?", style("?").blue().bold()))
        .default(prompt.enabled.unwrap_or(false))
        .interact()?;

    if enabled {
        let content: String = Input::new()
            .with_prompt(format!("{} System prompt text", style("?").blue().bold()))
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
        telemetry.service_name.as_deref().unwrap_or("tenex-daemon")
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
        .with_prompt(format!("{} Enable telemetry?", style("?").blue().bold()))
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
```

**Step 3: Verify it compiles**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo check -p tenex-launcher-tui`

**Step 4: Commit**

```bash
git add crates/tenex-launcher-tui/src/settings.rs
git commit -m "feat(tui): implement grouped settings with all 15 categories"
```

---

### Task 10: Integration — Full End-to-End Test

**Files:** No new files — manual testing.

**Step 1: Build the full binary**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && cargo build -p tenex-launcher-tui`
Expected: BUILD SUCCESS with no errors.

**Step 2: Run the onboarding flow**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && TENEX_BASE_DIR=/tmp/tenex-test cargo run -p tenex-launcher-tui -- onboard`
Expected: Walks through all 9 onboarding steps interactively.

**Step 3: Verify config files were created**

Run: `ls -la /tmp/tenex-test/`
Expected: `config.json`, `providers.json`, `llms.json` exist.

Run: `cat /tmp/tenex-test/config.json | python3 -m json.tool`
Expected: Valid JSON with relay config, private key, etc.

**Step 4: Run the dashboard**

Run: `cd /Users/pablofernandez/Work/tenex-chat-package && TENEX_BASE_DIR=/tmp/tenex-test cargo run -p tenex-launcher-tui`
Expected: Shows dashboard with service status and action menu (no onboarding since config exists).

**Step 5: Navigate to Settings > Providers, verify add/remove works**

**Step 6: Clean up test data**

Run: `rm -rf /tmp/tenex-test`

**Step 7: Final commit**

```bash
git add -A
git commit -m "feat(tui): complete REPL launcher with onboarding, dashboard, and settings"
```

---

## Follow-Up Tasks (Not In This Plan)

These require additional dependencies and are separate work items:

1. **Nostr connectivity for onboarding steps 6-8** — Add `nostr-sdk` to query kind 4199/4201/4202, implement real project creation (kind 31933), agent hiring, nudge/skill whitelisting.

2. **LLM settings full editing** — Add/edit/remove individual standard and meta LLM configurations with all fields (temperature, maxTokens, topP, reasoningEffort, meta variants).

3. **Service auto-start on dashboard entry** — Optionally start daemon and relay when entering the dashboard for the first time after onboarding.

4. **Nostr key generation** — Use proper `nostr` crate for keypair generation instead of raw random bytes. Convert between nsec/npub formats.
