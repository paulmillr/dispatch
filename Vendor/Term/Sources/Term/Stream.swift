// Bytes -> actions: Ghostty's `Parser.zig` state machine + `stream.zig`.
// Printable codepoints collect into runs; every other action flushes first.

enum State: Int { case ground, escape, escapeIntermediate, csiEntry, csiIntermediate, csiParam, csiIgnore
    case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore, oscString, sosPmApcString }
enum Step: UInt8 { case none, ignore, print, execute, collect, param, escDispatch, csiDispatch, oscPut, apcPut }

/// Transition table built from Ghostty's `parse_table.zig` rules: "anywhere"
/// rules first, then per-state rules override them.
let table: [(State, Step)] = {
    var t = [(State, Step)](repeating: (.ground, .none), count: 256 * 14)
    for s in 0..<14 { for c in 0..<256 { t[c * 14 + s] = (State(rawValue: s)!, .none) } }
    func set(_ r: ClosedRange<Int>, _ s: [State], _ n: State?, _ a: Step) {
        for from in s { for c in r { t[c * 14 + from.rawValue] = (n ?? from, a) } }
    }
    let all = (0..<14).map { State(rawValue: $0)! }
    let c0 = [0...0x17, 0x19...0x19, 0x1C...0x1F]
    func each(_ rs: [ClosedRange<Int>], _ s: [State], _ n: State?, _ a: Step) { for r in rs { set(r, s, n, a) } }
    each([0x18...0x18, 0x1A...0x1A, 0x80...0x8F, 0x91...0x97, 0x99...0x9A], all, .ground, .execute)
    set(0x9C...0x9C, all, .ground, .none)
    set(0x1B...0x1B, all, .escape, .none)
    each([0x98...0x98, 0x9E...0x9F], all, .sosPmApcString, .none)
    set(0x9B...0x9B, all, .csiEntry, .none)
    set(0x90...0x90, all, .dcsEntry, .none)
    set(0x9D...0x9D, all, .oscString, .none)
    each(c0, [.ground], nil, .execute); set(0x20...0x7F, [.ground], nil, .print)
    each(c0, [.escapeIntermediate], nil, .execute); set(0x20...0x2F, [.escapeIntermediate], nil, .collect)
    set(0x7F...0x7F, [.escapeIntermediate], nil, .ignore); set(0x30...0x7E, [.escapeIntermediate], .ground, .escDispatch)
    each(c0 + [0x20...0x7F], [.sosPmApcString], nil, .apcPut)
    each(c0, [.escape], nil, .execute); set(0x7F...0x7F, [.escape], nil, .ignore)
    each([0x30...0x4F, 0x51...0x57, 0x60...0x7E, 0x59...0x5A, 0x5C...0x5C], [.escape], .ground, .escDispatch)
    set(0x20...0x2F, [.escape], .escapeIntermediate, .collect)
    each([0x58...0x58, 0x5E...0x5F], [.escape], .sosPmApcString, .none)
    set(0x50...0x50, [.escape], .dcsEntry, .none); set(0x5B...0x5B, [.escape], .csiEntry, .none)
    set(0x5D...0x5D, [.escape], .oscString, .none)
    each(c0 + [0x7F...0x7F], [.dcsEntry], nil, .ignore); set(0x20...0x2F, [.dcsEntry], .dcsIntermediate, .collect)
    set(0x3A...0x3A, [.dcsEntry], .dcsIgnore, .none); each([0x30...0x39, 0x3B...0x3B], [.dcsEntry], .dcsParam, .param)
    set(0x3C...0x3F, [.dcsEntry], .dcsParam, .collect); set(0x40...0x7E, [.dcsEntry], .dcsPassthrough, .none)
    each(c0 + [0x7F...0x7F], [.dcsIntermediate], nil, .ignore); set(0x20...0x2F, [.dcsIntermediate], nil, .collect)
    set(0x30...0x3F, [.dcsIntermediate], .dcsIgnore, .none); set(0x40...0x7E, [.dcsIntermediate], .dcsPassthrough, .none)
    each(c0 + [0x80...0xFF], [.dcsIgnore], nil, .ignore)
    each(c0 + [0x7F...0x7F], [.dcsParam], nil, .ignore); each([0x30...0x39, 0x3B...0x3B], [.dcsParam], nil, .param)
    each([0x3A...0x3A, 0x3C...0x3F], [.dcsParam], .dcsIgnore, .none); set(0x20...0x2F, [.dcsParam], .dcsIntermediate, .collect)
    set(0x40...0x7E, [.dcsParam], .dcsPassthrough, .none)
    // dcsPassthrough: its payload (all but CAN, SUB, ESC: the "anywhere" rules above) never reaches
    // the table, `parse` hands it over in runs.
    each(c0, [.csiParam, .csiIgnore, .csiIntermediate, .csiEntry], nil, .execute)
    set(0x7F...0x7F, [.csiParam, .csiIgnore, .csiIntermediate, .csiEntry], nil, .ignore)
    set(0x30...0x3B, [.csiParam], nil, .param); set(0x40...0x7E, [.csiParam, .csiIntermediate, .csiEntry], .ground, .csiDispatch)
    set(0x3C...0x3F, [.csiParam], .csiIgnore, .none); set(0x20...0x2F, [.csiParam, .csiEntry], .csiIntermediate, .collect)
    set(0x20...0x3F, [.csiIgnore], nil, .ignore); set(0x40...0x7E, [.csiIgnore], .ground, .none)
    set(0x20...0x2F, [.csiIntermediate], nil, .collect); set(0x30...0x3F, [.csiIntermediate], .csiIgnore, .none)
    set(0x3A...0x3A, [.csiEntry], .csiIgnore, .none); each([0x30...0x39, 0x3B...0x3B], [.csiEntry], .csiParam, .param)
    set(0x3C...0x3F, [.csiEntry], .csiParam, .collect)
    each([0...0x06, 0x08...0x17, 0x19...0x19, 0x1C...0x1F], [.oscString], nil, .ignore)
    set(0x20...0xFF, [.oscString], nil, .oscPut); set(0x07...0x07, [.oscString], .ground, .none)
    return t
}()

