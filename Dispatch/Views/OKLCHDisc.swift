import CoreGraphics
import SwiftUI

/// The color discs of the scheme maker and editor: OKLCH hue around (0° up, clockwise), chroma out, at one lightness,
/// each pixel the color a pick there gives. sRGB's most colorful color for each hue sits at `core` of the radius in
/// either gamut, so Display P3 only adds a band outside it (the extra chroma P3 has for that hue): turning P3 on moves
/// nothing already on the disc. Without P3 the disc is the sRGB core alone.
enum OKLCHDisc {
    static let core = 0.8

    /// The most colorful color of hue `h` at lightness `l` that the gamut holds.
    static func maxChroma(l: Double, h: Double, displayP3: Bool) -> Double {
        var (low, high) = (0.0, 0.5)
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if ThemeColor.inGamut(OKLCH(l: l, c: mid, h: h), displayP3: displayP3) { low = mid } else { high = mid }
        }
        return low
    }

    /// Where a color of chroma `c` sits, as a fraction of the disc's radius: its share of sRGB's chroma for that hue
    /// inside the core, its share of P3's extra chroma in the band. Beyond the gamut it sits on the edge.
    static func radius(chroma c: Double, hue: Double, l: Double, displayP3: Bool) -> Double {
        let srgb = maxChroma(l: l, h: hue, displayP3: false)
        if c <= srgb { return srgb > 0 ? core * c / srgb : 0 }
        guard displayP3 else { return core }
        let p3 = maxChroma(l: l, h: hue, displayP3: true)
        return p3 > srgb ? min(1, core + (1 - core) * (c - srgb) / (p3 - srgb)) : core
    }

    /// The chroma at `radius` (0…1) along hue `hue`; without P3 the band holds sRGB's most colorful color.
    static func chroma(radius: Double, hue: Double, l: Double, displayP3: Bool) -> Double {
        let r = min(1, max(0, radius)), srgb = maxChroma(l: l, h: hue, displayP3: false)
        if r <= core { return r / core * srgb }
        guard displayP3 else { return srgb }
        let p3 = maxChroma(l: l, h: hue, displayP3: true)
        return srgb + (r - core) / (1 - core) * max(0, p3 - srgb)
    }

    /// The disc `pixels` square in Display P3, transparent outside it (and outside the core without P3).
    static func image(l: Double, displayP3: Bool, pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        // Each hue's two maxima, every half degree: the pixels look theirs up instead of searching.
        let steps = 720
        let srgb = (0..<steps).map { maxChroma(l: l, h: Double($0) / 2, displayP3: false) }
        let p3 = displayP3 ? (0..<steps).map { maxChroma(l: l, h: Double($0) / 2, displayP3: true) } : srgb
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        let half = Double(pixels) / 2
        for y in 0..<pixels {
            for x in 0..<pixels {
                let dx = Double(x) + 0.5 - half, dy = Double(y) + 0.5 - half
                let r = (dx * dx + dy * dy).squareRoot() / half
                // A pixel past the edge, so the clipped edge antialiases against real colors.
                guard r <= (displayP3 ? 1 : core) + 2 / half else { continue }
                var h = atan2(dy, dx) * 180 / .pi + 90
                if h < 0 { h += 360 }
                let step = min(steps - 1, Int(h * 2)), t = min(1, r)
                let c = t <= core ? t / core * srgb[step]
                    : displayP3 ? srgb[step] + (t - core) / (1 - core) * max(0, p3[step] - srgb[step]) : srgb[step]
                let (lr, lg, lb) = ThemeColor.linearDisplayP3(linearSRGB: ThemeColor.linearRGB(oklab: OKLCH(l: l, c: c, h: h).lab))
                let i = (y * pixels + x) * 4
                bytes[i] = byte(lr); bytes[i + 1] = byte(lg); bytes[i + 2] = byte(lb); bytes[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func byte(_ linear: Double) -> UInt8 {
        UInt8((ThemeColor.gamma(min(1, max(0, linear))) * 255).rounded())
    }

    /// A point on a disc of `radius` around `center` for hue `hue` (0° up) at `fraction` of the radius.
    static func point(center: CGPoint, radius: CGFloat, hue: Double, fraction: Double) -> CGPoint {
        let angle = (hue - 90) * .pi / 180
        return CGPoint(x: center.x + radius * fraction * cos(angle), y: center.y + radius * fraction * sin(angle))
    }

    /// The hue and radius fraction under `location` on a disc of `radius` around `center`.
    static func pick(_ location: CGPoint, center: CGPoint, radius: CGFloat) -> (hue: Double, fraction: Double) {
        let dx = location.x - center.x, dy = location.y - center.y
        return (ThemeGenerator.wrap(atan2(dy, dx) * 180 / .pi + 90), Double((dx * dx + dy * dy).squareRoot() / max(1, radius)))
    }
}

/// The last disc drawn, so a redraw at the same lightness and gamut reuses it (a lightness drag draws one per step).
final class OKLCHDiscCache {
    private var key: (l: Double, p3: Bool, pixels: Int)?
    private var image: CGImage?

    func image(l: Double, displayP3: Bool, pixels: Int) -> CGImage? {
        let l = (l * 400).rounded() / 400
        if let key, key.l == l, key.p3 == displayP3, key.pixels == pixels, let image { return image }
        key = (l, displayP3, pixels)
        image = OKLCHDisc.image(l: l, displayP3: displayP3, pixels: pixels)
        return image
    }
}

extension ThemeColor {
    /// CSS's `oklch(62% 0.160 250)` form, so it pastes into CSS, of the color itself (a Display P3 color's own, not its
    /// stand-in's). A gray has no hue.
    var oklchText: String {
        let lch = oklch
        let hue = lch.c < 0.0005 ? "none" : "\(Int(lch.h.rounded()) % 360)"
        return "oklch(\(String(format: "%.0f", lch.l * 100))% \(String(format: "%.3f", lch.c)) \(hue))"
    }
}
