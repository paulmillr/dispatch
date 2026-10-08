// Ghostty's sprite draw functions (font/sprite/draw/*.zig), one per code point range. Sizes come
// from the cell metrics (`cw`, `ch`, box `thickness`); a few read the canvas size instead (as in
// Ghostty: braille, powerline, the separated quadrants/sextants). Tables were extracted from the
// Zig sources (the line styles of box drawing, the smooth mosaics, the octants).

extension Sprite.Canvas {
    typealias XY = (x: Double, y: Double)

    // MARK: special.zig: decorations and cursors

    func special(_ s: Sprite.Special) {
        let (ul, ut, ct) = (Int(m.underlinePosition), Int(m.underlineThickness), Int(m.cursorThickness))
        let low = { (t: Int) in min(ul, max(self.height + self.pad.y - t, 0)) }   // the lowest line still on the canvas
        switch s {
        case .underline: rect(0, low(ut), width, ut)
        case .underlineDouble:
            let y = low(2 * ut)
            rect(0, max(y - ut, 0), width, ut)
            rect(0, y + ut, width, ut)
        case .underlineDotted:
            let (w, t, r) = (Double(width), Double(ut), 0.5.squareRoot() * Double(ut))
            let y = min(Double(ul) + 0.5 * t, Double(height) + Double(pad.y) - r.rounded(.up))
            let n = max(min((w / (4 * r)).rounded(.up), (w / (3 * r)).rounded(.down), (w / (2 * r + 1)).rounded(.down)), 1.0)
            var (p, x) = (path(), w / n / 2)
            for _ in 0..<Int(n) {
                p.arc(x, y, r, 0, 2 * .pi)
                p.close()
                x += w / n
            }
            fill(p)
        case .underlineDashed:
            let (y, dash) = (low(ut), width / 3 + 1)
            for i in Swift.stride(from: 0, to: width / dash + 1, by: 2) { rect(i * dash, y, dash, ut) }
        case .underlineCurly:
            let (w, lw) = (Double(width), Double(ut))
            let amplitude = w / .pi
            let top = min(Double(ul), Double(height) + Double(pad.y) - amplitude - lw), bottom = top + amplitude
            let (r, center) = (0.4, 0.5 * w)
            var p = path()
            p.move(0, bottom)
            p.curve(center * r, bottom, center - center * r, top, center, top)
            p.curve(center + center * r, top, w - center * r, bottom, w, bottom)
            stroke(p, lw, cap: .round, ctm: p.ctm)
        case .strikethrough: rect(0, Int(m.strikethroughPosition), width, Int(m.strikethroughThickness))
        case .overline: rect(0, max(Int(m.overlinePosition), -pad.y), width, Int(m.overlineThickness))
        case .cursorRect: rect(0, 0, width, height)
        case .cursorHollowRect:
            rect(0, 0, width, height)
            rect(ct, ct, max(width - ct * 2, 0), max(height - ct * 2, 0), 0)
        case .cursorBar: rect(-((ct + 1) / 2), 0, ct, height)
        case .cursorUnderline: rect(0, low(ut), width, ct)
        }
    }

    // MARK: box.zig

    /// Line styles of U+2500...U+257F (0: drawn otherwise): 2 bits each for up, right, down, left
    /// (none, light, heavy, double).
    static let lines: [UInt8] = [
        0x44, 0x88, 0x11, 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0x14, 0x18, 0x24, 0x28, 0x50, 0x90, 0x60, 0xA0, 0x05, 0x09, 0x06, 0x0A,
        0x41, 0x81, 0x42, 0x82, 0x15, 0x19, 0x16, 0x25, 0x26, 0x1A, 0x29, 0x2A, 0x51, 0x91, 0x52, 0x61, 0x62, 0x92, 0xA1, 0xA2,
        0x54, 0x94, 0x58, 0x98, 0x64, 0xA4, 0x68, 0xA8, 0x45, 0x85, 0x49, 0x89, 0x46, 0x86, 0x4A, 0x8A, 0x55, 0x95, 0x59, 0x99,
        0x56, 0x65, 0x66, 0x96, 0x5A, 0xA5, 0x69, 0x9A, 0xA9, 0xA6, 0x6A, 0xAA, 0, 0, 0, 0, 0xCC, 0x33, 0x1C, 0x34, 0x3C, 0xD0,
        0x70, 0xF0, 0x0D, 0x07, 0x0F, 0xC1, 0x43, 0xC3, 0x1D, 0x37, 0x3F, 0xD1, 0x73, 0xF3, 0xDC, 0x74, 0xFC, 0xCD, 0x47, 0xCF,
        0xDD, 0x77, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0x40, 0x01, 0x04, 0x10, 0x80, 0x02, 0x08, 0x20, 0x48, 0x21, 0x84, 0x12,
    ]

