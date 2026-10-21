import Foundation
import Observation
import SwiftUI

/// What a host session gives the conversation list (HostSession: link, client, topology). The integration step builds
/// it from `HostSessions`; Chat never sees the transport.
struct ChatHostSnapshot: Identifiable {
    let id: UUID
    var name: String
    var link: HostLink
    /// Why the host is not connected yet (`HostSession.problem`).
    var problem: String? = nil
    var client: HelperClient?
    var topology: HelperTopology?
    /// The helper features this connection's hello accepted (`HelperSession.Info.features`), e.g. "chat.list".
    var features: Set<String> = []
    /// The topology is the connected helper's (`HostSession.topologyIsLive`); false: last-known rows, shown stale.
    var live = true
}

/// What the list shows for one conversation before (or without) opening it: from one `chat.list` reply when the hello
/// accepted that feature, else from `chat.state` and the newest page.
struct ChatConversationSummary: Equatable, Sendable {
    var busy = false
    var subagents = 0
    var attention: String?
    /// The newest agent message (the two-line preview).
    var preview: String?
    /// The newest turn has ended (a result exists).
    var finished = false
    /// When the newest record was written: what "seen" marks (ChatMarkers).
    var lastActivity: Date?
    /// An approval or blocking question is open (`chat.list` `waiting`): the agent waits for the user, as a pending
    /// approval card does on the Mac.
    var waiting = false
    /// The conversation's title (`State.title`), which names an unrenamed tab as on the Mac.
    var title: String?

    /// Needs the user: an open approval or question, or the agent's own attention (a prompt only Terminal can answer).
    var needsYou: Bool { waiting || attention != nil }
}

/// Summaries for the agent-bound terminals of one host.
protocol ChatConversationSource: Sendable {
    func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary]
}

/// The fallback source: per conversation one `chat.state` and one `chat.page` (the newest page), N round trips per
/// host, for helpers without the `chat.list` feature.
struct ChatStateProbe: ChatConversationSource {
    func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary] {
        await withTaskGroup(of: (UInt64, ChatConversationSummary?).self) { group in
            for terminal in terminals {
                group.addTask { (terminal, await Self.summary(terminal, client: client)) }
            }
            var result: [UInt64: ChatConversationSummary] = [:]
            for await (terminal, summary) in group { if let summary { result[terminal] = summary } }
            return result
        }
    }

    private struct Observed: Decodable, Sendable {
        let binding: HelperTopology.Binding
        let state: HelperChat.State
    }

    static func summary(_ terminal: UInt64, client: HelperClient) async -> ChatConversationSummary? {
        let input = HelperChat.Input(HelperChat.Route(terminal: terminal, session: nil))
        guard let observed: Observed = try? await client.connection.request("chat.state", params: input) else { return nil }
        var summary = ChatConversationSummary(busy: observed.state.busy, subagents: observed.state.agents?.count ?? 0,
                                              attention: observed.state.attention)
        summary.title = observed.state.title
        if let page: HelperChat.Page = try? await client.connection.request("chat.page", params: input) {
            summary.apply(page.records)
        }
        return summary
    }
}

extension ChatConversationSummary {
    /// The preview, its record and the activity time from records in transcript order.
    mutating func apply(_ records: [HelperChat.Record]) {
        if let last = records.last(where: { $0.kind == "assistant" && !$0.text.isEmpty }) {
            preview = Self.preview(last.text)
        }
        let turns = records.compactMap(\.turn)
        if let turn = turns.last { finished = records.contains { $0.kind == "turn_ended" && $0.turn == turn } }
        if let time = records.compactMap(\.time_ms).max() { lastActivity = Date(timeIntervalSince1970: Double(time) / 1000) }
    }

