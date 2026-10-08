import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatPerformanceTests: XCTestCase {
    func testFormattingCacheReusesRevisionsAndInvalidatesChanges() async {
        let cache = ToolPresentationCache()
        var item = ChatItem(id: "tool", kind: .tool, text: #"{"cmd":"swift build"}"#, title: "exec_command", output: String(repeating: "output\n", count: 20_000))
        let revision = item.presentationID
        XCTAssertNil(cache.cached(for: item))
        _ = await cache.presentation(for: item)
        XCTAssertEqual(cache.cached(for: item)?.output, item.output,
                       "A remounted expanded row must obtain its cached body without an asynchronous placeholder")
        for _ in 0..<100 { _ = await cache.presentation(for: item) }
        let firstBuilds = await cache.builds
        XCTAssertEqual(firstBuilds, 1)
        item.output = "failure"; item.exitCode = 7
        XCTAssertNotEqual(item.presentationID, revision)
        XCTAssertNil(cache.cached(for: item), "A new content revision cannot reuse stale formatting")
        let changed = await cache.presentation(for: item)
        XCTAssertEqual(changed.exitCode, 7)
        XCTAssertEqual(changed.output, "failure")
        let builds = await cache.builds
        XCTAssertEqual(builds, 2)
    }

    func testRowsRemainStableAndRefreshWhenConversationChanges() {
        let session = ChatSession(id: UUID())
        session.turns = [ChatTurn(id: "one", items: [ChatItem(id: "same", kind: .tool, text: "a")]),
                         ChatTurn(id: "two", items: [ChatItem(id: "same", kind: .tool, text: "b")])]
        let before = session.transcriptRows
        XCTAssertEqual(Set(before.map(\.id)).count, 2)
        session.turns[0].items[0].output = "updated"
        XCTAssertEqual(session.transcriptRows.map(\.id), before.map(\.id))
        XCTAssertEqual(session.transcriptRows[0].item?.output, "updated")
        session.turns[0].items.append(ChatItem(id: "new", kind: .assistant, text: "next"))
        XCTAssertEqual(session.transcriptRows.count, 3)
        session.resetConversation()
        XCTAssertTrue(session.transcriptRows.isEmpty)
    }

    func testToolGeometrySurvivesPayloadEvictionAndExpiresWithItsTranscript() async {
        let cache = ToolPresentationCache(), session = ChatSession(id: UUID())
        let item = ChatItem(id: "tool", kind: .tool, text: "echo hello", title: "Shell", output: "hello")
        session.turns = [ChatTurn(id: "turn", items: [item])]
        _ = session.transcriptRows
        let typography = ChatTypography()
        session.toolLayouts.remember(CGSize(width: 568, height: 340), for: item.presentationID, typography: typography)
        _ = await cache.presentation(for: item)
        cache.removeAll()
        XCTAssertNil(cache.cached(for: item))
        XCTAssertEqual(session.toolLayouts.height(for: item.presentationID, width: 568, typography: typography), 340)
        XCTAssertNil(session.toolLayouts.height(for: item.presentationID, width: 500, typography: typography))
        var larger = typography; larger.size += 1
        XCTAssertNil(session.toolLayouts.height(for: item.presentationID, width: 568, typography: larger))
        session.turns = []
        _ = session.transcriptRows
        XCTAssertEqual(session.toolLayouts.count, 0, "Discarded transcript rows cannot retain geometry")
    }

    func testTenThousandToolRowsOnlyFormatVisibleRowsWhileScrolling() async throws {
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.sessionID = "large-chat"; session.showChat = true; session.atBottom = false
        let output = String(repeating: "Large tool output stays collapsed.\n", count: 2_000)
        // One very long turn reproduces the former eager inner VStack path.
        session.turns = [ChatTurn(id: "turn", items: (0..<10_000).map {
            ChatItem(id: "tool-\($0)", kind: .tool, text: "{\"cmd\":\"echo row \($0)\"}", title: "exec_command", output: output, completed: true, exitCode: 0)
        })]
        session.expandedToolGroups.insert(session.transcriptRows[0].id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let baseline = await ToolPresentationCache.shared.builds
        let start = Date()
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        let initialBuilds = await ToolPresentationCache.shared.builds - baseline
        XCTAssertLessThan(initialBuilds, 150, "Mounting a long turn must not format thousands of off-screen tool payloads")
        let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, 100_000)
        var worst = 0.0
        var timings: [Double] = []
        for _ in 1...40 {
            let tick = Date()
            let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0))
            session.scrollPosition.userWillScroll(deltaY: -150)
            scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
            window.contentView?.layoutSubtreeIfNeeded()
            let elapsed = Date().timeIntervalSince(tick)
            timings.append(elapsed)
            worst = max(worst, elapsed)
            try await Task.sleep(for: .milliseconds(16))
        }
        let totalBuilds = await ToolPresentationCache.shared.builds - baseline
        print("CHAT PERFORMANCE: 10000 rows, initial formatted=\(initialBuilds), total formatted=\(totalBuilds), p95 synchronous scroll=\(timings.sorted()[37])s, worst synchronous scroll=\(worst)s, elapsed=\(Date().timeIntervalSince(start))s")
        XCTAssertLessThan(totalBuilds, 500, "Scrolling must do work proportional to the viewport")
        XCTAssertLessThan(worst, 0.1, "A scroll step must not synchronously parse the conversation")
        XCTAssertEqual(session.turns[0].items.count, 10_000)
        // AppKit may apply the final wheel event on the next display callback.
        // Finish that input before measuring the effect of new output.
        try await Task.sleep(for: .milliseconds(100))
        let readingPosition = scroll.contentView.bounds.minY
        XCTAssertFalse(session.atBottom)
        session.insert(ChatItem(id: "background-output", kind: .assistant, text: "Output while reading earlier items"), turnID: "turn")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(scroll.contentView.bounds.minY, readingPosition, accuracy: 1, "New output must not move a reader who scrolled away from the bottom")
        let savedAnchor = try XCTUnwrap(session.scrollAnchor)
        window.contentView = nil
        session.atBottom = false
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        try await Task.sleep(for: .milliseconds(250))
        let restoredScroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertEqual(session.scrollAnchor, savedAnchor, "Returning to chat must retain the visible item, independent of estimated offscreen heights")
        XCTAssertGreaterThan(restoredScroll.contentView.bounds.minY, readingPosition / 2)
        // Chat normally opens at the newest output; jumping across the whole
        // transcript must preserve the same bounded rendering behavior.
        window.contentView = nil
        session.atBottom = true; session.scrollAnchor = nil
        let beforeBottom = await ToolPresentationCache.shared.builds
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        try await Task.sleep(for: .milliseconds(500))
        let bottomBuilds = await ToolPresentationCache.shared.builds - beforeBottom
        XCTAssertLessThan(bottomBuilds, 150)
        let bottomScroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertGreaterThan(bottomScroll.contentView.bounds.minY, 100_000, "Opening chat should still reveal the newest output")
        print("CHAT PERFORMANCE: automatic bottom jump formatted=\(bottomBuilds)")
        XCTAssertTrue(session.atBottom, "Initial bottom jump: remaining=\((bottomScroll.documentView?.frame.height ?? 0) - bottomScroll.contentView.bounds.maxY)")
        session.insert(ChatItem(id: "new-output", kind: .assistant, text: "Latest output"), turnID: "turn")
        try await Task.sleep(for: .milliseconds(250))
        let remaining = (bottomScroll.documentView?.frame.height ?? 0) - bottomScroll.contentView.bounds.maxY
        XCTAssertTrue(session.atBottom, "After output: remaining=\(remaining), follow=\(String(describing: session.followRevision)), revision=\(session.revision)")
        XCTAssertLessThan(remaining, 60, "New output should follow when the reader is at the bottom")
    }

    func testWholeToolHeaderRespondsToClicksAwayFromChevron() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let session = ChatSession(id: UUID())
        let item = ChatItem(id: "click", kind: .tool, text: #"{"cmd":"echo hello"}"#, title: "exec_command", output: "hello", completed: true, exitCode: 0)
        let binding = Binding(get: { session.expanded.contains(item.id) }, set: { if $0 { session.expanded.insert(item.id) } else { session.expanded.remove(item.id) } })
        window.contentView = NSHostingView(rootView: ChatToolCard(item: item, expanded: binding, directory: "/tmp")
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Chrome.terminal).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        // Blank space, text region, and padded trailing edge of the header.
        for x: CGFloat in [450, 140, 730] {
            let previous = session.expanded.contains(item.id)
            let point = NSPoint(x: x, y: 400 - 20 - 16)
            try PresentationTestSupport.click(window, at: point)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNotEqual(session.expanded.contains(item.id), previous, "Header click at x=\(x) should toggle disclosure")
        }
    }
}
