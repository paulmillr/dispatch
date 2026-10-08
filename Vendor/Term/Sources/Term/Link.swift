// Hyperlinks as pages store them (Ghostty's hyperlink.zig).

public enum LinkID: Equatable { case explicit([UInt8]), implicit(UInt32) }

public struct Link: Equatable {
    public var id: LinkID, uri: [UInt8]
    public init(id: LinkID, uri: [UInt8]) { (self.id, self.uri) = (id, uri) }

    /// Wyhash(0) over the bytes `std.hash.autoHash` feeds it for `PageEntry.hash`:
    /// tag byte, implicit u32 or explicit bytes + u64 length, uri bytes + u64 length.
    public var hash: UInt64 {
        func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { (0..<T.bitWidth / 8).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } }
        switch id {
        case .explicit(let s): return wyhash([0] + s + le(UInt64(s.count)) + uri + le(UInt64(uri.count)))
        case .implicit(let v): return wyhash([1] + le(v) + uri + le(UInt64(uri.count)))
        }
    }
}

/// Zig's `std.hash.Wyhash.hash(0, input)` (wyhash final v4).
@_spi(Test) public func wyhash(_ input: [UInt8]) -> UInt64 {
    let secret: [UInt64] = [0xa0761d6478bd642f, 0xe7037ed1a0b428db, 0x8ebc6af09c88c6e3, 0x589965cc75374cc3]
    func mum(_ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) { let r = a.multipliedFullWidth(by: b); return (r.low, r.high) }
    func mix(_ a: UInt64, _ b: UInt64) -> UInt64 { let r = mum(a, b); return r.0 ^ r.1 }
    func read(_ n: Int, _ at: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(input[at + $1]) << (8 * $1) } }
    let n = input.count
    var state = [UInt64](repeating: mix(secret[0], secret[1]), count: 3)
    var (a, b): (UInt64, UInt64) = (0, 0)
    if n > 16 {
        var i = 0
        if n >= 48 {
            for j in stride(from: 0, to: n - 48, by: 48) {
                for k in 0..<3 { state[k] = mix(read(8, j + 16 * k) ^ secret[k + 1], read(8, j + 16 * k + 8) ^ state[k]) }
                i = j + 48
            }
            state[0] ^= state[1] ^ state[2]
        }
        for j in stride(from: i, to: n - 16, by: 16) { state[0] = mix(read(8, j) ^ secret[1], read(8, j + 8) ^ state[0]) }
        (a, b) = (read(8, n - 16), read(8, n - 8))
    } else if n >= 4 {
        let q = (n >> 3) << 2
        (a, b) = (read(4, 0) << 32 | read(4, q), read(4, n - 4) << 32 | read(4, n - 4 - q))
    } else if n > 0 {
        a = UInt64(input[0]) << 16 | UInt64(input[n >> 1]) << 8 | UInt64(input[n - 1])
    }
    (a, b) = mum(a ^ secret[1], b ^ state[0])
    return mix(a ^ secret[0] ^ UInt64(n), b ^ secret[1])
}
