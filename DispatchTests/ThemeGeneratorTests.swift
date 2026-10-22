import XCTest
@testable import DispatchApp

/// Made color schemes: OKLab conversions, the contrast floor and slot roles over every mode, harmony and preset, and
/// a sweep of seeds.
final class ThemeGeneratorTests: XCTestCase {
    func testOKLabMatchesReferenceValuesAndRoundTrips() {
        // CSS Color 4's OKLab values for the sRGB primaries and white.
        let references: [(String, Double, Double, Double)] = [
            ("#ff0000", 0.62796, 0.22486, 0.12585), ("#00ff00", 0.86644, -0.23389, 0.17950),
            ("#0000ff", 0.45201, -0.03246, -0.31153), ("#ffffff", 1, 0, 0), ("#000000", 0, 0, 0),
        ]
        for (hex, l, a, b) in references {
            let lab = ThemeColor(hex: hex)!.oklab
            XCTAssertEqual(lab.l, l, accuracy: 1e-4, hex)
            XCTAssertEqual(lab.a, a, accuracy: 1e-4, hex)
            XCTAssertEqual(lab.b, b, accuracy: 1e-4, hex)
        }
        let red = ThemeColor(hex: "#ff0000")!.oklch
        XCTAssertEqual(red.c, 0.25768, accuracy: 1e-4)
        XCTAssertEqual(red.h, 29.234, accuracy: 0.01)
        for r in stride(from: 0, through: 255, by: 17) {
            for g in stride(from: 0, through: 255, by: 17) {
                for b in stride(from: 0, through: 255, by: 17) {
                    let color = ThemeColor(r: UInt8(r), g: UInt8(g), b: UInt8(b))
                    XCTAssertEqual(ThemeColor(oklch: color.oklch), color)
                }
            }
        }
    }

    func testGamutMappingKeepsLightnessAndHue() {
        // Far outside sRGB: chroma gives way, lightness and hue stay.
        for hue in stride(from: 0.0, to: 360, by: 20) {
            for l in [0.3, 0.6, 0.85] {
                let mapped = ThemeColor(oklch: OKLCH(l: l, c: 0.4, h: hue)).oklch
                XCTAssertEqual(mapped.l, l, accuracy: 0.01, "L \(l) h \(hue)")
                XCTAssertEqual(abs(ThemeGenerator.turn(from: hue, to: mapped.h)), 0, accuracy: 3, "L \(l) h \(hue)")
                XCTAssertLessThan(mapped.c, 0.4)
            }
        }
        XCTAssertEqual(ThemeColor(oklch: OKLCH(l: 1.2, c: 0, h: 0)), ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(ThemeColor(oklch: OKLCH(l: -0.1, c: 0.2, h: 0)), ThemeColor(r: 0, g: 0, b: 0))
    }

    func testEveryRecipeMeetsTheContrastFloorAndSlotRoles() {
        var recipes = ThemeRecipe.presets.map(\.recipe) + (0..<64).map { ThemeRecipe.random(seed: UInt64($0)) }
        for light in [false, true] {
            for harmony in ThemeRecipe.Harmony.allCases {
                for hue in stride(from: 0.0, to: 360, by: 30) {
                    for (l, c) in [(0.3, 0.12), (0.7, 0.3), (0.6, 0)] {
                        for knob in [0.0, 0.5, 1.0] {
                            recipes.append(ThemeRecipe(seed: ThemeColor(oklch: OKLCH(l: l, c: c, h: hue)), light: light,
                                                       harmony: harmony, vibrancy: knob, contrast: 1 - knob, tint: knob))
                        }
                    }
                }
            }
        }
        recipes += recipes.flatMap { [$0.with(vision: .redGreen), $0.with(vision: .blueYellow)] }
        for recipe in recipes {
            let theme = ThemeGenerator.make(recipe), background = theme.background
            let label = recipe.line
            XCTAssertEqual(theme.isLight, recipe.light, label)
            XCTAssertEqual(theme.palette.count, 16, label)
            let palette = theme.palette.compactMap { $0 }
            XCTAssertEqual(palette.count, 16, label)
            for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
                XCTAssertGreaterThanOrEqual(palette[index].contrast(with: background), ThemeGenerator.accentFloor, "\(index) \(label)")
            }
            for index in 1...6 { XCTAssertNotEqual(palette[index], palette[index + 8], "\(index) \(label)") }
            XCTAssertGreaterThanOrEqual(theme.foreground.contrast(with: background), ThemeGenerator.textFloor, label)
            XCTAssertGreaterThanOrEqual(palette[8].contrast(with: background), ThemeGenerator.dimFloor, label)
            // Black is text on light schemes, white on dark ones; the other is a surface near the background.
            let text = recipe.light ? palette[0] : palette[7], surface = recipe.light ? palette[7] : palette[0]
            XCTAssertGreaterThanOrEqual(text.contrast(with: background), ThemeGenerator.accentFloor, label)
            XCTAssertLessThan(surface.contrast(with: background), 1.6, label)
            if !recipe.light { XCTAssertGreaterThanOrEqual(palette[15].contrast(with: background), ThemeGenerator.textFloor, label) }
            XCTAssertGreaterThanOrEqual(theme.cursor!.contrast(with: background), ThemeGenerator.accentFloor, label)
            XCTAssertEqual(theme.cursorText, background, label)
            XCTAssertGreaterThanOrEqual(theme.foreground.contrast(with: theme.selectionBackground!), ThemeGenerator.accentFloor, label)
            XCTAssertEqual(theme.selectionForeground, theme.foreground, label)
        }
    }

