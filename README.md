# TENEX Package

This repository primarily provides `tenex-launcher-tui`: the interactive terminal launcher for [TENEX](https://tenex.chat).

It also includes the native macOS menu bar app (`TenexLauncher`) and shared orchestration code.

## Run `tenex-launcher-tui` (Main Package)

### Prerequisites

```bash
# Rust (cargo)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Bun (backend runtime)
curl -fsSL https://bun.sh/install | bash
```

### 1) Clone and initialize submodules

```bash
git clone git@github.com:tenex-chat/package.git
cd package
git submodule update --init --recursive
```

### 2) Install backend dependencies

```bash
(cd deps/backend && bun install)
```

### 3) First run (force onboarding)

```bash
cargo run -p tenex-launcher-tui -- onboard
```

### 4) Normal run

```bash
cargo run -p tenex-launcher-tui
```

### Useful environment variables

- `TENEX_BASE_DIR`: override config directory (default: `~/.tenex`)
- `TENEX_BACKEND`: explicit path to `tenex-daemon` binary (used by onboarding agent import)

Example with isolated config:

```bash
TENEX_BASE_DIR=/tmp/tenex-dev cargo run -p tenex-launcher-tui -- onboard
```

### Optional: build backend daemon binary

```bash
(cd deps/backend && bun run build)
```

This creates `deps/backend/dist/tenex-daemon`.
`tenex-launcher-tui` can still start the daemon via Bun without this binary, but building it enables onboarding agent import to run directly.

## Build macOS Menu Bar App (Optional)

If you want the native macOS app instead of the terminal launcher:

```bash
# Tuist (Xcode project generation)
curl -Ls https://install.tuist.io | bash

# Rust target for tenex-core FFI static library
rustup target add aarch64-apple-darwin

# Build Rust core for app FFI
(cd deps/tui && cargo build -p tenex-core --release --target aarch64-apple-darwin)

# Install backend deps
(cd deps/backend && bun install)

# Generate Xcode project and build
tuist generate --no-open
xcodebuild -project TenexLauncher.xcodeproj -scheme TenexLauncher -configuration Release build
```

Or open in Xcode: `tuist generate` then Cmd+R.

## Configuration

All config lives in `~/.tenex/` (or `TENEX_BASE_DIR`):

| File | Contents |
|------|----------|
| `config.json` | Relays, keys, logging, system prompt, compression |
| `providers.json` | LLM provider credentials |
| `llms.json` | Model configs and role assignments |
| `launcher.json` | Launcher-specific settings (relay/ngrok/launch behavior) |

## License

MIT
