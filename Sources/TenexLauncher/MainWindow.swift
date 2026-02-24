import SwiftUI

enum SidebarSection: String, CaseIterable {
    case top = ""
    case ai = "AI"
    case networking = "Networking"
    case advanced = "Advanced"

    var tabs: [SidebarTab] {
        switch self {
        case .top: [.daemon, .identity, .mobile]
        case .ai: [.providers, .llms, .roles, .embeddings, .imageGeneration, .agents, .conversations]
        case .networking: [.network, .relay]
        case .advanced: [.prompt, .app]
        }
    }
}

enum SidebarTab: String, Identifiable {
    case daemon = "Daemon"
    case providers = "Providers"
    case llms = "LLMs"
    case roles = "Roles"
    case identity = "Identity"
    case network = "Network"
    case relay = "Relay"
    case embeddings = "Embeddings"
    case imageGeneration = "Image Generation"
    case agents = "Agents"
    case conversations = "Conversations"
    case app = "App"
    case prompt = "Prompt"
    case mobile = "Mobile"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .daemon: "bolt.fill"
        case .providers: "key.fill"
        case .llms: "cpu"
        case .roles: "person.badge.key"
        case .identity: "person.text.rectangle"
        case .network: "network"
        case .relay: "dot.radiowaves.left.and.right"
        case .embeddings: "square.stack.3d.up"
        case .imageGeneration: "photo"
        case .agents: "person.2.fill"
        case .conversations: "bubble.left.and.bubble.right"
        case .app: "gearshape.2"
        case .prompt: "text.bubble"
        case .mobile: "iphone"
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
                    List(selection: $selectedTab) {
                        ForEach(SidebarSection.allCases, id: \.self) { section in
                            if section == .top {
                                ForEach(section.tabs) { tab in
                                    Label(tab.rawValue, systemImage: tab.icon)
                                        .tag(tab)
                                }
                            } else {
                                Section(section.rawValue) {
                                    ForEach(section.tabs) { tab in
                                        Label(tab.rawValue, systemImage: tab.icon)
                                            .tag(tab)
                                    }
                                }
                            }
                        }
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
                    case .mobile:
                        MobileSetupView(store: configStore)
                    case .identity, .network, .relay, .embeddings, .imageGeneration, .agents, .conversations, .app, .prompt, .roles:
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
