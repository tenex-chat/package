# AGENTS.md - TenexLauncher Sources

Guidelines for AI agents working in the main Swift source directory.

## Directory Purpose

Primary SwiftUI application code for the TENEX Launcher menu bar app.

## Architecture

### State Management
- `DaemonManager` - Backend daemon lifecycle (ObservableObject)
- `ConfigStore` - JSON config persistence (ObservableObject)
- `TenexCoreManager` - Rust FFI bridge (in TenexMVPBridge.swift)

### UI Structure
- `App.swift` - Entry point, defines three scenes (MenuBar, Settings, Main)
- `*View.swift` - SwiftUI views for settings panels
- `MenuBarIcon.swift` - Custom menu bar icon drawing

## Key Patterns

### Adding a New Settings Panel
1. Create `NewFeatureView.swift` with SwiftUI view
2. Add case to sidebar in `MainWindow.swift`
3. If needs config, add model to `ConfigModels.swift`
4. Wire persistence through `ConfigStore`

### Adding Config Fields
1. Add property to appropriate struct in `ConfigModels.swift`
2. ConfigStore auto-persists via Codable

### iOS Compatibility
When using types from `deps/tui/ios-app/`:
- Import via `UIKitShim` module
- Add macOS shims to `PlatformCompat.swift` if needed

## FFI Types

These come from Rust via uniffi (don't modify):
- `TenexCore`, `SafeTenexCore`
- `MessageInfo`, `ConversationFullInfo`
- Event callbacks

## File Dependencies

```
App.swift
├── DaemonManager (ObservableObject)
├── ConfigStore (ObservableObject)
├── TenexCoreManager (Rust bridge)
└── Views
    ├── MenuBarView
    ├── MainWindow (Settings)
    └── MainTabView (Chat)
```

## Do Not

- Create UIKit dependencies (this is macOS)
- Modify FFI-generated types
- Store state outside ObservableObjects
- Block main thread with Rust calls (use async)
