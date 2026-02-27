# TENEX Launcher TUI: REPL Redesign

Replace the full-screen ratatui TUI with an inline REPL using `dialoguer` + `console`. Conversational style (Vercel CLI-inspired): friendly, educational, not cutesy.

## Dependencies

Drop `ratatui` and `crossterm` from `tenex-launcher-tui`. Add:

```toml
dialoguer = { version = "0.11", features = ["history"] }
console = "0.15"
indicatif = "0.17"
```

`tenex-orchestrator` is untouched.

## Module Structure

```
crates/tenex-launcher-tui/src/
  main.rs          # entry, tokio runtime
  repl.rs          # top-level loop: onboarding or dashboard
  onboarding.rs    # sequential onboarding prompts
  dashboard.rs     # hybrid status + action menu
  settings.rs      # settings sub-REPL (grouped categories)
  display.rs       # shared styled output helpers
```

## Onboarding Flow

9 steps. Steps 1-5 essential, 6-8 guided but skippable.

### Step 1: Identity

```
? How do you want to authenticate?
  > Create new Nostr identity
    I have an existing key (nsec)

  ✓ Generated keypair: npub1abc...def
```

Explain what Nostr keys are and why they matter. If user picks "existing key", use `dialoguer::Password` for nsec input.

### Step 2: OpenClaw Import (conditional)

Only shown if `tenex_orchestrator::openclaw::detect()` returns Some.

```
  Looks like you have OpenClaw installed at ~/.openclaw
? Import credentials and agent configs? (Y/n)
  ⠋ Importing...
  ✓ Imported 2 providers, 4 agent configs
```

### Step 3: Relay

```
  The relay connects you to the Nostr network where your
  agents communicate.

? How should TENEX connect to Nostr?
  > Remote relay
    Local relay (run on this machine)

? Relay URL: (wss://tenex.chat) █
  ✓ Relay is responding, latency looks good.
```

### Step 4: Providers

```
  These are the AI services your agents will use.

  Connected: anthropic ✓, openai ✓

? Add another provider?
  > Skip — looks good
    Anthropic
    OpenAI
    Claude Code (requires `claude` CLI)
    Ollama
    OpenRouter
    Gemini CLI
```

Loop until user picks skip. Each provider prompts for API key via `dialoguer::Password`, then verifies the connection.

### Step 5: LLMs

```
  Here are the model configs I've set up based on your providers:
    ● sonnet    claude-sonnet-4-20250514 (anthropic)
    ● opus      claude-opus-4-20250514 (anthropic)
    ● auto      meta-llm (fast/balanced/powerful)

? Continue with these defaults? (Y/n)
```

Uses `OnboardingStateMachine::seed_default_llms()`. If user says no, enter LLM settings sub-REPL.

### Step 6: First Project

```
  TENEX organizes work into projects. Each project is a
  container for a team of AI agents focused on a shared
  concern. Agents can belong to multiple projects and
  collaborate across them.

  We recommend starting with a "Meta" project — a project
  about managing your other projects. Think of it as your
  command center.

? Create your Meta project? (Y/n)
  ✓ Created project "meta"
```

Creates a kind 31933 Nostr event with d-tag "meta".

### Step 7: Hire Agents

```
  Agents are AI personas with specific roles and skills.
  Let's find some generalist agents for your Meta project.

  ⠋ Discovering agents on the Nostr network...

  Found 12 agents. Here are some recommended starters:

? Which agents do you want to hire? (space to select)
    ✓ human-replica     Your digital twin
    ✓ project-manager   Coordinates tasks and delegates
      researcher        Deep research with web access
      developer         Full-stack coding agent
```

Queries kind 4199 on configured relays. Uses `dialoguer::MultiSelect`. For each selected agent, calls the hiring flow: fetch definition, save to `~/.tenex/agents/`, add agent tag to project event. First selected agent becomes PM.

### Step 8: Nudges & Skills

```
  Nudges shape how your agents behave. Skills give them
  specific capabilities they can reach for when needed.

  ⠋ Loading available nudges and skills...

? Select nudges to enable: (space to select)
    ✓ be-concise          Keep responses brief
    ✓ ask-before-acting   Always confirm before changes

? Select skills to allow: (space to select)
    ✓ git-workflow        PR creation, branch management
    ✓ nostr-publishing    Publish events to Nostr
```

Queries kind 4201 (nudges) and 4202 (skills). Publishes kind 14202 whitelist event for selected items.

### Step 9: Done

```
  ✓ Setup complete!

  Identity:     npub1abc...def
  Relay:        wss://tenex.chat
  Providers:    anthropic, openai
  Project:      meta (2 agents)

  Starting services...
  ⠋ Starting daemon...
  ✓ daemon running (pid 4821)
  ⠋ Connecting to relay...
  ✓ relay connected
```

## Dashboard

