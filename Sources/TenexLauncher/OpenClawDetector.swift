import Foundation

struct OpenClawCredential {
    let provider: String   // e.g. "anthropic"
    let apiKey: String     // e.g. "sk-ant-oat01-..."
}

struct OpenClawDetected {
    let stateDir: URL
    let credentials: [OpenClawCredential]
    let primaryModel: String?  // TENEX format, e.g. "anthropic:claude-sonnet-4-6"
}

struct OpenClawDetector {

    static func detect() -> OpenClawDetected? {
        guard let stateDir = findStateDir() else { return nil }
        return OpenClawDetected(
            stateDir: stateDir,
            credentials: readCredentials(stateDir: stateDir),
            primaryModel: readPrimaryModel(stateDir: stateDir)
        )
    }

    // MARK: - Private

    private static let configNames = ["openclaw.json", "clawdbot.json", "moldbot.json", "moltbot.json"]

    private static func findStateDir() -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["OPENCLAW_STATE_DIR"] {
            let url = URL(fileURLWithPath: envPath)
            if hasConfig(url) { return url }
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        for name in [".openclaw", ".clawdbot", ".moldbot", ".moltbot"] {
            let candidate = home.appendingPathComponent(name)
            if hasConfig(candidate) { return candidate }
        }

        return nil
    }

    private static func hasConfig(_ dir: URL) -> Bool {
        configNames.contains {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    private static func readCredentials(stateDir: URL) -> [OpenClawCredential] {
        let url = stateDir.appendingPathComponent("agents/main/agent/auth-profiles.json")
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(AuthProfilesFile.self, from: data)
        else { return [] }

        var credentials: [OpenClawCredential] = []
        let sortedProfiles = file.profiles.sorted { lhs, rhs in
            let lhsDefault = lhs.key.hasSuffix(":default")
            let rhsDefault = rhs.key.hasSuffix(":default")
            if lhsDefault != rhsDefault { return lhsDefault }
            return lhs.key < rhs.key
        }
        for (_, profile) in sortedProfiles {
            let key: String?
            switch profile.type {
            case "token":   key = profile.token
            case "api_key": key = profile.key
            case "oauth":   key = profile.access
            default:        key = nil
            }
            guard let provider = profile.provider,
                  let apiKey = key, !apiKey.isEmpty else { continue }
            guard !credentials.contains(where: { $0.provider == provider }) else { continue }
            credentials.append(OpenClawCredential(provider: provider, apiKey: apiKey))
        }
        return credentials
    }

    private static func readPrimaryModel(stateDir: URL) -> String? {
        for name in configNames {
            let url = stateDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let config = try? JSONDecoder().decode(OpenClawConfig.self, from: data),
                  let raw = config.agents?.defaults?.model?.primary
            else { continue }
            return convertModelFormat(raw)
        }
        return nil
    }

    private static func convertModelFormat(_ model: String) -> String {
        guard let idx = model.firstIndex(of: "/") else { return model }
        var result = model
        result.replaceSubrange(idx...idx, with: ":")
        return result
    }
}

// MARK: - Decodable helpers (file-private)

private struct AuthProfilesFile: Decodable {
    let profiles: [String: AuthProfile]
}

private struct AuthProfile: Decodable {
    let type: String
    let provider: String?
    var token: String?
    var key: String?
    var access: String?
}

private struct OpenClawConfig: Decodable {
    let agents: AgentsSection?
    struct AgentsSection: Decodable {
        let defaults: DefaultsSection?
        struct DefaultsSection: Decodable {
            let model: ModelSection?
            struct ModelSection: Decodable {
                let primary: String?
            }
        }
    }
}
