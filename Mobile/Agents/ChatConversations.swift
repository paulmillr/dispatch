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
    /// When the agent last said something the user reads (`chat.list` `reply_ms`: its newest message or turn end), what
    /// unread compares with the seen marker. Nil: `lastActivity` stands in (older helpers, the probe, an open thread).
    var reply: Date?
    /// The helper could not read the agent's state this time (`chat.list` `state_error`): `busy`, `attention` and
    /// `title` say nothing, and the previous summary's stand (`merged(over:)`).
    var stateUnknown = false
    /// The helper could not read the transcript this time (`history_error`): no preview or time, which says nothing.
    var readFailed = false

    /// One field the helper could not read: the row keeps what it had and stays stale until a clean read.
    var partial: Bool { stateUnknown || readFailed }

    /// Needs the user: an open approval or question, or the agent's own attention (a prompt only Terminal can answer).
    var needsYou: Bool { waiting || attention != nil }

    /// What unread compares with the seen marker.
    var replied: Date? { reply ?? lastActivity }

    /// A fetched summary over the one the row had: a state the helper could not read keeps the previous state, and a
    /// page that came back without a message (a transcript read that failed or raced an append) keeps the previous
    /// message and times, so one bad read neither turns a working agent idle and unread nor empties its row.
    func merged(over previous: ChatConversationSummary?) -> ChatConversationSummary {
        guard let previous else { return self }
        var result = self
        if stateUnknown {
            result.busy = previous.busy
            result.attention = previous.attention
            result.waiting = waiting || previous.waiting
            result.title = title ?? previous.title
            result.subagents = previous.subagents
        }
        if preview == nil, lastActivity == nil {
            result.preview = previous.preview
            result.lastActivity = previous.lastActivity
            result.reply = previous.reply
        }
        result.finished = stateUnknown && preview == nil && lastActivity == nil ? previous.finished
            : !result.busy && result.preview != nil
        return result
    }
}

/// Summaries for the agent-bound terminals of one host.
protocol ChatConversationSource: Sendable {
    func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary]
    /// As `summaries`, nil when the request failed (the rows stay as they were, stale, and are asked again).
    func fetch(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary]?
}

extension ChatConversationSource {
    func fetch(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary]? {
        await summaries(terminals, client: client)
    }
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

    /// One line of what the agent said: its Markdown read as text (`ChatMarkdownBlock.plainText`), whitespace collapsed.
    static func preview(_ text: String) -> String {
        // A row shows two lines: the message's head is enough to read, and parsing a long report whole cost every row.
        let head = text.count > previewSource ? String(text.prefix(previewSource)) : text
        let line = ChatMarkdownBlock.plainText(head).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > previewLength ? String(line.prefix(previewLength)) + "…" : line
    }

    /// The preview's length, as `chat.list` cuts it (`helper/core/src/dispatch/list.rs`), and how much of a message is
    /// read to make it.
    static let previewLength = 280
    static let previewSource = 2_000
}

