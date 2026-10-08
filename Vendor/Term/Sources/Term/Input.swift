// Input encoders (Ghostty's input/key_encode.zig with its macOS behavior, mouse_encode.zig,
// paste.zig): key events, mouse events and pastes become the bytes the program reads.

/// Modifier keys (Ghostty's input.Mods bits): the keys, the locks, then which side is pressed.
public struct Mods: OptionSet, Sendable {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let shift = Mods(rawValue: 1), ctrl = Mods(rawValue: 2), alt = Mods(rawValue: 4), `super` = Mods(rawValue: 8)
    public static let capsLock = Mods(rawValue: 16), numLock = Mods(rawValue: 32)
    public static let shiftRight = Mods(rawValue: 64), ctrlRight = Mods(rawValue: 128), altRight = Mods(rawValue: 256), superRight = Mods(rawValue: 512)
    /// The keys bindings look at (Ghostty's binding()).
    public static let binding: Mods = [.shift, .ctrl, .alt, .super]

    /// The mods for the platform's key translation: option is not alt when it acts as alt.
    public func translation(_ optionAsAlt: OptionAsAlt) -> Mods { optionAsAlt.applies(self) ? subtracting(.alt) : self }

    /// Protocol modifier bits: shift 1, alt 2, ctrl 4, super 8, (hyper, meta), caps lock 64, num lock 128
    /// (kitty uses all, CSI u the low 3, mouse reports the low 3 shifted by 2).
    var bits: Int {
        [Mods.shift, .alt, .ctrl, .super, [], [], .capsLock, .numLock].enumerated().reduce(0) { !$1.element.isEmpty && contains($1.element) ? $0 | 1 << $1.offset : $0 }
    }
}

/// Whether macOS's option key acts as alt (Ghostty's macos-option-as-alt).
public enum OptionAsAlt: String {
    case `false`, `true`, left, right
    /// Alt (when pressed) counts as alt on this side.
    func applies(_ mods: Mods) -> Bool {
        switch self {
        case .false: false
        case .true: true
        case .left: !mods.contains(.altRight)
        case .right: mods.contains(.altRight)
        }
    }
}

extension Key {
    /// The key's printable code point (Ghostty's Key.codepoint).
    public var codepoint: UInt32? { let c = Unicode.byte(keyCodepoints, Int(rawValue)); return c == 0 ? nil : UInt32(c) }
    /// The key for a mac virtual keycode (NSEvent.keyCode), like ghostty_surface_key.
    public init(macKeycode: UInt32) { self = macKeycodes[macKeycode] ?? .unidentified }
}

/// One PC-style function key entry (input/function_keys.zig).
@_spi(Test) public struct FunctionKey: Sendable {
    public enum Mode: Int, Sendable { case any, normal, application }
    public enum ModifyOtherKeys: Int, Sendable { case any, set, setOther }
    public var mods: Mods, anyMods: Bool, cursor: Mode, keypad: Mode, modifyOtherKeys: ModifyOtherKeys, sequence: String, decbkm: String?
}

/// The function key entries per key, read once from the generated table.
@_spi(Test) public let functionKeys: [Key: [FunctionKey]] = functionKeyTable.utf8.split(separator: 0x0A).reduce(into: [:]) { t, line in
    let f = line.split(separator: 0x20).map { String(decoding: $0, as: UTF8.self) }, n = f.prefix(6).map { Int($0)! }
    t[Key(rawValue: UInt16(n[0]))!, default: []].append(FunctionKey(
        mods: Mods(rawValue: UInt16(n[1])), anyMods: n[2] == 1, cursor: .init(rawValue: n[3])!, keypad: .init(rawValue: n[4])!,
        modifyOtherKeys: .init(rawValue: n[5])!, sequence: f[6], decbkm: f[7] == "-" ? nil : f[7]))
}

