// What the renderer draws of kitty graphics (renderer/image.zig kittyUpdate and
// kitty/graphics_unicode.zig): placements anchored on screen and relative ones, in the viewport;
// Unicode placeholder runs (U+10EEEE with row/column/id diacritics, image id in the foreground
// color, placement id in the underline color) for virtual placements; sorted by z, split into
// the layers below backgrounds, below text and above text.

/// One image to draw: its cell position in the viewport, z, the size in pixels, the offset in
/// its first cell and the source rectangle.
public struct ImageDraw: Equatable {
    public var image: UInt32, x: Int32, y: Int32, z: Int32, width: UInt32, height: UInt32
    public var cellOffsetX: UInt32, cellOffsetY: UInt32, sourceX: UInt32, sourceY: UInt32, sourceWidth: UInt32, sourceHeight: UInt32
}

public struct ImageDraws {
    /// In drawing order (z, then image id); [0, belowBackground) under the backgrounds,
    /// [belowBackground, belowText) under the text, the rest above it.
    public var draws: [ImageDraw] = [], belowBackground = 0, belowText = 0
    /// Virtual placements exist: redo every frame (placeholders move with the text).
    public var virtual = false
    /// The screen's images by id (a copy that shares their pixels): what the draws show, and which
    /// uploaded ones still exist at which generation.
    public var images: [UInt32: KittyImage] = [:]
    public init() {}
}

/// A run of placeholder cells on one row (graphics_unicode.zig Placement).
struct PlaceholderRun {
    var pin: Pin, imageID: UInt32, placementID: UInt32, col: UInt32, row: UInt32, width: UInt32

    static let placeholder: UInt32 = 0x10EEEE
    static let diacritics: [UInt32] = [0x0305,0x030D,0x030E,0x0310,0x0312,0x033D,0x033E,0x033F,0x0346,0x034A,0x034B,0x034C,0x0350,0x0351,0x0352,0x0357,0x035B,0x0363,0x0364,0x0365,0x0366,0x0367,0x0368,0x0369,0x036A,0x036B,0x036C,0x036D,0x036E,0x036F,0x0483,0x0484,0x0485,0x0486,0x0487,0x0592,0x0593,0x0594,0x0595,0x0597,0x0598,0x0599,0x059C,0x059D,0x059E,0x059F,0x05A0,0x05A1,0x05A8,0x05A9,0x05AB,0x05AC,0x05AF,0x05C4,0x0610,0x0611,0x0612,0x0613,0x0614,0x0615,0x0616,0x0617,0x0657,0x0658,0x0659,0x065A,0x065B,0x065D,0x065E,0x06D6,0x06D7,0x06D8,0x06D9,0x06DA,0x06DB,0x06DC,0x06DF,0x06E0,0x06E1,0x06E2,0x06E4,0x06E7,0x06E8,0x06EB,0x06EC,0x0730,0x0732,0x0733,0x0735,0x0736,0x073A,0x073D,0x073F,0x0740,0x0741,0x0743,0x0745,0x0747,0x0749,0x074A,0x07EB,0x07EC,0x07ED,0x07EE,0x07EF,0x07F0,0x07F1,0x07F3,0x0816,0x0817,0x0818,0x0819,0x081B,0x081C,0x081D,0x081E,0x081F,0x0820,0x0821,0x0822,0x0823,0x0825,0x0826,0x0827,0x0829,0x082A,0x082B,0x082C,0x082D,0x0951,0x0953,0x0954,0x0F82,0x0F83,0x0F86,0x0F87,0x135D,0x135E,0x135F,0x17DD,0x193A,0x1A17,0x1A75,0x1A76,0x1A77,0x1A78,0x1A79,0x1A7A,0x1A7B,0x1A7C,0x1B6B,0x1B6D,0x1B6E,0x1B6F,0x1B70,0x1B71,0x1B72,0x1B73,0x1CD0,0x1CD1,0x1CD2,0x1CDA,0x1CDB,0x1CE0,0x1DC0,0x1DC1,0x1DC3,0x1DC4,0x1DC5,0x1DC6,0x1DC7,0x1DC8,0x1DC9,0x1DCB,0x1DCC,0x1DD1,0x1DD2,0x1DD3,0x1DD4,0x1DD5,0x1DD6,0x1DD7,0x1DD8,0x1DD9,0x1DDA,0x1DDB,0x1DDC,0x1DDD,0x1DDE,0x1DDF,0x1DE0,0x1DE1,0x1DE2,0x1DE3,0x1DE4,0x1DE5,0x1DE6,0x1DFE,0x20D0,0x20D1,0x20D4,0x20D5,0x20D6,0x20D7,0x20DB,0x20DC,0x20E1,0x20E7,0x20E9,0x20F0,0x2CEF,0x2CF0,0x2CF1,0x2DE0,0x2DE1,0x2DE2,0x2DE3,0x2DE4,0x2DE5,0x2DE6,0x2DE7,0x2DE8,0x2DE9,0x2DEA,0x2DEB,0x2DEC,0x2DED,0x2DEE,0x2DEF,0x2DF0,0x2DF1,0x2DF2,0x2DF3,0x2DF4,0x2DF5,0x2DF6,0x2DF7,0x2DF8,0x2DF9,0x2DFA,0x2DFB,0x2DFC,0x2DFD,0x2DFE,0x2DFF,0xA66F,0xA67C,0xA67D,0xA6F0,0xA6F1,0xA8E0,0xA8E1,0xA8E2,0xA8E3,0xA8E4,0xA8E5,0xA8E6,0xA8E7,0xA8E8,0xA8E9,0xA8EA,0xA8EB,0xA8EC,0xA8ED,0xA8EE,0xA8EF,0xA8F0,0xA8F1,0xAAB0,0xAAB2,0xAAB3,0xAAB7,0xAAB8,0xAABE,0xAABF,0xAAC1,0xFE20,0xFE21,0xFE22,0xFE23,0xFE24,0xFE25,0xFE26,0x10A0F,0x10A38,0x1D185,0x1D186,0x1D187,0x1D188,0x1D189,0x1D1AA,0x1D1AB,0x1D1AC,0x1D1AD,0x1D242,0x1D243,0x1D244]
    static func index(_ cp: UInt32) -> UInt32? {
        var (lo, hi) = (0, diacritics.count)
        while lo < hi { let m = (lo + hi) / 2; if diacritics[m] < cp { lo = m + 1 } else { hi = m } }
        return lo < diacritics.count && diacritics[lo] == cp ? UInt32(lo) : nil
    }
    static func id(_ c: Style.Color) -> UInt32 {
        switch c {
        case .none: 0
        case .palette(let i): UInt32(i)
        case .rgb(let v): UInt32(v.r) << 16 | UInt32(v.g) << 8 | UInt32(v.b)
        }
    }

