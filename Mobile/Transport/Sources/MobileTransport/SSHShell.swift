import DispatchMobileSSHCore
import Foundation

/// An interactive login shell on its own session channel with a PTY (`SSHConnection.shell`). Like `SSHExec`, the
/// engine hands over one end of a socketpair and pumps it with backpressure; the PTY merges stdout and stderr, so
/// there is one output stream. Iterate the shell for output (each `next()` is one read; the sequence ends when the
/// server's side ends, after which `exitStatus()` says how), `write` keystrokes, `resize` on layout changes.
/// Unlike an exec there is no end of input: `close()` closes the channel (sshd hangs the shell up).
public final class SSHShell: AsyncSequence, Sendable {
  /// PTY output: stdout and stderr merged by the server.
  public typealias Element = Data

  private let state: ExecState
  let descriptor: Descriptor
  private let control: ShellHandle

  static func start(term: String, columns: Int, rows: Int, on session: SessionHandle) async throws -> SSHShell {
    let state = ExecState()
    let pointer = term.withCString { term in
      dms_shell_open(session.pointer, term, cells(columns), cells(rows), Engine.retain(state), { context, fd, code, message in
        let state = Engine.borrow(context, as: ExecState.self)
        if fd >= 0 {
          state.started.finish(.success(fd))
        } else {
          state.started.finish(.failure(Engine.error(code, message)))
          // No `exited` follows a failed start: release the context here.
          _ = Engine.release(context, as: ExecState.self)
        }
      }, { context, kind, status, signal in
        Engine.release(context, as: ExecState.self).exited(kind: kind, status: status, signal: signal.map { String(cString: $0) } ?? "")
      })
    }
    let control = ShellHandle(pointer)
    let fd = try await state.started.value
    return SSHShell(state: state, fd: fd, control: control)
  }

  private init(state: ExecState, fd: Int32, control: ShellHandle) {
    self.state = state
    descriptor = Descriptor(fd)
    self.control = control
  }

  /// Writes input (keystrokes, pastes); suspends while the socket (and so the SSH window) is full.
  public func write(_ data: Data) async throws {
    try await descriptor.write(data)
  }

  /// Sends the new grid to the server (`window-change`, no pixel size). Throws `channelClosed` once the shell ended
  /// or was closed; the server sends no answer, so a change racing the end is lost silently.
  public func resize(columns: Int, rows: Int) async throws {
    guard descriptor.fd != nil, state.finished == nil else { throw SSHTransportError.channelClosed }
    dms_shell_resize(control.pointer, cells(columns), cells(rows))
  }

  /// Status when the shell ended by exit; 128 on a signal; throws `SSHTransportError.channelClosed` when the channel
  /// or connection was lost before an exit status (same convention as `SSHExec`).
  public func exitStatus() async throws -> Int32 {
    switch await state.exit {
    case .status(let status): return Int32(bitPattern: status)
    case .signal: return 128
    case .lost: throw SSHTransportError.channelClosed
    }
  }

  /// Closes the socket, which closes the channel at once. `exitStatus()` then reports what the server sent before
  /// its close, if anything.
  public func close() async {
    descriptor.close()
  }

  public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
    let shell: SSHShell
    /// The next output chunk; nil once the output ended and the channel closed (then `exitStatus()` answers).
    public mutating func next() async throws -> Data? {
      if !shell.state.stdoutEnded, let data = try await shell.descriptor.read() {
        if !data.isEmpty { return data }
        shell.state.stdoutEnded = true
      }
      _ = await shell.state.exit
      return nil
    }
  }

  public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(shell: self) }
}

extension SSHConnection {
  /// Opens a session channel with a PTY of `columns` x `rows` (`term` is sent as TERM; no terminal modes and no
  /// environment) and starts the login shell on it. A refused pty-req or shell request throws what a refused exec
  /// does (`SSHTransportError.commandFailed(status: -1, …)`).
  public func shell(term: String, columns: Int, rows: Int) async throws -> SSHShell {
    try await SSHShell.start(term: term, columns: columns, rows: rows, on: session)
  }
}

/// The engine's shell handle (for window changes); freed with the shell. Freeing never closes the channel.
final class ShellHandle: @unchecked Sendable {
  let pointer: OpaquePointer?
  init(_ pointer: OpaquePointer?) { self.pointer = pointer }
  deinit { dms_shell_free(pointer) }
}

/// A grid dimension for the engine: at least one cell.
private func cells(_ count: Int) -> UInt32 { UInt32(clamping: Swift.max(count, 1)) }
