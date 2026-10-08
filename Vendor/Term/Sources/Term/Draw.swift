// What the renderer draws in the viewport: per cell its colors and decorations, and the cursor
// (Ghostty's terminal/render.zig RenderState + the decisions of renderer/generic.zig rebuildRow
// and addCursor). Glyphs are not decided here: the platform renderer shapes the text.

/// Renderer options, with Ghostty's defaults.
public struct DrawConfig {
    /// A configured color, or one of the cell's own colors.
    public enum Source { case color(RGB), cellForeground, cellBackground }
    public enum Bold { case color(RGB), bright }
    public var selectionBackground: Source?, selectionForeground: Source?
    public var searchBackground = Source.color(RGB(r: 0xFF, g: 0xE0, b: 0x82)), searchForeground = Source.color(RGB(r: 0, g: 0, b: 0))
    public var searchSelectedBackground = Source.color(RGB(r: 0xF2, g: 0xA5, b: 0x7E)), searchSelectedForeground = Source.color(RGB(r: 0, g: 0, b: 0))
    public var cursorColor: Source?, cursorText: Source?, bold: Bold?
    public var faintOpacity = 0.5, cursorOpacity = 1.0, backgroundOpacity = 1.0, backgroundOpacityCells = false
    public init() {}
}

public struct DrawCell: Equatable {
    public enum Highlight: UInt8 { case none, selection, search, searchSelected }
    public var highlight = Highlight.none
    public var bg: RGB, bgAlpha: UInt8, fg: RGB, fgAlpha: UInt8
    public var invisible = false, underline = Underline.none, underlineColor = RGB(r: 0, g: 0, b: 0), overline = false, strikethrough = false
}

public struct DrawCursor: Equatable {
    public enum Style: String { case block, blockHollow = "block_hollow", bar, underline, lock }
    public var style: Style, x: Int, y: Int, color: RGB, alpha: UInt8
    /// The color of the text under a block cursor (Ghostty's cursor-text; default: the background).
    public var text = RGB(r: 0, g: 0, b: 0)
}

extension Style {
    /// The foreground: the style's color, the default, or the bold color (Ghostty's Style.fg).
    func fg(_ def: RGB, _ palette: [RGB], _ bold: DrawConfig.Bold?) -> RGB {
        switch fgColor {
        case .none: if flags.bold, case .color(let c) = bold { return c }; return def
        case .palette(let i): return palette[Int(i) + (flags.bold && bold != nil && i < 8 ? 8 : 0)]
        case .rgb(let c): if flags.bold, c == def, case .color(let b) = bold { return b }; return c
        }
    }

    /// The background of a cell with this style: a background-only cell's own color first.
    func bg(_ cell: Cell, _ palette: [RGB]) -> RGB? {
        switch cell.tag {
        case .bgColorPalette: return palette[Int(cell.content & 0xFF)]
        case .bgColorRGB: return RGB(r: UInt8(cell.content & 0xFF), g: UInt8(cell.content >> 8 & 0xFF), b: UInt8(cell.content >> 16 & 0xFF))
        default: return Self.resolve(bgColor, palette)
        }
    }

    static func resolve(_ c: Color, _ palette: [RGB]) -> RGB? {
        switch c { case .none: nil; case .palette(let i): palette[Int(i)]; case .rgb(let v): v }
    }
}

/// Rows as drawn, kept by the caller across frames (Terminal.draw rewrites the marked ones), the
/// default colors they were drawn with and where the cursor was (it splits text runs); the
/// frame's cursor and preedit.
public struct DrawnRows {
    /// Row major, `cols` per row.
    public internal(set) var cells: [DrawCell?] = [], cols = 0
    /// Per viewport row: its cells as the renderer shapes them and its selected columns, copied
    /// with the rows drawn (the renderer builds its frame from them without the terminal).
    public internal(set) var lines: [RowCells] = [], selections: [ClosedRange<Int>?] = []
    public internal(set) var cursor: DrawCursor?, preedit: DrawPreedit?
    /// Where the cursor is in the viewport, drawn or not (nil: scrolled out of view).
    public internal(set) var at: (x: Int, y: Int)?
    public internal(set) var colors: (fg: RGB, bg: RGB)?
    public init() {}
}

