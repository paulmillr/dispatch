import AppKit
import SwiftUI
import XCTest
import Term
@testable import DispatchApp

@MainActor
final class UIWalkthroughTests: XCTestCase {
    func testFindNavigatesChatIncludingCollapsedToolOutput() async throws {
        let app = try AppWindowFixture()
        defer { app.close() }
        let id = try XCTUnwrap(app.controller.workspace.activeSurfaceID)
        try await TestSupport.eventually { app.window.isKeyWindow && TerminalRuntime.shared.views[id]?.surface != nil }
        let session = TerminalRuntime.shared.chat.session(for: id)
        session.sessionID = "find-chat"; session.active = true; session.showChat = true
        session.insert(ChatItem(id: "first", kind: .assistant, text: "First needle"), turnID: "turn")
        session.insert(ChatItem(id: "tool-a", kind: .tool, text: "{}", title: "Read", output: String(repeating: "other\n", count: 7000) + "hidden needle", completed: true), turnID: "turn")
        session.insert(ChatItem(id: "tool-b", kind: .tool, text: "{}", title: "Read", output: "done", completed: true), turnID: "turn")
        try app.shortcut("f", keyCode: 3)
        try await TestSupport.eventually { session.search.visible }
        XCTAssertFalse(session.terminalSearch.visible)
        session.search.query = "needle"
        try await TestSupport.eventually { session.search.total == 2 }
        try app.shortcut("g", keyCode: 5)
        try await TestSupport.eventually { session.search.selected == 0 }
        try app.shortcut("g", keyCode: 5)
        try await TestSupport.eventually { session.search.selected == 1 }
        let match = try XCTUnwrap(session.searchMatch)
        XCTAssertEqual(match.document.label, "Tool output")
        XCTAssertTrue(match.excerpt.text.contains("hidden needle"))
        XCTAssertTrue(session.visibleTranscriptRows.contains { $0.id == match.document.row })
        let capture = try await PresentationTestSupport.capture(app.window, named: "chat-find")
        XCTAssertTrue(try capture.text().contains("hidden needle"))
        try app.shortcut("g", keyCode: 5)
        try await TestSupport.eventually { session.search.selected == 0 }
        session.search.close()
        session.resetConversation()
        XCTAssertFalse(session.search.visible)
        XCTAssertTrue(session.searchMatches.isEmpty)
    }

