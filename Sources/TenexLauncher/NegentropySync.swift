import Foundation
import os

enum SyncStatus: Equatable {
    case idle
    case syncing
    case lastSyncSuccess(Date)
    case lastSyncFailed(Date, String)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .syncing: "Syncing..."
        case .lastSyncSuccess(let date): "Last sync: \(Self.formatDate(date))"
        case .lastSyncFailed(_, let error): "Failed: \(error)"
        }
    }

    var isSuccess: Bool {
        if case .lastSyncSuccess = self { return true }
        return false
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static func formatDate(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

@MainActor
final class NegentropySync: ObservableObject {
    @Published var status: SyncStatus = .idle
    @Published var lastSuccessfulSync: Date?
    @Published var syncCount: Int = 0

    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "negentropy-sync")

    // Configuration
    private var localRelayURL: String = "ws://127.0.0.1:7777"
    private var remoteRelays: [String] = ["wss://tenex.chat"]
    private var syncIntervalSeconds: TimeInterval = 60
    private var enabled: Bool = false

    // Event kinds to sync (TENEX protocol kinds)
    private let syncKinds: [Int] = [4199, 4129, 4200, 4201, 4202, 0, 14199]

    // Sync state
    private var syncTask: Task<Void, Never>?
    private var currentBackoff: TimeInterval = 60  // Backoff for failures, starts at 60s
    private let maxBackoff: TimeInterval = 900     // 15 minutes max backoff
    private let minBackoff: TimeInterval = 60      // 1 minute min backoff
    private var useBackoff: Bool = false           // Only use backoff after failures

    // Reference to StrfryManager for binary path
    private weak var strfryManager: StrfryManager?

    // MARK: - Configuration

    func configure(
        localRelayURL: String,
        remoteRelays: [String],
        syncIntervalSeconds: TimeInterval = 60,
        strfryManager: StrfryManager
    ) {
        self.localRelayURL = localRelayURL
        self.remoteRelays = remoteRelays
        self.syncIntervalSeconds = syncIntervalSeconds
        self.strfryManager = strfryManager
    }

    // MARK: - Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        currentBackoff = minBackoff
        useBackoff = false
        startSyncLoop()
        logger.info("Negentropy sync started with interval \(Int(self.syncIntervalSeconds))s")
    }

    func stop() {
        enabled = false
        syncTask?.cancel()
        syncTask = nil
        logger.info("Negentropy sync stopped")
    }

    // MARK: - Sync Loop

    private func startSyncLoop() {
        syncTask?.cancel()

        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled else { break }

                // Check if local relay is running
                if let manager = self.strfryManager, manager.status == .running {
                    await self.performSync()
                }

                // Use backoff interval on failures, configured interval on success
                let sleepInterval = self.useBackoff ? self.currentBackoff : self.syncIntervalSeconds
                let sleepNanos = UInt64(sleepInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }
    }

    // MARK: - Sync Execution

    private func performSync() async {
        guard let strfryManager else {
            logger.warning("No strfry manager available for sync")
            return
        }

        status = .syncing

        // Build the kind filter
        let kindFilter = syncKinds.map { String($0) }.joined(separator: ",")

        // Sync with each remote relay
        var allSuccess = true
        var lastErrorMsg = ""

        for remoteRelay in remoteRelays {
            // Sync DOWN: remote -> local
            let downSuccess = await runStrfrySync(
                direction: "down",
                remoteRelay: remoteRelay,
                kindFilter: kindFilter,
                strfryPath: strfryManager.strfryExecutablePath
            )

            // Sync UP: local -> remote
            let upSuccess = await runStrfrySync(
                direction: "up",
                remoteRelay: remoteRelay,
                kindFilter: kindFilter,
                strfryPath: strfryManager.strfryExecutablePath
            )

            if !downSuccess || !upSuccess {
                allSuccess = false
                lastErrorMsg = "Sync with \(remoteRelay) failed"
            }
        }

        if allSuccess {
            lastSuccessfulSync = Date()
            syncCount += 1
            status = .lastSyncSuccess(Date())
            currentBackoff = minBackoff  // Reset backoff on success
            useBackoff = false           // Use configured interval on success
            logger.info("Negentropy sync completed successfully")
        } else {
            status = .lastSyncFailed(Date(), lastErrorMsg)
            // Increase backoff: 60s -> 120s -> 300s -> ... -> 900s max
            currentBackoff = min(currentBackoff * 2, maxBackoff)
            useBackoff = true            // Use backoff interval after failure
            logger.error("Negentropy sync failed: \(lastErrorMsg)")
        }
    }

    private func runStrfrySync(
        direction: String,
        remoteRelay: String,
        kindFilter: String,
        strfryPath: String?
    ) async -> Bool {
        guard let strfryPath else {
            logger.error("strfry path not available")
            return false
        }

        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tenex")
            .appendingPathComponent("relay")
            .appendingPathComponent("strfry.conf")
            .path

        // Build command arguments
        // strfry sync <remote> --filter '{"kinds":[...]}' --dir <up|down>
        let filterJSON = "{\"kinds\":[\(kindFilter)]}"

        let arguments = [
            "--config=\(configPath)",
            "sync",
            remoteRelay,
            "--filter", filterJSON,
            "--dir", direction
        ]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: strfryPath)
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()

                    let success = process.terminationStatus == 0

                    if !success {
                        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                        let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        Task { @MainActor in
                            self.logger.error("strfry sync \(direction) failed: \(errorString)")
                        }
                    }

                    continuation.resume(returning: success)
                } catch {
                    Task { @MainActor in
                        self.logger.error("Failed to run strfry sync: \(error.localizedDescription)")
                    }
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Manual Sync

    func syncNow() async {
        guard let strfryManager, strfryManager.status == .running else {
            status = .lastSyncFailed(Date(), "Local relay not running")
            return
        }
        await performSync()
    }
}

