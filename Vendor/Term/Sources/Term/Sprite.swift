// Ghostty's sprite font (font/sprite: Face.zig, canvas.zig, draw/common.zig, draw/special.zig):
// box drawing, blocks, braille, legacy computing symbols, powerline and branch glyphs, underlines
// and cursors, drawn from the cell metrics instead of taken from a font. Pure pixel math, the same
// on every platform.

public enum Sprite {
    /// Ghostty's Sprite enum: decorations and cursors, numbered above Unicode.
    public enum Special: UInt32, CaseIterable, Sendable {
        case underline = 0x200000, underlineDouble, underlineDotted, underlineDashed, underlineCurly, strikethrough, overline
        case cursorRect, cursorHollowRect, cursorBar, cursorUnderline
    }

    /// Face.renderGlyph: `cp` over `cells` cells (the full cursors: the cursor height, centered on
    /// the cell), trimmed to its drawn pixels. nil: not a sprite.
    public static func render(_ cp: UInt32, _ m: CellMetrics, cells: Int) -> RasterGlyph? {
        guard let draw = drawer(cp) else { return nil }
        let tall = [Special.cursorRect, .cursorHollowRect, .cursorBar].contains { $0.rawValue == cp }
        let c = Canvas(Int(m.cellWidth) * max(cells, 1), Int(tall ? m.cursorHeight : m.cellHeight), m)
        draw(c, cp)
        return c.glyph(shift: (Int(m.cellHeight) - c.height) / 2)
    }

    /// Whether Ghostty draws `cp` itself (hasCodepoint).
    public static func has(_ cp: UInt32) -> Bool { drawer(cp) != nil }

    typealias Draw = @Sendable (Canvas, UInt32) -> Void

    static func drawer(_ cp: UInt32) -> Draw? {
        if let s = Special(rawValue: cp) { return { c, _ in c.special(s) } }
        var (lo, hi) = (0, drawers.count)
        while lo < hi {
            let mid = (lo + hi) / 2
            if cp < drawers[mid].range.lowerBound { hi = mid } else if cp > drawers[mid].range.upperBound { lo = mid + 1 } else { return drawers[mid].draw }
        }
        return nil
    }

    /// The draw functions by code point range, sorted (draw/*.zig `draw<MIN>_<MAX>`).
    static let drawers: [(range: ClosedRange<UInt32>, draw: Draw)] = [
        (0x2500...0x257F, { $0.box($1) }), (0x2580...0x259F, { $0.block($1) }), (0x25E2...0x25E5, { $0.geometric($1) }),
        (0x25F8...0x25FA, { $0.geometric($1) }), (0x25FF...0x25FF, { $0.geometric($1) }), (0x2800...0x28FF, { $0.braille($1) }),
        (0xE0B0...0xE0BF, { $0.powerline($1) }), (0xE0D2...0xE0D2, { $0.powerline($1) }), (0xE0D4...0xE0D4, { $0.powerline($1) }),
        (0xF5D0...0xF60D, { $0.branch($1) }), (0x1CC1B...0x1CC1E, { $0.supplement($1) }), (0x1CC21...0x1CC3F, { $0.supplement($1) }),
        (0x1CD00...0x1CDE5, { $0.supplement($1) }), (0x1CE00...0x1CE01, { $0.supplement($1) }), (0x1CE0B...0x1CE0C, { $0.supplement($1) }),
        (0x1CE16...0x1CE19, { $0.supplement($1) }), (0x1CE51...0x1CEAF, { $0.supplement($1) }), (0x1FB00...0x1FBAF, { $0.legacy($1) }),
        (0x1FBBD...0x1FBBF, { $0.legacy($1) }), (0x1FBCE...0x1FBEF, { $0.legacy($1) }),
    ]

    /// canvas.zig Canvas: an 8-bit alpha surface with a quarter of the size as padding on every side
    /// (drawings may overflow the cell); the transparent borders are trimmed at the end unless a
    /// drawer clips to the cell.
    final class Canvas {
        let width: Int, height: Int, m: CellMetrics, pad: (x: Int, y: Int), stride: Int, rows: Int
        var pixels: [UInt8], clip = (top: 0, left: 0, right: 0, bottom: 0)