    /// Markdown-free enough for two lines: whitespace collapsed, code fences dropped.
    /// One line of what the agent said: its Markdown read as text (`ChatMarkdownBlock.plainText`), whitespace collapsed.
    static func preview(_ text: String) -> String {
        ChatMarkdownBlock.plainText(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One `chat.list` reply for the whole host (the `chat.list` feature, helper/PROTOCOL.md Features): 2 to 4 ms.
struct ChatListOperation: ChatConversationSource {
    struct Row: Decodable, Sendable {
        let terminal: UInt64
        let busy: Bool?
        let attention: String?
        /// The newest assistant text, lines kept (at most 280 characters).
        let preview: String?
        let time_ms: Int64?
        /// Absent from helpers before it: nothing known to be open.
        let waiting: Bool?
        let title: String?

        var summary: ChatConversationSummary {
            let busy = busy ?? false
            // No turn records here: an agent that is not busy has finished its last turn.
            return ChatConversationSummary(
                busy: busy, attention: attention, preview: preview.map(ChatConversationSummary.preview),
                finished: !busy && preview != nil,
                lastActivity: time_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }, waiting: waiting ?? false,
                title: title)
        }
    }

    static func rows(_ client: HelperClient) async -> [Row]? {
        try? await client.connection.request("chat.list", params: [String: String]())
    }

    func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary] {
        guard let rows = await Self.rows(client) else { return [:] }
        var result: [UInt64: ChatConversationSummary] = [:]
        for row in rows where terminals.contains(row.terminal) { result[row.terminal] = row.summary }
        return result
    }
}

/// What the phone keeps per conversation: the last agent record seen (unread, M3a's blue dot) and mutes. Saved as one
/// private file; unread is per device in v1 and this store is where a push relay would read it.
@MainActor protocol ChatMarkerPersistence {
    func load() throws -> ChatMarkers.Document
    func save(_ document: ChatMarkers.Document) throws
}

@MainActor final class ChatMarkerFileStore: ChatMarkerPersistence {
    let url: URL
    init(url: URL = Home.support.appendingPathComponent("chat-markers.json")) { self.url = url }
    func load() throws -> ChatMarkers.Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(ChatMarkers.Document.self, from: Data(contentsOf: url))
    }
    func save(_ document: ChatMarkers.Document) throws {
        try PrivateFile.write(JSONEncoder().encode(document), to: url, excludedFromBackup: true)
    }
}

@MainActor final class ChatMarkerMemoryStore: ChatMarkerPersistence {
    var document = ChatMarkers.Document()
    func load() throws -> ChatMarkers.Document { document }
    func save(_ document: ChatMarkers.Document) throws { self.document = document }
}

@MainActor @Observable final class ChatMarkers {
    struct Document: Codable, Equatable {
        var version = 2
        /// "host:conversation" -> the time (ms) of the newest record this phone has shown.
        var seen: [String: Int64] = [:]
        /// "host:node key": conversations muted on this phone.
        var muted: Set<String> = []

        init() {}

        /// A missing or unreadable key takes its default; the rest of the file stays.
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = values.lenient(Int.self, forKey: .version, default: 2)
            seen = values.lenientDictionary(Int64.self, forKey: .seen)
            muted = Set(values.lenientArray(String.self, forKey: .muted))
        }
    }
    static let shared = ChatMarkers(store: ChatMarkerFileStore())
    private(set) var document = Document()
    @ObservationIgnored private let store: any ChatMarkerPersistence

    init(store: any ChatMarkerPersistence) {
        self.store = store
        // A marker file of another version starts afresh (every conversation's present is the new baseline).
        document = (try? store.load()).flatMap { $0.version == 2 ? $0 : nil } ?? Document()
    }

    static func seenKey(host: UUID, conversation: String) -> String { host.uuidString + ":" + conversation }
    static func muteKey(host: UUID, node: String) -> String { host.uuidString + ":" + node }

    func seen(host: UUID, conversation: String) -> Int64? { document.seen[Self.seenKey(host: host, conversation: conversation)] }

    /// Everything written up to `time` (ms) has been shown; a marker never moves back.
    func markSeen(host: UUID, conversation: String, through time: Int64) {
        let key = Self.seenKey(host: host, conversation: conversation)
        guard (document.seen[key] ?? .min) < time else { return }
        document.seen[key] = time
        try? store.save(document)
    }

    func muted(host: UUID, node: String) -> Bool { document.muted.contains(Self.muteKey(host: host, node: node)) }

    /// Forgets every seen marker and mute (Settings' Remove all data).
    func removeAll() {
        document = Document()
        try? store.save(document)
    }

    func setMuted(_ muted: Bool, host: UUID, node: String) {
        let key = Self.muteKey(host: host, node: node)
        if muted { document.muted.insert(key) } else { document.muted.remove(key) }
        try? store.save(document)
    }
}

