use std::sync::Arc;

use anyhow::Result;
use tenex_orchestrator::config::ConfigStore;

pub async fn run(config_store: &Arc<ConfigStore>) -> Result<()> {
    println!("  Settings coming soon.");
    Ok(())
}
