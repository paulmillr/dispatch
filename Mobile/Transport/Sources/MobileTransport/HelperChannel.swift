import Foundation

/// The helper's `--stdio` session on an exec channel, exposed as the read/write file handle pair that
/// `HelperConnection(read:write:)` (Dispatch/Helper) consumes, unmodified. Both are one `FileHandle` on
/// the engine's socketpair (HelperTransport drives a single descriptor for both directions); the engine
/// pumps it to and from the SSH channel with backpressure and EOF in both directions.
public final class HelperChannel: Sendable {
  /// The helper's stdout. Owned by its consumer (HelperTransport closes it).
  public let read: FileHandle
  /// The helper's stdin: the same handle as `read`.
  public var write: FileHandle { read }
  private let exec: SSHExec
  /// A second descriptor of the same socket, ours alone: `close()` shuts the socket down through it. The handle's own
  /// number is closed by its consumer whenever its transport ends, and the system hands that number to the next
  /// socket opened (another host's channel), which a shutdown by number would cut.
  private let control: Descriptor?

  /// Starts `command` (see `HelperBootstrap.launchCommand`) on a new session channel of `connection`.
  public static func open(on connection: SSHConnection, command: String) async throws -> HelperChannel {
    let exec = try await connection.exec(command)
    guard let fd = exec.takeFileDescriptor() else { throw SSHTransportError.channelClosed }
    return HelperChannel(exec: exec, fd: fd)
  }

  private init(exec: SSHExec, fd: Int32) {
    self.exec = exec
    let control = dup(fd)
    self.control = control >= 0 ? Descriptor(control) : nil
    read = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  /// The helper's exit status, once its channel closed (nil if it ended by a signal or the connection dropped).
  public func exitStatus() async -> Int32? {
    try? await exec.exitStatus()
  }

  /// The first 64 KiB the helper wrote to stderr.
  public func stderr() async -> String { exec.stderr }

  /// Ends the session: shuts the socket down both ways (EOF to the helper; the transport reads end of
  /// file). The handle's descriptor stays with its owner. Calling it again does nothing.
  public func close() async {
    control?.close()
  }
}
