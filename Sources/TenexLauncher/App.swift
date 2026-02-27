import SwiftUI

@main
struct TenexLauncherApp: App {
    @StateObject private var orchestrator = OrchestratorManager()
    @State private var coreManager = TenexCoreManager()
    @StateObject private var negentropySync = NegentropySync()
    @StateObject private var pendingEventsQueue = PendingEventsQueue()
    @NSApplicationDelegateAdaptor private var appDelegate: DockVisibilityDelegate

    @State private var isLoggedIn = false
    @State private var userNpub = ""
    @State private var isAttemptingAutoLogin = false
    @State private var autoLoginError: String?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                orchestrator: orchestrator,
                negentropySync: negentropySync,
                pendingEventsQueue: pendingEventsQueue
            )
        } label: {
            let nsImage = MenuBarIcon.create(running: orchestrator.daemonStatus == .running)
            Image(nsImage: nsImage)
        }
        .menuBarExtraStyle(.menu)

        // Settings / daemon management window
        Window("TENEX Settings", id: "settings") {
            MainWindow(
                orchestrator: orchestrator,
                coreManager: coreManager,
                negentropySync: negentropySync,
                pendingEventsQueue: pendingEventsQueue
            )
            .frame(minWidth: 700, minHeight: 500)
            .onChange(of: orchestrator.needsOnboarding) { _, needsOnboarding in
                if !needsOnboarding {
                    startAllServices()
                }
            }
        }
        .defaultSize(width: 800, height: 600)

        // Chat window — the TenexMVP app UI
        Window("TENEX", id: "main") {
            Group {
                if !coreManager.isInitialized {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Initializing TENEX...")
                            .foregroundStyle(.secondary)
                        if let error = coreManager.initializationError {
                            Text(error).foregroundStyle(.red).font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isAttemptingAutoLogin {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Logging in...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoggedIn {
                    MainTabView(userNpub: $userNpub, isLoggedIn: $isLoggedIn)
                        .environment(coreManager)
                } else {
                    LoginView(
                        isLoggedIn: $isLoggedIn,
                        userNpub: $userNpub,
                        autoLoginError: autoLoginError
                    )
                    .environment(coreManager)
                }
            }
            .frame(minWidth: 800, minHeight: 600)
            .onChange(of: coreManager.isInitialized) { _, isInitialized in
                if isInitialized {
                    attemptAutoLogin()
                }
            }
            .onChange(of: isLoggedIn) { _, loggedIn in
                if loggedIn {
                    coreManager.registerEventCallback()
                    Task { @MainActor in await coreManager.fetchData() }
                } else {
                    coreManager.unregisterEventCallback()
                }
            }
        }
        .defaultSize(width: 1000, height: 700)
    }

    private func startAllServices() {
        orchestrator.startAllServices(
            negentropySync: negentropySync,
            pendingEventsQueue: pendingEventsQueue
        )
        attemptAutoLogin()
    }

    private func attemptAutoLogin() {
        isAttemptingAutoLogin = true
        autoLoginError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = coreManager.attemptAutoLogin()

            DispatchQueue.main.async {
                isAttemptingAutoLogin = false
                switch result {
                case .noCredentials:
                    break
                case .success(let npub):
                    userNpub = npub
                    isLoggedIn = true
                case .invalidCredential(let error):
                    print("[TENEX] Stored credential invalid: \(error)")
                    Task { _ = await coreManager.clearCredentials() }
                    autoLoginError = "Stored credential was invalid. Please log in again."
                case .transientError(let error):
                    print("[TENEX] Auto-login transient error: \(error)")
                    autoLoginError = "Could not auto-login: \(error)"
                }
            }
        }
    }

}

// MARK: - Dock Visibility

class DockVisibilityDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowChanged), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowChanged(_ notification: Notification) {
        // Defer so the window state has settled
        DispatchQueue.main.async { Self.updateDockVisibility() }
    }

    static func updateDockVisibility() {
        let hasVisibleWindow = NSApp.windows.contains {
            $0.isVisible && $0.canBecomeKey && $0.className != "NSStatusBarWindow"
        }
        let desired: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
            if desired == .regular {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}
