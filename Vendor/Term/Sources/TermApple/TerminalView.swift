// A terminal in an NSView, like Ghostty's macOS SurfaceView: a Session (a shell on a pty, the
// surface, Metal frames into its layer) behind AppKit's keys, mouse and IME, which go through the
// surface's encoders to the pty.
#if canImport(AppKit)
import AppKit
import CoreText
import Metal
import QuartzCore
import Term

public final class TerminalView: NSView, NSTextInputClient, SurfaceHost {
    public let session: Session
    var surface: Surface { session.surface }
    let scale: CGFloat
    var marked = NSMutableAttributedString(), keyText: [String]?

    /// `config`: Ghostty config (the default: Ghostty's defaults at macOS size 13, no bindings), at
    /// the screen's scale. Host file/shared-memory graphics are opt-in because `shell` may run SSH.
    public init(frame: NSRect, config: Config = Config(), allowHostMedia: Bool = false) {
        scale = NSScreen.main?.backingScaleFactor ?? 2
        session = try! Session(config: config, scale: Double(scale), allowHostMedia: allowHostMedia)
        super.init(frame: frame)
        session.host(in: self)
        session.surface.host = self
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { true }

    /// The viewport's text (read under the lock: the IO queue may be parsing).
    public func visibleText() -> String { locked { String(decoding: surface.readText(.viewport), as: UTF8.self) } }

    func locked<T>(_ body: () throws -> T) rethrows -> T { try session.locked(body) }
    func pump() { session.pump() }

    /// Only clipboard reads caused by a local paste gesture can be confirmed without presenting a
    /// prompt. This view has no prompt UI, so every program-initiated request remains unconfirmed.
    @_spi(Test) public static func automaticallyConfirmsClipboard(_ request: ClipboardRequest) -> Bool {
        if case .paste = request { return true }
        return false
    }

    /// Starts `shell` (nil: the user's login shell) in the user's home, the window closing when it ends.
    public func start(shell: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        session.onExit = { [weak self] _ in self?.window?.close() }
        try? session.start(Launch(command: shell, directory: NSHomeDirectory(), overrides: [], config: locked { session.config }, environment: env,
                                  resources: env["GHOSTTY_RESOURCES_DIR"].flatMap { $0.isEmpty ? nil : $0 }, id: UInt64.random(in: 1 ... .max)))
    }

    public override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        session.setSize(width: Int(size.width * scale), height: Int(size.height * scale))
    }

    // MARK: focus, keys and text (SurfaceView_AppKit keyDown/keyUp/flagsChanged)

    public override func becomeFirstResponder() -> Bool { session.setFocus(true); return true }
    public override func resignFirstResponder() -> Bool { session.setFocus(false); return true }

