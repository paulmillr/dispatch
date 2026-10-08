import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Ordered app inputs and outputs. Native helper captures remain independent evidence.
/// A replay consumes every event; unknown work never falls back to a live process.
final class AppReplay: @unchecked Sendable {
    struct Event: Codable, Equatable, Sendable {
        let kind: String
        let id: Int
        let data: Data
    }

    struct Failure: Codable {
        let helper: HelperFailure?
        let domain: String
        let code: Int
        let message: String
        init(_ error: any Error) {
            helper = error as? HelperFailure
            let value = error as NSError
            domain = value.domain; code = value.code; message = value.localizedDescription
        }
        var error: any Error { helper.map { $0 as any Error } ?? NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    struct Launch: Codable, Equatable {
        let executable: String?
        let arguments: [String]
        let directory: String?
        init(_ process: Process) {
            executable = process.executableURL?.path
            arguments = process.arguments ?? []
            directory = process.currentDirectoryURL?.path
        }
    }

    final class Ticket: @unchecked Sendable {
        let id: Int
        let journal: AppReplay
        var replaying: Bool { journal.replaying }
        fileprivate init(_ id: Int, _ journal: AppReplay) { self.id = id; self.journal = journal }
        func action(kind: String, data: Data = Data()) throws {
            try journal.action(.init(kind: "out." + kind, id: id, data: data))
        }
        func emit(kind: String, data: Data = Data()) throws {
            try journal.emit(.init(kind: "in." + kind, id: id, data: data))
        }
        func listen(_ receive: @escaping (Event) -> Void, failed: @escaping (any Error) -> Void) throws {
            let failure = journal.lock.withLock { () -> (any Error)? in
                if let failure = journal.failure { return failure }
                journal.listeners[id] = receive
                journal.failures[id] = failed
                return nil as (any Error)?
            }
            if let failure { failed(failure); return }
            try journal.pump()
        }
    }

    /// Captures journal ownership when a real native resource is created, not when it later becomes ready.
    final class Boundary: @unchecked Sendable {
        fileprivate let journal: AppReplay
        fileprivate let event: Event
        fileprivate let index: Int?
        private var completed = false
        fileprivate init(_ journal: AppReplay, _ event: Event, _ index: Int?) {
            self.journal = journal; self.event = event; self.index = index
        }
        func arrive(ready: @escaping () -> Void, failed: @escaping (any Error) -> Void) throws {
            try journal.checked {
                try journal.lock.withLock {
                    if let failure = journal.failure { throw failure }
                    guard !journal.closed else { throw AppReplay.error("native event belongs to a finished app journal") }
                    if let index {
                        guard !journal.consumed.contains(index), journal.barriers[index] == nil else {
                            throw AppReplay.error("native boundary arrived twice")
                        }
                        journal.barriers[index] = (event.kind.hasSuffix(".ready") ? ready : nil, failed)
                    } else {
                        guard !completed else { throw AppReplay.error("native boundary arrived twice") }
                        try journal.accept(event)
                        completed = true
                        journal.native -= 1
                    }
                }
                if index == nil { ready() }
                try journal.pump()
            }
        }
        func cancel() {
            do {
                try journal.checked {
                    try journal.lock.withLock {
                        guard !journal.closed, journal.failure == nil else { return }
                        if let index {
                            guard !journal.consumed.contains(index) else { return }
                            guard event.kind.hasSuffix(".retired") else {
                                throw AppReplay.error("native resource retired before its recorded readiness")
                            }
                            journal.barriers[index] = ({}, journal.barriers[index]?.failed ?? { _ in })
                        } else if !completed {
                            try journal.accept(.init(kind: String(event.kind.dropLast(6)) + ".retired", id: 0, data: event.data))
                            completed = true
                            journal.native -= 1
                        }
                    }
                    try journal.pump()
                }
            } catch { /* checked retains the first failure in this resource's journal. */ }
        }
    }

    private static let guardLock = NSLock()
    @TaskLocal private static var suppressed = false
    nonisolated(unsafe) private static var current: AppReplay?
    nonisolated(unsafe) private static var required = false
    private let lock = NSRecursiveLock()
    private let source: URL
    private(set) var diagnostic: URL?
    private let file: FileHandle
    let replaying: Bool
    private struct Row { let offset: UInt64; let length: Int; let kind: String; let id: Int }
    private var rows: [Row] = []
    private var streams: [Int: [Int]] = [:]
    private var cursors: [Int: Int] = [:]
    private var completions: [Int: Int] = [:]
    private var consumed: Set<Int> = []
    private var frontier = 0
    private var actions: [Int] = []
    private var action = 0
    private var line = 0
    private var serial = 0
    private var active: Set<Int> = []
    private var endings: [Int: Set<String>] = [:]
    private var listeners: [Int: (Event) -> Void] = [:]
    private var identities: [Int: [UInt64: UInt64]] = [:]
    private var decoders: [Int: HelperWire.Decoder] = [:]
    private var partial: [Int: Data] = [:]
    private var malformed: Set<Int> = []
    private var created: [String: [UUID: UUID]] = [:]
    private var failure: (any Error)?
    private var failures: [Int: (any Error) -> Void] = [:]
    private var closed = false
    private var pumping = false
    private var barriers: [Int: (ready: (() -> Void)?, failed: (any Error) -> Void)] = [:]
    private var reserved: Set<Int> = []
    private var native = 0

    static var replaying: Bool { guardLock.withLock { required } || ProcessInfo.processInfo.environment["DISPATCH_APP_REPLAY"] != nil }
    static var enabled: Bool { !suppressed && guardLock.withLock { current != nil } }
    static var settled: Bool { guardLock.withLock { current }?.settled ?? true }
    var settled: Bool { lock.withLock { active.isEmpty && native == 0 && reserved.isSubset(of: consumed) } }

    static func begin(url: URL, replaying: Bool) throws {
        try guardLock.withLock {
            guard current == nil else { throw error("another app journal is still active") }
            required = replaying
            current = try AppReplay(url: url, replaying: replaying)
        }
    }

    static func open(kind: String, input: Data) throws -> Ticket? {
        if suppressed {
            guard !replaying else { throw error("live nested operation attempted during app replay") }
            return nil
        }
        guard let journal = guardLock.withLock({ current }) else {
            guard !replaying else { throw error("app replay has no active case journal; live execution is disabled") }
            return nil
        }
        return try journal.open(kind: kind, input: input)
    }

    func open(kind: String, input: Data) throws -> Ticket {
        try checked {
        try pump()
        let ticket = try lock.withLock {
            let id = try creation(kind: kind, input: input)
            active.insert(id)
            if kind == "helper" { endings[id] = ["in.end", "in.exit"] }
            try accept(.init(kind: "open." + kind, id: id, data: input))
            return Ticket(id, self)
        }
        try pump()
        return ticket
        }
    }

    static func emit(kind: String, data: Data) throws {
        guard !suppressed else { return }
        try guardLock.withLock({ current })?.emit(.init(kind: "in." + kind, id: 0, data: data))
    }

    static func boundary(kind: String, data: Data) throws -> Boundary? {
        guard let journal = guardLock.withLock({ current }) else {
            guard !replaying else { throw error("native resource has no active app journal") }
            return nil
        }
        return try journal.boundary(kind: kind, data: data)
    }

    func boundary(kind: String, data: Data) throws -> Boundary {
        try checked {
            try lock.withLock {
                if let failure { throw failure }
                guard !closed else { throw Self.error("native resource belongs to a finished app journal") }
                let event = Event(kind: "out." + kind + ".ready", id: 0, data: data)
                if !replaying {
                    native += 1
                    return Boundary(self, event, nil)
                }
                let matches = try (streams[0] ?? []).filter { index in
                    guard !consumed.contains(index), !reserved.contains(index),
                          [event.kind, "out." + kind + ".retired"].contains(rows[index].kind) else { return false }
                    return try read(index).data == data
                }
                guard matches.count == 1, let index = matches.first else {
                    throw Self.error("missing or ambiguous native boundary: " + event.kind)
                }
                reserved.insert(index)
                return Boundary(self, try read(index), index)
            }
        }
    }

    static func listen(_ receive: @escaping (Event) -> Void) throws {
        guard let journal = guardLock.withLock({ current }) else { return }
        journal.lock.withLock { journal.listeners[0] = receive }
        try journal.pump()
    }

    static func query(kind: String, input: Data, read: () throws -> Data) throws -> Data {
        if suppressed {
            guard !replaying else { throw error("live nested query attempted during app replay") }
            return try read()
        }
        guard let journal = guardLock.withLock({ current }) else {
            guard !replaying else { throw error("app replay has no active query journal") }
            return try read()
        }
        try journal.pump()
        let result: Result<Data, any Error> = try journal.checked { try journal.lock.withLock {
            let id = try journal.creation(kind: kind, input: input)
            try journal.accept(.init(kind: "open." + kind, id: id, data: input))
            if journal.replaying {
                let prerequisite = journal.action < journal.actions.count ? journal.actions[journal.action] : journal.rows.count
                guard let position = journal.position(id), position < prerequisite,
                      let event = try journal.peek(id), event.id == id, ["in.result", "in.error"].contains(event.kind) else {
                    throw error("app event \(journal.line + 1): synchronous query result is missing")
                }
                journal.consume(id)
                if event.kind == "in.error" { return .failure(try JSONDecoder().decode(Failure.self, from: event.data).error) }
                return .success(event.data)
            }
            do {
                let result = try $suppressed.withValue(true) { try read() }
                try journal.append(.init(kind: "in.result", id: id, data: result))
                return .success(result)
            } catch {
                try journal.append(.init(kind: "in.error", id: id, data: JSONEncoder().encode(Failure(error))))
                return .failure(error)
            }
        } }
        try journal.pump()
        return try result.get()
    }

    static func fail(_ error: any Error) {
        guard let journal = guardLock.withLock({ current }) else { return }
        journal.reject(error)
    }

    /// Bind a generated identity when its producer first exports it, never by matching wire text.
    static func identity(kind: String, value: UUID) throws -> UUID {
        if suppressed {
            guard !replaying else { throw error("live nested identity attempted during app replay") }
            return value
        }
        guard let journal = guardLock.withLock({ current }) else {
            guard !replaying else { throw error("app replay has no creation journal") }
            return value
        }
        if let previous = journal.lock.withLock({ journal.created[kind]?[value] }) { return previous }
        let recorded = try JSONDecoder().decode(UUID.self, from: query(kind: "identity." + kind, input: Data()) {
            try JSONEncoder().encode(value)
        })
        try journal.lock.withLock {
            guard journal.created[kind]?.values.contains(recorded) != true else { throw error("a recorded creation identity was bound twice") }
            journal.created[kind, default: [:]][value] = recorded
        }
        return recorded
    }

    nonisolated(nonsending) static func unrecorded<Value>(_ read: () async throws -> Value) async throws -> Value {
        guard !replaying else { throw error("live nested operation attempted during app replay") }
        return try await $suppressed.withValue(true) { try await read() }
    }

    nonisolated(nonsending) static func run(kind: String, input: Data, read: () async throws -> Data) async throws -> Data {
        guard let ticket = try open(kind: kind, input: input) else { return try await read() }
        if ticket.replaying {
            final class Reply: @unchecked Sendable { let lock = NSLock(); var sent = false }
            let reply = Reply()
            return try await withCheckedThrowingContinuation { continuation in
                func complete(_ result: Result<Data, any Error>) {
                    if reply.lock.withLock({ if reply.sent { return false }; reply.sent = true; return true }) {
                        continuation.resume(with: result)
                    }
                }
                do {
                    try ticket.listen({ event in
                        do {
                            guard event.kind == "in.result" else {
                                throw try JSONDecoder().decode(Failure.self, from: event.data).error
                            }
                            complete(.success(event.data))
                        } catch { complete(.failure(error)) }
                    }, failed: { complete(.failure($0)) })
                } catch { complete(.failure(error)) }
            }
        }
        do {
            let result = try await unrecorded { try await read() }
            try ticket.emit(kind: "result", data: result)
            return result
        } catch {
            try ticket.emit(kind: "error", data: JSONEncoder().encode(Failure(error)))
            throw error
        }
    }

    static func finish() throws {
        guard let journal = guardLock.withLock({ current }) else {
            guard !replaying else { throw error("app replay has no completed case journal") }
            return
        }
        defer { guardLock.withLock { current = nil; required = false } }
        try journal.finish()
    }

    func finish() throws {
        try checked {
        try lock.withLock {
            defer { closed = true; try? file.close() }
            if let failure { throw failure }
            guard active.isEmpty else { throw Self.error("unfinished app lifetimes: \(active.sorted())") }
            guard native == 0 else { throw Self.error("unfinished native app generations: \(native)") }
            try accept(.init(kind: "finish", id: 0, data: Data()))
            if replaying, consumed.count != rows.count { throw Self.error("events remain after app journal footer") }
        }
        }
    }

    init(url: URL, replaying: Bool) throws {
        self.replaying = replaying
        self.source = url
        if replaying {
            file = try FileHandle(forReadingFrom: url)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            file = try Self.create(url)
        }
        // Keep offsets, not wire payloads, so independent streams do not retain the recording in RAM.
        if replaying {
            var buffer = Data(), offset: UInt64 = 0
            var endings: [Int: Set<String>] = [:]
            for _ in sequence(first: 0, next: { $0 + 1 }) {
                if let end = buffer.firstIndex(of: 10) {
                    let length = buffer.distance(from: buffer.startIndex, to: end) + 1
                    let event = try JSONDecoder().decode(Event.self, from: buffer.prefix(length))
                    let position = rows.count
                    rows.append(Row(offset: offset, length: length, kind: event.kind, id: event.id))
                    streams[event.id, default: []].append(position)
                    if event.kind.hasPrefix("out.") { actions.append(position) }
                    if event.kind == "open.helper" { endings[event.id] = ["in.end", "in.exit"] }
                    if ["in.result", "in.error"].contains(event.kind) { completions[event.id] = position }
                    else if endings[event.id] != nil {
                        endings[event.id]?.remove(event.kind)
                        if endings[event.id]?.isEmpty == true { completions[event.id] = position }
                    } else if event.kind == "in.exit" { completions[event.id] = position }
                    buffer.removeFirst(length); offset += UInt64(length)
                    continue
                }
                guard let bytes = try file.read(upToCount: 65_536), !bytes.isEmpty else {
                    guard buffer.isEmpty else { throw Self.error("truncated app journal after event \(rows.count)") }
                    break
                }
                buffer.append(bytes)
            }
        }
        try action(.init(kind: "header", id: 0, data: Data("app-journal-1:\(HelperBinary.version)".utf8)))
    }

    private static func create(_ url: URL) throws -> FileHandle {
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #else
        let descriptor = Glibc.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #endif
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func error(_ message: String) -> HelperFailure {
        HelperFailure(code: "replay", message: message)
    }

    private func position(_ id: Int) -> Int? {
        let cursor = cursors[id, default: 0]
        guard let stream = streams[id], cursor < stream.count else { return nil }
        return stream[cursor]
    }

    private func read(_ position: Int) throws -> Event {
        let row = rows[position]
        try file.seek(toOffset: row.offset)
        guard let bytes = try file.read(upToCount: row.length), bytes.count == row.length else {
            throw Self.error("truncated app journal at event \(position + 1)")
        }
        return try JSONDecoder().decode(Event.self, from: bytes)
    }

    private func peek(_ id: Int) throws -> Event? {
        try position(id).map { try read($0) }
    }

    private func consume(_ id: Int) {
        guard let position = position(id) else { return }
        consumed.insert(position); cursors[id, default: 0] += 1; line += 1
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            guard consumed.contains(frontier) else { break }
            frontier += 1
        }
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            guard action < actions.count, consumed.contains(actions[action]) else { break }
            action += 1
        }
    }

