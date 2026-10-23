import Foundation

/// What the phone pushes as its application context (`WCSession.updateApplicationContext`): its hosts, the Agents rows
/// and the Spaces tree, as the phone shows them now. Latest wins; the system keeps the last one for the watch app's next
/// launch. No transcript is in it (threads are requests), and every text is clipped (`WatchLimits`), so it stays far
/// under the context's payload limit (`WatchCodec.snapshot(_:)` enforces `WatchLimits.snapshotBytes`).
///
/// Built by the phone's `WatchBridge` from `MobileComposition` (its `hosts`, `conversations` and `tabs`) on every sync
/// whose result differs from the last one pushed (docs/watch.md, When the phone pushes).
struct WatchSnapshot: Codable, Equatable, Sendable {
    var version = WatchProtocol.version
    /// When the phone built it: the watch says "Updated 12 min ago" from this, and drops a context older than what it
    /// already shows.
    var generated: Date
    var phone: WatchPhone
    /// In the user's order (`HostSessions.ordered`, `HostRecord.order`).
    var hosts: [WatchHost]
    /// The Agents rows (`ChatConversations.conversations`), in the phone's order: newest activity first.
    var conversations: [WatchConversation]
    /// Every host's spaces in the phone's order (`MobileTabs.orderedSpaces`).
    var spaces: [WatchSpace]
    /// Every space's tabs in server order (`MobileSpace.tabs`).
    var tabs: [WatchTab]
    /// The phone left rows out to fit `WatchLimits.snapshotBytes` (the oldest conversations and tabs go first).
    var truncated = false
    /// Reviews the phone sent whose undo window is still open (`WatchReviewEvents`), newest last: the watch shows the
    /// latest with Undo until its deadline.
    var reviews: [WatchReviewSent] = []

    init(generated: Date, phone: WatchPhone, hosts: [WatchHost], conversations: [WatchConversation] = [],
         spaces: [WatchSpace] = [], tabs: [WatchTab] = [], truncated: Bool = false, reviews: [WatchReviewSent] = []) {
        self.generated = generated
        self.phone = phone
        self.hosts = hosts
        self.conversations = conversations
        self.spaces = spaces
        self.tabs = tabs
        self.truncated = truncated
        self.reviews = reviews
    }

    private enum CodingKeys: String, CodingKey {
        case version, generated, phone, hosts, conversations, spaces, tabs, truncated, reviews
    }

    /// Lists decode per entry: one row a newer phone wrote differently drops that row, not the snapshot.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? WatchProtocol.version
        generated = try values.decode(Date.self, forKey: .generated)
        phone = (try? values.decodeIfPresent(WatchPhone.self, forKey: .phone)) ?? WatchPhone()
        hosts = values.watchList(WatchHost.self, forKey: .hosts)
        conversations = values.watchList(WatchConversation.self, forKey: .conversations)
        spaces = values.watchList(WatchSpace.self, forKey: .spaces)
        tabs = values.watchList(WatchTab.self, forKey: .tabs)
        truncated = (try? values.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        reviews = values.watchList(WatchReviewSent.self, forKey: .reviews)
    }
}

/// The phone app's own state, for the watch's banners.
struct WatchPhone: Codable, Equatable, Sendable {
    /// The phone's scene is active (`ScenePhase.active`): its hosts are connected or connecting, and requests are
    /// served at once. In the background a request connects the host it needs first (docs/watch.md, Background).
    var foreground = false
    /// Protected data is unavailable (`UIApplication.isProtectedDataAvailable` false): the phone is locked. Information
    /// only: passwords read after first unlock, so a locked phone still connects a password host (a Face ID key host is
    /// `WatchHostBlock.faceID` either way).
    var locked = false
    /// The phone has no usable network (`HostSessions.networkUnavailable`).
    var offline = false
    /// The trusted host keys cannot be read (`KnownHostStore.unreadable`): nothing connects until the user acts on the
    /// phone (Spaces' notice).
    var knownHostsUnreadable = false
    /// Conversations waiting for the user across hosts, muted ones included (`ChatConversations.needsYouCount`, the
    /// phone's back pill): the watch's badge.
    var needsYou = 0

    init(foreground: Bool = false, locked: Bool = false, offline: Bool = false, knownHostsUnreadable: Bool = false,
         needsYou: Int = 0) {
        self.foreground = foreground
        self.locked = locked
        self.offline = offline
        self.knownHostsUnreadable = knownHostsUnreadable
        self.needsYou = needsYou
    }

