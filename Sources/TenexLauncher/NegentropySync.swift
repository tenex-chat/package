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

/// Legacy relay sync-status wrapper.
/// The relay no longer exposes a /stats endpoint, so this remains idle.
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
    private weak var orchestrator: OrchestratorManager?

    // MARK: - Configuration

    func configure(
        localRelayURL: String,
        pollIntervalSeconds: TimeInterval = 10,
        orchestrator: OrchestratorManager
    ) {
        self.localRelayURL = localRelayURL
        self.pollIntervalSeconds = pollIntervalSeconds
        self.orchestrator = orchestrator
    }

    // MARK: - Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        status = .idle
    }

    func stop() {
        enabled = false
        pollTask?.cancel()
        pollTask = nil
        status = .idle
        logger.info("Sync status polling stopped")
    }

    func syncNow() async {
        guard let orchestrator, orchestrator.relayStatus == .running else {
            status = .lastSyncFailed(Date(), "Local relay not running")
            return
        }
        status = .idle
    }
}
