import Foundation
import os

enum StrfryStatus: Equatable {
    case stopped
    case starting
    case running
    case failed

    var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting..."
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    var isOperational: Bool {
        self == .running
    }
}

@MainActor
final class StrfryManager: ObservableObject {
    @Published var status: StrfryStatus = .stopped
    @Published var recentLogs: [String] = []
    @Published var lastError: String?
    @Published var lastSuccessfulSync: Date?
    @Published var uptime: TimeInterval = 0

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let maxLogLines = 100
    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "strfry")

    // Health monitoring
    private var healthCheckTask: Task<Void, Never>?
    private var uptimeTimer: Timer?
    private var startTime: Date?
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    // Configuration
    private(set) var port: Int = 7777

    // Directories
    private var relayDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tenex")
            .appendingPathComponent("relay")
    }

    private var dataDir: URL {
        relayDir.appendingPathComponent("data")
    }

    private var configPath: URL {
        relayDir.appendingPathComponent("strfry.conf")
    }

    private var pendingEventsPath: URL {
        relayDir.appendingPathComponent("pending.json")
    }

    // MARK: - Binary Location

    /// Resolve the path to the strfry binary.
    /// Priority: bundled binary > system PATH
    var strfryExecutablePath: String? {
        // 1. Bundled binary (production)
        if let bundled = Bundle.main.path(forResource: "strfry", ofType: nil) {
            return bundled
        }

        // 2. Bundled binary in Resources/Binaries (dev)
        let devBundled = bundlePath("Resources/Binaries/strfry")
        if FileManager.default.fileExists(atPath: devBundled) {
            return devBundled
        }

        // 3. System PATH fallback (for development)
        let pathDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        for dir in pathDirs {
            let path = "\(dir)/strfry"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }

    // MARK: - Configuration

    func configure(port: Int) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() async {
        guard status != .running && status != .starting else { return }

        guard let executable = strfryExecutablePath else {
            lastError = "Cannot find strfry binary. Looked for: bundled binary, Resources/Binaries/strfry, /opt/homebrew/bin/strfry"
            status = .failed
            logger.error("No strfry executable found")
            return
        }

        // Check port availability
        if !isPortAvailable(port) {
            lastError = "Port \(port) is already in use"
            status = .failed
            logger.error("Port \(self.port) is already in use")
            return
        }

        status = .starting
        lastError = nil
        recentLogs = []
        consecutiveFailures = 0

        // Ensure directories exist
        do {
            try setupDirectories()
            try generateConfig()
        } catch {
            status = .failed
            lastError = "Failed to setup directories: \(error.localizedDescription)"
            logger.error("Failed to setup strfry directories: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["relay", "--config=\(configPath.path)"]
        proc.currentDirectoryURL = relayDir

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdoutPipe = stdout
        stderrPipe = stderr

        readPipe(stdout)
        readPipe(stderr)

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = process.terminationStatus
                self.stopHealthMonitoring()

                if self.status == .running || self.status == .starting {
                    if code == 0 {
                        self.status = .stopped
                    } else {
                        self.handleFailure(reason: "Process exited with code \(code)")
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc

            // Wait for readiness
            let ready = await waitForReadiness()
            if ready {
                status = .running
                startTime = Date()
                startHealthMonitoring()
                logger.info("strfry started successfully on port \(self.port)")
            } else {
                status = .failed
                lastError = "strfry failed to become ready within timeout"
                proc.terminate()
                process = nil  // Clear process reference on readiness failure
                logger.error("strfry failed readiness check")
            }
        } catch {
            status = .failed
            lastError = error.localizedDescription
            process = nil  // Clear process reference on start failure
            logger.error("Failed to start strfry: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopHealthMonitoring()

        guard let proc = process, proc.isRunning else {
            status = .stopped
            process = nil
            return
        }

        // Send SIGTERM for graceful shutdown (consistent with DaemonManager)
        proc.terminate()

        // Give it 5 seconds, then send SIGINT (interrupt) as fallback
        // Using interrupt() instead of SIGKILL for consistency with DaemonManager
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if proc.isRunning {
                proc.interrupt()
            }
        }

        status = .stopped
        process = nil
        startTime = nil
        uptime = 0
    }

    // MARK: - Directory & Config Setup

    private func setupDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: relayDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    private func generateConfig() throws {
        guard let templatePath = Bundle.main.path(forResource: "strfry.conf", ofType: "template") else {
            // Try dev path
            let devTemplate = bundlePath("Resources/strfry.conf.template")
            guard FileManager.default.fileExists(atPath: devTemplate) else {
                throw NSError(domain: "StrfryManager", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "strfry.conf.template not found"])
            }
            try generateConfigFrom(templatePath: devTemplate)
            return
        }
        try generateConfigFrom(templatePath: templatePath)
    }

    private func generateConfigFrom(templatePath: String) throws {
        var template = try String(contentsOfFile: templatePath, encoding: .utf8)

        // Replace placeholders
        template = template.replacingOccurrences(of: "${DATA_DIR}", with: dataDir.path)
        template = template.replacingOccurrences(of: "${PORT}", with: String(port))

        try template.write(to: configPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Readiness & Health

    private func waitForReadiness() async -> Bool {
        let maxAttempts = 50  // 5 seconds at 100ms intervals
        let checkInterval: UInt64 = 100_000_000  // 100ms in nanoseconds

        for _ in 0..<maxAttempts {
            if await checkWebSocketConnection() {
                return true
            }
            try? await Task.sleep(nanoseconds: checkInterval)
        }
        return false
    }

    private func checkWebSocketConnection() async -> Bool {
        // Simple TCP connection check to the port
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    private func startHealthMonitoring() {
        stopHealthMonitoring()

        // Uptime timer
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startTime else { return }
                self.uptime = Date().timeIntervalSince(start)
            }
        }

        // Health check task - every 10 seconds
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

                guard let self, self.status == .running else { continue }

                let healthy = await self.checkWebSocketConnection()
                if !healthy {
                    await self.handleHealthCheckFailure()
                } else {
                    self.consecutiveFailures = 0
                }
            }
        }
    }

    private func stopHealthMonitoring() {
        uptimeTimer?.invalidate()
        uptimeTimer = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    private func handleHealthCheckFailure() async {
        consecutiveFailures += 1
        logger.warning("Health check failed (\(self.consecutiveFailures)/\(self.maxConsecutiveFailures))")

        if consecutiveFailures >= maxConsecutiveFailures {
            handleFailure(reason: "Health check failed \(maxConsecutiveFailures) consecutive times")
        }
    }

    private func handleFailure(reason: String) {
        lastError = reason
        logger.error("strfry failure: \(reason)")
        status = .failed
    }

    // MARK: - Port Check

    private func isPortAvailable(_ port: Int) -> Bool {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return bindResult == 0
    }

    // MARK: - Pipe Reading

    private func readPipe(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                let lines = line.components(separatedBy: .newlines).filter { !$0.isEmpty }
                self.recentLogs.append(contentsOf: lines)
                if self.recentLogs.count > self.maxLogLines {
                    self.recentLogs.removeFirst(self.recentLogs.count - self.maxLogLines)
                }
            }
        }
    }

    // MARK: - Helpers

    func bundlePath(_ relative: String) -> String {
        if let repoRoot = Bundle.main.infoDictionary?["TenexRepoRoot"] as? String {
            return (repoRoot as NSString).appendingPathComponent(relative)
        }
        return (Bundle.main.resourcePath! as NSString).appendingPathComponent(relative)
    }

    // MARK: - WebSocket URL

    var localRelayURL: String {
        "ws://127.0.0.1:\(port)"
    }

    /// Returns the effective relay URL to use (local relay only)
    func effectiveRelayURL() -> String {
        localRelayURL
    }

    // MARK: - Event Queuing
    //
    // TODO: PRIVACY MODE WIRING REQUIRED
    //
    // The properties below (`shouldQueueEvents`, `canPublishEvents`) expose the logic for
    // determining when events should be queued vs published, but the actual wiring to
    // TenexCore's event publishing is NOT YET IMPLEMENTED.
    //
    // Current Architecture Problem:
    // - Event publishing happens in the Rust TenexCore layer (via FFI)
    // - Swift has no interception point for events before they're published
    // - The PendingEventsQueue exists but queueEvent() is never called
    //
    // Required Implementation (choose one approach):
    //
    // OPTION A: Rust-side Integration (Recommended)
    // 1. Add a "privacy_mode_enabled" and "local_relay_available" config/state to TenexCore
    // 2. Modify TenexCore's event publishing logic to:
    //    - If privacy_mode && !local_relay_available: queue locally (return early, don't publish)
    //    - If privacy_mode && local_relay_available: publish to local relay only
    //    - If !privacy_mode: publish normally (with fallback)
    // 3. Add FFI methods: set_privacy_mode(bool), set_local_relay_status(bool)
    // 4. Call from Swift when strfryManager.status or privacyMode changes
    //
    // OPTION B: Swift Event Proxy (More Complex)
    // 1. Create a Swift event publishing proxy that TenexCore calls for outbound events
    // 2. Register this proxy via FFI callback (similar to TenexEventHandler)
    // 3. In the proxy: check shouldQueueEvents, either queue or forward to actual publish
    //
    // OPTION C: Notification-Based (Simplest but Limited)
    // 1. When user creates a new event in Swift UI, check shouldQueueEvents BEFORE
    //    calling TenexCore methods
    // 2. If shouldQueueEvents: call pendingEventsQueue.queueEvent() instead
    // 3. Limitation: only works for UI-initiated events, not background/automated ones
    //
    // Files to modify for Option A:
    // - tenex-core/src/lib.rs: Add privacy mode state and modify publish logic
    // - TenexLauncher/App.swift: Call set_privacy_mode/set_local_relay_status on status changes
    //
    // For now, these properties are provided for future integration.

    /// Determines if an event should be queued for later delivery.
    /// Returns true if privacy mode is enabled AND the local relay is not running.
    ///
    /// When this returns true, callers should queue the event via PendingEventsQueue.queueEvent()
    /// instead of publishing it directly.
    ///
    /// - Warning: This property is not yet wired to TenexCore. See TODO above for integration steps.
    var shouldQueueEvents: Bool {
        status != .running
    }

    /// Determines if events can be published (local relay must be running)
    ///
    /// - Warning: This property is not yet wired to TenexCore. See TODO above for integration steps.
    var canPublishEvents: Bool {
        status == .running
    }
}
