import Foundation
import XCTest
@testable import SSHEngine

/// Whole recorded sessions (`RobustScenarios`) replayed into `ClientCore` in memory with seeded corruption, on the wire
/// (after sealing: flipped bits, changed bytes and length fields, inserted and deleted bytes, packets duplicated,
/// dropped and swapped, truncation) and in the plaintext (before sealing, so it passes the integrity check and reaches
/// the parsers: flipped bits, changed length fields and message numbers, cut and extended payloads, messages
/// duplicated, dropped, moved, and messages of another phase or session inserted). For every case:
///
/// - no trap, and no case runs longer than the watchdog allows (a hang prints its case and stops the process);
/// - steps: one input (a read, a timer, a request) produces at most `3 × (bytes / 16 + 1) + Limits.channels + 16`
///   events (a packet is at least 16 bytes on the wire and yields at most three events; an end adds one per channel);
/// - buffers: the undecoded inbound bytes stay within `Limits.inboundBufferBytes` plus the read that brought them;
///   the outbound backlog within twice `Limits.outboundBacklogBytes` plus one packet (`Limits.packetLength`); output
///   the app has not read within the window (`Limits.channelWindow`); the live heap within 64 MiB of the case's start;
/// - the outcome: `.ended(SSHError)` exactly once and last, nothing after it, every login and channel ended before
///   it (a session that is not ended when its stream ends is a failure);
/// - trust: the host key question comes at most once and only with the recorded key and exchange hash; nothing is
///   established and no login succeeds unless that key was trusted; on the wire (where the integrity check holds) the
///   events are the recording's up to the corruption, then only the connection's end;
/// - no secret (the password, keyboard-interactive answer, the user's private key, the session keys) in any error.
///
/// `SSHENGINE_ROBUST_CASES` (default 25,000, about half a minute in a debug build) sets the number of cases (the long
/// mode: `SSHENGINE_ROBUST_CASES=1000000`), `SSHENGINE_ROBUST_SEED` the master seed (hex; printed),
/// `SSHENGINE_ROBUST_CASE=<case seed>` replays one case and prints what it did.
final class SessionReplayTests: XCTestCase {
  static let defaultSeed: UInt64 = 0x5EED_0001
  static let watchdogSeconds = 120.0

  static func hex(_ text: String?) -> UInt64? {
    guard let text else { return nil }
    let digits = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
    return UInt64(digits, radix: 16)
  }

  static func recordAll() throws -> [RecordedSession] {
    try RobustScenarios.all.enumerated().map { index, scenario in
      try SessionRecorder.record(scenario, seed: 0xC11E_0000 + UInt64(index))
    }
  }

  /// Every recording reaches what its scenario is for, and replays unmodified (sealed again, read in pieces) to the
  /// recording's events exactly.
  func testRecordingsReplayUnmodified() throws {
    let sessions = try Self.recordAll()
    var covered = Set<String>()
    for session in sessions {
      let names = session.events.map { event -> String in
        switch event {
        case .established: "established"
        case .rekeyed: "rekeyed"
        case .authFinished(.success(.success)): "login"
        case .authFinished(.success(.refused)): "refused"
        case .authFinished(.success(.passwordChangeRequested)): "password-change"
        case .prompt: "prompt"
        case .sign: "sign"
        case .opened: "opened"
        case .output(_, .stdout): "stdout"
        case .output(_, .stderr): "stderr"
        case .closed(_, .status, _): "exit-status"
        case .closed(_, .signal, _): "exit-signal"
        case .ended(.closed(.byServer)): "server-disconnect"
        case .ended: "ended"
        default: "other"
        }
      }
      covered.formUnion(names)
      XCTAssertTrue(names.contains("login"), session.scenario.name)
      XCTAssertEqual(names.last, names.contains("server-disconnect") ? "server-disconnect" : "ended", session.scenario.name)
      for chunking in 0..<4 {
        let replay = SessionReplay(session: session, pool: [])
        var mutated = replay.sealed(random: SeededRandom(seed: UInt64(chunking)))
        mutated.description = "unmodified"
        let result = replay.run(mutated, consumes: true, chunking: chunking == 0 ? nil : SeededRandom(seed: UInt64(chunking)))
        XCTAssertEqual(result.failures, [], session.scenario.name)
        XCTAssertEqual(result.events.filter(\.isNotTimer), session.events.filter(\.isNotTimer), session.scenario.name)
      }
    }
    for needed in ["established", "rekeyed", "login", "refused", "password-change", "prompt", "sign", "opened", "stdout",
                   "stderr", "exit-status", "exit-signal", "server-disconnect"] {
      XCTAssertTrue(covered.contains(needed), "no recording covers \(needed)")
    }
    let transport = sessions.flatMap { $0.beats }.compactMap { beat -> String? in
      if case .record(.install(let cipher, let mac, _, _)) = beat { return cipher.rawValue + (mac.map { "/" + $0.rawValue } ?? "") }
      return nil
    }
    print("ROBUST recordings: \(sessions.count) sessions, \(sessions.map { $0.beats.count }.reduce(0, +)) beats; "
          + "server-to-client protections: \(Set(transport).sorted())")
  }

