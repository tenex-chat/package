import SwiftUI

struct ProvidersView: View {
    @ObservedObject var store: ConfigStore

    @State private var newProviderName = ""
    @State private var showAddSheet = false

    var body: some View {
        Form {
            if store.providers.providers.isEmpty {
                ContentUnavailableView(
                    "No Providers",
                    systemImage: "key.slash",
                    description: Text("Add an API provider to get started.")
                )
            } else {
                ForEach(sortedProviderKeys, id: \.self) { key in
                    ProviderRow(
                        name: key,
                        entry: binding(for: key),
                        onDelete: { removeProvider(key) }
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
        .toolbar {
            ToolbarItem {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Provider", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet(store: store, isPresented: $showAddSheet)
        }
    }

    private var sortedProviderKeys: [String] {
        store.providers.providers.keys.sorted()
    }

    private func binding(for key: String) -> Binding<ProviderEntry> {
        Binding(
            get: { store.providers.providers[key] ?? ProviderEntry(apiKey: "") },
            set: {
                store.providers.providers[key] = $0
                store.saveProviders()
            }
        )
    }

    private func removeProvider(_ key: String) {
        store.providers.providers.removeValue(forKey: key)
        store.saveProviders()
    }
}

struct ProviderRow: View {
    let name: String
    @Binding var entry: ProviderEntry
    let onDelete: () -> Void

    @State private var showKey = false

    var body: some View {
        Section(name) {
            HStack {
                if showKey {
                    TextField("API Key", text: $entry.apiKey)
                        .font(.system(.body, design: .monospaced))
                } else {
                    SecureField("API Key", text: $entry.apiKey)
                }
                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
            }

            if let baseUrl = entry.baseUrl, !baseUrl.isEmpty {
                LabeledContent("Base URL") {
                    Text(baseUrl)
                        .font(.system(.body, design: .monospaced))
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

struct AddProviderSheet: View {
    @ObservedObject var store: ConfigStore
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var apiKey = ""
    @State private var baseUrl = ""

    private let knownProviders = ["anthropic", "openai", "openrouter", "google", "ollama"]

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Provider")
                .font(.headline)

            Form {
                Picker("Provider", selection: $name) {
                    Text("Select...").tag("")
                    ForEach(availableProviders, id: \.self) { provider in
                        Text(provider).tag(provider)
                    }
                }

                SecureField("API Key", text: $apiKey)
                    .font(.system(.body, design: .monospaced))

                TextField("Base URL (optional)", text: $baseUrl)
                    .font(.system(.body, design: .monospaced))
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    store.providers.providers[name] = ProviderEntry(
                        apiKey: apiKey,
                        baseUrl: baseUrl.isEmpty ? nil : baseUrl
                    )
                    store.saveProviders()
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || apiKey.isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 300)
    }

    private var availableProviders: [String] {
        let existing = Set(store.providers.providers.keys)
        return knownProviders.filter { !existing.contains($0) }
    }
}
