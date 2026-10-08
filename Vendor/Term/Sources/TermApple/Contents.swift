// The renderer's cell contents per frame (Ghostty's renderer/generic.zig rebuildCells, rebuildRow
// and the add* functions): each cell's background, per row the underline/overline, glyphs and
// strikethrough in draw order, the cursor glyph and the input method's text. The Metal renderer
// uploads these as instances.
#if canImport(CoreText)
import CoreGraphics
import Term

public struct Contents {
    /// A glyph (font glyph or sprite) drawn at a cell: the glyph as placed, where it goes from the
    /// cell's baseline origin, its color. Plain values (no reference counting per entry).
    public struct Entry {
        public var x: Int, y: Int, color: RGB, alpha: UInt8, glyph: CellRenderer.Placed, bearings: (x: Int, y: Int)
        public var noMinContrast = false, cursor = false
        init(_ x: Int, _ y: Int, _ color: RGB, _ alpha: UInt8, _ p: CellRenderer.Placed, bearings: (x: Int, y: Int)? = nil, noMinContrast: Bool = false, cursor: Bool = false) {
            (self.x, self.y, self.color, self.alpha, glyph) = (x, y, color, alpha, p)
            (self.bearings, self.noMinContrast, self.cursor) = (bearings ?? (p.offsetX, p.offsetY), noMinContrast, cursor)
        }
    }
    public var cols: Int, rows: Int, background: RGB
    /// rgba per cell, row major.
    public var bg: [UInt8]
    /// In draw order: [0] a block cursor (under the text), [1...rows] the rows, [rows + 1] other cursors.
    public var lists: [[Entry]]
    /// The block cursor for the shader, which recolors the text under it: cell (x, y), wide, text color.
    public var block: (x: Int, y: Int, wide: Bool, text: RGB)?
}

/// Builds Contents from a terminal: shapes each row, renders each glyph once (cached like
/// SharedGrid), sprites for decorations and cursors. A value: its owner pays one exclusivity check
/// per frame, not one per cache and buffer access (a class's stored properties are checked at
/// run time on every access).
public struct CellRenderer {
    static let maxCachedGlyphs = 8192
    public let metrics: CellMetrics
    let fonts: FontCollection, thicken: Bool, strength: UInt8
    var shaper: Shaper
    /// The glyph cache (SharedGrid's): placed glyphs by packed key (see render), their pixels by
    /// index (checks read them).
    var glyphs = Map<Placed?>()
    public private(set) var rendered: [RasterGlyph] = []
    /// The glyph atlases (Ghostty's font grid starts both at 512 pixels) and, when set (checks), a
    /// log of their operations in the oracle's format.
    public private(set) var gray = Atlas(size: 512, format: .grayscale), color = Atlas(size: 512, format: .bgra)
    public var atlasLog: [String]?

    /// A rendered glyph (`index` in rendered): where it sits in its atlas, its size and offsets.
    public struct Placed { public var index: Int, x: Int, y: Int, width: Int, height: Int, offsetX: Int, offsetY: Int, color: Bool }

    /// SharedGrid.renderGlyph with its cache key: face (sprite: -1), glyph, cell width (0: not
    /// given), thickening, constraint width; not the constraint: the first render of a glyph is kept
    /// for every later use. The cached render, else `make`'s placed in its atlas.
    mutating func render(font: Int, glyph: Int, cells: Int, thicken: Bool, strength: UInt8, width: Int, _ make: () -> RasterGlyph?) -> Placed? {
        // font + 1: 19 bits, glyph (sprites: 22 bits), cells, thicken, strength, width.
        let key = UInt64(font + 1) | UInt64(glyph) << 19 | UInt64(cells) << 43 | (thicken ? 1 << 45 : 0) | UInt64(strength) << 46 | UInt64(width) << 54
        if let p = glyphs[key] { return p }
        guard glyphs.count < Self.maxCachedGlyphs else { return nil }
        let p = make().flatMap { g -> Placed? in
            guard let spot: (x: Int, y: Int) = font < 0 || g.width > 0 ? place(g) : (0, 0) else {
                return nil
            }
            var metadata = g
            metadata.pixels.removeAll(keepingCapacity: false)
            rendered.append(metadata)
            return Placed(index: rendered.count - 1, x: spot.x, y: spot.y, width: g.width, height: g.height, offsetX: g.offsetX, offsetY: g.offsetY, color: g.color)
        }
        glyphs.set(key, p)
        return p
    }

