import Foundation
import SwiftUI

private let providerListOrder = [
    "openrouter",
    "anthropic",
    "openai",
    "ollama",
    "claude-code",
    "gemini-cli",
    "codex-app-server",
]

private let localCommandProviders: [String: String] = [
    "claude-code": "claude",
    "codex-app-server": "codex",
    "gemini-cli": "gemini",
]

private let settingsProviderDisplayNames: [String: String] = [
    "openrouter": "OpenRouter",
    "anthropic": "Anthropic",
    "openai": "OpenAI",
    "ollama": "Ollama",
    "claude-code": "Claude Code",
    "gemini-cli": "Gemini CLI",
    "codex-app-server": "Codex App Server",
]

private let apiKeyEnvVars: [String: String] = [
    "anthropic": "ANTHROPIC_API_KEY",
    "openai": "OPENAI_API_KEY",
    "openrouter": "OPENROUTER_API_KEY",
]

private func isOAuthSetupToken(_ key: String) -> Bool {
    key.hasPrefix("sk-ant-oat")
}

private func requiresApiKey(_ provider: String) -> Bool {
    ["openrouter", "openai", "anthropic", "ollama"].contains(provider)
}

struct ProvidersView: View {
    @ObservedObject var orchestrator: OrchestratorManager

    @State private var providerAvailability: [String: Bool] = [:]
    @State private var showCredentialSheet = false
    @State private var showManageSheet = false
    @State private var selectedProvider = ""
    @State private var credentialValue = ""
    @State private var credentialError: String?
    @State private var isAddingKey = false // true when adding a key to existing provider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerCard(
                title: "Providers",
                rows: providerListOrder.map { provider in
                    let connected = isConnected(provider)
                    let entry = orchestrator.providers.providers[provider]
                    let hasMultipleKeys = (entry?.apiKeys.count ?? 0) > 1
                    let isApiKeyProvider = requiresApiKey(provider) && connected

                    return SettingsProviderRowData(
                        id: provider,
                        name: settingsProviderDisplayNames[provider] ?? provider,
                        subtitle: subtitle(for: provider),
                        isConnected: connected,
                        showManage: isApiKeyProvider && connected,
                        showAdd: isApiKeyProvider && connected,
                        showDisconnect: connected && !isApiKeyProvider,
                        showConnect: !connected,
                        buttonDisabled: buttonDisabled(for: provider)
                    )
                }
            )
            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle("Providers")
        .task {
            await detectLocalAvailability()
            autoConnectDetected()
        }
        .sheet(isPresented: $showCredentialSheet) {
            providerCredentialSheet
        }
        .sheet(isPresented: $showManageSheet) {
            providerManageSheet
        }
    }

    // MARK: - Credential Sheet

    private var providerCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isAddingKey
                 ? "Add Key to \(settingsProviderDisplayNames[selectedProvider] ?? selectedProvider)"
                 : "Connect \(settingsProviderDisplayNames[selectedProvider] ?? selectedProvider)")
                .font(.headline)

            if selectedProvider == "ollama" {
                TextField("Ollama URL", text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else if selectedProvider == "anthropic" {
                SecureField("API key or setup-token", text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("Paste an API key (sk-ant-api...) or a setup-token from `claude setup-token` (sk-ant-oat...) to use your Max subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecureField("API key", text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let credentialError {
                Text(credentialError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    showCredentialSheet = false
                }
                Spacer()
                Button(isAddingKey ? "Add" : "Connect") {
                    let trimmed = credentialValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        credentialError = selectedProvider == "ollama" ? "URL is required." : "API key is required."
                        return
                    }
                    if isAddingKey {
                        orchestrator.addProviderKey(providerId: selectedProvider, apiKey: trimmed)
                    } else {
                        orchestrator.connectProvider(id: selectedProvider, apiKey: trimmed)
                    }
                    if selectedProvider == "openrouter" {
                        syncOpenRouterKeyToMacApp(trimmed)
                    }
                    credentialValue = ""
                    credentialError = nil
                    showCredentialSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    // MARK: - Manage Sheet

    private var providerManageSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage \(settingsProviderDisplayNames[selectedProvider] ?? selectedProvider) Keys")
                .font(.headline)

            let keys = orchestrator.providers.providers[selectedProvider]?.apiKeys ?? []

            if keys.isEmpty {
                Text("No keys configured.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        HStack {
                            if index == 0 {
                                Text("Primary")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.blue.opacity(0.15)))
                                    .foregroundStyle(.blue)
                            }
                            Text(maskedKey(key))
                                .font(.system(.caption, design: .monospaced))
                            Spacer()

                            if keys.count > 1 {
                                if index > 0 {
                                    Button {
                                        orchestrator.reorderProviderKey(
                                            providerId: selectedProvider,
                                            fromIndex: UInt32(index),
                                            toIndex: UInt32(index - 1)
                                        )
                                    } label: {
                                        Image(systemName: "arrow.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }

                                if index < keys.count - 1 {
                                    Button {
                                        orchestrator.reorderProviderKey(
                                            providerId: selectedProvider,
                                            fromIndex: UInt32(index),
                                            toIndex: UInt32(index + 1)
                                        )
                                    } label: {
                                        Image(systemName: "arrow.down")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            Button {
                                orchestrator.removeProviderKey(
                                    providerId: selectedProvider,
                                    index: UInt32(index)
                                )
                                // If no keys left, close the sheet
                                if (orchestrator.providers.providers[selectedProvider]?.apiKeys ?? []).isEmpty {
                                    showManageSheet = false
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(8)

                        if index < keys.count - 1 {
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
            }

            HStack {
                Button("Disconnect") {
                    disconnect(selectedProvider)
                    showManageSheet = false
                }
                .foregroundStyle(.red)

                Spacer()

                Button("Add Key") {
                    showManageSheet = false
                    isAddingKey = true
                    credentialValue = ""
                    credentialError = nil
                    showCredentialSheet = true
                }

                Button("Done") {
                    showManageSheet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func maskedKey(_ key: String) -> String {
        if key.count <= 8 { return key }
        return "\(key.prefix(6))...\(key.suffix(4))"
    }

    // MARK: - Helpers

    private func syncOpenRouterKeyToMacApp(_ key: String) {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tenex.mvp/credentials/openrouter_api_key.txt")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? key.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeOpenRouterKeyFromMacApp() {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.tenex.mvp/credentials/openrouter_api_key.txt")
        try? FileManager.default.removeItem(at: url)
    }

    private func connect(_ provider: String) {
        credentialError = nil
        selectedProvider = provider
        isAddingKey = false

        if provider == "ollama" {
            credentialValue = "http://localhost:11434"
            showCredentialSheet = true
            return
        }

        if provider == "openrouter" || provider == "openai" || provider == "anthropic" {
            credentialValue = ""
            showCredentialSheet = true
            return
        }

        orchestrator.connectProvider(id: provider, apiKey: "none")
    }

    private func disconnect(_ provider: String) {
        orchestrator.disconnectProvider(id: provider)
        if provider == "openrouter" {
            removeOpenRouterKeyFromMacApp()
        }
    }

    private func isConnected(_ provider: String) -> Bool {
        orchestrator.providers.providers[provider] != nil
    }

    private func buttonDisabled(for provider: String) -> Bool {
        if isConnected(provider) { return false }
        if provider == "openrouter" || provider == "openai" || provider == "anthropic" || provider == "ollama" {
            return false
        }
        return providerAvailability[provider] != true
    }

    private func subtitle(for provider: String) -> String {
        guard let entry = orchestrator.providers.providers[provider] else {
            switch provider {
            case "openrouter": return "Use API key to access hosted models"
            case "openai": return "Use OpenAI API key"
            case "anthropic": return "API key or setup-token from `claude setup-token`"
            case "ollama": return "Connect to your local Ollama endpoint"
            case "claude-code": return "Requires local `claude` command"
            case "codex-app-server": return "Requires local `codex` command"
            case "gemini-cli": return "Requires local `gemini` command"
            default: return "Not configured"
            }
        }

        let keySuffix = entry.apiKeys.count > 1 ? " (\(entry.apiKeys.count) keys)" : ""

        switch provider {
        case "anthropic":
            if let key = entry.primaryKey, isOAuthSetupToken(key) {
                return "Connected with setup-token (Max subscription)\(keySuffix)"
            }
            return "Connected with API key\(keySuffix)"
        case "openrouter", "openai":
            return "Connected with API key\(keySuffix)"
        case "ollama":
            return "Connected local endpoint (\(entry.primaryKey ?? "http://localhost:11434"))"
        case "claude-code":
            return "Connected from local `claude` command"
        case "codex-app-server":
            return "Connected from local `codex` command"
        case "gemini-cli":
            return "Connected from local `gemini` command"
        default:
            return "Connected"
        }
    }

    private func detectLocalAvailability() async {
        var availability: [String: Bool] = [:]
        for (provider, command) in localCommandProviders {
            availability[provider] = Self.commandExists(command)
        }
        if Self.commandExists("ollama") {
            availability["ollama"] = await Self.ollamaReachable(baseURL: "http://localhost:11434")
        } else {
            availability["ollama"] = false
        }
        providerAvailability = availability
    }

    private func autoConnectDetected() {
        // Auto-connect local command providers that are available
        for (provider, _) in localCommandProviders {
            if providerAvailability[provider] == true && !isConnected(provider) {
                orchestrator.providers.providers[provider] = ProviderEntry(apiKey: "none")
            }
        }

        // Auto-connect ollama if available
        if providerAvailability["ollama"] == true && !isConnected("ollama") {
            orchestrator.providers.providers["ollama"] = ProviderEntry(apiKey: "http://localhost:11434")
        }

        // Auto-connect API key providers from env vars
        for (provider, envVar) in apiKeyEnvVars {
            if !isConnected(provider), let apiKey = ProcessInfo.processInfo.environment[envVar], !apiKey.isEmpty {
                orchestrator.providers.providers[provider] = ProviderEntry(apiKey: apiKey)
                if provider == "openrouter" {
                    syncOpenRouterKeyToMacApp(apiKey)
                }
            }
        }

        // Auto-connect Anthropic from ANTHROPIC_AUTH_TOKEN (OAuth setup-token)
        if !isConnected("anthropic"),
           let authToken = ProcessInfo.processInfo.environment["ANTHROPIC_AUTH_TOKEN"],
           !authToken.isEmpty {
            orchestrator.providers.providers["anthropic"] = ProviderEntry(apiKey: authToken)
        }

        orchestrator.saveProviders()
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

    private static func ollamaReachable(baseURL: String) async -> Bool {
        guard var components = URLComponents(string: baseURL) else { return false }
        components.path = "/api/tags"
        guard let url = components.url else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Provider Card

    private func providerCard(
        title: String,
        rows: [SettingsProviderRowData]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 12) {
                        ProviderLogo(row.id, size: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(row.name)
                                    .font(.body.weight(.medium))
                                if row.isConnected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.body)
                                }
                            }
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if row.showManage {
                            Button("Manage") {
                                selectedProvider = row.id
                                showManageSheet = true
                            }
                            .buttonStyle(.bordered)

                            Button {
                                selectedProvider = row.id
                                isAddingKey = true
                                credentialValue = ""
                                credentialError = nil
                                showCredentialSheet = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                        } else if row.showDisconnect {
                            Button("Disconnect") {
                                disconnect(row.id)
                            }
                            .buttonStyle(.bordered)
                        } else if row.showConnect {
                            Button("Connect") {
                                connect(row.id)
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
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 1)
            )
        }
    }
}

private struct SettingsProviderRowData {
    let id: String
    let name: String
    let subtitle: String
    let isConnected: Bool
    let showManage: Bool
    let showAdd: Bool
    let showDisconnect: Bool
    let showConnect: Bool
    let buttonDisabled: Bool
}