    private func metadata(_ lhs: Data, _ rhs: Data) throws -> Bool {
        if let left = try? JSONSerialization.jsonObject(with: lhs, options: .fragmentsAllowed),
           let right = try? JSONSerialization.jsonObject(with: rhs, options: .fragmentsAllowed) {
            return try JSONSerialization.data(withJSONObject: left, options: [.sortedKeys, .fragmentsAllowed])
                == JSONSerialization.data(withJSONObject: right, options: [.sortedKeys, .fragmentsAllowed])
        }
        return lhs == rhs
    }

    private func creation(kind: String, input: Data) throws -> Int {
        if let failure { throw failure }
        serial += 1
        guard replaying else { return serial }
        let barrier = position(0) ?? rows.count
        var matches: [Int] = [], candidates: [Int] = []
        for (index, row) in rows.enumerated() where index < barrier && row.kind == "open." + kind && !consumed.contains(index) {
            candidates.append(index)
            if try metadata(read(index).data, input) { matches.append(index) }
        }
        let first = matches.first
        let blocked = first.map { index in completions.values.contains { $0 < index && !consumed.contains($0) } } ?? false
        let ambiguous = first.map { index in matches.dropFirst().contains { $0 < completions[rows[index].id, default: rows.count] } } ?? false
        guard let first, !blocked, !ambiguous else {
            let index = first ?? candidates.first
            let expected = try index.map { try read($0) }
            throw try mismatch(expected, .init(kind: "open." + kind, id: serial, data: input),
                               at: index ?? frontier, reason: ambiguous ? "ambiguous overlapping creation" : "no matching creation with completed prerequisites")
        }
        return rows[first].id
    }