    /// Atlas.reserve + set in the glyph's atlas, doubling the atlas when it is full.
    mutating func place(_ g: RasterGlyph) -> (x: Int, y: Int)? {
        func into(_ a: inout Atlas, _ log: inout [String]?) -> (x: Int, y: Int)? {
            guard g.width <= Atlas.maxSize - 2, g.height <= Atlas.maxSize - 2 else { return nil }
            while true {
                let r = a.reserve(g.width, g.height)
                log?.append("atlas \(a.format.rawValue) reserve \(g.width) \(g.height) -> " + (r.map { "\($0.x) \($0.y)" } ?? "full"))
                if let r {
                    if g.width > 0 && g.height > 0 { a.set(x: r.x, y: r.y, width: g.width, height: g.height, g.pixels) }
                    return r
                }
                guard a.size < Atlas.maxSize else { return nil }
                a.grow(to: min(a.size * 2, Atlas.maxSize))
                log?.append("atlas \(a.format.rawValue) grow \(a.size)")
            }
        }
        return g.color ? into(&color, &atlasLog) : into(&gray, &atlasLog)
    }

    /// Shaping results by run, in two generations: a frame finds a run in this one or moves it here
    /// from the last one; a frame starting with more than Ghostty's 2048 (font_shaper_cache: 256 x 8)
    /// drops the last generation. A screen's runs survive frame to frame however many there are
    /// (dropping all at 2048 reshaped a busy 200x60 screen every frame). Not observable: shaping the
    /// same run again gives the same glyphs.
    var shapes = Map<[ShapedCell]>(), older = Map<[ShapedCell]>()

    mutating func shape(_ run: TextRun) -> [ShapedCell] {
        if let hit = shapes[run.hash] { return hit }
        let cells = older[run.hash] ?? shaper.shape(run)
        shapes.set(run.hash, cells)
        return cells
    }

    /// A sprite with default options (decorations, cursors).
    mutating func sprite(_ cp: UInt32, cells: Int) -> Placed? {
        let metrics = metrics
        return render(font: -1, glyph: Int(cp), cells: cells, thicken: false, strength: 255, width: 1) { Sprite.render(cp, metrics, cells: cells) }
    }

    public init(_ fonts: FontCollection, metrics: CellMetrics, features: [(tag: String, value: Int)] = [], thicken: Bool = false, strength: UInt8 = 255) {
        (self.fonts, self.metrics, self.thicken, self.strength) = (fonts, metrics, thicken, strength)
        shaper = Shaper(fonts, features: features)
    }

    /// The frame being built, kept across frames: rows the render state marks are rebuilt (their
    /// background bytes and text list; the marks are consumed), the cursor lists every frame.
    public private(set) var frame = Contents(cols: 0, rows: 0, background: RGB(r: 0, g: 0, b: 0), bg: [], lists: [[], []])
    /// Terminal.draw's rows, kept like the frame.
    var drawn = DrawnRows()
    /// A row's buffers, kept across rows and frames: its runs, shaped glyphs (cell, glyph, run) and
    /// their order by cell (counting sort: `starts` per cell, `next`, `order`), its cells (the
    /// constraint width looks at neighbors). One value, taken out of the renderer while a frame is
    /// built: element writes to a class's arrays pay an exclusivity and uniqueness check each.
    struct Scratch {
        var runs: [TextRun] = [], shaped: [(x: Int, s: ShapedCell, run: Int)] = [], starts: [Int] = [], next: [Int] = [], order: [Int] = []
        var raws: [Cell] = []
    }
    var scratch = Scratch()

    /// Ghostty's rebuildCells for the rows `state` marks (update it from the terminal first).
    public mutating func contents(_ t: Terminal, _ look: DrawConfig, focused: Bool, blinkVisible: Bool, preedit: [(cp: UInt32, wide: Bool)]? = nil,
                         links: Set<Int> = [], state: inout RenderState) -> Contents {
        snapshot(t, look, focused: focused, blinkVisible: blinkVisible, preedit: preedit, links: links, state: &state)
        return contents(preedit: preedit, state: &state)
    }

    /// The terminal's part of a frame, under its lock (Ghostty's RenderState.update): the marked
    /// rows drawn and copied, the cursor.
    public mutating func snapshot(_ t: Terminal, _ look: DrawConfig, focused: Bool, blinkVisible: Bool, preedit: [(cp: UInt32, wide: Bool)]? = nil,
                                  links: Set<Int> = [], state: inout RenderState) {
        t.draw(look, focused: focused, blinkVisible: blinkVisible, preedit: preedit, links: links, state: &state, into: &drawn)
    }