/// A row as the renderer reads it: a copy of its cells, their styles and extra code points, so
/// the frame can be built after the terminal's lock is released (Ghostty's RenderState row copy).
/// `load` reuses the storage.
public struct RowCells {
    var cells: [Cell] = [], styles: [Int: Style] = [:], graphemes: [Int: [UInt32]] = [:]
    public var count: Int { cells.count }
    public init() {}
    public init(_ row: Pin) { load(row) }
    mutating func load(_ row: Pin) {
        let page = row.page, base = page.cellAt(row.y, 0)
        cells.removeAll(keepingCapacity: true)
        styles.removeAll(keepingCapacity: true)
        graphemes.removeAll(keepingCapacity: true)
        for x in 0..<page.cols {
            let c = page.cell(base + 8 * x)
            cells.append(c)
            if c.styleID != 0, styles[c.styleID] == nil { styles[c.styleID] = page.style(c.styleID) }
            if c.hasGrapheme { graphemes[x] = Array(page.grapheme(base + 8 * x)!) }
        }
    }
    public subscript(_ x: Int) -> Cell { cells[x] }
    /// The cell's style (the default one when it has none).
    public func style(_ x: Int) -> Style { let id = cells[x].styleID; return id != 0 ? styles[id]! : Style() }
    /// The cell's extra code points (nil: none).
    public func grapheme(_ x: Int) -> [UInt32]? { cells[x].hasGrapheme ? graphemes[x] : nil }
}

/// Where the input method's text shows (at the cursor, pushed left to fit) and its color.
/// The preedit as drawn: its row, first and last column, color, and `offset`: its first code point
/// shown (what doesn't fit is cut from the front). Plain values (a slice of the preedit's tuples
/// would go through runtime metadata on every copy).
public struct DrawPreedit { public var y: Int, x: Int, end: Int, fg: RGB, offset: Int }

