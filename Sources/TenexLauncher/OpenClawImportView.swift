import SwiftUI

struct OpenClawImportView: View {
    let detected: OpenClawDetected

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("OpenClaw Installation Found")
                            .font(.headline)
                        Text("Import your existing configuration to skip manual setup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !detected.credentials.isEmpty {
                    importCard(
                        icon: "key.fill",
                        title: "Provider Credentials",
                        items: detected.credentials.map { credentialLabel($0) }
                    )
                }

                if let model = detected.primaryModel {
                    importCard(
                        icon: "cpu",
                        title: "Model Configuration",
                        items: [model]
                    )
                }

                importCard(
                    icon: "person.fill",
                    title: "Agent",
                    items: ["Your OpenClaw agent will be imported in the background"]
                )

                Text("You can review and adjust everything on the next screens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private func credentialLabel(_ c: OpenClawCredential) -> String {
        "\(c.provider.prefix(1).uppercased() + c.provider.dropFirst()) API key"
    }

    private func importCard(icon: String, title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))

            ForEach(items, id: \.self) { item in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(item)
                        .font(.body)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.secondary))
    }
}