    func testAccentHuesKeepTheirMeaningAndStayApart() {
        for harmony in ThemeRecipe.Harmony.allCases {
            for hue in stride(from: 0.0, to: 360, by: 5) {
                let recipe = ThemeRecipe(seed: ThemeColor(oklch: OKLCH(l: 0.65, c: 0.15, h: hue)), harmony: harmony)
                let hues = ThemeGenerator.hues(for: recipe)
                for index in hues.indices {
                    let bend = abs(ThemeGenerator.turn(from: ThemeGenerator.anchors[index], to: hues[index]))
                    XCTAssertLessThanOrEqual(bend, ThemeGenerator.maxBend[index] + 1e-9, "\(harmony) \(hue) slot \(index + 1)")
                }
                // Around the wheel (from red, which never crosses 0°): red, yellow, green, cyan, blue, magenta, apart.
                let around = hues.sorted()
                XCTAssertEqual(around.map { hues.firstIndex(of: $0)! }, [0, 2, 1, 5, 3, 4], "\(harmony) \(hue)")
                for index in around.indices {
                    let next = around[(index + 1) % around.count]
                    XCTAssertGreaterThanOrEqual(ThemeGenerator.wrap(next - around[index]), ThemeGenerator.minimumSeparation - 1e-9,
                                                "\(harmony) \(hue)")
                }
                if harmony == .classic { XCTAssertEqual(hues, ThemeGenerator.anchors) }
            }
        }
        // A gray seed has no hue to lean toward.
        let gray = ThemeRecipe(seed: ThemeColor(r: 0x80, g: 0x80, b: 0x80), harmony: .square)
        XCTAssertEqual(ThemeGenerator.hues(for: gray), ThemeGenerator.anchors)
        // An analogous seed turns its neighbors (blue, cyan) toward it.
        let seed = ThemeRecipe(seed: ThemeColor(oklch: OKLCH(l: 0.6, c: 0.18, h: 230)), harmony: .analogous)
        let hues = ThemeGenerator.hues(for: seed), seedHue = seed.seed.oklch.h
        for index in [3, 5] {
            XCTAssertLessThan(abs(ThemeGenerator.turn(from: hues[index], to: seedHue)),
                              abs(ThemeGenerator.turn(from: ThemeGenerator.anchors[index], to: seedHue)))
        }
    }

