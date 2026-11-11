// Input, IME, and Edit-menu integration adapted from umputun/agterm and
// thdxg/macterm (MIT).
import AppKit
import Term

extension TerminalView {
    /// Offline, or gone from its server (`TerminalTab.gone`, read-only for good).
    var inputParked: Bool {
        inputSuspensions > 0 || TerminalRuntime.shared.hosts.reconnect.state(for: id) != nil
            || TerminalRuntime.shared.workspace?.isGone(id) == true
    }

    var agentMenuScreen: String {
        guard let surface else { return "" }
        // Read while hidden: a held chat terminal follows again so the text read is current (HelperWorkspace).
        if !onScreen { TerminalRuntime.shared.workspace?.helper(containing: id)?.screenRead(id) }
        return String(surface.readText(.active).prefix(65_536))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit can interpret Control shortcuts as text commands before
        // keyDown. The focused terminal must send them to the terminal directly.
        // Command/Option shortcuts and active IME composition keep their
        // normal responder-chain handling, as do the app's Settings › Keyboard digit chords and ⌃⇥.
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
        TerminalRuntime.shared.programs.acknowledge(id)
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
        // ⌃-click opens the terminal's menu, as in Terminal and iTerm2, unless the program reads the mouse.
        if event.modifierFlags.intersection([.control, .option, .shift, .command]) == .control, !surface.mouseCaptured {
            showContextMenu(event)
            return
        }
        reportMousePosition(event)
        _ = surface.mouseButton(.press, .left, mods: mouseModifiers(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        reportMousePosition(event)
        _ = surface.mouseButton(.release, .left, mods: mouseModifiers(event))
    }

    /// A program reading the mouse gets the click. Otherwise the terminal's menu opens, after the engine selected the
    /// word or link under the pointer (Ghostty's right-click-action = context-menu).
    override func rightMouseDown(with event: NSEvent) {
        guard !inputParked, let surface else { return }
        reportMousePosition(event)
        guard !surface.mouseButton(.press, .right, mods: mouseModifiers(event)) else { return }
        // The menu takes the release: the engine gets it now, so its button is not left held.
        _ = surface.mouseButton(.release, .right, mods: mouseModifiers(event))
        if window?.makeFirstResponder(self) == true { select() }
        showContextMenu(event)
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

    /// Under test the physical pointer is not the test's: resting or moving over a terminal it would type mouse
    /// reports into programs that track every motion (Pi's TUI), different on every run and machine, so a recording
    /// could never replay. Tests drive terminals with keys, clicks and drags; motion and entry come only from the user.
    private var followsPointer: Bool { !System.testing }

    override func mouseMoved(with event: NSEvent) {
        guard followsPointer else { return }
        reportMousePosition(event)
    }
    override func mouseDragged(with event: NSEvent) { reportMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { reportMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { reportMousePosition(event) }

    override func mouseEntered(with event: NSEvent) {
        guard followsPointer else { return }
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
        trackTypeahead(key)
        _ = surface.key(key)
    }

    private func trackTypeahead(_ key: TerminalKey) {
        guard key.action != .release, modifierForKeyCode(UInt16(clamping: key.keycode)) == nil else { return }
        let plain = key.mods.intersection([.ctrl, .alt, .super]).isEmpty
        if key.keycode == 36 || key.keycode == 76 {
            // Shift- or Option-Return breaks the line in an agent's prompt; adoption checks that it did.
            if key.mods.intersection([.ctrl, .super]).isEmpty, !key.mods.intersection([.shift, .alt]).isEmpty {
                typeahead?.append("\n")
                return
            }
            if plain, !key.mods.contains(.shift), let line = typeahead, !line.isEmpty, !line.contains("\n") {
                TerminalRuntime.shared.chat.terminalSubmitted(line, tab: id)
            }
            typeahead = plain && !key.mods.contains(.shift) ? "" : nil
        } else if key.keycode == 51, key.mods.subtracting(.capsLock).isEmpty {
            typeahead = typeahead.map { String($0.dropLast()) }
        } else if key.composing, key.text == nil {
            // Preedit updates commit their text separately.
        } else if plain, let text = key.text, !text.isEmpty,
                  !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            typeahead?.append(text)
        } else {
            typeahead = nil
        }
    }

    /// Erases `count` characters before the cursor, as the user's Delete key does.
    func eraseTypedCharacters(_ count: Int) {
        guard let surface, !inputParked else { return }
        for _ in 0..<count { sendKey(TerminalKey(action: .press, keycode: 51, mods: []), text: "\u{7f}", to: surface) }
    }

    /// Control-E, then `count` Deletes: from wherever the cursor was, an agent's prompt loses that many characters
    /// from its end (Claude Code 2.1.321, Codex 0.167: wrapped and multiline text alike).
    func eraseAgentPrompt(_ count: Int) {
        guard let surface, !inputParked else { return }
        sendKey(TerminalKey(action: .press, keycode: 14, mods: .ctrl, unshifted: 101), to: surface)
        eraseTypedCharacters(count)
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

// MARK: - Context menu

extension TerminalView {
    /// The terminal's menu at the pointer, its own items alone: a context menu (`popUpContextMenu`) for a view that
    /// takes text input gets the system's AutoFill and Services items added, which mean nothing in a terminal.
    func showContextMenu(_ event: NSEvent) {
        contextMenu().popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    /// The terminal's right-click (and ⌃-click) menu: Copy, Paste and Select All; the link under the pointer; Clear
    /// Screen; splitting. Its items act on this terminal, which the click selected. The modes are the strip's mode
    /// button's.
    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        func add(_ title: String, enabled: Bool = true, checked: Bool = false, _ action: @escaping @MainActor () -> Void) {
            let item = TerminalMenuItem(title: title, run: action)
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("Copy", enabled: surface?.hasSelection == true) { [weak self] in self?.copy(nil) }
        add("Paste", enabled: !inputParked && NSPasteboard.general.string(forType: .string).map { !$0.isEmpty } == true) { [weak self] in
            self?.paste(nil)
        }
        add("Select All", enabled: surface != nil) { [weak self] in self?.selectAll(nil) }
        // The right press selected the link under the pointer, if any.
        if let link = surface?.readSelection()?.trimmingCharacters(in: .whitespacesAndNewlines),
           TerminalLinkPolicy.opensHyperlink(link) {
            menu.addItem(.separator())
            add("Open Link") {
                let opener = Process()
                opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                opener.arguments = [link]
                try? opener.run()
            }
            add("Copy Link") { TerminalClipboard.write(link) }
        }
        menu.addItem(.separator())
        add("Clear Screen", enabled: canClearScreen) { [weak self] in _ = self?.performBindingAction("clear_screen") }
        let workspace = TerminalRuntime.shared.workspace
        if presentation == .workspace, let workspace {
            add("Split Right", enabled: workspace.canSplitPane()) { workspace.splitPane(.columns) }
            add("Split Down", enabled: workspace.canSplitPane()) { workspace.splitPane(.rows) }
        }
        return menu
    }

    /// ⌘K and the menus' Clear Screen: not while a full-screen program shows (the engine leaves its screen alone), nor
    /// in a tmux or herdr tab, whose history is the server's and stays there.
    var canClearScreen: Bool {
        guard let surface, !surface.alternateScreen else { return false }
        guard let workspace = TerminalRuntime.shared.workspace,
              let space = workspace.spaces.first(where: { $0.tabs.contains { $0.surfaceIDs.contains(id) } }),
              let helper = workspace.helper(space), let backend = space.backend else { return true }
        return !helper.external(backend)
    }
}

// MARK: - Services

extension TerminalView: @preconcurrency NSServicesMenuRequestor {
    /// The selection goes to Services (Search With, Open man Page, Make New Sticky Note); nothing comes back into the
    /// terminal, whose input is typing.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if returnType == nil, sendType == .string, surface?.hasSelection == true { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string), let text = surface?.readSelection(), !text.isEmpty else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }
}

/// A menu item that runs its closure.
@MainActor final class TerminalMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    @objc private func runAction(_ sender: Any?) { run() }
}

// MARK: - Standard Edit menu (responder chain)

extension TerminalView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }

    @objc func paste(_ sender: Any?) {
        guard performBindingAction("paste_from_clipboard") else { return }
        if let text = NSPasteboard.general.string(forType: .string) { typeahead?.append(text) }
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
