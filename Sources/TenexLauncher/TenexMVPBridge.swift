/// Bridge file: contains types from TenexMVP's App.swift that the rest of the views depend on.
/// The original App.swift is excluded from this target to avoid duplicate @main.
/// This file is a verbatim copy of the non-@main portions.

import SwiftUI
import CryptoKit

// MARK: - Auto-Login Result

enum AutoLoginResult {
    case noCredentials
    case success(npub: String)
    case invalidCredential(error: String)
    case transientError(error: String)
}

// MARK: - Streaming Buffer

struct StreamingBuffer {
    let agentPubkey: String
    var text: String
}

// MARK: - Profile Picture Cache

final class ProfilePictureCache {
    static let shared = ProfilePictureCache()

    private var cache: [String: String?] = [:]
    private let lock = NSLock()

    private init() {}

    func getCached(_ pubkey: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        if cache.keys.contains(pubkey) {
            return cache[pubkey]
        }
        return nil
    }

    func store(_ pubkey: String, pictureUrl: String?) {
        lock.lock()
        defer { lock.unlock() }
        cache[pubkey] = pictureUrl
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }
}

// MARK: - TenexCoreManager

@MainActor
class TenexCoreManager: ObservableObject {
    let core: TenexCore
    let safeCore: SafeTenexCore
    @Published var isInitialized = false
    @Published var initializationError: String?

    @Published var projects: [ProjectInfo] = []
    @Published var conversations: [ConversationFullInfo] = []
    @Published var inboxItems: [InboxItem] = []
    @Published var messagesByConversation: [String: [MessageInfo]] = [:]
    @Published private(set) var statsVersion: UInt64 = 0
    @Published private(set) var diagnosticsVersion: UInt64 = 0
    @Published private(set) var liveFeed: [LiveFeedItem] = []
    @Published private(set) var liveFeedLastReceivedAt: Date?

    private let liveFeedMaxItems = 400

    @Published var projectOnlineStatus: [String: Bool] = [:]
    @Published var onlineAgents: [String: [OnlineAgentInfo]] = [:]
    @Published var hasActiveAgents: Bool = false
    @Published var streamingBuffers: [String: StreamingBuffer] = [:]

    private var eventHandler: TenexEventHandler?
    private var projectStatusUpdateTask: Task<Void, Never>?
    let profilePictureCache = ProfilePictureCache.shared
    let hierarchyCache = ConversationHierarchyCache()

