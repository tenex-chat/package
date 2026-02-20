import SwiftUI

/// AppSection enum — originally in tui's MainTabView.swift which is excluded
/// because it uses iOS 18+ Tab() API. Duplicated here for MainShellView.
enum AppSection: String, CaseIterable, Identifiable {
    case chats
    case projects
    case reports
    case inbox
    case search
    case teams
    case agentDefinitions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .projects: return "Projects"
        case .reports: return "Reports"
        case .inbox: return "Inbox"
        case .search: return "Search"
        case .teams: return "Teams"
        case .agentDefinitions: return "Agent Definitions"
        }
    }

    var systemImage: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        case .reports: return "doc.richtext"
        case .inbox: return "tray"
        case .search: return "magnifyingglass"
        case .teams: return "person.2"
        case .agentDefinitions: return "person.3.sequence"
        }
    }

    var accessibilityRowID: String {
        "section_row_\(rawValue)"
    }

    var accessibilityContentID: String {
        "section_content_\(rawValue)"
    }
}

struct MainTabView: View {
    @Binding var userNpub: String
    @Binding var isLoggedIn: Bool
    @EnvironmentObject var coreManager: TenexCoreManager

    @State private var showAISettings = false
    @State private var showDiagnostics = false
    @State private var showStats = false

    var body: some View {
        MainShellView(
            userNpub: $userNpub,
            isLoggedIn: $isLoggedIn,
            runtimeText: coreManager.runtimeText,
            onShowSettings: { showAISettings = true },
            onShowDiagnostics: { showDiagnostics = true },
            onShowStats: { showStats = true }
        )
        .environmentObject(coreManager)
        .nowPlayingInset(coreManager: coreManager)
        .sheet(isPresented: $showAISettings) {
            AppSettingsView(defaultSection: .audio)
                .frame(minWidth: 500, idealWidth: 520, minHeight: 500, idealHeight: 600)
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                DiagnosticsView(coreManager: coreManager)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Done") { showDiagnostics = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showStats) {
            NavigationStack {
                StatsView(coreManager: coreManager)
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Done") { showStats = false }
                        }
                    }
            }
        }
    }
}
