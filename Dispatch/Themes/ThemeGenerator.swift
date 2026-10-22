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

    static func inGamut(_ lch: OKLCH) -> Bool {
        let (r, g, b) = linearRGB(oklab: lch.lab)
        let e = 1e-7
        return r >= -e && r <= 1 + e && g >= -e && g <= 1 + e && b >= -e && b <= 1 + e
    }

    var oklab: (l: Double, a: Double, b: Double) {
        let (r, g, b) = components
        return Self.oklab(linear: Self.linear(r), Self.linear(g), Self.linear(b))
    }

    var oklch: OKLCH { OKLCH(lab: oklab) }

    /// The sRGB color for `lch`, gamut-mapped the way CSS Color 4 recommends in spirit: lightness and hue stay, chroma
    /// shrinks (binary search) until the color fits, so an out-of-gamut request turns grayer rather than shifting hue
    /// or lightness the way per-channel clipping would.
    init(oklch: OKLCH) {
        var lch = OKLCH(l: min(1, max(0, oklch.l)), c: max(0, oklch.c), h: oklch.h)
        if !Self.inGamut(lch) {
            var (low, high) = (0.0, lch.c)
            for _ in 0..<24 {
                let mid = (low + high) / 2
                if Self.inGamut(OKLCH(l: lch.l, c: mid, h: lch.h)) { low = mid } else { high = mid }
            }
            lch.c = low
        }
        let (r, g, b) = Self.linearRGB(oklab: lch.lab)
        self.init(red: Self.gamma(min(1, max(0, r))), green: Self.gamma(min(1, max(0, g))), blue: Self.gamma(min(1, max(0, b))))
    }
}

