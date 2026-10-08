// The kitty clipboard protocol pieces a surface answers with (Ghostty's terminal/kitty/
// clipboard_grants.zig and clipboard_response.zig): one-time passwords and their grants, and
// OSC 5522 read responses.

/// Passwords granted for reads or writes (at most 32; the oldest goes first).
struct KittyGrants {
    struct Entry { var pw: [UInt8], read = false, write = false, oneTime = false }
    var entries: [Entry] = []

    /// A paste event's password: 22 characters of kitty's alphabet from secure random bytes
    /// (bytes at or above the alphabet's last whole multiple are skipped).
    static func password(_ entropy: (Int) -> [UInt8]) -> [UInt8] {
        let alphabet = Array("23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ".utf8), limit = 256 / alphabet.count * alphabet.count
        var pw: [UInt8] = []
        while pw.count < 22 {
            for b in entropy(44) where Int(b) < limit && pw.count < 22 { pw.append(alphabet[Int(b) % alphabet.count]) }
        }
        return pw
    }

    /// Grants.use: whether `pw` was granted this direction; a one-time grant goes with its first use.
    mutating func use(_ pw: [UInt8], read: Bool) -> Bool {
        guard !pw.isEmpty, let i = entries.firstIndex(where: { $0.pw == pw }) else { return false }
        let allowed = read ? entries[i].read : entries[i].write
        if entries[i].oneTime { entries.swapAt(i, entries.count - 1); entries.removeLast() }
        return allowed
    }

    mutating func grant(_ pw: [UInt8], read: Bool, oneTime: Bool) {
        guard !pw.isEmpty, pw.count <= 128 else { return }
        let i = entries.firstIndex { $0.pw == pw } ?? {
            if entries.count >= 32 { entries.removeFirst() }
            entries.append(Entry(pw: pw, oneTime: oneTime))
            return entries.count - 1
        }()
        entries[i].oneTime = entries[i].oneTime && oneTime
        if read { entries[i].read = true } else { entries[i].write = true }
    }
}

enum KittyClipboard {
    /// A successful read's replies (ReadSuccess.encode): OK, the MIME listing when asked, each
    /// content in 4096-byte DATA chunks, DONE.
    static func readSuccess(primary: Bool, id: [UInt8] = [], pw: [UInt8]?, list: Bool = true, available: [[UInt8]], contents: [ClipboardContent] = [],
                            terminator: Terminator = .st) -> [UInt8] {
        // The listing: space-separated types that fit one 4096-byte chunk with the newline (up to the first that doesn't).
        var listing: [UInt8] = []
        for (i, m) in available.enumerated() {
            let sep = i == 0 ? [] : [UInt8(0x20)]
            if listing.count + sep.count + m.count + 1 > 4096 { break }
            listing += sep + m
        }
        let data = available.isEmpty ? [] : listing + [0x0A]
        let r = { (status: String, mime: [UInt8]?, payload: [UInt8]) in response("read", status, id: id, mime: mime, pw: pw, payload: payload, terminator: terminator) }
        let chunks = contents.flatMap { c in Swift.stride(from: 0, to: c.data.count, by: 4096).map { r("DATA", c.mime, Array(c.data[$0..<min($0 + 4096, c.data.count)])) } }
        return response("read", "OK", primary: primary, id: id, pw: pw, terminator: terminator) + (list ? r("DATA", [0x2E], data) : []) + chunks.joined() + r("DONE", nil, [])
    }

    /// Response.encode: `ESC ] 5522 ; type=OP:status=S[:loc=primary][:id=..][:mime=b64][:pw=b64][;b64 payload]` and the terminator.
    static func response(_ op: String, _ status: String, primary: Bool = false, id: [UInt8] = [], mime: [UInt8]? = nil, pw: [UInt8]? = nil,
                         payload: [UInt8] = [], terminator: Terminator = .st) -> [UInt8] {
        var s = ascii("\u{1B}]5522;type=\(op):status=\(status)")
        if primary { s += ascii(":loc=primary") }
        if !id.isEmpty { s += ascii(":id=") + id }
        if let mime { s += ascii(":mime=") + Base64.encode(mime) }
        if let pw { s += ascii(":pw=") + Base64.encode(pw) }
        if !payload.isEmpty { s += [0x3B] + Base64.encode(payload) }
        return s + ascii(terminator == .st ? "\u{1B}\\" : "\u{07}")
    }
}

