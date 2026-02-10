import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case daemon = "Daemon"
    case providers = "Providers"
    case llms = "LLMs"
    case config = "General"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daemon: "bolt.fill"
        case .providers: "key.fill"
        case .llms: "cpu"
        case .config: "gearshape"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var daemon: DaemonManager
    @ObservedObject var configStore: ConfigStore

    @State private var selectedTab: SidebarTab = .daemon

    var body: some View {
        NavigationSplitView {
            List(SidebarTab.allCases, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch selectedTab {
            case .daemon:
                DaemonView(daemon: daemon)
            case .providers:
                ProvidersView(store: configStore)
            case .llms:
                LLMsView(store: configStore)
            case .config:
                GeneralConfigView(store: configStore)
            }
        }
    }
}
