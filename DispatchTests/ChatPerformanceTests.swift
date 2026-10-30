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
        let session = ChatSession(id: System.uuid())
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
        let cache = ToolPresentationCache(), session = ChatSession(id: System.uuid())
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
        let session = coordinator.session(for: System.uuid())
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
        try await TestSupport.poll { (PresentationTestSupport.views(of: NSScrollView.self, in: window.contentView ?? NSView()).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }?.contentView.bounds.minY ?? 0) > readingPosition / 2 }
        let restoredScroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertEqual(session.scrollAnchor, savedAnchor, "Returning to chat must retain the visible item, independent of estimated offscreen heights")
        XCTAssertGreaterThan(restoredScroll.contentView.bounds.minY, readingPosition / 2)
        // Chat normally opens at the newest output; jumping across the whole
        // transcript must preserve the same bounded rendering behavior.
        window.contentView = nil
        session.atBottom = true; session.scrollAnchor = nil
        let beforeBottom = await ToolPresentationCache.shared.builds
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        try await TestSupport.poll { session.atBottom && (PresentationTestSupport.views(of: NSScrollView.self, in: window.contentView ?? NSView()).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }?.contentView.bounds.minY ?? 0) > 100_000 }
        let bottomBuilds = await ToolPresentationCache.shared.builds - beforeBottom
        XCTAssertLessThan(bottomBuilds, 150)
        let bottomScroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: try XCTUnwrap(window.contentView)).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        XCTAssertGreaterThan(bottomScroll.contentView.bounds.minY, 100_000, "Opening chat should still reveal the newest output")
        print("CHAT PERFORMANCE: automatic bottom jump formatted=\(bottomBuilds)")
        XCTAssertTrue(session.atBottom, "Initial bottom jump: remaining=\((bottomScroll.documentView?.frame.height ?? 0) - bottomScroll.contentView.bounds.maxY)")
        session.insert(ChatItem(id: "new-output", kind: .assistant, text: "Latest output"), turnID: "turn")
        try await TestSupport.poll { session.atBottom && (bottomScroll.documentView?.frame.height ?? 0) - bottomScroll.contentView.bounds.maxY < 60 }
        let remaining = (bottomScroll.documentView?.frame.height ?? 0) - bottomScroll.contentView.bounds.maxY
        XCTAssertTrue(session.atBottom, "After output: remaining=\(remaining), follow=\(String(describing: session.followRevision)), revision=\(session.revision)")
        XCTAssertLessThan(remaining, 60, "New output should follow when the reader is at the bottom")
    }

    func testWholeToolHeaderRespondsToClicksAwayFromChevron() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        let session = ChatSession(id: System.uuid())
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

/// What a message's text views cost per update: none remount as it finishes, its text is built and measured only when
/// what it is built from changes, and a transcript whose window is off screen applies what arrived before it shows.
extension ChatPerformanceTests {
    private static let longReply = "Here is the plan for the write queue.\n\n"
        + (1...40).map { "\($0). Step \($0) of the reconnect checklist." }.joined(separator: "\n\n")

    private func messageTextViews(_ root: NSView) -> [NSTextView] {
        PresentationTestSupport.views(of: NSTextView.self, in: root, includingNestedMatches: true).filter { !$0.isEditable }
    }

