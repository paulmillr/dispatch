import Foundation

/// One attached tab's outgoing terminal input (`HelperWorkspace.attach`), in the order it was typed, without waiting
/// for each call's reply: a key goes on the wire as soon as the one before it is on the wire (the connection's transport
/// queue is serial, so the helper reads them in that order), as plain ssh streams keystrokes. Waiting for every reply
/// cost one round trip per key: ten keys took 12.6 s over a 1 s link.
///
/// Before each call the queue passes `gate` (the attach confirmation, a control client still on the PTY, whether the
/// tab still shows the terminal); `false` drops the call it was for. Input queued meanwhile joins into one call, and
/// so does input typed while the calls on the wire already hold `budget` bytes (the helper lends each subscription
/// 1 MiB of input credit and takes it back as each call completes) or number `depth`. Checked keys (`terminals.keys`,
/// possibly through another endpoint's connection) never join: they wait until every earlier call was answered, and
/// later input waits for their answer. Nothing is retried; `send` reports its own failures.
@MainActor
final class HelperInputQueue<Keys> {
  enum Item {
    case input(Data)
    case keys(Data, Keys)

    var count: Int {
      switch self {
      case .input(let bytes), .keys(let bytes, _): bytes.count
      }
    }
  }

  /// Awaits a call's reply once `send` put it on the wire.
  typealias Reply = @MainActor () async -> Void

  nonisolated static var budget: Int { 256 * 1024 }
  nonisolated static var depth: Int { 64 }

  private let gate: @MainActor () async -> Bool
  /// Puts one call on the wire (waits for that, not for its reply); nil when it was not sent.
  private let send: @MainActor (Item) async -> Reply?
  private let budget: Int
  private let depth: Int
  private var items: [Item] = []
  /// Calls on the wire whose replies have not come, oldest first, with their sizes.
  private var outstanding: [(id: Int, count: Int, reply: Task<Void, Never>)] = []
  private var calls = 0
  /// The worker (running or finished): a new one starts after it, so calls never overtake.
  private var tail: Task<Void, Never>?
  private var running = false
  private var generation = 0

  init(budget: Int = HelperInputQueue.budget, depth: Int = HelperInputQueue.depth,
       gate: @escaping @MainActor () async -> Bool, send: @escaping @MainActor (Item) async -> Reply?) {
    self.gate = gate
    self.send = send
    self.budget = max(1, budget)
    self.depth = max(1, depth)
  }

  /// Calls appended from now on go out after what `previous` (the queue an earlier attachment of the same tab used)
  /// already took on.
  func follow(_ previous: HelperInputQueue?) {
    guard let previous, previous !== self, let theirs = previous.tail else { return }
    let mine = tail
    tail = Task {
      await theirs.value
      await mine?.value
    }
  }

  /// Calls waiting to go out (tests).
  var queued: Int { items.count }
  /// Calls on the wire whose replies have not come (tests).
  var unanswered: Int { outstanding.count }

  func append(_ item: Item) {
    items.append(item)
    guard !running else { return }
    running = true
    generation += 1
    let generation = generation, previous = tail
    tail = Task {
      await previous?.value
      await run(generation)
    }
  }

  /// Drops what has not gone out and stops the worker; calls already on the wire keep their replies. Input appended
  /// later starts again, after the stopped worker returned.
  func cancel() {
    items.removeAll()
    tail?.cancel()
    running = false
    generation += 1
  }

  private func run(_ generation: Int) async {
    while self.generation == generation, !Task.isCancelled, let first = items.first {
      if case .keys = first {
        // Earlier calls may have gone through another connection: none may still be on its way.
        while let oldest = outstanding.first { await oldest.reply.value }
      } else {
        // Room on the wire for at least the first chunk (a chunk larger than the budget goes alone).
        while let oldest = outstanding.first, outstanding.count >= depth || used + first.count > budget {
          await oldest.reply.value
        }
      }
      let passed = await gate()
      guard self.generation == generation, !Task.isCancelled else { break }
      guard let item = take(limit: max(budget - used, items.first?.count ?? 0)) else { break }
      guard passed, let reply = await send(item) else { continue }
      if case .keys = item {
        await reply()
      } else {
        calls += 1
        let id = calls
        outstanding.append((id, item.count, Task {
          await reply()
          outstanding.removeAll { $0.id == id }
        }))
      }
    }
    if self.generation == generation { running = false }
  }

  private var used: Int { outstanding.reduce(0) { $0 + $1.count } }

  /// The next call: queued plain input joins up to `limit` bytes; keys go alone.
  private func take(limit: Int) -> Item? {
    guard !items.isEmpty else { return nil }
    let first = items.removeFirst()
    guard case .input(var bytes) = first else { return first }
    while case .input(let more)? = items.first, bytes.count + more.count <= limit {
      bytes.append(more)
      items.removeFirst()
    }
    return .input(bytes)
  }
}

/// One tab's herdr scroll steps (`terminals.scroll`): while one is in flight, further wheel steps of the same kind
/// (page, modifiers, cell) add up into one step sent when its reply returns, instead of a round trip and a repaint
/// each. Each step keeps what its caller does when the renderer owns the history instead (`scrollback_app_owned`).
struct HelperScrollSteps<Local> {
  struct Step: Equatable {
    var lines: Int64
    let page: Bool
    let column: UInt16?
    let row: UInt16?
    let modifiers: UInt8

    func joins(_ other: Step) -> Bool {
      page == other.page && modifiers == other.modifiers && column == other.column && row == other.row
    }
  }

  private(set) var busy = false
  private(set) var waiting: [(step: Step, locals: [Local])] = []

  var idle: Bool { !busy && waiting.isEmpty }

  /// The step to send now, or nil when one is in flight (this one waits, joined into the last waiting step of its
  /// kind).
  mutating func add(_ step: Step, _ local: Local) -> (step: Step, locals: [Local])? {
    guard busy else {
      busy = true
      return (step, [local])
    }
    if let last = waiting.indices.last, waiting[last].step.joins(step) {
      let (sum, overflow) = waiting[last].step.lines.addingReportingOverflow(step.lines)
      waiting[last].step.lines = overflow ? (step.lines < 0 ? .min : .max) : sum
      waiting[last].locals.append(local)
    } else {
      waiting.append((step, [local]))
    }
    return nil
  }

  /// The step in flight was answered: the next one to send, if any.
  mutating func finish() -> (step: Step, locals: [Local])? {
    guard !waiting.isEmpty else {
      busy = false
      return nil
    }
    return waiting.removeFirst()
  }

  /// Everything waiting, in order (the renderer owns the history now: each runs locally).
  mutating func drain() -> [Local] {
    defer { waiting.removeAll() }
    return waiting.flatMap(\.locals)
  }
}
