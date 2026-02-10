import Foundation
import os

enum DaemonStatus: Equatable {
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

@MainActor
final class DaemonManager: ObservableObject {
    @Published var status: DaemonStatus = .stopped
    @Published var recentLogs: [String] = []
    @Published var lastError: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let maxLogLines = 50
    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "daemon")

    /// Resolve the path to the daemon binary.
    /// Priority: bundled binary > compiled binary in deps > bun + source
    private var daemonExecutable: (path: String, arguments: [String])? {
        // 1. Bundled compiled binary (production)
        if let bundled = Bundle.main.path(forResource: "tenex-daemon", ofType: nil) {
            return (bundled, ["daemon"])
        }

        // 2. Compiled binary in deps (dev — after bun build --compile)
        let depsCompiled = bundlePath("deps/backend/dist/tenex-daemon")
        if FileManager.default.fileExists(atPath: depsCompiled) {
            return (depsCompiled, ["daemon"])
        }

        // 3. Run via bun from source (dev fallback)
        if let bun = findBun() {
            let entrypoint = bundlePath("deps/backend/src/index.ts")
            if FileManager.default.fileExists(atPath: entrypoint) {
                return (bun, ["run", entrypoint, "daemon"])
            }
        }

        return nil
    }

    func start() {
        guard status != .running && status != .starting else { return }

        guard let (executable, arguments) = daemonExecutable else {
            lastError = "Cannot find tenex daemon binary. Looked for: bundled binary, deps/backend/dist/tenex-daemon, bun + deps/backend/src/index.ts"
            status = .failed
            logger.error("No daemon executable found")
            return
        }

        status = .starting
        lastError = nil
        recentLogs = []

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        // Inherit the user's environment so API keys, PATH etc. are available
        var env = ProcessInfo.processInfo.environment
        // Ensure deps/backend/node_modules/.bin is on PATH for bun-based execution
        let nodeModulesBin = bundlePath("deps/backend/node_modules/.bin")
        if let existingPath = env["PATH"] {
            env["PATH"] = "\(nodeModulesBin):\(existingPath)"
        }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: bundlePath("deps/backend"))

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
                if self.status == .running || self.status == .starting {
                    if code == 0 {
                        self.status = .stopped
                    } else {
                        self.status = .failed
                        self.lastError = "Daemon exited with code \(code)"
                        self.logger.error("Daemon exited with code \(code)")
                    }
                }
            }
        }

        do {
            try proc.run()
            process = proc
            status = .running
            logger.info("Daemon started: \(executable) \(arguments.joined(separator: " "))")
        } catch {
            status = .failed
            lastError = error.localizedDescription
            logger.error("Failed to start daemon: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            status = .stopped
            return
        }

        // Send SIGTERM for graceful shutdown
        proc.terminate()

        // Give it 5 seconds, then SIGKILL
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if proc.isRunning {
                proc.interrupt()
            }
        }

        status = .stopped
        process = nil
    }

    // MARK: - Helpers

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

    /// Resolve a path relative to the repo root.
    /// In dev builds, SRCROOT is injected into Info.plist as TenexRepoRoot.
    /// In production, the binary is bundled inside the .app.
    private func bundlePath(_ relative: String) -> String {
        if let repoRoot = Bundle.main.infoDictionary?["TenexRepoRoot"] as? String {
            return (repoRoot as NSString).appendingPathComponent(relative)
        }
        return (Bundle.main.resourcePath! as NSString).appendingPathComponent(relative)
    }

    private func findBun() -> String? {
        let candidates = [
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
            "\(NSHomeDirectory())/.bun/bin/bun",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
