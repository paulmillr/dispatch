import Foundation
import Observation
import XCTest
@testable import DispatchMobile

/// `MobileWorkspace`: topology snapshots become spaces, tabs and panes, merged into the objects already shown.
@MainActor
final class TabsWorkspaceTests: XCTestCase {
    /// The real tmux capture: sessions are spaces, windows tabs, panes a tab's terminals in layout order, and a split
    /// window shows its focused pane.
    func testRealTmuxTopologyMapsSessionsWindowsAndPanes() throws {
        let snapshots = try TabsFixtures.liveTmux()
        XCTAssertGreaterThan(snapshots.count, 1)
        let workspace = TabsFixtures.workspace()
        workspace.apply(snapshots[0])
        XCTAssertEqual(workspace.spaces.map(\.ref.key), ["tmux:tmux.sock:$0", "tmux:tmux.sock:$1"])
        XCTAssertEqual(workspace.spaces.map(\.name), ["usr", "usr"])
        let first = try XCTUnwrap(workspace.spaces.first?.tabs.first)
        XCTAssertEqual(first.name, "zsh")
        XCTAssertEqual(first.panes.map(\.id), [5, 6])
        XCTAssertEqual(first.activePane?.id, 6, "the window's layout focus")
        XCTAssertEqual(first.cwd, "/usr")
        XCTAssertFalse(first.isChat)
        let second = try XCTUnwrap(workspace.spaces.last?.tabs.first)
        XCTAssertEqual(second.panes.map(\.id), [10, 11])
        XCTAssertEqual(second.activePane?.id, 11)
        XCTAssertEqual(workspace.spaces.first?.cwd, "/usr", "a space without its own directory takes its first tab's")
    }

    /// Every later snapshot of the capture keeps the objects of the nodes it still has.
    func testRealSnapshotsKeepRowIdentity() throws {
        let snapshots = try TabsFixtures.liveTmux()
        let workspace = TabsFixtures.workspace()
        workspace.apply(snapshots[0])
        let spaces = workspace.spaces.map(ObjectIdentifier.init), tabs = workspace.tabs.map(ObjectIdentifier.init)
        for snapshot in snapshots.dropFirst() {
            workspace.apply(snapshot)
            let keys = Set(snapshot.nodes.map(\.key))
            for (index, space) in workspace.spaces.enumerated() where index < spaces.count && keys.contains(space.ref.key) {
                XCTAssertEqual(ObjectIdentifier(space), spaces[index])
            }
            for tab in workspace.tabs where keys.contains(tab.ref.key) {
                XCTAssertTrue(tabs.contains(ObjectIdentifier(tab)), "\(tab.ref.key) was recreated")
            }
        }
    }

