import SwiftUI

/// AppSection enum — originally in tui's MainTabView.swift which is excluded
/// because it uses iOS 18+ Tab() API. Duplicated here for MainShellView.
enum AppSection: String, CaseIterable, Identifiable {
    case chats
    case projects
    case reports
    case inbox
    case search
    case stats
    case diagnostics
    case teams
    case agentDefinitions
    case nudges
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .projects: return "Projects"
        case .reports: return "Reports"
        case .inbox: return "Inbox"
        case .search: return "Search"
        case .stats: return "LLM Runtime"
        case .diagnostics: return "Diagnostics"
        case .teams: return "Teams"
        case .agentDefinitions: return "Agent Definitions"
        case .nudges: return "Nudges"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        case .reports: return "doc.richtext"
        case .inbox: return "tray"
        case .search: return "magnifyingglass"
        case .stats: return "clock"
        case .diagnostics: return "gauge.with.needle"
        case .teams: return "person.2"
        case .agentDefinitions: return "person.3.sequence"
        case .nudges: return "forward.circle"
        case .settings: return "gearshape"
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
    @Environment(TenexCoreManager.self) var coreManager

    var body: some View {
        MainShellView(
            userNpub: $userNpub,
            isLoggedIn: $isLoggedIn,
            runtimeText: coreManager.runtimeText
        )
        .environment(coreManager)
        .nowPlayingInset(coreManager: coreManager)
    }
}