    private func chatWindow(_ session: ChatSession, coordinator: ChatCoordinator, main: Bool = false) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = main ? MainWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // As in the app (NativeSplit, MotionContent): the chat's hosting view never sizes its window.
        let host = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        return window
    }

    private func chatSession(_ coordinator: ChatCoordinator, _ name: String) -> ChatSession {
        let session = coordinator.session(for: System.uuid())
        session.sessionID = name; session.showChat = true; session.atBottom = true
        return session
    }

    func testFinishingMessageKeepsItsTextViews() async throws {
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: true)
        let session = chatSession(coordinator, "finishing")
        let window = chatWindow(session, coordinator: coordinator)
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let start = System.date()
        session.busy = true; session.activeTurnID = "turn"
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Why does the write queue stall?"), turnID: "turn", at: start)
        var reply = ChatItem(id: "reply", kind: .assistant, text: "It waits for the link.\n\n- first check\n- second check")
        session.insert(reply, turnID: "turn", at: start.addingTimeInterval(1))
        let root = try XCTUnwrap(window.contentView)
        func replyViews() -> [ObjectIdentifier: String] {
            Dictionary(uniqueKeysWithValues: messageTextViews(root).filter { $0.string.contains("check") || $0.string.contains("link") }
                .map { (ObjectIdentifier($0), $0.string) })
        }
        try await TestSupport.eventually { replyViews().values.contains("second check") }
        let streamed = replyViews()
        // Streaming: the reply grows by a block; the blocks it had keep their views.
        reply.text += "\n- third check"
        session.insert(reply, turnID: "turn", at: start.addingTimeInterval(1))
        try await TestSupport.eventually { replyViews().values.contains("third check") }
        let grown = replyViews()
        XCTAssertTrue(Set(streamed.keys).isSubset(of: Set(grown.keys)), "A streamed block must keep its text view as the reply grows")
        // Finishing: the record completes and the turn ends.
        let made = ChatTextMetrics.views, built = ChatTextMetrics.builds
        reply.completed = true
        session.insert(reply, turnID: "turn", at: start.addingTimeInterval(1))
        if let index = session.turns.firstIndex(where: { $0.id == "turn" }) { session.turns[index].ended = start.addingTimeInterval(30) }
        session.busy = false; session.activeTurnID = nil
        try await TestSupport.eventually { !session.busy && session.turns.first?.ended != nil }
        // Let the finished turn lay out (its reply time, the idle composer) before comparing.
        for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertEqual(replyViews(), grown, "A finished message must keep the text views it streamed into")
        XCTAssertEqual(ChatTextMetrics.views, made, "Finishing a message must not mount any text view again")
        XCTAssertEqual(ChatTextMetrics.builds, built, "Finishing a message must not rebuild its unchanged text")
    }

    func testMessageTextIsBuiltAndMeasuredOnlyWhenItChanges() async throws {
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: true)
        let session = chatSession(coordinator, "cached-text")
        let start = System.date()
        // Texts no other test shows: the markdown cache is shared.
        let marker = System.uuid().uuidString
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Plan the reconnect " + marker), turnID: "one", at: start)
        let parses = ChatMarkdownCache.documentParses, inlineParses = ChatMarkdownCache.inlineParses
        session.insert(ChatItem(id: "plan", kind: .assistant, text: Self.longReply + "\n\nDone " + marker), turnID: "one", at: start.addingTimeInterval(1))
        let window = chatWindow(session, coordinator: coordinator)
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually { messageTextViews(root).contains { $0.string == "Done " + marker } }
        XCTAssertEqual(ChatMarkdownCache.documentParses - parses, 2, "Each message's markdown is parsed once (the prompt and the plan)")
        XCTAssertLessThanOrEqual(ChatMarkdownCache.inlineParses - inlineParses, 44, "Each block's inline markdown is parsed once")
        for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        /// Text views mounted since `before`: only those may build their text.
        func mounted(since before: Set<ObjectIdentifier>) -> Int {
            Set(messageTextViews(root).map(ObjectIdentifier.init)).subtracting(before).count
        }
        // Records below it, a busy agent, the composer: the mounted plan's text views neither rebuild nor measure again.
        var before = Set(messageTextViews(root).map(ObjectIdentifier.init))
        var built = counts(root, \.builds), measured = counts(root, \.measures)
        session.busy = true; session.activeTurnID = "two"
        session.insert(ChatItem(id: "next", kind: .user, text: "And the timeout?"), turnID: "two", at: start.addingTimeInterval(60))
        session.insert(ChatItem(id: "tool", kind: .tool, text: #"{"cmd":"rg timeout Sources"}"#, title: "exec_command",
                                output: "Sources/Queue.swift: timeout", completed: true, exitCode: 0), turnID: "two", at: start.addingTimeInterval(61))
        try await TestSupport.eventually { messageTextViews(root).contains { $0.string == "And the timeout?" } }
        for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        var fresh = mounted(since: before)
        XCTAssertGreaterThanOrEqual(fresh, 1)
        XCTAssertLessThanOrEqual(growth(root, \.builds, since: built), fresh, "Only newly mounted text views build their text")
        XCTAssertLessThanOrEqual(growth(root, \.measures, since: measured), fresh * 4, "Mounted blocks keep their sizes per width")
        // The pane narrows below the bubbles' width: blocks measure again, and only new mounts build.
        before = Set(messageTextViews(root).map(ObjectIdentifier.init))
        built = counts(root, \.builds); measured = counts(root, \.measures)
        window.setContentSize(NSSize(width: 520, height: 700))
        for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        fresh = mounted(since: before)
        XCTAssertGreaterThan(growth(root, \.measures, since: measured), fresh, "A new width measures the blocks that stayed again")
        XCTAssertLessThanOrEqual(growth(root, \.builds, since: built), fresh, "A new width keeps the built text")
        // Mounting the transcript again parses nothing again.
        let reparsed = ChatMarkdownCache.documentParses
        session.scrollPosition.disconnect()
        window.contentView = nil
        let host = NSHostingView(rootView: ChatView(session: session, coordinator: coordinator, focused: false, floatingSwitch: false))
        host.sizingOptions = []
        window.contentView = host
        try await TestSupport.eventually { messageTextViews(host).contains { $0.string == "And the timeout?" } }
        XCTAssertEqual(ChatMarkdownCache.documentParses, reparsed, "A remounted message reuses its parsed markdown")
    }

    func testOffScreenTranscriptAppliesHeldRowsBeforeItShows() async throws {
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: true)
        let session = chatSession(coordinator, "held")
        let start = System.date()
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Plan the reconnect"), turnID: "one", at: start)
        session.insert(ChatItem(id: "plan", kind: .assistant, text: Self.longReply), turnID: "one", at: start.addingTimeInterval(1))
        let window = chatWindow(session, coordinator: coordinator, main: true)
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually { messageTextViews(root).contains { $0.string.contains("Step 40 of") } && session.scrollPosition.isAtBottom(tolerance: 1) == true }
        XCTAssertFalse(session.transcriptHeld)
        window.orderOut(nil)
        XCTAssertTrue(session.transcriptHeld, "A transcript whose window left the screen holds what it shows")
        let made = ChatTextMetrics.views, revision = session.revision
        session.busy = true; session.activeTurnID = "two"
        session.insert(ChatItem(id: "late-prompt", kind: .user, text: "And the timeout?"), turnID: "two", at: start.addingTimeInterval(60))
        session.insert(ChatItem(id: "late", kind: .assistant, text: "Arrived while the window was away.\n\n" + Self.longReply),
                       turnID: "two", at: start.addingTimeInterval(61))
        if let index = session.turns.firstIndex(where: { $0.id == "two" }) { session.turns[index].ended = start.addingTimeInterval(90) }
        session.busy = false; session.activeTurnID = nil
        // The model goes on: records, revision, the rows the window will show.
        XCTAssertGreaterThan(session.revision, revision)
        XCTAssertTrue(session.visibleTranscriptRows.contains { $0.item?.id == "late" })
        XCTAssertFalse(session.presentedTranscriptRows.contains { $0.item?.id == "late" })
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertEqual(ChatTextMetrics.views, made, "No text view is mounted while the window is off screen")
        XCTAssertFalse(messageTextViews(root).contains { $0.string.contains("Arrived while the window was away") })
        // Ordering it in applies the held rows and lays them out first: in this same turn, before any frame shows.
        window.makeKeyAndOrderFront(nil)
        XCTAssertFalse(session.transcriptHeld)
        XCTAssertTrue(messageTextViews(root).contains { $0.string.contains("Arrived while the window was away") },
                      "The window's first frame must show what arrived while it was off screen")
        XCTAssertEqual(session.scrollPosition.isAtBottom(tolerance: 1), true, "Followed to its end before the first frame")
        XCTAssertTrue(window.isVisible)
    }

    /// A long reply landing makes its blocks' text views once each, and the records after it rebuild none of them.
    func testLongReplyLandingCostIsBoundedByItsBlocks() async throws {
        AppFont.register()
        let coordinator = ChatCoordinator(enabled: true)
        let session = chatSession(coordinator, "landing")
        let start = System.date()
        for turn in 0..<3 {
            let id = "turn-\(turn)", date = start.addingTimeInterval(Double(turn) * 60)
            session.insert(ChatItem(id: "prompt-\(turn)", kind: .user, text: "Question \(turn)"), turnID: id, at: date)
            session.insert(ChatItem(id: "reply-\(turn)", kind: .assistant, text: Self.longReply), turnID: id, at: date.addingTimeInterval(1))
            if let index = session.turns.firstIndex(where: { $0.id == id }) { session.turns[index].ended = date.addingTimeInterval(2) }
        }
        let window = chatWindow(session, coordinator: coordinator)
        defer { session.scrollPosition.disconnect(); window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually { session.scrollPosition.isAtBottom(tolerance: 1) == true && messageTextViews(root).count > 20 }
        for _ in 0..<3 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let made = ChatTextMetrics.views, built = ChatTextMetrics.builds, measured = ChatTextMetrics.measures
        let landing = start.addingTimeInterval(600)
        session.busy = true; session.activeTurnID = "landing"
        session.insert(ChatItem(id: "prompt-landing", kind: .user, text: "Once more"), turnID: "landing", at: landing)
        session.insert(ChatItem(id: "reply-landing", kind: .assistant, text: "Landing.\n\n" + Self.longReply), turnID: "landing", at: landing.addingTimeInterval(1))
        if let index = session.turns.firstIndex(where: { $0.id == "landing" }) { session.turns[index].ended = landing.addingTimeInterval(2) }
        session.busy = false; session.activeTurnID = nil
        try await TestSupport.eventually { messageTextViews(root).contains { $0.string == "Landing." } && session.scrollPosition.isAtBottom(tolerance: 1) == true }
        for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        // 42 blocks and a prompt; a lazy row scrolled back into view may add one more message's worth.
        let blocks = 44
        print("CHAT PERFORMANCE: long reply landing made=\(ChatTextMetrics.views - made) built=\(ChatTextMetrics.builds - built) measured=\(ChatTextMetrics.measures - measured)")
        XCTAssertLessThanOrEqual(ChatTextMetrics.views - made, blocks * 2)
        XCTAssertLessThanOrEqual(ChatTextMetrics.builds - built, blocks * 2, "A landing builds each new block's text once")
        XCTAssertLessThanOrEqual(ChatTextMetrics.measures - measured, blocks * 6, "Each block measures a few widths at most, once each")
        // The next record rebuilds and measures none of the mounted reply (only views it newly mounts, if any).
        let before = Set(messageTextViews(root).map(ObjectIdentifier.init))
        let settledBuilds = ChatTextMetrics.builds, settledMeasures = ChatTextMetrics.measures
        session.insert(ChatItem(id: "notice", kind: .notice, text: "Context compacted"), turnID: "landing", at: landing.addingTimeInterval(3))
        try await TestSupport.eventually { session.presentedTranscriptRows.contains { $0.item?.id == "notice" } }
        for _ in 0..<5 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let fresh = Set(messageTextViews(root).map(ObjectIdentifier.init)).subtracting(before).count
        XCTAssertLessThanOrEqual(ChatTextMetrics.builds - settledBuilds, fresh, "A record after the reply must not rebuild its text")
        XCTAssertLessThanOrEqual(ChatTextMetrics.measures - settledMeasures, fresh * 4, "A record after the reply must not measure it again")
    }
}

/// Builds and measures of this window's message text views only: transcripts other tests left alive in the process
/// build and measure too, and the global counters would charge them here.
extension ChatPerformanceTests {
    private func counts(_ root: NSView, _ metric: KeyPath<any ChatTextCounting, Int>) -> [ObjectIdentifier: Int] {
        Dictionary(uniqueKeysWithValues: messageTextViews(root).compactMap { $0 as? any ChatTextCounting }
            .map { (ObjectIdentifier($0), $0[keyPath: metric]) })
    }

    /// How much `metric` grew since `before` over the views mounted now; a view mounted since counts from zero.
    private func growth(_ root: NSView, _ metric: KeyPath<any ChatTextCounting, Int>, since before: [ObjectIdentifier: Int]) -> Int {
        counts(root, metric).reduce(0) { $0 + $1.value - (before[$1.key] ?? 0) }
    }
}