    /// An unchanged node is not even written: nothing observing it is invalidated.
    func testUnchangedNodesAreNotInvalidated() {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app().topology)
        let claude = workspace.tab("herdr:app:1")!, docs = workspace.space("herdr:docs")!
        let invalidated = Invalidations()
        withObservationTracking {
            _ = (claude.name, claude.panes, claude.activePane, claude.activity, claude.node, claude.space)
        } onChange: { invalidated.add("claude") }
        withObservationTracking { _ = (docs.name, docs.tabs, docs.cwd, docs.node) } onChange: { invalidated.add("docs") }
        withObservationTracking { _ = workspace.spaces } onChange: { invalidated.add("spaces") }
        // Another tab is renamed: only that tab changes.
        workspace.apply(TabsFixtures.app(devName: "server").topology)
        XCTAssertEqual(invalidated.names, [])
        XCTAssertEqual(workspace.tab("herdr:app:2")?.name, "server")
    }

    /// A changed node updates in place and counts as activity; a reconnect's new node ids keep the objects (by key).
    func testChangesUpdateInPlaceAndReconnectKeepsKeys() {
        let clock = TestClock()
        let workspace = TabsFixtures.workspace(now: { clock.now })
        workspace.apply(TabsFixtures.app().topology)
        let dev = workspace.tab("herdr:app:2")!
        XCTAssertNil(dev.activity, "the first snapshot says nothing about when a tab last changed")
        clock.advance(60)
        workspace.apply(TabsFixtures.app(devName: "server").topology)
        XCTAssertTrue(workspace.tab("herdr:app:2") === dev)
        XCTAssertEqual(dev.name, "server")
        XCTAssertEqual(dev.activity, clock.now)
        let old = dev.node
        workspace.apply(TabsFixtures.app(backend: 1, first: 500, devName: "server").topology)
        XCTAssertTrue(workspace.tab("herdr:app:2") === dev)
        XCTAssertNotEqual(dev.node, old)
        XCTAssertEqual(dev.node, TabsFixtures.app(first: 500).ids["herdr:app:2"])
    }

    /// A tab that appears while the host is listed is new: its time is now.
    func testNewTabIsActivityNow() {
        let clock = TestClock()
        let workspace = TabsFixtures.workspace(now: { clock.now })
        workspace.apply(TabsFixtures.app().topology)
        clock.advance(30)
        workspace.apply(TabsFixtures.app(extraTab: true).topology)
        XCTAssertEqual(workspace.tab("herdr:app:4")?.activity, clock.now)
        XCTAssertEqual(workspace.space("herdr:app")?.tabs.count, 4)
        XCTAssertEqual(workspace.space("herdr:app")?.activity, clock.now)
    }

    /// Times say when something happened: a change found across a gap happened at an unknown time and moves none. The
    /// launch cache against the live data, a reconnect (a new client), and a newly followed multiplexer are baselines;
    /// only a change between two live snapshots of one connection is dated.
    func testChangesFoundAcrossAGapMoveNoTime() {
        let clock = TestClock()
        var cachedHost = TabsFixtures.host
        cachedHost.live = false
        let workspace = MobileWorkspace(host: cachedHost, activity: TabActivityStore(url: nil), now: { clock.now })
        workspace.apply(TabsFixtures.app().topology)
        clock.advance(60)
        workspace.update(host: TabsFixtures.host)
        workspace.apply(TabsFixtures.app(devName: "server", extraTab: true).topology)
        XCTAssertNil(workspace.tab("herdr:app:2")?.activity, "renamed while the phone was away")
        XCTAssertNil(workspace.tab("herdr:app:4")?.activity, "made while the phone was away")
        clock.advance(60)
        workspace.apply(TabsFixtures.app(devName: "build", extraTab: true).topology)
        let seen = clock.now
        XCTAssertEqual(workspace.tab("herdr:app:2")?.activity, seen, "renamed between two live snapshots")

        let first = ScriptedHelper.scripted { _ in nil }, second = ScriptedHelper.scripted { _ in nil }
        defer { first.close(); second.close() }
        workspace.connect(first.client)
        workspace.apply(TabsFixtures.app(backend: 2, first: 500, devName: "build", extraTab: true).topology)
        clock.advance(60)
        workspace.connect(nil)
        workspace.connect(second.client)
        workspace.apply(TabsFixtures.app(backend: 3, first: 900, devName: "deploy", extraTab: true, focus: 0).topology)
        XCTAssertEqual(workspace.tab("herdr:app:2")?.activity, seen, "renamed while reconnecting")

        // Another multiplexer followed: its tabs were there all along, none of them is new.
        workspace.remove(backend: 3)
        let tmux = TopologySketch(backend: 4, first: 1200, spaces: [
            .init(key: "tmux:work", name: "work", tabs: [.init(key: "tmux:work:@1", name: "vim", panes: [.init(key: "%1", cwd: "/srv")])]),
        ])
        workspace.apply(tmux.topology)
        XCTAssertNil(workspace.tab("tmux:work:@1")?.activity)
    }

    /// Detached nodes are running but dismissed on this connection: they leave the lists.
    func testDetachedNodesAreHidden() {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app(detachDev: true).topology)
        XCTAssertNil(workspace.tab("herdr:app:2"))
        XCTAssertEqual(workspace.space("herdr:app")?.tabs.map(\.name), ["claude", "zsh"])
    }

    /// The pane switcher's pick wins over the server's focus while the pane exists.
    func testPickedPaneWinsWhileItExists() throws {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app(focus: 1).topology)
        let zsh = try XCTUnwrap(workspace.tab("herdr:app:3"))
        XCTAssertEqual(zsh.activePane?.key, "p:zsh2")
        zsh.pick(zsh.panes[0])
        workspace.apply(TabsFixtures.app(focus: 1).topology)
        XCTAssertEqual(zsh.activePane?.key, "p:zsh1")
        var sketch = TabsFixtures.app(focus: 0)
        sketch.spaces[0].tabs[2].panes.removeFirst()
        workspace.apply(sketch.topology)
        XCTAssertEqual(zsh.activePane?.key, "p:zsh2", "a picked pane that closed falls back to the focus")
    }

    /// Chat tabs: the agent's pane, even when another pane is active.
    func testAgentBindingMakesAChatTab() throws {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app().topology)
        XCTAssertTrue(try XCTUnwrap(workspace.tab("herdr:app:1")).isChat)
        XCTAssertEqual(workspace.tab("herdr:app:1")?.agentPane?.agent?.session, "s1")
        XCTAssertFalse(try XCTUnwrap(workspace.tab("herdr:app:3")).isChat)
        XCTAssertEqual(TabSegment.initial(for: workspace.tab("herdr:app:1")!), .chat)
        XCTAssertEqual(TabSegment.initial(for: workspace.tab("herdr:app:3")!), .terminal)
    }

    /// A program name tells a shell at its prompt from a running program; a renamed window says nothing.
    func testProgramComesFromUnrenamedWindows() {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app().topology)
        XCTAssertEqual(workspace.tab("herdr:app:3")?.program, "zsh")
        XCTAssertEqual(workspace.tab("herdr:app:3")?.atShell, true)
        XCTAssertNil(workspace.tab("herdr:app:2")?.program)
        XCTAssertTrue(MobileTab.isShell("-zsh"))
        XCTAssertFalse(MobileTab.isShell("pnpm"))
    }

    /// The Mac's automatic tab names: a renamed tab keeps its name, an agent's tab takes its conversation title, and a
    /// herdr tab numbered by position shows its pane's name, else its folder.
    func testTabsAreNamedAsTheMacNamesThem() {
        var host = TabsFixtures.host
        host.multiplexer = "herdr"
        let workspace = MobileWorkspace(host: host, client: nil, activity: TabActivityStore(url: nil))
        workspace.apply(TopologySketch(spaces: [.init(key: "herdr:w", name: "w", tabs: [
            .init(key: "herdr:w:1", name: "1", panes: [.init(key: "p:1", name: "vim", cwd: "/Users/alex/src/app")]),
            .init(key: "herdr:w:2", name: "2", panes: [.init(key: "p:2", name: "", cwd: "/Users/alex/src/docs")]),
            .init(key: "herdr:w:3", name: "notes", renamed: true, panes: [.init(key: "p:3", name: "zsh", cwd: "/Users/alex")]),
            .init(key: "herdr:w:4", name: "4", panes: [.init(key: "p:4", name: "", cwd: "/Users/alex")]),
        ])]).topology)
        let homes = host.homes
        XCTAssertEqual(workspace.tab("herdr:w:1")?.label(conversation: nil, homes: homes), "vim")
        XCTAssertEqual(workspace.tab("herdr:w:2")?.label(conversation: nil, homes: homes), "docs")
        XCTAssertEqual(workspace.tab("herdr:w:3")?.label(conversation: "Fix the build", homes: homes), "notes")
        XCTAssertEqual(workspace.tab("herdr:w:4")?.label(conversation: nil, homes: homes), "~")
        XCTAssertEqual(workspace.tab("herdr:w:1")?.label(conversation: "Fix the build", homes: homes), "Fix the build")
        // The attached terminal's own title, as the Mac's pane label reads it: a shell's prompt title names the folder.
        XCTAssertEqual(workspace.tab("herdr:w:1")?.label(conversation: nil, homes: homes, paneTitle: "~/src/app"), "app")
        XCTAssertEqual(workspace.tab("herdr:w:1")?.label(conversation: nil, homes: homes, paneTitle: "vim notes.md"), "vim notes.md")
        // tmux names an unrenamed window after its program: that name stays.
        let tmux = TabsFixtures.workspace()
        tmux.apply(TabsFixtures.app().topology)
        XCTAssertEqual(tmux.tab("herdr:app:3")?.label(conversation: nil, homes: homes), "zsh")
    }

    /// Two backends on one host (herdr and tmux) list side by side; removing one leaves the other.
    func testBackendsMergeAndLeave() {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app(backend: 1).topology)
        let tmux = TopologySketch(backend: 2, first: 900, spaces: [
            .init(key: "tmux:work", name: "work", tabs: [.init(key: "tmux:work:@1", name: "vim", panes: [.init(key: "%1", cwd: "/srv")])]),
        ])
        workspace.apply(tmux.topology)
        XCTAssertEqual(workspace.spaces.map(\.name), ["app", "docs", "work"])
        XCTAssertEqual(workspace.space("tmux:work")?.backend, 2)
        workspace.remove(backend: 1)
        XCTAssertEqual(workspace.spaces.map(\.name), ["work"])
    }

    /// Activity seen outside the topology (output, an agent) moves the tab up.
    func testNotedActivityUpdatesTheTab() {
        let clock = TestClock()
        let workspace = TabsFixtures.workspace(now: { clock.now })
        let sketch = TabsFixtures.app()
        workspace.apply(sketch.topology)
        clock.advance(5)
        workspace.noteActivity(terminal: sketch.ids["p:zsh2"]!)
        XCTAssertEqual(workspace.tab("herdr:app:3")?.activity, clock.now)
    }

    /// Times survive the app: the store writes a small file and reads it back.
    func testActivityPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabs-activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let date = Date().addingTimeInterval(-120).rounded
        let store = TabActivityStore(url: url)
        store.note(host: TabsFixtures.host.id, key: "p:dev", at: date)
        store.save()
        let reread = TabActivityStore(url: url)
        XCTAssertEqual(reread.date(host: TabsFixtures.host.id, key: "p:dev"), date)
        let workspace = TabsFixtures.workspace(store: reread)
        workspace.apply(TabsFixtures.app().topology)
        XCTAssertEqual(workspace.tab("herdr:app:2")?.activity, date)
    }

    /// The store keeps at most its limit per host, the newest.
    func testActivityStoreIsBounded() {
        let store = TabActivityStore(url: nil, limit: 3)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 { store.note(host: TabsFixtures.host.id, key: "k\(index)", at: base.addingTimeInterval(Double(index))) }
        XCTAssertNil(store.date(host: TabsFixtures.host.id, key: "k0"))
        XCTAssertNil(store.date(host: TabsFixtures.host.id, key: "k1"))
        XCTAssertNotNil(store.date(host: TabsFixtures.host.id, key: "k4"))
    }

    /// Paths show the host's home as ~ and typed ~ paths go to the helper absolute.
    func testHomePaths() {
        let host = TabsFixtures.host
        XCTAssertEqual(host.abbreviate("/Users/alex/src/app"), "~/src/app")
        XCTAssertEqual(host.abbreviate("/Users/alex"), "~")
        XCTAssertEqual(host.abbreviate("/Users/alexander"), "/Users/alexander")
        XCTAssertEqual(host.expand("~/src"), "/Users/alex/src")
        XCTAssertEqual(host.expand("~"), "/Users/alex")
        XCTAssertEqual(host.expand("/srv"), "/srv")
    }
}

