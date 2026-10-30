import XCTest
import Term
import TermApple
@testable import DispatchApp

/// The user's own color schemes: Ghostty theme files Dispatch reads, writes, resolves for the terminal, and exports.
@MainActor
final class CustomThemeTests: XCTestCase {
    override func setUp() async throws {
        try? FileManager.default.removeItem(at: CustomThemes.directory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: CustomThemes.directory)
    }

    private func sample() -> TerminalTheme {
        var theme = TerminalTheme()
        theme.background = ThemeColor(hex: "#1b1d2a")!
        theme.foreground = ThemeColor(hex: "#d8dbe9")!
        theme.cursor = ThemeColor(hex: "#f2c46d")
        theme.palette[1] = ThemeColor(hex: "#e5717c")
        theme.palette[2] = ThemeColor(hex: "#8fcf8a")
        return theme
    }

    func testDisplayP3ColorsKeepAnSRGBStandInAndRoundTrip() throws {
        // Display P3's pure red is outside sRGB: it keeps its P3 bytes and stands in as a less saturated sRGB red.
        let red = ThemeColor(displayP3Red: 1, green: 0, blue: 0)
        let wide = try XCTUnwrap(red.displayP3)
        XCTAssertEqual(wide.hex, "#ff0000")
        XCTAssertGreaterThan(red.r, 0xE0)
        XCTAssertGreaterThan(red.g, 0, "the stand-in reduces chroma rather than clipping")
        let gray = ThemeColor(displayP3Red: 0x60 / 255, green: 0x60 / 255, blue: 0x60 / 255)
        XCTAssertNil(gray.displayP3, "a color inside sRGB is plain sRGB")
        XCTAssertEqual(gray.hex, "#606060", "P3 and sRGB grays are the same")

        var theme = sample()
        theme.palette[1] = red
        let text = theme.text
        XCTAssertTrue(text.contains("palette = 1=\(red.hex)\n# display-p3: palette = 1=#ff0000\n"), "the P3 line follows its sRGB one")
        let back = try XCTUnwrap(TerminalTheme(text: text))
        XCTAssertEqual(back, theme)
        XCTAssertEqual(back.extra, [], "the P3 line is read, not kept as an unknown line")

        // A recipe's seed keeps its P3 color too.
        let recipe = ThemeRecipe(seed: red)
        XCTAssertEqual(try JSONDecoder().decode(ThemeRecipe.self, from: JSONEncoder().encode(recipe)).seed, red)

        // The terminal's config: the P3 color for the sRGB one its line set; Ghostty reads only the sRGB line.
        var config = Config()
        config.load(Array(text.utf8))
        XCTAssertEqual(config.palette[1], RGB(r: red.r, g: red.g, b: red.b))
        XCTAssertEqual(config.displayP3, [RGB(r: red.r, g: red.g, b: red.b).packed: RGB(r: 0xFF, g: 0, b: 0)])
        var plain = Config()
        plain.load(Array(sample().text.utf8))
        XCTAssertEqual(plain.displayP3, [:], "an sRGB theme draws as before")
        // Everything else reaches the renderer converted to P3: grays unchanged, sRGB red inside P3's red.
        XCTAssertEqual(WideColors.displayP3(RGB(r: 0x80, g: 0x80, b: 0x80)), RGB(r: 0x80, g: 0x80, b: 0x80))
        let srgbRed = WideColors.displayP3(RGB(r: 0xFF, g: 0, b: 0))
        XCTAssertLessThan(srgbRed.r, 0xFF)
        XCTAssertGreaterThan(srgbRed.g, 0)
        XCTAssertEqual(WideColors(config.displayP3).map(RGB(r: red.r, g: red.g, b: red.b)), RGB(r: 0xFF, g: 0, b: 0))
    }

    func testFontFeaturesFollowGhosttysSyntax() {
        var config = Config()
        config.load(Array("font-feature = -calt, -liga, -dlig\nfont-feature = ss01\nfont-feature = \"cv02\" 3\nfont-feature = zero off".utf8))
        XCTAssertEqual(config.fontFeatures, [FontFeature("calt", 0), FontFeature("liga", 0), FontFeature("dlig", 0),
                                             FontFeature("ss01", 1), FontFeature("cv02", 3), FontFeature("zero", 0)])
        XCTAssertTrue(config.diagnostics.isEmpty)
        config.load(Array("font-feature = toolong".utf8))
        XCTAssertEqual(config.diagnostics.map(\.key), ["font-feature"])
        config.load(Array("font-feature =".utf8))
        XCTAssertEqual(config.fontFeatures, [], "empty restores the default")
    }

