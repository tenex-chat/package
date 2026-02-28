use std::fs;
use std::process::{Command as SysCommand, Stdio};
use std::sync::Arc;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, MultiSelect, Select};
use indicatif::{ProgressBar, ProgressStyle};
use tenex_orchestrator::config::{
    ConfigStore, LauncherConfig, LocalRelayConfig, TenexConfig, TenexProviders,
};
use tenex_orchestrator::process::relay::RelayManager;
use tenex_orchestrator::process::ProcessManager;
use tenex_orchestrator::provider;

use crate::display;
use crate::nostr::{self, FetchResults};
use crate::ui;

/// Maximum items to show in a MultiSelect list before truncating.
const MAX_LIST_ITEMS: usize = 30;

/// npm package name for the TENEX backend CLI.
const BACKEND_PACKAGE: &str = "@tenex-chat/backend";

/// Binary name installed by the backend package.
const BACKEND_BIN: &str = "tenex-backend";

/// Bind to port 0 to let the OS assign an available port, then return it.
fn find_available_port() -> Result<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

/// Display the mobile pairing QR code.
/// Reads nsec from config, constructs the pairing URL, and renders the QR code.
/// Returns Ok(true) if QR was shown, Ok(false) if data was insufficient.
pub fn show_mobile_pairing(config_store: &Arc<ConfigStore>) -> Result<bool> {
    use nostr_sdk::ToBech32;

    let config = config_store.load_config();
    let launcher = config_store.load_launcher();

    let privkey_hex = match &config.tenex_private_key {
        Some(hex) => hex,
        None => {
            display::context("No identity configured — can't generate pairing code.");
            return Ok(false);
        }
    };
    let keys = nostr_sdk::Keys::parse(privkey_hex)
        .map_err(|e| anyhow::anyhow!("Invalid private key: {}", e))?;
    let nsec = keys.secret_key().to_bech32().expect("bech32 encoding");

    let relay = config
        .relays
        .as_ref()
        .and_then(|r| r.first())
        .cloned()
        .unwrap_or_default();

    if relay.is_empty() {
        display::context("No relay configured — can't generate pairing code.");
        return Ok(false);
    }

    let is_loopback = relay.contains("localhost") || relay.contains("127.0.0.1") || relay.contains("::1");
    let ngrok_url = launcher
        .local_relay
        .as_ref()
        .and_then(|lr| lr.ngrok_url.clone());

    let pairing_relay = if is_loopback {
        if let Some(url) = ngrok_url {
            url
        } else {
            display::context("Your relay is on localhost — mobile devices can't reach it.");
            display::hint("Enable ngrok in Settings > Local Relay to make it accessible.");
            return Ok(false);
        }
    } else {
        relay
    };

    let backend = launcher.tenex_public_key.as_deref().unwrap_or("");

    let mut url = format!("https://tenex.chat/signin?nsec={}", nsec);
    url.push_str(&format!("&relay={}", pairing_relay));
    if !backend.is_empty() {
        url.push_str(&format!("&backend={}", backend));
    }

    display::blank();
    display::qr_code(&url);
    display::blank();
    display::context("Scan this QR code with the TENEX mobile app to pair.");
    display::context("\u{26a0} This QR code contains your private key. Do not share it.");
    display::blank();

    Ok(true)
}

fn find_bun() -> Option<String> {
    for c in &["/opt/homebrew/bin/bun", "/usr/local/bin/bun"] {
        if std::path::Path::new(c).exists() {
            return Some(c.to_string());
        }
    }
    if let Some(home) = dirs::home_dir() {
        let bun_home = home.join(".bun/bin/bun");
        if bun_home.exists() {
            return Some(bun_home.to_string_lossy().into());
        }
    }
    None
}

