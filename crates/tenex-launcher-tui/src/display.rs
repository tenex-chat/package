use console::style;

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
#[allow(dead_code)]
pub fn warn(text: &str) {
    println!("  {} {}", style("⚠").yellow(), text);
}

/// Print an error message.
#[allow(dead_code)]
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