/// Printable codepoints collected before a run is handed over (a full buffer hands it over early:
/// runs are cut at chunk boundaries anyway).
let runCapacity = 4096

/// Not copyable: it owns its parameter and run buffers (plain memory, no per-byte checks).
public struct Stream<H: Handler>: ~Copyable {
    public var handler: H
    var state = State.ground
    var inter: UInt32 = 0, interCount = 0        // up to 4 intermediates, the first one highest
    let params = UnsafeMutablePointer<UInt16>.allocate(capacity: 24)
    var count = 0
    var colons: UInt32 = 0                        // bit i: param i ended with ':'
    var acc: UInt16 = 0, digits: UInt8 = 0
    var utf8 = Decoder()
    var osc = OSCParser()
    let run = UnsafeMutablePointer<UInt32>.allocate(capacity: runCapacity)
    var runLen = 0                                // printable codepoints not yet handed over
    /// Printable ASCII of the input being parsed not yet handed over, as bytes (most text: no code
    /// point buffer, and the terminal knows every byte is one narrow cell). Never outlives `parse`;
    /// at most one of `span` and `run` holds text.
    var span: UnsafePointer<UInt8>?, spanLen = 0

    public init(handler: H) { self.handler = handler; params.initialize(repeating: 0, count: 24) }
    deinit { params.deallocate(); run.deallocate() }

    /// Another module's use of a generic type runs unspecialized: the handler's calls go through a
    /// witness table and the fields after `handler` sit at offsets read from metadata. So the app
    /// handler gets its own `nextSlice` (below), specialized here; other handlers (tests) use this one.
    public mutating func nextSlice(_ input: UnsafeBufferPointer<UInt8>) { parse(input) }

