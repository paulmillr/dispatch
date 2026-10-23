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
}
