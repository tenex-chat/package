import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var orchestrator: OrchestratorManager
    @ObservedObject var negentropySync: NegentropySync
    @ObservedObject var pendingEventsQueue: PendingEventsQueue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            HStack {
                Circle()
                    .fill(statusColor(orchestrator.daemonStatus))
                    .frame(width: 8, height: 8)
                Text("Daemon: \(statusLabel(orchestrator.daemonStatus))")
            }

            // Local relay status (only show if enabled)
            if orchestrator.relayStatus != .stopped || orchestrator.relayError != nil {
                HStack {
                    Circle()
                        .fill(statusColor(orchestrator.relayStatus))
                        .frame(width: 8, height: 8)
                    Text("Local Relay: \(statusLabel(orchestrator.relayStatus))")
                }

                if orchestrator.relayStatus == .running {
                    if negentropySync.status.isSuccess, let lastSync = negentropySync.lastSuccessfulSync {
                        Text("  Last sync: \(lastSync, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Ngrok tunnel status
            if orchestrator.ngrokStatus != .stopped {
                Divider()

                HStack {
                    Circle()
                        .fill(statusColor(orchestrator.ngrokStatus))
                        .frame(width: 8, height: 8)
                    Text("Tunnel: \(statusLabel(orchestrator.ngrokStatus))")
                }

                if let tunnelURL = orchestrator.ngrokTunnelUrl {
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
            switch orchestrator.daemonStatus {
            case .stopped, .failed:
                Button("Start Daemon") { orchestrator.startDaemon() }
            case .starting:
                Button("Starting...") {}.disabled(true)
            case .running:
                Button("Stop Daemon") { orchestrator.stopDaemon() }
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
            orchestrator.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .task {
            if orchestrator.needsOnboarding {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } else {
                orchestrator.startAllServices(
                    negentropySync: negentropySync,
                    pendingEventsQueue: pendingEventsQueue
                )
            }
        }
    }

    private func statusColor(_ status: FfiProcessStatus) -> Color {
        switch status {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    private func statusLabel(_ status: FfiProcessStatus) -> String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting..."
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    private func showQRCodeWindow() {
        guard let wssURL = orchestrator.ngrokWssUrl else { return }

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
                    backendPubkey: orchestrator.launcher.tenexPublicKey
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
