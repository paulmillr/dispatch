import Metal
import XCTest
@_spi(Test) import TermApple
@testable import DispatchMobile

/// The launch's prewarm (`TerminalSession.prewarm`, docs/ios.md, The first terminal): the renderer's pipelines
/// compiled and the bundled fonts mapped once for the process, so a session made afterwards compiles nothing and reads
/// no font file. The test host is the app: its own launch starts the prewarm (`MobileAppDelegate`, at its first
/// foreground), which each case checks before `prewarm()` waits for it.
@MainActor
final class TerminalPrewarmTests: XCTestCase {
    /// The app's launch started the prewarm, not this test (which only waits for it to end).
    private func launchStartedThePrewarm() async throws {
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "the app's launch never started the prewarm") {
            TerminalSession.prewarmStarted
        }
    }

    func testASessionAfterThePrewarmCompilesNothingAndReadsNoFont() async throws {
        try await launchStartedThePrewarm()
        TerminalSession.prewarm()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertEqual(MetalRenderer.librariesMade(device, .bgra8Unorm), 1, "once for the process")
        let reads = FontCollection.bundledFontReads
        XCTAssertGreaterThanOrEqual(reads, 3, "the prewarm mapped the three bundled fonts")
        let session = try TerminalSession.testing()
        defer { session.close() }
        session.feed("Sam Example \u{f07b}")
        XCTAssertEqual(MetalRenderer.librariesMade(device, .bgra8Unorm), 1, "the session compiled nothing")
        XCTAssertEqual(FontCollection.bundledFontReads, reads, "the session took the shared fonts")
        XCTAssertEqual((0..<11).map { session.cell($0, 0).text }.joined(), "Sam Example")
    }

    /// Collections made on several threads at once share the fonts' descriptors: each draws text from JetBrains Mono
    /// and the Nerd symbols from their own face, and none reads a file.
    func testCollectionsOnManyThreadsShareTheBundledFonts() async throws {
        try await launchStartedThePrewarm()
        TerminalSession.prewarm()
        let reads = FontCollection.bundledFontReads
        let results = ResultBox(count: 8)
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            guard let fonts = try? FontCollection(families: [], points: 12 + Float(i), dpi: 216) else { return }
            let text = fonts.index(0x41, .regular, nil), symbol = fonts.index(0xF07B, .regular, nil)
            let names = [text, symbol].map { found in found.map { fonts.faces[$0.style.rawValue][$0.idx].entry.name } }
            results.set(i, names.map { $0 ?? "none" })
        }
        XCTAssertEqual(results.values, Array(repeating: ["JetBrains Mono", "Symbols Nerd Font"], count: 8))
        XCTAssertEqual(FontCollection.bundledFontReads, reads)
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[String]]

    init(count: Int) { stored = Array(repeating: [], count: count) }

    var values: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ index: Int, _ value: [String]) {
        lock.lock()
        stored[index] = value
        lock.unlock()
    }
}
