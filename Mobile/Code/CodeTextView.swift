import UIKit

/// The code composer's editor (M5e): a TextKit 1 `UITextView` whose draft stays plain Markdown. Every character edit
/// is re-styled inside the text storage's own editing pass (`willProcessEditing`), so a chip that forms or a fence
/// that closes is drawn in its final form in the same frame as the keystroke, and cursor, selection, marked text and
/// undo are never disturbed (attributes change in place; the text storage is never rebuilt). Autocorrection, smart
/// punctuation and capitalisation are on for prose and off while the caret is in code.
final class CodeTextView: UITextView, NSTextStorageDelegate {
    private(set) var markdown = ComposerMarkdown("")
    private(set) var style: CodeComposerStyle
    let codeLayout: CodeLayoutManager
    /// The caret is in code (input traits follow it).
    private(set) var inCode = false
    /// The draft changed (a keystroke, a key of the key row, a paste, undo): the new text.
    var changed: ((String) -> Void)?
    /// A paste of several lines, offered as a fenced block (the pasted range).
    var pasted: ((NSRange?) -> Void)?
    var submit: (() -> Void)?
    let placeholderLabel = UILabel()
    /// Styling passes so far (tests: one per edit, none for selection changes).
    private(set) var styled = 0
    private var styledText: String?

    static let maximumHeight: CGFloat = 236
    static let verticalInset: CGFloat = 7