/// Terminal modes and settings the key encoder follows (Ghostty's key_encode.Options).
public struct KeyOptions {
    public var cursorKeyApplication = false, keypadKeyApplication = false, backarrowKeyMode = false
    public var ignoreKeypadWithNumlock = false, altEscPrefix = false, modifyOtherKeys2 = false
    public var kittyFlags = KittyKeyFlags(0), optionAsAlt = OptionAsAlt.false
    public init() {}
    /// From the terminal (fromTerminal); optionAsAlt is the app's setting.
    public init(_ t: Terminal) {
        (altEscPrefix, cursorKeyApplication, keypadKeyApplication) = (t.modes.get(.altEscPrefix), t.modes.get(.cursorKeys), t.modes.get(.keypadKeys))
        (backarrowKeyMode, ignoreKeypadWithNumlock) = (t.modes.get(.backarrowKeyMode), t.modes.get(.ignoreKeypadWithNumlock))
        (modifyOtherKeys2, kittyFlags) = (t.flags.modifyOtherKeys2, t.active.kittyKeyboard.current)
    }
}

/// A key press, repeat or release with the text the platform produced for it.
public struct KeyEvent {
    public enum Action: String { case release, press, `repeat` }
    public var action = Action.press, key = Key.unidentified, mods = Mods(), consumedMods = Mods()
    /// Part of a dead-key composition; utf8 is then the preedit text.
    public var composing = false
    public var utf8: [UInt8] = [], unshiftedCodepoint: UInt32 = 0
    public init() {}

    /// Mods minus the ones consumed to produce the text.
    var effectiveMods: Mods { utf8.isEmpty ? mods : mods.subtracting(consumedMods) }
    /// The text is one control character (macOS sends some keys as those).
    var controlText: Bool { utf8.count == 1 && isControl(UInt32(utf8[0])) }

    /// The bytes for the program: kitty keyboard protocol when a kitty flag is set, legacy otherwise.
    public func encode(_ o: KeyOptions) -> [UInt8] { o.kittyFlags.isEmpty ? legacy(o) : kitty(o) }

    func kitty(_ o: KeyOptions) -> [UInt8] {
        let f = o.kittyFlags, binding = effectiveMods.intersection(.binding)
        if action == .release, !f.reportEvents || !f.reportAll && [.enter, .backspace, .tab].contains(key) { return [] }
        let entry = kittyKeys.first { $0.key == key }.map { ($0.code, $0.final, $0.modifier) }
            ?? (unshiftedCodepoint > 0 ? (unshiftedCodepoint, UInt8(ascii: "u"), false) : nil)
        if composing {
            // Only plain modifiers are sent while composing.
            guard entry?.2 == true else { return [] }
        } else {
            // IME confirmation still sends enter: its text goes as is.
            if !utf8.isEmpty, key == .enter || key == .backspace, !controlText { return key == .enter ? utf8 : [] }
            if !f.reportAll {
                if binding.isEmpty, let b = [Key.enter: UInt8(0x0D), .tab: 0x09, .backspace: 0x7F][key] { return [b] }
                if binding.isEmpty, action != .release, let cps = Decoder.decode(utf8), !cps.isEmpty, !cps.contains(where: isControl) { return utf8 }
            }
        }
        guard case let (code, final, modifier)? = entry else { return action == .release ? [] : utf8 }
        if modifier, !f.reportAll { return [] }
        let mods = mods.bits, event = f.reportEvents ? [.press: 1, .repeat: 2, .release: 3][action]! : 0
        var alternates: (shifted: UInt32?, base: UInt32?) = (nil, nil), text: [UInt32] = []
        if f.reportAlternates, !isControl(code), let cps = Decoder.decode(utf8) {
            if let cp = cps.first, cp != code, mods & 1 != 0 { alternates.shifted = cp }
            if let base = key.codepoint, base != code, cps.isEmpty || cps.count == 1 && cps[0] != base { alternates.base = base }
        }
        // Alt, ctrl, super, hyper, meta keep the text out; alt only when option acts as alt.
        if f.reportAssociated, event != 3, mods & (o.optionAsAlt.applies(self.mods) ? 0b11_1110 : 0b11_1100) == 0 {
            text = (Decoder.decode(utf8) ?? []).filter { !isControl($0) }
        }
        guard final == UInt8(ascii: "u") || final == UInt8(ascii: "~") else {
            return ascii(event > 0 ? "\u{1B}[1;\(mods + 1):\(event)" : mods > 0 ? "\u{1B}[1;\(mods + 1)" : "\u{1B}[") + [final]
        }
        var s = "\u{1B}[\(code)"
        if let a = alternates.shifted { s += ":\(a)" }
        if let b = alternates.base { s += (alternates.shifted == nil ? "::" : ":") + "\(b)" }
        let prior = event > 1 || mods > 0
        if event > 1 { s += ";\(mods + 1):\(event)" } else if mods > 0 { s += ";\(mods + 1)" }
        if !text.isEmpty { s += (prior ? ";" : ";;") + text.map(String.init).joined(separator: ":") }
        return ascii(s) + [final]
    }