    init() {
        let tenexCore = TenexCore()
        core = tenexCore
        safeCore = SafeTenexCore(core: tenexCore)
        hierarchyCache.setCoreManager(self)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = tenexCore.`init`()
            DispatchQueue.main.async {
                self?.isInitialized = success
                if !success {
                    self?.initializationError = "Failed to initialize TENEX core"
                }
            }
        }
    }

    func syncNow() async {
        _ = await safeCore.refresh()
    }

    func registerEventCallback() {
        let handler = TenexEventHandler(coreManager: self)
        eventHandler = handler
        core.setEventCallback(callback: handler)
    }

    func unregisterEventCallback() {
        core.clearEventCallback()
        eventHandler = nil
    }

    func manualRefresh() async {
        await syncNow()
    }

    @MainActor
    func applyMessageAppended(conversationId: String, message: MessageInfo) {
        var messages = messagesByConversation[conversationId, default: []]
        if !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
            messages.sort { $0.createdAt < $1.createdAt }
            setMessagesCache(messages, for: conversationId)
        }
        recordLiveFeedItem(conversationId: conversationId, message: message)
    }

    @MainActor
    func applyConversationUpsert(_ conversation: ConversationFullInfo) {
        var updated = conversations
        if let index = updated.firstIndex(where: { $0.id == conversation.id }) {
            updated[index] = conversation
        } else {
            updated.append(conversation)
        }
        conversations = sortedConversations(updated)
        updateActiveAgentsState()
    }

    @MainActor
    func applyProjectUpsert(_ project: ProjectInfo) {
        var updated = projects
        if let index = updated.firstIndex(where: { $0.id == project.id }) {
            updated[index] = project
        } else {
            updated.insert(project, at: 0)
        }
        projects = updated
    }

    @MainActor
    func applyInboxUpsert(_ item: InboxItem) {
        var updated = inboxItems
        if let index = updated.firstIndex(where: { $0.id == item.id }) {
            updated[index] = item
        } else {
            updated.append(item)
        }
        updated.sort { $0.createdAt > $1.createdAt }
        inboxItems = updated
    }

    @MainActor
    func applyProjectStatusChanged(projectId: String, projectATag _: String, isOnline: Bool, onlineAgents: [OnlineAgentInfo]) {
        let previousStatus = projectOnlineStatus[projectId]
        let previousAgents = self.onlineAgents[projectId]
        setProjectOnlineStatus(isOnline, for: projectId)
        setOnlineAgentsCache(onlineAgents, for: projectId)
        if previousStatus != isOnline || previousAgents != onlineAgents {
            signalDiagnosticsUpdate()
        }
    }

    @MainActor
    func applyActiveConversationsChanged(projectId _: String, projectATag: String, activeConversationIds: [String]) {
        var updated = conversations
        var didChange = false
        for index in updated.indices {
            if updated[index].projectATag == projectATag {
                let shouldBeActive = activeConversationIds.contains(updated[index].id)
                if updated[index].isActive != shouldBeActive {
                    updated[index].isActive = shouldBeActive
                    didChange = true
                }
            }
        }
        if didChange {
            conversations = sortedConversations(updated)
            updateActiveAgentsState()
        }
    }

    @MainActor
    func handlePendingBackendApproval(backendPubkey: String, projectATag: String) {
        Task {
            do {
                try await safeCore.approveBackend(pubkey: backendPubkey)
            } catch {
                return
            }
            let projectId = Self.projectId(fromATag: projectATag)
            guard !projectId.isEmpty else { return }
            let isOnline = await safeCore.isProjectOnline(projectId: projectId)
            let agents = (try? await safeCore.getOnlineAgents(projectId: projectId)) ?? []
            await MainActor.run {
                self.applyProjectStatusChanged(projectId: projectId, projectATag: projectATag, isOnline: isOnline, onlineAgents: agents)
            }
        }
    }

    @MainActor func signalStatsUpdate() { bumpStatsVersion() }
    @MainActor func signalDiagnosticsUpdate() { bumpDiagnosticsVersion() }

    @MainActor
    func signalConversationUpdate(conversationId: String) {
        Task {
            let messages = await safeCore.getMessages(conversationId: conversationId)
            await MainActor.run { self.setMessagesCache(messages, for: conversationId) }
            let filter = ConversationFilter(projectIds: [], showArchived: false, hideScheduled: false, timeFilter: .all)
            if let conversations = try? await safeCore.getAllConversations(filter: filter) {
                await MainActor.run {
                    self.conversations = self.sortedConversations(conversations)
                    self.updateActiveAgentsState()
                }
            }
        }
    }

    @MainActor
    func signalProjectStatusUpdate() {
        projectStatusUpdateTask?.cancel()
        projectStatusUpdateTask = Task { [weak self] in
            guard let self else { return }
            let projects: [ProjectInfo]
            do { projects = try await safeCore.getProjects() } catch { return }
            if Task.isCancelled { return }
            await MainActor.run { self.projects = projects }
            await self.refreshProjectStatusParallel(for: projects)
            if !Task.isCancelled {
                await MainActor.run { self.signalDiagnosticsUpdate() }
            }
        }
    }

    private func refreshProjectStatusParallel(for projects: [ProjectInfo]) async {
        await withTaskGroup(of: (String, Bool, [OnlineAgentInfo]).self) { group in
            for project in projects {
                group.addTask {
                    if Task.isCancelled { return (project.id, false, []) }
                    let isOnline = await self.safeCore.isProjectOnline(projectId: project.id)
                    let agents: [OnlineAgentInfo] = isOnline ? ((try? await self.safeCore.getOnlineAgents(projectId: project.id)) ?? []) : []
                    return (project.id, isOnline, agents)
                }
            }
            for await (projectId, isOnline, agents) in group {
                if Task.isCancelled { continue }
                await MainActor.run {
                    self.setProjectOnlineStatus(isOnline, for: projectId)
                    self.setOnlineAgentsCache(agents, for: projectId)
                }
            }
        }
    }

    @MainActor func signalGeneralUpdate() { bumpDiagnosticsVersion() }

    @MainActor
    func recordLiveFeedItem(conversationId: String, message: MessageInfo) {
        if liveFeed.contains(where: { $0.id == message.id }) { return }
        liveFeed.insert(LiveFeedItem(conversationId: conversationId, message: message), at: 0)
        if liveFeed.count > liveFeedMaxItems {
            liveFeed.removeLast(liveFeed.count - liveFeedMaxItems)
        }
        liveFeedLastReceivedAt = liveFeed.first?.receivedAt
    }

    @MainActor
    func clearLiveFeed() {
        liveFeed.removeAll()
        liveFeedLastReceivedAt = nil
    }

    @MainActor
    private func updateActiveAgentsState() {
        hasActiveAgents = conversations.contains { $0.isActive }
    }

    private func sortedConversations(_ items: [ConversationFullInfo]) -> [ConversationFullInfo] {
        items.sorted { lhs, rhs in
            switch (lhs.isActive, rhs.isActive) {
            case (true, false): true
            case (false, true): false
            default: lhs.effectiveLastActivity > rhs.effectiveLastActivity
            }
        }
    }

    func fetchAndCacheAgents(for projectId: String) async {
        let agents: [OnlineAgentInfo]
        do { agents = try await safeCore.getOnlineAgents(projectId: projectId) }
        catch {
            await MainActor.run { self.setOnlineAgentsCache([], for: projectId) }
            return
        }
        await MainActor.run { self.setOnlineAgentsCache(agents, for: projectId) }
    }

    @MainActor
    func ensureMessagesLoaded(conversationId: String) async {
        if messagesByConversation[conversationId] != nil { return }
        let fetched = await safeCore.getMessages(conversationId: conversationId)
        mergeMessagesCache(fetched, for: conversationId)
    }

    @MainActor private func setMessagesCache(_ messages: [MessageInfo], for conversationId: String) {
        var updated = messagesByConversation
        updated[conversationId] = messages
        messagesByConversation = updated
    }

    @MainActor private func mergeMessagesCache(_ messages: [MessageInfo], for conversationId: String) {
        var combined = messagesByConversation[conversationId] ?? []
        if combined.isEmpty {
            combined = messages
        } else {
            let existingIds = Set(combined.map { $0.id })
            combined.append(contentsOf: messages.filter { !existingIds.contains($0.id) })
        }
        combined.sort { $0.createdAt < $1.createdAt }
        setMessagesCache(combined, for: conversationId)
    }

    @MainActor private func setOnlineAgentsCache(_ agents: [OnlineAgentInfo], for projectId: String) {
        var updated = onlineAgents
        updated[projectId] = agents
        onlineAgents = updated
    }

    @MainActor private func setProjectOnlineStatus(_ isOnline: Bool, for projectId: String) {
        var updated = projectOnlineStatus
        updated[projectId] = isOnline
        projectOnlineStatus = updated
    }

    @MainActor private func bumpStatsVersion() { statsVersion &+= 1 }
    @MainActor private func bumpDiagnosticsVersion() { diagnosticsVersion &+= 1 }

    static func projectId(fromATag aTag: String) -> String {
        let parts = aTag.split(separator: ":")
        guard parts.count >= 3 else { return "" }
        return parts.dropFirst(2).joined(separator: ":")
    }

    @MainActor
    func fetchData() async {
        do {
            let approved = try await safeCore.approveAllPendingBackends()
            if approved > 0 { print("[TenexCoreManager] Auto-approved \(approved) backend(s)") }
        } catch {}

        do {
            let filter = ConversationFilter(projectIds: [], showArchived: true, hideScheduled: true, timeFilter: .all)
            async let fetchedProjects = safeCore.getProjects()
            async let fetchedConversations = try safeCore.getAllConversations(filter: filter)
            async let fetchedInbox = safeCore.getInbox()

            let (p, c, i) = try await (fetchedProjects, fetchedConversations, fetchedInbox)
            projects = p
            conversations = sortedConversations(c)
            inboxItems = i
            await refreshProjectStatusParallel(for: p)
            updateActiveAgentsState()
            signalStatsUpdate()
            signalDiagnosticsUpdate()
        } catch {
            print("[TenexCoreManager] Fetch failed: \(error)")
        }
    }

    func getProfilePicture(pubkey: String) -> String? {
        if let cached = profilePictureCache.getCached(pubkey) { return cached }
        do {
            let pictureUrl = try core.getProfilePicture(pubkey: pubkey)
            profilePictureCache.store(pubkey, pictureUrl: pictureUrl)
            return pictureUrl
        } catch {
            profilePictureCache.store(pubkey, pictureUrl: nil)
            return nil
        }
    }

    func prefetchProfilePictures(_ pubkeys: [String]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for pubkey in pubkeys {
                if self?.profilePictureCache.getCached(pubkey) == nil {
                    do {
                        let pictureUrl = try self?.core.getProfilePicture(pubkey: pubkey)
                        self?.profilePictureCache.store(pubkey, pictureUrl: pictureUrl)
                    } catch {
                        self?.profilePictureCache.store(pubkey, pictureUrl: nil)
                    }
                }
            }
        }
    }

    func attemptAutoLogin() -> AutoLoginResult {
        let loadResult = KeychainService.shared.loadNsec()
        switch loadResult {
        case .failure(.itemNotFound): return .noCredentials
        case .failure(let error): return .transientError(error: error.localizedDescription)
        case .success(let nsec):
            do {
                let loginResult = try core.login(nsec: nsec)
                if loginResult.success { return .success(npub: loginResult.npub) }
                else { return .transientError(error: "Login failed - please try again") }
            } catch let error as TenexError {
                switch error {
                case .InvalidNsec(let message): return .invalidCredential(error: message)
                case .NotLoggedIn, .Internal, .LogoutFailed, .LockError, .CoreNotInitialized:
                    return .transientError(error: error.localizedDescription)
                }
            } catch {
                return .transientError(error: error.localizedDescription)
            }
        }
    }

    func saveCredential(nsec: String) async -> String? {
        let result = await KeychainService.shared.saveNsecAsync(nsec)
        switch result { case .success: return nil; case .failure(let error): return error.localizedDescription }
    }

    func clearCredentials() async -> String? {
        profilePictureCache.clear()
        let result = await KeychainService.shared.deleteNsecAsync()
        switch result { case .success: return nil; case .failure(let error): return error.localizedDescription }
    }

    @MainActor
    func applyStreamChunk(agentPubkey: String, conversationId: String, textDelta: String?) {
        guard let delta = textDelta, !delta.isEmpty else { return }
        var buffer = streamingBuffers[conversationId] ?? StreamingBuffer(agentPubkey: agentPubkey, text: "")
        buffer.text.append(delta)
        streamingBuffers[conversationId] = buffer
    }
}

// MARK: - Main Tab View (macOS adapted — uses sidebar instead of bottom bar)

struct MainTabView: View {
    @Binding var userNpub: String
    @Binding var isLoggedIn: Bool
    @EnvironmentObject var coreManager: TenexCoreManager

    @State private var selectedTab = 0
    @State private var showNewConversation = false
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                    .tag(0)
                Label("Feed", systemImage: "dot.radiowaves.left.and.right")
                    .tag(1)
                Label("Projects", systemImage: "folder")
                    .tag(2)
                Label("Inbox", systemImage: "tray")
                    .tag(3)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            Group {
                switch selectedTab {
                case 0: ConversationsTabView()
                case 1: FeedView()
                case 2: ContentView(userNpub: $userNpub, isLoggedIn: $isLoggedIn)
                case 3: InboxView()
                default: ConversationsTabView()
                }
            }
            .environmentObject(coreManager)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showSearch = true } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { showNewConversation = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showSearch) {
            NavigationStack {
                SearchView()
                    .environmentObject(coreManager)
            }
        }
        .sheet(isPresented: $showNewConversation) {
            NavigationStack {
                MessageComposerView(project: nil, conversationId: nil, conversationTitle: nil)
                    .environmentObject(coreManager)
            }
        }
    }
}
