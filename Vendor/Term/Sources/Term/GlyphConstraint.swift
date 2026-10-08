// How a glyph is fitted into its cells (Ghostty's font/Glyph.zig RenderOptions.Constraint and
// renderer/cell.zig constraintWidth): Nerd Font icons and other symbols are scaled and aligned
// into the cell box; plain text glyphs are left alone.

public struct GlyphConstraint: Equatable, Sendable {
    public enum Size: String, Sendable { case none, fit, cover, fitCover1 = "fit_cover1", stretch }
    public enum Align: String, Sendable { case none, start, end, center, center1 }
    public var size = Size.none, alignVertical = Align.none, alignHorizontal = Align.none
    public var padTop = 0.0, padLeft = 0.0, padRight = 0.0, padBottom = 0.0
    public var relativeWidth = 1.0, relativeHeight = 1.0, relativeX = 0.0, relativeY = 0.0
    public var maxXYRatio: Double?, maxConstraintWidth = 2, iconHeight = false
    public init() {}

    /// A glyph box in pixels.
    public struct Box: Equatable { public var width: Double, height: Double, x: Double, y: Double
        public init(width: Double, height: Double, x: Double, y: Double) { (self.width, self.height, self.x, self.y) = (width, height, x, y) } }

    /// The cell box the constraint fits into (Ghostty's Metrics fields it reads).
    public struct Cell { public var cellWidth: Int, cellHeight: Int, faceWidth: Double, faceHeight: Double, faceY: Double, iconHeight: Double, iconHeightSingle: Double
        public init(cellWidth: Int, cellHeight: Int, faceWidth: Double, faceHeight: Double, faceY: Double, iconHeight: Double, iconHeightSingle: Double) {
            (self.cellWidth, self.cellHeight, self.faceWidth, self.faceHeight, self.faceY) = (cellWidth, cellHeight, faceWidth, faceHeight, faceY)
            (self.iconHeight, self.iconHeightSingle) = (iconHeight, iconHeightSingle)
        } }

    /// The Nerd Font attributes for a code point (nil: none; the renderer then fits symbols).
    public static func of(_ cp: UInt32) -> GlyphConstraint? {
        var (lo, hi) = (0, glyphConstraints.count)
        while lo < hi {
            let mid = (lo + hi) / 2, r = glyphConstraints[mid]
            if cp < r.start { hi = mid } else if cp >= r.start + r.count { lo = mid + 1 } else { return r.constraint }
        }
        return nil
    }

    /// Constraint.constrain: stretch fills the whole cell (pads not negative); otherwise the glyph's
    /// group box is scaled by the size rule around its center, then aligned.
    public func constrain(_ glyph: Box, _ m: Cell, _ constraintWidth: Int) -> Box {
        guard size != .none || alignHorizontal != .none || alignVertical != .none else { return glyph }
        guard size == .stretch else { return inner(glyph, m, constraintWidth) }
        var (c, n) = (self, m)
        (n.faceWidth, n.faceHeight, n.faceY) = (Double(m.cellWidth), Double(m.cellHeight), 0)
        (c.padBottom, c.padTop, c.padLeft, c.padRight) = (max(0, padBottom), max(0, padTop), max(0, padLeft), max(0, padRight))
        return c.inner(glyph, n, constraintWidth)
    }

    func inner(_ glyph: Box, _ m: Cell, _ constraintWidth: Int) -> Box {
        let width = size == .stretch && m.faceWidth > 0.9 * m.faceHeight ? 1 : min(maxConstraintWidth, constraintWidth)
        var g = Box(width: glyph.width / relativeWidth, height: glyph.height / relativeHeight, x: 0, y: 0)
        (g.x, g.y) = (glyph.x - g.width * relativeX, glyph.y - g.height * relativeY)
        let (wf, hf) = factors(g, m, width)
        let (cx, cy) = (g.x + g.width / 2, g.y + g.height / 2)
        (g.width, g.height) = (g.width * wf, g.height * hf)
        (g.x, g.y) = (cx - g.width / 2, cy - g.height / 2)
        g.y = alignedY(g, m)
        g.x = alignedX(g, m, width)
        return Box(width: wf * glyph.width, height: hf * glyph.height, x: g.x + g.width * relativeX, y: g.y + g.height * relativeY)
    }

    func factors(_ g: Box, _ m: Cell, _ width: Int) -> (Double, Double) {
        guard size != .none else { return (1, 1) }
        let multi = width > 1
        let target = (w: (Double(width) - (padLeft + padRight)) * m.faceWidth,
                      h: (1 - (padBottom + padTop)) * (iconHeight ? multi ? m.iconHeight : m.iconHeightSingle : m.faceHeight))
        var (wf, hf) = (target.w / g.width, target.h / g.height)
        switch size {
        case .none, .stretch: break
        case .fit: hf = min(1, wf, hf); wf = hf
        case .cover: hf = min(wf, hf); wf = hf
        case .fitCover1:
            hf = min(wf, hf)
            if multi, hf > 1 { hf = max(1, factors(g, m, 1).1) }
            wf = hf
        }
        if let r = maxXYRatio, g.width * wf > g.height * hf * r { wf = g.height * hf * r / g.width }
        return (wf, hf)
    }

    func alignedY(_ g: Box, _ m: Cell) -> Double {
        if size == .none && alignVertical == .none { return g.y }
        let start = m.faceY + padBottom * m.faceHeight, end = m.faceY + (m.faceHeight - g.height - padTop * m.faceHeight)
        switch alignVertical {
        case .none: return end < start ? (start + end) / 2 : max(start, min(g.y, end))
        case .start: return start
        case .end: return end
        case .center, .center1: return (start + end) / 2
        }
    }

    func alignedX(_ g: Box, _ m: Cell, _ width: Int) -> Double {
        if size == .none && alignHorizontal == .none { return g.x }
        let span = m.faceWidth + Double((width - 1) * m.cellWidth)
        let start = padLeft * m.faceWidth, end = span - g.width - padRight * m.faceWidth
        switch alignHorizontal {
        case .none: return max(start, min(g.x, end))
        case .start: return start
        case .end: return max(start, end)
        case .center: return max(start, (start + end) / 2)
        case .center1:
            let end1 = m.faceWidth - g.width - padRight * m.faceWidth   // Ghostty's order of operations (bit-exact)
            return max(start, (start + end1) / 2)
        }
    }

    /// renderer/cell.zig constraintWidth: how many cells a glyph may cover: wide cells 2; a symbol 2
    /// when the next cell is empty or a space, unless it is at the right edge or follows another
    /// symbol that isn't a graphics element (box drawing, blocks, legacy computing, Powerline).
    public static func width(_ cells: [Term.Cell], _ x: Int) -> Int {
        let cp = cells[x].codepoint, grid = cells[x].wide == .wide ? 2 : 1
        if grid > 1 || !Unicode.isSymbol(cp) || x == cells.count - 1 { return grid }
        let graphics = { (c: UInt32) in (0x2500...0x259F).contains(c) || (0x1FB00...0x1FBFF).contains(c) || (0x1CC00...0x1CEBF).contains(c) || (0xE0B0...0xE0D7).contains(c) }
        if x > 0, Unicode.isSymbol(cells[x - 1].codepoint), !graphics(cells[x - 1].codepoint) { return 1 }
        let next = cells[x + 1].codepoint
        return next == 0 || next == 0x20 || next == 0x2002 ? 2 : 1
    }
}
