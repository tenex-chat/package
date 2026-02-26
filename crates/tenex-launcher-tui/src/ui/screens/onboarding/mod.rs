use ratatui::prelude::*;
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};

use tenex_orchestrator::onboarding::OnboardingStep;

use crate::app::App;
use crate::ui::theme;

pub fn render(frame: &mut Frame, app: &App) {
    let outer = Block::default()
        .title(" Welcome to TENEX ")
        .title_style(theme::title())
        .borders(Borders::ALL)
        .border_style(theme::border_active());

    let inner = outer.inner(frame.area());
    frame.render_widget(outer, frame.area());

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),   // Header
            Constraint::Min(5),      // Content
            Constraint::Length(1),   // Navigation hints
        ])
        .split(inner);

    // Header
    render_header(frame, app, chunks[0]);

    // Content
    render_step_content(frame, app, chunks[1]);

    // Hints
    render_hints(frame, app, chunks[2]);
}

fn render_header(frame: &mut Frame, app: &App, area: Rect) {
    let subtitle = match app.onboarding.step {
        OnboardingStep::Identity => "Set up your Nostr identity to get started.",
        OnboardingStep::OpenClawImport => "Import your existing OpenClaw configuration.",
        OnboardingStep::Relay => "Choose how to connect to the Nostr network.",
        OnboardingStep::Providers => "Connect your AI providers.",
        OnboardingStep::LLMs => "Configure your LLM models and role assignments.",
        OnboardingStep::FirstProject => "Create your first project.",
        OnboardingStep::HireAgents => "Hire agents for your project.",
        OnboardingStep::NudgesSkills => "Configure nudges and skills.",
        OnboardingStep::Done => "Setup complete!",
    };

    let step_num = match app.onboarding.step {
        OnboardingStep::Identity => 1,
        OnboardingStep::OpenClawImport => 2,
        OnboardingStep::Relay => if app.onboarding.has_openclaw { 3 } else { 2 },
        OnboardingStep::Providers => if app.onboarding.has_openclaw { 4 } else { 3 },
        OnboardingStep::LLMs => if app.onboarding.has_openclaw { 5 } else { 4 },
        OnboardingStep::FirstProject => if app.onboarding.has_openclaw { 6 } else { 5 },
        OnboardingStep::HireAgents => if app.onboarding.has_openclaw { 7 } else { 6 },
        OnboardingStep::NudgesSkills => if app.onboarding.has_openclaw { 8 } else { 7 },
        OnboardingStep::Done => if app.onboarding.has_openclaw { 9 } else { 8 },
    };

    let total = if app.onboarding.has_openclaw { 9 } else { 8 };

    let header = Line::from(vec![
        Span::styled(
            format!(" Step {}/{} ", step_num, total),
            theme::section_header(),
        ),
        Span::styled(subtitle, theme::text_muted()),
    ]);

    frame.render_widget(Paragraph::new(header), area);
}

fn render_step_content(frame: &mut Frame, app: &App, area: Rect) {
    let block = Block::default()
        .borders(Borders::ALL)
        .border_style(theme::border_inactive());

    let inner = block.inner(area);
    frame.render_widget(block, area);

    let content = match app.onboarding.step {
        OnboardingStep::Identity => render_identity_step(),
        OnboardingStep::OpenClawImport => render_openclaw_step(),
        OnboardingStep::Relay => render_relay_step(),
        OnboardingStep::Providers => render_providers_step(app),
        OnboardingStep::LLMs => render_llms_step(app),
        OnboardingStep::FirstProject => render_placeholder_step("First Project"),
        OnboardingStep::HireAgents => render_placeholder_step("Hire Agents"),
        OnboardingStep::NudgesSkills => render_placeholder_step("Nudges & Skills"),
        OnboardingStep::Done => render_done_step(),
    };

    let paragraph = Paragraph::new(content)
        .wrap(Wrap { trim: false })
        .style(theme::text_primary());
    frame.render_widget(paragraph, inner);
}

