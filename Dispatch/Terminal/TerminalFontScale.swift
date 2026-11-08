import CoreText
import Foundation
import os

/// Every font drawn at Source Code Pro's apparent size: the size Settings shows is multiplied by the ratio of Source
/// Code Pro's lowercase height to the font's, so switching fonts keeps the text the same size (Inconsolata draws
/// larger, Victor Mono smaller). Terminal fonts by family; on the Mac also chat's faces (`ChatFont.sizeScale`) and the
/// interface's San Francisco (`AppFont.systemScale`). Lowercase height is the median outline height of
/// "acemnorsuvwxz", read from the glyphs' bounds rather than rendered (`scripts/measure-fonts.swift` prints every
/// role's). Shared with the iPhone app; both register the bundled fonts before a terminal opens.
enum TerminalFontScale {
    static let reference = TerminalFontCatalog.defaultFamily
    private static let cache = OSAllocatedUnfairLock(initialState: [String: Double]())

    /// The size a terminal draws `size` points of `family` at; Source Code Pro, and a family that can't be found, keep it.
    static func size(_ size: Double, family: String) -> Double {
        ((size * factor(family)) * 100).rounded() / 100
    }

    /// Source Code Pro's lowercase height over `family`'s, to three places; 1 when either can't be measured.
    static func factor(_ family: String) -> Double {
        if family == reference { return 1 }
        if let known = cache.withLock({ $0[family] }) { return known }
        // Not cached unmeasured: a font registered later (or the reference) gets its factor then.
        guard let base = lowercaseHeight(reference), let height = lowercaseHeight(family), height > 0 else { return 1 }
        let value = (base / height * 1000).rounded() / 1000
        cache.withLock { $0[family] = value }
        return value
    }

    /// Source Code Pro's lowercase height over `font`'s, to three places; 1 when either can't be measured. For faces
    /// not reached by family name: the system font's designs (SF Rounded, New York) and named chat faces. Measured at
    /// 16 points, a text size, so the system font's optical size is the one text draws in.
    static func factor(_ font: CTFont) -> Double {
        let key = "font:" + (CTFontCopyPostScriptName(font) as String)
        if let known = cache.withLock({ $0[key] }) { return known }
        guard let base = lowercaseHeight(reference),
              let height = lowercaseHeight(CTFontCreateCopyWithAttributes(font, 16, nil, nil)), height > 0 else { return 1 }
        let value = (base / (height * 1000 / 16) * 1000).rounded() / 1000
        cache.withLock { $0[key] = value }
        return value
    }

    /// A terminal cell of `family` at Settings' `size`, in points: an "M"'s advance by the line's height (ascent, descent
    /// and leading), within a point of the engine's own; Source Code Pro without the family. It budgets panes
    /// (`LayoutRoom`) before any terminal has measured a grid.
    static func cell(_ size: Double, family: String) -> CGSize {
        func font(_ family: String) -> CTFont? {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(self.size(size, family: family)), nil)
            return CTFontCopyFamilyName(font) as String == family ? font : nil
        }
        guard let font = font(family) ?? font(reference) else { return CGSize(width: size * 0.6, height: size * 1.26) }
        var character = UniChar(("M" as Character).asciiValue!), glyph = CGGlyph(0), advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return CGSize(width: advance.width, height: height.rounded(.up))
    }

    /// The median lowercase outline height of `family`'s regular face at 1000 points; nil without the family.
    static func lowercaseHeight(_ family: String) -> Double? {
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, Set([kCTFontFamilyNameAttribute as String]) as CFSet) as? [CTFontDescriptor] ?? []
        // The regular face: a variable font's default instance can be another weight (Victor Mono's is Thin).
        let style = { (d: CTFontDescriptor) in CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? "" }
        guard let regular = matches.first(where: { style($0) == "Regular" }) ?? matches.first else { return nil }
        let font = CTFontCreateWithFontDescriptor(regular, 1000, nil)
        guard CTFontCopyFamilyName(font) as String == family else { return nil }
        return lowercaseHeight(font)
    }

    /// The median lowercase outline height of `font` at its own size; nil when it lacks the letters.
    static func lowercaseHeight(_ font: CTFont) -> Double? {
        let characters = Array("acemnorsuvwxz".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return nil }
        var bounds = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, glyphs.count)
        let heights = bounds.map { Double($0.height) }.sorted()
        return heights[heights.count / 2]
    }
}
