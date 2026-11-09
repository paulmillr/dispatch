import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// A finished Claude turn's thinking folds into one step group in the real transcript document.
@MainActor
final class ThinkingFoldTests: XCTestCase {
    override func setUp() async throws {
        ChatSession.foldsThinkingEnabled = true
        ChatSession.thinkingFoldDelay = 1000  // These tests call the fold themselves, unless they say otherwise.
    }
    override func tearDown() async throws {
        ChatSession.foldsThinkingEnabled = false
        ChatSession.thinkingFoldDelay = 1.2
    }

    private static let thoughts = [
        "Totals that drift by a cent usually mean each line is rounded and the sum inherits the error. Finding where `Invoice` rounds first.",
        "`lineTotal` rounds half-up and `total` sums the rounded values, so that is the drift.",
        "Summing exact amounts and rounding once fixes it, as long as line items keep showing their rounded amounts.",
        "`Decimal` is already used for the amounts, so nothing here needs a type change.",
        "The tax lines go through the same path. Checking whether they round on their own.",
        "They do, in `TaxLine.amount`. That rounding has to move too or the drift comes back with tax on.",
        "Credit notes negate each line, and half-up is not symmetric around zero. Half-even avoids that.",
        "Patching `Invoice.total` first, then the tax path, so the test failures stay readable.",
        "One test fails because it expected the old per-line total, so it was pinning the bug.",
        "Correcting that expectation and adding the case that started this: three lines of 0.333.",
        "The PDF renderer reads `lineTotal` directly. It should keep the rounded display value.",
        "Exports use `total`, so they pick up the fix with no change of their own.",
        "The currency with no minor unit needs a look, since rounding to two places would be wrong there.",
        "`Currency.scale` already handles it. Adding a test so that stays true.",
        "Zero-amount invoices come out as 0.00 now rather than 0.01, which is what was asked for.",
        "Running the whole billing suite now that the targeted tests pass.",
        "A snapshot test changed by one cent in an invoice with 3 discount lines, and the new value is the correct one.",
        "Updating that snapshot, since the old value was the rounding bug.",
        "Nothing else calls the old rounding helper, so it can go.",
        "Full suite is green. Writing up what changed.",
    ]

    private func makeSession(thoughts: Int, history: Bool, earlier: Int = 1, reply: Bool = true) -> ChatSession {
        let session = ChatSession(id: System.uuid())
        session.sessionID = "thinking-fold-\(thoughts)"
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        var at = date
        func next(_ seconds: TimeInterval = 4) -> Date { at = at.addingTimeInterval(seconds); return at }
        if history {
            for turn in 0..<earlier {
                session.insert(ChatItem(id: "old-prompt-\(turn)", kind: .user, text: "Which module owns invoice totals?"), turnID: "old-\(turn)", at: next())
                session.insert(ChatItem(id: "old-reply-\(turn)", kind: .assistant, text: "`Billing` owns them: `Invoice.total` sums the lines and `TaxLine` adds the tax."), turnID: "old-\(turn)", at: next())
            }
        }
        session.insert(ChatItem(id: "prompt", kind: .user, text: "Invoices round each line before summing, so totals drift by a cent. Fix it?"), turnID: "turn", at: next())
        for index in 0..<thoughts {
            let text = Self.thoughts[index % Self.thoughts.count]
            session.insert(ChatItem(id: "claude-thought-\(index)", kind: .reasoning, text: text, completed: true), turnID: "turn", at: next())
            for tool in 0..<2 {
                session.insert(ChatItem(id: "tool-\(index)-\(tool)", kind: .tool, text: "{\"cmd\":\"swift test --filter InvoiceTests\"}",
                                        title: "exec_command", output: "ok", completed: true, exitCode: 0), turnID: "turn", at: next(2))
            }
        }
        if reply {
            session.insert(ChatItem(id: "final", kind: .assistant, text: "Totals now sum the exact amounts and round once, half-even, in `Invoice.total`. Line items still show their rounded amounts. `InvoiceTests` passes, with a new case for three lines of 0.333."), turnID: "turn", at: next())
        }
        // As ChatCoordinator ends a live turn.
        session.showChat = true
        session.noteTurnEnded("turn")
        let index = session.turn("turn", at: at, fileOffset: nil)
        session.turns[index].ended = next()
        return session
    }

