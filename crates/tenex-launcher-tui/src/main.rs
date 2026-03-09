mod dashboard;
mod display;
mod logo;
mod nostr;
mod onboarding;
mod repl;
mod settings;
mod ui;

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

    let args: Vec<String> = std::env::args().skip(1).collect();
    let force_onboarding = args.first().map(|s| s.as_str()) == Some("onboard");

    let mut backend_override: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--backend" {
            if let Some(path) = args.get(i + 1) {
                backend_override = Some(path.clone());
                i += 2;
                continue;
            }
        }
        i += 1;
    }

    // Set env var so the daemon also uses this backend path after onboarding
    if let Some(ref path) = backend_override {
        std::env::set_var("TENEX_BACKEND", path);
    }

    repl::run(force_onboarding, backend_override).await
}