/// Stored as `#rrggbb`, so a recipe reads like a theme file.
extension ThemeColor: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let color = ThemeColor(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a #rrggbb color: \(hex)")
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// The few choices a made color scheme comes from. Everything else follows by rule, so any recipe makes a readable
/// scheme and the same recipe always makes the same one.
extension ColorVision {
    /// How far apart (Oklab) two colors look to the least able viewer this vision covers, typical vision included.
    func distance(_ a: ThemeColor, _ b: ThemeColor) -> Double {
        ([nil] + deficiencies.map(Optional.some)).map { deficiency in
            let (x, y) = deficiency.map { (a.simulated($0), b.simulated($0)) } ?? (a, b)
            return x.distance(to: y)
        }.min() ?? 0
    }
}

extension ThemeColor {
    /// This color as someone with `deficiency` sees it.
    func simulated(_ deficiency: ColorVision.Deficiency) -> ThemeColor {
        let (r, g, b) = components
        let rgb = [Self.linear(r), Self.linear(g), Self.linear(b)]
        let seen = deficiency.matrix.map { row in min(1, max(0, zip(row, rgb).map(*).reduce(0, +))) }
        return ThemeColor(red: Self.gamma(seen[0]), green: Self.gamma(seen[1]), blue: Self.gamma(seen[2]))
    }

    /// Euclidean distance in Oklab: about 0.02 is just noticeable, 0.1 plainly different.
    func distance(to other: ThemeColor) -> Double {
        let (a, b) = (oklab, other.oklab)
        return ((a.l - b.l) * (a.l - b.l) + (a.a - b.a) * (a.a - b.a) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }
}

struct ThemeRecipe: Equatable, Codable, Sendable {
    /// The color the scheme grows from: its hue tints the background and bends the accents, and it becomes the cursor.
    var seed: ThemeColor
    var light: Bool
    var harmony: Harmony
    /// 0 muted, pastel accents … 1 as saturated as sRGB allows.
    var vibrancy: Double
    /// 0 soft (lifted background, gentler text) … 1 crisp (deep background, bright text).
    var contrast: Double
    /// 0 neutral grays … 1 background and text strongly tinted by the seed's hue.
    var tint: Double
    /// Colorblind recipes fix the accent hues for that vision; the harmony then shapes only the seed's tint.
    var vision: ColorVision

    init(seed: ThemeColor, light: Bool = false, harmony: Harmony = .analogous,
         vibrancy: Double = 0.6, contrast: Double = 0.55, tint: Double = 0.45, vision: ColorVision = .typical) {
        (self.seed, self.light, self.harmony) = (seed, light, harmony)
        (self.vibrancy, self.contrast, self.tint, self.vision) = (vibrancy, contrast, tint, vision)
    }

    /// The same recipe for another vision (presets keep their look and change who they are for).
    func with(vision: ColorVision) -> ThemeRecipe {
        var recipe = self
        recipe.vision = vision
        return recipe
    }

    private enum CodingKeys: String, CodingKey { case seed, light, harmony, vibrancy, contrast, tint, vision }

    // Recipes saved before colorblind schemes have no vision; a typical one is still written without it.
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        seed = try fields.decode(ThemeColor.self, forKey: .seed)
        light = try fields.decode(Bool.self, forKey: .light)
        harmony = try fields.decode(Harmony.self, forKey: .harmony)
        vibrancy = try fields.decode(Double.self, forKey: .vibrancy)
        contrast = try fields.decode(Double.self, forKey: .contrast)
        tint = try fields.decode(Double.self, forKey: .tint)
        vision = try fields.decodeIfPresent(ColorVision.self, forKey: .vision) ?? .typical
    }

    func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(seed, forKey: .seed)
        try fields.encode(light, forKey: .light)
        try fields.encode(harmony, forKey: .harmony)
        try fields.encode(vibrancy, forKey: .vibrancy)
        try fields.encode(contrast, forKey: .contrast)
        try fields.encode(tint, forKey: .tint)
        if vision != .typical { try fields.encode(vision, forKey: .vision) }
    }

    /// Which hues the accents lean toward, relative to the seed's: the color wheel's classic harmonies.
    enum Harmony: String, Codable, CaseIterable, Identifiable, Sendable {
        case classic, analogous, complementary, splitComplementary, triadic, square

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: "Classic"
            case .analogous: "Analogous"
            case .complementary: "Complementary"
            case .splitComplementary: "Split complementary"
            case .triadic: "Triadic"
            case .square: "Square"
            }
        }

        var detail: String {
            switch self {
            case .classic: "standard ANSI hues; the seed only tints"
            case .analogous: "every accent leans toward the seed"
            case .complementary: "toward the seed and its opposite"
            case .splitComplementary: "toward the seed and both sides of its opposite"
            case .triadic: "toward three hues a third apart"
            case .square: "toward four hues a quarter apart"
            }
        }

        /// The hues (degrees) accents are drawn toward, for a seed of hue `seed`.
        func attractors(seed: Double) -> [Double] {
            let offsets: [Double]
            switch self {
            case .classic: offsets = []
            case .analogous: offsets = [0]
            case .complementary: offsets = [0, 180]
            case .splitComplementary: offsets = [0, 150, 210]
            case .triadic: offsets = [0, 120, 240]
            case .square: offsets = [0, 90, 180, 270]
            }
            return offsets.map { ThemeGenerator.wrap(seed + $0) }
        }
    }

    /// A named starting point.
    struct Preset: Identifiable, Sendable {
        let name: String
        let recipe: ThemeRecipe
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Dusk", recipe: ThemeRecipe(seed: ThemeColor(r: 0x8B, g: 0x6C, b: 0xF0), harmony: .analogous,
                                                 vibrancy: 0.55, contrast: 0.5, tint: 0.6)),
        Preset(name: "Harbor", recipe: ThemeRecipe(seed: ThemeColor(r: 0x2F, g: 0xA3, b: 0xB5), harmony: .complementary,
                                                   vibrancy: 0.6, contrast: 0.6, tint: 0.5)),
        Preset(name: "Ember", recipe: ThemeRecipe(seed: ThemeColor(r: 0xE8, g: 0x74, b: 0x3B), harmony: .analogous,
                                                  vibrancy: 0.7, contrast: 0.45, tint: 0.45)),
        Preset(name: "Moss", recipe: ThemeRecipe(seed: ThemeColor(r: 0x7A, g: 0xA3, b: 0x52), harmony: .triadic,
                                                 vibrancy: 0.4, contrast: 0.35, tint: 0.55)),
        Preset(name: "Neon", recipe: ThemeRecipe(seed: ThemeColor(r: 0xFF, g: 0x3F, b: 0xB4), harmony: .square,
                                                 vibrancy: 1, contrast: 0.85, tint: 0.35)),
        Preset(name: "Graphite", recipe: ThemeRecipe(seed: ThemeColor(r: 0x8A, g: 0x8F, b: 0x98), harmony: .classic,
                                                     vibrancy: 0.45, contrast: 0.7, tint: 0)),
        Preset(name: "Paper", recipe: ThemeRecipe(seed: ThemeColor(r: 0xC8, g: 0xA2, b: 0x6A), light: true, harmony: .classic,
                                                  vibrancy: 0.55, contrast: 0.4, tint: 0.55)),
        Preset(name: "Glacier", recipe: ThemeRecipe(seed: ThemeColor(r: 0x5B, g: 0x8F, b: 0xD9), light: true,
                                                    harmony: .splitComplementary, vibrancy: 0.6, contrast: 0.6, tint: 0.4)),
        Preset(name: "Sakura", recipe: ThemeRecipe(seed: ThemeColor(r: 0xE2, g: 0x7A, b: 0xA6), light: true, harmony: .analogous,
                                                   vibrancy: 0.5, contrast: 0.45, tint: 0.5)),
    ]

    static let standard = presets[0].recipe

    /// "Surprise me": a pleasing recipe picked from `seed` alone. Seeds are vivid enough to matter, light schemes come
    /// up about a third of the time, and the knobs stay in the range where schemes look designed rather than random.
    static func random(seed: UInt64) -> ThemeRecipe {
        var state = seed
        func next() -> Double {
            // SplitMix64: tiny, well mixed, and the same on every machine.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        let hue = next() * 360
        let color = ThemeColor(oklch: OKLCH(l: 0.62 + next() * 0.14, c: 0.09 + next() * 0.11, h: hue))
        let light = next() < 0.33
        let harmonies = Harmony.allCases
        let harmony = harmonies[min(harmonies.count - 1, Int(next() * Double(harmonies.count)))]
        return ThemeRecipe(seed: color, light: light, harmony: harmony,
                           vibrancy: round2(0.35 + next() * 0.55), contrast: round2(0.3 + next() * 0.55),
                           tint: round2(0.15 + next() * 0.6))
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// The recipe a made theme carries in its file (a comment line), so it can be opened in the maker again.
    init?(theme: TerminalTheme) {
        guard let line = theme.extra.first(where: { $0.hasPrefix(Self.marker) }),
              let recipe = try? JSONDecoder().decode(ThemeRecipe.self, from: Data(line.dropFirst(Self.marker.count).utf8))
        else { return nil }
        self = recipe
    }

    static let marker = "# dispatch-recipe: "

    var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return Self.marker + json
    }
}

