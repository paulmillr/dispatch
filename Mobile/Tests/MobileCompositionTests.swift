import SwiftUI
import XCTest
@testable import DispatchMobile

/// The composition root: one `HostSessions` (here over the scripted driver) drives the Spaces model and the conversation
/// list, Spaces edits hosts through it, and Chat's urgency flows back into the Spaces rows.
@MainActor
final class MobileCompositionTests: XCTestCase {
    private func composition(hosts records: [HostRecord], driver: ScriptedHostSessionDriver = ScriptedHostSessionDriver(),
                             active: Bool = true) -> MobileComposition {
        let hosts = HostSessions(store: HostStore(url: nil, hosts: records),
                                 keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                 knownHosts: KnownHostStore(url: nil), driver: driver, active: active)
        let defaults = UserDefaults(suiteName: "composition-\(UUID().uuidString)")!
        return MobileComposition(hosts: hosts, tabs: MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults),
                                 presences: TerminalPresences(), markers: ChatMarkers(store: ChatMarkerMemoryStore()),
                                 outbox: ChatOutbox(store: ChatOutboxMemoryStore()),
                                 drafts: ChatDraftRepository(store: ChatDraftMemoryStore()))
    }

    private func host(_ name: String, order: Int = 0) -> HostRecord {
        HostRecord(name: name, address: name + ".local", user: "alex", auth: .password, order: order, tintSeed: name)
    }

    /// Two hosts reaching one machine and account (a LAN and a Tailscale address) show its spaces and agents once, under
    /// the first in the list, as the Mac keys a host by machine and uid; the other names it.
    func testTheSameMachineShowsItsSpacesOnce() async throws {
        let lan = HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .password, order: 0, tintSeed: "machine")
        let tailnet = HostRecord(name: "studio-ts", address: "studio.ts.net", user: "alex", auth: .password, order: 1, tintSeed: "machine")
        let app = composition(hosts: [lan, tailnet])
        try await TestSupport.eventually { app.hosts.ordered.allSatisfy { $0.link == .connected } }
        try await TestSupport.eventually { app.tabs.workspace(lan.id)?.spaces.isEmpty == false }
        XCTAssertEqual(app.tabs.workspace(tailnet.id)?.spaces.count, 0)
        XCTAssertEqual(app.tabs.workspace(tailnet.id)?.host.sameMachine, "studio")
        XCTAssertNil(app.tabs.workspace(lan.id)?.host.sameMachine)
        XCTAssertEqual(Set(app.conversations.conversations.map(\.key.host)), [lan.id], "Its agents once")
    }

    func testAConnectingHostFeedsSpacesAndAgents() async throws {
        let studio = host("studio")
        let app = composition(hosts: [studio])
        let workspace = try XCTUnwrap(app.tabs.workspace(studio.id), "listed at once, before it connects")
        XCTAssertEqual(workspace.host.state, .connecting)
        XCTAssertEqual(workspace.host.name, "studio")
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected }
        // Same turn: the areas already show what the session shows.
        XCTAssertEqual(workspace.host.state, .connected)
        XCTAssertTrue(workspace.client === session.client)
        XCTAssertEqual(workspace.host.home, "/Users/alex", "the hello account's home, for ~ in paths")
        XCTAssertEqual(workspace.host.system, session.host.system)
        XCTAssertEqual(workspace.spaces.map(\.name), ["docs", "billing"])
        XCTAssertEqual(workspace.features, Set(session.hello?.features ?? []))
        XCTAssertTrue(app.conversations.hosts[studio.id]?.client === session.client)
        XCTAssertEqual(app.conversations.conversations.count, 2, "one per agent-bound terminal")

        session.disconnect()
        XCTAssertEqual(workspace.host.state, .offline)
        XCTAssertNil(workspace.client)
        XCTAssertNil(app.conversations.hosts[studio.id]?.client)
        XCTAssertEqual(workspace.spaces.map(\.name), ["docs", "billing"], "the last spaces stay listed offline")
    }

    func testTheFollowedMultiplexerIsWhereNewSpaceGoes() async throws {
        let studio = host("studio")
        let driver = ScriptedHostSessionDriver { host in
            [.event(.following("tmux"))] + ScriptedHostSessionDriver.connects(host)
        }
        let app = composition(hosts: [studio], driver: driver)
        try await TestSupport.eventually { app.hosts.session(studio.id)?.link == .connected }
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        XCTAssertEqual(session.following, "tmux")
        XCTAssertEqual(MobileComposition.input(session).multiplexer, "tmux")
        var record = session.host
        record.multiplexer = .herdr
        app.hosts.update(record)
        XCTAssertEqual(MobileComposition.input(app.hosts.session(studio.id)!).multiplexer, "tmux",
                       "the followed one wins until the driver follows another")
    }

    /// Spaces marks where a host's spaces come from (the followed multiplexer, `TabsHost.multiplexer`), and New chat's
    /// quick menu offers the connected hosts' multiplexers, the shown one first, as holding New space does in Spaces.
    func testTheSpacesMarkAndNewChatsQuickMenu() async throws {
        let studio = host("studio")
        let app = composition(hosts: [studio])
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected }
        let workspace = try XCTUnwrap(app.tabs.workspace(studio.id))
        XCTAssertEqual(workspace.host.multiplexer, "tmux")
        let tmux = MultiplexerChoice(mux: 1, name: "tmux", route: .init(mux: 1, key: "tmux"))
        let herdr = MultiplexerChoice(mux: 2, name: "herdr", route: .init(mux: 2, key: "herdr"))
        workspace.multiplexers = [herdr, tmux]
        workspace.choice = tmux
        let entries = app.newChatSpaces.destinations()
        XCTAssertEqual(entries.map(\.id), ["\(studio.id.uuidString):tmux", "\(studio.id.uuidString):herdr"])
        XCTAssertEqual(entries.map { $0.title(host: nil) }, ["studio", "studio"])
        XCTAssertEqual(entries.map { $0.subtitle(host: nil) }, ["tmux", "Switches studio to herdr"])
        session.disconnect()
        XCTAssertEqual(app.newChatSpaces.destinations(), [], "nothing to make a space on offline")
        XCTAssertEqual(workspace.host.multiplexer, "tmux", "the spaces kept offline are still tmux's")
    }

    func testSpacesRemovesAndReordersHostsThroughTheStore() async throws {
        let a = host("a", order: 0), b = host("b", order: 1), c = host("c", order: 2)
        let app = composition(hosts: [a, b, c], active: false)
        let actions: SpacesHostActions = app.hosts
        XCTAssertEqual(app.tabs.workspaces.map(\.host.name), ["a", "b", "c"])

        actions.reorderHosts([c.id, a.id, b.id])
        XCTAssertEqual(app.hosts.store.hosts.map(\.name), ["c", "a", "b"])
        XCTAssertEqual(app.tabs.workspaces.map(\.host.name), ["c", "a", "b"])
        XCTAssertEqual(app.tabs.workspaces.map(\.host.order), [0, 1, 2])

        let question = try XCTUnwrap(actions.removalConfirmation(for: a.id))
        XCTAssertEqual(question.title, "Remove a?")
        XCTAssertEqual(question.button, "Remove host")
        XCTAssertEqual(question.message, HostSessions.removalMessage)
        actions.removeHost(a.id)
        XCTAssertEqual(app.hosts.store.hosts.map(\.name), ["c", "b"])
        XCTAssertEqual(app.tabs.workspaces.map(\.host.name), ["c", "b"])
        XCTAssertNil(app.conversations.hosts[a.id])
    }

    func testChatUrgencyBecomesTheSpacesDots() throws {
        func row(_ urgency: PaneUrgency, muted: Bool = false) -> ChatConversation {
            ChatConversation(key: ChatConversationKey(host: UUID(), node: "n"), terminal: 1, hostName: "h", name: "t", space: nil,
                             spaceNode: nil, cwd: nil, binding: ChatFixture.topologyBinding, summary: ChatConversationSummary(),
                             urgency: urgency, muted: muted, unread: urgency == .unread)
        }
        XCTAssertEqual(TabUrgency(row(.waiting)), .needsYou)
        XCTAssertEqual(TabUrgency(row(.waiting, muted: true)), .needsYou, "muted keeps only needs you")
        XCTAssertEqual(TabUrgency(row(.running)), .working)
        XCTAssertNil(TabUrgency(row(.running, muted: true)))
        XCTAssertEqual(TabUrgency(row(.unread)), .unseen)
        XCTAssertNil(TabUrgency(row(.idle)))
        XCTAssertEqual(TabUrgency(row(.waiting))?.rowDot, row(.waiting).dot)
    }

    /// The Terminal segment keeps its view when the host drops and comes back: online and offline are one branch, so
    /// the host view (and with it the keyboard, the capsule's latches and the drawn screen) is not made again.
    func testATerminalSegmentKeepsItsViewAcrossADrop() async throws {
        let studio = host("studio")
        let app = composition(hosts: [studio])
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected }
        let tab = try XCTUnwrap(app.tabs.workspace(studio.id)?.tabs.first)
        let pane = try XCTUnwrap(tab.activePane)
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        window.rootViewController = UIHostingController(rootView: app.content.terminal(tab, pane))
        window.isHidden = false
        defer { window.isHidden = true }
        func hostView() -> TerminalHostView? {
            window.layoutIfNeeded()
            var queue: [UIView] = [window]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let found = view as? TerminalHostView { return found }
                queue += view.subviews
            }
            return nil
        }
        try await TestSupport.eventually { hostView() != nil }
        let shown = try XCTUnwrap(hostView())
        session.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(hostView() === shown, "Offline: the same view keeps showing the last screen")
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(hostView() === shown, "Back online: still the same view")
    }

    /// A terminal whose pane closed on the host leaves the presences with the snapshot that no longer names it (each
    /// presence holds an attachment, a parse task and a render thread); the others stay.
    func testAPresenceGoesWhenItsTerminalLeavesTheTopology() async throws {
        let studio = host("studio")
        let gone = HostFixture.topology([.init(name: "docs", cwd: "/Users/alex/src/docs", tabs: 1, agents: 0)])
        let driver = ScriptedHostSessionDriver { host in
            Array(ScriptedHostSessionDriver.connects(host).dropLast()) + [.awaitRetry, .event(.topology(gone)), .hold]
        }
        let app = composition(hosts: [studio], driver: driver)
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected }
        let client = try XCTUnwrap(session.client)
        let terminals = try XCTUnwrap(session.topology).nodes.filter { $0.kind == .terminal }
        let kept = try XCTUnwrap(terminals.first { node in gone.nodes.contains { $0.key == node.key } })
        let closed = try XCTUnwrap(terminals.first { node in !gone.nodes.contains { $0.key == node.key } })
        for node in [kept, closed] {
            _ = app.presences.open(.init(host: studio.id, node: node.key), feed: HelperTerminalFeed(client: client, terminal: node.id),
                                   terminal: node.id, client: client)
        }
        session.retryNow()
        try await TestSupport.eventually { session.topology == gone }
        XCTAssertNil(app.presences.presence(.init(host: studio.id, node: closed.key)))
        XCTAssertNotNil(app.presences.presence(.init(host: studio.id, node: kept.key)))
    }

    /// After a reconnect, until the connection's first live topology: Spaces' rows are stale and refuse tab commands
    /// (their node ids are the previous helper's), Agents gets no client (no conversation opens on old ids), and the
    /// presences are not reattached; New space's `backends.create` still has the client. The live snapshot ends all that.
    func testAStaleTopologyWithholdsNodeIdsUntilTheFirstLiveOne() async throws {
        let studio = host("studio")
        let live = HostFixture.topology()
        let driver = ScriptedHostSessionDriver { _ in
            [.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:], topology: live),
             .awaitRetry, .event(.link(.reconnecting(attempt: 1, since: Date()))), .awaitRetry,
             .ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:], topology: nil),
             .awaitRetry, .event(.topology(live)), .hold]
        }
        let app = composition(hosts: [studio], driver: driver)
        let session = try XCTUnwrap(app.hosts.session(studio.id))
        try await TestSupport.eventually { session.link == .connected }
        let workspace = try XCTUnwrap(app.tabs.workspace(studio.id))
        let terminal = try XCTUnwrap(live.nodes.first { $0.kind == .terminal })
        let key = TerminalPresences.Key(host: studio.id, node: terminal.key)
        let before = try XCTUnwrap(session.client)
        let presence = app.presences.open(key, feed: HelperTerminalFeed(client: before, terminal: terminal.id),
                                          terminal: terminal.id, client: before)
        app.presences.retain(key)
        session.retryNow()
        try await TestSupport.eventually { if case .reconnecting = session.link { true } else { false } }
        session.retryNow()
        try await TestSupport.eventually { session.link == .connected }
        let client = try XCTUnwrap(session.client)

        XCTAssertTrue(workspace.client === client, "the client is there for New space")
        XCTAssertFalse(workspace.host.live)
        XCTAssertTrue(workspace.host.stale, "the rows show last-known data")
        let tab = try XCTUnwrap(workspace.tabs.first)
        do {
            try await workspace.rename(tab: tab, to: "x")
            XCTFail("a stale node id went out")
        } catch let failure as TabsFailure {
            XCTAssertEqual(failure, .loading)
        }
        XCTAssertNil(app.conversations.hosts[studio.id]?.client, "Agents waits for the live topology")
        XCTAssertTrue(app.conversations.conversations.allSatisfy(\.stale))
        XCTAssertFalse(presence.attached, "no reattach on the previous helper's ids")

        session.retryNow()
        try await TestSupport.eventually { session.topologyIsLive }
        XCTAssertTrue(workspace.host.live)
        XCTAssertFalse(workspace.host.stale)
        XCTAssertTrue(app.conversations.hosts[studio.id]?.client === client)
        XCTAssertTrue(presence.attached, "reattached through the new client on the live topology")
        XCTAssertTrue((presence.feed as? HelperTerminalFeed)?.client === client)
    }

    /// Chat's use of a presence is one of its users: retained once per conversation however often it reattaches, and
    /// its release detaches the terminal unless the Terminal segment still uses it.
    func testChatHoldsOneUseOfItsPresence() async throws {
        let peer = ScriptedHelper.terminal()
        defer { peer.close() }
        let presences = TerminalPresences()
        let chat = TerminalChatPresence(presences: presences)
        let key = ChatConversationKey(host: UUID(), node: "tmux:fixture:9")
        let node = TerminalPresences.Key(host: key.host, node: key.node)
        chat.retain(key, terminal: 9, client: peer.client)
        chat.retain(key, terminal: 9, client: peer.client)
        XCTAssertTrue(chat.attached(key))
        presences.retain(node)  // the Terminal segment shows it too
        chat.release(key)
        XCTAssertTrue(chat.attached(key), "the segment still uses it")
        presences.release(node)
        XCTAssertFalse(chat.attached(key), "nobody uses it: detached")
        XCTAssertNotNil(presences.presence(node), "kept with its last screen")
        chat.release(key)
        presences.close(node)
    }

    func testAgentsOpensTheConversationsTabOnChat() async throws {
        let studio = host("studio")
        let app = composition(hosts: [studio])
        try await TestSupport.eventually { !app.conversations.conversations.isEmpty }
        let conversation = try XCTUnwrap(app.conversations.conversations.first)
        let ref = try XCTUnwrap(app.tab(for: conversation.key))
        app.openChat(conversation.key, keyboard: false)
        XCTAssertEqual(app.navigator.path, [.tab(ref)])
        XCTAssertEqual(app.tabs.segments[ref], .chat)
        XCTAssertEqual(app.tabs.needsYou(excluding: ref), app.conversations.needsYouCount)
    }

    /// Every connection with Chat on installs Claude Code's and Codex's hooks, as the Mac does for a newly connected host;
    /// Pi's extension is opt-in and only enabled again where it is installed. Chat off changes nothing.
    func testIntegrationsAreEnabledOnEachConnection() async throws {
        for (installed, chat) in [(true, true), (false, true), (false, false)] {
            let helper = ScriptedHelper.scripted { request in
                switch request.method {
                case "launches.list": .result([["launch": 4, "key": "pi", "label": "Pi", "program": "pi"],
                                               ["launch": 5, "key": "claude", "label": "Claude Code", "program": "claude"]])
                case "installation.audit":
                    request.params["launch"] as? UInt64 == 4
                        ? .result(["edits": [], "restart": false, "installed": installed, "optional": true])
                        : .result(["edits": [], "restart": false, "installed": false, "optional": false])
                case "installation.install": .result(["edits": [], "restart": false, "installed": true])
                default: nil
                }
            }
            var record = host("pi")
            record.chat = chat
            let session = HostSession(host: record, driver: ScriptedHostSessionDriver()) { _ in
                HostSessionContext(verifyHostKey: { _ in true }, key: { nil }, password: { nil }, retries: AsyncStream { $0.finish() })
            }
            await MobileComposition.enableIntegrations(session, helper.client)
            let installs = helper.requests("installation.install").compactMap { $0.params["launch"] as? UInt64 }
            XCTAssertEqual(installs, !chat ? [] : installed ? [4, 5] : [5], "installed \(installed), chat \(chat)")
            XCTAssertTrue(helper.requests("installation.install").allSatisfy { $0.params["enabled"] as? Bool == true })
        }
    }
}
