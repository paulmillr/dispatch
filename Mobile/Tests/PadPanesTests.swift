import XCTest
@testable import DispatchMobile

/// The iPad detail column's panes (docs/ios.md, iPad › Panes): the tree (`PadPanes`: splits, removal, Merge Panes,
/// layout, room, drags, memory) and the navigator's side (`SpacesNavigator+Panes`: the focused pane is the path, tabs
/// shown elsewhere take the focus there, closes and the host's closes, commands, launches). On the Spaces sample
/// (`TabsSample`: mba2's app space holds claude, dev and zsh; studio's docs holds claude and zsh).
@MainActor
final class PadPanesTests: XCTestCase {
    private let mba2 = TabsSample.mba2.id, studio = TabsSample.studio.id
    private func tab(_ host: UUID, _ key: String) -> TabRef { TabRef(host: host, key: key) }
    private var claude: TabRef { tab(mba2, "herdr:app:1") }
    private var dev: TabRef { tab(mba2, "herdr:app:2") }
    private var zsh: TabRef { tab(mba2, "herdr:app:3") }
    private var docs: TabRef { tab(studio, "tmux:docs:@1") }

    /// A 13-inch iPad's detail column on its side beside the sidebar.
    private let room = CGSize(width: 1055, height: 1000)

    private func navigator(_ model: MobileTabs = TabsSample.model(), memory: UserDefaults? = nil) -> SpacesNavigator {
        let navigator = SpacesNavigator(model: model, memory: memory)
        navigator.sidebarHides = true
        navigator.split = true
        navigator.paneRoom = room
        return navigator
    }

    // MARK: The tree

    /// Split Right halves the pane and the new one takes the focus; along the same axis it joins the split (halving the
    /// pane's share), across it the pane becomes a split of its own. Four at most.
    func testSplitsHalveThePaneAndStopAtFour() {
        var panes = PadPanes.single
        let right = panes.split(0, axis: .columns, keeping: claude, detail: [])
        XCTAssertEqual(right, 1)
        XCTAssertEqual(panes.focused, 1)
        XCTAssertEqual(panes.leaf(0)?.tab, claude, "The pane that was focused keeps its tab")
        XCTAssertEqual(panes.root, .split(.columns, [.leaf(.init(id: 0, tab: claude)), .leaf(.init(id: 1))], [0.5, 0.5]))
        _ = panes.split(1, axis: .columns, keeping: dev, detail: [])
        guard case .split(.columns, let three, let shares) = panes.root else { return XCTFail("\(panes.root)") }
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(shares, [0.5, 0.25, 0.25])
        _ = panes.split(0, axis: .rows, keeping: nil, detail: [])
        XCTAssertEqual(panes.count, 4)
        XCTAssertNil(panes.split(0, axis: .rows, keeping: nil, detail: []), "Four at most")
        XCTAssertEqual(panes.leaves.map(\.id), [0, 3, 1, 2], "Reading order: the left column's top, then bottom")
    }

