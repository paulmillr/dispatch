import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The Mac's typed reveal as drawn (`ChatMarkdown` with a `ChatTypingReveal`) and as a session starts it. The frames
/// are stepped by hand, with no display link or wall clock.
@MainActor final class ChatTypingRevealViewTests: XCTestCase {
    private static let reply = """
    The resize lands while the renderer still holds the **old surface size**, so the next frame is drawn into a buffer nobody presents, and the tab stops redrawing.

    - `TerminalRuntime` resizes the grid at once, but the _Metal layer_ picks up its drawable size later.
    - When both happen in one turn, that frame goes to the stale drawable and is dropped.

    I will move the drawable resize into the same transaction and add a test that resizes mid-frame.
    """

    private struct Probe: View {
        let tick: Int
        let text: String
        let typing: ChatTypingReveal?
        var body: some View {
            ChatMarkdown(text: text, typing: typing).frame(width: 320, alignment: .topLeading)
        }
    }

    /// The text views of a hosted message, top to bottom (one per text block).
    private func textViews(_ host: NSView) -> [NSTextView] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(host).compactMap { $0 as? NSTextView }
            .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
    }

    /// Where each character of a text view sits: its line fragment's top, in the view.
    private func lineTops(_ view: NSTextView) -> [CGFloat] {
        guard let layout = view.layoutManager, let container = view.textContainer else { return [] }
        layout.ensureLayout(for: container)
        let string = view.string as NSString
        return (0..<string.length).map { offset in
            layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil).minY
        }
    }

    /// Frame by frame through a stream: every shown character sits on the line it has in the finished reply (a
    /// half-typed word never jumps lines), the hidden rest of the word draws nothing, no raw Markdown shows, and the
    /// one caret is one cell after the last character shown, on its line.
    func testCaretAndLinesMatchTheFinishedReplyEveryFrame() throws {
        AppFont.register()
        let finished = NSHostingView(rootView: Probe(tick: 0, text: Self.reply, typing: nil))
        finished.frame = NSRect(x: 0, y: 0, width: 320, height: 2000)
        finished.layoutSubtreeIfNeeded()
        let finalViews = textViews(finished)
        XCTAssertEqual(finalViews.count, 4)
        let finalTops = finalViews.map(lineTops)
        XCTAssertGreaterThan(Set(finalTops[0]).count, 3, "the first paragraph wraps")

        let stream = ChatTypingRevealTests.deltas(Self.reply, seed: 9)
        let reveal = ChatTypingReveal(id: "row", text: stream[0].text, ended: false, fromStart: true, at: 0)
        let host = NSHostingView(rootView: Probe(tick: 0, text: stream[0].text, typing: reveal))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 2000)
        var delta = 1, checked = 0, carets = 0
        for frame in 0..<(60 * 40) {
            let now = Double(frame) / 60
            while delta < stream.count && stream[delta].time <= now { delta += 1 }
            let text = stream[delta - 1].text
            reveal.feed(text, ended: delta == stream.count, at: now)
            reveal.step(to: now)
            guard frame % 4 == 0 else { continue }
            host.rootView = Probe(tick: frame, text: text, typing: reveal)
            host.layoutSubtreeIfNeeded()
            let current = reveal.current, layout = reveal.layout
            let views = textViews(host)
            let textBlocks = (0..<layout.visibleBlocks(current.shown)).filter { layout.blocks[$0].isText }
            XCTAssertEqual(views.count, textBlocks.count, "frame \(frame)")
            var caretViews = 0
            for (position, (view, block)) in zip(views, textBlocks).enumerated() {
                let shown = layout.shown(block: block, of: current.shown) ?? 0
                let storage = try XCTUnwrap(view.textStorage)
                let tops = lineTops(view)
                // Shown characters: drawn, on their finished lines. The rest: laid out, clear.
                var visibleCount = storage.length
                for offset in 0..<storage.length {
                    let color = storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
                    let visible = (color?.alphaComponent ?? 1) > 0
                    if !visible { visibleCount = min(visibleCount, offset) }
                    XCTAssertTrue(visible == (offset < visibleCount), "frame \(frame): the hidden part is one tail")
                    XCTAssertLessThan(offset, finalTops[position].count, "frame \(frame)")
                    if offset < finalTops[position].count {
                        XCTAssertEqual(tops[offset], finalTops[position][offset], accuracy: 0.5,
                                       "frame \(frame): block \(block) character \(offset) moved lines")
                    }
                }
                let drawn = (storage.string as NSString).substring(to: visibleCount)
                XCTAssertEqual(drawn, String(layout.blocks[block].plain.prefix(shown)), "frame \(frame)")
                XCTAssertFalse(drawn.contains("**") || drawn.contains("`") || drawn.hasPrefix("- "), "frame \(frame): \(drawn)")
                if let caret = (view as? ChatTypingCaretDrawing)?.typingCaret, caret.alpha > 0 {
                    caretViews += 1
                    let rect = try XCTUnwrap((view as? ChatTypingCaretDrawing)?.typingCaretRect(after: caret.offset))
                    XCTAssertEqual(caret.offset, visibleCount, "frame \(frame): the caret follows the last character shown")
                    let layoutManager = try XCTUnwrap(view.layoutManager)
                    let glyph = layoutManager.glyphIndexForCharacter(at: caret.offset - 1)
                    let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let cell = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer!)
                    XCTAssertEqual(rect.width, 2)
                    XCTAssertEqual(rect.minX, (view.textContainerOrigin.x + cell.maxX).rounded(), accuracy: 0.5, "frame \(frame)")
                    XCTAssertTrue(rect.midY > line.minY && rect.midY < line.maxY, "frame \(frame): caret on the line")
                }
            }
            XCTAssertLessThanOrEqual(caretViews, 1, "frame \(frame)")
            if current.caret > 0, let block = layout.caretBlock(current.shown), layout.blocks[block].isText {
                XCTAssertEqual(caretViews, 1, "frame \(frame)")
                carets += 1
            }
            checked += 1
            if delta == stream.count && reveal.done(at: now) { break }
        }
        XCTAssertEqual(reveal.current.shown, reveal.layout.total)
        XCTAssertGreaterThan(checked, 30)
        XCTAssertGreaterThan(carets, 20)
    }

    /// A Codex reply that starts while the chat shows types out from its first character, and so does a short Claude
    /// post (complete, its turn ended); a long Claude post, a reply arriving while the chat is not shown, and history
    /// show at once.
    func testSessionTypesRepliesStartedWhileShown() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        func session(_ agent: String, shown: Bool = true) -> ChatSession {
            let session = ChatSession(id: System.uuid(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
            session.agentID = agent
            session.showChat = shown
            return session
        }
        func reveal(_ session: ChatSession, historical: Bool = false) -> ChatTypingReveal? {
            session.insert(ChatItem(id: "a1", kind: .assistant, text: "Streaming the first words"), turnID: "t1", historical: historical)
            return session.typingReveals.reveal("2:t1:a1", text: "Streaming the first words", live: true, ended: false, reduceMotion: false)
        }
        let codex = try XCTUnwrap(reveal(session("codex")))
        XCTAssertEqual(codex.current.shown, 1)
        let pi = try XCTUnwrap(reveal(session("pi")))
        XCTAssertEqual(pi.current.shown, 1)
        for whole in [reveal(session("codex", shown: false)), reveal(session("codex"), historical: true)] {
            let whole = try XCTUnwrap(whole)
            XCTAssertEqual(whole.current.shown, whole.layout.total)
        }
        func post(_ text: String) -> ChatTypingReveal? {
            let claude = session("claude")
            var item = ChatItem(id: "a1", kind: .assistant, text: text)
            item.completed = true
            claude.insert(item, turnID: "t1")
            return claude.typingReveals.reveal("2:t1:a1", text: text, live: false, ended: true, reduceMotion: false)
        }
        let short = try XCTUnwrap(post("Done: the resize now lands in the same transaction."))
        XCTAssertLessThan(short.current.shown, short.layout.total)
        XCTAssertNil(post(String(repeating: "A longer answer that goes on. ", count: 20)))
    }

    /// Through the row's own view (`ChatTypedMarkdown`): drawing it shows the reveal (its clock runs), drawing it again
    /// with more text resumes a rested clock, leaving stops it, and coming back shows what arrived meanwhile.
    func testTypedMarkdownMountsAndReschedules() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 5
        let store = ChatTypingReveals()
        store.now = { time }
        defer { store.reset() }
        store.began("row")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        func view(_ text: String) -> some View {
            ChatTypedMarkdown(text: text, rowID: "row", reveals: store, live: true, ended: false).frame(width: 320)
        }
        let host = NSHostingView(rootView: view("Typing the first words"))
        func show(_ text: String) {
            host.rootView = view(text)
            if window.contentView !== host { window.contentView = host }
            host.layoutSubtreeIfNeeded()
        }
        func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
        show("Typing the first words")
        settle()
        XCTAssertTrue(store.running, "shown: its clock runs")
        let reveal = try XCTUnwrap(store.reveal("row", text: "Typing the first words", live: true, ended: false, reduceMotion: false))
        // Rest past the blink limit, then more arrives.
        for _ in 0..<(60 * 8) { time += 1.0 / 60; if store.running { store.step(to: time) } }
        XCTAssertFalse(store.running)
        show("Typing the first words and then some more of them")
        settle()
        XCTAssertTrue(store.running, "more arrived: its clock runs again")
        XCTAssertLessThan(reveal.current.shown, reveal.layout.total)
        // Gone from the window: the clock stops; shown again, it shows what has arrived.
        window.contentView = nil
        settle()
        time += 1.0 / 60; store.step(to: time)
        XCTAssertFalse(store.running)
        show("Typing the first words and then some more of them, and the rest")
        settle()
        XCTAssertEqual(reveal.current.shown, reveal.layout.total)
    }

    /// The transcript's live state for typing: the live turn and its newest item, kept with the rows while the
    /// transcript is held (its window off screen), so a reply typing then goes on once it shows again.
    func testLiveTurnForTypingIsHeldWithTheTranscript() throws {
        let session = ChatSession(id: System.uuid(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        session.showChat = true
        session.busy = true
        session.activeTurnID = "t1"
        _ = session.turn("t1")
        session.insert(ChatItem(id: "a1", kind: .assistant, text: "First"), turnID: "t1")
        let rows = session.visibleTranscriptRows
        let reply = try XCTUnwrap(rows.first { $0.item?.id == "a1" })
        XCTAssertEqual(ChatTypedMarkdown.streaming(reply, in: session.presentedTypingTurn), .newest)
        session.holdTranscript()
        session.insert(ChatItem(id: "a2", kind: .assistant, text: "Second"), turnID: "t1")
        XCTAssertEqual(ChatTypedMarkdown.streaming(reply, in: session.presentedTypingTurn), .newest, "held as it left")
        session.releaseTranscript()
        XCTAssertEqual(ChatTypedMarkdown.streaming(reply, in: session.presentedTypingTurn), .live)
        session.busy = false
        XCTAssertNil(ChatTypedMarkdown.streaming(reply, in: session.presentedTypingTurn))
    }
}