    mutating func parse(_ input: UnsafeBufferPointer<UInt8>) {
        var i = 0
        while i < input.count {
            if state == .ground && utf8.pending == 0 {
                // Text 16 bytes at a time (see `text`), then printable ASCII byte by byte (chunk edges).
                while i >= 3, i + 19 <= input.count, runLen + 16 <= runCapacity {
                    let n = text(input.baseAddress! + i)
                    if n == 0 { break }
                    i += n
                }
                let start = i
                while i < input.count, input[i] >= 0x20, input[i] < 0x7F { i += 1 }
                if i > start { extend(input.baseAddress! + start, i - start) }
                if i == input.count { break }
            }
            if state == .csiParam {
                // Parameter digits and separators, the bulk of a CSI sequence, without the table.
                while i < input.count, input[i] >= 0x30, input[i] <= 0x3B {
                    let c = input[i]
                    if c <= 0x39 { if count < 24 { digit(c); digits |= 1 } } else { separator(c) }
                    i += 1
                }
                if i == input.count { break }
            }
            if state == .dcsPassthrough {
                // DCS payload in runs (Ghostty: byte by byte, DEL dropped; the handlers drop it).
                let end = input.first(from: i) { $0.eq(0x18) | $0.eq(0x1A) | $0.eq(0x1B) }
                if end > i { emit(.dcsPut(UnsafeBufferPointer(rebasing: input[i..<end]))) }
                i = end
                if i == input.count { break }
            }
            let c = input[i]; i += 1
            if state == .ground {
                let (a, b) = utf8.next(c)
                if let a { codepoint(a) }
                if let b { codepoint(b) }
            } else { nonGround(c) }
        }
        flush()
    }

    @inline(__always) mutating func append(_ c: UInt32) {
        if spanLen > 0 || runLen == runCapacity { flush() }
        run[runLen] = c
        runLen += 1
    }

    /// n printable ASCII bytes at p join the span (a new one where they don't continue it).
    @inline(__always) mutating func extend(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if spanLen > 0, span! + spanLen == p { spanLen += n; return }
        flush()
        (span, spanLen) = (p, n)
    }

    mutating func flush() {
        if spanLen > 0 { handler.vt(.printBytes(UnsafeBufferPointer(start: span, count: spanLen))); spanLen = 0 }
        if runLen > 0 { handler.vt(.printSlice(UnsafeBufferPointer(start: run, count: runLen))); runLen = 0 }
    }

    mutating func emit(_ a: Action) { flush(); handler.vt(a) }

    /// Clean text at p (3 bytes before, 18 after readable): printable ASCII (into the span) and
    /// complete well-formed UTF-8 (into the run) up to the first control, ESC or malformed byte.
    /// Every lane is checked against the 3 bytes before it at once, so there is no branch per
    /// character. Returns the bytes consumed (0: the byte-by-byte path decides).
    @inline(__always) mutating func text(_ p: UnsafePointer<UInt8>) -> Int {
        let v = Lanes(p), control = Lanes.bits(v.lt(0x20)).trailingZeroBitCount
        if Lanes.bits(v.v).trailingZeroBitCount >= control {   // ASCII up to the first control
            let end = min(control, 16)
            if end > 0 { extend(p, end) }
            return end
        }
        let (p1, p2, p3) = (Lanes(p - 1), Lanes(p - 2), Lanes(p - 3))
        let cont = Lanes(v.v & 0xC0).eq(0x80), need = p1.ge(0xC0) | p2.ge(0xE0) | p3.ge(0xF0)
        let malformed: Lanes.V = cont ^ need | v.eq(0xC0) | v.eq(0xC1) | v.ge(0xF5)
        let outOfRange: Lanes.V = p1.eq(0xE0) & v.lt(0xA0) | p1.eq(0xED) & v.ge(0xA0) | p1.eq(0xF0) & v.lt(0x90) | p1.eq(0xF4) & v.ge(0x90)
        let bad = malformed | outOfRange | v.lt(0x20)
        let end = min(Lanes.bits(bad).trailingZeroBitCount, 16), leads = ~Lanes.bits(cont) & (1 << end - 1)
        guard leads & 1 != 0 else { return 0 }   // must start a character (a continuation is the decoder's)
        var (m, done) = (leads, 0)
        while m != 0 {
            let k = m.trailingZeroBitCount, (c, n) = Decoder.sequence(p + k)
            if k + n > end { break }
            if c & ~0x9F != 0 { run[runLen] = c; runLen += 1 }   // UTF-8-encoded C1 controls are ignored
            (m, done) = (m & (m - 1), k + n)
        }
        return done
    }

    /// stream.zig handleCodepoint: C0 executes, ESC starts a sequence,
    /// UTF-8-encoded C1 controls are ignored, everything else prints.
    mutating func codepoint(_ c: UInt32) {
        if c & ~0x9F != 0 { append(c); return }
        if c == 0x1B { state = .escape; clear() } else if c < 0x20 { execute(UInt8(c)) }
    }

