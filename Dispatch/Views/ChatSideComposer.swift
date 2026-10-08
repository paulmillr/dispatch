import SwiftUI
import AppKit

struct ChatSideComposer: NSViewRepresentable {
    @Environment(\.chatTheme) private var theme
    let side: ChatSideConversation
    let focused: Bool
    let close: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // TextKit 1 without the font's leading, as the main composer (ChatComposer.makeNSView).
        let text = SideTextView(usingTextLayoutManager: false)
        text.layoutManager?.usesFontLeading = false
        text.side = side
        text.delegate = context.coordinator
        text.allowsUndo = true
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.textContainerInset = NSSize(width: 12, height: 5)
        text.textContainer?.lineFragmentPadding = 0
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.drawsBackground = false
        text.backgroundColor = .clear
        text.placeholder = "Follow up…"
        text.setAccessibilityLabel("Message side conversation")
        text.setAccessibilityIdentifier("chat-side-composer")
        scroll.documentView = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? SideTextView else { return }
        text.side = side
        if !text.hasMarkedText(), text.string != side.draft {
            text.applyingState = true
            text.string = side.draft
            let selection = side.draftSelection
            let location = min(selection.location, text.string.utf16.count)
            text.setSelectedRange(NSRange(location: location, length: min(selection.length, text.string.utf16.count - location)))
            text.undoManager?.removeAllActions()
            text.automaticPairs = []
            text.applyingState = false
            text.scrollRangeToVisible(text.selectedRange())
        }
        if text.appliedTheme?.typography != theme.typography { text.font = theme.typography.reply }
        if text.appliedTheme != theme {
            text.textColor = NSColor(theme.ink)
            text.insertionPointColor = NSColor(theme.ink)
            text.placeholderColor = NSColor(theme.muted)
            text.selectedTextAttributes = [.backgroundColor: NSColor(theme.selection), .foregroundColor: NSColor(theme.selectedText)]
            text.appliedTheme = theme
        }
        text.submit = { side.send() }
        text.sendNow = { side.send() }
        text.cancel = close
        text.canAcceptFocus = { !side.hasQuestions }
        text.canFulfillFocus = { focused }
        text.highlight()
        text.measure()
        text.needsDisplay = true
        if !focused {
            text.pendingFocus = false
            if text.window?.firstResponder === text { text.window?.makeFirstResponder(nil) }
        } else if !context.coordinator.wasFocused {
            text.pendingFocus = true
            DispatchQueue.main.async { [weak text] in text?.fulfillFocusRequest() }
        }
        context.coordinator.wasFocused = focused
    }

    func makeCoordinator() -> Coordinator { Coordinator(side) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let side: ChatSideConversation
        var wasFocused = false
        init(_ side: ChatSideConversation) { self.side = side }
        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? SideTextView, !text.applyingState else { return }
            side.draft = text.string
            side.draftSelection = text.selectedRange()
            side.composingText = text.hasMarkedText()
            if !text.hasMarkedText() { text.highlight() }
            text.measure()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = notification.object as? SideTextView, !text.applyingState else { return }
            side.composingText = text.hasMarkedText()
            if !text.hasMarkedText() { side.draftSelection = text.selectedRange() }
        }
    }

    final class SideTextView: ChatEditorTextView {
        weak var side: ChatSideConversation?
        override var multiline: Bool {
            get { side?.draftMultiline ?? false }
            set { side?.draftMultiline = newValue }
        }
        override func didMeasure(_ height: CGFloat) {
            guard let side, abs(side.composerHeight - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak side] in
                if let side, abs(side.composerHeight - height) > 0.5 { side.composerHeight = height }
            }
        }
    }
}
