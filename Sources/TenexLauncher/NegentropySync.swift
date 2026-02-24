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

/// Polls the Go relay's /stats endpoint to surface sync status in the UI.
/// Actual sync is handled by the Go relay's Syncer.
@MainActor
final class NegentropySync: ObservableObject {
    @Published var status: SyncStatus = .idle
    @Published var lastSuccessfulSync: Date?
    @Published var syncCount: Int = 0

    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "sync-status")

    private var localRelayURL: String = "ws://127.0.0.1:7777"
    private var pollIntervalSeconds: TimeInterval = 10
    private var enabled: Bool = false
    private var pollTask: Task<Void, Never>?
    private weak var relayManager: RelayManager?

    // MARK: - Configuration

    func configure(
        localRelayURL: String,
        pollIntervalSeconds: TimeInterval = 10,
        relayManager: RelayManager
    ) {
        self.localRelayURL = localRelayURL
        self.pollIntervalSeconds = pollIntervalSeconds
        self.relayManager = relayManager
    }

    // MARK: - Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        startPollLoop()
        logger.info("Sync status polling started (interval: \(Int(self.pollIntervalSeconds))s)")
    }

    func stop() {
        enabled = false
        pollTask?.cancel()
        pollTask = nil
        status = .idle
        logger.info("Sync status polling stopped")
    }

    // MARK: - Poll Loop

    private func startPollLoop() {
        pollTask?.cancel()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled else { break }

                if let manager = self.relayManager, manager.status == .running {
                    await self.pollStats()
                }

                let sleepNanos = UInt64(self.pollIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
        }
    }

    // MARK: - Stats Polling

    private func pollStats() async {
        let httpURL = localRelayURL
            .replacingOccurrences(of: "ws://", with: "http://")
            .replacingOccurrences(of: "wss://", with: "https://")

        guard let statsURL = URL(string: httpURL + "/stats") else {
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: statsURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let syncInfo = json["sync"] as? [String: Any] else {
                // Relay is running but sync stats not yet available
                if status == .idle {
                    status = .syncing
                }
                return
            }

            let eventsSynced = syncInfo["events_synced"] as? Int ?? 0

            // Parse last_sync_time
            var lastSync: Date?
            if let timeStr = syncInfo["last_sync_time"] as? String {
                let formatter = ISO8601DateFormatter()
                lastSync = formatter.date(from: timeStr)
            }

            // Check relay connection statuses
            var allConnected = true
            if let relayStatus = syncInfo["relay_status"] as? [String: Any] {
                for (_, value) in relayStatus {
                    if let info = value as? [String: Any],
                       let connected = info["connected"] as? Bool,
                       !connected {
                        allConnected = false
                    }
                }
            }

            syncCount = eventsSynced
            if let lastSync {
                lastSuccessfulSync = lastSync
                status = .lastSyncSuccess(lastSync)
            } else if allConnected {
                status = .syncing
            }

        } catch {
            // Stats endpoint unreachable - don't change status, relay might be temporarily busy
        }
    }

    // MARK: - Manual Sync

    func syncNow() async {
        guard let relayManager, relayManager.status == .running else {
            status = .lastSyncFailed(Date(), "Local relay not running")
            return
        }
        // Trigger an immediate poll to refresh the displayed stats
        await pollStats()
    }
}
