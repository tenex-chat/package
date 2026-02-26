use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
use console::style;
use dialoguer::{Confirm, Select};
use indicatif::ProgressBar;
use tenex_orchestrator::config::ConfigStore;
use tenex_orchestrator::process::daemon::DaemonManager;
use tenex_orchestrator::process::ngrok::NgrokManager;
use tenex_orchestrator::process::relay::RelayManager;
use tenex_orchestrator::process::{ProcessManager, ProcessStatus};

use crate::display;
use crate::settings;

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
    let statuses = [
        ("daemon", daemon.status()),
        ("relay", relay.status()),
        ("ngrok", ngrok.status()),
    ];

    let choices: Vec<String> = statuses
        .iter()
        .map(|(name, status)| format!("{} — currently {}", name, status))
        .collect();

    let selection = Select::new()
        .with_prompt(format!("{} Which service?", style("?").blue().bold()))
        .items(&choices)
        .interact_opt()?;

    let Some(idx) = selection else {
        return Ok(());
    };

    let (name, status) = statuses[idx];

    match status {
        ProcessStatus::Running => {
            let stop = Confirm::new()
                .with_prompt(format!("{} Stop {}?", style("?").blue().bold(), name))
                .default(false)
                .interact()?;
            if stop {
                let spinner = ProgressBar::new_spinner();
                spinner.set_message(format!("Stopping {}...", name));
                spinner.enable_steady_tick(Duration::from_millis(80));
                match idx {
                    0 => daemon.stop().await?,
                    1 => relay.stop().await?,
                    2 => ngrok.stop().await?,
                    _ => {}
                }
                spinner.finish_and_clear();
                display::success(&format!("{} stopped.", name));
            }
        }
        _ => {
            let start = Confirm::new()
                .with_prompt(format!("{} Start {}?", style("?").blue().bold(), name))
                .default(true)
                .interact()?;
            if start {
                let spinner = ProgressBar::new_spinner();
                spinner.set_message(format!("Starting {}...", name));
                spinner.enable_steady_tick(Duration::from_millis(80));
                match idx {
                    0 => daemon.start().await?,
                    1 => relay.start().await?,
                    2 => ngrok.start().await?,
                    _ => {}
                }
                spinner.finish_and_clear();
                display::success(&format!("{} started.", name));
            }
        }
    }

    Ok(())
}
