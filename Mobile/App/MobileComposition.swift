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
    /// The Apple Watch link (docs/watch.md); nil where WatchConnectivity is unsupported.
    var watch: WatchBridge?
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
         feedsTabs: Bool = true, splitMemory: UserDefaults? = nil) {
        self.hosts = hosts
        self.tabs = tabs
        self.presences = presences
        self.cache = cache
        self.settings = settings
        self.modelMemory = modelMemory
        self.feedsTabs = feedsTabs
        conversations = ChatConversations(presence: TerminalChatPresence(presences: presences), markers: markers,
                                          outbox: outbox, drafts: drafts)
        navigator = SpacesNavigator(model: tabs, memory: splitMemory)
        // Shell tabs keep their presences with the rest (plain SSH).
        hosts.presences = presences
        restore()
        wire()
        sync()
    }

    /// Every saved host's last-known state from the cache, before the first frame: Spaces and Agents are populated at
    /// once (their rows dim their times until live data arrives) and reconcile in place. A plain host's shell tabs come
    /// back as ended cards without a screen.
    private func restore() {
        for session in hosts.ordered {
            guard let entry = cache.entry(session.id) else { continue }
            session.shells.restore(entry.shells)
            conversations.restore(host: session.id, summaries: entry.conversations.mapValues(\.summary))
            session.restore(hello: entry.hello, multiplexers: entry.multiplexers.map(\.multiplexer), versions: entry.versions,
                            following: entry.following, topology: entry.topology, updated: cache.updated(session.id))
        }
    }

    private func wire() {
        hosts.changed = { [weak self] in self?.sync() }
        conversations.rowsChanged = { [weak self] in self?.cacheConversations() }
        NotificationRoute.shared.open = { [weak self] key in self?.openChat(key, keyboard: false) }
        let presences = presences
        hosts.clientEnded = { session in presences.stopAll(host: session.id) }
        hosts.postConnect = [Self.enableIntegrations]
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
        let presences = presences
        tabs.paneTitle = { host, key in presences.presence(.init(host: host, node: key))?.title }
        tabs.conversationTitle = { host, terminal in
            guard let key = conversations.key(host: host, terminal: terminal) else { return nil }
            return conversations.conversations.first { $0.key == key }?.summary.title
        }
        tabs.agentActivity = { host, terminal in
            guard let key = conversations.key(host: host, terminal: terminal) else { return nil }
            return conversations.conversations.first { $0.key == key }?.summary.lastActivity
        }
        let tabs = tabs, hosts = hosts
        tabs.shellSessions = { hosts.session($0)?.shells }
        tabs.updated = { hosts.session($0)?.updated }
        tabs.refresh = { await hosts.refresh() }
        // New space on a multiplexer the host does not show: the host follows it from now on, as Host detail's choice.
        tabs.follow = { id, name in
            guard var record = hosts.session(id)?.host,
                  let preference = HostRecord.MultiplexerPreference(rawValue: name), record.multiplexer != preference else { return }
            record.multiplexer = preference
            hosts.update(record)
        }
        tabs.needsYouCount = { excluding in
            let here = excluding.flatMap { tabs.tab($0) }.map { tabs.urgency(of: $0) == .needsYou } ?? false
            return max(0, conversations.needsYouCount - (here ? 1 : 0))
        }
    }

    private struct Signature: Equatable {
        let record: HostRecord
        let link: HostLink
        let mode: HostSession.Mode?
        let client: ObjectIdentifier?
        let topology: HelperTopology?
        let live: Bool
        let switching: Bool
        let features: [String]
        let following: String?
        let home: String?
        let sameMachine: String?
        let shells: [ShellSessions.ShellTab]
    }

    /// Hosts that reach a machine and account an earlier host in the list already shows (a LAN and a Tailscale address
    /// of one Mac): the Mac keys a host by machine and uid (`HostRegistry`, `ssh:<machine>:<uid>`) and shows it once, so
    /// here the first connected one shows its spaces and agents and the others name it. Host id → that host's name.
    static func sameMachine(_ sessions: [HostSession]) -> [UUID: String] {
        var first: [String: String] = [:], result: [UUID: String] = [:]
        // A plain SSH host's hello is an earlier helper's: it names no machine now.
        for session in sessions where session.link.isConnected && !session.isPlain {
            guard let identity = session.hello?.identity, let account = session.hello?.account else { continue }
            let key = identity.host + ":" + String(account.uid)
            if let name = first[key] { result[session.id] = name } else { first[key] = session.host.name }
        }
        return result
    }

    /// Hands every host's current state to Spaces and Agents (cheap when nothing changed).
    func sync() {
        let sessions = hosts.ordered
        let duplicates = Self.sameMachine(sessions)
        var inputs: [TabsHostInput] = []
        var changed = false
        for session in sessions {
            let sameMachine = duplicates[session.id]
            let signature = Signature(record: session.host, link: session.link, mode: session.mode, client: session.client.map(ObjectIdentifier.init),
                                      topology: session.topology, live: session.topologyIsLive,
                                      switching: session.switchingMultiplexer,
                                      features: session.hello?.features ?? [],
                                      following: session.following, home: session.hello?.account?.home,
                                      sameMachine: sameMachine, shells: session.shells.tabs)
            if synced[session.id] != signature {
                synced[session.id] = signature
                changed = true
                var chat = snapshot(session)
                // The same machine's agents show once, under the host that shows its spaces.
                if sameMachine != nil { chat.topology = nil }
                conversations.update(chat)
                cache.record(session)
                // A dropped link (or going to the background) keeps when the host last answered.
                cache.record(heard: session.updated, host: session.id)
                cache.record(shells: session.shells.entries, host: session.id)
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
                    if let topology = session.topology { presences.serverGrids(host: session.id, topology: topology) }
                } else if session.client == nil {
                    reattached[session.id] = nil
                }
            }
            var host = input(session)
            if let sameMachine {
                host.topology = nil
                host.host.sameMachine = sameMachine
            }
            inputs.append(host)
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
            // `-DispatchSplitMemory YES`: the sample keeps the iPad's shown tab and sidebar too (its relaunch tests).
            let memory = UserDefaults.standard.bool(forKey: "DispatchSplitMemory") ? UserDefaults.standard : nil
            return MobileComposition(hosts: hosts, tabs: TabsSample.model(), feedsTabs: false, splitMemory: memory)
        }
        let saving = environment["DISPATCH_MOBILE_STORE"] != "memory" && (environment["DISPATCH_MOBILE_SCRIPTED"] ?? "0") == "0"
            && !DemoScenario.enabled
        #else
        let saving = true
        #endif
        // The iPad's shown tab and sidebar (`SpacesNavigator.restoreSplit`) are kept where the cache is.
        let composition = MobileComposition(hosts: hosts, cache: HostCache(url: saving ? HostCache.file : nil),
                                            splitMemory: saving ? .standard : nil)
        composition.refresh = BackgroundRefresh(
            notifier: SystemNotifier(), settings: composition.settings, cache: composition.cache,
            markers: composition.conversations.markers, hosts: { [weak hosts] in hosts?.store.hosts ?? [] },
            source: HostSessionsRefreshSource(hosts: hosts))
        let network = NetworkPathWatcher { [weak hosts] in hosts?.networkChanged() }
        network.observed = { [weak hosts] path in hosts?.networkPath(satisfied: path.satisfied) }
        network.start()
        composition.network = network
        // Also in the in-memory and scripted modes, so simulator demos push snapshots.
        composition.watch = WatchBridge.app(composition)
        return composition
    }

    /// The scene's phase: the sessions connect or disconnect; going to the background writes the cache and asks for the
    /// next background refresh.
    func scenePhaseChanged(_ phase: ScenePhase) {
        hosts.scenePhaseChanged(phase)
        watch?.scenePhaseChanged()
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

    /// Every host's last update, for the subtitle under Spaces' flat list and Agents (`HostsSubtitle`).
    var freshness: [HostFreshness] {
        hosts.ordered.map { session in
            HostFreshness(id: session.id, name: session.host.name, tint: HostSummary(session: session).tint,
                          state: SpacesHostState(session.link), updated: session.updated)
        }
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
                             multiplexer: session.following ?? override, features: Set(session.hello?.features ?? []),
                             mode: tabsMode(session), shells: session.shells.tabs)
    }

    /// The mode Spaces lists a host in: its connection's, else plain when the host's Helper switch is off (its next
    /// connection is plain too), else unknown. So while it is not connected a plain host keeps its Shell space, every
    /// card ended; a host that only fell back to plain SSH shows its Shell space only while ended cards are left, until
    /// a connection decides again.
    static func tabsMode(_ session: HostSession) -> HostSession.Mode? {
        session.mode ?? (session.host.helper ? nil : .plain(reason: nil))
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
        ChatHostSnapshot(id: session.id, name: session.host.name, link: session.link, problem: session.problem,
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
        if row.summary.needsYou { return "needs you" }
        if row.summary.busy { return "working" }
        return row.summary.preview
    }

    /// The agents' integrations on every connection, as the Mac's `installHelperIntegrations` does for a newly connected
    /// host: each non-optional one (Claude Code's and Codex's hooks) is installed, so an agent started outside Dispatch
    /// still asks here; an optional one (Pi's extension) is opt-in and only enabled again where it is installed (the
    /// helper keeps that per connection, docs/ios.md, Helper contract). New chat installs it once the user agrees. With
    /// Chat off the grant has no `hooks.configure` and nothing changes.
    static let enableIntegrations: HostPostConnectStep = { session, client in
        guard session.host.chat, let launches = try? await client.launches() else { return }
        for launch in launches {
            guard let audit: HelperChat.Installation = try? await client.connection.request(
                "installation.audit", params: HelperChat.Setup(launch: launch.launch, enabled: nil, terminal: nil)),
                  audit.optional != true || audit.installed == true else { continue }
            let _: HelperChat.Installation? = try? await client.connection.request(
                "installation.install", params: HelperChat.Setup(launch: launch.launch, enabled: true, terminal: nil))
        }
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
        let navigator = navigator
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
                    return AnyView(TerminalSegmentView(feed: ScriptedTerminalFeed.sample(output: output)))
                }
                #endif
                if tab.isShell {
                    return AnyView(ShellSegment(hosts: hosts, presences: presences, navigator: navigator, tab: tab, pane: pane))
                }
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
    /// Spaces: the topology's, then a plain host's Shell space (Tabs' own, no topology names it).
    var hostViews: SpacesHostViews {
        let hosts = hosts, navigator = navigator, tabs = tabs
        return SpacesHostViews(
            newHost: { done in hosts.newHostSheet(created: { done($0) }) },
            detail: { id in
                AnyView(hosts.hostDetail(id, count: { session in
                    HostSummary(session: session).spaces.count + (tabs.workspace(session.id)?.shellSpace == nil ? 0 : 1)
                }) { session in
                    HostSpacesList(session: session)
                    if let space = tabs.workspace(session.id)?.shellSpace { HostShellSpaceRow(session: session, space: space) }
                }.environment(\.hostSpaceOpening, navigator))
            })
    }

    /// New space for New chat (M9a): its form over New chat (for the recent space's host, as from New tab's picker), or
    /// the quick menu's places on the connected hosts; either way the space becomes the chat's.
    var newChatSpaces: NewChatSpaceMaker {
        let tabs = tabs, navigator = navigator, hostViews = hostViews
        return NewChatSpaceMaker(
            destinations: { NewSpaceDestination.all(tabs.workspaces) },
            quick: { try await navigator.makeSpace($0).space },
            form: { created in
                AnyView(NewSpaceSheet(model: tabs, host: tabs.recentSpace?.ref.host, hostViews: hostViews) { created($0.space) }
                    .tint(.dispatchPink))
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
            let session = hosts.session(tab.ref.host)
            VStack(spacing: 6) {
                Text(session?.link.isPending == true ? "Connecting to \(session?.host.name ?? "the host")…"
                     : "\(session?.host.name ?? "The host") is offline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let problem = session?.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
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

/// Host detail's row for a plain host's Shell space, after the topology's rows (`HostSpacesList`), as they draw theirs:
/// it opens the space (`MobileSpace.shellNode`).
private struct HostShellSpaceRow: View {
    let session: HostSession
    let space: MobileSpace
    @Environment(\.hostSpaceOpening) private var spaceOpening

    var body: some View {
        if let spaceOpening {
            Button { spaceOpening.open(host: session.id, space: MobileSpace.shellNode) } label: {
                HStack {
                    row
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            Text(space.name).font(.headline)
            Text(space.tabs.count == 1 ? "1 shell" : "\(space.tabs.count) shells")
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

/// A plain shell tab's Terminal segment: its presence, which `ShellSessions` keeps attached while the tab lives (this
/// view's own use comes and goes with it on screen, as any segment's). Once the shell ended (its exit, or the
/// connection's) the ended card offers New shell and Close over the last screen; a tab the launch cache brought back
/// has no screen, only the card.
private struct ShellSegment: View {
    let hosts: HostSessions
    let presences: TerminalPresences
    let navigator: SpacesNavigator
    let tab: MobileTab
    let pane: MobilePane

    var body: some View {
        let key = TerminalPresences.Key(host: tab.ref.host, node: pane.key)
        let state = hosts.session(tab.ref.host)?.shells.tab(key: pane.key)?.state ?? tab.shell
        let ref = tab.ref
        let card = TerminalEndedCard(ended: state?.isLive == false,
                                     newShell: { navigator.newShell(host: ref.host) },
                                     close: { navigator.actions.close(.tab(ref), .close) })
        if let presence = presences.presence(key) {
            TerminalSegmentView(presence: presence, ended: card).id(key)
                .onAppear { presences.retain(key) }
                .onDisappear { presences.release(key) }
        } else {
            TerminalEndedCardView(card: card, detail: state?.exitDetail)
                .frame(maxWidth: 404)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
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

    /// The host's presences of terminals that are gone (not in `keeping`, the live topology's terminal keys) go. Shell
    /// tabs' presences are not the topology's: their `ShellSessions` closes them.
    func prune(host: UUID, keeping: Set<String>) {
        for key in keys(host: host) where !keeping.contains(key.node) && !ShellSessions.isKey(key.node) { close(key) }
    }
}

extension TabsHost {
    /// A host session as Spaces draws it: name, tint (gray offline), glyph system, the hello account's home, state, order,
    /// and the multiplexer its spaces come from.
    @MainActor init(_ session: HostSession) {
        let record = session.host
        self.init(id: record.id, name: record.name, tint: HostSummary(session: session).tint, system: record.system,
                  home: session.hello?.account?.home, loginHome: session.hello?.account?.login_home,
                  state: SpacesHostState(session.link), order: record.order,
                  // A plain connection's Shell space is this connection's own: live, not stale.
                  live: (session.topologyIsLive || session.isPlain) && !session.switchingMultiplexer,
                  multiplexer: session.spacesMultiplexer, plain: session.plainSSH)
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

