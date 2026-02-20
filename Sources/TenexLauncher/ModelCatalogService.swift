import Foundation

enum ModelCatalogService {
    static func fetchModels(provider: String, providers: [String: ProviderEntry]) async throws -> [String] {
        switch provider {
        case "ollama":
            let baseURL = providers["ollama"]?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedURL = (baseURL?.isEmpty == false) ? baseURL! : "http://localhost:11434"
            return try await fetchOllamaModels(baseURL: resolvedURL)
        case "openrouter":
            guard let rawApiKey = providers["openrouter"]?.apiKey else {
                throw ModelCatalogError.missingCredential("OpenRouter API key is missing.")
            }
            let apiKey = rawApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                throw ModelCatalogError.missingCredential("OpenRouter API key is missing.")
            }
            return try await fetchOpenRouterModels(apiKey: apiKey)
        default:
            return []
        }
    }

    private static func fetchOllamaModels(baseURL: String) async throws -> [String] {
        guard var components = URLComponents(string: baseURL) else {
            throw ModelCatalogError.invalidConfiguration("Invalid Ollama URL.")
        }
        components.path = "/api/tags"
        guard let url = components.url else {
            throw ModelCatalogError.invalidConfiguration("Invalid Ollama URL.")
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed("Could not load Ollama models from \(baseURL).")
        }

        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models.map { $0.name }.filter { !$0.isEmpty }.sorted()
    }

    private static func fetchOpenRouterModels(apiKey: String) async throws -> [String] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            throw ModelCatalogError.invalidConfiguration("Invalid OpenRouter endpoint.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ModelCatalogError.requestFailed("Could not load OpenRouter models with the provided API key.")
        }

        let decoded = try JSONDecoder().decode(OpenRouterModelsResponse.self, from: data)
        return decoded.data.map { $0.id }.filter { !$0.isEmpty }.sorted()
    }
}

enum ModelCatalogError: LocalizedError {
    case missingCredential(String)
    case invalidConfiguration(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let message), .invalidConfiguration(let message), .requestFailed(let message):
            return message
        }
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
}

private struct OpenRouterModelsResponse: Decodable {
    let data: [OpenRouterModel]
}

private struct OpenRouterModel: Decodable {
    let id: String
}