/// One row of Agents (M3a).
struct ChatConversation: Identifiable, Equatable {
    let key: ChatConversationKey
    var id: ChatConversationKey { key }
    /// The terminal's node id in the current helper's topology.
    var terminal: UInt64
    var hostName: String
    /// The tab's name (the terminal's parent), else the terminal's.
    var name: String
    var space: String?
    /// The space's node id (New chat opens tabs there).
    var spaceNode: UInt64?
    var cwd: String?
    var binding: HelperTopology.Binding
    var summary: ChatConversationSummary
    var urgency: PaneUrgency
    var muted: Bool
    /// An agent result this phone has not shown yet.
    var unread: Bool
    /// Last-known (cached, or the host is not connected): the row dims its time until the live data arrives.
    var stale = false

    /// The gutter dot: blue for an agent that needs you or a result not yet seen, amber working, none idle or read
    /// (PaneUrgency waiting and unread are both unread, running is working). A muted conversation keeps only the dot
    /// of an agent blocked on the user.
    var dot: MobileRowDot? {
        switch urgency {
        case .waiting: .unread
        case .running: muted ? nil : .working
        case .unread: muted ? nil : .unread
        case .idle: nil
        }
    }
}

/// Agent conversations across hosts: one per terminal whose topology node carries an agent binding, with its
/// `PaneUrgency` (Dispatch/Attention.swift) from the agent's state, open requests and the phone's seen markers. Owns
/// the open `MobileChatSession`s so a thread keeps its state while the user moves between tabs.
@MainActor @Observable final class ChatConversations {
    private(set) var hosts: [UUID: ChatHostSnapshot] = [:]
    private(set) var conversations: [ChatConversation] = []
    @ObservationIgnored private var summaries: [ChatConversationKey: ChatConversationSummary] = [:]
    @ObservationIgnored private(set) var sessions: [ChatConversationKey: MobileChatSession] = [:]
    @ObservationIgnored private var probing: Set<UUID> = []
    /// Rows whose summary came from the device's cache and has not been fetched live yet.
    @ObservationIgnored private var cached: Set<ChatConversationKey> = []
    /// Called after the rows changed (the composition keeps the live ones in the cache).
    @ObservationIgnored var rowsChanged: (() -> Void)?
    @ObservationIgnored let presence: (any ChatTerminalPresence)?
    let markers: ChatMarkers
    let outbox: ChatOutbox
    let drafts: ChatDraftRepository
    @ObservationIgnored let source: any ChatConversationSource
    @ObservationIgnored let list: any ChatConversationSource
    /// M3a's pill: only rows with a dot.
    var unreadOnly = false

    /// `source` serves helpers without the `chat.list` feature, `list` those with it.
    init(source: any ChatConversationSource = ChatStateProbe(), list: any ChatConversationSource = ChatListOperation(),
         presence: (any ChatTerminalPresence)? = nil, markers: ChatMarkers = .shared, outbox: ChatOutbox = .shared,
         drafts: ChatDraftRepository = .shared) {
        self.source = source
        self.list = list
        self.presence = presence
        self.markers = markers
        self.outbox = outbox
        self.drafts = drafts
    }

    var visible: [ChatConversation] { unreadOnly ? conversations.filter { $0.dot != nil } : conversations }

    /// The back pill's count (M4a): conversations waiting for the user, across hosts, muted ones included.
    var needsYouCount: Int { conversations.filter { $0.urgency == .waiting }.count }

    /// The dot for a tab's terminal (Tabs) and the most urgent dot on a host (Hosts).
    func dot(host: UUID, terminal: UInt64) -> MobileRowDot? {
        conversations.first { $0.key.host == host && $0.terminal == terminal }?.dot
    }

    func dot(_ key: ChatConversationKey) -> MobileRowDot? { conversations.first { $0.key == key }?.dot }