    func box(_ cp: UInt32) {
        let style = Self.lines[Int(cp - 0x2500)]
        if style != 0 { return lines(style) }
        switch cp {
        case 0x2504...0x250B:
            let k = Int(cp - 0x2504) % 4
            dashes(cp < 0x2508 ? 3 : 4, horizontal: k < 2, thick(k % 2 + 1), max(4, thick(1)))
        case 0x254C...0x254F:
            let k = Int(cp - 0x254C)
            dashes(2, horizontal: k < 2, thick(k % 2 + 1), thick(k == 0 ? 1 : 2))
        case 0x256D: arc(1, 1)
        case 0x256E: arc(-1, 1)
        case 0x256F: arc(-1, -1)
        case 0x2570: arc(1, -1)
        case 0x2571: diagonal(up: true)
        case 0x2572: diagonal(up: false)
        default:
            diagonal(up: true)
            diagonal(up: false)
        }
    }

    /// linesChar: each side's line from the edge to the middle; where lines meet, they reach just
    /// far enough to join (heavy over light, doubles leaving a gap).
    func lines(_ style: UInt8) {
        let (up, right, down, left) = (style & 3, style >> 2 & 3, style >> 4 & 3, style >> 6 & 3)
        let (light, heavy) = (thick(1), thick(2))
        let (hLightTop, hHeavyTop) = (max(ch - light, 0) / 2, max(ch - heavy, 0) / 2)
        let (hLightBottom, hHeavyBottom) = (hLightTop + light, hHeavyTop + heavy)
        let (hDoubleTop, hDoubleBottom) = (max(hLightTop - light, 0), hLightBottom + light)
        let (vLightLeft, vHeavyLeft) = (max(cw - light, 0) / 2, max(cw - heavy, 0) / 2)
        let (vLightRight, vHeavyRight) = (vLightLeft + light, vHeavyLeft + heavy)
        let (vDoubleLeft, vDoubleRight) = (max(vLightLeft - light, 0), vLightRight + light)
        // How far a vertical line reaches into the horizontal ones (and the other way around).
        let reach = { (a: UInt8, b: UInt8, c: UInt8, d: UInt8, heavy: Int, double: Int, light: Int, other: Int) -> Int in
            if a == 2 || b == 2 { return heavy }
            if a != b || c == d { return a == 3 || b == 3 ? double : light }
            return a == 0 && b == 0 ? light : other
        }
        let upBottom = reach(left, right, down, up, hHeavyBottom, hDoubleBottom, hLightBottom, hLightTop)
        let downTop = reach(left, right, up, down, hHeavyTop, hDoubleTop, hLightTop, hLightBottom)
        let leftRight = reach(up, down, left, right, vHeavyRight, vDoubleRight, vLightRight, vLightLeft)
        let rightLeft = reach(up, down, right, left, vHeavyLeft, vDoubleLeft, vLightLeft, vLightRight)
        switch up {
        case 1: box(vLightLeft, 0, vLightRight, upBottom)
        case 2: box(vHeavyLeft, 0, vHeavyRight, upBottom)
        case 3:
            box(vDoubleLeft, 0, vLightLeft, left == 3 ? hLightTop : upBottom)
            box(vLightRight, 0, vDoubleRight, right == 3 ? hLightTop : upBottom)
        default: break
        }
        switch right {
        case 1: box(rightLeft, hLightTop, cw, hLightBottom)
        case 2: box(rightLeft, hHeavyTop, cw, hHeavyBottom)
        case 3:
            box(up == 3 ? vLightRight : rightLeft, hDoubleTop, cw, hLightTop)
            box(down == 3 ? vLightRight : rightLeft, hLightBottom, cw, hDoubleBottom)
        default: break
        }
        switch down {
        case 1: box(vLightLeft, downTop, vLightRight, ch)
        case 2: box(vHeavyLeft, downTop, vHeavyRight, ch)
        case 3:
            box(vDoubleLeft, left == 3 ? hLightBottom : downTop, vLightLeft, ch)
            box(vLightRight, right == 3 ? hLightBottom : downTop, vDoubleRight, ch)
        default: break
        }
        switch left {
        case 1: box(0, hLightTop, leftRight, hLightBottom)
        case 2: box(0, hHeavyTop, leftRight, hHeavyBottom)
        case 3:
            box(0, hDoubleTop, up == 3 ? vLightLeft : leftRight, hLightTop)
            box(0, hLightBottom, down == 3 ? vLightLeft : leftRight, hDoubleBottom)
        default: break
        }
    }

    /// lightDiagonal*: a light line corner to corner, a little past the cell.
    func diagonal(up: Bool) {
        let (w, h) = (Double(cw), Double(ch))
        let (sx, sy) = (min(1.0, w / h), min(1.0, h / w))
        if up { line(w + 0.5 * sx, -0.5 * sy, -0.5 * sx, h + 0.5 * sy, Double(thick(1))) }
        else { line(-0.5 * sx, -0.5 * sy, w + 0.5 * sx, h + 0.5 * sy, Double(thick(1))) }
    }

