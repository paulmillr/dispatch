import UIKit
@preconcurrency import Term

/// Keys and text. The software keyboard talks `UITextInput` (its document is only the input method's marked text,
/// shown as the terminal's preedit); every typed character becomes a key event for Term's encoder, carrying the
/// capsule's latched Ctrl or Alt. Hardware keyboards add `UIKeyCommand`s for what has no text: arrows, Esc, Tab,
/// function and navigation keys, and Ctrl and Alt chords (Option acts as Alt, as `macos-option-as-alt` on the Mac).
extension TerminalHostView {
    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { session.setFocus(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { session.setFocus(false) }
        return resigned
    }

    /// One key, pressed and released, with the capsule's latched modifiers; its bytes go to the feed.
    func send(_ key: TerminalInputKey) {
        var key = key
        key.mods.formUnion(pendingMods())
        if !key.mods.isEmpty, key.text.isEmpty == false, key.keycode == TerminalInputKey.unidentified, key.mods.contains(.ctrl),
           let control = Self.controlByte(key.text) {
            // A Ctrl chord on a character with no US key (the encoder needs the key): the C0 byte itself.
            feed?.send(Data([control]))
            return
        }
        let text = Array(key.text.utf8)
        session.locked {
            let surface = session.surface
            // The mods the platform consumed producing the text (shift for shifted characters), as on the Mac.
            let consumed = key.mods.intersection(.shift)
            _ = surface.key(.press, keycode: key.keycode, mods: key.mods, consumed: consumed, composing: false, unshifted: key.unshifted, text: text)
            _ = surface.key(.release, keycode: key.keycode, mods: key.mods, consumed: consumed, composing: false, unshifted: key.unshifted, text: [])
        }
        session.pump()
    }

    /// Text typed on the software keyboard (or dictated): one key per character.
    func type(_ text: String) {
        for character in text { send(.character(character)) }
    }

    /// A paste: bracketed when the program asked for it.
    func paste(text: String) {
        guard !text.isEmpty else { return }
        session.locked { session.surface.text(Array(text.utf8)) }
        session.pump()
    }

    static func controlByte(_ text: String) -> UInt8? {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.count == 1, scalar.isASCII else { return nil }
        let v = UInt8(scalar.value)
        switch v {
        case 0x40...0x5F: return v - 0x40
        case 0x61...0x7A: return v - 0x60
        case 0x3F: return 0x7F
        default: return nil
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): session.locked { session.surface.hasSelection }
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        default: false
        }
    }

    override func copy(_ sender: Any?) {
        guard let text = session.locked({ session.surface.readSelection() }) else { return }
        UIPasteboard.general.string = String(decoding: text, as: UTF8.self)
        session.locked { session.surface.touchClearSelection() }
        session.pump()
    }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string { paste(text: text) }
    }

    override var keyCommands: [UIKeyCommand]? { Self.commands }

    @MainActor private static let commands = makeCommands()

    private static func makeCommands() -> [UIKeyCommand] {
        let action = #selector(TerminalHostView.keyCommand(_:))
        func command(_ input: String, _ flags: UIKeyModifierFlags = [], priority: Bool = true) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            c.wantsPriorityOverSystemBehavior = priority
            return c
        }
        var list: [UIKeyCommand] = []
        let special = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow,
                       UIKeyCommand.inputHome, UIKeyCommand.inputEnd, UIKeyCommand.inputPageUp, UIKeyCommand.inputPageDown, UIKeyCommand.inputDelete]
        let combos: [UIKeyModifierFlags] = [[], .shift, .control, .alternate, [.shift, .control], [.shift, .alternate], [.control, .alternate]]
        for input in special { for flags in combos { list.append(command(input, flags)) } }
        for input in [UIKeyCommand.inputEscape, "\t"] { for flags in combos { list.append(command(input, flags)) } }
        let functions = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
                         UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12]
        for input in functions { for flags in [UIKeyModifierFlags(), .shift, .control, .alternate] { list.append(command(input, flags)) } }
        // Ctrl and Alt chords on every US key (Option would type its own characters otherwise).
        let keys = TerminalInputKey.usLayout.keys.map(String.init).sorted()
        for input in keys + ["\u{8}", "\r"] {
            for flags in [UIKeyModifierFlags.control, .alternate, [.control, .alternate], [.control, .shift], [.alternate, .shift]] {
                list.append(command(input, flags))
            }
        }
        return list
    }

    @objc func keyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        var mods: Mods = []
        let flags = command.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.alternate) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.super) }
        let functions = [UIKeyCommand.f1, UIKeyCommand.f2, UIKeyCommand.f3, UIKeyCommand.f4, UIKeyCommand.f5, UIKeyCommand.f6,
                         UIKeyCommand.f7, UIKeyCommand.f8, UIKeyCommand.f9, UIKeyCommand.f10, UIKeyCommand.f11, UIKeyCommand.f12]
        let key: TerminalInputKey
        switch input {
        case UIKeyCommand.inputUpArrow: key = .up
        case UIKeyCommand.inputDownArrow: key = .down
        case UIKeyCommand.inputLeftArrow: key = .left
        case UIKeyCommand.inputRightArrow: key = .right
        case UIKeyCommand.inputHome: key = .home
        case UIKeyCommand.inputEnd: key = .end
        case UIKeyCommand.inputPageUp: key = .pageUp
        case UIKeyCommand.inputPageDown: key = .pageDown
        case UIKeyCommand.inputDelete: key = .deleteForward
        case UIKeyCommand.inputEscape: key = .escape
        case "\t": key = .tab
        case "\u{8}": key = .backspace
        case "\r": key = .enter
        default:
            if let index = functions.firstIndex(of: input) {
                key = TerminalInputKey(keycode: TerminalInputKey.functionKeycodes[index])
            } else if let character = input.first {
                key = .character(character)
            } else { return }
        }
        send(key.with(mods))
        afterKey()
    }

    /// The capsule's one-shot latches are used up by a key (the capsule's model resets them).
    func afterKey() { onKeySent?() }
}

