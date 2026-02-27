mod dashboard;
mod display;
mod nostr;
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