    /// box.zig arc: a rounded corner from the middle of the edge `sy` (-1 top, 1 bottom) to the
    /// middle of the edge `sx` (-1 left, 1 right).
    func arc(_ sx: Double, _ sy: Double) {
        let t = thick(1)
        let (w, h, ft) = (Double(cw), Double(ch), Double(t))
        let (x, y) = (Double(max(cw - t, 0) / 2) + ft / 2, Double(max(ch - t, 0) / 2) + ft / 2)
        let (r, s) = (min(w, h) / 2, 0.25)
        var p = path()
        p.move(x, sy < 0 ? 0 : h)
        p.line(x, y + sy * r)
        p.curve(x, y + sy * s * r, x + sx * s * r, y, x + sx * r, y)
        p.line(sx < 0 ? 0 : w, y)
        stroke(p, ft)
    }

    /// dashHorizontal / dashVertical: `n` dashes with gaps between (a plain middle line when the cell
    /// is too small); leftover pixels widen the first dashes.
    func dashes(_ n: Int, horizontal: Bool, _ t: Int, _ gap: Int) {
        let size = horizontal ? cw : ch
        guard size >= 2 * n else { return horizontal ? hlineMiddle(1) : vlineMiddle(1) }
        let g = min(gap, size / (2 * n)), total = size - n * g
        var (at, extra) = (horizontal ? g / 2 : 0, total % n)
        for _ in 0..<n {
            var end = at + total / n
            if extra > 0 { (extra, end) = (extra - 1, end + 1) }
            if horizontal { hline(at, end, max(ch - t, 0) / 2, t) } else { vline(at, end, max(cw - t, 0) / 2, t) }
            at = end + g
        }
    }

    // MARK: block.zig

    /// blockShade: a `fw` x `fh` fraction of the cell aligned by `h` (-1 left, 0 center, 1 right)
    /// and `v` (-1 top, 0 middle, 1 bottom).
    func block(_ h: Int, _ v: Int, _ fw: Double, _ fh: Double, _ a: UInt8 = 255) {
        let (w, bh) = (Int((Double(cw) * fw).rounded()), Int((Double(ch) * fh).rounded()))
        let place = { (align: Int, size: Int, part: Int) in align < 0 ? 0 : align > 0 ? size - part : (size - part) / 2 }
        rect(place(h, cw, w), place(v, ch, bh), w, bh, a)
    }

    /// quadrant: bits tl, tr, bl, br.
    func quadrants(_ q: Int) {
        for (bit, x, y) in [(1, 0.0, 0.0), (2, 0.5, 0.0), (4, 0.0, 0.5), (8, 0.5, 0.5)] where q & bit != 0 { fill(x, x + 0.5, y, y + 0.5) }
    }

    func block(_ cp: UInt32) {
        let i = Int(cp - 0x2580)
        switch cp {
        case 0x2580: block(0, -1, 1, 0.5)
        case 0x2581...0x2587: block(0, 1, 1, Double(i) / 8)
        case 0x2588: box(0, 0, cw, ch)
        case 0x2589...0x258F: block(-1, 0, Double(16 - i) / 8, 1)
        case 0x2590: block(1, 0, 0.5, 1)
        case 0x2591...0x2593: box(0, 0, cw, ch, UInt8(0x40 * (i - 0x10)))
        case 0x2594: block(0, -1, 1, 0.125)
        case 0x2595: block(1, 0, 0.125, 1)
        default: quadrants([4, 8, 1, 13, 9, 7, 11, 2, 6, 14][i - 0x16])
        }
    }

    // MARK: braille.zig