    func testRecipesAreDeterministicAndTravelWithTheTheme() throws {
        for seed: UInt64 in [0, 1, 42, .max] {
            XCTAssertEqual(ThemeRecipe.random(seed: seed), ThemeRecipe.random(seed: seed))
            let recipe = ThemeRecipe.random(seed: seed)
            XCTAssertEqual(ThemeGenerator.make(recipe), ThemeGenerator.make(recipe))
            for knob in [recipe.vibrancy, recipe.contrast, recipe.tint] { XCTAssertTrue((0...1).contains(knob)) }
        }
        XCTAssertGreaterThan(Set((0..<32).map { ThemeRecipe.random(seed: UInt64($0)).seed }).count, 28)
        XCTAssertTrue((0..<32).contains { ThemeRecipe.random(seed: UInt64($0)).light })
        XCTAssertTrue((0..<32).contains { !ThemeRecipe.random(seed: UInt64($0)).light })

        // Saved as a file and read back, a made theme still names its recipe.
        let recipe = ThemeRecipe.presets[1].recipe
        let theme = ThemeGenerator.make(recipe)
        let reread = try XCTUnwrap(TerminalTheme(text: theme.text))
        XCTAssertEqual(ThemeRecipe(theme: reread), recipe)
        XCTAssertEqual(reread.palette, theme.palette)
        XCTAssertNil(ThemeRecipe(theme: TerminalTheme()))
        let json = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(ThemeRecipe.self, from: json), recipe)

