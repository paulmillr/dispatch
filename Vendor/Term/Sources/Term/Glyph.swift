// The glyph protocol (APC 25a1; terminal/apc/glyph/*.zig): support and codepoint queries,
// glyph registrations at private-use codepoints (TrueType simple-glyph outlines) kept in a
// per-terminal glossary of 1024, and clears. Ghostty only stores the registrations: nothing
// draws them, and a query reports glossary coverage only.

/// A request: `s`, `q`, `r` or `c`, its raw text after the identifier.
public struct GlyphRequest {
    public enum Verb: UInt8 { case support = 0x73, query = 0x71, register = 0x72, clear = 0x63 }
    let verb: Verb, raw: [UInt8]
    /// Register: where the payload starts (the last `;`).
    let payloadIndex: Int

    init?(_ raw: [UInt8]) {
        guard raw.count >= 2, raw[1] == 0x3B, let verb = Verb(rawValue: raw[0]) else { return nil }
        let last = raw.lastIndex(of: 0x3B)!
        if verb == .register, last <= 1 { return nil }
        (self.verb, self.raw, payloadIndex) = (verb, raw, last)
    }

    /// Options text: after `v;`, up to the payload for a register.
    var options: ArraySlice<UInt8> { raw[2..<(verb == .register ? payloadIndex : raw.count)] }
    var payload: ArraySlice<UInt8> { raw[(payloadIndex + 1)...] }

    /// An option's value: the last `key=` segment.
    func option(_ key: String) -> ArraySlice<UInt8>? {
        let key = Array(key.utf8)
        var found: ArraySlice<UInt8>?
        for seg in options.split(separator: 0x3B, omittingEmptySubsequences: false) {
            if let eq = seg.firstIndex(of: 0x3D), Array(seg[..<eq]) == key { found = seg[(eq + 1)...] }
        }
        return found
    }

    var cp: UInt32? { option("cp").flatMap { zigInt($0, base: 16, max: 0x1FFFFF, signed: true) }.map(UInt32.init) }
    func number(_ key: String, _ fallback: UInt32?) -> UInt32? {
        guard let v = option(key) else { return fallback }
        return zigInt(v, base: 10, max: UInt64(UInt32.max), signed: true).map(UInt32.init)
    }
    /// A named option: absent -> `fallback`, unknown name -> nil.
    func name<E: RawRepresentable>(_ key: String, _ fallback: E) -> E? where E.RawValue == String {
        guard let v = option(key) else { return fallback }
        return E(rawValue: String(decoding: v, as: UTF8.self))
    }
}

public struct GlyphOutline: Equatable {
    public struct Point: Equatable { public var x: Int32, y: Int32, onCurve: Bool }
    public var contours: [UInt16], points: [Point]

    enum Failure: Error { case malformed, composite, hinting, tooLarge }

    /// A TrueType `glyf` entry, simple glyphs only, no instructions (font/opentype/glyf.zig decode);
    /// `limit`: the most its tables may take (contours 2 bytes, points 12 bytes each, like Ghostty's).
    init(_ data: [UInt8], limit: Int) throws {
        var at = 0
        func byte() throws -> UInt8 { guard at < data.count else { throw Failure.malformed }; defer { at += 1 }; return data[at] }
        func u16() throws -> UInt16 { UInt16(try byte()) << 8 | UInt16(try byte()) }
        let n = Int16(bitPattern: try u16())
        for _ in 0..<4 { _ = try u16() }
        guard n >= 0 else { throw Failure.composite }
        (contours, points) = ([], [])
        if n == 0, data.count - at < 2 { return }
        guard Int(n) * 2 <= limit else { throw Failure.tooLarge }
        var last = -1
        for _ in 0..<n {
            let e = Int(try u16())
            guard e > last else { throw Failure.malformed }
            last = e
            contours.append(UInt16(e))
        }
        guard try u16() == 0 else { throw Failure.hinting }
        let count = last + 1
        // Ghostty's allocations under the limit: contours, points (12 bytes), flags past its 4 KiB stack buffer.
        guard Int(n) * 2 + count * 12 + (count > 4096 ? count : 0) <= limit else { throw Failure.tooLarge }
        var flags: [UInt8] = []
        while flags.count < count {
            let f = try byte()
            flags.append(f)
            if f & 8 != 0 {
                let r = Int(try byte())
                guard flags.count + r <= count else { throw Failure.malformed }
                flags += Array(repeating: f, count: r)
            }
        }
        func coords(_ short: UInt8, _ same: UInt8) throws -> [Int32] {
            var v: Int32 = 0
            return try flags.map { f in
                let d: Int32 = f & short != 0 ? (f & same != 0 ? 1 : -1) * Int32(try byte()) : f & same != 0 ? 0 : Int32(Int16(bitPattern: try u16()))
                let (s, o) = v.addingReportingOverflow(d)
                guard !o else { throw Failure.malformed }
                v = s
                return v
            }
        }
        let xs = try coords(2, 16), ys = try coords(4, 32)
        points = (0..<count).map { Point(x: xs[$0], y: ys[$0], onCurve: flags[$0] & 1 != 0) }
    }
}

