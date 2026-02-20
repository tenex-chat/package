import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case daemon = "Daemon"
    case providers = "Providers"
    case llms = "LLMs"
    case identity = "Identity"
    case network = "Network"
    case relay = "Relay"
    case agents = "Agents"
    case conversations = "Conversations"
    case app = "App"
    case prompt = "Prompt"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daemon: "bolt.fill"
        case .providers: "key.fill"
        case .llms: "cpu"
        case .identity: "person.text.rectangle"
        case .network: "network"
        case .relay: "dot.radiowaves.left.and.right"
        case .agents: "person.2.fill"
        case .conversations: "bubble.left.and.bubble.right"
        case .app: "gearshape.2"
        case .prompt: "text.bubble"
        }
    }
}

struct MainWindow: View {
    @ObservedObject var daemon: DaemonManager
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var coreManager: TenexCoreManager
    @ObservedObject var relayManager: RelayManager
    @ObservedObject var negentropySync: NegentropySync
    @ObservedObject var pendingEventsQueue: PendingEventsQueue

    @State private var selectedTab: SidebarTab = .daemon

    var body: some View {
        Group {
            if configStore.needsOnboarding {
                OnboardingView(store: configStore, coreManager: coreManager, relayManager: relayManager)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
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
                    case .identity, .network, .relay, .agents, .conversations, .app, .prompt:
                        GeneralConfigView(
                            store: configStore,
                            relayManager: relayManager,
                            negentropySync: negentropySync,
                            pendingEventsQueue: pendingEventsQueue,
                            tab: selectedTab
                        )
                    }
                }
            }
        }
    }
}
