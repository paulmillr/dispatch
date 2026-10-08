// Selections and their text (Ghostty's Selection.zig, the select functions of Screen.zig and the
// plain path of formatter.zig as Screen.selectionString uses it).

/// Two positions and whether they span a rectangle. The screen keeps its selection's positions
/// as tracked pins, so they move with the page list like the cursor.
public struct Selection: Equatable {
    public var start: Pin, end: Pin, rectangle: Bool
    public init(_ start: Pin, _ end: Pin, rectangle: Bool = false) { (self.start, self.end, self.rectangle) = (start, end, rectangle) }

    /// Top left and bottom right; a rectangle drawn right to left takes its columns crosswise.
    func corners(_ pages: PageList) -> (topLeft: Pin, bottomRight: Pin) {
        let (s, e) = (pages.point(.screen, start)!, pages.point(.screen, end)!)
        var (a, b) = s.y < e.y || s.y == e.y && s.x <= e.x ? (start, end) : (end, start)
        if rectangle, s.y != e.y, (s.y < e.y) != (s.x <= e.x) {   // mirrored: the rows' order, the other columns
            (a.x, b.x) = (min(b.x, a.page.cols - 1), min(a.x, b.page.cols - 1))
        }
        return (a, b)
    }
}

/// Default word boundaries (Ghostty's selection-word-chars default).
public let wordBoundaries: [UInt32] = [0, 0x20, 0x09, 0x27, 0x22, 0x2502, 0x60, 0x7C, 0x3A, 0x3B, 0x2C, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3C, 0x3E, 0x24]
/// Whitespace trimmed from line selections and select all.
public let lineWhitespace: [UInt32] = [0, 0x20, 0x09]

extension Pin {
    var cellValue: Cell { page.cell(cell) }

    /// Cells from this pin on: rightwards then down, or leftwards then up, through whole rows up to
    /// the limit's row (Ghostty's cellIterator: the limit bounds rows, not columns).
    func cells(down: Bool, to limit: Pin? = nil) -> some Sequence<Pin> {
        rows(down: down, to: limit).lazy.flatMap { r in
            let x0 = r.page === page && r.y == y ? x : down ? 0 : r.page.cols - 1
            return (down ? Array(x0..<r.page.cols) : Array((0...x0).reversed())).lazy.map { Pin(page: r.page, y: r.y, x: $0) }
        }
    }
}

extension Screen {
    /// The position of a point on this screen (nil: outside it).
    public func pin(_ tag: PointTag, x: Int, y: Int) -> Pin? { pages.pin(tag, x: x, y: y) }
    /// The point of a position on this screen (nil: not in that area).
    public func point(_ tag: PointTag, _ p: Pin) -> (x: Int, y: Int)? { pages.point(tag, p) }

    public var selection: Selection? { selected.map { Selection($0.start.pin, $0.end.pin, rectangle: $0.rectangle) } }

    /// Makes `sel` the selection, tracking its positions (nil clears it).
    public func select(_ sel: Selection?) {
        clearSelection()
        guard let sel else { return }
        selected = (pages.track(sel.start), pages.track(sel.end), sel.rectangle)
        dirty.selection = true
    }

    public func clearSelection() {
        guard let s = selected else { return }
        pages.untrack(s.start)
        pages.untrack(s.end)
        selected = nil
        dirty.selection = true
    }

    /// The word under a pin: the run of cells on the same side of the boundary set, across soft wraps.
    public func selectWord(at pin: Pin, boundaries: [UInt32] = wordBoundaries) -> Selection? {
        guard pin.cellValue.hasText else { return nil }
        let expect = boundaries.contains(pin.cellValue.codepoint)
        let same = { (p: Pin) in p.cellValue.hasText && boundaries.contains(p.cellValue.codepoint) == expect }
        let lineEnd = { (p: Pin) in p.x == p.page.cols - 1 && !p.row.wrap }
        var (start, end) = (pin, pin)
        for p in pin.cells(down: true).dropFirst() {
            if !same(p) { break }
            end = p
            if lineEnd(p) { break }
        }
        for p in pin.cells(down: false).dropFirst() {
            if lineEnd(p) || !same(p) { break }
            start = p
        }
        return Selection(start, end)
    }