fn ensure_bun() -> Result<String> {
    if let Some(bun) = find_bun() {
        return Ok(bun);
    }

    display::blank();
    display::context("TENEX requires Bun to run its backend.");
    display::blank();
    display::hint("Install it with:");
    println!(
        "    {}",
        style("curl -fsSL https://bun.sh/install | bash").color256(display::ACCENT)
    );
    display::blank();

    let theme = display::theme();
    loop {
        let _ = ui::prompt(|| {
            Confirm::with_theme(&theme)
                .with_prompt("Press Enter once Bun is installed")
                .default(true)
                .interact()
        })?;

        if let Some(bun) = find_bun() {
            display::success("Bun found.");
            return Ok(bun);
        }
        display::context("Still can't find Bun. Make sure the install completed.");
    }
}

fn spawn_backend_install(bun: &str) -> Option<tokio::task::JoinHandle<Result<()>>> {
    let bun = bun.to_string();
    Some(tokio::spawn(async move {
        let status = tokio::process::Command::new(&bun)
            .args(["install", "-g", &format!("{}@latest", BACKEND_PACKAGE)])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await?;

        if !status.success() {
            anyhow::bail!("bun install -g {} failed", BACKEND_PACKAGE);
        }
        Ok(())
    }))
}

async fn await_backend_install(handle: Option<tokio::task::JoinHandle<Result<()>>>) {
    let handle = match handle {
        Some(h) => h,
        None => return,
    };

    if !handle.is_finished() {
        let sp = spinner();
        sp.set_message("Installing backend tools...");
        let result = handle.await;
        sp.finish_and_clear();
        match result {
            Ok(Ok(())) => {
                display::success("Backend tools installed.");
            }
            Ok(Err(e)) => {
                tracing::warn!("Backend install failed: {}", e);
                display::context("Backend install failed — agent import may not work.");
            }
            Err(e) => {
                tracing::warn!("Backend install task panicked: {}", e);
            }
        }
        return;
    }

    match handle.await {
        Ok(Err(e)) => {
            tracing::warn!("Backend install failed: {}", e);
        }
        Err(e) => {
            tracing::warn!("Backend install task panicked: {}", e);
        }
        _ => {}
    }
}