  /// The seeded corruption run (see the class comment).
  func testCorruptedSessionsEndWithATypedError() throws {
    let environment = ProcessInfo.processInfo.environment
    let master = Self.hex(environment["SSHENGINE_ROBUST_SEED"]) ?? Self.defaultSeed
    let cases = environment["SSHENGINE_ROBUST_CASES"].flatMap { Int($0) } ?? 25_000
    let sessions = try Self.recordAll()
    let pool = sessions.flatMap(\.payloads)
    let replays = sessions.map { SessionReplay(session: $0, pool: pool) }
    if let single = Self.hex(environment["SSHENGINE_ROBUST_CASE"]) {
      let outcome = RobustCase(seed: single, replays: replays).run()
      print("ROBUST case 0x\(String(single, radix: 16)): \(outcome.description)\n  events: \(outcome.events)")
      XCTAssertEqual(outcome.failures, [], outcome.description)
      return
    }
    print("ROBUST master seed 0x\(String(master, radix: 16)), \(cases) cases "
          + "(SSHENGINE_ROBUST_SEED, SSHENGINE_ROBUST_CASES; SSHENGINE_ROBUST_CASE=<seed> replays one)")
    let watchdog = Watchdog(limit: Self.watchdogSeconds)
    defer { watchdog.stop() }
    let stream = SeededRandom(seed: master)
    var endings: [String: Int] = [:]
    var failed = 0
    var mostEvents = 0
    var mostHeap = 0
    let started = Date()
    for index in 0..<cases {
      let seed = stream.next()
      watchdog.begin(seed)
      let outcome = RobustCase(seed: seed, replays: replays).run()
      watchdog.end()
      endings[outcome.ending, default: 0] += 1
      mostEvents = max(mostEvents, outcome.mostEventsPerInput)
      mostHeap = max(mostHeap, outcome.heapGrowth)
      if !outcome.failures.isEmpty {
        failed += 1
        if failed <= 20 {
          XCTFail("case \(index) SSHENGINE_ROBUST_CASE=0x\(String(seed, radix: 16)): \(outcome.description): \(outcome.failures)")
        }
      }
    }
    _ = stream.next()
    let seconds = Date().timeIntervalSince(started)
    print(String(format: "ROBUST %d cases in %.1f s, %d failed; most events from one input %d; most heap growth %d KiB",
                 cases, seconds, failed, mostEvents, mostHeap / 1024))
    for (ending, count) in endings.sorted(by: { $0.value > $1.value }) { print("ROBUST   \(count)\t\(ending)") }
  }

  /// Truncation at every offset of every recording (the stream ends there): the session ends with its events up to
  /// that point, then `closed(.connectionLost)` (or the end the cut produced). `SSHENGINE_ROBUST_STRIDE` takes every
  /// n-th offset: 5 by default, 1 (every offset) when `SSHENGINE_ROBUST_CASES` asks for the long mode.
  func testTruncationAtEveryOffset() throws {
    let environment = ProcessInfo.processInfo.environment
    let long = (environment["SSHENGINE_ROBUST_CASES"].flatMap { Int($0) } ?? 0) >= 100_000
    let stride = max(1, environment["SSHENGINE_ROBUST_STRIDE"].flatMap { Int($0) } ?? (long ? 1 : 5))
    let sessions = try Self.recordAll()
    var total = 0
    let started = Date()
    for session in sessions {
      let replay = SessionReplay(session: session, pool: [])
      let sealed = replay.sealed(random: SeededRandom(seed: 1))
      var offset = 0
      while offset <= sealed.stream.count {
        var mutated = sealed
        mutated.truncate(at: offset)
        let result = replay.run(mutated, consumes: true, chunking: SeededRandom(seed: UInt64(offset)))
        total += 1
        if !result.failures.isEmpty {
          XCTFail("\(session.scenario.name), truncated at \(offset): \(result.failures)")
          break
        }
        offset += stride
      }
    }
    print(String(format: "ROBUST truncation: %d cases in %.1f s", total, Date().timeIntervalSince(started)))
  }
}

