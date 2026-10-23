import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The terminal's search (T1) and the key bar's menu (T2), on the terminal mockups' screen (`TerminalFixtures.viteTheme`,
/// three lines naming src/theme.ts): counts newest first, stepping round the ends, the rows and columns the renderer
/// highlights, a search that follows new output, the capsule's last key and the menu's actions.
@MainActor
final class TerminalSearchTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var controllers: [TerminalController] = []

    override func tearDown() async throws {
        for controller in controllers { controller.disappear() }
        for window in windows { window.isHidden = true }
        controllers = []
        windows = []
    }

    private func makeController(_ feed: any TerminalFeed, waitFor text: String? = "theme.ts") async throws -> TerminalController {
        let controller = TerminalController(feed: feed, configuration: TerminalConfiguration())
        // Needles run at once here; `testTypingIsDebounced` checks the pause.
        controller.search.debounce = .zero
        controllers.append(controller)
        windows.append(TerminalTestWindow.show(controller.hostView, size: CGSize(width: 402, height: 600)))
        controller.appear()
        if let text {
            let view = controller.hostView
            try await TestSupport.eventually(diagnostic: view.visibleText()) { view.visibleText().contains(text) }
        }
        return controller
    }

    /// The viewport rows holding `needle`, top to bottom, with the columns it covers.
    private func rows(of needle: String, in view: TerminalHostView) -> [(y: Int, x: ClosedRange<Int>)] {
        let lines = view.visibleText().components(separatedBy: "\n")
        return lines.enumerated().flatMap { y, line -> [(y: Int, x: ClosedRange<Int>)] in
            var found: [(y: Int, x: ClosedRange<Int>)] = []
            var start = line.startIndex
            while let range = line.range(of: needle, range: start..<line.endIndex) {
                let x = line.distance(from: line.startIndex, to: range.lowerBound)
                found.append((y, x...(x + needle.count - 1)))
                start = range.upperBound
            }
            return found
        }
    }

    /// A new needle counts every match and selects the newest; the arrows step up through older output and round
    /// the ends; the case of the needle does not matter; an empty needle stops the search, a missing one counts none.
    func testCountsAndSteppingRoundTheEnds() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: TerminalFixtures.viteTheme))
        let search = controller.search
        XCTAssertFalse(search.visible)
        controller.openSearch()
        XCTAssertTrue(search.visible)
        XCTAssertEqual(search.focusRequest, 1)
        XCTAssertEqual(search.count, "", "No needle, no count")
        search.update("theme.ts")
        XCTAssertEqual(search.total, 3)
        XCTAssertEqual(search.count, "1 of 3", "The newest match is selected at once")
        search.next()
        XCTAssertEqual(search.count, "2 of 3")
        search.next()
        XCTAssertEqual(search.count, "3 of 3")
        search.next()
        XCTAssertEqual(search.count, "1 of 3", "Round the oldest to the newest")
        search.previous()
        XCTAssertEqual(search.count, "3 of 3", "Round the newest to the oldest")
        search.update("THEME.TS")
        XCTAssertEqual(search.count, "3 of 3", "The same needle in another case keeps the selection")
        search.update("invoices")
        XCTAssertEqual(search.count, "0 of 0")
        XCTAssertFalse(search.canStep)
        search.next()
        XCTAssertEqual(search.count, "0 of 0")
        search.update("")
        XCTAssertNil(search.total)
        XCTAssertEqual(search.count, "")
        XCTAssertTrue(search.visible, "Clearing the needle keeps the capsule")
    }

    /// Every match is highlighted where its text is, the selected one apart, and the highlight follows the arrows;
    /// Done takes the highlights away and keeps the needle, which the next opening searches again.
    func testHighlightsFollowTheSelectionAndGoWithDone() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: TerminalFixtures.viteTheme))
        let view = controller.hostView, search = controller.search
        let expected = rows(of: "theme.ts", in: view)
        XCTAssertEqual(expected.count, 3, view.visibleText())
        controller.openSearch()
        search.update("theme.ts")
        func lit() -> [(y: Int, x: ClosedRange<Int>, selected: Bool)] {
            view.session.searchHighlightRows().enumerated().flatMap { y, row in row.map { (y, $0.x, $0.selected) } }
        }
        var highlights = lit()
        XCTAssertEqual(highlights.filter { !$0.selected }.map(\.y), expected.map(\.y), "Every match's row")
        XCTAssertEqual(highlights.filter { !$0.selected }.map(\.x), expected.map(\.x), "Every match's columns")
        XCTAssertEqual(highlights.filter(\.selected).map(\.y), [expected[2].y], "The newest (lowest) is selected")
        search.next()
        highlights = lit()
        XCTAssertEqual(highlights.filter(\.selected).map(\.y), [expected[1].y], "The next is the one above")
        XCTAssertEqual(highlights.filter(\.selected).map(\.x), [expected[1].x])
        controller.closeSearch()
        XCTAssertFalse(search.visible)
        XCTAssertNil(search.total)
        XCTAssertTrue(lit().isEmpty, "Done takes the highlights away")
        XCTAssertEqual(search.query, "theme.ts", "The needle stays")
        controller.openSearch()
        XCTAssertEqual(search.count, "1 of 3", "Opened again, it searches again")
        XCTAssertEqual(lit().count, 4)
    }

    /// An open search follows the program: output that arrives later is counted at the next frame.
    func testTheCountFollowsNewOutput() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: TerminalFixtures.viteTheme))
        let view = controller.hostView, search = controller.search
        controller.openSearch()
        search.update("theme.ts")
        XCTAssertEqual(search.total, 3)
        view.session.feed("  09:40:01 hmr update src/theme.ts\r\n")
        _ = view.session.searchHighlightRows()
        // The frame's refresh may be held back up to 24 ms; a frame comes for it then.
        try await TestSupport.eventually(diagnostic: "total \(String(describing: search.total))") {
            _ = view.session.searchHighlightRows()
            return search.total == 4
        }
        XCTAssertEqual(search.selected, 1, "The selected match stays where it was; a newer one came below it")
    }

    /// The capsule's last key: the keyboard key while the software keyboard is down, the menu while it is up, the
    /// folding key on an iPad with a hardware keyboard; it shows the ellipsis whenever the menu is open.
    func testTheLastKeysRole() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: Data()), waitFor: nil)
        controller.idiom = .phone
        controller.hardwareKeyboard = HardwareKeyboard(attached: false)
        XCTAssertEqual(controller.menuKey, .keyboard)
        XCTAssertEqual(controller.menuKey.symbol(menuOpen: false), "keyboard")
        XCTAssertEqual(controller.menuKey.symbol(menuOpen: true), "ellipsis.circle")
        XCTAssertEqual(controller.menuKey.label, "Show keyboard")
        XCTAssertFalse(controller.menuKey.opensOnTap, "A tap brings the keyboard; a long press opens the menu")
        controller.hardwareKeyboard = HardwareKeyboard(attached: true)
        XCTAssertEqual(controller.menuKey, .keyboard, "The phone keeps its keyboard key with a hardware keyboard")
        controller.idiom = .pad
        XCTAssertEqual(controller.menuKey, .hideKeys)
        XCTAssertEqual(controller.menuKey.symbol(menuOpen: false), "chevron.down")
        XCTAssertEqual(TerminalMenuKeyRole.menu.symbol(menuOpen: false), "ellipsis.circle")
        XCTAssertTrue(TerminalMenuKeyRole.menu.opensOnTap)
        XCTAssertEqual(TerminalMenuKeyRole.menu.label, "Terminal menu")
        XCTAssertFalse(controller.menuOpen)
        controller.menu(open: true)
        XCTAssertTrue(controller.menuOpen)
        controller.menu(open: false)
        XCTAssertFalse(controller.menuOpen)
    }

    /// The search capsule sits in the key capsule's slot at its height at every text size, so swapping them never
    /// changes the terminal's rows (a resize the server would redraw for).
    func testTheSearchCapsuleKeepsTheKeyCapsulesHeight() {
        let controller = TerminalController(feed: ScriptedTerminalFeed(output: Data()), configuration: TerminalConfiguration())
        controllers.append(controller)
        func height(_ view: some View, _ size: DynamicTypeSize) -> CGFloat {
            let host = UIHostingController(rootView: view.environment(\.dynamicTypeSize, size))
            return host.sizeThatFits(in: CGSize(width: 402, height: 1000)).height
        }
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility1, .accessibility5] {
            XCTAssertEqual(height(TerminalSearchBar(controller: controller), size),
                           height(TerminalKeyCapsule(controller: controller), size), accuracy: 0.5, "\(size)")
        }
    }

    /// The menu's items in the mockup's order, Clear screen with its chord; Hide keyboard while the keyboard is up.
    func testTheMenusItems() {
        XCTAssertEqual(TerminalMenuItem.sections(keyboardVisible: false).map { $0.map(\.title) },
                       [["Search", "Paste", "Select all"], ["Clear screen", "Reset terminal"]])
        XCTAssertEqual(TerminalMenuItem.sections(keyboardVisible: true).last, [.hideKeyboard])
        XCTAssertEqual(TerminalMenuItem.clearScreen.note(), "⌘K on a keyboard")
        XCTAssertEqual(TerminalMenuItem.allCases.compactMap { $0.note() }.count, 1)
        XCTAssertEqual(TerminalMenuItem.resetTerminal.note(chatSending: true), "Not while the agent is sending")
        XCTAssertFalse(TerminalMenuItem.resetTerminal.enabled(chatSending: true))
        XCTAssertTrue(TerminalMenuItem.clearScreen.enabled(chatSending: true))
        XCTAssertEqual(TerminalMenuItem.resetTerminal.symbol, "arrow.counterclockwise")
    }

    /// Search opens the capsule; Paste sends the pasteboard's text; Select all selects (and offers Copy); Clear screen
    /// empties the screen; none of them sends the program anything else.
    func testTheMenusActions() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteTheme)
        let controller = try await makeController(feed)
        let view = controller.hostView
        controller.perform(.search)
        XCTAssertTrue(controller.search.visible)
        controller.closeSearch()
        controller.perform(.selectAll)
        XCTAssertTrue(view.session.locked { view.session.surface.hasSelection })
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.copy(_:)), withSender: nil))
        UIPasteboard.general.string = "echo fictional"
        controller.perform(.paste)
        try await TestSupport.eventually(diagnostic: String(decoding: feed.record.sent, as: UTF8.self)) {
            String(decoding: feed.record.sent, as: UTF8.self) == "echo fictional"
        }
        controller.perform(.clearScreen)
        try await TestSupport.eventually(diagnostic: view.visibleText()) { !view.visibleText().contains("theme.ts") }
        XCTAssertEqual(String(decoding: feed.record.sent, as: UTF8.self), "echo fictional", "Nothing else reached the program")
    }

    /// Reset terminal on a helper's terminal: a new attachment repaints a fully reset terminal from the server (the
    /// alternate screen a program left behind is gone, the screen is back).
    func testResetReattachesAHelperTerminal() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteTheme)
        let controller = try await makeController(feed)
        let view = controller.hostView
        view.session.feed("\u{1B}[?1049h\u{1B}[2Jbroken")
        XCTAssertTrue(view.session.isAlternate)
        controller.openSearch()
        controller.perform(.resetTerminal)
        XCTAssertFalse(controller.search.visible, "Reset ends the search")
        try await TestSupport.eventually { feed.record.attachments.count == 2 }
        XCTAssertEqual(feed.record.detaches, 1)
        try await TestSupport.eventually(diagnostic: view.visibleText()) {
            !view.session.isAlternate && view.visibleText().contains("theme.ts")
        }
    }

    /// Reset terminal waits while Chat sends through the terminal (a reattach would drop the publication the send is
    /// verified against), and a reset starts the server's history position over (herdr reports it again).
    func testResetWaitsForChatAndStartsTheHistoryOver() async throws {
        let feed = ScriptedTerminalFeed(output: TerminalFixtures.viteTheme)
        let controller = try await makeController(feed)
        let presence = controller.presence
        presence.scroll.history(TerminalHistoryPosition(offset: 40, maximum: 400, viewport: 24))
        XCTAssertEqual(presence.scroll.serverOffset, 40)
        let conversation = ChatConversationKey(host: UUID(), node: "tmux:s:$0:%0")
        presence.chat(conversation, sending: true)
        XCTAssertFalse(controller.canReset)
        controller.perform(.resetTerminal)
        XCTAssertEqual(feed.record.detaches, 0, "No reset while the agent is sending")
        XCTAssertEqual(feed.record.attachments.count, 1)
        XCTAssertEqual(presence.scroll.serverOffset, 40)
        presence.chat(conversation, sending: false)
        XCTAssertTrue(controller.canReset)
        controller.perform(.resetTerminal)
        try await TestSupport.eventually { feed.record.attachments.count == 2 }
        XCTAssertEqual(presence.scroll.serverOffset, 0, "The history position starts over")
    }

    /// Reset terminal on a plain shell: the shell is not detached (that would end it); the emulator alone is reset.
    func testResetKeepsAPlainShellAttached() async throws {
        let inner = ScriptedTerminalFeed(output: TerminalFixtures.viteTheme)
        let controller = try await makeController(EndingFeed(inner))
        let view = controller.hostView
        view.session.feed("\u{1B}[?1049hbroken")
        XCTAssertTrue(view.session.isAlternate)
        controller.perform(.resetTerminal)
        XCTAssertFalse(view.session.isAlternate)
        XCTAssertFalse(view.visibleText().contains("theme.ts"), "The history is erased too")
        XCTAssertEqual(inner.record.detaches, 0)
        XCTAssertEqual(inner.record.attachments.count, 1)
        XCTAssertTrue(controller.presence.attached)
    }

    /// The menu bar's Find commands reach the terminal's search: Find… opens it, Find Next and Find Previous step it
    /// (opening it first).
    func testFindCommandsReachTheSearch() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: TerminalFixtures.viteTheme))
        let view = controller.hostView
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.find(_:)), withSender: nil))
        XCTAssertTrue(view.canPerformAction(#selector(UIResponder.findNext(_:)), withSender: nil))
        view.find(nil)
        XCTAssertTrue(controller.search.visible)
        controller.search.update("theme.ts")
        view.findNext(nil)
        XCTAssertEqual(controller.search.count, "2 of 3")
        view.findPrevious(nil)
        XCTAssertEqual(controller.search.count, "1 of 3")
        controller.closeSearch()
        view.findNext(nil)
        XCTAssertTrue(controller.search.visible, "Find Next opens a closed search")
        XCTAssertEqual(controller.search.count, "1 of 3", "on its newest match")
        view.findNext(nil)
        XCTAssertEqual(controller.search.count, "2 of 3", "and the next ⌘G steps")
    }

    /// Opening the search lets the capsule's Ctrl and Alt go: a latch must not modify a key typed after the search.
    func testOpeningTheSearchReleasesTheLatches() async throws {
        let controller = try await makeController(ScriptedTerminalFeed(output: Data()), waitFor: nil)
        controller.tap(.ctrl)
        controller.tap(.alt)
        controller.tap(.alt)
        XCTAssertEqual(controller.capsule.latch(.alt), .locked)
        controller.openSearch()
        XCTAssertEqual(controller.capsule.mods, [])
        XCTAssertEqual(controller.capsule.latch(.ctrl), .off)
        XCTAssertEqual(controller.capsule.latch(.alt), .off)
    }

    /// Typing runs the needle once it pauses, not per keystroke; a step or Return right after typing runs it first.
    func testTypingIsDebounced() async throws {
        let search = TerminalSearch()
        var performed: [String] = []
        search.perform = { performed.append($0) }
        search.open(focus: false)
        for needle in ["t", "th", "the", "theme"] { search.update(needle) }
        XCTAssertTrue(performed.isEmpty, "Nothing while typing")
        XCTAssertTrue(search.waiting)
        try await TestSupport.eventually { !search.waiting }
        XCTAssertEqual(performed, ["search:theme"], "One search, for the last needle")
        performed = []
        search.update("theme.ts")
        search.next()
        XCTAssertEqual(performed, ["search:theme.ts", "navigate_search:next"], "A step runs the waiting needle first")
        XCTAssertFalse(search.waiting)
        performed = []
        search.update("x")
        search.close()
        XCTAssertFalse(search.waiting, "Done drops a waiting needle")
        XCTAssertEqual(performed, ["end_search"])
    }

    /// The search reads the terminal again at most every 24 ms while frames find the viewport changed (Ghostty's
    /// refresh interval, not every frame at up to 120 Hz); a change inside the interval is kept for a frame when it
    /// is due, so the last output is searched.
    func testTheRefreshIsThrottled() {
        var throttle = SearchRefreshThrottle()
        let ms: (UInt64) -> UInt64 = { $0 * 1_000_000 }
        XCTAssertFalse(throttle.frame(at: ms(0), changed: false), "Nothing changed, nothing to read")
        XCTAssertTrue(throttle.frame(at: ms(1), changed: true))
        XCTAssertFalse(throttle.frame(at: ms(9), changed: true), "8 ms later: held back")
        XCTAssertFalse(throttle.frame(at: ms(17), changed: true))
        XCTAssertTrue(throttle.pending)
        XCTAssertEqual(throttle.due, ms(25))
        XCTAssertTrue(throttle.frame(at: ms(25), changed: false), "The held-back change is read when due")
        XCTAssertFalse(throttle.pending)
        XCTAssertNil(throttle.due)
        XCTAssertFalse(throttle.frame(at: ms(30), changed: false))
        // A frame every 8 ms (120 Hz) for a second of output: about 42 refreshes, not 125.
        var refreshes = 0
        for frame in 0..<125 where throttle.frame(at: ms(100 + UInt64(frame) * 8), changed: true) { refreshes += 1 }
        XCTAssertEqual(refreshes, 42)
    }
}

/// A plain shell's feed for the reset rule: a scripted feed whose detach would end the program.
private final class EndingFeed: TerminalFeed {
    let inner: ScriptedTerminalFeed
    init(_ inner: ScriptedTerminalFeed) { self.inner = inner }
    var endsOnDetach: Bool { true }
    var scrollback: TerminalScrollback { .client }
    func attach(_ size: TerminalFeedSize) -> AsyncStream<TerminalFeedEvent> { inner.attach(size) }
    func detach() { inner.detach() }
    func send(_ input: Data) { inner.send(input) }
    func resize(_ size: TerminalFeedSize) { inner.resize(size) }
    func scroll(_ request: TerminalScrollRequest) async -> TerminalScrollResult { await inner.scroll(request) }
    func publish(_ screen: TerminalScreen) { inner.publish(screen) }
}