/// A position in the marked text (UTF-16 offset).
final class TerminalTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class TerminalTextRange: UITextRange {
    let from: Int, to: Int
    init(_ from: Int, _ to: Int) { (self.from, self.to) = (min(from, to), max(from, to)) }
    override var start: UITextPosition { TerminalTextPosition(from) }
    override var end: UITextPosition { TerminalTextPosition(to) }
    override var isEmpty: Bool { from == to }
}

extension TerminalHostView: UITextInput {
    var hasText: Bool { true }

    func insertText(_ text: String) {
        let hadMarked = !marked.isEmpty
        if hadMarked { setPreedit("") }
        type(text)
        afterKey()
    }

    func deleteBackward() {
        guard marked.isEmpty else { return }
        send(.backspace)
        afterKey()
    }

    private var length: Int { (marked as NSString).length }

    private func clamp(_ offset: Int) -> Int { min(max(0, offset), length) }

    private func setPreedit(_ text: String) {
        inputDelegate?.textWillChange(self)
        marked = text
        markedSelection = NSRange(location: (text as NSString).length, length: 0)
        inputDelegate?.textDidChange(self)
        session.locked { session.surface.setPreedit(Array(text.utf8)) }
        session.pump()
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalTextRange else { return nil }
        let from = clamp(range.from), to = clamp(range.to)
        return (marked as NSString).substring(with: NSRange(location: from, length: to - from))
    }

    func replace(_ range: UITextRange, withText text: String) { insertText(text) }

    var selectedTextRange: UITextRange? {
        get { TerminalTextRange(markedSelection.location, markedSelection.location + markedSelection.length) }
        set {
            guard let range = newValue as? TerminalTextRange else { return }
            markedSelection = NSRange(location: clamp(range.from), length: clamp(range.to) - clamp(range.from))
        }
    }

    var markedTextRange: UITextRange? { marked.isEmpty ? nil : TerminalTextRange(0, length) }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        setPreedit(markedText ?? "")
        markedSelection = NSRange(location: min(selectedRange.location, length), length: min(selectedRange.length, length - min(selectedRange.location, length)))
    }

    func unmarkText() {
        let text = marked
        guard !text.isEmpty else { return }
        setPreedit("")
        type(text)
    }

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(length) }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let a = fromPosition as? TerminalTextPosition, let b = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(a.offset, b.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let p = position as? TerminalTextPosition else { return nil }
        let next = p.offset + offset
        return (0...length).contains(next) ? TerminalTextPosition(next) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? TerminalTextPosition)?.offset ?? 0, b = (other as? TerminalTextPosition)?.offset ?? 0
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? TerminalTextPosition)?.offset ?? 0) - ((from as? TerminalTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard let range = range as? TerminalTextRange else { return nil }
        switch direction {
        case .left, .up: return TerminalTextPosition(range.from)
        default: return TerminalTextPosition(range.to)
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let p = position as? TerminalTextPosition else { return nil }
        switch direction {
        case .left, .up: return TerminalTextRange(0, p.offset)
        default: return TerminalTextRange(p.offset, length)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .leftToRight }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// The input method's candidates go at the cursor.
    func firstRect(for range: UITextRange) -> CGRect { caretRect(for: endOfDocument) }

    func caretRect(for position: UITextPosition) -> CGRect {
        let point = session.locked { session.surface.imePoint() }
        let height = point.height
        return CGRect(x: point.x, y: point.y - height, width: 2, height: height)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }
}