private final class Invalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ name: String) { lock.withLock { list.append(name) } }
    var names: [String] { lock.withLock { list } }
}

private extension Date {
    /// Whole seconds, as the store writes them.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}

/// docs/ios.md, Areas and seams: node, tab, space and backend ids change with every helper connection;
/// the host and the topology key are the identity.
@MainActor
final class TabsReconnectTests: XCTestCase {
    func testReconnectUnderANewBackendKeepsRowsOnce() {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app(backend: 1, first: 10).topology)
        let tabs = workspace.tabs, spaces = workspace.spaces
        let reconnected = TabsFixtures.app(backend: 9, first: 4000)
        workspace.apply(reconnected.topology)
        XCTAssertEqual(workspace.tabs.count, tabs.count, "the old connection's view gave way")
        XCTAssertTrue(zip(workspace.tabs, tabs).allSatisfy { $0 === $1 })
        XCTAssertTrue(zip(workspace.spaces, spaces).allSatisfy { $0 === $1 })
        XCTAssertEqual(workspace.space("herdr:app")?.backend, 9)
        XCTAssertEqual(workspace.tab("herdr:app:1")?.panes.first?.id, reconnected.ids["p:claude"])
    }

    /// Persisted times are by host and pane key, so they apply to the next connection's ids.
    func testActivityFollowsKeysAcrossConnections() {
        let clock = TestClock()
        let store = TabActivityStore(url: nil)
        let first = TabsFixtures.workspace(now: { clock.now }, store: store)
        first.apply(TabsFixtures.app(backend: 1, first: 10).topology)
        clock.advance(10)
        first.apply(TabsFixtures.app(backend: 1, first: 10, devName: "server").topology)
        let seen = clock.now
        let next = TabsFixtures.workspace(now: { clock.now }, store: store)
        next.apply(TabsFixtures.app(backend: 5, first: 800, devName: "server").topology)
        XCTAssertEqual(next.tab("herdr:app:2")?.activity, seen)
    }
}

