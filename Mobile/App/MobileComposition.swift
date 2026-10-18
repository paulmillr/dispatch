import SwiftUI

/// The composition root (docs/ios.md, Architecture and data flow): one `HostSessions` feeds every area. On each change
/// of a host session (its record, link, client, hello, topology, followed multiplexer) the Spaces model
/// (`MobileTabs.sync`) and the conversation list (`ChatConversations.update`) get that host's new input in the same
/// main-actor turn; Chat's urgency and status flow back into the Spaces rows; terminal presences stop when a host's
/// client goes away and reattach on the next connection; Pi's optional integration is re-enabled on each connection.
/// Resilience (docs/ios.md): the last-known state of every host is restored from `HostCache` before the first frame and
/// kept current from the live data; a network change retries every session; the background refresh and its
/// notifications; Settings.
@MainActor
final class MobileComposition {
    let hosts: HostSessions
    let tabs: MobileTabs
    let conversations: ChatConversations
    let presences: TerminalPresences
    let navigator: SpacesNavigator
    let cache: HostCache
    let settings: MobileSettings
    /// New chat's and the threads' last agent, model and effort (`chat-models.json`).
    let modelMemory: ChatModelMemory
    /// Set by `app()`; tests make their own.
    var refresh: BackgroundRefresh?
    var network: NetworkPathWatcher?
    /// Spaces and Agents see a Chat-off host's topology without agents.
    private let topologies = HostTopologies()
    /// What was last handed to the areas per host; an unchanged host is not synced again (latency ticks).
    private var synced: [UUID: Signature] = [:]
    /// False only for the Debug Spaces sample, whose hosts are not sessions.
    private let feedsTabs: Bool
    /// A conversation New chat started: its thread opens with the keyboard up (M3b).
    private var focusing: ChatConversationKey?
    /// The client each host's presences last reattached through (once per connection, on its first live topology).
    private var reattached: [UUID: ObjectIdentifier] = [:]

    init(hosts: HostSessions, tabs: MobileTabs = MobileTabs(), presences: TerminalPresences = .shared,
         markers: ChatMarkers = .shared, outbox: ChatOutbox = .shared, drafts: ChatDraftRepository = .shared,
         cache: HostCache = HostCache(url: nil), settings: MobileSettings = MobileSettings(), modelMemory: ChatModelMemory = .shared,
         feedsTabs: Bool = true) {
        self.hosts = hosts
        self.tabs = tabs
        self.presences = presences
        self.cache = cache
        self.settings = settings
        self.modelMemory = modelMemory
        self.feedsTabs = feedsTabs
        conversations = ChatConversations(presence: TerminalChatPresence(presences: presences), markers: markers,
                                          outbox: outbox, drafts: drafts)
        navigator = SpacesNavigator(model: tabs)
        restore()
        wire()
        sync()
    }

    /// Every saved host's last-known state from the cache, before the first frame: Spaces and Agents are populated at
    /// once (their rows dim their times until live data arrives) and reconcile in place.
    private func restore() {
        for session in hosts.ordered {
            guard let entry = cache.entry(session.id) else { continue }
            conversations.restore(host: session.id, summaries: entry.conversations.mapValues(\.summary))
            session.restore(hello: entry.hello, multiplexers: entry.multiplexers.map(\.multiplexer), versions: entry.versions,
                            following: entry.following, topology: entry.topology)
        }
    }

    private func wire() {
        hosts.changed = { [weak self] in self?.sync() }
        conversations.rowsChanged = { [weak self] in self?.cacheConversations() }
        NotificationRoute.shared.open = { [weak self] key in self?.openChat(key, keyboard: false) }
        let presences = presences
        hosts.clientEnded = { session in presences.stopAll(host: session.id) }
        hosts.postConnect = [Self.enablePi]
        let conversations = conversations
        // The Debug Spaces sample brings its own urgency and lines (M2a's dots and "thinking 48s", the back pill's
        // count); its hosts are not sessions, so Chat has nothing to say about them.
        if feedsTabs { wireTabs(conversations) }
    }

