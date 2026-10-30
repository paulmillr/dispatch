// Font metrics as Ghostty computes them (font/face/coretext.zig getMetrics, font/Metrics.zig): a
// face's metrics from its OpenType tables and a few values the platform's font API measures,
// then the terminal cell metrics derived from them. Platform-free: the Apple side supplies the
// table bytes and the measurements.

/// The OpenType table fields Ghostty reads (font/opentype). A table shorter than Ghostty's struct
/// for it (head 54, hhea 36, post 32, OS/2 78/86/96/100 bytes by version 0/1/2-4/5; other OS/2
/// versions unsupported) counts as missing, like a failed parse there.
public struct FontTables {
    public var unitsPerEm: Int?
    public var hhea: (ascender: Int, descender: Int, lineGap: Int)?
    public var os2: (typoAscender: Int, typoDescender: Int, typoLineGap: Int, winAscent: Int, winDescent: Int,
                     strikeoutSize: Int, strikeoutPosition: Int, useTypoMetrics: Bool, xHeight: Int?, capHeight: Int?)?
    public var post: (underlinePosition: Int, underlineThickness: Int)?

    public init(head: [UInt8]?, hhea: [UInt8]?, os2: [UInt8]?, post: [UInt8]?) {
        let u = { (t: [UInt8], at: Int) in Int(t[at]) << 8 | Int(t[at + 1]) }
        let i = { (t: [UInt8], at: Int) in Int(Int16(bitPattern: UInt16(u(t, at)))) }
        if let t = head, t.count >= 54 { unitsPerEm = u(t, 18) }
        if let t = hhea, t.count >= 36 { self.hhea = (i(t, 4), i(t, 6), i(t, 8)) }
        if let t = post, t.count >= 32 { self.post = (i(t, 8), i(t, 10)) }
        if let t = os2, t.count >= 2, let need = [0: 78, 1: 86, 2: 96, 3: 96, 4: 96, 5: 100][u(t, 0)], t.count >= need {
            let v2 = u(t, 0) >= 2
            self.os2 = (i(t, 68), i(t, 70), i(t, 72), u(t, 74), u(t, 76), i(t, 26), i(t, 28), u(t, 62) & 0x80 != 0,
                        v2 ? i(t, 86) : nil, v2 ? i(t, 88) : nil)
        }
    }
}

/// What the platform's font API measures for a face at its size (CoreText in Ghostty).
public struct FontMeasurements {
    /// Units per em, ascent, descent (positive down), leading, cap and x height from the font API.
    public var unitsPerEm: Int, ascent: Double, descent: Double, leading: Double, capHeight: Double, xHeight: Double
    /// Widest advance of ASCII 32...126, height of their bounding box, advance of U+6C34 (nil: no
    /// glyph, or its bounds are wider than its advance).
    public var maxAdvance: Double, asciiHeight: Double, icWidth: Double?
    public init(unitsPerEm: Int, ascent: Double, descent: Double, leading: Double, capHeight: Double, xHeight: Double,
                maxAdvance: Double, asciiHeight: Double, icWidth: Double?) {
        (self.unitsPerEm, self.ascent, self.descent, self.leading, self.capHeight, self.xHeight) = (unitsPerEm, ascent, descent, leading, capHeight, xHeight)
        (self.maxAdvance, self.asciiHeight, self.icWidth) = (maxAdvance, asciiHeight, icWidth)
    }
}

/// A face's metrics in pixels (Ghostty's Metrics.FaceMetrics).
public struct FaceMetrics {
    public var pxPerEm: Double, cellWidth: Double, ascent: Double, descent: Double, lineGap: Double
    public var underlinePosition: Double?, underlineThickness: Double?, strikethroughPosition: Double?, strikethroughThickness: Double?
    public var capHeight: Double?, exHeight: Double?, asciiHeight: Double?, icWidth: Double?