        init(_ width: Int, _ height: Int, _ m: CellMetrics) {
            (self.width, self.height, self.m, pad) = (width, height, m, (width / 4, height / 4))
            (stride, rows) = (width + 2 * pad.x, height + 2 * pad.y)
            pixels = [UInt8](repeating: 0, count: stride * rows)
        }

        func pixel(_ x: Int, _ y: Int, _ a: UInt8) {
            let (px, py) = (x + pad.x, y + pad.y)
            if px >= 0, py >= 0, px < stride, py < rows { pixels[py * stride + px] = a }
        }
        /// Pixels outside the surface are dropped.
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ a: UInt8 = 255) {
            let (x0, x1, y0, y1) = (max(x + pad.x, 0), min(x + w + pad.x, stride), max(y + pad.y, 0), min(y + h + pad.y, rows))
            guard x0 < x1, y0 < y1 else { return }
            for py in y0..<y1 { pixels.replaceSubrange(py * stride + x0..<py * stride + x1, with: repeatElement(a, count: x1 - x0)) }
        }
        func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ a: UInt8 = 255) { rect(min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0), a) }
        func invert() { for i in pixels.indices { pixels[i] = 255 - pixels[i] } }
        /// (Ghostty also swaps the side clips; no drawer clips before flipping.)
        func flipHorizontal() {
            for y in 0..<rows { pixels[y * stride..<(y + 1) * stride].reverse() }
        }
        /// Drawers that fill past the cell (then invert, or draw circles) keep only the cell.
        func clipToCell() { clip = (pad.y, pad.x, pad.x, pad.y) }

        /// A path in cell coordinates (the padding is its translation).
        func path() -> Path { Path(ctm: Translation(tx: Double(pad.x), ty: Double(pad.y))) }

        /// canvas.trim + writeAtlas + the offsets of Face.renderGlyph (`shift`: the cursor centering).
        func glyph(shift: Int) -> RasterGlyph {
            let blank = { (ys: Range<Int>, xs: Range<Int>) in ys.allSatisfy { y in xs.allSatisfy { self.pixels[y * self.stride + $0] == 0 } } }
            while clip.top < rows - clip.bottom, blank(clip.top..<clip.top + 1, clip.left..<stride - clip.right) { clip.top += 1 }
            while clip.bottom < rows - clip.top, blank(rows - clip.bottom - 1..<rows - clip.bottom, clip.left..<stride - clip.right) { clip.bottom += 1 }
            while clip.left < stride - clip.right, blank(clip.top..<rows - clip.bottom, clip.left..<clip.left + 1) { clip.left += 1 }
            while clip.right < stride - clip.left, blank(clip.top..<rows - clip.bottom, stride - clip.right - 1..<stride - clip.right) { clip.right += 1 }
            let (w, h) = (max(0, stride - clip.left - clip.right), max(0, rows - clip.top - clip.bottom))
            var out = [UInt8]()
            for y in clip.top..<clip.top + h { out += pixels[y * stride + clip.left..<y * stride + clip.left + w] }
            return RasterGlyph(width: w, height: h, offsetX: clip.left - pad.x, offsetY: h + clip.bottom - pad.y + shift, color: false, pixels: out)
        }

        // Metrics as signed pixels.
        var cw: Int { Int(m.cellWidth) }
        var ch: Int { Int(m.cellHeight) }
        var thickness: Int { Int(m.boxThickness) }
    }
}

extension Sprite.Canvas {
    /// common.zig Thickness: light (1) or heavy (2) box lines (Ghostty's super light is unused).
    func thick(_ level: Int) -> Int { thickness * level }

    /// common.zig Fraction.min/max: a cell fraction's pixel edge (rounded toward the inside).
    func fill(_ x0: Double, _ x1: Double, _ y0: Double, _ y1: Double) {
        let lo = { (f: Double, s: Int) in Int(Double(s) - ((1 - f) * Double(s)).rounded()) }
        let hi = { (f: Double, s: Int) in Int((f * Double(s)).rounded()) }
        box(lo(x0, cw), lo(y0, ch), hi(x1, cw), hi(y1, ch))
    }
    func hline(_ x0: Int, _ x1: Int, _ y: Int, _ t: Int) { box(x0, y, x1, y + t) }
    func vline(_ y0: Int, _ y1: Int, _ x: Int, _ t: Int) { box(x, y0, x + t, y1) }
    func hlineMiddle(_ level: Int) { hline(0, cw, max(ch - thick(level), 0) / 2, thick(level)) }
    func vlineMiddle(_ level: Int) { vline(0, ch, max(cw - thick(level), 0) / 2, thick(level)) }

