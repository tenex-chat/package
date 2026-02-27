use std::io::{self, Write};
use std::thread;
use std::time::Duration;

use console::{colors_enabled, style, Style};
use dialoguer::theme::ColorfulTheme;

/// Accent color for step headers and interactive prompts.
pub const ACCENT: u8 = 222; // gold
/// Secondary color for informational highlights.
pub const INFO: u8 = 117; // sky blue
/// Color for selected/checked items.
pub const SELECTED: u8 = 114; // bright green

/// Build the TENEX dialoguer theme — gold accents, green checks, consistent everywhere.
pub fn theme() -> ColorfulTheme {
    ColorfulTheme {
        prompt_prefix: style("?".to_string()).for_stderr().color256(ACCENT).bold(),
        prompt_style: Style::new().for_stderr().bold(),
        prompt_suffix: style("›".to_string()).for_stderr().color256(ACCENT),
        success_prefix: style("✓".to_string()).for_stderr().green().bold(),
        success_suffix: style("·".to_string()).for_stderr().dim(),
        active_item_prefix: style("›".to_string()).for_stderr().color256(ACCENT).bold(),
        inactive_item_prefix: style(" ".to_string()).for_stderr(),
        active_item_style: Style::new().for_stderr().color256(ACCENT).bold(),
        inactive_item_style: Style::new().for_stderr().color256(252),
        checked_item_prefix: style("[✓]".to_string()).for_stderr().color256(SELECTED).bold(),
        unchecked_item_prefix: style("[ ]".to_string()).for_stderr().color256(240),
        values_style: Style::new().for_stderr().color256(INFO),
        hint_style: Style::new().for_stderr().dim(),
        defaults_style: Style::new().for_stderr().color256(INFO),
        error_prefix: style("✘".to_string()).for_stderr().red(),
        error_style: Style::new().for_stderr().red(),
        picked_item_prefix: style("›".to_string()).for_stderr().color256(ACCENT),
        unpicked_item_prefix: style(" ".to_string()).for_stderr(),
        fuzzy_cursor_style: Style::new().for_stderr().color256(ACCENT).bold(),
        fuzzy_match_highlight_style: Style::new().for_stderr().color256(ACCENT).bold(),
    }
}

/// Stream text character-by-character to stdout with LLM-like timing.
fn stream_chars(out: &mut io::StdoutLock<'_>, text: &str) {
    for ch in text.chars() {
        write!(out, "{}", ch).ok();
        out.flush().ok();

        let delay = match ch {
            '.' | '!' | '?' | '—' => 60,
            ',' | ';' | ':' => 35,
            ' ' => 6,
            '\n' => 30,
            _ => 18,
        };
        thread::sleep(Duration::from_millis(delay));
    }
}

/// Stream dim context text line-by-line with LLM-like animation.
/// Use this for onboarding explanatory paragraphs.
pub fn stream_context(text: &str) {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    let use_ansi = colors_enabled();

    for line in text.lines() {
        write!(out, "  ").ok();
        if use_ansi {
            write!(out, "\x1b[2m").ok();
        }
        stream_chars(&mut out, line);
        if use_ansi {
            write!(out, "\x1b[0m").ok();
        }
        writeln!(out).ok();
        out.flush().ok();
    }
}

/// Print an onboarding step header with step number and color.
///
///   1  Identity
///   ─────────────────────────────────────────
pub fn step(number: usize, total: usize, title: &str) {
    let rule = "─".repeat(45);
    println!();
    println!(
        "  {}  {}",
        style(format!("{}/{}", number, total)).color256(ACCENT).bold(),
        style(title).color256(ACCENT).bold(),
    );
    println!("  {}", style(rule).color256(ACCENT).dim());
    println!();
}

/// Print a section header (non-numbered, for dashboard/settings).
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

/// Print a hint/tip with a colored arrow.
pub fn hint(text: &str) {
    println!(
        "  {} {}",
        style("→").color256(ACCENT),
        style(text).color256(ACCENT)
    );
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
        style("●").color256(INFO),
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
        style("▲ T E N E X").color256(ACCENT).bold()
    );
    println!();
    println!(
        "  {}",
        style("Your AI agent team, powered by Nostr.").bold()
    );
    println!(
        "  {}",
        style("Let's get everything set up.").dim()
    );
    println!();
}

/// Print the final setup summary banner.
pub fn setup_complete() {
    println!();
    println!(
        "  {} {}",
        style("▲").color256(ACCENT).bold(),
        style("Setup complete!").color256(ACCENT).bold(),
    );
    println!();
}

/// Print a summary line for the final recap.
pub fn summary_line(label: &str, value: &str) {
    println!(
        "    {:<16}{}",
        style(format!("{}:", label)).color256(INFO),
        value
    );
}

/// Print the dashboard greeting.
pub fn dashboard_greeting() {
    println!();
    println!(
        "  {} {}",
        style("▲").color256(ACCENT).bold(),
        style("Here's what's running:").bold()
    );
    println!();
}

/// Render a QR code as Unicode half-block characters in the terminal.
pub fn qr_code(data: &str) {
    use qrcode::QrCode;

    let code = match QrCode::new(data) {
        Ok(c) => c,
        Err(e) => {
            context(&format!("Failed to generate QR code: {}", e));
            return;
        }
    };

    let matrix = code.to_colors();
    let width = code.width();
    let rows: Vec<&[qrcode::Color]> = matrix.chunks(width).collect();

    let quiet = "  ";

    let mut y = 0;
    while y < rows.len() {
        print!("{}", quiet);
        for x in 0..width {
            let top = rows[y][x] == qrcode::Color::Dark;
            let bottom = if y + 1 < rows.len() {
                rows[y + 1][x] == qrcode::Color::Dark
            } else {
                false
            };

            match (top, bottom) {
                (true, true) => print!("\u{2588}"),
                (true, false) => print!("\u{2580}"),
                (false, true) => print!("\u{2584}"),
                (false, false) => print!(" "),
            }
        }
        println!();
        y += 2;
    }
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