/// Plain SSH (docs/ios.md): a host without the helper lists one synthetic space, "Shell", whose tabs are the phone's
/// shells (`ShellSessions`), live or ended.
extension TabsWorkspaceTests {
    /// One Shell space and nothing of a topology (a cached one is not the plain host's spaces); its tabs come from the
    /// shells, named "Shell n" until the program sets a title, with no chat; an ended shell stays as a card with how it
    /// ended, and its row keeps its object throughout.
    func testAPlainHostListsOneShellSpaceFromItsShells() async throws {
        let opener = ScriptedShellOpener()
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let shells = ShellFixtures.sessions(opener: opener, now: { created })
        let model = ShellFixtures.model()
        model.shellSessions = { _ in shells }
        model.sync([ShellFixtures.input(shells, topology: TabsFixtures.app().topology)])
        let workspace = try XCTUnwrap(model.workspace(ShellFixtures.host.id))
        XCTAssertEqual(workspace.spaces.map(\.name), ["Shell"])
        let space = try XCTUnwrap(workspace.shellSpace)
        XCTAssertEqual(space.kind, .plainShell)
        XCTAssertEqual(space.ref.key, MobileSpace.shellKey)
        XCTAssertTrue(space.tabs.isEmpty, "listed before any shell")
        XCTAssertTrue(workspace.opensShells)
        XCTAssertTrue(workspace.connected)
        XCTAssertTrue(workspace.canAddTab(to: space))

        let first = try model.newShell(on: ShellFixtures.host.id)
        let second = try model.newShell(on: ShellFixtures.host.id)
        XCTAssertEqual(space.tabs.map { model.label(of: $0, host: workspace.host) }, ["Shell 1", "Shell 2"])
        XCTAssertTrue(space.tabs.allSatisfy { !$0.isChat && $0.agentPane == nil && $0.shell == .live })
        XCTAssertTrue(ShellSessions.isKey(first.ref.key))
        XCTAssertEqual(first.panes.map(\.key), [first.ref.key], "its pane is its presence's node")
        XCTAssertEqual(first.activity, created)
        XCTAssertEqual(first.space, space.ref)

        let shell = try await ShellFixtures.shell(opener, 0)
        XCTAssertEqual(shell.term, PlainShellFeed.term)
        shell.emit("\u{1B}]2;vim notes\u{07}")
        try await TestSupport.eventually { shells.tabs.first?.title == "vim notes" }
        model.sync([ShellFixtures.input(shells)])
        XCTAssertEqual(model.label(of: first, host: workspace.host), "vim notes", "the program's title (OSC 2)")
        shell.end(.status(3))
        try await TestSupport.eventually { shells.tabs.first?.state == .ended(3) }
        model.sync([ShellFixtures.input(shells)])
        XCTAssertTrue(workspace.tabs.first === first, "the same row object")
        XCTAssertEqual(first.shell, .ended(3))
        XCTAssertEqual(space.tabs.count, 2, "an ended shell stays")
        XCTAssertEqual(TabsTabLine.line(first, label: model.label(of: first, host: workspace.host), status: model.status),
                       "Exited with status 3")
        XCTAssertNil(TabsTabLine.line(second, label: "Shell 2", status: model.status), "a live shell has no line")
        XCTAssertNil(model.urgency(of: first))
        model.closeShell(second.ref)
        XCTAssertEqual(space.tabs.map(\.ref), [first.ref])
    }

