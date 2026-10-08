// SGR parameters -> attributes, as Ghostty's sgr.zig Parser.

struct SGR {
    let p: UnsafeBufferPointer<UInt16>, colons: UInt32
    var i = 0

    init(params: UnsafeBufferPointer<UInt16>, colons: UInt32) { (p, self.colons) = (params, colons) }

    func colon(_ at: Int) -> Bool { at < 32 && colons >> at & 1 != 0 }

    /// Colon-separated params after the current one (Ghostty's countColon).
    func colonCount() -> Int { var n = 0; while i + n < p.count - 1, colon(i + n) { n += 1 }; return n }

    mutating func skipColons() { i += colonCount() + 1 }

    mutating func next() -> Attribute? {
        guard i < p.count else { defer { i += 1 }; return i == 0 ? .unset : nil }
        let b = i, n = p.count - i, c = colon(i)
        func s(_ k: Int) -> UInt16 { p[p.startIndex + b + k] }
        func unknown(_ len: Int) -> Attribute { .unknown(UnknownSGR(full: Array(p), partial: Array(p[(p.startIndex + b)...].prefix(len)))) }
        i += 1
        if c, s(0) != 4, s(0) != 38, s(0) != 48, s(0) != 58 {
            while colon(i) { i += 1 }
            i += 1
            return unknown(min(i - b, n))
        }
        switch s(0) {
        case 0: return .unset
        case 1: return .bold
        case 2: return .faint
        case 3: return .italic
        case 4:
            guard c else { return .underline(.single) }
            if n < 2 { break }
            if colon(i) { skipColons(); break }
            i += 1
            return .underline(Underline(rawValue: s(1)) ?? .single)
        case 5, 6: return .blink
        case 7: return .inverse
        case 8: return .invisible
        case 9: return .strikethrough
        case 21: return .underline(.double)
        case 22: return .resetBold
        case 23: return .resetItalic
        case 24: return .underline(.none)
        case 25: return .resetBlink
        case 27: return .resetInverse
        case 28: return .resetInvisible
        case 29: return .resetStrikethrough
        case 30...37: return .fg8(ColorName(value: UInt8(s(0) - 30)))
        case 39: return .resetFg
        case 40...47: return .bg8(ColorName(value: UInt8(s(0) - 40)))
        case 49: return .resetBg
        case 53: return .overline
        case 55: return .resetOverline
        case 59: return .resetUnderlineColor
        case 90...97: return .brightFg8(ColorName(value: UInt8(s(0) - 82)))
        case 100...107: return .brightBg8(ColorName(value: UInt8(s(0) - 92)))
        case 38, 48, 58:
            let rgb: (RGB) -> Attribute = s(0) == 38 ? { .directColorFg($0) } : s(0) == 48 ? { .directColorBg($0) } : { .underlineColor($0) }
            let indexed: (UInt8) -> Attribute = s(0) == 38 ? { .fg256($0) } : s(0) == 48 ? { .bg256($0) } : { .underlineColor256($0) }
            guard n >= 2 else { break }
            if s(1) == 5, n >= 3 { i += 2; return indexed(UInt8(truncatingIfNeeded: s(2))) }
            // 38;2;r;g;b, or with colons 38:2:r:g:b / 38:2:cs:r:g:b.
            if s(1) == 2, n >= 5 {
                if let at = !c ? 2 : [3: 2, 4: 3][colonCount()] {
                    i += at + 2
                    return rgb(RGB(r: UInt8(truncatingIfNeeded: s(at)), g: UInt8(truncatingIfNeeded: s(at + 1)), b: UInt8(truncatingIfNeeded: s(at + 2))))
                }
                skipColons()
            }
        default: break
        }
        return unknown(n)
    }
}
