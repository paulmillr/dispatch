import Foundation
import XCTest
@_spi(Test) import Term
@testable import DispatchMobile

/// The emulator on the phone: fixtures fed through a `TerminalSession`, read back cell by cell (vttest-style checks,
/// the M6a screen, full-screen programs), the theme and fonts the configuration loads, and replies to the program.
@MainActor
final class TerminalEmulatorTests: XCTestCase {
    func testGridFollowsTheRequestedSize() throws {
        let session = try TerminalSession.testing(columns: 40, rows: 12)
        let size = session.currentSize
        XCTAssertEqual(size.columns, 40)
        XCTAssertEqual(size.rows, 12)
        XCTAssertGreaterThan(size.cellWidth, 0)
        XCTAssertGreaterThan(size.cellHeight, size.cellWidth)
    }

    func testScreenAlignmentFillsEveryCell() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 6)
        session.feed(TerminalFixtures.screenAlignment)
        for y in 0..<6 { XCTAssertEqual(session.row(y), String(repeating: "E", count: 20), "row \(y)") }
        XCTAssertEqual(session.cursor.x, 0)
        XCTAssertEqual(session.cursor.y, 0)
    }

    func testCursorMovesLeaveMarkersWhereVttestExpectsThem() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 8)
        session.feed(TerminalFixtures.cursorMoves)
        XCTAssertEqual(session.cell(0, 0).text, "A")
        XCTAssertEqual(session.cell(9, 4).text, "B")
        XCTAssertEqual(session.cell(4, 1).text, "C")
        XCTAssertEqual(session.cell(2, 5).text, "D")
    }

    func testScrollRegionScrollsOnlyItsRows() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 6)
        session.feed(TerminalFixtures.scrollRegion)
        XCTAssertEqual(session.row(0), "top")
        XCTAssertEqual(session.row(1), "two")
        XCTAssertEqual(session.row(2), "three")
        XCTAssertEqual(session.row(3), "four")
        XCTAssertEqual(session.row(4), "bottom")
    }

    func testAutowrapContinuesOnTheNextRow() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        session.feed(TerminalFixtures.autowrap(columns: 20))
        XCTAssertEqual(session.row(0), String(repeating: "x", count: 20))
        XCTAssertEqual(session.row(1), "abc")
    }

    func testEraseInsertAndDeleteCharacters() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        session.feed(TerminalFixtures.eraseInsertDelete)
        XCTAssertEqual(session.row(0), "0123")
        XCTAssertEqual(session.row(1), "ab  cdef")
        XCTAssertEqual(session.row(2), "adef")
    }

    func testColoursAndAttributesAreReadFromTheCells() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        session.feed(TerminalFixtures.colours)
        XCTAssertEqual(session.row(0), "BRPTIN")
        XCTAssertTrue(session.cell(0, 0).style.flags.bold)
        XCTAssertEqual(session.cell(1, 0).style.fgColor, .palette(1))
        XCTAssertEqual(session.cell(2, 0).style.fgColor, .palette(196))
        XCTAssertEqual(session.cell(3, 0).style.fgColor, .rgb(RGB(r: 1, g: 2, b: 3)))
        XCTAssertTrue(session.cell(4, 0).style.flags.inverse)
        XCTAssertEqual(session.cell(5, 0).style, Style())
    }

    func testWideCharactersTakeTwoCells() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        session.feed(TerminalFixtures.wide)
        XCTAssertEqual(session.cell(0, 0).text, "漢")
        XCTAssertEqual(session.cell(0, 0).wide, .wide)
        XCTAssertEqual(session.cell(1, 0).wide, .spacerTail)
        XCTAssertEqual(session.cell(2, 0).text, "字")
        XCTAssertEqual(session.cell(4, 0).text, "a")
        XCTAssertEqual(session.row(0), "漢字ab")
    }

    func testAlternateScreenKeepsThePrimaryScreen() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        session.feed(TerminalFixtures.alternateScreen)
        XCTAssertTrue(session.isAlternate)
        XCTAssertEqual(session.row(0), "alternate")
        session.feed(TerminalFixtures.alternateScreenExit)
        XCTAssertFalse(session.isAlternate)
        XCTAssertEqual(session.row(0), "primary")
    }

    /// M6a's screen, with the mockup's colours: the prompt's directory green, the port number yellow, URLs blue.
    func testViteFixtureShowsTheMockupScreen() throws {
        let session = try TerminalSession.testing(columns: 48, rows: 16)
        session.feed(TerminalFixtures.viteDev)
        XCTAssertEqual(session.row(0), "~/src/app $ pnpm dev")
        XCTAssertEqual(session.row(2), "  vite v6.1.0  ready in 412 ms")
        XCTAssertEqual(session.row(3), "  ➜  Local:   http://localhost:5173/")
        XCTAssertEqual(session.row(9), "           is deprecated")
        XCTAssertEqual(session.row(11), "  09:37:41 hmr update src/routes/invoices.ts")
        XCTAssertEqual(session.cursor.y, 12)
        XCTAssertEqual(session.cell(0, 0).style.fgColor, .palette(2))
        XCTAssertEqual(session.cell(24, 2).style.fgColor, .palette(3))
        XCTAssertEqual(session.cell(14, 3).style.fgColor, .palette(4))
        XCTAssertEqual(session.cell(12, 0).style.fgColor, .rgb(RGB(r: 255, g: 255, b: 255)))
    }

    func testVimFixtureDrawsAFullScreenEditor() throws {
        let session = try TerminalSession.testing(columns: 44, rows: 20)
        session.feed(TerminalFixtures.vim(columns: 44, rows: 20))
        XCTAssertTrue(session.isAlternate)
        XCTAssertEqual(session.row(0), "  1 import Foundation")
        XCTAssertEqual(session.cell(4, 0).style.fgColor, .palette(5))
        XCTAssertEqual(session.row(13), "~")
        XCTAssertEqual(session.cell(0, 13).style.fgColor, .palette(4))
        XCTAssertTrue(session.row(18).hasPrefix(" Sources/App/Retry.swift [+]"))
        XCTAssertTrue(session.cell(0, 18).style.flags.inverse)
        XCTAssertEqual(session.row(19), "-- INSERT --")
        XCTAssertEqual(session.cursor.x, 24)
        XCTAssertEqual(session.cursor.y, 8)
    }

    func testHtopFixtureDrawsMetersTableAndKeys() throws {
        let session = try TerminalSession.testing(columns: 50, rows: 20)
        session.feed(TerminalFixtures.htop(columns: 50, rows: 20))
        XCTAssertTrue(session.isAlternate)
        XCTAssertTrue(session.row(0).hasPrefix("  0["))
        XCTAssertTrue(session.row(0).contains("45.2%]"))
        XCTAssertTrue(session.row(5).hasPrefix("  PID USER"))
        XCTAssertEqual(session.cell(0, 5).style.bgColor, .palette(2))
        XCTAssertTrue(session.row(6).contains("node vite"))
        XCTAssertEqual(session.cell(0, 6).style.bgColor, .palette(6))
        XCTAssertTrue(session.row(19).hasPrefix("F1Help"))
    }

    /// The program's queries are answered through the feed (the multiplexer passes them on as input).
    func testRepliesGoBackToTheProgram() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        let sent = SentBytes()
        session.output = { sent.append($0) }
        session.feed("\u{1B}[6n")
        XCTAssertEqual(sent.text, "\u{1B}[1;1R")
    }

    /// The Mac's default dark theme, the `dispatch` palette, the configured font size and the contrast setting.
    func testConfigurationLoadsTheBundledThemeAndFonts() throws {
        let config = TerminalConfiguration().config()
        XCTAssertTrue(config.diagnostics.isEmpty, "\(config.diagnostics)")
        XCTAssertEqual(config.background, RGB(r: 0, g: 0, b: 0))
        XCTAssertEqual(config.foreground, RGB(r: 0xC9, g: 0xC9, b: 0xCE))
        XCTAssertEqual(config.palette[5], RGB(r: 0xE0, g: 0x7B, b: 0xE0))
        XCTAssertEqual(config.fontSize, 12)
        XCTAssertEqual(config.minimumContrast, 1)
        var contrast = TerminalConfiguration()
        contrast.improveTextContrast = true
        contrast.theme = "dispatch"
        let other = contrast.config()
        XCTAssertEqual(other.minimumContrast, 4.5)
        XCTAssertEqual(other.background, RGB(r: 0x0D, g: 0x0D, b: 0x0F))
        // The bundled fonts load (JetBrains Mono first).
        let session = try TerminalSession(configuration: TerminalConfiguration(), scale: 3)
        XCTAssertEqual(session.background, RGB(r: 0, g: 0, b: 0))
    }

    /// A new attachment starts from an empty screen and history: its output repaints everything.
    func testResetClearsScreenAndHistory() throws {
        let session = try TerminalSession.testing(columns: 20, rows: 4)
        session.feed(String(repeating: "line\r\n", count: 30))
        XCTAssertGreaterThan(session.locked { session.surface.terminal.scrollbar.total }, 4)
        session.reset()
        XCTAssertEqual(session.row(0), "")
        XCTAssertEqual(session.locked { session.surface.terminal.scrollbar.total }, 4)
    }
}