    mutating func clear() { (inter, interCount, count, colons, acc, digits) = (0, 0, 0, 0, 0, 0) }

    mutating func collect(_ c: UInt8) { if interCount < 4 { (inter, interCount) = (inter << 8 | UInt32(c), interCount + 1) } }

    /// Ends the current parameter (`;` or `:`), ignored past 24 params.
    mutating func separator(_ c: UInt8) {
        guard count < 24 else { return }
        params[count] = acc
        if c == 0x3A { colons |= 1 << count }
        count += 1; acc = 0; digits = 0
    }

    mutating func digit(_ c: UInt8) {
        let (m, o1) = acc.multipliedReportingOverflow(by: 10)
        let (s, o2) = (o1 ? UInt16.max : m).addingReportingOverflow(UInt16(c - 0x30))
        acc = o2 ? .max : s
    }

    mutating func nonGround(_ c: UInt8) {
        if state == .escape && c == 0x5B { state = .csiEntry; return }
        if state == .csiParam {
            // stream.zig overrides the table for CSI params (release path).
            switch c {
            case 0...0x0F: execute(c); return
            case 0x10...0x17, 0x19, 0x1C...0x1F, 0x7F: return
            case 0x18, 0x1A: state = .ground; return
            case 0x30...0x39: if count < 24 { digit(c); digits |= 1 }; return
            case 0x3A, 0x3B: separator(c); return
            case 0x40...0x7E: csiFinal(c); return
            default: break
            }
        }
        if state == .csiEntry {
            switch c {
            case 0x30...0x39: state = .csiParam; acc = UInt16(c - 0x30); digits = 1; return
            case 0x3B: state = .csiParam; params[0] = 0; count = 1; return
            case 0x3C...0x3F: state = .csiParam; collect(c); return
            case 0x40...0x7E: csiFinal(c); return
            default: break
            }
        }
        let (next, step) = table[Int(c) * 14 + state.rawValue]
        if next != state {   // exit
            switch state {
            case .oscString: if let a = osc.end(c) { emit(a) }
            case .dcsPassthrough: emit(.dcsUnhook)
            case .sosPmApcString: emit(.apcEnd(ApcEnd(terminated: c == 0x1B || c == 0x9C)))
            default: break
            }
        }
        switch step {
        case .print: codepoint(UInt32(c))
        case .execute: execute(c)
        case .collect: collect(c)
        case .param: if c == 0x3B || c == 0x3A { separator(c) } else { digit(c); digits &+= 1 }
        case .oscPut: osc.next(c)
        case .csiDispatch: csiFinal(c)
        case .escDispatch: escDispatch(c)
        case .apcPut: emit(.apcPut(c))
        case .none, .ignore: break
        }
        if next != state {   // entry
            switch next {
            case .escape, .dcsEntry, .csiEntry: clear()
            case .oscString: osc.reset()
            case .dcsPassthrough:
                if count < 24 {
                    if digits > 0 { params[count] = acc; count += 1 }
                    let bytes = (0..<interCount).reversed().map { UInt8(truncatingIfNeeded: inter >> UInt32(8 * $0)) }
                    emit(.dcsHook(DCS(intermediates: bytes, params: Array(UnsafeBufferPointer(start: params, count: count)), final: c)))
                }
            case .sosPmApcString: emit(.apcStart)
            default: break
            }
        }
        state = next
    }

    /// stream.zig csiDispatchFinal.
    mutating func csiFinal(_ c: UInt8) {
        state = .ground
        guard count < 24 else { return }
        if digits > 0 { params[count] = acc; count += 1 }
        if c != 0x6D && colons != 0 { return }   // colons only for SGR
        csiDispatch(c, UnsafeBufferPointer(start: params, count: count))
    }

    /// stream.zig execute: C1 bytes act as their ESC equivalents.
    mutating func execute(_ c: UInt8) {
        if c > 0x7F { (inter, interCount) = (0, 0); escDispatch(c - 0x40); return }
        switch c {
        case 0x05: emit(.enquiry)
        case 0x07: emit(.bell)
        case 0x08: emit(.backspace)
        case 0x09: emit(.horizontalTab(1))
        case 0x0A, 0x0B, 0x0C: emit(.linefeed)
        case 0x0D: emit(.carriageReturn)
        case 0x0E: emit(.invokeCharset(InvokeCharset(bank: .GL, charset: .G1, locking: false)))
        case 0x0F: emit(.invokeCharset(InvokeCharset(bank: .GL, charset: .G0, locking: false)))
        default: break
        }
    }
}

