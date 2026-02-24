import ServiceManagement
import SwiftUI

@main
struct TenexLauncherApp: App {
    @StateObject private var daemon = DaemonManager()
    @StateObject private var configStore = ConfigStore()
    @StateObject private var coreManager = TenexCoreManager()
    @StateObject private var relayManager = RelayManager()
    @StateObject private var ngrokManager = NgrokManager()
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
                daemon: daemon,
                configStore: configStore,
                relayManager: relayManager,
                ngrokManager: ngrokManager,
                negentropySync: negentropySync
            )
        } label: {
            let nsImage = MenuBarIcon.create(running: daemon.status == .running)
            Image(nsImage: nsImage)
        }
        .menuBarExtraStyle(.menu)

        // Settings / daemon management window
        Window("TENEX Settings", id: "settings") {
            MainWindow(
                daemon: daemon,
                configStore: configStore,
                coreManager: coreManager,
                relayManager: relayManager,
                negentropySync: negentropySync,
                pendingEventsQueue: pendingEventsQueue
            )
            .frame(minWidth: 700, minHeight: 500)
            .onChange(of: configStore.needsOnboarding) { _, needsOnboarding in
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
                        .environmentObject(coreManager)
                } else {
                    LoginView(
                        isLoggedIn: $isLoggedIn,
                        userNpub: $userNpub,
                        autoLoginError: autoLoginError
                    )
                    .environmentObject(coreManager)
                }
            }
            .frame(minWidth: 800, minHeight: 600)
            .onChange(of: coreManager.isInitialized) { _, isInitialized in
                if isInitialized {
                    // Start local relay if enabled and auto-start is on
                    startLocalRelayIfNeeded()
                    attemptAutoLogin()
                }
            }
            .onChange(of: configStore.needsOnboarding) { _, needsOnboarding in
                if !needsOnboarding {
                    startAllServices()
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
        daemon.start()
        startLocalRelayIfNeeded()
        attemptAutoLogin()

        if configStore.config.launchAtLogin == true {
            try? SMAppService.mainApp.register()
        }
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

    private func startLocalRelayIfNeeded() {
        guard let localRelay = configStore.config.localRelay,
              localRelay.enabled == true,
              localRelay.autoStart != false else {
            return
        }

        Task { @MainActor in
            let port = localRelay.port ?? 7777

            relayManager.configure(
                port: port,
                syncRelays: localRelay.syncRelays ?? ["wss://tenex.chat"]
            )
            await relayManager.start()

            // If relay started successfully, start sync status polling and drain pending events
            if relayManager.status == .running {
                negentropySync.configure(
                    localRelayURL: relayManager.localRelayURL,
                    relayManager: relayManager
                )
                negentropySync.start()

                // Drain any pending events (waits for queue to load first)
                _ = await pendingEventsQueue.drainWhenReady(relayURL: relayManager.localRelayURL)

                // Start ngrok tunnel if enabled
                if localRelay.ngrokEnabled == true {
                    ngrokManager.configure(port: port)
                    await ngrokManager.start()
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
