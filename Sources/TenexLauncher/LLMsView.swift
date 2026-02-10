import SwiftUI

struct LLMsView: View {
    @ObservedObject var store: ConfigStore

    @State private var showAddSheet = false

    var body: some View {
        Form {
            // Role assignments
            Section("Role Assignments") {
                RolePicker(label: "Default", selection: binding(\.default), configs: configNames)
                RolePicker(label: "Summarization", selection: binding(\.summarization), configs: configNames)
                RolePicker(label: "Supervision", selection: binding(\.supervision), configs: configNames)
                RolePicker(label: "Search", selection: binding(\.search), configs: configNames)
                RolePicker(label: "Compression", selection: binding(\.compression), configs: configNames)
            }

            // Configurations
            if store.llms.configurations.isEmpty {
                ContentUnavailableView(
                    "No LLM Configurations",
                    systemImage: "cpu",
                    description: Text("Add an LLM configuration to assign models to roles.")
                )
            } else {
                ForEach(sortedConfigKeys, id: \.self) { key in
                    let config = store.llms.configurations[key]!
                    switch config {
                    case .standard:
                        StandardLLMSection(
                            name: key,
                            config: standardBinding(for: key),
                            providers: providerNames,
                            onDelete: { removeConfig(key) }
                        )
                    case .meta:
                        MetaLLMSection(
                            name: key,
                            config: metaBinding(for: key),
                            configNames: configNames,
                            onDelete: { removeConfig(key) }
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
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
            AddLLMSheet(store: store, isPresented: $showAddSheet)
        }
    }

    private var sortedConfigKeys: [String] {
        store.llms.configurations.keys.sorted()
    }

    private var configNames: [String] {
        sortedConfigKeys
    }

    private var providerNames: [String] {
        Array(store.providers.providers.keys).sorted()
    }

    private func binding(_ keyPath: WritableKeyPath<TenexLLMs, String?>) -> Binding<String> {
        Binding(
            get: { store.llms[keyPath: keyPath] ?? "" },
            set: {
                store.llms[keyPath: keyPath] = $0.isEmpty ? nil : $0
                store.saveLLMs()
            }
        )
    }

    private func standardBinding(for key: String) -> Binding<StandardLLM> {
        Binding(
            get: {
                if case .standard(let s) = store.llms.configurations[key] { return s }
                return StandardLLM(provider: "", model: "")
            },
            set: {
                store.llms.configurations[key] = .standard($0)
                store.saveLLMs()
            }
        )
    }

    private func metaBinding(for key: String) -> Binding<MetaLLM> {
        Binding(
            get: {
                if case .meta(let m) = store.llms.configurations[key] { return m }
                return MetaLLM(provider: "meta", variants: [:], defaultVariant: "")
            },
            set: {
                store.llms.configurations[key] = .meta($0)
                store.saveLLMs()
            }
        )
    }

    private func removeConfig(_ key: String) {
        store.llms.configurations.removeValue(forKey: key)
        if store.llms.default == key { store.llms.default = nil }
        if store.llms.summarization == key { store.llms.summarization = nil }
        if store.llms.supervision == key { store.llms.supervision = nil }
        if store.llms.search == key { store.llms.search = nil }
        if store.llms.compression == key { store.llms.compression = nil }
        store.saveLLMs()
    }
}

// MARK: - Standard LLM Section

struct StandardLLMSection: View {
    let name: String
    @Binding var config: StandardLLM
    let providers: [String]
    let onDelete: () -> Void

    var body: some View {
        Section(name) {
            Picker("Provider", selection: $config.provider) {
                Text("Select...").tag("")
                ForEach(providers, id: \.self) { p in
                    Text(p).tag(p)
                }
            }

            TextField("Model", text: $config.model)
                .font(.system(.body, design: .monospaced))

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
}

// MARK: - Meta LLM Section

struct MetaLLMSection: View {
    let name: String
    @Binding var config: MetaLLM
    let configNames: [String]
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

    var body: some View {
        Picker(label, selection: $selection) {
            Text("None").tag("")
            ForEach(configs, id: \.self) { name in
                Text(name).tag(name)
            }
        }
    }
}

// MARK: - Add Sheet

struct AddLLMSheet: View {
    @ObservedObject var store: ConfigStore
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var provider = ""
    @State private var model = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add LLM Configuration")
                .font(.headline)

            Form {
                TextField("Name", text: $name)

                Picker("Provider", selection: $provider) {
                    Text("Select...").tag("")
                    ForEach(Array(store.providers.providers.keys).sorted(), id: \.self) { p in
                        Text(p).tag(p)
                    }
                }

                TextField("Model ID", text: $model)
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    store.llms.configurations[name] = .standard(
                        StandardLLM(provider: provider, model: model)
                    )
                    store.saveLLMs()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || provider.isEmpty || model.isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 280)
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
