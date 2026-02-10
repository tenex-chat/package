import SwiftUI

struct MenuBarView: View {
    @ObservedObject var daemon: DaemonManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("Daemon: \(daemon.status.label)")
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
            daemon.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusColor: Color {
        switch daemon.status {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }
}