    /// The word nearest `start` among the cells from `start` to `end` (either order).
    public func selectWord(between start: Pin, and end: Pin, boundaries: [UInt32] = wordBoundaries) -> Selection? {
        let down = start.before(end)
        for p in start.cells(down: down, to: end) {
            if down ? end.before(p) : p.before(end) { return nil }
            if let s = selectWord(at: p, boundaries: boundaries) { return s }
        }
        return nil
    }

    /// The line under a pin across soft wraps, without leading and trailing whitespace; with
    /// `promptBoundary`, a change of semantic content (prompt, input, output) ends it too.
    public func selectLine(at pin: Pin, whitespace: [UInt32]? = lineWhitespace, promptBoundary: Bool = true,
                           maxRows: Int? = nil) -> Selection? {
        let state = promptBoundary ? pin.cellValue.semantic : nil
        let rowLimit = max(1, maxRows ?? Int.max)
        let at = { (p: Pin, x: Int) in Pin(page: p.page, y: p.y, x: x) }
        let lineStart: Pin = {
            let up = pin.rows(down: false)
            var prev = Pin(page: pin.page, y: pin.y)
            if let v = state, let x = (0...pin.x).reversed().first(where: { at(prev, $0).cellValue.semantic != v }) { return at(prev, x + 1) }
            for p in up.dropFirst().prefix(rowLimit - 1) {
                if !p.row.wrap { return at(prev, 0) }
                guard let v = state else { prev = p; continue }
                for x in (0..<p.page.cols).reversed() {
                    if at(p, x).cellValue.semantic != v { return prev }
                    prev = at(p, x)
                }
            }
            return at(prev, 0)
        }()
        let lineEnd: Pin? = {
            for p in pin.rows(down: true).prefix(rowLimit) {
                if let v = state {
                    let x0 = p.page === pin.page && p.y == pin.y ? pin.x : 0
                    if x0 == 0, at(p, 0).cellValue.semantic != v { var prev = p.up(1)!; prev.x = prev.page.cols - 1; return prev }
                    if let x = (x0..<p.page.cols).first(where: { at(p, $0).cellValue.semantic != v }) { return at(p, x - 1) }
                }
                if !p.row.wrap { return at(p, p.page.cols - 1) }
            }
            return nil
        }()
        guard let end = lineEnd else { return nil }
        guard let ws = whitespace else { return Selection(lineStart, end) }
        let solid = { (p: Pin) in p.cellValue.hasText && !ws.contains(p.cellValue.codepoint) }
        guard let a = lineStart.cells(down: true, to: end).first(where: solid), let b = end.cells(down: false, to: lineStart).first(where: solid) else { return nil }
        return Selection(a, b)
    }

    /// From the first to the last non-whitespace cell of the screen.
    public func selectAll() -> Selection? {
        let solid = { (p: Pin) in p.cellValue.hasText && !lineWhitespace.contains(p.cellValue.codepoint) }
        guard let a = pages.topLeft(.screen).cells(down: true).first(where: solid),
              let b = pages.bottomRight(.screen)!.cells(down: false).first(where: solid) else { return nil }
        return Selection(a, b)
    }

    /// The command output around a pin: from its prompt's output to the last output cell with
    /// text before the next prompt (no prompt above: from the top to the next prompt).
    public func selectOutput(at pin: Pin) -> Selection? {
        guard pin.cellValue.semantic == .output else { return nil }
        let lastText = { (from: Pin, to: Pin) in from.cells(down: false, to: to).first { $0.cellValue.hasText } ?? to }
        guard let prompt = pages.promptAbove(pin) else {
            guard var end = pages.promptBelow(pin)?.prompt.up(1) else { return nil }
            end.x = end.page.cols - 1
            let top = pages.topLeft(.screen)
            return Selection(top, lastText(end, top))
        }
        // PageList.highlightSemanticContent(prompt, .output): the output up to the next prompt.
        var end = pages.bottomRight(.screen)!
        if let next = pages.promptBelow(prompt)?.next, var above = pages.promptBelow(next)?.prompt.up(1) {
            above.x = above.page.cols - 1
            end = above
        }
        var (cells, first) = (prompt.cells(down: true, to: end).makeIterator(), nil as Pin?)
        while let p = cells.next() { if p.cellValue.semantic == .output && p.cellValue.hasText { first = p; break } }
        guard let first else { return nil }
        var last = first
        while let p = cells.next(), p.cellValue.semantic == .output { if p.cellValue.hasText { last = p } }
        return Selection(first, lastText(last, first))
    }

