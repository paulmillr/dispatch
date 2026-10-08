import AppKit
import SwiftUI
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class PlanOnePresentationTests: XCTestCase {
    func testNativeLayoutsDropZonesAndStatsPopover() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let runtime = TerminalRuntime.shared
        let controller = AppDelegate(); let workspace = controller.workspace
        controller.settings.values = Preferences.flat
        runtime.workspace = workspace; runtime.start(preferences: Preferences.flat)
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.newSpace()
        for _ in 0..<5 { workspace.newTab() }
        var preferences = controller.settings.values
        preferences.hideSingleSpace = false
        controller.settings.values = preferences // in-memory test choices only
        for (index, tab) in workspace.currentTabs.enumerated() {
            workspace.updateTab(tab.id, customTitle: ["billing", "tests", "docs", "migrate", "shell", "logs"][index])
        }
        let firstSpace = workspace.selectedSpace!
        workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "ci-fix")
        workspace.newSpace(); workspace.renameSpace(workspace.selectedSpace!, to: "scratch")
        workspace.selectSpace(firstSpace)
        let original = workspace.allTabIDs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; runtime.stop(); HostStats.shared.stop() }
        func capture(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(250))
            _ = try await PresentationTestSupport.capture(window, named: name, in: "plan-1-validation")
        }
        try await capture("tabs-overflow-flat")
        let tab = try XCTUnwrap(workspace.activeTab)
        let terminal = try XCTUnwrap(runtime.views[tab.id]); let surface = try XCTUnwrap(terminal.surface)
        workspace.applyLayout(.twoAbove)
        try await capture("two-above")
        workspace.applyLayout(.grid)
        try await capture("grid")
        XCTAssertEqual(workspace.allTabIDs, original)
        XCTAssertTrue(terminal.surface === surface)
        workspace.applyLayout(.single)
        try await Task.sleep(for: .milliseconds(150))
        window.setContentSize(NSSize(width: 1800, height: 740))
        try await Task.sleep(for: .milliseconds(150))
        let wideTrackers = PresentationTestSupport.views(of: ReorderTrackingView.self, in: try XCTUnwrap(window.contentView))
        let trailingTab = workspace.currentTabs[0].id
        let tabSource = try XCTUnwrap(wideTrackers.first { $0.configuration.item == .tab(trailingTab) })
        let stripBlank = try XCTUnwrap(wideTrackers.first {
            // The strip's own zone (a strip is at most 38 pt tall), not the pane-wide one below it.
            $0.configuration.edge == .pane && $0.bounds.height <= 40 && $0.bounds.width > 600 && $0.configuration.accepts(.tab(trailingTab))
        })
        let tabStart = tabSource.convert(NSPoint(x: 40, y: 12), to: nil)
        let stripEnd = stripBlank.convert(NSPoint(x: stripBlank.bounds.maxX - 10, y: stripBlank.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try PresentationTestSupport.mouseEvent(type, in: window, at: point)
        }
        var blankEvents = try [mouse(.leftMouseDragged, stripEnd), mouse(.leftMouseUp, stripEnd)]
        tabSource.trackMouse(with: try mouse(.leftMouseDown, tabStart)) { blankEvents.isEmpty ? nil : blankEvents.removeFirst() }
        XCTAssertEqual(workspace.currentTabs.last?.id, trailingTab, "The full-width blank strip must accept a trailing reorder")
        XCTAssertEqual(workspace.activeTab?.id, tab.id)
        window.setContentSize(NSSize(width: 1180, height: 740))
        try await Task.sleep(for: .milliseconds(150))
        let trackers = PresentationTestSupport.views(of: ReorderTrackingView.self, in: try XCTUnwrap(window.contentView))
        let source = try XCTUnwrap(trackers.first { $0.configuration.item == .tab(tab.id) })
        let destination = try XCTUnwrap(trackers.first {
            $0.configuration.edge == .split(.right) && !$0.isHiddenOrHasHiddenAncestor &&
                !$0.visibleRect.isEmpty && $0.configuration.accepts(.tab(tab.id))
        })
        let origin = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let end = destination.convert(NSPoint(x: destination.bounds.midX, y: destination.bounds.midY), to: nil)
        var events = try [mouse(.leftMouseDragged, end), mouse(.leftMouseUp, end)]
        source.trackMouse(with: try mouse(.leftMouseDown, origin)) {
            if events.count == 1 {
                // Native mouse tracking cannot suspend; preserve its intermediate view rendering.
                if let view = window.contentView {
                    _ = try? PresentationTestSupport.render(view, named: "drag-split-preview", in: "plan-1-validation")
                }
            }
            return events.isEmpty ? nil : events.removeFirst()
        }
        XCTAssertEqual(workspace.current?.panes.count, 2)
        XCTAssertEqual(workspace.allTabIDs, original)
        try await capture("drag-split-result")
        let currentTrackers = PresentationTestSupport.views(of: ReorderTrackingView.self, in: try XCTUnwrap(window.contentView))
        let spaceSource = try XCTUnwrap(currentTrackers.first { $0.configuration.item == .space(firstSpace) })
        let blank = try XCTUnwrap(currentTrackers.first { $0.configuration.edge == .pane && $0.configuration.accepts(.space(firstSpace)) })
        let rowStart = spaceSource.convert(NSPoint(x: 40, y: spaceSource.bounds.midY), to: nil)
        let blankFrame = blank.convert(blank.bounds, to: nil)
        for row in currentTrackers where row.configuration.edge == .vertical {
            XCTAssertLessThanOrEqual(blankFrame.maxY, row.convert(row.bounds, to: nil).minY,
                                     "Move-to-end must occupy only the empty area below the spaces")
        }
        let originalSpaceOrder = workspace.spaces.map(\.id)
        let gutter = spaceSource.convert(NSPoint(x: -4, y: spaceSource.bounds.midY), to: nil)
        events = try [mouse(.leftMouseDragged, gutter), mouse(.leftMouseUp, gutter)]
        spaceSource.trackMouse(with: try mouse(.leftMouseDown, rowStart)) {
            if events.count == 1 {
                XCTAssertNil(blank.insertionAfter, "Crossing the sidebar margin must not draw an insertion line above the list")
            }
            return events.isEmpty ? nil : events.removeFirst()
        }
        XCTAssertEqual(workspace.spaces.map(\.id), originalSpaceOrder)
        let blankEnd = blank.convert(NSPoint(x: 40, y: blank.bounds.maxY - 20), to: nil)
        events = try [mouse(.leftMouseDragged, blankEnd), mouse(.leftMouseUp, blankEnd)]
        spaceSource.trackMouse(with: try mouse(.leftMouseDown, rowStart)) { events.isEmpty ? nil : events.removeFirst() }
        XCTAssertEqual(workspace.spaces.last?.id, firstSpace, "The blank sidebar area must accept a trailing reorder")
        XCTAssertEqual(workspace.allTabIDs, original)
        controller.settings.values.spaceOrder = .tree
        try await capture("tree")
        let popup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 356, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.contentView = NSHostingView(rootView: HostStatsView())
        popup.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await PresentationTestSupport.capture(popup, named: "host-popover", in: "plan-1-validation")
        popup.close(); popup.contentView = nil
        XCTAssertEqual(workspace.allTabIDs, original)
        XCTAssertTrue(terminal.surface === surface)
    }
    func testNativePickerAndFileViews() async throws {
        AppFont.register()
        let workspace = Workspace(); workspace.newSpace()
        for _ in 0..<3 { workspace.newTab() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "let key = event.id\nawait remember(key)\n".write(to: directory.appendingPathComponent("billing.swift"), atomically: true, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        @discardableResult
        func capture(_ name: String, view: AnyView) async throws -> PresentationTestSupport.Snapshot {
            window.contentView = NSHostingView(rootView: view.foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            return try await PresentationTestSupport.capture(window, named: name, in: "plan-1-validation")
        }
        try await capture("layout-picker", view: AnyView(LayoutOptions(space: workspace.current!, workspace: workspace).frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.terminal)))
        let patch = ToolDocument(path: "billing.swift", diff: "@@ -41,2 +41,2 @@\n-let key = attempt.id\n+let key = event.id\n await remember(key)\n")
        try await capture("inline-diff", view: AnyView(CodeDocumentView(document: patch, directory: directory.path).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.terminal)))
        let sourcePreview = try await capture("inline-source", view: AnyView(CodeDocumentView(document: ToolDocument(path: patch.path, diff: ""), directory: directory.path).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Chrome.terminal)))
        let text = try sourcePreview.text()
        try PresentationTestSupport.assertText("let key = event.id", in: sourcePreview)
        XCTAssertTrue(text.replacingOccurrences(of: " ", with: "").contains("awaitremember(key)"), text)
    }
    func testSourcePreviewRefreshesWhenDocumentChangesAndClearsFailedContent() async throws {
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "Original source contents".write(to: directory.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try "Replacement source contents".write(to: directory.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        func document(_ path: String) -> some View {
            CodeDocumentView(document: ToolDocument(path: path, diff: ""), directory: directory.path)
                .padding(20).foregroundStyle(Chrome.ink).background(Chrome.terminal).preferredColorScheme(.dark)
        }
        let host = NSHostingView(rootView: document("first.txt"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close(); window.contentView = nil }
        // Lowercased: Vision can misread a letter's case ("RepLacement").
        func renderedText() async throws -> String {
            try await Task.sleep(for: .milliseconds(300))
            return try await PresentationTestSupport.capture(host).text().lowercased()
        }
        let first = try await renderedText()
        XCTAssertTrue(first.contains("original source contents"), first)
        host.rootView = document("second.txt")
        let second = try await renderedText()
        XCTAssertTrue(second.contains("replacement source contents"), second)
        XCTAssertFalse(second.contains("original source contents"), second)
        host.rootView = document("missing.txt")
        let missing = try await renderedText()
        XCTAssertTrue(missing.replacingOccurrences(of: " ", with: "").contains("missing.txt"), missing)
        XCTAssertFalse(missing.contains("replacement source contents"), missing)
    }

    func testChatKeepsEarlierTurnsInNativeRender() async throws {
        let coordinator = ChatCoordinator(enabled: true); let session = coordinator.session(for: UUID())
        session.active = true; session.sessionID = UUID().uuidString; session.showChat = true
        session.insert(ChatItem(id: "first", kind: .user, text: "Original visible message"), turnID: "first")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 916, height: 702), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func renderedText() async throws -> String {
            try await PresentationTestSupport.capture(window).text()
        }
        try await Task.sleep(for: .milliseconds(150))
        let snapshot1 = try await renderedText()
        XCTAssertTrue(snapshot1.contains("Original visible message"))
        for index in 2...5 { session.insert(ChatItem(id: "user-\(index)", kind: .user, text: "Later message \(index)"), turnID: "turn-\(index)") }
        try await Task.sleep(for: .milliseconds(150))
        let text = try await renderedText()
        XCTAssertTrue(text.contains("Original visible message"), text)
        XCTAssertTrue(text.contains("Later message 5"))
        XCTAssertFalse(text.contains("worked for"))
    }
    private func text(_ surface: any TerminalBackend) -> String {
        TerminalTestSupport.screen(surface: surface)
    }
}
