import SwiftUI

struct MobileSetupView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var ngrokManager: NgrokManager
    @State private var nsec: String?
    @State private var loadingNsec = true

    private var configuredRelay: String? {
        store.config.relays?.first
    }

    private var localRelayConfigured: Bool {
        store.config.localRelay?.enabled == true
            && (configuredRelay == nil || QRCodeGenerator.isLoopbackRelay(configuredRelay))
    }

    private var ngrokEnabled: Bool {
        store.config.localRelay?.ngrokEnabled == true
    }

    private var relayForQRCode: String? {
        if localRelayConfigured {
            return ngrokManager.wssURL
        }
        return configuredRelay
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if loadingNsec {
                    ProgressView("Loading credentials...")
                } else if let nsec {
                    mobileSetupContent(nsec: nsec)
                } else {
                    unavailableState(
                        icon: "qrcode",
                        message: "No credentials found. Log in first to generate a mobile setup QR code."
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .task {
            let result = await Task.detached {
                KeychainService.shared.loadNsec()
            }.value
            if case .success(let key) = result {
                nsec = key
            }
            loadingNsec = false
        }
    }

    @ViewBuilder
    private func mobileSetupContent(nsec: String) -> some View {
        if let relay = relayForQRCode {
            let setupURL = QRCodeGenerator.mobileSetupURL(
                nsec: nsec,
                relay: relay,
                backendPubkey: store.config.tenexPublicKey
            )

            if let qrImage = QRCodeGenerator.generate(from: setupURL) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
            }

            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("Relay:")
                        .foregroundStyle(.secondary)
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                }
                .font(.caption)

                if let pubkey = store.config.tenexPublicKey {
                    HStack(spacing: 4) {
                        Text("Backend:")
                            .foregroundStyle(.secondary)
                        Text(String(pubkey.prefix(8)) + "..." + String(pubkey.suffix(8)))
                            .font(.system(.caption, design: .monospaced))
                    }
                    .font(.caption)
                }
            }

            VStack(spacing: 8) {
                Text("TENEX for iPhone")
                    .font(.headline)
                Text("Coming soon on TestFlight. Scan this QR code with the TENEX iOS app to instantly log in and connect to your backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("This QR code contains your private key. Do not share it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
        } else if localRelayConfigured {
            localRelayUnavailableState
        } else {
            unavailableState(
                icon: "qrcode",
                message: "No relay configured. Set up a relay first in Network settings."
            )
        }
    }

    private var localRelayUnavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if ngrokEnabled {
                Text("Local relay is configured for mobile via ngrok, but no tunnel is running yet.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Local relay uses localhost, which your iPhone cannot reach.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let lastError = ngrokManager.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            if ngrokEnabled {
                switch ngrokManager.status {
                case .stopped, .failed:
                    Button("Start ngrok tunnel") {
                        startNgrokTunnel()
                    }
                case .starting:
                    ProgressView("Starting ngrok...")
                case .running:
                    Button("Stop ngrok tunnel") {
                        ngrokManager.stop()
                    }
                }
            } else {
                Button("Enable and start ngrok") {
                    enableAndStartNgrok()
                }
            }
        }
        .frame(maxWidth: 420)
    }

    private func unavailableState(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func enableAndStartNgrok() {
        if store.config.localRelay == nil {
            store.config.localRelay = LocalRelayConfig()
        }
        store.config.localRelay?.enabled = true
        store.config.localRelay?.ngrokEnabled = true
        store.saveConfig()
        startNgrokTunnel()
    }

    private func startNgrokTunnel() {
        let port = store.config.localRelay?.port ?? 7777
        Task {
            ngrokManager.configure(port: port)
            await ngrokManager.start()
        }
    }
}