extension Stream where H == StreamHandler {
    public mutating func nextSlice(_ input: UnsafeBufferPointer<UInt8>) { parse(input) }
}

/// UTF-8 decoding with Unicode's "maximal subpart" replacement: one U+FFFD
/// per invalid subpart; the byte that broke a sequence is decoded again.
struct Decoder {
    var pending = 0, value: UInt32 = 0, low: UInt8 = 0x80, high: UInt8 = 0xBF, rejected = false

    /// Up to two codepoints: a U+FFFD for a broken sequence, then whatever
    /// the breaking byte decodes to on its own.
    mutating func next(_ b: UInt8) -> (UInt32?, UInt32?) {
        guard pending > 0 else { return (start(b), nil) }
        guard b >= low && b <= high else { pending = 0; (low, high) = (0x80, 0xBF); rejected = true; return (0xFFFD, start(b)) }
        value = value << 6 | UInt32(b & 0x3F); pending -= 1; (low, high) = (0x80, 0xBF)
        return (pending == 0 ? value : nil, nil)
    }

    /// The codepoint and length of the well-formed sequence at p (4 readable bytes), without a
    /// branch on the length: the lead's leading ones give it, one formula assembles every length.
    @inline(__always) static func sequence(_ p: UnsafePointer<UInt8>) -> (UInt32, Int) {
        let w = UInt32(littleEndian: UnsafeRawPointer(p).loadUnaligned(as: UInt32.self))
        let ones = (~p[0]).leadingZeroBitCount, n = max(ones, 1)
        let x = UInt32(p[0] & 0x7F &>> UInt8(ones)) << 18 | (w >> 8 & 0x3F) << 12 | (w >> 16 & 0x3F) << 6 | w >> 24 & 0x3F
        return (x &>> UInt32(6 * (4 - n)), n)
    }

    mutating func start(_ b: UInt8) -> UInt32? {
        switch b {
        case 0..<0x80: return UInt32(b)
        case 0xC2...0xDF: (pending, value) = (1, UInt32(b & 0x1F))
        case 0xE0...0xEF: (pending, value) = (2, UInt32(b & 0x0F)); low = b == 0xE0 ? 0xA0 : 0x80; high = b == 0xED ? 0x9F : 0xBF
        case 0xF0...0xF4: (pending, value) = (3, UInt32(b & 0x07)); low = b == 0xF0 ? 0x90 : 0x80; high = b == 0xF4 ? 0x8F : 0xBF
        default: rejected = true; return 0xFFFD
        }
        return nil
    }
}

/// 16 bytes as vector lanes. Swift compiles SIMD comparisons lane by lane, but wrapping arithmetic
/// and bit operations vectorize, so lane tests are arithmetic: a lane's top bit is its result.
struct Lanes {
    typealias V = SIMD16<UInt8>
    let v: V
    @inline(__always) init(_ v: V) { self.v = v }
    @inline(__always) init(_ p: UnsafePointer<UInt8>) { v = UnsafeRawPointer(p).loadUnaligned(as: V.self) }
    /// Lanes < t: the borrow out of lane - t.
    @inline(__always) func lt(_ t: UInt8) -> V { let b = V(repeating: t), d = v &- b; return (~v & b | ~(v ^ b) & d) & 0x80 }
    @inline(__always) func ge(_ t: UInt8) -> V { ~lt(t) & 0x80 }
    @inline(__always) func eq(_ t: UInt8) -> V { let x = v ^ V(repeating: t); return (x &- 1) & ~x & 0x80 }
    /// The top bit of every lane, lane 0 first (movemask: one multiply packs a word's top bits).
    @inline(__always) static func bits(_ m: V) -> Int {
        let (a, b) = unsafeBitCast(m, to: (UInt64, UInt64).self), k: UInt64 = 0x0002_0408_1020_4081
        let lo = ((a & 0x8080_8080_8080_8080) &* k) >> 56, hi = ((b & 0x8080_8080_8080_8080) &* k) >> 56
        return Int(lo | hi << 8)
    }
}
