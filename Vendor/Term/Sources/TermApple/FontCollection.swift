// The fonts of a surface and which one draws each code point, like Ghostty's font collection
// (font/SharedGridSet.zig, Collection.zig, CodepointResolver.zig, discovery.zig on CoreText).
#if canImport(CoreText)
import CoreText
import Foundation
import Term

public final class FontCollection {
    static let maxIndexCache = 65_536, maxFallbackFaces = 256
    /// The bundled fonts' bundle: SwiftPM's resource bundle, or this framework (Dispatch builds
    /// the library as a framework target).
    #if SWIFT_PACKAGE
    static let bundle = Bundle.module
    #else
    static let bundle = Bundle(for: FontCollection.self)
    #endif

    public enum Style: Int, CaseIterable { case regular, bold, italic, boldItalic }
    public enum Presentation { case text, emoji }
    public enum Adjustment { case none, icWidth }

    /// A face: discovered (loaded on first use) or loaded, with its size scale (a pending adjustment
    /// until loaded). Aliases share their entry.
    public final class Entry {
        var font: CTFont, loaded: Bool, fallback: Bool, scale: Double?, adjustment: Adjustment
        /// A synthetic bold face's stroke width in points (drawn thicker when rasterized).
        public internal(set) var syntheticBold: Double?
        init(_ font: CTFont, loaded: Bool, fallback: Bool, scale: Double?, adjustment: Adjustment = .none) {
            (self.font, self.loaded, self.fallback, self.scale, self.adjustment) = (font, loaded, fallback, scale, adjustment)
        }
        /// Loaded: the family name; discovered: CoreText's display name (Ghostty's Face/DeferredFace.name).
        public var name: String { (loaded ? CTFontCopyFamilyName(font) : CTFontCopyDisplayName(font)) as String }
        public var pendingAdjustment: Adjustment { adjustment }
        public var isLoaded: Bool { loaded }
        public var sizeScale: Double? { scale }
        public var isFallback: Bool { fallback }
    }

    /// Faces per style in order; `alias` marks entries that stand in for another style's entry.
    public private(set) var faces: [[(entry: Entry, alias: Bool)]] = Array(repeating: [], count: 4)
    /// index's answers by code point, style and presentation (packed: see index).
    var indexCache = Map<(style: Style, idx: Int)?>()
    let points: Float, dpi: Int
    var primary: FaceMetrics?

    /// Ghostty's Collection.CompleteError: regular faces exist, but none draws text.
    public enum Failure: Error { case defaultUnavailable }