    /// The frame from the last snapshot, without the terminal: shaping, glyphs, decorations.
    public mutating func contents(preedit: [(cp: UInt32, wide: Bool)]?, state: inout RenderState) -> Contents {
        if shapes.count > 2048 { swap(&shapes, &older); shapes.clear() }
        let (cursor, pre) = (drawn.cursor, drawn.preedit)
        let cols = drawn.cols, rows = cols == 0 ? 0 : drawn.cells.count / cols
        // The frame as a local while it is built (a class's property pays a check per access).
        var frame = Contents(cols: 0, rows: 0, background: RGB(r: 0, g: 0, b: 0), bg: [], lists: [])
        swap(&frame, &self.frame)
        defer { swap(&frame, &self.frame) }
        if frame.rows != rows || frame.cols != cols {
            (frame.rows, frame.cols) = (rows, cols)
            frame.bg = [UInt8](repeating: 0, count: cols * rows * 4)
            frame.lists = Array(repeating: [], count: rows + 2)
        }
        frame.background = drawn.colors!.bg
        let cursorX = drawn.at
        // The row buffers as a local too; each row's list taken out while it is filled.
        var (list, r) = ([Contents.Entry](), Scratch())
        swap(&r, &scratch)
        let cells = drawn.cells
        for y in 0..<rows where state.rows[y] {
            state.rows[y] = false
            swap(&list, &frame.lists[y + 1])
            list.removeAll(keepingCapacity: true)
            let row = drawn.lines[y]
            // The row's shaped glyphs grouped by cell (a counting sort that keeps run order inside a
            // cell; the renderer walks them with the cells).
            shaper.runs(row, selection: drawn.selections[y], cursorX: cursorX.flatMap { $0.y == y ? $0.x : nil }, into: &r.runs)
            r.shaped.removeAll(keepingCapacity: true)
            for (i, run) in r.runs.enumerated() { for s in shape(run) { r.shaped.append((run.offset + s.x, s, i)) } }
            r.starts.removeAll(keepingCapacity: true)
            r.starts.append(contentsOf: repeatElement(0, count: cols + 1))
            for g in r.shaped { r.starts[g.x + 1] += 1 }
            for x in 0..<cols { r.starts[x + 1] += r.starts[x] }
            r.order.removeAll(keepingCapacity: true)
            r.order.append(contentsOf: repeatElement(0, count: r.shaped.count))
            r.next.removeAll(keepingCapacity: true)
            r.next.append(contentsOf: r.starts)
            for (i, g) in r.shaped.enumerated() { r.order[r.next[g.x]] = i; r.next[g.x] += 1 }
            r.raws.removeAll(keepingCapacity: true)
            for x in 0..<row.count { r.raws.append(row[x]) }
            frame.bg.withUnsafeMutableBufferPointer { bg in
                for x in 0..<cols {
                    let at = (y * cols + x) * 4
                    guard let d = cells[y * cols + x] else { (bg[at], bg[at + 1], bg[at + 2], bg[at + 3]) = (0, 0, 0, 0); continue }   // under the preedit
                    (bg[at], bg[at + 1], bg[at + 2], bg[at + 3]) = (d.bg.r, d.bg.g, d.bg.b, d.bgAlpha)
                }
            }
            for x in 0..<cols {
                guard let d = cells[y * cols + x], !d.invisible else { continue }
                func sprite(_ s: Sprite.Special, _ color: RGB) {
                    if let p = self.sprite(s.rawValue, cells: 1) { list.append(Contents.Entry(x, y, color, d.fgAlpha, p)) }
                }
                switch d.underline {
                case .none: break
                case .single: sprite(.underline, d.underlineColor)
                case .double: sprite(.underlineDouble, d.underlineColor)
                case .dotted: sprite(.underlineDotted, d.underlineColor)
                case .dashed: sprite(.underlineDashed, d.underlineColor)
                case .curly: sprite(.underlineCurly, d.underlineColor)
                }
                if d.overline { sprite(.overline, d.fg) }
                for k in r.starts[x]..<r.starts[x + 1] {
                    let (s, run) = (r.shaped[r.order[k]].s, r.runs[r.shaped[r.order[k]].run])
                    guard let p = glyph(run, s, r.raws, x), p.width > 0, p.height > 0 else { continue }
                    list.append(Contents.Entry(x, y, d.fg, d.fgAlpha, p, bearings: (p.offsetX + s.xOffset, p.offsetY + s.yOffset),
                                               noMinContrast: Self.graphics(r.raws[x].codepoint)))
                }
                if d.strikethrough { sprite(.strikethrough, d.fg) }
            }
            // addPreeditCell (with its row, like rebuildCells): the input method's text from the
            // regular font, underlined.
            if let p = pre, p.y == y {
                var x = p.x
                for cp in preedit![p.offset...] {
                    if let g = codepoint(cp.cp, cells: 0) { list.append(Contents.Entry(x, y, p.fg, 255, g)) }
                    for ux in cp.wide && x < cols - 1 ? [x, x + 1] : [x] {
                        if let g = sprite(Sprite.Special.underline.rawValue, cells: 1) { list.append(Contents.Entry(ux, y, p.fg, 255, g)) }
                    }
                    x += cp.wide ? 2 : 1
                }
            }
            swap(&list, &frame.lists[y + 1])
        }
        swap(&r, &scratch)
        // addCursor, every frame: a sprite over one or two cells (the lock: U+F023 from the regular
        // font); the block goes under the text and tells the shader which cell's text to recolor.
        frame.lists[0].removeAll(keepingCapacity: true)
        frame.lists[rows + 1].removeAll(keepingCapacity: true)
        frame.block = nil
        if let cur = cursor {
            let wide = drawn.lines[cur.y][cur.x].wide == .wide
            let shape: Sprite.Special? = switch cur.style {
            case .block: .cursorRect
            case .blockHollow: .cursorHollowRect
            case .bar: .cursorBar
            case .underline: .cursorUnderline
            case .lock: nil
            }
            let g = shape.flatMap { sprite($0.rawValue, cells: wide ? 2 : 1) } ?? codepoint(0xF023, cells: wide ? 2 : 1)
            if let g { frame.lists[cur.style == .block ? 0 : rows + 1].append(Contents.Entry(cur.x, cur.y, cur.color, cur.alpha, g, cursor: true)) }
            if cur.style == .block { frame.block = (cur.x, cur.y, wide, cur.text) }
        }
        return frame
    }

