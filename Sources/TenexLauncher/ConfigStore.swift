import Foundation
import os

@MainActor
final class ConfigStore: ObservableObject {
    @Published var config: TenexConfig = TenexConfig()
    @Published var providers: TenexProviders = TenexProviders()
    @Published var llms: TenexLLMs = TenexLLMs()
    @Published var loadError: String?

    private let logger = Logger(subsystem: "chat.tenex.launcher", category: "config")
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }()
    private let decoder = JSONDecoder()

    static var tenexDir: URL {
        if let override = ProcessInfo.processInfo.environment["TENEX_BASE_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".tenex")
    }

    init() {
        loadAll()
    }

    // MARK: - Load

    func loadAll() {
        loadError = nil
        config = load("config.json") ?? TenexConfig()
        providers = load("providers.json") ?? TenexProviders()
        llms = load("llms.json") ?? TenexLLMs()
    }

    private func load<T: Decodable>(_ filename: String) -> T? {
        let url = Self.tenexDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            logger.error("Failed to load \(filename): \(error.localizedDescription)")
            loadError = "Error reading \(filename): \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Save

    func saveConfig() {
        save(config, to: "config.json")
    }

    func saveProviders() {
        save(providers, to: "providers.json")
    }

    func saveLLMs() {
        save(llms, to: "llms.json")
    }

    private func save<T: Encodable>(_ value: T, to filename: String) {
        let dir = Self.tenexDir
        let url = dir.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
            logger.info("Saved \(filename)")
        } catch {
            logger.error("Failed to save \(filename): \(error.localizedDescription)")
            loadError = "Error saving \(filename): \(error.localizedDescription)"
        }
    }

    // MARK: - Convenience

    var configExists: Bool {
        FileManager.default.fileExists(atPath: Self.tenexDir.appendingPathComponent("config.json").path)
    }

    var providersExist: Bool {
        FileManager.default.fileExists(atPath: Self.tenexDir.appendingPathComponent("providers.json").path)
    }

    var llmsExist: Bool {
        FileManager.default.fileExists(atPath: Self.tenexDir.appendingPathComponent("llms.json").path)
    }
}