    private func wireTabs(_ conversations: ChatConversations) {
        tabs.urgency = { host, terminal in
            guard let key = conversations.key(host: host, terminal: terminal),
                  let row = conversations.conversations.first(where: { $0.key == key }) else { return nil }
            return TabUrgency(row)
        }
        tabs.status = { host, terminal in
            guard let key = conversations.key(host: host, terminal: terminal),
                  let row = conversations.conversations.first(where: { $0.key == key }) else { return nil }
            return Self.status(row, session: conversations.sessions[key])
        }
        let tabs = tabs
        tabs.needsYouCount = { excluding in
            let here = excluding.flatMap { tabs.tab($0) }.map { tabs.urgency(of: $0) == .needsYou } ?? false
            return max(0, conversations.needsYouCount - (here ? 1 : 0))
        }
    }

    private struct Signature: Equatable {
        let record: HostRecord
        let link: HostLink
        let client: ObjectIdentifier?
        let topology: HelperTopology?
        let live: Bool
        let features: [String]
        let following: String?
        let home: String?
    }

    /// Hands every host's current state to Spaces and Agents (cheap when nothing changed).
    func sync() {
        let sessions = hosts.ordered
        var inputs: [TabsHostInput] = []
        var changed = false
        for session in sessions {
            let signature = Signature(record: session.host, link: session.link, client: session.client.map(ObjectIdentifier.init),
                                      topology: session.topology, live: session.topologyIsLive,
                                      features: session.hello?.features ?? [],
                                      following: session.following, home: session.hello?.account?.home)
            if synced[session.id] != signature {
                synced[session.id] = signature
                changed = true
                conversations.update(snapshot(session))
                cache.record(session)
                if let client = session.client, session.topologyIsLive {
                    // The connection's first live topology: the host's presences attach again by topology key (a stale
                    // snapshot's node ids are another helper's).
                    if reattached[session.id] != ObjectIdentifier(client) {
                        reattached[session.id] = ObjectIdentifier(client)
                        reattach(session, client: client)
                    }
                    // A terminal the live topology no longer names (its pane or window closed) keeps no presence: nothing
                    // else ever closes one, and each holds an attachment, a parse task and a render thread.
                    let keeping = Set(session.topology?.nodes.filter { $0.kind == .terminal }.map(\.key) ?? [])
                    presences.prune(host: session.id, keeping: keeping)
                } else if session.client == nil {
                    reattached[session.id] = nil
                }
            }
            inputs.append(input(session))
        }
        let ids = Set(sessions.map(\.id))
        for id in synced.keys where !ids.contains(id) {
            synced[id] = nil
            reattached[id] = nil
            conversations.remove(host: id)
            presences.closeAll(host: id)
            tabs.dropHost(id)
            topologies.forget(id)
            cache.remove(host: id)
            changed = true
        }
        if feedsTabs, changed || tabs.workspaces.count != inputs.count { tabs.sync(inputs) }
    }

    /// The live rows of connected hosts go to the cache (offline rows are the cache's own).
    private func cacheConversations() {
        for session in hosts.ordered where session.link.isConnected {
            let present = Set(topologies.topology(session)?.nodes.map(\.key) ?? [])
            cache.record(conversations: conversations.liveSummaries(host: session.id), present: present, host: session.id)
        }
    }

