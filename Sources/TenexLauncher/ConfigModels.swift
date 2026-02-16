import Foundation

// MARK: - config.json

struct TenexConfig: Codable {
    var whitelistedPubkeys: [String]?
    var tenexPrivateKey: String?
    var backendName: String?
    var projectsBase: String?
    var relays: [String]?
    var blossomServerUrl: String?
    var logging: LoggingConfig?
    var telemetry: TelemetryConfig?
    var globalSystemPrompt: GlobalSystemPrompt?
    var summarization: SummarizationConfig?
    var compression: CompressionConfig?
    var claudeCode: ClaudeCodeConfig?
    var escalation: EscalationConfig?
    var localRelay: LocalRelayConfig?
}

struct LocalRelayConfig: Codable {
    var enabled: Bool?
    var autoStart: Bool?
    var privacyMode: Bool?
    var port: Int?
    var syncRelays: [String]?
}

struct LoggingConfig: Codable {
    var logFile: String?
    var level: String?
}

struct TelemetryConfig: Codable {
    var enabled: Bool?
    var serviceName: String?
    var endpoint: String?
}

struct GlobalSystemPrompt: Codable {
    var enabled: Bool?
    var content: String?
}

struct SummarizationConfig: Codable {
    var inactivityTimeout: Int?
}

struct CompressionConfig: Codable {
    var enabled: Bool?
    var tokenThreshold: Int?
    var tokenBudget: Int?
    var slidingWindowSize: Int?
}

struct ClaudeCodeConfig: Codable {
    var enableTenexTools: Bool?
}

struct EscalationConfig: Codable {
    var agent: String?
}

// MARK: - providers.json

struct TenexProviders: Codable {
    var providers: [String: ProviderEntry]

    init(providers: [String: ProviderEntry] = [:]) {
        self.providers = providers
    }
}

struct ProviderEntry: Codable {
    var apiKey: String
    var baseUrl: String?
    var timeout: Int?
    var options: [String: AnyCodable]?
}

// MARK: - llms.json

struct TenexLLMs: Codable {
    var configurations: [String: LLMConfiguration]
    var `default`: String?
    var summarization: String?
    var supervision: String?
    var search: String?
    var promptCompilation: String?
    var compression: String?

    init(
        configurations: [String: LLMConfiguration] = [:],
        default defaultConfig: String? = nil
    ) {
        self.configurations = configurations
        self.`default` = defaultConfig
    }
}

/// A configuration is either a standard model reference or a meta model with variants.
enum LLMConfiguration: Codable {
    case standard(StandardLLM)
    case meta(MetaLLM)

    var provider: String {
        switch self {
        case .standard(let s): s.provider
        case .meta: "meta"
        }
    }

    var displayModel: String {
        switch self {
        case .standard(let s): s.model
        case .meta(let m): "meta (\(m.defaultVariant))"
        }
    }

    var isMetaModel: Bool {
        if case .meta = self { return true }
        return false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Try meta first (it has "variants"), fall back to standard
        if let meta = try? container.decode(MetaLLM.self), meta.provider == "meta" {
            self = .meta(meta)
        } else {
            let standard = try container.decode(StandardLLM.self)
            self = .standard(standard)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .standard(let s): try container.encode(s)
        case .meta(let m): try container.encode(m)
        }
    }
}

struct StandardLLM: Codable {
    var provider: String
    var model: String
    var temperature: Double?
    var maxTokens: Int?
    var topP: Double?
    var reasoningEffort: String?
}

struct MetaLLM: Codable {
    var provider: String // always "meta"
    var variants: [String: MetaVariant]
    var defaultVariant: String

    enum CodingKeys: String, CodingKey {
        case provider, variants
        case defaultVariant = "default"
    }
}

struct MetaVariant: Codable {
    var model: String
    var keywords: [String]?
    var description: String?
    var systemPrompt: String?
    var tier: Int?
}

// MARK: - Utility: AnyCodable for arbitrary JSON values

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let str = value as? String {
            try container.encode(str)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        }
    }
}
