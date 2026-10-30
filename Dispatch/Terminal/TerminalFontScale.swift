import CoreText
import Foundation
import os

/// Every terminal font drawn at Source Code Pro's apparent size: the size Settings shows is multiplied by the ratio of
/// Source Code Pro's lowercase height to the font's, so switching fonts keeps the text the same size (Inconsolata
/// draws larger, Victor Mono smaller). Lowercase height is the median outline height of "acemnorsuvwxz", as chat's
/// calibration measures it (`scripts/measure-chat-fonts.swift`), read from the glyphs' bounds rather than rendered.
/// Shared with the iPhone app; both register the bundled fonts before a terminal opens.
enum TerminalFontScale {
    static let reference = "Source Code Pro"
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
        let characters = Array("acemnorsuvwxz".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return nil }
        var bounds = [CGRect](repeating: .zero, count: glyphs.count)
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &bounds, glyphs.count)
        let heights = bounds.map { Double($0.height) }.sorted()
        return heights[heights.count / 2]
    }
}
