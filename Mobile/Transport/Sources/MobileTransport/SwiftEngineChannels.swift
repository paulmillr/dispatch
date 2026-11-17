import Foundation
import SSHEngine

/// Pumps an open channel through its socketpair as the seam states it (`EngineSession`, Channels), with two tasks and
/// no thread of their own: input (the caller's writes into the channel) and output (the channel into the caller's
/// reads). Each direction takes the next chunk only once the last one was taken by the other side, so backpressure
/// holds both ways: a caller that stops reading stops `read()` on the channel (whose window then stops the server),
/// and a channel whose window is shut stops the reads of the socket (whose buffers then block the caller's writes).
enum SwiftEngineBridge {
  /// The exec's refusal text, the user's ("The host refused to run the helper: …"); russh's too.
  static let refusedExec = "the server refused the exec request"

  /// Exec: stdout to the socket, stderr to `events` as it comes, the caller's end of input as EOF; then, once the
  /// channel closed, the socket closed and `exited` as the last call.
  static func exec(_ channel: any ExecChannel, socket: SwiftEngineSocket, events: any EngineChannelEvents) async {
    let input = Task {
      while true {
        switch await socket.read() {
        case .data(let bytes):
          // Fails once the channel closed or the connection ended: nobody takes more input.
          do { try await channel.write(bytes) } catch { return }
        case .end:
          // EOF after what was written; the channel stays open for output.
          return await channel.finishInput()
        case .closed:
          return
        }
      }
    }
    pumping: while true {
      let output: ChannelOutput?
      do { output = try await channel.read() } catch { break }
      switch output {
      case .stdout(let bytes)?:
        guard await socket.write(bytes) else {
          // The caller closed its end: nobody reads the rest, so the channel goes (`exited` with what came before).
          await channel.close()
          break pumping
        }
      case .stderr(let bytes)?:
        events.stderr(Data(bytes))
      case nil:
        // The remote's EOF (or the channel's end): the caller reads end of file after all the data.
        socket.finishWriting()
        break pumping
      }
    }
    let exit = await channel.exit()
    await socket.close()
    input.cancel()
    events.exited(Self.exit(exit))
  }

  /// Shell: output to the socket; the caller's end of input closes the channel (a PTY has no end of file). Returns how
  /// the shell ended once the channel closed and the socket is closed; the caller reports it.
  static func shell(_ channel: any ShellChannel, socket: SwiftEngineSocket) async -> EngineExit {
    let input = Task {
      while true {
        switch await socket.read() {
        case .data(let bytes):
          do { try await channel.write(bytes) } catch { return }
        case .end:
          return await channel.close()
        case .closed:
          return
        }
      }
    }
    while true {
      let output: [UInt8]?
      do { output = try await channel.read() } catch { break }
      guard let output else {
        socket.finishWriting()
        break
      }
      guard await socket.write(output) else {
        await channel.close()
        break
      }
    }
    let exit = await channel.exit()
    await socket.close()
    input.cancel()
    // A shell's requests were confirmed before it opened: the engine reports no refusal for it.
    return exit == .refused ? .lost : Self.exit(exit)
  }

  static func exit(_ exit: ChannelExit) -> EngineExit {
    switch exit {
    case .status(let status): .status(status)
    case .signal(let name, _, _): .signal(name)
    case .lost: .lost
    case .refused: .refused(refusedExec)
    }
  }
}

/// A shell's control (`EngineShell`): window changes in call order, under one lock, onto the channel once it opened.
/// Before that the latest size waits (sent once open unless it is the opening size); after the end or a failed open
/// they are dropped. The channel coalesces and skips the size in effect (`ShellChannel.resize`). Releasing this
/// never closes the channel.
final class SwiftEngineShellControl: EngineShell, @unchecked Sendable {
  private enum State {
    case opening(wanted: TerminalSize?)
    case open(any ShellChannel)
    case ended
  }

  private let lock = NSLock()
  private let opening: TerminalSize
  private var state = State.opening(wanted: nil)

  init(opening: TerminalSize) { self.opening = opening }

  func resize(columns: UInt32, rows: UInt32) {
    let size = TerminalSize(columns: max(columns, 1), rows: max(rows, 1))
    lock.withLock {
      switch state {
      case .opening: state = .opening(wanted: size)
      // Never fails but once the channel ended, when the change is dropped as the seam says.
      case .open(let channel): try? channel.resize(size)
      case .ended: break
      }
    }
  }

  func attach(_ channel: any ShellChannel) {
    lock.withLock {
      guard case .opening(let wanted) = state else { return }
      if let wanted, wanted != opening { try? channel.resize(wanted) }
      state = .open(channel)
    }
  }

  /// The shell ended or did not open: later changes are dropped, and the channel is no longer held.
  func end() {
    lock.withLock { state = .ended }
  }
}