    /// The selection's text as plain UTF-8 (Ghostty's plain formatter, soft wraps unwrapped).
    public func selectionString(_ sel: Selection, trim: Bool) -> [UInt8] {
        var pins: [Pin]?
        return selectionString(sel, trim: trim, pins: &pins)
    }

    /// The same, and (pins non-nil) the cell of every byte (Screen.selectionStringMap).
    func selectionString(_ sel: Selection, trim: Bool, emit: Emit = .plain, pins: inout [Pin]?) -> [UInt8] {
        let (tl, br) = sel.corners(pages)
        var (out, blanks) = ([UInt8](), (rows: 0, cells: 0))
        for (page, rows) in tl.chunks(down: true, to: br) {
            var map: [(x: Int, y: Int)]? = pins == nil ? nil : []
            page.format(rows.lowerBound, rows.upperBound - 1, x0: sel.rectangle || page === tl.page ? tl.x : 0,
                        x1: sel.rectangle || page === br.page ? br.x : page.cols - 1, rectangle: sel.rectangle, trim: trim, emit: emit, &blanks, &out, &map)
            pins? += (map ?? []).map { Pin(page: page, y: $0.y, x: $0.x) }
        }
        return out
    }

    /// read_text (Ghostty's Surface.dumpTextLocked): the text and, when some of it is in the
    /// viewport, its first and last viewport points and their offsets (row * cols + column).
    public func readText(_ sel: Selection) -> (text: [UInt8], viewport: (tl: (x: Int, y: Int), br: (x: Int, y: Int), offsetStart: Int, offsetLen: Int)?) {
        let text = selectionString(sel, trim: false)
        let (tl, br) = sel.corners(pages), vpTL = pages.topLeft(.viewport)
        guard let vpBR = pages.bottomRight(.viewport), !br.before(vpTL), !vpBR.before(tl) else { return (text, nil) }
        let a = pages.point(.viewport, tl) ?? (0, 0), b = pages.point(.viewport, br) ?? pages.point(.viewport, vpBR)!
        let start = a.y * pages.cols + a.x
        return (text, (a, b, start, b.y * pages.cols + b.x - start))
    }
}

/// How the page formatter writes text (Ghostty's formatter.zig emit): plain UTF-8, or HTML with
/// styles as inline spans and hyperlinks as anchors (a div per page; colors from the palette;
/// the div's own colors when given).
public enum Emit {
    case plain, html(palette: [RGB], background: RGB?, foreground: RGB?)
}

