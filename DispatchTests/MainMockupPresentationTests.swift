import AppKit
import SwiftUI
import Vision
import XCTest
@testable import DispatchApp

@MainActor
final class MainMockupPresentationTests: XCTestCase {
    func testSidebarPalettesPreserveTerminalSurface() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppDelegate(settings: SettingsStore(file: directory.appendingPathComponent("settings.json")))
        let runtime = TerminalRuntime.shared, workspace = controller.workspace
        let previousSidebar = SidebarThemeStore.shared.current
        runtime.workspace = workspace; runtime.start(preferences: Preferences())
        workspace.onCloseTabs = { runtime.close($0) }
        controller.settings.values.hideSingleSpace = false
        workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "api-refactor")
        workspace.newTab()
        let tab = try XCTUnwrap(workspace.activeTab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            runtime.stop(); HostStats.shared.stop(); SidebarThemeStore.shared.current = previousSidebar
        }
        try await TestSupport.eventually { runtime.views[tab.id]?.surface != nil }
        let surface = runtime.views[tab.id]?.surface
        let terminal = try XCTUnwrap(runtime.views[tab.id])
        TerminalTestSupport.send("printf 'THEME_%s\\n' READY", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("THEME_READY") }
        for theme in SidebarTheme.allCases {
            controller.settings.values.appTheme = AppTheme(rawValue: theme.rawValue)!
            try runtime.apply(controller.settings.values)
            try await TestSupport.eventually { SidebarThemeStore.shared.current == theme }
            _ = try await capture(window, "main-sidebar-" + theme.rawValue)
            XCTAssertTrue(runtime.views[tab.id]?.surface === surface)
            XCTAssertTrue(TerminalTestSupport.screen(terminal: terminal).contains("THEME_READY"))
            XCTAssertEqual(window.appearance?.name, theme == .dark ? .darkAqua : .aqua)
        }
    }

    func testMainEmptyReducedFlatTreeAndCustomSplitStates() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        let workspace = controller.workspace
        runtime.workspace = workspace; runtime.start(preferences: Preferences.flat)
        workspace.onCloseTabs = { runtime.close($0) }
        controller.settings.values.hideSingleSpace = true
        controller.settings.values.spaceOrder = .flat
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        let empty = try await capture(window, "main-empty").text()
        // Vision may split a centered heading into observations interleaved with
        // the buttons below it. Check the visible words without assuming OCR order.
        let emptyWords = Set(empty.split(whereSeparator: { !$0.isLetter }).map(String.init))
        XCTAssertTrue(Set(["A", "space", "to", "work"]).isSubset(of: emptyWords), empty)
        XCTAssertTrue(empty.contains("New Space"), empty)
        XCTAssertTrue(empty.contains("New Tab"), empty)
        workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "api-refactor")
        let firstSpace = workspace.selectedSpace!
        let firstTab = try XCTUnwrap(workspace.activeTab)
        let reduced = try await capture(window, "main-single").text()
        XCTAssertFalse(reduced.contains("+ space")); XCTAssertFalse(reduced.contains("urgency"))
        workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "ci-fix")
        workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "scratch")
        workspace.selectSpace(firstSpace)
        for _ in 0..<3 { workspace.newTab() }
        for (index, tab) in workspace.currentTabs.enumerated() { workspace.updateTab(tab.id, customTitle: ["billing", "tests", "docs", "shell"][index]) }
        let flat = try await capture(window, "main-flat").text()
        for label in ["api-refactor", "ci-fix", "scratch", "+ space"] { XCTAssertTrue(flat.contains(label), flat) }
        XCTAssertFalse(flat.contains("single"), "The default layout control is icon-only")
        controller.settings.values.spaceOrder = .tree
        let treeSnapshot = try await capture(window, "main-tree")
        let tree = try sidebarText(treeSnapshot, window: window)
        // The host heading's plus stays hidden until the pointer is over it (NewSpacePresentationTests).
        XCTAssertFalse(tree.contains("this Mac")); XCTAssertTrue(tree.contains("Local"), tree)
        XCTAssertFalse(tree.contains("+ local"), tree)
        let original = workspace.allTabIDs
        workspace.applyLayout(.grid)
        _ = try await capture(window, "main-grid")
        XCTAssertEqual(workspace.allTabIDs, original)
        XCTAssertNotNil(runtime.views[firstTab.id]?.surface)
        window.setContentSize(NSSize(width: 700, height: 520))
        _ = try await capture(window, "main-narrow-grid")
        XCTAssertEqual(workspace.allTabIDs, original)
    }

    func testLayoutControlRemainsInGeometricTopRightForCustomSplits() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let rows = PaneLayout.split(UUID(), .rows, .pane(a), .pane(b))
        XCTAssertEqual(rows.topRightPaneID, a)
        let grid = PaneLayout.split(UUID(), .rows,
            .split(UUID(), .columns, .pane(a), .pane(b)),
            .split(UUID(), .columns, .pane(c), .pane(d)))
        XCTAssertEqual(grid.topRightPaneID, b, "Custom split placement cannot depend on a preset label")
        let side = PaneLayout.split(UUID(), .columns, .pane(a), .split(UUID(), .rows, .pane(b), .pane(c)))
        XCTAssertEqual(side.topRightPaneID, b)
    }

    func testOverflowAttentionJumpSwitcherAndLastSpaceShortcut() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let runtime = TerminalRuntime.shared, controller = AppDelegate()
        controller.settings.values = Preferences.flat
        let workspace = controller.workspace
        runtime.workspace = workspace; runtime.start(preferences: Preferences.flat)
        workspace.onCloseTabs = { runtime.close($0) }
        controller.settings.values.hideSingleSpace = false
        controller.settings.values.spaceOrder = .flat
        for index in 1...24 {
            workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "project-\(index)")
        }
        let first = workspace.spaces[0], last = workspace.spaces[23]
        workspace.selectSpace(first.id)
        // Short, zero-padded titles fit a minimum-width tab untruncated, and none is a prefix of another.
        for index in 1...13 { workspace.newTab(); workspace.updateTab(workspace.activeTab!.id, customTitle: String(format: "job-%02d", index)) }
        let original = workspace.allTabIDs
        let hiddenTab = runtime.chat.session(for: first.panes[0].selected)
        hiddenTab.approvals.append(PendingApproval(key: "hidden-tab", operation: "swift test") { _ in })
        let pending = runtime.chat.session(for: last.panes[0].selected)
        pending.approvals.append(PendingApproval(key: "hidden", operation: "swift build") { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 540), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        let beforeSnapshot = try await capture(window, "main-overflow")
        let before = try beforeSnapshot.text()
        XCTAssertTrue(before.contains("more"), before)
        let sidebar = try sidebarText(beforeSnapshot, window: window)
        XCTAssertTrue(sidebar.contains("needs you"), sidebar)
        XCTAssertTrue(before.contains("job-13"), "Selected overflowing tab must stay visible: \(before)")
        // The overflow pill's left side pages the strip back to the tabs scrolled
        // out before the selected one, without changing the selection.
        func visibleJobs(_ text: String) -> [Int] {
            text.matches(of: /job-(\d\d)/).compactMap { Int($0.1) }
        }
        let firstVisible = try XCTUnwrap(visibleJobs(before).min(), before)
        XCTAssertGreaterThan(firstVisible, 1, "Earlier tabs are scrolled out: \(before)")
        let split = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self, in: XCTUnwrap(window.contentView)).first { $0.sidebar })
        let pane = try XCTUnwrap(split.arrangedSubviews.last)
        let terminal = try XCTUnwrap(workspace.activeSurfaceID.flatMap { runtime.views[$0] })
        // The glass sidebar overlays the split; its second view includes the sidebar's width.
        let point = NSPoint(x: terminal.convert(.zero, to: nil).x + Chrome.stripInset + 10,
            y: pane.convert(NSPoint(x: 0, y: pane.isFlipped ? 15 : pane.bounds.height - 15), to: nil).y)
        try PresentationTestSupport.click(window, at: point)
        var earlier = ""
        try await TestSupport.eventually(diagnostic: "Earlier tabs: \(earlier)") {
            earlier = try await PresentationTestSupport.capture(window).text()
            return visibleJobs(earlier).contains { $0 < firstVisible }
        }
        _ = try await capture(window, "main-overflow-previous-tab")
        XCTAssertEqual(workspace.activeTab?.label, "job-13")
        XCTAssertTrue(hiddenTab.approvals[0].pending)
        hiddenTab.approvals[0].resolve(.deny)
        _ = try await capture(window, "main-overflow-resolved-tab")
        // ⌘J is the Navigate menu's Next Attention.
        controller.nextAttention()
        let after = try await capture(window, "main-overflow-jump").text()
        XCTAssertEqual(workspace.selectedSpace, last.id)
        XCTAssertFalse(after.contains("needs you"), "The hidden-row attention badge clears after jumping. \(after)")
        XCTAssertTrue(pending.approvals[0].pending, "Navigation must not decide an approval")
        XCTAssertEqual(workspace.allTabIDs, original)
        for index in 25...44 { workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "project-\(index)") }
        _ = try await capture(window, "main-overflow-search")
        let root = try XCTUnwrap(window.contentView)
        let field = try await PresentationTestSupport.openSpaceSearch(controller, in: root)
        window.makeFirstResponder(field)
        XCTAssertEqual(workspace.spaces.count, 44)
        let shortcut = NSMenuItem(); shortcut.tag = 0; controller.selectSpace(shortcut)
        shortcut.tag = 8; controller.selectSpace(shortcut)
        XCTAssertEqual(workspace.selectedSpace, workspace.spaces.last?.id, "Control-9 always selects the last space")
    }

    private func sidebarText(_ snapshot: PresentationTestSupport.Snapshot, window: NSWindow) throws -> String {
        // Keep terminal text from interleaving with sidebar rows in Vision's
        // reading order. These fixtures use the standard 264-point sidebar.
        let width = try XCTUnwrap(window.contentView).bounds.width
        return try snapshot.text(in: CGRect(x: 0, y: 0, width: 264 / width, height: 1))
    }

    private func capture(_ window: NSWindow, _ name: String) async throws -> PresentationTestSupport.Snapshot {
        try await Task.sleep(for: .milliseconds(450))
        return try await PresentationTestSupport.capture(window, named: name)
    }
}