extension ClientEvent {
  var isNotTimer: Bool {
    if case .timer = self { return false }
    return true
  }

  /// What a connection's end adds after the point where a replay left its recording.
  var isTeardown: Bool {
    switch self {
    case .authFinished(.failure), .openFailed, .ended, .closed(_, _, lostWith: .some), .timer: true
    default: false
    }
  }
}

// MARK: - Sealing and running one replay

/// A sealed stream and where in it the client hears and acts.
struct MutatedStream {
  struct Mark {
    var offset: Int
    /// nil: a delivery boundary (the client reads what came so far).
    var interjection: Interjection?
  }

  var stream: [UInt8] = []
  var marks: [Mark] = []
  /// The stream ends after this many bytes (truncation).
  var endAt: Int?
  /// The sealed packets' ranges (before any wire change).
  var packets: [Range<Int>] = []
  /// Wire changes made (plaintext changes keep the integrity check: the prefix rule does not apply to them).
  var wireChanged = false
  var plaintextChanged = false
  var description = ""

  mutating func truncate(at offset: Int) {
    endAt = min(offset, stream.count)
    wireChanged = true
    description += " truncate@\(offset)"
  }

  mutating func insert(_ bytes: [UInt8], at offset: Int) {
    stream.insert(contentsOf: bytes, at: offset)
    for index in marks.indices where marks[index].offset > offset { marks[index].offset += bytes.count }
    wireChanged = true
  }

  mutating func delete(_ range: Range<Int>) {
    stream.removeSubrange(range)
    for index in marks.indices where marks[index].offset > range.lowerBound {
      marks[index].offset = max(range.lowerBound, marks[index].offset - range.count)
    }
    wireChanged = true
  }
}

struct ReplayResult {
  var caseDescription = ""
  var events: [ClientEvent] = []
  var failures: [String] = []
  var ending = "none"
  var mostEventsPerInput = 0
  var heapGrowth = 0

  var description: String { "\(caseDescription) -> \(ending)" }
}

/// One recorded session, sealed again on demand (with plaintext changes) and run into a fresh core.
struct SessionReplay {
  let session: RecordedSession
  /// Payloads of every session (messages of another phase).
  let pool: [[UInt8]]

  /// The keys of every server direction in the recording, as text an error must not contain.
  var secretTexts: [String] {
    var texts = [RobustSecrets.password, RobustSecrets.kbdAnswer, hexText(Array(RobustSecrets.userKey.rawRepresentation))]
    for beat in session.beats {
      if case .record(.install(_, _, let keys, _)) = beat {
        texts.append(keys.key.withUnsafeBytes { hexText(Array($0)) })
      }
    }
    return texts
  }

  func sealed(beats: [Beat]? = nil, random: SeededRandom) -> MutatedStream {
    var result = MutatedStream()
    var framer = OutboundFramer()
    for beat in beats ?? session.beats {
      switch beat {
      case .record(.raw(let bytes)):
        result.stream += bytes
      case .record(.payload(let payload)):
        framer.output = []
        guard (try? framer.seal(payload, random: random)) != nil else { continue }
        let start = result.stream.count
        result.stream += framer.output
        result.packets.append(start..<result.stream.count)
      case .record(.install(let cipher, let mac, let keys, let reset)):
        guard let sealer = try? PacketProtection.sealer(cipher: cipher, mac: mac, keys: keys) else { continue }
        framer.install(sealer)
        if reset { framer.resetSequence() }
      case .deliver:
        result.marks.append(.init(offset: result.stream.count, interjection: nil))
      case .client(let interjection):
        result.marks.append(.init(offset: result.stream.count, interjection: interjection))
      }
    }
    return result
  }

