import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class WorkspaceTests: XCTestCase {
    func testTabAndSpaceShortcutsDispatchThroughTheApplicationMenu() async throws {
        let controller = AppDelegate(), workspace = controller.workspace
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu; window.close() }
        controller.buildMenus()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { NSApp.keyWindow === window }
        func press(_ code: UInt16, _ text: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: TerminalTestSupport.keyEvent(code, text,
                in: window, modifiers: modifiers)) == true)
        }
        let shifted: NSEvent.ModifierFlags = [.command, .shift]
        workspace.newSpace()
        let firstSpace = try XCTUnwrap(workspace.selectedSpace), firstTab = try XCTUnwrap(workspace.activeTab?.id)
        press(17, "t")
        let secondTab = try XCTUnwrap(workspace.activeTab?.id)
        press(17, "t")
        XCTAssertEqual(workspace.currentTabs.count, 3)
        XCTAssertEqual(workspace.spaces.count, 1)
        for shift in [false, true] {
            press(2, shift ? "D" : "d", shift ? shifted : .command)
            XCTAssertEqual(workspace.current?.panes.count, 2)
            press(2, shift ? "D" : "d", shift ? shifted : .command)
            XCTAssertEqual(workspace.current?.panes.count, 1)
            XCTAssertEqual(workspace.currentTabs.count, shift ? 5 : 4)
        }
        press(18, "1")
        XCTAssertEqual(workspace.activeTab?.id, firstTab)
        press(19, "2")
        XCTAssertEqual(workspace.activeTab?.id, secondTab)
        press(18, "1")
        XCTAssertEqual(workspace.activeTab?.id, firstTab)
        // ⌘[ / ⌘] (the tab digits' modifiers) and ⌃⇧⇥ / ⌃⇥ cycle tabs.
        for (next, previous): ((UInt16, String, NSEvent.ModifierFlags), (UInt16, String, NSEvent.ModifierFlags)) in [
            ((48, "\t", .control), (48, "\u{19}", [.control, .shift])),
            ((30, "]", .command), (33, "[", .command)),
        ] {
            press(next.0, next.1, next.2)
            XCTAssertEqual(workspace.activeTab?.id, secondTab)
            press(previous.0, previous.1, previous.2)
            XCTAssertEqual(workspace.activeTab?.id, firstTab)
        }
        press(30, "]")
        XCTAssertEqual(workspace.activeTab?.id, secondTab)
        for preset in [LayoutPreset.columns, .rows, .twoAbove, .grid] {
            XCTAssertTrue(workspace.applyLayout(preset))
            let space = try XCTUnwrap(workspace.current)
            let targets = space.layout.paneIDs.compactMap { id in space.panes.first { $0.id == id }?.selected }
            for index in targets.indices.reversed() {
                press(ApplicationMenu.digitKeyCodes[index], String(index + 1))
                XCTAssertEqual(workspace.activeTab?.id, targets[index])
                let navigate = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Navigate")?.submenu)
                let item = try XCTUnwrap(navigate.items.first { $0.action == #selector(AppDelegate.selectNumberedItem(_:)) && $0.tag == index })
                XCTAssertTrue(controller.validateMenuItem(item))
                XCTAssertEqual(item.title, "Pane \(index + 1)")
            }
            let unavailable = NSMenuItem(title: "", action: #selector(AppDelegate.selectNumberedItem(_:)), keyEquivalent: "")
            unavailable.tag = targets.count
            XCTAssertFalse(controller.validateMenuItem(unavailable))
        }
        XCTAssertTrue(workspace.applyLayout(.single))
        let firstAfterMerge = workspace.currentTabs.first?.id
        press(18, "1")
        XCTAssertEqual(workspace.activeTab?.id, firstAfterMerge)
        let tabItem = NSMenuItem(title: "Pane 1", action: #selector(AppDelegate.selectNumberedItem(_:)), keyEquivalent: "1")
        XCTAssertTrue(controller.validateMenuItem(tabItem))
        XCTAssertEqual(tabItem.title, "Tab 1")
        workspace.selectTab(secondTab)
        press(45, "n")
        XCTAssertEqual(workspace.spaces.count, 2)
        let secondSpace = try XCTUnwrap(workspace.selectedSpace)
        press(18, "&", controller.settings.values.keyGroups.spaces) // The physical digit selects, as on AZERTY where 1 is shifted.
        XCTAssertEqual(workspace.selectedSpace, firstSpace)
        press(19, "2", controller.settings.values.keyGroups.spaces)
        XCTAssertEqual(workspace.selectedSpace, secondSpace)
        // ⇧⌘[ / ⇧⌘], the space digits' modifiers, step through spaces.
        press(33, "{", shifted)
        XCTAssertEqual(workspace.selectedSpace, firstSpace)
        XCTAssertEqual(workspace.activeTab?.id, secondTab)
        press(30, "}", shifted)
        XCTAssertEqual(workspace.selectedSpace, secondSpace)
        press(25, "9", controller.settings.values.keyGroups.spaces)
        XCTAssertEqual(workspace.selectedSpace, secondSpace)
        press(13, "w")
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.selectedSpace, firstSpace)
        XCTAssertEqual(workspace.currentTabs.count, 5)
        press(13, "w")
        XCTAssertEqual(workspace.currentTabs.count, 4)
        XCTAssertFalse(workspace.allTabIDs.contains(secondTab))
        var remote = Space(name: "remote", directory: "/tmp")
        remote.hostID = .authenticated("fixture")
        remote.panes[0].tabs[0].machine = .ssh(SSHShell(destination: "user@fixture", options: []))
        workspace.spaces.append(remote)
        workspace.selectSpace(remote.id)
        press(45, "N", shifted)
        XCTAssertEqual(workspace.spaces.count, 3)
        XCTAssertEqual(workspace.current?.hostID, .local)
        XCTAssertEqual(workspace.currentMachine, .local)
        XCTAssertEqual(workspace.spaces.first(where: { $0.id == remote.id })?.tabs.count, 1)
        let selectedSpace = workspace.selectedSpace, selectedTab = workspace.activeTab?.id
        for (code, character): (UInt16, Int) in [(123, NSLeftArrowFunctionKey), (124, NSRightArrowFunctionKey),
                                                (126, NSUpArrowFunctionKey), (125, NSDownArrowFunctionKey)] {
            for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
                let event = TerminalTestSupport.keyEvent(code, String(UnicodeScalar(character)!), in: window, modifiers: modifiers)
                XCTAssertFalse(NSApp.mainMenu!.performKeyEquivalent(with: event), "Arrow shortcuts must remain available to text input")
                XCTAssertEqual(workspace.selectedSpace, selectedSpace)
                XCTAssertEqual(workspace.activeTab?.id, selectedTab)
            }
        }
    }

    func testSplitCreationKeepsTheOriginalVisible() throws {
        for axis in [SplitAxis.columns, .rows] {
            for count in [1, 3] {
                let workspace = Workspace()
                workspace.defaultDirectory = "/tmp"
                workspace.newLocalSpace()
                let original = try XCTUnwrap(workspace.activeTab)
                for _ in 1..<count { workspace.newTab() }
                workspace.selectTab(original.id)
                let pane = try XCTUnwrap(workspace.current?.activePane)
                XCTAssertTrue(workspace.canToggleSplit(axis))
                workspace.toggleSplit(axis)
                let created = try XCTUnwrap(workspace.activeTab)
                let space = try XCTUnwrap(workspace.current)
                XCTAssertNotEqual(created.id, original.id)
                XCTAssertEqual(created.directory, original.directory)
                XCTAssertEqual(created.machine, original.machine)
                XCTAssertEqual(space.layout.paneIDs, [pane.id, space.focusedPane])
                XCTAssertEqual(space.panes.first(where: { $0.id == pane.id }), pane)
                XCTAssertEqual(space.activePane?.tabs.map(\.id), [created.id])
                XCTAssertEqual(space.tabs.count, count + 1)
                workspace.toggleSplit(axis)
                XCTAssertEqual(workspace.current?.panes.count, 1)
                XCTAssertEqual(workspace.current?.tabs.count, count + 1)
                XCTAssertEqual(workspace.activeTab?.id, created.id)
            }
        }
    }

    func testLayoutPresetsKeepVisibleTabsInTheirPositions() throws {
        func fixture(tmux: Bool) -> Workspace {
            let workspace = Workspace()
            workspace.newLocalSpace()
            for _ in 0..<4 { workspace.newTab() }
            if tmux {
                workspace.spaces[0].structure(workspace.current!.tabs, selected: 0)
                workspace.spaces[0].selectedContainer = workspace.spaces[0].windows[2].id
            } else { workspace.selectTab(workspace.current!.tabs[2].id) }
            return workspace
        }
        for tmux in [false, true] {
            let workspace = fixture(tmux: tmux)
            let original = try XCTUnwrap(workspace.activeTab?.id)
            let pane = try XCTUnwrap(workspace.current?.focusedPane)
            let ids = workspace.allTabIDs
            for preset in [LayoutPreset.columns, .twoAbove, .rows, .grid, .grid, .single] {
                let visible = workspace.current!.panes.map(\.selected)
                XCTAssertTrue(workspace.applyLayout(preset))
                XCTAssertEqual(workspace.activeTab?.id, original)
                XCTAssertEqual(workspace.current?.layout.paneIDs.first, pane)
                XCTAssertEqual(workspace.allTabIDs, ids)
                if preset == .twoAbove {
                    let layout = try XCTUnwrap(workspace.current?.layout)
                    guard case .split(_, .rows, .split(_, .columns, .pane(let left), .pane(let right)), .pane(let bottom)) = layout else {
                        return XCTFail("2 above must have two top panes and one full-width bottom pane")
                    }
                    XCTAssertEqual([left, right, bottom], workspace.current?.panes.map(\.id))
                }
                if preset.count >= visible.count {
                    XCTAssertTrue(Set(visible).isSubset(of: Set(workspace.current!.panes.map(\.selected))))
                }
            }
            // Reducing a grid retains the focused pane on its matching side.
            for index in 0..<4 {
                for preset in [LayoutPreset.columns, .rows] {
                    let workspace = fixture(tmux: tmux)
                    XCTAssertTrue(workspace.applyLayout(.grid))
                    let before = try XCTUnwrap(workspace.current)
                    let paneID = before.layout.paneIDs[index]
                    let tab = try XCTUnwrap(before.panes.first { $0.id == paneID }?.selected)
                    workspace.selectTab(tab)
                    XCTAssertTrue(workspace.applyLayout(preset))
                    let position = preset == .columns ? index % 2 : index / 2
                    XCTAssertEqual(workspace.current?.layout.paneIDs[position], paneID)
                    XCTAssertEqual(workspace.activeTab?.id, tab)
                }
            }
        }
    }

    func testSplitTogglesPreserveTabsFocusAndUnrelatedBranches() throws {
        for axis in [SplitAxis.columns, .rows] {
            let workspace = Workspace()
            workspace.newLocalSpace(); workspace.newTab()
            let firstPane = try XCTUnwrap(workspace.current?.focusedPane)
            workspace.onCloseTabs = { _ in XCTFail("Toggling a split must not close terminals") }
            workspace.toggleSplit(axis)
            XCTAssertEqual(workspace.current?.panes.count, 2)
            let outer = try XCTUnwrap(workspace.current?.layout)
            workspace.newTab()
            let otherAxis: SplitAxis = axis == .columns ? .rows : .columns
            workspace.toggleSplit(otherAxis)
            let tabs = workspace.allTabIDs, selected = workspace.activeTab?.id
            XCTAssertEqual(workspace.current?.panes.count, 3)
            XCTAssertTrue(workspace.canToggleSplit(otherAxis))
            workspace.toggleSplit(otherAxis)
            XCTAssertEqual(workspace.current?.layout, outer)
            XCTAssertEqual(workspace.activeTab?.id, selected)
            XCTAssertEqual(workspace.allTabIDs, tabs)
            // The same shortcut also merges when focus moves to the other side.
            workspace.selectTab(try XCTUnwrap(workspace.current?.panes.first(where: { $0.id == firstPane })?.selected))
            let focused = workspace.activeTab?.id
            workspace.toggleSplit(axis)
            XCTAssertEqual(workspace.current?.layout, .pane(firstPane))
            XCTAssertEqual(workspace.activeTab?.id, focused)
            XCTAssertEqual(workspace.allTabIDs, tabs)
        }
    }

    func testTmuxSplitTogglesPreserveServerArrangements() throws {
        for axis in [SplitAxis.columns, .rows] {
            let workspace = Workspace()
            var space = Space(name: "tmux", directory: "/tmp")
            space.structure((0..<3).map { _ in TerminalTab(directory: "/tmp") }, selected: 2)
            workspace.spaces = [space]; workspace.selectSpace(space.id)
            workspace.split(axis)
            XCTAssertEqual(workspace.current?.windowPresentation?.groups.count, 2)
            XCTAssertTrue(workspace.canToggleSplit(axis))
            workspace.toggleSplit(axis)
            XCTAssertEqual(workspace.current?.windowPresentation?.groups.count, 1)
            XCTAssertEqual(workspace.current?.windows, space.windows)
            XCTAssertEqual(workspace.current?.selectedContainer, space.selectedContainer)
            XCTAssertEqual(Set(workspace.current?.windowPresentation?.orderedWindows ?? []), Set(space.windows.map(\.id)))
        }
    }

    func testSidebarToggleRemembersOnlyExceptionsToAutomaticVisibility() {
        let controller = AppDelegate()
        controller.settings.values = Preferences()
        let workspace = controller.workspace
        workspace.newSpace()
        XCTAssertFalse(controller.sidebarVisible)
        controller.toggleSidebar()
        XCTAssertEqual(controller.windowState.sidebarVisibilityOverride, true)
        controller.toggleSidebar()
        XCTAssertNil(controller.windowState.sidebarVisibilityOverride)
        workspace.newSpace()
        XCTAssertTrue(controller.sidebarVisible, "A second space shows the sidebar after a single-space show/hide cycle")
        controller.toggleSidebar()
        XCTAssertEqual(controller.windowState.sidebarVisibilityOverride, false)
        workspace.newSpace()
        XCTAssertFalse(controller.sidebarVisible, "Explicitly hiding a multi-space sidebar remains remembered")
        controller.toggleSidebar()
        XCTAssertNil(controller.windowState.sidebarVisibilityOverride)
        workspace.closeSpace(workspace.selectedSpace!)
        workspace.closeSpace(workspace.selectedSpace!)
        XCTAssertFalse(controller.sidebarVisible, "Showing a multi-space sidebar restores automatic hiding at one space")
        controller.toggleSidebar()
        workspace.newSpace()
        workspace.closeSpace(workspace.selectedSpace!)
        XCTAssertTrue(controller.sidebarVisible, "An explicit single-space show remains remembered")
        controller.toggleSidebar()
        XCTAssertNil(controller.windowState.sidebarVisibilityOverride)
        // The user's automatic-visibility setting still defines the baseline.
        controller.settings.values.hideSingleSpace = false
        XCTAssertTrue(controller.sidebarVisible)
        controller.toggleSidebar()
        XCTAssertFalse(controller.sidebarVisible)
        controller.toggleSidebar()
        XCTAssertNil(controller.windowState.sidebarVisibilityOverride)
    }

    func testNativeSpaceNameFollowsFirstTabUntilManuallyRenamed() {
        let workspace = Workspace()
        workspace.defaultDirectory = "/tmp/dispatch"
        workspace.newLocalSpace()
        let space = workspace.selectedSpace!, first = workspace.activeTab!.id
        XCTAssertEqual(workspace.current?.name, "dispatch")
        workspace.newTab()
        let second = workspace.activeTab!.id
        workspace.updateTab(second, directory: "/tmp/other")
        XCTAssertEqual(workspace.current?.name, "dispatch", "Selection does not change the naming source")
        workspace.updateTab(first, directory: "/tmp/project/")
        XCTAssertEqual(workspace.current?.name, "project")
        workspace.closeTab(first)
        XCTAssertEqual(workspace.current?.name, "other")
        workspace.renameSpace(space, to: "  Work  ")
        workspace.updateTab(second, directory: "/tmp/changed")
        XCTAssertEqual(workspace.current?.name, "Work")
        workspace.renameSpace(space, to: " \n ")
        XCTAssertEqual(workspace.current?.name, "Work")
    }

    func testTmuxSpaceNameUsesFirstWindowAndPreservesCustomName() {
        let workspace = Workspace()
        var space = Space(name: "fallback", directory: "/tmp/first", usesDirectoryName: true)
        space.structure([TerminalTab(directory: "/tmp/first"), TerminalTab(directory: "/tmp/second")], selected: 1, name: "shell")
        let first = space.windows[0], second = space.windows[1]
        workspace.spaces = [space]; workspace.selectSpace(space.id)
        XCTAssertEqual(workspace.current?.name, "first")
        workspace.updateTab(first.terminals[0].id, directory: "/tmp/changed")
        XCTAssertEqual(workspace.current?.name, "changed")
        workspace.spaces[0].containers.removeFirst()
        XCTAssertEqual(workspace.current?.name, "second")
        workspace.renameSpace(space.id, to: "Pinned")
        workspace.updateTab(second.terminals[0].id, directory: "/tmp/renamed")
        XCTAssertEqual(workspace.current?.name, "Pinned")
    }

    func testAutomaticSpaceNameHandlesRootAndUnknownDirectory() {
        for (directory, expected) in [
            ("/home/user.guest", "user.guest"),
            ("/home/user.guest/project/", "project"),
            ("/home/user.guest/notes λ %20 #1", "notes λ %20 #1"),
            ("relative/project", "fallback")
        ] {
            let remote = Space(name: "fallback", directory: directory, usesDirectoryName: true)
            XCTAssertEqual(remote.name, expected, directory)
        }
        var space = Space(name: "fallback", directory: "/", usesDirectoryName: true)
        XCTAssertEqual(space.name, "/")
        space.panes[0].tabs[0].directory = ""
        XCTAssertEqual(space.name, "fallback")
        space.name = "custom"
        space.panes[0].tabs[0].directory = "/tmp/project"
        XCTAssertEqual(space.name, "custom")
    }

    func testInitialTabTitleUsesInheritedDirectoryBeforeShellStarts() {
        XCTAssertEqual(TerminalTab(directory: NSHomeDirectory()).label, "~")
        XCTAssertEqual(TerminalTab(directory: "/").label, "/")
        XCTAssertEqual(TerminalTab(directory: "/tmp/example/").label, "example")
        let workspace = Workspace()
        workspace.newSpace()
        workspace.updateTab(workspace.activeTab!.id, title: "vim", directory: "/tmp/project")
        workspace.newTab()
        XCTAssertEqual(workspace.activeTab?.label, "project")
        workspace.updateTab(workspace.activeTab!.id, title: "Running command")
        XCTAssertEqual(workspace.activeTab?.label, "Running command")
        workspace.newTab()
        workspace.split(.rows)
        XCTAssertEqual(workspace.activeTab?.label, "project")
    }

    func testSpaceReorderingPreservesSelectionAndChangesNavigationOrder() {
        let workspace = Workspace()
        for _ in 0..<3 { workspace.newSpace() }
        let ids = workspace.spaces.map(\.id)
        let tabs = workspace.allTabIDs
        workspace.onCloseTabs = { _ in XCTFail("Reordering must not close shells") }
        XCTAssertTrue(workspace.reorderSpace(ids[2], relativeTo: ids[0], after: false))
        XCTAssertEqual(workspace.spaces.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(workspace.selectedSpace, ids[2])
        workspace.cycleSpace(1)
        XCTAssertEqual(workspace.selectedSpace, ids[0])
        XCTAssertTrue(workspace.reorderSpace(ids[2], relativeTo: ids[1], after: true))
        XCTAssertEqual(workspace.spaces.map(\.id), ids)
        XCTAssertEqual(workspace.selectedSpace, ids[0])
        XCTAssertFalse(workspace.reorderSpace(ids[0], relativeTo: ids[0], after: true))
        XCTAssertFalse(workspace.reorderSpace(ids[0], relativeTo: UUID(), after: true))
        XCTAssertEqual(workspace.spaces.map(\.id), ids)
        XCTAssertEqual(workspace.allTabIDs, tabs)
    }

    func testTabReorderingAndInsertionIntoAnotherPanePreserveShells() {
        let workspace = Workspace()
        workspace.newSpace()
        workspace.newTab()
        workspace.newTab()
        let pane = workspace.current!.focusedPane
        let ids = workspace.currentTabs.map(\.id)
        workspace.onCloseTabs = { _ in XCTFail("Moving must not close shells") }
        XCTAssertTrue(workspace.moveTab(ids[2], to: pane, relativeTo: ids[0]))
        XCTAssertEqual(workspace.currentTabs.map(\.id), [ids[2], ids[0], ids[1]])
        XCTAssertEqual(workspace.activeTab?.id, ids[2])
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, ids[0])
        XCTAssertTrue(workspace.moveTab(ids[2], to: pane, relativeTo: ids[1], after: true))
        XCTAssertEqual(workspace.currentTabs.map(\.id), ids)
        XCTAssertEqual(workspace.activeTab?.id, ids[0])
        let before = workspace.spaces
        XCTAssertFalse(workspace.moveTab(ids[0], to: pane, relativeTo: ids[0]))
        XCTAssertFalse(workspace.moveTab(ids[0], to: pane, relativeTo: UUID()))
        XCTAssertEqual(workspace.spaces, before)
        workspace.newTab()
        workspace.split(.columns)
        let splitTab = workspace.activeTab!.id
        XCTAssertTrue(workspace.moveTab(splitTab, to: pane, relativeTo: ids[1]))
        XCTAssertEqual(workspace.currentTabs.map(\.id), [ids[0], splitTab, ids[1], ids[2]])
        XCTAssertEqual(workspace.current?.layout, .pane(pane))
        XCTAssertEqual(workspace.activeTab?.id, splitTab)
        XCTAssertEqual(workspace.allTabIDs, Set(ids + [splitTab]))
    }

    func testSpaceNavigationWrapsAndKeepsEachSelection() {
        let workspace = Workspace()
        workspace.cycleSpace(1)
        XCTAssertNil(workspace.selectedSpace)
        workspace.newSpace()
        workspace.newTab()
        let first = workspace.activeTab!.id
        workspace.newSpace()
        let second = workspace.activeTab!.id
        workspace.cycleSpace(1)
        XCTAssertEqual(workspace.activeTab?.id, first)
        workspace.cycleSpace(-1)
        XCTAssertEqual(workspace.activeTab?.id, second)
    }

    func testNumberedNavigationFocusesPanesWhileTabCyclingStaysInFocusedPane() {
        let workspace = Workspace()
        workspace.newSpace()
        let first = workspace.activeTab!.id
        workspace.newTab()
        let second = workspace.activeTab!.id
        workspace.selectPane(at: 0)
        XCTAssertEqual(workspace.activeTab?.id, second)
        workspace.cycleTab(-1)
        XCTAssertEqual(workspace.activeTab?.id, first)
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, second)
        workspace.selectPane(at: 1)
        workspace.selectPane(at: 8)
        XCTAssertEqual(workspace.activeTab?.id, second)
        workspace.newTab()
        workspace.split(.columns)
        let split = workspace.activeTab!.id
        workspace.selectPane(at: 0)
        XCTAssertEqual(workspace.activeTab?.id, second)
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, first)
        workspace.selectPane(at: 1)
        XCTAssertEqual(workspace.activeTab?.id, split)
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.activeTab?.id, split)
    }

    func testNumberedShortcutsFollowLayoutAndEachPanesCurrentTab() throws {
        for tmux in [false, true] {
            let workspace = Workspace()
            workspace.newLocalSpace()
            for _ in 0..<5 { workspace.newTab() }
            if tmux {
                workspace.spaces[0].structure(workspace.current!.tabs, selected: 0)
                workspace.selectWindow(workspace.spaces[0].windows[2].id)
            } else { workspace.selectTab(workspace.current!.tabs[2].id) }

            for preset in [LayoutPreset.columns, .rows, .twoAbove, .grid, .single] {
                XCTAssertTrue(workspace.applyLayout(preset))
                var space = try XCTUnwrap(workspace.current)
                if preset != .single {
                    // Change the selected tab inside a pane containing hidden tabs.
                    if tmux {
                        let group = try XCTUnwrap(space.windowPresentation?.groups.first { $0.windows.count > 1 })
                        workspace.selectWindow(try XCTUnwrap(group.windows.first { $0 != group.selected }))
                        workspace.spaces[0].presentation?.groups.reverse()
                    } else {
                        let pane = try XCTUnwrap(space.panes.first { $0.tabs.count > 1 })
                        workspace.selectTab(try XCTUnwrap(pane.tabs.first { $0.id != pane.selected }).id)
                        workspace.spaces[0].panes.reverse()
                    }
                    space = try XCTUnwrap(workspace.current)
                }
                let expected: [UUID]
                let paneIDs: [UUID]
                if tmux, let presentation = space.windowPresentation {
                    paneIDs = presentation.layout.paneIDs
                    expected = presentation.layout.paneIDs.compactMap { id in presentation.groups.first { $0.id == id }?.selected }
                } else {
                    paneIDs = space.layout.paneIDs
                    expected = space.layout.paneIDs.compactMap { id in space.panes.first { $0.id == id }?.selected }
                }
                XCTAssertEqual(expected.count, preset.count)
                XCTAssertEqual(space.numberedPaneIDs, paneIDs)
                for index in expected.indices.reversed() {
                    workspace.selectPane(at: index)
                    XCTAssertEqual(tmux ? workspace.current?.selectedContainer : workspace.activeTab?.id, expected[index])
                    XCTAssertEqual(workspace.current?.numberedPaneIDs, paneIDs)
                    XCTAssertEqual(workspace.current?.paneShortcutNumber(for: paneIDs[index]), index + 1)
                    XCTAssertEqual(workspace.paneFocusFeedback?.paneID, paneIDs[index])
                    let feedback = try XCTUnwrap(workspace.paneFocusFeedback)
                    workspace.selectPane(at: index)
                    XCTAssertNotEqual(workspace.paneFocusFeedback?.id, feedback.id, "Repeated shortcuts must highlight the pane again")
                }
                let selected = workspace.activeTab?.id
                let feedback = workspace.paneFocusFeedback?.id
                workspace.selectPane(at: expected.count)
                workspace.selectPane(at: -1)
                XCTAssertEqual(workspace.activeTab?.id, selected)
                XCTAssertEqual(workspace.paneFocusFeedback?.id, feedback)
            }
        }
    }

    func testNumberedShortcutsReadCustomGridByRowsInsteadOfTreeOrder() {
        let workspace = Workspace()
        let panes = (0..<4).map { _ in Pane(tabs: [TerminalTab(directory: "/tmp")]) }
        var space = Space(name: "Grid", tab: panes[0].tabs[0])
        space.panes = [panes[3], panes[1], panes[0], panes[2]]
        space.layout = .split(UUID(), .columns,
            .split(UUID(), .rows, .pane(panes[0].id), .pane(panes[2].id)),
            .split(UUID(), .rows, .pane(panes[1].id), .pane(panes[3].id)))
        space.focusedPane = panes[3].id
        workspace.spaces = [space]
        workspace.selectSpace(space.id)
        for index in panes.indices {
            workspace.selectPane(at: index)
            XCTAssertEqual(workspace.current?.focusedPane, panes[index].id)
        }
    }

    func testSinglePaneTabShortcutsFollowReorderingAndLayoutChanges() throws {
        for tmux in [false, true] {
            let workspace = Workspace()
            workspace.newLocalSpace()
            for _ in 0..<9 { workspace.newTab() }
            if tmux {
                workspace.spaces[0].structure(workspace.current!.tabs, selected: 0)
                workspace.selectWindow(workspace.spaces[0].windows[2].id)
            }
            let before = try XCTUnwrap(workspace.current).numberedTabIDs
            if tmux {
                let moved = workspace.spaces[0].containers.remove(at: 2)
                workspace.spaces[0].containers.insert(moved, at: 0)
            } else {
                XCTAssertTrue(workspace.moveTab(before[2], to: workspace.current!.focusedPane, relativeTo: before[0]))
            }
            let expected = [before[2], before[0], before[1]] + Array(before.dropFirst(3))
            for index in 0..<9 {
                workspace.selectNumberedItem(at: index)
                XCTAssertEqual(tmux ? workspace.current?.selectedContainer : workspace.activeTab?.id, expected[index])
                XCTAssertEqual(workspace.current?.tabShortcutNumber(for: expected[index]), index + 1)
            }
            XCTAssertNil(workspace.current?.tabShortcutNumber(for: expected[9]))
            let selected = workspace.activeTab?.id
            workspace.selectNumberedItem(at: 9)
            workspace.selectNumberedItem(at: -1)
            XCTAssertEqual(workspace.activeTab?.id, selected)

            XCTAssertTrue(workspace.applyLayout(.columns))
            let split = try XCTUnwrap(workspace.current)
            XCTAssertEqual(split.numberedShortcutCount, 2)
            XCTAssertTrue(expected.allSatisfy { split.tabShortcutNumber(for: $0) == nil })
            // With splits, the focused pane's legends name where ⌘] and ⌘[ actually land.
            let current = { tmux ? workspace.current?.selectedContainer : workspace.activeTab?.id }
            let origin = current()
            let next = expected.filter { split.tabShortcut(for: $0) == .next }
            let previous = expected.filter { split.tabShortcut(for: $0) == .previous }
            XCTAssertEqual(next.count, 1)
            XCTAssertEqual(previous.count, 1)
            XCTAssertFalse(expected.contains { if case .number = split.tabShortcut(for: $0) { true } else { false } })
            workspace.cycleTab(1)
            XCTAssertEqual(current(), next.first)
            workspace.cycleTab(-1)
            XCTAssertEqual(current(), origin)
            workspace.cycleTab(-1)
            XCTAssertEqual(current(), previous.first)
            workspace.cycleTab(1)
            for index in 0..<2 {
                workspace.selectNumberedItem(at: index)
                XCTAssertEqual(workspace.paneFocusFeedback?.paneID, split.numberedPaneIDs[index])
            }
            XCTAssertTrue(workspace.applyLayout(.single))
            let mergedOrder = try XCTUnwrap(workspace.current).numberedTabIDs
            workspace.selectNumberedItem(at: 0)
            XCTAssertEqual(tmux ? workspace.current?.selectedContainer : workspace.activeTab?.id, mergedOrder[0])
            XCTAssertEqual(workspace.current?.tabShortcutNumber(for: mergedOrder[0]), 1)
        }
    }

    func testTmuxTabCyclingStaysInTheFocusedPaneAndPaneOneKeepsItsSelection() throws {
        let workspace = Workspace()
        var space = Space(name: "tmux", directory: "/tmp")
        space.structure((0..<4).map { _ in TerminalTab(directory: "/tmp") }, selected: 2)
        let windows = space.windows
        workspace.spaces = [space]
        workspace.selectSpace(space.id)
        workspace.selectPane(at: 0)
        XCTAssertEqual(workspace.current?.selectedContainer, windows[2].id, "A single pane must not switch to its first tab")
        workspace.selectPane(at: 1)
        XCTAssertEqual(workspace.current?.selectedContainer, windows[2].id)

        var presentation = TabPresentation(windows: windows.map(\.id), selected: windows[2].id, preset: .columns)
        presentation.groups[0].windows = [windows[0].id, windows[2].id]
        presentation.groups[1].windows = [windows[1].id, windows[3].id]
        workspace.spaces[0].presentation = presentation
        for index in 0..<2 {
            workspace.selectPane(at: index)
            let group = presentation.groups[index]
            XCTAssertEqual(workspace.currentTabs.map(\.id), group.windows.compactMap { id in windows.first { $0.id == id }?.terminals.first?.id })
            let before = try XCTUnwrap(workspace.current?.selectedContainer)
            workspace.cycleTab(1)
            XCTAssertNotEqual(workspace.current?.selectedContainer, before)
            XCTAssertTrue(group.windows.contains(try XCTUnwrap(workspace.current?.selectedContainer)))
            workspace.cycleTab(-1)
            XCTAssertEqual(workspace.current?.selectedContainer, before)
            XCTAssertEqual(workspace.current?.windowPresentation?.groups[1 - index].selected, presentation.groups[1 - index].selected)
        }
    }

    func testThemeDefaultsAppearanceAndOlderSettings() throws {
        var settings = Preferences()
        XCTAssertEqual(settings.resolvedTheme(systemIsDark: true), "dispatch-black")
        XCTAssertEqual(settings.resolvedTheme(systemIsDark: false), "dispatch-black")
        settings.lightTheme = "Builtin Light"
        XCTAssertEqual(settings.resolvedTheme(systemIsDark: false), "Builtin Light")
        settings.appTheme = .dark
        XCTAssertEqual(settings.resolvedTheme(systemIsDark: false), "dispatch-black")
        settings.appTheme = .light
        XCTAssertEqual(settings.resolvedTheme(systemIsDark: true), "Builtin Light")
        let previous = Data(#"{"fontFamily":"Menlo","fontSize":15,"theme":"Catppuccin Mocha","optionAsAlt":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: previous)
        XCTAssertEqual(decoded.theme, "Catppuccin Mocha")
        XCTAssertEqual(decoded.lightTheme, "Catppuccin Mocha")
        XCTAssertEqual(decoded.fontSize, 15)
        XCTAssertFalse(decoded.optionAsAlt)
        let previousDefault = try JSONDecoder().decode(Preferences.self, from: Data(#"{"theme":"Default"}"#.utf8))
        XCTAssertEqual(previousDefault.theme, "Default")
        XCTAssertEqual(previousDefault.resolvedTheme(systemIsDark: true), "dispatch-black")
        XCTAssertEqual(previousDefault.resolvedTheme(systemIsDark: false), "dispatch-black")
        let explicitDefault = try JSONDecoder().decode(Preferences.self, from: Data(#"{"theme":"Default","appearance":"dark"}"#.utf8))
        XCTAssertEqual(explicitDefault.theme, "Default")
        XCTAssertEqual(explicitDefault.resolvedTheme(systemIsDark: true), "dispatch-black")
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(explicitDefault)), explicitDefault)
        let explicitTheme = try JSONDecoder().decode(Preferences.self, from: Data(#"{"theme":"Example Theme"}"#.utf8))
        XCTAssertEqual(explicitTheme.resolvedTheme(systemIsDark: true), "Example Theme")
    }

    func testHostNewSpacePrefersCurrentThenExistingBackendOtherwiseNative() throws {
        for backend in ["tmux", "herdr"] {
            let workspace = Workspace()
            let host = HostID.authenticated("host-a")
            let shell = SSHShell(destination: "user@host-a", options: ["-p", "2222"])
            var native = Space(name: "native", directory: "/tmp")
            native.hostID = host
            native.panes[0].tabs[0].machine = .ssh(shell)
            var tab = TerminalTab(directory: "/tmp")
            tab.machine = .ssh(shell)
            var managed = Space(name: backend, tab: tab)
            managed.hostID = host
            // Either multiplexer's session is a structured space of its own helper backend.
            managed.structure([tab], selected: 0, backend: backend == "tmux" ? 1 : 2)
            let other = Space(name: "other host", directory: "/tmp")
            workspace.spaces = [native, managed, other]
            workspace.selectSpace(managed.id)
            XCTAssertEqual(workspace.newSpaceSource(on: host)?.id, managed.id)
            workspace.selectSpace(other.id)
            XCTAssertEqual(workspace.newSpaceSource(on: host)?.id, managed.id,
                           "A backend on the requested host wins over its earlier native space")
            workspace.selectSpace(native.id)
            XCTAssertEqual(workspace.newSpaceSource(on: host)?.id, native.id)
            workspace.newSpace(on: host)
            XCTAssertEqual(workspace.spaces.count, 4)
            XCTAssertEqual(workspace.current?.hostID, host)
            XCTAssertEqual(workspace.activeTab?.machine, .ssh(shell))
            XCTAssertEqual(workspace.activeTab?.launchCommand, shell.command())
            XCTAssertEqual(workspace.current?.structured, false)

            workspace.spaces = [native, other]
            workspace.selectSpace(other.id)
            workspace.newSpace(on: host)
            XCTAssertEqual(workspace.current?.hostID, host)
            XCTAssertEqual(workspace.activeTab?.machine, .ssh(shell))
            workspace.newSpace(on: .local)
            XCTAssertEqual(workspace.current?.hostID, .local)
            XCTAssertEqual(workspace.activeTab?.machine, .local)
        }
    }

    func testExplicitNewSpaceChoiceStartsRequestedBackendOnTargetHost() {
        for remote in [false, true] {
            for backend in SpaceBackend.allCases {
                let workspace = Workspace()
                let host: HostID = remote ? .authenticated("target") : .local
                let machine: TerminalMachine = remote ? .ssh(SSHShell(destination: "target")) : .local
                var source = Space(name: "source", directory: "/tmp")
                source.hostID = host
                source.panes[0].tabs[0].machine = machine
                workspace.spaces = [source]
                workspace.selectSpace(source.id)
                workspace.newSpace(on: host, backend: backend)
                XCTAssertEqual(workspace.spaces.count, 2)
                XCTAssertEqual(workspace.current?.hostID, host)
                XCTAssertEqual(workspace.activeTab?.machine, machine)
                XCTAssertEqual(workspace.activeTab?.launchCommand, machine.command(running: backend.command))
            }
        }
    }

    func testClosingNestedSplitCollapsesOnlyThatBranch() {
        let workspace = Workspace()
        workspace.newSpace()
        let first = workspace.activeTab!.id
        workspace.newTab()
        workspace.split(.columns)
        let second = workspace.activeTab!.id
        workspace.newTab()
        workspace.split(.rows)
        let third = workspace.activeTab!.id
        var closed: [UUID] = []
        workspace.onCloseTabs = { closed += $0 }
        workspace.closeTab(second)
        XCTAssertEqual(workspace.current?.panes.count, 2)
        XCTAssertEqual(workspace.current?.layout.paneIDs.count, 2)
        XCTAssertEqual(workspace.allTabIDs, Set([first, third]))
        XCTAssertEqual(workspace.activeTab?.id, third)
        XCTAssertEqual(closed, [second])
    }

    func testMovingSoleTabCollapsesSourceWithoutClosingShell() {
        let workspace = Workspace()
        workspace.newSpace()
        let first = workspace.activeTab!.id
        let firstPane = workspace.current!.focusedPane
        workspace.newTab()
        workspace.split(.columns)
        let second = workspace.activeTab!.id
        workspace.onCloseTabs = { _ in XCTFail("Moving a tab must never close a shell") }
        workspace.moveTab(second, to: firstPane)
        XCTAssertEqual(workspace.current?.panes.count, 1)
        XCTAssertEqual(workspace.current?.panes[0].tabs.map(\.id), [first, second])
        XCTAssertEqual(workspace.activeTab?.id, second)
        XCTAssertEqual(workspace.current?.layout, .pane(firstPane))
    }

    func testCloseBackgroundTabPreservesSelection() {
        let workspace = Workspace()
        workspace.newSpace()
        let first = workspace.activeTab!.id
        workspace.newTab()
        let second = workspace.activeTab!.id
        workspace.closeTab(first)
        XCTAssertEqual(workspace.activeTab?.id, second)
        workspace.closeTab(second)
        XCTAssertNil(workspace.current)
        XCTAssertTrue(workspace.spaces.isEmpty)
        workspace.newTab()
        XCTAssertNotNil(workspace.activeTab)
    }

    func testSpaceSelectionAndDirectoryInheritance() {
        let workspace = Workspace()
        workspace.newSpace()
        let firstSpace = workspace.selectedSpace!
        workspace.updateTab(workspace.activeTab!.id, directory: "/tmp")
        workspace.newTab()
        XCTAssertEqual(workspace.activeTab?.directory, "/tmp")
        workspace.newTab()
        workspace.split(.rows)
        XCTAssertEqual(workspace.activeTab?.directory, "/tmp")
        let selected = workspace.activeTab!.id
        workspace.newSpace()
        workspace.selectSpace(firstSpace)
        XCTAssertEqual(workspace.activeTab?.id, selected)
    }

    func testSplitLimitAndInvalidMoves() {
        let workspace = Workspace()
        workspace.newSpace()
        for _ in 0..<8 { workspace.newTab(); workspace.split(.columns) }
        XCTAssertEqual(workspace.current?.panes.count, 4)
        let before = workspace.spaces
        workspace.moveTab(UUID(), to: UUID())
        workspace.closeTab(UUID())
        workspace.selectSpace(UUID())
        XCTAssertEqual(workspace.spaces, before)
    }

    func testClosingBackgroundSpaceDoesNotChangeActiveSpace() {
        let workspace = Workspace()
        workspace.newSpace()
        let first = workspace.selectedSpace!
        workspace.newSpace()
        let second = workspace.selectedSpace!
        workspace.closeSpace(first)
        XCTAssertEqual(workspace.selectedSpace, second)
        XCTAssertNotNil(workspace.activeTab)
    }

    func testSplittingSoleTabAtPaneLimitPreservesEveryShell() {
        for edge in PaneEdge.allCases {
            let workspace = Workspace()
            workspace.newSpace()
            for _ in 0..<3 { workspace.newTab() }
            XCTAssertTrue(workspace.applyLayout(.grid))
            let source = workspace.current!.panes[0]
            let target = workspace.current!.panes[3].id
            let tabs = workspace.allTabIDs
            workspace.onCloseTabs = { _ in XCTFail("Splitting must preserve shells") }

            XCTAssertTrue(workspace.splitTab(source.selected, beside: target, edge: edge))
            let space = workspace.current!
            XCTAssertEqual(space.panes.count, 4)
            XCTAssertEqual(workspace.allTabIDs, tabs)
            XCTAssertEqual(space.activeTab?.id, source.selected)
            XCTAssertFalse(space.layout.paneIDs.contains(source.id))
            XCTAssertTrue(space.layout.paneIDs.contains(target))
            XCTAssertEqual(Set(space.layout.paneIDs), Set(space.panes.map(\.id)))
            XCTAssertNil(space.preset)
        }
    }

    func testMovingOnlyTabReindexesDestinationSpaceWithoutClosingShell() {
        let workspace = Workspace()
        workspace.newSpace()
        let moved = workspace.activeTab!.id
        workspace.newSpace()
        let destination = workspace.current!
        let tabs = workspace.allTabIDs
        workspace.onCloseTabs = { _ in XCTFail("Moving must preserve shells") }

        XCTAssertTrue(workspace.moveTab(moved, to: destination.focusedPane, relativeTo: destination.activeTab!.id))
        XCTAssertEqual(workspace.spaces.map(\.id), [destination.id])
        XCTAssertEqual(workspace.currentTabs.map(\.id), [moved, destination.activeTab!.id])
        XCTAssertEqual(workspace.activeTab?.id, moved)
        XCTAssertEqual(workspace.allTabIDs, tabs)
    }

    func testClosingBackgroundSelectedTabsChoosesNeighborsAndRemovesEmptySpace() {
        let workspace = Workspace()
        workspace.newSpace()
        workspace.newTab()
        workspace.newTab()
        let tabs = workspace.currentTabs.map(\.id)
        let background = workspace.selectedSpace!
        workspace.selectTab(tabs[1])
        workspace.newSpace()
        let foreground = workspace.current!
        var closed: [UUID] = []
        workspace.onCloseTabs = { closed += $0 }

        workspace.closeTab(tabs[1])
        XCTAssertEqual(workspace.spaces.first { $0.id == background }?.activeTab?.id, tabs[2])
        workspace.closeTab(tabs[2])
        XCTAssertEqual(workspace.spaces.first { $0.id == background }?.activeTab?.id, tabs[0])
        workspace.closeTab(tabs[0])
        XCTAssertEqual(workspace.current, foreground)
        XCTAssertEqual(workspace.spaces.map(\.id), [foreground.id])
        XCTAssertEqual(closed, [tabs[1], tabs[2], tabs[0]])
        XCTAssertEqual(workspace.allTabIDs, Set(foreground.tabs.map(\.id)))
    }

    func testSettingsRoundTripAndInvalidInputDoesNotReplaceSavedValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let settings = SettingsStore(file: file)
        var values = Preferences()
        values.fontSize = 18
        values.largeSidebarItems = false
        values.hideSingleSpace = false
        try settings.save(values)
        XCTAssertEqual(SettingsStore(file: file).values, values)
        var invalid = values
        invalid.startingDirectory = "/nonexistent-\(UUID())"
        XCTAssertThrowsError(try settings.save(invalid))
        XCTAssertEqual(SettingsStore(file: file).values, values)
        invalid = values
        invalid.fontFamily = "Mono\ncommand = unexpected"
        XCTAssertThrowsError(try settings.save(invalid))
        invalid = values
        invalid.fontSize = 33
        XCTAssertThrowsError(try settings.save(invalid))
        XCTAssertEqual(SettingsStore(file: file).values.sidebarFontSize, 17)
        values.fontSize = 8
        try settings.save(values)
        XCTAssertEqual(SettingsStore(file: file).values.sidebarFontSize, 8)
    }

    func testFontMenuContainsOnlyMonospacedFamilies() {
        let fonts = SettingsView.monospacedFontFamilies
        XCTAssertTrue(fonts.contains("Menlo"))
        XCTAssertFalse(fonts.contains("Helvetica"))
        XCTAssertFalse(fonts.contains("Times New Roman"))
        XCTAssertFalse(fonts.contains("Andale Mono"))
        XCTAssertFalse(fonts.contains("Courier New"))
        for family in ["Departure Mono", "Ioskeley Mono Term", "JetBrains Mono", "0xProto"] {
            XCTAssertTrue(fonts.contains(family), family)
        }
        for family in fonts {
            let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13)!
            XCTAssertTrue(font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace), family)
        }
    }

    func testSpaceReorderUsesOneBoundaryAcrossBothRowsAndTheirGap() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        let ids = (0..<3).map { _ in UUID() }
        var drops: [(UUID, Bool)] = []
        let blank = ReorderTrackingView(configuration: LocalReorder(edge: .pane, accepts: { _ in true }) { _, _ in
            XCTFail("The gap between spaces must not fall through to move-to-end")
        })
        blank.frame = content.bounds
        content.addSubview(blank)
        let rows = ids.enumerated().map { index, id in
            let row = ReorderTrackingView(configuration: LocalReorder(item: .space(id), edge: .vertical,
                accepts: { _ in true }) { _, after in drops.append((id, after)) })
            row.frame = NSRect(x: 0, y: 140 - index * 40, width: 200, height: 30)
            content.addSubview(row)
            return row
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = rows[2].convert(NSPoint(x: 50, y: 15), to: nil)
        for y: CGFloat in [145, 135, 125] {
            let end = content.convert(NSPoint(x: 50, y: y), to: nil)
            var events = [mouse(.leftMouseDragged, end), mouse(.leftMouseUp, end)]
            rows[2].trackMouse(with: mouse(.leftMouseDown, start)) {
                if events.count == 1 {
                    XCTAssertNil(rows[0].insertionAfter)
                    XCTAssertEqual(rows[1].insertionAfter, false, "Every approach must show the same insertion line")
                    XCTAssertNil(blank.insertionAfter)
                }
                return events.isEmpty ? nil : events.removeFirst()
            }
            XCTAssertNil(rows[1].insertionAfter, "Mouse-up must clear the line")
        }
        XCTAssertEqual(drops.map(\.0), [ids[1], ids[1], ids[1]])
        XCTAssertTrue(drops.allSatisfy { !$0.1 })

        // Tree groups retain their own final boundary instead of pointing at
        // the first row of the next host.
        rows[0].configuration.reorderGroup = "first-host"
        rows[1].configuration.reorderGroup = "second-host"
        let end = rows[0].convert(NSPoint(x: 50, y: 25), to: nil)
        var events = [mouse(.leftMouseDragged, end), mouse(.leftMouseUp, end)]
        rows[2].trackMouse(with: mouse(.leftMouseDown, start)) {
            if events.count == 1 {
                XCTAssertEqual(rows[0].insertionAfter, true)
                XCTAssertNil(rows[1].insertionAfter)
            }
            return events.isEmpty ? nil : events.removeFirst()
        }
        XCTAssertEqual(drops.last?.0, ids[0])
        XCTAssertEqual(drops.last?.1, true)
    }

    func testLocalReorderCommitsOnMouseUpAndEscapeCancels() {
        let workspace = Workspace()
        workspace.newSpace()
        workspace.newSpace()
        let ids = workspace.spaces.map(\.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        func row(_ id: UUID, y: CGFloat) -> ReorderTrackingView {
            let view = ReorderTrackingView(configuration: LocalReorder(item: .space(id), edge: .vertical,
                select: { workspace.selectSpace(id) }, accepts: { if case .space = $0 { return true }; return false }) { item, after in
                    guard case .space(let source) = item else { return }
                    workspace.reorderSpace(source, relativeTo: id, after: after)
                })
            view.frame = NSRect(x: 0, y: y, width: 200, height: 30)
            content.addSubview(view)
            return view
        }
        let first = row(ids[0], y: 100)
        let second = row(ids[1], y: 50)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = second.convert(NSPoint(x: 50, y: 15), to: nil)
        let end = first.convert(NSPoint(x: 50, y: 5), to: nil)
        var events = [mouse(.leftMouseDragged, end), mouse(.leftMouseUp, end)]
        second.trackMouse(with: mouse(.leftMouseDown, start)) { events.isEmpty ? nil : events.removeFirst() }
        XCTAssertEqual(workspace.spaces.map(\.id), [ids[1], ids[0]], "The new order must be committed before tracking returns")
        XCTAssertEqual(workspace.selectedSpace, ids[1])

        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        let cancelStart = first.convert(NSPoint(x: 50, y: 15), to: nil)
        let cancelEnd = second.convert(NSPoint(x: 50, y: 25), to: nil)
        events = [mouse(.leftMouseDragged, cancelEnd), escape]
        first.trackMouse(with: mouse(.leftMouseDown, cancelStart)) { events.isEmpty ? nil : events.removeFirst() }
        XCTAssertEqual(workspace.spaces.map(\.id), [ids[1], ids[0]])
    }
}

@MainActor
final class WorkspaceTransactionTests: XCTestCase {

    func testAddingSpaceCommitsLayoutAndSelectionTogether() {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let revision = workspace.layoutRevision, focus = workspace.focusRequest
        let space = Space(name: "Added", directory: "/tmp")
        workspace.addSpace(space)
        XCTAssertEqual(workspace.layoutRevision, revision + 1)
        XCTAssertEqual(workspace.spaces.last, space)
        XCTAssertEqual(workspace.selectedSpace, workspace.spaces.last?.id)
        XCTAssertNotEqual(workspace.focusRequest, focus)
    }

    func testCompleteLayoutCommitsOnceAndNoOpDoesNotPublish() {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let original = workspace.spaces
        let revision = workspace.layoutRevision
        let tab = TerminalTab(directory: "/tmp")
        workspace.updateLayout { next in
            next.spaces[0].panes[0].tabs.append(tab)
            next.spaces[0].name = "Updated"
            next.selectTab(tab.id)
            XCTAssertEqual(workspace.spaces, original, "Draft mutations must not publish an intermediate layout")
            XCTAssertEqual(workspace.layoutRevision, revision)
        }
        XCTAssertEqual(workspace.layoutRevision, revision + 1)
        XCTAssertEqual(workspace.activeTab?.id, tab.id)
        XCTAssertEqual(workspace.current?.name, "Updated")
        workspace.updateLayout { _ in }
        workspace.selectTab(tab.id)
        XCTAssertEqual(workspace.layoutRevision, revision + 1, "An unchanged selection must not persist layout again")
    }

    func testThrowingMutationLeavesLayoutAndSelectionUntouched() {
        enum Failure: Error { case rejected }
        let workspace = Workspace()
        workspace.newLocalSpace()
        let original = workspace.spaces, selected = workspace.selectedSpace
        let revision = workspace.layoutRevision
        XCTAssertThrowsError(try workspace.updateLayout { next in
            next.removeSpace(at: 0)
            throw Failure.rejected
        })
        XCTAssertEqual(workspace.spaces, original)
        XCTAssertEqual(workspace.selectedSpace, selected)
        XCTAssertEqual(workspace.layoutRevision, revision)
    }

    func testRejectedSplitLeavesSourceAndSelectionUntouched() throws {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let original = workspace.spaces, selected = workspace.selectedSpace
        let tab = try XCTUnwrap(workspace.activeTab?.id)
        let pane = try XCTUnwrap(workspace.current?.focusedPane)
        let revision = workspace.layoutRevision
        for target in [UUID(), pane] {
            let result = workspace.updateLayout { $0.splitTab(tab, beside: target, edge: .right) }
            XCTAssertNil(result)
            XCTAssertEqual(workspace.spaces, original)
            XCTAssertEqual(workspace.selectedSpace, selected)
            XCTAssertEqual(workspace.layoutRevision, revision)
        }
    }

    func testCreatingLocalSplitPublishesOnlyTheCompleteLayout() throws {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let original = try XCTUnwrap(workspace.activeTab?.id)
        let pane = try XCTUnwrap(workspace.current?.focusedPane)
        let revision = workspace.layoutRevision
        workspace.toggleSplit(.columns)
        XCTAssertEqual(workspace.layoutRevision, revision + 1)
        let split = try XCTUnwrap(workspace.current)
        XCTAssertEqual(split.panes.count, 2)
        XCTAssertEqual(split.panes.first { $0.id == pane }?.selected, original)
        XCTAssertNotEqual(workspace.activeTab?.id, original)
        XCTAssertEqual(Set(split.tabs.map(\.id)).count, 2)
        XCTAssertEqual(Set(split.layout.paneIDs), Set(split.panes.map(\.id)))
    }

    func testCompoundCommandsCommitOnceAndKeepTerminalIdentity() throws {
        let workspace = Workspace()
        workspace.newLocalSpace()
        let first = try XCTUnwrap(workspace.activeTab?.id)
        func commitsOnce(_ operation: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
            let revision = workspace.layoutRevision
            operation()
            XCTAssertEqual(workspace.layoutRevision, revision + 1, file: file, line: line)
            for space in workspace.spaces {
                XCTAssertEqual(Set(space.layout.paneIDs), Set(space.panes.map(\.id)), file: file, line: line)
                XCTAssertTrue(space.panes.contains { $0.id == space.focusedPane }, file: file, line: line)
                XCTAssertTrue(space.panes.allSatisfy { pane in pane.tabs.contains { $0.id == pane.selected } }, file: file, line: line)
            }
        }
        commitsOnce { workspace.newTab() }
        let second = try XCTUnwrap(workspace.activeTab?.id)
        commitsOnce { XCTAssertTrue(workspace.applyLayout(.columns)) }
        let firstPane = try XCTUnwrap(workspace.current?.panes.first { $0.tabs.contains { $0.id == first } }?.id)
        commitsOnce { XCTAssertTrue(workspace.moveTab(second, to: firstPane)) }
        XCTAssertEqual(workspace.allSurfaceIDs, [first, second])
        XCTAssertEqual(workspace.activeTab?.id, second)
        commitsOnce { workspace.updateTab(second, title: "Changed", directory: "/", customTitle: "Custom") }
        commitsOnce { workspace.moveTabToNewSpace(second) }
        let selected = try XCTUnwrap(workspace.selectedSpace)
        let other = try XCTUnwrap(workspace.spaces.first { $0.id != selected }?.id)
        commitsOnce { XCTAssertTrue(workspace.reorderSpace(selected, relativeTo: other, after: false)) }
        XCTAssertEqual(workspace.allSurfaceIDs, [first, second])
        XCTAssertEqual(workspace.activeTab?.id, second)
        commitsOnce { workspace.closeTab(second) }
        XCTAssertEqual(workspace.allSurfaceIDs, [first])
        XCTAssertEqual(workspace.activeTab?.id, first)
    }

    func testCreatingHerdrSplitPublishesOneCompleteOptimisticLayout() async throws {
        let herdr = try await HerdrSession(); defer { herdr.close() }
        let workspace = herdr.app.workspace
        let key = try XCTUnwrap(herdr.snapshot().workspaces.first).workspace_id
        _ = try herdr.api("tab.create", ["workspace_id": key, "focus": false])
        try await TestSupport.eventually { workspace.current?.tabs.count == 2 }
        let count = try XCTUnwrap(workspace.current).tabs.count
        let original = try XCTUnwrap(workspace.current?.activePane)
        let identities = Set(original.tabs.flatMap(\.surfaceIDs))
        try herdr.pause()
        let revision = workspace.layoutRevision

        workspace.toggleSplit(.columns)

        XCTAssertEqual(workspace.layoutRevision, revision + 1, "Optimistic creation, original selection and split placement commit together")
        let split = try XCTUnwrap(workspace.current), created = try XCTUnwrap(split.activeTab)
        XCTAssertTrue(created.isConnecting)
        XCTAssertEqual(split.panes.count, 2)
        XCTAssertEqual(split.panes.first { $0.id == original.id }, original)
        XCTAssertEqual(split.activePane?.tabs.map(\.id), [created.id])
        XCTAssertTrue(identities.isSubset(of: Set(split.tabs.flatMap(\.surfaceIDs))))
        XCTAssertEqual(split.tabs.count, count + 1)
        let pane = split.focusedPane
        herdr.resume()
        try await TestSupport.eventually { workspace.activeTab?.id == created.id && workspace.activeTab?.isConnecting == false }
        XCTAssertEqual(workspace.current?.focusedPane, pane)
        XCTAssertEqual(workspace.current?.panes.first { $0.id == original.id }, original)
    }

    func testCreatingTmuxSplitCommitsOnceAndRetainsPlacementAfterConfirmation() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let workspace = app.workspace
        let original = try XCTUnwrap(workspace.current?.activePane)
        let originalWindow = try XCTUnwrap(workspace.current?.activeWindow)
        let revision = workspace.layoutRevision

        workspace.toggleSplit(.columns)

        XCTAssertEqual(workspace.layoutRevision, revision + 1, "The pending server window first appears in its completed split")
        let split = try XCTUnwrap(workspace.current), created = try XCTUnwrap(split.activeTab)
        XCTAssertTrue(created.isConnecting)
        XCTAssertEqual(split.panes.count, 2)
        XCTAssertEqual(split.panes.first { $0.id == original.id }, original)
        XCTAssertEqual(split.windows.first { $0.id == originalWindow.id }?.arrangement, originalWindow.arrangement)
        let createdPane = split.focusedPane
        try await app.ready()
        XCTAssertEqual(workspace.activeTab?.id, created.id)
        XCTAssertEqual(workspace.current?.focusedPane, createdPane)
        XCTAssertEqual(workspace.current?.panes.first { $0.id == original.id }, original)
        XCTAssertFalse(try XCTUnwrap(workspace.activeTab).isConnecting)
    }
}