    /// Every run from the top of the viewport to its bottom, in order.
    static func runs(_ top: Pin, _ bottom: Pin) -> [PlaceholderRun] {
        struct Cell { var low: UInt32, high: UInt32?, placement: UInt32?, row: UInt32?, col: UInt32? }
        var out: [PlaceholderRun] = []
        for rowPin in top.rows(down: true, to: bottom) {
            let page = rowPin.page
            var run: (start: Pin, first: Cell, width: UInt32)?
            func flush() { if let r = run { out.append(PlaceholderRun(pin: r.start, imageID: r.first.low | (r.first.high ?? 0) << 24, placementID: r.first.placement ?? 0, col: r.first.col ?? 0, row: r.first.row ?? 0, width: r.width)) }; run = nil }
            for x in 0..<page.cols {
                let offset = page.cellAt(rowPin.y, x), c = page.cell(offset)
                guard c.codepoint == placeholder else { flush(); continue }
                let style = page.style(c.styleID)
                let marks = page.grapheme(offset).map(Array.init) ?? []
                var cell = Cell(low: id(style.fgColor), high: nil, placement: id(style.underlineColor), row: nil, col: nil)
                if cell.placement == 0 { cell.placement = nil }
                if marks.count > 0 { cell.row = index(marks[0]) }
                if marks.count > 1 { cell.col = index(marks[1]) }
                if marks.count > 2, let h = index(marks[2]), h <= 255 { cell.high = h }
                if let r = run, r.first.low == cell.low, r.first.placement == cell.placement, cell.row == nil || cell.row == r.first.row,
                   cell.col == nil || cell.col == r.first.col! + r.width, cell.high == nil || cell.high == r.first.high {
                    run!.width += 1
                    continue
                }
                flush()
                if cell.row == nil { cell.row = 0 }
                if cell.col == nil { cell.col = 0 }
                var start = rowPin
                start.x = x
                run = (start, cell, 1)
            }
            flush()
        }
        return out
    }