enum Base64 {
    /// Standard alphabet with padding (Zig's std.base64.standard).
    static func encode(_ data: [UInt8]) -> [UInt8] {
        let table = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var out: [UInt8] = []
        out.reserveCapacity((data.count + 2) / 3 * 4)
        for i in stride(from: 0, to: data.count, by: 3) {
            let n = min(3, data.count - i)
            let v = (UInt32(data[i]) << 16) | (n > 1 ? UInt32(data[i + 1]) << 8 : 0) | (n > 2 ? UInt32(data[i + 2]) : 0)
            for k in 0..<4 { out.append(k <= n ? table[Int(v >> (18 - 6 * k) & 63)] : 0x3D) }
        }
        return out
    }
}

/// An OSC 5522 command's metadata (clipboard_command.zig Metadata): `key=value` records split by
/// ':'; ids keep [A-Za-z0-9-_+.] (512 at most); MIME types, names and passwords are base64.
struct KittyMetadata {
    enum Op: String { case read, write, wdata, walias }
    enum Invalid: Error { case value }
    var op: Op, primary = false, id: [UInt8] = [], mime: [UInt8] = [], pw: [UInt8] = [], name: [UInt8] = []

    /// The records by key (the last of a key wins); nil when a record has no '='.
    static func fields(_ raw: [UInt8]) -> [String: [UInt8]]? {
        var f: [String: [UInt8]] = [:]
        for record in raw.split(separator: 0x3A, omittingEmptySubsequences: false) {
            guard let eq = record.firstIndex(of: 0x3D) else { return nil }
            f[String(decoding: record[..<eq], as: UTF8.self)] = Array(record[(eq + 1)...])
        }
        return f
    }

    /// The operation alone (for commands whose values are invalid).
    static func operation(_ raw: [UInt8]) -> Op? { fields(raw)?["type"].flatMap { Op(rawValue: String(decoding: $0, as: UTF8.self)) } }

    /// nil: not a command (ignored); throws for a value that isn't valid base64/UTF-8 or too long.
    static func parse(_ raw: [UInt8]) throws -> KittyMetadata? {
        guard let f = fields(raw), let op = operation(raw) else { return nil }
        // decodeValue: at most `max` bytes decoded (and base64 no longer than that encodes to).
        func decode(_ v: [UInt8], _ max: Int, tooLong: [UInt8]? = nil) throws -> [UInt8] {
            if v.count > (max + 2) / 3 * 4 { if let tooLong { return tooLong }; throw Invalid.value }
            guard let d = Base64.decodeStrict(v, paddingRequired: true), isUTF8(d) else { throw Invalid.value }
            if d.count > max { if let tooLong { return tooLong }; throw Invalid.value }
            return d
        }
        let idChars = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+.".utf8)
        return KittyMetadata(op: op, primary: f["loc"] == Array("primary".utf8), id: Array((f["id"] ?? []).filter(idChars.contains).prefix(512)),
                             mime: try decode(f["mime"] ?? [], 256), pw: try decode(f["pw"] ?? [], 128, tooLong: []), name: try decode(f["name"] ?? [], 256))
    }
}

/// simd.base64.Streaming: base64 in pieces; a group cut between pieces waits in `carry`, '=' ends
/// the data.
struct Base64Stream {
    var carry: [UInt8] = []
    enum Invalid: Error { case data }

    static func partial(_ pos: Int, _ c: UInt8) -> Bool { Base64.value(c) != nil || pos >= 2 && c == 0x3D }