fn render_identity_step() -> Text<'static> {
    Text::from(vec![
        Line::from(""),
        Line::from("  TENEX uses Nostr keys for authentication."),
        Line::from("  You need a keypair to use this instance."),
        Line::from(""),
        Line::from(vec![
            Span::styled("  [1] ", theme::hint()),
            Span::raw("I have a Nostr key (enter nsec)"),
        ]),
        Line::from(vec![
            Span::styled("  [2] ", theme::hint()),
            Span::raw("Create new identity"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "  Press 1 or 2 to choose, then Enter to continue.",
            theme::text_dim(),
        )),
    ])
}

fn render_openclaw_step() -> Text<'static> {
    Text::from(vec![
        Line::from(""),
        Line::from("  OpenClaw installation detected!"),
        Line::from(""),
        Line::from("  We can import your credentials and agent configurations."),
        Line::from(""),
        Line::from(Span::styled(
            "  Press Enter to import, Esc to skip.",
            theme::text_dim(),
        )),
    ])
}

fn render_relay_step() -> Text<'static> {
    Text::from(vec![
        Line::from(""),
        Line::from(vec![
            Span::styled("  [1] ", theme::hint()),
            Span::raw("Remote Relay — Connect to a relay server"),
        ]),
        Line::from(vec![
            Span::styled("  [2] ", theme::hint()),
            Span::raw("Local Relay — Run a relay on this machine"),
        ]),
        Line::from(""),
        Line::from(Span::styled(
            "  Press 1 or 2 to choose, then Enter to continue.",
            theme::text_dim(),
        )),
    ])
}

fn render_providers_step(app: &App) -> Text<'static> {
    let providers = app.config_store.load_providers();
    let mut lines = vec![
        Line::from(""),
        Line::from("  Connected providers:"),
        Line::from(""),
    ];

    if providers.providers.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (none — connect at least one to continue)",
            theme::text_dim(),
        )));
    } else {
        let names = tenex_orchestrator::provider::provider_display_names();
        for (id, _) in &providers.providers {
            let display = names.get(id.as_str()).copied().unwrap_or(id.as_str());
            lines.push(Line::from(format!("  ● {}", display)));
        }
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "  Press Enter to continue to LLM configuration.",
        theme::text_dim(),
    )));

    Text::from(lines)
}

fn render_llms_step(app: &App) -> Text<'static> {
    let llms = app.config_store.load_llms();
    let mut lines = vec![
        Line::from(""),
        Line::from("  LLM configurations:"),
        Line::from(""),
    ];

    if llms.configurations.is_empty() {
        lines.push(Line::from(Span::styled(
            "  (defaults will be seeded based on your providers)",
            theme::text_dim(),
        )));
    } else {
        for (name, config) in &llms.configurations {
            lines.push(Line::from(format!(
                "  ● {} — {} ({})",
                name,
                config.display_model(),
                config.provider()
            )));
        }
    }

    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "  Press Enter to continue.",
        theme::text_dim(),
    )));

    Text::from(lines)
}

fn render_placeholder_step(title: &str) -> Text<'static> {
    Text::from(vec![
        Line::from(""),
        Line::from(format!("  {} — coming soon.", title)),
        Line::from(""),
        Line::from(Span::styled(
            "  Press Enter to continue.",
            theme::text_dim(),
        )),
    ])
}

fn render_done_step() -> Text<'static> {
    Text::from(vec![
        Line::from(""),
        Line::from("  Setup complete!"),
        Line::from(""),
        Line::from(Span::styled(
            "  Press Enter to finish and go to the dashboard.",
            theme::text_dim(),
        )),
    ])
}

fn render_hints(frame: &mut Frame, app: &App, area: Rect) {
    let hints = if app.onboarding.step == OnboardingStep::Identity {
        Line::from(vec![
            Span::styled(" [Enter]", theme::hint()),
            Span::styled(" continue", theme::text_dim()),
        ])
    } else {
        Line::from(vec![
            Span::styled(" [Enter]", theme::hint()),
            Span::styled(" continue  ", theme::text_dim()),
            Span::styled("[Esc]", theme::hint()),
            Span::styled(" back", theme::text_dim()),
        ])
    };

    frame.render_widget(Paragraph::new(hints), area);
}
