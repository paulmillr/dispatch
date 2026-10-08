import SwiftUI
import AppKit

struct ChatComposer: NSViewRepresentable {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    let focused: Bool
    let submit: () -> Void
    var interrupt: (() -> Bool)?
    var exitChat: (() -> Void)?
    var exitPrompt: (() -> String)?
    var pickModel: ((ChatModelPicker.Column, Bool) -> Void)?
    var workspace: Workspace?
    var sendNow: (() -> Void)?
    var queueAction: ((UUID, String) -> Void)?
    var optionChanged: ((Bool) -> Void)?
    var showShortcuts: (() -> Void)?
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // TextKit 1 from the start: measure() and the code bands use the layout manager, and reading
        // it would switch a TextKit 2 view at runtime. Without the font's leading: TextKit adds it to
        // typed lines but not to the empty editor's line, so the composer
        // grew and the caret jumped on the first character.
        let text = ComposerTextView(usingTextLayoutManager: false)
        text.layoutManager?.usesFontLeading = false
        text.allowsUndo = true
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = theme.typography.reply
        text.textContainerInset = NSSize(width: 12, height: 5)
        text.textContainer?.lineFragmentPadding = 0
        text.textColor = NSColor(theme.ink); text.backgroundColor = .clear; text.drawsBackground = false
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.delegate = context.coordinator; text.submit = submit; text.pickModel = pickModel
        text.interrupt = interrupt; text.exitChat = exitChat; text.exitPrompt = exitPrompt
        text.sendNow = sendNow; text.queueAction = queueAction; text.showShortcuts = showShortcuts
        text.session = session
        configureFocus(text)
        text.setAccessibilityLabel("Message agent")
        text.setAccessibilityIdentifier("chat-composer-\(session.id)")
        scroll.documentView = text; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        context.coordinator.optionChanged = optionChanged
        context.coordinator.modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak text, weak coordinator = context.coordinator] event in
            guard let text, let window = text.window,
                  event.window === window || (event.window == nil && window.isKeyWindow) else { return event }
            coordinator?.optionChanged?(event.modifierFlags.contains(.option))
            return event
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.optionChanged = optionChanged
        guard let text = scroll.documentView as? ComposerTextView else { return }
        let drafts = session.drafts
        // The editor's own keystrokes are already in it; observe only changes made elsewhere.
        _ = drafts.externalRevision
        let draft = drafts.editorDraft
        var revealRestoredSelection = false
        let switched = text.editorGeneration != drafts.editorGeneration
        if switched || !text.hasMarkedText() {
            if switched || text.string != draft.text {
                text.resetExitShortcut()
                text.applyingState = true
                if switched && text.hasMarkedText() {
                    text.inputContext?.discardMarkedText()
                    text.unmarkText()
                }
                text.string = draft.text
                let selection = draft.selection
                let location = min(selection.location, text.string.utf16.count)
                text.setSelectedRange(NSRange(location: location, length: min(selection.length, text.string.utf16.count - location)))
                if switched { text.undoManager?.removeAllActions(); text.automaticPairs = [] }
                revealRestoredSelection = switched
                text.editorGeneration = drafts.editorGeneration
                text.applyingState = false
            }
        }
        if text.appliedTheme?.typography != theme.typography {
            text.font = theme.typography.reply
        }
        if text.appliedTheme != theme {
            text.textColor = NSColor(theme.ink); text.insertionPointColor = NSColor(theme.ink)
            text.placeholderColor = NSColor(theme.muted)
            text.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection), .foregroundColor: NSColor(theme.selectedText)]
            text.appliedTheme = theme
        }
        let placeholder = TerminalRuntime.shared.chat.placeholder(session)
        text.placeholder = placeholder
        text.highlight()
        text.measure()
        if revealRestoredSelection { text.scrollRangeToVisible(text.selectedRange()) }
        // Edits redraw what they change. This runs on every keystroke, so redraw the whole editor only for
        // what draw() shows besides the text: the placeholder and its colors.
        let drawn = Coordinator.Drawn(placeholder: placeholder, empty: text.string.isEmpty, theme: theme)
        if context.coordinator.drawn != drawn {
            context.coordinator.drawn = drawn
            text.needsDisplay = true
        }
        text.submit = submit; text.pickModel = pickModel
        text.interrupt = interrupt; text.exitChat = exitChat; text.exitPrompt = exitPrompt
        text.sendNow = sendNow; text.queueAction = queueAction; text.showShortcuts = showShortcuts
        text.session = session
        configureFocus(text)
        let canFocus = focused && text.canAcceptFocus()
        if !canFocus {
            text.pendingFocus = false
            if text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        }
        if canFocus && (context.coordinator.focusRequest != session.focusRequest || !context.coordinator.wasFocused) {
            context.coordinator.focusRequest = session.focusRequest
            text.pendingFocus = true
            DispatchQueue.main.async { text.fulfillFocusRequest() }
        }
        context.coordinator.wasFocused = canFocus
    }
    private func configureFocus(_ text: ComposerTextView) {
        text.canAcceptFocus = {
            // A blocking question or question card takes the input; optional questions leave it to the draft.
            guard session.showChat, !session.waitingForAnswer else { return false }
            guard let workspace else { return true }
            return workspace.isSurfacePresented(session.id)
        }
        text.canFulfillFocus = { workspace == nil || workspace?.activeSurfaceID == session.id }
        text.didFocus = {
            (workspace ?? TerminalRuntime.shared.workspace)?.selectSurface(session.id)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let monitor = coordinator.modifierMonitor { NSEvent.removeMonitor(monitor) }
        coordinator.modifierMonitor = nil
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: ChatSession
        var optionChanged: ((Bool) -> Void)?
        var modifierMonitor: Any?
        var focusRequest: UUID?
        var wasFocused = false
        struct Drawn: Equatable { let placeholder: String, empty: Bool, theme: ChatTheme }
        var drawn: Drawn?
        init(_ session: ChatSession) { self.session = session }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? ComposerTextView, !text.applyingState else { return }
            session.drafts.edit(text: text.string, selection: text.selectedRange(), fromEditor: true); session.lastInputAt = Date()
            if !text.hasMarkedText() { text.highlight() }
            text.measure()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? ComposerTextView, !text.applyingState, !text.hasMarkedText() else { return }
            session.drafts.edit(selection: text.selectedRange(), fromEditor: true)
        }
    }
    class ComposerTextView: ChatEditorTextView {
        weak var session: ChatSession?
        var editorGeneration: UUID?
        var interrupt: (() -> Bool)?
        var exitChat: (() -> Void)?
        var exitPrompt: (() -> String)?
        private var exitArmedAt: TimeInterval?
        var queueAction: ((UUID, String) -> Void)?
        var pickModel: ((ChatModelPicker.Column, Bool) -> Void)?
        var showShortcuts: (() -> Void)?
        override var multiline: Bool {
            get { session?.drafts.current.multiline ?? false }
            set { session?.drafts.edit(multiline: newValue) }
        }
        override var displayedPlaceholder: String {
            if exitArmedAt != nil { return exitPrompt?() ?? "Press Ctrl+D again to exit chat" }
            return placeholder
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resetExitShortcut()
        }
        override func windowDidResignKey() { resetExitShortcut() }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { resetExitShortcut() }
            return resigned
        }
        override func keyDown(with event: NSEvent) {
            // Chat tabs answer the same prefix keys as their terminal; ⌃B twice keeps the editor's ⌃B.
            if let session, !hasMarkedText(), TerminalRuntime.shared.workspace?.prefixKeys.handle(event, surface: session.id) == true { return }
            if latestMessagesShortcut(event) { return }
            if editorModeShortcut(event) || helpShortcut(event) || exitShortcut(event) || queueShortcut(event) || commandShortcut(event) { return }
            if event.keyCode == 53, !hasMarkedText(), !multiline,
               event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               interrupt?() == true { return }
            if modelShortcut(event) { return }
            super.keyDown(with: event)
        }
        override func keyUp(with event: NSEvent) {
            if TerminalRuntime.shared.workspace?.prefixKeys.swallowsKeyUp(event) == true { return }
            super.keyUp(with: event)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            if let session, !hasMarkedText(), let prefixKeys = TerminalRuntime.shared.workspace?.prefixKeys {
                // As in the terminal: a chord the app takes cancels a waiting prefix.
                if event.modifierFlags.contains(.command) || ApplicationMenu.claimsShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) {
                    prefixKeys.cancel()
                } else if prefixKeys.claims(event, surface: session.id) {
                    keyDown(with: event); return true
                }
            }
            if latestMessagesShortcut(event) { return true }
            if editorModeShortcut(event) || helpShortcut(event) || exitShortcut(event) || queueShortcut(event) || commandShortcut(event)
                || modelShortcut(event) { return true }
            return super.performKeyEquivalent(with: event)
        }
        private func latestMessagesShortcut(_ event: NSEvent) -> Bool {
            guard event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !hasMarkedText(), !multiline, string.isEmpty,
                  let session, session.hasNewMessages, !session.atBottom else { return false }
            session.revealLatestMessages()
            return true
        }
        override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
            resetExitShortcut()
            return true
        }
        override func didMeasure(_ measured: CGFloat) {
            if let session, abs(session.composerHeight - measured) > 0.5 {
                DispatchQueue.main.async { [weak session] in
                    if let session, abs(session.composerHeight - measured) > 0.5 { session.composerHeight = measured }
                }
            }
        }
        private func exitShortcut(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard event.keyCode == 2, flags == .control, string.isEmpty,
                  session?.drafts.current.multiline != true, !hasMarkedText(), let exitChat else {
                resetExitShortcut(); return false
            }
            // Holding the key must never confirm an exit.
            guard !event.isARepeat else { return true }
            if let first = exitArmedAt, event.timestamp >= first, event.timestamp - first <= 1 {
                resetExitShortcut()
                exitChat()
            } else {
                let timestamp = event.timestamp
                exitArmedAt = timestamp
                needsDisplay = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard self?.exitArmedAt == timestamp else { return }
                    self?.resetExitShortcut()
                }
            }
            return true
        }
        func resetExitShortcut() {
            guard exitArmedAt != nil else { return }
            exitArmedAt = nil
            needsDisplay = true
        }
        private func commandShortcut(_ event: NSEvent) -> Bool {
            guard !hasMarkedText(), let session, !session.matchingCommands.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
            if event.keyCode == 48 { session.completeCommand(); return true }
            if event.keyCode == 125 || event.keyCode == 126 {
                session.commandSelection = (session.commandSelection + (event.keyCode == 125 ? 1 : -1)
                    + session.matchingCommands.count) % session.matchingCommands.count
                return true
            }
            return false
        }
        private func queueShortcut(_ event: NSEvent) -> Bool {
            guard !hasMarkedText(), let session, string.isEmpty,
                  !session.drafts.current.multiline, session.editingQueuedID == nil else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Match the shortcuts to the row whose hover actions are visible.
            if let id = session.hoveredQueuedID ?? session.selectedQueuedID,
               let message = session.queuedMessages.first(where: { $0.id == id }), session.editingQueuedID != id {
                if flags == .option, event.keyCode == 36 || event.keyCode == 76 {
                    if session.queuedSubmissionID != id, message.pause == nil, message.matches(session) { queueAction?(id, "send") }
                    return true
                }
                if flags == .command, event.keyCode == 51 {
                    if !event.isARepeat, session.queuedSubmissionID != id { queueAction?(id, "delete") }
                    return true
                }
                if flags.isEmpty {
                    if event.keyCode == 53 { session.selectedQueuedID = nil; session.hoveredQueuedID = nil; return true }
                    if event.charactersIgnoringModifiers == "e", session.draft.isEmpty,
                       session.editingQueuedID == nil, session.queuedSubmissionID != id {
                        queueAction?(id, "edit"); return true
                    }
                    if event.keyCode == 125 || event.keyCode == 126,
                       let index = session.queuedMessages.firstIndex(where: { $0.id == id }) {
                        session.hoveredQueuedID = nil
                        let next = index + (event.keyCode == 125 ? 1 : -1)
                        session.selectedQueuedID = session.queuedMessages.indices.contains(next) ? session.queuedMessages[next].id : nil
                        return true
                    }
                    session.selectedQueuedID = nil
                }
            } else if flags.isEmpty, event.keyCode == 126, string.isEmpty, session.editingQueuedID == nil,
                      let last = session.queuedMessages.last {
                session.selectedQueuedID = last.id; return true
            }
            return false
        }
        override func saveDraft() { session?.drafts.keep() }
        private func editorModeShortcut(_ event: NSEvent) -> Bool {
            guard !hasMarkedText() else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 14, flags == .command {
                multiline.toggle(); return true
            }
            if event.keyCode == 53, flags.isEmpty, multiline {
                multiline = false; return true
            }
            return false
        }
        private func helpShortcut(_ event: NSEvent) -> Bool {
            guard !hasMarkedText(), event.keyCode == 44,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  let showShortcuts else { return false }
            showShortcuts(); return true
        }
        private func modelShortcut(_ event: NSEvent) -> Bool {
            guard !hasMarkedText(), session?.drafts.current.multiline != true,
                  window?.firstResponder === self, let pickModel else { return false }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == 46 && flags == [.command, .shift] { pickModel(.model, false); return true }
            if event.keyCode == 14 && (flags == [.command, .shift] || flags == [.command, .shift, .option]) {
                pickModel(.effort, flags.contains(.option)); return true
            }
            return false
        }
    }
}
