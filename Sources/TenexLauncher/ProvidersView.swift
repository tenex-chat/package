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

struct ProvidersView: View {
    @ObservedObject var store: ConfigStore

    @State private var providerAvailability: [String: Bool] = [:]
    @State private var showCredentialSheet = false
    @State private var selectedProvider = ""
    @State private var credentialValue = ""
    @State private var credentialError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerCard(
                title: "Providers",
                rows: providerListOrder.map { provider in
                    let connected = isConnected(provider)
                    return SettingsProviderRowData(
                        id: provider,
                        name: settingsProviderDisplayNames[provider] ?? provider,
                        subtitle: subtitle(for: provider),
                        isConnected: connected,
                        buttonLabel: connected ? "Disconnect" : "Connect",
                        buttonDisabled: buttonDisabled(for: provider)
                    )
                },
                onButtonTap: { provider in
                    if isConnected(provider) {
                        disconnect(provider)
                    } else {
                        connect(provider)
                    }
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
    }

    private var providerCredentialSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect \(settingsProviderDisplayNames[selectedProvider] ?? selectedProvider)")
                .font(.headline)

            if selectedProvider == "ollama" {
                TextField("Ollama URL", text: $credentialValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
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
                Button("Connect") {
                    let trimmed = credentialValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        credentialError = selectedProvider == "ollama" ? "URL is required." : "API key is required."
                        return
                    }
                    store.providers.providers[selectedProvider] = ProviderEntry(apiKey: trimmed)
                    store.saveProviders()
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

        store.providers.providers[provider] = ProviderEntry(apiKey: "none")
        store.saveProviders()
    }

    private func disconnect(_ provider: String) {
        store.providers.providers.removeValue(forKey: provider)
        store.saveProviders()
        if provider == "openrouter" {
            removeOpenRouterKeyFromMacApp()
        }
    }

    private func isConnected(_ provider: String) -> Bool {
        store.providers.providers[provider] != nil
    }

    private func buttonDisabled(for provider: String) -> Bool {
        if isConnected(provider) { return false }
        if provider == "openrouter" || provider == "openai" || provider == "anthropic" || provider == "ollama" {
            return false
        }
        return providerAvailability[provider] != true
    }

    private func subtitle(for provider: String) -> String {
        if isConnected(provider) {
            switch provider {
            case "openrouter", "openai", "anthropic":
                return "Connected with API key"
            case "ollama":
                return "Connected local endpoint (\(store.providers.providers[provider]?.apiKey ?? "http://localhost:11434"))"
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

        switch provider {
        case "openrouter":
            return "Use API key to access hosted models"
        case "openai":
            return "Use OpenAI API key"
        case "anthropic":
            return "Use Anthropic API key"
        case "ollama":
            return "Connect to your local Ollama endpoint"
        case "claude-code":
            return "Requires local `claude` command"
        case "codex-app-server":
            return "Requires local `codex` command"
        case "gemini-cli":
            return "Requires local `gemini` command"
        default:
            return "Not configured"
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
                store.providers.providers[provider] = ProviderEntry(apiKey: "none")
            }
        }

        // Auto-connect ollama if available
        if providerAvailability["ollama"] == true && !isConnected("ollama") {
            store.providers.providers["ollama"] = ProviderEntry(apiKey: "http://localhost:11434")
        }

        // Auto-connect API key providers from env vars
        for (provider, envVar) in apiKeyEnvVars {
            if !isConnected(provider), let apiKey = ProcessInfo.processInfo.environment[envVar], !apiKey.isEmpty {
                store.providers.providers[provider] = ProviderEntry(apiKey: apiKey)
                if provider == "openrouter" {
                    syncOpenRouterKeyToMacApp(apiKey)
                }
            }
        }

        store.saveProviders()
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

    private func providerCard(
        title: String,
        rows: [SettingsProviderRowData],
        onButtonTap: ((String) -> Void)? = nil
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
    let buttonLabel: String?
    let buttonDisabled: Bool
}
