import ServiceManagement
import SwiftUI

struct GeneralConfigView: View {
    @ObservedObject var orchestrator: OrchestratorManager
    @ObservedObject var negentropySync: NegentropySync
    @ObservedObject var pendingEventsQueue: PendingEventsQueue
    let tab: SidebarTab

    @State private var launchAtLogin = false

    var body: some View {
        Form {
            switch tab {
            case .identity: identitySection
            case .network: networkSection
            case .relay: localRelaySection
            case .roles: rolesSection
            case .embeddings: embeddingsSection
            case .imageGeneration: imageGenerationSection
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
                    get: { orchestrator.config.whitelistedPubkeys ?? [] },
                    set: {
                        orchestrator.config.whitelistedPubkeys = $0.isEmpty ? nil : $0
                        orchestrator.saveConfig()
                    }
                ))
            } header: {
                Text("Authorized Users")
            } footer: {
                Text("Nostr pubkeys authorized to use this TENEX instance. The backend only responds to messages from these users.")
            }
        }
    }

    private var rolesSection: some View {
        Section("Role Assignments") {
            RolePicker(
                label: "Default",
                selection: llmBinding(\.default),
                configs: llmConfigNames,
                help: "Primary fallback model for agent execution when no role-specific model is set."
            )
            RolePicker(
                label: "Summarization",
                selection: llmBinding(\.summarization),
                configs: llmConfigNames,
                help: "Used for conversation summaries and prompt-based analysis helpers."
            )
            RolePicker(
                label: "Supervision",
                selection: llmBinding(\.supervision),
                configs: llmConfigNames,
                help: "Used by the supervisor to verify agent behavior and produce corrections."
            )
            RolePicker(
                label: "Search",
                selection: llmBinding(\.search),
                configs: llmConfigNames,
                help: "Used for LLM-powered web search; falls back to provider search when unavailable."
            )
            RolePicker(
                label: "Prompt Compilation",
                selection: llmBinding(\.promptCompilation),
                configs: llmConfigNames,
                help: "Used to compile lessons and comments into effective system prompts."
            )
            RolePicker(
                label: "Compression",
                selection: llmBinding(\.compression),
                configs: llmConfigNames,
                help: "Optional dedicated model for conversation history compression under context pressure."
            )
        }
    }

    private var llmConfigNames: [String] {
        orchestrator.llms.configurations.keys.sorted()
    }

    private func llmBinding(_ keyPath: WritableKeyPath<TenexLLMs, String?>) -> Binding<String> {
        Binding(
            get: { orchestrator.llms[keyPath: keyPath] ?? "" },
            set: {
                orchestrator.llms[keyPath: keyPath] = $0.isEmpty ? nil : $0
                orchestrator.saveLLMs()
            }
        )
    }

    private var networkSection: some View {
        Section("Network") {
            VStack(alignment: .leading) {
                Text("Relays")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StringListEditor(
                    items: Binding(
                        get: { orchestrator.config.relays ?? ["wss://tenex.chat"] },
                        set: {
                            orchestrator.config.relays = $0.isEmpty ? nil : $0
                            orchestrator.saveConfig()
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

            if orchestrator.launcher.localRelay?.enabled == true {
                Toggle("Auto-start with app", isOn: localRelayAutoStartBinding)

                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", value: localRelayPortBinding, format: .number)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .disabled(orchestrator.relayStatus == .running)
                    if orchestrator.relayStatus == .running {
                        Text("(restart required)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Status")
                    Spacer()
                    LocalRelayStatusView(status: orchestrator.relayStatus)
                }

                if orchestrator.relayStatus == .running {
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
                    switch orchestrator.relayStatus {
                    case .stopped, .failed:
                        Button("Start Relay") {
                            orchestrator.startRelay()
                        }
                    case .starting:
                        Button("Starting...") {}
                            .disabled(true)
                    case .running:
                        Button("Stop Relay") {
                            negentropySync.stop()
                            orchestrator.stopRelay()
                        }

                        Button("Sync Now") {
                            Task {
                                await negentropySync.syncNow()
                            }
                        }
                    }
                }

                if let error = orchestrator.relayError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var appSection: some View {
        Group {
            Section("Startup") {
                Toggle("Start TENEX at login", isOn: $launchAtLogin)
                    .onAppear {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                        orchestrator.launcher.launchAtLogin = enabled
                        orchestrator.saveLauncher()
                    }
            }

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
                    get: { orchestrator.config.telemetry?.enabled ?? true },
                    set: {
                        if orchestrator.config.telemetry == nil {
                            orchestrator.config.telemetry = TelemetryConfig()
                        }
                        orchestrator.config.telemetry?.enabled = $0
                        orchestrator.saveConfig()
                    }
                ))
            }
        }
    }

    private var globalSystemPromptSection: some View {
        Section("Global System Prompt") {
            Toggle("Enabled", isOn: Binding(
                get: { orchestrator.config.globalSystemPrompt?.enabled ?? false },
                set: {
                    if orchestrator.config.globalSystemPrompt == nil {
                        orchestrator.config.globalSystemPrompt = GlobalSystemPrompt()
                    }
                    orchestrator.config.globalSystemPrompt?.enabled = $0
                    orchestrator.saveConfig()
                }
            ))

            TextEditor(text: Binding(
                get: { orchestrator.config.globalSystemPrompt?.content ?? "" },
                set: {
                    if orchestrator.config.globalSystemPrompt == nil {
                        orchestrator.config.globalSystemPrompt = GlobalSystemPrompt()
                    }
                    orchestrator.config.globalSystemPrompt?.content = $0.isEmpty ? nil : $0
                    orchestrator.saveConfig()
                }
            ))
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 100)
        }
    }

    // MARK: - Embeddings

    private var embeddingsSection: some View {
        Section("Embedding Model") {
            Picker("Provider", selection: embedProviderBinding) {
                Text("Local").tag("local")
                if orchestrator.providers.providers["openai"] != nil {
                    Text("OpenAI").tag("openai")
                }
                if orchestrator.providers.providers["openrouter"] != nil {
                    Text("OpenRouter").tag("openrouter")
                }
            }

            Picker("Model", selection: embedModelBinding) {
                ForEach(embedModelsForProvider, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        }
    }

    private var embedModelsForProvider: [String] {
        switch orchestrator.embed.provider ?? "local" {
        case "openai":
            return ["text-embedding-3-small", "text-embedding-3-large", "text-embedding-ada-002"]
        case "openrouter":
            return ["openai/text-embedding-3-small", "openai/text-embedding-3-large", "openai/text-embedding-ada-002"]
        default:
            return ["Xenova/all-MiniLM-L6-v2", "Xenova/all-mpnet-base-v2", "Xenova/paraphrase-multilingual-MiniLM-L12-v2"]
        }
    }

    private var embedProviderBinding: Binding<String> {
        Binding(
            get: { orchestrator.embed.provider ?? "local" },
            set: {
                orchestrator.embed.provider = $0
                let models: [String]
                switch $0 {
                case "openai":
                    models = ["text-embedding-3-small", "text-embedding-3-large", "text-embedding-ada-002"]
                case "openrouter":
                    models = ["openai/text-embedding-3-small", "openai/text-embedding-3-large", "openai/text-embedding-ada-002"]
                default:
                    models = ["Xenova/all-MiniLM-L6-v2", "Xenova/all-mpnet-base-v2", "Xenova/paraphrase-multilingual-MiniLM-L12-v2"]
                }
                orchestrator.embed.model = models.first
                orchestrator.saveEmbed()
            }
        )
    }

    private var embedModelBinding: Binding<String> {
        Binding(
            get: { orchestrator.embed.model ?? embedModelsForProvider.first ?? "" },
            set: {
                orchestrator.embed.model = $0
                orchestrator.saveEmbed()
            }
        )
    }

    // MARK: - Image Generation

    private static let imageModels = [
        "black-forest-labs/flux.2-pro",
        "black-forest-labs/flux.2-max",
        "black-forest-labs/flux.2-klein-4b",
        "google/gemini-2.5-flash-image",
    ]

    private static let aspectRatios = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3"]
    private static let imageSizes = ["1K", "2K", "4K"]

    private var hasOpenRouter: Bool {
        orchestrator.providers.providers["openrouter"] != nil
    }

    private var imageGenerationSection: some View {
        Group {
            if !hasOpenRouter {
                Section("Image Generation") {
                    Text("Image generation requires an OpenRouter provider. Add one in the Providers tab.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Image Generation Model") {
                    Picker("Model", selection: imageModelBinding) {
                        ForEach(Self.imageModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                Section("Defaults") {
                    Picker("Aspect Ratio", selection: imageAspectRatioBinding) {
                        Text("None").tag("")
                        ForEach(Self.aspectRatios, id: \.self) { ratio in
                            Text(ratio).tag(ratio)
                        }
                    }

                    Picker("Image Size", selection: imageSizeBinding) {
                        Text("None").tag("")
                        ForEach(Self.imageSizes, id: \.self) { size in
                            Text(size).tag(size)
                        }
                    }
                }
            }
        }
    }

    private var imageModelBinding: Binding<String> {
        Binding(
            get: { orchestrator.image.model ?? Self.imageModels.first ?? "" },
            set: {
                orchestrator.image.provider = "openrouter"
                orchestrator.image.model = $0
                orchestrator.saveImage()
            }
        )
    }

    private var imageAspectRatioBinding: Binding<String> {
        Binding(
            get: { orchestrator.image.defaultAspectRatio ?? "" },
            set: {
                orchestrator.image.defaultAspectRatio = $0.isEmpty ? nil : $0
                orchestrator.saveImage()
            }
        )
    }

    private var imageSizeBinding: Binding<String> {
        Binding(
            get: { orchestrator.image.defaultImageSize ?? "" },
            set: {
                orchestrator.image.defaultImageSize = $0.isEmpty ? nil : $0
                orchestrator.saveImage()
            }
        )
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

                if orchestrator.config.intervention?.enabled == true {
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

                if orchestrator.config.compression?.enabled != false {
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
            get: { orchestrator.config.escalation?.agent ?? "" },
            set: {
                let value = $0.trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    orchestrator.config.escalation = nil
                } else {
                    if orchestrator.config.escalation == nil {
                        orchestrator.config.escalation = EscalationConfig()
                    }
                    orchestrator.config.escalation?.agent = value
                }
                orchestrator.saveConfig()
            }
        )
    }

    private var interventionEnabledBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.config.intervention?.enabled ?? false },
            set: {
                if orchestrator.config.intervention == nil {
                    orchestrator.config.intervention = InterventionConfig()
                }
                orchestrator.config.intervention?.enabled = $0
                if !$0 { orchestrator.config.intervention = nil }
                orchestrator.saveConfig()
            }
        )
    }

    private var interventionAgentBinding: Binding<String> {
        Binding(
            get: { orchestrator.config.intervention?.agent ?? "" },
            set: {
                if orchestrator.config.intervention == nil {
                    orchestrator.config.intervention = InterventionConfig(enabled: true)
                }
                orchestrator.config.intervention?.agent = $0.isEmpty ? nil : $0
                orchestrator.saveConfig()
            }
        )
    }

    private var interventionReviewTimeoutBinding: Binding<Int> {
        Binding(
            get: { orchestrator.config.intervention?.reviewTimeout ?? 300_000 },
            set: {
                if orchestrator.config.intervention == nil {
                    orchestrator.config.intervention = InterventionConfig(enabled: true)
                }
                orchestrator.config.intervention?.reviewTimeout = $0
                orchestrator.saveConfig()
            }
        )
    }

    private var interventionSkipIfActiveBinding: Binding<Int> {
        Binding(
            get: { orchestrator.config.intervention?.skipIfActiveWithin ?? 120 },
            set: {
                if orchestrator.config.intervention == nil {
                    orchestrator.config.intervention = InterventionConfig(enabled: true)
                }
                orchestrator.config.intervention?.skipIfActiveWithin = $0
                orchestrator.saveConfig()
            }
        )
    }

    // MARK: - Conversations Bindings

    private var compressionEnabledBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.config.compression?.enabled ?? true },
            set: {
                if orchestrator.config.compression == nil {
                    orchestrator.config.compression = CompressionConfig()
                }
                orchestrator.config.compression?.enabled = $0
                orchestrator.saveConfig()
            }
        )
    }

    private var compressionThresholdBinding: Binding<Int> {
        Binding(
            get: { orchestrator.config.compression?.tokenThreshold ?? 50_000 },
            set: {
                if orchestrator.config.compression == nil {
                    orchestrator.config.compression = CompressionConfig()
                }
                orchestrator.config.compression?.tokenThreshold = $0
                orchestrator.saveConfig()
            }
        )
    }

    private var compressionBudgetBinding: Binding<Int> {
        Binding(
            get: { orchestrator.config.compression?.tokenBudget ?? 40_000 },
            set: {
                if orchestrator.config.compression == nil {
                    orchestrator.config.compression = CompressionConfig()
                }
                orchestrator.config.compression?.tokenBudget = $0
                orchestrator.saveConfig()
            }
        )
    }

    private var compressionWindowBinding: Binding<Int> {
        Binding(
            get: { orchestrator.config.compression?.slidingWindowSize ?? 50 },
            set: {
                if orchestrator.config.compression == nil {
                    orchestrator.config.compression = CompressionConfig()
                }
                orchestrator.config.compression?.slidingWindowSize = $0
                orchestrator.saveConfig()
            }
        )
    }

    private var summarizationTimeoutBinding: Binding<Int> {
        Binding(
            get: { orchestrator.config.summarization?.inactivityTimeout ?? 300_000 },
            set: {
                if orchestrator.config.summarization == nil {
                    orchestrator.config.summarization = SummarizationConfig()
                }
                orchestrator.config.summarization?.inactivityTimeout = $0
                orchestrator.saveConfig()
            }
        )
    }

    private func bound(_ keyPath: WritableKeyPath<TenexConfig, String?>, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { orchestrator.config[keyPath: keyPath] ?? defaultValue },
            set: {
                orchestrator.config[keyPath: keyPath] = $0 == defaultValue ? nil : $0
                orchestrator.saveConfig()
            }
        )
    }

    private var logLevelBinding: Binding<String> {
        Binding(
            get: { orchestrator.config.logging?.level ?? "info" },
            set: {
                if orchestrator.config.logging == nil {
                    orchestrator.config.logging = LoggingConfig()
                }
                orchestrator.config.logging?.level = $0
                orchestrator.saveConfig()
            }
        )
    }

    // MARK: - Local Relay Bindings

    private var localRelayEnabledBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.launcher.localRelay?.enabled ?? false },
            set: {
                if orchestrator.launcher.localRelay == nil {
                    orchestrator.launcher.localRelay = LocalRelayConfig()
                }
                orchestrator.launcher.localRelay?.enabled = $0
                orchestrator.saveLauncher()
            }
        )
    }

    private var localRelayAutoStartBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.launcher.localRelay?.autoStart ?? true },
            set: {
                if orchestrator.launcher.localRelay == nil {
                    orchestrator.launcher.localRelay = LocalRelayConfig()
                }
                orchestrator.launcher.localRelay?.autoStart = $0
                orchestrator.saveLauncher()
            }
        )
    }

    private var localRelayPortBinding: Binding<Int> {
        Binding(
            get: { orchestrator.launcher.localRelay?.port ?? 7777 },
            set: {
                if orchestrator.launcher.localRelay == nil {
                    orchestrator.launcher.localRelay = LocalRelayConfig()
                }
                orchestrator.launcher.localRelay?.port = $0
                orchestrator.saveLauncher()
            }
        )
    }
}

// MARK: - Local Relay Status View

struct LocalRelayStatusView: View {
    let status: FfiProcessStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
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

    private var statusLabel: String {
        switch status {
        case .stopped: "Stopped"
        case .starting: "Starting..."
        case .running: "Running"
        case .failed: "Failed"
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