pub async fn run(config_store: &Arc<ConfigStore>, backend_override: Option<&str>) -> Result<ClientChoice> {
    display::welcome();

    // 1. Ensure bun is available and kick off background backend install
    let backend_handle = if backend_override.is_some() {
        None
    } else {
        let bun = ensure_bun()?;
        spawn_backend_install(&bun)
    };

    // 2. Pre-start local relay on a random port
    let relay_port = find_available_port()?;
    let repo_root = tenex_orchestrator::process::detect_repo_root();
    let relay = RelayManager::new(repo_root, config_store.clone());
    relay.configure(relay_port, vec!["wss://tenex.chat".into()]).await;

    let relay_url = format!("ws://127.0.0.1:{}", relay_port);
    let relay_started = {
        let sp = spinner();
        sp.set_message("Starting local relay...");
        match relay.start().await {
            Ok(()) => {
                sp.finish_and_clear();
                display::success(&format!("Local relay running on port {}.", relay_port));
                true
            }
            Err(e) => {
                sp.finish_and_clear();
                tracing::warn!("Relay failed to start: {}", e);
                false
            }
        }
    };

    // 3. Delegate to backend: standalone mode handles Identity, OpenClaw, Relay,
    //    Providers, LLMs, ProjectAndAgents
    await_backend_install(backend_handle).await;

    step_delegate_to_backend(
        backend_override,
        if relay_started { Some(&relay_url) } else { None },
    )?;

    // 4. Reload everything the backend wrote
    let config = config_store.load_config();
    let providers = config_store.load_providers();
    let mut launcher = config_store.load_launcher();

    // 5. Determine if user chose local relay
    let chose_local = config
        .relays
        .as_ref()
        .and_then(|r| r.first())
        .map(|url| url.contains("localhost") || url.contains("127.0.0.1"))
        .unwrap_or(false);

    // 6. Set up launcher local_relay config or stop relay
    if chose_local {
        launcher.local_relay = Some(LocalRelayConfig {
            enabled: Some(true),
            auto_start: Some(true),
            port: Some(relay_port),
            sync_relays: Some(vec!["wss://tenex.chat".into()]),
            ngrok_enabled: Some(false),
            ngrok_url: None,
            nip42_auth: Some(true),
        });
    } else if relay_started {
        let sp = spinner();
        sp.set_message("Stopping local relay...");
        let _ = relay.stop().await;
        sp.finish_and_clear();
    }

    // 7. Derive keys from config and seed client preferences
    if let Some(privkey_hex) = &config.tenex_private_key {
        if let Ok(keys) = nostr_sdk::Keys::parse(privkey_hex) {
            launcher.tenex_public_key = Some(keys.public_key().to_hex());
            seed_client_preferences(config_store, &keys);
        }
    }
    config_store.save_launcher(&launcher)?;

    // 8. Connect to Nostr and fetch nudges/skills
    let relay_urls = config.relays.clone().unwrap_or_default();
    let fetch_keys = config
        .tenex_private_key
        .as_ref()
        .and_then(|hex| nostr_sdk::Keys::parse(hex).ok());

    let nostr_client = if !relay_urls.is_empty() {
        match nostr::connect(&relay_urls, fetch_keys).await {
            Ok(c) => Some(c),
            Err(e) => {
                tracing::warn!("Failed to connect to relays: {}", e);
                None
            }
        }
    } else {
        None
    };

    let fetched = if let Some(ref client) = nostr_client {
        let sp = spinner();
        sp.set_message("Fetching nudges & skills...");
        let result = nostr::fetch_events(client).await;
        sp.finish_and_clear();
        match result {
            Ok(f) => Some(f),
            Err(e) => {
                tracing::warn!("Nostr fetch failed: {}", e);
                None
            }
        }
    } else {
        None
    };

    let total_steps = 3;

    // 9. Nudges & Skills
    step_nudges_skills(
        &mut launcher,
        config_store,
        &fetched,
        1,
        total_steps,
    )?;

    // 10. Launch client + mobile pairing
    let client_choice = step_launch_client(config_store, 2, total_steps)?;

    // 11. Done
    step_done(&config, &providers, &launcher)?;

    if let Some(client) = nostr_client {
        let _ = tokio::time::timeout(
            std::time::Duration::from_secs(3),
            client.disconnect(),
        )
        .await;
    }

    Ok(client_choice)
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

/// Write the nsec into the TUI's preferences so `tenex-tui` can auto-login.
/// Seed credentials and pre-approve the backend in all client preference files.
///
/// Writes to:
///   `~/.tenex/cli/preferences.json` — TUI/REPL client
///   `~/Library/Application Support/tenex/nostrdb/ios_preferences.json` — iOS/FFI (macOS only)
fn seed_client_preferences(store: &ConfigStore, keys: &nostr_sdk::Keys) {
    use nostr_sdk::ToBech32;

    let nsec = keys.secret_key().to_bech32().expect("bech32 nsec");
    let backend_pubkey = keys.public_key().to_hex();

    // ── TUI/REPL preferences ────────────────────────────────────────────────
    let cli_dir = store.base_dir().join("cli");
    if fs::create_dir_all(&cli_dir).is_err() {
        tracing::warn!("Could not create TUI config dir: {}", cli_dir.display());
        return;
    }

    let prefs_path = cli_dir.join("preferences.json");
    let mut prefs: serde_json::Value = fs::read_to_string(&prefs_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| serde_json::json!({}));

    prefs["stored_credentials"] = serde_json::Value::String(nsec);
    merge_approved_backend(&mut prefs, &backend_pubkey);

    match fs::write(&prefs_path, serde_json::to_string_pretty(&prefs).unwrap()) {
        Ok(()) => tracing::info!("Seeded TUI preferences at {}", prefs_path.display()),
        Err(e) => tracing::warn!("Failed to write TUI preferences: {}", e),
    }

    // ── iOS/FFI preferences (macOS only) ────────────────────────────────────
    #[cfg(target_os = "macos")]
    {
        if let Some(data_dir) = dirs::data_dir() {
            let ffi_dir = data_dir.join("tenex").join("nostrdb");
            if fs::create_dir_all(&ffi_dir).is_ok() {
                let ffi_path = ffi_dir.join("ios_preferences.json");
                let mut ffi_prefs: serde_json::Value = fs::read_to_string(&ffi_path)
                    .ok()
                    .and_then(|s| serde_json::from_str(&s).ok())
                    .unwrap_or_else(|| serde_json::json!({}));

                merge_approved_backend(&mut ffi_prefs, &backend_pubkey);

                match fs::write(&ffi_path, serde_json::to_string_pretty(&ffi_prefs).unwrap()) {
                    Ok(()) => tracing::info!("Seeded iOS preferences at {}", ffi_path.display()),
                    Err(e) => tracing::warn!("Failed to write iOS preferences: {}", e),
                }
            }
        }
    }
}

/// Add a backend pubkey to the `approved_backend_pubkeys` array in a preferences JSON value,
/// avoiding duplicates.
fn merge_approved_backend(prefs: &mut serde_json::Value, pubkey: &str) {
    let arr = prefs["approved_backend_pubkeys"]
        .as_array()
        .cloned()
        .unwrap_or_default();

    let pubkey_val = serde_json::Value::String(pubkey.to_string());
    if !arr.contains(&pubkey_val) {
        let mut arr = arr;
        arr.push(pubkey_val);
        prefs["approved_backend_pubkeys"] = serde_json::Value::Array(arr);
    }
}

/// Delegate all core setup to the backend's standalone flow.
///
/// Spawns `tenex-backend setup init [--local-relay-url <url>]`
/// with inherited stdio for interactive terminal passthrough.
/// The backend handles: Identity, OpenClaw, Relay, Providers, LLMs, ProjectAndAgents.
fn step_delegate_to_backend(
    backend_override: Option<&str>,
    local_relay_url: Option<&str>,
) -> Result<()> {
    let backend_cmd = match resolve_backend_bin(backend_override) {
        Some(cmd) => cmd,
        None => {
            display::context("Backend binary not found — skipping setup.");
            display::hint("Install the backend with: bun add -g @tenex-chat/backend");
            return Ok(());
        }
    };

    let mut args = vec!["setup", "init"];
    let url_owned;
    if let Some(url) = local_relay_url {
        args.push("--local-relay-url");
        url_owned = url.to_string();
        args.push(&url_owned);
    }

    let status = backend_cmd
        .command(&args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();

    match status {
        Ok(s) if s.success() => {}
        Ok(s) => {
            display::context(&format!(
                "Backend setup exited with code {}. Continuing onboarding.",
                s.code().unwrap_or(-1)
            ));
        }
        Err(e) => {
            display::context(&format!("Failed to run backend setup: {}. Continuing.", e));
        }
    }

    Ok(())
}

/// A resolved backend command: program + base arguments.
///
/// For compiled binaries: `program = "/path/to/tenex-backend"`, `base_args = []`
/// For TypeScript sources:  `program = "bun"`, `base_args = ["run", "/path/to/index.ts"]`
struct BackendCmd {
    program: String,
    base_args: Vec<String>,
}

impl BackendCmd {
    fn command(&self, extra_args: &[&str]) -> SysCommand {
        let mut cmd = SysCommand::new(&self.program);
        cmd.args(&self.base_args);
        cmd.args(extra_args);
        cmd
    }
}

/// Resolve the backend CLI binary.
///
/// Resolution order:
/// 1. Explicit override (from `--backend` flag)
/// 2. `TENEX_BACKEND` environment variable
/// 3. Bun global bin directory (`~/.bun/bin/tenex-backend`)
/// 4. `deps/backend/dist/tenex-daemon` found by walking up the directory tree (dev)
/// 5. `tenex-backend` on `$PATH`
///
/// If the resolved path ends in `.ts` or `.js`, it's wrapped with `bun run`.
fn resolve_backend_bin(backend_override: Option<&str>) -> Option<BackendCmd> {
    let from_path = |path: std::path::PathBuf| -> BackendCmd {
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext == "ts" || ext == "js" {
            let bun = find_bun().unwrap_or_else(|| "bun".into());
            BackendCmd {
                program: bun,
                base_args: vec!["run".into(), path.to_string_lossy().into()],
            }
        } else {
            BackendCmd {
                program: path.to_string_lossy().into(),
                base_args: vec![],
            }
        }
    };

    // 1. Explicit override
    if let Some(val) = backend_override {
        let path = std::path::PathBuf::from(val);
        if path.exists() {
            return Some(from_path(path));
        }
    }

    // 2. TENEX_BACKEND env var
    if let Ok(val) = std::env::var("TENEX_BACKEND") {
        let path = std::path::PathBuf::from(&val);
        if path.exists() {
            return Some(from_path(path));
        }
    }

    // 3. Bun global bin directory
    if let Some(home) = dirs::home_dir() {
        let bun_global = home.join(format!(".bun/bin/{}", BACKEND_BIN));
        if bun_global.exists() {
            return Some(from_path(bun_global));
        }
    }

    // 4. deps/backend/dist/tenex-daemon — walk up from exe to find repo root (dev)
    if let Ok(exe) = std::env::current_exe() {
        let mut dir = exe.parent().map(|p| p.to_path_buf());
        for _ in 0..8 {
            if let Some(d) = dir {
                let candidate = d.join("deps/backend/dist/tenex-daemon");
                if candidate.exists() {
                    return Some(from_path(candidate));
                }
                dir = d.parent().map(|p| p.to_path_buf());
            } else {
                break;
            }
        }
    }

    // 5. `tenex-backend` on PATH
    if let Ok(out) = SysCommand::new("which").arg(BACKEND_BIN).output() {
        if out.status.success() {
            let path_str = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if !path_str.is_empty() {
                return Some(from_path(std::path::PathBuf::from(path_str)));
            }
        }
    }

    None
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
                let raw = format!("{} {}", padded, &n.description);
                display::truncate_to_terminal(&raw, 6)
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

        let nudge_selections = ui::prompt(|| {
            MultiSelect::with_theme(&theme)
                .with_prompt("Pick nudges for your team (space to select)")
                .items(&nudge_items)
                .interact()
        })?;

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
                let raw = format!("{} {}", padded, &s.description);
                display::truncate_to_terminal(&raw, 6)
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

        let skill_selections = ui::prompt(|| {
            MultiSelect::with_theme(&theme)
                .with_prompt("Pick skills to enable (space to select)")
                .items(&skill_items)
                .interact()
        })?;

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

/// Which client the user chose during onboarding.
pub enum ClientChoice {
    Mac,
    Ios,
    Repl,
}

fn step_launch_client(
    config_store: &Arc<ConfigStore>,
    step: usize,
    total: usize,
) -> Result<ClientChoice> {
    display::step(step, total, "Launch Client");

    display::stream_context("Choose how you'd like to interact with your agents.");
    display::blank();

    let theme = display::theme();

    let mut options: Vec<&str> = Vec::new();
    let mut option_keys: Vec<&str> = Vec::new();

    // macOS app option — only on macOS
    #[cfg(target_os = "macos")]
    {
        options.push("Mac app");
        option_keys.push("mac");
    }

    options.push("iOS app (pair via QR code)");
    option_keys.push("ios");

    options.push("REPL (continue in this terminal)");
    option_keys.push("repl");

    let sel = ui::prompt(|| {
        Select::with_theme(&theme)
            .with_prompt("Which client?")
            .items(&options)
            .default(0)
            .interact()
    })?;

    let choice = match option_keys[sel] {
        #[cfg(target_os = "macos")]
        "mac" => {
            display::blank();
            display::context("Opening TenexLauncher…");
            let _ = std::process::Command::new("open")
                .args(["-a", "TenexLauncher"])
                .spawn();
            ClientChoice::Mac
        }
        "ios" => {
            let shown = show_mobile_pairing(config_store)?;
            if shown {
                let _ = ui::prompt(|| {
                    Confirm::with_theme(&theme)
                        .with_prompt("Continue?")
                        .default(true)
                        .interact()
                })?;
            }
            ClientChoice::Ios
        }
        _ => ClientChoice::Repl,
    };

    Ok(choice)
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
