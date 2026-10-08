// Unicode properties from tables generated out of the pinned Ghostty
// (unicode/props.zig), grapheme breaks from uucode's rules (unicode/grapheme.zig).
// Never Apple's or Swift's Unicode data: their versions and width rules differ.

/// Ghostty's `Properties` (packed u16): width u2, width_zero_in_grapheme,
/// grapheme_break u5, emoji_vs_base.
public struct Props {
    public let raw: UInt16
    public var width: Int { Int(raw & 3) }
    public var widthZeroInGrapheme: Bool { raw & 4 != 0 }
    public var graphemeBreak: UInt8 { UInt8(raw >> 3 & 31) }
    public var emojiVSBase: Bool { raw & 0x100 != 0 }
}

public enum Unicode {
    /// Entry i of a generated table (static data stored as byte + 1, see Tables.swift).
    @inline(__always) static func byte(_ table: StaticString, _ i: Int) -> Int { Int(table.utf8Start[i]) &- 1 }

    public static func props(_ cp: UInt32) -> Props {
        precondition(cp <= 0x10FFFF)
        // `+`, not `|`: the tables' -1 offsets then fold into the load addresses.
        let i = byte(propsIndex, byte(propsBlocks, Int(cp >> 8)) << 8 + Int(cp & 0xFF))
        return Props(raw: UInt16(truncatingIfNeeded: byte(propsValues, 2 * i) &+ byte(propsValues, 2 * i + 1) << 7))
    }

    /// Whether a grapheme break lies between cp1 and cp2; `state` carries the
    /// sequence state (regional indicators, emoji ZWJ, Indic conjuncts). Loops over many code
    /// points pass `table` once: reading the lazily built global costs a runtime call each time.
    public static func graphemeBreak(_ cp1: UInt32, _ cp2: UInt32, _ state: inout UInt8, _ table: UnsafePointer<UInt8> = graphemeBreaks) -> Bool {
        let n = BreakClass.count
        let v = table[(Int(state) * n + Int(props(cp1).graphemeBreak)) * n + Int(props(cp2).graphemeBreak)]
        state = v >> 1
        return v & 1 != 0
    }
}

/// uucode's GraphemeBreakNoControl (the values of Props.graphemeBreak) and grapheme.BreakState.
private enum BreakClass: UInt8, CaseIterable {
    case other, prepend, regionalIndicator, spacingMark, l, v, t, lv, lvt, zwj, zwnj, extendedPictographic, emojiModifierBase, emojiModifier,
         icbExtend, icbLinker, icbConsonant
    static var count: Int { Int(icbConsonant.rawValue) + 1 }
    func `in`(_ set: BreakClass...) -> Bool { set.contains(self) }
    var extend: Bool { self.in(.zwnj, .icbExtend, .icbLinker) }
    var icbExtend: Bool { self.in(.icbExtend, .zwj) }
    var pictographic: Bool { self.in(.extendedPictographic, .emojiModifierBase) }
}
private enum BreakState: UInt8, CaseIterable { case none, regionalIndicator, extendedPictographic, icbConsonant, icbLinker }

/// uucode's computeGraphemeBreakNoControl (UAX #29 without controls, which Ghostty handles first).
private func breaks(_ gb1: BreakClass, _ gb2: BreakClass, _ state: inout BreakState) -> Bool {
    switch state {
    case .regionalIndicator: if gb1 != .regionalIndicator || gb2 != .regionalIndicator { state = .none }
    case .extendedPictographic:
        let keep = { (g: BreakClass) in g.in(.icbExtend, .icbLinker, .zwnj, .zwj, .extendedPictographic, .emojiModifierBase, .emojiModifier) }
        if !keep(gb1) || !keep(gb2) { state = .none }
    case .icbConsonant, .icbLinker:
        let keep = { (g: BreakClass) in g.in(.icbConsonant, .icbLinker, .icbExtend, .zwj) }
        if !keep(gb1) || !keep(gb2) { state = .none }
    case .none: break
    }
    // Hangul syllables, spacing marks, prepend.
    if gb1 == .l, gb2.in(.l, .v, .lv, .lvt) { return false }
    if gb1.in(.lv, .v), gb2.in(.v, .t) { return false }
    if gb1.in(.lvt, .t), gb2 == .t { return false }
    if gb2 == .spacingMark || gb1 == .prepend { return false }
    // Indic conjuncts.
    if gb1 == .icbConsonant {
        if gb2.icbExtend { state = .icbConsonant; return false }
        if gb2 == .icbLinker { state = .icbLinker; return false }
    } else if state == .icbConsonant {
        if gb2 == .icbLinker { state = .icbLinker; return false }
        if gb2.icbExtend { return false }
        state = .none
    } else if state == .icbLinker {
        if gb2 == .icbLinker || gb2.icbExtend { return false }
        state = .none
        if gb2 == .icbConsonant { return false }
    }
    // Emoji ZWJ sequences and modifiers.
    if gb1.pictographic {
        if gb2.extend || gb2 == .zwj || (gb1 == .emojiModifierBase && gb2 == .emojiModifier) { state = .extendedPictographic; return false }
    } else if state == .extendedPictographic {
        if (gb1.extend || gb1 == .emojiModifier) && (gb2.extend || gb2 == .zwj) { return false }
        state = .none
        if gb1 == .zwj, gb2.pictographic { return false }
    }
    // Regional indicator pairs.
    if gb1 == .regionalIndicator, gb2 == .regionalIndicator {
        state = state == .none ? .regionalIndicator : .none
        return state == .none
    }
    return !(gb2.extend || gb2 == .zwj)
}

/// Every (state, class, class) of `breaks` (unicode/grapheme.zig Precompute): (state * classes + gb1) *
/// classes + gb2 -> break bit | new state << 1. Built at first use (thread-safe, read-only after), never freed.
@usableFromInline nonisolated(unsafe) let graphemeBreaks: UnsafePointer<UInt8> = {
    let n = BreakClass.count
    let table = UnsafeMutablePointer<UInt8>.allocate(capacity: BreakState.allCases.count * n * n)
    for s in BreakState.allCases {
        for a in BreakClass.allCases {
            for b in BreakClass.allCases {
                var state = s
                let broken = breaks(a, b, &state)
                table[(Int(s.rawValue) * n + Int(a.rawValue)) * n + Int(b.rawValue)] = (broken ? 1 : 0) | state.rawValue << 1
            }
        }
    }
    return UnsafePointer(table)
}()

extension Unicode {
    /// Whether a code point's default presentation is emoji (Unicode Emoji_Presentation, as Ghostty's tables).
    public static func isEmojiPresentation(_ cp: UInt32) -> Bool { contains(emojiPresentationRuns, cp) }
    /// Oniguruma's \w and \d (UTF-8).
    public static func isWord(_ cp: UInt32) -> Bool { contains(wordRuns, cp) }
    public static func isDigit(_ cp: UInt32) -> Bool { contains(digitRuns, cp) }
    /// Symbols the renderer lets span two cells (renderer/cell.zig isSymbol).
    public static func isSymbol(_ cp: UInt32) -> Bool { contains(symbolRuns, cp) }

    /// Whether `cp` falls in one of the sorted (start, count) runs.
    static func contains(_ runs: [(UInt32, UInt32)], _ cp: UInt32) -> Bool {
        var (lo, hi) = (0, runs.count)
        while lo < hi { let mid = (lo + hi) / 2; if runs[mid].0 + runs[mid].1 <= cp { lo = mid + 1 } else { hi = mid } }
        return lo < runs.count && runs[lo].0 <= cp
    }
}
