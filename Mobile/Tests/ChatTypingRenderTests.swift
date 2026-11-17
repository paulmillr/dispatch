import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The iPhone's typed reveal as drawn (`MobileChatMarkdownView` with a `ChatTypingReveal`, its text renderer): frames
/// stepped by hand and rendered, the caret found by its colour.
@MainActor final class ChatTypingRenderTests: XCTestCase {
    private static let reply = "Typing one word at a time across the bubble, so that it wraps onto a second line and then a third one here."

    private struct Pixels {
        let width: Int, height: Int, scale: CGFloat
        let data: [UInt8]
        init?(_ image: UIImage) {
            guard let cg = image.cgImage else { return nil }
            width = cg.width; height = cg.height; scale = image.scale
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            self.data = data
        }
        func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }
    }

    /// The view as the screen shows it: in a window, captured from the render server (a typing paragraph is a UIKit view
    /// revealed by a Core Animation mask, which `ImageRenderer` does not draw).
    private func render(_ typing: ChatTypingReveal?, text: String) async throws -> Pixels {
        let view = MobileChatMarkdownView(text: text, typing: typing)
            .font(.system(size: 17))
            .foregroundStyle(Color.black)
            .frame(width: 260, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let size = UIHostingController(rootView: view).sizeThatFits(in: CGSize(width: 260, height: 10_000))
        // Pinned to the window's top: a window a fraction taller would centre it a fraction of a pixel lower.
        let host = UIHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 260, height: size.height.rounded(.up)))
        window.backgroundColor = .white
        host.view.backgroundColor = .white
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return try XCTUnwrap(Pixels(image))
    }

    /// While it types, exactly one caret shows: 2 points wide, in the accent, right after the last character drawn on
    /// its line with nothing drawn after it (the rest of the word is laid out, not drawn); the text grows a line at a
    /// time and is never taller than the finished reply.
    func testCaretFollowsTheLastCharacterDrawn() async throws {
        let pink = UIColor(Color.dispatchPink).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        pink.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let accent = (Int(red * 255), Int(green * 255), Int(blue * 255))
        let finished = try await render(nil, text: Self.reply)

        // Two words every 0.15 s, typed out about 0.3 s behind.
        let words = Self.reply.split(separator: " ", omittingEmptySubsequences: false)
        func arrived(_ time: Double) -> String { words.prefix(min(words.count, 2 + Int(time / 0.15) * 2)).joined(separator: " ") }
        let reveal = ChatTypingReveal(id: "row", text: arrived(0), ended: false, fromStart: true, at: 0)
        var previousHeight = 0, checked = 0
        for frame in 1...(60 * 4) {
            let now = Double(frame) / 60
            let text = arrived(now)
            reveal.feed(text, ended: false, at: now)
            reveal.step(to: now)
            guard frame % 10 == 0, reveal.current.caret == 1 else { continue }
            let pixels = try await render(reveal, text: text)
            let step = frame
            XCTAssertLessThanOrEqual(pixels.height, finished.height)
            XCTAssertGreaterThanOrEqual(pixels.height, previousHeight, "grows, never shrinks")
            previousHeight = pixels.height
            // The caret's pixels.
            var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let p = pixels.rgba(x, y)
                    if abs(p.r - accent.0) < 24, abs(p.g - accent.1) < 24, abs(p.b - accent.2) < 24, p.a > 200 {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(maxX, 0, "step \(step): a caret")
            guard maxX >= 0 else { continue }
            let scale = Int(pixels.scale)
            XCTAssertLessThanOrEqual(maxX - minX + 1, 2 * scale + 1, "step \(step): 2 points wide")
            XCTAssertGreaterThan(maxY - minY, 10 * scale, "step \(step): a line tall")
            // Text on the caret's line: dark pixels, all left of the caret and ending right before it.
            var textMaxX = -1
            for y in minY...maxY {
                for x in 0..<pixels.width where x < minX || x > maxX {
                    let p = pixels.rgba(x, y)
                    if p.r < 110 && p.g < 110 && p.b < 110 && p.a > 200 {
                        XCTAssertLessThan(x, minX, "step \(step): nothing drawn after the caret")
                        textMaxX = max(textMaxX, x)
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(textMaxX, 0, "step \(step): text before the caret")
            // One cell after the last character: right after a letter, a space's width after a space.
            let space = reveal.layout.blocks[0].plain[reveal.current.shown - 1].isWhitespace
            XCTAssertLessThanOrEqual(minX - textMaxX, (space ? 9 : 3) * scale, "step \(step): right after the last character")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
    }

    /// A reply whose first words are a construct still arriving draws one line holding the caret, not an empty bubble.
    func testHeldFirstWordsDrawTheCaretAlone() async throws {
        let reveal = ChatTypingReveal(id: "row", text: "**Summ", ended: false, fromStart: true, at: 0)
        let pixels = try await render(reveal, text: "**Summ")
        XCTAssertGreaterThan(pixels.height, 14 * Int(pixels.scale))
        var caret = 0, text = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels.rgba(x, y)
                if p.r > 150 && p.b > 150 && p.g < 140 { caret += 1 }
                if p.r < 110 && p.g < 110 && p.b < 110 && p.a > 200 { text += 1 }
            }
        }
        XCTAssertGreaterThan(caret, 10, "the caret shows")
        XCTAssertEqual(text, 0, "no raw ** shows")
    }

    /// The caret's pixels in `pixels` (the accent, opaque): its bounds, nil without one.
    private func caret(in pixels: Pixels) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let pink = UIColor(Color.dispatchPink).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        pink.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let accent = (Int(red * 255), Int(green * 255), Int(blue * 255))
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = pixels.rgba(x, y)
                if abs(p.r - accent.0) < 24, abs(p.g - accent.1) < 24, abs(p.b - accent.2) < 24, p.a > 200 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return maxX >= 0 ? (minX, maxX, minY, maxY) : nil
    }

    /// The typing paragraph is the finished text revealed: every line above the caret's, and its own up to the caret,
    /// draws exactly as the finished reply does (the same font, colour and place), so nothing moves as it finishes.
    func testTheTypedPartDrawsAsTheFinishedText() async throws {
        let finished = try await render(nil, text: Self.reply)
        let reveal = ChatTypingReveal(id: "row", text: Self.reply, ended: false, fromStart: true, at: 0)
        var time = 0.0
        while reveal.current.shown < 70 { time += 1.0 / 60; reveal.step(to: time) }
        let typing = try await render(reveal, text: Self.reply)
        let bar = try XCTUnwrap(caret(in: typing))
        XCTAssertGreaterThan(bar.minY, 10, "on the second line or below")
        var differing = 0, compared = 0
        var samples: [String] = []
        for y in 0..<min(typing.height, finished.height) {
            // Rows above the caret's line whole; on its line, left of it.
            let limit = y < bar.minY - 2 ? finished.width : (y <= bar.maxY ? bar.minX - 2 : 0)
            for x in 0..<max(0, limit) {
                compared += 1
                let a = typing.rgba(x, y), b = finished.rgba(x, y)
                // Anti-aliasing may differ by a few levels (the image is drawn at the screen's scale); a glyph out of place
                // by a pixel differs by a hundred or more.
                if abs(a.r - b.r) > 32 || abs(a.g - b.g) > 32 || abs(a.b - b.b) > 32 {
                    differing += 1
                    if samples.count < 12 { samples.append("(\(x),\(y)) \(a.r)/\(b.r)") }
                }
            }
        }
        XCTAssertGreaterThan(compared, 10_000)
        XCTAssertEqual(differing, 0, "\(samples) caret \(bar) sizes \(typing.width)x\(typing.height) \(finished.width)x\(finished.height)")
    }

    /// The caret follows the characters, not their UTF-16 units or glyphs: after an emoji, a family emoji and an accent,
    /// it stands right after the last character shown, where that text alone ends.
    func testTheCaretCountsCharactersAcrossEmoji() async throws {
        let text = "Café ☕️ and 👩‍👩‍👧 then the rest"
        let reveal = ChatTypingReveal(id: "row", text: text, ended: false, fromStart: true, at: 0)
        let plain = reveal.layout.blocks[0].plain
        let target = try XCTUnwrap(plain.firstIndex(of: "h")) + 1
        var time = 0.0
        while reveal.current.shown < target { time += 1.0 / 60; reveal.step(to: time) }
        let shown = String(plain.prefix(reveal.current.shown))
        XCTAssertTrue(shown.hasSuffix("th"), shown)
        let typing = try await render(reveal, text: text)
        let alone = try await render(nil, text: shown)
        let bar = try XCTUnwrap(caret(in: typing))
        var end = -1
        for y in 0..<alone.height {
            for x in 0..<alone.width {
                let p = alone.rgba(x, y)
                if p.r < 110 && p.g < 110 && p.b < 110 && p.a > 200 { end = max(end, x) }
            }
        }
        XCTAssertGreaterThan(end, 0)
        XCTAssertLessThanOrEqual(abs(bar.minX - end), 3 * Int(typing.scale), "caret at \(bar.minX), \"\(shown)\" ends at \(end)")
    }

    /// In a window, the typing paragraph draws the frames itself: stepping the reveal grows it a line at a time (it asks
    /// SwiftUI for the height), and once typed out and faded the block is SwiftUI text again.
    func testTheParagraphGrowsByItselfAndHandsBack() async throws {
        let reveal = ChatTypingReveal(id: "row", text: Self.reply, ended: true, fromStart: true, at: 0)
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let host = UIHostingController(rootView: MobileChatMarkdownView(text: Self.reply, typing: reveal)
            .font(.system(size: 17)).frame(width: 260, alignment: .topLeading))
        host.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 260, height: 400)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        func paragraphs() -> [UIView] {
            var found: [UIView] = [], queue: [UIView] = [window]
            while let view = queue.popLast() {
                if view is ChatTypingParagraph.ParagraphView { found.append(view) }
                queue.append(contentsOf: view.subviews)
            }
            return found
        }
        var time = 0.0
        func step() { time += 1.0 / 60; reveal.step(to: time) }
        step()
        try await TestSupport.eventually { paragraphs().count == 1 && paragraphs()[0].bounds.height > 10 }
        let paragraph = paragraphs()[0]
        let first = paragraph.bounds.height
        while reveal.current.shown < 60 { step() }
        try await TestSupport.eventually { paragraph.bounds.height > first + 10 }
        XCTAssertTrue(paragraphs().first === paragraph, "the same view: SwiftUI did not draw a new one")
        try await TestSupport.eventually {
            step()
            return reveal.done(at: time) && paragraphs().isEmpty
        }
    }

    /// What the view draws apart from the frames (`ChatTypingStage`): in a reply of every kind of block typing out and
    /// ending, no frame cuts or puts the caret in a block before the stage's live one, and the stage changes only as a
    /// block is added, a few times while the frames change hundreds.
    func testAFrameChangesOnlyTheBlocksFromTheStagesLiveOne() {
        let reply = """
            ## Billing webhooks

            The handler now retries twice, then gives up and logs the event.

            ```swift
            let retries = 2
            log(event)
            ```

            - First item, short.
            - Second item, a little longer than the first.

            | Name | Value |
            | --- | --- |
            | retries | 2 |

            ---

            Done; nothing else changed.
            """
        let reveal = ChatTypingReveal(id: "row", text: String(reply.prefix(40)), ended: false, fromStart: true, at: 0)
        var frames = 0, stages = 0, previous = reveal.current
        for step in 1...(60 * 20) {
            let now = Double(step) / 60
            // A character a frame (about six seconds of it), then the stream ends.
            let arrived = min(reply.count, 40 + step)
            let changed = Changed()
            withObservationTracking { _ = reveal.stage } onChange: { changed.fired = true }
            reveal.feed(String(reply.prefix(arrived)), ended: arrived == reply.count && step > 420, at: now - 0.5 / 60)
            reveal.step(to: now)
            if changed.fired { stages += 1 }
            let frame = reveal.current
            if frame != previous { frames += 1; previous = frame }
            let stage = reveal.stage
            XCTAssertEqual(stage, ChatTypingStage(reveal.layout, frame: frame), "step \(step)")
            for index in 0..<stage.live {
                XCTAssertNil(reveal.layout.cut(block: index, frame: frame), "step \(step): block \(index) is before the live one")
            }
            for index in stage.count..<reveal.layout.blocks.count {
                XCTAssertNil(reveal.layout.shown(block: index, of: frame.shown), "step \(step): block \(index) shows nothing yet")
            }
        }
        XCTAssertTrue(reveal.done(at: 20), "typed out and faded")
        XCTAssertEqual(reveal.stage.count, reveal.layout.blocks.count)
        XCTAssertGreaterThan(frames, 150)
        XCTAssertLessThan(stages, 3 * reveal.layout.blocks.count, "\(stages) stages for \(frames) frames")
    }
    private final class Changed: @unchecked Sendable { var fired = false }

    /// Typing the second paragraph, the first draws exactly as in the finished reply.
    func testBlocksBeforeTheTypingOneDrawAsTheFinishedReply() async throws {
        let first = "The handler now retries twice, then gives up and logs the event for the morning report."
        let reply = first + "\n\nThe second paragraph is still typing out across the bubble, one word at a time."
        let finished = try await render(nil, text: reply)
        let alone = try await render(nil, text: first)
        let reveal = ChatTypingReveal(id: "row", text: reply, ended: false, fromStart: true, at: 0)
        var time = 0.0
        while reveal.current.shown < reveal.layout.blocks[1].start + 20 {
            time += 1.0 / 60
            reveal.step(to: time)
        }
        XCTAssertEqual(reveal.stage, ChatTypingStage(reveal.layout, frame: reveal.current))
        XCTAssertEqual(reveal.stage.live, 1)
        let typing = try await render(reveal, text: reply)
        XCTAssertEqual(typing.width, finished.width)
        // The first paragraph's rows, short of the spacing below it.
        let rows = alone.height - Int(alone.scale)
        XCTAssertGreaterThan(rows, 0)
        var differing = 0
        var samples: [String] = []
        for y in 0..<rows {
            for x in 0..<finished.width {
                let a = typing.rgba(x, y), b = finished.rgba(x, y)
                if abs(a.r - b.r) > 32 || abs(a.g - b.g) > 32 || abs(a.b - b.b) > 32 {
                    differing += 1
                    if samples.count < 8 { samples.append("(\(x),\(y)) \(a.r)/\(b.r)") }
                }
            }
        }
        XCTAssertEqual(differing, 0, "\(samples) rows \(rows) sizes \(typing.height) \(finished.height)")
    }

    /// The thread's stack is not lazy: a typing reply scrolled out of view stays in it. It stops typing there (its
    /// clock's link stops) and types again once scrolled back.
    func testAReplyScrolledAwayStopsTyping() async throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        let store = ChatTypingReveals()
        store.now = { 5 }
        defer { store.reset() }
        store.began("row")
        let text = "Typing the first words of a reply long enough to keep typing while the test looks at it."
        func thread(above: CGFloat) -> some View {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: above)
                    MobileTypedMarkdown(text: text, rowID: "row", reveals: store, live: true, ended: false)
                }
            }
        }
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
        let host = UIHostingController(rootView: AnyView(thread(above: 2000)))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await TestSupport.eventually { store.reveal("row", text: text, live: true, ended: false, reduceMotion: false) != nil }
        let reveal = try XCTUnwrap(store.reveal("row", text: text, live: true, ended: false, reduceMotion: false))
        try await TestSupport.eventually { !reveal.mounted && !store.running }

        host.rootView = AnyView(thread(above: 0))
        try await TestSupport.eventually { reveal.mounted && store.running }

        host.rootView = AnyView(thread(above: 2000))
        try await TestSupport.eventually { !reveal.mounted && !store.running }
    }

    /// Through the thread's own view (`MobileTypedMarkdown`): shown, the reveal's clock runs; more text after a long
    /// rest starts it again; gone from the window, it stops.
    func testTypedMarkdownRunsTheClockWhileShown() async throws {
        let previous = ChatTypingReveals.enabled
        ChatTypingReveals.enabled = true
        defer { ChatTypingReveals.enabled = previous }
        var time: TimeInterval = 5
        let store = ChatTypingReveals()
        store.now = { time }
        defer { store.reset() }
        store.began("row")
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 400)
        let host = UIHostingController(rootView:
            MobileTypedMarkdown(text: "Typing the first words", rowID: "row", reveals: store, live: true, ended: false))
        func show(_ text: String) {
            host.rootView = MobileTypedMarkdown(text: text, rowID: "row", reveals: store, live: true, ended: false)
        }
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        try await TestSupport.eventually { store.running }
        let reveal = try XCTUnwrap(store.reveal("row", text: "Typing the first words", live: true, ended: false, reduceMotion: false))
        for _ in 0..<(60 * 8) { time += 1.0 / 60; if store.running { store.step(to: time) } }
        XCTAssertFalse(store.running)
        show("Typing the first words and then some more of them")
        try await TestSupport.eventually { store.running }
        XCTAssertLessThan(reveal.current.shown, reveal.layout.total)
        window.rootViewController = nil
        try await TestSupport.eventually {
            time += 1.0 / 60; store.step(to: time)
            return !store.running
        }
    }
}