/// Makes a terminal color scheme from a `ThemeRecipe`, in OKLCH, so lightness, colorfulness and hue are separate
/// numbers that look like what they say.
///
/// The approach, from the schemes that get this right:
/// - **Fixed lightness, chosen hues.** Like Solarized and Selenized, accents share (nearly) one lightness and differ in
///   hue, so no color shouts and each sits the same distance from the background. Selenized's small per-hue offsets
///   are kept (yellow and cyan a little lighter) because a dim yellow reads as olive. Brights keep the hue and step
///   lighter on dark backgrounds, deeper on light ones, as in Selenized, so `ls` and prompts never fall back to grays.
/// - **Hues keep their meaning.** Each ANSI slot starts at its anchor (red 29°, yellow 95°, green 142°, cyan 195°,
///   blue 258°, magenta 328°, Oklab's sRGB primaries and their mixes), because errors must stay red and success green.
///   The harmony mode adds attractor hues (the seed, its complement, a triad…); every accent turns toward the nearest
///   one, by at most its slot's bound (12°…22°), and accents far from every attractor lose a little chroma, so the
///   harmony's colors lead and the rest recede. A grayish seed has no hue to lean toward and bends nothing.
/// - **Tinted neutrals.** Background, text and the black/white slots are the seed's hue at low chroma (Catppuccin,
///   Rosé Pine, Tokyo Night, Flexoki all tint their neutrals), from neutral gray at `tint` 0.
/// - **Gamut mapping** reduces chroma at constant lightness and hue until the color is in sRGB (`ThemeColor(oklch:)`).
/// - **A hard contrast floor.** WCAG 2 contrast is the guarantee because it is the standard every checker shows, even
///   though APCA models dark mode better; the lightness choices above are what keep dark schemes from glaring. After
///   rounding to `#rrggbb`, colors 1–6 and 9–14, white (7) on dark and black (0) on light meet 4.5:1 against the
///   background, the foreground and the brightest text slot 7:1, bright black (8, comments and suggestions) 3:1, the
///   cursor 4.5:1 (so its text, the background, reads on it) and the foreground 4.5:1 on the selection. A color that
///   misses moves away from the background's lightness until it meets the floor; it never changes hue.
/// - **Colorblind recipes** trade hue meaning for hues those viewers can tell apart: each vision has fixed accent hues
///   and per-slot lightness offsets (dark, light), found by searching for the largest smallest Oklab distance between
///   the six accents as protanopes and deuteranopes (red-green) or tritanopes (blue-yellow) see them (Machado 2009),
///   within the contrast floor. Red-green turns red to vermillion and green to sky blue, as GitHub's colorblind
///   themes do; blue-yellow keeps red and green and turns yellow to orange. Harmonies no longer bend the accents, and
///   accents keep at least `colorblindChroma`. A pair that still looks closer than `distinctFloor` moves apart in
///   lightness (`separated`), so lightness tells apart what hue can't.
/// - **Slots behave like terminals expect.** On a dark scheme black (0) is a raised surface and white (7) is readable
///   text; on a light one black is readable text and white a sunken surface, as Solarized and Selenized do.
enum ThemeGenerator {
    /// Each accent's OKLCH hue by ANSI slot 1–6: red, green, yellow, blue, magenta, cyan.
    static let anchors: [Double] = [29, 142, 95, 258, 328, 195]
    /// How far (degrees) a harmony may turn each accent, by slot: yellow and red have the narrowest bands before they
    /// read as orange or pink.
    static let maxBend: [Double] = [14, 22, 12, 22, 20, 22]
    /// Lightness offsets per accent (dark, light) by slot, after Selenized's per-hue factors.
    private static let lightnessOffsets: [(dark: Double, light: Double)] = [
        (-0.01, 0), (0.03, 0.01), (0.08, 0.05), (-0.01, 0), (0, 0), (0.04, 0.01),
    ]
    /// Colorblind accent hues by slot 1–6, and lightness offsets (dark, light), from the search described above.
    private static let colorblindAccents: [ColorVision: (hues: [Double], dark: [Double], light: [Double])] = [
        .redGreen: ([44, 212, 95, 275, 340, 171], [-0.08, 0.10, 0.15, -0.03, -0.07, 0.03], [-0.04, -0.18, -0.20, 0.03, 0.03, -0.06]),
        .blueYellow: ([33, 137, 74, 310, 334, 204], [-0.10, 0.07, 0.16, -0.10, 0.02, -0.10], [-0.09, -0.19, 0.03, -0.07, -0.20, -0.04]),
    ]
    /// Colorblind accents keep this much chroma whatever the vibrancy: muted, they would lean on lightness alone.
    static let colorblindChroma = 0.12
    /// The least Oklab distance between two accents, as the vision's least able viewer sees them.
    static let distinctFloor = 0.07

