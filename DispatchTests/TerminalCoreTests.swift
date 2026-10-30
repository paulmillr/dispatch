import XCTest
@_spi(Test) import Term

/// Regression sequences from Ghostty 1.4, exercised through the Swift stream and surface.
final class TerminalCoreTests: XCTestCase {
    private func surface(_ options: TerminalOptions = TerminalOptions(cols: 20, rows: 10)) -> Surface {
        Surface(terminal: Terminal(options), options: HandlerOptions(),
                size: RenderSize(screen: (options.cols * 10, options.rows * 20), cell: (10, 20)),
                now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
    }

    private func feed(_ s: Surface, _ text: String) { feed(s, Array(text.utf8)) }
    private func feed(_ s: Surface, _ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { s.feed($0) } }
    private func reply(_ s: Surface) -> [UInt8] {
        var result: [UInt8] = []
        s.drain(reply: { result += $0 }, event: { _ in })
        return result
    }
    private func cursor(_ s: Surface) -> Cursor { s.terminal.view.primary.view.cursor }

    func testPasteProtectionRejectsBothLineEndingsBeforeWriting() throws {
        let s = surface()
        for text in ["a\rb", "a\nb", "a\r\nb", "\u{1B}[201~"] {
            let c = ClipboardCompletion(contents: [ClipboardContent(mime: Array("text/plain".utf8), data: Array(text.utf8))])
            XCTAssertThrowsError(try s.completeClipboard(.paste(.standard), c))
            XCTAssertEqual(reply(s), [])
        }
        feed(s, "\u{1B}[?2004h")
        let c = ClipboardCompletion(contents: [ClipboardContent(mime: Array("text/plain".utf8), data: Array("a\rb\nc".utf8))])
        try s.completeClipboard(.paste(.standard), c)
        XCTAssertEqual(reply(s), Array("\u{1B}[200~a\rb\nc\u{1B}[201~".utf8))
        let end = ClipboardCompletion(contents: [ClipboardContent(mime: Array("text/plain".utf8), data: Array("\u{1B}[201~".utf8))])
        XCTAssertThrowsError(try s.completeClipboard(.paste(.standard), end))
        XCTAssertEqual(reply(s), [])
        feed(s, "\u{1B}[?2004l")
        var approved = c; approved.confirmed = true
        try s.completeClipboard(.paste(.standard), approved)
        XCTAssertEqual(reply(s), Array("a\rb\rc".utf8))
    }

    func testLegacyKeyboardPreservesUnicodeAndModifyOtherKeys() {
        var e = KeyEvent(), o = KeyOptions()
        e.mods = .alt; o.altEscPrefix = true; o.optionAsAlt = .true
        for (text, cp): (String, UInt32) in [("é", 0xE9), ("界", 0x754C), ("😀", 0x1F600)] {
            e.utf8 = Array(text.utf8); e.unshiftedCodepoint = cp
            XCTAssertEqual(e.encode(o), [0x1B] + Array(text.utf8))
            e.utf8 = []
            XCTAssertEqual(e.encode(o), [0x1B] + Array(text.utf8))
        }
        e.utf8 = Array("é".utf8); e.unshiftedCodepoint = 0
        XCTAssertEqual(e.encode(o), [0x1B] + Array("é".utf8))
        e = KeyEvent(); e.key = .keyA; e.mods = .ctrl; e.utf8 = Array("a".utf8)
        o = KeyOptions()
        XCTAssertEqual(e.encode(o), [1])
        o.modifyOtherKeys2 = true
        XCTAssertEqual(e.encode(o), Array("\u{1B}[27;5;97~".utf8))
    }

    func testMouse1005EncodesTheButtonAsUTF8() {
        let t = Terminal(TerminalOptions(cols: 20, rows: 10))
        var o = MouseOptions(t, size: RenderSize(screen: (200, 200), cell: (10, 20)))
        o.event = .normal; o.format = .utf8
        var last: (x: Int, y: Int)?
        let e = MouseEvent(action: .press, button: .eight, mods: [], x: 1, y: 1)
        XCTAssertEqual(e.encode(o, lastCell: &last), [0x1B, 0x5B, 0x4D, 0xC2, 0xA0, 33, 33])
    }

    func testReportsKeepModeNumbersAndRespectOrigin() {
        let s = surface()
        feed(s, "\u{1B}[?40000$p\u{1B}[1$p\u{1B}[4$p\u{1B}[19t")
        XCTAssertEqual(reply(s), Array("\u{1B}[?40000;0$y\u{1B}[1;4$y\u{1B}[4;2$y\u{1B}[9;10;20t".utf8))
        feed(s, "\u{1B}[3;8r\u{1B}[?6h\u{1B}[2;4H\u{1B}[?6n\u{1B}[6n")
        XCTAssertEqual(reply(s), Array("\u{1B}[?2;4;1R\u{1B}[2;4R".utf8))
    }

    func testSoftResetPreservesContentsAndUnrelatedState() {
        let s = surface()
        feed(s, "hello\u{1B}[9G\u{1B}[g\u{1B}]4;1;#123456\u{07}\u{1B}]10;#123456\u{07}")
        XCTAssertFalse(s.terminal.view.tabstops[8])
        feed(s, "\u{1B}[?2004h\u{1B}[?6h\u{1B}[4h\u{1B}[1m\u{1B}[2;4H\u{1B}7\u{1B}[!p")
        XCTAssertEqual((cursor(s).x), 3); XCTAssertEqual(cursor(s).y, 1)
        XCTAssertFalse(cursor(s).style.flags.bold)
        XCTAssertFalse(s.terminal.view.modes.get(Mode("origin")))
        XCTAssertFalse(s.terminal.view.modes.get(Mode("insert")))
        XCTAssertTrue(s.terminal.view.modes.get(Mode("bracketed_paste")))
        XCTAssertFalse(s.terminal.view.colors.palette.mask[1])
        XCTAssertNotNil(s.terminal.view.colors.foreground.override)
        XCTAssertFalse(s.terminal.view.tabstops[8])
        XCTAssertTrue(String(decoding: s.readText(.active), as: UTF8.self).hasPrefix("hello"))
        feed(s, "\u{1B}8")
        XCTAssertEqual(cursor(s).x, 0); XCTAssertEqual(cursor(s).y, 0)
        feed(s, "\u{1B}]4;1;#123456\u{07}\u{1B}c")
        XCTAssertFalse(s.terminal.view.colors.palette.mask[1])
    }

    func testCancelledStringsNeverApplyAndParserRecoversAcrossChunks() {
        for split in [false, true] {
            for cancel: UInt8 in [0x18, 0x1A] {
                let s = surface()
                let bytes = Array("\u{1B}]2;cancelled".utf8) + [cancel]
                    + Array("\u{1B}]52;c;Zm9v".utf8) + [cancel]
                    + Array("\u{1B}_Ga=q,i=123,s=1,v=1,f=24;AAAA".utf8) + [cancel]
                if split { for byte in bytes { feed(s, [byte]) } } else { feed(s, bytes) }
                XCTAssertEqual(s.terminal.view.title, [])
                XCTAssertEqual(reply(s), [])
                var clipboardWrites = 0
                s.takeMessages { if case .clipboardWrite = $0 { clipboardWrites += 1 } }
                XCTAssertEqual(clipboardWrites, 0)
                feed(s, "\u{1B}]2;valid\u{07}\u{1B}_Ga=q,i=124,s=1,v=1,f=24;AAAA\u{1B}\\")
                XCTAssertEqual(s.terminal.view.title, Array("valid".utf8))
                XCTAssertEqual(reply(s), Array("\u{1B}_Gi=124;OK\u{1B}\\".utf8))
            }
        }
    }

    func testCursorBackwardStopsAtMarginUnlessAlreadyOutside() {
        let s = surface()
        feed(s, "\u{1B}[?69h\u{1B}[5;15s\u{1B}[1;5H\u{1B}[D\u{08}")
        XCTAssertEqual(cursor(s).x, 4)
        feed(s, "\u{1B}[1;3H\u{1B}[99D")
        XCTAssertEqual(cursor(s).x, 0)
    }

    func testClearingScrollbackRebuildsCursorReferencesAfterPruning() throws {
        var options = TerminalOptions(cols: 10, rows: 3)
        options.maxScrollbackBytes = nil; options.maxScrollbackLines = 0
        let s = surface(options), screen = s.terminal.view.primary
        let rows = Int(try XCTUnwrap(screen.pageChain.first).capacity.rows)
        feed(s, String(repeating: "x\r\n", count: rows + 1) + "x")
        XCTAssertGreaterThan(screen.pageChain.count, 1)
        feed(s, "\u{1B}[H\u{1B}[1m\u{1B}]8;;https://example.com\u{1B}\\\u{1B}[22JY")
        let p = try XCTUnwrap(screen.pin(.active, x: 0, y: 0)), cell = p.page.cell(p.cell)
        XCTAssertEqual(cell.codepoint, 89)
        XCTAssertTrue(p.page.style(cell.styleID).flags.bold)
        let link = try XCTUnwrap(p.page.hyperlink(p.cell))
        XCTAssertEqual(p.page.link(id: link).uri, Array("https://example.com".utf8))
    }

    func testSingleRowScrollingKeepsCursorStyleAndHyperlink() throws {
        var options = TerminalOptions(cols: 3, rows: 1)
        options.maxScrollbackBytes = nil; options.maxScrollbackLines = 0
        let s = surface(options), screen = s.terminal.view.primary
        feed(s, "\u{1B}[1m\u{1B}]8;;https://example.com\u{1B}\\" + String(repeating: "a", count: 103))
        s.terminal.resize(cols: 80, rows: 1)
        let x = cursor(s).x
        let before = try XCTUnwrap(screen.pin(.active, x: x, y: 0))
        let scrolls = Int(before.page.capacity.rows) - before.page.state.rows + 1
        feed(s, String(repeating: "\n", count: scrolls) + "Y")
        let p = try XCTUnwrap(screen.pin(.active, x: x, y: 0)), cell = p.page.cell(p.cell)
        XCTAssertEqual(cell.codepoint, 89)
        XCTAssertTrue(p.page.style(cell.styleID).flags.bold)
        let link = try XCTUnwrap(p.page.hyperlink(p.cell))
        XCTAssertEqual(p.page.link(id: link).uri, Array("https://example.com".utf8))
    }
}