    /// Ghostty's getMetrics: vertical metrics from hhea or OS/2 by its preference rules, underline
    /// from post, strikeout and cap/x height from OS/2, the rest measured.
    public init(_ t: FontTables, pixels: Double, _ m: FontMeasurements) {
        let pixels = pixels.isFinite && pixels > 0 ? pixels : 13
        let units = (t.unitsPerEm ?? m.unitsPerEm) > 0 ? (t.unitsPerEm ?? m.unitsPerEm) : 1000
        let unit = pixels / Double(units)
        (pxPerEm, cellWidth, asciiHeight, icWidth) = (pixels, m.maxAdvance, m.asciiHeight, m.icWidth)
        let scale = { (a: Int, d: Int, g: Int) in (Double(a) * unit, Double(d) * unit, Double(g) * unit) }
        if let h = t.hhea {
            if let o = t.os2, o.useTypoMetrics || h.ascender == 0 && h.descender == 0 {
                (ascent, descent, lineGap) = o.useTypoMetrics || o.typoAscender != 0 || o.typoDescender != 0
                    ? scale(o.typoAscender, o.typoDescender, o.typoLineGap) : scale(o.winAscent, -o.winDescent, 0)
            } else {
                (ascent, descent, lineGap) = scale(h.ascender, h.descender, h.lineGap)
            }
        } else {
            (ascent, descent, lineGap) = (m.ascent, -m.descent, m.leading)
        }
        if let p = t.post {
            let broken = p.underlineThickness == 0
            underlinePosition = broken && p.underlinePosition == 0 ? nil : Double(p.underlinePosition) * unit
            underlineThickness = broken ? nil : Double(p.underlineThickness) * unit
        }
        if let o = t.os2 {
            let broken = o.strikeoutSize == 0
            strikethroughPosition = broken && o.strikeoutPosition == 0 ? nil : Double(o.strikeoutPosition) * unit
            strikethroughThickness = broken ? nil : Double(o.strikeoutSize) * unit
        }
        capHeight = t.os2?.capHeight.map { Double($0) * unit } ?? m.capHeight
        exHeight = t.os2?.xHeight.map { Double($0) * unit } ?? m.xHeight
    }

    // Fallbacks for missing or zero values (Ghostty's FaceMetrics accessors).
    public var cap: Double { capHeight.flatMap { $0 > 0 ? $0 : nil } ?? 0.75 * ascent }
    public var ex: Double { exHeight.flatMap { $0 > 0 ? $0 : nil } ?? 0.75 * cap }
    var underlineThick: Double { underlineThickness.flatMap { $0 > 0 ? $0 : nil } ?? 0.15 * ex }
    var strikethroughThick: Double { strikethroughThickness.flatMap { $0 > 0 ? $0 : nil } ?? underlineThick }
}

/// The terminal's cell metrics in whole pixels (Ghostty's Metrics.calc + clamp).
public struct CellMetrics: Equatable {
    public var cellWidth: UInt32, cellHeight: UInt32, cellBaseline: UInt32
    public var underlinePosition: UInt32, underlineThickness: UInt32, strikethroughPosition: UInt32, strikethroughThickness: UInt32
    public var overlinePosition: Int32, overlineThickness: UInt32, boxThickness: UInt32, cursorThickness: UInt32, cursorHeight: UInt32
    public var iconHeight: Double, iconHeightSingle: Double, faceWidth: Double, faceHeight: Double, faceY: Double

    public init(_ f: FaceMetrics) {
        let safe = { (value: Double, fallback: Double) in value.isFinite ? value : fallback }
        let ascent = safe(f.ascent, f.pxPerEm), descent = safe(f.descent, 0), lineGap = safe(f.lineGap, 0)
        let faceHeight = safe(ascent - descent + lineGap, max(f.pxPerEm, 1))
        let (width, height) = (safe(f.cellWidth, 1).rounded(), faceHeight.rounded())
        let faceBaseline = lineGap / 2 - descent
        let baseline = (faceBaseline - (height - faceHeight) / 2).rounded()
        let top = height - baseline
        let underlineThick = safe(f.underlineThick, 1), strikeThick = safe(f.strikethroughThick, 1)
        let underline = max(1, underlineThick.rounded(.up)), strike = max(1, strikeThick.rounded(.up))
        let underlinePos = safe(f.underlinePosition ?? -underlineThick, -underlineThick)
        let strikePos = safe(f.strikethroughPosition ?? (f.ex + strikeThick) * 0.5, 0)
        // Minimums: 1 for every size and thickness. The Metal ABI does signed-int pixel math.
        let limit = Double(Int32.max)
        let px = { (v: Double) -> UInt32 in
            guard v.isFinite, v > 1 else { return 1 }
            return v >= limit ? UInt32(Int32.max) : UInt32(v)
        }
        let coordinate = { (v: Double) -> UInt32 in
            guard v.isFinite, v > 0 else { return 0 }
            return v >= limit ? UInt32(Int32.max) : UInt32(v)
        }
        (cellWidth, cellHeight, cellBaseline) = (px(width), px(height), coordinate(baseline))
        (underlinePosition, underlineThickness) = (coordinate((top - underlinePos).rounded()), px(underline))
        (strikethroughPosition, strikethroughThickness) = (coordinate((top - strikePos).rounded()), px(strike))
        (overlinePosition, overlineThickness, boxThickness, cursorThickness, cursorHeight) = (0, px(underline), px(underline), 1, px(height))
        (iconHeight, iconHeightSingle) = (min(max(1, faceHeight), limit), min(max(1, safe((2 * f.cap + faceHeight) / 3, 1)), limit))
        (faceWidth, self.faceHeight, faceY) = (min(max(1, safe(f.cellWidth, 1)), limit), min(max(1, faceHeight), limit), safe(baseline - faceBaseline, 0))
    }
}