    private func mismatch(_ expected: Event?, _ actual: Event, at position: Int, reason: String) throws -> HelperFailure {
        let message = "app event \(position + 1): expected \(expected?.kind ?? "EOF") lifetime \(expected?.id ?? 0), received \(actual.kind) lifetime \(actual.id); \(reason)"
        let path = source.appendingPathExtension("mismatch-" + UUID().uuidString + ".json")
        let output = try Self.create(path)
        defer { try? output.close() }
        try output.write(contentsOf: JSONEncoder().encode([expected, actual]))
        diagnostic = path
        return Self.error(message + "; private diagnostic: " + path.path)
    }

    private func append(_ event: Event) throws {
        guard !closed else { throw Self.error("app journal is closed") }
        var bytes = try JSONEncoder().encode(event)
        bytes.append(10)
        try file.write(contentsOf: bytes)
        line += 1
    }

    private func checked<Value>(_ body: () throws -> Value) throws -> Value {
        do { return try body() }
        catch { reject(error); throw error }
    }

    private func reject(_ error: any Error) {
        let callbacks = lock.withLock { () -> [(any Error) -> Void] in
            guard failure == nil else { return [] }
            failure = error
            let callbacks = Array(failures.values) + barriers.values.map(\.failed)
            failures.removeAll(); listeners.removeAll(); active.removeAll(); endings.removeAll()
            barriers.removeAll()
            return callbacks
        }
        for callback in callbacks { callback(error) }
    }

