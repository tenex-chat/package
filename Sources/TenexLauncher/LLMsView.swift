import SwiftUI

struct LLMsView: View {
    @ObservedObject var orchestrator: OrchestratorManager

    @State private var showAddSheet = false
    @State private var selectedConfig: LLMConfigSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Configurations")
                    .font(.headline)

                if orchestrator.llms.configurations.isEmpty {
                    ContentUnavailableView(
                        "No LLM Configurations",
                        systemImage: "cpu",
                        description: Text("Add an LLM configuration to assign models to roles.")
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(sortedConfigKeys.enumerated()), id: \.element) { index, key in
                            if let config = orchestrator.llms.configurations[key] {
                                Button {
                                    selectedConfig = LLMConfigSelection(id: key)
                                } label: {
                                    LLMConfigurationRow(name: key, config: config)
                                        .padding(12)
                                }
                                .buttonStyle(.plain)
                                if index < sortedConfigKeys.count - 1 {
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
            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle("LLMs")
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add LLM", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddLLMSheet(orchestrator: orchestrator, isPresented: $showAddSheet)
        }
        .sheet(item: $selectedConfig) { selection in
            LLMConfigurationEditorSheet(
                orchestrator: orchestrator,
                configName: selection.id,
                providers: providerNames,
                onDelete: {
                    removeConfig(selection.id)
                    selectedConfig = nil
                }
            )
        }
    }

    private var sortedConfigKeys: [String] {
        orchestrator.llms.configurations.keys.sorted()
    }

    private var providerNames: [String] {
        Array(orchestrator.providers.providers.keys).sorted()
    }

    private func removeConfig(_ key: String) {
        orchestrator.llms.configurations.removeValue(forKey: key)
        if orchestrator.llms.default == key { orchestrator.llms.default = nil }
        if orchestrator.llms.summarization == key { orchestrator.llms.summarization = nil }
        if orchestrator.llms.supervision == key { orchestrator.llms.supervision = nil }
        if orchestrator.llms.search == key { orchestrator.llms.search = nil }
        if orchestrator.llms.promptCompilation == key { orchestrator.llms.promptCompilation = nil }
        if orchestrator.llms.compression == key { orchestrator.llms.compression = nil }
        orchestrator.saveLLMs()
    }
}

private struct LLMConfigSelection: Identifiable {
    let id: String
}

private struct LLMConfigurationRow: View {
    let name: String
    let config: LLMConfiguration

    var body: some View {
        HStack(spacing: 10) {
            ProviderLogo(providerID, size: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(providerSummary)
                    Text("•")
                    Text(modelSummary)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var providerID: String {
        switch config {
        case .standard(let standard):
            return standard.provider
        case .meta:
            return ""
        }
    }

    private var providerSummary: String {
        switch config {
        case .standard(let standard):
            return standard.provider.isEmpty ? "Not set" : standard.provider
        case .meta:
            return "meta"
        }
    }

    private var modelSummary: String {
        switch config {
        case .standard(let standard):
            return standard.model.isEmpty ? "Not set" : standard.model
        case .meta(let meta):
            let variants = meta.variants.keys.sorted().compactMap { key -> String? in
                guard let variant = meta.variants[key] else { return nil }
                return "\(key):\(variant.model)"
            }
            if variants.isEmpty {
                return "default=\(meta.defaultVariant)"
            }
            return "default=\(meta.defaultVariant) | " + variants.joined(separator: " OR ")
        }
    }
}

private struct LLMConfigurationEditorSheet: View {
    @ObservedObject var orchestrator: OrchestratorManager
    let configName: String
    let providers: [String]
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let config = orchestrator.llms.configurations[configName] {
                    switch config {
                    case .standard:
                        StandardLLMSection(
                            name: configName,
                            config: standardBinding,
                            providers: providers,
                            providerEntries: orchestrator.providers.providers,
                            onDelete: onDelete
                        )
                    case .meta:
                        MetaLLMSection(
                            name: configName,
                            config: metaBinding,
                            onDelete: onDelete
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "Configuration Not Found",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This configuration no longer exists.")
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
    }

    private var standardBinding: Binding<StandardLLM> {
        Binding(
            get: {
                if case .standard(let standard) = orchestrator.llms.configurations[configName] {
                    return standard
                }
                return StandardLLM(provider: "", model: "")
            },
            set: {
                orchestrator.llms.configurations[configName] = .standard($0)
                orchestrator.saveLLMs()
            }
        )
    }

    private var metaBinding: Binding<MetaLLM> {
        Binding(
            get: {
                if case .meta(let meta) = orchestrator.llms.configurations[configName] {
                    return meta
                }
                return MetaLLM(provider: "meta", variants: [:], defaultVariant: "")
            },
            set: {
                orchestrator.llms.configurations[configName] = .meta($0)
                orchestrator.saveLLMs()
            }
        )
    }
}

// MARK: - Standard LLM Section

struct StandardLLMSection: View {
    let name: String
    @Binding var config: StandardLLM
    let providers: [String]
    let providerEntries: [String: ProviderEntry]
    let onDelete: () -> Void
    @State private var modelOptions: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    var body: some View {
        Section(name) {
            Picker("Provider", selection: $config.provider) {
                Text("Select...").tag("")
                ForEach(providers, id: \.self) { p in
                    Text(p).tag(p)
                }
            }
            .onChange(of: config.provider) { _, _ in
                Task { await reloadModelOptions() }
            }
            .task {
                await reloadModelOptions()
            }

            if modelOptions.isEmpty {
                TextField("Model", text: $config.model)
                    .font(.system(.body, design: .monospaced))
            } else {
                Picker("Model", selection: $config.model) {
                    ForEach(resolvedModelOptions, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
            }

            if isLoadingModels {
                ProgressView()
                    .controlSize(.small)
            }
            if let modelLoadError {
                Text(modelLoadError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OptionalDoubleField(label: "Temperature", value: $config.temperature)
            OptionalIntField(label: "Max Tokens", value: $config.maxTokens)

            if let effort = config.reasoningEffort {
                LabeledContent("Reasoning Effort") {
                    Text(effort)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Remove", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        }
    }

    private var resolvedModelOptions: [String] {
        if config.model.isEmpty || modelOptions.contains(config.model) {
            return modelOptions
        }
        return [config.model] + modelOptions
    }

    private func reloadModelOptions() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        modelLoadError = nil

        do {
            modelOptions = try await ModelCatalogService.fetchModels(
                provider: config.provider,
                providers: providerEntries
            )
        } catch let error as ModelCatalogError {
            modelOptions = []
            modelLoadError = error.errorDescription
        } catch {
            modelOptions = []
            modelLoadError = "Could not load models for \(config.provider)."
        }
    }
}

// MARK: - Meta LLM Section

struct MetaLLMSection: View {
    let name: String
    @Binding var config: MetaLLM
    let onDelete: () -> Void

    var body: some View {
        Section {
            LabeledContent("Type") {
                Text("Meta Model")
                    .foregroundStyle(.secondary)
            }

            Picker("Default Variant", selection: $config.defaultVariant) {
                ForEach(Array(config.variants.keys).sorted(), id: \.self) { key in
                    Text(key).tag(key)
                }
            }

            ForEach(Array(config.variants.keys).sorted(), id: \.self) { variantKey in
                if let variant = config.variants[variantKey] {
                    DisclosureGroup("Variant: \(variantKey)") {
                        LabeledContent("Model") {
                            Text(variant.model)
                                .font(.system(.body, design: .monospaced))
                        }
                        if let desc = variant.description {
                            LabeledContent("Description") {
                                Text(desc)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let tier = variant.tier {
                            LabeledContent("Tier") {
                                Text("\(tier)")
                            }
                        }
                        if let keywords = variant.keywords, !keywords.isEmpty {
                            LabeledContent("Keywords") {
                                Text(keywords.joined(separator: ", "))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Remove", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text(name)
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Role Picker

struct RolePicker: View {
    let label: String
    @Binding var selection: String
    let configs: [String]
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(label, selection: $selection) {
                Text("None").tag("")
                ForEach(configs, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Add Sheet

struct AddLLMSheet: View {
    @ObservedObject var orchestrator: OrchestratorManager
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var modelOptions: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add LLM Configuration")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                Picker("Provider", selection: $provider) {
                    Text("Select...").tag("")
                    ForEach(Array(orchestrator.providers.providers.keys).sorted(), id: \.self) { p in
                        Text(p).tag(p)
                    }
                }
                .onChange(of: provider) { _, _ in
                    Task { await reloadModelOptions() }
                }

                if modelOptions.isEmpty {
                    TextField("Model ID", text: $model)
                        .font(.system(.body, design: .monospaced))
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(resolvedModelOptions, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
                if isLoadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
                if let modelLoadError {
                    Text(modelLoadError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .task {
                await reloadModelOptions()
            }

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    orchestrator.llms.configurations[name] = .standard(
                        StandardLLM(provider: provider, model: model)
                    )
                    orchestrator.saveLLMs()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || provider.isEmpty || model.isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 280)
    }

    private var resolvedModelOptions: [String] {
        if model.isEmpty || modelOptions.contains(model) {
            return modelOptions
        }
        return [model] + modelOptions
    }

    private func reloadModelOptions() async {
        guard !provider.isEmpty else {
            modelOptions = []
            modelLoadError = nil
            return
        }
        isLoadingModels = true
        defer { isLoadingModels = false }
        modelLoadError = nil

        do {
            modelOptions = try await ModelCatalogService.fetchModels(
                provider: provider,
                providers: orchestrator.providers.providers
            )
            if model.isEmpty, let first = modelOptions.first {
                model = first
            }
        } catch let error as ModelCatalogError {
            modelOptions = []
            modelLoadError = error.errorDescription
        } catch {
            modelOptions = []
            modelLoadError = "Could not load models for \(provider)."
        }
    }
}

// MARK: - Field Helpers

struct OptionalDoubleField: View {
    let label: String
    @Binding var value: Double?

    @State private var text = ""

    var body: some View {
        TextField(label, text: $text)
            .onAppear { text = value.map { String($0) } ?? "" }
            .onChange(of: text) { _, newValue in
                value = Double(newValue)
            }
    }
}

struct OptionalIntField: View {
    let label: String
    @Binding var value: Int?

    @State private var text = ""

    var body: some View {
        TextField(label, text: $text)
            .onAppear { text = value.map { String($0) } ?? "" }
            .onChange(of: text) { _, newValue in
                value = Int(newValue)
            }
    }
}
