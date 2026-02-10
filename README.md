# TENEX

Native macOS menu bar app for [TENEX](https://tenex.chat) — a multi-agent AI coordination system built on Nostr.

Manages the backend daemon, provides configuration UI, and embeds the chat client in a single app.

## What it does

- **Menu bar daemon control** — start/stop the backend, monitor status, view real-time logs
- **Configuration UI** — manage LLM providers, model assignments, relays, and global settings (persisted to `~/.tenex/`)
- **Chat client** — conversations, projects, inbox, and live feed via Rust FFI core

## Download

Grab the latest DMG from [Releases](https://github.com/tenex-chat/package/releases). Open it and drag TENEX to Applications.

On first launch, it appears in your menu bar (not the Dock). Click the icon → "Open TENEX..." to open the chat window.

## Build from source

### Prerequisites

```bash
# Rust (for tenex-core FFI)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-darwin

# Bun (TypeScript runtime for backend)
curl -fsSL https://bun.sh/install | bash

# Tuist (Xcode project generation)
curl -Ls https://install.tuist.io | bash
```

### Build

```bash
git clone --recursive git@github.com:tenex-chat/package.git
cd package

# Build Rust core
(cd deps/tui && cargo build -p tenex-core --release --target aarch64-apple-darwin)

# Install backend deps
(cd deps/backend && bun install)

# Generate Xcode project and build
tuist generate --no-open
xcodebuild -project TenexLauncher.xcodeproj -scheme TenexLauncher -configuration Release build
```

Or open in Xcode: `tuist generate` then Cmd+R.

## Architecture

```
Sources/TenexLauncher/     SwiftUI menu bar app (macOS 14+)
Sources/UIKitShim/         Module shim for iOS → macOS compilation
deps/backend/              TypeScript backend daemon (Bun)
deps/tui/                  Rust core + iOS chat client sources
```

| Layer | Tech |
|-------|------|
| UI | SwiftUI, Tuist, Kingfisher |
| Backend | TypeScript, Bun, ai-sdk, NDK |
| Core | Rust (uniffi FFI) |
| Protocol | Nostr |
| CI | GitHub Actions, Developer ID notarization |

The app embeds the TenexMVP iOS chat client sources directly, compiled for macOS with a platform compatibility layer. The Rust core (`libtenex_core.a`) handles event storage, crypto, and performance-critical operations via FFI.

## Configuration

All config lives in `~/.tenex/` (override with `TENEX_BASE_DIR` env var):

| File | Contents |
|------|----------|
| `config.json` | Relays, keys, logging, system prompt, compression |
| `providers.json` | LLM provider credentials (OpenAI, Anthropic, Google, etc.) |
| `llms.json` | Model configs and role assignments (default, summarization, search, etc.) |

These can be edited through the Settings UI or directly as JSON.

## License

MIT
