import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var coreManager: TenexCoreManager
    @ObservedObject var relayManager: RelayManager

    @State private var step: OnboardingStep = .identity

    enum OnboardingStep {
        case identity
        case relay
        case providers
        case llms
    }

    enum RelayMode {
        case remote
        case local
    }

    // Identity state
    @State private var identityPath: IdentityPath = .none
    @State private var nsecInput = ""
    @State private var nsecError: String?
    @State private var identityNpub = ""
    @State private var identityHexPubkey = ""
    @State private var generatedNsec = ""
    @State private var isProcessing = false
    @State private var identityCompleted = false
    @State private var displayName = NSFullUserName().isEmpty ? NSUserName() : NSFullUserName()
    @State private var selectedAvatarStyle = ""

    private let avatarStyles = [
        "lorelei", "miniavs", "dylan", "pixel-art", "rings", "avataaars",
        "adventurer", "adventurer-neutral", "big-ears", "big-ears-neutral",
        "bottts", "bottts-neutral", "croodles", "croodles-neutral",
        "fun-emoji", "icons", "identicon", "micah", "notionists",
        "notionists-neutral", "open-peeps", "personas", "shapes", "thumbs"
    ]
    @State private var avatarWindowStart = 0

    // Relay state
    @State private var relayMode: RelayMode = .remote
    @State private var remoteRelayURL = "wss://tenex.chat"
    @State private var ngrokAvailable = false
    @State private var ngrokEnabled = false

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
                case .relay:
                    relayStepView
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
                        case .providers: step = .relay
                        case .relay: step = .identity
                        case .identity: break
                        }
                    }
                }

                Spacer()

                switch step {
                case .identity:
                    if identityCompleted {
                        Button("Continue") {
                            step = .relay
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                case .relay:
                    Button("Continue") {
                        saveRelayConfig()
                        step = .providers
                    }
                    .keyboardShortcut(.defaultAction)
                case .providers:
                    Button("Continue") {
                        seedDefaultLLMConfigs()
                        step = .llms
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.providers.providers.isEmpty)
                case .llms:
                    Button("Finish Setup") {
                        generateBackendKeyAndApprove()
                        store.saveConfig()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .onAppear {
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first(where: { $0.title == "TENEX Settings" }) {
                    let size = NSSize(width: 580, height: 540)
                    window.setContentSize(size)
                    window.center()
                }
            }
        }
    }

    private var headerSubtitle: String {
        switch step {
        case .identity:
            "Set up your Nostr identity to get started."
        case .relay:
            "Choose how to connect to the Nostr network."
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

    private func defaultAvatarStyle(for pubkey: String) -> (String, Int) {
        let prefix = String(pubkey.prefix(8))
        let index = Int((UInt64(prefix, radix: 16) ?? 0) % UInt64(avatarStyles.count))
        return (avatarStyles[index], index)
    }

    private func avatarURL(style: String, pubkey: String) -> String {
        "https://api.dicebear.com/7.x/\(style)/png?seed=\(pubkey)"
    }

    private var createKeyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your new Nostr identity")
                .font(.headline)

            // Name field
            VStack(alignment: .leading, spacing: 6) {
                Text("Display name")
                    .font(.subheadline.weight(.medium))
                TextField("Your name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            // Avatar picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose your avatar")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    Button {
                        avatarWindowStart = (avatarWindowStart - 6 + avatarStyles.count) % avatarStyles.count
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    ForEach(0..<6, id: \.self) { offset in
                        let style = avatarStyles[(avatarWindowStart + offset) % avatarStyles.count]
                        AsyncImage(url: URL(string: avatarURL(style: style, pubkey: identityHexPubkey))) { image in
                            image.resizable()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(selectedAvatarStyle == style ? Color.accentColor : .clear, lineWidth: 3)
                        )
                        .onTapGesture {
                            selectedAvatarStyle = style
                        }
                    }

                    Button {
                        avatarWindowStart = (avatarWindowStart + 6) % avatarStyles.count
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Keys display
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

            HStack {
                Button("Back") {
                    identityPath = .none
                    generatedNsec = ""
                    identityNpub = ""
                    identityHexPubkey = ""
                    displayName = ""
                    selectedAvatarStyle = ""
                }

                Spacer()

                Button("Continue") {
                    storeKeyAndComplete()
                }
                .buttonStyle(.borderedProminent)
                .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
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

    // MARK: - Relay Step

    private var relayStepView: some View {
        VStack(spacing: 24) {
            HStack(spacing: 16) {
                relayCard(
                    icon: "globe",
                    title: "Remote Relay",
                    description: "Connect to a relay server. Works from any device.",
                    selected: relayMode == .remote
                ) {
                    relayMode = .remote
                }

                relayCard(
                    icon: "server.rack",
                    title: "Local Relay",
                    description: "Run a relay on this machine. Data stays local.",
                    selected: relayMode == .local
                ) {
                    relayMode = .local
                }
            }
            .padding(.horizontal, 24)

            if relayMode == .remote {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Relay URL")
                        .font(.subheadline.weight(.medium))
                    TextField("wss://tenex.chat", text: $remoteRelayURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 24)
            }

            if relayMode == .local {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(isOn: $ngrokEnabled) {
                            Text("Expose via ngrok for mobile access")
                        }
                        .disabled(!ngrokAvailable)

                        if !ngrokAvailable {
                            Text("(ngrok not installed)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 400)
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .padding(.top, 24)
        .onAppear { detectNgrok() }
    }

    private func relayCard(
        icon: String,
        title: String,
        description: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)

                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.background.secondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func detectNgrok() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ngrok"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        ngrokAvailable = process.terminationStatus == 0
    }

    private func saveRelayConfig() {
        switch relayMode {
        case .remote:
            store.config.relays = [remoteRelayURL]
            store.config.localRelay = LocalRelayConfig(enabled: false)
        case .local:
            store.config.localRelay = LocalRelayConfig(
                enabled: true,
                autoStart: true,
                port: 7777,
                syncRelays: ["wss://tenex.chat"],
                ngrokEnabled: ngrokEnabled
            )
        }
    }

    // MARK: - Actions

    private func generateBackendKeyAndApprove() {
        // Generate a keypair for the backend if one doesn't exist
        if store.config.tenexPrivateKey == nil {
            guard let keypair = try? coreManager.core.generateKeypair() else { return }
            guard let hexPrivateKey = Bech32.nsecToHex(keypair.nsec) else { return }
            store.config.tenexPrivateKey = hexPrivateKey

            // Approve the backend in the client
            try? coreManager.core.approveBackend(pubkey: keypair.pubkeyHex)
        }
    }

    private func generateNewKeypair() {
        isProcessing = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let keypair = try coreManager.core.generateKeypair()
                DispatchQueue.main.async {
                    generatedNsec = keypair.nsec
                    identityNpub = keypair.npub
                    identityHexPubkey = keypair.pubkeyHex
                    let (style, index) = defaultAvatarStyle(for: keypair.pubkeyHex)
                    selectedAvatarStyle = style
                    avatarWindowStart = index
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

                // Publish profile if name was provided (create flow)
                let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    let pictureUrl = selectedAvatarStyle.isEmpty ? nil : avatarURL(style: selectedAvatarStyle, pubkey: identityHexPubkey)
                    try? coreManager.core.publishProfile(name: trimmedName, pictureUrl: pictureUrl)
                }

                identityCompleted = true
                isProcessing = false
            }
        }
    }

    // MARK: - Default LLM Seeding

    private func seedDefaultLLMConfigs() {
        guard store.llms.configurations.isEmpty else { return }

        let connected = Set(store.providers.providers.keys)

        // Prefer claude-code (local CLI), fall back to anthropic API key
        let anthropicProvider: String? = if connected.contains("claude-code") {
            "claude-code"
        } else if connected.contains("anthropic") {
            "anthropic"
        } else {
            nil
        }

        if let provider = anthropicProvider {
            store.llms.configurations["Sonnet"] = .standard(
                StandardLLM(provider: provider, model: "claude-sonnet-4-6")
            )
            store.llms.configurations["Opus"] = .standard(
                StandardLLM(provider: provider, model: "claude-opus-4-6")
            )
            store.llms.configurations["Auto"] = .meta(MetaLLM(
                provider: "meta",
                variants: [
                    "fast": MetaVariant(
                        model: "claude-haiku-4-5-20251001",
                        description: "Fast, lightweight tasks",
                        tier: 1
                    ),
                    "balanced": MetaVariant(
                        model: "claude-sonnet-4-6",
                        description: "Good balance of speed and capability",
                        tier: 2
                    ),
                    "powerful": MetaVariant(
                        model: "claude-opus-4-6",
                        description: "Most capable, complex reasoning",
                        tier: 3
                    ),
                ],
                defaultVariant: "balanced"
            ))
            store.llms.default = "Auto"
        }

        if connected.contains("openai") {
            store.llms.configurations["GPT-4o"] = .standard(
                StandardLLM(provider: "openai", model: "gpt-4o")
            )
            if anthropicProvider == nil {
                store.llms.default = "GPT-4o"
            }
        }

        if !store.llms.configurations.isEmpty {
            store.saveLLMs()
        }
    }
}
