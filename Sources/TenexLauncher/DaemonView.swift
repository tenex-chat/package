import SwiftUI

struct DaemonView: View {
    @ObservedObject var orchestrator: OrchestratorManager

    var body: some View {
        VStack(spacing: 0) {
            // Header controls
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusLabel)
                    .font(.headline)

                Spacer()

                switch orchestrator.daemonStatus {
                case .stopped, .failed:
                    Button("Start") { orchestrator.startDaemon() }
                        .buttonStyle(.borderedProminent)
                case .starting:
                    ProgressView()
                        .controlSize(.small)
                case .running:
                    Button("Stop") { orchestrator.stopDaemon() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()

            if let error = orchestrator.daemonError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            // Log output
            LogView(logs: orchestrator.daemonLogs)
        }
        .navigationTitle("Daemon")
    }

    private var statusColor: Color {
        switch orchestrator.daemonStatus {
        case .running: .green
        case .starting: .yellow
        case .stopped: .gray
        case .failed: .red
        }
    }

    private var statusLabel: String {
        switch orchestrator.daemonStatus {
        case .stopped: "Stopped"
        case .starting: "Starting..."
        case .running: "Running"
        case .failed: "Failed"
        }
    }
}

struct LogView: View {
    let logs: [String]

    @State private var autoScroll = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            .background(index % 2 == 0 ? Color.clear : Color.primary.opacity(0.03))
                            .id(index)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logs.count) { _, _ in
                if autoScroll, let last = logs.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !logs.isEmpty {
                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .padding(8)
            }
        }
        .overlay {
            if logs.isEmpty {
                ContentUnavailableView(
                    "No Logs",
                    systemImage: "text.justify.left",
                    description: Text("Start the daemon to see output here.")
                )
            }
        }
    }
}