    private enum CodingKeys: String, CodingKey { case foreground, locked, offline, knownHostsUnreadable, needsYou }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        foreground = (try? values.decodeIfPresent(Bool.self, forKey: .foreground)) ?? false
        locked = (try? values.decodeIfPresent(Bool.self, forKey: .locked)) ?? false
        offline = (try? values.decodeIfPresent(Bool.self, forKey: .offline)) ?? false
        knownHostsUnreadable = (try? values.decodeIfPresent(Bool.self, forKey: .knownHostsUnreadable)) ?? false
        needsYou = (try? values.decodeIfPresent(Int.self, forKey: .needsYou)) ?? 0
    }
}

/// A host's connection as Spaces shows it (`SpacesHostState`, from `HostLink`).
enum WatchHostState: String, WatchTolerantValue {
    case connected
    /// Connecting, authenticating, starting the helper or reconnecting (`HostLink.isPending`).
    case connecting
    /// Disconnected or failed: the last-known spaces and agents stay listed.
    case offline
    case unknown
}

/// Why a host cannot connect without the phone's screen (docs/watch.md, Background): the watch says "Open Dispatch on
/// your iPhone" (or "Unlock your iPhone") for it instead of retrying.
enum WatchHostBlock: String, WatchTolerantValue {
    /// Its key is behind Face ID (`KeyProtection.biometry`, a Secure Enclave key): a background connection cannot
    /// prompt (`interactionNotAllowed`).
    case faceID
    /// Its host key has not been trusted yet (`HostTrustRequest.Kind.unknown`).
    case trustHostKey
    /// Its host key changed (`HostSession.hostKeyMismatch`): a hard stop until Remove and retry.
    case hostKeyChanged
    /// It asks a keyboard-interactive question (`HostLoginPrompt`).
    case login
    /// Reserved: phone builds before passwords read after first unlock sent it for every host while locked; current
    /// ones never do.
    case phoneLocked
    case unknown
}

/// One host (`HostSession`, `HostRecord`, `TabsHost`).
struct WatchHost: Codable, Equatable, Sendable, Identifiable {
    /// `HostRecord.id.uuidString`: every conversation, space and tab names its host by it.
    var id: String
    var name: String
    /// The user's order (`HostRecord.order`).
    var order: Int
    var state: WatchHostState
    /// The host's colour as the phone draws it in dark mode (`HostSummary.tint`, `HostTint.color`), as `#RRGGBB` sRGB:
    /// the watch has no HostTint (OKLCH, the colour store) and is always dark. Nil: draw grey.
    var tint: String?
    /// The glyph's system (`HostSystem`): "macos" or "linux"; nil before the host was reached.
    var system: String?
    /// "macOS 26.1", "Ubuntu 24.04" (`HostSummary.osLabel`), for the host's detail line.
    var osLabel: String?
    /// Why it is not connected (`HostSession.problem`, or the failure of a `.failed` link), as the phone words it.
    var problem: String?
    /// Set when only the phone's screen can connect it.
    var blocked: WatchHostBlock?
    /// The host's Chat switch (`HostRecord.chat`): off, its agents are plain terminals and it has no conversations.
    var chat: Bool
    /// The rows are this connection's (`TabsHost.live`, `HostSession.topologyIsLive`); false: last-known, shown dimmed.
    var live: Bool
    /// "tmux" or "herdr" (`HostSession.spacesMultiplexer`).
    var multiplexer: String?
    /// The earlier host that reaches the same machine and account (`MobileComposition.sameMachine`): its spaces and
    /// agents show there, and this one says "Same machine as …".
    var sameMachine: String?
    /// When the phone last reached it (`HostRecord.lastConnected`), for "Last connected 2h ago" while offline.
    var lastConnected: Date?
    /// The helper's round trip in milliseconds while connected (`HostSession.latency`, the `echo` probe): "18 ms".
    var latency: Double?
    /// Since when it is not connected, for "Offline since 2:02 PM" (the last connection's time); nil while connected.
    var offlineSince: Date?
    /// Its load, memory and disk with the last 15 minutes of CPU (`WatchStatsSource`); kept while offline (last-known,
    /// drawn dimmed). Nil when the phone has none.
    var stats: WatchHostStats?

