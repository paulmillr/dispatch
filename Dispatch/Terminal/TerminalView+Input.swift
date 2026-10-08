// Input, IME, and Edit-menu integration adapted from umputun/agterm and
// thdxg/macterm (MIT).
import AppKit
import Term

extension TerminalView {
    var inputParked: Bool { inputSuspensions > 0 || TerminalRuntime.shared.hosts.reconnect.state(for: id) != nil }

    var agentMenuScreen: String {
        guard let surface else { return "" }
        return String(surface.readText(.active).prefix(65_536))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit can interpret Control shortcuts as text commands before
        // keyDown. The focused terminal must send them to the terminal directly.
        // Command/Option shortcuts and active IME composition keep their
        // normal responder-chain handling, as do the app's Settings › Keys digit chords and ⌃⇥.
        let flags = event.modifierFlags
        // Prefix keys complete in keyDown; a chord the app takes here instead cancels a waiting prefix.
        if event.type == .keyDown, window?.firstResponder === self,
           flags.contains(.command) || ApplicationMenu.claimsShortcut(keyCode: event.keyCode, modifiers: flags) {
            TerminalRuntime.shared.workspace?.prefixKeys.cancel()
        }
        guard event.type == .keyDown, window?.firstResponder === self,
              surface != nil, !inputParked, !hasMarkedText(),
              !ApplicationMenu.claimsShortcut(keyCode: event.keyCode, modifiers: flags),
              flags.contains(.control), !flags.contains(.command), !flags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard inputSuspensions == 0 else { return }
        if surface != nil, !hasMarkedText(), TerminalRuntime.shared.workspace?.prefixKeys.handle(event, surface: id) == true { return }
        if inputParked, event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            let runtime = TerminalRuntime.shared
            if let host = runtime.workspace?.hosts.terminals[id]?.host {
                runtime.hosts.reconnect.reconnect(hostID: host, sourceSurfaceID: id)
            }
            return
        }
        TerminalRuntime.shared.chat.sessions[id]?.lastInputAt = Date()
        guard let surface else { super.keyDown(with: event); return }
        let action: KeyEvent.Action = event.isARepeat ? .repeat : .press
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let scrollModifiers = flags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 116 || event.keyCode == 121, scrollModifiers.isEmpty || scrollModifiers == .shift {
            let pages = event.keyCode == 116 ? 1 : -1
            // A multiplexer pages its own history; the renderer's history pages here (replayed once).
            if let owner = TerminalRuntime.shared.workspace?.helper(containing: id), owner.scrolls(id) {
                owner.scroll(id, lines: Int64(pages * max(1, surface.grid.rows)), page: true, at: nil,
                             modifiers: scrollModifiers == .shift ? 1 : 0) { [weak self] in self?.keyDown(with: event) }
                return
            }
        }

        // Control chords are encoded by the terminal from the physical key and
        // modifier. Sending the layout character avoids AppKit's control-byte
        // transformation and matches Ghostty.app's input path.
        if flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           !hasMarkedText() {
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            sendKey(makeKeyEvent(event, action: action), text: text.isEmpty ? nil : text, to: surface)
            return
        }

        // Command shortcuts are terminal bindings. In particular Cmd-C and
        // Cmd-V reach the clipboard host installed by Dispatch.
        if flags.contains(.command) {
            sendKey(makeKeyEvent(event, action: action), to: surface)
            return
        }

        // A held key's repeats open AppKit's press-and-hold accent picker when
        // they reach the input context. Terminal keys repeat instead; Chat keeps
        // the picker, and an active IME composition still receives its repeats.
        if event.isARepeat, !hasMarkedText() {
            let translationEvent = translatedEvent(for: event)
            var key = makeKeyEvent(event, action: .repeat)
            let text = filterSpecial(translationEvent.characters ?? "")
            key.consumed = text.isEmpty ? [] : consumedModifiers(translationEvent.modifierFlags)
            sendKey(key, text: text.isEmpty ? nil : text, to: surface)
            return
        }

        // Let AppKit's input context own layout translation and IME. Ordinary
        // key insertion is accumulated by insertText; an active composition
        // is rendered through the terminal's preedit.
        let hadMarkedText = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        let translationEvent = translatedEvent(for: event)
        interpretKeyEvents([translationEvent])
        currentKeyEvent = nil

