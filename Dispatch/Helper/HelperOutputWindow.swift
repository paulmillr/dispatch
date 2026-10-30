import Foundation

/// The app's side of `terminals.window` (helper/PROTOCOL.md, Features): the helper keeps at most 256 KB of a client's
/// terminal output unacknowledged, across all its attach subscriptions, and the client acknowledges what it handed to
/// its terminals with `terminals.ack {terminal, bytes, subscription}`. Only connections whose hello accepted the feature
/// (`HelperSession.outputWindow`, off by default) acknowledge anything; for every other connection `delivered` is a
/// lookup and nothing more.
///
/// Every `terminal.output` an attach subscription receives counts, rendered or dropped (a stale tab, a hidden gateway):
/// an unacknowledged byte would shrink the window for good. While output streams, a subscription's bytes go out in
/// batches of `batch`. The window is the client's, not a terminal's, so nothing may stay pending for long: a
/// subscription quiet for `quiet` is acknowledged whole, and so is everything once the connection's pending total
/// reaches `limit`, half the window. Otherwise several terminals that each stopped just under a batch would add up to a
/// full window, the helper would pause every multiplexer, and no further output would come to trigger an ack.
final class HelperOutputWindow: @unchecked Sendable {
  /// Bytes of one subscription acknowledged together while it streams: a quarter of the helper's 256 KB window.
  static let batch = 64 * 1024
  /// Everything pending on a connection is acknowledged once this much is: half the helper's window.
  static let limit = 128 * 1024
  /// A subscription that received nothing for this long is acknowledged whole.
  static let quiet = DispatchTimeInterval.milliseconds(100)

  /// The attach subscription output arrives on. Its request id is known once `client.attach` returns, which may be
  /// after its first output: what is pending for it waits for `identify`.
  final class Subscription: @unchecked Sendable {
    /// Guarded by `HelperOutputWindow.lock`.
    fileprivate var id: UInt64?
    fileprivate weak var window: HelperOutputWindow?

    init() {}

    func identify(_ id: UInt64) {
      let window = HelperOutputWindow.lock.withLock {
        self.id = id
        return self.window
      }
      window?.flush { $0.subscription === self }
    }
  }

  private struct Pending {
    let subscription: Subscription
    let terminal: UInt64
    var bytes: Int
    var last: DispatchTime
  }

  private struct Ack: Encodable, Sendable {
    let terminal: UInt64
    let bytes: UInt64
    let subscription: UInt64
  }

  private static let lock = NSLock()
  /// Guarded by `lock`.
  nonisolated(unsafe) private static var windows: [ObjectIdentifier: HelperOutputWindow] = [:]
  /// Acknowledgements the helper refused or that could not be sent (guarded by `lock`).
  nonisolated(unsafe) private static var failures = 0
  static var failed: Int { lock.withLock { failures } }

  private weak var connection: HelperConnection?
  /// Delivered bytes not yet acknowledged, by subscription (guarded by `lock`).
  private var pending: [ObjectIdentifier: Pending] = [:]
  private var total = 0
  private var armed = false

  private init(_ connection: HelperConnection) { self.connection = connection }

  /// `connection`'s helper accepted `terminals.window` in its hello: acknowledge its output from now on.
  static func enable(_ connection: HelperConnection) {
    lock.withLock {
      windows = windows.filter { $0.value.connection != nil }
      windows[ObjectIdentifier(connection)] = HelperOutputWindow(connection)
    }
  }

  /// An attach subscription's update was handled (output written to its terminal, or dropped): its output counts as
  /// delivered. Anything else, and output of a connection without the feature, is ignored.
  static func delivered(
    _ update: Result<HelperClient.Update, any Error>, on connection: HelperConnection, subscription: Subscription
  ) {
    guard case .success(.output(let output)) = update else { return }
    delivered(output.bytes.count, of: output.terminal, on: connection, subscription: subscription)
  }

  static func delivered(_ count: Int, of terminal: UInt64, on connection: HelperConnection, subscription: Subscription) {
    guard count > 0 else { return }
    let window: HelperOutputWindow? = lock.withLock {
      let key = ObjectIdentifier(connection)
      guard let window = windows[key] else { return nil }
      // A connection at a reused address is not the one that enabled the window.
      guard window.connection === connection else {
        windows[key] = nil
        return nil
      }
      subscription.window = window
      let now = DispatchTime.now()
      window.pending[ObjectIdentifier(subscription), default: Pending(
        subscription: subscription, terminal: terminal, bytes: 0, last: now)].bytes += count
      window.pending[ObjectIdentifier(subscription)]?.last = now
      window.total += count
      return window
    }
    guard let window else { return }
    if window.locked({ $0.total >= limit }) {
      window.flush { _ in true }
    } else {
      window.flush { $0.subscription === subscription && $0.bytes >= batch }
      window.arm()
    }
  }

  /// Delivered bytes not yet acknowledged on `connection`; nil when it acknowledges nothing (tests).
  static func pending(on connection: HelperConnection) -> Int? {
    lock.withLock {
      windows[ObjectIdentifier(connection)].flatMap { $0.connection === connection ? $0.total : nil }
    }
  }

  private func locked<T>(_ body: (HelperOutputWindow) -> T) -> T { Self.lock.withLock { body(self) } }

  /// Acknowledge the pending entries `chosen` picks whose subscription is identified.
  private func flush(_ chosen: (Pending) -> Bool) {
    let acks: [Ack] = locked { window in
      var acks: [Ack] = []
      for (key, entry) in window.pending where chosen(entry) {
        guard let id = entry.subscription.id else { continue }
        acks.append(Ack(terminal: entry.terminal, bytes: UInt64(entry.bytes), subscription: id))
        window.total -= entry.bytes
        window.pending[key] = nil
      }
      return acks
    }
    guard let connection, !acks.isEmpty else { return }
    for ack in acks {
      // Order does not matter: the helper adds them up.
      Task {
        do {
          let _: HelperClient.Empty = try await connection.request("terminals.ack", params: ack)
        } catch {
          Self.lock.withLock { Self.failures += 1 }
          print("Helper output ack failed: terminal=\(ack.terminal), subscription=\(ack.subscription), bytes=\(ack.bytes): \(error)")
        }
      }
    }
  }

  /// One timer per connection while anything is pending: acknowledges each subscription quiet for `quiet`.
  private func arm() {
    let start = locked { window -> Bool in
      // Entries waiting for their subscription's id go out when it is known (`Subscription.identify`).
      guard !window.armed, window.pending.values.contains(where: { $0.subscription.id != nil }) else { return false }
      window.armed = true
      return true
    }
    guard start else { return }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.quiet) { [weak self] in
      guard let self else { return }
      let now = DispatchTime.now()
      self.flush { entry in
        now.uptimeNanoseconds - entry.last.uptimeNanoseconds >= Self.nanoseconds(Self.quiet)
      }
      self.locked { $0.armed = false }
      self.arm()
    }
  }

  private static func nanoseconds(_ interval: DispatchTimeInterval) -> UInt64 {
    switch interval {
    case .milliseconds(let value): UInt64(value) * 1_000_000
    case .seconds(let value): UInt64(value) * 1_000_000_000
    case .microseconds(let value): UInt64(value) * 1_000
    case .nanoseconds(let value): UInt64(value)
    default: 0
    }
  }
}