    init() {
        style = CodeComposerStyle()
        let storage = NSTextStorage()
        codeLayout = CodeLayoutManager()
        storage.addLayoutManager(codeLayout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        codeLayout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        storage.delegate = self
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: Self.verticalInset, left: 0, bottom: Self.verticalInset, right: 0)
        isScrollEnabled = false
        tintColor = CodePalette.keyword
        keyboardAppearance = .default  // Follows the app's appearance.
        adjustsFontForContentSizeCategory = false
        typingAttributes = style.proseAttributes
        applyTraits(code: false, reload: false)
        placeholderLabel.font = style.prose
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        #if DEBUG
        // `-DispatchHardwareKeyboard YES` stands in for an attached keyboard: no software keyboard either, as with a
        // real one, so screenshots and tests show the composer as a keyboard user sees it.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DispatchHardwareKeyboard") != nil, defaults.bool(forKey: "DispatchHardwareKeyboard") {
            inputView = UIView(frame: .zero)
        }
        #endif
        NotificationCenter.default.addObserver(self, selector: #selector(textDidChange), name: UITextView.textDidChangeNotification, object: self)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: CodeTextView, _: UITraitCollection) in
            view.restyleForContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func textDidChange() { didEdit() }

    override var selectedTextRange: UITextRange? {
        didSet { updateCaretContext() }
    }

    override var selectedRange: NSRange {
        didSet { updateCaretContext() }
    }

    var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set {
            placeholderLabel.text = newValue
            accessibilityLabel = newValue
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        let height = style.proseLine
        placeholderLabel.frame = CGRect(x: inset.left, y: inset.top, width: max(0, bounds.width - inset.left - inset.right), height: height)
        placeholderLabel.isHidden = !textStorage.string.isEmpty
        // Below its bound the field grows instead; at the bound it scrolls.
        let scrolls = bounds.height >= Self.maximumHeight - 0.5
            && sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height > bounds.height + 0.5
        if isScrollEnabled != scrolls {
            isScrollEnabled = scrolls
            if scrolls { scrollRangeToVisible(selectedRange) }
        }
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorage.EditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // UIKit edits the text view's storage on the main thread only.
        nonisolated(unsafe) let storage = textStorage
        MainActor.assumeIsolated { restyle(storage) }
    }

    /// Styles the storage for its text unless marked text (an input method's composition) is open; the pass after the
    /// composition ends catches up.
    private func restyle(_ storage: NSTextStorage) {
        guard markedTextRange == nil else { return }
        let text = storage.string
        markdown = ComposerMarkdown(text)
        codeLayout.markdown = markdown
        codeLayout.style = style
        codeLayout.trailingLineInFence = text.hasSuffix("\n") && markdown.fences.last.map { $0.closing == nil } == true
        style.apply(to: storage, markdown: markdown)
        styledText = text
        styled += 1
        placeholderLabel.isHidden = !text.isEmpty
    }

    /// Catches up after marked text ended without another character edit.
    func restyleIfNeeded() {
        if styledText != textStorage.string { restyle(textStorage) }
    }

    private func restyleForContentSize() {
        style = CodeComposerStyle(traits: traitCollection)
        placeholderLabel.font = style.prose
        styledText = nil
        restyleIfNeeded()
        updateCaretContext()
    }

    /// Replaces the whole draft from outside (a sent message cleared, a quoted reply): the only path that sets the
    /// text wholesale; the edit history no longer applies to it.
    func setDraft(_ text: String) {
        guard text != textStorage.string else { return }
        let caret = (text as NSString).length
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        selectedRange = NSRange(location: caret, length: 0)
        undoManager?.removeAllActions()
        updateCaretContext()
        setNeedsLayout()
    }

    /// Typing attributes and input traits for where the caret is.
    func updateCaretContext() {
        let location = selectedRange.location
        let code = markdown.isCode(at: location, in: textStorage.string)
        let inFence = markdown.fence(at: location).map { location > NSMaxRange($0.opening) - 1 || $0.opening.length == 0 } ?? false
        typingAttributes = inFence ? style.codeAttributes : style.proseAttributes
        if code != inCode { applyTraits(code: code, reload: true) }
    }

    private func applyTraits(code: Bool, reload: Bool) {
        inCode = code
        autocorrectionType = code ? .no : .default
        autocapitalizationType = code ? .none : .sentences
        smartQuotesType = code ? .no : .default
        smartDashesType = code ? .no : .default
        smartInsertDeleteType = code ? .no : .default
        spellCheckingType = code ? .no : .default
        inlinePredictionType = code ? .no : .default
        if reload, isFirstResponder { reloadInputViews() }
    }

    /// Applies `edit` as typing would: through UITextInput, so it is one undoable step.
    func perform(_ edit: ComposerMarkdown.Edit) {
        guard let start = position(from: beginningOfDocument, offset: edit.range.location),
              let end = position(from: start, offset: edit.range.length),
              let range = textRange(from: start, to: end) else { return }
        replace(range, withText: edit.text)
        selectedRange = edit.selection
        didEdit()
    }

    func press(_ key: ComposerKey) {
        perform(key.edit(textStorage.string, selection: selectedRange))
    }

    /// Wraps the pasted range in a fence (the "Paste as code" offer).
    func fence(_ range: NSRange) {
        guard NSMaxRange(range) <= textStorage.length else { return }
        let pasted = (textStorage.string as NSString).substring(with: range)
        perform(ComposerMarkdown.fenced(pasted, replacing: range, in: textStorage.string))
    }

    /// After any change of the characters: the caret's context and the owner.
    func didEdit() {
        restyleIfNeeded()
        updateCaretContext()
        changed?(textStorage.string)
    }

    override func paste(_ sender: Any?) {
        let string = UIPasteboard.general.string ?? ""
        let start = selectedRange.location
        let offer = ComposerMarkdown.offersCode(string) && !markdown.isCode(at: start, in: textStorage.string)
        super.paste(sender)
        let end = selectedRange.location
        pasted?(offer && end > start ? NSRange(location: start, length: end - start) : nil)
    }

    /// Paste as a fenced block directly (the edit menu's "Paste as Code").
    @objc func pasteAsCode(_ sender: Any?) {
        guard let string = UIPasteboard.general.string, !string.isEmpty else { return }
        perform(ComposerMarkdown.fenced(string, replacing: selectedRange, in: textStorage.string))
        pasted?(nil)
    }

    /// The draft's editor mode and whether the agent works, for the hardware keys (`ComposerHardwareKeys`).
    var keyState: () -> (multiline: Bool, working: Bool) = { (false, false) }
    /// A hardware key's action the composer carries out (send, steer, stop, editor mode); newline and resign are the
    /// view's own.
    var keyAction: ((ComposerKeyAction) -> Void)?

    /// Made once: UIKit asks for them on every key event.
    private static let commands = ComposerHardwareKeys.commands(action: #selector(hardwareKey(_:)))
    override var keyCommands: [UIKeyCommand]? { Self.commands }

    func action(for command: UIKeyCommand) -> ComposerKeyAction {
        guard let key = ComposerHardwareKeys.key(command) else { return .system }
        let state = keyState()
        return ComposerHardwareKeys.action(key, modifiers: command.modifierFlags, multiline: state.multiline,
                                           working: state.working, composing: markedTextRange != nil)
    }

    /// A command the composer does not take this time (an open composition's Return) is declined, so the key goes on
    /// to the text system.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(hardwareKey(_:)) {
            guard let command = sender as? UIKeyCommand else { return markedTextRange == nil }
            return self.action(for: command) != .system
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func hardwareKey(_ command: UIKeyCommand) { perform(action(for: command)) }

    func perform(_ action: ComposerKeyAction) {
        switch action {
        case .newline:
            insertText("\n")
            didEdit()
        case .resign: _ = resignFirstResponder()
        case .system: break
        case .send where keyAction == nil: submit?()
        default: keyAction?(action)
        }
    }

    /// The height the editor wants at `width`: its text, at least one prose line, at most `maximumHeight` (then it
    /// scrolls). Measured on a copy of the styled text, so it does not depend on the view's current width (SwiftUI asks
    /// for the width the field is about to get).
    func fittingHeight(width: CGFloat) -> CGFloat {
        let minimum = style.proseLine + 2 * Self.verticalInset
        return min(max(ceil(textHeight(width: width)) + 2 * Self.verticalInset, minimum), Self.maximumHeight)
    }

    func textHeight(width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: textStorage)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).maxY
    }
}
