import SwiftUI

struct MenuBarView: View {
    @ObservedObject var daemon: DaemonManager
    @ObservedObject var strfryManager: StrfryManager
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
            if strfryManager.status != .stopped || strfryManager.lastError != nil {
                HStack {
                    Circle()
                        .fill(relayStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Local Relay: \(strfryManager.status.label)")
                }

                if strfryManager.status == .running {
                    Text("  Uptime: \(formatUptime(strfryManager.uptime))")
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
            strfryManager.stop()
            daemon.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
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
        switch strfryManager.status {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        case .fallback: .orange
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