public struct GlyphEntry: Equatable {
    public enum Glyph: Equatable { case glyf(GlyphOutline) }
    public struct DesignMetrics: Equatable { public var unitsPerEm, advanceWidth, lineHeight: UInt32 }
    public enum Width: String { case narrow, wide }
    public var glyph: Glyph, design: DesignMetrics, width: Width, constraint: GlyphConstraint
}

/// A terminal's registrations, oldest first (a re-registration moves to the end).
public struct Glossary {
    static let max = 1024, glyfLimit = 64 * 1024
    public private(set) var entries: [(cp: UInt32, entry: GlyphEntry)] = []

    static func privateUse(_ cp: UInt32) -> Bool { (0xE000...0xF8FF).contains(cp) || (0xF0000...0xFFFFD).contains(cp) || (0x100000...0x10FFFD).contains(cp) }
    public func contains(_ cp: UInt32) -> Bool { entries.contains { $0.cp == cp } }

    /// Executes a request (apc/glyph/execute.zig); the reply to send, if any.
    mutating func execute(_ r: GlyphRequest) -> [UInt8]? {
        func reply(_ s: String) -> [UInt8] { Array("\u{1B}_25a1;\(s)\u{1B}\\".utf8) }
        switch r.verb {
        case .support: return reply("s;fmt=glyf")
        case .query:
            guard let cp = r.cp else { return nil }
            return reply("q;cp=\(String(cp, radix: 16));status=\(contains(cp) ? "glossary" : "")")
        case .register:
            let mode = r.option("reply").flatMap { ["0": 0, "1": 1, "2": 2][String(decoding: $0, as: UTF8.self)] } ?? 1
            do {
                let cp = try register(r)
                return mode == 1 ? reply("r;cp=\(String(cp, radix: 16));status=0") : nil
            } catch {
                return mode == 0 ? nil : reply("r;cp=\(String(r.cp ?? 0, radix: 16));status=1;reason=\(error)")
            }
        case .clear:
            if let cp = r.cp {
                guard Glossary.privateUse(cp) else { return reply("c;status=1;reason=out_of_namespace") }
                entries.removeAll { $0.cp == cp }
            } else if r.option("cp") != nil {
                return reply("c;status=1;reason=malformed_payload")
            } else {
                entries = []
            }
            return reply("c;status=0")
        }
    }

    enum Reason: Error, CustomStringConvertible {
        case outOfNamespace, malformedPayload, compositeUnsupported, hintingUnsupported, payloadTooLarge
        var description: String {
            switch self {
            case .outOfNamespace: "out_of_namespace"
            case .malformedPayload: "malformed_payload"
            case .compositeUnsupported: "composite_unsupported"
            case .hintingUnsupported: "hinting_unsupported"
            case .payloadTooLarge: "payload_too_large"
            }
        }
    }

