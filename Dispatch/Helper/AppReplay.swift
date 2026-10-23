import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if DEBUG && canImport(CZstd)
import CZstd
#endif

/// Ordered app inputs and outputs. Native helper captures remain independent evidence.
/// A replay consumes every event; unknown work never falls back to a live process.
final class AppReplay: @unchecked Sendable {
    /// One journal row: what the app asked or sent (`open.`, `out.`) or what came back (`in.`), as a typed value
    /// (the helper's binary value grammar: bytes stay bytes, nothing is JSON).
    struct Event: Equatable, Sendable {
        let kind: String
        let id: Int
        let value: HelperBinary.Value
    }

    static func value<T: Encodable>(_ item: T) throws -> HelperBinary.Value { try HelperBinary.value(encoding: item) }
    static func decode<T: Decodable>(_ type: T.Type, _ value: HelperBinary.Value) throws -> T {
        try HelperBinary.decode(type, from: value)
    }
    /// A result as the journal stores it, what replay reads back: capture hands the app this one too (a Swift
    /// dictionary decoded from a value iterates as that value was built).
    static func stored(_ value: HelperBinary.Value) throws -> HelperBinary.Value {
        try HelperBinary.decode(HelperBinary.encode(value, schema: false), schema: false)
    }
    /// Every event of a journal file (a capture, layer app).
    static func events(_ url: URL) throws -> [Event] { try Capture.read(Capture.expand(Data(contentsOf: url))).map(\.event) }
    /// What a capture file is (the corpus keeps app journals beside helper captures): true an app journal this app
    /// replays, false one of another format or protocol version (it can never replay here), nil a helper's capture.
    static func journal(_ url: URL) throws -> Bool? {
        let bytes = try Capture.expand(Data(contentsOf: url)), header = Capture.header
        guard bytes.count >= header.count, Array(bytes[4..<12]) == Capture.magic else { throw error(url.lastPathComponent + " is not a capture") }
        guard bytes[16] == 1 else { return nil }
        return Array(bytes.prefix(header.count)) == header
    }
    /// The bytes a row carries (wire, pty output).
    static func bytes(_ value: HelperBinary.Value) -> Data {
        if case .bytes(let data) = value { return data }
        return Data()
    }
    /// A value for reading (reports, notes): keys sorted, UTF-8 bytes as text, other bytes as hex.
    static func text(_ value: HelperBinary.Value) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return "\(value)"
        case .unsigned(let value): return "\(value)"
        case .signed(let value): return "\(value)"
        case .real(let value): return "\(value)"
        case .string(let value): return String(reflecting: value)
        case .bytes(let value):
            if let text = String(data: value, encoding: .utf8) { return "b" + String(reflecting: text) }
            return "hex(" + value.map { String(format: "%02x", $0) }.joined() + ")"
        case .array(let items): return "[" + items.map(text).joined(separator: ", ") + "]"
        case .object(let fields): return "{" + fields.keys.sorted().map { $0 + ": " + text(fields[$0]!) }.joined(separator: ", ") + "}"
        }
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
        /// A cancellation is a CancellationError again (callers catch it by type; it has no NSError bridge).
        var error: any Error {
            if let helper { return helper }
            if domain == (CancellationError() as NSError).domain { return CancellationError() }
            return NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    struct Launch: Codable, Equatable {
        let executable: String?
        let arguments: [String]
        let directory: String?
        #if canImport(AppKit)
        init(_ process: Process) {
            executable = process.executableURL?.path
            arguments = process.arguments ?? []
            directory = process.currentDirectoryURL?.path
        }
        #endif
    }

    final class Ticket: @unchecked Sendable {
        let id: Int
        let journal: AppReplay
        /// One lifetime's endpoints (a pty's master and slave) share its record order; each has its
        /// own kinds (`in.<channel.>read`) and listener.
        let channel: String
        var replaying: Bool { journal.replaying }
        /// Replay: a creation the recording never saw begin; nothing arrives on it.
        var unseen: Bool { id < 0 }
        fileprivate init(_ id: Int, _ journal: AppReplay, _ channel: String = "") {
            self.id = id; self.journal = journal; self.channel = channel
        }
        func channel(_ name: String) -> Ticket { Ticket(id, journal, channel + name + ".") }
        /// A point its caller continues at (a test's step): capture records it, nothing runs; replay resumes
        /// the caller when the recording reaches it.
        /// Replay: its recorded result or error. A cancelled caller stops waiting at once when the recorded one ended by
        /// its cancellation (a sleep); one the recording saw finish (a process run ignores cancellation) still gets its
        /// result. The recorded end, still reached in order, finds a stopped wait gone.
        /// `caller`: only its caller can have cancelled it (a sleep ends by elapsing or by its caller): a recorded
        /// cancellation then never ends the wait by itself, only the caller's does; it holds nothing either (identical
        /// concurrent sleeps, two timeouts' timers, may pair with each other's records).
        /// `woken`: something besides its caller may cut it short (a nap a window notification ends). Replay cannot count
        /// on that cut coming at the recorded point (the notification follows wall time and window state), so a live
        /// cancellation ends the wait only when the recording never saw it end; one the recording ended (cut or elapsed)
        /// ends where the recording did, never earlier (a poll run early would read what capture's had not seen yet).
        nonisolated(nonsending) func outcome(caller: Bool = false, woken: Bool = false) async throws -> HelperBinary.Value {
            final class Reply: @unchecked Sendable {
                let lock = NSLock(); var sent = false, continuation: CheckedContinuation<HelperBinary.Value, any Error>?
                func complete(_ result: Result<HelperBinary.Value, any Error>) {
                    let continuation = lock.withLock { () -> CheckedContinuation<HelperBinary.Value, any Error>? in
                        if sent { return nil }
                        sent = true
                        return self.continuation
                    }
                    continuation?.resume(with: result)
                }
            }
            let reply = Reply(), cancellable = journal.cancelled(id) && !(woken && journal.ended(id))
            if caller && cancellable { journal.release(id) }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Cancelled before it waited: only the cancellation can have ended it. Its recorded end is still
                    // received (and dropped), so replay goes past it.
                    let done = reply.lock.withLock { () -> Bool in reply.continuation = continuation; return reply.sent }
                    do {
                        try listen({ event in
                            do {
                                guard event.kind == "in.result" else { throw try AppReplay.decode(Failure.self, event.value).error }
                                reply.complete(.success(event.value))
                            } catch { reply.complete(.failure(error)) }
                        }, failed: { reply.complete(.failure($0)) })
                    } catch { reply.complete(.failure(error)) }
                    if done { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: { if cancellable { reply.complete(.failure(CancellationError())) } }
        }
        /// `wake`: what capture records with it (a test's step: where its condition was checked, `mark`).
        nonisolated(nonsending) func reach(_ wake: HelperBinary.Value = .null) async throws {
            if replaying { try await journal.hold(id) } else { try emit(kind: "result", value: wake) }
        }
        func action(kind: String, value: HelperBinary.Value = .null) throws {
            try journal.action(.init(kind: "out." + channel + kind, id: id, value: value))
        }
        func emit(kind: String, value: HelperBinary.Value = .null) throws {
            try journal.emit(.init(kind: "in." + channel + kind, id: id, value: value))
        }
        /// Replay: an input recorded after the app changed its own state (a pty's new size: a redraw after it is drawn
        /// for it) waits, with its lifetime's later records (the others go on), while `waits` names what it waits for
        /// (given the lifetime's later records; the stall report prints it); `recheck` once that state changed.
        func gate(_ waits: @escaping (Event, AnySequence<Event>) -> String?) { journal.lock.withLock { journal.gates[id] = waits } }
        func recheck() { try? journal.pump() }
        /// Replay: the app is closing what this lifetime shows (it asked its helper to close that terminal): its gate
        /// holds nothing more (a closing view gets no more layout; its state can no longer matter). Hanging up or
        /// closing one of its endpoints does the same.
        func closing() {
            journal.lock.withLock { journal.gates[id] = nil }
            recheck()
        }
        /// Replay: whether the app's view of this lifetime is off screen (in no window): it gets no layout, so nothing its
        /// gate waits for is reachable meanwhile. Its held records wait without holding the other lifetimes' (they go on
        /// past them); shown again, they wait for its layout as before (drawn at a stale size, a redraw would be lost).
        func offscreen(_ hidden: Bool) {
            journal.lock.withLock { if hidden { journal.hidden.insert(id) } else { journal.hidden.remove(id) } }
            recheck()
        }
        /// The queue its consumer handles what arrives on (read in capture, delivered in replay): a test's step comes
        /// after it drained.
        func through(_ queue: DispatchQueue) {
            journal.lock.withLock { journal.consumers[id, default: [:]][channel] = queue }
        }
        func listen(_ receive: @escaping (Event) -> Void, failed: @escaping (any Error) -> Void) throws {
            let failure = journal.lock.withLock { () -> (any Error)? in
                if let failure = journal.failure { return failure }
                if let kind = journal.refused[id] { return HelperFailure(code: "unrecorded", message: "Not in the recording: " + kind) }
                journal.listeners[id, default: [:]][channel] = receive
                journal.failures[id, default: [:]][channel] = failed
                return nil as (any Error)?
            }
            if let failure { failed(failure); return }
            try journal.pump()
        }
    }

    private static let guardLock = NSLock()
    @TaskLocal private static var suppressed = false
    /// Inside a waiting test's check: what it asks (requests through the app's connections, lifetimes it opens) is its
    /// own; HelperConnection carries this to the request's record. Only for waits whose recording has the check's end.
    @TaskLocal static var asking = false
    nonisolated(unsafe) private static var current: AppReplay?
    nonisolated(unsafe) private static var required = false
    private let lock = NSRecursiveLock()
    private let source: URL
    private(set) var diagnostic: URL?
    /// Capture: the journal file being written (nil in replay).
    private let writer: Writer?
    private let started = DispatchTime.now().uptimeNanoseconds
    let replaying: Bool
    /// Replay: the recording, read once.
    private var rows: [Event] = []
    private var streams: [Int: [Int]] = [:]
    private var cursors: [Int: Int] = [:]
    private var consumed: Set<Int> = []
    /// Replay: app outputs issued before their stream reached them; any one may match the stream head.
    private var pending: [Int: [Event]] = [:]
    private var line = 0
    /// Replay: acknowledgments answered here (`answers`), the recorded requests they replace (`skipped`)
    /// and typed bytes per terminal not yet matched to recorded input (`typed`: a helper's requests, a renderer's hand-back).
    private var answers: [Int: [Data]] = [:]
    private var skipped: [Int: Set<UInt64>] = [:]
    private var typed: [Int: [String: Data]] = [:]
    /// Replay, helper connections: recorded request ids and the recorded byte-stream requests by stream.
    /// Replay: a stall fails the journal with every stream's state: a recorded event the app never reaches, or an app
    /// wait the recording never answers. Stalled = idle for 4x what capture took to reach the frontier from the record
    /// before it (at least a second): a slow screen took long in capture too, an answer replay holds took moments.
    private var watchdog: DispatchSourceTimer?
    private var clocks: [UInt64] = []
    /// The least stall bound: the app's own wall-time waits (Task.sleep timers) overlap recorded activity in capture, so a
    /// short recorded gap can precede a longer wait (mix27: up to 1.4 s).
    private static let least: UInt64 = 3_000_000_000
    /// The line the watchdog last saw, the idle time since it moved, when the watchdog last looked and what capture took
    /// to reach the frontier then.
    private var watched = (line: -1, idle: UInt64(0), at: DispatchTime.now().uptimeNanoseconds, gap: UInt64(0))
    private var requested: [Int: Set<UInt64>] = [:]
    /// Replay: the helper's recorded answers by question (method and params) and by method.
    private var answered: [String: [HelperBinary.Value]] = [:]
    /// Replay: requests that changed nothing on the helper, with their cancels: cancelled before anything came back for
    /// them, or refused (their first answer an error). UI timing: a run sends them or not. They match when sent; unsent,
    /// they hold nothing. An answer replay delivers before the app sent its request (a refusal reached first, an answer
    /// read together with one to a sent request) waits for it (`held`, by recorded id; `asks`: each recorded request id's
    /// record). One the app went past, sending an equal later one as it, is never sent later (`passed`).
    private var inert: Set<Int> = []
    private var passed: Set<Int> = []
    private var asks: [Int: [UInt64: Int]] = [:]
    private var held: [Int: [UInt64: Data]] = [:]
    /// Replay: creations the recording never saw that fail to their caller, by kind.
    private var refused: [Int: String] = [:]
    /// Replay: recorded creations by kind; observations by kind and input; every other record in order (`owed`):
    /// the first one not reached yet is the frontier.
    private var opens: [String: [Int]] = [:]
    /// Recorded creations by kind and input, the next one first (identical ones are taken in recorded order).
    private struct Key: Hashable { let kind: String; let input: HelperBinary.Value }
    private var creations: [Key: ArraySlice<Int>] = [:]
    private var observations: [Key: [Int]] = [:]
    /// Replay: what a test's condition asked capture as it polled (System.polling), by kind and input: read, not owed.
    private var polls: [Key: [Int]] = [:]
    private var owed: [Int] = []
    private var reached = 0
    private var synced = 0
    /// Replay: where each app task can have been in capture at the least (`query`). Holding a task keeps its identity
    /// from passing to a new one (a finished task's memory is reused at once).
    private var floors: [UnsafeCurrentTask: Int] = [:]
    /// Replay: the test's own tasks (those that wait for its steps).
    private var testers: Set<UnsafeCurrentTask> = []
    /// Replay, while tests wait for their steps (`waiting`): inputs recorded from where capture began the check that held
    /// are held, except a check's own I/O (`questions`: its requests not answered yet by connection; `opened`: lifetimes it
    /// opened) and up to what failing checks freed (`taken`); each wait's window runs to where that check returned
    /// (`advance`; `stuck`: the line where a check failed on the settled state; `own`: records the checks' own I/O
    /// reached). A recording without the check's end (`loose` waits) lets inputs come while a check runs (`checks`).
    private var limits: [Range<Int>] = []
    private var checks = 0, loose = 0, own = 0
    private var questions: [Int: Set<UInt64>] = [:]
    private var opened: Set<Int> = []
    private var taken: Int?
    private var stuck: Int?
    private var renderers: Set<Int> = []
    private var streamed: [Int: [String: ArraySlice<Int>]] = [:]
    /// Replay: helper reads `early` looked at, by record: their response ids ([] when not only whole responses).
    private var replies: [Int: [UInt64]] = [:]
    private var serial = 0
    private var active: Set<Int> = []
    /// Lifetimes that never hold settle/finish: waits (clock: System.sleep, step: System.step; an app timer may outlive
    /// the case that started it) and creations the recording never saw begin.
    private var waits: Set<Int> = []
    private var endings: [Int: Set<String>] = [:]
    private var listeners: [Int: [String: (Event) -> Void]] = [:]
    private var consumers: [Int: [String: DispatchQueue]] = [:]
    /// The ids the app makes derive from it.
    private var seed = UUID()
    private var counts: [String: UInt64] = [:]
    /// Requests replay answered or dropped because the run's UI timing differed from the recording's (the report lists them).
    private var notes: [String] = []
    /// Stall report: the last records replay consumed, the last observations answered with an older
    /// recorded value than the newest one (the frontier had not reached it).
    private var recent: [Int] = []
    /// Replay: the idle time that ended with a record reached furthest beyond what capture took for it, with that time
    /// (what the stall bound is measured against).
    private var longest = (idle: UInt64(0), gap: UInt64(0))
    private var stale: [String] = []
    var relaxed: [String] { lock.withLock { notes } }
    /// Every stream's state, as a failed replay prints it.
    var report: String { lock.withLock { state() } }
    /// Replay: sites that made another count of ids than the recording (where their later ids shifted).
    private var drifts: [String] = []
    var drift: [String] { lock.withLock { drifts } }
    private var identities: [Int: [UInt64: UInt64]] = [:]
    private var decoders: [Int: HelperWire.Decoder] = [:]
    private var partial: [Int: Data] = [:]
    private var malformed: Set<Int> = []
    private var created: [String: [UUID: UUID]] = [:]
    private var failure: (any Error)?
    private var failures: [Int: [String: (any Error) -> Void]] = [:]
    private var closed = false
    private var pumping = false
    /// Live work in flight (`live`): the app is not idle meanwhile.
    private var working = 0
    private var steps: [Int: () -> Void] = [:]
    private var gates: [Int: (Event, AnySequence<Event>) -> String?] = [:]
    /// Lifetimes whose view is off screen (Ticket.offscreen): their gates hold only their own records meanwhile.
    private var hidden: Set<Int> = []

    #if DEBUG
    static var replaying: Bool { guardLock.withLock { required } || ProcessInfo.processInfo.environment["DISPATCH_APP_REPLAY"] != nil }
    #else
    /// Release: the app never replays, and no journal can begin (`begin`): its I/O is never recorded.
    static var replaying: Bool { false }
    #endif
    static var enabled: Bool { !suppressed && guardLock.withLock { current != nil } }
    /// The active journal's failure: a replay that diverged cannot be waited out.
    static var failed: (any Error)? { guardLock.withLock { current }.flatMap { journal in journal.lock.withLock { journal.failure } } }
    static var settled: Bool { guardLock.withLock { current }?.settled ?? true }
    static var longest: (idle: Duration, gap: Duration) {
        let longest = guardLock.withLock { current }.map { journal in journal.lock.withLock { journal.longest } } ?? (idle: 0, gap: 0)
        return (.nanoseconds(longest.idle), .nanoseconds(longest.gap))
    }
    var settled: Bool {
        lock.withLock { active.isSubset(of: waits) && (pending.values.allSatisfy(\.isEmpty) && answers.values.allSatisfy(\.isEmpty)) }
    }

    static func begin(url: URL, replaying: Bool) throws {
        #if !DEBUG
        throw error("app capture and replay exist only in Debug builds")
        #endif
        try guardLock.withLock {
            guard current == nil else { throw error("another app journal is still active") }
            required = replaying
            current = try AppReplay(url: url, replaying: replaying)
        }
    }

    static func open(kind: String, input: HelperBinary.Value) throws -> Ticket? {
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

    func open(kind: String, input: HelperBinary.Value) throws -> Ticket {
        try checked {
        try pump()
        let ticket = try lock.withLock {
            // Work the recording never saw begin (a timer loop went on, a view mounted after the recording's teardown
            // cut the app): a wait never wakes, a terminal process never starts (what the app sends it goes nowhere).
            // Anything else past every recorded one of its kind fails to its caller (it would wait forever); one that
            // differs from a remaining recorded one is a divergence. Test steps stay exact.
            let kinds = "open." + kind
            if replaying, kind != "step", recorded(kinds, input) == nil,
               ["clock", "pty"].contains(kind) || opens[kinds, default: []].allSatisfy(consumed.contains) {
                // Listed (a launch may only differ from the recorded one); timer loops are not.
                if kind != "clock" { notes.append("unseen " + kind + " " + String(Self.text(input).suffix(160))) }
                serial += 1
                active.insert(-serial); waits.insert(-serial)
                if !["clock", "pty"].contains(kind) { refused[-serial] = kind }
                return Ticket(-serial, self)
            }
            let id = try creation(kind: kind, input: input)
            active.insert(id)
            if ["clock", "step"].contains(kind) { waits.insert(id) }
            if kind == "helper" { endings[id] = ["in.end", "in.exit"] }
            try accept(.init(kind: "open." + kind, id: id, value: input))
            if replaying, Self.asking, limits.count > loose { opened.insert(id); own += 1 }
            return Ticket(id, self)
        }
        try pump()
        return ticket
        }
    }

    static func query(kind: String, input: HelperBinary.Value, read: () throws -> HelperBinary.Value) throws -> HelperBinary.Value {
        if suppressed {
            guard !replaying else { throw error("live nested query attempted during app replay") }
            return try read()
        }
        guard let journal = guardLock.withLock({ current }) else {
            guard !replaying else { throw error("app replay has no active query journal") }
            return try read()
        }
        return try journal.query(kind: kind, input: input, read: read)
    }

    func query(kind: String, input: HelperBinary.Value, read: () throws -> HelperBinary.Value) throws -> HelperBinary.Value {
        try pump()
        let result: Result<HelperBinary.Value, any Error> = try checked { try lock.withLock {
            // An observation (what the OS reports about state other processes change) is asked as often as
            // the scheduler polls: it answers what capture saw last before the first record the app has not
            // made yet past the last synchronous answer (taken at once: its asker already saw that much);
            // before its first capture there, its first (asked ahead with its stream). Inputs the app has not
            // received yet do not hold it back: the world went on without it (capture read them whenever they
            // came; a step holds them until its caller ran). Nor do the test's steps, when anyone but the test asks (the
            // app polling on its own, while the test waits or runs on to its next wait): a step is the test's progress, not
            // the app's. The test's own reads and checks see the state as of its next step.
            // Nor what another party has not made yet, for a task that saw past it: a task asks in order and capture
            // recorded its asks in that order, so it was past the first record of each thing it asked from where it was
            // before (its floor, kept within the frontier: an answer past it is a guess). Nothing recorded between its
            // floor and the frontier: answered from its floor on (the test's next view mounting held the frontier before
            // what the task saw; capture ran the task after it). The test's checks keep their step's state.
            // A test's condition asks the world as often as it checks (System.polling), and how often it checks is wall time
            // (a check refuses while a sidebar slides): its other questions (a fixture's command) are read like observations.
            let polled = replaying && System.polling && !kind.hasPrefix("observe.") && !kind.hasPrefix("identity.")
            if replaying, kind.hasPrefix("observe.") || polled {
                // Polled hot (a view reading the time every frame, 500 tabs' processes): both lookups are binary searches.
                let key = Key(kind: "open." + kind, input: input)
                if polled, polls[key] == nil { polls[key] = opens[key.kind, default: []].filter { rows[$0].value == input } }
                let recorded = (polled ? polls[key] : observations[key]) ?? []
                let task = Self.asking ? nil : withUnsafeCurrentTask { $0 }
                let app = !Self.asking && !testers.isEmpty && task.map { !testers.contains($0) } ?? true
                _ = first(owed, &reached)
                var at = max(reached, Self.split(owed, synced + 1))
                for _ in sequence(first: 0, next: { $0 + 1 }) {
                    guard at < owed.count, consumed.contains(owed[at]) || rows[owed[at]].kind.hasPrefix("in.")
                            || app && rows[owed[at]].kind == "open.step" else { break }
                    at += 1
                }
                let frontier = at < owed.count ? owed[at] : rows.count, before = Self.split(recorded, frontier)
                let floor = task.flatMap { floors[$0] } ?? 0, next = Self.split(recorded, floor)
                if let task, next < recorded.count { floors[task] = max(floor, min(recorded[next], frontier)) }
                // Never asked in capture (a poll reached a process its polls never did): the asker gets no answer.
                guard let index = (before > 0 ? recorded[before - 1] : recorded.first).map({ $0 < floor && next < recorded.count ? recorded[next] : $0 }),
                      let event = streams[rows[index].id].flatMap({ $0.count > 1 ? self.rows[$0[1]] : nil }) else {
                    notes.append("unrecorded " + kind + " " + String(Self.text(input).prefix(160)))
                    return .failure(HelperFailure(code: "unrecorded", message: "Not in the recording: " + kind))
                }
                if index < recorded[recorded.count - 1] {
                    stale = Array((stale + ["\(kind) \(String(Self.text(input).prefix(80))): record \(index), newest \(recorded[recorded.count - 1]), frontier \(frontier)"]).suffix(8))
                }
                // The wait's recorded asks (before the test's next step) were reads: none is owed.
                if polled {
                    let step = self.recorded("open.step", .null) ?? rows.count
                    for ask in recorded where ask < step && !consumed.contains(ask) {
                        for row in streams[rows[ask].id] ?? [] where !consumed.contains(row) {
                            consume(row)
                            if Self.asking, limits.count > loose { own += 1 }
                        }
                    }
                }
                return event.kind == "in.error" ? .failure(try Self.decode(Failure.self, event.value).error) : .success(event.value)
            }
            // A value the app made more often than the recording saw: made now. Making one tells the app nothing
            // about other processes, so what it observes stays where replay is. Any other query the recording never
            // saw (the app got further before the recording's teardown cut it) fails to its caller.
            let made = kind.hasPrefix("identity.")
            if replaying, recorded("open." + kind, input) == nil {
                if made { return .success(try read()) }
                notes.append("unrecorded " + kind + " " + String(Self.text(input).prefix(160)))
                return .failure(HelperFailure(code: "unrecorded", message: "Not in the recording: " + kind))
            }
            let id = try creation(kind: kind, input: input)
            try accept(.init(kind: "open." + kind, id: id, value: input))
            if replaying {
                guard let position = position(id), let event = peek(id),
                      ["in.result", "in.error"].contains(event.kind) else {
                    throw Self.error("app record \(line): synchronous query result is missing")
                }
                consume(position)
                if !made { synced = max(synced, position) }
                if event.kind == "in.error" { return .failure(try Self.decode(Failure.self, event.value).error) }
                return .success(event.value)
            }
            do {
                let result = try Self.$suppressed.withValue(true) { try read() }
                try append(.init(kind: "in.result", id: id, value: result))
                return .success(try Self.stored(result))
            } catch {
                try append(.init(kind: "in.error", id: id, value: Self.value(Failure(error))))
                return .failure(error)
            }
        } }
        try pump()
        return try result.get()
    }

    static func fail(_ error: any Error) {
        guard let journal = guardLock.withLock({ current }) else { return }
        journal.reject(error)
    }

    /// An id the app makes at `site` (its file, function and what it is for); nil outside a journal or inside recorded
    /// live work (its ids are part of that work's recorded result).
    static func made(_ site: String) -> UUID? {
        if suppressed { return nil }
        guard let journal = guardLock.withLock({ current }) else { return nil }
        do { return try journal.made(site) } catch { fail(error); return nil }
    }

    /// The journal's recorded seed, the site and how many ids the site made before: replay makes the same ones without
    /// recording each (a site making more or fewer shifts only its own later ids).
    func made(_ site: String) throws -> UUID {
        let (seed, count) = lock.withLock { () -> (UUID, UInt64) in counts[site, default: 0] += 1; return (self.seed, counts[site]!) }
        let bytes = withUnsafeBytes(of: seed.uuid) { Array($0) } + Array(site.utf8) + withUnsafeBytes(of: count.littleEndian) { Array($0) }
        // FNV-1a from two bases, each mixed (SplitMix64's finalizer): 128 stable bits.
        func half(_ basis: UInt64) -> UInt64 {
            var z = bytes.reduce(basis) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9; z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        var value = (half(0xcbf29ce484222325).bigEndian, half(0x6c62272e07bb0142).bigEndian)
        return withUnsafeMutableBytes(of: &value) { raw in
            raw[6] = raw[6] & 0x0f | 0x40; raw[8] = raw[8] & 0x3f | 0x80
            return UUID(uuid: raw.load(as: uuid_t.self))
        }
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
        let recorded = try decode(UUID.self, query(kind: "identity." + kind, input: .null) { .string(value.uuidString) })
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

    /// `caller`, `woken`: see Ticket.outcome.
    nonisolated(nonsending) static func run(kind: String, input: HelperBinary.Value, caller: Bool = false, woken: Bool = false,
                                            read: () async throws -> HelperBinary.Value) async throws -> HelperBinary.Value {
        guard let ticket = try open(kind: kind, input: input) else { return try await read() }
        if ticket.replaying { return try await ticket.outcome(caller: caller, woken: woken) }
        do {
            let result = try await unrecorded { try await read() }
            try ticket.emit(kind: "result", value: result)
            return try stored(result)
        } catch {
            try ticket.emit(kind: "error", value: value(Failure(error)))
            throw error
        }
    }

    nonisolated(nonsending) static func reach(kind: String, input: HelperBinary.Value, wake: HelperBinary.Value = .null) async throws {
        try await open(kind: kind, input: input)?.reach(wake)
    }

    /// Replay: the operation's recorded outcome, when the recording reaches it.
    /// Replay: a step's caller resumes once replay reaches its recorded wake, and nothing recorded after the
    /// wake is delivered before the caller's synchronous part ran (capture went on from there at once): the wake
    /// is reached on the main queue's next turn.
    @MainActor fileprivate func hold(_ id: Int) async throws {
        final class Reply: @unchecked Sendable { let lock = NSLock(); var sent = false }
        let reply = Reply()
        let index: Int = try await withCheckedThrowingContinuation { continuation in
            // Called from whichever thread reaches the wake or fails the journal: not the caller's actor.
            @Sendable func complete(_ result: Result<Int, any Error>) {
                if reply.lock.withLock({ if reply.sent { return false }; reply.sent = true; return true }) {
                    continuation.resume(with: result)
                }
            }
            do {
                try checked { try lock.withLock {
                    if let failure { throw failure }
                    guard let index = position(id) else { throw Self.error("a recorded step has no wake") }
                    steps[index] = drained { complete(.success(index)) }
                    failures[id, default: [:]][""] = { @Sendable in complete(.failure($0)) }
                } }
                try pump()
            } catch { complete(.failure(error)) }
        }
        DispatchQueue.main.async { [self] in
            do {
                try checked { try lock.withLock {
                    if let failure { throw failure }
                    consume(index)
                    complete(rows[index])
                } }
                try pump()
            } catch {}  // checked: the failure is already the journal's
        }
    }

    /// Every consumer handles what reached it, then one main turn: a test's condition holds on that (TestSupport).
    func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in drained { continuation.resume() }() }
    }

    /// Replay: the recording ended this lifetime with its caller's cancellation, or never saw it end (it still waited
    /// when the recording ended, or never began there): nothing but a cancellation will end it.
    /// A lifetime's recorded end (its caller's cancellation) holds nothing and reaches no one: the caller ends it.
    fileprivate func release(_ id: Int) {
        lock.withLock {
            guard let end = streams[id]?.last(where: { ["in.result", "in.error"].contains(rows[$0].kind) }) else { return }
            inert.insert(end)
        }
        try? pump()
    }

    /// Replay: the recording saw this lifetime end (a result or an error).
    fileprivate func ended(_ id: Int) -> Bool {
        lock.withLock { streams[id]?.contains { ["in.result", "in.error"].contains(rows[$0].kind) } ?? false }
    }

    fileprivate func cancelled(_ id: Int) -> Bool {
        lock.withLock {
            let end = streams[id]?.last { ["in.result", "in.error"].contains(rows[$0].kind) }
            return end.map { rows[$0].kind == "in.error" && (try? Self.decode(Failure.self, rows[$0].value))?.error is CancellationError } ?? true
        }
    }

    static func settle() async {
        guard let journal = guardLock.withLock({ current }) else { return }
        await journal.settle()
    }

    /// Work a test does live on purpose, in replay too (real shells running the app's wrappers): the journal does not
    /// see it, so while it runs the app is not idle (the watchdog waits for it).
    static func live<Value>(_ body: () throws -> Value) rethrows -> Value {
        guard let journal = guardLock.withLock({ current }) else { return try body() }
        return try journal.live(body)
    }

    func live<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.withLock { working += 1 }
        defer { lock.withLock { working -= 1 } }
        return try body()
    }

    /// Capture: how many records the journal has (a test's step records where its condition was checked).
    static var mark: Int { guardLock.withLock({ current })?.mark ?? 0 }
    /// Replay: how far the app got, not counting the checks' own I/O (advance compares it).
    var mark: Int { lock.withLock { line - own } }

    /// Replay, while a test waits for its next step: what capture read after it began the check that held (recorded
    /// before the step all the same) waits, so the test checks the state capture's check saw, never a later one
    /// (`advance`: what was read while that check ran comes, first one input at a time, while the condition fails).
    nonisolated(nonsending) static func waiting<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        guard let journal = guardLock.withLock({ current }) else { return try await body() }
        return try await journal.waiting(body)
    }

    nonisolated(nonsending) func waiting<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        let hold = lock.withLock { () -> (window: Range<Int>, loose: Bool)? in
            if replaying, let task = withUnsafeCurrentTask(body: { $0 }) { testers.insert(task) }
            guard replaying, let open = recorded("open.step", .null), let wake = streams[rows[open].id]?.dropFirst().first,
                  case .object(let fields) = rows[wake].value else { return nil }
            func number(_ key: String) -> Int? { if case .unsigned(let value)? = fields[key] { return Int(value) }; return nil }
            // A recording without the check's end frees nothing; inputs come while its checks run (as when it was made).
            guard let mark = number("mark") else { return nil }
            let end = number("end")
            limits.append(mark..<(end ?? mark))
            if end == nil { loose += 1 }
            return (mark..<(end ?? mark), end == nil)
        }
        guard let hold else { return try await body() }
        defer {
            lock.withLock { limits.remove(at: limits.firstIndex(of: hold.window)!); if hold.loose { loose -= 1 } }
            try? pump()
        }
        return try await body()
    }

    /// A check of a waiting test's condition: what it asks itself (`asking`) is answered past the hold (it waits for that);
    /// nothing else recorded after the mark comes meanwhile.
    nonisolated(nonsending) static func checking<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        guard let journal = guardLock.withLock({ current }) else { return try await body() }
        return try await journal.checking(body)
    }

    nonisolated(nonsending) func checking<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        lock.withLock { checks += 1 }
        defer { lock.withLock { checks -= 1 } }
        return try await Self.$asking.withValue(true) { try await body() }
    }

    /// A waiting test's check failed (`mark`: the line when it began). Capture read on while its check ran: that check
    /// may have seen input recorded between its mark and its end (pty output parsed before the screen was read). Replay
    /// first holds all of it (a later redraw may clear what the test waits for). A check that fails again on the settled
    /// state with nothing reached since (the app may need a turn to react) frees the held inputs at the frontier: one,
    /// then as many as the window passed so far (a flood read during a slow check comes in a few rounds), until the
    /// condition holds. Nothing read after that check returned comes before the step.
    nonisolated(nonsending) static func advance(_ mark: Int) async {
        guard let journal = guardLock.withLock({ current }) else { return }
        await journal.advance(mark)
    }

    nonisolated(nonsending) func advance(_ mark: Int) async {
        // The input at the frontier, held in a window and not freed yet, with nothing reached since the check began.
        func frontier() -> (next: Int, window: Range<Int>)? {
            guard line - own == mark, let next = due(), rows[next].kind.hasPrefix("in."), taken.map({ next > $0 }) != false,
                  let window = limits.first(where: { $0.contains(next) }) else { return nil }
            return (next, window)
        }
        guard replaying, lock.withLock(frontier) != nil else { return }
        await settle()
        let freed = lock.withLock { () -> Bool in
            guard let (next, window) = frontier() else { return false }
            guard stuck == mark else { stuck = mark; return false }
            let at = Self.split(owed, next), passed = at - Self.split(owed, window.lowerBound)
            taken = owed[min(at + max(1, passed), Self.split(owed, window.upperBound)) - 1]
            return true
        }
        if freed { try? pump() }
    }


    /// A step's resume: what arrived before its wake is handled first (its consumers' queues drain, then a main turn).
    private func drained(_ resume: @escaping @Sendable () -> Void) -> () -> Void {
        { [self] in Self.drain(lock.withLock { consumers.values.flatMap(\.values) }, then: resume) }
    }

    private static func drain(_ queues: [DispatchQueue], then: @escaping @Sendable () -> Void) {
        guard let queue = queues.first else { return DispatchQueue.main.async(execute: then) }
        queue.async { drain(Array(queues.dropFirst()), then: then) }
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
            // A capture that cannot finish keeps what it recorded, without the footer that would certify it.
            defer { closed = true; watchdog?.cancel(); try? writer?.finish(certified: false) }
            // How many ids each site made without a key (capture records it): a site that made another count in replay
            // is where its later ids shifted.
            let made = counts.filter { !$0.key.contains("\u{0}") || $0.key.hasSuffix("\u{0}") }
            if !replaying { try append(.init(kind: "made", id: 0, value: Self.value(made))) }
            else if let index = streams[0]?.first(where: { rows[$0].kind == "made" && !consumed.contains($0) }) {
                let recorded = (try? Self.decode([String: UInt64].self, rows[index].value)) ?? [:]
                drifts = Set(recorded.keys).union(made.keys).sorted().compactMap { site in
                    let (was, now) = (recorded[site, default: 0], made[site, default: 0])
                    return was == now ? nil : site.replacingOccurrences(of: "\u{0}", with: "") + ": recorded \(was), made \(now)"
                }
                consume(index)
                if !drifts.isEmpty { print("App replay made ids differently (\(source.lastPathComponent)): " + drifts.joined(separator: ", ")) }
            }
            for index in inert.sorted() where !consumed.contains(index) {
                var decoder = HelperWire.Decoder()
                try? decoder.feed(Self.bytes(rows[index].value)) { if $0.kind == .request { notes.append("unsent " + Self.method($0.body).text) } }
            }
            if replaying, !notes.isEmpty { print("App replay relaxed (\(source.lastPathComponent)): " + notes.joined(separator: ", ")) }
            if let failure { throw failure }
            // Typed bytes past the whole recorded stream were still being sent when the recording's teardown cut
            // the app; bytes a remaining record still waits for were never completed.
            for (id, terminals) in typed {
                for (key, bytes) in terminals where !bytes.isEmpty && streamed[id]?[key]?.contains(where: { !consumed.contains($0) }) == true {
                    throw Self.error("streamed bytes never recorded on lifetime \(id): \(key) \(String(reflecting: String(decoding: bytes, as: UTF8.self)))")
                }
            }
            if let (id, waiting) = pending.first(where: { !$0.value.isEmpty }) {
                let index = position(id)
                throw try mismatch(index.map { rows[$0] }, waiting[0], at: index ?? rows.count,
                                   reason: "app output never reached by its recorded stream")
            }
            guard active.isSubset(of: waits) else { throw Self.error("unfinished app lifetimes: \(active.subtracting(waits).sorted())") }
            try accept(.init(kind: "finish", id: 0, value: .null))
            // Observations the app polled fewer times than recorded, values it did not make again: not owed.
            let heads = !replaying ? [] : streams.keys.sorted().compactMap { id in
                position(id).flatMap { asked(id) ? nil : "\(rows[$0].kind) lifetime \(id) at record \($0)" }
            }
            guard heads.isEmpty else { throw Self.error("recorded events never reached: " + heads.joined(separator: ", ")) }
            try writer?.finish(certified: true)
        }
        }
    }

    init(url: URL, replaying: Bool) throws {
        self.replaying = replaying
        self.source = url
        if replaying {
            writer = nil
            for (event, clock) in try Capture.read(Capture.expand(Data(contentsOf: url))) {
                clocks.append(clock)
                streams[event.id, default: []].append(rows.count)
                if event.kind.hasPrefix("open.") {
                    opens[event.kind, default: []].append(rows.count)
                    creations[Key(kind: event.kind, input: event.value), default: []].append(rows.count)
                }
                rows.append(event)
            }
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            writer = try Writer(Self.create(url))
        }
        // A helper connection's requests may be sent in any order: each matches the earliest equal recorded
        // one. Byte streams match by bytes; recorded screen publications are acknowledged here instead.
        for index in opens.filter({ $0.key.hasPrefix("open.observe.") }).values.joined() where replaying {
            observations[Key(kind: rows[index].kind, input: rows[index].value), default: []].append(index)
        }
        owed = rows.indices.filter { !asked(rows[$0].id) }
        // A terminal's renderer child (it connected back) is the app's own loop: sent the app's drawing (its slave's
        // bytes) and the app's encoding of keys, pointer and replies (its input), it hands typed bytes back on its
        // slave. Only that hand-back is replayed, once the app typed it (`handed`); what the app sends it is never compared.
        renderers = Set(rows.filter { $0.kind == "in.connect" }.map(\.id))
        for index in rows.indices where own(rows[index]) { consume(index) }
        for (id, stream) in streams where id != 0 && replaying && rows[stream[0]].kind == "open.helper" {
            var methods: [UInt64: (name: String, text: String)] = [:], replies = HelperWire.Decoder(), acknowledged: Set<UInt64> = []
            var sent: [UInt64: Int] = [:], heard: Set<UInt64> = []
            for index in stream {
                let event = rows[index]
                if event.kind == "in.read" {
                    try? replies.feed(Self.bytes(event.value)) { message in
                        // Refused at once: the helper answered its first word with an error.
                        if heard.insert(message.id).inserted, message.kind == .response, let request = sent[message.id],
                           case .object(let body)? = try? HelperBinary.decode(message.body), body["error"] != nil {
                            inert.insert(request)
                        }
                        guard message.kind == .response, let method = methods[message.id], let value = try? HelperBinary.decode(message.body) else { return }
                        for key in [method.name, method.text] { answered[key, default: []].append(value) }
                    }
                }
                guard event.kind == "out.wire" else { continue }
                if let request = Self.stream(event.value) {
                    requested[id, default: []].insert(request.id)
                    acknowledged.insert(request.id)
                    if let input = request.input { streamed[id, default: [:]][input.key, default: []].append(index) }
                    else { skipped[id, default: []].insert(request.id); consume(index) }
                } else {
                    var single = HelperWire.Decoder(), messages: [HelperWire.Message] = []
                    try? single.feed(Self.bytes(event.value)) { message in
                        messages.append(message)
                        requested[id, default: []].insert(message.id)
                        if message.kind == .request { methods[message.id] = Self.method(message.body) }
                    }
                    // Replay acknowledges those requests itself: they are never pending, so the app never cancels them.
                    if !messages.isEmpty, messages.allSatisfy({ $0.kind == .cancel && acknowledged.contains($0.id) }) { consume(index) }
                    guard messages.count == 1 else { continue }
                    if messages[0].kind == .request { sent[messages[0].id] = index; asks[id, default: [:]][messages[0].id] = index }
                    else if messages[0].kind == .cancel, !heard.contains(messages[0].id), let request = sent[messages[0].id] {
                        inert.formUnion([request, index])
                    }
                }
            }
        }
        // The ids the app makes derive from the journal's seed: recorded first, taken back in replay.
        if !replaying { try append(.init(kind: "seed", id: 0, value: .string(seed.uuidString))) }
        else if let index = streams[0]?.first(where: { rows[$0].kind == "seed" }), case .string(let text) = rows[index].value,
                let recorded = UUID(uuidString: text) {
            seed = recorded
            consume(index)
        }
        if replaying {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                // A main queue that does not answer within a second is the app working (laying out a large session
                // took 90s in capture too): that time is not idle. So is a queue the journal feeds (replay hands input
                // over at once, and a helper connection still decoding that burst holds what the app sends after it), and
                // work a test does live (`live`: real shells).
                let answered = DispatchGroup()
                for queue in [DispatchQueue.main] + self.lock.withLock({ self.consumers.values.flatMap(\.values) }) {
                    answered.enter()
                    queue.async { answered.leave() }
                }
                let busy = answered.wait(timeout: .now() + 1) == .timedOut || self.lock.withLock({ self.working > 0 }),
                    now = DispatchTime.now().uptimeNanoseconds
                let stalled = self.lock.withLock { () -> (idle: UInt64, gap: UInt64)? in
                    if self.line != self.watched.line,
                       Int64(self.watched.idle) - 4 * Int64(self.watched.gap) > Int64(self.longest.idle) - 4 * Int64(self.longest.gap) {
                        self.longest = (self.watched.idle, self.watched.gap)
                    }
                    let idle = self.line != self.watched.line ? 0 : self.watched.idle + (busy ? 0 : now - self.watched.at)
                    // Only while the recording owes something: a test may run without I/O for long. Its own records
                    // (id 0: the ids made, finish) are taken at finish, which judges what is left.
                    let frontier = self.due().flatMap { self.rows[$0].id != 0 ? $0 : nil }
                    let gap = frontier.map { self.clocks[$0] - min(self.clocks[$0], $0 > 0 ? self.clocks[$0 - 1] : 0) } ?? 0
                    self.watched = (self.line, idle, now, gap)
                    guard !self.closed, self.failure == nil, frontier != nil else { return nil }
                    return idle >= max(Self.least, 4 * gap) ? (idle, gap) : nil
                }
                if let stalled, !self.waive() {
                    self.reject(Self.error("app replay stalled: no recorded event was reached for \(Duration.nanoseconds(stalled.idle)) "
                        + "while the app was idle (capture reached it after \(Duration.nanoseconds(stalled.gap)))"))
                }
            }
            timer.resume()
            watchdog = timer
        }
    }

    /// Replay, about to stall: inputs held only for a pty size the app's layout never gave their view (it left the window
    /// before the sidebar reached it; capture's layout passed through a size replay's never makes) come at the app's
    /// size, listed as relaxed. A last resort: never while anything else can come.
    @discardableResult
    func waive() -> Bool {
        let held = lock.withLock { () -> Bool in
            let held = streams.keys.sorted().compactMap { id in self.position(id).flatMap(self.gated).map { (id, $0) } }
            for (id, reason) in held { gates[id] = nil; notes.append("size not reached on lifetime \(id): " + reason) }
            return !held.isEmpty
        }
        if held { try? pump() }
        return held
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

    /// A stream's head: its first unconsumed record (id 0 records are consumed out of order).
    private func position(_ id: Int) -> Int? {
        first(streams[id] ?? [], &cursors[id, default: 0])
    }

    /// A stream from its head on (what is before it is consumed or inert): scans never walk a long stream's past.
    private func ahead(_ id: Int) -> ArraySlice<Int> {
        _ = position(id)
        return (streams[id] ?? [])[cursors[id, default: 0]...]
    }

    /// The first unconsumed record of an ordered list (inert requests never hold it); its cursor only moves forward.
    private func first(_ list: [Int], _ cursor: inout Int) -> Int? {
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            guard cursor < list.count, consumed.contains(list[cursor]) || inert.contains(list[cursor]) else { break }
            cursor += 1
        }
        return cursor < list.count ? list[cursor] : nil
    }

    /// The owed record due next. A gated input holds everything recorded after it while its view is in a window: what
    /// follows can change that view's layout (a selection moving to another space; mix53 herdr toggle). A view in no
    /// window gets no layout, so meanwhile its gated lifetime holds only its own records: they wait, in order, until it
    /// is shown again and reached that state; the others go on past them.
    private func due() -> Int? {
        _ = first(owed, &reached)
        var parked: Set<Int> = []
        for index in owed[reached...] where !consumed.contains(index) && !inert.contains(index) && !parked.contains(rows[index].id) {
            guard gated(index) != nil, hidden.contains(rows[index].id) else { return index }
            parked.insert(rows[index].id)
        }
        return nil
    }

    private func peek(_ id: Int) -> Event? {
        position(id).map { rows[$0] }
    }

    private func consume(_ position: Int) {
        consumed.insert(position); line += 1
        recent = Array((recent + [position]).suffix(12))
    }

    /// How many of an ascending list are below `value`.
    private static func split(_ list: [Int], _ value: Int) -> Int {
        var (low, high) = (0, list.count)
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            guard low < high else { break }
            let middle = (low + high) / 2
            if list[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The next recorded creation of this kind and input not taken yet.
    private func recorded(_ kind: String, _ input: HelperBinary.Value) -> Int? {
        let key = Key(kind: kind, input: input)
        creations[key] = creations[key]?.drop { consumed.contains($0) }
        return creations[key]?.first
    }

    private func creation(kind: String, input: HelperBinary.Value) throws -> Int {
        if let failure { throw failure }
        serial += 1
        guard replaying else { return serial }
        // Creations wait on no other stream; identical recorded creations are taken in recorded order.
        if let index = recorded("open." + kind, input) { return rows[index].id }
        let candidate = opens["open." + kind]?.first { !consumed.contains($0) }
        throw try mismatch(candidate.map { rows[$0] }, .init(kind: "open." + kind, id: serial, value: input),
                           at: candidate ?? rows.count, reason: "no matching creation")
    }

    private func mismatch(_ expected: Event?, _ actual: Event, at position: Int, reason: String) throws -> HelperFailure {
        let message = "app record \(position): expected \(expected?.kind ?? "EOF") lifetime \(expected?.id ?? 0), received \(actual.kind) lifetime \(actual.id); \(reason)"
        // The two events as a journal of their own (capture inspect reads it), in the run's results: never beside a
        // stored journal (the corpus holds recordings only).
        let directory = ProcessInfo.processInfo.environment["DISPATCH_APP_DIAGNOSTICS"].map { URL(fileURLWithPath: $0) }
            ?? source.deletingLastPathComponent()
        let path = directory.appendingPathComponent(source.deletingLastPathComponent().lastPathComponent + "-"
            + source.deletingPathExtension().deletingPathExtension().lastPathComponent + ".mismatch-" + UUID().uuidString + ".rpl.zst")
        let output = try Writer(Self.create(path))
        for event in [expected, actual].compactMap({ $0 }) { try output.write(event, clock: 0) }
        try output.finish(certified: true)
        diagnostic = path
        return Self.error(message + "; private diagnostic: " + path.path)
    }

    private func append(_ event: Event) throws {
        guard !closed, let writer else { throw Self.error("app journal is closed") }
        try writer.write(event, clock: DispatchTime.now().uptimeNanoseconds - started)
        line += 1
    }

    private func checked<Value>(_ body: () throws -> Value) throws -> Value {
        do { return try body() }
        catch { reject(error); throw error }
    }

    /// Every stream's next record and the app outputs still waiting for it: a failure's context.
    private func state() -> String {
        // A test step names where in the source it was (its wake).
        func at(_ index: Int) -> String {
            guard rows[index].kind == "open.step", let wake = streams[rows[index].id]?.dropFirst().first,
                  case .object(let fields) = rows[wake].value, case .string(let at)? = fields["at"] else { return "" }
            return " (" + at + ")"
        }
        let frontier = due().map { "\(rows[$0].kind) lifetime \(rows[$0].id) at record \($0)" + at($0) }
        return (["frontier: \(frontier ?? "end")",
                 "recent: " + recent.map { "\(rows[$0].kind) lifetime \(rows[$0].id) at record \($0)" }.joined(separator: ", ")]
                + stale.map { "stale observation " + $0 }
                + streams.keys.sorted().compactMap { id -> String? in
            let head = position(id).map { "\(rows[$0].kind) at record \($0)" }, waiting = (pending[id] ?? []).map(\.kind)
            guard !asked(id), head != nil || !waiting.isEmpty else { return nil }
            return "lifetime \(id): next \(head ?? "end"); waiting \(waiting); listening \((listeners[id] ?? [:]).keys.sorted())"
                + (typed[id]?["out.input"].map { "; typed " + String(Self.text(.bytes($0)).suffix(160)) } ?? "")
                + (position(id).flatMap(gated).map { "; held: " + $0 + (hidden.contains(id) ? " (in no window: the others go on)" : "") } ?? "")
        }).joined(separator: "\n")
    }

    /// What a gated input waits for (the app's own state its recording followed); nil: it goes.
    private func gated(_ index: Int) -> String? {
        gates[rows[index].id]?(rows[index], AnySequence(ahead(rows[index].id).lazy.filter { $0 > index }.map { self.rows[$0] }))
    }

    private func own(_ event: Event) -> Bool {
        renderers.contains(event.id) && ["out.slave.wire", "out.input"].contains(event.kind)
    }

    /// A renderer's hand-back is what the app typed coming back through its pty (one not raw yet turns CR into NL): it
    /// waits until the app typed it, passing over what else the app typed (a pointer report the recording lacks). Focus
    /// reports follow window activation, which the cases run before decide (iso60): neither side waits on them, and the
    /// hand-back still comes as recorded, so the app relays what capture relayed. A test waiting for its step types
    /// nothing: then a hand-back of what this run never typed goes on.
    private func handed(_ index: Int) -> Bool {
        let id = rows[index].id
        guard rows[index].kind == "in.slave.read" else { return true }
        let line = { (bytes: Data) in bytes.map { $0 == 13 ? 10 : $0 } }, wanted = line(Self.unfocused(Self.bytes(rows[index].value)))
        guard !wanted.isEmpty else { return true }
        guard let range = line(typed[id]?["out.input"] ?? Data()).firstRange(of: wanted) else { return !steps.isEmpty || !limits.isEmpty }
        typed[id]?["out.input"]?.removeFirst(range.upperBound)
        return true
    }

    /// Bytes without focus reports (DECSET 1004: ESC [ I, ESC [ O).
    private static func unfocused(_ bytes: Data) -> Data {
        [Data("\u{1b}[I".utf8), Data("\u{1b}[O".utf8)].reduce(bytes) { $0.replacing($1, with: Data()) }
    }

    /// A lifetime the app asks for only when it needs it, never owed: an observation of state other processes change
    /// (asked any number of times) or a value the app made (kept to hand back; a cache or another path asks no more).
    private func asked(_ id: Int) -> Bool { ["open.observe.", "open.identity."].contains { rows[streams[id]![0]].kind.hasPrefix($0) } }

    private func reject(_ error: any Error) {
        let callbacks = lock.withLock { () -> [(any Error) -> Void] in
            guard failure == nil else { return [] }
            failure = error
            if replaying { print("App replay failed (\(source.lastPathComponent)): \(error)\n" + state()) }
            let callbacks = failures.values.flatMap(\.values)
            failures.removeAll(); listeners.removeAll(); consumers.removeAll(); active.removeAll(); endings.removeAll()
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
                if event.id < 0 { return }
                if event.id != 0, event.kind.hasPrefix("out.") { return try enqueue(event) }
                // Creations open their stream; id 0 records (header, finish) are taken by kind.
                let index = event.id == 0
                    ? streams[0]?.first(where: { !consumed.contains($0) && rows[$0].kind == event.kind }) : position(event.id)
                let expected = index.map { rows[$0] }
                guard let index, let expected, try equal(expected, event, bind: true) else {
                    throw try mismatch(expected, event, at: index ?? rows.count, reason: "values must match the recorded stream")
                }
                consume(index)
            } else {
                try append(event)
            }
        }
    }

    /// An app output waits until its stream reaches a matching record, in any order among the waiting
    /// outputs; it fails at once only when no remaining record of its stream could match it.
    private func enqueue(_ event: Event) throws {
        if event.kind == "out.hangup" || event.kind.hasSuffix(".close") { gates[event.id] = nil }
        // A renderer child capture saw connect before the app took its view down (the app then closed that connection with
        // the view) comes here after what took the view down: the app refused it, as live when a child connects late, and
        // opened no slave. Its pty hung up, what capture recorded on that slave never happens.
        if event.kind == "out.hangup", listeners[event.id]?["slave."] == nil {
            inert.formUnion(ahead(event.id).filter { !consumed.contains($0) && rows[$0].kind.contains(".slave.") })
        }
        if requested[event.id] != nil, event.kind == "out.wire" { return try request(event) }
        // Recorded requests the app has not sent when it closes their connection end with it (UI timing).
        if requested[event.id] != nil, event.kind == "out.close",
           let close = streams[event.id]?.first(where: { !consumed.contains($0) && rows[$0].kind == "out.close" }) {
            for index in streams[event.id]! where index < close && !consumed.contains(index) {
                var decoder = HelperWire.Decoder()
                if rows[index].kind == "out.wire", Self.stream(rows[index].value) == nil {
                    try? decoder.feed(Self.bytes(rows[index].value)) { if $0.kind == .request { notes.append("unsent " + Self.method($0.body).text) } }
                }
                consume(index)
            }
        }
        if own(event) {
            if event.kind == "out.input" { typed[event.id, default: [:]][event.kind] = Self.unfocused((typed[event.id]?[event.kind] ?? Data()) + Self.bytes(event.value)) }
            return
        }
        pending[event.id, default: []].append(event)
        try match(event.id)
        guard pending[event.id]?.contains(event) == true else { return }
        let possible = try ahead(event.id).contains { index in
            guard !consumed.contains(index), rows[index].kind == event.kind else { return false }
            return try equal(rows[index], event, bind: false)
        }
        guard !possible else { return }
        if late(event) {
            pending[event.id]?.removeLast()
            notes.append("after its end " + event.kind)
            return
        }
        let index = position(event.id)
        throw try mismatch(index.map { rows[$0] }, event, at: index ?? rows.count,
                           reason: "no remaining recorded output of this stream matches")
    }

    /// Its channel's end already delivered: the app acted before its transport's queue took that end; capture's
    /// transport had stopped first and recorded nothing.
    private func late(_ event: Event) -> Bool {
        let name = event.kind.dropFirst(4), end = "in." + name[..<(name.lastIndex(of: ".").map { name.index(after: $0) } ?? name.startIndex)] + "end"
        return streams[event.id]?.contains(where: { consumed.contains($0) && rows[$0].kind == end }) == true
    }

    /// A helper request matches the earliest equal recorded request of its connection, in any order.
    /// Byte streams (typed input, control data) match as bytes across their requests' split; those and
    /// screen publications get the helper's empty acknowledgment from here.
    private func request(_ event: Event) throws {
        // After the connection's last recorded request the recording's teardown cut the app off: what it still
        // sends (a refresh, a focus report) met the recorded close there.
        let ended = !ahead(event.id).contains { !consumed.contains($0) && !inert.contains($0) && rows[$0].kind == "out.wire" }
        // Past the connection's end (late): nothing answers it, nothing waits for it (an answer would never be taken).
        if ended, late(event) {
            var decoder = HelperWire.Decoder()
            try? decoder.feed(Self.bytes(event.value)) { if $0.kind == .request { notes.append("after its end " + Self.method($0.body).name) } }
            return
        }
        if let request = Self.stream(event.value) {
            let result = try HelperBinary.encode(.object(["result": .null]))
            answers[event.id, default: []].append(try HelperWire.encode(.init(kind: .response, id: request.id, body: result)))
            guard let input = request.input, !ended else { return }
            typed[event.id, default: [:]][input.key, default: Data()].append(input.bytes)
            // Matched in order: the consumed ones are a prefix.
            let rest = streamed[event.id]?[input.key]?.drop { consumed.contains($0) }
            streamed[event.id]?[input.key] = rest
            for index in rest ?? [] where !consumed.contains(index) {
                guard let recorded = Self.stream(rows[index].value), let bytes = recorded.input?.bytes else { continue }
                let live = typed[event.id]?[input.key] ?? Data()
                guard live.prefix(bytes.count) == bytes else {
                    guard bytes.prefix(live.count) == live else {
                        throw Self.error("app record \(index): \(input.key) bytes differ from the recording: \(String(reflecting: String(decoding: live, as: UTF8.self)))")
                    }
                    return
                }
                typed[event.id]?[input.key] = Data(live.dropFirst(bytes.count))
                skipped[event.id, default: []].insert(recorded.id)
                consume(index)
            }
            return
        }
        // Every input recorded before `later` came (the app sent what it sends now after all of it), or waits only behind a
        // request of this connection the app has not sent yet (its requests go out in any order: it may send this first).
        _ = first(owed, &reached)
        let unsent = ahead(event.id).first { !consumed.contains($0) && !inert.contains($0) && rows[$0].kind == "out.wire" } ?? rows.count
        let seen = { (later: Int) in self.owed[min(self.reached, Self.split(self.owed, later))..<Self.split(self.owed, later)].allSatisfy {
            self.consumed.contains($0) || self.inert.contains($0) || !self.rows[$0].kind.hasPrefix("in.") || self.rows[$0].id == event.id && $0 > unsent
        } }
        for index in streams[event.id] ?? [] where !consumed.contains(index) && rows[index].kind == "out.wire" {
            guard try equal(rows[index], event, bind: false) else { continue }
            // Refused at once and its refusal already reached, while the app got every input recorded before an equal later
            // request (the change that let that one through): it sent this one past the refusal, as that later one. Equal
            // requests go out in order: the app went past the refused one for good (an open much later is a later one).
            if inert.contains(index), try passed.contains(index) || held[event.id]?.keys.contains(where: { asks[event.id]?[$0] == index }) == true
                && streams[event.id]!.contains(where: {
                    try $0 > index && !consumed.contains($0) && rows[$0].kind == "out.wire" && seen($0) && equal(rows[$0], event, bind: false)
                }) {
                passed.insert(index)
                continue
            }
            _ = try equal(rows[index], event, bind: true)
            consume(index)
            // A waiting test's check asked this: its answer comes past the step's hold (a loose wait's checks get all anyway).
            if Self.asking, limits.count > loose {
                own += 1
                var decoder = HelperWire.Decoder()
                try? decoder.feed(Self.bytes(rows[index].value)) { if $0.kind == .request { questions[event.id, default: []].insert($0.id) } }
            }
            if let (recorded, body) = held[event.id]?.first(where: { asks[event.id]?[$0.key] == index }) {
                held[event.id]?[recorded] = nil
                answers[event.id, default: []].append(try HelperWire.encode(.init(kind: .response, id: identities[event.id]?[recorded] ?? recorded, body: body)))
            }
            return
        }
        // A cancel the recording lacks raced its request's recorded response: the response still comes (the app
        // drops it, as when a real cancel arrives too late).
        var messages: [HelperWire.Message] = [], decoder = HelperWire.Decoder()
        try? decoder.feed(Self.bytes(event.value)) { messages.append($0) }
        if !messages.isEmpty && messages.allSatisfy({ $0.kind == .cancel && identities[event.id]?.values.contains($0.id) == true }) { return }
        // A request the recording lacks (UI timing: a run sends it or not) gets the recording's answer when that is
        // unambiguous: the same question always answered alike, or a method only ever acknowledged (an answer without
        // data). Else the helper's answer for what it cannot serve now (an error the app may show). The test's own
        // checks judge whether that changed anything.
        let empty = HelperBinary.Value.object(["result": .null])
        let unavailable = HelperBinary.Value.object(["error": .object([
            "code": .string("unavailable"), "message": .string("Not in the recording: the helper did not answer this request.")])])
        for message in messages where message.kind == .request {
            let method = Self.method(message.body), same = answered[method.text] ?? [], any = answered[method.name] ?? []
            // The helper is still answering an equal request the app sent before (a refreshed chat.open): no answer.
            if outstanding(event.id, method.text) { notes.append("unanswered " + method.text); continue }
            let known = same.first.flatMap { first in same.allSatisfy { $0 == first } ? first : nil }
                ?? (!any.isEmpty && any.allSatisfy { $0 == empty } ? empty : nil)
            answers[event.id, default: []].append(try HelperWire.encode(.init(kind: .response, id: message.id, body: HelperBinary.encode(known ?? unavailable))))
            notes.append((known == nil ? "unrecorded " : "answered ") + method.text)
        }
    }

    /// Whether a request this connection sent with these method and params is open in the recording so far: neither
    /// answered nor cancelled.
    private func outstanding(_ id: Int, _ text: String) -> Bool {
        var asked: Set<UInt64> = [], reads = HelperWire.Decoder()
        for index in streams[id] ?? [] where consumed.contains(index) {
            if rows[index].kind == "out.wire" {
                var decoder = HelperWire.Decoder()
                try? decoder.feed(Self.bytes(rows[index].value)) { message in
                    if message.kind == .request, Self.method(message.body).text == text { asked.insert(message.id) }
                    if message.kind == .cancel { asked.remove(message.id) }
                }
            } else if rows[index].kind == "in.read" {
                try? reads.feed(Self.bytes(rows[index].value)) { if $0.kind == .response { asked.remove($0.id) } }
            }
        }
        return !asked.isEmpty
    }

    /// A request's method, and as the report lists it: its method and params.
    private static func method(_ body: Data) -> (name: String, text: String) {
        guard case .object(let request)? = try? HelperBinary.decode(body), case .string(let method)? = request["method"] else { return ("?", "?") }
        return (method, method + " " + (request["params"].map(text) ?? ""))
    }

    private func match(_ id: Int) throws {
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            guard let index = position(id), rows[index].kind.hasPrefix("out.") else { return }
            let expected = rows[index]
            guard let waiting = pending[id], !waiting.isEmpty else { return }
            guard let found = try waiting.firstIndex(where: { try equal(expected, $0, bind: false) }) else { return }
            _ = try equal(expected, waiting[found], bind: true)
            pending[id]?.remove(at: found)
            consume(index)
        }
    }

    /// A helper connection's answer to a request the app has sent does not wait behind requests recorded earlier that
    /// the app has not sent yet (it sends independent requests in its own order: a slot limiter sends the next only
    /// after an answer). Passed over: those unsent requests and the answers waiting for them; only whole frames, so the
    /// connection's byte order holds. A read that also answers unsent requests comes too: those answers wait (`held`).
    private func early(_ id: Int) -> Int? {
        guard requested[id] != nil, partial[id]?.isEmpty != false else { return nil }
        // Asked at every pump while the frontier waits for the app's request: each read is decoded once.
        func responses(_ index: Int) -> [UInt64] {
            if let ids = replies[index] { return ids }
            var decoder = HelperWire.Decoder(), messages: [HelperWire.Message] = [], bytes = Self.bytes(rows[index].value)
            let whole = (try? decoder.feed(bytes) { messages.append($0); bytes.removeFirst($0.body.count + 13) }) != nil && bytes.isEmpty
                && messages.allSatisfy({ $0.kind == .response })
            replies[index] = whole ? messages.map(\.id) : []
            return replies[index]!
        }
        for index in ahead(id) where !consumed.contains(index) && !inert.contains(index) {
            if rows[index].kind == "out.wire" { continue }
            guard rows[index].kind == "in.read", case let ids = responses(index), !ids.isEmpty else { return nil }
            if ids.contains(where: { identities[id]?[$0] != nil }) { return index }
        }
        return nil
    }

    /// Where a check's answer on this connection was recorded: the read that completes a response to one of its questions.
    private func answer(_ id: Int) -> Int? {
        guard let asked = questions[id] else { return nil }
        var decoder = decoders[id] ?? HelperWire.Decoder()
        for index in ahead(id) where rows[index].kind == "in.read" && !consumed.contains(index) {
            var found = false
            guard (try? decoder.feed(Self.bytes(rows[index].value)) { found = found || $0.kind == .response && asked.contains($0.id) }) != nil
            else { return nil }
            if found { return index }
        }
        return nil
    }

    /// Requests whose split is the scheduler's: what the app draws (screen publications and grid resizes, never compared)
    /// and what is typed (one byte stream per terminal, compared across request boundaries). The helper
    /// answers both with an empty acknowledgment.
    private static func stream(_ value: HelperBinary.Value) -> (id: UInt64, input: (key: String, bytes: Data)?)? {
        var messages: [HelperWire.Message] = [], decoder = HelperWire.Decoder()
        guard (try? decoder.feed(bytes(value), emit: { messages.append($0) })) != nil, messages.count == 1, messages[0].kind == .request,
              case .object(let request)? = try? HelperBinary.decode(messages[0].body), case .string(let method)? = request["method"]
        else { return nil }
        if ["terminals.publish", "terminals.resize"].contains(method) { return (messages[0].id, nil) }
        guard case .object(let params)? = request["params"], case .bytes(let bytes)? = params["bytes"],
              [nil, .string("data")].contains(params["event"]), case .unsigned(let terminal)? = params["terminal"]
        else { return nil }
        return (messages[0].id, (method + " \(terminal)", bytes))
    }

    /// A request without the terminal grid it was sized for: geometry follows the app's layout (drawing), not I/O.
    /// A hello without its features: they only tune how the helper batches what it sends (`terminals.coalesce`), and a
    /// recording holds the helper's frames as they were, so one made before the Mac named any replays unchanged.
    private static func drawn(_ value: HelperBinary.Value) -> HelperBinary.Value {
        guard case .object(var request) = value, case .object(var params)? = request["params"] else { return value }
        params["size"] = nil
        if request["method"] == .string("hello") { params["features"] = nil }
        request["params"] = .object(params)
        return .object(request)
    }

    /// Helper wire ids are the app's own counters: a recorded id binds to the live one on first use.
    private func equal(_ expected: Event, _ event: Event, bind: Bool) throws -> Bool {
        guard expected.kind == event.kind, expected.id == event.id else { return false }
        guard event.kind == "out.wire" else { return expected.value == event.value }
        var recorded: [HelperWire.Message] = [], actual: [HelperWire.Message] = []
        var before = HelperWire.Decoder(), after = HelperWire.Decoder()
        try before.feed(Self.bytes(expected.value)) { recorded.append($0) }
        try after.feed(Self.bytes(event.value)) { actual.append($0) }
        try before.finish(); try after.finish()
        guard recorded.count == actual.count else { return false }
        var bound = identities[event.id] ?? [:]
        for (left, right) in zip(recorded, actual) {
            guard left.kind == right.kind else { return false }
            if left.kind == .cancel {
                guard bound[left.id] == right.id, left.body == right.body else { return false }
            } else {
                guard try Self.drawn(HelperBinary.decode(left.body)) == Self.drawn(HelperBinary.decode(right.body)) else { return false }
                if let mapped = bound[left.id] { guard mapped == right.id else { return false } }
                else {
                    guard !bound.values.contains(right.id) else { return false }
                    bound[left.id] = right.id
                }
            }
        }
        if bind { identities[event.id] = bound }
        return true
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
        // A replayed lifetime keeps its endpoints until its recorded stream is over (a slave may end after exit).
        if event.id != 0 && !active.contains(event.id) && (!replaying || position(event.id) == nil) {
            failures[event.id] = nil
            listeners[event.id] = nil
            consumers[event.id] = nil
            endings[event.id] = nil
            answers[event.id] = nil
        }
    }

    /// An input's endpoint: its kind's channel (`in.<channel.>name`); id 0 has one global listener.
    private func channel(_ row: Event) -> String {
        let name = row.kind.dropFirst(3)
        return row.id == 0 ? "" : String(name[..<(name.lastIndex(of: ".").map { name.index(after: $0) } ?? name.startIndex)])
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
        // The pump stops where it finds nothing, under the same lock: a step, listener or record added after that
        // finds it stopped and pumps itself (resetting it later lost such wakeups: a step never resumed).
        var stopped = false
        defer { if !stopped { lock.withLock { pumping = false } } }
        for _ in sequence(first: 0, next: { $0 + 1 }) {
            let delivery = try lock.withLock { () -> (Event, (Event) -> Void)? in
                let found = try { () -> (Event, (Event) -> Void)? in
                // A step's caller resumes at its recorded wake; the wake stays unreached until it runs (hold), but its
                // caller has seen the state there (observations answer past it).
                if let wake = due(), let resume = steps.removeValue(forKey: wake) {
                    synced = max(synced, wake)
                    return (rows[wake], { _ in resume() })
                }
                if let (id, bytes) = answers.first(where: { listeners[$0.key]?[""] != nil && !$0.value.isEmpty }) {
                    answers[id]?.removeFirst()
                    return (.init(kind: "in.read", id: id, value: .bytes(bytes[0])), listeners[id]![""]!)
                }
                // App requests go out in any order (each waits on its stream until reached); everything finishes
                // in recorded order: an input is delivered once it is the frontier.
                for (id, waiting) in pending where !waiting.isEmpty { try match(id) }
                guard let next = due() else { return nil }
                let frontier = rows[next].kind == "out.wire" ? early(rows[next].id) ?? next : next
                // An answer behind a request the app has not sent, with more than answers before it: that request may
                // wait for held input. What the recording read before the answer comes first, in recorded order.
                let behind = checks == 0 ? nil : questions.keys.filter { id in
                    self.position(id).map { self.rows[$0].kind == "out.wire" } == true && self.early(id) == nil
                }.compactMap(answer).min()
                // Past the hold: what precedes the marks or was freed (all of it while a loose wait's check runs); else what
                // a check waits for: inputs of its own lifetimes, up to its answers, ahead of the frontier (or behind it).
                let free = checks > 0 && loose > 0 || taken.map({ frontier <= $0 }) == true || limits.allSatisfy({ frontier < $0.lowerBound })
                    || behind.map({ frontier < $0 }) == true
                let mine = opened.union(questions.keys).sorted().compactMap { id in self.position(id).flatMap { self.rows[$0].kind == "out.wire" ? self.early(id) : $0 } }
                guard let ready = ((free ? [frontier] : []) + mine).first(where: { ready in
                    self.rows[ready].kind.hasPrefix("in.") && self.listeners[self.rows[ready].id]?[self.channel(self.rows[ready])] != nil
                        && self.gated(ready) == nil
                        && self.handed(ready)
                }) else { return nil }
                var event = rows[ready]
                let channel = channel(rows[ready]), receive = listeners[event.id]![channel]!
                if event.kind == "in.end", let bytes = partial.removeValue(forKey: event.id), !bytes.isEmpty {
                    return (.init(kind: "in.read", id: event.id, value: .bytes(bytes)), receive)
                }
                consume(ready)
                if opened.contains(event.id) || questions[event.id] != nil { own += 1 }
                complete(event)
                try match(event.id)
                if event.kind == "in.read", requested[event.id] != nil || identities[event.id] != nil, !malformed.contains(event.id) {
                    var decoder = decoders[event.id] ?? HelperWire.Decoder()
                    var pending = partial[event.id] ?? Data()
                    pending.append(Self.bytes(event.value))
                    var bytes = Data()
                    do {
                        try decoder.feed(Self.bytes(event.value)) { message in
                            if message.kind == .response, let request = asks[event.id]?[message.id], !consumed.contains(request) {
                                held[event.id, default: [:]][message.id] = message.body
                            } else if skipped[event.id]?.remove(message.id) == nil {
                                bytes.append(try HelperWire.encode(.init(kind: message.kind, id: identities[event.id]?[message.id] ?? message.id, body: message.body)))
                            }
                            if message.kind == .response { questions[event.id]?.remove(message.id) }
                            pending.removeFirst(message.body.count + 13)
                        }
                        if questions[event.id]?.isEmpty == true { questions[event.id] = nil }
                    } catch {
                        // Invalid native wire is itself a recorded app input. Preserve it so
                        // HelperConnection, rather than the journal, reports its framing error.
                        malformed.insert(event.id)
                        bytes.append(pending)
                        pending.removeAll()
                    }
                    partial[event.id] = pending
                    decoders[event.id] = decoder
                    event = .init(kind: event.kind, id: event.id, value: .bytes(bytes))
                }
                return (.init(kind: "in." + event.kind.dropFirst(3 + channel.count), id: event.id, value: event.value), receive)
                }()
                if found == nil { pumping = false; stopped = true }
                return found
            }
            guard let (event, receive) = delivery else { return }
            receive(event)
        }
        }
    }

    /// The journal file is a capture (the helper's core/src/system/capture/trace.rs): zstd around length-prefixed
    /// frames; a header (magic, version, layer app, helper wire version), one record per event, a footer counting them.
    /// What the app asked or sent is a record's args, what came back its output.
    private enum Capture {
        static let magic = Array("DCAPTURE".utf8)
        static let version: UInt32 = 1
        static func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        static func blob(_ bytes: [UInt8]) -> [UInt8] { little(UInt32(bytes.count)) + bytes }
        static func frame(_ body: [UInt8]) -> [UInt8] { blob(body) }
        static var header: [UInt8] { frame(magic + little(version) + [1] + little(HelperBinary.version)) }
        static func asked(_ kind: String) -> Bool { kind.hasPrefix("open.") || kind.hasPrefix("out.") }
        static func record(_ event: Event, clock: UInt64) throws -> [UInt8] {
            let value = try [UInt8](HelperBinary.encode(event.value, schema: false)), null: [UInt8] = [0]
            let (args, output) = asked(event.kind) ? (value, null) : (null, value)
            var body: [UInt8] = [0]
            body += blob(Array("app/\(event.id)".utf8))
            body += little(clock)
            body += blob(Array(event.kind.utf8))
            body += blob(args)
            body += little(UInt64(0))
            body += blob(output)
            body += [0]
            return frame(body)
        }
        static func footer(_ rows: UInt64) -> [UInt8] { frame([255] + little(rows)) }

        /// Every event of a whole capture with its clock: one that ends without a footer counting every record is cut.
        static func read(_ bytes: [UInt8]) throws -> [(event: Event, clock: UInt64)] {
            var at = 0
            func take(_ count: Int) throws -> ArraySlice<UInt8> {
                guard count >= 0, count <= bytes.count - at else { throw error("app journal is cut") }
                defer { at += count }
                return bytes[at..<(at + count)]
            }
            func number<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
                try T(littleEndian: take(MemoryLayout<T>.size).withUnsafeBytes { $0.loadUnaligned(as: T.self) })
            }
            func blob() throws -> ArraySlice<UInt8> { try take(Int(number(UInt32.self))) }
            func text() throws -> String {
                guard let text = String(bytes: try blob(), encoding: .utf8) else { throw error("app journal text is not UTF-8") }
                return text
            }
            let head = try blob()
            guard head == header.dropFirst(4) else { throw error("app journal is not a capture of this app and helper version") }
            var events: [(event: Event, clock: UInt64)] = [], complete = false
            for _ in sequence(first: 0, next: { $0 + 1 }) {
                guard at < bytes.count else { break }
                let end = try Int(number(UInt32.self)) + at
                guard end <= bytes.count else { throw error("app journal is cut") }
                switch try take(1).first! {
                case 0:
                    let section = try text(), clock = try number(UInt64.self), kind = try text()
                    let args = try blob(), _ = try number(UInt64.self), output = try blob(), _ = try take(1)
                    guard section.hasPrefix("app/"), let id = Int(section.dropFirst(4)) else { throw error("app journal section") }
                    let value = try HelperBinary.decode(Data(asked(kind) ? args : output), schema: false)
                    events.append((Event(kind: kind, id: id, value: value), clock))
                    complete = false
                case 255:
                    guard try number(UInt64.self) == UInt64(events.count) else { throw error("app journal footer does not count its records") }
                    complete = true
                default: throw error("app journal frame")
                }
                guard at == end else { throw error("app journal frame length") }
            }
            guard complete else { throw error("app journal has no footer: cut") }
            return events
        }

        /// The whole file expanded: its zstd frames one after another (the helper's capture/zstd.rs), the window no
        /// larger than the corpus encoder's.
        static func expand(_ data: Data) throws -> [UInt8] {
            #if DEBUG && canImport(CZstd)
            guard data.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) else { throw error("app journal is not a capture: no zstd frame") }
            guard let stream = ZSTD_createDStream() else { throw error("zstd decoder") }
            defer { ZSTD_freeDStream(stream) }
            func check(_ code: Int) throws -> Int {
                guard ZSTD_isError(code) == 0 else {
                    throw error("app journal is damaged: zstd " + String(cString: ZSTD_getErrorName(code)))
                }
                return code
            }
            _ = try check(ZSTD_DCtx_setParameter(stream, ZSTD_d_windowLogMax, 27))
            let input = [UInt8](data)
            var output: [UInt8] = [], buffer = [UInt8](repeating: 0, count: 1 << 20), left = 0
            try input.withUnsafeBytes { source in
                try buffer.withUnsafeMutableBytes { target in
                    var from = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                    for _ in sequence(first: 0, next: { $0 + 1 }) {
                        var to = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                        left = try check(ZSTD_decompressStream(stream, &to, &from))
                        output.append(contentsOf: target[0..<to.pos])
                        // Done once the input is read and a buffer with room left nothing more to flush.
                        guard from.pos < from.size || to.pos == to.size else { break }
                    }
                }
            }
            guard left == 0 else { throw error("app journal is cut: zstd") }
            return output
            #else
            // Linux engine checks only (no zstd there): the frames uncompressed.
            return [UInt8](data)
            #endif
        }
    }

    /// Capture: frames compressed as they are recorded, then the footer. Compression and file writes run on the
    /// writer's own queue, as the helper's capture writer thread does: recording costs the record's encoding, never
    /// compression on the thread that recorded it (with bzip2, before zstd, a terminal flood stalled the app at ~2 MB/s).
    /// Past the helper's queue bound (128 MiB) waiting, recording waits for the writer: memory stays bounded, the journal
    /// whole.
    final class Writer: @unchecked Sendable {
        private static let bound = 128 << 20
        private let file: FileHandle, queue = DispatchQueue(label: "yachts.dispatch.journal.writer"), lock = NSCondition()
        private var rows: UInt64 = 0, done = false, queued = 0, failure: (any Error)?
        #if DEBUG && canImport(CZstd)
        private let stream: OpaquePointer
        private var buffer = [UInt8](repeating: 0, count: 1 << 17)
        #endif
        init(_ file: FileHandle) throws {
            self.file = file
            #if DEBUG && canImport(CZstd)
            guard let stream = ZSTD_createCStream() else { throw AppReplay.error("zstd encoder") }
            self.stream = stream
            // A live capture, as the helper writes one (capture/zstd.rs): level 1 in its own window, each frame checked.
            for (parameter, value) in [(ZSTD_c_compressionLevel, Int32(1)), (ZSTD_c_checksumFlag, Int32(1))] {
                let code = ZSTD_CCtx_setParameter(stream, parameter, value)
                guard ZSTD_isError(code) == 0 else { throw AppReplay.error("zstd encoder: " + String(cString: ZSTD_getErrorName(code))) }
            }
            #endif
            try queue.sync { try put(Capture.header, finishing: false) }
        }
        deinit {
            #if DEBUG && canImport(CZstd)
            ZSTD_freeCStream(stream)
            #endif
        }
        func write(_ event: Event, clock: UInt64) throws {
            let bytes = try Capture.record(event, clock: clock)
            try lock.withLock {
                for _ in sequence(first: 0, next: { $0 + 1 }) {
                    guard failure == nil, queued > 0, queued + bytes.count > Self.bound else { break }
                    lock.wait()
                }
                if let failure { throw failure }
                queued += bytes.count
                rows += 1
            }
            queue.async { [self] in
                let result = Result { try put(bytes, finishing: false) }
                lock.withLock {
                    queued -= bytes.count
                    if case .failure(let error) = result, failure == nil { failure = error }
                    lock.broadcast()
                }
            }
        }
        /// `certified`: the footer that makes it whole; without it a reader takes the file for cut.
        func finish(certified: Bool) throws {
            guard let rows = lock.withLock({ () -> UInt64? in defer { done = true }; return done ? nil : self.rows }) else { return }
            try queue.sync {
                defer { try? file.close() }
                if let failure = lock.withLock({ self.failure }) { throw failure }
                try put(certified ? Capture.footer(rows) : [], finishing: true)
            }
        }
        /// On the writer's queue only. `finishing` ends the frame.
        private func put(_ bytes: [UInt8], finishing: Bool) throws {
            #if DEBUG && canImport(CZstd)
            try bytes.withUnsafeBytes { source in
                try buffer.withUnsafeMutableBytes { target in
                    var from = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                    for _ in sequence(first: 0, next: { $0 + 1 }) {
                        var to = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                        let left = ZSTD_compressStream2(stream, &to, &from, finishing ? ZSTD_e_end : ZSTD_e_continue)
                        guard ZSTD_isError(left) == 0 else {
                            throw AppReplay.error("zstd encoder: " + String(cString: ZSTD_getErrorName(left)))
                        }
                        if to.pos > 0 { try file.write(contentsOf: Data(target[0..<to.pos])) }
                        // Every input byte taken (continue), or the frame ended with nothing left to flush (end).
                        if finishing ? left == 0 : from.pos == from.size { break }
                    }
                }
            }
            #else
            try file.write(contentsOf: Data(bytes))
            #endif
        }
    }
}
