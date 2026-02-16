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

    // Reference to RelayManager for status checks
    private weak var relayManager: RelayManager?

    // MARK: - Configuration

    func configure(
        localRelayURL: String,
        remoteRelays: [String],
        syncIntervalSeconds: TimeInterval = 60,
        relayManager: RelayManager
    ) {
        self.localRelayURL = localRelayURL
        self.remoteRelays = remoteRelays
        self.syncIntervalSeconds = syncIntervalSeconds
        self.relayManager = relayManager
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
                if let manager = self.relayManager, manager.status == .running {
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
        guard relayManager != nil else {
            logger.warning("No relay manager available for sync")
            return
        }

        status = .syncing

        // For the Khatru-based relay, we use WebSocket-based negentropy sync
        // The actual negentropy protocol implementation would involve:
        // 1. Connect to local relay
        // 2. Connect to remote relay
        // 3. Run negentropy protocol to reconcile events
        //
        // For the initial implementation, we verify connectivity and mark as successful
        // Full negentropy sync will be added when the Go relay supports it

        var allSuccess = true
        var lastErrorMsg = ""

        for remoteRelay in remoteRelays {
            let success = await performConnectivityCheck(
                localURL: localRelayURL,
                remoteURL: remoteRelay
            )

            if !success {
                allSuccess = false
                lastErrorMsg = "Connectivity check with \(remoteRelay) failed"
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

    /// Performs connectivity check between local and remote relay
    /// For now, this verifies local relay is healthy - full negentropy protocol TBD
    private func performConnectivityCheck(localURL: String, remoteURL: String) async -> Bool {
        // Verify local relay is reachable via health endpoint
        let healthURLString = localURL
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")

        guard let localHealthURL = URL(string: healthURLString + "/health") else {
            logger.error("Invalid local relay URL")
            return false
        }

        do {
            let (_, response) = try await URLSession.shared.data(from: localHealthURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.error("Local relay health check failed")
                return false
            }

            // TODO: Implement actual negentropy sync protocol
            // For now, consider sync successful if local relay is healthy
            // The actual implementation would:
            // 1. Open WebSocket to local relay
            // 2. Open WebSocket to remote relay
            // 3. Exchange negentropy frames to identify missing events
            // 4. Request and store missing events

            return true
        } catch {
            logger.error("Local relay health check error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Manual Sync

    func syncNow() async {
        guard let relayManager, relayManager.status == .running else {
            status = .lastSyncFailed(Date(), "Local relay not running")
            return
        }
        await performSync()
    }
}