  /// Runs the stream into a fresh core; `chunking` splits each delivery into random reads.
  func run(_ mutated: MutatedStream, consumes: Bool, chunking: SeededRandom?, defersTrust: Bool = false) -> ReplayResult {
    var result = ReplayResult()
    let pilot: Pilot
    do {
      pilot = try Pilot(scenario: session.scenario, seed: session.seed, expected: (session.hostKey, session.sessionID),
                        consumes: consumes)
    } catch {
      result.failures.append("the core: \(error)")
      return result
    }
    pilot.defersTrust = defersTrust
    let core = pilot.core
    let heapStart = Heap.inUse()
    var failures: [String] = []

    func budget(bytes: Int) -> Int { 3 * (bytes / 16 + 1) + Limits.channels + 16 }

    func flush() {
      for _ in 0..<1000 {
        if core.outboundBacklog > 2 * Limits.outboundBacklogBytes + Limits.packetLength {
          failures.append("outbound backlog \(core.outboundBacklog)")
        }
        let bytes = core.takeOutbound()
        pilot.drain(budget: budget(bytes: 0))
        if bytes.isEmpty { return }
      }
      failures.append("the outbound never emptied")
    }

    func checkHeap() {
      let growth = Heap.inUse() - heapStart
      result.heapGrowth = max(result.heapGrowth, growth)
      if growth > 64 << 20 { failures.append("heap grew by \(growth) bytes") }
    }

    var streamEnded = false
    func deliver(_ bytes: ArraySlice<UInt8>) {
      var rest = bytes
      while !rest.isEmpty {
        let size = chunking.map { random in [1, 7, 64, 1500, 1 << 20][random.below(5)] } ?? rest.count
        let chunk = Array(rest.prefix(max(1, size)))
        rest = rest.dropFirst(chunk.count)
        let wasEnded = core.isEnded
        core.receive(chunk)
        pilot.drain(budget: budget(bytes: chunk.count))
        // Once ended, nothing more is read (what was buffered stays until the core goes).
        if !wasEnded, core.inboundBuffered > Limits.inboundBufferBytes + chunk.count {
          failures.append("inbound buffer \(core.inboundBuffered) after a read of \(chunk.count)")
        }
        flush()
      }
      checkHeap()
      if pilot.answerDeferredTrust() {
        pilot.drain(budget: budget(bytes: Limits.inboundBufferBytes + bytes.count))
        flush()
      }
    }

    func endStream() {
      guard !streamEnded else { return }
      streamEnded = true
      core.receiveEnd()
      pilot.drain(budget: budget(bytes: 0))
      flush()
    }

    core.start()
    pilot.drain(budget: budget(bytes: 0))
    flush()
    var offset = 0
    let limit = min(mutated.endAt ?? mutated.stream.count, mutated.stream.count)
    for mark in mutated.marks {
      let upTo = min(mark.offset, limit)
      if upTo > offset {
        deliver(mutated.stream[offset..<upTo])
        offset = upTo
      }
      if mutated.endAt != nil, offset >= limit { endStream() }
      if let interjection = mark.interjection {
        pilot.interject(interjection)
        pilot.drain(budget: budget(bytes: 0))
        flush()
      }
    }
    if limit > offset { deliver(mutated.stream[offset..<limit]) }
    if pilot.answerDeferredTrust() {
      pilot.drain(budget: budget(bytes: Limits.inboundBufferBytes))
      flush()
    }
    endStream()
    if !pilot.hasEnded { failures.append("not ended once the stream ended") }

    // Nothing after the end.
    let after = pilot.totalEvents
    core.receive([0, 0, 0, 12, 10, 21, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    core.timerFired(.keepalive)
    core.timerFired(.rekey)
    core.timerFired(.directAnswer)
    core.end(.closed(.byClient))
    pilot.drain(budget: 0)
    if pilot.totalEvents != after { failures.append("events after the end") }

    failures += pilot.violations
    for error in pilot.requestErrors {
      if case .usage = error { failures.append("a request in answer to the core's events failed: \(error)") }
    }
    if let index = pilot.events.lastIndex(where: { if case .ended = $0 { true } else { false } }),
      case .ended(let error) = pilot.events[index]
    {
      result.ending = Self.category(error)
    }
    // Secrets.
    let secrets = secretTexts
    for error in pilot.reportedErrors + pilot.requestErrors {
      let texts = ["\(error)", String(reflecting: error), error.description]
      for text in texts {
        for secret in secrets where text.contains(secret) { failures.append("a secret in an error's text: \(text)") }
      }
    }
    // The prefix rule: under an intact integrity check the client acted on nothing the server did not send.
    if mutated.wireChanged && !mutated.plaintextChanged {
      let got = pilot.events.filter(\.isNotTimer)
      let recorded = session.events.filter(\.isNotTimer)
      var index = 0
      while index < got.count, index < recorded.count, got[index] == recorded[index] { index += 1 }
      let closedByApp = pilot.closedByApp
      // The server's attempt limit (`UserauthCore.connectionEnded`): a connection that ends while an asked-for attempt
      // waits, after the server refused an earlier one on it, ends that attempt as refused with nothing left.
      let refusedBefore = got[..<index].contains { event in
        if case .authFinished(.success(.refused(_, partialSuccess: false))) = event { true } else { false }
      }
      if let odd = got[index...].first(where: { event in
        if case .closed(let id, _, nil) = event, closedByApp.contains(id.rawValue) { return false }
        if case .writable = event { return false }
        if refusedBefore, case .authFinished(.success(.refused(let remaining, partialSuccess: false))) = event,
          remaining.isEmpty
        {
          return false
        }
        return !event.isTeardown
      }) {
        failures.append("after leaving the recording at event \(index), \(odd)")
      }
    }
    result.events = pilot.events
    result.failures = failures
    result.mostEventsPerInput = pilot.mostEventsPerInput
    return result
  }

  /// A short name for an end, for the run's summary: its enum cases' path (`protocolViolation.malformed.truncated`).
  static func category(_ error: SSHError) -> String {
    var labels: [String] = []
    var value: Any = error
    for _ in 0..<4 {
      let mirror = Mirror(reflecting: value)
      guard mirror.displayStyle == .enum else { break }
      guard let child = mirror.children.first, let label = child.label else {
        labels.append("\(value)")
        break
      }
      labels.append(label)
      // A payload tuple: follow its first enum element.
      let inner = Mirror(reflecting: child.value)
      if inner.displayStyle == .tuple {
        guard let element = inner.children.first(where: { Mirror(reflecting: $0.value).displayStyle == .enum }) else { break }
        value = element.value
      } else {
        value = child.value
      }
    }
    return labels.joined(separator: ".")
  }
}

func hexText(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// The live heap: malloc's bytes in use, or under the address sanitizer its allocator's count of live bytes (the zone
/// statistics it reports there grow with every allocation, freed or not).
enum Heap {
  static func inUse() -> Int {
    if let live = sanitizerLiveBytes { return live() }
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return Int(statistics.size_in_use)
  }

  private static let sanitizerLiveBytes: (@Sendable () -> Int)? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__sanitizer_get_current_allocated_bytes") else {
      return nil
    }
    let function = unsafeBitCast(symbol, to: (@convention(c) () -> Int).self)
    return { function() }
  }()
}

// MARK: - One seeded case

/// A case: from its seed, a session, whether the app reads, how reads are cut, and one to three changes before or
/// after sealing.
struct RobustCase {
  let seed: UInt64
  let replays: [SessionReplay]

