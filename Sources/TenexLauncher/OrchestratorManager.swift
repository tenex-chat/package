import Foundation
import os
import ServiceManagement

/// Bridges the Rust `OrchestratorCore` (via UniFFI) into SwiftUI's
/// reactive world. Replaces the old `ConfigStore`, `DaemonManager`,
/// `RelayManager`, and `NgrokManager` classes.
@MainActor
final class OrchestratorManager: ObservableObject {
    let core: OrchestratorCore

    // MARK: - Config (decoded from Rust JSON)

    @Published var config: TenexConfig = TenexConfig()
    @Published var launcher: LauncherConfig = LauncherConfig()
    @Published var providers: TenexProviders = TenexProviders()
    @Published var llms: TenexLLMs = TenexLLMs()
    @Published var embed: TenexEmbedConfig = TenexEmbedConfig()
    @Published var image: TenexImageConfig = TenexImageConfig()
    @Published var loadError: String?

    // MARK: - Service Status (polled from Rust)

    @Published var daemonStatus: FfiProcessStatus = .stopped
    @Published var daemonError: String?
    @Published var daemonLogs: [String] = []

    @Published var relayStatus: FfiProcessStatus = .stopped
    @Published var relayError: String?
    @Published var relayLogs: [String] = []
    @Published var relayUrl: String?

    @Published var ngrokStatus: FfiProcessStatus = .stopped
    @Published var ngrokError: String?
    @Published var ngrokLogs: [String] = []
    @Published var ngrokTunnelUrl: String?

    // MARK: - Onboarding

    @Published var onboardingStep: FfiOnboardingStep = .identity

    // MARK: - Providers

    @Published var providerInfos: [ProviderInfo] = []

