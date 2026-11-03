import XCTest
@_spi(Test) import Term
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

/// DECRQCRA and XTCHECKSUM as Ghostty 1.4 answers them (xterm's xtermCheckRect): only when vt-xt-checksum-report
/// allows it, since a program could read the screen back cell by cell. Expected sums are Ghostty's test cases.
final class TerminalChecksumTests: XCTestCase {
    private func surface(reports: Bool = true) -> Surface {
        var options = HandlerOptions()
        options.checksumReports = reports
        return Surface(terminal: Terminal(TerminalOptions(cols: 10, rows: 5)), options: options,
                       size: RenderSize(screen: (100, 100), cell: (10, 20)), now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
    }

    private func feed(_ s: Surface, _ text: String) { Array(text.utf8).withUnsafeBufferPointer { s.feed($0) } }

    private func replies(_ s: Surface) -> String {
        var out: [UInt8] = []
        s.drain(reply: { out += $0 }, event: { _ in })
        return String(decoding: out, as: UTF8.self)
    }

    /// The sum of a rectangle (`Pt;Pl;Pb;Pr`, empty: defaults) with XTCHECKSUM `flags`.
    private func sum(_ s: Surface, _ rect: String = "", flags: Int = 1) -> UInt16? {
        _ = replies(s)
        feed(s, "\u{1B}[\(flags)#y\u{1B}[9;1;\(rect)*y")
        let reply = replies(s)
        guard reply.hasPrefix("\u{1B}P9!~"), reply.hasSuffix("\u{1B}\\"), reply.count == 11 else { return nil }
        return UInt16(reply.dropFirst(5).prefix(4), radix: 16)
    }

    func testRepliesOnlyWhenAllowed() {
        let off = surface(reports: false)
        feed(off, "hello\u{1B}[1#y\u{1B}[1;1;1;1;1;5*y")
        XCTAssertEqual(replies(off), "")
        let s = surface()
        // "hello" sums to 0x214, which the DEC checksum negates; XTCHECKSUM 1 keeps it; a full reset restores DEC.
        feed(s, "hello\u{1B}[3;1;1;1;1;5*y")
        XCTAssertEqual(replies(s), "\u{1B}P3!~FDEC\u{1B}\\")
        feed(s, "\u{1B}[1#y\u{1B}[4;1;1;1;1;5*y")
        XCTAssertEqual(replies(s), "\u{1B}P4!~0214\u{1B}\\")
        feed(s, "\u{1B}chello\u{1B}[5;1;1;1;1;5*y")
        XCTAssertEqual(replies(s), "\u{1B}P5!~FDEC\u{1B}\\")
        // Too many parameters, another or no intermediate: no reply; XTCHECKSUM with two parameters changes nothing.
        feed(s, "\u{1B}[1;1;1;1;1;1;1*y\u{1B}[1;1;1;1;1;1y\u{1B}[1;1;1;1;1;1\"y")
        XCTAssertEqual(replies(s), "")
        feed(s, "\u{1B}[1;2#y\u{1B}[6;1;1;1;1;5*y")
        XCTAssertEqual(replies(s), "\u{1B}P6!~FDEC\u{1B}\\")
    }

    func testBlanksUndrawnCellsAndBounds() {
        var s = surface()
        feed(s, "a b")
        XCTAssertEqual(sum(s, "1;;1"), 0x61 + 0x62, "DEC trims blanks, skips undrawn cells")
        XCTAssertEqual(sum(s, "1;;1", flags: 1 | 4), 0x61 + 0x62 + 0x20 * 8)
        XCTAssertEqual(sum(s, "1;;1", flags: 1 | 8), 0x61 + 0x62)
        s = surface()
        feed(s, " a\r\n b")
        XCTAssertEqual(sum(s), 0x20 + 0x61 + 0x62, "a leading space counts")
        s = surface()
        feed(s, "abc")
        XCTAssertEqual(sum(s, ";3;;2", flags: 0), 0, "an empty rectangle")
        s = surface()
        feed(s, "abc\r\ndef\r\nghi")
        XCTAssertEqual(sum(s, "2;2;3;3"), 0x65 + 0x66 + 0x68 + 0x69)
        XCTAssertEqual(sum(s, "2;2;99;99"), 0x65 + 0x66 + 0x68 + 0x69, "clamped to the screen")
        // Origin mode: relative to the scrolling region.
        s = surface()
        feed(s, "\u{1B}[2;4r\u{1B}[?6h\u{1B}[1;1Hx\u{1B}[H")
        XCTAssertEqual(sum(s, "1;1;1;1"), 0x78)
    }

    func testAttributesAndCharacters() {
        var s = surface()
        feed(s, "\u{1B}[1;4ma\u{1B}[0;7;5m \u{1B}[0;8m\u{1B}[1\"qb\u{1B}[0\"q")
        XCTAssertEqual(sum(s, "1;;1"), 0x61 + 0x80 + 0x10 + 0x20 + 0x20 + 0x40 + 0x62 + 0x08 + 0x04)
        XCTAssertEqual(sum(s, "1;;1", flags: 1 | 2), 0x61 + 0x62)
        s = surface()
        feed(s, "a\u{1B}[3m ")
        XCTAssertEqual(sum(s, "1;;1"), 0x61 + 0x20, "an italic space counts")
        s = surface()
        feed(s, "é€")
        XCTAssertEqual(sum(s, "1;;1"), 0x69 + 0x1B, "DEC 8-bit values")
        XCTAssertEqual(sum(s, "1;;1", flags: 1 | 16), 0xE9 + 0x20AC)
        s = surface()
        feed(s, "橋")
        XCTAssertEqual(sum(s, "1;;1"), 0x1B + 0x1B, "a wide character and its spacer")
        XCTAssertEqual(sum(s, "1;;1", flags: 1 | 16), 0x6A4B)
        s = surface()
        feed(s, "\u{1B}[?2027he\u{301}")
        XCTAssertEqual(sum(s, "1;;1;1"), 0x65)
        XCTAssertEqual(sum(s, "1;;1;1", flags: 1 | 4), 0x65 + 0x301, "combining marks in the untrimmed DEC sum")
        XCTAssertEqual(sum(s, "1;;1;1", flags: 1 | 4 | 16), 0x65)
    }

    func testConfigEnablesReports() {
        func config(_ text: String) -> Config { var c = Config(); c.load(Array(text.utf8)); return c }
        XCTAssertFalse(config("").checksumReports)
        XCTAssertTrue(config("vt-xt-checksum-report = true").checksumReports)
        XCTAssertFalse(config("vt-xt-checksum-report = true\nvt-xt-checksum-report = false").checksumReports)
        XCTAssertEqual(config("vt-xt-checksum-report = maybe").diagnostics.map(\.key), ["vt-xt-checksum-report"])
        XCTAssertTrue(config("vt-xt-checksum-report = true").diagnostics.isEmpty)
    }
}

extension TerminalChecksumTests {
    /// The apps write the key off themselves, after the theme: a theme file cannot turn reports on.
    @MainActor func testAThemeCannotTurnReportsOn() throws {
        let sneaky: (String, inout [String]) -> [UInt8]? = { _, _ in Array("vt-xt-checksum-report = true\n".utf8) }
        var unguarded = Config()
        unguarded.load(Array("theme = sneaky\n".utf8))
        unguarded.finalize(dark: true, theme: sneaky)
        XCTAssertTrue(unguarded.checksumReports, "a theme's lines apply unless the config sets the key itself")
        #if canImport(AppKit)
        let text = try TerminalRuntime.shared.makeConfig(Preferences())
        #else
        let text = TerminalConfiguration().text
        #endif
        XCTAssertTrue(text.contains("\nvt-xt-checksum-report = false\n"))
        var app = Config()
        app.load(Array(text.replacingOccurrences(of: "\ntheme = ", with: "\ntheme = sneaky\n# was ").utf8))
        app.finalize(dark: true, theme: sneaky)
        XCTAssertFalse(app.checksumReports)
    }
}
