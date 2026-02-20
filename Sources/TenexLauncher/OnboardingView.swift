import Foundation
import SwiftUI

private let onboardingProviderDisplayNames: [String: String] = [
    "openrouter": "OpenRouter",
    "ollama": "Ollama",
    "claude-code": "Claude Code",
    "codex-app-server": "Codex App Server",
]

private let providerPriority = ["codex-app-server", "claude-code", "openrouter", "ollama"]
private let onboardingProviderList = ["openrouter", "claude-code", "codex-app-server", "ollama"]

struct OnboardingView: View {
    @ObservedObject var store: ConfigStore

    @StateObject private var viewModel = OnboardingViewModel()
    @State private var openRouterApiKey = ""
    @State private var openRouterError: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to TENEX")
                .font(.largeTitle.weight(.semibold))

            Text("Let’s configure providers and create initial model settings.")
                .foregroundStyle(.secondary)

            if viewModel.step == .providers {
                providersStep
            } else {
                llmsStep
            }

            HStack {
                if viewModel.step == .llms {
                    Button("Back") {
                        viewModel.step = .providers
                    }
                }

                Spacer()

                if viewModel.step == .providers {
                    Button("Continue") {
                        viewModel.step = .llms
                        Task { await viewModel.loadModelsForConfiguredProviders() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.connectedProviderKeys.isEmpty || viewModel.isDetectingProviders)
                } else {
                    Button("Finish Setup") {
                        isSaving = true
                        viewModel.finishOnboarding(store: store)
                        isSaving = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !viewModel.hasValidDrafts)
                }
            }
        }
        .padding(24)
        .task {
            await viewModel.detectProvidersIfNeeded()
        }
    }

    private var providersStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if viewModel.isDetectingProviders {
                ProgressView("Detecting local providers...")
            }

            providerCard(
                title: "Providers",
                rows: onboardingProviderList.map { key in
                    ProviderRowData(
                        id: key,
                        name: onboardingProviderDisplayNames[key] ?? key,
                        subtitle: viewModel.providerSubtitle(for: key),
                        iconSystemName: viewModel.iconName(for: key),
                        buttonLabel: viewModel.buttonLabel(for: key),
                        buttonDisabled: viewModel.buttonDisabled(for: key)
                    )
                },
                onButtonTap: { id in
                    if viewModel.isProviderConnected(id) {
                        viewModel.disconnectProvider(id)
                        return
                    }

                    if id == "openrouter" {
                        openRouterError = nil
                        viewModel.showOpenRouterConnect = true
                        return
                    }

                    viewModel.connectProvider(id)
                }
            )
        }
        .sheet(isPresented: $viewModel.showOpenRouterConnect) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect OpenRouter")
                    .font(.headline)
                SecureField("API key", text: $openRouterApiKey)
                    .textFieldStyle(.roundedBorder)
                if let openRouterError {
                    Text(openRouterError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Button("Cancel") {
                        viewModel.showOpenRouterConnect = false
                    }
                    Spacer()
                    Button("Connect") {
                        let trimmed = openRouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else {
                            openRouterError = "API key is required."
                            return
                        }
                        viewModel.connectOpenRouter(apiKey: trimmed)
                        openRouterApiKey = ""
                        viewModel.showOpenRouterConnect = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }

    private var llmsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isLoadingModels {
                ProgressView("Loading model catalogs...")
            }

            ForEach(viewModel.connectedProviderKeys, id: \.self) { provider in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(onboardingProviderDisplayNames[provider] ?? provider)
                            .font(.headline)

                        if let error = viewModel.modelLoadErrors[provider] {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        let indices = viewModel.draftIndices(for: provider)
                        if indices.isEmpty {
                            Text("No configurations yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 6) {
                                TextField("Configuration name", text: $viewModel.llmDrafts[index].name)
                                    .textFieldStyle(.roundedBorder)
                                let models = viewModel.models(for: provider)
                                if models.isEmpty {
                                    TextField("Model ID", text: $viewModel.llmDrafts[index].model)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                } else {
                                    Picker("Model", selection: $viewModel.llmDrafts[index].model) {
                                        ForEach(models, id: \.self) { model in
                                            Text(model).tag(model)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }

                                if provider == "codex-app-server" {
                                    Picker("Reasoning effort", selection: $viewModel.llmDrafts[index].reasoningEffort) {
                                        Text("Default").tag("")
                                        Text("low").tag("low")
                                        Text("medium").tag("medium")
                                        Text("high").tag("high")
                                        Text("xhigh").tag("xhigh")
                                    }
                                    .pickerStyle(.menu)
                                }

                                HStack {
                                    Spacer()
                                    Button("Remove", role: .destructive) {
                                        viewModel.removeDraft(id: viewModel.llmDrafts[index].id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }

                        Button {
                            viewModel.addDraft(for: provider)
                        } label: {
                            Label("Add Configuration", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func providerCard(
        title: String,
        rows: [ProviderRowData],
        onButtonTap: ((String) -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                if rows.isEmpty {
                    HStack {
                        Text("No providers connected")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(12)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 12) {
                            Image(systemName: row.iconSystemName)
                                .font(.title3)
                                .frame(width: 24)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.body.weight(.medium))
                                Text(row.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let label = row.buttonLabel {
                                Button(label) {
                                    onButtonTap?(row.id)
                                }
                                .buttonStyle(.bordered)
                                .disabled(row.buttonDisabled)
                            }
                        }
                        .padding(12)
                        if index < rows.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }
}

struct ProviderRowData {
    let id: String
    let name: String
    let subtitle: String
    let iconSystemName: String
    let buttonLabel: String?
    let buttonDisabled: Bool
}

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step {
        case providers
        case llms
    }

    @Published var step: Step = .providers
    @Published var isDetectingProviders = false
    @Published var isLoadingModels = false
    @Published var showOpenRouterConnect = false

    @Published var providers: [String: ProviderEntry] = [:]
    @Published var llmDrafts: [LLMConfigDraft] = []
    @Published var ollamaModels: [String] = []
    @Published var openRouterModels: [String] = []
    @Published var modelLoadErrors: [String: String] = [:]
    @Published var providerAvailability: [String: Bool] = [
        "openrouter": true,
        "claude-code": false,
        "codex-app-server": false,
        "ollama": false,
    ]

    private var hasDetected = false

    var connectedProviderKeys: [String] {
        providers.keys.sorted { lhs, rhs in
            let lhsIndex = providerPriority.firstIndex(of: lhs) ?? .max
            let rhsIndex = providerPriority.firstIndex(of: rhs) ?? .max
            if lhsIndex == rhsIndex {
                return lhs < rhs
            }
            return lhsIndex < rhsIndex
        }
    }

    var hasValidDrafts: Bool {
        llmDrafts.contains {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func draftIndices(for provider: String) -> [Int] {
        llmDrafts.enumerated().compactMap { index, draft in
            draft.provider == provider ? index : nil
        }
    }

    func addDraft(for provider: String) {
        let suggestedModel = models(for: provider).first ?? defaultModel(for: provider)
        llmDrafts.append(
            LLMConfigDraft(
                provider: provider,
                name: suggestedDraftName(for: provider),
                model: suggestedModel
            )
        )
    }

    func removeDraft(id: UUID) {
        llmDrafts.removeAll { $0.id == id }
    }

    func detectProvidersIfNeeded() async {
        guard !hasDetected else { return }
        hasDetected = true
        isDetectingProviders = true
        defer { isDetectingProviders = false }

        let hasClaude = Self.commandExists("claude")
        providerAvailability["claude-code"] = hasClaude
        if hasClaude {
            connectProvider("claude-code")
        }

        let hasCodex = Self.commandExists("codex")
        providerAvailability["codex-app-server"] = hasCodex
        if hasCodex {
            connectProvider("codex-app-server")
        }

        let hasOllamaCommand = Self.commandExists("ollama")
        if hasOllamaCommand {
            let baseURL = "http://localhost:11434"
            providers["ollama"] = ProviderEntry(apiKey: baseURL)
            do {
                let models = try await ModelCatalogService.fetchModels(provider: "ollama", providers: providers)
                providerAvailability["ollama"] = true
                ollamaModels = models
                if let first = models.first {
                    ensureDefaultDraft(for: "ollama", model: first)
                }
            } catch {
                providerAvailability["ollama"] = false
                providers.removeValue(forKey: "ollama")
            }
        } else {
            providerAvailability["ollama"] = false
        }
    }

    func connectProvider(_ provider: String) {
        guard !isProviderConnected(provider) else { return }
        switch provider {
        case "claude-code":
            guard providerAvailability["claude-code"] == true else { return }
            providers["claude-code"] = ProviderEntry(apiKey: "none")
            ensureDefaultDraft(for: "claude-code", model: "claude-sonnet-4-20250514")
        case "codex-app-server":
            guard providerAvailability["codex-app-server"] == true else { return }
            providers["codex-app-server"] = ProviderEntry(apiKey: "none")
            ensureDefaultDraft(for: "codex-app-server", model: "gpt-5.1-codex-max")
        case "ollama":
            guard providerAvailability["ollama"] == true else { return }
            let baseURL = "http://localhost:11434"
            providers["ollama"] = ProviderEntry(apiKey: baseURL)
            if let first = ollamaModels.first {
                ensureDefaultDraft(for: "ollama", model: first)
            }
        default:
            return
        }
    }

    func connectOpenRouter(apiKey: String) {
        providers["openrouter"] = ProviderEntry(apiKey: apiKey)
        ensureDefaultDraft(for: "openrouter", model: openRouterModels.first ?? "")
    }

    func isProviderConnected(_ provider: String) -> Bool {
        providers[provider] != nil
    }

    func disconnectProvider(_ provider: String) {
        providers.removeValue(forKey: provider)
        llmDrafts.removeAll { $0.provider == provider }
        modelLoadErrors.removeValue(forKey: provider)
        if provider == "openrouter" {
            openRouterModels = []
        }
    }

    func buttonLabel(for provider: String) -> String {
        isProviderConnected(provider) ? "Disconnect" : "Connect"
    }

    func buttonDisabled(for provider: String) -> Bool {
        if isProviderConnected(provider) { return false }
        if provider == "openrouter" { return false }
        return providerAvailability[provider] != true
    }

    func iconName(for provider: String) -> String {
        switch provider {
        case "openrouter":
            return "arrow.triangle.2.circlepath"
        case "claude-code":
            return "a.circle"
        case "codex-app-server":
            return "chevron.left.forwardslash.chevron.right"
        case "ollama":
            return "desktopcomputer"
        default:
            return "circle"
        }
    }

    func providerSubtitle(for provider: String) -> String {
        if isProviderConnected(provider) {
            switch provider {
            case "claude-code":
                return "Detected from local `claude` command"
            case "codex-app-server":
                return "Detected from local `codex` command"
            case "ollama":
                return "Detected local Ollama and reachable API"
            case "openrouter":
                return "Connected with API key"
            default:
                return "Connected"
            }
        }

        switch provider {
        case "claude-code":
            return "Requires local `claude` command"
        case "codex-app-server":
            return "Requires local `codex` command"
        case "ollama":
            return "Requires `ollama` command and reachable local server"
        case "openrouter":
            return "Use API key to access hosted models"
        default:
            return "Not connected"
        }
    }

    func loadModelsForConfiguredProviders() async {
        isLoadingModels = true
        defer { isLoadingModels = false }

        modelLoadErrors = [:]

        if let ollamaProvider = providers["ollama"] {
            let baseURL = ollamaProvider.apiKey.isEmpty ? "http://localhost:11434" : ollamaProvider.apiKey
            do {
                let models = try await ModelCatalogService.fetchModels(provider: "ollama", providers: providers)
                ollamaModels = models
                if let first = models.first {
                    fillMissingModels(for: "ollama", fallbackModel: first)
                }
            } catch {
                modelLoadErrors["ollama"] = "Could not load Ollama models from \(baseURL)."
            }
        }

        if let openRouterProvider = providers["openrouter"] {
            let apiKey = openRouterProvider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                modelLoadErrors["openrouter"] = "OpenRouter API key is missing."
                return
            }
            do {
                let models = try await ModelCatalogService.fetchModels(provider: "openrouter", providers: providers)
                openRouterModels = models
                if let first = models.first {
                    fillMissingModels(for: "openrouter", fallbackModel: first)
                }
            } catch {
                modelLoadErrors["openrouter"] = "Could not load OpenRouter models with the provided API key."
            }
        }
    }

    func models(for provider: String) -> [String] {
        switch provider {
        case "ollama":
            return ollamaModels
        case "openrouter":
            return openRouterModels
        default:
            return []
        }
    }

    func finishOnboarding(store: ConfigStore) {
        store.providers = TenexProviders(providers: providers)
        store.saveProviders()

        var newLLMs = TenexLLMs()
        var providerToFirstConfigName: [String: String] = [:]
        var usedConfigNames = Set<String>()

        for draft in llmDrafts {
            let provider = draft.provider
            let selectedModel = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
            var configName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selectedModel.isEmpty, !configName.isEmpty else { continue }

            if usedConfigNames.contains(configName) {
                var suffix = 2
                while usedConfigNames.contains("\(configName)-\(suffix)") {
                    suffix += 1
                }
                configName = "\(configName)-\(suffix)"
            }

            usedConfigNames.insert(configName)
            if providerToFirstConfigName[provider] == nil {
                providerToFirstConfigName[provider] = configName
            }
            let effort = draft.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            newLLMs.configurations[configName] = .standard(
                StandardLLM(
                    provider: provider,
                    model: selectedModel,
                    temperature: nil,
                    maxTokens: nil,
                    topP: nil,
                    reasoningEffort: effort.isEmpty ? nil : effort
                )
            )
        }

        if let defaultConfig = Self.pickDefaultConfig(providerToConfigName: providerToFirstConfigName) {
            newLLMs.default = defaultConfig
            newLLMs.summarization = defaultConfig
            newLLMs.supervision = defaultConfig
            newLLMs.search = defaultConfig
            newLLMs.compression = defaultConfig
        }

        if !newLLMs.configurations.isEmpty {
            store.llms = newLLMs
            store.saveLLMs()
        }

        if !store.configExists {
            store.saveConfig()
        }
    }

    private static func pickDefaultConfig(providerToConfigName: [String: String]) -> String? {
        for provider in providerPriority {
            if let config = providerToConfigName[provider] {
                return config
            }
        }
        return providerToConfigName.values.sorted().first
    }

    private func ensureDefaultDraft(for provider: String, model: String) {
        if !llmDrafts.contains(where: { $0.provider == provider }) {
            llmDrafts.append(
                LLMConfigDraft(
                    provider: provider,
                    name: suggestedDraftName(for: provider),
                    model: model
                )
            )
            return
        }

        if let index = llmDrafts.firstIndex(where: {
            $0.provider == provider && $0.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            llmDrafts[index].model = model
        }
    }

    private func fillMissingModels(for provider: String, fallbackModel: String) {
        for index in llmDrafts.indices where llmDrafts[index].provider == provider {
            if llmDrafts[index].model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                llmDrafts[index].model = fallbackModel
            }
        }
    }

    private func suggestedDraftName(for provider: String) -> String {
        let base: String
        switch provider {
        case "codex-app-server":
            base = "codex"
        case "claude-code":
            base = "claude code"
        case "openrouter":
            base = "openrouter"
        case "ollama":
            base = "ollama"
        default:
            base = provider
        }

        var candidate = base
        var suffix = 2
        let existing = Set(llmDrafts.map { $0.name.lowercased() })
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func defaultModel(for provider: String) -> String {
        switch provider {
        case "codex-app-server":
            return "gpt-5.1-codex-max"
        case "claude-code":
            return "claude-sonnet-4-20250514"
        default:
            return ""
        }
    }

    private static func commandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command) >/dev/null 2>&1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

}

struct LLMConfigDraft: Identifiable {
    let id: UUID
    let provider: String
    var name: String
    var model: String
    var reasoningEffort: String

    init(
        id: UUID = UUID(),
        provider: String,
        name: String,
        model: String,
        reasoningEffort: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}
