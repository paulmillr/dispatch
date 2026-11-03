import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

/// The typed reveal of streamed replies (`ChatTypingLayout`, `ChatTypingClock`, `ChatTypingReveals`): pure and driven
/// by the times the tests give, so no test waits on a clock. Shared with the iPhone's tests.
@MainActor final class ChatTypingRevealTests: XCTestCase {
    static let reply = """
    The resize lands while the renderer still holds the **old surface size**, so the next frame is drawn into a buffer nobody presents.

    - `TerminalRuntime` resizes the grid at once, but the _Metal layer_ only picks up its drawable size on the next pass.
    - When both happen in one turn, that frame goes to the stale drawable and is dropped ([notes](https://example.com/notes)).

    1. Move the drawable resize into the same transaction.
    2. Add a test that resizes mid-frame, as *Sam Example* asked.

    ## Plan

    | Step | Owner |
    | --- | --- |
    | Resize | `Renderer` |
    | Test | Sam Example |

    ```swift
    let size = layer.drawableSize
    layer.drawableSize = view.bounds.size
    ```

    > Note: the ~/Library cache stays as is, see snake_case_names.

    ***

    That's all for now. Done!
    """

    /// A Codex-like stream of `text`: one to five words per delta at irregular gaps, one longer stall (after the ninth).
    static func deltas(_ text: String, start: TimeInterval = 0, seed: UInt64 = 7,
                       stall: TimeInterval = 0.95) -> [(time: TimeInterval, text: String)] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var result: [(TimeInterval, String)] = []
        var index = text.startIndex, time = start, count = 0
        while index < text.endIndex {
            var words = 1 + Int(next() * 5)
            var end = index
            while end < text.endIndex && words > 0 {
                if text[end] == " " || text[end] == "\n" { words -= 1 }
                end = text.index(after: end)
            }
            result.append((time, String(text[..<end])))
            index = end
            count += 1
            time += count == 9 ? stall : 0.06 + next() * 0.22
        }
        return result
    }

    // MARK: Pacing

    /// While text waits the reveal never types slower than a steady typist once it has picked up speed, its speed eases
    /// (no frame jumps far ahead of the one before) and it keeps about 0.3 s behind what has arrived.
    func testRateStaysWithinBoundsAndBehindTheStream() {
        let text = String(repeating: "Steady words arrive in small groups and type out evenly ", count: 6)
        let stream = Self.deltas(text, seed: 3)
        var clock = ChatTypingClock(position: 0, at: 0)
        var arrivedAt: [Int: TimeInterval] = [:], shownAt: [Int: TimeInterval] = [:]
        var layout = ChatTypingLayout("", ended: false)
        var delta = 0, previousShown = 0, previousRate = 0.0
        let dt = 1.0 / 60
        for frame in 0..<(60 * 20) {
            let now = Double(frame) * dt
            while delta < stream.count && stream[delta].time <= now {
                layout = ChatTypingLayout(stream[delta].text, ended: false)
                for unit in 0..<layout.total where arrivedAt[unit] == nil { arrivedAt[unit] = stream[delta].time }
                delta += 1
            }
            let waiting = Double(layout.total) - clock.position
            clock.advance(to: now, costs: layout.costs, ended: delta == stream.count)
            for unit in previousShown..<clock.shown { shownAt[unit] = now }
            if waiting > 2, let first = arrivedAt[clock.shown], now - first > 0.6 {
                XCTAssertGreaterThanOrEqual(clock.rate, ChatTypingClock.minimumRate * 0.9, "frame \(frame)")
            }
            // Eased: the speed moves a small step toward its target each frame.
            XCTAssertLessThanOrEqual(abs(clock.rate - previousRate), max(40, previousRate * 0.2), "frame \(frame)")
            XCTAssertLessThanOrEqual(clock.shown - previousShown, 6, "frame \(frame)")
            previousShown = clock.shown; previousRate = clock.rate
        }
        XCTAssertEqual(clock.shown, layout.total)
        // Behind the stream by about the lag, units arriving mid-stream.
        let lags = arrivedAt.keys.sorted().dropFirst(40).dropLast(40).compactMap { unit in shownAt[unit].map { $0 - arrivedAt[unit]! } }
        let median = lags.sorted()[lags.count / 2]
        XCTAssertGreaterThan(median, 0.1)
        XCTAssertLessThan(median, 0.6)
        XCTAssertTrue(lags.allSatisfy { $0 >= 0 })
    }

    /// A unit after `,;:` costs 2.5 more and after `.!?` 5 more (on the space that follows), a new block 7 more, each
    /// within ±25% of that; a dot inside a word does not pause.
    func testPunctuationAndBlockPauses() {
        let layout = ChatTypingLayout("One, two. Three file.swift go!\n\nNext", ended: true)
        let plain = layout.blocks[0].plain
        func cost(_ offset: Int) -> Double { layout.costs[offset] }
        for (offset, character) in plain.enumerated() {
            let previous = offset > 0 ? plain[offset - 1] : nil
            let base: Double = character == " " && previous == "," ? 3.5 : character == " " && previous == "." ? 6 : 1
            XCTAssertGreaterThanOrEqual(cost(offset), base * 0.75 - 1e-9, "\(offset) \(character)")
            XCTAssertLessThanOrEqual(cost(offset), base * 1.25 + 1e-9, "\(offset) \(character)")
        }
        let next = layout.blocks[1].start
        XCTAssertGreaterThanOrEqual(cost(next), 8 * 0.75)
        XCTAssertLessThanOrEqual(cost(next), 8 * 1.25)
        // The same position always costs the same: a frame drawn again is the same frame.
        XCTAssertEqual(layout.costs, ChatTypingLayout("One, two. Three file.swift go!\n\nNext", ended: true).costs)
        XCTAssertGreaterThan(Set(layout.costs.filter { $0 < 2 }).count, 5, "jittered")
    }

    /// Once the stream ends the reveal catches up faster: the reply finishes well within half a second of its last
    /// delta, sooner than if the stream had stayed open.
    func testEndOfStreamCatchesUpFaster() {
        func finish(ending: Bool) -> TimeInterval {
            let stream = Self.deltas(Self.reply, seed: 11)
            var clock = ChatTypingClock(position: 0, at: 0)
            var layout = ChatTypingLayout("", ended: false)
            var delta = 0
            for frame in 0..<(60 * 60) {
                let now = Double(frame) / 60
                while delta < stream.count && stream[delta].time <= now {
                    delta += 1
                    layout = ChatTypingLayout(stream[delta - 1].text, ended: ending && delta == stream.count)
                }
                clock.advance(to: now, costs: layout.costs, ended: ending && delta == stream.count)
                if delta == stream.count, clock.shown == layout.total { return now - stream[stream.count - 1].time }
            }
            return .infinity
        }
        let ended = finish(ending: true), open = finish(ending: false)
        XCTAssertLessThan(ended, 0.5)
        XCTAssertLessThan(ended, open)
    }

    /// The caret: solid while typing, blinking 0.9/0.15 at about 1.1 Hz while caught up with a quiet stream (steady
    /// after the blink limit, when the clock needs nothing more), fading out over 0.3 s once the message is complete.
    func testCaretTypesBlinksAndFades() {
        let layout = ChatTypingLayout("Hello there", ended: false)
        var clock = ChatTypingClock(position: 0, at: 0)
        clock.advance(to: 0.05, costs: layout.costs, ended: false)
        XCTAssertEqual(clock.caret(at: 0.05), 1)
        XCTAssertEqual(clock.needs(at: 0.05), .frames)
        var now = 0.05
        while clock.position < Double(layout.total) { now += 1.0 / 60; clock.advance(to: now, costs: layout.costs, ended: false) }
        let caught = now
        let samples = stride(from: caught, to: caught + 2, by: 0.05).map { clock.caret(at: $0) }
        XCTAssertEqual(Set(samples), [0.9, 0.15])
        XCTAssertEqual(clock.caret(at: caught), 0.9)
        XCTAssertEqual(clock.needs(at: caught + 1), .blink)
        XCTAssertEqual(clock.caret(at: caught + ChatTypingClock.blinkLimit + 1), 0.9)
        XCTAssertEqual(clock.needs(at: caught + ChatTypingClock.blinkLimit + 1), .nothing)
        // The stream ends: the caret fades from then.
        let end = caught + 1
        clock.advance(to: end, costs: layout.costs, ended: true)
        XCTAssertEqual(clock.caret(at: end), 1, accuracy: 1e-9)
        XCTAssertEqual(clock.caret(at: end + 0.15), 0.5, accuracy: 1e-6)
        XCTAssertEqual(clock.needs(at: end + 0.15), .frames)
        XCTAssertEqual(clock.caret(at: end + 0.3), 0, accuracy: 1e-9)
        XCTAssertTrue(clock.done(at: end + 0.31))
    }

    // MARK: What shows

    /// A complete reply, one outside the live turn, and one first seen with its text there show at once; one that
    /// began streaming just before it was first drawn types from its first character; Reduce Motion and testing show
    /// everything at once. A message that is done leaves the store.
    func testCompleteMessagesShowAtOnceAndNewOnesType() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 100
        let store = ChatTypingReveals()
        store.now = { time }
        store.drivesItself = false
        XCTAssertNil(store.reveal("done", text: "Finished.", live: true, ended: true, reduceMotion: false))
        XCTAssertNil(store.reveal("old", text: "Earlier turn.", live: false, ended: false, reduceMotion: false))
        let seen = store.reveal("seen", text: "Arrived before it was drawn", live: true, ended: false, reduceMotion: false)
        XCTAssertEqual(seen?.current.shown, seen?.layout.total)
        XCTAssertGreaterThan(seen?.layout.total ?? 0, 0)

        store.began("new")
        time += 0.05
        let typing = store.reveal("new", text: "Streaming reply", live: true, ended: false, reduceMotion: false)
        XCTAssertEqual(typing?.current.shown, 1)
        XCTAssertEqual(typing?.current.caret, 1)
        // A mark too old to be this drawing's: the reply shows at once.
        store.began("late")
        time += ChatTypingReveals.arrivalWindow + 0.1
        let late = store.reveal("late", text: "Shown when the chat opened", live: true, ended: false, reduceMotion: false)
        XCTAssertEqual(late?.current.shown, late?.layout.total)

        XCTAssertNil(store.reveal("new", text: "Streaming reply", live: true, ended: false, reduceMotion: true))
        store.began("motion")
        XCTAssertNil(store.reveal("motion", text: "Streaming", live: true, ended: false, reduceMotion: true))

        // Typed to its end and faded: the next draw of the complete reply leaves the store.
        store.began("finish")
        let finish = try XCTUnwrap(store.reveal("finish", text: "Short reply", live: true, ended: false, reduceMotion: false))
        store.appeared(finish)
        _ = store.reveal("finish", text: "Short reply.", live: true, ended: true, reduceMotion: false)
        for _ in 0..<120 { time += 1.0 / 60; store.step(to: time) }
        XCTAssertEqual(finish.current, ChatTypingFrame(shown: finish.layout.total, caret: 0))
        XCTAssertNil(store.reveal("finish", text: "Short reply.", live: true, ended: true, reduceMotion: false))

        ChatTypingReveals.enabled = false
        store.began("testing")
        XCTAssertNil(store.reveal("testing", text: "Streaming", live: true, ended: false, reduceMotion: false))
    }

    /// While testing the reveal is off, so recorded tests that wait on a reply's text see it as it arrives.
    func testRevealIsOffWhileTesting() {
        XCTAssertFalse(ChatTypingReveals.enabled)
    }

    /// The clock runs only while a shown reveal types, blinks or fades: none for a complete reply or one no view shows,
    /// and it stops once the last reveal is done. A reveal shown again after it left shows what arrived meanwhile.
    func testClockRunsOnlyWhileARevealNeedsIt() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 10
        let store = ChatTypingReveals()
        store.now = { time }
        store.drivesItself = false
        store.began("row")
        let reveal = try XCTUnwrap(store.reveal("row", text: "Typing out a reply", live: true, ended: false, reduceMotion: false))
        XCTAssertEqual(reveal.needs(at: time), .nothing, "not shown yet")
        store.appeared(reveal)
        XCTAssertEqual(reveal.needs(at: time), .frames)
        for _ in 0..<30 { time += 1.0 / 60; store.step(to: time) }
        let shown = reveal.current.shown
        XCTAssertGreaterThan(shown, 1)
        store.disappeared(reveal)
        XCTAssertEqual(reveal.needs(at: time), .nothing)
        time += 1
        store.step(to: time)
        XCTAssertEqual(reveal.current.shown, shown, "no steps while no view shows it")
        // Shown again: what arrived meanwhile shows at once.
        let again = store.reveal("row", text: "Typing out a reply that grew meanwhile", live: true, ended: false, reduceMotion: false)
        XCTAssertTrue(again === reveal)
        store.appeared(reveal)
        XCTAssertEqual(reveal.current.shown, reveal.layout.total)
        _ = store.reveal("row", text: "Typing out a reply that grew meanwhile.", live: true, ended: true, reduceMotion: false)
        for _ in 0..<60 { time += 1.0 / 60; store.step(to: time) }
        XCTAssertEqual(reveal.needs(at: time), .nothing)
        XCTAssertTrue(reveal.done(at: time))
    }

    /// A real display link drives the store while a reveal types, and stops when it is done: an idle chat runs none.
    func testDisplayLinkStopsWhenIdle() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 10
        let store = ChatTypingReveals()
        store.now = { time }
        XCTAssertNil(store.reveal("complete", text: "Done.", live: true, ended: true, reduceMotion: false))
        XCTAssertFalse(store.running)
        store.began("row")
        let reveal = try XCTUnwrap(store.reveal("row", text: "Typing", live: true, ended: false, reduceMotion: false))
        XCTAssertFalse(store.running, "no view shows it yet")
        store.appeared(reveal)
        XCTAssertTrue(store.running)
        _ = store.reveal("row", text: "Typing.", live: true, ended: true, reduceMotion: false)
        for _ in 0..<60 { time += 1.0 / 60; store.step(to: time) }
        XCTAssertFalse(store.running)
        store.reset()
    }

    // MARK: No raw Markdown, ever

    /// Every prefix of a reply (any way its deltas could split it) shows only what the whole reply shows, drawn the
    /// same way: the same block kinds, a text block's characters a prefix of its final ones (no `**`, backtick, `[`,
    /// list marker or table pipe that later turns into formatting), code by whole lines, tables by whole rows.
    func testNoPrefixShowsRawMarkdown() {
        let final = ChatTypingLayout(Self.reply, ended: true)
        let finalBlocks = Self.blocks(final)
        var index = Self.reply.startIndex
        while index < Self.reply.endIndex {
            index = Self.reply.index(after: index)
            let prefix = String(Self.reply[..<index])
            let layout = ChatTypingLayout(prefix, ended: false)
            Self.assertConsistent(layout, shown: layout.total, with: final, finalBlocks, "prefix \(prefix.count): \(prefix.suffix(24).debugDescription)")
        }
    }

    /// Frame by frame through a Codex-like stream at 60 fps: what shows only grows, stays consistent with the whole
    /// reply, and the caret is after the last character shown, in the block that holds it.
    func testEveryFrameShowsFormattedTextWithTheCaretAfterIt() {
        let final = ChatTypingLayout(Self.reply, ended: true)
        let finalBlocks = Self.blocks(final)
        let stream = Self.deltas(Self.reply, seed: 5)
        var clock = ChatTypingClock(position: 0, at: 0)
        var layout = ChatTypingLayout("", ended: false)
        var delta = 0, previous = 0, previousText = ""
        var frame = 0
        while frame < 60 * 60 {
            let now = Double(frame) / 60
            while delta < stream.count && stream[delta].time <= now {
                delta += 1
                layout = ChatTypingLayout(stream[delta - 1].text, ended: delta == stream.count)
            }
            clock.advance(to: now, costs: layout.costs, ended: delta == stream.count)
            let drawn = ChatTypingFrame(shown: min(clock.shown, layout.total), caret: clock.caret(at: now))
            XCTAssertGreaterThanOrEqual(drawn.shown, previous, "frame \(frame)")
            Self.assertConsistent(layout, shown: drawn.shown, with: final, finalBlocks, "frame \(frame)")
            // The text shown only grows: each frame's is the previous frame's and more.
            let text = Self.shownText(layout, drawn.shown)
            XCTAssertTrue(text.hasPrefix(previousText), "frame \(frame): \(text.suffix(30).debugDescription)")
            previousText = text
            if drawn.caret > 0, let block = layout.caretBlock(drawn.shown), layout.blocks[block].isText {
                let visible = layout.visibleBlocks(drawn.shown)
                XCTAssertEqual(block, layout.blocks[..<visible].lastIndex { $0.units > 0 }, "frame \(frame)")
                if let cut = layout.cut(block: block, frame: drawn) {
                    XCTAssertEqual(cut.caret, drawn.caret)
                    XCTAssertEqual(layout.blocks[block].start + cut.shown, drawn.shown, "caret after the last unit shown")
                }
                for other in 0..<visible where other != block {
                    XCTAssertNil(layout.cut(block: other, frame: drawn)?.caret, "one caret, frame \(frame)")
                }
            }
            previous = drawn.shown
            if delta == stream.count && clock.done(at: now) { break }
            frame += 1
        }
        XCTAssertEqual(previous, final.total)
        XCTAssertLessThan(frame, 60 * 60)
    }

    /// The word being typed is laid out whole (`hiddenTail`), up to the next space, so it never jumps lines.
    func testHiddenTailFinishesTheWord() {
        let layout = ChatTypingLayout("Resizing **mid-frame** drawables", ended: true)
        XCTAssertEqual(layout.hiddenTail(block: 0, shown: 2), 6)    // "Re" + "sizing"
        XCTAssertEqual(layout.hiddenTail(block: 0, shown: 8), 0)    // at the space
        XCTAssertEqual(layout.hiddenTail(block: 0, shown: 10), 8)   // "m" + "id-frame"
        let split = ChatTypingLayout.split(AttributedString("Resizing frames"), shown: 2, hidden: 6)
        XCTAssertEqual(String(split.shown.characters), "Re")
        XCTAssertEqual(String(split.tail.characters), "sizing")
    }

    /// What a half-arrived construct holds back shows as soon as it closes, formatted; nothing else waits.
    func testHeldConstructsShowOnceClosed() {
        func shown(_ text: String) -> String {
            let layout = ChatTypingLayout(text, ended: false)
            return Self.shownText(layout, layout.total)
        }
        XCTAssertEqual(shown("Holds the **old surf"), "Holds the ")
        XCTAssertEqual(shown("Holds the **old surface size**, so"), "Holds the old surface size, so")
        XCTAssertEqual(shown("Use `Termin"), "Use ")
        XCTAssertEqual(shown("Use `TerminalRuntime` now"), "Use TerminalRuntime now")
        XCTAssertEqual(shown("See [notes](https://exa"), "See ")
        XCTAssertEqual(shown("See [notes](https://example.com) now"), "See notes now")
        XCTAssertEqual(shown("Done.\n\n- "), "Done.")
        XCTAssertEqual(shown("Done.\n\n- `Ter"), "Done.")
        XCTAssertEqual(shown("Done.\n\n- Next"), "Done.\n\nNext")
        XCTAssertEqual(shown("Done.\n\n1"), "Done.")
        XCTAssertEqual(shown("Done.\n\n```swift\nlet a = 1\nlet b"), "Done.\n\nlet a = 1")
        XCTAssertEqual(shown("snake_case_names stay"), "snake_case_names stay")
        XCTAssertEqual(shown("| A | B |\n"), "")
        XCTAssertEqual(shown("| A | B |\n| --- | --- |\n"), "A|B")
        // An opener long before the end is text: a lone `[` does not hold the rest of its paragraph back.
        let long = "A [ bracket " + String(repeating: "and more words ", count: 20)
        XCTAssertEqual(shown(long), long)
        // Once the stream ends everything shows.
        let ended = ChatTypingLayout("Use `Termin", ended: true)
        XCTAssertEqual(Self.shownText(ended, ended.total), "Use `Termin")
    }

    // MARK: Resting and resuming

    /// A store whose display link runs (`drivesItself`), stepped by hand on its own clock, with one row shown.
    private func typingStore(_ time: @escaping () -> TimeInterval) -> ChatTypingReveals {
        let store = ChatTypingReveals()
        store.now = time
        return store
    }

    /// A stream quiet for longer than the blink limit (the link stops) types again when more arrives: the link starts
    /// again and the whole reply shows, as the end signal coming long after the last delta still fades the caret.
    func testQuietLongerThanTheBlinkTypesWhatComesNext() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 50
        let store = typingStore { time }
        defer { store.reset() }
        let stream = Self.deltas(Self.reply, start: time, seed: 13, stall: ChatTypingClock.blinkLimit + 3)
        store.began("row")
        let reveal = try XCTUnwrap(store.reveal("row", text: stream[0].text, live: true, ended: false, reduceMotion: false))
        store.appeared(reveal)
        var delta = 1, stopped = false, restarted = false
        while time < stream[stream.count - 1].time + 2 {
            time += 1.0 / 60
            while delta < stream.count && stream[delta].time <= time {
                _ = store.reveal("row", text: stream[delta].text, live: true, ended: false, reduceMotion: false)
                if stopped && store.running { restarted = true }
                delta += 1
            }
            if store.running { store.step(to: time) } else { stopped = true }
        }
        XCTAssertTrue(stopped, "the link rested through the stall")
        XCTAssertTrue(restarted, "and started again when the stream went on")
        XCTAssertEqual(reveal.current.shown, reveal.layout.total)
        XCTAssertEqual(reveal.layout.total, ChatTypingLayout(Self.reply, ended: false).total)
        // The end signal comes long after: the caret fades, then the link stops for good.
        time += ChatTypingClock.blinkLimit + 2
        XCTAssertNotNil(store.reveal("row", text: Self.reply, live: true, ended: true, reduceMotion: false))
        XCTAssertTrue(store.running)
        for _ in 0..<60 { time += 1.0 / 60; if store.running { store.step(to: time) } }
        XCTAssertFalse(store.running)
        XCTAssertEqual(reveal.current, ChatTypingFrame(shown: ChatTypingLayout(Self.reply, ended: true).total, caret: 0))
    }

    /// A reply that leaves the live turn while it types (its window held, a turn ended early) and comes back goes on
    /// typing from where it showed, the link starting again; one that finished meanwhile shows the rest at once.
    func testLiveThenNotLiveThenLiveResumes() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 20
        let store = typingStore { time }
        defer { store.reset() }
        let first = "The resize lands while the renderer still holds the old surface size, so"
        store.began("row")
        let reveal = try XCTUnwrap(store.reveal("row", text: first, live: true, ended: false, reduceMotion: false))
        store.appeared(reveal)
        for _ in 0..<12 { time += 1.0 / 60; store.step(to: time) }
        XCTAssertLessThan(reveal.current.shown, reveal.layout.total)
        // Not live: it catches up with what it has and rests.
        XCTAssertNotNil(store.reveal("row", text: first, live: false, ended: false, reduceMotion: false))
        for _ in 0..<6 { time += 1.0 / 60; store.step(to: time) }
        let held = reveal.current.shown
        // Live again with more: it types on from there.
        let more = first + " the next frame is drawn into a buffer nobody presents."
        XCTAssertTrue(store.reveal("row", text: more, live: true, ended: false, reduceMotion: false) === reveal)
        XCTAssertTrue(store.running)
        time += 1.0 / 60; store.step(to: time)
        XCTAssertGreaterThanOrEqual(reveal.current.shown, held)
        XCTAssertLessThan(reveal.current.shown, reveal.layout.total, "typing, not shown at once")
        XCTAssertEqual(reveal.current.caret, 1)
        for _ in 0..<180 { time += 1.0 / 60; if store.running { store.step(to: time) } }
        XCTAssertEqual(reveal.current.shown, reveal.layout.total)

        // Finished while not live: dropped, and shown again live it shows what has arrived, caught up.
        _ = store.reveal("row", text: more, live: false, ended: false, reduceMotion: false)
        for _ in 0..<60 { time += 1.0 / 60; if store.running { store.step(to: time) } }
        XCTAssertNil(store.reveal("row", text: more, live: false, ended: false, reduceMotion: false))
        let again = try XCTUnwrap(store.reveal("row", text: more + " Then", live: true, ended: false, reduceMotion: false))
        XCTAssertEqual(again.current.shown, again.layout.total)
    }

    /// The display link of a store that goes (a typing tab closed) stops with it.
    func testLinkStopsWhenItsStoreGoes() throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        let before = ChatTypingLink.running
        var store: ChatTypingReveals? = ChatTypingReveals()
        weak var gone = store
        store?.began("row")
        let reveal = try XCTUnwrap(store?.reveal("row", text: "Typing a reply", live: true, ended: false, reduceMotion: false))
        store?.appeared(reveal)
        XCTAssertEqual(ChatTypingLink.running, before + 1)
        store = nil
        XCTAssertNil(gone)
        XCTAssertEqual(ChatTypingLink.running, before)
    }

    /// A reply whose first words are all a construct still arriving (`**Summ`) shows the caret alone, not nothing.
    func testHeldFirstWordsShowTheCaretAlone() {
        let reveal = ChatTypingReveal(id: "row", text: "**Summ", ended: false, fromStart: true, at: 0)
        XCTAssertEqual(reveal.layout.total, 0)
        XCTAssertEqual(reveal.current.shown, 0)
        XCTAssertGreaterThan(reveal.current.caret, 0)
        reveal.feed("**Summary** of the change", ended: false, at: 0.1)
        reveal.step(to: 0.2)
        XCTAssertGreaterThan(reveal.current.shown, 0)
        XCTAssertEqual(reveal.current.caret, 1)
    }

    /// Constructs a delta may cut anywhere: no prefix shows their syntax raw (nested parentheses in a link, a task's
    /// box, an autolink, a hard break, emphasis, code spans, lists, tables, fences).
    func testNoPrefixOfTrickyMarkdownShowsRawSyntax() {
        for reply in [
            "Use **bold `code` inside** here.", "***bold italic*** then text.", "See https://example.com/a_(b)_c for more.",
            "[link](https://example.com/a_(b)) after.", "a ~~strike~~ b and ~/path/file done.", "- [ ] task one\n- [x] task two",
            "10. tenth item\n11. eleventh", "> quote line\n> second line", "1) paren list\n2) second", "Intro:\n* star item\n* another",
            "A 2*3*4 product and a*b.", "file_name_with_underscores_ok and _emph_ end.", "Text <https://example.com> autolink.",
            "Line with trailing backslash \\\nnext line", "Escaped \\*not emphasis\\* done.", "Inline `a` and ``b`c`` and `d`.",
            "Table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.", "Code:\n\n```\nfn main() {}\n```\nAfter code.",
            "word-word **x**y z", "Emoji 👍🏽 and café, then naïve.",
        ] {
            let final = ChatTypingLayout(reply, ended: true)
            let finalBlocks = Self.blocks(final)
            var index = reply.startIndex
            while index < reply.endIndex {
                index = reply.index(after: index)
                let layout = ChatTypingLayout(String(reply[..<index]), ended: false)
                Self.assertConsistent(layout, shown: layout.total, with: final, finalBlocks, "\(reply[..<index].debugDescription)")
            }
        }
    }

    /// A long word (a path, a URL) is laid out whole while it types, so it never moves to another line.
    func testLongWordsAreLaidOutWhole() {
        let path = "/Users/sam/Developer/project/Sources/Module/VeryLongFileName.swift"
        let layout = ChatTypingLayout("See \(path) here", ended: true)
        XCTAssertEqual(layout.hiddenTail(block: 0, shown: 5), path.count - 1)
    }

    // MARK: Helpers

    static func blocks(_ layout: ChatTypingLayout) -> [ChatMarkdownBlock] {
        ChatMarkdownBlock.parse(TextRendering.rich(layout.source).text)
    }

    /// The text a frame shows, block by block.
    static func shownText(_ layout: ChatTypingLayout, _ shown: Int) -> String {
        let parsed = blocks(layout)
        return (0..<layout.visibleBlocks(shown)).map { index in
            let units = layout.shown(block: index, of: shown) ?? 0
            switch parsed[index].kind {
            case .code: return ChatTypingLayout.lines(parsed[index].text).prefix(units).joined(separator: "\n")
            case .table(let rows): return rows.prefix(units).map { $0.joined(separator: "|") }.joined(separator: "\n")
            case .rule: return "---"
            default: return String(layout.blocks[index].plain.prefix(units))
            }
        }.joined(separator: "\n\n")
    }

    static func assertConsistent(_ layout: ChatTypingLayout, shown: Int, with final: ChatTypingLayout,
                                 _ finalBlocks: [ChatMarkdownBlock], _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let parsed = blocks(layout)
        XCTAssertEqual(parsed.count, layout.blocks.count, context, file: file, line: line)
        for index in 0..<layout.visibleBlocks(shown) {
            guard index < finalBlocks.count else {
                return XCTFail("\(context): block \(index) is not in the reply", file: file, line: line)
            }
            let units = layout.shown(block: index, of: shown) ?? 0
            let block = parsed[index], whole = finalBlocks[index]
            switch (block.kind, whole.kind) {
            case (.table(let rows), .table(let all)):
                XCTAssertEqual(Array(rows.prefix(units)), Array(all.prefix(units)), "\(context): table \(index)", file: file, line: line)
            case (.code(let language), .code(let wholeLanguage)):
                XCTAssertEqual(language, wholeLanguage, "\(context): code \(index)", file: file, line: line)
                XCTAssertEqual(ChatTypingLayout.lines(block.text).prefix(units), ChatTypingLayout.lines(whole.text).prefix(units),
                               "\(context): code \(index)", file: file, line: line)
            default:
                XCTAssertEqual(block.kind, whole.kind, "\(context): block \(index)", file: file, line: line)
                XCTAssertEqual(String(layout.blocks[index].plain.prefix(units)), String(final.blocks[index].plain.prefix(units)),
                               "\(context): block \(index)", file: file, line: line)
            }
        }
    }
}