    /// Configured families per style (Ghostty's font-family*; empty style lists use the regular list
    /// with bold/italic traits, like Config.finalize), then the embedded fonts. Throws where Ghostty
    /// fails to make the surface's font grid.
    public init(families: [String], points: Float, dpi: Int, synthetic: Bool = true) throws {
        (self.points, self.dpi) = (points, dpi)
        for style in Style.allCases {
            for family in families {
                if let font = Self.discover(family: family, size: points, bold: style == .bold || style == .boldItalic,
                                            italic: style == .italic || style == .boldItalic, codepoint: 0).first {
                    faces[style.rawValue].append((Entry(font, loaded: false, fallback: false, scale: nil), false))
                }
            }
        }
        try completeStyles(synthetic: synthetic)
        let resource = { (name: String) in [UInt8](try! Data(contentsOf: Self.bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Resources")!)) }
        let (upright, italic) = (resource("JetBrainsMono-Variable"), resource("JetBrainsMono-Italic-Variable"))
        add(upright, .regular, adjustment: .icWidth)
        add(upright, .bold, adjustment: .icWidth, weight: 700)
        add(italic, .italic, adjustment: .icWidth)
        add(italic, .boldItalic, adjustment: .icWidth, weight: 700)
        add(resource("SymbolsNerdFont-Regular"), .regular, adjustment: .none)
        // macOS: Apple Color Emoji by exact family name (discoverExactFamily), loaded on use.
        let emoji = CTFontCreateWithName("Apple Color Emoji" as CFString, 12, nil)
        if CTFontCopyFamilyName(emoji) as String == "Apple Color Emoji" {
            faces[0].append((Entry(emoji, loaded: false, fallback: true, scale: nil), false))
        }
    }

    var pixels: Double { Face.pixels(points: points, dpi: dpi) }

    /// A loaded face appended with its scale computed now (Collection.add), resized by it.
    func add(_ data: [UInt8], _ style: Style, adjustment: Adjustment, weight: Double? = nil) {
        let base = Face(data: data, pixels: pixels)!
        let scale = scaleFactor(base.metrics, adjustment)
        var font = Face(base.font, pixels: Face.pixels(points: points * Float(scale), dpi: dpi)).font
        if let w = weight { font = Self.vary(font, ["wght": w]) }
        faces[style.rawValue].append((Entry(font, loaded: true, fallback: true, scale: scale), false))
    }

    /// A font with its named variation axes set (Ghostty's Face.setVariations: by axis tag).
    static func vary(_ font: CTFont, _ values: [String: Double]) -> CTFont {
        let tag = { (s: String) in s.utf8.reduce(0) { $0 << 8 | Int($1) } }
        let variation = Dictionary(uniqueKeysWithValues: values.map { (NSNumber(value: tag($0.key)), NSNumber(value: $0.value)) })
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, desc)
    }

    /// The face of an entry, loading it (with its scale) on first use (getFaceFromEntry).
    public func face(_ e: Entry) -> CTFont {
        if !e.loaded {
            let face = Face(e.font, pixels: pixels)
            if e.scale == nil { e.scale = scaleFactor(face.metrics, e.adjustment) }
            e.font = e.scale == 1 ? face.font : Face(e.font, pixels: Face.pixels(points: points * Float(e.scale!), dpi: dpi)).font
            e.loaded = true
        }
        return e.font
    }

    /// Size factor matching a fallback to the primary face (Collection.scaleFactor): ic width, else ex
    /// height, cap height, line height, each per pixel-per-em, when the face has the metric.
    func scaleFactor(_ f: FaceMetrics, _ adjustment: Adjustment) -> Double {
        guard adjustment != .none else { return 1 }
        if primary == nil {
            guard let e = faces[0].first?.entry else { return 1 }
            primary = Face(face(e), pixels: CTFontGetSize(face(e))).metrics
        }
        let p = primary!, (ps, fs) = (1 / p.pxPerEm, 1 / f.pxPerEm)
        if f.icWidth == f.icWidthOrFallback { return p.icWidthOrFallback * ps / (f.icWidthOrFallback * fs) }
        if f.exHeight == f.ex { return p.ex * ps / (f.ex * fs) }
        if f.capHeight == f.cap { return p.cap * ps / (f.cap * fs) }
        return p.lineHeight * ps / (f.lineHeight * fs)
    }

    /// Styles without faces (Collection.completeStyles), from the first regular text face: italic =
    /// it skewed 15 degrees, bold = it stroked, bold italic = the real bold skewed, else the italic
    /// stroked; `synthetic` off: aliases of it.
    func completeStyles(synthetic: Bool) throws {
        guard faces.contains(where: \.isEmpty), !faces[0].isEmpty else { return }
        guard let regular = faces[0].first(where: { e in
            let font = face(e.entry)
            return !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) || Face.glyph(font, 0x41) != nil
        })?.entry else { throw Failure.defaultUnavailable }
        let hadBold = !faces[Style.bold.rawValue].isEmpty
        let skewed = { (e: Entry) -> Entry in
            var skew = CGAffineTransform(a: 1, b: 0, c: 0.267949, d: 1, tx: 0, ty: 0)
            return Entry(CTFontCreateCopyWithAttributes(self.face(e), 0, &skew, nil), loaded: true, fallback: false, scale: 1)
        }
        let stroked = { (e: Entry) -> Entry in
            let s = Entry(CTFontCreateCopyWithAttributes(self.face(e), 0, nil, nil), loaded: true, fallback: false, scale: 1)
            s.syntheticBold = max(Double(self.points) / 14, 1)
            return s
        }
        for style in [Style.italic, .bold, .boldItalic] where faces[style.rawValue].isEmpty {
            let base = style != .boldItalic ? regular : hadBold ? faces[Style.bold.rawValue][0].entry : faces[Style.italic.rawValue][0].entry
            faces[style.rawValue].append(!synthetic ? (regular, true) : style == .bold || style == .boldItalic && !hadBold ? (stroked(base), false) : (skewed(base), false))
        }
    }

    /// The face for a code point (SharedGrid.getIndex): decided by its first lookup and cached, a
    /// missing face too (fallbacks discovered later don't change it). nil: none; (style, -1): sprite.
    public func index(_ cp: UInt32, _ style: Style, _ p: Presentation?) -> (style: Style, idx: Int)? {
        let key = UInt64(cp) | UInt64(style.rawValue) << 32 | UInt64(p == nil ? 0 : p == .text ? 1 : 2) << 34
        if let hit = indexCache[key] { return hit }
        let found = resolve(cp, style, p)
        if indexCache.count >= Self.maxIndexCache { indexCache.clear() }
        indexCache.set(key, found)
        return found
    }

    /// CodepointResolver.getIndex: sprite, the style's faces, regular, then a discovered fallback
    /// appended to regular.
    func resolve(_ cp: UInt32, _ style: Style, _ p: Presentation?) -> (style: Style, idx: Int)? {
        if Sprite.has(cp) { return (style, -1) }
        let mode = p ?? (Unicode.isEmojiPresentation(cp) ? .emoji : .text)
        if let i = faces[style.rawValue].firstIndex(where: { has($0.entry, cp, p == nil && !$0.entry.fallback ? nil : mode) }) { return (style, i) }
        if style != .regular, let found = resolve(cp, .regular, p) { return found }
        if style == .regular, faces[0].count < Self.maxFallbackFaces {
            for font in Self.fallback(cp, size: points, bold: false, italic: false, original: face(faces[0][0].entry)).prefix(64) {
                let e = Entry(font, loaded: false, fallback: true, scale: nil, adjustment: .icWidth)
                if has(e, cp, mode) { faces[0].append((e, false)); return (.regular, faces[0].count - 1) }
            }
        }
        // Last resort: any regular face with the glyph, whatever its presentation.
        return faces[0].firstIndex { has($0.entry, cp, nil) }.map { (.regular, $0) }
    }

    /// Whether an entry draws a code point in a presentation (nil: any glyph), without loading it.
    func has(_ e: Entry, _ cp: UInt32, _ p: Presentation?) -> Bool {
        let color = CTFontGetSymbolicTraits(e.font).contains(.traitColorGlyphs)
        guard let g = Face.glyph(e.font, cp) else { return false }
        guard let p else { return true }
        if !e.loaded { return (p == .emoji) == color }
        return (p == .emoji) == (color && Face.isColorGlyph(e.font, g))
    }
}

extension FontCollection {
    /// Fonts matching a descriptor (family, code point, size rounded, traits), best first by Ghostty's
    /// Score (codepoint, monospace, exact style, italic, bold, fuzzy style, glyph count), each at 12 pt
    /// from its descriptor without the character set (DiscoverIterator.next). Ghostty sorts unstably:
    /// exact score ties could order differently.
    static func discover(family: String?, size: Float, bold: Bool, italic: Bool, codepoint: UInt32, monospace: Bool = false) -> [CTFont] {
        var attrs: [CFString: Any] = [:]
        if let family { attrs[kCTFontFamilyNameAttribute] = family }
        if codepoint > 0 { attrs[kCTFontCharacterSetAttribute] = CFCharacterSetCreateWithCharactersInRange(nil, CFRange(location: Int(codepoint), length: 1)) }
        if size > 0 { attrs[kCTFontSizeAttribute] = NSNumber(value: Int32(size.rounded())) }
        let traits: UInt32 = (italic ? 1 : 0) | (bold ? 2 : 0) | (monospace ? 1 << 10 : 0)
        if traits > 0 { attrs[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: NSNumber(value: Int32(bitPattern: traits))] }
        let collection = CTFontCollectionCreateWithFontDescriptors([CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)] as CFArray, nil)
        let list = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        let scored = list.map { ($0, score($0, bold: bold, italic: italic, codepoint: codepoint)) }
        return scored.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.map { item in
            let d = CTFontDescriptorCreateCopyWithAttributes(item.element.0, [kCTFontCharacterSetAttribute: kCFNull] as CFDictionary)
            return CTFontCreateWithFontDescriptor(d, 12, nil)
        }
    }

