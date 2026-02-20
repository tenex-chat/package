import SwiftUI

struct MenuBarView: View {
    @ObservedObject var daemon: DaemonManager
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var relayManager: RelayManager
    @ObservedObject var negentropySync: NegentropySync
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            HStack {
                Circle()
                    .fill(daemonStatusColor)
                    .frame(width: 8, height: 8)
                Text("Daemon: \(daemon.status.label)")
            }

            // Local relay status (only show if enabled)
            if relayManager.status != .stopped || relayManager.lastError != nil {
                HStack {
                    Circle()
                        .fill(relayStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Local Relay: \(relayManager.status.label)")
                }

                if relayManager.status == .running {
                    Text("  Uptime: \(formatUptime(relayManager.uptime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if negentropySync.status.isSuccess, let lastSync = negentropySync.lastSuccessfulSync {
                        Text("  Last sync: \(lastSync, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            switch daemon.status {
            case .stopped, .failed:
                Button("Start Daemon") { daemon.start() }
            case .starting:
                Button("Starting...") {}.disabled(true)
            case .running:
                Button("Stop Daemon") { daemon.stop() }
            }
        }

        Divider()

        Button("Open TENEX...") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")

        Button("Settings...") {
            openWindow(id: "settings")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit TENEX") {
            relayManager.stop()
            daemon.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .task {
            if configStore.needsOnboarding {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    private var daemonStatusColor: Color {
        switch daemon.status {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    private var relayStatusColor: Color {
        switch relayManager.status {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    private func formatUptime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }
}