    /// A pane that goes gives its share to the one before it (else after); a split left with one pane is that pane, and
    /// one along its parent's axis joins the parent. The focused pane's place goes to the next in reading order.
    func testRemovingGivesTheShareAndFlattens() {
        var panes = PadPanes.single
        _ = panes.split(0, axis: .columns, keeping: claude, detail: [])
        _ = panes.split(1, axis: .rows, keeping: dev, detail: [])
        XCTAssertTrue(panes.remove(2))
        XCTAssertEqual(panes.root, .split(.columns, [.leaf(.init(id: 0, tab: claude)), .leaf(.init(id: 1, tab: dev))], [0.5, 0.5]))
        XCTAssertEqual(panes.focused, 1, "Removed while focused: the one before it at the end")
        XCTAssertTrue(panes.remove(0))
        XCTAssertFalse(panes.isSplit)
        XCTAssertFalse(panes.remove(1), "The last pane stays")

        var three = PadPanes.single
        _ = three.split(0, axis: .columns, keeping: claude, detail: [])
        _ = three.split(1, axis: .rows, keeping: dev, detail: [])
        _ = three.split(2, axis: .columns, keeping: zsh, detail: [])
        // 0 | (1 / (2 | 3)): removing 1 leaves 2 | 3 beside 0, one split across.
        three.remove(1)
        guard case .split(.columns, let children, let shares) = three.root else { return XCTFail("\(three.root)") }
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 0.0001)
    }

    /// Merge Panes joins the innermost split around the focused pane into it; outer splits stay.
    func testMergeJoinsTheInnermostSplit() {
        var panes = PadPanes.single
        _ = panes.split(0, axis: .columns, keeping: claude, detail: [])
        _ = panes.split(1, axis: .rows, keeping: dev, detail: [])
        XCTAssertEqual(Set(panes.merge()), [1])
        XCTAssertEqual(panes.root, .split(.columns, [.leaf(.init(id: 0, tab: claude)), .leaf(.init(id: 2))], [0.5, 0.5]))
        panes.merge()
        XCTAssertFalse(panes.isSplit)
        XCTAssertEqual(panes.focused, 2)
    }

    /// Panes and hairlines tile the column in whole points; a split needs both halves at the least a pane takes.
    func testLayoutAndRoom() {
        var panes = PadPanes.single
        _ = panes.split(0, axis: .columns, keeping: claude, detail: [])
        let layout = panes.layout(in: CGRect(origin: .zero, size: room))
        XCTAssertEqual(layout.panes[0], CGRect(x: 0, y: 0, width: 527, height: 1000))
        XCTAssertEqual(layout.panes[1], CGRect(x: 527.5, y: 0, width: 527.5, height: 1000))
        XCTAssertEqual(layout.dividers.map(\.frame), [CGRect(x: 527, y: 0, width: 0.5, height: 1000)])
        XCTAssertFalse(panes.canSplit(1, axis: .columns, in: room), "Two 263-point panes are narrower than a phone")
        XCTAssertTrue(panes.canSplit(1, axis: .rows, in: room))
        XCTAssertFalse(PadPanes.single.canSplit(0, axis: .columns, in: CGSize(width: 513, height: 1100)),
                       "An 11-inch upright beside the sidebar")
        XCTAssertTrue(PadPanes.single.canSplit(0, axis: .columns, in: CGSize(width: 834, height: 1100)), "Without it")
        XCTAssertFalse(PadPanes.single.canSplit(0, axis: .rows, in: CGSize(width: 834, height: 500)))
    }

    /// A drag moves the hairline, the two panes either side keeping `dragMinimum`.
    func testADragMovesOnlyItsHairline() throws {
        var panes = PadPanes.single
        _ = panes.split(0, axis: .columns, keeping: claude, detail: [])
        _ = panes.split(1, axis: .columns, keeping: dev, detail: [])
        let divider = try XCTUnwrap(panes.layout(in: CGRect(origin: .zero, size: room)).dividers.last)
        let moved = PadPanes.dragged(divider, to: 900)
        XCTAssertEqual(moved[0], 0.5, "The first pane keeps its share")
        XCTAssertEqual(moved[1] + moved[2], 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(moved[1], moved[2])
        let clamped = PadPanes.dragged(divider, to: 2000)
        XCTAssertEqual(clamped[2] * (room.width - 1), PadPanes.dragMinimum.width, accuracy: 0.5)
        panes.setShares(moved, at: divider.path)
        XCTAssertEqual(panes.layout(in: CGRect(origin: .zero, size: room)).dividers.last?.shares, moved)
    }

    /// The memory keeps the tree and the other panes' tabs; a tab gone since leaves its pane out, and one pane left is
    /// no split.
    func testTheMemoryKeepsTheTree() throws {
        var panes = PadPanes.single
        _ = panes.split(0, axis: .columns, keeping: claude, detail: [])
        _ = panes.split(1, axis: .rows, keeping: dev, detail: [])
        let data = try JSONEncoder().encode(panes.kept)
        let kept = try JSONDecoder().decode(PadPanes.Kept.self, from: data)
        let back = try XCTUnwrap(PadPanes(kept: kept) { _ in true })
        XCTAssertEqual(back.leaves.map(\.tab), [claude, dev, nil])
        XCTAssertNil(back.leaf(back.focused)?.tab, "The focused pane's tab is the remembered shown tab")
        let without = try XCTUnwrap(PadPanes(kept: kept) { $0 != dev })
        XCTAssertEqual(without.leaves.map(\.tab), [claude, nil])
        XCTAssertNil(PadPanes(kept: kept) { _ in false }, "One pane left")
    }

    // MARK: The navigator

    /// A tab opened beside the shown one takes the focus; the pane it left keeps its tab and the screens pushed over it.
    /// Focusing that pane again brings them back onto the path.
    func testTheFocusedPaneIsThePath() {
        let navigator = navigator()
        let preview = TabsRoute.files(claude, .preview("README.md"))
        navigator.path = [.tab(claude), preview]
        navigator.split(navigator.panes.focused, .columns, showing: dev)
        XCTAssertEqual(navigator.path, [.tab(dev)])
        XCTAssertEqual(navigator.paneTab(0), claude)
        XCTAssertEqual(navigator.paneDetail(0), [preview])
        XCTAssertEqual(navigator.panePath(0), [.tab(claude), preview])
        XCTAssertEqual(navigator.panes.otherTabs, [claude])

        navigator.focusPane(0)
        XCTAssertEqual(navigator.path, [.tab(claude), preview])
        XCTAssertEqual(navigator.paneTab(1), dev)
        navigator.stepPane(1)
        XCTAssertEqual(navigator.splitPath.tab, dev, "Next Pane")
        navigator.stepPane(1)
        XCTAssertEqual(navigator.splitPath.tab, claude, "Round the end")

        // A pane's own stack: Back in the other pane changes its screens only.
        navigator.focusPane(1)
        navigator.setPaneDetail(0, [])
        XCTAssertEqual(navigator.paneDetail(0), [])
        XCTAssertEqual(navigator.splitPath.tab, dev)
        // Its tab screen pushing (a file from Files) focuses it first.
        navigator.setPanePath(0, [.tab(claude), preview])
        XCTAssertEqual(navigator.panes.focused, 0)
        XCTAssertEqual(navigator.path, [.tab(claude), preview])
    }

    /// A pill, a sidebar row or Agents opening a tab another pane shows focuses that pane; any other tab shows in the
    /// focused pane. A tab opened beside a pane that shows it elsewhere moves there.
    func testATabShownElsewhereTakesTheFocusThere() {
        let navigator = navigator()
        navigator.path = [.tab(claude)]
        navigator.split(0, .columns, showing: dev)
        navigator.select(claude)
        XCTAssertEqual(navigator.panes.focused, 0)
        XCTAssertEqual(navigator.paneTab(1), dev)
        navigator.select(zsh)
        XCTAssertEqual(navigator.paneTab(0), zsh, "In the focused pane")
        navigator.openChat(dev)
        XCTAssertEqual(navigator.panes.focused, 1, "Agents' row")
        // A path set another way (the sidebar's stack) follows too.
        navigator.path = [.tab(zsh)]
        XCTAssertEqual(navigator.panes.focused, 0)
        XCTAssertEqual(navigator.paneTab(1), dev)

        XCTAssertFalse(navigator.canOpenBeside(dev, pane: 0, axis: .rows), "Shown already")
        XCTAssertTrue(navigator.canOpenBeside(claude, pane: 0, axis: .rows))
        navigator.split(0, .rows, showing: claude)
        XCTAssertEqual(navigator.panes.count, 3)
        navigator.split(2, .columns, showing: dev)
        XCTAssertEqual(navigator.panes.count, 3, "dev left its pane for the new one")
        XCTAssertEqual(navigator.splitPath.tab, dev)
        XCTAssertEqual(Set(navigator.panes.otherTabs), [zsh, claude])
    }

    /// A pane whose tab closes shows the next tab of its strip that no pane shows (else the one before); without one
    /// the pane goes, and the focus passes on. A space closing takes its panes.
    func testAPaneWhoseTabClosesShowsItsNeighbourOrGoes() {
        let navigator = navigator()
        navigator.path = [.tab(claude)]
        navigator.split(0, .columns, showing: dev)
        navigator.closed(.tab(claude))
        XCTAssertEqual(navigator.paneTab(0), zsh, "dev is shown: the next free one")
        XCTAssertEqual(navigator.splitPath.tab, dev, "The focus stays")
        navigator.closed(.tab(dev))
        XCTAssertEqual(navigator.splitPath.tab, claude, "The focused pane: the free one before it")
        XCTAssertEqual(navigator.panes.count, 2)

        navigator.select(docs)
        navigator.split(navigator.panes.focused, .rows, showing: tab(studio, "tmux:docs:@2"))
        XCTAssertEqual(navigator.panes.count, 3)
        navigator.closed(.space(SpaceRef(host: studio, key: "tmux:docs")))
        XCTAssertEqual(navigator.panes.count, 1, "Both docs panes went")
        XCTAssertEqual(navigator.splitPath.tab, zsh, "The pane left takes the focus")
    }

    /// The host closing a tab (another client, its shell's exit) hands its pane on as a close from here does.
    func testAPaneWhoseTabTheHostClosesHandsOn() {
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: UserDefaults(suiteName: "pad-panes-host-close")!)
        func sync(_ keys: [String]) {
            let sketch = TopologySketch(spaces: [.init(key: "herdr:app", name: "app", tabs: keys.map { key in
                .init(key: key, name: "zsh", panes: [.init(key: "p:" + key, cwd: "/Users/alex/src/app")])
            })])
            model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        }
        sync(["herdr:app:1", "herdr:app:2", "herdr:app:3", "herdr:app:4"])
        let navigator = navigator(model)
        let host = TabsFixtures.host.id
        func ref(_ n: Int) -> TabRef { TabRef(host: host, key: "herdr:app:\(n)") }
        navigator.path = [.tab(ref(2))]
        navigator.split(0, .columns, showing: ref(4))
        sync(["herdr:app:1", "herdr:app:2", "herdr:app:3", "herdr:app:4"])
        sync(["herdr:app:1", "herdr:app:3", "herdr:app:4"])
        XCTAssertEqual(navigator.paneTab(0), ref(3), "The other pane: its next")
        XCTAssertEqual(navigator.splitPath.tab, ref(4))
        sync(["herdr:app:3", "herdr:app:4"])
        sync(["herdr:app:3"])
        XCTAssertEqual(navigator.panes.count, 1, "No free neighbour: the pane went")
        XCTAssertEqual(navigator.splitPath.tab, ref(3))
    }

    /// Split Right and Down, Merge Panes and the pane steps apply in an iPad's split, as the room and the panes allow.
    func testTheCommandsFollowThePanes() {
        let navigator = navigator()
        navigator.path = [.tab(claude)]
        var enabled = navigator.enabledCommands(presenting: false)
        XCTAssertTrue(enabled.isSuperset(of: [.splitRight, .splitDown]))
        XCTAssertTrue(enabled.isDisjoint(with: [.mergePanes, .previousPane, .nextPane]))
        navigator.split(0, .columns, showing: dev)
        enabled = navigator.enabledCommands(presenting: false)
        XCTAssertFalse(enabled.contains(.splitRight), "No room for a third across")
        XCTAssertTrue(enabled.isSuperset(of: [.splitDown, .mergePanes, .previousPane, .nextPane]))
        navigator.mergePanes()
        XCTAssertFalse(navigator.panes.isSplit)
        XCTAssertEqual(navigator.splitPath.tab, dev)

        navigator.paneRoom = CGSize(width: 513, height: 500)
        XCTAssertTrue(navigator.enabledCommands(presenting: false).isDisjoint(with: [.splitRight, .splitDown]))
        let duo = SpacesNavigator(model: TabsSample.model())
        duo.split = true
        duo.paneRoom = room
        duo.path = [.tab(claude)]
        XCTAssertFalse(duo.canSplitPane(.columns), "The Duo's tab never splits")
    }

    /// A launch brings the panes back beside the shown tab; one whose tab the cached topology lost is left out. The stack
    /// shows the focused pane, and splitting again settles a pane that shows the stack's tab.
    func testPanesComeBackAtLaunchAndAfterTheStack() throws {
        let suite = "pad-panes-memory-\(UUID().uuidString)"
        let memory = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { memory.removePersistentDomain(forName: suite) }
        let first = SpacesNavigator(model: TabsSample.model(), memory: memory)
        first.restoreSplit(splits: true)
        first.paneRoom = room
        first.path = [.tab(claude)]
        first.split(0, .columns, showing: dev)
        first.split(first.panes.focused, .rows, showing: docs)
        XCTAssertNotNil(memory.data(forKey: SpacesNavigator.panesKey))

        let second = SpacesNavigator(model: TabsSample.model(), memory: memory)
        second.restoreSplit(splits: true)
        XCTAssertEqual(second.path, [.tab(docs)])
        XCTAssertEqual(second.panes.leaves.map(\.tab), [claude, dev, nil])

        second.split = false
        second.path = [.tab(dev)]
        second.split = true
        XCTAssertEqual(second.panes.count, 2, "dev's other pane went: the stack's tab is the focused one")
        XCTAssertEqual(second.splitPath.tab, dev)
        second.mergePanes()
        XCTAssertNil(memory.data(forKey: SpacesNavigator.panesKey), "No splits, nothing kept")
    }

    // MARK: Layouts

    /// The Mac's presets up to four panes, by their trees; ⌘D then ⇧⌘D in each half is a grid too.
    func testTheLayoutsAreTheMacsTrees() {
        var panes = PadPanes.single
        XCTAssertEqual(panes.preset, .single)
        _ = panes.split(0, axis: .columns, keeping: claude, detail: [])
        XCTAssertEqual(panes.preset, .columns)
        _ = panes.split(1, axis: .rows, keeping: dev, detail: [])
        XCTAssertNil(panes.preset, "One above one beside one is no preset")
        _ = panes.split(0, axis: .rows, keeping: nil, detail: [])
        XCTAssertEqual(panes.preset, .grid)
        XCTAssertEqual(PadLayout.allCases.map(\.title), ["Single", "Side by Side", "Stacked", "Two Above One", "Grid"])
        XCTAssertEqual(PadLayout.twoAbove.frames(in: CGRect(x: 0, y: 0, width: 1000, height: 800)).map(\.size),
                       [CGSize(width: 500, height: 400), CGSize(width: 499.5, height: 400), CGSize(width: 1000, height: 399.5)])
        XCTAssertTrue(PadLayout.grid.fits(CGSize(width: 889.5, height: 790)), "An 11-inch on its side beside the sidebar")
        XCTAssertFalse(PadLayout.grid.fits(CGSize(width: 513.5, height: 1166)), "Upright beside it")
        XCTAssertTrue(PadLayout.grid.fits(CGSize(width: 834, height: 1166)), "Upright without it")
    }

    /// A layout moves tabs, never starts one: the panes go where they overlap most, the focused one first and still
    /// focused; empty panes take the space's other tabs in strip order; too few tabs is refused as the Mac says it.
    func testALayoutPlacesTheTabsAndKeepsTheFocus() {
        let navigator = navigator()
        navigator.path = [.tab(dev)]
        XCTAssertEqual(navigator.layoutRefusal(.grid), "Grid needs 4 tabs. This space has 3.")
        XCTAssertNil(navigator.layoutRefusal(.twoAbove))
        navigator.applyLayout(.twoAbove)
        XCTAssertEqual(navigator.paneLayout, .twoAbove)
        XCTAssertEqual(navigator.splitPath.tab, dev, "The focus stays")
        XCTAssertEqual(navigator.panes.leaves.map { navigator.paneTab($0.id) }, [claude, zsh, dev],
                       "The pane where it overlaps most (the wide one below, as the Mac's); the others in strip order")
        navigator.applyLayout(.columns)
        XCTAssertEqual(navigator.panes.leaves.map { navigator.paneTab($0.id) }, [dev, zsh],
                       "The focused one first; claude, on the left, has no place left and stays in the strip")
        navigator.applyLayout(.rows)
        XCTAssertEqual(navigator.panes.leaves.map { navigator.paneTab($0.id) }, [dev, zsh], "Each where it overlaps most")
        navigator.focusPane(navigator.panes.leaves[1].id)
        navigator.applyLayout(.columns)
        XCTAssertEqual(navigator.panes.leaves.map { navigator.paneTab($0.id) }, [zsh, dev])
        XCTAssertEqual(navigator.splitPath.tab, zsh)

        // The same layout again evens its dividers.
        if let divider = navigator.panes.layout(in: CGRect(origin: .zero, size: room)).dividers.first {
            navigator.panes.setShares([0.7, 0.3], at: divider.path)
        }
        navigator.applyLayout(.columns)
        XCTAssertEqual(navigator.panes.layout(in: CGRect(origin: .zero, size: room)).dividers.first?.shares, [0.5, 0.5])
        navigator.applyLayout(.single)
        XCTAssertFalse(navigator.panes.isSplit)
        XCTAssertEqual(navigator.splitPath.tab, zsh)

        navigator.paneRoom = CGSize(width: 513.5, height: 1166)
        XCTAssertEqual(navigator.layoutRefusal(.columns), "Side by Side needs a larger window.")
        XCTAssertNil(navigator.layoutRefusal(.rows))
        let enabled = navigator.enabledCommands(presenting: false)
        XCTAssertTrue(enabled.contains(.layoutRows))
        XCTAssertFalse(enabled.contains(.layoutColumns))
        XCTAssertFalse(enabled.contains(.layoutSingle), "Already one pane")
    }

    /// Four agents in a grid: tabs another pane shows keep their place, and tabs from other spaces stay where they are.
    func testAGridOfAgents() {
        let navigator = navigator()
        navigator.path = [.tab(claude)]
        navigator.split(0, .columns, showing: docs)
        navigator.focusPane(0)
        navigator.applyLayout(.grid)
        XCTAssertEqual(navigator.paneLayout, .grid)
        XCTAssertEqual(navigator.panes.leaves.map { navigator.paneTab($0.id) }, [claude, docs, dev, zsh])
        XCTAssertEqual(navigator.splitPath.tab, claude)
    }

    /// As the Mac's unfocused panes: an empty composer folds to a Reply button in a pane that is not focused; a draft,
    /// a reply's quote, Reply itself or the composer's own focus keep it; the focused pane and a lone tab never fold.
    func testInactivePanesFoldTheirEmptyComposer() {
        func folds(inactive: Bool = true, replying: Bool = false, focused: Bool = false, quoting: Bool = false,
                   empty: Bool = true) -> Bool {
            ChatThreadView.folds(rail: false, inactivePane: inactive, replying: replying, focused: focused, quoting: quoting,
                                 empty: empty)
        }
        XCTAssertTrue(folds())
        XCTAssertFalse(folds(inactive: false), "The focused pane")
        XCTAssertFalse(folds(empty: false), "A draft stays in place")
        XCTAssertFalse(folds(quoting: true))
        XCTAssertFalse(folds(replying: true))
        XCTAssertFalse(folds(focused: true))
        XCTAssertTrue(ChatThreadView.folds(rail: true, inactivePane: false, replying: false, focused: false, quoting: false,
                                           empty: true), "A phone on its side, as before")
    }
}
