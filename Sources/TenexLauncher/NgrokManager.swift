import Foundation
import os

enum NgrokStatus: Equatable {
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
}

/// Manages the ngrok tunnel process lifecycle for exposing the local relay
@MainActor
final class NgrokManager: ObservableObject {
    @Published var status: NgrokStatus = .stopped
    @Published var tunnelURL: String?
    @Published var lastError: String?

    private var process: Process?
    private var port: Int = 7777
    private var pollTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "ngrok")

    /// The WebSocket URL derived from the ngrok HTTPS tunnel
    var wssURL: String? {
        tunnelURL?.replacingOccurrences(of: "https://", with: "wss://")
    }

    // MARK: - Configuration

    func configure(port: Int) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() async {
        guard status != .running && status != .starting else { return }

        status = .starting
        lastError = nil
        tunnelURL = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["ngrok", "http", "\(port)", "--log", "stdout"]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        proc.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollTask?.cancel()
                self.pollTask = nil

                if self.status == .running || self.status == .starting {
                    let code = process.terminationStatus
                    if code == 0 {
                        self.status = .stopped
                    } else {
                        self.lastError = "ngrok exited with code \(code)"
                        self.status = .failed
                    }
                }
                self.tunnelURL = nil
            }
        }

        do {
            try proc.run()
            process = proc
            logger.info("ngrok process started, polling for tunnel URL...")
            await pollForURL()
        } catch {
            status = .failed
            lastError = error.localizedDescription
            process = nil
            logger.error("Failed to start ngrok: \(error.localizedDescription)")
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil

        guard let proc = process, proc.isRunning else {
            status = .stopped
            process = nil
            tunnelURL = nil
            return
        }

        // Prevent terminationHandler from overriding our state
        proc.terminationHandler = nil
        proc.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning {
                proc.interrupt()
            }
        }

        status = .stopped
        process = nil
        tunnelURL = nil
    }

    // MARK: - URL Polling

    /// Poll ngrok's local API until a tunnel URL appears
    private func pollForURL() async {
        let maxAttempts = 60 // 30 seconds at 500ms intervals
        let pollInterval: UInt64 = 500_000_000 // 500ms

        for _ in 0..<maxAttempts {
            guard !Task.isCancelled, status == .starting else { return }

            if let url = await fetchTunnelURL() {
                tunnelURL = url
                status = .running
                logger.info("ngrok tunnel established: \(url)")
                return
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }

        lastError = "Timed out waiting for ngrok tunnel URL"
        status = .failed
        logger.error("ngrok tunnel URL polling timed out")
    }

    /// Fetch the public URL from ngrok's local API
    private func fetchTunnelURL() async -> String? {
        guard let url = URL(string: "http://localhost:4040/api/tunnels") else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let tunnels = json?["tunnels"] as? [[String: Any]] else { return nil }

            // Find the HTTPS tunnel
            for tunnel in tunnels {
                if let publicURL = tunnel["public_url"] as? String,
                   publicURL.hasPrefix("https://") {
                    return publicURL
                }
            }
        } catch {
            // ngrok API not ready yet
        }

        return nil
    }
}