    static func score(_ desc: CTFontDescriptor, bold: Bool, italic: Bool, codepoint: UInt32) -> Int {
        let font = CTFontCreateWithFontDescriptor(desc, 12, nil)
        let glyphs = min(Int(CTFontGetGlyphCount(font)), 0xFFFF)
        let covers = codepoint > 0 && Face.glyph(font, codepoint) != nil
        let symbolic = ((CTFontDescriptorCopyAttribute(desc, kCTFontTraitsAttribute) as? [CFString: Any])?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        var (isItalic, isBold) = (symbolic & 1 != 0, symbolic & 2 != 0)
        if let head = Face.table(font, "head"), head.count >= 54 {
            let macStyle = Int(head[44]) << 8 | Int(head[45])
            (isBold, isItalic) = (isBold || macStyle & 1 != 0, isItalic || macStyle & 2 != 0)
        }
        if let os2 = Face.table(font, "OS/2"), os2.count >= 78, [0, 1, 2, 3, 4, 5].contains(Int(os2[0]) << 8 | Int(os2[1])) {
            let fs = Int(os2[62]) << 8 | Int(os2[63])
            (isBold, isItalic) = (isBold || fs & 0x20 != 0, isItalic || fs & 1 != 0)
        }
        // Variation axes by name (Ghostty compares the axis name with "wght", "ital", "slnt").
        if let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]], let values = CTFontCopyVariation(font) as? [NSNumber: NSNumber] {
            var italSeen = false
            for axis in axes {
                let name = axis[kCTFontVariationAxisNameKey] as? String ?? ""
                let id = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber
                let value = id.flatMap { values[$0] }?.doubleValue ?? (axis[kCTFontVariationAxisDefaultValueKey] as? NSNumber)?.doubleValue ?? 0
                if name == "wght" { isBold = value > 600 } else if name == "ital" { (isItalic, italSeen) = (value > 0.5, true) }
                else if !italSeen, name == "slnt" { isItalic = value <= -5 }
            }
        }
        let style = (CTFontDescriptorCopyAttribute(desc, kCTFontStyleNameAttribute) as? String ?? "").lowercased()
        let desired = bold ? (italic ? ["bold italic", "bold", "italic", "oblique"] : ["bold", "upright"]) : italic ? ["italic", "regular", "oblique"] : ["regular", "upright"]
        var fuzzy = min(style.utf8.count, 255)
        for d in desired where style.contains(d) { fuzzy = max(0, fuzzy - d.utf8.count) }
        let bits = [covers, symbolic & (1 << 10) != 0, style == desired[0], italic == isItalic, bold == isBold]
        return bits.reduce(0) { $0 << 1 | ($1 ? 1 : 0) } << 24 | (255 - fuzzy) << 16 | glyphs
    }

    /// Fallback fonts for a code point (discoverFallback): Han goes to CoreText's own fallback for
    /// the original face; else fonts covering it by Score, and CoreText's fallback when none.
    static func fallback(_ cp: UInt32, size: Float, bold: Bool, italic: Bool, original: CTFont) -> [CTFont] {
        let byString = { () -> [CTFont] in
            let s = String(UnicodeScalar(cp).map(Character.init) ?? " ") as CFString
            let f = CTFontCreateForString(original, s, CFRange(location: 0, length: CFStringGetLength(s)))
            guard CTFontCopyPostScriptName(f) as String != "LastResort" else { return [] }
            let d = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(f), [kCTFontCharacterSetAttribute: kCFNull] as CFDictionary)
            return [CTFontCreateWithFontDescriptor(d, 12, nil)]
        }
        if (0x4E00...0x9FFF).contains(cp) { return byString() }
        let found = discover(family: nil, size: size, bold: bold, italic: italic, codepoint: cp)
        return found.isEmpty ? byString() : found
    }
}

extension FaceMetrics {
    var icWidthOrFallback: Double { icWidth.flatMap { $0 > 0 ? $0 : nil } ?? min(asciiHeightOrFallback, 2 * cellWidth) }
    var asciiHeightOrFallback: Double { asciiHeight.flatMap { $0 > 0 ? $0 : nil } ?? 1.5 * cap }
    var lineHeight: Double { ascent - descent + lineGap }
}
#endif
