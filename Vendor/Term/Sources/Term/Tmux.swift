// tmux control mode (`tmux -CC`): the terminal hands the stream inside its DCS 1000p envelope to
// the host (`Surface.control`), and `Tmux` reads that stream. The grammar is Dispatch's control
// client's (TmuxProtocol), to its edges; Ghostty's own viewer is not ported (Dispatch never used it).

/// What a terminal in tmux control mode hands to its host, as it arrives (DCS 1000p ... ST).
public enum Control { case start, data(UnsafeBufferPointer<UInt8>), end }

/// A reader for tmux's control stream: lines end at LF (trailing CRs dropped), `%output` data is
/// unescaped into one reused buffer (the line itself when nothing is escaped), reply lines and
/// notifications are handed over as they are. Events are valid only during the callback; after a
/// failure the reader is done.
public struct Tmux {
    public enum Event {
        /// `%output %<pane> <data>` and `%extended-output %<pane> <fields> : <data>`.
        case output(pane: Int, bytes: UnsafeBufferPointer<UInt8>)
        case begin(Frame), reply(UnsafeBufferPointer<UInt8>), end(Frame, failed: Bool)
        case notification(UnsafeBufferPointer<UInt8>)
    }
    public struct Frame: Equatable { public var time: UInt64, number: UInt64, flags: UInt64 }
    public enum Failure: Error { case oversized, invalidFrame, invalidEscape }

    /// The longest line (Dispatch: 32 MiB).
    let limit: Int
    var line: [UInt8] = [], data: [UInt8] = []
    var block: Frame?

