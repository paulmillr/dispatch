import Foundation
@preconcurrency import Term

/// A key the phone sends to the terminal: Term's encoder reads the Mac's virtual keycodes (`Key(macKeycode:)`,
/// Ghostty's embedded API), so the software keyboard, the key capsule and hardware keyboards all name keys that way.
struct TerminalInputKey: Equatable, Sendable {
    var keycode: UInt32
    /// The text the key produces without Ctrl (empty for function keys).
    var text: String = ""
    var mods: Mods = []

    /// The unshifted code point of a text key (Ghostty's unshifted_codepoint).
    var unshifted: UInt32 { text.lowercased().unicodeScalars.first.map(\.value) ?? 0 }

    static let unidentified: UInt32 = 0xFFFF

    static let enter = TerminalInputKey(keycode: 0x24)
    static let tab = TerminalInputKey(keycode: 0x30)
    static let backspace = TerminalInputKey(keycode: 0x33)
    static let escape = TerminalInputKey(keycode: 0x35)
    static let left = TerminalInputKey(keycode: 0x7B)
    static let right = TerminalInputKey(keycode: 0x7C)
    static let down = TerminalInputKey(keycode: 0x7D)
    static let up = TerminalInputKey(keycode: 0x7E)
    static let home = TerminalInputKey(keycode: 0x73)
    static let end = TerminalInputKey(keycode: 0x77)
    static let pageUp = TerminalInputKey(keycode: 0x74)
    static let pageDown = TerminalInputKey(keycode: 0x79)
    static let deleteForward = TerminalInputKey(keycode: 0x75)
    /// F1 to F12.
    static let functionKeycodes: [UInt32] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]

    func with(_ extra: Mods) -> TerminalInputKey {
        var key = self
        key.mods.formUnion(extra)
        return key
    }

    /// A typed character: its physical key on a US layout when it has one (Ctrl and Alt chords and the kitty
    /// keyboard protocol need it), shift when the character is the key's shifted one.
    static func character(_ character: Character, mods: Mods = []) -> TerminalInputKey {
        let text = String(character)
        switch character {
        case "\r", "\n": return enter.with(mods)
        case "\t": return tab.with(mods)
        case "\u{7F}", "\u{8}": return backspace.with(mods)
        case "\u{1B}": return escape.with(mods)
        default: break
        }
        if let code = usLayout[character] { return TerminalInputKey(keycode: code, text: text, mods: mods) }
        if let lower = character.lowercased().first, lower != character, let code = usLayout[lower] {
            return TerminalInputKey(keycode: code, text: text, mods: mods.union(.shift))
        }
        if let base = shifted[character], let code = usLayout[base] {
            return TerminalInputKey(keycode: code, text: text, mods: mods.union(.shift))
        }
        return TerminalInputKey(keycode: unidentified, text: text, mods: mods)
    }

    /// A US key with Shift held: its shifted character on the key's own keycode (UIKeyCommand names the unshifted one).
    static func withShift(_ base: Character) -> TerminalInputKey {
        guard let code = usLayout[base] else { return character(base) }
        let shifted = Self.shifted.first { $0.value == base }?.key ?? Character(String(base).uppercased())
        return TerminalInputKey(keycode: code, text: String(shifted))
    }

    /// The Mac's ANSI keycodes for the unshifted characters.
    static let usLayout: [Character: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14,
        "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31, "`": 0x32,
    ]

    /// Shifted characters on a US layout and their unshifted key.
    static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]
}

/// The key capsule's state (M6a): Ctrl and Alt latch for the next key (tap), or stay on (double tap) until tapped
/// again; Esc and Tab send at once. Holding the d-pad key shows the arrow cluster: dragging onto an arrow or Return
/// sends it and repeats it while the finger stays; lifting hides the cluster. A short tap pins the cluster open so
/// its keys can be tapped (each repeating while held) until the d-pad key is tapped again.
///
/// Time is passed in (`Duration` since any fixed origin), so tests drive it with their own clock; `nextDeadline`
/// says when `advance(to:)` has something to do.
struct KeyCapsuleModel: Equatable, Sendable {
    enum Modifier: Equatable, Sendable { case ctrl, alt }
    enum Latch: Equatable, Sendable { case off, once, locked }
    enum Arrow: Equatable, Sendable, CaseIterable { case up, down, left, right, enter }
    enum Cluster: Equatable, Sendable {
        case hidden
        /// The d-pad key is down, not yet long enough to show the cluster.
        case pressing(since: Duration)
        /// Shown while the finger that held the d-pad key stays down.
        case holding
        /// Shown after a tap, until the d-pad key is tapped again.
        case pinned
    }

    static let doubleTap = Duration.milliseconds(350)
    static let holdDelay = Duration.milliseconds(250)
    static let repeatDelay = Duration.milliseconds(400)
    static let repeatInterval = Duration.milliseconds(80)

    private(set) var ctrl = Latch.off
    private(set) var alt = Latch.off
    private var lastTap: (modifier: Modifier, at: Duration)?
    private(set) var cluster = Cluster.hidden
    /// The arrow being held and when it repeats next.
    private(set) var held: Arrow?
    private var nextRepeat: Duration?

    static func == (a: KeyCapsuleModel, b: KeyCapsuleModel) -> Bool {
        a.ctrl == b.ctrl && a.alt == b.alt && a.cluster == b.cluster && a.held == b.held && a.nextRepeat == b.nextRepeat
            && a.lastTap?.modifier == b.lastTap?.modifier && a.lastTap?.at == b.lastTap?.at
    }

    var clusterVisible: Bool { cluster == .holding || cluster == .pinned }

    /// The latched modifiers, without using them up.
    var mods: Mods {
        var mods: Mods = []
        if ctrl != .off { mods.insert(.ctrl) }
        if alt != .off { mods.insert(.alt) }
        return mods
    }

    func latch(_ modifier: Modifier) -> Latch { modifier == .ctrl ? ctrl : alt }

    mutating func tap(_ modifier: Modifier, at time: Duration) {
        let current = latch(modifier)
        let quick = lastTap.map { $0.modifier == modifier && time - $0.at <= Self.doubleTap } ?? false
        let next: Latch = switch current {
        case .off: .once
        case .once: quick ? .locked : .off
        case .locked: .off
        }
        if modifier == .ctrl { ctrl = next } else { alt = next }
        lastTap = next == .once ? (modifier, time) : nil
    }

    /// The modifiers for a key being sent now: one-shot latches are used up.
    mutating func consume() -> Mods {
        let mods = self.mods
        if ctrl == .once { ctrl = .off }
        if alt == .once { alt = .off }
        return mods
    }

    mutating func dpadDown(at time: Duration) {
        if cluster == .hidden { cluster = .pressing(since: time) }
    }

    /// The finger left the d-pad key (or the cluster it dragged into). A tap toggles the pinned cluster.
    mutating func dpadUp(at time: Duration) {
        switch cluster {
        case .pressing: cluster = .pinned
        case .holding: cluster = .hidden
        case .pinned: cluster = .hidden
        case .hidden: break
        }
        release()
    }

    /// The holding finger is over `arrow` (nil: between keys). Entering a key presses it.
    mutating func drag(over arrow: Arrow?, at time: Duration) -> [Arrow] {
        guard cluster == .holding, arrow != held else { return [] }
        guard let arrow else { release(); return [] }
        return press(arrow, at: time)
    }

    /// A finger went down on a key of the pinned cluster.
    mutating func keyDown(_ arrow: Arrow, at time: Duration) -> [Arrow] {
        guard cluster == .pinned else { return [] }
        return press(arrow, at: time)
    }

    mutating func keyUp() { release() }

    /// Everything off: latches released, the cluster hidden (the capsule collapsed).
    mutating func reset() {
        ctrl = .off
        alt = .off
        lastTap = nil
        hideCluster()
    }

    /// Hides the cluster (the keyboard or the view went away).
    mutating func hideCluster() {
        cluster = .hidden
        release()
    }

    private mutating func press(_ arrow: Arrow, at time: Duration) -> [Arrow] {
        held = arrow
        nextRepeat = time + Self.repeatDelay
        return [arrow]
    }

    private mutating func release() {
        held = nil
        nextRepeat = nil
    }

    /// When `advance(to:)` next changes something.
    var nextDeadline: Duration? {
        if case .pressing(let since) = cluster { return since + Self.holdDelay }
        return nextRepeat
    }

    /// Time passed: the held d-pad key shows the cluster; a held arrow repeats (each due repeat once).
    mutating func advance(to time: Duration) -> [Arrow] {
        if case .pressing(let since) = cluster, time >= since + Self.holdDelay { cluster = .holding }
        guard let held, var due = nextRepeat else { return [] }
        var sent: [Arrow] = []
        while due <= time {
            sent.append(held)
            due += Self.repeatInterval
        }
        nextRepeat = due
        return sent
    }

    static func key(_ arrow: Arrow) -> TerminalInputKey {
        switch arrow {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .enter: .enter
        }
    }
}