    private func action(_ event: Event) throws {
        try checked {
            try pump()
            try accept(event)
            try pump()
        }
    }

    private func accept(_ event: Event) throws {
        try lock.withLock {
            if let failure { throw failure }
            if replaying {
                let expected = try peek(event.id)
                let index = position(event.id) ?? rows.count
                let barrier = position(0) ?? rows.count
                var matches = expected?.kind == event.kind && expected?.id == event.id
                    && (event.id == 0 ? index == frontier : index < barrier)
                if matches, let expected {
                    if event.kind == "out.wire" {
                        var recorded: [HelperWire.Message] = [], actual: [HelperWire.Message] = []
                        var before = HelperWire.Decoder(), after = HelperWire.Decoder()
                        try before.feed(expected.data) { recorded.append($0) }
                        try after.feed(event.data) { actual.append($0) }
                        try before.finish(); try after.finish()
                        matches = recorded.count == actual.count
                        for (left, right) in zip(recorded, actual) {
                            matches = matches && left.kind == right.kind
                            if left.kind == .cancel {
                                matches = matches && identities[event.id]?[left.id] == right.id && left.body == right.body
                            } else {
                                let equal = try HelperBinary.decode(left.body) == HelperBinary.decode(right.body)
                                matches = matches && equal
                                if let mapped = identities[event.id]?[left.id] { matches = matches && mapped == right.id }
                                else {
                                    matches = matches && identities[event.id]?.values.contains(right.id) != true
                                    identities[event.id, default: [:]][left.id] = right.id
                                }
                            }
                        }
                    } else if event.kind.hasPrefix("open.") {
                        matches = try metadata(expected.data, event.data)
                    } else { matches = expected.data == event.data }
                }
                guard matches else {
                    throw try mismatch(expected, event, at: index, reason: "values and lifetime order must match exactly")
                }
                consume(event.id)
            } else {
                try append(event)
            }
        }
    }