    /// Where this run's part of the image goes (Placement.renderPlacement); nil when nothing shows.
    func render(_ st: ImageStorage, _ img: KittyImage, _ cellW: UInt32, _ cellH: UInt32)
        -> (offsetX: UInt32, offsetY: UInt32, sourceX: UInt32, sourceY: UInt32, sourceWidth: UInt32, sourceHeight: UInt32, width: UInt32, height: UInt32)? {
        guard let target = st.placeholderTarget(imageID, placementID) else { return nil }
        var rows = target.placement.rows, cols = target.placement.columns
        if rows == 0 { rows = (img.height + cellH - 1) / cellH }
        if cols == 0 { cols = (img.width + cellW - 1) / cellW }
        guard rows <= UInt32(UInt16.max), cols <= UInt32(UInt16.max) else { return nil }
        let (iw, ih) = (Double(img.width), Double(img.height))
        let rowsPx = Double(rows * cellH), colsPx = Double(cols * cellW)
        var (xOff, yOff, xScale, yScale) = (0.0, 0.0, 0.0, 0.0)
        if iw * rowsPx > ih * colsPx { xScale = colsPx / max(iw, 1); yScale = xScale; yOff = (rowsPx - ih * yScale) / 2 } else {
            yScale = rowsPx / max(ih, 1); xScale = yScale; xOff = (colsPx - iw * xScale) / 2
        }
        let sx = xOff / xScale, sy = yOff / yScale, sw = iw + sx * 2, sh = ih + sy * 2
        var src = (x: sw * (Double(col) / Double(cols)), y: sh * (Double(row) / Double(rows)), w: sw * (Double(width) / Double(cols)), h: sh * (1 / Double(rows)))
        var (dx, dy, dw, dh) = (0.0, 0.0, Double(width * cellW), Double(cellH))
        if src.y < sy {
            let o = sy - src.y
            (src.h, dy, dh, src.y) = (src.h - o, o, dh - o * yScale, 0)
            if src.h > ih { (src.h, dh) = (ih, ih * yScale) }
        } else if src.y + src.h > sh - sy {
            src.y -= sy
            src.h = sh - sy - src.y - sy
            dh = src.h * yScale
        } else { src.y -= sy }
        if src.x < sx {
            let o = sx - src.x
            (src.w, dx, dw, src.x) = (src.w - o, o, dw - o * xScale, 0)
            if src.w > iw { (src.w, dw) = (iw, iw * xScale) }
        } else if src.x + src.w > sw - sx {
            src.x -= sx
            src.w = sw - sx - src.x - sx
            dw = src.w * xScale
        } else { src.x -= sx }
        guard src.w > 0, src.h > 0 else { return nil }
        func u(_ v: Double) -> UInt32 { UInt32(max(0, v.rounded())) }
        return (u(dx * xScale), u(dy * yScale), u(src.x), u(src.y), u(src.w), u(src.h), u(dw), u(dh))
    }
}

extension ImageStorage {
    /// The placement a placeholder names: its external id, else the preferred virtual placement.
    func placeholderTarget(_ image: UInt32, _ placement: UInt32) -> (key: KittyPlacementKey, placement: KittyPlacement)? {
        if placement > 0 {
            let key = KittyPlacementKey(imageID: image, external: true, id: placement)
            return placements[key].map { (key, $0) }
        }
        let keys = placements.filter { if case .virtual = $0.value.location { $0.key.imageID == image } else { false } }.keys
        return keys.min { $0.preferred(over: $1) }.map { ($0, placements[$0]!) }
    }
}

