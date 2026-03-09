use std::io::{self, Write};

use console::style;

use crate::display::ACCENT;

// Amber/orange palette (xterm-256)
const DARK: u8 = 130;
const MID: u8 = 172;
const BRIGHT: u8 = 220;
const GLOW: u8 = 222;

/// Print the TENEX welcome banner — stippled Sierpinski triangle
/// with "T E N E X" and tagline to the right.
pub fn print_logo() {
    let art: &[(&str, u8)] = &[
        ("        •        ", GLOW),
        ("       • •       ", BRIGHT),
        ("      • • •      ", BRIGHT),
        ("     • • • •     ", ACCENT),
        ("    •   •   •    ", ACCENT),
        ("   • • • • • •   ", MID),
        ("  • • • • • • •  ", MID),
        (" • • • • • • • • ", DARK),
    ];
    for (i, (line, color)) in art.iter().enumerate() {
        print!("  ");
        for ch in line.chars() {
            if ch == ' ' {
                print!(" ");
            } else {
                print!("\x1b[1;38;5;{}m{}\x1b[0m", color, ch);
            }
        }
        match i {
            3 => print!("  {}", style("T E N E X").color256(ACCENT).bold()),
            5 => print!("  {}", style("Your AI agent team, powered by Nostr.").bold()),
            6 => print!("  {}", style("Let's get everything set up.").dim()),
            _ => {}
        }
        println!();
    }
    io::stdout().flush().unwrap();
}
