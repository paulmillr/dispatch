import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor final class ChatSideComposerTests: XCTestCase {
    private func mount(_ side: ChatSideConversation, close: @escaping () -> Void = {}) async throws
        -> (NSWindow, ChatSideComposer.SideTextView) {
        try DesktopTestSupport.requireUnlocked()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatSideSheet(side: side, close: close, maximumHeight: 360))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        do {
            try await TestSupport.eventually { window.isKeyWindow && window.firstResponder is ChatSideComposer.SideTextView }
            return (window, try XCTUnwrap(window.firstResponder as? ChatSideComposer.SideTextView))
        } catch {
            window.contentView = nil; window.close()
            throw error
        }
    }

    private func checkCaret(_ editor: ChatSideComposer.SideTextView, in window: NSWindow, line: UInt = #line) async throws {
        editor.scrollRangeToVisible(editor.selectedRange())
        try await TestSupport.eventually(line: line) { editor.caretTimer != nil && editor.caretOn }
        window.contentView?.layoutSubtreeIfNeeded()
        editor.displayIfNeeded()
        let native = editor.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)), from: nil)
        XCTAssertFalse(editor.shouldDrawInsertionPoint, line: line)
        XCTAssertEqual(editor.caretRect.minX, native.minX, accuracy: 1 / window.backingScaleFactor, line: line)
        XCTAssertEqual(editor.caretRect.minY, native.minY, accuracy: 1 / window.backingScaleFactor, line: line)
        XCTAssertEqual(editor.caretRect.height, native.height, accuracy: 1 / window.backingScaleFactor, line: line)
        XCTAssertEqual(editor.caretRect.width, 1, line: line)
    }

    func testSideComposerUsesLocalCaretThroughEditingIMEAndFocusChanges() async throws {
        let side = ChatSideConversation(mode: .side, parentID: "parent", agentID: "codex", model: "fixture")
        side.ready = true
        let (window, editor) = try await mount(side)
        defer { window.contentView = nil; window.close(); side.close() }
        try await checkCaret(editor, in: window)
        try await TestSupport.eventually { !editor.caretOn }
        try await TestSupport.eventually { editor.caretOn }
        for text in ["Emoji 👩🏽‍💻 日本語", "first\nsecond\n", String(repeating: "wrapped text ", count: 50)] {
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            XCTAssertEqual(side.draft, text)
            try await checkCaret(editor, in: window)
        }
        window.setContentSize(NSSize(width: 360, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        try await checkCaret(editor, in: window)
        editor.setSelectedRange(NSRange(location: 2, length: 4))
        XCTAssertNil(editor.caretTimer)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        try await checkCaret(editor, in: window)
        editor.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        try await checkCaret(editor, in: window)
        editor.insertText("入力", replacementRange: editor.markedRange())
        XCTAssertFalse(editor.hasMarkedText())
        try await checkCaret(editor, in: window)
        window.makeFirstResponder(nil)
        XCTAssertNil(editor.caretTimer)
        window.makeFirstResponder(editor)
        try await checkCaret(editor, in: window)
        let timer = try XCTUnwrap(editor.caretTimer)
        window.contentView = nil
        XCTAssertNil(editor.caretTimer)
        XCTAssertFalse(timer.isValid)
    }

    func testMultilineSideKeyboardProtectionThroughAppKit() async throws {
        let side = ChatSideConversation(mode: .side, parentID: "parent", agentID: "codex", model: "fixture")
        side.ready = true; side.draft = "first\nsecond"
        var closes = 0, sends = 0
        let (window, editor) = try await mount(side, close: { closes += 1 })
        defer { window.contentView = nil; window.close(); side.close() }
        let controller = AppDelegate()
        controller.window = window
        controller.workspace.newSpace(); controller.workspace.newTab()
        let tab = controller.workspace.activeTab?.id
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        controller.buildMenus()
        editor.submit = { sends += 1 }; editor.sendNow = { sends += 1 }
        func key(_ code: UInt16, _ value: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            TerminalTestSupport.keyEvent(code, value, in: window, modifiers: flags)
        }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        for event in [key(53, "\u{1b}"), key(1, "s", .command), key(2, "d", .command),
                      key(44, "/", .command), key(35, "p", .command)] {
            NSApp.sendEvent(event)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(side.draft, "first\nsecond")
        }
        XCTAssertEqual(controller.workspace.activeTab?.id, tab)
        XCTAssertEqual(closes, 0)
        NSApp.sendEvent(key(30, "]", .command))
        XCTAssertEqual(side.draft, "first\n    second")
        NSApp.sendEvent(key(33, "[", .command))
        XCTAssertEqual(side.draft, "first\nsecond")
        NSApp.sendEvent(key(36, "\r"))
        NSApp.sendEvent(key(76, "\r", .shift))
        XCTAssertEqual(side.draft, "first\nsecond\n\n")
        XCTAssertEqual(sends, 0)
        NSApp.sendEvent(key(36, "\n", .control))
        NSApp.sendEvent(key(76, "\r", .option))
        XCTAssertEqual(sends, 2)
        editor.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        NSApp.sendEvent(key(36, "\r"))
        XCTAssertEqual(sends, 2, "IME confirmation must not submit")
        editor.unmarkText()
        editor.selectAll(nil); editor.insertText("", replacementRange: editor.selectedRange())
        XCTAssertTrue(side.draftMultiline)
        NSApp.sendEvent(key(2, "\u{4}", .control))
        NSApp.sendEvent(key(2, "\u{4}", .control))
        NSApp.sendEvent(key(53, "\u{1b}"))
        XCTAssertEqual(closes, 0)
    }

    func testSideDraftSelectionAndHeightSurviveUpdatesAndQuestionRemount() async throws {
        let side = ChatSideConversation(mode: .btw, parentID: "parent", agentID: "codex", model: "fixture")
        side.ready = true
        let (window, editor) = try await mount(side)
        defer { window.contentView = nil; window.close(); side.close() }
        let value = String(repeating: "code line\n", count: 40)
        editor.insertText(value, replacementRange: editor.selectedRange())
        let selection = NSRange(location: 12, length: 4)
        editor.setSelectedRange(selection)
        try await TestSupport.eventually { side.composerHeight > 300 }
        XCTAssertLessThan(editor.enclosingScrollView?.frame.height ?? 1000, 160)
        side.busy = true
        side.messages.append(.init(id: "reply", user: false, text: "Streaming reply"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.string, value)
        side.permission = .init(title: "Allow?", operation: "{}", language: "json")
        try await TestSupport.eventually { editor.window == nil }
        XCTAssertNil(editor.caretTimer)
        side.permission = nil
        try await TestSupport.eventually { window.firstResponder is ChatSideComposer.SideTextView }
        let restored = try XCTUnwrap(window.firstResponder as? ChatSideComposer.SideTextView)
        XCTAssertFalse(restored === editor)
        XCTAssertEqual(restored.string, value)
        XCTAssertEqual(restored.selectedRange(), selection)
        XCTAssertTrue(restored.multiline)
    }
}