    /// The conversation key of a terminal in a host's current topology.
    func key(host: UUID, terminal: UInt64) -> ChatConversationKey? {
        hosts[host]?.topology?.nodes.first { $0.id == terminal }.map { ChatConversationKey(host: host, node: $0.key) }
    }

    func dot(host: UUID) -> MobileRowDot? {
        let dots = conversations.filter { $0.key.host == host }.compactMap(\.dot)
        // The most urgent first: needs you, then working, then an unseen result (PaneUrgency's order).
        let rows = conversations.filter { $0.key.host == host && $0.dot != nil }
        if rows.contains(where: { $0.urgency == .waiting }) { return .unread }
        return dots.contains(.working) ? .working : dots.isEmpty ? nil : .unread
    }

    /// A host's link, client or topology changed.
    func update(_ host: ChatHostSnapshot) {
        let previous = hosts[host.id]
        hosts[host.id] = host
        for (key, session) in sessions where key.host == host.id {
            session.hostName = host.name
            // Node ids change with every helper: the conversation follows its terminal's key.
            if let topology = host.topology {
                let node = topology.nodes.first { $0.key == key.node && $0.kind == .terminal && !$0.detached }
                session.update(terminal: node?.id, binding: node?.agent)
            }
            // Without a topology (offline) the last binding stands: the thread stays readable.
            session.update(link: host.link, client: host.client, problem: host.problem)
        }
        rebuild()
        let bindings = { (topology: HelperTopology?) -> [String] in
            topology?.nodes.compactMap { node in node.agent.map { node.key + ":" + $0.session } } ?? []
        }
        if host.client != nil, previous?.client !== host.client || bindings(previous?.topology) != bindings(host.topology) {
            Task { await refresh(host: host.id) }
        }
    }

    func remove(host: UUID) {
        hosts[host] = nil
        cached = cached.filter { $0.host != host }
        rebuild()
    }

    /// The host's rows as the device last saw them (`HostCache`, at launch), by topology key; live summaries replace
    /// them as they are fetched.
    func restore(host: UUID, summaries restored: [String: ChatConversationSummary]) {
        for (node, summary) in restored {
            let key = ChatConversationKey(host: host, node: node)
            guard summaries[key] == nil else { continue }
            summaries[key] = summary
            cached.insert(key)
        }
        rebuild()
    }

