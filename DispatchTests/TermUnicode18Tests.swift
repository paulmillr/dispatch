import XCTest
@_spi(Test) import Term

/// Unicode 18 in the Swift terminal (tables from uucode ea62149, as Ghostty 1.4): widths of newly
/// assigned characters, the revised Indic conjunct rule (GB9c), and how the terminal lays them out.
final class TermUnicode18Tests: XCTestCase {
    private func surface() -> Surface {
        let options = TerminalOptions(cols: 20, rows: 4)
        return Surface(terminal: Terminal(options), options: HandlerOptions(),
                       size: RenderSize(screen: (options.cols * 10, options.rows * 20), cell: (10, 20)),
                       now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
    }

    private func breaks(_ cps: [UInt32]) -> [Bool] {
        var state: UInt8 = 0
        return zip(cps, cps.dropFirst()).map { Unicode.graphemeBreak($0, $1, &state) }
    }

    func testNewlyAssignedCharactersHaveTheirUnicode18Widths() {
        // New emoji (default emoji presentation), Tangut Components Supplement and a Jurchen character: wide.
        for cp: UInt32 in [0x1F6D9, 0x1FA8B, 0x1FAEB, 0x1FAF9, 0x18CD6, 0x18E00] {
            XCTAssertEqual(Unicode.props(cp).width, 2, String(cp, radix: 16))
        }
        XCTAssertTrue(Unicode.isEmojiPresentation(0x1F6D9))
        // A new Hebrew combining mark: zero width.
        XCTAssertEqual(Unicode.props(0x05C8).width, 0)
        // Unchanged: ASCII, CJK, an emoji, a combining accent.
        XCTAssertEqual([0x61, 0x4E00, 0x1F600, 0x0301].map { Unicode.props($0).width }, [1, 2, 2, 0])
    }

    func testGraphemeBreaksFollowUnicode18() {
        // GB9c no longer needs a leading consonant: Linker Extend* x Consonant.
        XCTAssertEqual(breaks([0x61, 0x094D, 0x0915]), [false, false])
        XCTAssertEqual(breaks([0x0915, 0x094D, 0x0300, 0x0915]), [false, false, false])
        // An extend without a linker does not join a consonant; a consonant ends the linker sequence.
        XCTAssertEqual(breaks([0x0915, 0x0300, 0x0915]), [false, true])
        XCTAssertEqual(breaks([0x094D, 0x0915, 0x0300, 0x0915]), [false, false, true])
        // InCB=Linker with Grapheme_Cluster_Break=Other breaks before it but joins the next consonant.
        XCTAssertEqual(breaks([0x61, 0x1CF5, 0x0300, 0x0915]), [true, false, false])
        // A linker inside an emoji sequence still leads to a ZWJ emoji.
        XCTAssertEqual(breaks([0x1F600, 0x094D, 0x0300, 0x200D, 0x1F600]), [false, false, false, false])
        // A new emoji modifier base takes a skin tone; flags, ZWJ sequences and Hangul are unchanged.
        XCTAssertEqual(breaks([0x1FAF9, 0x1F3FB]), [false])
        XCTAssertEqual(breaks([0x1F1E8, 0x1F1ED, 0x1F1E8, 0x1F1ED]), [false, true, false])
        XCTAssertEqual(breaks([0x1F469, 0x200D, 0x1F680]), [false, false])
        XCTAssertEqual(breaks([0x1100, 0x1161, 0x11A8]), [false, false])
    }

    func testTerminalLaysOutUnicode18TextAndCopiesItBack() throws {
        for (text, cells) in [("\u{1F6D9}", 2), ("\u{18CD6}", 2), ("a\u{094D}\u{0915}", 2), ("\u{1FAF9}\u{1F3FB}", 2), ("\u{05D0}\u{05C8}", 1)] {
            let s = surface(), screen = s.terminal.view.primary
            Array((text + "x").utf8).withUnsafeBufferPointer { s.feed($0) }
            XCTAssertEqual(screen.view.cursor.x, cells + 1, text)
            // The whole text is one cell's grapheme, and selecting the row gives it back.
            let p = try XCTUnwrap(screen.pin(.active, x: 0, y: 0))
            let scalars = [p.page.cell(p.cell).codepoint] + (p.page.grapheme(p.cell).map { Array($0) } ?? [])
            XCTAssertEqual(scalars, text.unicodeScalars.map(\.value), text)
            let row = Selection(p, try XCTUnwrap(screen.pin(.active, x: 19, y: 0)))
            XCTAssertEqual(String(decoding: screen.selectionString(row, trim: true), as: UTF8.self), text + "x")
        }
    }
}