    func testThemeTextRoundTripsAndKeepsWhatItDoesntModel() throws {
        let text = """
        # A fictional scheme
        palette = 0=#101010
        palette = 200=#abcdef
        background = 1b1d2a
        foreground = #ddd
        selection-background = #333344
        font-thicken = true
        """
        let theme = try XCTUnwrap(TerminalTheme(text: text))
        XCTAssertEqual(theme.background.hex, "#1b1d2a")
        XCTAssertEqual(theme.foreground.hex, "#dddddd", "three-digit colors")
        XCTAssertEqual(theme.palette[0]?.hex, "#101010")
        XCTAssertEqual(theme.selectionBackground?.hex, "#333344")
        XCTAssertEqual(theme.extra, ["# A fictional scheme", "palette = 200=#abcdef", "font-thicken = true"])
        XCTAssertEqual(TerminalTheme(text: theme.text), theme)
        XCTAssertEqual(theme.isLight, false)
        XCTAssertNil(TerminalTheme(text: "font-size = 13"), "no colors: not a scheme")
    }

    func testSavedThemesListByNameAndResolveToTheirFile() throws {
        XCTAssertTrue(CustomThemes.list().isEmpty)
        let url = try CustomThemes.save(sample(), named: "Harbor Night")
        XCTAssertEqual(CustomThemes.list().map(\.name), ["Harbor Night"])
        XCTAssertEqual(CustomThemes.list().first?.light, false)
        XCTAssertEqual(CustomThemes.theme(named: "Harbor Night"), sample())
        XCTAssertEqual(ThemeResolution.value(for: "Harbor Night").value, url.path, "the terminal gets the file's path")
        XCTAssertEqual(CustomThemes.uniqueName("Harbor Night"), "Harbor Night 2")
        XCTAssertEqual(CustomThemes.sanitized(" ../Night/Shift "), "-Night-Shift")
        XCTAssertThrowsError(try CustomThemes.save(sample(), named: ".hidden"))
        try CustomThemes.delete(named: "Harbor Night")
        XCTAssertTrue(CustomThemes.list().isEmpty)
    }

    /// Colorblind schemes are listed only in their colorblind mode, the user's own included by the vision their recipe
    /// names; every scheme a mode lists exists, and old settings files read as typical vision.
    func testColorblindModesListOnlyTheirSchemes() throws {
        try CustomThemes.save(sample(), named: "Harbor Night")
        try CustomThemes.save(ThemeGenerator.make(ThemeRecipe.standard.with(vision: .redGreen)), named: "Dusk Colorblind")
        let directory = System.resources.appendingPathComponent("ghostty/themes")
        let all = ColorSchemes(directory: directory)
        let colorblind = Set(ColorSchemes.colorblind.values.flatMap { $0.light + $0.dark })
        let typical = all.filtered(for: .typical)
        XCTAssertTrue(colorblind.isDisjoint(with: typical.light + typical.dark + typical.either))
        XCTAssertFalse(typical.light.isEmpty || typical.dark.isEmpty)
        XCTAssertEqual(typical.custom.map(\.name), ["Harbor Night"])
        for vision in [ColorVision.redGreen, .blueYellow] {
            let own = try XCTUnwrap(ColorSchemes.colorblind[vision])
            let listed = all.filtered(for: vision)
            XCTAssertEqual(listed.light, own.light.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "\(vision)")
            XCTAssertEqual(listed.dark, own.dark.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "\(vision)")
            XCTAssertTrue(listed.either.isEmpty)
            XCTAssertEqual(listed.custom.map(\.name), vision == .redGreen ? ["Dusk Colorblind"] : [], "\(vision)")
            for name in own.light + own.dark {
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path), name)
                XCTAssertEqual(ColorSchemes.vision(of: name), vision, name)
            }
        }
        XCTAssertEqual(ColorSchemes.vision(of: "Dusk Colorblind"), .redGreen)
        XCTAssertEqual(ColorSchemes.vision(of: "Default"), .typical)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).colorVision, .typical)
        var preferences = Preferences()
        preferences.colorVision = .blueYellow
        let saved = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(saved.colorVision, .blueYellow)
    }

    /// Surprise me keeps one surprise per side among the user's schemes, for the vision asked: the other side's, which
    /// may be in use, stays; a kept one stays when the next comes.
    func testSurprisesReplaceEachOtherUntilKept() throws {
        let first = try SurpriseScheme.make(light: false, vision: .typical, seed: 1)
        XCTAssertTrue(SurpriseScheme.isSurprise(first))
        XCTAssertEqual(CustomThemes.theme(named: first)?.isLight, false)
        for seed: UInt64 in 2...20 { _ = try SurpriseScheme.make(light: true, vision: .redGreen, seed: seed) }
        let surprises = CustomThemes.list().filter { SurpriseScheme.isSurprise($0.name) }
        XCTAssertEqual(surprises.count, 2, "\(CustomThemes.list().map(\.name))")
        XCTAssertTrue(surprises.contains { $0.name == first }, "the dark surprise outlives the light ones")
        let last = try XCTUnwrap(surprises.first { $0.name != first }).name
        XCTAssertEqual(CustomThemes.theme(named: last)?.isLight, true)
        XCTAssertEqual(ColorSchemes.vision(of: last), .redGreen)
        try SurpriseScheme.keep(last)
        XCTAssertFalse(SurpriseScheme.isSurprise(last))
        let next = try SurpriseScheme.make(light: true, vision: .typical, seed: 99)
        XCTAssertEqual(Set(CustomThemes.list().map(\.name)), [first, last, next])
        XCTAssertNotEqual(last, next)
    }

    func testAMissingSchemeFallsBackInsteadOfFailingTheTerminal() {
        XCTAssertEqual(ThemeResolution.value(for: "dispatch-black").missing, false)
        let missing = ThemeResolution.value(for: "A Scheme That Was Deleted")
        XCTAssertEqual(missing.value, "dispatch-black")
        XCTAssertTrue(missing.missing)
        XCTAssertTrue(ThemeResolution.value(for: "../etc/passwd").missing, "never a path out of the folders")
    }

    func testExportWritesAGhosttyConfigThemesAndSettingsThatRestore() throws {
        try CustomThemes.save(sample(), named: "Harbor Night")
        var preferences = Preferences()
        preferences.fontFamily = "Menlo"
        preferences.fontSize = 13.5
        preferences.theme = "Harbor Night"
        preferences.lightTheme = "Default"
        preferences.cursor = .bar
        preferences.cursorBlink = false
        preferences.optionAsAlt = .left
        preferences.scrollback = .unlimited
        let config = SettingsExport.ghosttyConfig(preferences)
        for line in ["font-family = Menlo", "font-size = 13.5", "theme = light:dispatch-black,dark:Harbor Night", "cursor-style = bar",
                     "cursor-style-blink = false", "macos-option-as-alt = left", "scrollback-limit-bytes = unlimited", "working-directory = home"] {
            XCTAssertTrue(config.contains(line + "\n"), "\(line) in:\n\(config)")
        }
        let folder = System.home.appendingPathComponent("Exported Settings", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(try SettingsExport.write(preferences, to: folder), ["dispatch-black", "Harbor Night"])
        XCTAssertNotNil(ColorSchemeGallery.theme(from: folder.appendingPathComponent("themes/Harbor Night")))

        try CustomThemes.delete(named: "Harbor Night")
        let plan = try SettingsExport.plan(from: folder)
        XCTAssertEqual(plan.themes.map(\.name), ["Harbor Night"], "Dispatch's own scheme is bundled, not imported")
        XCTAssertTrue(plan.themes.allSatisfy(\.keepsName))
        var restored = Preferences()
        plan.changes.forEach { $0.apply(&restored) }
        XCTAssertEqual(restored, preferences)
    }
}