  static let interesting32: [UInt32] = [0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 31, 32, 0x7F, 0x80, 0xFF, 0x100, 0x3FFF, 0x4000,
                                        0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x3FFFF, 0x40000, 0x40001, 0x7FFF_FFFF,
                                        0x8000_0000, 0xFFFF_FFFE, 0xFFFF_FFFF]
  static let interesting8: [UInt8] = [0, 1, 2, 0x7F, 0x80, 0xFE, 0xFF]

  func run() -> ReplayResult {
    let random = SeededRandom(seed: seed)
    let replay = replays[random.below(replays.count)]
    let consumes = random.below(4) != 0
    let chunked = random.below(3) != 0
    let defersTrust = random.below(4) == 0
    var beats = replay.session.beats
    var notes: [String] = [replay.session.scenario.name, consumes ? "reads" : "never reads"]
    if defersTrust { notes.append("trust answered late") }
    let changes = [1, 1, 1, 2, 3][random.below(5)]
    var plaintext = false
    var wireOps: [(inout MutatedStream) -> Void] = []
    for _ in 0..<changes {
      if random.below(2) == 0 {
        plaintext = true
        notes.append(mutatePlaintext(&beats, random: random, pool: replay.pool))
      } else {
        let (note, op) = wireMutation(random: random)
        notes.append(note)
        wireOps.append(op)
      }
    }
    var mutated = replay.sealed(beats: beats, random: SeededRandom(seed: seed ^ 0x51A1))
    for op in wireOps { op(&mutated) }
    mutated.plaintextChanged = plaintext
    mutated.description = notes.joined(separator: ", ") + mutated.description
    var result = replay.run(mutated, consumes: consumes, chunking: chunked ? SeededRandom(seed: seed ^ 0xC4C4) : nil,
                            defersTrust: defersTrust)
    result.caseDescription = mutated.description
    return result
  }