/// One `chat.list` reply for the whole host (the `chat.list` feature, helper/PROTOCOL.md Features).
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
        /// The agent's own state word (Claude's registry status: "busy", "idle", "waiting"…).
        var activity: String? = nil
        /// Why the state could not be read: `busy`, `attention` and `title` are null then, not idle.
        var state_error: String? = nil
        /// When its newest message (or turn end) was written; absent from helpers before it.
        var reply_ms: Int64? = nil
        /// Why the transcript could not be read: no preview or time this time, not an empty conversation.
        var history_error: String? = nil

        var summary: ChatConversationSummary {
            // Claude blocked on a prompt in its terminal reports "waiting", which its registry counts as busy: it waits
            // for the user, whether or not the attention guard has named the prompt yet.
            let blocked = activity == "waiting"
            let busy = (busy ?? false) && !blocked
            // No turn records here: an agent that is not busy has finished its last turn.
            var summary = ChatConversationSummary(
                busy: busy, attention: attention, preview: preview.map(ChatConversationSummary.preview),
                finished: !busy && preview != nil,
                lastActivity: time_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                waiting: (waiting ?? false) || (blocked && attention == nil), title: title)
            summary.reply = reply_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
            summary.stateUnknown = state_error != nil
            summary.readFailed = history_error != nil
            return summary
        }

        private enum CodingKeys: String, CodingKey {
            case terminal, busy, attention, preview, time_ms, waiting, title, activity, state_error, reply_ms, history_error
        }
    }

    static func rows(_ client: HelperClient) async -> [Row]? {
        try? await client.connection.request("chat.list", params: [String: String]())
    }

    func summaries(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary] {
        await fetch(terminals, client: client) ?? [:]
    }

    func fetch(_ terminals: [UInt64], client: HelperClient) async -> [UInt64: ChatConversationSummary]? {
        guard let rows = await Self.rows(client) else { return nil }
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
    /// Markers move with every record a shown thread receives and with every conversation first seen: the file is
    /// written once a second at most, and at once when the app leaves the foreground (`flush`).
    @ObservationIgnored private var saving: Task<Void, Never>?
    static let saveDelay: Duration = .seconds(1)

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
        scheduleSave()
    }

    private func scheduleSave() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes what changed now (the app leaves the foreground; a test).
    func flush() {
        saving?.cancel()
        saving = nil
        try? store.save(document)
    }

    /// Forgets the markers and mutes of a host the user removed.
    func removeAll(host: UUID) {
        let prefix = host.uuidString + ":"
        let seen = document.seen.filter { !$0.key.hasPrefix(prefix) }
        let muted = document.muted.filter { !$0.hasPrefix(prefix) }
        guard seen.count != document.seen.count || muted.count != document.muted.count else { return }
        document.seen = seen
        document.muted = muted
        flush()
    }

    func muted(host: UUID, node: String) -> Bool { document.muted.contains(Self.muteKey(host: host, node: node)) }

    /// Forgets every seen marker and mute (Settings' Remove all data).
    func removeAll() {
        document = Document()
        flush()
    }

    func setMuted(_ muted: Bool, host: UUID, node: String) {
        let key = Self.muteKey(host: host, node: node)
        if muted { document.muted.insert(key) } else { document.muted.remove(key) }
        flush()
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
    /// Last-known (cached, the previous connection's, or the host is not connected): the row dims until live data
    /// arrives.
    var stale = false
    /// When the row first appeared in this run: its place in the list until the agent writes something.
    var since = Date.distantPast
    /// While it works, read from the host's list (no open thread): what it said since the turn began, as far as the
    /// phone can tell (`TabsStatus.note`), and when the turn began when the phone saw it begin.
    var workingNote: String? = nil
    var workingSince: Date? = nil

    /// What the list sorts by: the newest record, else when the row appeared (a new agent is at the top, not the end).
    var order: Date { summary.lastActivity ?? since }

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
/// Agents' filter chips: every conversation, those that need the user (live ones, as the badge counts them), or
/// those with something unread (a result not seen yet, or needing the user). Kept across launches
/// (`MobileComposition`).
enum AgentsFilter: String, CaseIterable, Identifiable, Sendable {
    case all, needsYou, unread
    var id: Self { self }
    var title: String {
        switch self { case .all: "All"; case .needsYou: "Needs you"; case .unread: "Unread" }
    }
    var symbol: String {
        // One bubble, as Spaces' Agents chip.
        switch self { case .all: "text.bubble"; case .needsYou: "exclamationmark.bubble"; case .unread: "envelope.badge" }
    }
    func keeps(_ row: ChatConversation) -> Bool {
        switch self {
        case .all: true
        case .needsYou: row.urgency == .waiting && !row.stale
        case .unread: row.urgency == .waiting || row.urgency == .unread
        }
    }
}

/// Agent conversations across hosts: one per terminal whose topology node carries an agent binding, with its
/// `PaneUrgency` (Dispatch/Attention.swift) from the agent's state, open requests and the phone's seen markers. Keeps
/// the `MobileChatSession`s of the threads shown lately so a thread keeps its state while the user moves between tabs;
/// older ones are released (`release`), their rows read from `chat.list` again.
///
/// A conversation's session, from first to last (docs/ios.md, Agents and Chat):
/// - **Warm** (`warm`): opened by the Agents list for its first rows while it shows (`agentsListShown`), one at a time,
///   its terminal not attached. Not in `sessions`, so nothing else sees it: its row stays `chat.list`'s, it marks
///   nothing seen, silences no banner and is not the watch's. It has no work of its own (nothing can reach it). It is
///   released (`releaseWarm`) once its row has been out of the list's first rows, or the list off screen, for
///   `prewarmLinger`, at once when the app goes to the background, and when it would have to open again (a new
///   connection, node or binding: it is warmed again through the queue). One whose `chat.open` failed or went
///   unanswered for `warmOpenLimit` is released and its row given up on that connection; a tap opens such a row afresh
///   (`takeWarm`).
/// - **Open** (`sessions`): made, or taken over from `warm` (`claim`), by whoever asks for it (`session(for:)`), or by
///   a tap that pushes its tab on Chat (`opening`, in the tap's turn). A new session first takes the conversation's
///   kept transcript (`transcripts`), when it is still the topology's conversation (`seed`).
/// - **Pending** (`pending`): opened by a tap and not on screen yet. Not trimmed; the helper's answers wait for the
///   thread's first frame (`MobileChatSession.holdUpdates`, at most `holdLimit`). A push that never shows it
///   (`abandoned`: the tab left the path, another pane's thread showed, or `pendingLimit` passed) makes it an ordinary
///   open session, trimmed as any other.
/// - **Shown** (`onScreen`, then `recent`): the thread on screen and the `keptSessions` shown last stay subscribed.
/// - **Released** (`release`): neither shown, nor among the last shown, nor pending, and without work of its own
///   (`trimSessions`), or its host removed. What it read goes to `transcripts`, in memory, for the next session.
@MainActor @Observable final class ChatConversations {
    private(set) var hosts: [UUID: ChatHostSnapshot] = [:] {
        didSet { terminalKeys = hosts.mapValues { host in
            Dictionary((host.topology?.nodes ?? []).map { ($0.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        } }
    }
    private(set) var conversations: [ChatConversation] = [] {
        didSet { rowIndex = Dictionary(conversations.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// The rows by key and each host's terminals' keys by node id: Spaces asks for them per row on every list update.
    @ObservationIgnored private var rowIndex: [ChatConversationKey: Int] = [:]
    @ObservationIgnored private var terminalKeys: [UUID: [UInt64: String]] = [:]
    @ObservationIgnored private var summaries: [ChatConversationKey: ChatConversationSummary] = [:]
    @ObservationIgnored private(set) var sessions: [ChatConversationKey: MobileChatSession] = [:]
    @ObservationIgnored private var probing: Set<UUID> = []
    /// Hosts asked again while a fetch was on its way: it runs once more when that one ends.
    @ObservationIgnored private var requested: Set<UUID> = []
    /// Rows whose summary came from the device's cache, or whose last fetch could not read the agent's state, and has
    /// not been fetched live since.
    @ObservationIgnored private var cached: Set<ChatConversationKey> = []
    /// The client whose `chat.list` the host's rows last came from: until a fetch over a new connection answers, the
    /// rows are the previous connection's and show stale (a reconnect does not make old data look live).
    @ObservationIgnored private var confirmed: [UUID: ObjectIdentifier] = [:]
    /// When each host last answered before this launch (`HostCache`): a conversation first seen now whose newest
    /// message is later is unread (it arrived while the phone was away), not the baseline.
    @ObservationIgnored private var baselines: [UUID: Date] = [:]
    /// When each row first appeared in this run: the order of a conversation that has written nothing yet.
    @ObservationIgnored private var firstSeen: [ChatConversationKey: Date] = [:]
    /// A busy row's turn as the list saw it begin (`workingNote`): the row's newest record then (the host's clock, so an
    /// answer is compared with the host's times), and whether the row was seen idle before (its start is then the
    /// turn's). A message newer than the mark is this turn's; the previous turn's answer is older.
    @ObservationIgnored private var busyMarks: [ChatConversationKey: (mark: Date, begun: Bool)] = [:]
    /// Rows seen idle in this run: a later busy one was seen to begin.
    @ObservationIgnored private var seenIdle: Set<ChatConversationKey> = []
    /// The newest agent message's preview per open session, by transcript revision: Markdown is read once per change.
    @ObservationIgnored private var previews: [ChatConversationKey: (revision: Int, text: String?)] = [:]
    /// Threads on screen now, and the ones shown last (newest first): their sessions stay subscribed.
    @ObservationIgnored private var onScreen: Set<ChatConversationKey> = []
    @ObservationIgnored private var recent: [ChatConversationKey] = []
    /// Threads a tap is pushing that have not come on screen yet (`opening`), and since when: their sessions are not
    /// trimmed until they show, or `pendingLimit` passes without it (a push whose thread never came: its tab opened on
    /// another segment, or its pane was rebound meanwhile).
    @ObservationIgnored private var pendingSince: [ChatConversationKey: Date] = [:]
    var pending: Set<ChatConversationKey> { Set(pendingSince.keys) }
    /// What released sessions read, for the next session of each conversation (`ChatTranscriptStore`).
    @ObservationIgnored let transcripts: ChatTranscriptStore
    /// Sessions the Agents list opened ahead of a tap and nobody has asked for yet (the type's comment, Warm).
    @ObservationIgnored private(set) var warm: [ChatConversationKey: MobileChatSession] = [:]
    /// The Agents list's first rows, in the order it shows them, while it is on screen (`agentsListShown`).
    @ObservationIgnored private var listed: [ChatConversationKey] = []
    @ObservationIgnored private var listShowing = false
    /// Warm sessions whose rows left the list's first rows (or whose list left the screen), and since when.
    @ObservationIgnored private var cooling: [ChatConversationKey: Date] = [:]
    /// When each warm session's `chat.open` went out: one not answered within `warmOpenLimit` is let go.
    @ObservationIgnored private var warmStarted: [ChatConversationKey: Date] = [:]
    /// Rows whose warm open failed or never answered: not warmed again on this connection (a tap opens them afresh).
    @ObservationIgnored private var gaveUp: Set<ChatConversationKey> = []
    /// Wakes `tick` at the next deadline (cooling, a warm open, a push).
    @ObservationIgnored private var deadlineTimer: Task<Void, Never>?
    /// The clock those deadlines read; checks set their own.
    @ObservationIgnored var now: () -> Date = { System.date() }
    /// The app is not in the background (`MobileComposition.scenePhaseChanged`): only then does the list warm rows.
    @ObservationIgnored var foreground = true {
        didSet { if foreground != oldValue { reconsiderWarm() } }
    }
    /// A screen pushed over the tab bar covers the list on a phone's stack (`MobileComposition.routed`), whether or not
    /// the list heard of its disappearance.
    @ObservationIgnored var agentsListCovered = false {
        didSet { if agentsListCovered != oldValue { reconsiderWarm() } }
    }
    @ObservationIgnored private(set) var rebuildPending = false
    @ObservationIgnored private var hostChanges: [UUID: Task<Void, Never>] = [:]
    /// Called after the rows changed (the composition keeps the live ones in the cache).
    @ObservationIgnored var rowsChanged: (() -> Void)?
    /// A live row's summary changed, or a live row went away while its host stayed connected (nil `current`): the
    /// composition's notifications while the app is open (`AgentAlerts.arrived`). Rows restored from the cache or
    /// coming back with a connection are not arrivals: they are stale until their host's first fetch answers.
    @ObservationIgnored var arrived: ((_ previous: ChatConversation, _ current: ChatConversation?) -> Void)?
    @ObservationIgnored let presence: (any ChatTerminalPresence)?
    let markers: ChatMarkers
    let outbox: ChatOutbox
    let drafts: ChatDraftRepository
    @ObservationIgnored let source: any ChatConversationSource
    @ObservationIgnored let list: any ChatConversationSource
    /// The list's filter (Agents' chips), kept across launches by the composition (`filterChanged`).
    var filter = AgentsFilter.all {
        didSet { if filter != oldValue { filterChanged?(filter) } }
    }
    @ObservationIgnored var filterChanged: ((AgentsFilter) -> Void)?
    /// The space New chat starts in: the one used last (`MobileTabs.recentSpace`), by host and topology key.
    @ObservationIgnored var preferredSpace: (() -> (host: UUID, key: String)?)?
    /// How many threads not on screen keep their sessions (and their subscriptions) after they were shown.
    @ObservationIgnored var keptSessions = 3
    /// How many of the Agents list's first rows are opened ahead of a tap: about what an iPhone shows of the list
    /// before it is scrolled (six rows of three lines under the chips on a 6.1-inch screen), so a row tapped without
    /// scrolling opens as a reopen does. Each is a live `chat.open` on top of the threads kept after they were shown:
    /// its page once, then the agent's state and records while it works, and on the host the helper's prompt watch,
    /// which reads the terminal's screen on each settled change (every 33 ms while a native prompt shows) and sends
    /// what prompt it finds (docs/security.md, Chat reads on the phone).
    static let prewarmCount = 6
    /// How long a warm session outlives its place in the list's first rows (or the list on screen): a thread opened
    /// from the list and closed again, or a row moving one place and back, opens nothing again.
    @ObservationIgnored var prewarmLinger: Duration = .seconds(10)
    /// How long a warm `chat.open` may go unanswered before it is let go and the next row warms.
    @ObservationIgnored var warmOpenLimit: Duration = .seconds(10)
    /// How long a push's session stays `pending` without its thread showing (a push shows in well under a second).
    @ObservationIgnored var pendingLimit: Duration = .seconds(5)
    /// How long a tapped thread's answers wait for its first frame at most (`MobileChatSession.holdUpdates`).
    @ObservationIgnored var holdLimit: Duration = MobileChatSession.holdLimit
    /// How long a host's activity push waits for more before the host's rows are fetched (`activityChanged`).
    static let pushDelay: Duration = .milliseconds(400)
    /// At most this often a session's change rebuilds the rows.
    static let rebuildDelay: Duration = .milliseconds(100)

    /// `source` serves helpers without the `chat.list` feature, `list` those with it.
    init(source: any ChatConversationSource = ChatStateProbe(), list: any ChatConversationSource = ChatListOperation(),
         presence: (any ChatTerminalPresence)? = nil, markers: ChatMarkers = .shared, outbox: ChatOutbox = .shared,
         drafts: ChatDraftRepository = .shared, transcripts: ChatTranscriptStore = ChatTranscriptStore()) {
        self.source = source
        self.list = list
        self.presence = presence
        self.markers = markers
        self.outbox = outbox
        self.drafts = drafts
        self.transcripts = transcripts
    }

    var visible: [ChatConversation] { conversations.filter { filter.keeps($0) } }

    /// Conversations waiting for the user, across hosts, muted ones included, on the hosts reached now (live rows): the
    /// one count for the back pill (M4a), Spaces' Needs you chip and filter, the Agents tab's badge and chip, the app's
    /// badge (`AgentAlerts.waiting` of the live rows) and the watch's.
    var needsYouCount: Int { conversations.filter { !$0.stale && $0.urgency == .waiting }.count }

    /// A row by its key.
    func conversation(_ key: ChatConversationKey) -> ChatConversation? {
        guard let index = rowIndex[key], conversations.indices.contains(index) else { return nil }
        return conversations[index]
    }

    /// The dot for a terminal's conversation, and for a host its most urgent one (needs you, working, then unread).
    func dot(host: UUID, terminal: UInt64) -> MobileRowDot? {
        key(host: host, terminal: terminal).flatMap { conversation($0)?.dot }
    }

    func dot(_ key: ChatConversationKey) -> MobileRowDot? { conversation(key)?.dot }

    func dot(host: UUID) -> MobileRowDot? {
        let rows = conversations.filter { $0.key.host == host && $0.dot != nil }
        if rows.contains(where: { $0.urgency == .waiting }) { return .unread }
        return rows.contains { $0.dot == .working } ? .working : rows.isEmpty ? nil : .unread
    }

    /// The conversation key of a terminal in a host's current topology.
    func key(host: UUID, terminal: UInt64) -> ChatConversationKey? {
        // Read `hosts` so a view asking follows the topology, then the index built from it.
        guard hosts[host] != nil, let node = terminalKeys[host]?[terminal] else { return nil }
        return ChatConversationKey(host: host, node: node)
    }

    /// A host's link, client or topology changed.
    func update(_ host: ChatHostSnapshot) {
        let previous = hosts[host.id]
        hosts[host.id] = host
        let client = host.link == .connected ? host.client : nil
        if previous.map({ ($0.link == .connected ? $0.client : nil) !== client }) ?? true {
            // A new connection tries the rows given up on the last one.
            gaveUp = gaveUp.filter { $0.host != host.id }
        }
        // A warm session that would open again (another client, node or binding) is let go instead, and warmed again
        // through the queue: one at a time, after the user's thread (`advancePrewarm`).
        for (key, session) in warm where key.host == host.id {
            let node = host.topology?.nodes.first { $0.key == key.node && $0.kind == .terminal && !$0.detached }
            if client !== session.client || (host.topology != nil && (node?.id != session.terminal || node?.agent != session.binding)) {
                releaseWarm(key, advancing: false)
            } else {
                if session.hostName != host.name { session.hostName = host.name }
                session.update(link: host.link, client: host.client, problem: host.problem, features: host.features)
            }
        }
        for (key, session) in sessions where key.host == host.id {
            if session.hostName != host.name { session.hostName = host.name }
            // Node ids change with every helper: the conversation follows its terminal's key.
            if let topology = host.topology {
                let node = topology.nodes.first { $0.key == key.node && $0.kind == .terminal && !$0.detached }
                session.update(terminal: node?.id, binding: node?.agent)
            }
            // Without a topology (offline) the last binding stands: the thread stays readable.
            session.update(link: host.link, client: host.client, problem: host.problem, features: host.features)
        }
        if host.client == nil { confirmed[host.id] = nil }
        rebuild()
        // A host reached again (or its agents changed): the list's first rows on it can be warmed now.
        advancePrewarm()
        let bindings = { (topology: HelperTopology?) -> [String] in
            topology?.nodes.compactMap { node in node.agent.map { node.key + ":" + $0.session } } ?? []
        }
        if host.client != nil, previous?.client !== host.client || bindings(previous?.topology) != bindings(host.topology) {
            Task { await refresh(host: host.id) }
        }
    }

    /// The host was removed (by the user, or Remove all data): its sessions end and what they read is forgotten.
    func remove(host: UUID) {
        hosts[host] = nil
        cached = cached.filter { $0.host != host }
        confirmed[host] = nil
        for key in sessions.keys where key.host == host { release(key) }
        for key in warm.keys where key.host == host { releaseWarm(key) }
        pendingSince = pendingSince.filter { $0.key.host != host }
        gaveUp = gaveUp.filter { $0.host != host }
        listed.removeAll { $0.host == host }
        // After the releases, which keep what they read.
        transcripts.remove(host: host)
        rebuild()
    }

    /// Every kept transcript goes (Remove all data, memory pressure); open sessions keep theirs.
    func forgetTranscripts() {
        transcripts.removeAll()
    }

    /// The host's rows as the device last saw them (`HostCache`, at launch), by topology key; live summaries replace
    /// them as they are fetched. `heard`: when the host last answered then, the unread baseline of conversations this
    /// phone has no marker for.
    func restore(host: UUID, summaries restored: [String: ChatConversationSummary], heard: Date? = nil) {
        if let heard { baselines[host] = heard }
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

    /// Every connected host's rows, fetched again: pull to refresh, the app coming to the foreground, and the
    /// composition's timer while the app is open.
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for id in hosts.keys where hosts[id]?.client != nil {
                group.addTask { await self.refresh(host: id) }
            }
        }
    }

    /// The host's helper said an agent's state changed (its activity push): its rows are fetched again shortly, once
    /// for a burst of changes.
    func activityChanged(host: UUID) {
        guard hostChanges[host] == nil else { return }
        hostChanges[host] = Task { [weak self] in
            try? await Task.sleep(for: Self.pushDelay)
            guard let self, !Task.isCancelled else { return }
            self.hostChanges[host] = nil
            await self.refresh(host: host)
        }
    }

    /// Fetches summaries for a host's conversations that have no live session. Asked while a fetch is on its way, it
    /// runs again when that one ends (the topology may have bound new agents meanwhile). A failed request keeps the
    /// rows as they were, stale.
    func refresh(host id: UUID) async {
        guard let host = hosts[id], let client = host.client else { return }
        guard !probing.contains(id) else {
            requested.insert(id)
            return
        }
        let nodes = host.topology?.nodes.filter { $0.kind == .terminal && $0.agent != nil && !$0.detached }
            .filter { sessions[ChatConversationKey(host: id, node: $0.key)]?.phase != .verified } ?? []
        guard !nodes.isEmpty else {
            confirmed[id] = ObjectIdentifier(client)
            rebuild()
            return
        }
        probing.insert(id)
        let fetched = await (host.features.contains("chat.list") ? list : source).fetch(nodes.map(\.id), client: client)
        probing.remove(id)
        if hosts[id]?.client === client, let fetched {
            confirmed[id] = ObjectIdentifier(client)
            for node in nodes {
                let key = ChatConversationKey(host: id, node: node.key)
                guard let summary = fetched[node.id] else { continue }
                summaries[key] = summary.merged(over: summaries[key])
                if summary.partial { cached.insert(key) } else { cached.remove(key) }
            }
            rebuild()
        }
        if requested.remove(id) != nil { await refresh(host: id) }
    }

    /// The conversation's session, created on first use (or taken over from the Agents list's warm ones, its terminal
    /// attached now) and kept while its thread is shown or among the last shown.
    func session(for key: ChatConversationKey) -> MobileChatSession {
        if let session = sessions[key] {
            // A warm session a tap took over whose push was abandoned: whoever asks now needs its terminal. Not one being
            // pushed or shown (its screen asks for it too): that one attaches after its first frame (`firstFrameShown`).
            if session.defersTerminal, !pending.contains(key), !onScreen.contains(key) { session.attachTerminal() }
            return session
        }
        if let session = takeWarm(key, attaching: true) { return session }
        return open(key)
    }

    /// A new session in `sessions`: seeded with the conversation's kept transcript when the topology still binds that
    /// conversation (one kept for another is dropped), then opened when its host is reached. `hold`: a tap is pushing
    /// its thread (`opening`), so its answers wait for the first frame, from the very first.
    private func open(_ key: ChatConversationKey, hold: Bool = false) -> MobileChatSession {
        let session = make(key)
        session.changed = { [weak self] _ in self?.scheduleRebuild() }
        session.phaseChanged = { [weak self] _ in self?.advancePrewarm() }
        sessions[key] = session
        if hold { session.holdUpdates(for: holdLimit) }
        connect(session)
        return session
    }

    private func make(_ key: ChatConversationKey) -> MobileChatSession {
        let host = hosts[key.host]
        let session = MobileChatSession(key: key, hostName: host?.name ?? "", presence: presence, drafts: drafts, outbox: outbox)
        let node = host?.topology?.nodes.first { $0.key == key.node && $0.kind == .terminal }
        session.update(terminal: node?.id, binding: node?.agent)
        if let kept = transcripts.take(key) {
            let bound = node?.agent?.session ?? ""
            if kept.conversation == bound {
                session.seed(kept)
            } else if bound.isEmpty {
                // No conversation named now (a new helper's first snapshots, a provisional binding): kept for later.
                transcripts.keep(kept, for: key)
            }
            // Another conversation's rows never show; they are dropped.
        }
        return session
    }

    private func connect(_ session: MobileChatSession) {
        let host = hosts[session.key.host]
        session.update(link: host?.link ?? .disconnected, client: host?.client, problem: host?.problem,
                       features: host?.features ?? [])
    }

    /// A tab is being pushed on Chat (an Agents row, a space's tab, a notification): its session opens in this turn, so
    /// `chat.open` leaves with the tap, a warm one is taken over, and the session is kept until its thread shows or the
    /// push is abandoned (`abandoned`). Whatever the helper answers before the thread's first frame waits for it
    /// (`MobileChatSession.holdUpdates`, ended by `shown` and the thread's own view).
    func opening(_ key: ChatConversationKey) {
        pendingSince[key] = now()
        if let session = sessions[key] {
            if session.phase != .verified { session.holdUpdates(for: holdLimit) }
        } else if let session = takeWarm(key, attaching: false) {
            // Verified or on its way: its rows are the first frame's; the terminal attaches as it shows (`shown`).
            if session.phase != .verified { session.holdUpdates(for: holdLimit) }
        } else {
            _ = open(key, hold: true)
        }
        scheduleDeadlines()
    }

    /// The push `opening` began will not show the thread (another tab replaced it, the user went back first): its
    /// session is an ordinary one again, trimmed by the usual rules, and nothing it holds waits longer.
    func abandoned(_ key: ChatConversationKey) {
        guard pendingSince.removeValue(forKey: key) != nil else { return }
        sessions[key]?.endHold()
        trimSessions()
        advancePrewarm()
    }

    /// The thread came on screen: its session stays subscribed while it shows and while it is among the last shown. A
    /// warm session's terminal attaches now; answers held for the push apply just after this frame is committed.
    func shown(_ key: ChatConversationKey) {
        pendingSince[key] = nil
        onScreen.insert(key)
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        // The first frame ends the hold and attaches a deferred terminal (`ChatThreadView.attached`, after the push's
        // layout); this appearance may come before the view is in a window, so it only starts the backstop: a thread
        // shown without its view entering a window gets both after `holdLimit`.
        if let session = sessions[key], session.waitsForFirstFrame {
            let limit = holdLimit
            Task { [weak self, weak session] in
                try? await Task.sleep(for: limit)
                guard let self, let session, self.onScreen.contains(key), self.sessions[key] === session else { return }
                session.firstFrameShown()
            }
        }
    }

    /// The thread left the screen: sessions beyond the last few shown are released.
    func hidden(_ key: ChatConversationKey) {
        onScreen.remove(key)
        trimSessions()
        advancePrewarm()
    }

    /// Releases the sessions of threads neither on screen, nor among the last `keptSessions` shown, nor being pushed
    /// (`pending`), unless one still has work of its own (sending, a queue, a side conversation, an approval on screen,
    /// a launch). Warm sessions are not `sessions`: they follow the Agents list (`reconsiderWarm`).
    func trimSessions() {
        let kept = Set(recent.prefix(keptSessions)).union(onScreen).union(pending)
        recent = Array(recent.prefix(max(keptSessions, 1) * 4))
        for (key, session) in sessions where !kept.contains(key) && session.releasable { release(key) }
    }

    /// Ends a session: its subscription closes, what it read is kept (`transcripts`), and its row reads `chat.list`
    /// again (fetched now, so the row does not sit on the session's last state).
    private func release(_ key: ChatConversationKey) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.changed = nil
        session.phaseChanged = nil
        if let kept = session.kept() { transcripts.keep(kept, for: key) }
        session.release()
        previews[key] = nil
        if let summary = conversation(key)?.summary { summaries[key] = summary }
        if hosts[key.host]?.client != nil {
            cached.insert(key)
            Task { await refresh(host: key.host) }
        }
        scheduleRebuild()
    }

    // MARK: Warm sessions (the Agents list's first rows)

    /// The Agents list is on screen with these rows first, in the order it shows them (its grouping and sections,
    /// `AgentsScreen.shownOrder`): the first `prewarmCount` are opened ahead of a tap.
    func agentsListShown(_ order: [ChatConversationKey]) {
        listShowing = true
        listed = Array(order.prefix(Self.prewarmCount))
        reconsiderWarm()
    }

    /// The Agents list left the screen: its warm sessions go after `prewarmLinger`.
    func agentsListHidden() {
        listShowing = false
        reconsiderWarm()
    }

    /// The rows to keep warm now: the list's first ones, while it shows and the app is not in the background.
    private var wanted: [ChatConversationKey] { listShowing && !agentsListCovered && foreground ? listed : [] }

    /// Warm sessions follow `wanted`: one no longer wanted cools for `prewarmLinger` (in the background it goes at
    /// once), one wanted again stays, and the wanted rows without a session are opened (`advancePrewarm`).
    private func reconsiderWarm() {
        let wanted = Set(self.wanted)
        let now = now()
        for key in warm.keys {
            if wanted.contains(key) { cooling[key] = nil } else if cooling[key] == nil { cooling[key] = now }
        }
        if !foreground { for key in Array(cooling.keys) { releaseWarm(key) } }
        tick()
        advancePrewarm()
    }

    /// The lifecycle's deadlines, read on `now`: warm sessions that cooled for `prewarmLinger` go; a warm `chat.open`
    /// unanswered for `warmOpenLimit` goes and its row is given up on this connection (the queue moves on); a push
    /// whose thread did not show within `pendingLimit` is abandoned. Then wakes for the next deadline.
    func tick() {
        let now = now()
        func passed(_ since: Date, _ limit: Duration) -> Bool { now.timeIntervalSince(since) >= Self.seconds(limit) }
        for (key, since) in cooling where passed(since, prewarmLinger) { releaseWarm(key) }
        for (key, since) in warmStarted where warm[key]?.phase == .opening && passed(since, warmOpenLimit) {
            gaveUp.insert(key)
            releaseWarm(key)
        }
        for (key, since) in pendingSince where passed(since, pendingLimit) { abandoned(key) }
        scheduleDeadlines()
        advancePrewarm()
    }

    private func scheduleDeadlines() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        let deadlines = cooling.values.map { $0.addingTimeInterval(Self.seconds(prewarmLinger)) }
            + warmStarted.filter { warm[$0.key]?.phase == .opening }.values.map { $0.addingTimeInterval(Self.seconds(warmOpenLimit)) }
            + pendingSince.values.map { $0.addingTimeInterval(Self.seconds(pendingLimit)) }
        guard let next = deadlines.min() else { return }
        let wait = max(0, next.timeIntervalSince(now()))
        deadlineTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Opens the next wanted row's session, one at a time: a warm session still waiting for its history holds the next
    /// back, so the list's reads never queue more than one page ahead of the thread the user taps, and nothing warms
    /// while a thread the user opened (being pushed, or on screen) still waits for its own. A row is warmed only on a
    /// host reached now (its live topology's client), with no session yet, and nothing in the device's queue for it (a
    /// warm session must not send what the user queued). Every session's phase change asks again.
    func advancePrewarm() {
        guard !warm.values.contains(where: { $0.phase == .opening }),
              !pending.union(onScreen).contains(where: { sessions[$0]?.phase == .opening }) else { return }
        for key in wanted where sessions[key] == nil && warm[key] == nil && !gaveUp.contains(key) {
            guard let host = hosts[key.host], host.link == .connected, host.client != nil,
                  conversation(key) != nil, outbox.items(for: key).isEmpty else { continue }
            let session = make(key)
            session.deferTerminal()
            session.phaseChanged = { [weak self] session in self?.warmPhaseChanged(key, session) }
            warm[key] = session
            warmStarted[key] = now()
            connect(session)
            if session.phase == .opening {
                scheduleDeadlines()
                return
            }
        }
    }

    /// A warm session that failed (`paused`: its `chat.open` refused, the agent gone) is let go and its row given up on
    /// this connection, so the queue moves on and a tap opens it afresh; any other change may let the next row warm.
    /// After the session's own change has finished (this runs inside it).
    private func warmPhaseChanged(_ key: ChatConversationKey, _ session: MobileChatSession) {
        if case .paused = session.phase {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.warm[key] === session, case .paused = session.phase else { return }
                self.gaveUp.insert(key)
                self.releaseWarm(key)
            }
        }
        advancePrewarm()
    }

    /// The warm session of `key` for whoever asks, when it can serve: verified, or its `chat.open` on its way for less
    /// than `warmOpenLimit`. One that failed or hangs is let go (what it read kept) so a fresh session opens instead.
    private func takeWarm(_ key: ChatConversationKey, attaching: Bool) -> MobileChatSession? {
        guard let session = warm[key] else { return nil }
        let opening = session.phase == .opening
            && now().timeIntervalSince(warmStarted[key] ?? .distantPast) < Self.seconds(warmOpenLimit)
        guard session.phase == .verified || opening else {
            releaseWarm(key, advancing: false)
            return nil
        }
        return claim(key, attaching: attaching)
    }

    /// A warm session becomes an open one (`sessions`), as if it had been opened now: its row follows it from here. Its
    /// terminal attaches at once for whoever asked (`attaching`), or as its thread shows for a tap (`shown`).
    private func claim(_ key: ChatConversationKey, attaching: Bool) -> MobileChatSession {
        let session = warm.removeValue(forKey: key)!
        cooling[key] = nil
        warmStarted[key] = nil
        session.changed = { [weak self] _ in self?.scheduleRebuild() }
        session.phaseChanged = { [weak self] _ in self?.advancePrewarm() }
        sessions[key] = session
        if attaching {
            session.attachTerminal()
            scheduleRebuild()
        }
        // A tap's: the row follows the session once the thread's first frame is committed (`firstFrameShown`), so its
        // rebuild (100 ms on) does not land in the push's layout.
        advancePrewarm()
        return session
    }

    /// Ends a warm session. It had no work of its own and its row never followed it: only what it read is kept.
    /// `advancing` false: the caller asks the queue once it is done (it changes more first).
    private func releaseWarm(_ key: ChatConversationKey, advancing: Bool = true) {
        cooling[key] = nil
        warmStarted[key] = nil
        guard let session = warm.removeValue(forKey: key) else { return }
        session.phaseChanged = nil
        if let kept = session.kept() { transcripts.keep(kept, for: key) }
        session.release()
        if advancing { advancePrewarm() }
    }

    /// The thread is on screen with its newest message: that result is seen.
    func markSeen(_ key: ChatConversationKey) {
        guard let session = sessions[key], let conversation = session.conversation,
              let time = session.transcript.lastActivity else { return }
        let before = markers.seen(host: key.host, conversation: conversation)
        markers.markSeen(host: key.host, conversation: conversation, through: Self.milliseconds(time))
        if markers.seen(host: key.host, conversation: conversation) != before { scheduleRebuild() }
    }

    /// The row's result is seen without opening it (a row's Mark as Read), through its newest message.
    func markRead(_ key: ChatConversationKey) {
        guard let row = conversation(key), let latest = row.summary.replied ?? row.summary.lastActivity,
              let conversation = sessions[key]?.conversation ?? row.binding.session.nilIfEmpty else { return }
        markers.markSeen(host: key.host, conversation: conversation, through: Self.milliseconds(latest))
        rebuild()
    }

    /// The watch showed the thread through `through` (docs/watch.md, Seen): the marker moves there, never past the newest
    /// record the phone knows of (the row's `lastActivity`) and never back. False: no such row, or nothing to mark.
    @discardableResult
    func markSeen(_ key: ChatConversationKey, through: Date) -> Bool {
        guard let row = conversation(key), let latest = row.summary.lastActivity,
              let conversation = sessions[key]?.conversation ?? row.binding.session.nilIfEmpty else { return false }
        markers.markSeen(host: key.host, conversation: conversation, through: Self.milliseconds(min(through, latest)))
        rebuild()
        return true
    }

    func setMuted(_ muted: Bool, _ conversation: ChatConversation) {
        markers.setMuted(muted, host: conversation.key.host, node: conversation.key.node)
        rebuild()
    }

    /// A session's notifications come in bursts (records, state, queue): one rebuild for each burst.
    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.rebuildDelay)
            guard let self else { return }
            self.rebuildPending = false
            self.rebuild()
        }
    }

    /// A read of the conversation came back without any message: `chat.list` read it whole (no partial read), or its
    /// thread's history loaded empty.
    static func saidNothing(fetched: ChatConversationSummary?, session: MobileChatSession?) -> Bool {
        if let session, session.phase == .verified { return session.transcript.isEmpty }
        guard let fetched, !fetched.partial else { return false }
        return fetched.preview == nil && fetched.lastActivity == nil
    }

    /// The preview of a session's newest agent message, read again only when its transcript changed.
    private func preview(_ key: ChatConversationKey, _ session: MobileChatSession) -> String? {
        let revision = session.transcript.revision
        if let cached = previews[key], cached.revision == revision { return cached.text }
        let text = session.transcript.lastAgentItem.map { ChatConversationSummary.preview($0.text) }
        previews[key] = (revision, text)
        return text
    }

    func rebuild() {
        rebuildPending = false
        var rows: [ChatConversation] = []
        let now = System.date()
        for host in hosts.values {
            guard let topology = host.topology else { continue }
            let nodes = Dictionary(topology.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let live = host.link == .connected && host.live
                && host.client.map { confirmed[host.id] == ObjectIdentifier($0) } == true
            for node in topology.nodes where node.kind == .terminal && !node.detached {
                guard let binding = node.agent else { continue }
                let key = ChatConversationKey(host: host.id, node: node.key)
                let tab = node.parent.flatMap { nodes[$0] }
                let space = sequence(first: node, next: { $0.parent.flatMap { nodes[$0] } }).first { $0.kind == .workspace }
                let session = sessions[key]
                let fetched = summaries[key]
                var summary = fetched ?? ChatConversationSummary()
                var stale = !live || cached.contains(key)
                if let session, session.phase == .verified {
                    stale = host.link != .connected || !host.live
                    summary = ChatConversationSummary(
                        busy: session.turnRunning, subagents: session.subagents.count, attention: session.attention,
                        preview: preview(key, session) ?? summary.preview,
                        finished: session.transcript.turns.last?.ended != nil,
                        lastActivity: session.transcript.lastActivity ?? summary.lastActivity,
                        waiting: session.waitingForUser, title: session.title ?? summary.title)
                    // The newest the phone knows: what the row shows once the session is released or the host drops.
                    summaries[key] = summary
                }
                if firstSeen[key] == nil { firstSeen[key] = now }
                var workingNote: String?, workingSince: Date?
                if !stale {
                    if summary.busy {
                        let mark = busyMarks[key] ?? {
                            let mark = (mark: summary.lastActivity ?? now, begun: seenIdle.contains(key))
                            busyMarks[key] = mark
                            return mark
                        }()
                        if let reply = summary.replied, reply > mark.mark, let preview = summary.preview {
                            workingNote = TabsNote.line(preview)
                        }
                        workingSince = mark.begun ? mark.mark : nil
                    } else {
                        busyMarks[key] = nil
                        seenIdle.insert(key)
                    }
                }
                let conversation = binding.session.isEmpty ? nil : binding.session
                var unread = false
                if let conversation, !stale {
                    let latest = summary.replied.map(Self.milliseconds)
                    if let seen = markers.seen(host: host.id, conversation: conversation) {
                        if let latest, summary.preview != nil { unread = latest > seen && summary.finished }
                    } else if let latest, summary.preview != nil {
                        if let baseline = baselines[host.id], latest > Self.milliseconds(baseline) {
                            // Written while this phone was away from the host: news, not the baseline.
                            unread = summary.finished
                        } else {
                            // First sight of this conversation on this phone: what it already holds is the baseline.
                            markers.markSeen(host: host.id, conversation: conversation, through: latest)
                        }
                    } else if Self.saidNothing(fetched: fetched, session: session) {
                        // A conversation known to have said nothing yet (just started, or after /clear): whatever it
                        // says next is news. Not a row whose summary has not been read yet.
                        markers.markSeen(host: host.id, conversation: conversation, through: 0)
                    }
                }
                // As the Mac's PaneUrgency: the turn runs. Subagents left running after it ended do not hold back
                // its unseen result.
                rows.append(ChatConversation(
                    key: key, terminal: node.id, hostName: host.name, name: Self.name(tab: tab ?? node, title: summary.title, agent: session?.agentKey ?? TerminalTab.agent(named: [
                        binding.executable.map { URL(fileURLWithPath: $0).lastPathComponent }, node.name, (tab ?? node).name])), space: space?.name,
                    spaceNode: space?.id, cwd: node.cwd, binding: binding, summary: summary,
                    urgency: PaneUrgency(waiting: summary.needsYou, working: summary.busy, unread: unread),
                    muted: markers.muted(host: host.id, node: node.key), unread: unread, stale: stale,
                    since: firstSeen[key] ?? now, workingNote: workingNote, workingSince: workingSince))
            }
        }
        rows.sort {
            ($0.order, $0.hostName, $0.key.node) > ($1.order, $1.hostName, $1.key.node)
        }
        if rows != conversations {
            let previous = conversations
            conversations = rows
            if let arrived { Self.arrivals(from: previous, to: rows, hosts: hosts).forEach { arrived($0.0, $0.1) } }
            rowsChanged?()
        }
    }

    /// The live rows that changed between two builds: a summary that differs, or a row gone from a host that is still
    /// connected and live. A stale row on either side is not compared.
    static func arrivals(from previous: [ChatConversation], to rows: [ChatConversation],
                         hosts: [UUID: ChatHostSnapshot]) -> [(ChatConversation, ChatConversation?)] {
        let current = Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return previous.filter { !$0.stale }.compactMap { before in
            if let now = current[before.key] {
                return !now.stale && now.summary != before.summary ? (before, now) : nil
            }
            // Gone means its agent left the terminal (or the terminal closed), not a detached tab.
            guard let host = hosts[before.key.host], host.link == .connected, host.live,
                  host.topology?.nodes.contains(where: { $0.key == before.key.node && $0.agent != nil }) == false else { return nil }
            return (before, nil)
        }
    }

    /// A row's name as the Mac's automatic tab names give it (ContainerTab.displayLabel): a renamed tab's own name, else
    /// the conversation's title, else the tab's, the agent's (`agent`) for a window named after the launcher. A tab the
    /// phone's launch named after its agent is not renamed (`TerminalTab.named`).
    static func name(tab: HelperTopology.Node, title: String?, agent: String? = nil) -> String {
        guard !TerminalTab.named(tab.name, renamed: tab.renamed == true, agent: agent) else { return tab.name }
        return TerminalTab.conversationLabel(title) ?? TerminalTab.shown(tab.name, agent: agent)
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
