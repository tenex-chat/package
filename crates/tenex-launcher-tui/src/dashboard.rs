use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use dialoguer::{Confirm, Select};
use indicatif::ProgressBar;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;
use tenex_orchestrator::process::{ProcessManager, ProcessStatus};

use crate::display;
use crate::onboarding;
use crate::settings;
use crate::ui;

pub async fn run(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) -> Result<()> {
    let theme = display::theme();
    loop {
        print_status(config_store, daemon, relay, ngrok).await;

        let choices = vec![
            "Check status",
            "Start/stop services",
            "Mobile pairing",
            "Settings",
            "Quit",
        ];
        let selection = ui::prompt(|| {
            Select::with_theme(&theme)
                .with_prompt("What do you want to do?")
                .items(&choices)
                .default(0)
                .interact_opt()
        });

        match selection? {
            Some(0) => continue,
            Some(1) => handle_services(&theme, config_store, daemon, relay, ngrok).await?,
            Some(2) => { onboarding::show_mobile_pairing(config_store)?; },
            Some(3) => settings::run(config_store).await?,
            Some(4) | None => break,
            _ => continue,
        }
    }

    Ok(())
}

fn uses_local_relay(config_store: &Arc<ConfigStore>) -> bool {
    config_store
        .load_launcher()
        .local_relay
        .as_ref()
        .and_then(|lr| lr.enabled)
        .unwrap_or(false)
}

async fn print_status(
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) {
    display::dashboard_greeting();

    let daemon_status = daemon.status().await;
    display::service_status(
        "daemon",
        daemon_status == ProcessStatus::Running,
        &format_process_detail(daemon_status),
    );

    if uses_local_relay(config_store) {
        let relay_status = relay.status().await;
        let ngrok_status = ngrok.status().await;

        display::service_status(
            "relay",
            relay_status == ProcessStatus::Running,
            if relay_status == ProcessStatus::Running {
                "localhost"
            } else {
                "not running"
            },
        );
        display::service_status(
            "ngrok",
            ngrok_status == ProcessStatus::Running,
            if ngrok_status == ProcessStatus::Running {
                "tunnel active"
            } else {
                "start it to expose your agent"
            },
        );
    }

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
    theme: &dialoguer::theme::ColorfulTheme,
    config_store: &Arc<ConfigStore>,
    daemon: &Arc<DaemonManager>,
    relay: &Arc<RelayManager>,
    ngrok: &Arc<NgrokManager>,
) -> Result<()> {
    let local_relay = uses_local_relay(config_store);

    let mut entries: Vec<(&str, ProcessStatus)> = vec![
        ("daemon", daemon.status().await),
    ];
    if local_relay {
        entries.push(("relay", relay.status().await));
        entries.push(("ngrok", ngrok.status().await));
    }

    let choices: Vec<String> = entries
        .iter()
        .map(|(name, status)| format!("{} — currently {}", name, status))
        .collect();

    let selection = ui::prompt(|| {
        Select::with_theme(theme)
            .with_prompt("Which service?")
            .items(&choices)
            .interact_opt()
    })?;

    let Some(idx) = selection else {
        return Ok(());
    };

    let (name, status) = entries[idx];
    let running = status == ProcessStatus::Running;

    if running {
        let stop = ui::prompt(|| {
            Confirm::with_theme(theme)
                .with_prompt(format!("Stop {}?", name))
                .default(false)
                .interact()
        })?;
        if stop {
            let spinner = ProgressBar::new_spinner();
            spinner.set_message(format!("Stopping {}...", name));
            spinner.enable_steady_tick(Duration::from_millis(80));
            match name {
                "daemon" => daemon.stop().await?,
                "relay" => relay.stop().await?,
                "ngrok" => ngrok.stop().await?,
                _ => {}
            }
            spinner.finish_and_clear();
            display::success(&format!("{} stopped.", name));
        }
    } else {
        let start = ui::prompt(|| {
            Confirm::with_theme(theme)
                .with_prompt(format!("Start {}?", name))
                .default(true)
                .interact()
        })?;
        if start {
            let spinner = ProgressBar::new_spinner();
            spinner.set_message(format!("Starting {}...", name));
            spinner.enable_steady_tick(Duration::from_millis(80));
            match name {
                "daemon" => daemon.start().await?,
                "relay" => relay.start().await?,
                "ngrok" => ngrok.start().await?,
                _ => {}
            }
            spinner.finish_and_clear();
            display::success(&format!("{} started.", name));
        }
    }

    Ok(())
}
