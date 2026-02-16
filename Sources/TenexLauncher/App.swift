import SwiftUI

@main
struct TenexLauncherApp: App {
    @StateObject private var daemon = DaemonManager()
    @StateObject private var configStore = ConfigStore()
    @StateObject private var coreManager = TenexCoreManager()
    @StateObject private var strfryManager = StrfryManager()
    @StateObject private var negentropySync = NegentropySync()
    @StateObject private var pendingEventsQueue = PendingEventsQueue()

    @State private var isLoggedIn = false
    @State private var userNpub = ""
    @State private var isAttemptingAutoLogin = false
    @State private var autoLoginError: String?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                daemon: daemon,
                strfryManager: strfryManager,
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
                strfryManager: strfryManager,
                negentropySync: negentropySync,
                pendingEventsQueue: pendingEventsQueue
            )
            .frame(minWidth: 700, minHeight: 500)
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
            .onChange(of: isLoggedIn) { _, loggedIn in
                if loggedIn {
                    coreManager.clearLiveFeed()
                    coreManager.registerEventCallback()
                    Task { @MainActor in await coreManager.fetchData() }
                } else {
                    coreManager.unregisterEventCallback()
                    coreManager.clearLiveFeed()
                }
            }
        }
        .defaultSize(width: 1000, height: 700)
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
            let privacyMode = localRelay.privacyMode ?? false

            strfryManager.configure(port: port, privacyMode: privacyMode)
            await strfryManager.start()

            // If relay started successfully, start sync and drain pending events
            if strfryManager.status == .running {
                negentropySync.configure(
                    localRelayURL: strfryManager.localRelayURL,
                    remoteRelays: localRelay.syncRelays ?? ["wss://tenex.chat"],
                    strfryManager: strfryManager
                )
                negentropySync.start()

                // Drain any pending events (waits for queue to load first)
                _ = await pendingEventsQueue.drainWhenReady(relayURL: strfryManager.localRelayURL)
            }
        }
    }

}
