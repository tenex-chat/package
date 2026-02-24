import SwiftUI

struct MobileSetupView: View {
    @ObservedObject var store: ConfigStore
    @State private var nsec: String?
    @State private var loadingNsec = true

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if loadingNsec {
                    ProgressView("Loading credentials...")
                } else if let nsec, let relay = store.config.relays?.first {
                    let setupURL = QRCodeGenerator.mobileSetupURL(
                        nsec: nsec,
                        relay: relay,
                        backendPubkey: store.config.tenexPublicKey
                    )

                    // QR Code
                    if let qrImage = QRCodeGenerator.generate(from: setupURL) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                    }

                    // Connection info
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

                    // TestFlight section
                    VStack(spacing: 8) {
                        Text("TENEX for iPhone")
                            .font(.headline)
                        Text("Coming soon on TestFlight. Scan this QR code with the TENEX iOS app to instantly log in and connect to your backend.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }

                    // Warning
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("This QR code contains your private key. Do not share it.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.1)))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        if nsec == nil {
                            Text("No credentials found. Log in first to generate a mobile setup QR code.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Text("No relay configured. Set up a relay first in Network settings.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
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
}