    private func emit(_ event: Event) throws {
        try lock.withLock {
            guard !replaying else { throw Self.error("live external event attempted during app replay") }
            try append(event)
            complete(event)
        }
    }

    private func complete(_ event: Event) {
        if ["in.result", "in.error"].contains(event.kind) { active.remove(event.id) }
        else if endings[event.id] != nil {
            endings[event.id]?.remove(event.kind)
            if endings[event.id]?.isEmpty == true { active.remove(event.id) }
        } else if event.kind == "in.exit" { active.remove(event.id) }
        if event.id != 0 && !active.contains(event.id) {
            failures[event.id] = nil
            listeners[event.id] = nil
            endings[event.id] = nil
        }
    }

    private func pump() throws {
        try checked {
        guard replaying else { return }
        let started = lock.withLock { () -> Bool in
            guard !pumping else { return false }
            pumping = true
            return true
        }
        guard started else { return }
        defer { lock.withLock { pumping = false } }
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            let delivery = try lock.withLock { () -> (Event, (Event) -> Void)? in
                let barrier = position(0) ?? rows.count
                if barrier == frontier, let ready = barriers[barrier]?.ready {
                    barriers.removeValue(forKey: barrier)
                    let event = try read(barrier)
                    consume(0)
                    return (event, { _ in ready() })
                }
                let prerequisite = action < actions.count ? actions[action] : rows.count
                let ready = streams.keys.compactMap { id -> Int? in
                    guard let index = position(id), index < prerequisite, rows[index].kind.hasPrefix("in."), listeners[id] != nil,
                          id == 0 ? index == frontier : index < barrier else { return nil }
                    return index
                }.min()
                guard let ready else { return nil }
                var event = try read(ready)
                let receive = listeners[event.id]!
                if event.kind == "in.end", let bytes = partial.removeValue(forKey: event.id), !bytes.isEmpty {
                    return (.init(kind: "in.read", id: event.id, data: bytes), receive)
                }
                consume(event.id)
                complete(event)
                if event.kind == "in.read", identities[event.id] != nil, !malformed.contains(event.id) {
                    var decoder = decoders[event.id] ?? HelperWire.Decoder()
                    var pending = partial[event.id] ?? Data()
                    pending.append(event.data)
                    var bytes = Data()
                    do {
                        try decoder.feed(event.data) { message in
                            bytes.append(try HelperWire.encode(.init(kind: message.kind, id: identities[event.id]?[message.id] ?? message.id, body: message.body)))
                            pending.removeFirst(message.body.count + 13)
                        }
                    } catch {
                        // Invalid native wire is itself a recorded app input. Preserve it so
                        // HelperConnection, rather than the journal, reports its framing error.
                        malformed.insert(event.id)
                        bytes.append(pending)
                        pending.removeAll()
                    }
                    partial[event.id] = pending
                    decoders[event.id] = decoder
                    event = .init(kind: event.kind, id: event.id, data: bytes)
                }
                return (event, receive)
            }
            guard let (event, receive) = delivery else { return }
            receive(event)
        }
        }
    }
}
