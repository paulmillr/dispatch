// A font face through CoreText, loaded and measured like Ghostty's (font/face/coretext.zig).
#if canImport(CoreText)
import CoreText
import Term

/// A CoreText font at a pixel size.
public struct Face {
    public let font: CTFont

    /// Pixels for a size in points at a dpi, computed in 32-bit floats like Ghostty (DesiredSize.pixels).
    public static func pixels(points: Float, dpi: Int) -> Double { Double(points * Float(dpi) / 72) }

    /// From font file bytes: a descriptor from the data, then the font at `pixels` (Ghostty's Face.init).
    public init?(data: [UInt8], pixels: Double) {
        guard let d = CFDataCreate(nil, data, data.count), let desc = CTFontManagerCreateFontDescriptorFromData(d) else { return nil }
        self.init(CTFontCreateWithFontDescriptor(desc, 12, nil), pixels: pixels)
    }

    /// A font by PostScript name at `pixels` (how a discovered face is loaded).
    public init(name: String, pixels: Double) { self.init(CTFontCreateWithName(name as CFString, 12, nil), pixels: pixels) }

    /// The same font at `pixels` (Ghostty's initFontCopy).
    public init(_ base: CTFont, pixels: Double) { font = CTFontCreateCopyWithAttributes(base, pixels, nil, nil) }

    public var family: String { CTFontCopyFamilyName(font) as String }

    /// The glyph for a code point (UTF-16, surrogate pairs included), nil when the font has none.
    public static func glyph(_ font: CTFont, _ cp: UInt32) -> CGGlyph? {
        var units = Array(String(UnicodeScalar(cp).map(Character.init) ?? "\u{FFFD}").utf16), glyphs = [CGGlyph](repeating: 0, count: units.count)
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) ? glyphs[0] : nil
    }

    /// A table's bytes (nil: missing).
    static func table(_ font: CTFont, _ tag: String) -> [UInt8]? {
        guard let d = CTFontCopyTable(font, tag.utf8.reduce(0) { $0 << 8 | CTFontTableTag($1) }, []) else { return nil }
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(d), count: CFDataGetLength(d)))
    }

    /// Whether a glyph is drawn in color (Ghostty's ColorState): fonts with the color trait whose
    /// `sbix` table is non-empty (every glyph), or whose `SVG ` table lists the glyph.
    public static func isColorGlyph(_ font: CTFont, _ glyph: CGGlyph) -> Bool {
        guard CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return false }
        if let sbix = table(font, "sbix"), !sbix.isEmpty { return true }
        guard let svg = table(font, "SVG "), svg.count >= 10 else { return false }
        let u16 = { (at: Int) in Int(svg[at]) << 8 | Int(svg[at + 1]) }
        let list = u16(2) << 16 | u16(4)
        guard list + 2 <= svg.count else { return false }
        for i in 0..<u16(list) where list + 2 + 12 * i + 4 <= svg.count {
            let at = list + 2 + 12 * i
            if u16(at) <= Int(glyph), Int(glyph) <= u16(at + 2) { return true }
        }
        return false
    }

    /// Ghostty's getMetrics: the OpenType tables plus CoreText's measurements.
    public var metrics: FaceMetrics {
        let table = { (tag: String) in Face.table(font, tag) }
        let tables = FontTables(head: table("head") ?? table("bhed"), hhea: table("hhea"), os2: table("OS/2"), post: table("post"))
        var chars = (32..<127).map { UniChar($0) }, glyphs = [CGGlyph](repeating: 0, count: chars.count)
        _ = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        _ = CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        let ascii = CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, nil, glyphs.count)
        // U+6C34 (water): its advance, unless its bounds are wider.
        var water: UniChar = 0x6C34, glyph: CGGlyph = 0, ic: Double?
        if CTFontGetGlyphsForCharacters(font, &water, &glyph, 1) {
            let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
            ic = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1).size.width > advance ? nil : advance
        }
        let m = FontMeasurements(unitsPerEm: Int(CTFontGetUnitsPerEm(font)), ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font),
                                 leading: CTFontGetLeading(font), capHeight: CTFontGetCapHeight(font), xHeight: CTFontGetXHeight(font),
                                 maxAdvance: advances.reduce(0) { max($0, $1.width) }, asciiHeight: ascii.size.height, icWidth: ic)
        return FaceMetrics(tables, pixels: CTFontGetSize(font), m)
    }
}
#endif