    mutating func feed(_ input: [UInt8]) throws -> [UInt8] {
        var (rest, out) = (input[...], [UInt8]())
        if !carry.isEmpty {
            let take = rest.prefix(4 - carry.count)
            for (i, c) in take.enumerated() where !Self.partial(carry.count + i, c) { throw Invalid.data }
            carry += take
            rest = rest.dropFirst(take.count)
            if carry.count < 4 { return [] }
            guard let d = Base64.decodeStrict(carry, paddingRequired: true) else { throw Invalid.data }
            let padded = carry[3] == 0x3D
            (out, carry) = (d, [])
            if padded {
                if !rest.isEmpty { throw Invalid.data }
                return out
            }
        }
        let bulk = rest.prefix(rest.count - rest.count % 4)
        guard let d = Base64.decodeStrict(Array(bulk), paddingRequired: true) else { throw Invalid.data }
        out += d
        if bulk.last == 0x3D {
            if bulk.count != rest.count { throw Invalid.data }
            return out
        }
        let tail = rest.dropFirst(bulk.count)
        for (i, c) in tail.enumerated() where !Self.partial(i, c) { throw Invalid.data }
        carry = Array(tail)
        return out
    }

    /// The data must end on a whole group.
    mutating func finish() throws {
        defer { carry = [] }
        if !carry.isEmpty { throw Invalid.data }
    }
}

/// A clipboard write in progress (clipboard_write.zig WriteState): `wdata` chunks per MIME type
/// into one spool (at most 64 types), `walias` names for a type (at most 64), committed as contents.
struct KittyWrite {
    enum Failure: Error { case tooLarge, invalid }
    var primary: Bool, id: [UInt8], pw: [UInt8], name: [UInt8], maxSize: Int
    var spool: [UInt8] = [], entries: [(mime: [UInt8], start: Int, count: Int)] = [], aliases: [(alias: [UInt8], target: [UInt8])] = []
    var current: Int?, decoder = Base64Stream()

    init(_ m: KittyMetadata, maxSize: Int) { (primary, id, pw, name, self.maxSize) = (m.primary, m.id, m.pw, m.name, maxSize) }

    mutating func data(_ mime: [UInt8], _ payload: [UInt8]) throws {
        if current.map({ entries[$0].mime }) != mime {
            if let i = current {
                do { try decoder.finish() } catch { throw Failure.invalid }
                entries[i].count = spool.count - entries[i].start
            }
            if let i = entries.firstIndex(where: { $0.mime == mime }) {
                (entries[i].start, entries[i].count, current) = (spool.count, 0, i)
            } else if entries.count >= 64 {
                current = nil
                return
            } else {
                entries.append((mime, spool.count, 0))
                current = entries.count - 1
            }
        }
        let d: [UInt8]
        do { d = try decoder.feed(payload) } catch { throw Failure.invalid }
        if d.count > max(maxSize - spool.count, 0) { throw Failure.tooLarge }
        spool += d
    }

    /// `walias`: the payload's names (whitespace separated, up to 256 bytes each) point at `mime`.
    mutating func alias(_ mime: [UInt8], _ payload: [UInt8]) throws {
        guard let d = Base64.decodeStrict(payload, paddingRequired: true), isUTF8(d) else { throw Failure.invalid }
        let names = d.split(whereSeparator: { [0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C].contains($0) }).map(Array.init).filter { $0.count <= 256 }
        for n in names {
            if let i = aliases.firstIndex(where: { $0.alias == n }) { aliases[i].target = mime; continue }
            if aliases.count >= 64 { return }
            aliases.append((n, mime))
        }
    }

    /// The contents: each type's data, then aliases (replacing a type's data or added after).
    mutating func commit() throws -> [ClipboardContent] {
        if let i = current {
            do { try decoder.finish() } catch { throw Failure.invalid }
            entries[i].count = spool.count - entries[i].start
            current = nil
        }
        var contents = entries.map { ClipboardContent(mime: $0.mime, data: Array(spool[$0.start..<$0.start + $0.count])) }
        for a in aliases {
            guard let target = contents.first(where: { $0.mime == a.target }) else { continue }
            if let i = contents.firstIndex(where: { $0.mime == a.alias }) { contents[i].data = target.data } else { contents.append(ClipboardContent(mime: a.alias, data: target.data)) }
        }
        return contents
    }
}

/// std.unicode.utf8ValidateSlice: decoding changes nothing (no replacement characters).
func isUTF8(_ b: [UInt8]) -> Bool { String(decoding: b, as: UTF8.self).utf8.elementsEqual(b) }