extension Terminal {
    /// The viewport as drawn: the rows marked in `state.rows` are recomputed into `rows` (nil:
    /// under the preedit; a new grid or new default colors mark every row), then `rows.cursor` (nil:
    /// not drawn) and `rows.preedit`. `focused`: the surface has focus; `blinkVisible`: the blink
    /// phase shows the cursor; `links`: hovered link cells (y * cols + x), underlined. The marks
    /// stay: the caller clears them once it used the rows.
    public func draw(_ config: DrawConfig, focused: Bool, blinkVisible: Bool, preedit: [(cp: UInt32, wide: Bool)]? = nil,
                     links: Set<Int> = [], state: inout RenderState, into rows: inout DrawnRows) {
        let s = active, pal = colors.palette.current, n = state.rows.count
        let reverse = modes.get(.reverseColors), (bgDefault, fgDefault) = (drawBackground, reverse ? colors.background.value! : colors.foreground.value!)
        // New grid, or new default colors: every row (Ghostty doesn't redraw for OSC 10/11 default
        // color changes and leaves rows drawn in the old colors; we do).
        let grid = rows.cells.count != n * cols || rows.cols != cols
        if grid || rows.colors.map({ $0 != (fgDefault, bgDefault) }) ?? true {
            if grid {
                (rows.cells, rows.cols) = (Array(repeating: nil, count: n * cols), cols)
                (rows.lines, rows.selections) = (Array(repeating: RowCells(), count: n), Array(repeating: nil, count: n))
            }
            for y in 0..<n { state.rows[y] = true }
        }
        rows.colors = (fgDefault, bgDefault)
        // The cursor's viewport row (a row the render state saw), and the preedit there: it
        // replaces the cells it covers, and the cursor.
        let cp = s.cursor.pin.pin
        let at = state.pins.firstIndex { $0.page === cp.page && $0.y == cp.y }.map { y in
            (x: s.cursor.x, y: y, wideTail: s.cursor.x > 0 && cp.page.cell(cp.page.cellAt(cp.y, s.cursor.x - 1)).wide == .wide)
        }
        let place = preedit.flatMap { p in at.map { vp in
            let r = Surface.preeditRange(p, start: vp.x, max: cols - 1)
            return DrawPreedit(y: vp.y, x: r.start, end: r.end, fg: fgDefault, offset: r.offset)
        } }
        // A cursor that moved (even along its row, which marks nothing in the terminal: Ghostty keeps
        // the old run split there) rebuilds its old and new rows.
        if let old = rows.at, old != at.map({ ($0.x, $0.y) }) ?? (-1, -1), old.y < n { state.rows[old.y] = true }
        if let a = at, rows.at.map({ $0 != (a.x, a.y) }) ?? true { state.rows[a.y] = true }
        rows.at = at.map { ($0.x, $0.y) }
        let alpha = { (o: Double) in UInt8((255 * o).rounded(.up)) }
        let faint = alpha(config.faintOpacity), cellsAlpha: UInt8 = config.backgroundOpacityCells ? UInt8(255 * config.backgroundOpacity) : 255
        let selected = selectedColumns(), width = cols
        for y in 0..<n where state.rows[y] {
            rows.selections[y] = selected(y)
            rows.lines[y].load(state.pins[y])
        }
        let ranges = rows.selections
        // An empty unstyled unselected cell (most of a screen): the default colors, nothing drawn.
        let blank = DrawCell(bg: bgDefault, bgAlpha: 0, fg: fgDefault, fgAlpha: 255, underlineColor: fgDefault)
        rows.cells.withUnsafeMutableBufferPointer { out in
            for y in 0..<n where state.rows[y] {
                let row = state.pins[y], page = row.page, base = page.cellAt(row.y, 0), range = ranges[y]
                let lights = y < state.highlights.count ? state.highlights[y] : []
                // The last style and its colors: consecutive cells mostly share one.
                var (id, style, fgStyle, styleBg) = (-1, Style(), fgDefault, RGB?.none)
                for x in 0..<page.cols {
                    if let p = place, p.y == y, x >= p.x, x <= p.end { out[y * width + x] = nil; continue }
                    let cell = page.cell(base + 8 * x)
                    if cell.bits == 0, range == nil, lights.isEmpty, links.isEmpty { out[y * width + x] = blank; continue }
                    if cell.styleID != id {
                        id = cell.styleID
                        style = id != 0 ? page.style(id) : Style()
                        (fgStyle, styleBg) = (style.fg(fgDefault, pal, config.bold), Style.resolve(style.bgColor, pal))
                    }
                    let inv = style.flags.inverse
                    let bgStyle = cell.tag == .bgColorPalette || cell.tag == .bgColorRGB ? style.bg(cell, pal) : styleBg
                    // Selection first, then the search highlights in order (the selected match first).
                    let xc = cell.wide == .spacerTail ? max(x - 1, 0) : x
                    let hl: DrawCell.Highlight = range?.contains(xc) == true ? .selection
                        : lights.first { $0.x.contains(xc) }.map { $0.selected ? .searchSelected : .search } ?? .none
                    let pick = { (c: DrawConfig.Source?, def: RGB, bg: RGB?) -> RGB? in
                        switch c { case nil: def; case .color(let v)?: v; case .cellForeground?: inv ? bg : fgStyle; case .cellBackground?: inv ? fgStyle : bg }
                    }
                    let bg: RGB? = switch hl {
                    case .selection: pick(config.selectionBackground, fgDefault, bgStyle)
                    case .search: pick(config.searchBackground, fgDefault, bgStyle)
                    case .searchSelected: pick(config.searchSelectedBackground, fgDefault, bgStyle)
                    case .none: inv != (cell.codepoint == 0x2588) ? fgStyle : bgStyle
                    }
                    let finalBg = bgStyle ?? bgDefault
                    let fg: RGB = switch hl {
                    case .selection: pick(config.selectionForeground, bgDefault, finalBg)!
                    case .search: pick(config.searchForeground, bgDefault, finalBg)!
                    case .searchSelected: pick(config.searchSelectedForeground, bgDefault, finalBg)!
                    case .none: inv ? finalBg : fgStyle
                    }
                    let bgAlpha: UInt8 = hl != .none || inv ? 255 : bgStyle == nil ? 0 : cellsAlpha
                    var d = DrawCell(highlight: hl, bg: bg ?? bgDefault, bgAlpha: bgAlpha, fg: fg, fgAlpha: style.flags.faint ? faint : 255)
                    if style.flags.invisible { d.invisible = true } else {
                        // Hovered links get a single underline, a double one when already underlined.
                        let hovered = !links.isEmpty && links.contains(y * width + x)
                        let underline = !hovered ? style.flags.underline : style.flags.underline == .single ? .double : .single
                        (d.underline, d.underlineColor) = (underline, Style.resolve(style.underlineColor, pal) ?? fg)
                        (d.overline, d.strikethrough) = (style.flags.overline, style.flags.strikethrough)
                    }
                    out[y * width + x] = d
                }
            }
        }
        // The cursor (Ghostty's renderer.cursorStyle, rebuildCells' cursor color, addCursor).
        (rows.cursor, rows.preedit) = (nil, place)
        guard let at, place == nil else { return }
        let visual: DrawCursor.Style = switch s.cursor.cursorStyle { case .block: .block; case .blockHollow: .blockHollow; case .bar: .bar; case .underline: .underline }
        let shape: DrawCursor.Style? = !modes.get(.cursorVisible) ? nil : !focused ? .blockHollow : modes.get(.cursorBlinking) && !blinkVisible ? nil : visual
        guard let shape else { return }
        // A configured source against the cell under the cursor (inverse swaps the cell's colors).
        let resolve = { (source: DrawConfig.Source) -> RGB in
            let cell = cp.page.cell(cp.page.cellAt(cp.y, at.x))
            let style = cell.styleID != 0 ? cp.page.style(cell.styleID) : Style()
            let (fg, bg) = (style.fg(fgDefault, pal, config.bold), style.bg(cell, pal) ?? bgDefault)
            switch source { case .color(let c): return c; case .cellForeground: return style.flags.inverse ? bg : fg; case .cellBackground: return style.flags.inverse ? fg : bg }
        }
        let color = colors.cursor.value ?? config.cursorColor.map(resolve) ?? fgDefault
        rows.cursor = DrawCursor(style: shape, x: at.wideTail ? at.x - 1 : at.x, y: at.y, color: color, alpha: focused ? alpha(config.cursorOpacity) : 255,
                                 text: config.cursorText.map(resolve) ?? bgDefault)
    }
}