    /// Each slot's starting hue for `vision`.
    static func anchors(for vision: ColorVision) -> [Double] { colorblindAccents[vision]?.hues ?? anchors }

    /// The slots in hue order around the wheel, for keeping neighbors apart.
    private static let wheelOrder = anchors.indices.sorted { anchors[$0] < anchors[$1] }

    static let accentFloor = 4.5
    static let textFloor = 7.0
    static let dimFloor = 3.0

    static func wrap(_ hue: Double) -> Double {
        let h = hue.truncatingRemainder(dividingBy: 360)
        return h < 0 ? h + 360 : h
    }

    /// Signed shortest turn from `a` to `b`, -180...180.
    static func turn(from a: Double, to b: Double) -> Double {
        var d = wrap(b - a)
        if d > 180 { d -= 360 }
        return d
    }

    /// How much the seed has a hue at all: 0 for grays, 1 from chroma 0.06.
    static func presence(_ seed: OKLCH) -> Double { smoothstep(0.015, 0.06, seed.c) }

    /// The six accent hues, by slot 1–6, after the harmony bends them.
    static func hues(for recipe: ThemeRecipe) -> [Double] {
        if let fixed = colorblindAccents[recipe.vision] { return fixed.hues }
        let seed = recipe.seed.oklch
        let attractors = recipe.harmony.attractors(seed: seed.h)
        let strength = presence(seed)
        var bends = anchors.indices.map { index -> Double in
            let anchor = anchors[index]
            guard let nearest = attractors.min(by: { abs(turn(from: anchor, to: $0)) < abs(turn(from: anchor, to: $1)) })
            else { return 0 }
            let d = turn(from: anchor, to: nearest)
            // A far attractor pulls half as hard: the palette leans, it doesn't collapse onto one hue.
            let reach = 1 - 0.5 * smoothstep(45, 180, abs(d))
            let bound = maxBend[index] * reach * strength
            return max(-bound, min(bound, d))
        }
        // Neighbors pulled toward one attractor from both sides would meet (green and cyan both turning to a teal
        // seed): give back the converging part of their bends until they are `minimumSeparation` apart again. Every
        // anchor gap is wider than that, so unbending always gets there.
        for _ in 0..<4 {
            for (position, i) in wheelOrder.enumerated() {
                let j = wheelOrder[(position + 1) % wheelOrder.count]
                let gap = wrap(anchors[j] - anchors[i]) + bends[j] - bends[i]
                guard gap < minimumSeparation else { continue }
                let towardJ = max(0, bends[i]), towardI = max(0, -bends[j])
                let need = minimumSeparation - gap, total = towardJ + towardI
                guard total > 0 else { continue }
                bends[i] -= need * towardJ / total
                bends[j] += need * towardI / total
            }
        }
        return anchors.indices.map { wrap(anchors[$0] + bends[$0]) }
    }