    func testFindSearchesTerminalHistoryWithoutResizingOrSendingInput() async throws {
        let app = try AppWindowFixture()
        defer { app.close() }
        let id = try XCTUnwrap(app.controller.workspace.activeSurfaceID)
        try await TestSupport.eventually { TerminalRuntime.shared.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(TerminalRuntime.shared.views[id])
        TerminalTestSupport.send("printf '\\033[2J\\033[H'; printf 'find-%s\\n' alpha alpha; for i in {1..100}; do echo row-$i; done", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("row-100") }
        XCTAssertFalse(TerminalTestSupport.viewport(terminal: terminal).contains("find-alpha"))
        let surface = try XCTUnwrap(terminal.surface)
        let size = surface.grid
        try app.shortcut("f", keyCode: 3)
        let search = TerminalRuntime.shared.chat.session(for: id).terminalSearch
        try await TestSupport.eventually { search.visible }
        search.query = "find-alpha"
        try await TestSupport.eventually { search.total == 2 }
        try app.shortcut("g", keyCode: 5)
        try await TestSupport.eventually { search.selected != nil }
        let first = search.selected
        try app.shortcut("g", keyCode: 5)
        try await TestSupport.eventually { search.selected != first }
        try app.shortcut("G", keyCode: 5, modifiers: [.command, .shift])
        try await TestSupport.eventually { search.selected == first }
        XCTAssertTrue(TerminalTestSupport.viewport(terminal: terminal).contains("find-alpha"))
        XCTAssertEqual(surface.grid.columns, size.columns)
        XCTAssertEqual(surface.grid.rows, size.rows)
        search.query = "no-such-search-match"
        try await TestSupport.eventually { search.total == 0 }
        search.close()
        try await TestSupport.eventually { app.window.firstResponder === terminal }
        terminal.performBindingAction("scroll_to_bottom")
        XCTAssertFalse(TerminalTestSupport.screen(terminal: terminal).contains("no-such-search-match"))
    }

    func testTabScrollRoutingAndMovedHover() async throws {
        let app = try AppWindowFixture(width: 1000, height: 700)
        defer { app.close() }
        let workspace = app.controller.workspace
        for _ in 0..<11 { workspace.newTab() }
        let tab = try XCTUnwrap(workspace.activeTab).id
        let root = try XCTUnwrap(app.window.contentView)
        try await TestSupport.eventually {
            PresentationTestSupport.views(of: ReorderTrackingView.self, in: root).contains { $0.configuration.item == .tab(tab) }
        }
        let row = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: root).first { $0.configuration.item == .tab(tab) })
        let scroll = try XCTUnwrap(row.enclosingScrollView)
        try await TestSupport.eventually { !row.visibleRect.isEmpty }
        let clip = scroll.contentView
        let start = clip.bounds.origin
        let event = try XCTUnwrap(NSEvent(cgEvent: try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil,
            units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 120, wheel3: 0))))
        row.scrollWheel(with: event)
        try await TestSupport.eventually { clip.bounds.origin == NSPoint(x: start.x - 120, y: start.y) }
        let forwarded = clip.bounds.origin
        clip.scroll(to: start); scroll.reflectScrolledClipView(clip)
        scroll.scrollWheel(with: event)
        try await TestSupport.eventually { clip.bounds.origin == forwarded }
        let direct = clip.bounds.origin
        XCTAssertEqual(forwarded, direct)
        XCTAssertLessThan(direct.x, start.x)
        clip.scroll(to: start); scroll.reflectScrolledClipView(clip)
        root.layoutSubtreeIfNeeded()
        row.hover.present(from: row)
        XCTAssertNotNil(row.hover.panel)
        clip.scroll(to: NSPoint(x: max(0, start.x - 80), y: start.y)); scroll.reflectScrolledClipView(clip)
        XCTAssertNil(row.hover.panel, "Scrolling must immediately dismiss the hint")
        row.hover.refresh(from: row)
        XCTAssertNil(row.hover.panel, "A moved anchor must dismiss its hint instead of repositioning it")
        row.hover.dismiss()
        let terminal = try XCTUnwrap(TerminalRuntime.shared.views[tab])
        let frame = scroll.convert(scroll.bounds, to: nil), content = terminal.convert(terminal.bounds, to: nil)
        XCTAssertTrue(frame.intersection(content).isEmpty, "The tab scroller must stay out of the terminal")
        _ = try await PresentationTestSupport.capture(app.window, named: "tab-scroll-routing")
    }

    func testCreationAndClosingShortcutsKeepTabsAndSpacesDistinct() async throws {
        let app = try AppWindowFixture()
        defer { app.close() }
        let workspace = app.controller.workspace
        let originalSpace = try XCTUnwrap(workspace.selectedSpace)
        try app.shortcut("t", keyCode: 17)
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.currentTabs.count, 2)
        try app.shortcut("N", keyCode: 45, modifiers: [.command, .shift])
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.currentTabs.count, 1)
        XCTAssertEqual(workspace.current?.hostID, .local)
        try app.shortcut("W", keyCode: 13, modifiers: [.command, .shift])
        XCTAssertEqual(workspace.spaces.count, 1)
        XCTAssertEqual(workspace.currentTabs.count, 2)
        try app.shortcut("n", keyCode: 45)
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.currentTabs.count, 1)
        try app.shortcut("t", keyCode: 17)
        try app.shortcut("w", keyCode: 13)
        XCTAssertEqual(workspace.spaces.count, 2)
        XCTAssertEqual(workspace.currentTabs.count, 1)
        try app.shortcut("t", keyCode: 17)
        try app.shortcut("W", keyCode: 13, modifiers: [.command, .shift])
        XCTAssertEqual(workspace.spaces.map(\.id), [originalSpace])
        XCTAssertEqual(workspace.currentTabs.count, 2)
        let file = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu)
        for title in ["Rename Space…", "Rename Tab…"] {
            XCTAssertEqual(try XCTUnwrap(file.items.first { $0.title == title }).keyEquivalent, "")
        }
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        XCTAssertFalse(view.items.contains { $0.title == "Host Statistics" })
    }

    func testLongTabTitlesKeepCloseButtonInsideVisibleStrip() async throws {
        try await checkLongTabClose(fontSize: 12.5)
    }

    func testLargeFontKeepsTabCloseButtonInsideVisibleStrip() async throws {
        try await checkLongTabClose(fontSize: 22)
    }

    private func checkLongTabClose(fontSize: Double) async throws {
        let app = try AppWindowFixture(width: 620, height: 440)
        defer { app.close() }
        app.controller.settings.values.fontSize = fontSize
        let workspace = app.controller.workspace
        workspace.newTab()
        let tab = try XCTUnwrap(workspace.activeTab)
        workspace.updateTab(tab.id, customTitle: String(repeating: "long-project-name-", count: 12))
        try await Task.sleep(for: .milliseconds(300))
        let root = try XCTUnwrap(app.window.contentView)
        let row = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
            .first { $0.configuration.item == .tab(tab.id) })
        var ancestor = row.superview
        while ancestor != nil && !(ancestor is NSClipView) { ancestor = ancestor?.superview }
        let viewport = try XCTUnwrap(ancestor)
        _ = try await PresentationTestSupport.capture(app.window, named: "walkthrough-long-tab")
        XCTAssertLessThanOrEqual(row.bounds.width, viewport.bounds.width, "Long titles must truncate before their close button leaves the strip")
        // The close button replaces the status glyph in the tab's leading slot.
        let closePoint = row.convert(NSPoint(x: row.bounds.minX + 2 + StripTab.closeButtonWidth / 2, y: row.bounds.midY), to: nil)
        XCTAssertTrue(viewport.convert(viewport.bounds, to: nil).contains(closePoint))
        guard viewport.convert(viewport.bounds, to: nil).contains(closePoint) else { return }
        try await app.hover(at: row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil))
        try await app.hover(at: closePoint)
        _ = try await PresentationTestSupport.capture(app.window, named: "walkthrough-long-tab-hover-\(fontSize)")
        try PresentationTestSupport.click(app.window, at: closePoint)
        try await TestSupport.eventually { !workspace.allTabIDs.contains(tab.id) }
    }

    func testTabsShareTheStripEquallyUntilTheyScroll() async throws {
        let app = try AppWindowFixture()
        defer { app.close() }
        let workspace = app.controller.workspace
        let root = try XCTUnwrap(app.window.contentView)
        func widths() throws -> (tabs: [UUID: CGFloat], viewport: CGFloat) {
            root.layoutSubtreeIfNeeded()
            let rows = PresentationTestSupport.views(of: ReorderTrackingView.self, in: root).compactMap { row -> (UUID, ReorderTrackingView)? in
                if case .tab(let id) = row.configuration.item { return (id, row) }
                return nil
            }
            var ancestor = rows.first?.1.superview
            while ancestor != nil && !(ancestor is NSClipView) { ancestor = ancestor?.superview }
            return (Dictionary(uniqueKeysWithValues: rows.map { ($0.0, $0.1.bounds.width) }), try XCTUnwrap(ancestor).bounds.width)
        }
        workspace.newTab()
        let pair = workspace.currentTabs.map(\.id)
        workspace.updateTab(pair[0], customTitle: "ab")
        workspace.updateTab(pair[1], customTitle: String(repeating: "longer-title-", count: 3))
        try await Task.sleep(for: .milliseconds(300))
        let shared = try widths()
        for id in pair {
            XCTAssertEqual(try XCTUnwrap(shared.tabs[id]), shared.viewport / 2, accuracy: 2, "Two tabs split the strip, whatever their titles")
        }
        for _ in 0..<10 { workspace.newTab() }
        try await Task.sleep(for: .milliseconds(300))
        let crowded = try widths()
        let sizes = workspace.currentTabs.compactMap { crowded.tabs[$0.id] }
        XCTAssertEqual(Set(sizes.map { $0.rounded() }).count, 1, "Tabs stay equal: \(sizes)")
        // Twelve tabs would be under 70 points each in this strip; they stop well above that and scroll.
        XCTAssertGreaterThan(try XCTUnwrap(sizes.first), 100, "Tabs keep a usable minimum")
        XCTAssertGreaterThan(sizes.reduce(0, +), crowded.viewport, "Past the minimum the strip scrolls")
        _ = try await PresentationTestSupport.capture(app.window, named: "walkthrough-tab-widths")
    }

    func testMinimumWindowWithNestedSplits() async throws {
        let app = try AppWindowFixture(width: 620, height: 440)
        defer { app.close() }
        let workspace = app.controller.workspace
        workspace.newTab()
        workspace.newTab()
        let firstPane = try XCTUnwrap(workspace.current?.activePane)
        workspace.split(.columns)
        workspace.selectTab(firstPane.tabs[1].id)
        workspace.split(.columns)
        app.controller.toggleSidebar()
        try await Task.sleep(for: .milliseconds(350))
        _ = try await PresentationTestSupport.capture(app.window, named: "walkthrough-minimum-nested-splits")
        for tab in workspace.current!.tabs {
            let terminal = try XCTUnwrap(TerminalRuntime.shared.views[tab.id])
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, PaneLayout.minimumPaneSize.width - 1)
            XCTAssertGreaterThanOrEqual(terminal.bounds.height, PaneLayout.minimumPaneSize.height - 31)
        }
        XCTAssertEqual(workspace.allTabIDs.count, 3)
    }

    func testCompactSplitKeepsSelectedTabClosableWithChatControls() async throws {
        let app = try AppWindowFixture(width: 620, height: 440)
        defer { app.close() }
        let workspace = app.controller.workspace
        workspace.newTab()
        workspace.newTab()
        workspace.split(.columns)
        workspace.newTab()
        let tab = try XCTUnwrap(workspace.activeTab)
        TerminalRuntime.shared.chat.session(for: tab.id).active = true
        try await Task.sleep(for: .milliseconds(250))
        let root = try XCTUnwrap(app.window.contentView)
        let split = try XCTUnwrap(PresentationTestSupport.views(of: TerminalSplitView.self, in: root, includingNestedMatches: true)
            .first { !$0.sidebar && $0.isVertical })
        split.setPosition(split.bounds.width - 181, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(250))
        let row = try XCTUnwrap(PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
            .first { $0.configuration.item == .tab(tab.id) })
        let terminal = try XCTUnwrap(TerminalRuntime.shared.views[tab.id])
        XCTAssertEqual(terminal.bounds.width, 180, accuracy: 1)
        // The close button replaces the status glyph in the tab's leading slot.
        let closePoint = row.convert(NSPoint(x: row.bounds.minX + 2 + StripTab.closeButtonWidth / 2, y: row.bounds.midY), to: nil)
        let paneFrame = terminal.convert(terminal.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(closePoint.x, paneFrame.minX)
        XCTAssertLessThanOrEqual(closePoint.x, paneFrame.maxX - 28, "The close button must stay before the pane toolbar")
        _ = try await PresentationTestSupport.capture(app.window, named: "walkthrough-compact-chat-pane")
        try await app.hover(at: closePoint)
        try PresentationTestSupport.click(app.window, at: closePoint)
        try await TestSupport.eventually { !workspace.allTabIDs.contains(tab.id) }
    }
}

