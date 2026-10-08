import AppKit

class ChatEditorTextView: ChatCaretTextView {
    var multiline = false
    var submit: (() -> Void)?
    var sendNow: (() -> Void)?
    var cancel: (() -> Void)?
    var displayedPlaceholder: String { placeholder }
    var applyingState = false
    var automaticPairs: [(open: Int, close: Int)] = []
    var fences: [ComposerFence] = []
    private var highlightedText: String?
    private var highlightedTheme: ChatTheme?
    var appliedTheme: ChatTheme?
    var placeholderColor = NSColor(Chrome.muted)
    var placeholder = "Reply…"
    var placeholderFont: NSFont? { font }
    var canAcceptFocus: () -> Bool = { true }
    var canFulfillFocus: () -> Bool = { true }
    var didFocus: (() -> Void)?
    var pendingFocus = false
    func fulfillFocusRequest() {
        guard pendingFocus, canAcceptFocus(), canFulfillFocus(), let window else { return }
        if window.makeFirstResponder(self) { pendingFocus = false }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftUI can update the editor before mounting it during a switch.
        // Keep the request until a window can actually accept it.
        DispatchQueue.main.async { [weak self] in self?.fulfillFocusRequest() }
    }
    override var acceptsFirstResponder: Bool { canAcceptFocus() && super.acceptsFirstResponder }
    override func becomeFirstResponder() -> Bool {
        guard canAcceptFocus(), super.becomeFirstResponder() else { return false }
        didFocus?()
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        drawCodeBands(dirtyRect)
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), let font = placeholderFont else { return }
        // Use the editor's own font and text origin, so placeholder and
        // insertion point share one coordinate system and the same inset.
        let prompt = displayedPlaceholder
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (prompt as NSString).draw(in: NSRect(origin: textContainerOrigin,
                                            size: NSSize(width: max(0, bounds.width - textContainerOrigin.x * 2), height: font.ascender - font.descender + font.leading + 2)), withAttributes: [
            .font: font, .foregroundColor: placeholderColor, .paragraphStyle: paragraph
        ])
    }
    override func keyDown(with event: NSEvent) {
        if multilineEditingShortcut(event) || saveShortcut(event) { return }
        if event.keyCode == 53, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if !multiline { cancel?() }; return
        }
        if submitShortcut(event) { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, !hasMarkedText(), flags.isEmpty || flags == .shift {
            indent(outdent: flags == .shift); return
        }
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            if flags.contains(.shift) || multiline {
                multiline = true
                insertNewlineIgnoringFieldEditor(nil)
            } else { submit?() }
            return
        }
        // Only key events produce automatic pairs; paste and IME insertion never enter here.
        if !hasMarkedText(), flags.isEmpty || flags == .shift,
           let character = event.characters, completeBracket(character) { return }
        if event.keyCode == 51, !hasMarkedText(), flags.isEmpty, deleteEmptyPair() { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if multilineEditingShortcut(event) || saveShortcut(event) { return true }
        if submitShortcut(event) { return true }
        if event.keyCode == 53, multiline, !hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (123...126).contains(event.keyCode), flags == .command || flags == [.command, .shift] {
            // Use AppKit's text movement/selection bindings before menu navigation.
            interpretKeyEvents([event]); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    func reservesMultilineShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard multiline else { return false }
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        // Reserve familiar editor bindings before the app's split,
        // tab/space navigation and space-search menu actions can claim them.
        return (flags == .command || flags == [.command, .shift])
            && [2, 44, 33, 30, 35].contains(keyCode)
    }
    private func multilineEditingShortcut(_ event: NSEvent) -> Bool {
        guard reservesMultilineShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if !hasMarkedText(), flags == .command, event.keyCode == 33 || event.keyCode == 30 {
            indent(outdent: event.keyCode == 33, wholeLines: true)
        }
        return true
    }
    private func submitShortcut(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76,
              [.command, .control, .option].contains(event.modifierFlags.intersection([.command, .control, .option, .shift])) else { return false }
        if event.modifierFlags.contains(.option) { sendNow?() } else { submit?() }
        return true
    }
    private func saveShortcut(_ event: NSEvent) -> Bool {
        guard !hasMarkedText(), event.keyCode == 1,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else { return false }
        saveDraft()
        return true
    }
    // Ephemeral side drafts remain in place; the main composer keeps a named draft.
    func saveDraft() {}
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        if let replacementString {
            let delta = replacementString.utf16.count - affectedCharRange.length
            automaticPairs = automaticPairs.compactMap { pair in
                if affectedCharRange.length > 0 && (NSLocationInRange(pair.open, affectedCharRange) || NSLocationInRange(pair.close, affectedCharRange)) { return nil }
                return (pair.open >= affectedCharRange.location ? pair.open + delta : pair.open,
                        pair.close >= affectedCharRange.location ? pair.close + delta : pair.close)
            }
        }
        return true
    }
    func replace(_ range: NSRange, with value: String, selection: NSRange,
                 restoringPairs: [(open: Int, close: Int)]? = nil) {
        let previous = (string as NSString).substring(with: range)
        let previousSelection = selectedRange(), previousPairs = automaticPairs
        breakUndoCoalescing()
        let manager = undoManager
        // NSTextView also registers edits in shouldChangeText. This operation
        // owns one inverse, including its selection and automatic pair markers.
        manager?.disableUndoRegistration()
        guard shouldChangeText(in: range, replacementString: value) else { manager?.enableUndoRegistration(); return }
        textStorage?.replaceCharacters(in: range, with: value)
        if let restoringPairs { automaticPairs = restoringPairs }
        setSelectedRange(selection)
        didChangeText()
        manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget: self) { target in
            target.replace(NSRange(location: range.location, length: value.utf16.count), with: previous,
                           selection: previousSelection, restoringPairs: previousPairs)
        }
        breakUndoCoalescing()
    }
    func completeBracket(_ value: String) -> Bool {
        let selection = selectedRange()
        guard ComposerFence.scan(string).contains(where: { $0.contains(selection) }) else { return false }
        if selection.length == 0, ["}", "]", ")"].contains(value),
           let index = automaticPairs.firstIndex(where: { $0.close == selection.location }),
           selection.location < string.utf16.count,
           (string as NSString).substring(with: NSRange(location: selection.location, length: 1)) == value {
            automaticPairs.remove(at: index)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0)); return true
        }
        guard let closer = ["{": "}", "[": "]", "(": ")"][value] else { return false }
        let body = (string as NSString).substring(with: selection)
        replace(selection, with: value + body + closer, selection: NSRange(location: selection.location + 1, length: selection.length))
        automaticPairs.append((selection.location, selection.location + selection.length + 1))
        return true
    }
    func deleteEmptyPair() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0, automaticPairs.contains(where: { $0.open == selection.location - 1 && $0.close == selection.location }),
              selection.location > 0, selection.location < string.utf16.count else { return false }
        let range = NSRange(location: selection.location - 1, length: 2)
        guard ["{}", "[]", "()"].contains((string as NSString).substring(with: range)) else { return false }
        replace(range, with: "", selection: NSRange(location: range.location, length: 0)); return true
    }
    func indent(outdent: Bool, wholeLines: Bool = false) {
        let source = string as NSString, selection = selectedRange()
        if selection.length == 0 && !outdent && !wholeLines {
            replace(selection, with: "    ", selection: NSRange(location: selection.location + 4, length: 0)); return
        }
        let touched = NSRange(location: selection.location, length: max(0, selection.length - 1))
        let lines = source.lineRange(for: touched)
        let original = source.substring(with: lines)
        var parts = original.components(separatedBy: "\n")
        var firstDelta = 0, delta = 0
        for i in parts.indices {
            if i == parts.count - 1 && parts[i].isEmpty && original.hasSuffix("\n") { continue }
            let count: Int
            if outdent {
                count = parts[i].hasPrefix("\t") ? 1 : min(4, parts[i].prefix(while: { $0 == " " }).count)
                parts[i] = String(parts[i].dropFirst(count))
            } else { count = 4; parts[i] = "    " + parts[i] }
            let change = outdent ? -count : count
            if i == 0 { firstDelta = change }; delta += change
        }
        let value = parts.joined(separator: "\n")
        let result = selection.length == 0
            ? NSRange(location: max(lines.location, selection.location + firstDelta), length: 0)
            : NSRange(location: lines.location, length: max(0, lines.length + delta))
        replace(lines, with: value, selection: result)
    }
    func highlight() {
        guard !hasMarkedText(), let theme = appliedTheme, let storage = textStorage,
              highlightedText != string || highlightedTheme != theme else { return }
        highlightedText = string; highlightedTheme = theme
        fences = ComposerFence.scan(string)
        applyingState = true
        storage.beginEditing()
        storage.setAttributes([.font: theme.typography.reply, .foregroundColor: NSColor(theme.ink)], range: NSRange(location: 0, length: storage.length))
        for fence in fences {
            storage.addAttribute(.font, value: theme.typography.codeReply, range: fence.range)
            storage.addAttribute(.foregroundColor, value: NSColor(theme.muted), range: fence.opening)
            if let closing = fence.closing { storage.addAttribute(.foregroundColor, value: NSColor(theme.muted), range: closing) }
            let code = (string as NSString).substring(with: fence.body)
            for token in SyntaxHighlight.tokens(code, language: fence.language, theme: theme) {
                storage.addAttribute(.foregroundColor, value: NSColor(token.color), range: NSRange(location: fence.body.location + token.range.location, length: token.range.length))
            }
        }
        storage.endEditing()
        typingAttributes = [.font: theme.typography.reply, .foregroundColor: NSColor(theme.ink)]
        applyingState = false; needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        measure()
    }
    func measure() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(max(layoutManager.usedRect(for: textContainer).height, layoutManager.extraLineFragmentRect.maxY)) + 2 * textContainerInset.height
        let measured = max((font.map { layoutManager.defaultLineHeight(for: $0) } ?? 18) + 10, height)
        didMeasure(measured)
    }
    func didMeasure(_ height: CGFloat) {}
    private func drawCodeBands(_ dirtyRect: NSRect) {
        guard let theme = appliedTheme, let layoutManager, let textContainer else { return }
        for fence in fences {
            let glyphs = layoutManager.glyphRange(forCharacterRange: fence.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.y += textContainerOrigin.y
            rect.origin.x = 0; rect.size.width = bounds.width
            guard rect.intersects(dirtyRect) else { continue }
            NSColor(theme.terminal).setFill(); rect.fill()
            let badge = String(fence.language.prefix(24)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.native(size: max(8, theme.typography.reply.pointSize - 3)), .foregroundColor: NSColor(theme.muted)]
            let size = badge.size(withAttributes: attributes)
            let origin = NSPoint(x: max(12, bounds.width - size.width - 16), y: rect.minY + 1)
            // Reserve only the right edge of the fence line for a non-editing badge.
            NSColor(theme.terminal).setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x - 4, y: origin.y, width: size.width + 8, height: size.height), xRadius: 3, yRadius: 3).fill()
            badge.draw(at: origin, withAttributes: attributes)
        }
    }
}
