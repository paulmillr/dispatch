import XCTest
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
        try CustomThemes.save(ThemeGenerator.make(ThemeRecipe.presets[0].recipe.with(vision: .redGreen)), named: "Dusk Colorblind")
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

    /// Surprise me keeps one surprise among the user's schemes, on the side and for the vision asked; a kept one stays
    /// when the next comes.
    func testSurprisesReplaceEachOtherUntilKept() throws {
        let first = try SurpriseScheme.make(light: false, vision: .typical, seed: 1)
        XCTAssertTrue(SurpriseScheme.isSurprise(first))
        XCTAssertEqual(CustomThemes.theme(named: first)?.isLight, false)
        for seed: UInt64 in 2...20 { _ = try SurpriseScheme.make(light: true, vision: .redGreen, seed: seed) }
        let surprises = CustomThemes.list().filter { SurpriseScheme.isSurprise($0.name) }
        XCTAssertEqual(surprises.count, 1, "\(CustomThemes.list().map(\.name))")
        let last = try XCTUnwrap(surprises.first).name
        XCTAssertEqual(CustomThemes.theme(named: last)?.isLight, true)
        XCTAssertEqual(ColorSchemes.vision(of: last), .redGreen)
        try SurpriseScheme.keep(last)
        XCTAssertFalse(SurpriseScheme.isSurprise(last))
        let next = try SurpriseScheme.make(light: true, vision: .typical, seed: 99)
        XCTAssertEqual(Set(CustomThemes.list().map(\.name)), [last, next])
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
        XCTAssertNotNil(YourColorSchemes.theme(from: folder.appendingPathComponent("themes/Harbor Night")))

        try CustomThemes.delete(named: "Harbor Night")
        let plan = try SettingsExport.plan(from: folder)
        XCTAssertEqual(plan.themes.map(\.name), ["Harbor Night"], "Dispatch's own scheme is bundled, not imported")
        XCTAssertTrue(plan.themes.allSatisfy(\.keepsName))
        var restored = Preferences()
        plan.changes.forEach { $0.apply(&restored) }
        XCTAssertEqual(restored, preferences)
    }
}
