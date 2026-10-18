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

/// The helper spike (docs/ios-helper-spike.md): node, tab, space and backend ids change with every helper connection;
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