    func legacy(_ o: KeyOptions) -> [UInt8] {
        let binding = effectiveMods.intersection(.binding)
        guard action != .release, !composing else { return [] }
        if let seq = functionKey(o) {
            // With text, backspace/enter/escape stay with the IME (unless the text is a control character).
            let ime = !utf8.isEmpty && [.backspace, .enter, .escape].contains(key) && !controlText
            if !ime { return seq }
            if key == .backspace { return [] }
        }
        if let c = ctrlSequence() { return binding.contains(.alt) ? [0x1B, c] : [c] }
        let prefix = altPrefix(binding, o)
        if utf8.isEmpty { return prefix.map { [0x1B, $0] } ?? [] }
        if o.modifyOtherKeys2, let cps = Decoder.decode(utf8), cps.count == 1 {
            let m = o.optionAsAlt.applies(mods) ? mods.intersection(.binding) : mods.intersection([.shift, .ctrl, .super])
            if (0x40...0x7F).contains(cps[0]) || !m.subtracting(.shift).isEmpty || cps[0] == 0x20, let i = modifyOtherKeysMods.firstIndex(of: m) {
                return ascii("\u{1B}[27;\(i + 2);\(cps[0])~")
            }
        }
        // fixterms CSI u for ctrl+character; shift counts only when the text isn't shifted.
        if mods.contains(.ctrl), let cps = Decoder.decode(utf8), cps.count == 1 {
            var (m, c) = (mods.bits & 7, cps[0])
            if (0x41...0x5A).contains(c), m & 1 != 0 { c += 0x20 }
            if unshiftedCodepoint != c { m &= ~1 }
            return ascii("\u{1B}[\(c);\(m + 1)u")
        }
        if let p = prefix { return [0x1B, p] }
        return mods.contains(.super) ? [] : utf8   // macOS: command+key sends no text
    }

    /// The byte to send after ESC for alt+key (mode 1036), when option acts as alt.
    func altPrefix(_ binding: Mods, _ o: KeyOptions) -> UInt8? {
        guard binding.contains(.alt), o.altEscPrefix, o.optionAsAlt.applies(mods) else { return nil }
        if utf8.count == 1 { return utf8[0] }
        return unshiftedCodepoint > 0 && unshiftedCodepoint < 256 ? UInt8(unshiftedCodepoint) : nil
    }

    /// The xterm PC-style function key sequence for this key under the modes (function_keys.zig).
    func functionKey(_ o: KeyOptions) -> [UInt8]? {
        let m = mods.intersection(.binding), keypad = !o.ignoreKeypadWithNumlock && o.keypadKeyApplication
        let e = functionKeys[key]?.first { e in
            (e.cursor == .any || (e.cursor == .application) == o.cursorKeyApplication)
                && (e.keypad == .any || (e.keypad == .application) == keypad)
                && (e.modifyOtherKeys == .any || (e.modifyOtherKeys == .setOther) == o.modifyOtherKeys2)
                && (e.mods.isEmpty ? m.isEmpty || e.anyMods : e.mods == m)
        }
        return e.map { Array((o.backarrowKeyMode ? $0.decbkm ?? $0.sequence : $0.sequence).utf8) }
    }

