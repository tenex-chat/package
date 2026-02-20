import SwiftUI

struct OnboardingView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var coreManager: TenexCoreManager

    @State private var step: OnboardingStep = .identity

    enum OnboardingStep {
        case identity
        case providers
        case llms
    }

    // Identity state
    @State private var identityPath: IdentityPath = .none
    @State private var nsecInput = ""
    @State private var nsecError: String?
    @State private var identityNpub = ""
    @State private var identityHexPubkey = ""
    @State private var generatedNsec = ""
    @State private var confirmedSavedKey = false
    @State private var isProcessing = false
    @State private var identityCompleted = false

    enum IdentityPath {
        case none
        case existing
        case create
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to TENEX")
                    .font(.largeTitle.weight(.semibold))
                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            // Content
            Group {
                switch step {
                case .identity:
                    identityStepView
                case .providers:
                    ProvidersView(store: store)
                case .llms:
                    LLMsView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            HStack {
                if step != .identity {
                    Button("Back") {
                        switch step {
                        case .llms: step = .providers
                        case .providers: step = .identity
                        case .identity: break
                        }
                    }
                }

                Spacer()

                switch step {
                case .identity:
                    Button("Continue") {
                        step = .providers
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!identityCompleted)
                case .providers:
                    Button("Continue") {
                        step = .llms
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.providers.providers.isEmpty)
                case .llms:
                    Button("Finish Setup") {
                        store.saveConfig()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .identity:
            "Set up your Nostr identity to get started."
        case .providers:
            "Connect your AI providers."
        case .llms:
            "Configure your LLM models and role assignments."
        }
    }

    // MARK: - Identity Step

    private var identityStepView: some View {
        Group {
            if !identityCompleted {
                identityChoiceView
            } else {
                ScrollView {
                    identityConfirmedView
                        .padding(24)
                }
            }
        }
    }

    @ViewBuilder
    private var identityChoiceView: some View {
        if identityPath == .none {
            VStack(spacing: 16) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("TENEX uses Nostr keys for authentication.\nYou need a keypair to use this instance.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("I have a Nostr key") {
                        identityPath = .existing
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("Create new identity") {
                        generateNewKeypair()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if identityPath == .existing {
            VStack {
                existingKeyView
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if identityPath == .create {
            ScrollView {
                createKeyView
                    .frame(maxWidth: 480)
                    .padding(24)
            }
        }
    }

    private var existingKeyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter your Nostr secret key")
                .font(.headline)

            SecureField("nsec1...", text: $nsecInput)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)

            if let error = nsecError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Back") {
                    identityPath = .none
                    nsecInput = ""
                    nsecError = nil
                }

                Spacer()

                Button("Validate & Continue") {
                    validateExistingKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(nsecInput.isEmpty || isProcessing)
            }
        }
    }

    private var createKeyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your new Nostr identity")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your secret key (nsec)")
                    .font(.subheadline.weight(.medium))

                HStack {
                    Text(generatedNsec)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(generatedNsec, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to clipboard")
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))

                Text("Save this key — you'll need it to log in on other devices. It cannot be recovered.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Your public key (npub)")
                    .font(.subheadline.weight(.medium))

                Text(identityNpub)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))
            }

            Toggle("I've saved my secret key somewhere safe", isOn: $confirmedSavedKey)

            HStack {
                Button("Back") {
                    identityPath = .none
                    generatedNsec = ""
                    identityNpub = ""
                    identityHexPubkey = ""
                    confirmedSavedKey = false
                }

                Spacer()

                Button("Continue") {
                    storeKeyAndComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!confirmedSavedKey || isProcessing)
            }
        }
    }

    private var identityConfirmedView: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Identity configured", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                HStack {
                    Text("Logged in as")
                        .foregroundStyle(.secondary)
                    Text(identityNpub)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Authorized Users")
                    .font(.headline)
                Text("Nostr pubkeys authorized to use this TENEX instance. Add team members who should have access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                PubkeyListEditor(pubkeys: Binding(
                    get: { store.config.whitelistedPubkeys ?? [] },
                    set: { store.config.whitelistedPubkeys = $0.isEmpty ? nil : $0 }
                ))
            }
        }
    }

    // MARK: - Actions

    private func generateNewKeypair() {
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let keypair = try coreManager.core.generateKeypair()
                DispatchQueue.main.async {
                    generatedNsec = keypair.nsec
                    identityNpub = keypair.npub
                    identityHexPubkey = keypair.pubkeyHex
                    identityPath = .create
                    isProcessing = false
                }
            } catch {
                DispatchQueue.main.async {
                    nsecError = "Failed to generate keypair: \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }

    private func validateExistingKey() {
        let trimmed = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("nsec1") else {
            nsecError = "Key must start with nsec1"
            return
        }

        isProcessing = true
        nsecError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try coreManager.core.login(nsec: trimmed)
                DispatchQueue.main.async {
                    if result.success {
                        identityNpub = result.npub
                        identityHexPubkey = result.pubkey
                        generatedNsec = trimmed
                        storeKeyAndComplete()
                    } else {
                        nsecError = "Login failed"
                        isProcessing = false
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    nsecError = error.localizedDescription
                    isProcessing = false
                }
            }
        }
    }

    private func storeKeyAndComplete() {
        isProcessing = true
        let nsecToStore = identityPath == .existing ? nsecInput.trimmingCharacters(in: .whitespacesAndNewlines) : generatedNsec

        // For "create new" path, login first to set up core state
        if identityPath == .create {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let _ = try coreManager.core.login(nsec: nsecToStore)
                } catch {
                    DispatchQueue.main.async {
                        nsecError = "Failed to login with generated key: \(error.localizedDescription)"
                        isProcessing = false
                    }
                    return
                }

                saveAndFinalize(nsecToStore)
            }
        } else {
            // Already logged in from validateExistingKey
            DispatchQueue.global(qos: .userInitiated).async {
                saveAndFinalize(nsecToStore)
            }
        }
    }

    private func saveAndFinalize(_ nsec: String) {
        Task {
            let saveError = await coreManager.saveCredential(nsec: nsec)
            await MainActor.run {
                if let error = saveError {
                    nsecError = "Failed to save key: \(error)"
                    isProcessing = false
                    return
                }

                // Add hex pubkey to whitelist
                var pubkeys = store.config.whitelistedPubkeys ?? []
                if !pubkeys.contains(identityHexPubkey) {
                    pubkeys.append(identityHexPubkey)
                    store.config.whitelistedPubkeys = pubkeys
                }

                identityCompleted = true
                isProcessing = false
            }
        }
    }
}
