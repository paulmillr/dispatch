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
    /// tab. A split keeps both of its tabs listed.
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
        // a2 moves into a pane on the right: the list's order holds, and choosing a1 focuses the left pane.
        workspace.split(.columns)
        let space = try XCTUnwrap(workspace.current)
        XCTAssertEqual(space.panes.count, 2)
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), tabs)
        XCTAssertEqual(workspace.sidebarTabs.prefix(2).map(\.pane), space.numberedPaneIDs)
        workspace.selectSidebarTab(tabs[0])
        XCTAssertEqual(workspace.current?.focusedPane, space.numberedPaneIDs[0])
        XCTAssertEqual(workspace.activeTab?.id, tabs[0])
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
