use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;

use crate::display;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    display::welcome();
    display::success("Onboarding complete! (stub)");
    Ok(())
}
