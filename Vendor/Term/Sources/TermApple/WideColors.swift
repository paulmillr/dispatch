#if canImport(Metal)
import Foundation
import Term

/// A theme's Display P3 colors (Config.displayP3) for the renderer. With them the shader takes every color as Display
/// P3: the theme's P3 colors as given, every other (sRGB: program colors, the theme's sRGB ones) converted here
/// first. Grays convert to themselves (the two spaces share white and transfer function). Used under the renderer's
/// lock, which its cache relies on.
public final class WideColors {
    public let theme: [UInt32: RGB]
    private var cache: [UInt32: RGB] = [:]
    private var last = (key: UInt32.max, color: RGB(r: 0, g: 0, b: 0))

    public init(_ theme: [UInt32: RGB]) { self.theme = theme }

    /// `color` (sRGB) as the shader should get it.
    public func map(_ color: RGB) -> RGB {
        let key = color.packed
        if key == last.key { return last.color }
        let mapped: RGB
        if let wide = theme[key] ?? cache[key] {
            mapped = wide
        } else {
            mapped = Self.displayP3(color)
            // Programs can paint any number of colors: the cache starts over rather than grow without bound.
            if cache.count >= 4096 { cache.removeAll(keepingCapacity: true) }
            cache[key] = mapped
        }
        last = (key, mapped)
        return mapped
    }

    /// An sRGB color's Display P3 components, 8-bit like the shader's input.
    public static func displayP3(_ c: RGB) -> RGB {
        func linear(_ v: UInt8) -> Double {
            let x = Double(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        func encoded(_ x: Double) -> UInt8 {
            let v = min(max(x, 0), 1)
            let e = v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
            return UInt8((e * 255).rounded())
        }
        let (r, g, b) = (linear(c.r), linear(c.g), linear(c.b))
        // Linear sRGB to linear Display P3 (both D65).
        return RGB(r: encoded(0.8224621 * r + 0.1775380 * g),
                   g: encoded(0.0331941 * r + 0.9668058 * g),
                   b: encoded(0.0170827 * r + 0.0723974 * g + 0.9105199 * b))
    }
}
#endif