    init(id: String, name: String, order: Int, state: WatchHostState, tint: String? = nil, system: String? = nil,
         osLabel: String? = nil, problem: String? = nil, blocked: WatchHostBlock? = nil, chat: Bool = true, live: Bool = true,
         multiplexer: String? = nil, sameMachine: String? = nil, lastConnected: Date? = nil, latency: Double? = nil,
         offlineSince: Date? = nil, stats: WatchHostStats? = nil) {
        self.id = id
        self.name = name
        self.order = order
        self.state = state
        self.tint = tint
        self.system = system
        self.osLabel = osLabel
        self.problem = problem
        self.blocked = blocked
        self.chat = chat
        self.live = live
        self.multiplexer = multiplexer
        self.sameMachine = sameMachine
        self.lastConnected = lastConnected
        self.latency = latency
        self.offlineSince = offlineSince
        self.stats = stats
    }

    /// Shown dimmed: not connected, or its rows are not this connection's yet.
    var stale: Bool { state != .connected || !live }
}

/// The gutter dot (`MobileRowDot`, `ChatConversation.dot`): blue unread for needs you or a result not yet seen, amber
/// working; nil idle or read.
enum WatchDot: String, WatchTolerantValue {
    case working, unread, unknown
}

/// One Agents row (`ChatConversation`, Mobile/Agents/ChatConversations.swift).
struct WatchConversation: Codable, Equatable, Sendable, Identifiable {
    var host: String
    /// The terminal's topology key (`ChatConversationKey.node`).
    var node: String
    /// The row's name (`ChatConversation.name`: a renamed tab's name, else the conversation's title, else the tab's).
    var name: String
    /// The space it runs in (`ChatConversation.space`), for "claude in app".
    var space: String?
    /// The tab holding it (`TabRef.key`), so Spaces can mark the tab and a tab can open its thread.
    var tab: String?
    /// The agent ("claude", "codex", "pi") when the phone knows it (`MobileChatSession.agentKey`, else the binding's
    /// executable's name), for the glyph.
    var agent: String?
    /// The newest agent message, flattened and clipped to `WatchLimits.preview` (`ChatConversationSummary.preview`).
    var preview: String?
    /// The agent's own attention line, when it waits on something only the terminal can answer
    /// (`ChatConversationSummary.attention`).
    var attention: String?
    var dot: WatchDot?
    /// An open approval or question, or the agent's attention (`ChatConversationSummary.needsYou`): the row shows
    /// "Needs you" and Agents' filter keeps it.
    var needsYou: Bool
    /// A turn runs (`ChatConversationSummary.busy`).
    var busy: Bool
    /// Muted on the phone (`ChatConversation.muted`): only needs you shows a dot.
    var muted: Bool
    /// When its newest record was written (`ChatConversationSummary.lastActivity`): the row's time and the sort.
    var lastActivity: Date?
    /// Last-known data (`ChatConversation.stale`): the row dims its time.
    var stale: Bool
    /// The conversation's own title (`MobileChatSession.title`, else `ChatConversationSummary.title`), when the agent
    /// named it: the watch's row and thread title (`displayTitle`); `name`, the row's automatic name, otherwise.
    var title: String?
    /// While working: the current step as the phone's working row names it ("Editing Sidebar.tsx", "Running cargo
    /// test"), else the agent's activity word; nil when the phone has not opened the conversation.
    var step: String?
    /// When the running turn started (the phone's working clock), for "· 48s".
    var workingSince: Date?
    /// While it needs you: what it asks ("Allow cargo test --workspace?", the question's text), else its attention line.
    var waitingText: String?

    init(host: String, node: String, name: String, space: String? = nil, tab: String? = nil, agent: String? = nil,
         preview: String? = nil, attention: String? = nil, dot: WatchDot? = nil, needsYou: Bool = false, busy: Bool = false,
         muted: Bool = false, lastActivity: Date? = nil, stale: Bool = false, title: String? = nil, step: String? = nil,
         workingSince: Date? = nil, waitingText: String? = nil) {
        self.host = host
        self.node = node
        self.name = name
        self.space = space
        self.tab = tab
        self.agent = agent
        self.preview = preview
        self.attention = attention
        self.dot = dot
        self.needsYou = needsYou
        self.busy = busy
        self.muted = muted
        self.lastActivity = lastActivity
        self.stale = stale
        self.title = title
        self.step = step
        self.workingSince = workingSince
        self.waitingText = waitingText
    }

    var key: WatchConversationKey { WatchConversationKey(host: host, node: node) }
    var id: WatchConversationKey { key }

    /// What the watch titles it by: the conversation's own title, else the row's name (the tab's).
    var displayTitle: String { title?.isEmpty == false ? title! : name }
}

