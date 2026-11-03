import XCTest
@_spi(Test) import Term

/// The terminal's batched paths against their one-at-a-time meaning: SGR direct colours, rows
/// rotated by scrolling (across page boundaries), REP and printSlice against print, rejected OSC
/// payloads skipped in bulk, and chunking (any split of a stream leaves the same terminal).
final class TerminalFastPathTests: XCTestCase {
    private func surface(_ cols: Int, _ rows: Int, scrollback: Int? = 50_000_000) -> Surface {
        var options = TerminalOptions(cols: cols, rows: rows)
        options.maxScrollbackBytes = scrollback
        return Surface(terminal: Terminal(options), options: HandlerOptions(),
                       size: RenderSize(screen: (cols * 10, rows * 20), cell: (10, 20)),
                       now: { 0 }, entropy: { [UInt8](repeating: 1, count: $0) })
    }

    private func feed(_ s: Surface, _ text: String) { feed(s, Array(text.utf8)) }
    private func feed(_ s: Surface, _ bytes: [UInt8]) { bytes.withUnsafeBufferPointer { s.feed($0) } }
    private func reply(_ s: Surface) -> [UInt8] {
        var result: [UInt8] = []
        s.drain(reply: { result += $0 }, event: { _ in })
        return result
    }

    /// A seeded generator (SplitMix64): every run sees the same cases.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ z >> 30) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ z >> 27) &* 0x94D0_49BB_1331_11EB
            return z ^ z >> 31
        }
        mutating func next(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
        mutating func pick<T>(_ a: [T]) -> T { a[next(0...a.count - 1)] }
    }

    /// Everything a stream leaves in the terminal, as numbers: the cursors, then both screens'
    /// every page (history included) with its ref counts, row flags (not the cells offset or the
    /// renderer's dirty bit), cells (style values, not ids), graphemes and links. Not `full`: the
    /// active screen's cursor and active area only.
    private func state(_ t: Terminal, full: Bool = true) -> [UInt64] {
        let v = t.view
        var out: [UInt64] = [v.isAlternate ? 1 : 0, UInt64(v.previousChar ?? 0xFFFF_FFFF)]
        func row(_ p: Page, _ y: Int) {
            out.append(p.row(y).bits >> 32 & ~(1 << 8))
            for x in 0..<p.size.cols {
                let at = p.cellAt(y, x), cell = p.cell(at)
                out.append(cell.bits & ~(0xFFFF << 26))
                if cell.styleID != 0 { out.append(p.style(cell.styleID).hash) }
                if cell.hasGrapheme, let g = p.grapheme(at) { for cp in g { out.append(UInt64(cp)) } }
                if cell.hyperlink, let id = p.hyperlink(at) { out += p.link(id: id).uri.map { UInt64($0) } }
            }
        }
        let screens = full ? [v.primary, v.alternate].compactMap { $0 } : [v.isAlternate ? v.alternate! : v.primary]
        for screen in screens {
            let c = screen.view.cursor
            out += [UInt64(c.x), UInt64(c.y), c.pendingWrap ? 1 : 0, c.style.hash]
            guard full else {
                for y in 0..<t.grid.rows { if let p = screen.pin(.active, x: 0, y: y) { row(p.page, p.y) } }
                continue
            }
            out.append(UInt64(screen.pageChain.count))
            for p in screen.pageChain {
                let s = p.state
                out += [s.rows, p.size.cols, s.styles.living, s.styles.refs, s.links.living, s.links.refs,
                        s.graphemeMap, s.hyperlinkMap, s.graphemeBytes, s.stringBytes].map { UInt64($0) }
                for y in 0..<p.size.rows { row(p, y) }
            }
        }
        return out
    }

    private func assertSameState(_ a: Surface, _ b: Surface, full: Bool = true, _ context: @autoclosure () -> String, line: UInt = #line) -> Bool {
        let (x, y) = (state(a.terminal, full: full), state(b.terminal, full: full))
        guard x != y else { return true }
        let at = (0..<min(x.count, y.count)).first { x[$0] != y[$0] } ?? min(x.count, y.count)
        XCTFail("states differ at \(at) of \(x.count)/\(y.count): \(context())", line: line)
        return false
    }

    /// Row y of the active area as text (empty cells as spaces, trailing ones dropped), or only
    /// its first `prefix` cells and its last one ("first|last").
    private func row(_ s: Surface, _ y: Int, cols: Int, prefix: Int? = nil) -> String {
        let screen = s.terminal.view.isAlternate ? s.terminal.view.alternate! : s.terminal.view.primary
        guard let p = screen.pin(.active, x: 0, y: y) else { return "<no row \(y)>" }
        func text(_ xs: Range<Int>) -> String {
            var t = ""
            for x in xs { let cp = p.page.cell(p.page.cellAt(p.y, x)).codepoint; t.unicodeScalars.append(cp == 0 ? " " : Swift.Unicode.Scalar(cp)!) }
            while t.last == " " { t.removeLast() }
            return t
        }
        guard let prefix else { return text(0..<cols) }
        return text(0..<prefix) + "|" + text(cols - 1..<cols)
    }

    // MARK: SGR

    func testSGRDirectColourFormsAndMalformedParameters() {
        func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Style.Color { .rgb(RGB(r: r, g: g, b: b)) }
        func style(fg: Style.Color = .none, bg: Style.Color = .none, ul: Style.Color = .none, _ flags: (inout Style.Flags) -> Void = { _ in }) -> Style {
            var f = Style.Flags()
            flags(&f)
            return Style(fgColor: fg, bgColor: bg, underlineColor: ul, flags: f)
        }
        let cases: [(String, Style)] = [
            ("38;2;1;2;3", style(fg: rgb(1, 2, 3))),
            ("38:2:1:2:3", style(fg: rgb(1, 2, 3))),
            ("38:2::1:2:3", style(fg: rgb(1, 2, 3))),             // empty colour space
            ("38:2:9:1:2:3", style(fg: rgb(1, 2, 3))),            // colour space id
            ("48:2:1:2:3;1", style(bg: rgb(1, 2, 3)) { $0.bold = true }),
            ("58:2::4:5:6;3", style(ul: rgb(4, 5, 6)) { $0.italic = true }),
            ("38;2;300;400;500", style(fg: rgb(44, 144, 244))),   // truncated to bytes
            ("1;38:2:1:2:3:4:5;3", style { $0.bold = true; $0.italic = true }),   // 5 colon params: unknown, skipped
            ("38:2:1:2;3", style { $0.italic = true }),           // 2 colon params: unknown, skipped
            ("38:2:1;3", style { $0.italic = true }),
            ("38;2;1;2", style { $0.faint = true; $0.bold = true }),   // too short: the rest are attributes
            ("38;2", style { $0.faint = true }),
            ("38;5;200;1", style(fg: .palette(200)) { $0.bold = true }),
            ("38:5:200", style(fg: .palette(200))),
            ("48;5", style { $0.blink = true }),
            ("58;5;7", style(ul: .palette(7))),
            ("4:3", style { $0.underline = .curly }),
            ("4:3:1;9", style { $0.strikethrough = true }),      // a colon run after 4:x: unknown
            ("1;;3", style { $0.italic = true }),                 // an empty parameter is 0
            ("1:2;3", style { $0.italic = true }),                // colons on a plain attribute
        ]
        for (params, expected) in cases {
            let s = surface(20, 2)
            feed(s, "\u{1B}[\(params)mX")
            let cursor = s.terminal.view.primary.view.cursor
            XCTAssertEqual(cursor.style, expected, params)
            let screen = s.terminal.view.primary
            let p = screen.pin(.active, x: 0, y: 0)!
            XCTAssertEqual(p.page.style(p.page.cell(p.cell).styleID), expected, params)
        }
    }

    // MARK: Scrolling

    /// Region scrolling (IND at the bottom margin, RI at the top, SU, SD, IL, DL) against a model of
    /// the rows, on both screens, with and without history, wide rows (small pages: the active area
    /// always spans several) and one-row screens. Every rotation path is counted where its page
    /// boundary condition holds: IND under a top margin 0 with history and a page boundary below the
    /// bottom margin (Screen.scrollAboveRotate rotates each page down), IND in a region spanning a
    /// page boundary (PageList.eraseRow, bounded, across pages), and a one-row screen (region bottom 0).
    func testRegionScrollingMatchesARowModelAcrossPageBoundaries() throws {
        // (cols, rows, scrollback, alternate, kind): the path each case must reach.
        enum Path { case none, aboveAcrossPages, regionAcrossPages, oneRow }
        let cases: [(Int, Int, Int, Bool, Path)] = [
            (8, 9, 50_000_000, false, .none), (1000, 100, 2_000_000, false, .aboveAcrossPages), (1000, 100, 0, false, .regionAcrossPages),
            (1000, 100, 0, true, .regionAcrossPages), (8, 9, 0, true, .none), (8, 1, 50_000_000, false, .oneRow), (1000, 1, 0, false, .oneRow),
        ]
        for (cols, rows, scrollback, alternate, path) in cases {
            let s = surface(cols, rows, scrollback: scrollback)
            if alternate { feed(s, "\u{1B}[?1049h") }
            let screen = alternate ? try XCTUnwrap(s.terminal.view.alternate) : s.terminal.view.primary
            /// Rows a and b of the active area on different pages: a row's index in its page grows by
            /// one per row only within a page.
            func spans(_ a: Int, _ b: Int) -> Bool {
                guard let p = screen.pin(.active, x: 0, y: a), let q = screen.pin(.active, x: 0, y: b) else { return false }
                return q.y - p.y != b - a
            }
            var reached = 0
            // The model: each row's label ("" for a blank row); a row shows "label|#" (its label
            // first, a mark in its last cell) or "|".
            var model = [String](repeating: "", count: rows), label = 0
            func write(_ y: Int) {
                label += 1
                model[y] = "R" + String(label, radix: 36)
                feed(s, "\u{1B}[\(y + 1);1H\(model[y])\u{1B}[K\u{1B}[\(y + 1);\(cols)H#")
            }
            for y in 0..<rows { write(y) }
            var (t, b) = (0, rows - 1)
            func up(_ from: Int, _ n: Int) { for _ in 0..<min(n, b - from + 1) { model.remove(at: from); model.insert("", at: b) } }
            func down(_ from: Int, _ n: Int) { for _ in 0..<min(n, b - from + 1) { model.remove(at: b); model.insert("", at: from) } }
            var rng = Seeded(state: UInt64(cols * rows + (alternate ? 1 : 0)))
            /// IND at the bottom margin (often with a label there first, so rows that should move
            /// are not all blank), counted when this case's path is taken with its condition.
            func index(_ n: Int) {
                for _ in 0..<n {
                    if rng.next(0...1) == 0 { write(b) }
                    feed(s, "\u{1B}[\(b + 1);1H")
                    switch path {
                    case .aboveAcrossPages: if t == 0, b < rows - 1, spans(b, rows - 1) { reached += 1 }
                    case .regionAcrossPages: if b < rows - 1 || t > 0, spans(t, b) { reached += 1 }
                    case .oneRow: reached += 1
                    case .none: break
                    }
                    feed(s, "\n")
                    up(t, 1)
                }
            }
            for step in 0..<300 {
                let op: String
                switch rng.next(0...9) {
                case 0 where rows > 1:
                    switch rng.next(0...3) {
                    case 0: (t, b) = (0, rows - 1)
                    case 1: (t, b) = (0, rng.next(1...rows - 2))   // top margin 0 above the last row
                    default: t = rng.next(0...rows - 2); b = rng.next(t + 1...rows - 1)
                    }
                    op = "DECSTBM"
                    feed(s, "\u{1B}[\(t + 1);\(b + 1)r")
                case 1: op = "IND"; index(1)
                case 2: op = "RI"; feed(s, "\u{1B}[\(t + 1);1H\u{1B}M"); down(t, 1)
                case 3: let n = rng.next(0...4); op = "SU \(n)"; feed(s, "\u{1B}[\(n)S"); up(t, n)
                case 4: let n = rng.next(0...4); op = "SD \(n)"; feed(s, "\u{1B}[\(n)T"); down(t, n)
                case 5:
                    let (y, n) = (rng.next(t...b), rng.next(1...4)); op = "IL \(y) \(n)"
                    feed(s, "\u{1B}[\(y + 1);1H\u{1B}[\(n)L"); down(y, n)
                case 6:
                    let (y, n) = (rng.next(t...b), rng.next(1...4)); op = "DL \(y) \(n)"
                    feed(s, "\u{1B}[\(y + 1);1H\u{1B}[\(n)M"); up(y, n)
                case 7: let n = rng.next(1...rows + 1); op = "IND x\(n)"; index(n)
                default: let y = rng.next(0...rows - 1); op = "write \(y)"; write(y)
                }
                let actual = (0..<rows).map { row(s, $0, cols: cols, prefix: 7) }
                let expected = model.map { $0.isEmpty ? "|" : $0 + "|#" }
                guard actual == expected else {
                    XCTFail("\(cols)x\(rows) scrollback \(scrollback) alternate \(alternate), step \(step) \(op), region \(t)...\(b):\n\(actual)\n\(expected)")
                    break
                }
            }
            if path != .none { XCTAssertGreaterThanOrEqual(reached, 20, "\(cols)x\(rows) scrollback \(scrollback) alternate \(alternate): \(path) reached \(reached) times") }
        }
    }

    // MARK: REP and printSlice

    /// Ghostty's printSlice differential, with REP: one terminal prints every code point and every
    /// repeat through print; the other prints runs through printSlice in random chunks and repeats
    /// through printRepeat (or the stream's CSI b), among wrapping, margins, insert mode, wide and
    /// combining characters, grapheme clustering, charsets, hyperlinks, regions and both screens.
    func testBatchedPrintingMatchesPrintingOneAtATime() {
        let alphabet: [UInt32] = [0x61, 0x62, 0x5A, 0x30, 0x20, 0x10, 0x1F, 0x7F, 0xE9, 0xFF, 0x301, 0x4E00, 0x4E01, 0x1F600, 0x200D,
                                  0xFE0F, 0xFE0E, 0x78, 0x79, 0x1F9D1, 0x308, 0xAD, 0x3042, 0xAC00, 0x71, 0x72, 0x73, 0x74, 0x31, 0x32,
                                  0x1F1E6, 0x1F1E7, 0x1100, 0x1161, 0x11A8, 0x200C, 0x430, 0x3B1, 0x1F3FD, 0x2500, 0xFF57, 0x10EEEE]
        var rng = Seeded(state: 0xC0FFEE)
        for (cols, rows, ops) in [(80, 24, 200), (10, 4, 300), (5, 2, 300), (2, 2, 150), (1, 3, 100)] {
            let one = surface(cols, rows), batched = surface(cols, rows)
            var log: [String] = []
            for step in 0..<ops {
                switch rng.next(0...27) {
                case 0...7:
                    let cps = (0..<rng.next(1...64)).map { _ in rng.pick(alphabet) }
                    log.append("print \(cps.map { String($0, radix: 16) })")
                    for c in cps { one.terminal.print(c) }
                    var i = 0
                    while i < cps.count {
                        let n = rng.next(1...cps.count - i)
                        cps[i..<i + n].withUnsafeBufferPointer { batched.terminal.printSlice($0) }
                        i += n
                    }
                case 8...12:
                    let n = rng.pick([0, 1, 2, 3, cols - 1, cols, cols + 1, 2 * cols + 1, rng.next(1...300), 4095, 4096, 4097, 9000])
                    let viaStream = rng.next(0...1) == 0
                    log.append("rep \(n)\(viaStream ? " (CSI b)" : "")")
                    if let c = one.terminal.view.previousChar { for _ in 0..<max(n, 1) { one.terminal.print(c) } }
                    if viaStream { feed(batched, "\u{1B}[\(n)b") } else { batched.terminal.printRepeat(n) }
                default:
                    let e = rng.pick([
                        "\r\n", "\u{1B}[\(rng.next(1...rows));\(rng.next(1...cols))H", "\u{1B}[m", "\u{1B}[1m", "\u{1B}[31m",
                        "\u{1B}[38;2;\(rng.next(0...255));\(rng.next(0...255));\(rng.next(0...255))m", "\u{1B}[48:2::1:2:3m",
                        "\u{1B}[4h", "\u{1B}[4l", "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}[?2027h", "\u{1B}[?2027l",
                        "\u{1B}[?69h\u{1B}[\(rng.next(1...max(1, cols / 2)));\(rng.next(max(1, cols / 2)...cols))s", "\u{1B}[?69l",
                        "\u{1B}]8;;http://example.test/\(rng.next(0...3))\u{1B}\\", "\u{1B}]8;;\u{1B}\\",
                        "\u{1B}(0", "\u{1B}(B", "\u{1B}*0\u{1B}N", "\u{1B}[\(rng.next(1...rows));\(rng.next(1...rows))r", "\u{1B}[r",
                        "\u{1B}[?6h", "\u{1B}[?6l", "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[2J", "\u{1B}[K", "\u{1B}[\(rng.next(1...3))@",
                    ])
                    log.append("feed \(e.debugDescription)")
                    feed(one, e)
                    feed(batched, e)
                }
                // The active area after every step, everything (history, ref counts) every 25.
                guard assertSameState(one, batched, full: step % 25 == 24 || step == ops - 1, "\(cols)x\(rows) after \(log.suffix(4))") else { break }
            }
        }
    }

    // MARK: Rejected OSC

    /// Rejected OSC strings (unknown numbers, payloads past their limit) end at BEL, ST, CAN, SUB or
    /// ESC and ignore everything up to there (C0 controls included), split anywhere.
    func testRejectedOSCPayloadsEndAtTheirTerminatorsInEveryChunking() {
        // Unknown numbers (rejected at once), and payloads past their limit (2048 bytes for titles, pwd
        // and links, 4088 for 7501: rejected mid-payload), with C0 controls and UTF-8 after the cut.
        let x = String(repeating: "x", count: 20_000), past = String(repeating: "t", count: 3000) + "\u{08}\u{05}é界"
        let rejected = ["6;" + x, "999;abc", "abc;def", "3;x", "2;" + past, "0;" + past, "7;file://host.test/" + past, "8;;http://example.test/" + past,
                        "7501;" + String(repeating: "p", count: 5000) + "\u{08}\u{05}", "6;\u{05}\u{08}\u{1F}\u{7F}é" + x]
        let ends: [(String, String)] = [("\u{07}", "AB"), ("\u{1B}\\", "AB"), ("\u{18}", "AB"), ("\u{1A}", "AB"), ("\u{1B}[1m", "AB")]
        var rng = Seeded(state: 0x05C)
        for payload in rejected {
            for (end, shown) in ends {
                let bytes = Array("xy\u{1B}]\(payload)\(end)AB\u{1B}]2;ok\u{07}".utf8)
                let whole = surface(20, 3)
                feed(whole, bytes)
                XCTAssertEqual(row(whole, 0, cols: 20), "xy" + shown, "\(payload.prefix(8)) \(end.debugDescription)")
                XCTAssertEqual(whole.terminal.view.title, Array("ok".utf8))
                XCTAssertEqual(reply(whole), [])
                var splits = (0..<6).map { _ in rng.next(1...bytes.count - 1) }.sorted()
                if bytes.count < 64 { splits = Array(1..<bytes.count) }
                for at in splits {
                    let split = surface(20, 3)
                    feed(split, Array(bytes[..<at]))
                    feed(split, Array(bytes[at...]))
                    guard assertSameState(whole, split, "\(payload.prefix(8)) \(end.debugDescription) split at \(at)") else { break }
                }
                let bytewise = surface(20, 3)
                for b in bytes { feed(bytewise, [b]) }
                _ = assertSameState(whole, bytewise, "\(payload.prefix(8)) \(end.debugDescription) byte by byte")
            }
        }
    }

    // MARK: Chunking

    /// A stream mixing every path above (SGR forms, REP, accepted and rejected OSC, regions,
    /// both screens, replies, broken UTF-8) leaves the same terminal and replies however it is split.
    func testRandomChunkingKeepsTheTerminalAndItsReplies() {
        var rng = Seeded(state: 0xD15A7C)
        var stream: [UInt8] = []
        let pieces: [() -> [UInt8]] = [
            { Array("\u{1B}[\(rng.pick(["38:2::1:2:3", "38;2;9;8;7", "38:2:1:2", "48;5;99", "58:2:1:4:5:6", "4:3", "1;;3", "38;5", "0"]))m".utf8) },
            { Array("\(rng.pick(["a", "界", "é", "😀", "🇫", "\u{301}"]))\u{1B}[\(rng.pick([0, 1, 7, 80, 81, 300, 5000]))b".utf8) },
            { Array("\u{1B}]\(rng.pick(["6;", "999;", "2;", "8;;http://example.test/", "8;;", "4;1;?", "10;?"]))\(String(repeating: "p", count: rng.pick([0, 5, 3000, 9000])))\(rng.pick(["\u{07}", "\u{1B}\\", "\u{18}", "\u{1A}", "\u{1B}[m"]))".utf8) },
            { Array("\u{1B}[\(rng.next(1...6));\(rng.next(7...24))r\u{1B}[\(rng.next(1...24));1H\(String(repeating: "\n", count: rng.next(1...30)))\u{1B}M\u{1B}[\(rng.next(0...5))\(rng.pick(["S", "T", "L", "M"]))".utf8) },
            { Array(rng.pick(["\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[r", "\u{1B}[?2027h", "\u{1B}[?2027l", "\u{1B}[4h", "\u{1B}[4l", "\u{1B}[?7l", "\u{1B}[?7h"]).utf8) },
            { Array(rng.pick(["\u{1B}[6n", "\u{1B}[c", "\u{1B}P$qm\u{1B}\\", "\u{1B}[?6n", "\u{1B}[5n"]).utf8) },
            { rng.pick([[0xC3], [0xE2, 0x82], [0xF0, 0x9F, 0x98], [0xED, 0xA0, 0x80], [0xC0, 0xAF]]) },
            { Array("\(String(repeating: rng.pick(["text ", "wide 界 ", "é\u{301} "]), count: rng.next(1...40)))\r\n".utf8) },
        ]
        while stream.count < 400_000 { stream += rng.pick(pieces)() }
        for (cols, rows) in [(80, 24), (7, 5)] {
            let whole = surface(cols, rows)
            feed(whole, stream)
            let replies = reply(whole)
            XCTAssertFalse(replies.isEmpty)
            for maxChunk in [1, 3, 17, 300, 70_000] {
                let split = surface(cols, rows)
                var (i, replied): (Int, [UInt8]) = (0, [])
                while i < stream.count {
                    let n = min(stream.count - i, rng.next(1...maxChunk))
                    feed(split, Array(stream[i..<i + n]))
                    replied += reply(split)
                    i += n
                }
                XCTAssertEqual(replied, replies, "\(cols)x\(rows) chunks up to \(maxChunk)")
                _ = assertSameState(whole, split, "\(cols)x\(rows) chunks up to \(maxChunk)")
            }
        }
    }
}