    private func mount(_ session: ChatSession) throws -> (NSWindow, ChatTranscriptDocument) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: ChatCoordinator(enabled: false), focused: false, floatingSwitch: false)
            .foregroundStyle(Chrome.ink).preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        session.setPresented(true, by: System.uuid())  // As the tab showing it does.
        let root = try XCTUnwrap(window.contentView)
        let document = try XCTUnwrap(PresentationTestSupport.views(of: ChatTranscriptDocument.self, in: root).first)
        return (window, document)
    }

    private func replyMounted(_ session: ChatSession, _ document: ChatTranscriptDocument) async throws {
        let reply = try XCTUnwrap(session.transcriptRows.last { $0.item?.kind == .assistant }?.id)
        try await TestSupport.eventually(diagnostic: "the reply was not shown") {
            session.isPresented && document.mountedRows[reply] != nil && !document.lookaheadPending
        }
    }

    private func clipTop(_ document: ChatTranscriptDocument) throws -> CGFloat {
        try XCTUnwrap(document.enclosingScrollView).contentView.bounds.minY
    }

    private func scenario(thoughts: Int, history: Bool, earlier: Int = 1, pinned: Bool = false) async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = makeSession(thoughts: thoughts, history: history, earlier: earlier)
        let (window, document) = try mount(session)
        defer { window.close(); window.contentView = nil }
        let reply = try XCTUnwrap(session.transcriptRows.last { $0.item?.kind == .assistant }?.id)
        try await replyMounted(session, document)
        let before = try XCTUnwrap(document.mountedRows[reply]).frame.minY - clipTop(document)

        session.attemptThinkingFold("turn", autoplay: false)
        try await TestSupport.eventually(diagnostic: "the fold did not start") { document.thinkingFoldStarted }
        let deltas = try XCTUnwrap(document.thinkingFoldDeltas())
        let start = try XCTUnwrap(document.mountedRows[reply]).frame.minY - clipTop(document)
        XCTAssertEqual(start, before, accuracy: 0.5, "The first frame shows the reply where it was")
        XCTAssertGreaterThanOrEqual(deltas.above, -(try XCTUnwrap(document.enclosingScrollView).contentView.bounds.height), "Clamped to the viewport")
        for progress in stride(from: CGFloat(0), through: 1, by: 0.25) { document.setThinkingFoldProgress(progress) }
        XCTAssertFalse(document.thinkingFoldActive)
        if pinned { XCTAssertEqual(deltas.below, 0, accuracy: 0.5, "A full window keeps the reply where it was") }
        document.layoutTranscript()
        let end = try XCTUnwrap(document.mountedRows[reply]).frame.minY - clipTop(document)
        XCTAssertEqual(end, before - deltas.below, accuracy: 0.5, "The reply ends where the layout puts it")
        XCTAssertEqual(thoughtsShown(session), 0)
    }

    // MARK: When it folds

    private func thoughtsShown(_ session: ChatSession) -> Int { session.transcriptRows.filter { $0.item?.isNarration == true }.count }

    func testAFinishedTurnFoldsOnItsOwnAfterTheReplySettles() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        ChatSession.thinkingFoldDelay = 0.3
        let session = makeSession(thoughts: 3, history: false)
        let (window, document) = try mount(session)
        defer { window.close(); window.contentView = nil }
        XCTAssertEqual(thoughtsShown(session), 3, "Held until the delay has passed")
        try await replyMounted(session, document)
        try await TestSupport.eventually(diagnostic: "the turn did not fold") { self.thoughtsShown(session) == 0 && !document.thinkingFoldActive }
        XCTAssertTrue(session.heldThinkingTurns.isEmpty)
        XCTAssertEqual(session.transcriptRows.compactMap(\.group).count, 1)
    }

    func testATurnThatEndedWithoutAReplyKeepsItsThinking() throws {
        let session = makeSession(thoughts: 3, history: false, reply: false)
        session.attemptThinkingFold("turn")
        XCTAssertEqual(thoughtsShown(session), 3)
        XCTAssertTrue(session.heldThinkingTurns.contains("turn"))
    }

    func testAReplyRecordedAfterTheTurnEndedStillFolds() async throws {
        ChatSession.thinkingFoldDelay = 0.05
        let session = makeSession(thoughts: 3, history: false, reply: false)
        session.insert(ChatItem(id: "late", kind: .assistant, text: "Done."), turnID: "turn", at: Date(timeIntervalSince1970: 1_750_001_000))
        try await TestSupport.eventually(diagnostic: "the late reply did not fold the turn") { self.thoughtsShown(session) == 0 }
    }

    func testHistoryIsFoldedAsItIsRead() {
        let session = ChatSession(id: System.uuid())
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        session.insert(ChatItem(id: "p", kind: .user, text: "Hello"), turnID: "t", at: date, historical: true)
        session.insert(ChatItem(id: "claude-a", kind: .reasoning, text: "Thinking it over.", completed: true), turnID: "t", at: date, historical: true)
        session.insert(ChatItem(id: "r", kind: .assistant, text: "Hi"), turnID: "t", at: date, historical: true)
        session.turns[session.turn("t", at: date, fileOffset: nil)].ended = date
        XCTAssertEqual(thoughtsShown(session), 0)
        XCTAssertTrue(session.heldThinkingTurns.isEmpty)
    }

    func testAReaderInTheTurnHoldsTheFoldUntilTheyReturn() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = makeSession(thoughts: 3, history: false)
        let (window, document) = try mount(session)
        defer { window.close(); window.contentView = nil }
        try await replyMounted(session, document)
        session.atBottom = false
        session.attemptThinkingFold("turn")
        XCTAssertEqual(thoughtsShown(session), 3, "Their rows are on screen")
        ChatSession.thinkingFoldDelay = 0.05
        session.atBottom = true
        try await TestSupport.eventually(diagnostic: "returning to the end did not fold") { self.thoughtsShown(session) == 0 }
    }

    func testAnOpenedStepHoldsUntilTheNextTurnAndTheFoldStartsCollapsed() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = makeSession(thoughts: 3, history: false)
        let (window, document) = try mount(session)
        defer { window.close(); window.contentView = nil }
        try await replyMounted(session, document)
        let group = try XCTUnwrap(session.transcriptRows.compactMap(\.group).first)
        session.setGroupExpanded(group, true)
        session.atBottom = true
        session.attemptThinkingFold("turn")
        XCTAssertEqual(thoughtsShown(session), 3, "Stays as the reader left it")
        session.insert(ChatItem(id: "next", kind: .user, text: "Thanks"), turnID: "next-turn", at: Date(timeIntervalSince1970: 1_750_002_000))
        XCTAssertEqual(thoughtsShown(session), 0, "The next turn lets it go")
        let folded = try XCTUnwrap(session.transcriptRows.compactMap(\.group).first)
        XCTAssertFalse(session.groupIsExpanded(folded, turnID: "turn"), "An opened group must not open the merged list")
    }

    /// The opened group: a thought is a step's row, and clicking one shows its text.
    func testOpenedGroupShowsThinkSteps() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = makeSession(thoughts: 3, history: false)
        let (window, document) = try mount(session)
        defer { window.close(); window.contentView = nil }
        try await replyMounted(session, document)
        session.attemptThinkingFold("turn", autoplay: false)
        try await TestSupport.eventually(diagnostic: "the fold did not start") { document.thinkingFoldStarted }
        document.setThinkingFoldProgress(1)
        let row = try XCTUnwrap(session.transcriptRows.first { $0.group != nil })
        let group = try XCTUnwrap(row.group)
        session.setGroupExpanded(group, true)
        session.expanded.insert(group.children[3].id)
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually(diagnostic: "the opened group did not show") {
            session.visibleTranscriptRows.count > 5 && document.mountedRows[group.children[3].id] != nil
        }
        let text = try PresentationTestSupport.render(root).text()
        XCTAssertTrue(text.contains("Think"), text)
    }

    func testFoldLongTurn() async throws { try await scenario(thoughts: 20, history: true) }
    func testFoldShortChat() async throws { try await scenario(thoughts: 3, history: false) }
    /// Enough earlier turns that the window stays full after the fold: the reply must not move.
    func testFoldInLongChatKeepsReplyPinned() async throws { try await scenario(thoughts: 20, history: true, earlier: 12, pinned: true) }

    /// Played at the display's own rate, it ends by itself and costs one layout pass, however many thoughts folded.
    func testFoldPlaysToItsEndInOneLayoutPass() async throws {
        try DesktopTestSupport.requireUnlocked(); AppFont.register()
        let session = makeSession(thoughts: 20, history: true)
        let (window, document) = try mount(session)
        defer { window.close(); window.contentView = nil }
        try await replyMounted(session, document)
        let passes = document.layoutPasses
        session.attemptThinkingFold("turn")
        try await TestSupport.eventually(diagnostic: "the fold did not run") { document.thinkingFoldStarted }
        try await TestSupport.eventually(diagnostic: "the fold did not end") { !document.thinkingFoldActive }
        XCTAssertEqual(document.layoutPasses - passes, 1)
    }

    func testTheHeaderCountsThoughtsApart() {
        XCTAssertEqual(ChatToolGroupHeader.caption(count: 4, thoughts: 1, elapsed: 47, radio: false), "4 steps, 1 thought · 47s")
        XCTAssertEqual(ChatToolGroupHeader.caption(count: 0, thoughts: 2, elapsed: nil, radio: false), "2 thoughts")
        XCTAssertEqual(ChatToolGroupHeader.caption(count: 3, elapsed: nil, radio: false), "3 steps")
    }
}