    // MARK: - Private

    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "orchestrator")
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }()
    private var statusPollTask: Task<Void, Never>?

    // MARK: - Init

    init(repoRoot: String? = nil) {
        self.core = OrchestratorCore(repoRoot: repoRoot)
        reloadAll()
    }

    // MARK: - Lifecycle

    func initialize() {
        do {
            try core.`init`()
        } catch {
            logger.error("Orchestrator init failed: \(error.localizedDescription)")
            loadError = error.localizedDescription
        }
    }

    func shutdown() {
        statusPollTask?.cancel()
        statusPollTask = nil

        do {
            try core.shutdown()
        } catch {
            logger.error("Orchestrator shutdown failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Config I/O

    func reloadAll() {
        loadError = nil
        config = decodeJSON(core.loadConfigJson()) ?? TenexConfig()
        launcher = decodeJSON(core.loadLauncherJson()) ?? LauncherConfig()
        providers = decodeJSON(core.loadProvidersJson()) ?? TenexProviders()
        llms = decodeJSON(core.loadLlmsJson()) ?? TenexLLMs()
        embed = decodeJSON(core.loadEmbedJson()) ?? TenexEmbedConfig()
        image = decodeJSON(core.loadImageJson()) ?? TenexImageConfig()
    }

    func saveConfig() {
        guard let json = encodeJSON(config) else { return }
        do {
            try core.saveConfigJson(json: json)
        } catch {
            loadError = "Error saving config: \(error.localizedDescription)"
        }
    }

    func saveProviders() {
        guard let json = encodeJSON(providers) else { return }
        do {
            try core.saveProvidersJson(json: json)
        } catch {
            loadError = "Error saving providers: \(error.localizedDescription)"
        }
    }

    func saveLLMs() {
        guard let json = encodeJSON(llms) else { return }
        do {
            try core.saveLlmsJson(json: json)
        } catch {
            loadError = "Error saving LLMs: \(error.localizedDescription)"
        }
    }

    func saveEmbed() {
        guard let json = encodeJSON(embed) else { return }
        do {
            try core.saveEmbedJson(json: json)
        } catch {
            loadError = "Error saving embed config: \(error.localizedDescription)"
        }
    }

    func saveImage() {
        guard let json = encodeJSON(image) else { return }
        do {
            try core.saveImageJson(json: json)
        } catch {
            loadError = "Error saving image config: \(error.localizedDescription)"
        }
    }

    func saveLauncher() {
        guard let json = encodeJSON(launcher) else { return }
        do {
            try core.saveLauncherJson(json: json)
        } catch {
            loadError = "Error saving launcher config: \(error.localizedDescription)"
        }
    }

    func addProviderKey(providerId: String, apiKey: String) {
        do {
            try core.addProviderKey(providerId: providerId, apiKey: apiKey)
            reloadAll()
        } catch {
            loadError = "Failed to add provider key: \(error.localizedDescription)"
        }
    }

    func removeProviderKey(providerId: String, index: UInt32) {
        do {
            try core.removeProviderKey(providerId: providerId, index: index)
            reloadAll()
        } catch {
            loadError = "Failed to remove provider key: \(error.localizedDescription)"
        }
    }

    func reorderProviderKey(providerId: String, fromIndex: UInt32, toIndex: UInt32) {
        do {
            try core.reorderProviderKey(providerId: providerId, fromIndex: fromIndex, toIndex: toIndex)
            reloadAll()
        } catch {
            loadError = "Failed to reorder provider key: \(error.localizedDescription)"
        }
    }

    // MARK: - Paths

    static var tenexDir: URL {
        if let override = ProcessInfo.processInfo.environment["TENEX_BASE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".tenex")
    }

    // MARK: - Convenience

    var configExists: Bool { core.configExists() }
    var providersExist: Bool { core.providersExist() }
    var llmsExist: Bool { core.llmsExist() }
    var needsOnboarding: Bool { core.needsOnboarding() }

    // MARK: - Unified Startup

    func startAllServices(
        negentropySync: NegentropySync,
        pendingEventsQueue: PendingEventsQueue
    ) {
        initialize()
        startStatusPolling()

        let core = self.core
        let localRelay = self.launcher.localRelay
        let launchAtLogin = self.launcher.launchAtLogin

        Task.detached { [weak self] in
            let relayEnabled = localRelay?.enabled == true && localRelay?.autoStart != false

            // 1. Relay first (blocks up to 5s for readiness — off main thread)
            if relayEnabled {
                try? core.startRelay()
            }

            // 2. Daemon after relay is ready
            try? core.startDaemon()

            // 3. Ngrok after relay if configured
            if relayEnabled && localRelay?.ngrokEnabled == true {
                try? core.startNgrok()
            }

            // 4. Post-startup on main actor
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshStatus()

                if self.relayStatus == .running {
                    negentropySync.configure(
                        localRelayURL: self.localRelayURL,
                        orchestrator: self
                    )
                    negentropySync.start()
                }

                if launchAtLogin == true {
                    try? SMAppService.mainApp.register()
                }
            }

            // 5. Drain pending events
            if relayEnabled {
                let relayURL = await MainActor.run { [weak self] in
                    self?.localRelayURL ?? "ws://127.0.0.1:7777"
                }
                _ = await pendingEventsQueue.drainWhenReady(relayURL: relayURL)
            }
        }
    }

    // MARK: - Service Management

    func startDaemon() {
        do {
            try core.startDaemon()
            refreshStatus()
        } catch {
            daemonError = error.localizedDescription
            logger.error("Failed to start daemon: \(error.localizedDescription)")
        }
    }

    func stopDaemon() {
        do {
            try core.stopDaemon()
            refreshStatus()
        } catch {
            logger.error("Failed to stop daemon: \(error.localizedDescription)")
        }
    }

    func startRelay() {
        do {
            try core.startRelay()
            refreshStatus()
        } catch {
            relayError = error.localizedDescription
            logger.error("Failed to start relay: \(error.localizedDescription)")
        }
    }

    func stopRelay() {
        do {
            try core.stopRelay()
            refreshStatus()
        } catch {
            logger.error("Failed to stop relay: \(error.localizedDescription)")
        }
    }

    func startNgrok() {
        do {
            try core.startNgrok()
            refreshStatus()
        } catch {
            ngrokError = error.localizedDescription
            logger.error("Failed to start ngrok: \(error.localizedDescription)")
        }
    }

    func stopNgrok() {
        do {
            try core.stopNgrok()
            refreshStatus()
        } catch {
            logger.error("Failed to stop ngrok: \(error.localizedDescription)")
        }
    }

    // MARK: - Status Polling

    func startStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatus()
                self?.refreshLogs()
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    func stopStatusPolling() {
        statusPollTask?.cancel()
        statusPollTask = nil
    }

    func refreshStatus() {
        let snapshot = core.serviceStatus()
        daemonStatus = snapshot.daemonStatus
        daemonError = snapshot.daemonError
        relayStatus = snapshot.relayStatus
        relayError = snapshot.relayError
        relayUrl = snapshot.relayUrl
        ngrokStatus = snapshot.ngrokStatus
        ngrokError = snapshot.ngrokError
        ngrokTunnelUrl = snapshot.ngrokTunnelUrl
    }

    func refreshLogs() {
        daemonLogs = core.daemonLogs()
        relayLogs = core.relayLogs()
        ngrokLogs = core.ngrokLogs()
    }

    // MARK: - Providers

    func detectProviders() -> [ProviderInfo] {
        let infos = core.detectProviders()
        providerInfos = infos
        return infos
    }

    func autoConnectProviders() -> Bool {
        do {
            let changed = try core.autoConnectProviders()
            if changed {
                reloadAll()
            }
            return changed
        } catch {
            logger.error("Auto-connect failed: \(error.localizedDescription)")
            return false
        }
    }

    func connectProvider(id: String, apiKey: String) {
        do {
            try core.connectProvider(providerId: id, apiKey: apiKey)
            reloadAll()
        } catch {
            loadError = "Failed to connect provider: \(error.localizedDescription)"
        }
    }

    func disconnectProvider(id: String) {
        do {
            try core.disconnectProvider(providerId: id)
            reloadAll()
        } catch {
            loadError = "Failed to disconnect provider: \(error.localizedDescription)"
        }
    }

    func fetchModels(providerId: String) -> [String] {
        do {
            return try core.fetchModels(providerId: providerId)
        } catch {
            logger.error("Failed to fetch models: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Onboarding

    func advanceOnboarding() {
        core.onboardingNext()
        onboardingStep = core.onboardingStep()
    }

    func goBackOnboarding() {
        core.onboardingBack()
        onboardingStep = core.onboardingStep()
    }

    var onboardingComplete: Bool {
        core.onboardingIsComplete()
    }

    func seedDefaultLLMs() -> Bool {
        do {
            let changed = try core.seedDefaultLlms()
            if changed { reloadAll() }
            return changed
        } catch {
            logger.error("Seed LLMs failed: \(error.localizedDescription)")
            return false
        }
    }

    func saveOnboardingRelay(mode: String, remoteUrl: String = "", ngrokEnabled: Bool = false) {
        do {
            try core.saveOnboardingRelay(mode: mode, remoteUrl: remoteUrl, ngrokEnabled: ngrokEnabled)
            reloadAll()
        } catch {
            logger.error("Save relay config failed: \(error.localizedDescription)")
        }
    }

    func detectOpenClaw() -> String {
        core.detectOpenclaw()
    }

    func importOpenClawCredentials() -> Bool {
        do {
            let imported = try core.importOpenclawCredentials()
            if imported { reloadAll() }
            return imported
        } catch {
            logger.error("OpenClaw import failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Derived

    /// The WebSocket URL derived from the ngrok HTTPS tunnel
    var ngrokWssUrl: String? {
        ngrokTunnelUrl?.replacingOccurrences(of: "https://", with: "wss://")
    }

    /// The local relay WebSocket URL
    var localRelayURL: String {
        relayUrl ?? "ws://127.0.0.1:7777"
    }

    // MARK: - Private Helpers

    private func decodeJSON<T: Decodable>(_ json: String) -> T? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode \(T.self): \(error.localizedDescription)")
            loadError = "Decode error: \(error.localizedDescription)"
            return nil
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8)
        } catch {
            logger.error("Failed to encode \(T.self): \(error.localizedDescription)")
            loadError = "Encode error: \(error.localizedDescription)"
            return nil
        }
    }
}