    /// The app's: the saved hosts over SSH with the cache in the app container, or in Debug the Spaces sample
    /// (`-DispatchTabsSample YES`). Live UI test runs (`DISPATCH_MOBILE_STORE=memory`) and the scripted demo keep the
    /// cache in memory.
    static func app(environment: [String: String] = ProcessInfo.processInfo.environment) -> MobileComposition {
        let hosts = HostSessions.app()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "DispatchTabsSample") {
            return MobileComposition(hosts: hosts, tabs: TabsSample.model(), feedsTabs: false)
        }
        let saving = environment["DISPATCH_MOBILE_STORE"] != "memory" && (environment["DISPATCH_MOBILE_SCRIPTED"] ?? "0") == "0"
        #else
        let saving = true
        #endif
        let composition = MobileComposition(hosts: hosts, cache: HostCache(url: saving ? HostCache.file : nil))
        composition.refresh = BackgroundRefresh(
            notifier: SystemNotifier(), settings: composition.settings, cache: composition.cache,
            markers: composition.conversations.markers, hosts: { [weak hosts] in hosts?.store.hosts ?? [] },
            source: HostSessionsRefreshSource(hosts: hosts))
        let network = NetworkPathWatcher { [weak hosts] in hosts?.networkChanged() }
        network.start()
        composition.network = network
        return composition
    }

    /// The scene's phase: the sessions connect or disconnect; going to the background writes the cache and asks for the
    /// next background refresh.
    func scenePhaseChanged(_ phase: ScenePhase) {
        hosts.scenePhaseChanged(phase)
        if phase == .background {
            cache.flush()
            refresh?.schedule()
        }
    }

    /// The app refresh task (`BGAppRefreshTask`, docs/ios.md, Background refresh).
    func backgroundRefresh() async {
        await refresh?.run()
    }

    /// The tab holding a conversation's terminal.
    func tab(for key: ChatConversationKey) -> TabRef? {
        tabs.workspace(key.host)?.tabs.first { $0.panes.contains { $0.key == key.node } }?.ref
    }

    /// Agents' row tap and New chat's Start: the conversation's tab on its Chat segment (with the keyboard up after
    /// Start).
    func openChat(_ key: ChatConversationKey, keyboard: Bool) {
        guard let ref = tab(for: key) else { return }
        if keyboard { focusing = key }
        navigator.openChat(ref)
    }

    /// How Agents draws a host: its tint (gray offline) and glyph, as Spaces does.
    var look: ChatHostLook {
        let hosts = hosts
        return ChatHostLook(
            tint: { id in hosts.session(id).map { HostSummary(session: $0).tint } ?? HostTint(hostID: id.uuidString).color },
            glyph: { id in
                guard let record = hosts.session(id)?.host else { return AnyView(Image(systemName: "display").resizable().scaledToFit()) }
                return AnyView(HostGlyph(host: record, size: MobileRow<HostGlyph>.glyphSize))
            })
    }

    /// What Spaces takes from a host session (its topology without agents when the host's Chat is off).
    func input(_ session: HostSession) -> TabsHostInput {
        var input = Self.input(session)
        input.topology = topologies.topology(session)
        return input
    }

    static func input(_ session: HostSession) -> TabsHostInput {
        let record = session.host
        let host = TabsHost(session)
        let override = record.multiplexer == .automatic ? nil : record.multiplexer.rawValue
        return TabsHostInput(host: host, client: session.client, topology: session.topology,
                             multiplexer: session.following ?? override, features: Set(session.hello?.features ?? []))
    }

    /// What Agents takes from a host session: with Chat off, no agents (the host's conversations are terminals only).
    /// Until the connection's first live topology the client is withheld: the rows are stale and no conversation opens
    /// on node ids of a snapshot from the cache or an earlier helper.
    func snapshot(_ session: HostSession) -> ChatHostSnapshot {
        var snapshot = Self.snapshot(session)
        snapshot.topology = topologies.topology(session)
        return snapshot
    }

    static func snapshot(_ session: HostSession) -> ChatHostSnapshot {
        ChatHostSnapshot(id: session.id, name: session.host.name, link: session.link,
                         client: session.topologyIsLive ? session.client : nil, topology: session.topology,
                         features: Set(session.hello?.features ?? []), live: session.topologyIsLive)
    }

    /// Line two of a chat tab's row: the model and what the agent is doing.
    static func status(_ row: ChatConversation, session: MobileChatSession?) -> String? {
        if let session, session.phase == .verified {
            let model = session.modelLabel ?? session.model
            let doing = session.waitingForUser ? "needs you" : session.working ? (session.activity ?? "working") : nil
            let parts = [model, doing].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if row.summary.attention != nil { return "needs you" }
        if row.summary.busy { return "working" }
        return row.summary.preview
    }

    /// Pi's extension is enabled per helper connection (docs/ios.md, Helper contract): re-enabled on every connection where
    /// Pi and its Dispatch integration are installed. Starting Pi the first time installs it (New chat).
    static let enablePi: HostPostConnectStep = { _, client in
        guard let launches = try? await client.launches(), let pi = launches.first(where: { $0.key == "pi" }) else { return }
        guard let audit: HelperChat.Installation = try? await client.connection.request(
            "installation.audit", params: HelperChat.Setup(launch: pi.launch, enabled: nil, terminal: nil)),
              audit.installed == true else { return }
        let _: HelperChat.Installation? = try? await client.connection.request(
            "installation.install", params: HelperChat.Setup(launch: pi.launch, enabled: true, terminal: nil))
    }

    /// The host's terminal presences attach again through the new connection (a new helper may hand out the same ids).
    private func reattach(_ session: HostSession, client: HelperClient) {
        guard let topology = session.topology else { return }
        presences.reopen(host: session.id, client: client, topology: topology)
    }

    #if DEBUG
    /// The Chat demo's conversations behind the Spaces sample's agent tabs, made on first use (with its helper peer).
    private lazy var sampleChat: (ChatConversations, ChatDemo.Peer) = ChatDemo.conversations(screen: "M4a")
    #endif

    /// The Terminal and Chat segments of a tab (`TabScreen`).
    var content: TabsContent {
        let hosts = hosts, presences = presences, conversations = conversations, tabs = tabs, memory = modelMemory
        #if DEBUG
        // The Spaces sample's hosts are not sessions: its tabs show M6a's dev server so the Terminal segment has a
        // screen (screenshots, the fidelity pairs).
        let sample = !feedsTabs
        #else
        let sample = false
        #endif
        return TabsContent(
            terminal: { tab, pane in
                #if DEBUG
                if sample {
                    let output = Data(String(repeating: "\r\n", count: 60).utf8) + TerminalFixtures.viteDev
                    return AnyView(TerminalSegmentView(feed: ScriptedTerminalFeed(output: output)))
                }
                #endif
                return AnyView(TerminalSegment(hosts: hosts, presences: presences, tab: tab, pane: pane))
            },
            chat: { tab, pane in
                #if DEBUG
                if sample {
                    // The sample's hosts have no conversations: its agent tabs show the Chat demo's M4a thread.
                    let key = ChatConversationKey(host: ChatDemo.host, node: "tmux:s:$0:%0")
                    let space = tabs.workspace(tab.ref.host)?.space(of: tab)?.name ?? tab.name
                    return AnyView(ChatThreadView(session: self.sampleChat.0.session(for: key), space: space, tab: tab.name,
                                                  directory: pane.cwd, homes: HomePath(account: "/Users/alex"), memory: ChatDemo.memory))
                }
                #endif
                let key = ChatConversationKey(host: tab.ref.host, node: pane.key)
                let space = tabs.workspace(tab.ref.host)?.space(of: tab)?.name ?? tab.name
                let focus = self.focusing == key
                if focus { self.focusing = nil }
                // One view per conversation: no state (scroll position, draft field, sheets) carries to another.
                return AnyView(ChatThreadView(session: conversations.session(for: key), space: space, tab: tab.name, directory: pane.cwd,
                                              homes: HomePath(hosts.session(key.host)?.hello), focusOnAppear: focus, seen: { conversations.markSeen(key) }, memory: memory)
                    .id(key))
            },
            terminalSubtitle: { tab, pane in
                // The sample's hosts have no hello: the tab's own folder and program, shortened by the sample's home.
                if sample { return nil }
                let presence = presences.presence(.init(host: tab.ref.host, node: pane.key))
                let homes = HomePath(hosts.session(tab.ref.host)?.hello)
                let text = TerminalSubtitle.text(directory: presence?.directory ?? pane.cwd, shell: tab.program, homes: homes)
                return text.isEmpty ? nil : text
            })
    }

    /// Hosts' screens embedded in Spaces: New host (M8a) and host detail (M1f) with the host's spaces opening in
    /// Spaces.
    var hostViews: SpacesHostViews {
        let hosts = hosts, navigator = navigator
        return SpacesHostViews(
            newHost: { done in hosts.newHostSheet(created: { done($0) }) },
            detail: { id in
                AnyView(hosts.hostDetail(id) { HostSpacesList(session: $0) }.environment(\.hostSpaceOpening, navigator))
            })
    }
}