    static func mods(_ f: NSEvent.ModifierFlags) -> Mods {
        var m: Mods = []
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, Mods.shift), (.control, .ctrl), (.option, .alt), (.command, .super), (.capsLock, .capsLock)] where f.contains(flag) { m.insert(mod) }
        for (mask, mod) in [(0x04, Mods.shiftRight), (0x2000, .ctrlRight), (0x40, .altRight), (0x10, .superRight)] where Int(f.rawValue) & mask != 0 { m.insert(mod) }
        return m
    }

    func key(_ action: KeyEvent.Action, _ event: NSEvent, translation: NSEvent.ModifierFlags? = nil, text: String? = nil, composing: Bool = false) {
        let unshifted = event.type == .keyDown || event.type == .keyUp ? event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0 : 0
        // String.keyEventText: no text that starts with a control character.
        let bytes = text.flatMap { $0.isEmpty || $0.unicodeScalars.first!.value < 0x20 || $0.unicodeScalars.first!.value == 0x7F ? nil : Array($0.utf8) } ?? []
        _ = locked { surface.key(action, keycode: UInt32(event.keyCode), mods: Self.mods(event.modifierFlags),
                                 consumed: Self.mods((translation ?? event.modifierFlags).subtracting([.control, .command])), composing: composing, unshifted: unshifted, text: bytes) }
    }

    public override func keyDown(with event: NSEvent) {
        var flags = event.modifierFlags
        let translated = locked { surface.translationMods(Self.mods(flags)) }
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, Mods.shift), (.control, .ctrl), (.option, .alt), (.command, .super)] {
            if translated.contains(mod) { flags.insert(flag) } else { flags.remove(flag) }
        }
        let translation = flags == event.modifierFlags ? event : NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: flags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        let action: KeyEvent.Action = event.isARepeat ? .repeat : .press
        keyText = []
        defer { keyText = nil }
        let markedBefore = marked.length > 0
        interpretKeyEvents([translation])
        syncPreedit(clear: markedBefore)
        let composing = marked.length > 0 || markedBefore
        let suppress = { (t: String?) in composing && t.map { $0.unicodeScalars.count == 1 && $0.unicodeScalars.first!.value < 0x20 } == true }
        if let list = keyText, !list.isEmpty {
            for t in list where !suppress(t) { key(action, event, translation: translation.modifierFlags, text: t) }
        } else if !suppress(event.characters) {
            // NSEvent.ghosttyCharacters: control characters as their unmodified key, no function-key PUA.
            var text = translation.characters
            if let s = text?.unicodeScalars, s.count == 1, let v = s.first?.value {
                if v < 0x20 { text = translation.characters(byApplyingModifiers: translation.modifierFlags.subtracting(.control)) }
                if (0xF700...0xF8FF).contains(v) { text = nil }
            }
            key(action, event, translation: translation.modifierFlags, text: text, composing: composing)
        }
        pump()
    }

    public override func keyUp(with event: NSEvent) { key(.release, event); pump() }

    public override func flagsChanged(with event: NSEvent) {
        let pairs: [UInt16: (Mods, Int)] = [0x39: (.capsLock, 0), 0x38: (.shift, 0), 0x3C: (.shift, 0x04), 0x3B: (.ctrl, 0), 0x3E: (.ctrl, 0x2000),
                                           0x3A: (.alt, 0), 0x3D: (.alt, 0x40), 0x37: (.super, 0), 0x36: (.super, 0x10)]
        guard let (mod, side) = pairs[event.keyCode], !hasMarkedText() else { return }
        let down = Self.mods(event.modifierFlags).contains(mod) && (side == 0 || Int(event.modifierFlags.rawValue) & side != 0)
        key(down ? .press : .release, event)
        pump()
    }

    func syncPreedit(clear: Bool) {
        locked { if marked.length > 0 { surface.setPreedit(Array(marked.string.utf8)) } else if clear { surface.setPreedit([]) } }
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        marked = NSMutableAttributedString()
        if keyText != nil { keyText!.append(text) } else { locked { surface.text(Array(text.utf8)) }; pump() }
    }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = NSMutableAttributedString(string: (string as? NSAttributedString)?.string ?? string as? String ?? "")
        if keyText == nil { syncPreedit(clear: true); pump() }
    }
    public func unmarkText() { marked = NSMutableAttributedString(); syncPreedit(clear: true); pump() }
    public func hasMarkedText() -> Bool { marked.length > 0 }
    public func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public override func doCommand(by selector: Selector) {}
    /// The IME candidate window goes at the cursor.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let (at, size) = locked { (surface.terminal.cursorViewport ?? (x: 0, y: 0), surface.size) }
        let cell = NSRect(x: CGFloat(at.x * size.cell.width) / scale, y: CGFloat(at.y * size.cell.height) / scale,
                          width: CGFloat(size.cell.width) / scale, height: CGFloat(size.cell.height) / scale)
        return window?.convertToScreen(convert(cell, to: nil)) ?? cell
    }

    // MARK: mouse

    func position(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        locked { surface.mousePos(x: Double(p.x), y: Double(p.y), mods: Self.mods(event.modifierFlags)) }
    }
    func button(_ state: Surface.MouseButtonState, _ b: MouseEvent.Button, _ event: NSEvent) {
        position(event)
        _ = locked { surface.mouseButton(state, b, mods: Self.mods(event.modifierFlags)) }
        pump()
    }
    public override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); button(.press, .left, event) }
    public override func mouseUp(with event: NSEvent) { button(.release, .left, event) }
    public override func rightMouseDown(with event: NSEvent) { button(.press, .right, event) }
    public override func rightMouseUp(with event: NSEvent) { button(.release, .right, event) }
    public override func otherMouseDown(with event: NSEvent) { button(.press, .middle, event) }
    public override func otherMouseUp(with event: NSEvent) { button(.release, .middle, event) }
    public override func mouseMoved(with event: NSEvent) { position(event); pump() }
    public override func mouseDragged(with event: NSEvent) { position(event); pump() }
    public override func rightMouseDragged(with event: NSEvent) { position(event); pump() }
    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas, k = precise ? 2.0 : 1.0
        let phases: [(NSEvent.Phase, UInt8)] = [(.began, 1), (.stationary, 2), (.changed, 3), (.ended, 4), (.cancelled, 5), (.mayBegin, 6)]
        let momentum = phases.first { $0.0 == event.momentumPhase }?.1 ?? 0
        locked { surface.scroll(x: Double(event.scrollingDeltaX) * k, y: Double(event.scrollingDeltaY) * k, mods: (precise ? 1 : 0) | momentum << 1) }
        pump()
    }

    // MARK: SurfaceHost

    public func perform(_ action: SurfaceAction) -> Bool {
        if case .setTitle(let t) = action { window?.title = String(decoding: t, as: UTF8.self); return true }
        return false
    }
    public func setClipboard(_ location: SurfaceMessage.Clipboard, _ contents: [ClipboardContent], confirm: Bool) {
        guard location == .standard, !confirm, let text = contents.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: text.data, as: UTF8.self), forType: .string)
    }
    public func clipboardRequest(_ location: SurfaceMessage.Clipboard, _ request: ClipboardRequest, mimes: [[UInt8]], list: Bool) -> ClipboardReadResult {
        let plain = Array("text/plain".utf8), wantsText = mimes.contains(plain)
        let write = if case .kittyWrite = request { true } else { false }
        guard location == .standard, wantsText || list || write else { return .unsupported }
        let text = NSPasteboard.general.string(forType: .string)
        guard !wantsText || text != nil else { return .unavailable }
        var completion = ClipboardCompletion(
            contents: text.map { [ClipboardContent(mime: plain, data: Array($0.utf8))] } ?? [],
            available: list && text != nil ? [plain] : []
        )
        do {
            try locked { try surface.completeClipboard(request, completion) }
        } catch {
            // A paste is a local user gesture. Program-initiated requests that require consent are
            // denied because this host has no clipboard confirmation UI.
            guard Self.automaticallyConfirmsClipboard(request) else {
                locked { surface.denyClipboard(request) }
                return .started
            }
            completion.confirmed = true
            try? locked { try surface.completeClipboard(request, completion) }
        }
        return .started
    }
    public func open(_ kind: SurfaceAction.OpenKind, _ url: [UInt8]) throws {
        if let u = URL(string: String(decoding: url, as: UTF8.self)) { NSWorkspace.shared.open(u) }
    }
    public func exists(_ path: [UInt8]) -> Bool { FileManager.default.fileExists(atPath: String(decoding: path, as: UTF8.self)) }
}
#endif
