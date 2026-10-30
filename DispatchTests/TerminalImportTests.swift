import AppKit
import XCTest
@testable import DispatchApp

/// Ghostty's, iTerm2's and Terminal's settings read into an ImportPlan, from fictional fixtures: config text, and
/// preference dictionaries as each app saves them.
@MainActor final class TerminalImportTests: XCTestCase {
    private let fonts = ["Example Mono", "Menlo", "Source Code Pro"]

    private func applied(_ plan: ImportPlan) -> Preferences {
        var preferences = Preferences()
        for change in plan.changes { change.apply(&preferences) }
        return preferences
    }

    private func folder() throws -> URL {
        let url = System.temporary.appendingPathComponent("import-" + System.uuid().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Ghostty

    func testGhosttyMapsTheSettingsDispatchHas() throws {
        let start = try folder()
        let text = """
        # a comment
        font-family = "example mono"
        font-family = Fallback Sans
        font-size = 14.5
        cursor-style = block_hollow
        cursor-style-blink = false
        macos-option-as-alt = left
        scrollback-limit = 2000000000
        command = direct:/bin/zsh -l
        working-directory = \(start.path)
        minimum-contrast = 3
        clipboard-write = deny
        image-storage-limit = 0
        """
        let plan = GhosttyImport.plan(text: text, fonts: fonts, theme: { _ in nil })
        let result = applied(plan)
        XCTAssertEqual(plan.source, "Ghostty")
        XCTAssertEqual(result.fontFamily, "Example Mono", "the first family, as the font list spells it")
        XCTAssertEqual(result.fontSize, 14.5)
        XCTAssertEqual(result.cursor, .block, "a hollow block is a block")
        XCTAssertFalse(result.cursorBlink)
        XCTAssertEqual(result.optionAsAlt, .left)
        XCTAssertEqual(result.scrollback, .large)
        XCTAssertEqual(result.shell, "/bin/zsh -l")
        XCTAssertEqual(result.startingDirectory, start.standardizedFileURL.path)
        XCTAssertTrue(result.improveTextContrast)
        XCTAssertFalse(result.allowClipboardWrites)
        XCTAssertFalse(result.enableKittyGraphics)
        XCTAssertEqual(plan.changes.first { $0.setting == "Font size" }?.value, "14.5 pt")
        XCTAssertTrue(plan.themes.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty, "\(plan.skipped)")
    }

    func testGhosttyValuesMapToTheNearestChoices() {
        func plan(_ text: String) -> Preferences { applied(GhosttyImport.plan(text: text, fonts: fonts, theme: { _ in nil })) }
        XCTAssertEqual(plan("scrollback-limit = 10000000").scrollback, .small)
        XCTAssertEqual(plan("scrollback-limit-bytes = 100000000").scrollback, .automatic)
        XCTAssertEqual(plan("scrollback-limit-bytes = unlimited").scrollback, .unlimited)
        XCTAssertEqual(plan("scrollback-limit-lines = 5000").scrollback, .small)
        XCTAssertEqual(plan("macos-option-as-alt = true").optionAsAlt, .both)
        XCTAssertEqual(plan("macos-option-as-alt = false").optionAsAlt, .off)
        XCTAssertEqual(plan("cursor-style = bar\ncursor-style-blink = true").cursor, .bar)
        XCTAssertEqual(plan("working-directory = home").startingDirectory, System.home.path)
        XCTAssertFalse(plan("minimum-contrast = 1").improveTextContrast)
        XCTAssertTrue(plan("clipboard-write = ask").allowClipboardWrites)
        let later = GhosttyImport.plan(text: "font-size = 20\ncursor-style = bar\ncursor-style =\nfont-size = 11", fonts: fonts, theme: { _ in nil })
        XCTAssertEqual(later.changes.map(\.setting), ["Font size"], "the last value wins; an empty one is Ghostty's default")
        XCTAssertEqual(applied(later).fontSize, 11)
        XCTAssertTrue(GhosttyImport.plan(text: "image-storage-limit = 1000", fonts: fonts).changes.isEmpty, "Kitty graphics stay opt-in")
    }

    func testGhosttySkipsWhatDispatchCannotTake() {
        let text = """
        font-family = Not Installed Mono
        font-size = 48
        command = fish
        working-directory = /nonexistent/example
        theme = Missing Theme
        background-blur = 20
        window-padding-x = 4
        window-theme = dark
        window-height = 40
        window-width = 120
        keybind = super+t=new_tab
        keybind = super+w=close_surface
        copy-on-select = clipboard
        font-feature = -calt
        adjust-cell-width = 10%
        adjust-cell-height = 2
        shell-integration = zsh
        some-future-key = 1
        """
        let plan = GhosttyImport.plan(text: text, fonts: fonts, theme: { _ in nil })
        XCTAssertTrue(plan.changes.isEmpty, "\(plan.changes.map(\.setting))")
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.skipped, [
            "font-family Not Installed Mono (not a monospaced font on this Mac)",
            "font-size 48 pt (Dispatch takes 8–32 pt)",
            "theme Missing Theme (not found)",
            "adjust-cell-height 2 (Dispatch takes a percentage)",
            "command (not a program by its full path)",
            "working-directory (folder not found)",
            "background-blur (terminal opacity only)",
            "window-padding-x, window-theme, window-height and 1 more (Dispatch arranges its own windows)",
            "keybind (Dispatch keeps its own shortcuts)",
            "font-feature (font styles and features)",
            "adjust-cell-width (no cell adjustments)",
            "copy-on-select (mouse behavior)",
            "shell-integration (Dispatch's own shell integration)",
        ])
    }

    private var catppuccin: TerminalTheme {
        TerminalTheme(text: "background = #1e1e2e\nforeground = #cdd6f4\npalette = 1=#f38ba8\ncursor-color = #f5e0dc\n")!
    }
    private var latte: TerminalTheme { TerminalTheme(text: "background = #eff1f5\nforeground = #4c4f69\n")! }
    private func lookup(_ name: String) -> TerminalTheme? {
        switch name {
        case "Example Night", "/themes/Example Night": catppuccin
        case "Example Day": latte
        default: nil
        }
    }

    /// Ghostty's adjust-cell-height as a percentage is the nearest line spacing; export writes it back.
    func testGhosttyCellHeightIsLineSpacing() {
        for (text, expected) in [("20%", LineSpacing.relaxed), ("-5%", .tight), ("2%", .normal), ("-50%", .tight)] {
            let plan = GhosttyImport.plan(text: "adjust-cell-height = \(text)", fonts: fonts, theme: { _ in nil })
            XCTAssertEqual(plan.changes.map(\.setting), ["Line spacing"], text)
            XCTAssertEqual(applied(plan).lineSpacing, expected, text)
        }
        XCTAssertEqual(LineSpacing.tight.cellHeight, "-6%")
        XCTAssertEqual(LineSpacing.relaxed.cellHeight, "18%")
        XCTAssertNil(LineSpacing.normal.cellHeight, "Normal is the font's own line")
        // Saved with the other settings; older files and unknown values read as Normal.
        var chosen = Preferences()
        chosen.lineSpacing = .tight
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen)).lineSpacing, .tight)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).lineSpacing, .normal)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(#"{"lineSpacing":"airy"}"#.utf8)).lineSpacing, .normal)
    }

    /// Ghostty's background-opacity is Terminal opacity, within what Settings offers.
    func testGhosttyBackgroundOpacityIsTerminalOpacity() {
        for (text, expected) in [("0.85", 0.85), ("0.3", 0.6), ("1", 1.0), ("2", 1.0)] {
            let plan = GhosttyImport.plan(text: "background-opacity = \(text)", fonts: fonts, theme: { _ in nil })
            XCTAssertEqual(applied(plan).terminalOpacity, expected, accuracy: 1e-9, text)
            XCTAssertTrue(plan.skipped.isEmpty, "\(plan.skipped)")
        }
    }

    func testGhosttyCopiesANamedThemeForBothSchemes() {
        let plan = GhosttyImport.plan(text: "theme = Example Night", fonts: fonts, theme: lookup)
        XCTAssertEqual(plan.themes.map(\.name), ["Example Night"])
        XCTAssertEqual(plan.themes.first?.theme, catppuccin)
        XCTAssertEqual(plan.themes.first?.role, .both)
        XCTAssertFalse(plan.isEmpty)
        let path = GhosttyImport.plan(text: "theme = /themes/Example Night", fonts: fonts, theme: lookup)
        XCTAssertEqual(path.themes.map(\.name), ["Example Night"], "a theme by its path keeps its file's name")
    }

    func testGhosttyColorsInTheConfigBuildOnTheNamedTheme() throws {
        let text = """
        background = #101010
        theme = Example Night
        palette = 2=#00ff00
        palette = 1=
        selection-background = 334455
        cursor-color = cell-foreground
        """
        let plan = GhosttyImport.plan(text: text, fonts: fonts, theme: lookup)
        XCTAssertEqual(plan.themes.map(\.name), ["Example Night", "Ghostty"])
        XCTAssertEqual(plan.themes.map(\.role), [.none, .both], "the config's own colors are the scheme, the copy is kept")
        let ghostty = try XCTUnwrap(plan.themes.last?.theme)
        XCTAssertEqual(ghostty.background, ThemeColor(hex: "#101010"), "the config's lines replay over the theme")
        XCTAssertEqual(ghostty.foreground, catppuccin.foreground)
        XCTAssertEqual(ghostty.palette[2], ThemeColor(hex: "#00ff00"))
        XCTAssertEqual(ghostty.palette[1], catppuccin.palette[1], "an invalid entry keeps the theme's color")
        XCTAssertEqual(ghostty.selectionBackground, ThemeColor(hex: "#334455"))
        XCTAssertEqual(ghostty.cursor, catppuccin.cursor, "cell-foreground can't be a theme color; the theme's stays")

        let alone = GhosttyImport.plan(text: "background = #202020\nforeground = #e0e0e0", fonts: fonts, theme: lookup)
        XCTAssertEqual(alone.themes.map(\.name), ["Ghostty"])
        XCTAssertEqual(alone.themes.first?.theme.background, ThemeColor(hex: "#202020"))
        XCTAssertEqual(alone.themes.first?.theme.palette, TerminalTheme().palette, "Ghostty's standard colors under its own")
    }

    func testGhosttyLightAndDarkPairs() throws {
        let pair = GhosttyImport.plan(text: "theme = light:Example Day,dark:\"Example Night\"", fonts: fonts, theme: lookup)
        XCTAssertEqual(pair.themes.map(\.name), ["Example Day", "Example Night"])
        XCTAssertEqual(pair.themes.map(\.role), [.light, .dark])

        let over = GhosttyImport.plan(text: "theme = dark:Example Night,light:Example Day\nforeground = #777777", fonts: fonts, theme: lookup)
        XCTAssertEqual(over.themes.map(\.name), ["Example Day", "Ghostty Light", "Example Night", "Ghostty Dark"])
        XCTAssertEqual(over.themes.map(\.role), [.none, .light, .none, .dark])
        XCTAssertEqual(over.themes[1].theme.background, latte.background)
        XCTAssertEqual(over.themes[3].theme.background, catppuccin.background)
        XCTAssertEqual(over.themes[3].theme.foreground, ThemeColor(hex: "#777777"))

        let same = GhosttyImport.plan(text: "theme = light:Example Day,dark:Example Day", fonts: fonts, theme: lookup)
        XCTAssertEqual(same.themes.map(\.role), [.both])
        let bad = GhosttyImport.plan(text: "theme = light:Example Day", fonts: fonts, theme: lookup)
        XCTAssertEqual(bad.skipped, ["theme (not a theme name or light/dark pair)"])
    }

    func testGhosttyIncludesApplyAfterTheirFile() throws {
        let root = try folder()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parts"), withIntermediateDirectories: true)
        try """
        config-file = parts/look
        config-file = ?parts/optional-missing
        config-file = parts/required-missing
        font-size = 12
        cursor-style = bar
        """.write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try """
        font-size = 16
        config-file = more
        config-file = ../config
        """.write(to: root.appendingPathComponent("parts/look"), atomically: true, encoding: .utf8)
        try "cursor-style = underline\n".write(to: root.appendingPathComponent("parts/more"), atomically: true, encoding: .utf8)
        try "font-size = 18\n".write(to: root.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8)

        let plan = GhosttyImport.plan(files: [root.appendingPathComponent("config")], fonts: fonts, theme: { _ in nil })
        let result = applied(plan)
        XCTAssertEqual(result.fontSize, 16, "an include overrides its file, wherever the line is")
        XCTAssertEqual(result.cursor, .underline, "includes of includes apply last; the cycle back to config is read once")
        XCTAssertEqual(plan.skipped, ["config-file required-missing (not found)"], "an optional include may be missing")

        let both = GhosttyImport.plan(files: [root.appendingPathComponent("config"), root.appendingPathComponent("config.ghostty")],
                                      fonts: fonts, theme: { _ in nil })
        XCTAssertEqual(applied(both).fontSize, 16, "every default file loads before the includes")
        let text = GhosttyImport.plan(text: "config-file = parts/more", directory: root, fonts: fonts, theme: { _ in nil })
        XCTAssertEqual(applied(text).cursor, .underline, "text's includes resolve against its folder")
    }

    func testGhosttyConfigLocations() throws {
        let home = try folder()
        XCTAssertEqual(GhosttyImport.configURLs(home: home, xdg: nil), [])
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        let xdg = home.appendingPathComponent("xdg/ghostty")
        for folder in [support, xdg, home.appendingPathComponent(".config/ghostty")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "font-size = 13\n".write(to: folder.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        }
        try "font-size = 13\n".write(to: support.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GhosttyImport.configURLs(home: home, xdg: nil).map(\.path),
                       [".config/ghostty/config", "Library/Application Support/com.mitchellh.ghostty/config",
                        "Library/Application Support/com.mitchellh.ghostty/config.ghostty"].map { home.appendingPathComponent($0).path })
        XCTAssertEqual(GhosttyImport.configURLs(home: home, xdg: home.appendingPathComponent("xdg").path).first?.path,
                       xdg.appendingPathComponent("config").path, "XDG_CONFIG_HOME replaces ~/.config")
    }

    // MARK: iTerm2

    private func iTermColor(_ r: Double, _ g: Double, _ b: Double, space: String? = "sRGB") -> [String: Any] {
        var color: [String: Any] = ["Red Component": r, "Green Component": g, "Blue Component": b, "Alpha Component": 1]
        if let space { color["Color Space"] = space }
        return color
    }

    private func iTermPreferences(_ profile: [String: Any]) -> [String: Any] {
        let profiles: [[String: Any]] = [["Name": "Spare", "Guid": "A-1"], profile.merging(["Name": "Example Work", "Guid": "B-2"]) { a, _ in a }]
        return ["Default Bookmark Guid": "B-2", "New Bookmarks": profiles]
    }

    func testITermMapsTheDefaultProfile() throws {
        let start = try folder()
        let profile: [String: Any] = [
            "Normal Font": "Menlo-Regular 13.5",
            "Background Color": iTermColor(0.1, 0.1, 0.1), "Foreground Color": iTermColor(0.9, 0.9, 0.9),
            "Cursor Color": iTermColor(1, 0.5, 0), "Cursor Text Color": iTermColor(0, 0, 0),
            "Selection Color": iTermColor(0.2, 0.3, 0.4), "Selected Text Color": iTermColor(1, 1, 1),
            "Ansi 1 Color": iTermColor(0.8, 0, 0), "Ansi 15 Color": iTermColor(1, 1, 1),
            "Cursor Type": 1, "Blinking Cursor": false,
            "Option Key Sends": 2, "Right Option Key Sends": 0,
            "Unlimited Scrollback": false, "Scrollback Lines": 100_000,
            "Custom Command": "Yes", "Command": "/bin/zsh -l",
            "Custom Directory": "Yes", "Working Directory": start.path,
            "Minimum Contrast": 0.3,
            "Transparency": 0.2, "Blur": true, "ASCII Ligatures": true, "Use Non-ASCII Font": true, "Vertical Spacing": 1.2,
            "Use Bold Color": true, "Background Image Location": "/Example/image.png",
        ]
        let preferences = iTermPreferences(profile)
        XCTAssertEqual(ITermImport.profiles(in: preferences).map(\.name), ["Example Work", "Spare"], "the default first")
        XCTAssertEqual(ITermImport.profiles(in: preferences).map(\.isDefault), [true, false])

        let plan = ITermImport.plan(preferences: preferences, fonts: fonts)
        XCTAssertEqual(plan.source, "iTerm2 · Example Work")
        let result = applied(plan)
        XCTAssertEqual(result.terminalOpacity, 0.8, accuracy: 1e-9, "transparency 0.2 is 80% opaque")
        XCTAssertEqual(result.fontFamily, "Menlo")
        XCTAssertEqual(result.fontSize, 13.5)
        XCTAssertEqual(result.cursor, .bar)
        XCTAssertFalse(result.cursorBlink)
        XCTAssertEqual(result.optionAsAlt, .left, "Esc+ on the left, Normal on the right")
        XCTAssertEqual(result.scrollback, .automatic)
        XCTAssertEqual(result.shell, "/bin/zsh -l")
        XCTAssertEqual(result.startingDirectory, start.standardizedFileURL.path)
        XCTAssertTrue(result.improveTextContrast)

        let theme = try XCTUnwrap(plan.themes.first)
        XCTAssertEqual(plan.themes.count, 1)
        XCTAssertEqual(theme.name, "iTerm2 · Example Work")
        XCTAssertEqual(theme.role, .both)
        XCTAssertEqual(theme.theme.background, ThemeColor(red: 0.1, green: 0.1, blue: 0.1))
        XCTAssertEqual(theme.theme.foreground, ThemeColor(red: 0.9, green: 0.9, blue: 0.9))
        XCTAssertEqual(theme.theme.cursor, ThemeColor(r: 255, g: 128, b: 0))
        XCTAssertEqual(theme.theme.cursorText, ThemeColor(r: 0, g: 0, b: 0))
        XCTAssertEqual(theme.theme.selectionBackground, ThemeColor(red: 0.2, green: 0.3, blue: 0.4))
        XCTAssertEqual(theme.theme.selectionForeground, ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(theme.theme.palette[1], ThemeColor(red: 0.8, green: 0, blue: 0))
        XCTAssertEqual(theme.theme.palette[15], ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertNil(theme.theme.palette[0], "a color the profile lacks stays the standard one")
        XCTAssertEqual(plan.skipped, [
            "Blur (terminal opacity only)", "Background image (no background images)",
            "Bold color (bold text keeps its color)", "Ligatures (not drawn)", "Non-ASCII font (one font for all text)",
            "Line and character spacing (not adjustable)",
        ])

        let spare = ITermImport.plan(preferences: preferences, profile: "A-1", fonts: fonts)
        XCTAssertEqual(spare.source, "iTerm2 · Spare")
        XCTAssertTrue(spare.isEmpty)
    }

    func testITermOtherProfileChoices() {
        func plan(_ profile: [String: Any]) -> ImportPlan { ITermImport.plan(preferences: iTermPreferences(profile), fonts: fonts) }
        XCTAssertEqual(applied(plan(["Cursor Type": 0])).cursor, .underline)
        XCTAssertEqual(applied(plan(["Cursor Type": 2])).cursor, .block)
        XCTAssertEqual(applied(plan(["Option Key Sends": 1, "Right Option Key Sends": 1])).optionAsAlt, .both)
        XCTAssertEqual(applied(plan(["Option Key Sends": 0, "Right Option Key Sends": 2])).optionAsAlt, .right)
        XCTAssertEqual(applied(plan(["Option Key Sends": 0, "Right Option Key Sends": 0])).optionAsAlt, .off)
        XCTAssertEqual(applied(plan(["Unlimited Scrollback": true, "Scrollback Lines": 1000])).scrollback, .unlimited)
        XCTAssertEqual(applied(plan(["Scrollback Lines": 1000])).scrollback, .small)
        XCTAssertEqual(applied(plan(["Custom Command": "No"])).shell, "")
        XCTAssertEqual(applied(plan(["Custom Command": "Custom Shell", "Custom Shell": "/bin/bash"])).shell, "/bin/bash")
        XCTAssertEqual(plan(["Custom Command": "Yes", "Command": "ssh example.invalid"]).skipped, ["Command (not a program by its full path)"])
        XCTAssertEqual(applied(plan(["Custom Directory": "No"])).startingDirectory, System.home.path)
        XCTAssertEqual(plan(["Custom Directory": "Recycle"]).changes.count, 0)
        XCTAssertFalse(applied(plan(["Minimum Contrast": 0])).improveTextContrast)
        let unknown = plan(["Normal Font": "ExampleMono-Regular 13"])
        XCTAssertEqual(unknown.skipped, ["Font ExampleMono-Regular (not installed)"])
        XCTAssertEqual(unknown.changes.map(\.setting), ["Font size"], "the size still comes along")
        let proportional = plan(["Normal Font": "Helvetica 13"])
        XCTAssertEqual(proportional.skipped, ["Font Helvetica (not a monospaced font on this Mac)"])
    }

    func testITermColorSpacesAndSeparateLightAndDarkColors() throws {
        XCTAssertEqual(ITermImport.color(iTermColor(1, 0, 0, space: "P3")), ThemeColor(displayP3Red: 1, green: 0, blue: 0), "P3's red stays P3")
        let calibrated = try XCTUnwrap(NSColor(calibratedRed: 0.5, green: 0.25, blue: 0.75, alpha: 1).usingColorSpace(.sRGB))
        let expected = ThemeColor(red: Double(calibrated.redComponent), green: Double(calibrated.greenComponent), blue: Double(calibrated.blueComponent))
        XCTAssertEqual(ITermImport.color(iTermColor(0.5, 0.25, 0.75, space: nil)), expected, "no color space is calibrated RGB")
        XCTAssertEqual(ITermImport.color(iTermColor(0.5, 0.25, 0.75, space: "Calibrated")), expected)
        XCTAssertNotEqual(expected, ThemeColor(red: 0.5, green: 0.25, blue: 0.75), "converted, not copied")

        let plan = ITermImport.plan(preferences: iTermPreferences([
            "Use Separate Colors for Light and Dark Mode": true,
            "Background Color (Light)": iTermColor(1, 1, 1), "Foreground Color (Light)": iTermColor(0, 0, 0),
            "Background Color (Dark)": iTermColor(0, 0, 0), "Foreground Color (Dark)": iTermColor(1, 1, 1),
            "Ansi 4 Color": iTermColor(0, 0, 1), "Ansi 4 Color (Dark)": iTermColor(0.5, 0.5, 1),
            "Smart Cursor Color (Dark)": true, "Cursor Color (Dark)": iTermColor(1, 0, 0), "Cursor Color (Light)": iTermColor(0, 1, 0),
        ]), fonts: fonts)
        XCTAssertEqual(plan.themes.map(\.name), ["iTerm2 · Example Work Light", "iTerm2 · Example Work Dark"])
        XCTAssertEqual(plan.themes.map(\.role), [.light, .dark])
        XCTAssertEqual(plan.themes[0].theme.background, ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(plan.themes[1].theme.background, ThemeColor(r: 0, g: 0, b: 0))
        XCTAssertEqual(plan.themes[0].theme.palette[4], ThemeColor(r: 0, g: 0, b: 255), "a mode without its own color takes the shared one")
        XCTAssertEqual(plan.themes[1].theme.palette[4], ThemeColor(red: 0.5, green: 0.5, blue: 1))
        XCTAssertEqual(plan.themes[0].theme.cursor, ThemeColor(r: 0, g: 255, b: 0))
        XCTAssertNil(plan.themes[1].theme.cursor, "a smart cursor has no color of its own")
    }

    // MARK: Terminal

    private func archived(_ object: NSObject) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    func testTerminalMapsAnArchivedProfile() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 15))
        let profile: [String: Any] = [
            "name": "Example Paper", "type": "Window Settings",
            "Font": try archived(font),
            "BackgroundColor": try archived(NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 0.9)),
            "TextColor": try archived(NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)),
            "TextBoldColor": try archived(NSColor.black),
            "CursorColor": try archived(NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)),
            "SelectionColor": try archived(NSColor(calibratedWhite: 0.8, alpha: 1)),
            "ANSIRedColor": try archived(NSColor(srgbRed: 0.75, green: 0.1, blue: 0.1, alpha: 1)),
            "ANSIBrightWhiteColor": try archived(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
            "BackgroundBlur": 0.5, "FontHeightSpacing": 1.1,
            "CursorType": 2, "CursorBlink": true, "useOptionAsMetaKey": true,
            "ShouldLimitScrollback": 1, "ScrollbackLines": 5000,
            "CommandString": "/bin/bash --login", "RunCommandAsShell": true,
        ]
        let profiles: [String: [String: Any]] = ["Basic": ["name": "Basic"], "Example Paper": profile, "Example Ocean": [:]]
        let preferences: [String: Any] = ["Default Window Settings": "Example Paper", "Shell": "/bin/zsh", "Window Settings": profiles]
        XCTAssertEqual(TerminalAppImport.profiles(in: preferences).map(\.name), ["Example Paper", "Basic", "Example Ocean"])

        let plan = TerminalAppImport.plan(preferences: preferences, fonts: fonts)
        XCTAssertEqual(plan.source, "Terminal · Example Paper")
        let result = applied(plan)
        XCTAssertEqual(result.terminalOpacity, 0.9, accuracy: 1e-9, "the background's alpha")
        XCTAssertEqual(result.fontFamily, "Menlo")
        XCTAssertEqual(result.fontSize, 15)
        XCTAssertEqual(result.cursor, .bar)
        XCTAssertTrue(result.cursorBlink)
        XCTAssertEqual(result.optionAsAlt, .both)
        XCTAssertEqual(result.scrollback, .small)
        XCTAssertEqual(result.shell, "/bin/bash --login", "a command run as the shell wins over Shells open with")

        let theme = try XCTUnwrap(plan.themes.first)
        XCTAssertEqual(theme.name, "Terminal · Example Paper")
        XCTAssertEqual(theme.role, .light, "a light background is the light scheme")
        XCTAssertEqual(theme.theme.background, ThemeColor(red: 0.98, green: 0.97, blue: 0.94))
        XCTAssertEqual(theme.theme.foreground, ThemeColor(red: 0.1, green: 0.1, blue: 0.1))
        XCTAssertEqual(theme.theme.cursor, ThemeColor(red: 0.2, green: 0.4, blue: 0.8))
        XCTAssertNotNil(theme.theme.selectionBackground, "generic gray converts to sRGB")
        XCTAssertEqual(theme.theme.palette[1], ThemeColor(red: 0.75, green: 0.1, blue: 0.1))
        XCTAssertEqual(theme.theme.palette[15], ThemeColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(theme.theme.palette.compactMap { $0 }.count, 2, "colors the profile lacks stay standard")
        XCTAssertEqual(plan.skipped, ["Background blur (terminal opacity only)", "Bold text color (bold text keeps its color)",
                                      "Character and line spacing (not adjustable)"])
    }

    func testTerminalProfilesWithoutColorsOrWithAShellCommand() throws {
        let dark: [String: Any] = ["BackgroundColor": try archived(NSColor.black), "TextColor": try archived(NSColor.white),
                                   "CommandString": "echo hello", "ShouldLimitScrollback": false, "useOptionAsMetaKey": false,
                                   "CursorType": 1, "Font": try archived(try XCTUnwrap(NSFont(name: "Helvetica", size: 12)))]
        let basicFont = try archived(NSFont.systemFont(ofSize: 11))
        let profiles: [String: [String: Any]] = ["Basic": ["CursorType": 0, "Font": basicFont], "Example Night": dark]
        let preferences: [String: Any] = ["Shell": "/bin/zsh -l", "Window Settings": profiles]
        XCTAssertEqual(TerminalAppImport.profiles(in: preferences).map(\.name), ["Basic", "Example Night"], "without a default, by name")

        let basic = TerminalAppImport.plan(preferences: preferences, fonts: fonts)
        XCTAssertEqual(basic.source, "Terminal · Basic")
        XCTAssertTrue(basic.themes.isEmpty)
        XCTAssertEqual(basic.skipped, ["Font SF Mono (not a monospaced font on this Mac)",
                                       "Colors (this profile follows the system's light or dark appearance)"],
                       "Terminal's own profiles name the hidden system font they show as SF Mono")
        XCTAssertEqual(applied(TerminalAppImport.plan(preferences: preferences, fonts: fonts + ["SF Mono"])).fontFamily, "SF Mono")
        XCTAssertEqual(applied(basic).cursor, .block)
        XCTAssertEqual(applied(basic).shell, "/bin/zsh -l")

        let night = TerminalAppImport.plan(preferences: preferences, profile: "Example Night", fonts: fonts)
        XCTAssertEqual(night.themes.map(\.role), [.dark])
        let result = applied(night)
        XCTAssertEqual(result.cursor, .underline)
        XCTAssertEqual(result.optionAsAlt, .off)
        XCTAssertEqual(result.scrollback, .unlimited)
        XCTAssertEqual(result.shell, "/bin/zsh -l", "a command the shell runs isn't the shell")
        XCTAssertEqual(result.fontFamily, Preferences().fontFamily)
        XCTAssertEqual(night.skipped, ["Font Helvetica (not a monospaced font on this Mac)", "Run command (no startup command)"])
    }
}
