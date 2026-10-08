// Cell styles (Ghostty's style.zig) in their packed form, and the hash.

/// Stored as Ghostty's `PackedStyle` (u128) in two words: color tags u8 x3 (fg, bg, underline) at
/// bits 0-23, color data u24 x3 at bits 24-95, flags u16 at 96-111. So comparing, hashing and the
/// default check (all zeros) are word operations, and pages store styles as they are.
public struct Style: Equatable, BitwiseCopyable {
    public enum Color: Equatable { case none, palette(UInt8), rgb(RGB) }
    /// Ghostty's packed u16 flags: 8 bools, then underline u3.
    public struct Flags: Equatable {
        public var bits: UInt16
        public init(bits: UInt16 = 0) { self.bits = bits }
        @inline(__always) subscript(_ i: Int) -> Bool { get { bits >> i & 1 != 0 } set { bits = bits & ~(1 << i) | (newValue ? 1 << i : 0) } }
        public var bold: Bool { get { self[0] } set { self[0] = newValue } }
        public var italic: Bool { get { self[1] } set { self[1] = newValue } }
        public var faint: Bool { get { self[2] } set { self[2] = newValue } }
        public var blink: Bool { get { self[3] } set { self[3] = newValue } }
        public var inverse: Bool { get { self[4] } set { self[4] = newValue } }
        public var invisible: Bool { get { self[5] } set { self[5] = newValue } }
        public var strikethrough: Bool { get { self[6] } set { self[6] = newValue } }
        public var overline: Bool { get { self[7] } set { self[7] = newValue } }
        public var underline: Underline {
            get { Underline(rawValue: bits >> 8 & 7) ?? .none }
            set { bits = bits & ~(7 << 8) | newValue.rawValue << 8 }
        }
    }

    var low: UInt64 = 0, high: UInt64 = 0

    public init(fgColor: Color = .none, bgColor: Color = .none, underlineColor: Color = .none, flags: Flags = Flags()) {
        (self.fgColor, self.bgColor, self.underlineColor, self.flags) = (fgColor, bgColor, underlineColor, flags)
    }

    /// Bits [at, at + n) of the 128-bit value. Swift's smart shifts (a negative amount shifts the
    /// other way, 64 or more gives 0) let a field cross into the high word without a special case.
    @inline(__always) func get(_ at: Int, _ n: Int) -> UInt64 { (low >> at | high >> (at - 64)) & (1 << n - 1) }
    @inline(__always) mutating func set(_ at: Int, _ n: Int, _ v: UInt64) {
        let m: UInt64 = 1 << n - 1
        low = low & ~(m << at) | v << at
        high = high & ~(m >> (64 - at)) | v >> (64 - at)
    }

    /// Color slot i (0 fg, 1 bg, 2 underline): tag byte i, data at bit 24 + 24 i.
    @inline(__always) subscript(color i: Int) -> Color {
        get {
            let d = get(24 + 24 * i, 24)
            switch get(8 * i, 8) {
            case 1: return .palette(UInt8(d & 0xFF))
            case 2: return .rgb(RGB(r: UInt8(d & 0xFF), g: UInt8(d >> 8 & 0xFF), b: UInt8(d >> 16)))
            default: return .none
            }
        }
        set {
            let (tag, d): (UInt64, UInt64) = switch newValue {
            case .none: (0, 0)
            case .palette(let p): (1, UInt64(p))
            case .rgb(let v): (2, UInt64(v.r) | UInt64(v.g) << 8 | UInt64(v.b) << 16)
            }
            set(8 * i, 8, tag)
            set(24 + 24 * i, 24, d)
        }
    }
    public var fgColor: Color { get { self[color: 0] } set { self[color: 0] = newValue } }
    public var bgColor: Color { get { self[color: 1] } set { self[color: 1] = newValue } }
    public var underlineColor: Color { get { self[color: 2] } set { self[color: 2] = newValue } }
    public var flags: Flags { get { Flags(bits: UInt16(get(96, 16))) } set { set(96, 16, UInt64(newValue.bits)) } }

    /// `std.hash.int` (mx3) of the packed halves XORed, like `Style.hash`.
    public var hash: UInt64 { mx3(low ^ high) }
}

/// std.hash.int for u64 (https://github.com/jonmaiga/mx3).
func mx3(_ v: UInt64) -> UInt64 {
    let c: UInt64 = 0xbea225f9eb34556d
    var x = (v ^ v >> 32) &* c
    x = (x ^ x >> 29) &* c
    x = (x ^ x >> 32) &* c
    return x ^ x >> 29
}