    /// Glossary.Entry.init + register: the options, then the payload, then the namespace.
    mutating func register(_ r: GlyphRequest) throws -> UInt32 {
        guard let cp = r.cp else { throw Reason.malformedPayload }
        enum Format: String { case glyf, colrv0, colrv1 }
        enum Size: String { case height, advance, contain, cover, stretch }
        enum H: String { case start, center, end }
        enum V: String { case start, center, end, baseline }
        let upm = r.number("upm", 1000)
        let widths: [String: GlyphEntry.Width] = ["1": .narrow, "2": .wide]
        let width = r.option("width").map { widths[String(decoding: $0, as: UTF8.self)] } ?? GlyphEntry.Width.narrow
        guard let fmt = r.name("fmt", Format.glyf), let upm, let aw = r.number("aw", upm), let lh = r.number("lh", upm), upm > 0, aw > 0, lh > 0,
              let width, let size = r.name("size", Size.height) else { throw Reason.malformedPayload }
        var (h, v) = (H.center, V.center)
        if let a = r.option("align") {
            let parts = a.split(separator: 0x2C, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard parts.count == 2, let ph = H(rawValue: parts[0]), let pv = V(rawValue: parts[1]) else { throw Reason.malformedPayload }
            (h, v) = (ph, pv)
        }
        var pad = [0.0, 0, 0, 0]
        if let p = r.option("pad") {
            let parts = p.split(separator: 0x2C, omittingEmptySubsequences: false).map(Glossary.fraction)
            guard parts.count == 4, !parts.contains(nil) else { throw Reason.malformedPayload }
            let f = parts.map { $0! }
            if f[3] + f[1] < 1, f[0] + f[2] < 1 { pad = f }
        }
        var c = GlyphConstraint()
        c.size = [.height: .none, .advance: .none, .contain: .cover, .cover: .cover, .stretch: .stretch][size]!
        c.alignHorizontal = [.start: .start, .center: .center, .end: .end][h]!
        c.alignVertical = [.start: .start, .center: .center, .end: .end, .baseline: .start][v]!
        (c.padTop, c.padRight, c.padBottom, c.padLeft) = (pad[0], pad[1], pad[2], pad[3])
        guard fmt == .glyf else { throw Reason.malformedPayload }
        // std.base64.standard: whole padded groups, the size checked before the characters, canonical.
        let b64 = Array(r.payload), padding = b64.suffix(2).reversed().prefix { $0 == 0x3D }.count
        guard b64.count % 4 == 0 else { throw Reason.malformedPayload }
        guard b64.count / 4 * 3 - padding <= Glossary.glyfLimit else { throw Reason.payloadTooLarge }
        guard let data = Base64.decodeStrict(b64, paddingRequired: true), Base64.encode(data) == b64 else { throw Reason.malformedPayload }
        let outline: GlyphOutline
        do { outline = try GlyphOutline(data, limit: Glossary.glyfLimit) } catch let e as GlyphOutline.Failure {
            throw [.malformed: Reason.malformedPayload, .composite: .compositeUnsupported, .hinting: .hintingUnsupported, .tooLarge: .payloadTooLarge][e]!
        }
        guard Glossary.privateUse(cp) else { throw Reason.outOfNamespace }
        entries.removeAll { $0.cp == cp }
        entries.append((cp, GlyphEntry(glyph: .glyf(outline), design: .init(unitsPerEm: upm, advanceWidth: aw, lineHeight: lh), width: width, constraint: c)))
        if entries.count > Glossary.max { entries.removeFirst() }
        return cp
    }

    /// terminal/fraction.zig: [+-]digits[.digits] within 0...1.
    static func fraction(_ s: ArraySlice<UInt8>) -> Double? {
        var v = s, negative = false
        if let f = v.first, f == 0x2B || f == 0x2D { negative = f == 0x2D; v = v.dropFirst() }
        let dot = v.firstIndex(of: 0x2E) ?? v.endIndex
        let (whole, frac) = (v[..<dot], dot < v.endIndex ? v[(dot + 1)...] : [])
        guard !(whole + frac).isEmpty, (whole + frac).allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        let int = whole.reduce(0.0) { $0 * 10 + Double($1 - 0x30) }
        var (n, scale): (UInt64, UInt64) = (0, 1)
        for d in frac where scale < 1_000_000_000_000_000 { n = n * 10 + UInt64(d - 0x30); scale *= 10 }
        let r = (negative ? -1 : 1) * (int + Double(n) / Double(scale))
        return r >= 0 && r <= 1 ? r : nil
    }
}