extension Terminal {
    /// The kitty images to draw now, over the viewport (cells of `cellWidth` x `cellHeight` pixels),
    /// into `out` (its arrays keep their capacity from frame to frame).
    public func imageDraws(_ out: inout ImageDraws, cellWidth: UInt32, cellHeight: UInt32) {
        let s = active, st = s.images
        out.draws.removeAll(keepingCapacity: true)
        (out.belowBackground, out.belowText, out.virtual, out.images) = (0, 0, false, st.images)
        guard !st.placements.isEmpty else { return }
        let top = s.pages.topLeft(.viewport)
        guard var bottom = s.pages.bottomRight(.viewport), let topY = s.pages.point(.screen, top)?.y, let botY = s.pages.point(.screen, bottom)?.y else { return }
        bottom.x = 0
        func append(_ img: KittyImage, _ p: KittyPlacement, _ x: Int, _ y: Int) {
            let size = p.pixelSize(img, self), off = p.cellOffset(self), src = p.sourceRect(img)
            guard size.width > 0, size.height > 0, let x = Int32(exactly: x), let y = Int32(exactly: y) else { return }
            out.draws.append(ImageDraw(image: img.id, x: x, y: y, z: p.z, width: size.width, height: size.height, cellOffsetX: off.x, cellOffsetY: off.y,
                                       sourceX: src.x, sourceY: src.y, sourceWidth: src.width, sourceHeight: src.height))
        }
        var pending: [(img: KittyImage, p: KittyPlacement, root: KittyPlacementKey, h: Int32, v: Int32)] = []
        for (k, p) in st.placements {
            var origin: (pin: Pin, h: Int32, v: Int32)
            switch p.location {
            case .pin(let tp): origin = (tp.pin, 0, 0)
            case .virtual: out.virtual = true; continue
            case .relative(let parent, let h, let v):
                guard let chain = st.resolveChain(parent, h, v) else { continue }
                switch chain.root.location {
                case .pin(let tp): origin = (tp.pin, chain.horizontal, chain.vertical)
                default:
                    out.virtual = true
                    if let img = st.images[k.imageID] { pending.append((img, p, chain.key, chain.horizontal, chain.vertical)) }
                    continue
                }
            }
            guard let img = st.images[k.imageID], !origin.pin.garbage else { continue }
            let g = p.gridSize(img, self)
            guard g.cols > 0, g.rows > 0, let oy = s.pages.point(.screen, origin.pin)?.y else { continue }
            let imgTop = oy + Int(origin.v), imgBot = imgTop + Int(g.rows) - 1, left = origin.pin.x + Int(origin.h), right = left + Int(g.cols) - 1
            guard imgTop <= botY, imgBot >= topY, left < cols, right >= 0 else { continue }
            append(img, p, left, imgTop - topY)
        }
        if out.virtual {
            var origins: [KittyPlacementKey: (x: Int, y: Int)] = [:]
            for run in PlaceholderRun.runs(top, bottom) {
                if let img = st.images[run.imageID], let r = run.render(st, img, cellWidth, cellHeight), r.width > 0, r.height > 0, let vy = s.pages.point(.viewport, run.pin)?.y {
                    out.draws.append(ImageDraw(image: img.id, x: Int32(run.pin.x), y: Int32(vy), z: -1, width: r.width, height: r.height, cellOffsetX: r.offsetX,
                                               cellOffsetY: r.offsetY, sourceX: r.sourceX, sourceY: r.sourceY, sourceWidth: r.sourceWidth, sourceHeight: r.sourceHeight))
                }
                guard !pending.isEmpty, let target = st.placeholderTarget(run.imageID, run.placementID), let vp = s.pages.point(.viewport, run.pin) else { continue }
                let o = origins[target.key]
                origins[target.key] = (min(o?.x ?? vp.x, vp.x), min(o?.y ?? vp.y, vp.y))
            }
            for pr in pending {
                guard let o = origins[pr.root] else { continue }
                let g = pr.p.gridSize(pr.img, self)
                guard g.cols > 0, g.rows > 0 else { continue }
                let x = o.x + Int(pr.h), y = o.y + Int(pr.v)
                guard y < rows, y + Int(g.rows) - 1 >= 0, x < cols, x + Int(g.cols) - 1 >= 0 else { continue }
                append(pr.img, pr.p, x, y)
            }
        }
        out.draws.sort { ($0.z, $0.image) < ($1.z, $1.image) }
        out.belowBackground = out.draws.firstIndex { $0.z >= Int32.min / 2 } ?? out.draws.count
        out.belowText = out.draws.firstIndex { $0.z >= 0 } ?? out.draws.count
    }

    /// Advances the active screen's running animations to the frames due at `nowMs` (the
    /// renderer's clock); how long until the next one is due (nil: nothing running).
    public func animationTick(_ nowMs: UInt64) -> UInt64? { active.images.animationTick(nowMs) }
}
