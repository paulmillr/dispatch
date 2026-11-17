/// The channel API as the client facade offers it (C implements the channel layer in Connection/). Session channels
/// only (RFC 4254 §6): an exec, and a login shell on a PTY. No forwarding, X11, agent or subsystem; a CHANNEL_OPEN
/// from the server is refused (administratively prohibited).
///
/// Flow control both ways: `write` suspends while the server's window or the transport's backlog is full; the window
/// the engine grants the server (`Limits.channelWindow`) is topped up only as `read` consumes, so a reader that stops
/// stops the server, never the engine's memory.

/// A terminal size in character cells (no pixel size is ever sent).
public struct TerminalSize: Sendable, Hashable {
  public var columns: UInt32
  public var rows: UInt32

  public init(columns: UInt32, rows: UInt32) {
    self.columns = columns
    self.rows = rows
  }
}

/// A chunk of an exec's output, in arrival order.
public enum ChannelOutput: Sendable, Equatable {
  case stdout([UInt8])
  /// Extended data of type stderr; any other type is a protocol error.
  case stderr([UInt8])
}

/// How a command or shell ended. Decided once, after the channel closed. The C ABI's `DMS_EXIT_*` kinds.
public enum ChannelExit: Sendable, Equatable {
  /// `exit-status` (DMS_EXIT_STATUS).
  case status(UInt32)
  /// `exit-signal` (DMS_EXIT_SIGNAL): the name without "SIG" as the server sent it (a validated name, strict),
  /// whether core was dumped, and the error message (display text: `readDisplayText` within
  /// `Limits.channelMessageBytes`, then `DisplayText.sanitize`; the language tag is ignored).
  case signal(name: String, coreDumped: Bool, message: String)
  /// The channel or connection went away without either (DMS_EXIT_LOST).
  case lost
  /// The server refused the exec request: nothing ran, and the engine closed the channel (DMS_EXIT_REFUSED).
  case refused
}

/// A command on its own session channel (`dms_exec`). Handed over as soon as the exec request is sent, without
/// waiting for the server's reply: what is written at once follows the request on the channel as far as the window
/// allows (OpenSSH grants a session channel's window only once the command started), output that arrives before the
/// reply reads as usual, and a refused request ends the channel (`exit()` is `.refused`, `read` ends).
public protocol ExecChannel: Sendable {
  /// Sends `bytes` as the command's stdin, in order, suspending while the window or backlog is full. Throws
  /// `SSHError.usage(.channelClosed)` after `finishInput` or once the channel closed, or the connection's end.
  /// Never suspends past the channel's end: a write waiting for the window when the channel closes (by either side)
  /// throws `usage(.channelClosed)`, and one waiting when the connection ends throws the connection's end.
  func write(_ bytes: [UInt8]) async throws(SSHError)

  /// Sends EOF: the command reads end of file and may still answer. Idempotent.
  func finishInput() async

  /// The next output chunk; nil once the server sent EOF or closed the channel. Throws only for the connection's
  /// end. One reader at a time. stdout and stderr come through this one stream, in the order they arrived, and
  /// nothing the server sent before its CLOSE is dropped: it stays readable after `exit()` returned. After the
  /// client's own `close()` a pending or later read returns nil at once, without waiting for the server's CLOSE.
  /// Output that arrived before the connection's end is still read, then the end is thrown (unless EOF came first).
  func read() async throws(SSHError) -> ChannelOutput?

  /// Abandons the command: closes the channel, drops unread output; `exit()` then reports what arrived before
  /// (usually `.lost`). Idempotent. Releasing the last reference to the channel closes it too.
  func close() async

  /// How the command ended; returns once the channel closed (both CHANNEL_CLOSEs, or the connection's end).
  func exit() async -> ChannelExit
}

/// A login shell on a PTY (`dms_shell_open`): `pty-req` with the TERM and size (no pixel size, no terminal modes,
/// no `env`), then `shell`, both confirmed before the channel is handed over (a refusal throws
/// `SSHError.requestRefused`). The PTY merges stderr into the output.
public protocol ShellChannel: Sendable {
  /// Terminal input, in order, suspending while the window or backlog is full. Throws as `ExecChannel.write`, and
  /// likewise never suspends past the channel's end.
  func write(_ bytes: [UInt8]) async throws(SSHError)

  /// The next output; nil once the server's side ended. Throws only for the connection's end. As
  /// `ExecChannel.read`: nothing sent before the server's CLOSE is dropped, and after the client's own `close()` a
  /// pending or later read returns nil at once.
  func read() async throws(SSHError) -> [UInt8]?

  /// Asks for a `window-change`. Changes reach the server in call order, a size superseded before it was sent is
  /// skipped (the latest wins); none is sent for the size already in effect. Throws `SSHError.usage(.channelClosed)`
  /// once the shell ended or was closed.
  func resize(_ size: TerminalSize) throws(SSHError)

  /// Ends the shell: closes the channel (a PTY has no end of file; ^D is data). The connection stays up.
  /// Idempotent; `exit()` answers at once afterwards: a status that arrived before the close, else `.lost`. Unread
  /// output is dropped. Releasing the last reference to the channel closes it too.
  func close() async

  /// How the shell ended; returns once the channel closed.
  func exit() async -> ChannelExit
}