extension Page {
    /// Ghostty's page formatter (soft wraps unwrapped): rows y0...y1, from column x0 on the first
    /// row to x1 on the last (every row when `rectangle`). Rows end in newlines and blank cells become
    /// spaces, both only when text follows; `blanks` carries them over from the page before when this
    /// one starts at (0, 0). With `trim`, spaces count as blank (plain). HTML: styled cells are never
    /// blank, a style change closes and opens a span (after pending spaces), blank rows first close
    /// the span. `map` (Ghostty's point map, plain only) gets the cell of every byte: blank spaces
    /// count back from the next text cell, a blank row's newline takes the last mapped cell, the ones
    /// after it (0, that row + k).
    func format(_ y0: Int, _ y1: Int, x0 startX: Int, x1: Int, rectangle: Bool, trim: Bool, emit: Emit = .plain,
                _ blanks: inout (rows: Int, cells: Int), _ out: inout [UInt8], _ map: inout [(x: Int, y: Int)]?) {
        if y0 != 0 || startX != 0 { blanks = (0, 0) }
        var (endX, endY) = (min(x1, cols - 1), y1)
        guard startX < cols else { return }
        if !rectangle, cell(cellAt(endY, endX)).wide == .spacerHead, endY < rows - 1 { (endY, endX) = (endY + 1, 0) }
        if y0 == endY, startX > endX { return }
        let html: (palette: [RGB], background: RGB?, foreground: RGB?)? = if case .html(let p, let b, let f) = emit { (p, b, f) } else { nil }
        let hex = { (c: RGB) in [c.r, c.g, c.b].map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() }
        if let h = html {
            out += ascii("<div style=\"font-family: monospace; white-space: pre;" + (h.background.map { "background-color: #\(hex($0));" } ?? "")
                         + (h.foreground.map { "color: #\(hex($0));" } ?? "") + "\">")
        }
        // HTML state: the open span's style (nil id: a background-color cell's), the open anchor.
        var (style, styleID, link) = (Style(), Optional(0), nil as Int?)
        let base = map?.count ?? 0
        for y in y0...endY {
            var xStart = 0
            if startX > 0, rectangle || y == y0 {
                switch cell(cellAt(y, startX)).wide {
                case .spacerHead: continue
                case .spacerTail: xStart = startX - 1
                default: xStart = startX
                }
            }
            let xs = xStart..<(rectangle || y == endY ? endX + 1 : cols)
            guard xs.contains(where: { cell(cellAt(y, $0)).hasText }) else { blanks.rows += 1; continue }
            if blanks.rows > 0, html != nil, style != Style() {
                out += ascii("</div>")
                (style, styleID) = (Style(), 0)
            }
            if blanks.rows > 0, let last = map.map({ $0.count > base ? $0.last! : (x: 0, y: 0) }) {
                map! += [last] + (1..<blanks.rows).map { (x: 0, y: last.y + $0) }
            }
            if blanks.rows > 0 { out += repeatElement(0x0A, count: blanks.rows) }
            blanks.rows = row(y).wrap ? 0 : 1
            if !row(y).wrapContinuation { blanks.cells = 0 }
            for x in xs {
                let c = cell(cellAt(y, x))
                if c.wide == .spacerHead || c.wide == .spacerTail { continue }
                if html != nil ? c.isEmpty && !c.hasStyling : !c.hasText || trim && c.codepoint == 0x20 { blanks.cells += 1; continue }
                if blanks.cells > 0 { out += repeatElement(0x20, count: blanks.cells) }
                var (bx, by) = (x, y)
                for _ in 0..<(map == nil ? 0 : blanks.cells) {
                    if bx > 0 { bx -= 1 } else if by > 0 { (bx, by) = (cols - 1, by - 1) }
                    map!.append((bx, by))
                }
                blanks.cells = 0
                if let h = html {
                    // Background-color cells have no style id: their style is compared by value.
                    let id: Int? = c.tag.rawValue < 2 ? c.styleID : nil
                    let cs = c.tag == .bgColorPalette || c.tag == .bgColorRGB ? { var s = Style(); s.bgColor = c.tag == .bgColorPalette ? .palette(UInt8(c.content & 0xFF))
                        : .rgb(RGB(r: UInt8(c.content & 0xFF), g: UInt8(c.content >> 8 & 0xFF), b: UInt8(c.content >> 16 & 0xFF))); return s }()
                        : c.hasStyling ? self.style(c.styleID) : Style()
                    if id != nil, id == styleID {
                    } else if (id == nil || styleID == nil) && cs == style {
                        styleID = id
                    } else {
                        if style != Style() { out += ascii("</div>") }
                        (style, styleID) = (cs, id)
                        if cs != Style() { out += ascii("<div style=\"display: inline;" + cs.html(h.palette) + "\">") }
                    }
                    let id2 = c.hyperlink ? hyperlink(cellAt(y, x)) : nil
                    if id2 != link {
                        if link != nil { out += ascii("</a>") }
                        link = id2
                        if let id2 { out += ascii("<a href=\""); for b in self.link(id: id2).uri { htmlEscape(UInt32(b), &out) }; out += ascii("\">") }
                    }
                    if !c.hasText { out.append(0x20); continue }
                    htmlEscape(c.codepoint, &out)
                    if c.tag == .codepointGrapheme { for g in grapheme(cellAt(y, x))! { htmlEscape(g, &out) } }
                    continue
                }
                let n = out.count
                utf8(c.codepoint, &out)
                if c.tag == .codepointGrapheme { for g in grapheme(cellAt(y, x))! { utf8(g, &out) } }
                if map != nil { for _ in n..<out.count { map!.append((x, y)) } }
            }
        }
        guard html != nil else { return }
        if style != Style() { out += ascii("</div>") }
        if link != nil { out += ascii("</a>") }
        out += ascii("</div>")
        blanks.rows = max(0, blanks.rows - 1)
    }
}

