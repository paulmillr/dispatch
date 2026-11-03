// DECRQCRA (CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y: request a checksum of a rectangle) and XTCHECKSUM (CSI Ps # y:
// choose how it is computed), as Ghostty 1.4's xt_checksum.zig, which follows xterm's xtermCheckRect. Terminal test
// suites use them to verify the screen. Off unless enabled (`vt-xt-checksum-report`, HandlerOptions.checksumReports):
// a program can checksum the screen cell by cell and so read back everything on it, other programs' output included.
// Scope: the active screen only (the page number is ignored), DEC checksum by default, xterm's extension bits.

/// XTCHECKSUM's bits (xterm's CSBITS); none: the DEC checksum, which a full reset restores.
public struct ChecksumFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x1F }
    /// Don't negate the sum.
    public static let positive = ChecksumFlags(rawValue: 1)
    /// Don't add the VT100 video attributes.
    public static let noAttributes = ChecksumFlags(rawValue: 2)
    /// Count blanks (the DEC checksum counts a plain space only as the rectangle's first cell).
    public static let noTrim = ChecksumFlags(rawValue: 4)
    /// Count never-written cells as spaces instead of skipping them.
    public static let undrawn = ChecksumFlags(rawValue: 8)
    /// Sum whole code points rather than DEC 8-bit values (wide spacers and combining marks not counted).
    public static let full = ChecksumFlags(rawValue: 16)
}

/// A DECRQCRA request: 1-based coordinates, 0 where omitted.
public struct ChecksumRequest: Equatable, Sendable {
    public var id: UInt16 = 0, top: UInt16 = 0, left: UInt16 = 0, bottom: UInt16 = 0, right: UInt16 = 0
    public init(id: UInt16 = 0, top: UInt16 = 0, left: UInt16 = 0, bottom: UInt16 = 0, right: UInt16 = 0) {
        (self.id, self.top, self.left, self.bottom, self.right) = (id, top, left, bottom, right)
    }
}

extension Terminal {
    /// The rectangle's checksum on the active screen with the XTCHECKSUM flags: origin mode makes the coordinates
    /// relative to the scrolling region, they are clamped to the screen, an empty rectangle sums to 0.
    public func checksum(_ r: ChecksumRequest) -> UInt16 {
        let origin = modes.get(.origin) ? scrollingRegion : nil
        func limit(_ v: UInt16, _ d: Int, _ margin: Int, _ max: Int) -> Int { Swift.min(Swift.max((v == 0 ? d : Int(v)) + margin, 1), max) }
        let (top, left) = (limit(r.top, 1, origin?.top ?? 0, rows), limit(r.left, 1, origin?.left ?? 0, cols))
        let (bottom, right) = (limit(r.bottom, rows, origin?.top ?? 0, rows), limit(r.right, cols, origin?.left ?? 0, cols))
        let f = flags.checksum
        var sum: UInt16 = 0
        guard top <= bottom, left <= right else { return 0 }
        var first = true
        for y in (top - 1)...(bottom - 1) {
            guard let p = active.pin(.active, x: 0, y: y) else { continue }
            let page = p.page
            // A page may be narrower than the rectangle, as an xterm line may be shorter than the screen.
            for x in Swift.min(left - 1, page.cols)..<Swift.min(right, page.cols) {
                let at = page.cellAt(p.y, x), cell = page.cell(at)
                var ch: UInt16
                if cell.wide == .spacerTail {
                    if f.contains(.full) { continue }
                    ch = 0x1B   // xterm's placeholder outside 8 bits
                } else if !cell.hasText {
                    guard f.contains(.noTrim) || f.contains(.undrawn) else { continue }
                    ch = 0x20
                } else if f.contains(.full) {
                    ch = UInt16(truncatingIfNeeded: cell.codepoint)
                } else {
                    // xtermCharSetDec for ASCII; translated line drawing counts as outside 8 bits.
                    ch = switch cell.codepoint { case 0x7F, 0xFF: 0; case 0x20...0x7E, 0x80...0x9F, 0xA1...0xFE: UInt16(cell.codepoint & 0x7F); default: 0x1B }
                }
                let style = page.style(cell.styleID).flags
                if !f.contains(.noAttributes) {
                    if cell.protected { ch &+= 0x04 }
                    if style.invisible { ch &+= 0x08 }
                    if style.underline != .none { ch &+= 0x10 }
                    if style.inverse { ch &+= 0x20 }
                    if style.blink { ch &+= 0x40 }
                    if style.bold { ch &+= 0x80 }
                }
                if f.contains(.noTrim) {
                    sum &+= ch
                    // xterm adds combining marks only to the untrimmed DEC sum.
                    if !f.contains(.full), cell.hasGrapheme, let marks = page.grapheme(at) { for cp in marks { sum &+= UInt16(truncatingIfNeeded: cp) } }
                } else if first || ch != 0x20 || style.faint || style.italic || style.strikethrough || style.underline == .double {
                    sum &+= ch
                }
                first = f.contains(.noTrim)
            }
            if !f.contains(.noTrim) { first = false }
        }
        return f.contains(.positive) ? sum : 0 &- sum
    }
}