    /// addGlyph's render: sprites draw themselves; font glyphs get the renderer's constraint (Nerd
    /// Font attributes, else fit for symbols) over the cells the glyph may cover.
    mutating func glyph(_ run: TextRun, _ s: ShapedCell, _ raws: [Cell], _ x: Int) -> Placed? {
        let cp = raws[x].codepoint, cells = raws[x].wide == .wide ? 2 : 1, width = GlyphConstraint.width(raws, x)
        let (fonts, metrics, thicken, strength) = (fonts, metrics, thicken, strength)   // (the render closure can't read self)
        return render(font: run.font < 0 ? -1 : run.style.rawValue << 16 | run.font, glyph: s.glyph, cells: cells, thicken: thicken, strength: strength, width: width) {
            if run.font < 0 { return Sprite.render(UInt32(s.glyph), metrics, cells: cells) }
            var fit = GlyphConstraint()
            fit.size = .fit
            return fonts.raster(run.style, run.font, glyph: CGGlyph(s.glyph), cell: metrics, constraint: GlyphConstraint.of(cp) ?? (Unicode.isSymbol(cp) ? fit : GlyphConstraint()),
                                constraintWidth: width, thicken: thicken, strength: strength)
        }
    }

    /// SharedGrid.renderCodepoint: a code point from the regular style's face (or a sprite) as text,
    /// default options (no thickening, no constraint); `cells` 0: not given.
    mutating func codepoint(_ cp: UInt32, cells: Int) -> Placed? {
        let (fonts, metrics) = (fonts, metrics)
        guard let at = fonts.index(cp, .regular, .text) else { return nil }
        if at.idx < 0 { return sprite(cp, cells: cells) }
        guard let glyph = Face.glyph(fonts.face(fonts.faces[at.style.rawValue][at.idx].entry), cp) else { return nil }
        return render(font: at.style.rawValue << 16 | at.idx, glyph: Int(glyph), cells: cells, thicken: false, strength: 255, width: 1) {
            fonts.raster(at.style, at.idx, glyph: glyph, cell: metrics, constraint: GlyphConstraint(), constraintWidth: 1)
        }
    }

    /// cell.zig noMinContrast: box drawing, blocks, legacy computing, powerline.
    static func graphics(_ cp: UInt32) -> Bool {
        switch cp { case 0x2500...0x259F, 0x1FB00...0x1FBFF, 0x1CC00...0x1CEBF, 0xE0B0...0xE0D7: true; default: false }
    }
}
#endif
