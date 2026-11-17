/// The byte stream under the engine: one TCP connection. Only the driver touches it (one read loop and one writer at
/// a time; a read and a write may be in flight together). The app's implementation is Network.framework's; tests use
/// an in-memory pair. Nothing about SSH is known here: the stream moves bytes and reports how it failed.
public protocol ByteStream: Sendable {
  /// The next bytes from the peer, at least 1 and at most `maximum`; empty once the peer closed its side (EOF), and
  /// empty for every read after that. Throws `SSHError.closed(.connectionLost)` on a reset, `.network` on another
  /// failure, `.cancelled` when the calling task was cancelled.
  func read(maximum: Int) async throws(SSHError) -> [UInt8]

  /// Writes all of `bytes`, returning once the stream took them (backpressure: the driver writes no faster than the
  /// network drains). Throws as `read`; after `close` it throws `.closed(.byClient)`.
  func write(_ bytes: [UInt8]) async throws(SSHError)

  /// Closes both directions at once: a read or write in flight returns (EOF, or throws). Idempotent.
  func close() async
}

/// Opens the TCP connection a session runs on.
public protocol StreamConnector: Sendable {
  /// Resolves `host` and connects to `port`, giving up at `deadline` with the stage that was slow:
  /// `SSHError.timedOut(.lookup)` while resolving, `.noAnswer` while connecting. Other failures:
  /// `.hostNotFound` (no address), `.connectionRefused`, `.unreachable` (no route, or Local Network access denied),
  /// `.network` (anything else, the OS's text), `.cancelled` (the calling task was cancelled). TCP_NODELAY is set.
  func connect(host: String, port: UInt16, deadline: ContinuousClock.Instant) async throws(SSHError) -> any ByteStream
}
