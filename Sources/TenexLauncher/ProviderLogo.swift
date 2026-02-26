import SwiftUI

private let providerLogoSlugs: [String: String] = [
    "openrouter": "openrouter",
    "anthropic": "anthropic",
    "openai": "openai",
    "ollama": "ollama",
    "claude-code": "anthropic",
    "gemini-cli": "google",
    "codex-app-server": "openai",
]

struct ProviderLogo: View {
    let provider: String
    let size: CGFloat

    @State private var image: NSImage?

    init(_ provider: String, size: CGFloat = 20) {
        self.provider = provider
        self.size = size
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .task(id: provider) {
            self.image = await LauncherProviderLogoCache.shared.logo(for: provider)
        }
    }
}

private actor LauncherProviderLogoCache {
    static let shared = LauncherProviderLogoCache()

    private var cache: [String: NSImage] = [:]

    func logo(for provider: String) async -> NSImage? {
        let slug = providerLogoSlugs[provider] ?? provider

        if let cached = cache[slug] {
            return cached
        }

        guard let url = URL(string: "https://models.dev/logos/\(slug).svg") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = NSImage(data: data) else { return nil }
            image.isTemplate = true
            cache[slug] = image
            return image
        } catch {
            return nil
        }
    }
}
