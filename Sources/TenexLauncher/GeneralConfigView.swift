import SwiftUI

struct GeneralConfigView: View {
    @ObservedObject var store: ConfigStore

    var body: some View {
        Form {
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
        .formStyle(.grouped)
        .navigationTitle("General")
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
