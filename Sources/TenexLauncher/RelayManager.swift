import Foundation
import os

enum RelayStatus: Equatable {
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

/// Manages the Khatru-based local Nostr relay process lifecycle
@MainActor
final class RelayManager: ObservableObject {
    @Published var status: RelayStatus = .stopped
    @Published var recentLogs: [String] = []
    @Published var lastError: String?
    @Published var lastSuccessfulSync: Date?
    @Published var uptime: TimeInterval = 0

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let maxLogLines = 100
    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "relay")

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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tenex")
            .appendingPathComponent("relay.json")
    }

    // MARK: - Binary Location

    /// Detect current machine architecture
    private var machineArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Binary name for current architecture
    private var binaryName: String {
        "tenex-relay-\(machineArchitecture)"
    }

    /// Resolve the path to the relay binary.
    /// Priority: bundled binary > dev path
    var relayExecutablePath: String? {
        // 1. Bundled binary (production)
        if let bundled = Bundle.main.path(forResource: binaryName, ofType: nil) {
            return bundled
        }

        // 2. Dev path in deps
        let devPath = bundlePath("deps/khatru-relay/dist/\(binaryName)")
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        // 3. Try generic name without architecture suffix
        if let bundledGeneric = Bundle.main.path(forResource: "tenex-relay", ofType: nil) {
            return bundledGeneric
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

        guard let executable = relayExecutablePath else {
            lastError = "Cannot find relay binary. Looked for: bundled \(binaryName), deps/khatru-relay/dist/\(binaryName)"
            status = .failed
            logger.error("No relay executable found for architecture \(self.machineArchitecture)")
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
            try ensureConfig()
        } catch {
            status = .failed
            lastError = "Failed to setup directories: \(error.localizedDescription)"
            logger.error("Failed to setup relay directories: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["-config", configPath.path]

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
                logger.info("Relay started successfully on port \(self.port)")
            } else {
                status = .failed
                lastError = "Relay failed to become ready within timeout"
                proc.terminate()
                process = nil
                logger.error("Relay failed readiness check")
            }
        } catch {
            status = .failed
            lastError = error.localizedDescription
            process = nil
            logger.error("Failed to start relay: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopHealthMonitoring()

        guard let proc = process, proc.isRunning else {
            status = .stopped
            process = nil
            return
        }

        // Send SIGTERM for graceful shutdown
        proc.terminate()

        // Give it 5 seconds, then send SIGINT as fallback
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

    /// Write relay config file with current settings.
    /// Always overwrites to ensure the Go relay uses the current Swift-side config.
    private func ensureConfig() throws {
        let config: [String: Any] = [
            "port": port,
            "data_dir": dataDir.path,
            "nip11": [
                "name": "TENEX Local Relay",
                "description": "Local Nostr relay for TENEX",
                "pubkey": "",
                "contact": "",
                "supported_nips": [1, 2, 4, 9, 11, 12, 16, 20, 22, 33, 40, 42, 77],
                "software": "tenex-khatru-relay",
                "version": "0.1.0"
            ],
            "limits": [
                "max_message_length": 524288,
                "max_subscriptions": 100,
                "max_filters": 50,
                "max_event_tags": 2500,
                "max_content_length": 102400
            ],
            "negentropy": [
                "enabled": true
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: config, options: .prettyPrinted)
        try data.write(to: configPath)
    }

    // MARK: - Readiness & Health

    private func waitForReadiness() async -> Bool {
        let maxAttempts = 50  // 5 seconds at 100ms intervals
        let checkInterval: UInt64 = 100_000_000  // 100ms in nanoseconds

        for _ in 0..<maxAttempts {
            if await checkHealthEndpoint() {
                return true
            }
            try? await Task.sleep(nanoseconds: checkInterval)
        }
        return false
    }

    /// Check health endpoint instead of raw socket
    private func checkHealthEndpoint() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
        } catch {
            // Connection refused or other error - relay not ready yet
        }
        return false
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

                let healthy = await self.checkHealthEndpoint()
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
        logger.error("Relay failure: \(reason)")
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

    // MARK: - Event Publishing

    /// Determines if an event should be queued for later delivery.
    /// Returns true when the local relay is not running.
    var shouldQueueEvents: Bool {
        status != .running
    }

    /// Determines if events can be published (local relay must be running)
    var canPublishEvents: Bool {
        status == .running
    }
}