    /// A host's summaries by topology key, for the rows that show live data.
    func liveSummaries(host: UUID) -> [String: ChatConversationSummary] {
        Dictionary(conversations.filter { $0.key.host == host && !$0.stale }.map { ($0.key.node, $0.summary) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Fetches summaries for a host's conversations that have no open session.
    func refresh(host id: UUID) async {
        guard let host = hosts[id], let client = host.client, !probing.contains(id) else { return }
        let nodes = host.topology?.nodes.filter { $0.kind == .terminal && $0.agent != nil && !$0.detached }
            .filter { sessions[ChatConversationKey(host: id, node: $0.key)]?.phase != .verified } ?? []
        guard !nodes.isEmpty else { return }
        probing.insert(id)
        defer { probing.remove(id) }
        let fetched = await (host.features.contains("chat.list") ? list : source).summaries(nodes.map(\.id), client: client)
        guard hosts[id]?.client === client else { return }
        for node in nodes {
            let key = ChatConversationKey(host: id, node: node.key)
            if let summary = fetched[node.id] { summaries[key] = summary }
            cached.remove(key)
        }
        rebuild()
    }

    /// The conversation's session, created on first use and kept while the terminal is bound.
    func session(for key: ChatConversationKey) -> MobileChatSession {
        if let session = sessions[key] { return session }
        let host = hosts[key.host]
        let session = MobileChatSession(key: key, hostName: host?.name ?? "", presence: presence, drafts: drafts, outbox: outbox)
        let node = host?.topology?.nodes.first { $0.key == key.node && $0.kind == .terminal }
        session.update(terminal: node?.id, binding: node?.agent)
        session.changed = { [weak self] _ in self?.rebuild() }
        sessions[key] = session
        session.update(link: host?.link ?? .disconnected, client: host?.client, problem: host?.problem)
        return session
    }

    /// The thread is on screen with its newest message: that result is seen.
    func markSeen(_ key: ChatConversationKey) {
        guard let session = sessions[key], let conversation = session.conversation,
              let time = session.transcript.lastActivity else { return }
        markers.markSeen(host: key.host, conversation: conversation, through: Self.milliseconds(time))
        rebuild()
    }

    /// The watch showed the thread through `through` (docs/watch.md, Seen): the marker moves there, never past the newest
    /// record the phone knows of (the row's `lastActivity`) and never back. False: no such row, or nothing to mark.
    @discardableResult
    func markSeen(_ key: ChatConversationKey, through: Date) -> Bool {
        guard let row = conversations.first(where: { $0.key == key }), let latest = row.summary.lastActivity,
              let conversation = sessions[key]?.conversation ?? row.binding.session.nilIfEmpty else { return false }
        markers.markSeen(host: key.host, conversation: conversation, through: Self.milliseconds(min(through, latest)))
        rebuild()
        return true
    }

    func setMuted(_ muted: Bool, _ conversation: ChatConversation) {
        markers.setMuted(muted, host: conversation.key.host, node: conversation.key.node)
        rebuild()
    }

    private func rebuild() {
        var rows: [ChatConversation] = []
        for host in hosts.values {
            guard let topology = host.topology else { continue }
            let nodes = Dictionary(topology.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for node in topology.nodes where node.kind == .terminal && !node.detached {
                guard let binding = node.agent else { continue }
                let key = ChatConversationKey(host: host.id, node: node.key)
                let tab = node.parent.flatMap { nodes[$0] }
                let space = sequence(first: node, next: { $0.parent.flatMap { nodes[$0] } }).first { $0.kind == .workspace }
                let session = sessions[key]
                var summary = summaries[key] ?? ChatConversationSummary()
                var waiting = summary.needsYou
                var stale = host.link != .connected || !host.live || cached.contains(key)
                if let session, session.phase == .verified || !session.transcript.isEmpty {
                    stale = host.link != .connected || !host.live || session.phase != .verified
                    summary = ChatConversationSummary(
                        busy: session.turnRunning, subagents: session.subagents.count, attention: session.attention,
                        preview: session.transcript.lastAgentItem.map { ChatConversationSummary.preview($0.text) } ?? summary.preview,
                        finished: session.transcript.turns.last?.ended != nil,
                        lastActivity: session.transcript.lastActivity ?? summary.lastActivity,
                        waiting: session.waitingForUser, title: session.title ?? summary.title)
                    waiting = summary.needsYou
                }
                let conversation = binding.session.isEmpty ? nil : binding.session
                var unread = false
                if let conversation, let latest = summary.lastActivity.map(Self.milliseconds), summary.preview != nil {
                    if let seen = markers.seen(host: host.id, conversation: conversation) {
                        unread = latest > seen && summary.finished
                    } else {
                        // First sight of this conversation on this phone: what it already holds is the baseline.
                        markers.markSeen(host: host.id, conversation: conversation, through: latest)
                    }
                }
                // As the Mac's PaneUrgency: the turn runs. Subagents left running after it ended do not hold back
                // its unseen result.
                let working = summary.busy
                rows.append(ChatConversation(
                    key: key, terminal: node.id, hostName: host.name, name: Self.name(tab: tab ?? node, title: summary.title), space: space?.name,
                    spaceNode: space?.id, cwd: node.cwd, binding: binding, summary: summary,
                    urgency: PaneUrgency(waiting: waiting, working: working, unread: unread),
                    muted: markers.muted(host: host.id, node: node.key), unread: unread, stale: stale))
            }
        }
        rows.sort {
            ($0.summary.lastActivity ?? .distantPast, $0.hostName, $0.key.node)
                > ($1.summary.lastActivity ?? .distantPast, $1.hostName, $1.key.node)
        }
        if rows != conversations {
            conversations = rows
            rowsChanged?()
        }
    }

    /// A row's name as the Mac's automatic tab names give it (ContainerTab.displayLabel): a renamed tab's own name, else
    /// the conversation's title, else the tab's.
    static func name(tab: HelperTopology.Node, title: String?) -> String {
        guard tab.renamed != true else { return tab.name }
        return TerminalTab.conversationLabel(title) ?? tab.name
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