        var key = makeKeyEvent(event, action: action)
        key.consumed = consumedModifiers(translationEvent.modifierFlags)
        key.composing = hasMarkedText() || hadMarkedText
        if !keyTextAccumulator.isEmpty {
            var commit = key
            commit.composing = false
            for text in keyTextAccumulator {
                sendKey(commit, text: text, to: surface)
            }
        } else if !hasMarkedText() {
            let text = filterSpecial(event.characters ?? "")
            if !text.isEmpty, !key.composing {
                sendKey(key, text: text, to: surface)
            } else {
                key.consumed = []
                sendKey(key, to: surface)
            }
        }
    }

    override func doCommand(by _: Selector) {}

    override func keyUp(with event: NSEvent) {
        guard let surface, TerminalRuntime.shared.workspace?.prefixKeys.swallowsKeyUp(event) != true else { return }
        let scrollModifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        // Its press paged the multiplexer's history; the release belongs to that gesture.
        if event.keyCode == 116 || event.keyCode == 121, scrollModifiers.isEmpty || scrollModifiers == .shift,
           TerminalRuntime.shared.workspace?.helper(containing: id)?.scrolls(id) == true { return }
        sendKey(makeKeyEvent(event, action: .release), to: surface)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        let pressed = modifierForKeyCode(event.keyCode).map { event.modifierFlags.contains($0) } ?? false
        sendKey(makeKeyEvent(event, action: pressed ? .press : .release), to: surface)
    }

    override func mouseDown(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        if window?.makeFirstResponder(self) == true { select() }
        reportMousePosition(event)
        _ = surface.mouseButton(.press, .left, mods: mouseModifiers(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        reportMousePosition(event)
        _ = surface.mouseButton(.release, .left, mods: mouseModifiers(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        reportMousePosition(event)
        _ = surface.mouseButton(.press, .right, mods: mouseModifiers(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        reportMousePosition(event)
        _ = surface.mouseButton(.release, .right, mods: mouseModifiers(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard !inputParked, event.buttonNumber == 2, let surface else {
            super.otherMouseDown(with: event)
            return
        }
        reportMousePosition(event)
        _ = surface.mouseButton(.press, .middle, mods: mouseModifiers(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard !inputParked, event.buttonNumber == 2, let surface else {
            super.otherMouseUp(with: event)
            return
        }
        reportMousePosition(event)
        _ = surface.mouseButton(.release, .middle, mods: mouseModifiers(event))
    }

    override func mouseMoved(with event: NSEvent) { reportMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { reportMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { reportMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { reportMousePosition(event) }

    override func mouseEntered(with event: NSEvent) {
        reportMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard !inputParked, let surface, NSEvent.pressedMouseButtons == 0 else { return }
        surface.mousePos(x: -1, y: -1, mods: mouseModifiers(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        // A multiplexer scrolls its own history; the renderer's history scrolls here (replayed once).
        let owner = TerminalRuntime.shared.workspace?.helper(containing: id).flatMap { $0.scrolls(id) ? $0 : nil }
        if let owner {
            let size = surface.grid, scale = window?.backingScaleFactor ?? 1
            let lineHeight = Double(size.cellHeight) / scale
            let lines = herdrScrollAccumulator.consume(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                                      lineHeight: lineHeight, began: event.phase == .began)
            guard lines != 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            let column = Int((point.x * scale - 10 * scale) / Double(max(1, size.cellWidth)))
            let row = Int(((bounds.height - point.y) * scale - 8 * scale) / Double(max(1, size.cellHeight)))
            let cell = (column: UInt16(max(0, min(Int(size.columns) - 1, column))), row: UInt16(max(0, min(Int(size.rows) - 1, row))))
            let flags = event.modifierFlags
            let modifiers = (flags.contains(.shift) ? 1 : 0) | (flags.contains(.option) ? 2 : 0) | (flags.contains(.control) ? 4 : 0)
            owner.scroll(id, lines: Int64(lines), page: false, at: cell, modifiers: UInt8(modifiers)) { [weak self] in
                self?.scrollWheel(with: event)
            }
            return
        }
        reportMousePosition(event)
        var modifiers: Int32 = 0
        if event.hasPreciseScrollingDeltas { modifiers |= 1 }
        surface.mouseScroll(x: event.scrollingDeltaX, y: event.scrollingDeltaY, mods: modifiers)
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface, !inputParked || !action.hasPrefix("paste_") else { return false }
        return surface.bindingAction(action)
    }

    private func reportMousePosition(_ event: NSEvent) {
        guard !inputParked, let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        surface.mousePos(x: point.x, y: bounds.height - point.y, mods: mouseModifiers(event))
    }

    private func sendKey(_ event: TerminalKey, text: String? = nil, to surface: any TerminalBackend) {
        guard !inputParked else { return }
        var key = event
        key.text = text
        _ = surface.key(key)
    }

    private func makeKeyEvent(_ event: NSEvent, action: KeyEvent.Action) -> TerminalKey {
        TerminalKey(action: action, keycode: UInt32(event.keyCode), mods: keyModifiers(event), unshifted: unshiftedCodepoint(from: event))
    }

    private func consumedModifiers(_ flags: NSEvent.ModifierFlags) -> Mods {
        var value: Mods = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.option) { value.insert(.alt) }
        if flags.contains(.capsLock) { value.insert(.capsLock) }
        return value
    }

    private func keyModifiers(_ event: NSEvent) -> Mods {
        var value: Mods = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.control) { value.insert(.ctrl) }
        if flags.contains(.option) { value.insert(.alt) }
        if flags.contains(.command) { value.insert(.super) }
        if flags.contains(.capsLock) { value.insert(.capsLock) }
        return value
    }

    private func mouseModifiers(_ event: NSEvent) -> Mods { keyModifiers(event) }

    private func modifierForKeyCode(_ keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 57: return .capsLock
        case 58, 61: return .option
        case 59, 62: return .control
        default: return nil
        }
    }

    /// Mirrors the terminal's configured Option-as-Alt translation before
    /// AppKit interprets a key for the active keyboard layout.
    private func translatedEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translation = surface.translationMods(keyModifiers(event))
        var flags = event.modifierFlags
        for (mod, flag) in [
            (Mods.shift, NSEvent.ModifierFlags.shift),
            (Mods.ctrl, NSEvent.ModifierFlags.control),
            (Mods.alt, NSEvent.ModifierFlags.option),
            (Mods.super, NSEvent.ModifierFlags.command),
        ] {
            if translation.contains(mod) { flags.insert(flag) } else { flags.remove(flag) }
        }
        guard flags != event.modifierFlags else { return event }
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: flags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func filterSpecial(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        let value = scalar.value
        if value < 0x20 || (0xF700 ... 0xF8FF).contains(value) { return "" }
        return text
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let characters = event.characters(byApplyingModifiers: []),
              let scalar = characters.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }
}

// MARK: - NSTextInputClient

extension TerminalView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange _: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !inputParked, !text.isEmpty else { return }
        unmarkText()
        if currentKeyEvent != nil {
            keyTextAccumulator.append(text)
        } else if let surface {
            sendKey(TerminalKey(action: .press, keycode: 0, mods: []), text: text, to: surface)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        guard !inputParked, let surface else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedTextRange = text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: text.utf16.count)
        markedText = text
        selectedTextRange = selectedRange
        surface.preedit(text)
    }

    func unmarkText() {
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        markedText = ""
        surface?.preedit("")
    }

    func selectedRange() -> NSRange { selectedTextRange }
    func markedRange() -> NSRange { markedTextRange }
    func hasMarkedText() -> Bool { markedTextRange.location != NSNotFound }

    func attributedSubstring(
        forProposedRange _: NSRange,
        actualRange _: NSRangePointer?
    ) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .backgroundColor]
    }

    func characterIndex(for _: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let point = surface?.imePoint() else { return .zero }
        let (x, y, width, height) = point
        let viewPoint = NSPoint(x: x, y: bounds.height - y)
        let screenPoint = window?.convertPoint(toScreen: convert(viewPoint, to: nil)) ?? viewPoint
        return NSRect(x: screenPoint.x, y: screenPoint.y - height, width: width, height: height)
    }
}

// MARK: - Standard Edit menu (responder chain)

extension TerminalView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }

    @objc func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return surface?.hasSelection ?? false
        case #selector(paste(_:)):
            return surface != nil
                && (NSPasteboard.general.string(forType: .string).map { !$0.isEmpty } ?? false)
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return true
        }
    }
}