extension Terminal {
    /// The default background as drawn (reverse video swaps it with the foreground).
    public var drawBackground: RGB { modes.get(.reverseColors) ? colors.foreground.value! : colors.background.value! }

    /// Each viewport row's selected columns (Ghostty's Selection.containedRowCached): the corners
    /// are resolved once, rows go by their screen y (the viewport's rows are consecutive).
    public func selectedColumns() -> (Int) -> ClosedRange<Int>? {
        let s = active
        guard let sel = s.selection else { return { _ in nil } }
        let (tl, br) = sel.corners(s.pages)
        guard let a = s.pages.point(.screen, tl), let b = s.pages.point(.screen, br), let top = s.pages.point(.screen, s.pages.topLeft(.viewport)) else { return { _ in nil } }
        let last = s.pages.cols - 1
        // Ghostty also clamps a rectangle's columns to the row's width: a no-op, every page has the same width.
        return { y in
            let p = top.y + y
            guard p >= a.y, p <= b.y else { return nil }
            return sel.rectangle ? a.x...b.x : (p == a.y ? a.x : 0)...(p == b.y ? b.x : last)
        }
    }

    /// The cursor's viewport position (nil: scrolled out of view).
    public var cursorViewport: (x: Int, y: Int)? {
        active.pages.point(.viewport, active.cursor.pin.pin).flatMap { $0.y < active.pages.rows ? $0 : nil }
    }
}