    /// Eight dots in two columns, spaced to fill the canvas evenly (leftover pixels go to dot size,
    /// margins and spacing in a fixed order).
    func braille(_ cp: UInt32) {
        var (w, xs, ys) = (min(width / 4, height / 8), width / 4, height / 8)
        var (xm, ym) = (xs / 2, ys / 2)
        var (xl, yl) = (width - 2 * xm - xs - 2 * w, height - 2 * ym - 3 * ys - 4 * w)
        if xl >= 2 && yl >= 4 && w == 0 { (w, xl, yl) = (w + 1, xl - 2, yl - 4) }
        if xl >= 2 && xm == 0 { (xm, xl) = (1, xl - 2) }
        if yl >= 2 && ym == 0 { (ym, yl) = (1, yl - 2) }
        if xl >= 1 { (xs, xl) = (xs + 1, xl - 1) }
        if yl >= 3 { (ys, yl) = (ys + 1, yl - 3) }
        if xl >= 2 { (xm, xl) = (xm + 1, xl - 2) }
        if yl >= 2 { (ym, yl) = (ym + 1, yl - 2) }
        if xl >= 2 && yl >= 4 { w += 1 }
        let x = [xm, xm + w + xs], y = (0..<4).map { ym + $0 * (w + ys) }
        // Bits: tl ul ll tr ur lr bl br (the Unicode dot order).
        for (bit, (cx, cy)) in [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)].enumerated() where cp & 1 << bit != 0 {
            box(x[cx], y[cy], x[cx] + w, y[cy] + w)
        }
    }

    // MARK: geometric_shapes.zig

    /// The corner triangles of U+25E2...U+25E5 (filled) and U+25F8...U+25FA, U+25FF (outlined).
    func geometric(_ cp: UInt32) {
        switch cp {
        case 0x25E2: cornerTriangle(3)
        case 0x25E3: cornerTriangle(2)
        case 0x25E4: cornerTriangle(0)
        case 0x25E5: cornerTriangle(1)
        case 0x25F8...0x25FA: cornerTriangle(Int(cp - 0x25F8), outline: true)
        default: cornerTriangle(3, outline: true)
        }
    }

    /// cornerTriangleShade / cornerTriangleOutline: corners tl, tr, bl, br.
    func cornerTriangle(_ corner: Int, _ a: UInt8 = 255, outline: Bool = false) {
        let (w, h) = (Double(cw), Double(ch))
        let pts: [XY] = [[(0, 0), (0, h), (w, 0)], [(0, 0), (w, h), (w, 0)], [(0, 0), (0, h), (w, h)], [(0, h), (w, h), (w, 0)]][corner]
        guard outline else { return polygon(pts, a) }
        var p = path()
        p.move(pts[0].x, pts[0].y)
        for q in pts.dropFirst() { p.line(q.x, q.y) }
        p.close()
        innerStroke(p, Double(thick(1)))
    }

    // MARK: powerline.zig (sizes from the canvas)

    func powerline(_ cp: UInt32) {
        let (w, h) = (Double(width), Double(height))
        let c = (2.0.squareRoot() - 1.0) * 4.0 / 3.0, r = min(w, h / 2)
        switch cp {
        case 0xE0B0: polygon([(0, 0), (w, h / 2), (0, h)])
        case 0xE0B2: polygon([(w, 0), (0, h / 2), (w, h)])
        case 0xE0B8: polygon([(0, 0), (w, h), (0, h)])
        case 0xE0BA: polygon([(w, 0), (w, h), (0, h)])
        case 0xE0BC: polygon([(0, 0), (w, 0), (0, h)])
        case 0xE0BE: polygon([(0, 0), (w, 0), (w, h)])
        case 0xE0B9, 0xE0BF: diagonal(up: false)
        case 0xE0BB, 0xE0BD: diagonal(up: true)
        case 0xE0B1, 0xE0B3:
            var p = path()
            p.move(0, 0)
            p.line(w, h / 2)
            p.line(0, h)
            stroke(p, Double(thick(1)))
            if cp == 0xE0B3 { flipHorizontal() }
        case 0xE0B4, 0xE0B6:
            var p = path()
            p.move(0, 0)
            p.curve(r * c, 0, r, r - r * c, r, r)
            p.line(r, h - r)
            p.curve(r, h - r + r * c, r * c, h, 0, h)
            p.close()
            fill(p)
            if cp == 0xE0B6 { flipHorizontal() }
        case 0xE0B5, 0xE0B7:
            var p = path()
            p.move(0, 0)
            p.line(1, 0)
            p.curve(r * c, 0, r, r - r * c, r, r)
            p.line(r, h - r)
            p.curve(r, h - r + r * c, r * c, h, 1, h)
            p.line(0, h)
            innerStroke(p, Double(thickness))
            if cp == 0xE0B7 { flipHorizontal() }
        default:
            let t = Double(thickness)
            polygon([(0, 0), (w, 0), (w / 2, h / 2 - t / 2), (0, h / 2 - t / 2)])
            polygon([(0, h), (w, h), (w / 2, h / 2 + t / 2), (0, h / 2 + t / 2)])
            if cp == 0xE0D4 { flipHorizontal() }
        }
    }

    // MARK: branch.zig

    func branch(_ cp: UInt32) {
        let i = Int(cp - 0xF5D0)
        switch i {
        case 0: hlineMiddle(1)
        case 1: vlineMiddle(1)
        case 2...5: fading(i - 2)
        case 6...29:
            // Lines and arcs, in drawing order: h, v, or a corner (tl, tr, bl, br).
            let ops = ["br", "bl", "tr", "tl", "v tr", "v br", "tr br", "v tl", "v bl", "tl bl", "bl h", "br h", "br bl", "tl h", "tr h", "tr tl",
                       "v tl tr", "v bl br", "h bl tl", "h tr br", "v tl br", "v tr bl", "h tl br", "h tr bl"][i - 6]
            for op in ops.split(separator: " ") {
                switch op {
                case "h": hlineMiddle(1)
                case "v": vlineMiddle(1)
                default: arc(op.hasSuffix("l") ? -1 : 1, op.hasPrefix("t") ? -1 : 1)
                }
            }
        default:
            // Nodes: filled then hollow, for each set of lines (bits up, right, down, left).
            node([0, 2, 8, 10, 4, 1, 5, 6, 12, 3, 9, 7, 13, 14, 11, 15][(i - 30) / 2], filled: i % 2 == 0)
        }
    }

    /// branchNode: a circle in the middle with lines out to the edges.
    func node(_ sides: Int, filled: Bool) {
        let t = thick(1)
        let (w, h, ft) = (Double(cw), Double(ch), Double(t))
        let (hTop, vLeft) = (max(ch - t, 0) / 2, max(cw - t, 0) / 2)
        let (x, y) = (Double(vLeft) + ft / 2, Double(hTop) + ft / 2)
        let r = min(min(x, y), min(w - x, h - y))
        if sides & 1 != 0 { box(vLeft, 0, vLeft + t, Int((y - r + ft / 2).rounded(.up))) }
        if sides & 2 != 0 { box(Int((x + r - ft / 2).rounded(.down)), hTop, cw, hTop + t) }
        if sides & 4 != 0 { box(vLeft, Int((y + r - ft / 2).rounded(.down)), vLeft + t, ch) }
        if sides & 8 != 0 { box(0, hTop, Int((x - r + ft / 2).rounded(.up)), hTop + t) }
        circle(x, y, r, filled ? nil : ft)
    }

    /// A circle through a drawing context (its translation applies to the stroke): filled
    /// (`width` nil) or stroked inside the radius.
    func circle(_ x: Double, _ y: Double, _ r: Double, _ width: Double?) {
        var p = path()
        p.arc(x, y, r - (width ?? 0) / 2, 0, .pi * 2)
        p.close()
        if let width { stroke(p, width, ctm: p.ctm) } else { fill(p) }
    }

    /// fadingLine to the right, left, bottom, top: a light line fading out towards that edge.
    func fading(_ to: Int) {
        let t = thick(1)
        let (hTop, vLeft) = (max(ch - t, 0) / 2, max(cw - t, 0) / 2)
        let vertical = to >= 2
        let size = Double(vertical ? ch : cw)
        var color = to % 2 == 0 ? 255.0 : 0.0
        let inc = 255.0 / (to % 2 == 0 ? -size : size)
        for i in 0..<(vertical ? ch : cw) {
            for j in vertical ? vLeft..<vLeft + t : hTop..<hTop + t {
                if vertical { pixel(j, i, UInt8(color.rounded())) } else { pixel(i, j, UInt8(color.rounded())) }
            }
            color += inc
        }
    }

    // MARK: symbols_for_legacy_computing.zig

    /// Smooth mosaics U+1FB3C...U+1FB67 as 4 rows of 3 characters ('#' filled; the polygon runs
    /// through the filled corners and edge middles).
    static let mosaics = [
        "......#..##.", "......#\\.###", "...#..#\\.##.", "...#..##.###", "#..#..##.##.", "/###########", "./##########", ".##.########",
        "..#.########", ".##.##.#####", "..../#######", "........#.##", "......./####", ".....#./#.##", ".....#.#####", "..#..#.##.##",
        "##\\#########", "#\\.#########", "##.##.######", "#..##.######", "##.##.##.###", "...#\\.######", "#########\\##", "#########.\\#",
        "######.##.##", "######.##..#", "###.##.##.##", "##.#........", "####/.......", "##.#/.#.....", "#####.#.....", "##.##.#..#..",
        "#######/....", "###########/", "##########/.", "########.##.", "########.#..", "#####.##.##.", ".##..#......", "###.\\#......",
        ".##.\\#..#...", "###.##..#...", ".##.##..#..#", "######.\\#...",
    ]

    func legacy(_ cp: UInt32) {
        let (w, h) = (Double(cw), Double(ch))
        switch cp {
        case 0x1FB00...0x1FB3B:
            // Sextants (skipping the ones that are half blocks): bits tl tr ml mr bl br.
            let i = Int(cp - 0x1FB00), s = i + i / 0x14 + 1
            for (bit, x, y0, y1) in [(0, 0.0, 0.0, 1.0 / 3.0), (1, 0.5, 0.0, 1.0 / 3.0), (2, 0.0, 1.0 / 3.0, 2.0 / 3.0), (3, 0.5, 1.0 / 3.0, 2.0 / 3.0),
                                     (4, 0.0, 2.0 / 3.0, 1.0), (5, 0.5, 2.0 / 3.0, 1.0)] where s & 1 << bit != 0 {
                fill(x, x == 0 ? 0.5 : 1, y0, y1)
            }
        case 0x1FB3C...0x1FB67:
            let pat = Array(Self.mosaics[Int(cp - 0x1FB3C)])
            let on = { (r: Int, c: Int) in pat[r * 3 + c] == "#" }
            let (upper, lower, center) = (1.0 / 3.0 * h, 2.0 / 3.0 * h, 0.5 * w)
            // SmoothMosaic.from: the filled boundary points in order (Ghostty leaves out an edge middle
            // between two filled neighbors: it lies on their line, the fill is the same).
            let points: [(Int, Int, Double, Double)] = [(0, 0, 0, 0), (1, 0, 0, upper), (2, 0, 0, lower), (3, 0, 0, h), (3, 1, center, h),
                                                        (3, 2, w, h), (2, 2, w, lower), (1, 2, w, upper), (0, 2, w, 0), (0, 1, center, 0)]
            var p = path()
            for (r, c, x, y) in points where on(r, c) { p.line(x, y) }
            p.close()
            fill(p)
        case 0x1FB68...0x1FB6F:
            edgeTriangle(Int(cp - 0x1FB68) % 4)
            if cp < 0x1FB6C {
                invert()
                clipToCell()
            }
        case 0x1FB70...0x1FB75: fill(Double(cp - 0x1FB6F) / 8, Double(cp - 0x1FB6E) / 8, 0, 1)
        case 0x1FB76...0x1FB7B: fill(0, 1, Double(cp - 0x1FB75) / 8, Double(cp - 0x1FB74) / 8)
        case 0x1FB7C...0x1FB80:
            let (hs, vs) = ([(-1, 1), (-1, -1), (1, -1), (1, 1), (0, 1)][Int(cp - 0x1FB7C)])
            if hs != 0 { block(hs, 0, 0.125, 1) } else { block(0, -1, 1, 0.125) }
            block(0, vs, 1, 0.125)
        case 0x1FB81: for n in [0, 2, 4, 7] { fill(0, 1, Double(n) / 8, Double(n + 1) / 8) }
        case 0x1FB82...0x1FB86: block(0, -1, 1, [0.25, 0.375, 0.625, 0.75, 0.875][Int(cp - 0x1FB82)])
        case 0x1FB87...0x1FB8B: block(1, 0, [0.25, 0.375, 0.625, 0.75, 0.875][Int(cp - 0x1FB87)], 1)
        case 0x1FB8C: block(-1, 0, 0.5, 1, 0x80)
        case 0x1FB8D: block(1, 0, 0.5, 1, 0x80)
        case 0x1FB8E: block(0, -1, 1, 0.5, 0x80)
        case 0x1FB8F: block(0, 1, 1, 0.5, 0x80)
        case 0x1FB90: box(0, 0, cw, ch, 0x80)
        case 0x1FB91, 0x1FB92, 0x1FB94:
            box(0, 0, cw, ch, 0x80)
            if cp == 0x1FB94 { block(1, 0, 0.5, 1) } else { block(0, cp == 0x1FB91 ? -1 : 1, 1, 0.5) }
        case 0x1FB93: break
        case 0x1FB95, 0x1FB96: checkerboard(Int(cp - 0x1FB95))
        case 0x1FB97:
            box(0, height / 4, width, 2 * height / 4)
            box(0, 3 * height / 4, width, height)
        case 0x1FB98, 0x1FB99:
            // Hatching: diagonal lines across (and past) the cell.
            clipToCell()
            let t = thick(1), n = cw / (2 * t)
            let step = (w / Double(n)).rounded()
            for k in -n...n {
                let x = Double(k) * step
                if cp == 0x1FB98 { line(x, 0, w + x, h, Double(t)) } else { line(w + x, 0, x, h, Double(t)) }
            }
        case 0x1FB9A:
            edgeTriangle(1)
            edgeTriangle(3)
        case 0x1FB9B:
            edgeTriangle(0)
            edgeTriangle(2)
        case 0x1FB9C...0x1FB9F: cornerTriangle([0, 1, 3, 2][Int(cp - 0x1FB9C)], 0x80)
        case 0x1FBA0...0x1FBAE: cornerDiagonals([1, 2, 4, 8, 5, 10, 12, 3, 9, 6, 14, 13, 11, 7, 15][Int(cp - 0x1FBA0)])
        case 0x1FBAF: lines(0x66)
        case 0x1FBBD...0x1FBBF:
            if cp == 0x1FBBD {
                diagonal(up: true)
                diagonal(up: false)
            } else { cornerDiagonals(cp == 0x1FBBE ? 8 : 15) }
            invert()
            clipToCell()
        case 0x1FBCE: block(-1, 0, 2.0 / 3.0, 1)
        case 0x1FBCF: block(-1, 0, 1.0 / 3.0, 1)
        case 0x1FBD0...0x1FBDF:
            // Diagonals between edge middles and corners: positions (x, y) in halves of the cell.
            let lines = [[(2, 1, 0, 2)], [(2, 0, 0, 1)], [(0, 0, 2, 1)], [(0, 1, 2, 2)], [(0, 0, 1, 2)], [(1, 0, 2, 2)], [(2, 0, 1, 2)], [(1, 0, 0, 2)],
                         [(0, 0, 1, 1), (1, 1, 2, 0)], [(2, 0, 1, 1), (1, 1, 2, 2)], [(0, 2, 1, 1), (1, 1, 2, 2)], [(0, 0, 1, 1), (1, 1, 0, 2)],
                         [(0, 0, 1, 2), (1, 2, 2, 0)], [(2, 0, 0, 1), (0, 1, 2, 2)], [(0, 2, 1, 0), (1, 0, 2, 2)], [(0, 0, 2, 1), (2, 1, 0, 2)]][Int(cp - 0x1FBD0)]
            let at = { (k: Int, size: Double) in k == 0 ? 0 : k == 2 ? size : size / 2 }
            for (x0, y0, x1, y1) in lines { line(at(x0, w), at(y0, h), at(x1, w), at(y1, h), Double(thick(1))) }
        case 0x1FBE4...0x1FBE7: block([0, 0, -1, 1][Int(cp - 0x1FBE4)], [-1, 1, 0, 0][Int(cp - 0x1FBE4)], 0.5, 0.5)
        default:
            // Circles on the edges (1FBE0 top, right, bottom, left) and corners (1FBEC tr, bl, br, tl).
            let (x, y) = ([(1, 0), (2, 1), (1, 2), (0, 1), (1, 0), (2, 1), (1, 2), (0, 1), (2, 0), (0, 2), (2, 2), (0, 0)][Int(cp - 0x1FBE0) - (cp >= 0x1FBE8 ? 4 : 0)])
            edgeCircle(x, y, filled: cp >= 0x1FBE8)
        }
    }

    /// symbols_for_legacy_computing.zig circle: a circle centered on an edge or corner (positions in
    /// halves of the cell), clipped to the cell.
    func edgeCircle(_ px: Int, _ py: Int, filled: Bool) {
        clipToCell()
        let (w, h) = (Double(cw), Double(ch))
        let at = { (k: Int, size: Double) in k == 0 ? 0 : k == 2 ? size : size / 2 }
        circle(at(px, w), at(py, h), 0.5 * min(w, h), filled ? nil : Double(thick(1)))
    }

    /// edgeTriangle left, top, right, bottom: from the cell's middle to that edge.
    func edgeTriangle(_ edge: Int) {
        let (w, h) = (Double(cw), Double(ch))
        let ends: [XY] = [[(0, 0), (0, h)], [(w, 0), (0, 0)], [(w, h), (w, 0)], [(0, h), (w, h)]][edge]
        polygon([((w / 2).rounded(), (h / 2).rounded())] + ends)
    }

    /// cornerDiagonalLines: bits tl tr bl br, lines from the middle of the top/bottom edge to the
    /// middle of the side.
    func cornerDiagonals(_ q: Int) {
        let (w, h, t) = (Double(cw), Double(ch), Double(thick(1)))
        let (x, y) = (Double(cw / 2 + cw % 2), Double(ch / 2 + ch % 2))
        if q & 1 != 0 { line(x, 0, 0, y, t) }
        if q & 2 != 0 { line(x, 0, w, y, t) }
        if q & 4 != 0 { line(x, h, 0, y, t) }
        if q & 8 != 0 { line(x, h, w, y, t) }
    }

    func checkerboard(_ parity: Int) {
        let ys = Int((4 * (Double(ch) / Double(cw))).rounded())
        for x in 0..<4 {
            for y in 0..<ys where (x + y) % 2 == parity {
                let (x0, x1, y0, y1) = (cw * x / 4, cw * (x + 1) / 4, ch * y / ys, ch * (y + 1) / ys)
                rect(x0, y0, max(x1 - x0, 0), max(y1 - y0, 0))
            }
        }
    }

    // MARK: symbols_for_legacy_computing_supplement.zig

    func supplement(_ cp: UInt32) {
        let (w, h, t) = (width, height, thickness)
        switch cp {
        case 0x1CC1B, 0x1CC1C:
            lines(0x44)
            box(w - t, cp == 0x1CC1B ? 0 : h / 2, w, cp == 0x1CC1B ? h / 2 : h)
        case 0x1CC1D:
            box(0, 0, w, t)
            box(0, 0, t, h / 2)
        case 0x1CC1E:
            box(0, h - t, w, h)
            box(0, h / 2, t, h)
        case 0x1CC21...0x1CC2F: separated(Int(cp - 0x1CC20), rows: 2)
        case 0x1CC30...0x1CC3F:
            let (x, y, pw, ph, corner) = [(0, 0, 2, 2, 0), (1, 0, 2, 2, 0), (2, 0, 2, 2, 1), (3, 0, 2, 2, 1), (0, 1, 2, 2, 0), (0, 0, 1, 1, 0), (1, 0, 1, 1, 1),
                                          (3, 1, 2, 2, 1), (0, 2, 2, 2, 2), (0, 1, 1, 1, 2), (1, 1, 1, 1, 3), (3, 2, 2, 2, 3), (0, 3, 2, 2, 2), (1, 3, 2, 2, 2),
                                          (2, 3, 2, 2, 3), (3, 3, 2, 2, 3)][Int(cp - 0x1CC30)]
            circlePiece(Double(x), Double(y), Double(pw), Double(ph), corner)
        case 0x1CD00...0x1CDE5:
            // Octants (bits in reading order), the ones no other character covers.
            let covered: Set = [0, 1, 2, 3, 5, 10, 15, 20, 40, 63, 64, 80, 85, 90, 95, 128, 160, 165, 170, 175, 192, 240, 245, 250, 252, 255]
            let o = (0...255).filter { !covered.contains($0) }[Int(cp - 0x1CD00)]
            for bit in 0..<8 where o & 1 << bit != 0 { fill(Double(bit % 2) / 2, Double(bit % 2 + 1) / 2, Double(bit / 2) / 4, Double(bit / 2 + 1) / 4) }
        case 0x1CE00:
            edgeCircle(0, 1, filled: false)
            edgeCircle(2, 1, filled: false)
        case 0x1CE01:
            edgeCircle(1, 0, filled: false)
            edgeCircle(1, 2, filled: false)
        case 0x1CE0B, 0x1CE0C:
            let x = cp == 0x1CE0B ? 0.0 : 1.0
            circlePiece(x, 0, 1, 0.5, cp == 0x1CE0B ? 0 : 1)
            circlePiece(x, 0, 1, 0.5, cp == 0x1CE0B ? 2 : 3)
        case 0x1CE16...0x1CE19:
            let i = Int(cp - 0x1CE16)
            lines(0x11)
            box(i < 2 ? w / 2 : 0, i % 2 == 0 ? 0 : h - t, i < 2 ? w : w / 2, i % 2 == 0 ? t : h)
        case 0x1CE51...0x1CE8F: separated(Int(cp - 0x1CE50), rows: 3)
        default:
            // Quarter-cell blocks: a column/row grid, then bars along the edges.
            let i = Int(cp - 0x1CE90)
            let q = i < 16 ? [i % 4, i % 4 + 1, i / 4, i / 4 + 1]
                : ["2434", "1434", "0334", "0234", "0124", "0114", "0103", "0102", "0201", "0301", "1401", "2401", "3402", "3403", "3414", "3424"][i - 16]
                    .map { $0.wholeNumberValue! }
            fill(Double(q[0]) / 4, Double(q[1]) / 4, Double(q[2]) / 4, Double(q[3]) / 4)
        }
    }

    /// Separated quadrants (2 rows) and sextants (3 rows): bits in reading order, blocks with gaps
    /// (the middle row takes the leftover height).
    func separated(_ bits: Int, rows: Int) {
        let gap = max(1, width / 12)
        let (midX, midY) = (gap * 2 + width % 2, gap * 2 + (rows == 2 ? height % 2 : height % 3 / 2))
        let w = (width - gap * 2 - midX) / 2
        let rest = height - gap * 2 - midY * (rows - 1), h = rest >= 0 ? rest / rows : -((-rest + rows - 1) / rows)   // floor division
        let mid = height - gap * 2 - midY * (rows - 1) - h * (rows - 1)
        var y = gap
        for row in 0..<rows {
            let rh = rows == 3 && row == 1 ? mid : h
            for col in 0..<2 where bits & 1 << (row * 2 + col) != 0 { box(gap + col * (w + midX), y, gap + col * (w + midX) + w, y + rh) }
            y += rh + midY
        }
    }

    /// circlePiece: a quarter ellipse of `pw` x `ph` canvases, shifted by (`x`, `y`) canvases,
    /// corners tl, tr, bl, br.
    func circlePiece(_ x: Double, _ y: Double, _ pw: Double, _ ph: Double, _ corner: Int) {
        let (w, h, xp, yp) = (Double(width) * pw, Double(height) * ph, Double(width) * x, Double(height) * y)
        clipToCell()
        let c = (2.0.squareRoot() - 1.0) * 4.0 / 3.0
        let (kw, kh, t) = (c * w, c * h, Double(thickness))
        let ht = t * 0.5
        var p = path()
        switch corner {
        case 0:
            p.move(w - xp, ht - yp)
            p.curve(w - kw - xp, ht - yp, ht - xp, h - kh - yp, ht - xp, h - yp)
        case 1:
            p.move(w - xp, ht - yp)
            p.curve(w + kw - xp, ht - yp, w * 2 - ht - xp, h - kh - yp, w * 2 - ht - xp, h - yp)
        case 2:
            p.move(ht - xp, h - yp)
            p.curve(ht - xp, h + kh - yp, w - kw - xp, h * 2 - ht - yp, w - xp, h * 2 - ht - yp)
        default:
            p.move(w * 2 - ht - xp, h - yp)
            p.curve(w * 2 - ht - xp, h + kh - yp, w + kw - xp, h * 2 - ht - yp, w - xp, h * 2 - ht - yp)
        }
        stroke(p, t)
    }
}
