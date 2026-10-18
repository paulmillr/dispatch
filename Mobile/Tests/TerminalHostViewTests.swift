import Foundation
import UIKit
import XCTest
@_spi(Test) import Term
@testable import DispatchMobile

/// The host view with a scripted feed: output shown, the grid sent with the attach and again on every size change
/// (rotation, keyboard, zoom), keys from the software keyboard, the capsule and hardware keyboards encoded for the
/// program, selection and copy, and finger scrolling through the local scrollback into the server's history.
@MainActor
final class TerminalHostViewTests: XCTestCase {
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        for controller in controllers { controller.disappear() }
        controllers.removeAll()
    }

    private var controllers: [TerminalController] = []

    /// The feed's terminal in a host view, in a window, attached.
    private func host(_ feed: ScriptedTerminalFeed, size: CGSize = CGSize(width: 402, height: 600),
                      scrollback: TerminalScrollback = .unknown) async throws -> TerminalHostView {
        try await makeController(feed, size: size, scrollback: scrollback).hostView
    }

    private func makeController(_ feed: ScriptedTerminalFeed, size: CGSize = CGSize(width: 402, height: 600),
                            scrollback: TerminalScrollback = .unknown) async throws -> TerminalController {
        let controller = TerminalController(feed: feed, scrollback: scrollback, configuration: TerminalConfiguration())
        controllers.append(controller)
        windows.append(TerminalTestWindow.show(controller.hostView, size: size))
        controller.appear()
        try await TestSupport.eventually { !feed.record.attachments.isEmpty }
        return controller
    }

    private func sent(_ feed: ScriptedTerminalFeed, _ expected: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic: "sent \(String(reflecting: String(decoding: feed.record.sent, as: UTF8.self)))") {
            String(decoding: feed.record.sent, as: UTF8.self) == expected
        }
    }

    func testAttachShowsTheOutputAtTheViewsGrid() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await host(feed)
        try await TestSupport.eventually { view.visibleText().contains("~/src/app $ pnpm dev") }
        let size = try XCTUnwrap(feed.record.attachments.first)
        XCTAssertEqual(size, view.session.currentSize)
        // 402 points less 2 x 14 padding, in cells of the 12 point font: about 50 columns.
        XCTAssertGreaterThanOrEqual(size.columns, 45)
        XCTAssertLessThanOrEqual(size.columns, 56)
        XCTAssertGreaterThan(size.cellHeight, size.cellWidth)
    }

    /// Rotation and the keyboard change the view's size: the new grid goes through the feed once per change.
    func testSizeChangesResizeThroughTheFeed() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await host(feed)
        let portrait = view.session.currentSize
        view.window?.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
        view.window?.layoutIfNeeded()
        try await TestSupport.eventually { feed.record.resizes.last?.columns ?? 0 > portrait.columns }
        let landscape = try XCTUnwrap(feed.record.resizes.last)
        XCTAssertLessThan(landscape.rows, portrait.rows)
        XCTAssertEqual(landscape, view.session.currentSize)
        let count = feed.record.resizes.count
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(feed.record.resizes.count, count, "An unchanged grid is not sent again")
        // The keyboard takes the bottom: fewer rows, the same columns.
        view.window?.frame = CGRect(x: 0, y: 0, width: 874, height: 250)
        view.window?.layoutIfNeeded()
        try await TestSupport.eventually { feed.record.resizes.last?.rows ?? 0 < landscape.rows }
        XCTAssertEqual(feed.record.resizes.last?.columns, landscape.columns)
    }

    /// Pinch zoom: a larger font means fewer cells, sent through the feed; sizes stay in half points within bounds.
    func testZoomChangesTheFontAndResizes() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await host(feed)
        let before = view.session.currentSize
        var bigger = view.configuration
        bigger.fontSize = 18
        view.configure(bigger)
        try await TestSupport.eventually { (feed.record.resizes.last?.columns ?? .max) < before.columns }
        XCTAssertGreaterThan(feed.record.resizes.last!.cellHeight, before.cellHeight)
        XCTAssertEqual(TerminalConfiguration.zoomed(12, scale: 1.5), 18)
        XCTAssertEqual(TerminalConfiguration.zoomed(12, scale: 1.13), 13.5)
        XCTAssertEqual(TerminalConfiguration.zoomed(12, scale: 0.1), 7)
        XCTAssertEqual(TerminalConfiguration.zoomed(12, scale: 9), 28)
        XCTAssertEqual(TerminalConfiguration.zoomed(12, scale: .nan), 12)
    }

    func testSoftwareKeyboardTextReturnAndBackspace() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let view = try await host(feed)
        view.insertText("ls -la")
        view.insertText("\n")
        view.deleteBackward()
        view.insertText("\t")
        try await sent(feed, "ls -la\r\u{7F}\t")
    }

    func testInputMethodPreeditIsSentWhenCommitted() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let view = try await host(feed)
        view.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertEqual(view.text(in: view.markedTextRange!), "に")
        view.deleteBackward()
        XCTAssertTrue(feed.record.sent.isEmpty, "Nothing reaches the program while composing")
        view.insertText("日本")
        XCTAssertNil(view.markedTextRange)
        try await sent(feed, "日本")
    }

    /// The capsule's Ctrl and Alt apply to the next key typed on the software keyboard, then release.
    func testCapsuleModifiersApplyToTheNextKey() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let controller = try await makeController(feed)
        let view = controller.hostView
        controller.tap(.ctrl)
        view.insertText("c")
        XCTAssertEqual(controller.capsule.ctrl, .off)
        controller.tap(.alt)
        view.insertText("x")
        view.insertText("y")
        controller.press(.escape)
        controller.press(.tab)
        try await sent(feed, "\u{3}\u{1B}xy\u{1B}\t")
    }

    func testArrowKeysFollowTheCursorKeyMode() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let controller = try await makeController(feed)
        controller.dpadDown()
        controller.dpadUp()
        controller.clusterKeyDown(.up)
        controller.clusterKeyUp()
        try await sent(feed, "\u{1B}[A")
        // vim and htop switch to application cursor keys.
        controller.hostView.session.feed("\u{1B}[?1h")
        controller.clusterKeyDown(.left)
        controller.clusterKeyUp()
        controller.clusterKeyDown(.enter)
        controller.clusterKeyUp()
        try await sent(feed, "\u{1B}[A\u{1B}OD\r")
    }

    func testHardwareKeyCommands() async throws {
        let feed = ScriptedTerminalFeed(output: Data())
        let view = try await host(feed)
        let command = { (input: String, flags: UIKeyModifierFlags) in
            view.keyCommand(UIKeyCommand(input: input, modifierFlags: flags, action: #selector(TerminalHostView.keyCommand(_:))))
        }
        command("c", .control)
        command("b", .alternate)
        command(UIKeyCommand.inputUpArrow, [])
        command(UIKeyCommand.inputRightArrow, .alternate)
        command(UIKeyCommand.inputEscape, [])
        command(UIKeyCommand.f1, [])
        command("\t", .shift)
        try await sent(feed, "\u{3}\u{1B}b\u{1B}[A\u{1B}[1;3C\u{1B}\u{1B}OP\u{1B}[Z")
        XCTAssertGreaterThan(view.keyCommands?.count ?? 0, 100)
    }

    func testPasteIsBracketedWhenTheProgramAsks() async throws {
        let feed = ScriptedTerminalFeed(output: Data("\u{1B}[?2004h".utf8))
        let view = try await host(feed)
        try await TestSupport.eventually { view.session.locked { true } && feedParsed(view, "\u{1B}[?2004h") }
        view.paste(text: "echo hi")
        try await sent(feed, "\u{1B}[200~echo hi\u{1B}[201~")
    }

    /// Long press selects the word under the finger without a click reaching the program; Copy puts it on the
    /// pasteboard; the handles extend it.
    func testSelectionCopyAndHandles() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteDev)
        let view = try await host(feed)
        try await TestSupport.eventually { view.visibleText().contains("localhost") }
        let session = view.session
        // "http://localhost:5173/" starts at column 14 of row 3; Ghostty's word boundaries include ":", so the word
        // under column 20 is "//localhost", from column 19.
        XCTAssertTrue(session.locked { session.surface.touchSelectWord((x: 20, y: 3)) })
        XCTAssertEqual(session.locked { session.surface.readSelection().map { String(decoding: $0, as: UTF8.self) } }, "//localhost")
        view.updateSelectionHandles()
        XCTAssertFalse(view.startHandle.isHidden)
        XCTAssertFalse(view.endHandle.isHidden)
        XCTAssertEqual(view.startHandle.center.x, view.rect(of: (x: 19, y: 3)).minX, accuracy: 0.5)
        // The end handle dragged above the start swaps ends.
        let moved = session.locked { session.surface.touchMoveSelection(.end, to: (x: 2, y: 2)) }
        XCTAssertEqual(moved, .start)
        let ends = try XCTUnwrap(session.locked { session.surface.touchSelection })
        XCTAssertEqual(ends.start?.x, 2)
        XCTAssertEqual(ends.start?.y, 2)
        XCTAssertEqual(ends.end?.x, 19)
        XCTAssertEqual(ends.end?.y, 3)
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "vite v6.1.0  ready in 412 ms\n  ➜  Local:   http:/")
        XCTAssertFalse(session.locked { session.surface.hasSelection })
        XCTAssertTrue(feed.record.sent.isEmpty, "Selecting sends nothing to the program")
    }

    /// Scrolling up uses the local scrollback to its top, then asks the server; tmux answers app-owned, after
    /// which the step stays local. Scrolling down returns to the live screen.
    func testFingerScrollingUsesLocalScrollbackThenTheServer() async throws {
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\r\n")
        let feed = ScriptedTerminalFeed(output: Data(lines.utf8), options: .init(scroll: .appOwned))
        let view = try await host(feed)
        XCTAssertEqual(view.scroll.server, .unknown, "No backend kind given: learned from the first answer")
        try await TestSupport.eventually { view.visibleText().contains("line 200") }
        let session = view.session
        let line = view.cellSize.height
        let above = session.locked { session.surface.touchHistoryAbove }
        XCTAssertGreaterThan(above, 100)
        view.scrollBy(points: line * 10 + 1, at: .zero)
        XCTAssertEqual(session.locked { session.surface.touchHistoryAbove }, above - 10)
        XCTAssertTrue(feed.record.scrolls.isEmpty)
        view.scrollBy(points: line * Double(above), at: .zero)
        XCTAssertEqual(session.locked { session.surface.touchHistoryAbove }, 0)
        try await TestSupport.eventually { feed.record.scrolls.count == 1 }
        XCTAssertEqual(feed.record.scrolls[0].lines, 10, "Only the lines past the local top go to the server")
        try await TestSupport.eventually { view.scroll.server == .appOwned }
        view.scrollBy(points: line * 5, at: .zero)
        XCTAssertEqual(feed.record.scrolls.count, 1, "App-owned: the server is not asked again")
        view.scrollBy(points: -line * Double(above + 50), at: .zero)
        XCTAssertEqual(session.locked { session.surface.touchHistoryBelow }, 0)
        XCTAssertTrue(view.visibleText().contains("line 200"))
    }

    /// herdr keeps history on the server: with no local scrollback every step goes there, and back down returns it.
    func testServerHistoryScrollsAndReturns() async throws {
        let feed = ScriptedTerminalFeed(output: Data("$ ".utf8), options: .init(scroll: .server, history: 500))
        let view = try await host(feed)
        let line = view.cellSize.height
        view.scrollBy(points: line * 12, at: CGPoint(x: 30, y: 40))
        try await TestSupport.eventually { view.scroll.serverOffset == 12 && view.scroll.server == .available }
        XCTAssertEqual(feed.record.scrolls.first?.lines, 12)
        XCTAssertEqual(feed.record.scrolls.first?.row, view.cell(at: CGPoint(x: 30, y: 40)).y)
        view.scrollBy(points: -line * 20, at: .zero)
        try await TestSupport.eventually { feed.record.scrolls.count == 2 }
        XCTAssertEqual(feed.record.scrolls[1].lines, -12, "Down returns the server to its live screen, no further")
    }

    /// tmux: the backend kind says the history is the client's, so the server is never asked, even past the top.
    func testTmuxScrollbackStaysLocal() async throws {
        let lines = (1...100).map { "line \($0)" }.joined(separator: "\r\n")
        let feed = ScriptedTerminalFeed(output: Data(lines.utf8), options: .init(scroll: .server, history: 50))
        let view = try await host(feed, scrollback: TerminalScrollback(multiplexer: "tmux"))
        try await TestSupport.eventually { view.visibleText().contains("line 100") }
        view.scrollBy(points: view.cellSize.height * 500, at: .zero)
        XCTAssertEqual(view.session.locked { view.session.surface.touchHistoryAbove }, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(feed.record.scrolls.isEmpty)
    }

    /// A new attachment (a reconnect) clears what the previous one showed before its own output repaints.
    func testReattachStartsFromAnEmptyScreen() async throws {
        let first = ScriptedTerminalFeed(output: Data("first attachment".utf8))
        let view = try await host(first)
        try await TestSupport.eventually { view.visibleText().contains("first attachment") }
        let second = ScriptedTerminalFeed(output: Data("second".utf8))
        view.presence.reattach(second)
        try await TestSupport.eventually { view.visibleText().contains("second") }
        XCTAssertFalse(view.visibleText().contains("first attachment"))
        XCTAssertEqual(first.record.detaches, 1)
    }

    func testProcessExitReachesTheController() async throws {
        let feed = ScriptedTerminalFeed([.output(Data("bye".utf8)), .exit(3)])
        let controller = try await makeController(feed)
        try await TestSupport.eventually { controller.ended == .exited(3) }
    }

    func testTitleAndWorkingDirectoryForTheHeader() async throws {
        let feed = ScriptedTerminalFeed(output: Data("\u{1B}]2;vim notes.md\u{7}\u{1B}]7;file://localhost/home/paul/src/my%20app\u{7}".utf8))
        let controller = try await makeController(feed)
        try await TestSupport.eventually { controller.title == "vim notes.md" }
        try await TestSupport.eventually { controller.directory == "/home/paul/src/my app" }
        XCTAssertEqual(TerminalSubtitle.text(directory: controller.directory, shell: "/usr/bin/zsh", home: "/home/paul"), "~/src/my app · zsh")
        XCTAssertEqual(TerminalSubtitle.text(directory: "/home/paul", shell: "-bash", home: "/home/paul/"), "~ · bash")
        XCTAssertEqual(TerminalSubtitle.text(directory: "/srv/app", shell: nil, home: "/home/paul"), "/srv/app")
        XCTAssertEqual(TerminalSubtitle.text(directory: nil, shell: "fish -l"), "fish")
        XCTAssertNil(TerminalSubtitle.path(fromWorkingDirectory: "http://example.com/x"))
    }
}

/// Whether `bytes` were parsed (the feed task runs off the main queue): the scripted output is short, so its
/// arrival shows in the bytes the session counted.
@MainActor private func feedParsed(_ view: TerminalHostView, _ bytes: String) -> Bool {
    view.session.frameStats().bytesFed >= bytes.utf8.count
}