/// What changed since the renderer's last frame (Ghostty's RenderState.update, without its cell
/// copies: the renderer reads cells on the terminal's own thread). `update` consumes the
/// terminal's dirty flags; the renderer clears `rows` as it rebuilds them and sets `dirty` back
/// to `.false` after a frame.
public struct RenderState {
    public enum Dirty: String { case `false`, partial, full }
    public var dirty = Dirty.false
    /// Per viewport row: rebuild it.
    public var rows: [Bool] = []
    /// Per viewport row: where it is (valid until the terminal changes: update before drawing).
    public internal(set) var pins: [Pin] = []
    /// Per viewport row: search highlights in precedence order (columns, the selected match or not).
    public internal(set) var highlights: [[(x: ClosedRange<Int>, selected: Bool)]] = []
    var screen: Bool?, size = (cols: 0, rows: 0), viewport: Pin?
    public init() {}

    public mutating func update(_ t: Terminal) {
        let s = t.active, pages = s.pages, top = pages.topLeft(.viewport)
        let redraw = screen != t.isAlternate || t.dirty != Terminal.Dirty() || s.dirty != Screen.Dirty() || size != (pages.cols, pages.rows)
            || viewport.map { $0 != top } ?? true
        (size, viewport) = ((pages.cols, pages.rows), top)
        if rows.count != size.rows {
            rows.removeAll(keepingCapacity: true)
            rows.append(contentsOf: repeatElement(true, count: size.rows))
            pins.removeAll(keepingCapacity: true)
            pins.append(contentsOf: repeatElement(top, count: size.rows))
        }
        // Page by page from the viewport's top: a dirty page (or a redraw) rebuilds all its rows.
        var (page, y0, vy, any) = (top.page, top.y, 0, false)
        while vy < size.rows {
            let take = min(page.rows - y0, size.rows - vy), all = redraw || page.dirty
            page.dirty = false
            // (stored only where a row moved: a Pin holds its page, a store retains and releases)
            for y in y0..<y0 + take where pins[vy + y - y0].page !== page || pins[vy + y - y0].y != y { pins[vy + y - y0] = Pin(page: page, y: y) }
            for y in y0..<y0 + take where all || page.row(y).dirty {
                page.updateRow(y) { $0.dirty = false }
                rows[vy + y - y0] = true
                any = true
            }
            vy += take
            if let next = page.next { (page, y0) = (next, 0) }
        }
        if redraw { (screen, dirty) = (t.isAlternate, .full) } else if any && dirty == .false { dirty = .partial }
        t.dirty = Terminal.Dirty()
        s.dirty = Screen.Dirty()
        // The renderer's frame (updateFrame): a dirty frame makes the search re-read the viewport.
        if dirty != .false { t.searchViewportDirty = true }
    }

    /// updateFrame's search part: when the search's highlights changed or the frame is dirty, rows
    /// losing theirs are rebuilt, then the selected match and the matches are laid on the rows they
    /// cover (RenderState.updateHighlightsFlattened). Returns whether they were applied. The rows
    /// are marked; `dirty` is not (Ghostty's renderer reads it to rebuild, ours rebuilds marked rows).
    public mutating func highlight(_ search: SearchHighlights) -> Bool {
        guard search.changed || dirty != .false else { return false }
        if highlights.count != rows.count { highlights = Array(repeating: [], count: rows.count) }
        for y in highlights.indices where !highlights[y].isEmpty { highlights[y].removeAll(keepingCapacity: true); rows[y] = true }
        for (selected, list) in [(true, search.selected.map { [$0] } ?? []), (false, search.matches)] {
            for (y, pin) in pins.enumerated() {
                for m in list {
                    for (i, c) in m.chunks.enumerated() where c.page === pin.page && c.serial == pin.page.serial && pin.y >= c.start && pin.y < c.end {
                        let a = i == 0 && pin.y == c.start ? m.topX : 0, b = i == m.chunks.count - 1 && pin.y == c.end - 1 ? m.botX : size.cols - 1
                        highlights[y].append((a...b, selected))
                        rows[y] = true
                    }
                }
            }
        }
        return true
    }
}
