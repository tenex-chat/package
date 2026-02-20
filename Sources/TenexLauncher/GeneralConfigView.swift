import SwiftUI

enum GeneralSettingsTab: String, CaseIterable, Identifiable {
    case identity = "Identity"
    case network = "Network"
    case relay = "Relay"
    case app = "App"
    case prompt = "Prompt"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .identity: "person.text.rectangle"
        case .network: "network"
        case .relay: "dot.radiowaves.left.and.right"
        case .app: "gearshape.2"
        case .prompt: "text.bubble"
        }
    }
}

struct GeneralConfigView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var relayManager: RelayManager
    @ObservedObject var negentropySync: NegentropySync
    @ObservedObject var pendingEventsQueue: PendingEventsQueue

    @State private var selectedTab: GeneralSettingsTab = .identity

    var body: some View {
        TabView(selection: $selectedTab) {
            settingsForm {
                identitySection
            }
            .tabItem {
                Label(GeneralSettingsTab.identity.rawValue, systemImage: GeneralSettingsTab.identity.icon)
            }
            .tag(GeneralSettingsTab.identity)

            settingsForm {
                networkSection
            }
            .tabItem {
                Label(GeneralSettingsTab.network.rawValue, systemImage: GeneralSettingsTab.network.icon)
            }
            .tag(GeneralSettingsTab.network)

            settingsForm {
                localRelaySection
            }
            .tabItem {
                Label(GeneralSettingsTab.relay.rawValue, systemImage: GeneralSettingsTab.relay.icon)
            }
            .tag(GeneralSettingsTab.relay)

            settingsForm {
                appSection
            }
            .tabItem {
                Label(GeneralSettingsTab.app.rawValue, systemImage: GeneralSettingsTab.app.icon)
            }
            .tag(GeneralSettingsTab.app)

            settingsForm {
                globalSystemPromptSection
            }
            .tabItem {
                Label(GeneralSettingsTab.prompt.rawValue, systemImage: GeneralSettingsTab.prompt.icon)
            }
            .tag(GeneralSettingsTab.prompt)
        }
        .navigationTitle("General")
    }

    private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Form {
            content()
        }
        .formStyle(.grouped)
    }

    private var identitySection: some View {
        Section("Identity") {
            TextField("Backend Name", text: bound(\.backendName, default: "tenex backend"))

            VStack(alignment: .leading) {
                Text("Whitelisted Pubkeys")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PubkeyListEditor(pubkeys: Binding(
                    get: { store.config.whitelistedPubkeys ?? [] },
                    set: {
                        store.config.whitelistedPubkeys = $0.isEmpty ? nil : $0
                        store.saveConfig()
                    }
                ))
            }
        }
    }

    private var networkSection: some View {
        Section("Network") {
            VStack(alignment: .leading) {
                Text("Relays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StringListEditor(
                    items: Binding(
                        get: { store.config.relays ?? ["wss://tenex.chat"] },
                        set: {
                            store.config.relays = $0.isEmpty ? nil : $0
                            store.saveConfig()
                        }
                    ),
                    placeholder: "wss://relay.example.com"
                )
            }

            TextField("Blossom Server URL", text: bound(\.blossomServerUrl, default: "https://blossom.primal.net"))
        }
    }

    private var localRelaySection: some View {
        Section("Local Relay") {
            Toggle("Enable Local Relay", isOn: localRelayEnabledBinding)

            if store.config.localRelay?.enabled == true {
                Toggle("Auto-start with app", isOn: localRelayAutoStartBinding)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: localRelayPortBinding, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .disabled(relayManager.status == .running)
                    if relayManager.status == .running {
                        Text("(restart required)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Status")
                    Spacer()
                    LocalRelayStatusView(status: relayManager.status)
                }

                if relayManager.status == .running {
                    HStack {
                        Text("Sync")
                        Spacer()
                        Text(negentropySync.status.label)
                            .foregroundStyle(.secondary)
                    }

                    if let lastSync = negentropySync.lastSuccessfulSync {
                        HStack {
                            Text("Last Sync")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    switch relayManager.status {
                    case .stopped, .failed:
                        Button("Start Relay") {
                            Task {
                                relayManager.configure(port: store.config.localRelay?.port ?? 7777)
                                await relayManager.start()
                                if relayManager.status == .running {
                                    negentropySync.configure(
                                        localRelayURL: relayManager.localRelayURL,
                                        remoteRelays: store.config.localRelay?.syncRelays ?? ["wss://tenex.chat"],
                                        relayManager: relayManager
                                    )
                                    negentropySync.start()

                                    // Drain pending events after manual start (waits for queue to load first)
                                    _ = await pendingEventsQueue.drainWhenReady(
                                        relayURL: relayManager.localRelayURL
                                    )
                                }
                            }
                        }
                    case .starting:
                        Button("Starting...") {}
                            .disabled(true)
                    case .running:
                        Button("Stop Relay") {
                            negentropySync.stop()
                            relayManager.stop()
                        }

                        Button("Sync Now") {
                            Task {
                                await negentropySync.syncNow()
                            }
                        }
                    }
                }

                if let error = relayManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var appSection: some View {
        Group {
            Section("Paths") {
                TextField("Projects Base", text: bound(\.projectsBase, default: "~/tenex"))
            }

            Section("Logging") {
                Picker("Log Level", selection: logLevelBinding) {
                    ForEach(["silent", "error", "warn", "info", "debug"], id: \.self) { level in
                        Text(level).tag(level)
                    }
                }
            }

            Section("Telemetry") {
                Toggle("Enabled", isOn: Binding(
                    get: { store.config.telemetry?.enabled ?? true },
                    set: {
                        if store.config.telemetry == nil {
                            store.config.telemetry = TelemetryConfig()
                        }
                        store.config.telemetry?.enabled = $0
                        store.saveConfig()
                    }
                ))
            }
        }
    }

    private var globalSystemPromptSection: some View {
        Section("Global System Prompt") {
            Toggle("Enabled", isOn: Binding(
                get: { store.config.globalSystemPrompt?.enabled ?? false },
                set: {
                    if store.config.globalSystemPrompt == nil {
                        store.config.globalSystemPrompt = GlobalSystemPrompt()
                    }
                    store.config.globalSystemPrompt?.enabled = $0
                    store.saveConfig()
                }
            ))

            TextEditor(text: Binding(
                get: { store.config.globalSystemPrompt?.content ?? "" },
                set: {
                    if store.config.globalSystemPrompt == nil {
                        store.config.globalSystemPrompt = GlobalSystemPrompt()
                    }
                    store.config.globalSystemPrompt?.content = $0.isEmpty ? nil : $0
                    store.saveConfig()
                }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 100)
        }
    }

    private func bound(_ keyPath: WritableKeyPath<TenexConfig, String?>, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { store.config[keyPath: keyPath] ?? defaultValue },
            set: {
                store.config[keyPath: keyPath] = $0 == defaultValue ? nil : $0
                store.saveConfig()
            }
        )
    }

    private var logLevelBinding: Binding<String> {
        Binding(
            get: { store.config.logging?.level ?? "info" },
            set: {
                if store.config.logging == nil {
                    store.config.logging = LoggingConfig()
                }
                store.config.logging?.level = $0
                store.saveConfig()
            }
        )
    }

    // MARK: - Local Relay Bindings

    private var localRelayEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.config.localRelay?.enabled ?? false },
            set: {
                if store.config.localRelay == nil {
                    store.config.localRelay = LocalRelayConfig()
                }
                store.config.localRelay?.enabled = $0
                store.saveConfig()
            }
        )
    }

    private var localRelayAutoStartBinding: Binding<Bool> {
        Binding(
            get: { store.config.localRelay?.autoStart ?? true },
            set: {
                if store.config.localRelay == nil {
                    store.config.localRelay = LocalRelayConfig()
                }
                store.config.localRelay?.autoStart = $0
                store.saveConfig()
            }
        )
    }

    private var localRelayPortBinding: Binding<Int> {
        Binding(
            get: { store.config.localRelay?.port ?? 7777 },
            set: {
                if store.config.localRelay == nil {
                    store.config.localRelay = LocalRelayConfig()
                }
                store.config.localRelay?.port = $0
                store.saveConfig()
            }
        )
    }
}

// MARK: - Local Relay Status View

struct LocalRelayStatusView: View {
    let status: RelayStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(status.label)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch status {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }
}

// MARK: - Reusable List Editors

struct PubkeyListEditor: View {
    @Binding var pubkeys: [String]
    @State private var newPubkey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(pubkeys.enumerated()), id: \.offset) { index, pubkey in
                HStack {
                    Text(truncated(pubkey))
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button {
                        pubkeys.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("npub1... or hex pubkey", text: $newPubkey)
                    .font(.system(.caption, design: .monospaced))
                Button {
                    let trimmed = newPubkey.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        pubkeys.append(trimmed)
                        newPubkey = ""
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(newPubkey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func truncated(_ key: String) -> String {
        guard key.count > 24 else { return key }
        return "\(key.prefix(12))...\(key.suffix(8))"
    }
}

struct StringListEditor: View {
    @Binding var items: [String]
    var placeholder: String = ""

    @State private var newItem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack {
                    Text(item)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Button {
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField(placeholder, text: $newItem)
                    .font(.system(.caption, design: .monospaced))
                Button {
                    let trimmed = newItem.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        items.append(trimmed)
                        newItem = ""
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
