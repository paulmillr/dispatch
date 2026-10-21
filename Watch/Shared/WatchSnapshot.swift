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

    init(generated: Date, phone: WatchPhone, hosts: [WatchHost], conversations: [WatchConversation] = [],
         spaces: [WatchSpace] = [], tabs: [WatchTab] = [], truncated: Bool = false) {
        self.generated = generated
        self.phone = phone
        self.hosts = hosts
        self.conversations = conversations
        self.spaces = spaces
        self.tabs = tabs
        self.truncated = truncated
    }

    private enum CodingKeys: String, CodingKey { case version, generated, phone, hosts, conversations, spaces, tabs, truncated }

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

    init(id: String, name: String, order: Int, state: WatchHostState, tint: String? = nil, system: String? = nil,
         osLabel: String? = nil, problem: String? = nil, blocked: WatchHostBlock? = nil, chat: Bool = true, live: Bool = true,
         multiplexer: String? = nil, sameMachine: String? = nil, lastConnected: Date? = nil) {
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

    init(host: String, node: String, name: String, space: String? = nil, tab: String? = nil, agent: String? = nil,
         preview: String? = nil, attention: String? = nil, dot: WatchDot? = nil, needsYou: Bool = false, busy: Bool = false,
         muted: Bool = false, lastActivity: Date? = nil, stale: Bool = false) {
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
    }

    var key: WatchConversationKey { WatchConversationKey(host: host, node: node) }
    var id: WatchConversationKey { key }
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
    /// Line two of the row (`MobileComposition.status`: "opus-5.5 · needs you"), clipped to `WatchLimits.line`.
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