/// One space (`MobileSpace`, `SpacesSpaceRow`): a tmux session or a herdr workspace.
struct WatchSpace: Codable, Equatable, Sendable, Identifiable {
    var host: String
    /// Its topology key (`SpaceRef.key`).
    var key: String
    var name: String
    /// Its folder, `~`-shortened by the host's homes (`HomePath.abbreviate`, `MobileSpace.cwd`).
    var folder: String?
    /// Its tabs that need you or hold an unseen result (`SpacesSpaceRow.unread`).
    var unread: Int
    /// One of its tabs is working (`SpacesSpaceRow.working`).
    var working: Bool
    /// Its latest tab's time (`MobileTabs.activity(of:)`).
    var activity: Date?

    init(host: String, key: String, name: String, folder: String? = nil, unread: Int = 0, working: Bool = false,
         activity: Date? = nil) {
        self.host = host
        self.key = key
        self.name = name
        self.folder = folder
        self.unread = unread
        self.working = working
        self.activity = activity
    }

    var id: String { host + "/" + key }
}

/// How much a tab wants attention (`TabUrgency`, Mobile/Tabs/TabsQuery.swift).
enum WatchUrgency: String, WatchTolerantValue {
    case unseen, working, needsYou, unknown

    /// The row's dot: blue for needs you and an unseen result, amber working.
    var dot: WatchDot { self == .working ? .working : .unread }
}

/// One tab (`MobileTab`, `TabsEntry`): a tmux window or a herdr tab.
struct WatchTab: Codable, Equatable, Sendable, Identifiable {
    var host: String
    /// Its space's key (`WatchSpace.key`).
    var space: String
    /// Its topology key (`TabRef.key`).
    var key: String
    /// The name it shows (`MobileTabs.label(of:)`: automatic tab names, the agent's title).
    var name: String
    /// What runs in it when the server names it (`MobileTab.program`).
    var program: String?
    /// Its active pane's folder, `~`-shortened (`MobileTab.cwd`).
    var folder: String?
    /// A chat tab (`MobileTab.isChat`): the speech-bubble glyph.
    var chat: Bool
    /// The agent's name for the glyph, as `WatchConversation.agent`.
    var agent: String?
    /// The agent pane's topology key (`MobileTab.agentPane.key`): tapping the tab opens this conversation's thread.
    var conversation: String?
    var urgency: WatchUrgency?
    /// Line two of the row (`TabsTabLine.line` of `MobileComposition.status`'s words: "Editing Sidebar.tsx", "Allow cargo
    /// test --workspace?", the last message; never a ticking time), clipped to `WatchLimits.line`.
    var status: String?
    /// Its time (`MobileTabs.activity(of:)`).
    var activity: Date?

    init(host: String, space: String, key: String, name: String, program: String? = nil, folder: String? = nil,
         chat: Bool = false, agent: String? = nil, conversation: String? = nil, urgency: WatchUrgency? = nil,
         status: String? = nil, activity: Date? = nil) {
        self.host = host
        self.space = space
        self.key = key
        self.name = name
        self.program = program
        self.folder = folder
        self.chat = chat
        self.agent = agent
        self.conversation = conversation
        self.urgency = urgency
        self.status = status
        self.activity = activity
    }

    var id: String { host + "/" + key }

    /// The thread a tap opens, for a tab bound to an agent.
    var conversationKey: WatchConversationKey? { conversation.map { WatchConversationKey(host: host, node: $0) } }
}

/// A host's statistics as the phone's host strip shows them (CPU %, memory used, disk free, the 15-minute CPU line).
/// Every field optional: a host or a phone build that reports less leaves it out.
struct WatchHostStats: Codable, Equatable, Sendable {
    /// What the phone flags as high (its strip draws the value red).
    enum Warning: String, WatchTolerantValue {
        case cpu, memory, disk, unknown
    }

    /// Buckets of `history`: 60 of 15 s, the last 15 minutes.
    static let historyCount = 60
    static let historyInterval: TimeInterval = 15

    /// CPU use across all cores, 0 to 100.
    var cpu: Double?
    /// The one-minute load average.
    var load: Double?
    /// Bytes.
    var memoryUsed: Int64?
    var memoryTotal: Int64?
    var diskFree: Int64?
    var diskTotal: Int64?
    var warnings: [Warning]
    /// CPU % per 15 s bucket (its peak), oldest first, at most `historyCount`; nil where no sample came (a gap).
    var history: [Double?]
    /// When the newest sample was taken.
    var sampled: Date?
    /// The numbers are not current: the host's link dropped, the phone is in the background (it samples only in the
    /// foreground) or a new connection's first sample is not in yet (`HostStatistics.stale`). Sent only when true.
    var stale: Bool