        XCTAssertEqual(Set(ThemeRecipe.presets.map(\.name)).count, ThemeRecipe.presets.count)
        XCTAssertTrue(ThemeRecipe.presets.contains { $0.recipe.light } && ThemeRecipe.presets.contains { !$0.recipe.light })
        XCTAssertEqual(ThemeGenerator.suggestedName(for: ThemeRecipe(seed: ThemeColor(r: 0x80, g: 0x80, b: 0x80))), "Graphite")
        XCTAssertEqual(ThemeGenerator.suggestedName(for: ThemeRecipe(seed: ThemeColor(r: 0x80, g: 0x80, b: 0x80), light: true)), "Paper")
        XCTAssertEqual(ThemeGenerator.suggestedName(for: ThemeRecipe.presets[0].recipe), "Dusk")
    }

    /// The recipes the colorblind checks run over: every preset and a spread of random ones, dark and light, at the
    /// knobs' ends and middle.
    private func colorblindRecipes(_ vision: ColorVision) -> [ThemeRecipe] {
        var recipes: [ThemeRecipe] = []
        for base in ThemeRecipe.presets.map(\.recipe) + (0..<24).map({ ThemeRecipe.random(seed: UInt64($0)) }) {
            for light in [false, true] {
                for knob in [0.0, 0.5, 1.0] {
                    var recipe = base.with(vision: vision)
                    recipe.light = light
                    (recipe.vibrancy, recipe.contrast) = (knob, 1 - knob)
                    recipes.append(recipe)
                }
            }
        }
        return recipes
    }

    /// Colorblind recipes keep every pair of accents (and of brights) plainly apart as their viewers see them, where the
    /// usual recipes can make two accents look the same; their hues are fixed, whatever the harmony.
    func testColorblindSchemesKeepAccentsApartForTheirViewers() {
        for vision in [ColorVision.redGreen, .blueYellow] {
            var usual = Double.infinity
            for recipe in colorblindRecipes(vision) {
                XCTAssertEqual(ThemeGenerator.hues(for: recipe), ThemeGenerator.anchors(for: vision), recipe.line)
                let palette = ThemeGenerator.make(recipe).palette.compactMap { $0 }
                let typical = ThemeGenerator.make(recipe.with(vision: .typical)).palette.compactMap { $0 }
                for first in 1...6 {
                    for second in (first + 1)..<7 {
                        for offset in [0, 8] {
                            XCTAssertGreaterThanOrEqual(vision.distance(palette[first + offset], palette[second + offset]),
                                                        ThemeGenerator.distinctFloor - 1e-9, "\(first + offset)/\(second + offset) \(recipe.line)")
                        }
                        usual = min(usual, vision.distance(typical[first], typical[second]))
                    }
                }
            }
            XCTAssertLessThan(usual, ThemeGenerator.distinctFloor / 2, "\(vision): the usual accents can look alike")
        }
        XCTAssertEqual(ThemeGenerator.anchors(for: .typical), ThemeGenerator.anchors)
        // Simulation: grays stay gray, and red and green collapse for red-green viewers but not for blue-yellow ones.
        let gray = ThemeColor(r: 0x80, g: 0x80, b: 0x80)
        for deficiency in ColorVision.Deficiency.allCases { XCTAssertLessThan(gray.simulated(deficiency).distance(to: gray), 0.01) }
        let red = ThemeColor(r: 0xCC, g: 0x44, b: 0x44), green = ThemeColor(r: 0x44, g: 0x99, b: 0x44)
        XCTAssertLessThan(ColorVision.redGreen.distance(red, green), ColorVision.blueYellow.distance(red, green) / 2)
    }

    func testColorVisionTravelsWithTheRecipe() throws {
        let recipe = ThemeRecipe.presets[0].recipe.with(vision: .redGreen)
        let reread = try XCTUnwrap(TerminalTheme(text: ThemeGenerator.make(recipe).text))
        XCTAssertEqual(ThemeRecipe(theme: reread)?.vision, .redGreen)
        // A typical recipe is written as before, and recipes saved before colorblind schemes read as typical.
        XCTAssertFalse(ThemeRecipe.presets[0].recipe.line.contains("vision"))
        let old = ##"{"contrast":0.5,"harmony":"analogous","light":false,"seed":"#8b6cf0","tint":0.6,"vibrancy":0.55}"##
        XCTAssertEqual(try JSONDecoder().decode(ThemeRecipe.self, from: Data(old.utf8)).vision, .typical)
    }

    /// Names say what a scheme looks like, and a name already used moves on to another word, not a number.
    func testSuggestedNamesDescribeTheSchemeAndAvoidTakenOnes() {
        let names = (0..<64).map { ThemeGenerator.suggestedName(for: ThemeRecipe.random(seed: UInt64($0))) }
        XCTAssertGreaterThan(Set(names).count, 30, "\(names)")
        // Saved one after another, no two share a name, and few need a number.
        var taken: Set<String> = []
        for seed: UInt64 in 0..<64 { taken.insert(ThemeGenerator.suggestedName(for: ThemeRecipe.random(seed: seed), taken: taken)) }
        XCTAssertEqual(taken.count, 64)
        XCTAssertLessThan(taken.filter { $0.last?.isNumber == true }.count, 4, "\(taken.sorted())")
        let dusk = ThemeRecipe.presets[0].recipe
        XCTAssertEqual(ThemeGenerator.suggestedName(for: dusk), "Dusk")
        XCTAssertEqual(ThemeGenerator.suggestedName(for: dusk, taken: ["Dusk"]), "Twilight")
        XCTAssertEqual(ThemeGenerator.suggestedName(for: dusk, taken: ["Dusk", "Twilight", "Violet"]), "Dusk 2")
        var vivid = dusk
        vivid.vibrancy = 1
        XCTAssertEqual(ThemeGenerator.suggestedName(for: vivid), "Vivid Dusk")
        var soft = dusk
        (soft.contrast, soft.light) = (0.1, true)
        XCTAssertEqual(ThemeGenerator.suggestedName(for: soft), "Soft Lilac")
    }
}
