use console::{Key, Term};
use tenex_orchestrator::config::TenexLLMs;

use crate::display;

/// Block SIGCHLD on the current thread during a blocking terminal I/O call.
///
/// The `console` crate uses `select()`/`poll()` for terminal reads. These
/// syscalls are NOT restarted by `SA_RESTART` when interrupted by signals.
/// When a child process exits (e.g. background `bun install`), SIGCHLD
/// interrupts the call with EINTR. The console crate then misinterprets
/// this as Ctrl+C and calls `libc::raise(SIGINT)`, crashing the process.
///
/// Blocking SIGCHLD on the calling thread prevents the interruption.
/// Other tokio worker threads still receive SIGCHLD for child management.
pub fn prompt<T>(f: impl FnOnce() -> T) -> T {
    unsafe {
        let mut block_set: libc::sigset_t = std::mem::zeroed();
        let mut old_set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut block_set);
        libc::sigaddset(&mut block_set, libc::SIGCHLD);
        libc::pthread_sigmask(libc::SIG_BLOCK, &block_set, &mut old_set);
        let result = f();
        libc::pthread_sigmask(libc::SIG_SETMASK, &old_set, std::ptr::null_mut());
        result
    }
}

pub enum ModelListAction {
    Edit(String),
    Delete(String),
    Add,
    Done,
}

// Sentinel values for the two footer entries
const IDX_ADD: usize = usize::MAX - 1;
const IDX_DONE: usize = usize::MAX;

/// Show an interactive model list using arrow key navigation.
/// - ↑↓: navigate (including Add / Done footer items)
/// - Enter: perform action on selected item (edit model, add, or done)
/// - d: delete selected model (only when a model is selected)
pub fn interactive_model_list(llms: &TenexLLMs) -> anyhow::Result<ModelListAction> {
    prompt(|| interactive_model_list_inner(llms))
}

fn interactive_model_list_inner(llms: &TenexLLMs) -> anyhow::Result<ModelListAction> {
    let mut names: Vec<String> = llms.configurations.keys().cloned().collect();
    names.sort();

    let term = Term::stderr();
    let _ = term.hide_cursor();

    // cursor tracks into an extended index space:
    //   0..names.len()  → model entries
    //   IDX_ADD         → "Add model configuration"
    //   IDX_DONE        → "Done"
    let n = names.len();
    // Total rendered lines: blank + n items + blank + add + done + blank + hint
    let line_count = n + 6;
    let mut cursor: usize = if n == 0 { IDX_ADD } else { 0 };

    render_model_list(&term, &names, llms, cursor)?;

    let result = loop {
        match term.read_key()? {
            Key::ArrowUp => {
                let prev = prev_cursor(cursor, n);
                if prev != cursor {
                    cursor = prev;
                    term.clear_last_lines(line_count)?;
                    render_model_list(&term, &names, llms, cursor)?;
                }
            }
            Key::ArrowDown => {
                let next = next_cursor(cursor, n);
                if next != cursor {
                    cursor = next;
                    term.clear_last_lines(line_count)?;
                    render_model_list(&term, &names, llms, cursor)?;
                }
            }
            Key::Enter => {
                term.clear_last_lines(line_count)?;
                match cursor {
                    IDX_ADD => break ModelListAction::Add,
                    IDX_DONE => break ModelListAction::Done,
                    i => break ModelListAction::Edit(names[i].clone()),
                }
            }
            Key::Char('d') | Key::Char('D') => {
                if cursor < n {
                    term.clear_last_lines(line_count)?;
                    break ModelListAction::Delete(names[cursor].clone());
                }
            }
            _ => {}
        }
    };

    let _ = term.show_cursor();
    Ok(result)
}

fn prev_cursor(cursor: usize, n: usize) -> usize {
    match cursor {
        IDX_DONE => IDX_ADD,
        IDX_ADD => {
            if n > 0 {
                n - 1
            } else {
                IDX_ADD
            }
        }
        0 => 0,
        i => i - 1,
    }
}

fn next_cursor(cursor: usize, n: usize) -> usize {
    match cursor {
        IDX_ADD => IDX_DONE,
        IDX_DONE => IDX_DONE,
        i if i + 1 < n => i + 1,
        _ => IDX_ADD,
    }
}

fn render_model_list(
    term: &Term,
    names: &[String],
    llms: &TenexLLMs,
    cursor: usize,
) -> anyhow::Result<()> {
    let n = names.len();

    term.write_line("")?;
    for (i, name) in names.iter().enumerate() {
        let cfg = &llms.configurations[name];
        let is_active = cursor == i;
        let is_default = llms.default_config.as_deref() == Some(name.as_str());

        let prefix = if is_active {
            console::style("›").color256(display::ACCENT).bold().to_string()
        } else {
            " ".to_string()
        };

        let name_part = if is_active {
            console::style(format!("{:<20}", name))
                .color256(display::ACCENT)
                .bold()
                .to_string()
        } else {
            console::style(format!("{:<20}", name)).color256(252).to_string()
        };

        let default_tag = if is_default {
            console::style(" [default]").color256(display::SELECTED).to_string()
        } else {
            String::new()
        };

        term.write_line(&format!(
            "  {} {} {}  {}{}",
            prefix,
            name_part,
            cfg.display_model(),
            console::style(format!("({})", cfg.provider())).dim(),
            default_tag,
        ))?;
    }

    term.write_line("")?;

    // "Add model configuration" entry
    let add_active = cursor == IDX_ADD;
    let add_prefix = if add_active {
        console::style("›").color256(display::ACCENT).bold().to_string()
    } else {
        " ".to_string()
    };
    let add_label = if add_active {
        console::style("+ Add model configuration")
            .color256(display::ACCENT)
            .bold()
            .to_string()
    } else {
        format!(
            "{} {}",
            console::style("+").color256(display::INFO).bold(),
            console::style("Add model configuration").color256(display::INFO),
        )
    };
    term.write_line(&format!("  {} {}", add_prefix, add_label))?;

    // "Done" entry
    let done_active = cursor == IDX_DONE;
    let done_prefix = if done_active {
        console::style("›").color256(display::ACCENT).bold().to_string()
    } else {
        " ".to_string()
    };
    let done_label = if done_active {
        console::style("✓ Done")
            .color256(display::ACCENT)
            .bold()
            .to_string()
    } else {
        format!(
            "{} {}",
            console::style("✓").color256(display::SELECTED).bold(),
            console::style("Done").color256(display::SELECTED),
        )
    };
    term.write_line(&format!("  {} {}", done_prefix, done_label))?;

    term.write_line("")?;
    let hint = if n > 0 && cursor < n {
        "↑↓ navigate  ·  Enter edit  ·  d delete"
    } else {
        "↑↓ navigate  ·  Enter confirm"
    };
    term.write_line(&format!(
        "  {}",
        console::style(hint).dim()
    ))?;

    Ok(())
}
