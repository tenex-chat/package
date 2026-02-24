import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var daemon: DaemonManager
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var relayManager: RelayManager
    @ObservedObject var ngrokManager: NgrokManager
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

            // Ngrok tunnel status
            if ngrokManager.status != .stopped {
                Divider()

                HStack {
                    Circle()
                        .fill(ngrokStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Tunnel: \(ngrokManager.status.label)")
                }

                if let tunnelURL = ngrokManager.tunnelURL {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tunnelURL, forType: .string)
                    } label: {
                        HStack {
                            Text(tunnelURL)
                                .font(.caption)
                                .lineLimit(1)
                            Image(systemName: "doc.on.doc")
                                .font(.caption2)
                        }
                    }

                    Button("Show QR Code") {
                        showQRCodeWindow()
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
            ngrokManager.stop()
            relayManager.stop()
            daemon.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .task {
            if configStore.needsOnboarding {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                daemon.start()
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

    private var ngrokStatusColor: Color {
        switch ngrokManager.status {
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

    private func showQRCodeWindow() {
        guard let wssURL = ngrokManager.wssURL else { return }

        // Load nsec on background thread
        DispatchQueue.global(qos: .userInitiated).async {
            let nsecResult = KeychainService.shared.loadNsec()

            DispatchQueue.main.async {
                let nsec: String
                switch nsecResult {
                case .success(let key): nsec = key
                case .failure:
                    return
                }

                let payload = QRCodeGenerator.mobileSetupURL(
                    nsec: nsec,
                    relay: wssURL,
                    backendPubkey: configStore.config.tenexPublicKey
                )

                let panel = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: 360, height: 440),
                    styleMask: [.titled, .closable, .utilityWindow],
                    backing: .buffered,
                    defer: false
                )
                panel.title = "TENEX Mobile Connect"
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.isReleasedWhenClosed = false
                panel.center()

                let hostingView = NSHostingView(rootView: QRCodePanelView(payload: payload, relayURL: wssURL))
                panel.contentView = hostingView
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - QR Code Panel

struct QRCodePanelView: View {
    let payload: String
    let relayURL: String

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan with TENEX Mobile")
                .font(.headline)

            if let qrImage = QRCodeGenerator.generate(from: payload) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            }

            VStack(spacing: 4) {
                Text("Relay")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(relayURL)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Contains your private key")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Copy Relay URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relayURL, forType: .string)
            }
        }
        .padding(24)
    }
}
