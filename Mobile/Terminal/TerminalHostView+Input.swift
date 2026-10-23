import UIKit
@preconcurrency import Term

/// Keys and text. The software keyboard talks `UITextInput` (its document is only the input method's marked text,
/// shown as the terminal's preedit); every typed character becomes a key event for Term's encoder, carrying the
/// capsule's latched Ctrl or Alt. Hardware keyboards add `UIKeyCommand`s for what has no text: arrows, Esc, Tab,
/// function and navigation keys, and Ctrl and Alt chords (Option acts as Alt, as `macos-option-as-alt` on the Mac).
extension TerminalHostView {
    override var canBecomeFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // The iPad keyboard's shortcut bar would offer Undo, Redo and Paste, which a terminal has no use for or has in
        // its edit menu and ⌘V; the capsule carries the keys the keyboard lacks. Empty, the bar goes and gives the rows
        // back (with a hardware keyboard, only the system's minimal bar remains). No effect on an iPhone. Set here, as
        // the keys come, outside SwiftUI's layout (`init`'s note).
        if !inputAssistantItem.leadingBarButtonGroups.isEmpty || !inputAssistantItem.trailingBarButtonGroups.isEmpty {
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
        }
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

    /// The Mac's Edit menu for a terminal (`TerminalView.validateMenuItem`): Copy with a selection, Paste with text,
    /// Select All; plus Clear Screen and the font size, which a menu (⌘K, ⌘+, ⌘-, ⌘0) sends down the responder chain.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        // UIKit asks before it fires a key command: every hardware key's command goes through here.
        case #selector(keyCommand(_:)): true
        case #selector(copy(_:)): session.locked { session.surface.hasSelection }
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        case #selector(selectAll(_:)), #selector(clearScreen(_:)), #selector(resetFontSize(_:)): true
        // The menu bar's Find…, Find Next and Find Previous (⌘F, ⌘G, ⇧⌘G): the segment's search capsule.
        case #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)): onFind != nil
        case #selector(increaseSize(_:)): configuration.fontSize < TerminalConfiguration.fontSizes.upperBound
        case #selector(decreaseSize(_:)): configuration.fontSize > TerminalConfiguration.fontSizes.lowerBound
        default: false
        }
    }

    override func selectAll(_ sender: Any?) {
        session.locked { _ = session.surface.bindingAction(Array("select_all".utf8)) }
        session.pump()
    }

    /// The Mac's Clear Screen (⌘K, `clear_screen`): the screen and scrollback cleared, the prompt redrawn.
    @objc func clearScreen(_ sender: Any?) {
        session.locked { _ = session.surface.bindingAction(Array("clear_screen".utf8)) }
        session.pump()
    }

    /// Find… (⌘F) opens the search capsule over this terminal; Find Next and Find Previous (⌘G, ⇧⌘G) step it,
    /// opening it first when it is closed.
    override func find(_ sender: Any?) { onFind?(.open) }
    override func findNext(_ sender: Any?) { onFind?(.next) }
    override func findPrevious(_ sender: Any?) { onFind?(.previous) }

    /// ⌘+ and ⌘- (the system's Bigger and Smaller): a point at a time, as the Mac's, kept as a pinch's size is.
    override func increaseSize(_ sender: Any?) { adjustFontSize(by: 1) }
    override func decreaseSize(_ sender: Any?) { adjustFontSize(by: -1) }

    /// ⌘0: the device class's default size.
    @objc func resetFontSize(_ sender: Any?) { setFontSize(TerminalController.defaultFontSize) }

    func adjustFontSize(by points: Double) { setFontSize(configuration.fontSize + points) }

    func setFontSize(_ size: Double) {
        let size = min(max(size, TerminalConfiguration.fontSizes.lowerBound), TerminalConfiguration.fontSizes.upperBound)
        guard size != configuration.fontSize else { return }
        var next = configuration
        next.fontSize = size
        configure(next)
        onFontSize?(size)
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

    /// Chords iPadOS keeps from key commands: Ctrl-Space (and with Shift or Alt) switches input sources, so no command
    /// for it ever fires, but the press still comes here. The terminal takes it (tmux and Emacs read Ctrl-Space as
    /// NUL), as the Mac's does; every other press goes on to key commands and the text system.
    static func reservedChord(_ keyCode: UIKeyboardHIDUsage, _ flags: UIKeyModifierFlags) -> TerminalInputKey? {
        guard keyCode == .keyboardSpacebar, flags.contains(.control), !flags.contains(.command) else { return nil }
        var mods: Mods = .ctrl
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.alternate) { mods.insert(.alt) }
        return TerminalInputKey.character(" ").with(mods)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = presses
        for press in presses {
            guard let key = press.key, let chord = Self.reservedChord(key.keyCode, key.modifierFlags) else { continue }
            rest.remove(press)
            reservedPresses.insert(press)
            send(chord)
            afterKey()
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(reservedPresses)
        reservedPresses.subtract(presses)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.subtracting(reservedPresses)
        reservedPresses.subtract(presses)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

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
        let combos: [UIKeyModifierFlags] = [[], .shift, .control, .alternate, [.shift, .control], [.shift, .alternate], [.control, .alternate],
                                            [.shift, .control, .alternate]]
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
        // Shift-Return and Shift-Backspace keep their Shift (the text path drops it): an agent's TUI reads
        // Shift-Return as a newline under the kitty keyboard protocol, as the Mac's does.
        for input in ["\u{8}", "\r"] { list.append(command(input, .shift)) }
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
        // PageUp and PageDown (alone or with Shift) page a multiplexer's own history, as on the Mac; the program gets the
        // key when the server leaves the scrollback to the app. Shift pages the emulator's history (its keybinds).
        if input == UIKeyCommand.inputPageUp || input == UIKeyCommand.inputPageDown, mods.isEmpty || mods == .shift,
           presence.scrollback == .server, let feed {
            let rows = max(1, session.currentSize.rows)
            let request = TerminalScrollRequest(lines: (input == UIKeyCommand.inputPageUp ? 1 : -1) * rows, page: true,
                                                modifiers: mods == .shift ? 1 : 0)
            let key = (input == UIKeyCommand.inputPageUp ? TerminalInputKey.pageUp : TerminalInputKey.pageDown).with(mods)
            Task { [weak self] in
                let result = await feed.scroll(request)
                if result != .server { self?.send(key) }
            }
            afterKey()
            return
        }
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
                // A shifted chord carries the shifted character, as the Mac's do (Option+Shift+A is ESC A, not ESC a).
                key = mods.contains(.shift) ? TerminalInputKey.withShift(character) : .character(character)
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
