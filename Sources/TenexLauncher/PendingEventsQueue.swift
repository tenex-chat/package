import Foundation
import os

/// Manages a queue of pending events when the local relay is unavailable in privacy mode.
/// Events are persisted to disk and drained when the relay becomes available.
@MainActor
final class PendingEventsQueue: ObservableObject {
    @Published var pendingCount: Int = 0
    @Published var isDraining: Bool = false
    @Published private(set) var isLoaded: Bool = false

    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "pending-events")

    private var pendingEventsPath: URL {
        ConfigStore.tenexDir
            .appendingPathComponent("relay")
            .appendingPathComponent("pending.json")
    }

    // Timeout for WebSocket operations
    private let webSocketTimeout: TimeInterval = 10.0

    // MARK: - Event Storage

    struct PendingEvent: Codable {
        let id: String
        let eventJSON: String
        let timestamp: Date
    }

    private var pendingEvents: [PendingEvent] = []

    // Shared encoder/decoder with consistent date strategy
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Initialization

    init() {
        Task {
            await loadPendingEventsAsync()
        }
    }

    // MARK: - Queue Operations

    /// Queue an event for later delivery to the local relay.
    ///
    /// This method should be called when:
    /// - Privacy mode is enabled AND
    /// - The local relay is not running (strfryManager.shouldQueueEvents == true)
    ///
    /// - Parameters:
    ///   - id: The Nostr event ID (hex string)
    ///   - eventJSON: The full signed event as JSON string
    ///
    /// - Note: This method is currently NOT automatically wired to TenexCore's event publishing.
    ///   See StrfryManager.swift for integration TODO and options.
    func queueEvent(id: String, eventJSON: String) {
        let event = PendingEvent(id: id, eventJSON: eventJSON, timestamp: Date())
        pendingEvents.append(event)
        pendingCount = pendingEvents.count
        savePendingEventsAsync()
        logger.info("Queued event \(id) for later delivery")
    }

    /// Wait for the queue to finish loading, then drain if there are pending events.
    /// This is the recommended way to drain after relay startup to avoid race conditions.
    ///
    /// - Parameter relayURL: The WebSocket URL of the local relay (e.g., "ws://127.0.0.1:7777")
    /// - Returns: True if all events were successfully drained (or queue was empty)
    func drainWhenReady(relayURL: String) async -> Bool {
        // Wait for queue to finish loading (with timeout)
        let maxWaitNanos: UInt64 = 5_000_000_000  // 5 seconds
        let checkIntervalNanos: UInt64 = 100_000_000  // 100ms
        var elapsed: UInt64 = 0

        while !isLoaded && elapsed < maxWaitNanos {
            try? await Task.sleep(nanoseconds: checkIntervalNanos)
            elapsed += checkIntervalNanos
        }

        // Now drain if there are pending events
        if pendingCount > 0 {
            return await drainToRelay(relayURL: relayURL)
        }
        return true
    }

    /// Drain all pending events to the local relay
    func drainToRelay(relayURL: String) async -> Bool {
        guard !pendingEvents.isEmpty else { return true }
        guard !isDraining else { return false }

        isDraining = true
        defer { isDraining = false }

        logger.info("Draining \(self.pendingEvents.count) pending events to \(relayURL)")

        var successfulIds: Set<String> = []

        for event in pendingEvents {
            let success = await sendEventToRelay(eventJSON: event.eventJSON, relayURL: relayURL)
            if success {
                successfulIds.insert(event.id)
            } else {
                logger.warning("Failed to drain event \(event.id)")
                // Stop on first failure to maintain order
                break
            }
        }

        // Remove successfully sent events
        pendingEvents.removeAll { successfulIds.contains($0.id) }
        pendingCount = pendingEvents.count
        savePendingEventsAsync()

        let allSent = pendingEvents.isEmpty
        if allSent {
            logger.info("Successfully drained all pending events")
        } else {
            logger.warning("\(self.pendingEvents.count) events still pending")
        }

        return allSent
    }

    /// Clear all pending events (use with caution)
    func clearAll() {
        pendingEvents.removeAll()
        pendingCount = 0
        savePendingEventsAsync()
        logger.info("Cleared all pending events")
    }

    // MARK: - Persistence

    /// Load pending events asynchronously off the main actor
    private func loadPendingEventsAsync() async {
        let path = pendingEventsPath

        let result: (events: [PendingEvent], error: Error?)? = await Task.detached {
            guard FileManager.default.fileExists(atPath: path.path) else {
                return ([], nil)
            }

            do {
                let data = try Data(contentsOf: path)
                let events = try Self.decoder.decode([PendingEvent].self, from: data)
                return (events, nil)
            } catch {
                return ([], error)
            }
        }.value

        if let result {
            if let error = result.error {
                logger.error("Failed to load pending events: \(error.localizedDescription)")
            } else if !result.events.isEmpty {
                logger.info("Loaded \(result.events.count) pending events from disk")
            }
            pendingEvents = result.events
            pendingCount = result.events.count
        }

        isLoaded = true
    }

    /// Save pending events asynchronously off the main actor
    private func savePendingEventsAsync() {
        let path = pendingEventsPath
        let events = pendingEvents

        Task.detached {
            do {
                // Ensure directory exists
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                let data = try Self.encoder.encode(events)
                try data.write(to: path, options: .atomic)
            } catch {
                Task { @MainActor in
                    self.logger.error("Failed to save pending events: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Network

    private func sendEventToRelay(eventJSON: String, relayURL: String) async -> Bool {
        // strfry accepts events via WebSocket using the Nostr protocol ["EVENT", event_json]
        guard let wsURL = URL(string: relayURL) else {
            logger.error("Invalid relay URL: \(relayURL)")
            return false
        }

        // Parse the event to get its ID for matching the OK response
        guard let eventData = eventJSON.data(using: .utf8),
              let eventDict = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any],
              let eventId = eventDict["id"] as? String else {
            logger.error("Failed to parse event JSON to get ID")
            return false
        }

        // Create WebSocket task upfront so we can cancel it on timeout
        let session = URLSession(configuration: .default)
        let wsTask = session.webSocketTask(with: wsURL)

        return await withTaskGroup(of: Bool.self) { group in
            // Add timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.webSocketTimeout * 1_000_000_000))
                // Timeout fired - cancel the WebSocket and close the connection
                wsTask.cancel(with: .goingAway, reason: "Timeout".data(using: .utf8))
                return false
            }

            // Add actual send task
            group.addTask {
                await self.performWebSocketSend(
                    eventJSON: eventJSON,
                    eventId: eventId,
                    wsTask: wsTask
                )
            }

            // Return first completed result (either timeout or actual result)
            if let result = await group.next() {
                // Cancel remaining tasks and ensure WebSocket is closed
                group.cancelAll()
                // Defensive: ensure socket is closed regardless of which task finished first
                if wsTask.state != .completed && wsTask.state != .canceling {
                    wsTask.cancel(with: .normalClosure, reason: nil)
                }
                return result
            }
            return false
        }
    }

    private func performWebSocketSend(
        eventJSON: String,
        eventId: String,
        wsTask: URLSessionWebSocketTask
    ) async -> Bool {
        // Check if already cancelled (e.g., by timeout)
        guard wsTask.state != .canceling && wsTask.state != .completed else {
            return false
        }

        wsTask.resume()

        // Build Nostr EVENT message
        let message = "[\"EVENT\",\(eventJSON)]"

        do {
            try await wsTask.send(.string(message))
        } catch {
            logger.error("Failed to send event: \(error.localizedDescription)")
            wsTask.cancel(with: .goingAway, reason: nil)
            return false
        }

        // Wait for OK response with proper cancellation support
        return await waitForOKResponse(task: wsTask, eventId: eventId)
    }

    private func waitForOKResponse(
        task: URLSessionWebSocketTask,
        eventId: String
    ) async -> Bool {
        // Check for cancellation before each receive
        while !Task.isCancelled && task.state != .canceling && task.state != .completed {
            do {
                let message = try await task.receive()
                let parseResult = parseRelayResponse(message: message, expectedEventId: eventId)

                switch parseResult {
                case .accepted:
                    task.cancel(with: .normalClosure, reason: nil)
                    return true
                case .rejected:
                    // Relay explicitly rejected - don't wait, return immediately
                    task.cancel(with: .normalClosure, reason: nil)
                    return false
                case .continueWaiting:
                    // NOTICE or other message - keep waiting
                    continue
                }
            } catch {
                // Connection closed or error - task may have been cancelled
                if !Task.isCancelled {
                    logger.error("WebSocket receive failed: \(error.localizedDescription)")
                }
                task.cancel(with: .goingAway, reason: nil)
                return false
            }
        }

        // Task was cancelled (likely timeout)
        return false
    }

    /// Result of parsing a relay response
    private enum RelayResponseResult {
        case accepted       // ["OK", id, true, ...] - event accepted
        case rejected       // ["OK", id, false, ...] - event rejected, stop waiting
        case continueWaiting // NOTICE or other message - keep waiting for OK
    }

    /// Parse relay response to check for OK vs NOTICE
    private func parseRelayResponse(
        message: URLSessionWebSocketTask.Message,
        expectedEventId: String
    ) -> RelayResponseResult {
        let jsonString: String
        switch message {
        case .string(let str):
            jsonString = str
        case .data(let data):
            guard let str = String(data: data, encoding: .utf8) else { return .continueWaiting }
            jsonString = str
        @unknown default:
            return .continueWaiting
        }

        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let msgType = array.first as? String else {
            return .continueWaiting
        }

        switch msgType {
        case "OK":
            // ["OK", event_id, success, message]
            guard array.count >= 3,
                  let eventId = array[1] as? String,
                  let success = array[2] as? Bool else {
                return .continueWaiting
            }
            if eventId == expectedEventId {
                if success {
                    return .accepted
                } else {
                    let reason = array.count > 3 ? (array[3] as? String ?? "unknown") : "rejected"
                    logger.warning("Event \(eventId) rejected: \(reason)")
                    return .rejected
                }
            }
            // OK for different event - keep waiting
            return .continueWaiting
        case "NOTICE":
            // ["NOTICE", message] - not an OK, keep waiting
            if let notice = array[safe: 1] as? String {
                logger.info("Relay notice: \(notice)")
            }
            return .continueWaiting
        default:
            // Other message types - keep waiting
            return .continueWaiting
        }
    }
}

// MARK: - Array safe subscript extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