    /// painter.fill: non-zero winding, 4x multisampled, curves flattened.
    func fill(_ p: Sprite.Path, _ a: UInt8 = 255) {
        guard !p.nodes.isEmpty else { return }
        raster(Sprite.fillPolygon(p.nodes, scale: 4, tolerance: Sprite.tolerance), a)
    }
    /// painter.stroke; `ctm`: the translation a drawing context strokes with (canvas paths: none).
    func stroke(_ p: Sprite.Path, _ width: Double, cap: Sprite.Cap = .butt, ctm: Sprite.Translation = .init(), _ a: UInt8 = 255) {
        guard !p.nodes.isEmpty else { return }
        var s = Sprite.Stroker(width: max(width, 0.00390625), cap: width >= 2 ? cap : .butt, join: .miter, ctm: ctm, scale: 4)
        raster(s.run(p.nodes), a)
    }
    /// canvas.innerStrokePath: the path moved inward by half the width, then stroked.
    func innerStroke(_ p: Sprite.Path, _ width: Double) {
        var inset = Sprite.Path()
        inset.nodes = Sprite.offset(p.nodes, by: -width / 2)
        stroke(inset, width)
    }
    func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ width: Double) {
        var p = path()
        p.move(x0, y0)
        p.line(x1, y1)
        stroke(p, width)
    }
    /// canvas.triangle / canvas.quad: a filled polygon.
    func polygon(_ pts: [XY], _ a: UInt8 = 255) {
        var p = path()
        p.move(pts[0].x, pts[0].y)
        for q in pts.dropFirst() { p.line(q.x, q.y) }
        p.close()
        fill(p, a)
    }

    /// multisample.zig run: per pixel row, 4 sub-rows of edge crossings (at sub-pixel centers) give
    /// spans of 4x4 coverage; full coverage paints, partial coverage blends in (src over).
    /// (z2d skips polygons outside the surface and rescans active edges only at breakpoints; both
    /// only save work: nothing outside draws, and the active edges are the same.)
    func raster(_ poly: Sprite.Polygon, _ a: UInt8) {
        let clamp = { (v: Int, lo: Int, hi: Int) in min(max(v, lo), hi) }
        let top = clamp(Int((poly.top / 4).rounded(.down)), 0, rows - 1), bottom = clamp(Int((poly.bottom / 4).rounded(.up)), top, rows - 1)
        let left = clamp(Int((poly.left / 4).rounded(.down)), 0, stride - 1), right = clamp(Int((poly.right / 4).rounded(.up)), left, stride)
        let (span, left4) = ((right - left) * 4, left * 4)
        for y in top...bottom {
            var coverage = [Int](repeating: 0, count: right - left)
            for sub in 0..<4 {
                let mid = Double(y * 4 + sub) + 0.5
                // The edges crossing this sub-row's center.
                let crossings = poly.edges.filter { $0.top < mid && $0.bottom >= mid }.map { (x: Int(($0.x + $0.inc * (mid - $0.top)).rounded()), dir: $0.dir) }.sorted { $0.x < $1.x }
                // Non-zero winding: spans start where the winding leaves 0 and end where it returns.
                var (xs, winding) = ([Int](), 0)
                for c in crossings {
                    if winding == 0 { xs.append(c.x) }
                    winding += c.dir
                    if winding == 0 { xs.append(c.x) }
                }
                var from = 0
                for i in Swift.stride(from: 0, to: xs.count - 1, by: 2) {
                    let start = max(from, xs[i] - left4)
                    if start >= span { break }
                    let end = clamp(xs[i + 1] - left4, start, span)
                    for x in start..<end { coverage[x / 4] += 1 }
                    from = end
                }
            }
            for (i, c) in coverage.enumerated() where c > 0 {
                let at = y * stride + left + i, d = Int(pixels[at])
                // Integer src-over; partial coverage scales the source alpha first (dst-in).
                let s = c >= 16 ? Int(a) : Int(a) * clamp(c * 16 - 1, 0, 255) / 255
                pixels[at] = UInt8(s + d - s * d / 255)
            }
        }
    }
}