Hybrid: print status, show action menu, loop.

```
  Hey! Here's what's running:

    daemon    ● running    pid 4821
    relay     ● running    wss://tenex.chat
    ngrok     ○ stopped    start it to expose your agent

  What do you want to do?
  > Check status
    Start/stop services
    Settings
    Quit
```

Every action returns to the main menu. Each loop cycle re-reads service status.

### Start/Stop Services

```
? Which service?
  > ngrok — currently stopped
    daemon — currently running
    relay — currently running

? Start ngrok? (Y/n)
  ⠋ Starting ngrok...
  ✓ ngrok running — https://abc123.ngrok.io
```

## Settings

Grouped by section. Each sub-menu: print current state, offer actions (add/edit/remove/back), save immediately on confirm.

```
? What would you like to configure?

  AI
    ❯ Providers       API keys and connections
      LLMs            Model configurations
      Roles           Which model handles what task
      Embeddings      Text embedding model
      Image Gen       Image generation model

  Agents
      Escalation      Route ask() through an agent first
      Intervention    Auto-review when you're idle

  Network
      Relays          Nostr relay connections
      Local Relay     Run a relay on this machine

  Conversations
      Compression     Token limits and sliding window
      Summarization   Auto-summary timing

  Advanced
      Identity        Authorized pubkeys
      System Prompt   Global prompt for all projects
      Logging         Log level and file path
      Telemetry       OpenTelemetry tracing

      ↩ Back to dashboard
```

### Settings Detail: Providers

```
  Currently connected:
    ✓ anthropic    sk-ant-•••••7f2
    ✓ openai       sk-•••••x9k
    ○ claude-code  not detected

? What do you want to do?
  > Add a provider
    Remove a provider
    Back
```

### Settings Detail: LLMs

```
  Configured models:
    ● sonnet    claude-sonnet-4-20250514 (anthropic)
    ● opus      claude-opus-4-20250514 (anthropic)
    ● auto      meta-llm [fast→sonnet, balanced→sonnet, powerful→opus]

? What do you want to do?
  > Edit a model
    Add a model
    Remove a model
    Back
```

Editing shows current values as defaults (hit Enter to keep):

```
? Model ID: (claude-sonnet-4-20250514) █
? Provider: (anthropic) █
? Temperature: (0.7) █
```

### Settings Detail: Roles

```
  Role assignments:
    default           → auto
    summarization     → sonnet
    supervision       → opus
    search            → sonnet
    promptCompilation → sonnet
    compression       → (not set)

? Edit a role assignment?
  > default           currently: auto
    summarization     currently: sonnet
    supervision       currently: opus
    search            currently: sonnet
    promptCompilation currently: sonnet
    compression       currently: (not set)
    Back
```

### Settings Detail: Embeddings

```
  Current: local — Xenova/all-MiniLM-L6-v2

? Provider:
  > local
    openai (requires OpenAI provider)
    openrouter (requires OpenRouter provider)

? Model:
  > Xenova/all-MiniLM-L6-v2
    Xenova/all-mpnet-base-v2
    Xenova/paraphrase-multilingual-MiniLM-L12-v2
```

### Settings Detail: Image Generation

```
  Current: openrouter — black-forest-labs/flux.2-pro
  Aspect ratio: 16:9    Size: 2K

? Model:
  > black-forest-labs/flux.2-pro
    black-forest-labs/flux.2-max
    google/gemini-2.5-flash-image

? Default aspect ratio:
  > 16:9
    1:1
    9:16
    4:3
```

### Settings Detail: Agents (Escalation & Intervention)

```
  Escalation: not configured
  Intervention: disabled

? What do you want to configure?
  > Escalation — route ask() through an agent first
    Intervention — auto-review when you're idle
    Back
```

### Settings Detail: Conversations

```
  Compression: enabled
    Token threshold: 50,000
    Token budget: 40,000
    Sliding window: 50 messages

  Summarization:
    Inactivity timeout: 5 minutes

? What do you want to adjust?
  > Compression settings
    Summarization settings
    Back
```

## Visual Style

- Conversational tone throughout (friendly, not cutesy)
- Blue `?` for prompts
- Green `✓` for success/completed
- Cyan for user input and selected items
- Dim gray for hints and contextual explanations
- `●` running / `○` stopped for service status
- `❯` for menu selector
- 1-2 lines of dim explanatory text before each prompt
- `indicatif` spinners for async operations
- Educational: explain concepts when introducing them for the first time

## Interaction Model

- Every config change persists immediately (no "save and exit")
- Every action returns to its parent menu
- Ctrl-C at any point exits cleanly; whatever was saved stays saved
- No back navigation in onboarding (it's fast enough to re-run with `tenex-launcher onboard`)
- Dashboard loop: print status → menu → action → repeat
- MCP configuration excluded (per-project, managed by backend)
