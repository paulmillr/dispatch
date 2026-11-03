import XCTest
@_spi(Test) import Term
@_spi(Test) import TermApple
@testable import DispatchApp

/// scrollback-limit-lines (Ghostty's key): lines a new terminal keeps besides its screen, with the byte limit beside
/// it (the first one reached drops the oldest lines); unset, nothing changes. Settings offers it as line counts.
@MainActor
final class ScrollbackLineLimitTests: XCTestCase {
    func testConfigReadsTheLineLimitLikeGhostty() {
        XCTAssertNil(SwiftEngine.parse("", dark: true).scrollbackLimitLines, "unlimited by default")
        XCTAssertEqual(SwiftEngine.parse("scrollback-limit-lines = 1000", dark: true).scrollbackLimitLines, 1000)
        XCTAssertEqual(SwiftEngine.parse("scrollback-limit-lines = 0x10", dark: true).scrollbackLimitLines, 16)
        XCTAssertNil(SwiftEngine.parse("scrollback-limit-lines = 5\nscrollback-limit-lines = unlimited", dark: true).scrollbackLimitLines)
        XCTAssertNil(SwiftEngine.parse("scrollback-limit-lines = 5\nscrollback-limit-lines =", dark: true).scrollbackLimitLines, "empty: the default")
        let bad = SwiftEngine.parse("scrollback-limit-lines = lots", dark: true)
        XCTAssertEqual(bad.diagnostics.map(\.key), ["scrollback-limit-lines"])
        XCTAssertNil(bad.scrollbackLimitLines)
        XCTAssertEqual(SwiftEngine.parse("scrollback-limit-lines = 7", dark: true).scrollbackLimitBytes, 50_000_000, "the byte limit stays")
    }

    /// The lines of history a new terminal with `config` keeps after 20,000 numbered lines, and its screen's rows.
    private func kept(_ config: String) throws -> (lines: [Substring], rows: Int) {
        let session = try Session(config: SwiftEngine.parse(config, dark: true), scale: 1, machine: System.machine.launch)
        defer { session.close() }
        session.setSize(width: 800, height: 600)
        let output = Array((1...20_000).map { "line \($0)\r\n" }.joined().utf8)
        return session.locked {
            output.withUnsafeBufferPointer { session.surface.feed($0) }
            let text = String(decoding: session.surface.readPrimaryText(), as: UTF8.self)
            return (text.split(separator: "\n").filter { $0.hasPrefix("line ") }, session.surface.terminal.grid.rows)
        }
    }

    func testANewTerminalKeepsTheLinesOfItsLimit() throws {
        let all = try kept("")
        XCTAssertEqual(all.lines.count, 20_000, "no line limit: as before")
        let limited = try kept("scrollback-limit-lines = 1000")
        // Whole pages go: up to the limit besides the screen (its last row is empty), at most a page fewer.
        XCTAssertLessThanOrEqual(limited.lines.count, 1000 + limited.rows - 1)
        XCTAssertGreaterThan(limited.lines.count, 100 + limited.rows)
        XCTAssertEqual(limited.lines.last, "line 20000", "the newest lines stay")
        XCTAssertEqual(limited.lines.first.flatMap { Int($0.dropFirst(5)) }, 20_000 - limited.lines.count + 1, "contiguous")
        // With both limits the first one reached decides.
        let bytes = try kept("scrollback-limit-bytes = 1000000\nscrollback-limit-lines = 15000")
        XCTAssertLessThan(bytes.lines.count, 15_000)
        XCTAssertEqual(bytes.lines.count, try kept("scrollback-limit-bytes = 1000000").lines.count, "the byte limit first")
        XCTAssertEqual(try kept("scrollback-limit-bytes = 5000000\nscrollback-limit-lines = 1000").lines.count, limited.lines.count, "the line limit first")
    }

    func testSettingsOfferLineCountsWithinTheMemoryLimit() throws {
        XCTAssertEqual(Scrollback.lines10k.limit(automatic: 123), "123", "a line count keeps the automatic size")
        XCTAssertEqual(Scrollback.lines100k.lines, 100_000)
        XCTAssertNil(Scrollback.automatic.lines)
        XCTAssertEqual(Scrollback.sizes + Scrollback.lineCounts, Scrollback.allCases)
        var preferences = Preferences()
        preferences.scrollback = .lines10k
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).scrollback, .lines10k)
        let config = SettingsExport.ghosttyConfig(preferences)
        XCTAssertTrue(config.contains("scrollback-limit-lines = 10000\n"))
        XCTAssertFalse(config.contains("scrollback-limit-bytes"))
        // Dispatch's export reads back as itself; another line count by its size, as before.
        func imported(_ text: String) -> Scrollback {
            var p = Preferences()
            for change in GhosttyImport.plan(text: text, fonts: [], theme: { _ in nil }).changes { change.apply(&p) }
            return p.scrollback
        }
        XCTAssertEqual(imported(config), .lines10k)
        XCTAssertEqual(imported("scrollback-limit-lines = 100000"), .lines100k)
        XCTAssertEqual(imported("scrollback-limit-lines = 5000"), .small)
    }
}