  /// A change to the payloads before they are sealed. Returns what it did.
  func mutatePlaintext(_ beats: inout [Beat], random: SeededRandom, pool: [[UInt8]]) -> String {
    let payloadIndices = beats.indices.filter { if case .record(.payload) = beats[$0] { true } else { false } }
    guard !payloadIndices.isEmpty else { return "nothing" }
    let at = payloadIndices[random.below(payloadIndices.count)]
    guard case .record(.payload(var payload)) = beats[at] else { return "nothing" }
    let number = payload.first ?? 0
    func put(_ bytes: [UInt8]) { beats[at] = .record(.payload(bytes)) }
    switch random.below(13) {
    case 0, 1:
      let flips = 1 + random.below(4)
      for _ in 0..<flips where !payload.isEmpty {
        let index = random.below(payload.count)
        payload[index] ^= 1 << UInt8(random.below(8))
      }
      put(payload)
      return "plaintext: \(flips) bits flipped in message \(number)"
    case 2, 3:
      // A length field (a u32 that fits as a string's length here), or any u32, set to an interesting value.
      let candidates = payload.count < 5 ? [] : (1...(payload.count - 4)).filter { offset in
        let value = payload[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        return offset + 4 + value <= payload.count
      }
      guard payload.count >= 5 else { return "nothing" }
      let offset = candidates.isEmpty || random.below(4) == 0 ? 1 + random.below(payload.count - 4)
        : candidates[random.below(candidates.count)]
      let old = payload[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
      let value = random.below(3) == 0 ? old &+ UInt32(bitPattern: Int32(random.below(9) - 4))
        : Self.interesting32[random.below(Self.interesting32.count)]
      payload.replaceSubrange(offset..<offset + 4, with: Raw.u32(value))
      put(payload)
      return "plaintext: u32 at \(offset) of message \(number) \(old) -> \(value)"
    case 4:
      guard !payload.isEmpty else { return "nothing" }
      let index = random.below(payload.count)
      payload[index] = Self.interesting8[random.below(Self.interesting8.count)]
      put(payload)
      return "plaintext: byte \(index) of message \(number) set"
    case 5:
      let keep = random.below(payload.count + 1)
      put(Array(payload.prefix(keep)))
      return "plaintext: message \(number) cut to \(keep) of \(payload.count)"
    case 6:
      let extra = (0..<(1 + random.below(40))).map { _ in UInt8(truncatingIfNeeded: random.next()) }
      put(payload + extra)
      return "plaintext: message \(number) extended by \(extra.count)"
    case 7:
      beats.remove(at: at)
      return "plaintext: message \(number) dropped"
    case 8:
      let later = payloadIndices.filter { $0 >= at }
      let target = later[random.below(later.count)] + 1
      beats.insert(.record(.payload(payload)), at: target)
      return "plaintext: message \(number) duplicated"
    case 9:
      // Reordered: moved after a later message.
      let later = payloadIndices.filter { $0 > at }
      guard let target = later.isEmpty ? nil : later[random.below(min(later.count, 4))] else { return "nothing" }
      beats.insert(beats[at], at: target + 1)
      beats.remove(at: at)
      return "plaintext: message \(number) moved later"
    case 10:
      let message = pool[random.below(pool.count)]
      beats.insert(.record(.payload(message)), at: at)
      return "plaintext: message \(message.first ?? 0) of another phase inserted before \(number)"
    case 11:
      let message = Self.hostileMessage(random: random)
      beats.insert(.record(.payload(message)), at: at)
      return "plaintext: hostile message \(message.first ?? 0) inserted before \(number)"
    default:
      guard !payload.isEmpty else { return "nothing" }
      let replacement = UInt8(truncatingIfNeeded: random.next())
      payload[0] = replacement
      put(payload)
      return "plaintext: message \(number) renumbered \(replacement)"
    }
  }

  /// Messages the scripted server never sends: refusable requests, channel messages for odd numbers, extreme values.
  static func hostileMessage(random: SeededRandom) -> [UInt8] {
    let channel: UInt32 = [0, 1, 2, 3, 63, 64, 0xFFFF_FFFF][random.below(7)]
    let big = interesting32[random.below(interesting32.count)]
    let text = Raw.string([UInt8](repeating: 0x41, count: [0, 1, 300, 2000, 20000][random.below(5)]))
    switch random.below(20) {
    case 0: return [2] + text
    case 1: return [4, 1] + text + Raw.string("")
    case 2: return [3] + Raw.u32(big)
    case 3: return [7] + Raw.u32(big) + Raw.string("server-sig-algs") + text
    case 4: return [80] + Raw.string("tcpip-forward") + [1] + text
    case 5: return [81] + text
    case 6: return [82]
    case 7: return [90] + Raw.string("forwarded-tcpip") + Raw.u32(channel) + Raw.u32(big) + Raw.u32(big) + text
    case 8: return [91] + Raw.u32(channel) + Raw.u32(channel) + Raw.u32(big) + Raw.u32(big)
    case 9: return [92] + Raw.u32(channel) + Raw.u32(big) + text + Raw.string("")
    case 10: return [93] + Raw.u32(channel) + Raw.u32(big)
    case 11: return [94] + Raw.u32(channel) + text
    case 12: return [95] + Raw.u32(channel) + Raw.u32(big) + text
    case 13: return [96] + Raw.u32(channel)
    case 14: return [97] + Raw.u32(channel)
    case 15: return [98] + Raw.u32(channel) + Raw.string("exit-status") + [UInt8(random.below(3))] + Raw.u32(big)
    case 16: return [98] + Raw.u32(channel) + Raw.string("exit-signal") + [0] + Raw.string("KILL") + [1] + text + Raw.string("")
    case 17: return [99 + UInt8(random.below(2))] + Raw.u32(channel)
    case 18: return [52]
    default: return [1] + Raw.u32(big) + text + Raw.string("")
    }
  }

  /// A change to the sealed bytes, applied once the stream is sealed.
  func wireMutation(random: SeededRandom) -> (String, (inout MutatedStream) -> Void) {
    let pick = random.below(11)
    let a = random.next()
    let b = random.next()
    let c = random.next()
    func position(_ value: UInt64, _ count: Int) -> Int { count == 0 ? 0 : Int(value % UInt64(count)) }
    switch pick {
    case 0, 1:
      return ("wire: bits flipped", { stream in
        guard !stream.stream.isEmpty else { return }
        for step in 0..<(1 + Int(c % 3)) {
          let index = position(a &+ UInt64(step) &* b, stream.stream.count)
          stream.stream[index] ^= 1 << UInt8(truncatingIfNeeded: (b >> UInt64(step * 3)) % 8)
        }
        stream.wireChanged = true
        stream.description += " (flips near \(position(a, stream.stream.count)))"
      })
    case 2:
      return ("wire: a byte set", { stream in
        guard !stream.stream.isEmpty else { return }
        let index = position(a, stream.stream.count)
        stream.stream[index] = Self.interesting8[Int(b % UInt64(Self.interesting8.count))]
        stream.wireChanged = true
        stream.description += " (@\(index))"
      })
    case 3, 4:
      return ("wire: a packet's length field", { stream in
        guard !stream.packets.isEmpty else { return }
        let packet = stream.packets[position(a, stream.packets.count)]
        guard packet.lowerBound + 4 <= stream.stream.count else { return }
        let value = b % 2 == 0 ? Self.interesting32[position(c, Self.interesting32.count)] : UInt32(truncatingIfNeeded: c)
        stream.stream.replaceSubrange(packet.lowerBound..<packet.lowerBound + 4, with: Raw.u32(value))
        stream.wireChanged = true
        stream.description += " (packet at \(packet.lowerBound) -> \(value))"
      })
    case 5:
      return ("wire: truncated", { stream in stream.truncate(at: position(a, stream.stream.count + 1)) })
    case 6:
      return ("wire: bytes inserted", { stream in
        let count = c % 8 == 0 ? 300 * 1024 : Int(1 + c % 64)
        let bytes = (0..<count).map { UInt8(truncatingIfNeeded: (b &+ UInt64($0)) &* 0x9E37_79B9_7F4A_7C15 >> 56) }
        let at = position(a, stream.stream.count + 1)
        stream.insert(bytes, at: at)
        stream.description += " (\(count) at \(at))"
      })
    case 7:
      return ("wire: bytes deleted", { stream in
        guard !stream.stream.isEmpty else { return }
        let start = position(a, stream.stream.count)
        let end = min(stream.stream.count, start + Int(1 + b % 64))
        stream.delete(start..<end)
        stream.description += " (\(start)..<\(end))"
      })
    case 8:
      return ("wire: a packet duplicated", { stream in
        guard !stream.packets.isEmpty else { return }
        let packet = stream.packets[position(a, stream.packets.count)]
        guard packet.upperBound <= stream.stream.count else { return }
        stream.insert(Array(stream.stream[packet]), at: packet.upperBound)
        stream.description += " (at \(packet.lowerBound))"
      })
    case 9:
      return ("wire: a packet dropped", { stream in
        guard !stream.packets.isEmpty else { return }
        let packet = stream.packets[position(a, stream.packets.count)]
        guard packet.upperBound <= stream.stream.count else { return }
        stream.delete(packet)
        stream.description += " (at \(packet.lowerBound))"
      })
    default:
      return ("wire: two packets swapped", { stream in
        guard stream.packets.count >= 2 else { return }
        let first = position(a, stream.packets.count - 1)
        let one = stream.packets[first]
        let two = stream.packets[first + 1]
        guard one.upperBound == two.lowerBound, two.upperBound <= stream.stream.count else { return }
        let swapped = Array(stream.stream[two]) + Array(stream.stream[one])
        stream.stream.replaceSubrange(one.lowerBound..<two.upperBound, with: swapped)
        stream.wireChanged = true
        stream.description += " (at \(one.lowerBound))"
      })
    }
  }
}

// MARK: - Watchdog

/// Stops the process when one case runs past its limit (a hang), printing the case to replay.
final class Watchdog: @unchecked Sendable {
  private let lock = NSLock()
  private var current: (seed: UInt64, since: Date)?
  private var stopped = false

  init(limit: Double) {
    let thread = Thread { [weak self] in
      while true {
        Thread.sleep(forTimeInterval: 1)
        guard let self else { return }
        let (seed, since, stopped) = self.lock.withLock { (self.current?.seed, self.current?.since, self.stopped) }
        if stopped { return }
        if let seed, let since, Date().timeIntervalSince(since) > limit {
          print("ROBUST hang: SSHENGINE_ROBUST_CASE=0x\(String(seed, radix: 16)) ran over \(limit) s")
          fflush(stdout)
          abort()
        }
      }
    }
    thread.start()
  }

  func begin(_ seed: UInt64) {
    lock.withLock { current = (seed, Date()) }
    CrashNote.set("ROBUST crashed in SSHENGINE_ROBUST_CASE=0x\(String(seed, radix: 16))\n")
  }
  func end() { lock.withLock { current = nil } }
  func stop() { lock.withLock { stopped = true } }
}

/// What a crash (a trap, a bad access) prints before the process dies: the case to replay.
enum CrashNote {
  nonisolated(unsafe) private static var buffer = [CChar](repeating: 0, count: 128)
  nonisolated(unsafe) private static var length = 0
  nonisolated(unsafe) private static var installed = false

  static func set(_ text: String) {
    if !installed {
      installed = true
      for signal in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT] {
        Darwin.signal(signal) { number in
          CrashNote.buffer.withUnsafeBufferPointer { _ = write(2, $0.baseAddress, CrashNote.length) }
          Darwin.signal(number, SIG_DFL)
          raise(number)
        }
      }
    }
    let bytes = Array(text.utf8.prefix(127)).map { CChar(bitPattern: $0) }
    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    length = bytes.count
  }
}