    /// Ctrl+character as a C0 byte (Kitty's table); nil when other mods or no single character.
    func ctrlSequence() -> UInt8? {
        guard mods.contains(.ctrl) else { return nil }
        var m = mods.intersection(.binding).subtracting(.alt), c: UInt8
        if utf8.count == 1 { c = utf8[0] } else if let cp = key.codepoint, m == .ctrl { c = UInt8(cp) } else { return nil }
        if !(0x40...0x5A).contains(c) { m.remove(.shift) }
        if (0x41...0x5A).contains(c), unshiftedCodepoint > 0, unshiftedCodepoint < 256 { c = UInt8(unshiftedCodepoint) }
        return m == .ctrl ? ctrlSequences[c] : nil
    }
}

func isControl(_ cp: UInt32) -> Bool { cp < 0x20 || cp == 0x7F }

/// The renderer's size (Ghostty's renderer.Size): the surface in pixels, the cell, the padding.
public struct RenderSize {
    public var screen: (width: Int, height: Int), cell: (width: Int, height: Int)
    public var padding: (top: Int, bottom: Int, right: Int, left: Int)
    public init(screen: (width: Int, height: Int), cell: (width: Int, height: Int), padding: (top: Int, bottom: Int, right: Int, left: Int) = (0, 0, 0, 0)) {
        (self.screen, self.cell, self.padding) = (screen, cell, padding)
    }
    public enum Balance: String { case off = "false", on = "true", equal }

    /// Pixels for a padding given in points (Ghostty's scaledPadding: f32 arithmetic, floored).
    public static func pixels(points: Int, dpi: Float) -> Int { Int((Float(points) * dpi / 72).rounded(.down)) }

    /// The explicit padding, or (balanced) the padding that centers the grid the explicit one leaves
    /// (Ghostty's Size.balancePadding; `on` then moves the extra top space to the bottom).
    public mutating func pad(_ explicit: (top: Int, bottom: Int, right: Int, left: Int), _ balance: Balance) {
        padding = explicit
        guard balance != .off else { return }
        let g = grid
        let space = { (screen: Int, n: Int, cell: Int) in max(0, Int(((Float(screen) - Float(n) * Float(cell)) / 2).rounded(.down))) }
        let (h, v) = (space(screen.width, g.cols, cell.width), space(screen.height, g.rows, cell.height))
        padding = (v, v, h, h)
        if balance == .on {
            let shift = max(0, v - (explicit.left + explicit.right + cell.width) / 2)
            (padding.top, padding.bottom) = (v - shift, v + shift)
        }
    }

    /// Columns and rows that fit (at least 1 each), in Ghostty's float arithmetic.
    public var grid: (cols: Int, rows: Int) {
        let (w, h) = (max(screen.width - padding.left - padding.right, 0), max(screen.height - padding.top - padding.bottom, 0))
        return (max(1, Int(Float(w) / Float(cell.width))), max(1, Int(Float(h) / Float(cell.height))))
    }
}

/// Mouse reporting state the encoder follows (Ghostty's mouse_encode.Options).
public struct MouseOptions {
    public var event: TerminalFlags.MouseEvent, format: TerminalFlags.MouseFormat, size: RenderSize
    /// Any button is held (out-of-viewport motion is reported only then).
    public var anyButtonPressed = false
    public init(_ t: Terminal, size: RenderSize) { (event, format, self.size) = (t.flags.mouseEvent, t.flags.mouseFormat, size) }
}

