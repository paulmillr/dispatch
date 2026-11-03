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

    private func render(_ typing: ChatTypingReveal?, text: String) throws -> Pixels {
        let view = MobileChatMarkdownView(text: text, typing: typing)
            .font(.system(size: 17))
            .foregroundStyle(Color.black)
            .frame(width: 260, alignment: .topLeading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try XCTUnwrap(renderer.uiImage.flatMap(Pixels.init))
    }

    /// While it types, exactly one caret shows: 2 points wide, in the accent, right after the last character drawn on
    /// its line with nothing drawn after it (the rest of the word is laid out, not drawn); the text grows a line at a
    /// time and is never taller than the finished reply.
    func testCaretFollowsTheLastCharacterDrawn() throws {
        let pink = UIColor(Color.dispatchPink).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        pink.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let accent = (Int(red * 255), Int(green * 255), Int(blue * 255))
        let finished = try render(nil, text: Self.reply)

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
            let pixels = try render(reveal, text: text)
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
    func testHeldFirstWordsDrawTheCaretAlone() throws {
        let reveal = ChatTypingReveal(id: "row", text: "**Summ", ended: false, fromStart: true, at: 0)
        let pixels = try render(reveal, text: "**Summ")
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