/// Ghostty's HTML code point writer: the five markup characters as entities, ASCII as is, the rest
/// as decimal numeric entities.
func htmlEscape(_ cp: UInt32, _ out: inout [UInt8]) {
    switch cp {
    case 0x3C: out += ascii("&lt;")
    case 0x3E: out += ascii("&gt;")
    case 0x26: out += ascii("&amp;")
    case 0x22: out += ascii("&quot;")
    case 0x27: out += ascii("&#39;")
    case 0..<0x80: out.append(UInt8(cp))
    default: out += ascii("&#\(cp);")
    }
}

extension Style {
    /// Style.formatterHtml: CSS declarations (palette colors resolved).
    func html(_ palette: [RGB]) -> String {
        let color = { (name: String, c: Color) -> String in
            switch c {
            case .none: ""
            case .palette(let i): "\(name): rgb(\(palette[Int(i)].r), \(palette[Int(i)].g), \(palette[Int(i)].b));"
            case .rgb(let v): "\(name): rgb(\(v.r), \(v.g), \(v.b));"
            }
        }
        let f = flags
        var s = color("color", fgColor) + color("background-color", bgColor) + color("text-decoration-color", underlineColor)
        let lines = [(f.underline != .none, " underline"), (f.strikethrough, " line-through"), (f.overline, " overline"), (f.blink, " blink")].filter(\.0)
        if !lines.isEmpty { s += "text-decoration-line:" + lines.map(\.1).joined() + ";" }
        switch f.underline {
        case .none: break
        case .single: s += "text-decoration-style: solid;"
        case .double: s += "text-decoration-style: double;"
        case .curly: s += "text-decoration-style: wavy;"
        case .dotted: s += "text-decoration-style: dotted;"
        case .dashed: s += "text-decoration-style: dashed;"
        }
        for (on, css) in [(f.bold, "font-weight: bold;"), (f.italic, "font-style: italic;"), (f.faint, "opacity: 0.5;"), (f.invisible, "visibility: hidden;"),
                          (f.inverse, "filter: invert(100%);")] where on { s += css }
        return s
    }
}

extension PageList {
    /// Ghostty's promptIterator(.right_down) without a limit: the first prompt at or below `start`
    /// (its row start), and the row after that prompt's continuation rows, where the next search starts.
    func promptBelow(_ start: Pin) -> (prompt: Pin, next: Pin?)? {
        var cur: Pin? = start
        while let p = cur {
            if p.row.semanticPrompt != .none {
                var n = p.down(1)
                while let r = n, r.row.semanticPrompt == .promptContinuation { n = r.down(1) }
                return (Pin(page: p.page, y: p.y), n)
            }
            cur = p.down(1)
        }
        return nil
    }
}

/// Appends a codepoint as UTF-8.
@inline(__always) func utf8(_ cp: UInt32, _ out: inout [UInt8]) {
    if cp < 0x80 { return out.append(UInt8(cp)) }
    let n = cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4
    out.append(UInt8(0xF0 << (4 - n) & 0xFF) | UInt8(cp >> (6 * (n - 1))))
    for i in (0..<n - 1).reversed() { out.append(0x80 | UInt8(cp >> (6 * i) & 0x3F)) }
}