@MainActor
private final class AppWindowFixture {
    private let restore = TestSupport.preserveRuntime()
    let controller = AppDelegate()
    let window: MainWindow
    private let previousMenu: NSMenu?
    private let previousChat: ChatCoordinator
    private let previousPointer = CGEvent(source: nil)?.location
    private let answerer = CloseConfirmationAnswerer()

    init(width: CGFloat = 1000, height: CGFloat = 700) throws {
        try DesktopTestSupport.requireUnlocked()
        previousMenu = NSApp.mainMenu
        let runtime = TerminalRuntime.shared
        previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        controller.settings.values = Preferences()
        runtime.workspace = controller.workspace
        runtime.start(preferences: controller.settings.values)
        // These walkthroughs exercise UI state, without agent discovery changing fixtures.
        runtime.chat.stop()
        controller.workspace.onCloseTabs = { runtime.close($0) }
        controller.workspace.newSpace()
        window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        controller.window = window
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: MainView(workspace: controller.workspace, settings: controller.settings, controller: controller))
        controller.buildMenus()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hover(at point: NSPoint) async throws {
        let screenPoint = window.convertPoint(toScreen: point)
        let desktop = try XCTUnwrap(NSScreen.screens.first)
        let position = CGPoint(x: screenPoint.x, y: desktop.frame.maxY - screenPoint.y)
        XCTAssertEqual(CGWarpMouseCursorPosition(position), .success)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
            mouseCursorPosition: position, mouseButton: .left))
        event.postToPid(getpid())
        // Associate the move with this fixture window so SwiftUI updates hover tracking.
        window.sendEvent(try PresentationTestSupport.mouseEvent(.mouseMoved, in: window, at: point))
        // SwiftUI updates hover state before enabling the close button's hit target.
        try await Task.sleep(for: .milliseconds(150))
    }

    func shortcut(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = .command) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        XCTAssertTrue(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
    }

    func close() {
        answerer.stop()
        window.orderOut(nil)
        window.contentView = nil
        NSApp.mainMenu = previousMenu
        TerminalRuntime.shared.stop()
        TerminalRuntime.shared.chat = previousChat
        HostStats.shared.stop()
        restore()
        if let previousPointer { CGWarpMouseCursorPosition(previousPointer) }
    }
}
