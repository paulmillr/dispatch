import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// Settings › Tabs only: no tab strips, the sidebar lists every tab, "+ space" becomes "+ tab".
@MainActor
final class TabsOnlyTests: XCTestCase {
    /// Off by default; a saved choice round-trips, and settings files written before it decode without it.
    func testPreferenceDefaultsOffAndRoundTrips() throws {
        func decode(_ json: String) throws -> Preferences { try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)) }
        XCTAssertFalse(try decode("{}").tabsOnly)
        XCTAssertTrue(try decode(#"{"tabsOnly":true}"#).tabsOnly)
        let directory = System.temporary.appendingPathComponent(System.uuid().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var preferences = store.values
        preferences.tabsOnly = true
        try store.save(preferences)
        XCTAssertTrue(SettingsStore(file: file).values.tabsOnly)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self).contains(#""tabsOnly":true"#))
    }

    /// Two spaces of two tabs each: [a1, a2, b1, b2], with b2 (the current space's focused pane's tab) active.
    private func fourTabs(_ workspace: Workspace) throws -> (a: UUID, b: UUID, tabs: [UUID]) {
        workspace.newSpace()
        let a1 = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newTab()
        let a2 = try XCTUnwrap(workspace.activeTab?.id)
        let a = try XCTUnwrap(workspace.selectedSpace)
        workspace.newSpace()
        let b1 = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newTab()
        let b2 = try XCTUnwrap(workspace.activeTab?.id)
        return (a, try XCTUnwrap(workspace.selectedSpace), [a1, a2, b1, b2])
    }

    /// The sidebar's list is every tab of every space, panes in reading order and each pane's tabs in order; the
    /// active row is the current space's focused pane's tab, and choosing a row anywhere selects its space, pane and
    /// tab. A split is one row, the space's, listing its panes' tabs; a tab moved into one of its panes shows there,
    /// and the one it covered goes to a row of its own. Listing spaces, every tab is a row.
    func testSidebarListsEveryTabInOrderAndSelectsAcrossSpaces() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let (a, b, tabs) = try fourTabs(workspace)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), tabs)
        XCTAssertEqual(workspace.sidebarTabs.map(\.space), [a, a, b, b])
        XCTAssertTrue(workspace.sidebarTabs.allSatisfy { !$0.window && $0.host == .local && $0.pane != nil })
        XCTAssertEqual(workspace.selectedSidebarTab, tabs[3])
        XCTAssertEqual(workspace.lastingTabCount, 4)
        workspace.selectSidebarTab(tabs[1])
        XCTAssertEqual(workspace.selectedSpace, a)
        XCTAssertEqual(workspace.activeTab?.id, tabs[1])
        XCTAssertEqual(workspace.selectedSidebarTab, tabs[1])
        // a2 moves into a pane on the right: space a is one row, a1 and a2 its lines in reading order.
        workspace.split(.columns)
        let space = try XCTUnwrap(workspace.current)
        XCTAssertEqual(space.panes.count, 2)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [a, tabs[2], tabs[3]])
        let row = workspace.sidebarTabs[0]
        XCTAssertTrue(row.split)
        XCTAssertNil(row.pane)
        XCTAssertEqual(row.members.map(\.id), [tabs[0], tabs[1]])
        XCTAssertEqual(row.members.map(\.pane), space.numberedPaneIDs)
        XCTAssertEqual(row.members.map(\.focused), [false, true])
        XCTAssertEqual(row.surfaceIDs, [tabs[0], tabs[1]])
        XCTAssertEqual(row.cells, [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])
        XCTAssertEqual(workspace.selectedSidebarTab, a)
        XCTAssertEqual(workspace.lastingTabCount, 3)
        // Choosing a line's tab focuses its pane; choosing the row elsewhere comes back to the pane it had focused.
        workspace.selectTab(tabs[0])
        XCTAssertEqual(workspace.current?.focusedPane, space.numberedPaneIDs[0])
        workspace.selectSidebarTab(tabs[3])
        workspace.selectSidebarTab(a)
        XCTAssertEqual(workspace.selectedSpace, a)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0])
        XCTAssertEqual(workspace.selectedSidebarTab, a)
        // b1 moves into a1's pane: it shows there, and a1 goes to the plain tabs nearest the split, b2's space.
        XCTAssertTrue(workspace.moveTab(tabs[2], to: space.numberedPaneIDs[0]))
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [a, tabs[3], tabs[0]])
        XCTAssertEqual(workspace.sidebarTabs[0].members.map(\.id), [tabs[2], tabs[1]])
        XCTAssertTrue(workspace.spaces.allSatisfy { $0.panes.count == 1 || $0.panes.allSatisfy { $0.tabs.count == 1 } })
        workspace.tabsOnly = false
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [tabs[2], tabs[1], tabs[3], tabs[0]], "Listing spaces, every tab is a row")
        XCTAssertTrue(workspace.sidebarTabs.allSatisfy(\.members.isEmpty))
    }

    /// A split made while spaces showed keeps its pane's other tabs behind the shown one. Turning tabs only on lifts
    /// them to rows of their own, so ⌘] and ⌘[ walk every row once and wrap: choosing a row never swaps another into
    /// its place.
    func testSplitsFromSpacesModeLiftTheirHiddenTabsAndSteppingWraps() throws {
        let workspace = Workspace()
        workspace.newSpace()
        let first = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newTab(); workspace.newTab()
        let third = try XCTUnwrap(workspace.activeTab?.id)
        let second = try XCTUnwrap(workspace.current?.tabs[1].id)
        workspace.toggleSplit(.columns)
        let beside = try XCTUnwrap(workspace.activeTab?.id)
        let split = try XCTUnwrap(workspace.current)
        XCTAssertEqual(split.panes.map { $0.tabs.count }, [3, 1], "Spaces' ⌘D leaves the pane's other tabs behind it")
        workspace.tabsOnly = true
        let lifted = try XCTUnwrap(workspace.spaces.first { $0.id != split.id })
        XCTAssertEqual(workspace.spaces.map(\.id), [split.id, lifted.id])
        XCTAssertEqual(lifted.tabs.map(\.id), [first, second])
        XCTAssertEqual(workspace.spaces[0].panes.map { $0.tabs.map(\.id) }, [[third], [beside]])
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [split.id, first, second])
        XCTAssertEqual(workspace.selectedSidebarTab, split.id)
        var forward: [UUID?] = []
        for _ in 0..<6 { workspace.cycleTab(1); forward.append(workspace.selectedSidebarTab) }
        XCTAssertEqual(forward, [first, second, split.id, first, second, split.id])
        var back: [UUID?] = []
        for _ in 0..<3 { workspace.cycleTab(-1); back.append(workspace.selectedSidebarTab) }
        XCTAssertEqual(back, [second, first, split.id])
        XCTAssertEqual(workspace.activeTab?.id, beside, "The split comes back with the pane it had focused")
        workspace.selectNumberedItem(at: 8)
        XCTAssertEqual(workspace.selectedSidebarTab, second, "⌘9 is the last row")
    }

    /// Grouped by host, a tab whose terminal reached another host lists under that host, and ⌘] walks the rows as
    /// they are drawn.
    func testSteppingFollowsTheHostGroups() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        workspace.spaceOrder = .tree
        let (_, _, tabs) = try fourTabs(workspace)
        let mini = HostID(rawValue: "ssh:mini")
        workspace.hosts.associate(tabs[0], context: TerminalHostContext(host: mini, generation: System.uuid(), state: .connected, authenticated: true))
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [tabs[1], tabs[2], tabs[3], tabs[0]])
        workspace.selectTab(tabs[3])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[1], "It wraps to the first row drawn")
        workspace.spaceOrder = .flat
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), tabs, "One list keeps the spaces' order")
    }

    /// ⌘-clicks mark rows (the first marks the active row too) without choosing one, a ⇧-click marks a range from
    /// the row last clicked, a plain click clears them. ⌘D splits the marked rows into a new space in the list's
    /// order (⌘⇧D's Stacked fits only two), where the first stood, focused on the active tab if it is one of them; the
    /// spaces they leave keep their other tabs, or go.
    func testMarkedRowsSplitTogether() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let (a, b, tabs) = try fourTabs(workspace)
        workspace.clickSidebarRow(tabs[1], .toggle)
        XCTAssertEqual(workspace.sidebarMarks, [tabs[1], tabs[3]], "The first ⌘-click marks the active row too")
        XCTAssertEqual(workspace.activeTab?.id, tabs[3], "Marking chooses nothing")
        workspace.clickSidebarRow(tabs[3], .toggle)
        XCTAssertEqual(workspace.sidebarMarks, [tabs[1]])
        workspace.clickSidebarRow(tabs[2], .range)
        XCTAssertEqual(workspace.sidebarMarks, [tabs[2], tabs[3]], "⇧ marks from the row last clicked")
        workspace.clickSidebarRow(tabs[0], .plain)
        XCTAssertTrue(workspace.sidebarMarks.isEmpty)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0])
        workspace.clickSidebarRow(tabs[2], .toggle)
        workspace.clickSidebarRow(tabs[1], .toggle)
        XCTAssertEqual(workspace.sidebarMarks, [tabs[0], tabs[1], tabs[2]])
        XCTAssertNil(workspace.sidebarSplitRefusal(workspace.sidebarMarks))
        XCTAssertTrue(workspace.canToggleSplit(.rows))
        workspace.toggleSplit(.rows)
        let split = try XCTUnwrap(workspace.current)
        XCTAssertFalse([a, b].contains(split.id))
        XCTAssertEqual(split.preset, .twoAbove)
        XCTAssertEqual(workspace.spaces.map(\.id), [split.id, b], "a went with its tabs; the split stands where it stood")
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [split.id, tabs[3]])
        XCTAssertEqual(workspace.sidebarTabs[0].members.map(\.id), [tabs[0], tabs[1], tabs[2]])
        XCTAssertEqual(workspace.activeTab?.id, tabs[0], "The active tab keeps focus")
        XCTAssertEqual(workspace.selectedSidebarTab, split.id)
        XCTAssertTrue(workspace.sidebarMarks.isEmpty)
        XCTAssertEqual(split.tabs.count, 3)
        XCTAssertTrue(split.panes.allSatisfy { $0.tabs.count == 1 })
    }

    /// A split takes two to four tabs on one host, and no tmux or herdr window.
    func testSplitRefusesWindowsOtherHostsAndMoreThanFour() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        workspace.spaceOrder = .flat
        let (_, b, tabs) = try fourTabs(workspace)
        workspace.newTab()
        let fifth = try XCTUnwrap(workspace.activeTab?.id)
        XCTAssertEqual(workspace.sidebarSplitRefusal([tabs[0]]), "Choose two or more tabs")
        XCTAssertEqual(workspace.sidebarSplitRefusal(Set(tabs + [fifth])), "A split holds at most 4 tabs")
        XCTAssertFalse(workspace.splitSidebarRows(Set(tabs + [fifth])))
        XCTAssertEqual(workspace.sidebarTabs.count, 5)
        let index = try XCTUnwrap(workspace.spaces.firstIndex { $0.id == b })
        workspace.spaces[index].hostID = HostID(rawValue: "ssh:mini")
        XCTAssertEqual(workspace.sidebarSplitRefusal([tabs[0], tabs[2]]), "Tabs on different hosts can't share a split")
        XCTAssertNil(workspace.sidebarSplitRefusal([tabs[2], tabs[3]]))
        let terminal = TerminalTab(directory: "/tmp")
        var session = Space(name: "session", tab: terminal)
        session.backend = 7
        session.containers = [ContainerTab(id: System.uuid(), node: 1, name: "one", arrangement: PaneArrangement(tab: terminal))]
        workspace.spaces.append(session)
        XCTAssertEqual(workspace.sidebarSplitRefusal([tabs[0], session.containers[0].id]), "Tabs and tmux or herdr windows can't share a split")
    }

    /// Tabs only's ⌘D on a tab among others moves it to a space of its own after them, where the new tab splits
    /// beside it; ⌘T while the split shows makes a row in the plain tabs' space before it; ⌘D again pops the other
    /// pane out there rather than merging the two into one pane.
    func testCommandDSplitsTheTabAloneAndNewTabsStayRows() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        workspace.newSpace()
        let first = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newTab()
        let second = try XCTUnwrap(workspace.activeTab?.id)
        let home = try XCTUnwrap(workspace.selectedSpace)
        XCTAssertTrue(workspace.canToggleSplit(.columns))
        workspace.toggleSplit(.columns)
        let split = try XCTUnwrap(workspace.current)
        XCTAssertNotEqual(split.id, home)
        let added = try XCTUnwrap(workspace.activeTab?.id)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [first, split.id])
        XCTAssertEqual(workspace.sidebarTabs[1].members.map(\.id), [second, added])
        workspace.newTab()
        let third = try XCTUnwrap(workspace.activeTab?.id)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [first, third, split.id])
        XCTAssertEqual(workspace.selectedSidebarTab, third)
        XCTAssertEqual(workspace.spaces.first { $0.id == home }?.tabs.map(\.id), [first, third])
        XCTAssertEqual(workspace.spaces.first { $0.id == split.id }?.tabs.count, 2, "The split took no hidden tab")
        workspace.selectTab(second)
        workspace.toggleSplit(.columns)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [first, third, added, second])
        XCTAssertEqual(workspace.activeTab?.id, second)
        XCTAssertTrue(workspace.spaces.allSatisfy { $0.panes.count == 1 })
    }

    /// A tab dropped on a split's line joins it there: two panes grow to two above one, then a grid, and four is the
    /// most. One moved within trades places, the panes and their order staying; Layout lays a split out again in its
    /// reading order.
    func testTabsJoinAndMoveWithinASplit() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let (_, _, tabs) = try fourTabs(workspace)
        XCTAssertTrue(workspace.splitSidebarRows([tabs[0], tabs[1]], preset: .rows))
        let split = try XCTUnwrap(workspace.current).id
        XCTAssertEqual(workspace.current?.preset, .rows)
        workspace.arrangeSplit(split, .columns)
        XCTAssertEqual(workspace.current?.preset, .columns)
        XCTAssertEqual(workspace.sidebarTabs[0].members.map(\.id), [tabs[0], tabs[1]])
        XCTAssertEqual(workspace.sidebarTabs[0].cells.first, CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertTrue(workspace.canAddToSplit(tabs[2], space: split))
        XCTAssertTrue(workspace.addToSplit(tabs[2], space: split, relativeTo: tabs[0], after: true))
        XCTAssertEqual(workspace.sidebarTabs[0].members.map(\.id), [tabs[0], tabs[2], tabs[1]])
        XCTAssertEqual(workspace.current?.preset, .twoAbove)
        XCTAssertEqual(workspace.activeTab?.id, tabs[2])
        XCTAssertTrue(workspace.addToSplit(tabs[3], space: split, relativeTo: nil, after: false))
        XCTAssertEqual(workspace.current?.preset, .grid)
        XCTAssertEqual(workspace.spaces.map(\.id), [split], "The spaces the tabs left went with them")
        workspace.newTab()
        let fifth = try XCTUnwrap(workspace.activeTab?.id)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [split, fifth], "With no plain tabs, a new tab gets a space after the split")
        XCTAssertFalse(workspace.canAddToSplit(fifth, space: split), "Four is the most")
        let panes = try XCTUnwrap(workspace.spaces.first { $0.id == split }).numberedPaneIDs
        XCTAssertTrue(workspace.addToSplit(tabs[0], space: split, relativeTo: tabs[3], after: true))
        let moved = try XCTUnwrap(workspace.spaces.first { $0.id == split })
        XCTAssertEqual(moved.numberedPaneIDs, panes, "Moving within keeps the panes")
        XCTAssertEqual(workspace.sidebarTabs[0].members.map(\.id), [tabs[2], tabs[1], tabs[3], tabs[0]])
        XCTAssertEqual(workspace.activeTab?.id, tabs[0])
    }

    /// Pop Out takes a split's tab to the plain tabs before it on its host; a split down to one tab is a plain row;
    /// Separate All takes every tab out, the focused one still shown.
    func testPopOutAndSeparateAll() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let (a, _, tabs) = try fourTabs(workspace)
        XCTAssertTrue(workspace.splitSidebarRows([tabs[2], tabs[3]]))
        let split = try XCTUnwrap(workspace.current).id
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [tabs[0], tabs[1], split])
        workspace.popOutOfSplit(tabs[2])
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), tabs)
        XCTAssertEqual(workspace.spaces.first { $0.id == a }?.tabs.map(\.id), [tabs[0], tabs[1], tabs[2]])
        XCTAssertEqual(workspace.activeTab?.id, tabs[3], "The split's focus stays")
        XCTAssertTrue(workspace.splitSidebarRows([tabs[0], tabs[3]]))
        let again = try XCTUnwrap(workspace.current).id
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [tabs[1], tabs[2], again])
        workspace.separateSplit(again)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [tabs[1], tabs[2], tabs[0], tabs[3]])
        XCTAssertEqual(workspace.spaces.map(\.id), [a])
        XCTAssertEqual(workspace.activeTab?.id, tabs[3])
    }

    /// ⌘1…9 and ⌘[ / ⌘] (⌃⇥) walk the sidebar's list across spaces and panes, ⌘9 landing on the last tab. Off,
    /// they number and step through the focused pane's tabs as before.
    func testTabDigitsAndSteppingWalkTheList() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let (_, _, tabs) = try fourTabs(workspace)
        workspace.selectNumberedItem(at: 0)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[1])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[2], "Stepping crosses into the next space")
        workspace.cycleTab(-1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[1])
        workspace.selectNumberedItem(at: 8)
        XCTAssertEqual(workspace.activeTab?.id, tabs[3], "9 is the last tab")
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0], "Stepping wraps")
        workspace.selectNumberedItem(at: 2)
        XCTAssertEqual(workspace.activeTab?.id, tabs[2])
        workspace.selectNumberedItem(at: 4)
        XCTAssertEqual(workspace.activeTab?.id, tabs[2], "A digit past the list does nothing")
        workspace.tabsOnly = false
        workspace.selectTab(tabs[0])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[1])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0], "Off, stepping stays in the focused pane")
        workspace.selectNumberedItem(at: 2)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0], "Off, the digits number the pane's own tabs")
    }

    /// The Spaces digits (⌘⇧1…9) and steps (⌘⇧[ / ⌘⇧]) do what the Tabs ones do: tabs only shows no spaces to
    /// choose. Listing spaces, they choose spaces again.
    func testSpaceKeysChooseRows() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let (a, _, tabs) = try fourTabs(workspace)
        workspace.selectSpace(at: 2)
        XCTAssertEqual(workspace.activeTab?.id, tabs[2])
        workspace.selectSpace(at: 8)
        XCTAssertEqual(workspace.activeTab?.id, tabs[3], "9 is the last row")
        workspace.cycleSpace(1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[0], "Stepping wraps through the rows")
        workspace.cycleSpace(-1)
        XCTAssertEqual(workspace.activeTab?.id, tabs[3])
        workspace.tabsOnly = false
        workspace.selectSpace(at: 0)
        XCTAssertEqual(workspace.selectedSpace, a)
    }

    /// The sidebar hides with one tab (as it hides with one space otherwise) and shows with two, in one space.
    func testSidebarHidesWithOneTabInsteadOfOneSpace() throws {
        let controller = AppDelegate()
        controller.settings.values = Preferences()
        let workspace = controller.workspace
        workspace.tabsOnly = true
        workspace.newSpace()
        XCTAssertFalse(controller.sidebarVisible)
        workspace.newTab()
        XCTAssertTrue(controller.sidebarVisible, "Two tabs list in the sidebar")
        workspace.tabsOnly = false
        XCTAssertFalse(controller.sidebarVisible, "Listing spaces, one space hides it")
        workspace.tabsOnly = true
        workspace.closeTab(try XCTUnwrap(workspace.activeTab?.id))
        XCTAssertFalse(controller.sidebarVisible)
        controller.settings.values.hideSingleSpace = false
        XCTAssertTrue(controller.sidebarVisible)
    }

    /// A tmux or herdr space lists its windows, one row each in its strip's order, with every pane's terminal.
    func testStructuredSpaceListsItsWindows() throws {
        let workspace = Workspace()
        workspace.tabsOnly = true
        let first = TerminalTab(directory: "/tmp"), second = TerminalTab(directory: "/tmp"), beside = TerminalTab(directory: "/tmp")
        var space = Space(name: "session", tab: first)
        space.backend = 7
        var split = PaneArrangement(tab: second)
        let pane = Pane(tabs: [beside])
        split.layout = split.layout.splitting(split.panes[0].id, with: pane.id, axis: .columns)
        split.panes.append(pane)
        space.containers = [ContainerTab(id: System.uuid(), node: 1, name: "one", arrangement: PaneArrangement(tab: first)),
                            ContainerTab(id: System.uuid(), node: 2, name: "two", arrangement: split)]
        space.selectedContainer = space.containers[0].id
        workspace.spaces = [space]
        workspace.selectedSpace = space.id
        let rows = workspace.sidebarTabs
        XCTAssertEqual(rows.map(\.id), space.containers.map(\.id))
        XCTAssertTrue(rows.allSatisfy { $0.window && $0.pane == nil })
        XCTAssertEqual(rows.map(\.surfaceIDs), [[first.id], [second.id, beside.id]])
        // A window with panes lists them a line each, but is no split of tabs.
        XCTAssertEqual(rows.map { $0.members.map(\.id) }, [[], [second.id, beside.id]])
        XCTAssertFalse(rows[1].split)
        XCTAssertEqual(rows[1].tabIDs, [rows[1].id])
        XCTAssertEqual(workspace.selectedSidebarTab, space.containers[0].id)
        workspace.selectSidebarTab(space.containers[1].id)
        XCTAssertEqual(workspace.selectedSidebarTab, space.containers[1].id)
        XCTAssertEqual(workspace.activeTab?.id, second.id)
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.selectedSidebarTab, space.containers[0].id, "Stepping wraps through the windows")
    }

    /// No strip shows for any pane, the new-space titles say tab, and the Tabs digits number the list's rows with
    /// the last one on 9 (none while the group is unbound).
    func testStripsHideAndTitlesSayTab() throws {
        let workspace = Workspace()
        workspace.newSpace(); workspace.newTab()
        let space = try XCTUnwrap(workspace.current), pane = try XCTUnwrap(space.activePane)
        XCTAssertTrue(PaneView.showsTabs(pane: pane, space: space, tabsOnly: false))
        XCTAssertFalse(PaneView.showsTabs(pane: pane, space: space, tabsOnly: true))
        XCTAssertEqual(NewSpaceMenu.noun("New tmux space", tabs: true), "New tmux tab")
        XCTAssertEqual(NewSpaceMenu.noun("New space on dev", tabs: true), "New tab on dev")
        XCTAssertEqual(NewSpaceMenu.noun("New local space", tabs: true), "New local tab")
        XCTAssertEqual(NewSpaceMenu.noun("New space here", tabs: false), "New space here")
        let ids = (0..<10).map { _ in System.uuid() }
        let shortcuts = StripSpaceMenu.shortcuts(ids, keys: KeyGroups(), group: \.tabs)
        XCTAssertEqual(shortcuts[ids[0]], "⌘1")
        XCTAssertEqual(shortcuts[ids[7]], "⌘8")
        XCTAssertEqual(shortcuts[ids[8]], "")
        XCTAssertEqual(shortcuts[ids[9]], "⌘9")
        var unbound = KeyGroups()
        unbound.tabs = []
        XCTAssertEqual(StripSpaceMenu.shortcuts(ids, keys: unbound, group: \.tabs)[ids[0]], "")
    }

    /// The window: an empty one offers New Tab alone; with tabs, the sidebar lists them under "+ tab" with no strip
    /// above the panes, the title is the tab's alone, a row's click selects its tab, and grouping by host keeps the
    /// rows under Local.
    func testSidebarListsTabsAndTheWindowHasNoStrip() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        var preferences = Preferences.flat
        preferences.tabsOnly = true
        preferences.spaceOrder = .flat
        preferences.hideSingleSpace = true
        runtime.workspace = workspace; runtime.start(preferences: preferences)
        workspace.onCloseTabs = { runtime.close($0) }
        controller.settings.values = preferences
        XCTAssertTrue(workspace.tabsOnly, "The runtime mirrors the preference as it starts")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        let empty = try await capture(window, "tabs-only-empty").text()
        XCTAssertTrue(empty.contains("New Tab"), empty)
        XCTAssertFalse(empty.contains("New Space"), "Tabs only makes tabs: \(empty)")
        workspace.newSpace(); workspace.newTab(); workspace.newSpace(); workspace.newTab()
        let titles = ["billing", "tests", "docs", "shell"]
        for (index, tab) in workspace.sidebarTabs.enumerated() { workspace.updateTab(tab.id, customTitle: titles[index]) }
        let snapshot = try await capture(window, "tabs-only-flat")
        let sidebar = try sidebarText(snapshot, window: window)
        for label in titles + ["+ tab"] { XCTAssertTrue(sidebar.contains(label), sidebar) }
        XCTAssertFalse(sidebar.contains("+ space"), sidebar)
        let strips = PresentationTestSupport.accessibilityFrames(matching: {
            $0.hasPrefix("tab-") && UUID(uuidString: String($0.dropFirst(4))) != nil
        }, in: window)
        XCTAssertTrue(strips.isEmpty, "No strip tabs: \(strips)")
        XCTAssertEqual(PresentationTestSupport.accessibilityFrames(matching: { $0.hasPrefix("sidebar-tab-") }, in: window).count, 4)
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("sidebar-new-tab", in: window).isEmpty)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("sidebar-new-space", in: window).isEmpty)
        try await TestSupport.eventually { window.title == "shell" }
        let first = workspace.sidebarTabs[0].id
        let row = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("sidebar-tab-\(first)", in: window).first)
        try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: row.midX, y: row.midY))
        try await TestSupport.eventually { workspace.activeTab?.id == first }
        try await TestSupport.eventually { window.title == "billing" }
        controller.settings.values.spaceOrder = .tree
        let tree = try sidebarText(try await capture(window, "tabs-only-tree"), window: window)
        XCTAssertTrue(tree.contains("Local"), tree)
        for label in titles { XCTAssertTrue(tree.contains(label), tree) }
    }

    /// The Next / Previous Tab and Space items (⌘] ⌘[ ⌘⇧] ⌘⇧[) and the digits' items stay enabled while the active
    /// row is a space's only tab or a split: tabs only steps and numbers the rows, not the current space's tabs.
    func testStepAndDigitItemsCountRows() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        var preferences = Preferences.flat
        preferences.tabsOnly = true
        runtime.workspace = workspace; runtime.start(preferences: preferences)
        workspace.onCloseTabs = { runtime.close($0) }
        controller.settings.values = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        try await TestSupport.eventually { NSApp.keyWindow === window }
        workspace.newSpace(); workspace.newSpace(); workspace.newTab()
        let rows = workspace.sidebarTabs.map(\.id)
        XCTAssertEqual(rows.count, 3)
        func enabled(_ action: Selector, tag: Int = 0) -> Bool {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            return controller.validateMenuItem(item)
        }
        workspace.selectSidebarTab(rows[0])
        XCTAssertEqual(workspace.currentTabs.count, 1, "The first space holds one tab")
        XCTAssertTrue(enabled(#selector(AppDelegate.nextTab)))
        XCTAssertTrue(enabled(#selector(AppDelegate.previousTab)))
        XCTAssertTrue(enabled(#selector(AppDelegate.nextSpace)))
        XCTAssertTrue(enabled(#selector(AppDelegate.selectNumberedItem(_:)), tag: 2))
        XCTAssertFalse(enabled(#selector(AppDelegate.selectNumberedItem(_:)), tag: 3))
        XCTAssertTrue(enabled(#selector(AppDelegate.selectSpace(_:)), tag: 2))
        XCTAssertTrue(enabled(#selector(AppDelegate.selectSpace(_:)), tag: 8))
        controller.nextTab()
        XCTAssertEqual(workspace.selectedSidebarTab, rows[1])
        XCTAssertTrue(workspace.splitSidebarRows([rows[1], rows[2]]))
        let split = try XCTUnwrap(workspace.current).id
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [rows[0], split])
        XCTAssertTrue(enabled(#selector(AppDelegate.nextTab)), "A split is a row to step from")
        controller.nextTab()
        XCTAssertEqual(workspace.selectedSidebarTab, rows[0])
        workspace.tabsOnly = false
        workspace.selectSpace(workspace.spaces[0].id)
        XCTAssertFalse(enabled(#selector(AppDelegate.nextTab)), "Listing spaces, a space of one tab has none to step to")
    }

    /// The window: ⌘-clicks mark rows without choosing one; a split is one row with a line per tab, in every sidebar
    /// style, and a line's click focuses its pane.
    func testSplitRowInTheWindow() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        var preferences = Preferences.flat
        preferences.tabsOnly = true
        preferences.spaceOrder = .flat
        preferences.sidebarStyle = .large
        runtime.workspace = workspace; runtime.start(preferences: preferences)
        workspace.onCloseTabs = { runtime.close($0) }
        controller.settings.values = preferences
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        workspace.newSpace(); workspace.newTab(); workspace.newSpace(); workspace.newTab()
        let titles = ["billing", "tests", "docs", "shell"]
        let tabs = workspace.sidebarTabs.map(\.id)
        for (index, tab) in tabs.enumerated() { workspace.updateTab(tab, customTitle: titles[index]) }
        _ = try await capture(window, "tabs-only-split-before")
        for id in [tabs[1], tabs[2]] {
            let row = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("sidebar-tab-\(id)", in: window).first)
            try PresentationTestSupport.click(window, at: NSPoint(x: row.midX, y: row.midY), modifierFlags: .command)
        }
        try await TestSupport.eventually { workspace.sidebarMarks == [tabs[1], tabs[2], tabs[3]] }
        XCTAssertEqual(workspace.activeTab?.id, tabs[3], "Marking chooses nothing")
        _ = try await capture(window, "tabs-only-marked")
        workspace.clickSidebarRow(tabs[3], .toggle)
        XCTAssertTrue(workspace.splitSidebarRows(workspace.sidebarMarks))
        let split = try XCTUnwrap(workspace.current).id
        XCTAssertEqual(workspace.activeTab?.id, tabs[1])
        for style in [SidebarStyle.large, .icons, .compact] {
            controller.settings.values.sidebarStyle = style
            _ = try await capture(window, "tabs-only-split-\(style.rawValue)")
            // Each row and line says its tab's name (read from accessibility: Vision misreads some styles' rows).
            for (index, title) in titles.enumerated() {
                let identifier = index == 1 || index == 2 ? "sidebar-split-member-\(tabs[index])" : "sidebar-tab-\(tabs[index])"
                let labels = PresentationTestSupport.accessibilityLabels(identifier, in: window)
                XCTAssertTrue(labels.contains { $0.contains(title) }, "\(style) \(title): \(labels)")
            }
            let lines = PresentationTestSupport.accessibilityFrames(matching: { $0.hasPrefix("sidebar-split-member-") }, in: window)
            XCTAssertEqual(lines.count, 2, "\(style)")
            XCTAssertEqual(PresentationTestSupport.accessibilityFrames(matching: { $0.hasPrefix("sidebar-tab-") }, in: window).count, 3,
                           "billing, the split, shell: \(style)")
        }
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [tabs[0], split, tabs[3]])
        let docs = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("sidebar-split-member-\(tabs[2])", in: window).first)
        try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: docs.midX, y: docs.midY))
        try await TestSupport.eventually { workspace.activeTab?.id == tabs[2] }
        XCTAssertEqual(workspace.selectedSidebarTab, split)
        _ = try await capture(window, "tabs-only-split-docs")
    }

    /// Three spaces of one tmux session (A, B, C), two windows each (A1 A2 …), listed as tabs: the windows' names.
    private func tmuxRows(_ app: TmuxWalkthrough) async throws -> [UUID: String] {
        let workspace = app.workspace
        app.controller.settings.values.tabsOnly = true
        app.controller.settings.values.spaceOrder = .flat
        workspace.tabsOnly = true
        workspace.spaceOrder = .flat
        try await app.attach()
        for count in 2...3 {
            workspace.newSpace()
            try await app.wait {
                workspace.spaces.filter(\.structured).count == count
                    && workspace.spaces.filter(\.structured).flatMap(\.tabs).allSatisfy { !$0.isConnecting }
            }
        }
        for space in workspace.spaces.filter(\.structured) {
            workspace.selectSpace(space.id)
            workspace.newTab()
            try await app.wait {
                workspace.spaces.first { $0.id == space.id }?.windows.count == 2
                    && workspace.spaces.flatMap(\.tabs).allSatisfy { !$0.isConnecting }
            }
        }
        try await app.ready()
        var names: [UUID: String] = [:]
        for (s, space) in workspace.spaces.filter(\.structured).enumerated() {
            for (w, window) in space.windows.enumerated() { names[window.id] = "\(["A", "B", "C"][s])\(w + 1)" }
        }
        return names
    }

    /// Three spaces of a tmux session (window groups), two windows each, listed as tabs: dragging a window row before
    /// or after another moves it there, within its space or into another, the first row of a space included (a window
    /// arriving in a space takes the place its server gave it).
    func testTmuxWindowRowsReorderAcrossSpaces() async throws {
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        let workspace = app.workspace
        let names = try await tmuxRows(app)
        let ids = Dictionary(uniqueKeysWithValues: names.map { ($1, $0) })
        func order() -> [String] { workspace.sidebarTabs.compactMap { names[$0.id] } }
        XCTAssertEqual(order(), ["A1", "A2", "B1", "B2", "C1", "C2"])
        func drag(_ source: String, _ target: String, after: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
            try await Task.sleep(for: .milliseconds(200))
            let trackers = PresentationTestSupport.views(of: ReorderTrackingView.self, in: try XCTUnwrap(app.window.contentView))
            let from = try XCTUnwrap(trackers.first { $0.configuration.item == .window(ids[source]!) }, file: file, line: line)
            let to = try XCTUnwrap(trackers.first { $0.configuration.item == .window(ids[target]!) }, file: file, line: line)
            var expected = order().filter { $0 != source }
            let index = try XCTUnwrap(expected.firstIndex(of: target))
            expected.insert(source, at: after ? index + 1 : index)
            let start = from.convert(NSPoint(x: 40, y: from.bounds.midY), to: nil)
            let end = to.convert(NSPoint(x: 40, y: after ? to.bounds.maxY - 4 : 4), to: nil)
            var events = try [PresentationTestSupport.mouseEvent(.leftMouseDragged, in: app.window, at: end),
                              PresentationTestSupport.mouseEvent(.leftMouseUp, in: app.window, at: end)]
            from.trackMouse(with: try PresentationTestSupport.mouseEvent(.leftMouseDown, in: app.window, at: start)) {
                events.isEmpty ? nil : events.removeFirst()
            }
            try await TestSupport.eventually(file: file, line: line, diagnostic: "\(source) \(after ? "after" : "before") \(target): \(order())") {
                app.runtime.helpers.values.allSatisfy { $0.operations == 0 } && order() == expected
            }
            XCTAssertNil(app.error, file: file, line: line)
        }
        try await drag("A2", "A1", after: false)
        try await drag("A1", "B2", after: true)
        try await drag("C1", "A2", after: false)
        try await drag("B1", "C2", after: true)
        try await drag("C2", "B2", after: false)
        try await drag("A2", "C1", after: true)
        try await drag("B2", "A1", after: true)
        XCTAssertEqual(order(), ["C1", "A2", "C2", "A1", "B2", "B1"])
    }

    /// A tmux or herdr space whose window groups hold one window each, all of its windows, is a split: one row, a
    /// line per window, laid out again by Layout. Groups holding several windows (made while spaces showed) fold into
    /// one strip, so a window's row shows that window alone.
    func testWindowGroupsAreSplitsOrFold() throws {
        let workspace = Workspace()
        func session(_ count: Int) -> Space {
            let tabs = (0..<count).map { _ in TerminalTab(directory: "/tmp") }
            var space = Space(name: "session", tab: tabs[0])
            space.backend = 7
            space.containers = tabs.enumerated().map { index, tab in
                ContainerTab(id: System.uuid(), node: UInt64(index + 1), name: "w\(index)", arrangement: PaneArrangement(tab: tab))
            }
            space.selectedContainer = space.containers[0].id
            space.presentation = TabPresentation(windows: space.containers.map(\.id), selected: space.containers[0].id, preset: .columns)
            return space
        }
        let pair = session(2), three = session(3)
        workspace.spaces = [pair, three]
        workspace.selectedSpace = pair.id
        workspace.tabsOnly = true
        XCTAssertTrue(Workspace.windowSplit(workspace.spaces[0]))
        XCTAssertEqual(workspace.spaces[1].presentation?.groups.count, 1, "Mixed groups fold into one strip")
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [pair.id] + (three.presentation?.orderedWindows ?? []),
                       "A folded strip keeps the order its groups showed")
        let row = workspace.sidebarTabs[0]
        XCTAssertTrue(row.windows && row.split && row.multiplexed)
        XCTAssertEqual(row.members.map(\.id), pair.containers.map(\.id))
        XCTAssertEqual(row.members.map(\.focused), [true, false])
        XCTAssertEqual(workspace.selectedSidebarTab, pair.id)
        XCTAssertEqual(workspace.current?.panes.count, 2)
        workspace.arrangeSplit(pair.id, .rows)
        XCTAssertEqual(workspace.spaces[0].presentation?.preset, .rows)
        XCTAssertEqual(workspace.sidebarTabs[0].members.map(\.id), pair.containers.map(\.id))
        XCTAssertEqual(workspace.sidebarTabs[0].cells.first, CGRect(x: 0, y: 0, width: 1, height: 0.5))
    }

    /// Marked tmux windows of two spaces split in Dispatch: they move into a space of their own (a retag on the server:
    /// every window, pane and process stays) and show side by side, one row with a line per window, while another
    /// window's row shows it alone. ⌘T while the split shows makes a window elsewhere; Pop Out takes a window back out
    /// (the split down to one window is a plain row); ⌘D on a window among others gives it a space of its own.
    func testTmuxWindowsSplitInDispatch() async throws {
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        let workspace = app.workspace
        let names = try await tmuxRows(app)
        let ids = Dictionary(uniqueKeysWithValues: names.map { ($1, $0) })
        func server() throws -> Set<String> {
            Set(try app.server(["list-panes", "-a", "-F", "#{window_id}|#{pane_id}|#{pane_pid}"]).split(separator: "\n").map(String.init))
        }
        func settled(_ condition: @escaping () -> Bool) async throws {
            try await TestSupport.eventually(diagnostic: "spaces \(workspace.spaces.map { $0.containers.map { names[$0.id] ?? "new" } }); \(app.error ?? "no error")") {
                app.runtime.helpers.values.allSatisfy { $0.operations == 0 } && condition()
            }
        }
        func splitSpace() -> Space? { workspace.spaces.first { Workspace.windowSplit($0) } }
        let before = try server()
        let a1 = try XCTUnwrap(ids["A1"]), a2 = try XCTUnwrap(ids["A2"]), b1 = try XCTUnwrap(ids["B1"])
        let launcher = try XCTUnwrap(workspace.sidebarTabs.first { !$0.multiplexed }).id
        XCTAssertEqual(workspace.sidebarSplitRefusal([a1, launcher]), "Tabs and tmux or herdr windows can't share a split")
        workspace.sidebarMarks = [a1, b1]
        XCTAssertTrue(workspace.canToggleSplit(.columns))
        workspace.toggleSplit(.columns)
        try await settled { splitSpace().map { Set($0.containers.map(\.id)) == [a1, b1] } == true }
        let split = try XCTUnwrap(splitSpace())
        let row = try XCTUnwrap(workspace.sidebarTabs.first { $0.id == split.id })
        XCTAssertTrue(row.windows)
        XCTAssertEqual(row.members.map(\.id), [a1, b1])
        XCTAssertEqual(split.presentation?.preset, .columns)
        XCTAssertEqual(workspace.selectedSidebarTab, split.id)
        XCTAssertEqual(workspace.current?.panes.count, 2, "Both windows show")
        XCTAssertTrue(workspace.sidebarMarks.isEmpty)
        XCTAssertEqual(try server(), before, "Only Dispatch's window groups changed: every window, pane and process stays")
        try await Task.sleep(for: .milliseconds(450))
        _ = try await PresentationTestSupport.capture(app.window, named: "tmux-window-split", in: "tabs-only-validation")
        workspace.selectSidebarTab(a2)
        XCTAssertEqual(workspace.current?.panes.count, 1, "Another window's row shows it alone")
        workspace.selectSidebarTab(split.id)
        workspace.newTab()
        try await settled {
            workspace.spaces.flatMap(\.containers).count == 7 && !workspace.spaces.flatMap(\.tabs).contains(where: \.isConnecting)
        }
        XCTAssertEqual(splitSpace()?.containers.count, 2, "The new window goes to another space")
        workspace.popOutOfSplit(b1)
        try await settled { splitSpace() == nil && (workspace.spaces.first { $0.containers.contains { $0.id == b1 } }?.containers.count ?? 0) > 1 }
        XCTAssertTrue(workspace.sidebarTabs.contains { $0.id == a1 }, "A split down to one window is a plain row")
        let home = try XCTUnwrap(workspace.spaces.first { $0.containers.contains { $0.id == a2 } })
        XCTAssertGreaterThan(home.containers.count, 1)
        workspace.selectWindow(a2)
        workspace.toggleSplit(.columns)
        try await settled { workspace.spaces.contains { $0.containers.map(\.id) == [a2] } }
        XCTAssertNil(app.error)
    }

    private func sidebarText(_ snapshot: PresentationTestSupport.Snapshot, window: NSWindow) throws -> String {
        // Keep terminal text from interleaving with sidebar rows in Vision's reading order (the 264-point sidebar).
        let width = try XCTUnwrap(window.contentView).bounds.width
        return try snapshot.text(in: CGRect(x: 0, y: 0, width: 264 / width, height: 1))
    }

    private func capture(_ window: NSWindow, _ name: String) async throws -> PresentationTestSupport.Snapshot {
        try await Task.sleep(for: .milliseconds(450))
        return try await PresentationTestSupport.capture(window, named: name, in: "tabs-only-validation")
    }
}
