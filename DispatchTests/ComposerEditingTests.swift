import AppKit
import XCTest
@testable import DispatchApp

@MainActor final class ComposerEditingTests: XCTestCase {
    private var window: NSWindow!
    private var delegate: ChatComposer.Coordinator!
    private var session: ChatSession!
    private func editor(_ value: String = "") -> ChatComposer.ComposerTextView {
        session = ChatSession(id: System.uuid(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        session.showChat = true; session.draft = value; if value.contains("\n") { session.drafts.edit(multiline: true) }
        delegate = ChatComposer.Coordinator(session)
        let text = ChatComposer.ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        text.isRichText = false; text.allowsUndo = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.session = session; text.delegate = delegate; text.string = value
        text.appliedTheme = .standard; text.font = ChatTheme.standard.typography.reply
        text.setSelectedRange(NSRange(location: value.utf16.count, length: 0))
        window = NSWindow(contentRect: text.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = text; window.makeFirstResponder(text)
        return text
    }
    private func close() { window?.orderOut(nil); window?.contentView = nil; window = nil; delegate = nil; session = nil }
    private func key(_ code: UInt16, _ value: String, _ flags: NSEvent.ModifierFlags = [],
                     ignoringModifiers: String? = nil, timestamp: TimeInterval = 0, repeating: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp, windowNumber: window.windowNumber,
                         context: nil, characters: value, charactersIgnoringModifiers: ignoringModifiers ?? value, isARepeat: repeating, keyCode: code)!
    }
    func testDoubleControlDExitsOnlyWithTwoRecentPressesInAnEmptyComposer() {
        defer { close() }
        let text = editor()
        var exits = 0
        text.exitChat = { exits += 1 }
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10))
        XCTAssertEqual(exits, 0)
        XCTAssertTrue(text.performKeyEquivalent(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10.5)))
        XCTAssertEqual(exits, 1)

        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 20))
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 21.1))
        XCTAssertEqual(exits, 1, "A delayed second press only arms a new confirmation")
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 21.2, repeating: true))
        XCTAssertEqual(exits, 1, "Holding Ctrl+D cannot confirm an exit")
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 21.4))
        XCTAssertEqual(exits, 2)
    }

    func testDoubleControlDResetsWhenTypingOrChangingFocusAndPreservesForwardDelete() {
        defer { close() }
        let text = editor()
        var exits = 0
        text.exitChat = { exits += 1 }
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10))
        text.keyDown(with: key(0, "a", timestamp: 10.1))
        text.keyDown(with: key(51, "\u{7f}", timestamp: 10.2))
        XCTAssertTrue(text.string.isEmpty)
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10.3))
        XCTAssertEqual(exits, 0, "Typing cancels the pending exit")
        window.makeFirstResponder(nil); window.makeFirstResponder(text)
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10.4))
        XCTAssertEqual(exits, 0, "Returning focus requires a fresh pair of presses")

        text.insertText("abc", replacementRange: text.selectedRange())
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10.5))
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10.6))
        XCTAssertEqual(text.string, "c")
        XCTAssertEqual(exits, 0)
        XCTAssertEqual(session.draft, "c")
    }

    func testEscapeLeavesEditorWithoutStoppingOrLosingDraft() {
        defer { close() }
        let text = editor("a\nb")
        var interrupts = 0, exits = 0
        text.interrupt = { _ in interrupts += 1; return true }
        text.exitChat = { exits += 1 }
        text.keyDown(with: key(53, "\u{1b}"))
        XCTAssertEqual(text.string, "a\nb")
        XCTAssertFalse(session.drafts.current.multiline)
        XCTAssertEqual(interrupts, 0)
        XCTAssertTrue(text.performKeyEquivalent(with: key(14, "e", .command)))
        XCTAssertTrue(session.drafts.current.multiline)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 10))
        XCTAssertEqual(text.string, "\nb", "Ctrl+D must retain forward-delete")
        text.selectAll(nil)
        text.insertText("", replacementRange: text.selectedRange())
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 11))
        text.keyDown(with: key(2, "\u{4}", .control, ignoringModifiers: "d", timestamp: 11.5))
        text.keyDown(with: key(53, "\u{1b}"))
        XCTAssertEqual(interrupts, 0)
        XCTAssertEqual(exits, 0)
        XCTAssertFalse(session.drafts.current.multiline)

        session.clearDraft()
        text.keyDown(with: key(53, "\u{1b}"))
        XCTAssertEqual(interrupts, 1, "Compact mode retains Escape to interrupt")
    }

    func testComposerCommandShortcutsAndSidebarDoNotConflict() async throws {
        defer { close() }
        let text = editor("Keep this draft")
        var submitted = 0, help = 0
        text.submit = { submitted += 1 }
        text.showShortcuts = { help += 1 }
        let controller = AppDelegate()
        controller.window = window; controller.workspace.newLocalSpace()
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        controller.buildMenus()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { NSApp.keyWindow === self.window }
        window.makeFirstResponder(text)
        for multiline in [false, true] {
            session.drafts.edit(multiline: multiline)
            XCTAssertTrue(text.performKeyEquivalent(with: key(44, "/", .command)))
            XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", .command)))
            let visible = controller.sidebarVisible
            XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: key(42, "\\", .command)))
            XCTAssertNotEqual(controller.sidebarVisible, visible)
            XCTAssertEqual(session.draft, "Keep this draft")
        }
        XCTAssertEqual(help, 2); XCTAssertEqual(submitted, 2)
        text.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        _ = text.performKeyEquivalent(with: key(44, "/", .command))
        _ = text.performKeyEquivalent(with: key(36, "\r", .command))
        XCTAssertEqual(help, 2); XCTAssertEqual(submitted, 2, "IME composition must not send a draft")
    }

    func testQueueShortcutsFollowSelectionAndRespectDisabledActions() {
        defer { close() }
        let text = editor()
        let selected = ChatQueuedMessage(text: "selected", process: nil)
        let hovered = ChatQueuedMessage(text: "hovered", process: nil)
        session.queuedMessages = [selected, hovered]
        session.selectedQueuedID = selected.id
        session.hoveredQueuedID = hovered.id
        var actions: [(UUID, String)] = []
        text.queueAction = { actions.append(($0, $1)) }
        text.keyDown(with: key(14, "e"))
        XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        XCTAssertEqual(actions.map(\.0), [selected.id, selected.id], "The keyboard's selection, never the hovered row, takes the keys")
        XCTAssertEqual(actions.map(\.1), ["edit", "send"])
        XCTAssertTrue(text.string.isEmpty)

        session.queuedMessages[0].pause = .stopped
        XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        XCTAssertEqual(actions.count, 2, "A paused row's disabled Steer action must not send")
        session.queuedSubmissionID = selected.id
        XCTAssertTrue(text.performKeyEquivalent(with: key(51, "\u{7f}", .command)))
        text.keyDown(with: key(14, "e"))
        XCTAssertEqual(actions.count, 2, "A sending row must not be deleted or edited")
        text.string = ""; session.draft = ""
        text.keyDown(with: key(51, "\u{7f}"))
        XCTAssertEqual(actions.count, 2, "Backspace must not discard a queued message")

        session.selectedQueuedID = selected.id
        text.keyDown(with: key(53, "\u{1b}"))
        XCTAssertNil(session.selectedQueuedID)
    }

    func testQueueHoverLeavesComposerKeysAlone() {
        defer { close() }
        let text = editor()
        let queued = ChatQueuedMessage(text: "queued", process: nil)
        session.queuedMessages = [queued]
        session.hoveredQueuedID = queued.id
        var actions: [(UUID, String)] = []
        var sends = 0
        text.queueAction = { actions.append(($0, $1)) }
        text.sendNow = { sends += 1 }
        // A row under the pointer shows its buttons; the keys stay the composer's.
        XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        XCTAssertEqual(sends, 1)
        text.keyDown(with: key(14, "e"))
        XCTAssertEqual(text.string, "e", "Typing a message that starts with e must not edit the hovered row")
        text.string = ""; session.draft = ""
        _ = text.performKeyEquivalent(with: key(51, "\u{7f}", .command))
        XCTAssertTrue(actions.isEmpty, "⌘⌫ must not delete the hovered row")

        session.selectedQueuedID = queued.id
        XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        text.keyDown(with: key(14, "e"))
        XCTAssertTrue(text.string.isEmpty)
        XCTAssertEqual(actions.map(\.1), ["send", "edit"])
    }

    /// While the agent works, Esc twice stops it in editor mode as out of it; idle, Esc leaves editor mode.
    func testEscapeStopsTheAgentInEditorModeAndLeavesEditorModeWhenIdle() {
        defer { close() }
        let text = editor("first\nsecond")
        var stops = 0, working = true
        text.canStop = { working }
        text.interrupt = { _ in stops += 1; return true }
        XCTAssertTrue(text.performKeyEquivalent(with: key(53, "\u{1b}", timestamp: 1)))
        text.keyDown(with: key(53, "\u{1b}", timestamp: 1.4))
        XCTAssertEqual(stops, 2)
        XCTAssertTrue(session.drafts.current.multiline, "Stopping must not leave editor mode")
        working = false
        XCTAssertTrue(text.performKeyEquivalent(with: key(53, "\u{1b}", timestamp: 3)))
        XCTAssertEqual(stops, 2)
        XCTAssertFalse(session.drafts.current.multiline)
        XCTAssertEqual(session.draft, "first\nsecond")
    }

    func testQueueSelectionDoesNotCaptureDraftNavigationOrSending() {
        defer { close() }
        let text = editor("first\nsecond\nthird")
        let queued = ChatQueuedMessage(text: "queued", process: nil)
        session.queuedMessages = [queued]
        session.selectedQueuedID = queued.id
        session.hoveredQueuedID = queued.id
        var actions = 0, sends = 0
        text.queueAction = { _, _ in actions += 1 }
        text.sendNow = { sends += 1 }
        for (code, character): (UInt16, Int) in [(126, NSUpArrowFunctionKey), (125, NSDownArrowFunctionKey)] {
            text.setSelectedRange(NSRange(location: 8, length: 0))
            text.keyDown(with: key(code, String(UnicodeScalar(character)!)))
            XCTAssertNotEqual(text.selectedRange().location, 8)
        }
        XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        XCTAssertEqual(sends, 1)
        text.selectAll(nil)
        text.insertText("", replacementRange: text.selectedRange())
        XCTAssertTrue(session.drafts.current.multiline)
        session.selectedQueuedID = nil
        text.keyDown(with: key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        XCTAssertNil(session.selectedQueuedID, "Empty multiline drafts must retain editor navigation")
        session.selectedQueuedID = queued.id
        XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(actions, 0)
    }

    func testBackspaceNeverDiscardsHoveredOrSelectedQueueRows() {
        defer { close() }
        let text = editor("code\nline")
        let queued = ChatQueuedMessage(text: "queued", process: nil)
        session.queuedMessages = [queued]
        var actions = 0
        text.queueAction = { _, _ in actions += 1 }
        for hover in [true, false] {
            text.selectAll(nil)
            text.insertText("code\nline", replacementRange: text.selectedRange())
            session.hoveredQueuedID = hover ? queued.id : nil
            session.selectedQueuedID = queued.id
            text.keyDown(with: key(51, "\u{7f}"))
            XCTAssertEqual(text.string, "code\nlin")
            text.selectAll(nil)
            text.keyDown(with: key(51, "\u{7f}"))
            XCTAssertTrue(text.string.isEmpty)
            session.selectedQueuedID = queued.id
            text.keyDown(with: key(51, "\u{7f}", repeating: true))
            text.keyDown(with: key(51, "\u{7f}"))
            XCTAssertEqual(actions, 0)
        }
        session.drafts.edit(multiline: false)
        session.hoveredQueuedID = queued.id
        session.selectedQueuedID = queued.id
        text.keyDown(with: key(51, "\u{7f}", repeating: true))
        text.keyDown(with: key(51, "\u{7f}"))
        XCTAssertEqual(actions, 0, "An empty compact composer must not discard queued messages either")
    }

    func testOptionReturnInsertsAnUndoableNewlineEvenWithAQueuedMessageSelected() {
        defer { close() }
        let text = editor()
        let queued = ChatQueuedMessage(text: "queued", process: nil)
        session.queuedMessages = [queued]
        var sends = 0, actions = 0
        text.submit = { sends += 1 }; text.sendNow = { sends += 1 }
        text.queueAction = { _, _ in actions += 1 }
        for multiline in [false, true] {
            for code: UInt16 in [36, 76] {
                for equivalent in [false, true] {
                    session.drafts.edit(multiline: multiline)
                    session.selectedQueuedID = queued.id; session.hoveredQueuedID = queued.id
                    let event = key(code, "\r", .option)
                    if equivalent { XCTAssertTrue(text.performKeyEquivalent(with: event)) }
                    else { text.keyDown(with: event) }
                    XCTAssertEqual(session.draft, "\n")
                    XCTAssertEqual(session.drafts.current.multiline, multiline)
                    XCTAssertEqual(sends, 0); XCTAssertEqual(actions, 0)
                    text.undoManager?.undo()
                    XCTAssertEqual(text.string, "")
                    XCTAssertEqual(session.draft, "")
                }
            }
        }
    }

    func testCommandOptionReturnSendsFromEitherEditorModeAndRespectsComposition() {
        defer { close() }
        let text = editor("draft")
        var sends = 0, alternates = 0
        text.submit = { sends += 1 }; text.sendNow = { alternates += 1 }
        for multiline in [false, true] {
            session.drafts.edit(multiline: multiline)
            text.keyDown(with: key(76, "\r", [.command, .option]))
            XCTAssertTrue(text.performKeyEquivalent(with: key(36, "\r", [.command, .option])))
        }
        XCTAssertEqual(alternates, 4); XCTAssertEqual(sends, 0)
        XCTAssertEqual(text.string, "draft")
        text.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        _ = text.performKeyEquivalent(with: key(36, "\r", [.command, .option]))
        XCTAssertEqual(alternates, 4, "Confirming an input method must not send")
    }

    func testReturnKeypadAndStickyMultiline() {
        defer { close() }
        let text = editor("compact")
        var submits = 0
        text.submit = { submits += 1 }
        text.keyDown(with: key(36, "\r")); text.keyDown(with: key(76, "\r"))
        XCTAssertEqual(submits, 2)
        text.keyDown(with: key(76, "\r", .shift))
        XCTAssertEqual(session.draft, "compact\n"); XCTAssertFalse(session.drafts.current.multiline, "⇧⏎ adds a line, no editor mode")
        text.keyDown(with: key(36, "\r")); XCTAssertEqual(submits, 3, "Return still sends")
        XCTAssertTrue(text.performKeyEquivalent(with: key(14, "e", .command))); XCTAssertTrue(session.drafts.current.multiline)
        text.keyDown(with: key(36, "\r")); XCTAssertEqual(session.draft, "compact\n\n")
        text.keyDown(with: key(76, "\r", .control)); XCTAssertEqual(submits, 4)
        text.selectAll(nil); text.insertText("single", replacementRange: text.selectedRange())
        XCTAssertTrue(session.drafts.current.multiline)
        text.keyDown(with: key(36, "\r")); XCTAssertEqual(session.draft, "single\n")
        session.drafts.keep(); XCTAssertFalse(session.drafts.current.multiline)
    }
    func testTabIndentsSelectionAndNeverQueues() {
        defer { close() }
        let text = editor("a\n  b\nlast")
        var submits = 0; text.submit = { submits += 1 }
        text.setSelectedRange(NSRange(location: 0, length: 6))
        text.keyDown(with: key(48, "\t"))
        XCTAssertEqual(text.string, "    a\n      b\nlast")
        text.keyDown(with: key(48, "\t", .shift))
        XCTAssertEqual(text.string, "a\n  b\nlast")
        text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
        text.keyDown(with: key(48, "\t")); XCTAssertTrue(text.string.hasSuffix("last    "))
        XCTAssertEqual(submits, 0)
    }
    func testMultilineSlashBangAndOptionCharactersUseTextEditing() {
        defer { close() }
        let text = editor()
        session.drafts.edit(multiline: true)
        var picked = 0, submitted = 0
        text.pickModel = { _, _ in picked += 1 }; text.submit = { submitted += 1 }
        text.keyDown(with: key(44, "/"))
        XCTAssertEqual(text.string, "/")
        XCTAssertTrue(session.draftIsCommand, "one line is a command in editor mode too")
        text.keyDown(with: key(18, "!", .shift))
        text.keyDown(with: key(46, "µ", .option))
        XCTAssertEqual(text.string, "/!µ")
        XCTAssertEqual(picked, 0); XCTAssertEqual(submitted, 0)
        for flags: NSEvent.ModifierFlags in [.option, [.option, .shift]] {
            XCTAssertFalse(text.performKeyEquivalent(with: key(14, "e", flags)))
        }
        session.clearDraft()
        text.keyDown(with: key(46, "µ", .option))
        XCTAssertTrue(text.string.hasSuffix("µµ"), "Compact mode types Option characters too")
        XCTAssertEqual(picked, 0)
        XCTAssertTrue(text.performKeyEquivalent(with: key(46, "M", [.command, .shift])))
        XCTAssertEqual(picked, 1, "Compact mode retains the model shortcut")
    }
    func testCommandArrowsMoveAndSelectTextThroughApplicationMenus() async throws {
        defer { close() }
        let text = editor("first\nsecond\nthird")
        let controller = AppDelegate(), workspace = controller.workspace
        controller.window = window
        workspace.newSpace(); workspace.newTab(); workspace.newSpace(); workspace.newTab()
        let tab = workspace.activeTab?.id, space = workspace.selectedSpace
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        controller.buildMenus()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { NSApp.keyWindow === self.window }
        window.makeFirstResponder(text)
        for (code, character, end): (UInt16, Int, Int) in [
            (123, NSLeftArrowFunctionKey, 6), (124, NSRightArrowFunctionKey, 12),
            (126, NSUpArrowFunctionKey, 0), (125, NSDownArrowFunctionKey, 18)
        ] {
            for shift in [false, true] {
                text.setSelectedRange(NSRange(location: 8, length: 0))
                let event = key(code, String(UnicodeScalar(character)!), shift ? [.command, .shift] : .command)
                XCTAssertFalse(NSApp.mainMenu!.performKeyEquivalent(with: event), "The menu must defer to the composer")
                NSApp.sendEvent(event)
                XCTAssertEqual(text.selectedRange(), shift ? NSRange(location: min(8, end), length: abs(end - 8)) : NSRange(location: end, length: 0))
                XCTAssertEqual(workspace.activeTab?.id, tab); XCTAssertEqual(workspace.selectedSpace, space)
                XCTAssertTrue(window.firstResponder === text)
            }
        }
    }
    func testMultilineEditorShortcutsTakePrecedenceOverApplicationMenus() async throws {
        defer { close() }
        let text = editor("first\nsecond")
        let controller = AppDelegate(), workspace = controller.workspace
        controller.window = window
        workspace.newSpace(); workspace.newTab(); workspace.newSpace(); workspace.newTab()
        let tab = workspace.activeTab?.id, space = workspace.selectedSpace
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        controller.buildMenus()
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { NSApp.keyWindow === self.window }
        window.makeFirstResponder(text)
        for (code, character): (UInt16, String) in [(2, "d"), (44, "/"), (35, "p"), (33, "["), (30, "]")] {
            for shift in [false, true] {
                let event = key(code, character, shift ? [.command, .shift] : .command)
                XCTAssertFalse(NSApp.mainMenu!.performKeyEquivalent(with: event))
                NSApp.sendEvent(event)
                XCTAssertEqual(workspace.activeTab?.id, tab)
                XCTAssertEqual(workspace.selectedSpace, space)
                XCTAssertTrue(window.firstResponder === text)
            }
        }
        XCTAssertEqual(text.string, "first\n    second", "Only Cmd+] should change this draft")
        NSApp.sendEvent(key(33, "[", .command))
        XCTAssertEqual(text.string, "first\nsecond")
        session.clearDraft()
        XCTAssertFalse(text.reservesMultilineShortcut(keyCode: 2, modifiers: .command))
    }

    func testPasteAndMarkedTextDoNotCompleteBracketsOrSubmit() {
        defer { close() }
        let text = editor("```swift\n")
        text.insertText("({\n[", replacementRange: text.selectedRange())
        XCTAssertEqual(text.string, "```swift\n({\n[")
        XCTAssertTrue(session.drafts.current.multiline); XCTAssertTrue(text.automaticPairs.isEmpty)
        text.setMarkedText("仮(", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        XCTAssertTrue(text.hasMarkedText())
        let before = text.string
        text.highlight(); XCTAssertEqual(text.string, before)
        var submits = 0; text.submit = { submits += 1 }
        text.keyDown(with: key(36, "\r"))
        XCTAssertEqual(submits, 0)
        text.unmarkText()
        XCTAssertTrue(text.automaticPairs.isEmpty)
    }
    func testBracketsSurroundUnicodeSkipCloserDeleteAndUndo() throws {
        defer { close() }
        let text = editor("```swift\nλ😀\n```")
        text.setSelectedRange(NSRange(location: 9, length: 3))
        XCTAssertTrue(text.completeBracket("{"))
        XCTAssertEqual(text.string, "```swift\n{λ😀}\n```")
        XCTAssertEqual(text.selectedRange(), NSRange(location: 10, length: 3))
        text.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertTrue(text.completeBracket("}")); XCTAssertEqual(text.selectedRange().location, 14)
        text.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertTrue(text.completeBracket("(")); XCTAssertTrue(text.deleteEmptyPair())
        XCTAssertEqual(text.string, "```swift\n{λ😀}\n```")
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(text.completeBracket("["))
        text.setSelectedRange(NSRange(location: 8, length: 5))
        XCTAssertFalse(text.completeBracket("["))
        text.setSelectedRange(NSRange(location: 10, length: 0))
        let previous = text.string
        let undo = try XCTUnwrap(text.undoManager)
        undo.removeAllActions()
        undo.beginUndoGrouping(); XCTAssertTrue(text.completeBracket("[")); undo.endUndoGrouping()
        text.highlight(); undo.undo()
        XCTAssertEqual(text.string, previous)
        undo.redo(); XCTAssertTrue(text.string.contains("[]λ😀"))
        XCTAssertTrue(text.completeBracket("]"), "Redo restores automatic closer tracking: \(text.automaticPairs), selection \(text.selectedRange())")
    }
    func testSaveShortcutKeepsDraftAndOpensFreshBuffer() {
        defer { close() }
        let text = editor("first\nsecond")
        let draft = session.drafts.current, generation = session.drafts.editorGeneration
        text.keyDown(with: key(1, "s", .command))
        XCTAssertEqual(session.drafts.saved, [draft])
        XCTAssertTrue(session.drafts.current.isEmpty)
        XCTAssertNotEqual(session.drafts.editorGeneration, generation)
        XCTAssertTrue(text.performKeyEquivalent(with: key(1, "s", .command)))
        XCTAssertEqual(session.drafts.saved.count, 1, "Saving an empty buffer does not create another draft")
        session.draft = "next draft"
        XCTAssertTrue(text.performKeyEquivalent(with: key(1, "s", .command)))
        XCTAssertEqual(session.drafts.saved.map(\.text), ["first\nsecond", "next draft"])
        XCTAssertTrue(session.drafts.current.isEmpty)
    }
    func testOptionArrowsMoveInTextWithoutSwitchingDrafts() {
        defer { close() }
        let text = editor("saved")
        session.drafts.keep()
        text.selectAll(nil)
        text.insertText("first\nsecond\nthird", replacementRange: text.selectedRange())
        let draftID = session.drafts.current.id
        for (code, character): (UInt16, Int) in [(126, NSUpArrowFunctionKey), (125, NSDownArrowFunctionKey)] {
            text.setSelectedRange(NSRange(location: 8, length: 0))
            text.keyDown(with: key(code, String(UnicodeScalar(character)!), .option))
            XCTAssertNotEqual(text.selectedRange().location, 8)
            XCTAssertEqual(session.drafts.current.id, draftID)
            XCTAssertEqual(session.draft, "first\nsecond\nthird")
            XCTAssertEqual(session.drafts.saved.map(\.text), ["saved"])
        }
    }
    func testChatFontScalingKeepsComposerCodeAtSelectedSize() throws {
        defer { close() }
        let text = editor("Prose\n```swift\nlet x = 12\n```\nMore prose")
        var preferences = Preferences()
        preferences.fontSize = 14
        preferences.chatFont = .comicSans
        var theme = ChatTheme.standard
        theme.typography = ChatTypography(preferences: preferences)
        text.appliedTheme = theme
        text.highlight()
        let storage = try XCTUnwrap(text.textStorage)
        let prose = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let code = try XCTUnwrap(storage.attribute(.font, at: 16, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(prose.fontName, "ComicSansMS")
        XCTAssertEqual(prose.pointSize, 15 * preferences.chatFont.sizeScale, accuracy: 0.001)
        XCTAssertEqual(code.fontName, "SourceCodePro-Regular")
        XCTAssertEqual(code.pointSize, 15, accuracy: 0.001)
        preferences.chatFont = .sameAsCode
        theme.typography = ChatTypography(preferences: preferences)
        text.appliedTheme = theme
        text.highlight()
        let restored = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(restored, code)
    }

    func testFenceRangesAliasesThemesAndBoundedFallback() throws {
        let source = "😀 prose\n  ~~~~ts\nconst x = 12\n~~~\n~~~~\n```python\nprint('λ')"
        let fences = ComposerFence.scan(source)
        XCTAssertEqual(fences.count, 2)
        XCTAssertEqual((source as NSString).substring(with: fences[0].opening), "  ~~~~ts\n")
        XCTAssertEqual((source as NSString).substring(with: fences[0].body), "const x = 12\n~~~\n")
        XCTAssertNotNil(fences[0].closing); XCTAssertNil(fences[1].closing)
        XCTAssertTrue(fences[1].contains(NSRange(location: source.utf16.count, length: 0)))
        XCTAssertEqual(SyntaxHighlight.language(fences[0].language), "typescript")
        let tokens = SyntaxHighlight.tokens("const λ = 12", language: "ts")
        XCTAssertEqual(tokens.map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 10, length: 2)])
        XCTAssertTrue(SyntaxHighlight.tokens(String(repeating: "const x = 1;", count: 6000), language: "js").isEmpty)
        XCTAssertTrue(SyntaxHighlight.tokens("let x = 1", language: "unrecognized").isEmpty)
        defer { close() }
        let text = editor("```swift\nlet x = 12\n```")
        text.highlight()
        let selected = text.selectedRange(), content = text.string
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor, NSColor(ChatTheme.standard.keyword))
        var theme = ChatTheme.standard; theme.typography.codeFontName = "Menlo-Regular"
        text.appliedTheme = theme; text.highlight()
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 9, effectiveRange: nil) as? NSFont)?.fontName, "Menlo-Regular")
        XCTAssertEqual(text.string, content); XCTAssertEqual(text.selectedRange(), selected)
    }

    /// ⌘V and drops read the pasteboard in one place (ComposerTextView.readSelection): image data and Finder's files
    /// become attachments, a files view's rows type their quoted host paths, and text pastes as text.
    func testPasteOfImageDataOrFilesAttachesAndTextStaysText() throws {
        defer { close() }
        let text = editor()
        var attached: [[ChatAttachmentSource]] = [], chosen = 0
        text.canAttach = { true }
        text.attach = { attached.append($0) }
        text.chooseAttachments = { _ in chosen += 1 }
        let board = NSPasteboard(name: .init("dispatch-test-" + System.uuid().uuidString))
        defer { board.releaseGlobally() }
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))

        board.clearContents(); board.setData(png, forType: .png)
        XCTAssertTrue(text.readSelection(from: board, type: .png))
        XCTAssertEqual(attached.last, [.data(name: "Pasted image.png", png)], "A screenshot on the clipboard")
        XCTAssertEqual(text.string, "")

        let url = System.temporary.appendingPathComponent("Example notes.txt")
        board.clearContents(); board.writeObjects([url as NSURL])
        XCTAssertTrue(text.readSelection(from: board, type: .fileURL))
        XCTAssertEqual(attached.last, [.file(url)], "A file copied in Finder")
        XCTAssertEqual(text.string, "")

        // Copied cells carry a picture of themselves too: they paste as text.
        board.clearContents(); board.declareTypes([.string, .png], owner: nil)
        board.setString("cells", forType: .string); board.setData(png, forType: .png)
        XCTAssertTrue(text.readSelection(from: board, type: .string))
        XCTAssertEqual(text.string, "cells")
        XCTAssertEqual(attached.count, 2)

        // A files view's row is already on a host: its path is typed, quoted.
        board.clearContents()
        board.writeObjects([FilesDragController.localItem(FilesDragPayload(endpoint: .local, session: System.uuid(), paths: ["/srv/example/log book.txt"]))])
        XCTAssertTrue(text.readSelection(from: board, type: .filesPaths))
        XCTAssertEqual(text.string, "cells/srv/example/log\\ book.txt")
        XCTAssertEqual(attached.count, 2)
        XCTAssertEqual(session.draft, text.string)

        // Without attachments (a command, an older helper) the text view keeps its own paste.
        text.canAttach = { false }
        board.clearContents(); board.setData(png, forType: .png)
        _ = text.readSelection(from: board, type: .png)
        XCTAssertEqual(attached.count, 2)

        let shortcut = key(0, "A", [.command, .shift], ignoringModifiers: "a")
        XCTAssertFalse(text.performKeyEquivalent(with: shortcut), "No open panel without attachments")
        text.canAttach = { true }
        XCTAssertTrue(text.performKeyEquivalent(with: shortcut))
        XCTAssertEqual(chosen, 1)
    }
}

