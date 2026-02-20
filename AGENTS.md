# AGENTS.md - TENEX Launcher

Guidelines for AI agents working on this project.

## Project Overview

Native macOS menu bar application (macOS 14+) for TENEX multi-agent AI coordination system.

## Critical Context

1. **Submodules Required**: Always ensure `deps/backend/` and `deps/tui/` are initialized:
   ```bash
   git submodule update --init --recursive
   ```

2. **Build System**: This project uses **Tuist**, not raw Xcode project files.
   - Run `tuist generate` to create/update Xcode project
   - Never manually edit `.xcodeproj` files

3. **FFI Layer**: Rust core (`deps/tui/tenex-core`) compiles to `libtenex_core.a` with uniffi Swift bindings.

## Key Conventions

### Swift Code Style
- SwiftUI for all UI (no AppKit unless necessary)
- ObservableObject pattern for state management
- Async/await for concurrency

### Configuration
- All user config lives in `~/.tenex/` directory
- `ConfigStore.swift` handles persistence
- Models defined in `ConfigModels.swift`

### Platform Compatibility
- iOS code from `deps/tui/ios-app/` is reused via `UIKitShim` module
- Add macOS shims in `PlatformCompat.swift` when needed

## Build Commands

```bash
# Full build
tuist generate --no-open && xcodebuild -project TenexLauncher.xcodeproj -scheme TenexLauncher build

# Rust core only
(cd deps/tui && cargo build -p tenex-core --release --target aarch64-apple-darwin)

# Backend deps
(cd deps/backend && bun install)
```

## File Locations

| What | Where |
|------|-------|
| App entry | `Sources/TenexLauncher/App.swift` |
| Rust bridge | `Sources/TenexLauncher/TenexMVPBridge.swift` |
| Config models | `Sources/TenexLauncher/ConfigModels.swift` |
| UI views | `Sources/TenexLauncher/*View.swift` |
| Build config | `Project.swift` |

## Testing

No test infrastructure in this repository. Run tests in submodules:
- Rust: `(cd deps/tui && cargo test)`
- Backend: `(cd deps/backend && bun test)` (if available)

## Do Not

- Modify `.xcodeproj` directly (use Tuist)
- Commit uninitialized submodule references
- Add AppKit dependencies without justification
- Store secrets in code (use Keychain via `KeychainService`)
