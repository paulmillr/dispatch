// Program status (OSC 7501, superlogical.com/rex/docs/build/program-status rev 0.3): programs
// report idle/working/done/blocked/error records; the terminal keeps them and answers only the `?`
// query. Not part of Ghostty.

/// One stored record, with `app` resolved from the nearest ancestor that has one.
public struct ProgramStatus: Equatable, Sendable {
    public enum State: String, Sendable { case idle, working, done, blocked, error }
    public enum Kind: String, Sendable { case permission, question, auth }
    /// "" is the root record; children are "/"-separated paths.
    public var id: String
    public var state: State
    /// `blocked` only.
    public var kind: Kind?
    /// 0-100 for `working` and `blocked`; nil: indeterminate.
    public var progress: UInt8?
    public var app: String?
    /// Decoded UTF-8, free of control characters (not yet of format characters).
    public var title: String?, message: String?
    /// The terminal's report counter when this record was last replaced (a host can tell a record
    /// it has already shown from a new one with the same contents).
    public var serial: UInt64

    public init(id: String = "", state: State, kind: Kind? = nil, progress: UInt8? = nil, app: String? = nil,
                title: String? = nil, message: String? = nil, serial: UInt64 = 0) {
        (self.id, self.state, self.kind, self.progress, self.app, self.title, self.message, self.serial) =
            (id, state, kind, progress, app, title, message, serial)
    }

    /// Whether a new shell prompt or the process's exit ends it.
    public var transient: Bool { state == .working || state == .blocked }
}

/// A parsed OSC 7501 body: a query, or a report that passed every check.
public enum ProgramStatusCommand: Equatable {
    /// `state=clear`: the record `id` and its descendants (nil: every record).
    case clear(String?)
    /// The record as reported (`app` not inherited, `serial` unset).
    case report(ProgramStatus)
    case query(Terminator)

    /// Bytes from OSC through ST, of which "ESC ] 7501 ;" is 7.
    static let sequenceLimit = 4096
    static let valueBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.,+/=-".utf8)
    static let idBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-".utf8)

    /// nil: discarded whole (a broken limit, bad base64, a control character, no or unknown state, a bad id).
    static func parse(_ body: [UInt8], _ t: Terminator) -> ProgramStatusCommand? {
        guard 7 + body.count + (t == .bel ? 1 : 2) <= sequenceLimit else { return nil }
        if body == [0x3F] { return .query(t) }
        var pairs: [String: [UInt8]] = [:]
        for raw in body.split(separator: 0x3A, omittingEmptySubsequences: false) {
            guard let eq = raw.firstIndex(of: 0x3D) else { continue }
            let key = trim(raw[..<eq], " \t"), value = trim(raw[(eq + 1)...], " \t")
            guard !key.isEmpty, key.allSatisfy({ (0x61...0x7A).contains($0) }), value.allSatisfy(valueBytes.contains) else { continue }
            guard key.count <= 16 else { return nil }
            pairs[String(decoding: key, as: UTF8.self)] = Array(value)
        }
        guard let rawState = pairs["state"].map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        var id: String?
        if let v = pairs["id"] {
            guard v.count <= 128 else { return nil }
            let segments = v.split(separator: 0x2F, omittingEmptySubsequences: false)
            guard segments.count <= 8, segments.allSatisfy({ (1...32).contains($0.count) && $0.allSatisfy(idBytes.contains) }) else { return nil }
            id = String(decoding: v, as: UTF8.self)
        }
        if rawState == "clear" { return .clear(id) }
        guard let state = ProgramStatus.State(rawValue: rawState) else { return nil }
        guard let texts = try? (title: text(pairs["title"], 192), message: text(pairs["msg"], 2048)), pairs["app"].map({ $0.count <= 32 }) != false else { return nil }
        let app = pairs["app"].flatMap { !$0.isEmpty && $0.allSatisfy(idBytes.contains) ? String(decoding: $0, as: UTF8.self) : nil }
        let kind = state == .blocked ? pairs["kind"].flatMap { ProgramStatus.Kind(rawValue: String(decoding: $0, as: UTF8.self)) } : nil
        var progress: UInt8?
        if state == .working || state == .blocked, let v = pairs["progress"], (1...3).contains(v.count), v.allSatisfy({ (0x30...0x39).contains($0) }),
           let n = Int(String(decoding: v, as: UTF8.self)), n <= 100 { progress = UInt8(n) }
        return .report(ProgramStatus(id: id ?? "", state: state, kind: kind, progress: progress, app: app, title: texts.title, message: texts.message))
    }

    struct Discarded: Error {}

    /// A base64 text value (nil: absent); throws when the report must be discarded: its encoding
    /// longer than `max` decoded bytes need, bad base64 or UTF-8, a control character.
    private static func text(_ v: [UInt8]?, _ max: Int) throws -> String? {
        guard let v else { return nil }
        guard v.count <= (max + 2) / 3 * 4, let d = Base64.decodeStrict(v), d.count <= max, isUTF8(d) else { throw Discarded() }
        let s = String(decoding: d, as: UTF8.self)
        guard !s.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else { throw Discarded() }
        return s
    }
}

/// A terminal's records (they belong to the terminal, not a screen). Kept oldest update first.
public struct ProgramStatusRecords: Equatable {
    /// The most records kept (the protocol's cap; at least 64 must fit).
    public static let capacity = 256
    var records: [ProgramStatus] = []
    var serial: UInt64 = 0

    public init() {}

    /// The records with `app` inherited, root first, then by id.
    public var all: [ProgramStatus] {
        let own = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.app) })
        return records.map { r in
            var r = r
            var path = r.id
            while r.app == nil, !path.isEmpty {
                path = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
                if let app = own[path] ?? nil { r.app = app }
            }
            return r
        }.sorted { $0.id < $1.id }
    }

    /// True when the records changed.
    @discardableResult
    public mutating func apply(_ command: ProgramStatusCommand) -> Bool {
        switch command {
        case .query: return false
        case .clear(nil):
            defer { records.removeAll() }
            return !records.isEmpty
        case .clear(let id?):
            let before = records.count
            records.removeAll { $0.id == id || $0.id.hasPrefix(id + "/") }
            return records.count != before
        case .report(var record):
            serial += 1
            record.serial = serial
            records.removeAll { $0.id == record.id }
            if records.count >= Self.capacity { records.removeFirst(records.count - Self.capacity + 1) }
            records.append(record)
            return true
        }
    }

    /// A new shell prompt or the process's exit: working and blocked records end. True when any did.
    @discardableResult
    public mutating func endTransient() -> Bool {
        let before = records.count
        records.removeAll(where: \.transient)
        return records.count != before
    }

    /// A full reset.
    @discardableResult
    public mutating func reset() -> Bool { apply(.clear(nil)) }
}