/// A metric's adjustment as the config writes it (Ghostty's Metrics.Modifier): `N%` scales by 1 + N/100 (-100% and
/// below scale to 0), `N` adds whole pixels.
public enum MetricModifier: Equatable, Sendable {
    case percent(Double), absolute(Int32)

    /// Modifier.parse: a float before `%`, else a decimal i32.
    init?(_ bytes: [UInt8]) {
        guard let last = bytes.last else { return nil }
        if last == 0x25 {
            guard let percent = Config.float(Array(bytes.dropLast())).map({ $0 / 100 }) else { return nil }
            self = .percent(percent <= -1 ? 0 : 1 + percent)
            return
        }
        let negative = bytes.first == 0x2D
        let digits = bytes.first == 0x2B || negative ? bytes.dropFirst() : bytes[...]
        guard let n = zigInt(digits, base: 10, max: negative ? UInt64(Int32.max) + 1 : UInt64(Int32.max)) else { return nil }
        self = .absolute(Int32(truncatingIfNeeded: negative ? -Int64(n) : Int64(n)))
    }

    /// Modifier.apply on an unsigned pixel metric: rounded, never below 0.
    func apply(_ value: UInt32) -> UInt32 {
        switch self {
        case .percent(let p):
            let v = (Double(value) * max(0, p)).rounded()
            return v >= Double(UInt32.max) ? .max : UInt32(v)
        case .absolute(let a):
            return UInt32(clamping: max(0, Int64(value) + Int64(a)))
        }
    }
}

extension CellMetrics {
    /// The cell metrics with `adjust-cell-height` applied.
    public init(_ f: FaceMetrics, cellHeight: MetricModifier?) {
        self.init(f)
        if let cellHeight { adjustCellHeight(cellHeight) }
    }

    /// adjust-cell-height (Ghostty's Metrics.apply for cell_height): the new height, at least 1, with the baseline and
    /// the line positions moved by half the difference each so text stays centred. An odd pixel goes to the edge the face
    /// leans away from. The cursor keeps its height.
    public mutating func adjustCellHeight(_ modifier: MetricModifier) {
        let original = cellHeight, new = max(modifier.apply(original), 1)
        guard new != original else { return }
        cellHeight = new
        let diff = Double(new) - Double(original), half = diff / 2
        let aboveCenter = faceY - (Double(original) - faceHeight) / 2 > 0
        let (top, bottom) = aboveCenter ? (half.rounded(.up), half.rounded(.down)) : (half.rounded(.down), half.rounded(.up))
        // Ghostty's addFloatToInt: saturating at the unsigned range.
        let add = { (value: UInt32, delta: Double) in UInt32(clamping: max(0, Int64(value) + Int64(delta))) }
        cellBaseline = add(cellBaseline, bottom)
        faceY += bottom
        underlinePosition = add(underlinePosition, top)
        strikethroughPosition = add(strikethroughPosition, top)
        overlinePosition = Int32(clamping: Int64(overlinePosition) + Int64(top))
    }
}

/// A rendered glyph (font glyph or sprite): its pixels (rows top down; 1 byte per pixel, 4 for
/// color) and where they go relative to the cell's baseline origin.
public struct RasterGlyph: Sendable {
    public var width: Int, height: Int, offsetX: Int, offsetY: Int, color: Bool, pixels: [UInt8]
    public static let empty = RasterGlyph(width: 0, height: 0, offsetX: 0, offsetY: 0, color: false, pixels: [])
    public init(width: Int, height: Int, offsetX: Int, offsetY: Int, color: Bool, pixels: [UInt8]) {
        (self.width, self.height, self.offsetX, self.offsetY, self.color, self.pixels) = (width, height, offsetX, offsetY, color, pixels)
    }
}