/// A tab's Terminal segment: its node's presence (shared with Chat), attached through the host's current client.
private struct TerminalSegment: View {
    let hosts: HostSessions
    let presences: TerminalPresences
    let tab: MobileTab
    let pane: MobilePane

    var body: some View {
        let key = TerminalPresences.Key(host: tab.ref.host, node: pane.key)
        // One branch online and offline: a link that drops or comes back keeps the same view (its host view, keyboard
        // and capsule state) showing the same presence.
        if let presence = presence(key) {
            // Attached while on screen (and while a chat needs it); hidden, it keeps its last screen detached.
            TerminalSegmentView(presence: presence).id(key)
                .onAppear { presences.retain(key) }
                .onDisappear { presences.release(key) }
        } else {
            Text("\(hosts.session(tab.ref.host)?.host.name ?? "The host") is offline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// Connected: the node's presence through the host's client; offline, or before the connection's first live
    /// topology (the pane's id may be another helper's): the last screen stays readable.
    private func presence(_ key: TerminalPresences.Key) -> TerminalPresence? {
        guard let session = hosts.session(tab.ref.host), let client = session.client, session.topologyIsLive else {
            return presences.presence(key)
        }
        let node = session.topology?.nodes.first { $0.key == pane.key }
        return presences.open(key, feed: HelperTerminalFeed(client: client, terminal: pane.id), terminal: pane.id, client: client,
                              scrollback: TerminalScrollback(multiplexer: session.following),
                              grid: node?.size.map { (Int($0.columns), Int($0.rows)) })
    }
}

/// Chat's terminal side over the Terminal area's presences: a verified conversation keeps its terminal attached and
/// its screen published (docs/ios.md, Helper contract) as one of the presence's users; its release lets the attachment go
/// unless the Terminal segment shows it.
@MainActor
final class TerminalChatPresence: ChatTerminalPresence {
    let presences: TerminalPresences
    /// The conversations holding a use of their presence (retain may come again with a new id after a reconnect).
    private var holding: Set<ChatConversationKey> = []
    init(presences: TerminalPresences) { self.presences = presences }

    func retain(_ key: ChatConversationKey, terminal: UInt64, client: HelperClient) {
        let node = TerminalPresences.Key(host: key.host, node: key.node)
        // The feed first, so the use attaches through this client and id, never the previous helper's.
        _ = presences.open(node, feed: HelperTerminalFeed(client: client, terminal: terminal), terminal: terminal, client: client)
        if holding.insert(key).inserted { presences.retain(node) }
    }

    func release(_ key: ChatConversationKey) {
        guard holding.remove(key) != nil else { return }
        presences.release(.init(host: key.host, node: key.node))
    }

    func attached(_ key: ChatConversationKey) -> Bool {
        presences.presence(.init(host: key.host, node: key.node))?.attached == true
    }
}

extension TerminalPresences {
    /// The app's presences, shared by the Terminal segments and Chat.
    static let shared = TerminalPresences()

    /// After a reconnect: each of the host's presences in use whose node the new topology names attaches through
    /// `client` (the others take the new feed when they are used again).
    func reopen(host: UUID, client: HelperClient, topology: HelperTopology) {
        for node in topology.nodes where node.kind == .terminal && !node.detached {
            let key = Key(host: host, node: node.key)
            guard presence(key) != nil, inUse(key) else { continue }
            _ = open(key, feed: HelperTerminalFeed(client: client, terminal: node.id), terminal: node.id, client: client)
        }
    }

    /// The host was removed: its presences go.
    func closeAll(host: UUID) {
        for key in keys(host: host) { close(key) }
    }

    /// The host's presences of terminals that are gone (not in `keeping`, the live topology's terminal keys) go.
    func prune(host: UUID, keeping: Set<String>) {
        for key in keys(host: host) where !keeping.contains(key.node) { close(key) }
    }
}

extension TabsHost {
    /// A host session as Spaces draws it: name, tint (gray offline), glyph system, the hello account's home, state, order.
    @MainActor init(_ session: HostSession) {
        let record = session.host
        self.init(id: record.id, name: record.name, tint: HostSummary(session: session).tint, system: record.system,
                  home: session.hello?.account?.home, loginHome: session.hello?.account?.login_home,
                  state: SpacesHostState(session.link), order: record.order, live: session.topologyIsLive)
    }
}

extension TabUrgency {
    /// A conversation's urgency as Spaces shows it: needs you, working and an unseen result; a muted conversation keeps
    /// only needs you (its dot, `ChatConversation.dot`).
    init?(_ row: ChatConversation) {
        switch row.urgency {
        case .waiting: self = .needsYou
        case .running where !row.muted: self = .working
        case .unread where !row.muted: self = .unseen
        default: return nil
        }
    }
}

extension SpacesNavigator: HostSpaceOpening {
    func open(host: UUID, space: UInt64) { openSpace(host: host, node: space) }
}

