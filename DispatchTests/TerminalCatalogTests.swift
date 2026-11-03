import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

final class TerminalCatalogTests: XCTestCase {
    func testThemeParserKeepsPresenceAndCanonicalColors() throws {
        let parsed = TerminalTheme.parse("""
        foreground = "#abc"
        palette = 1=#f00
        palette = 6=#123456
        palette = 20=#fed
        # display-p3: foreground = #abcdef
        """)
        XCTAssertFalse(parsed.hasBackground)
        XCTAssertTrue(parsed.hasForeground)
        XCTAssertNil(parsed.side, "a missing background belongs on either side")
        XCTAssertEqual(parsed.theme.foreground.hex, "#aabbcc")
        XCTAssertEqual(parsed.theme.foreground.displayP3?.hex, "#abcdef")
        XCTAssertEqual(parsed.theme.palette[1]?.hex, "#ff0000")
        XCTAssertEqual(parsed.theme.palette[6]?.hex, "#123456")
        XCTAssertTrue(parsed.theme.extra.contains("palette = 20=#fed"))
        let theme = try XCTUnwrap(TerminalTheme(text: parsed.theme.text))
        XCTAssertEqual(theme, parsed.theme, "the editable form keeps colors and unknown palette entries")
    }

    func testThemeClassificationUsesLinearLightAndForeground() {
        XCTAssertEqual(TerminalTheme.parse("background=#111\nforeground=#fff").side, false)
        XCTAssertEqual(TerminalTheme.parse("background=#fff\nforeground=#111").side, true)
        XCTAssertNil(TerminalTheme.parse("background=#aaa\nforeground=#fff").side)
        XCTAssertNil(TerminalTheme.parse("background=invalid\nforeground=#fff").side)
        XCTAssertEqual(TerminalTheme.parse("background=#000\nbackground=\"#fff\"").side, true,
                       "the last valid assignment is the one the terminal uses")
        XCTAssertNil(TerminalTheme(text: "palette=1=#f00"))
        XCTAssertEqual(TerminalTheme.parse("palette=1=#f00").theme.palette[1]?.hex, "#ff0000")
        let windows = TerminalTheme.parse("background=#111\r\nforeground=#fff\r\npalette=1=#f00\r\n")
        XCTAssertEqual(windows.side, false)
        XCTAssertEqual(windows.theme.palette[1]?.hex, "#ff0000")
        XCTAssertEqual(windows.theme.foreground.hex, "#ffffff")
    }

    func testFontIdentityAndNativeSubstitutionsRemainStable() throws {
        let choices = ChatFontChoice.allCases
        XCTAssertEqual(try JSONDecoder().decode([ChatFontChoice].self, from: JSONEncoder().encode(choices)), choices)
        XCTAssertEqual(ChatFontChoice.comicSans.namedFace(on: .macOS), "ComicSansMS")
        XCTAssertEqual(ChatFontChoice.comicSans.namedFace(on: .iOS), "Chalkboard SE")
        XCTAssertEqual(ChatFontChoice.comicSans.scale(on: .macOS), 0.907)
        XCTAssertEqual(ChatFontChoice.comicSans.scale(on: .iOS), 1)
        XCTAssertEqual(ChatFontChoice.latinModernRoman.scale(on: .macOS), ChatFontChoice.latinModernRoman.scale(on: .iOS))
        let families = TerminalFontCatalog.bundled.map(\.family)
        XCTAssertEqual(families.count, Set(families).count)
        XCTAssertTrue(families.contains(TerminalFontCatalog.defaultFamily))
        XCTAssertTrue(families.contains(TerminalFontCatalog.fallbackFamily))
    }
}