    /// The least hue difference (degrees) between neighboring accents, so yellow never meets green.
    static let minimumSeparation = 40.0

    static func make(_ recipe: ThemeRecipe) -> TerminalTheme {
        let t = clamp01(recipe.contrast), v = clamp01(recipe.vibrancy), k = clamp01(recipe.tint)
        let light = recipe.light
        let seed = recipe.seed.oklch
        let hued = presence(seed)
        let hue = seed.h

        // Neutrals: the seed's hue at low chroma.
        let neutralC = k * (light ? 0.032 : 0.045) * hued
        let bgL = light ? 0.945 + 0.045 * t : 0.25 - 0.10 * t
        let background = ThemeColor(oklch: OKLCH(l: bgL, c: neutralC, h: hue))
        let fgL = light ? 0.40 - 0.16 * t : 0.85 + 0.11 * t
        let foreground = readable(OKLCH(l: fgL, c: neutralC * 0.45, h: hue), on: background, light: light, floor: textFloor)

        // Accents.
        let accentHues = hues(for: recipe)
        let attractors = recipe.harmony.attractors(seed: hue)
        let baseL = light ? 0.56 - 0.08 * t : 0.70 + 0.08 * t
        let colorblind = colorblindAccents[recipe.vision]
        let baseC = colorblind == nil ? 0.06 + 0.14 * v : max(colorblindChroma, 0.06 + 0.14 * v)
        var planned: [(lch: OKLCH, emphasis: Double)] = []
        for (index, h) in accentHues.enumerated() {
            let distance = attractors.map { abs(turn(from: h, to: $0)) }.min() ?? 0
            let emphasis = colorblind == nil ? 1 - 0.3 * smoothstep(20, 90, distance) * hued : 1
            let offset = colorblind.map { light ? $0.light[index] : $0.dark[index] }
                ?? (light ? lightnessOffsets[index].light : lightnessOffsets[index].dark)
            planned.append((OKLCH(l: baseL + offset, c: baseC * emphasis, h: h), emphasis))
        }
        let normals = separated(planned.map(\.lch), vision: recipe.vision, on: background, light: light)
        let brights = separated(normals.indices.map { index in
            OKLCH(l: normals[index].oklch.l + (light ? -0.07 : 0.08), c: baseC * planned[index].emphasis * 1.05,
                  h: accentHues[index])
        }, vision: recipe.vision, on: background, light: light)

        // Black and white: one is text, the other a surface, by side.
        let dim = readable(OKLCH(l: bgL + (fgL - bgL) * 0.45, c: neutralC * 0.8, h: hue), on: background, light: light,
                           floor: dimFloor)
        let black: ThemeColor, white: ThemeColor, brightWhite: ThemeColor
        if light {
            black = readable(OKLCH(l: fgL + 0.03, c: neutralC * 0.6, h: hue), on: background, light: true, floor: accentFloor)
            white = ThemeColor(oklch: OKLCH(l: bgL - 0.075, c: neutralC * 1.2, h: hue))
            brightWhite = ThemeColor(oklch: OKLCH(l: bgL - 0.025, c: neutralC, h: hue))
        } else {
            black = ThemeColor(oklch: OKLCH(l: bgL + 0.075, c: neutralC * 1.15, h: hue))
            white = readable(OKLCH(l: fgL - 0.07, c: neutralC * 0.6, h: hue), on: background, light: false, floor: accentFloor)
            brightWhite = readable(OKLCH(l: min(0.99, fgL + 0.03), c: neutralC * 0.3, h: hue), on: background, light: false,
                                   floor: textFloor)
        }

        var theme = TerminalTheme()
        theme.background = background
        theme.foreground = foreground
        theme.palette = [black] + normals + [white, dim] + brights + [brightWhite]

        // The cursor is the seed itself when it reads on the background, else the seed moved to where it does.
        theme.cursor = readable(OKLCH(l: seed.l, c: max(seed.c, 0.02 * hued), h: hue), on: background, light: light,
                                floor: accentFloor)
        theme.cursorText = background

        // Selection: a seed-tinted band the text stays readable on.
        let selectionC = max(neutralC * 1.6, (0.03 + 0.04 * v) * hued)
        var selectionL = light ? bgL - 0.11 - 0.03 * t : bgL + 0.12 + 0.03 * t
        var selection = ThemeColor(oklch: OKLCH(l: selectionL, c: selectionC, h: hue))
        while selection.contrast(with: foreground) < accentFloor, light ? selectionL < bgL : selectionL > bgL {
            selectionL += light ? 0.005 : -0.005
            selection = ThemeColor(oklch: OKLCH(l: selectionL, c: selectionC, h: hue))
        }
        theme.selectionBackground = selection
        theme.selectionForeground = foreground
        theme.extra = [recipe.line]
        return theme
    }