    public init(limit: Int) { self.limit = limit }

    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, _ event: (Event) -> Void) throws(Failure) {
        var start = 0
        while start < bytes.count {
            let end = bytes.first(from: start) { $0.eq(10) }
            guard end - start <= limit - line.count else { throw .oversized }
            if end == bytes.count { line.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start...])); return }
            if line.isEmpty { try consume(UnsafeBufferPointer(rebasing: bytes[start..<end]), event) } else {
                line.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<end]))
                let whole = line
                line = []
                var failure: Failure?   // (withUnsafeBufferPointer rethrows untyped)
                whole.withUnsafeBufferPointer { l in do throws(Failure) { try consume(l, event) } catch { failure = error } }
                if let failure { throw failure }
                line = whole
                line.removeAll(keepingCapacity: true)
            }
            start = end + 1
        }
    }

    mutating func consume(_ raw: UnsafeBufferPointer<UInt8>, _ event: (Event) -> Void) throws(Failure) {
        var n = raw.count
        while n > 0, raw[n - 1] == 13 { n -= 1 }
        let l = UnsafeBufferPointer(rebasing: raw[..<n])
        // Inside a reply every line is text, until %end or %error with the begin's numbers.
        if let b = block {
            for (word, failed) in [("%end ", false), ("%error ", true)] where Self.frame(l, word) == b {
                block = nil
                return event(.end(b, failed: failed))
            }
            return event(.reply(l))
        }
        if l.starts(with: "%begin ".utf8) {
            guard let f = Self.frame(l, "%begin ") else { throw .invalidFrame }
            block = f
            return event(.begin(f))
        }
        if l.starts(with: "%output ".utf8) {
            // Split at the first two spaces: `%output`, the pane, the data.
            let space = l.first(from: 8) { $0.eq(32) }
            guard space < n, let pane = Self.pane(l[8..<space]) else { throw .invalidFrame }
            return try output(pane, UnsafeBufferPointer(rebasing: l[(space + 1)...]), event)
        }
        if l.starts(with: "%extended-output ".utf8) {
            // Three fields split at runs of spaces (the third starts after one), data after " : "
            // (no third field: no " : " either).
            var i = 17
            while i < n, l[i] == 32 { i += 1 }
            let space = l.first(from: i) { $0.eq(32) }
            guard i < n, let pane = Self.pane(l[i..<space]),
                  let colon = (space + 1..<max(space + 1, n - 2)).first(where: { l[$0] == 32 && l[$0 + 1] == 0x3A && l[$0 + 2] == 32 }) else { throw .invalidFrame }
            return try output(pane, UnsafeBufferPointer(rebasing: l[(colon + 3)...]), event)
        }
        if n == 0 { return }
        if l.starts(with: "%end ".utf8) || l.starts(with: "%error ".utf8) { throw .invalidFrame }
        event(.notification(l))
    }

    /// Output data: `\ooo` is a byte (every backslash starts one).
    mutating func output(_ pane: Int, _ d: UnsafeBufferPointer<UInt8>, _ event: (Event) -> Void) throws(Failure) {
        var i = d.first(from: 0) { $0.eq(92) }
        if i == d.count { return event(.output(pane: pane, bytes: d)) }
        data.removeAll(keepingCapacity: true)
        data.append(contentsOf: UnsafeBufferPointer(rebasing: d[..<i]))
        while i < d.count {
            guard i + 3 < d.count, d[i + 1] &- 0x30 < 8, d[i + 2] &- 0x30 < 8, d[i + 3] &- 0x30 < 8, d[i + 1] < 0x34 else { throw .invalidEscape }
            data.append((d[i + 1] - 0x30) << 6 | (d[i + 2] - 0x30) << 3 | (d[i + 3] - 0x30))
            let next = d.first(from: i + 4) { $0.eq(92) }
            data.append(contentsOf: UnsafeBufferPointer(rebasing: d[(i + 4)..<next]))
            i = next
        }
        data.withUnsafeBufferPointer { event(.output(pane: pane, bytes: $0)) }
    }

    /// `<word><time> <number> <flags>`: three numbers between runs of spaces.
    static func frame(_ l: UnsafeBufferPointer<UInt8>, _ word: String) -> Frame? {
        guard l.starts(with: word.utf8) else { return nil }
        var numbers: [UInt64] = [], i = word.utf8.count
        while i < l.count {
            if l[i] == 32 { i += 1; continue }
            let end = l.first(from: i) { $0.eq(32) }
            guard numbers.count < 3, let v = number(l[i..<end]) else { return nil }   // (a 4th: no frame, stop early)
            numbers.append(v)
            i = end
        }
        return numbers.count == 3 ? Frame(time: numbers[0], number: numbers[1], flags: numbers[2]) : nil
    }

    /// `%<digits>` as an Int.
    static func pane(_ s: Slice<UnsafeBufferPointer<UInt8>>) -> Int? {
        guard s.first == 37, s.count > 1, s.dropFirst().allSatisfy({ $0 &- 0x30 < 10 }), let v = number(s.dropFirst()), v <= Int.max else { return nil }
        return Int(v)
    }

    /// A number as Swift's UInt64(String) reads it: an optional sign ('-' only for zero), digits.
    static func number(_ s: Slice<UnsafeBufferPointer<UInt8>>) -> UInt64? {
        let signed = s.first == 0x2B || s.first == 0x2D, digits = s.dropFirst(signed ? 1 : 0)
        guard !digits.isEmpty else { return nil }
        var v: UInt64 = 0
        for c in digits {
            guard c &- 0x30 < 10 else { return nil }
            let (m, o) = v.multipliedReportingOverflow(by: 10), (a, p) = m.addingReportingOverflow(UInt64(c - 0x30))
            guard !o, !p else { return nil }
            v = a
        }
        return s.first == 0x2D && v != 0 ? nil : v
    }
}

extension UnsafeBufferPointer<UInt8> {
    /// The first index from `i` whose byte `stop` picks (a lane test: 16 bytes at a time, the tail
    /// one byte at a time through the same test), or `count`.
    @inline(__always) func first(from i: Int, _ stop: (Lanes) -> Lanes.V) -> Int {
        var i = i
        while i + 16 <= count {
            let m = stop(Lanes(baseAddress! + i))
            if m != Lanes.V() { return i + Lanes.bits(m).trailingZeroBitCount }
            i += 16
        }
        while i < count, Lanes.bits(stop(Lanes(Lanes.V(repeating: self[i])))) == 0 { i += 1 }
        return i
    }
}
