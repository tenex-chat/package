import SwiftUI

struct GeneralConfigView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var relayManager: RelayManager
    @ObservedObject var negentropySync: NegentropySync
    @ObservedObject var pendingEventsQueue: PendingEventsQueue
    let tab: SidebarTab

    var body: some View {
        Form {
            switch tab {
            case .identity: identitySection
            case .network: networkSection
            case .relay: localRelaySection
            case .agents: agentsSection
            case .conversations: conversationsSection
            case .app: appSection
            case .prompt: globalSystemPromptSection
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(tab.rawValue)
    }

    private var identitySection: some View {
        Group {
            Section("Backend") {
                TextField("Backend Name", text: bound(\.backendName, default: "tenex backend"))
            }

            Section {
                PubkeyListEditor(pubkeys: Binding(
                    get: { store.config.whitelistedPubkeys ?? [] },
                    set: {
                        store.config.whitelistedPubkeys = $0.isEmpty ? nil : $0
                        store.saveConfig()
                    }
                ))
            } header: {
                Text("Authorized Users")
            } footer: {
                Text("Nostr pubkeys authorized to use this TENEX instance. The backend only responds to messages from these users.")
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

    // MARK: - Agents

    private var agentsSection: some View {
        Group {
            Section {
                TextField("Agent Slug", text: escalationAgentBinding)
            } header: {
                Text("Escalation")
            } footer: {
                Text("Route ask() tool calls through this agent first. It acts as a first-line handler that can resolve questions without interrupting you.")
            }

            Section {
                Toggle("Enable Intervention", isOn: interventionEnabledBinding)

                if store.config.intervention?.enabled == true {
                    TextField("Reviewer Agent Slug", text: interventionAgentBinding)

                    DurationPicker(
                        label: "Review Timeout",
                        options: Self.timeoutOptionsMs,
                        value: interventionReviewTimeoutBinding
                    )

                    DurationPicker(
                        label: "Skip If Active Within",
                        options: Self.skipActiveOptionsSeconds,
                        value: interventionSkipIfActiveBinding
                    )
                }
            } header: {
                Text("Intervention")
            } footer: {
                Text("When an agent finishes work and you haven't responded within the timeout, another agent is assigned to review the results.")
            }

        }
    }

    // MARK: - Conversations

    private var conversationsSection: some View {
        Group {
            Section {
                Toggle("Enable Compression", isOn: compressionEnabledBinding)

                if store.config.compression?.enabled != false {
                    HStack {
                        Text("Compress When Tokens Exceed")
                        Spacer()
                        TextField("", value: compressionThresholdBinding, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Target Token Count")
                        Spacer()
                        TextField("", value: compressionBudgetBinding, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Recent Messages to Preserve")
                        Spacer()
                        TextField("", value: compressionWindowBinding, format: .number)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Compression")
            } footer: {
                Text("Automatically compresses conversation history when it grows too large, keeping context windows manageable.")
            }

            Section {
                DurationPicker(
                    label: "Inactivity Timeout",
                    options: Self.summarizationTimeoutOptions,
                    value: summarizationTimeoutBinding
                )
            } header: {
                Text("Summarization")
            } footer: {
                Text("After this period of inactivity, a summary of the conversation is generated. Summaries help agents quickly understand past context.")
            }
        }
    }

    // MARK: - Duration Options

    private static let timeoutOptionsMs: [(label: String, value: Int)] = [
        ("1 minute", 60_000),
        ("2 minutes", 120_000),
        ("5 minutes", 300_000),
        ("10 minutes", 600_000),
        ("15 minutes", 900_000),
    ]

    private static let skipActiveOptionsSeconds: [(label: String, value: Int)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
    ]

    private static let summarizationTimeoutOptions: [(label: String, value: Int)] = [
        ("1 minute", 60_000),
        ("2 minutes", 120_000),
        ("5 minutes", 300_000),
        ("10 minutes", 600_000),
        ("15 minutes", 900_000),
        ("30 minutes", 1_800_000),
    ]

    // MARK: - Agents Bindings

    private var escalationAgentBinding: Binding<String> {
        Binding(
            get: { store.config.escalation?.agent ?? "" },
            set: {
                let value = $0.trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    store.config.escalation = nil
                } else {
                    if store.config.escalation == nil {
                        store.config.escalation = EscalationConfig()
                    }
                    store.config.escalation?.agent = value
                }
                store.saveConfig()
            }
        )
    }

    private var interventionEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.config.intervention?.enabled ?? false },
            set: {
                if store.config.intervention == nil {
                    store.config.intervention = InterventionConfig()
                }
                store.config.intervention?.enabled = $0
                if !$0 { store.config.intervention = nil }
                store.saveConfig()
            }
        )
    }

    private var interventionAgentBinding: Binding<String> {
        Binding(
            get: { store.config.intervention?.agent ?? "" },
            set: {
                if store.config.intervention == nil {
                    store.config.intervention = InterventionConfig(enabled: true)
                }
                store.config.intervention?.agent = $0.isEmpty ? nil : $0
                store.saveConfig()
            }
        )
    }

    private var interventionReviewTimeoutBinding: Binding<Int> {
        Binding(
            get: { store.config.intervention?.reviewTimeout ?? 300_000 },
            set: {
                if store.config.intervention == nil {
                    store.config.intervention = InterventionConfig(enabled: true)
                }
                store.config.intervention?.reviewTimeout = $0
                store.saveConfig()
            }
        )
    }

    private var interventionSkipIfActiveBinding: Binding<Int> {
        Binding(
            get: { store.config.intervention?.skipIfActiveWithin ?? 120 },
            set: {
                if store.config.intervention == nil {
                    store.config.intervention = InterventionConfig(enabled: true)
                }
                store.config.intervention?.skipIfActiveWithin = $0
                store.saveConfig()
            }
        )
    }

    // MARK: - Conversations Bindings

    private var compressionEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.config.compression?.enabled ?? true },
            set: {
                if store.config.compression == nil {
                    store.config.compression = CompressionConfig()
                }
                store.config.compression?.enabled = $0
                store.saveConfig()
            }
        )
    }

    private var compressionThresholdBinding: Binding<Int> {
        Binding(
            get: { store.config.compression?.tokenThreshold ?? 50_000 },
            set: {
                if store.config.compression == nil {
                    store.config.compression = CompressionConfig()
                }
                store.config.compression?.tokenThreshold = $0
                store.saveConfig()
            }
        )
    }

    private var compressionBudgetBinding: Binding<Int> {
        Binding(
            get: { store.config.compression?.tokenBudget ?? 40_000 },
            set: {
                if store.config.compression == nil {
                    store.config.compression = CompressionConfig()
                }
                store.config.compression?.tokenBudget = $0
                store.saveConfig()
            }
        )
    }

    private var compressionWindowBinding: Binding<Int> {
        Binding(
            get: { store.config.compression?.slidingWindowSize ?? 50 },
            set: {
                if store.config.compression == nil {
                    store.config.compression = CompressionConfig()
                }
                store.config.compression?.slidingWindowSize = $0
                store.saveConfig()
            }
        )
    }

    private var summarizationTimeoutBinding: Binding<Int> {
        Binding(
            get: { store.config.summarization?.inactivityTimeout ?? 300_000 },
            set: {
                if store.config.summarization == nil {
                    store.config.summarization = SummarizationConfig()
                }
                store.config.summarization?.inactivityTimeout = $0
                store.saveConfig()
            }
        )
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

struct DurationPicker: View {
    let label: String
    let options: [(label: String, value: Int)]
    @Binding var value: Int

    var body: some View {
        Picker(label, selection: $value) {
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(option.value)
            }
            if !options.contains(where: { $0.value == value }) {
                Text("Custom (\(value))").tag(value)
            }
        }
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
