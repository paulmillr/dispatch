import Foundation

/// A color in OKLab's polar form: perceived lightness 0...1, chroma (0 is gray, sRGB tops out near 0.32) and hue in
/// degrees. Equal steps in `l` look equal whatever the hue, which is what lets a scheme set every accent's lightness
/// by number instead of by eye.
struct OKLCH: Equatable, Sendable {
    var l: Double
    var c: Double
    var h: Double

    init(l: Double, c: Double, h: Double) { (self.l, self.c, self.h) = (l, c, h) }

    init(lab: (l: Double, a: Double, b: Double)) {
        let hue = atan2(lab.b, lab.a) * 180 / .pi
        (l, c, h) = (lab.l, (lab.a * lab.a + lab.b * lab.b).squareRoot(), hue < 0 ? hue + 360 : hue)
    }

    var lab: (l: Double, a: Double, b: Double) {
        let radians = h * .pi / 180
        return (l, c * cos(radians), c * sin(radians))
    }
}

/// Björn Ottosson's OKLab (2020): linear sRGB → LMS cone response → cube root → opponent axes.
extension ThemeColor {
    /// sRGB transfer function, both ways.
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func oklab(linear r: Double, _ g: Double, _ b: Double) -> (l: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear sRGB, unclamped: a component outside 0...1 means the color is outside the sRGB gamut.
    static func linearRGB(oklab lab: (l: Double, a: Double, b: Double)) -> (Double, Double, Double) {
        let l = pow(lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b, 3)
        let m = pow(lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b, 3)
        let s = pow(lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// Whether `lch` is inside sRGB, or inside Display P3 when `displayP3`.
    static func inGamut(_ lch: OKLCH, displayP3: Bool = false) -> Bool {
        var (r, g, b) = linearRGB(oklab: lch.lab)
        if displayP3 { (r, g, b) = linearDisplayP3(linearSRGB: (r, g, b)) }
        let e = 1e-7
        return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && b >= -e && b <= 1 + e
    }

    /// Linear sRGB to linear Display P3, and back (both D65; sRGB values outside 0...1 are colors beyond sRGB).
    static func linearDisplayP3(linearSRGB c: (Double, Double, Double)) -> (Double, Double, Double) {
        (0.8224621 * c.0 + 0.1775380 * c.1, 0.0331941 * c.0 + 0.9668058 * c.1, 0.0170827 * c.0 + 0.0723974 * c.1 + 0.9105199 * c.2)
    }
    static func linearSRGB(displayP3 c: (Double, Double, Double)) -> (Double, Double, Double) {
        (1.2249401 * c.0 - 0.2249404 * c.1, -0.0420569 * c.0 + 1.0420571 * c.1, -0.0196376 * c.0 - 0.0786361 * c.1 + 1.0982735 * c.2)
    }

    /// The color itself in linear sRGB: a Display P3 color's own (components outside 0...1), not its sRGB stand-in's.
    var linearSRGB: (Double, Double, Double) {
        if let p3 = displayP3 {
            return Self.linearSRGB(displayP3: (Self.linear(Double(p3.r) / 255), Self.linear(Double(p3.g) / 255), Self.linear(Double(p3.b) / 255)))
        }
        let (r, g, b) = components
        return (Self.linear(r), Self.linear(g), Self.linear(b))
    }

    /// What every other reader of a theme file sees: the sRGB color, a Display P3 one's stand-in.
    var sRGBStandIn: ThemeColor { ThemeColor(r: r, g: g, b: b) }

    var oklab: (l: Double, a: Double, b: Double) {
        let (r, g, b) = linearSRGB
        return Self.oklab(linear: r, g, b)
    }

    var oklch: OKLCH { OKLCH(lab: oklab) }

    /// The sRGB color for `lch`, gamut-mapped the way CSS Color 4 recommends in spirit: lightness and hue stay, chroma
    /// shrinks (binary search) until the color fits, so an out-of-gamut request turns grayer rather than shifting hue
    /// or lightness the way per-channel clipping would. `displayP3`: mapped into Display P3 instead, a color beyond
    /// sRGB keeping its P3 value beside its sRGB stand-in.
    init(oklch: OKLCH, displayP3: Bool = false) {
        var lch = OKLCH(l: min(1, max(0, oklch.l)), c: max(0, oklch.c), h: oklch.h)
        if !Self.inGamut(lch, displayP3: displayP3) {
            var (low, high) = (0.0, lch.c)
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if Self.inGamut(OKLCH(l: lch.l, c: mid, h: lch.h), displayP3: displayP3) { low = mid } else { high = mid }
            }
            lch.c = low
        }
        let srgb = Self.linearRGB(oklab: lch.lab)
        if displayP3 {
            let (r, g, b) = Self.linearDisplayP3(linearSRGB: srgb)
            self.init(displayP3Red: Self.gamma(min(1, max(0, r))), green: Self.gamma(min(1, max(0, g))), blue: Self.gamma(min(1, max(0, b))))
            return
        }
        let (r, g, b) = srgb
        self.init(red: Self.gamma(min(1, max(0, r))), green: Self.gamma(min(1, max(0, g))), blue: Self.gamma(min(1, max(0, b))))
    }
}

/// Stored as `#rrggbb`, so a recipe reads like a theme file; a Display P3 color as `#rrggbb display-p3 #rrggbb`.
extension ThemeColor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        let parts = text.components(separatedBy: " display-p3 ")
        guard var color = ThemeColor(hex: parts[0]), parts.count <= 2 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a #rrggbb color: \(text)")
        }
        if parts.count == 2 {
            guard let p3 = ThemeColor(hex: parts[1]) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a #rrggbb color: \(text)")
            }
            color.displayP3 = P3(r: p3.r, g: p3.g, b: p3.b)
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayP3.map { "\(hex) display-p3 \($0.hex)" } ?? hex)
    }
}
