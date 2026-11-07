import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// Settings › Vertical tabs: no tab strips; the sidebar goes into the shown space and lists its tabs (SpaceTabsList).
@MainActor
final class VerticalTabsTests: XCTestCase {
    /// Off by default, and stored under the key of the mode it replaced (tabs only), so a choice made there carries over.
    func testPreferenceCarriesOverTheTabsOnlyChoice() throws {
        func decode(_ json: String) throws -> Preferences { try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)) }
        XCTAssertFalse(try decode("{}").verticalTabs)
        XCTAssertTrue(try decode(#"{"tabsOnly":true}"#).verticalTabs)
        let directory = System.temporary.appendingPathComponent(System.uuid().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        var preferences = store.values
        preferences.verticalTabs = true
        try store.save(preferences)
        XCTAssertTrue(SettingsStore(file: file).values.verticalTabs)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self).contains(#""tabsOnly":true"#))
    }

    /// Back lists the spaces; showing a space, by its row, its digits or a tab anywhere, goes into it again.
    func testShowingASpaceGoesIntoIt() throws {
        let workspace = Workspace()
        workspace.verticalTabs = true
        workspace.newSpace()
        let first = try XCTUnwrap(workspace.selectedSpace)
        let tab = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newSpace()
        let second = try XCTUnwrap(workspace.selectedSpace)
        XCTAssertFalse(workspace.sidebarListsSpaces)
        workspace.sidebarListsSpaces = true
        workspace.selectSpace(first)
        XCTAssertFalse(workspace.sidebarListsSpaces, "Choosing a space goes into it")
        workspace.sidebarListsSpaces = true
        workspace.selectSpace(at: 1)
        XCTAssertEqual(workspace.selectedSpace, second)
        XCTAssertFalse(workspace.sidebarListsSpaces, "So do the space digits")
        workspace.sidebarListsSpaces = true
        workspace.selectTab(tab)
        XCTAssertEqual(workspace.selectedSpace, first)
        XCTAssertFalse(workspace.sidebarListsSpaces, "And showing a tab of another space")
    }

    /// A space's tabs list in its panes' reading order, each pane's in order; the listed tab that is active is the
    /// focused pane's, and choosing one selects its pane. Splitting keeps every tab: no tab moves to make a row.
    func testSidebarListsTheSpacesTabsByPane() throws {
        let workspace = Workspace()
        workspace.verticalTabs = true
        workspace.newSpace()
        let first = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newTab()
        let second = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newSpace()
        let other = try XCTUnwrap(workspace.activeTab?.id)
        let space = try XCTUnwrap(workspace.spaces.first { $0.tabs.contains { $0.id == first } })
        XCTAssertEqual(workspace.sidebarTabs(in: space).map(\.id), [first, second])
        XCTAssertEqual(workspace.sidebarTabs.map(\.id), [first, second, other], "The radar's: every space's")
        workspace.selectTab(first)
        workspace.toggleSplit(.columns)
        let split = try XCTUnwrap(workspace.current)
        XCTAssertEqual(split.panes.count, 2)
        let rows = workspace.sidebarTabs(in: split)
        XCTAssertTrue(Set(rows.map(\.id)).isSuperset(of: [first, second]))
        let panes = rows.compactMap(\.pane).reduce(into: [UUID]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(panes, split.numberedPaneIDs, "A pane's tabs together, panes in reading order")
        XCTAssertTrue(rows.allSatisfy { !$0.window && $0.members.isEmpty })
        XCTAssertEqual(workspace.selectedSidebarTab, split.activeTab?.id)
        let left = try XCTUnwrap(rows.first { $0.pane == split.numberedPaneIDs[0] })
        workspace.selectSidebarTab(left.id)
        XCTAssertEqual(workspace.current?.focusedPane, split.numberedPaneIDs[0])
        XCTAssertEqual(workspace.selectedSidebarTab, left.id)
    }

    /// With one space the sidebar hides only while that space has one tab: it lists the tabs.
    func testSidebarHidesWithOneSpaceOnlyWhileItHasOneTab() throws {
        let controller = AppDelegate()
        controller.settings.values = Preferences()
        let workspace = controller.workspace
        workspace.verticalTabs = true
        workspace.newSpace()
        XCTAssertFalse(controller.sidebarVisible)
        workspace.newTab()
        XCTAssertTrue(controller.sidebarVisible, "Two tabs list in the sidebar")
        workspace.verticalTabs = false
        XCTAssertFalse(controller.sidebarVisible, "With strips, one space hides it")
        workspace.verticalTabs = true
        workspace.closeTab(try XCTUnwrap(workspace.activeTab?.id))
        XCTAssertFalse(controller.sidebarVisible)
        controller.settings.values.hideSingleSpace = false
        XCTAssertTrue(controller.sidebarVisible)
    }

    /// No pane has a strip: the content takes the window's height, and the sidebar names where each pane sits.
    func testPanesHaveNoStripsAndHeadingsNameThem() throws {
        let workspace = Workspace()
        workspace.newSpace()
        workspace.newTab()
        let space = try XCTUnwrap(workspace.current), pane = try XCTUnwrap(space.activePane)
        XCTAssertTrue(PaneView.showsTabs(pane: pane, space: space, verticalTabs: false), "Two tabs: a strip")
        XCTAssertFalse(PaneView.showsTabs(pane: pane, space: space, verticalTabs: true))
        XCTAssertFalse(WindowTabBar.showsTabs(space: space, verticalTabs: true))
        XCTAssertEqual(SpaceTabsList.place(CGRect(x: 0, y: 0, width: 0.5, height: 1)), "Left")
        XCTAssertEqual(SpaceTabsList.place(CGRect(x: 0.5, y: 0, width: 0.5, height: 1)), "Right")
        XCTAssertEqual(SpaceTabsList.place(CGRect(x: 0, y: 0.5, width: 1, height: 0.5)), "Bottom")
        XCTAssertEqual(SpaceTabsList.place(CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)), "Top right")
        XCTAssertEqual(SpaceTabsList.place(CGRect(x: 0, y: 0, width: 1, height: 1)), "Pane")
    }

    /// A split lists a heading per pane in reading order, each pane's tabs under it, the focused pane marked.
    func testSplitGroupsTabsUnderTheirPanes() throws {
        let workspace = Workspace()
        workspace.verticalTabs = true
        workspace.newSpace()
        workspace.newTab()
        workspace.toggleSplit(.columns)
        let space = try XCTUnwrap(workspace.current)
        let panes = SpaceTabsList.panes(of: space, tabs: workspace.sidebarTabs(in: space))
        XCTAssertEqual(panes.map(\.id), space.numberedPaneIDs)
        XCTAssertEqual(panes.map { SpaceTabsList.place($0.cell) }, ["Left", "Right"])
        XCTAssertEqual(panes.map(\.focused), space.numberedPaneIDs.map { $0 == space.focusedPane })
        for pane in panes {
            XCTAssertEqual(pane.tabs.map(\.id), space.panes.first { $0.id == pane.id }?.tabs.map(\.id))
        }
        XCTAssertEqual(panes.flatMap(\.tabs).count, space.tabs.count, "Every tab under its pane")
    }

    /// With the sidebar hidden (full screen's host mark), the space picker lists the shown space's tabs under its row,
    /// and New Tab: there is no strip to reach them. A click shows the tab and closes the picker. Strips on, none list.
    func testHostPickerListsTheShownSpacesTabs() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        let controller = AppDelegate(), workspace = controller.workspace
        TerminalRuntime.shared.workspace = workspace
        workspace.verticalTabs = true
        workspace.newSpace()
        let first = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newTab()
        let second = try XCTUnwrap(workspace.activeTab?.id)
        workspace.newSpace()
        let elsewhere = try XCTUnwrap(workspace.activeTab?.id)
        workspace.selectTab(second)
        var closed = 0
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: StripSpacePicker(workspace: workspace, controller: controller) { closed += 1 })
        window.makeKeyAndOrderFront(nil)
        func rows(_ id: UUID) -> [NSRect] { PresentationTestSupport.accessibilityFrames("strip-picker-tab-\(id)", in: window) }
        try await TestSupport.eventually(diagnostic: "the shown space's tabs did not list") {
            window.contentView?.layoutSubtreeIfNeeded()
            return !rows(first).isEmpty && !rows(second).isEmpty
        }
        XCTAssertTrue(rows(elsewhere).isEmpty, "only the shown space's tabs list")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("strip-space-picker-new-tab", in: window).isEmpty)
        let row = try XCTUnwrap(rows(first).first)
        try PresentationTestSupport.click(window, at: NSPoint(x: row.midX, y: row.midY))
        try await TestSupport.eventually { workspace.activeTab?.id == first && closed == 1 }

        workspace.verticalTabs = false
        try await TestSupport.eventually(diagnostic: "tabs listed with strips on") {
            window.contentView?.layoutSubtreeIfNeeded()
            return rows(first).isEmpty
                && PresentationTestSupport.accessibilityFrames("strip-space-picker-new-tab", in: window).isEmpty
        }
    }

    /// The banner under the strip (an agent waiting in another tab) shows that tab on a click and goes, with strips
    /// and with vertical tabs, the waiting tab behind the shown one or in another pane of a split.
    func testAttentionBannerGoesOnceClicked() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        for (vertical, split) in [(false, false), (true, false), (false, true), (true, true)] {
            let runtime = TerminalRuntime.shared
            let controller = AppDelegate(), workspace = controller.workspace
            controller.settings.values = Preferences()
            controller.settings.values.attentionNotifications = false
            controller.settings.values.verticalTabs = vertical
            workspace.verticalTabs = vertical
            runtime.workspace = workspace
            runtime.start(preferences: controller.settings.values)
            defer { runtime.stop() }
            workspace.onCloseTabs = { runtime.close($0) }
            workspace.newLocalSpace()
            let waiting = try XCTUnwrap(workspace.activeSurfaceID)
            workspace.newTab()
            let shown = try XCTUnwrap(workspace.activeSurfaceID)
            if split {
                workspace.split(.columns)
                XCTAssertEqual(workspace.current?.panes.count, 2)
                XCTAssertEqual(workspace.activeSurfaceID, shown, "the shown tab's pane has focus")
            }
            let pending = runtime.chat.session(for: waiting)
            pending.approvals = [PendingApproval(key: "approval", operation: "Run tests?") { _ in }]
            defer { runtime.chat.close(waiting); runtime.chat.close(shown) }
            XCTAssertEqual(controller.attention.banner?.id, waiting)
            let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; controller.window = window
            window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings,
                                                                  controller: controller))
            window.makeKeyAndOrderFront(nil)
            defer { window.close(); window.contentView = nil }
            var banner = NSRect.zero
            try await TestSupport.eventually(diagnostic: "no banner, vertical tabs \(vertical), split \(split)") {
                window.contentView?.layoutSubtreeIfNeeded()
                guard let frame = PresentationTestSupport.accessibilityFrames("attention-banner", in: window).first else { return false }
                banner = frame
                return true
            }
            try PresentationTestSupport.click(window, at: NSPoint(x: banner.midX, y: banner.midY))
            try await TestSupport.eventually(diagnostic: "the banner stayed, vertical tabs \(vertical), split \(split): active \(String(describing: workspace.activeSurfaceID)), banner \(String(describing: controller.attention.banner?.id))") {
                window.contentView?.layoutSubtreeIfNeeded()
                return workspace.activeSurfaceID == waiting
                    && PresentationTestSupport.accessibilityFrames("attention-banner", in: window).isEmpty
            }
        }
    }

    /// With the sidebar hidden the top-right pane's layout picker floats beside its mode switch, each its own control,
    /// with nothing drawn around them (the default button bezel showed there).
    func testFloatingLayoutPickerBesideTheSwitch() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        let runtime = TerminalRuntime.shared
        let controller = AppDelegate(), workspace = controller.workspace
        controller.settings.values = Preferences()
        controller.settings.values.verticalTabs = true
        workspace.verticalTabs = true
        runtime.workspace = workspace
        runtime.start(preferences: controller.settings.values)
        defer { runtime.stop() }
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newLocalSpace()
        for _ in 0..<3 { workspace.newTab() }
        XCTAssertTrue(workspace.applyLayout(.grid))
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings,
                                                              controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        var picker = NSRect.zero
        controller.windowState.sidebarVisibilityOverride = false
        try await TestSupport.eventually { !controller.sidebarVisible }
        try await TestSupport.eventually(diagnostic: "no floating layout picker: \(PresentationTestSupport.accessibilityIdentifiers(in: window))") {
            window.contentView?.layoutSubtreeIfNeeded()
            // The pointer in the top-right pane's corner reveals its switch over the terminal.
            if let root = window.contentView {
                for reveal in PresentationTestSupport.views(of: FloatingSwitchRevealView.self, in: root) {
                    reveal.updatePointer(at: NSPoint(x: reveal.bounds.width - 2, y: 2))
                }
            }
            guard let frame = PresentationTestSupport.accessibilityFrames("layout-picker", in: window).first else { return false }
            picker = frame
            return true
        }
        try await Task.sleep(for: .milliseconds(400))
        let snapshot = try await PresentationTestSupport.capture(window, named: "floating-layout-picker", in: "vertical-tabs")
        // Its frame's corner, outside the circle, is the terminal's dark: no button bezel drawn around it.
        let root = try XCTUnwrap(window.contentView)
        let bitmap = snapshot.bitmap, scale = CGFloat(bitmap.pixelsWide) / root.bounds.width
        let corner = root.convert(NSPoint(x: picker.minX + 1.5, y: picker.maxY - 1.5), from: nil)
        let y = root.isFlipped ? corner.y : root.bounds.height - corner.y
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(corner.x * scale), y: Int(y * scale))?.usingColorSpace(.deviceRGB))
        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
        XCTAssertLessThan(brightness, 0.12, "a bezel around the layout picker: \(color) at \(picker)")
    }
}