extension ComposerEditingTests {
    /// Editor mode comes from ⌘E, a multi-line paste or Settings' default, never from a typed line; a one-line command
    /// still runs from it with Return.
    func testAPasteOfLinesEntersEditorModeAndReturnStillSendsACommand() throws {
        defer { close() }
        let text = editor()
        var submits = 0; text.submit = { submits += 1 }
        let board = NSPasteboard(name: .init("dispatch-test-" + System.uuid().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents(); board.setString("one line", forType: .string)
        XCTAssertTrue(text.readSelection(from: board, type: .string))
        XCTAssertFalse(session.drafts.current.multiline, "a one-line paste keeps single-line mode")
        board.clearContents(); board.setString("\nfirst\nsecond", forType: .string)
        XCTAssertTrue(text.readSelection(from: board, type: .string))
        XCTAssertEqual(session.draft, "one line\nfirst\nsecond")
        XCTAssertTrue(session.drafts.current.multiline, "a multi-line paste enters editor mode")
        XCTAssertFalse(session.draftIsCommand)

        text.selectAll(nil); text.insertText("/compact", replacementRange: text.selectedRange())
        XCTAssertTrue(session.drafts.current.multiline)
        XCTAssertTrue(session.draftIsCommand)
        text.keyDown(with: key(36, "\r"))
        XCTAssertEqual(submits, 1, "Return sends a one-line command in editor mode")
        XCTAssertEqual(session.draft, "/compact")
    }
}
