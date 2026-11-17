import Foundation

/// A value shared between a server's thread and a test: every change goes through `update` under a lock, and a test
/// waits for a condition on it with a deadline (`wait`), without polling or sleeping. Waiters are resumed by the change
/// that satisfies them; one whose deadline passes throws `Watched.Timeout`.
final class Watched<Value: Sendable>: @unchecked Sendable {
  struct Timeout: Error, CustomStringConvertible {
    let what: String
    let last: Value
    var description: String { "timed out waiting for \(what); last value: \(last)" }
  }

  private struct Waiter {
    let satisfied: @Sendable (Value) -> Bool
    let continuation: CheckedContinuation<Value, any Error>
    var deadline: Task<Void, Never>?
  }

  private let lock = NSLock()
  private var current: Value
  private var waiters: [UInt64: Waiter] = [:]
  private var nextWaiter: UInt64 = 0

  init(_ value: Value) { current = value }

  var value: Value { lock.withLock { current } }

  /// Changes the value and resumes every waiter it now satisfies.
  func update(_ change: (inout Value) -> Void) {
    let (ready, value) = lock.withLock { () -> ([Waiter], Value) in
      change(&current)
      let ids = waiters.filter { $0.value.satisfied(current) }.map(\.key)
      return (ids.compactMap { waiters.removeValue(forKey: $0) }, current)
    }
    for waiter in ready {
      waiter.deadline?.cancel()
      waiter.continuation.resume(returning: value)
    }
  }

  /// The value once `satisfied` holds for it (at once if it already does); throws `Timeout` after `timeout`.
  @discardableResult
  func wait(_ what: String, timeout: Duration = .seconds(10), until satisfied: @escaping @Sendable (Value) -> Bool)
    async throws -> Value
  {
    try await withCheckedThrowingContinuation { continuation in
      let id = lock.withLock { () -> UInt64? in
        if satisfied(current) { return nil }
        nextWaiter += 1
        waiters[nextWaiter] = Waiter(satisfied: satisfied, continuation: continuation)
        return nextWaiter
      }
      guard let id else { return continuation.resume(returning: value) }
      let deadline = Task { [weak self] in
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        self?.expire(id, what)
      }
      // The waiter may have been resumed (and its deadline found nil) between the two locks.
      let stale = lock.withLock { () -> Bool in
        guard waiters[id] != nil else { return true }
        waiters[id]?.deadline = deadline
        return false
      }
      if stale { deadline.cancel() }
    }
  }

  private func expire(_ id: UInt64, _ what: String) {
    let (waiter, value) = lock.withLock { (waiters.removeValue(forKey: id), current) }
    waiter?.continuation.resume(throwing: Timeout(what: what, last: value))
  }
}

/// What one connection of the scripted server saw and did, in the order it happened: the client's messages and the
/// server's own (both by number, with whether the hold was in effect), the login and channel facts the layers record,
/// and how the connection ended. Plain data: a test reads it as a snapshot.
struct ServerLog: Sendable, CustomStringConvertible {
  struct Traffic: Sendable, Equatable {
    /// The client sent it (else the server queued it).
    let inbound: Bool
    let number: UInt8
    /// Whether the server's hold was in effect (for the server's own: whether it was held back).
    let held: Bool
  }

  /// A signed publickey request, verified or not.
  struct Signature: Sendable, Equatable {
    let algorithm: String
    let keyBlob: [UInt8]
    /// The signature is valid over the session id and the request.
    let verified: Bool
    /// The server took the login.
    let accepted: Bool
    /// It arrived while the hold was in effect.
    let whileHeld: Bool
  }

  /// A userauth request, by method (`none`, `password`, `publickey` with and without signature as `publickey-query`
  /// and `publickey-signed`, `keyboard-interactive`), and what the server answered (`52`, `51`, `60`).
  struct Login: Sendable, Equatable {
    let user: String
    let method: String
    var answer: UInt8?
  }

  var traffic: [Traffic] = []
  var logins: [Login] = []
  var signatures: [Signature] = []
  /// Each keyboard-interactive INFO_RESPONSE, its answers in order.
  var keyboardResponses: [[String]] = []
  /// What session channels asked for, in order: `pty <term> <cols>x<rows> <px>x<px> modes=<n>`, `shell`,
  /// `env <name>`, `resize <cols>x<rows> <px>x<px>`, `close` (a shell channel's close from the client).
  var terminal: [String] = []
  /// Exec requests' commands, in order.
  var commands: [String] = []
  /// Channels opened, and the client's announced window and maximum packet of each.
  var channels: [(window: UInt32, maximumPacket: UInt32)] = []
  /// Things the client did that the RFCs forbid (data past the window, an unknown channel): the server records them
  /// and goes on as a lenient server would.
  var violations: [String] = []
  /// Completed key exchanges (the first included); `rekeysStartedByServer` of them the server began.
  var exchanges = 0
  var rekeysStartedByServer = 0
  /// Whether the hold is in effect now, and whether it ever was.
  var holding = false
  var held = false
  /// Set once the connection's thread finished (the client closed, or an error).
  var ended = false
  /// Why the server gave up on the connection (a protocol error it could not go on from), if it did.
  var failure: String?
  var disconnectReason: UInt32?

  func received(_ number: UInt8) -> [Traffic] { traffic.filter { $0.inbound && $0.number == number } }
  func sent(_ number: UInt8) -> [Traffic] { traffic.filter { !$0.inbound && $0.number == number } }
  /// The verified signatures' algorithms, in order.
  var verifiedAlgorithms: [String] { signatures.filter(\.verified).map(\.algorithm) }

  /// The window changes the server saw, as (cols, rows).
  var resizes: [(Int, Int)] {
    terminal.compactMap { line in
      guard line.hasPrefix("resize ") else { return nil }
      let grid = line.dropFirst("resize ".count).split(separator: " ")[0].split(separator: "x")
      guard grid.count == 2, let columns = Int(grid[0]), let rows = Int(grid[1]) else { return nil }
      return (columns, rows)
    }
  }

  var description: String {
    "traffic \(traffic.map { "\($0.inbound ? "<" : ">")\($0.number)\($0.held ? "h" : "")" }.joined(separator: " ")); "
      + "logins \(logins); signatures \(signatures.map(\.algorithm)); terminal \(terminal); commands \(commands); "
      + "violations \(violations); exchanges \(exchanges); ended \(ended); failure \(failure ?? "none")"
  }
}
