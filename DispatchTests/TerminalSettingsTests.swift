import XCTest
@testable import DispatchApp

/// Settings for people coming from other terminals: the cursor, scrollback, which Option keys are Alt, and the
/// shell new local tabs run.
@MainActor
final class TerminalSettingsTests: XCTestCase {
    func testDefaultsAndRoundTrip() throws {
        let fresh = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.cursor, .block)
        XCTAssertTrue(fresh.cursorBlink)
        XCTAssertEqual(fresh.scrollback, .automatic)
        XCTAssertEqual(fresh.optionAsAlt, .both)
        XCTAssertEqual(fresh.shell, "", "the login shell")
        XCTAssertNil(fresh.shellProgram)
        var chosen = fresh
        chosen.cursor = .bar
        chosen.cursorBlink = false
        chosen.scrollback = .unlimited
        chosen.optionAsAlt = .left
        chosen.shell = "/bin/zsh -l"
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(chosen)), chosen)
        XCTAssertEqual(chosen.shellProgram, "/bin/zsh")
    }

    func testScrollbackLimitsAndOptionKeysInGhosttysTerms() {
        XCTAssertEqual(Scrollback.automatic.limit(automatic: 123), "123")
        XCTAssertEqual(Scrollback.small.limit(automatic: 123), "10000000")
        XCTAssertEqual(Scrollback.unlimited.limit(automatic: 123), "unlimited")
        XCTAssertEqual(OptionKeys.allCases.map(\.ghostty), ["true", "left", "right", "false"])
    }

    func testOnlyARunnableShellReplacesTheLoginShell() {
        let runtime = TerminalRuntime.shared, preferences = runtime.preferences
        defer { runtime.preferences = preferences }
        runtime.preferences.shell = ""
        XCTAssertNil(runtime.shellCommand)
        runtime.preferences.shell = "  /bin/sh -l "
        XCTAssertEqual(runtime.shellCommand, "/bin/sh -l")
        runtime.preferences.shell = "/nonexistent/fish"
        XCTAssertNil(runtime.shellCommand, "a missing shell falls back to the login shell")
        runtime.preferences.shell = "fish"
        XCTAssertNil(runtime.shellCommand, "only a full path: a bare name can't be checked before it runs")
    }

    func testColorSchemesSortByTheirBackground() {
        XCTAssertEqual(ColorSchemes.side("background = #1e1e2e\nforeground = #cdd6f4"), false, "dark")
        XCTAssertEqual(ColorSchemes.side("background = #eff1f5\nforeground = #4c4f69"), true, "light")
        XCTAssertNil(ColorSchemes.side("palette = 0=#000000"), "no background reads as either")
        XCTAssertNil(ColorSchemes.side("background = #ff0000\nforeground = #ffff00"), "a mid background reads as either")
        XCTAssertEqual(ColorSchemes.side("background = #fff"), true, "three-digit colors")
    }

    func testSchemeAuditFindsProblems() {
        let schemes = ColorSchemes(directory: System.resources.appendingPathComponent("ghostty/themes"), custom: [])
        XCTAssertNil(schemes.problems["iTerm2 Solarized Light"], "classics are left alone")
        XCTAssertNil(schemes.problems["Monokai Soda"], "a repeated color isn't marked")
        XCTAssertNil(schemes.problems["Dracula"])
        XCTAssertNil(schemes.problems["Hot Dog Stand"], "Fun schemes are left alone")
        XCTAssertEqual(Set(SchemeGroup.classics.keys).subtracting(schemes.dark + schemes.light), [], "every classic is bundled")
        let audit = { (theme: String) in SchemeAudit.problems(name: "Harbor Night", theme: theme) }
        let palette = (0...15).map { "palette = \($0)=#\($0 == 8 ? "606060" : $0 == 7 || $0 == 15 ? "e0e0e0" : "e06c75")" }.joined(separator: "\n")
        XCTAssertEqual(audit("background = #101010\nforeground = #2a2a2a\n" + palette), ["text contrast only 1.3:1"])
        XCTAssertEqual(audit("background = #101010\nforeground = #e0e0e0\npalette = 3=#1a1a10\ncursor-color = #181818"),
                       ["yellow hard to read", "cursor hard to see"])
        XCTAssertEqual(audit("palette = 1=#000000"), [], "no background: nothing to judge against")
    }

    func testSchemesHaveTheirSections() {
        let schemes = ColorSchemes(directory: System.resources.appendingPathComponent("ghostty/themes"), custom: [])
        XCTAssertEqual(Set(schemes.dark + schemes.light + schemes.either), Set(SchemeGroup.bundled.keys), "every bundled scheme placed by hand")
        XCTAssertEqual(schemes.groups["vim-vantablack"], .graphite)
        XCTAssertEqual(schemes.groups["Dracula"], .neon)
        XCTAssertEqual(schemes.groups["iTerm2 Solarized Light"], .cream)
        XCTAssertEqual(schemes.groups["GitHub Light Default"], .white)
        XCTAssertEqual(schemes.groups["Alabaster"], .offWhite)
        for name in SchemeGroup.bothSides {
            XCTAssertTrue(schemes.dark.contains(name) && schemes.light.contains(name), name)
            XCTAssertEqual(schemes.groups[name], .fun, name)
        }
        let day = { (theme: String) in ColorSchemes.group("Harbor Day", theme: theme, light: true) }
        XCTAssertEqual(day("background = #ffffff\npalette = 1=#e06c75\npalette = 2=#98c379"), .white)
        XCTAssertEqual(day("background = #f7f7f7\npalette = 1=#e06c75\npalette = 2=#98c379"), .offWhite)
        XCTAssertEqual(day("background = #fdf6e3\npalette = 1=#e06c75\npalette = 2=#98c379"), .cream)
        XCTAssertEqual(day("background = #e5e9f0\npalette = 1=#e06c75\npalette = 2=#98c379"), .mist)
        XCTAssertEqual(day("background = #ffffff\npalette = 1=#806060\npalette = 2=#608060"), .muted)
        let theirs = { (theme: String) in ColorSchemes.group("Harbor Night", theme: theme, light: false) }
        XCTAssertEqual(theirs("background = #000000\npalette = 1=#ff0000"), .oled)
        XCTAssertEqual(theirs("background = #1e2030\npalette = 1=#ff0000\npalette = 2=#00ff00"), .neon)
        XCTAssertEqual(theirs("background = #1e2030\npalette = 1=#806060\npalette = 2=#608060"), .muted)
        XCTAssertEqual(theirs("background = #24203a\npalette = 1=#e06c75\npalette = 2=#98c379"), .dusk)
        XCTAssertEqual(theirs("background = #0d1a26\npalette = 1=#e06c75\npalette = 2=#98c379"), .midnight)
        XCTAssertEqual(theirs("background = #222222\npalette = 1=#e06c75\npalette = 2=#98c379"), .graphite)
    }
}