    init(cpu: Double? = nil, load: Double? = nil, memoryUsed: Int64? = nil, memoryTotal: Int64? = nil, diskFree: Int64? = nil,
         diskTotal: Int64? = nil, warnings: [Warning] = [], history: [Double?] = [], sampled: Date? = nil, stale: Bool = false) {
        self.cpu = cpu
        self.load = load
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.warnings = warnings
        self.history = history
        self.sampled = sampled
        self.stale = stale
    }

    /// The highest bucket of `history` ("peak 82%").
    var peak: Double? { history.compactMap { $0 }.max() }

    private enum CodingKeys: String, CodingKey {
        case cpu, load, memoryUsed, memoryTotal, diskFree, diskTotal, warnings, history, sampled, stale
    }

    /// A gap travels as -1: a property list has no null.
    private static let gap = -1.0

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cpu = try? values.decodeIfPresent(Double.self, forKey: .cpu)
        load = try? values.decodeIfPresent(Double.self, forKey: .load)
        memoryUsed = try? values.decodeIfPresent(Int64.self, forKey: .memoryUsed)
        memoryTotal = try? values.decodeIfPresent(Int64.self, forKey: .memoryTotal)
        diskFree = try? values.decodeIfPresent(Int64.self, forKey: .diskFree)
        diskTotal = try? values.decodeIfPresent(Int64.self, forKey: .diskTotal)
        warnings = values.watchList(Warning.self, forKey: .warnings)
        history = ((try? values.decodeIfPresent([Double].self, forKey: .history)) ?? []).map { $0 < 0 ? nil : $0 }
        sampled = try? values.decodeIfPresent(Date.self, forKey: .sampled)
        stale = (try? values.decodeIfPresent(Bool.self, forKey: .stale)) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(cpu, forKey: .cpu)
        try values.encodeIfPresent(load, forKey: .load)
        try values.encodeIfPresent(memoryUsed, forKey: .memoryUsed)
        try values.encodeIfPresent(memoryTotal, forKey: .memoryTotal)
        try values.encodeIfPresent(diskFree, forKey: .diskFree)
        try values.encodeIfPresent(diskTotal, forKey: .diskTotal)
        if !warnings.isEmpty { try values.encode(warnings, forKey: .warnings) }
        if !history.isEmpty { try values.encode(history.map { $0 ?? Self.gap }, forKey: .history) }
        try values.encodeIfPresent(sampled, forKey: .sampled)
        if stale { try values.encode(true, forKey: .stale) }
    }
}

/// A review the phone just sent to an agent (the Review tab's Send), mirrored on the wrist with Undo until `undoUntil`
/// (`WatchReviewEvents` on the phone).
struct WatchReviewSent: Codable, Equatable, Sendable, Identifiable {
    /// The phone's event id: what `undoReview` names.
    var id: String
    var host: String
    /// The conversation it went to (`WatchConversationKey.node`).
    var node: String
    /// "claude", "codex", "pi": the glyph and "then claude reads it".
    var agent: String?
    /// The conversation's name, as its Agents row says it.
    var title: String
    var comments: Int
    var files: Int
    var sent: Date
    /// Until when Undo takes it back; after it the agent has it.
    var undoUntil: Date

    init(id: String, host: String, node: String, agent: String? = nil, title: String, comments: Int, files: Int, sent: Date,
         undoUntil: Date) {
        self.id = id
        self.host = host
        self.node = node
        self.agent = agent
        self.title = title
        self.comments = comments
        self.files = files
        self.sent = sent
        self.undoUntil = undoUntil
    }

    var key: WatchConversationKey { WatchConversationKey(host: host, node: node) }

    /// Undo still takes it back at `date`.
    func undoable(at date: Date) -> Bool { date < undoUntil }
}

extension KeyedDecodingContainer {
    /// A list whose entries decode one by one: an entry that does not decode is left out.
    func watchList<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard var list = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !list.isAtEnd {
            if let value = try? list.decode(T.self) {
                result.append(value)
            } else if (try? list.decode(WatchSkipped.self)) == nil {
                break
            }
        }
        return result
    }
}

/// Consumes one entry of any shape (`watchList` skips what it cannot read).
private struct WatchSkipped: Decodable {
    init(from decoder: any Decoder) throws {}
}