/// Duplicate and Edit: the editor's slots fall back to what the terminal draws, and what it saves no longer carries a
/// recipe or a surprise mark but keeps the colorblind mode it was edited in, so Settings lists it there.
extension CustomThemeTests {
    func testEditedSchemesDropTheirRecipeAndKeepTheirColorblindMode() throws {
        var theme = sample()
        XCTAssertEqual(theme[.cursorText], theme.background, "an unset cursor text is the background, as in Ghostty")
        XCTAssertEqual(theme[.selection], theme.foreground)
        XCTAssertEqual(theme[.ansi(4)], SchemeDemo.standard[4], "an unset ANSI color is xterm's")
        theme[.ansi(4)] = try XCTUnwrap(ThemeColor(hex: "#6c8cf0"))
        XCTAssertEqual(theme.palette[4]?.hex, "#6c8cf0")

        var made = ThemeGenerator.make(ThemeRecipe.standard.with(vision: .redGreen))
        made.extra.append(SurpriseScheme.marker)
        XCTAssertNotNil(ThemeRecipe(theme: made))
        let saved = ThemeEditorView.saved(made, vision: .redGreen)
        XCTAssertNil(ThemeRecipe(theme: saved), "hand-edited colors leave the maker")
        XCTAssertFalse(saved.extra.contains(SurpriseScheme.marker), "an edited surprise is kept")
        XCTAssertEqual(ThemeEditorView.vision(in: saved), .redGreen)
        try CustomThemes.save(saved, named: "Edited")
        XCTAssertEqual(ColorSchemes.vision(of: "Edited"), .redGreen, "listed in the colorblind mode it was edited in")
        XCTAssertEqual(ThemeEditorView.vision(in: ThemeEditorView.saved(saved, vision: .typical)), nil)
        try CustomThemes.save(ThemeEditorView.saved(sample(), vision: .typical), named: "Plain")
        XCTAssertEqual(ColorSchemes.vision(of: "Plain"), .typical)
    }
}