    /// While the host is not connected: a host whose Helper switch is off keeps its Shell space (every card ended, the
    /// launch cache's without a screen) and opens nothing; a host that fell back to plain SSH (switch on, mode unknown
    /// offline) lists the cards beside its other spaces while any are left. Cards close offline. A helper connection's
    /// snapshot after a plain one is applied again, even the same one.
    func testTheShellSpaceWhileDisconnected() throws {
        let shells = ShellFixtures.sessions(opener: nil)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        shells.restore([ShellTabEntry(id: UUID(), number: 4, title: "htop", created: created),
                        ShellTabEntry(id: UUID(), number: 7, title: nil, created: created)])
        let model = ShellFixtures.model()
        model.shellSessions = { _ in shells }
        model.sync([ShellFixtures.input(shells, state: .offline, topology: TabsFixtures.app().topology)])
        let workspace = try XCTUnwrap(model.workspace(ShellFixtures.host.id))
        let space = try XCTUnwrap(workspace.shellSpace)
        XCTAssertEqual(workspace.spaces.map(\.name), ["Shell"])
        XCTAssertEqual(space.tabs.map(\.name), ["htop", "Shell 7"])
        XCTAssertTrue(space.tabs.allSatisfy { $0.shell == .ended(nil) })
        XCTAssertFalse(workspace.opensShells)
        XCTAssertFalse(workspace.connected)
        XCTAssertFalse(workspace.canAddTab(to: space))
        XCTAssertNil(model.recentSpace, "New tab goes nowhere offline")
        XCTAssertThrowsError(try model.newShell(on: ShellFixtures.host.id))

        model.sync([ShellFixtures.input(shells, mode: nil, state: .offline, topology: TabsFixtures.app().topology)])
        XCTAssertEqual(workspace.spaces.map(\.name), ["app", "docs", "Shell"])
        XCTAssertTrue(workspace.shellSpace === space)
        model.closeShell(space.tabs[1].ref)
        model.closeShells(host: ShellFixtures.host.id)
        XCTAssertTrue(shells.tabs.isEmpty)
        XCTAssertEqual(workspace.spaces.map(\.name), ["app", "docs"], "no cards left, no Shell space")
        model.sync([ShellFixtures.input(shells, state: .offline)])
        XCTAssertEqual(workspace.spaces.map(\.name), ["Shell"], "Helper off: listed, empty")
    }
}