    /// Accents made readable; for a colorblind vision, the pair that looks closest moves apart in lightness (the lighter
    /// one lighter, the darker one darker) a step at a time until every pair is `distinctFloor` apart or the steps run
    /// out. The contrast floor still holds: a color pushed toward the background is lifted back by `readable`.
    static func separated(_ planned: [OKLCH], vision: ColorVision, on background: ThemeColor, light: Bool) -> [ThemeColor] {
        var planned = planned
        var colors = planned.map { readable($0, on: background, light: light, floor: accentFloor) }
        guard vision != .typical else { return colors }
        for _ in 0..<60 {
            var closest = (distance: Double.infinity, first: 0, second: 0)
            for first in colors.indices {
                for second in colors.indices where second > first {
                    let distance = vision.distance(colors[first], colors[second])
                    if distance < closest.distance { closest = (distance, first, second) }
                }
            }
            guard closest.distance < distinctFloor else { break }
            let lighterFirst = colors[closest.first].oklch.l >= colors[closest.second].oklch.l
            let (up, down) = lighterFirst ? (closest.first, closest.second) : (closest.second, closest.first)
            planned[up].l = min(0.98, planned[up].l + 0.01)
            planned[down].l = max(0.02, planned[down].l - 0.01)
            colors[up] = readable(planned[up], on: background, light: light, floor: accentFloor)
            colors[down] = readable(planned[down], on: background, light: light, floor: accentFloor)
        }
        return colors
    }