public struct MouseEvent {
    public enum Action: String { case press, release, motion }
    public enum Button: String { case unknown, left, right, middle, four, five, six, seven, eight, nine, ten, eleven }
    public var action: Action, button: Button?, mods: Mods
    /// Surface pixels (padding included); may be outside the surface.
    public var x: Float, y: Float
    public init(action: Action, button: Button?, mods: Mods, x: Float, y: Float) { (self.action, self.button, self.mods, self.x, self.y) = (action, button, mods, x, y) }

    /// The report for the program, if the mode reports this event. `lastCell` is the last reported
    /// cell: motion within it is not reported again.
    public func encode(_ o: MouseOptions, lastCell: inout (x: Int, y: Int)?) -> [UInt8] {
        let reports = switch o.event {
        case .none: false
        case .x10: action == .press && [.left, .middle, .right].contains(button)
        case .normal: action != .motion
        case .button: button != nil
        case .any: true
        }
        guard reports else { return [] }
        let s = o.size, grid = s.grid, (px, py) = (Double(x) - Double(s.padding.left), Double(y) - Double(s.padding.top))
        if action != .release, x < 0 || y < 0 || x > Float(s.screen.width) || y > Float(s.screen.height),
           !(o.event == .button || o.event == .any) || !o.anyButtonPressed { return [] }
        let cell = (x: min(Int(max(0, px) / Double(s.cell.width)), grid.cols - 1), y: min(Int(max(0, py) / Double(s.cell.height)), grid.rows - 1))
        if action == .motion, o.format != .sgrPixels, let l = lastCell, l == cell { return [] }
        lastCell = cell
        let sgr = o.format == .sgr || o.format == .sgrPixels
        guard var code = button == nil || action == .release && !sgr ? 3 : [.left: 0, .middle: 1, .right: 2, .four: 64, .five: 65, .six: 66, .seven: 67, .eight: 128, .nine: 129][button!] else { return [] }
        if o.event != .x10 { code |= (mods.bits & 7) << 2 }
        if action == .motion { code += 32 }
        let end = action == .release ? "m" : "M"
        switch o.format {
        case .x10: return cell.x > 222 || cell.y > 222 ? [] : [0x1B, 0x5B, 0x4D, UInt8(32 + code), UInt8(33 + cell.x), UInt8(33 + cell.y)]
        case .utf8:
            var out: [UInt8] = [0x1B, 0x5B, 0x4D, UInt8(32 + code)]
            utf8(UInt32(cell.x + 33), &out)
            utf8(UInt32(cell.y + 33), &out)
            return out
        case .sgr: return ascii("\u{1B}[<\(code);\(cell.x + 1);\(cell.y + 1)\(end)")
        case .urxvt: return ascii("\u{1B}[\(32 + code);\(cell.x + 1);\(cell.y + 1)M")
        case .sgrPixels: return ascii("\u{1B}[<\(code);\(Int32(px.rounded()));\(Int32(py.rounded()))\(end)")
        }
    }
}

/// Paste settings the encoder follows (Ghostty's paste.Options).
public struct PasteOptions {
    public var bracketed = false
    public init() {}
    public init(_ t: Terminal) { bracketed = t.modes.get(.bracketedPaste) }
}

public enum Paste {
    /// The bytes for the program in the pieces the surface writes one by one: unsafe control bytes
    /// become spaces; bracketed paste (mode 2004) frames the data, otherwise newlines become
    /// carriage returns.
    public static func encode(_ data: [UInt8], _ o: PasteOptions) -> [[UInt8]] {
        let d = data.map { pasteStrip.contains($0) ? 0x20 : $0 }
        return o.bracketed ? [ascii("\u{1B}[200~"), d, ascii("\u{1B}[201~")] : [d.map { $0 == 0x0A ? 0x0D : $0 }]
    }

    /// No newline and no end-of-paste sequence: nothing that could run a command by itself.
    public static func isSafe(_ data: [UInt8]) -> Bool { !data.contains(0x0A) && data.firstRange(of: ascii("\u{1B}[201~")) == nil }
}