    /// `lch`, moved away from the background's lightness (never turned) until it meets `floor` as `#rrggbb`. Pure white
    /// and black clear every floor here against the backgrounds this makes, so the search always ends.
    static func readable(_ lch: OKLCH, on background: ThemeColor, light: Bool, floor: Double) -> ThemeColor {
        var lch = lch
        var color = ThemeColor(oklch: lch)
        while color.contrast(with: background) < floor, light ? lch.l > 0 : lch.l < 1 {
            lch.l = light ? max(0, lch.l - 0.005) : min(1, lch.l + 0.005)
            color = ThemeColor(oklch: lch)
        }
        return color
    }

    /// A name for a made scheme that says what it looks like: an adjective when one knob stands out (Vivid or Muted,
    /// Crisp or Soft, Deep or Gray), then a noun for the seed's hue family, dark or light flavored; grays are Graphite
    /// or Paper. Schemes that look alike share the pattern; one whose name is `taken` moves to the family's next noun
    /// before falling back to a number, so two different schemes never get one name.
    static func suggestedName(for recipe: ThemeRecipe, taken: Set<String> = []) -> String {
        let seed = recipe.seed.oklch
        let families: [(dark: [String], light: [String])] = [
            (["Garnet", "Ruby", "Cinder"], ["Petal", "Rose", "Blush"]),
            (["Ember", "Rust", "Flare"], ["Coral", "Peach", "Salmon"]),
            (["Copper", "Bronze", "Clay"], ["Apricot", "Melon", "Terracotta"]),
            (["Amber", "Honey", "Ochre"], ["Sand", "Wheat", "Butter"]),
            (["Olive", "Lichen", "Fern"], ["Pear", "Lime", "Celery"]),
            (["Moss", "Forest", "Pine"], ["Meadow", "Sage", "Clover"]),
            (["Lagoon", "Jade", "Reef"], ["Mint", "Spearmint", "Aloe"]),
            (["Harbor", "Teal", "Tide"], ["Seafoam", "Surf", "Aqua"]),
            (["Deep Sea", "Abyss", "Fjord"], ["Glacier", "Frost", "Sky"]),
            (["Midnight", "Navy", "Indigo"], ["Periwinkle", "Cornflower", "Bluebell"]),
            (["Dusk", "Twilight", "Violet"], ["Lilac", "Lavender", "Wisteria"]),
            (["Orchid", "Plum", "Mulberry"], ["Peony", "Fuchsia", "Orchid Bloom"]),
        ]
        let grays = (dark: ["Graphite", "Slate", "Ash"], light: ["Paper", "Linen", "Chalk"])
        let nouns: [String]
        if presence(seed) < 0.5 {
            nouns = recipe.light ? grays.light : grays.dark
        } else {
            let family = families[Int(wrap(seed.h + 15) / 30) % families.count]
            nouns = recipe.light ? family.light : family.dark
        }
        // The knob farthest from its middle, if it is far enough to show.
        let knobs: [(value: Double, low: String, high: String)] = [
            (recipe.vibrancy, "Muted", "Vivid"), (recipe.contrast, "Soft", "Crisp"), (recipe.tint, "Gray", "Deep"),
        ]
        let standout = knobs.max { abs($0.value - 0.5) < abs($1.value - 0.5) }
        let adjective = standout.flatMap { abs($0.value - 0.5) >= 0.25 ? ($0.value < 0.5 ? $0.low : $0.high) : nil }
        let names = nouns.map { [adjective, $0].compactMap { $0 }.joined(separator: " ") }
        if let free = names.first(where: { !taken.contains($0) }) { return free }
        return (2...).lazy.map { "\(names[0]) \($0)" }.first { !taken.contains($0) }!
    }

    private static func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0.5 }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
