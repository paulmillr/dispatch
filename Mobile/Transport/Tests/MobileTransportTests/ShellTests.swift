#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Foundation
@testable import MobileTransport
import XCTest

/// Interactive shells on a PTY (plain SSH mode): the login shell (the account's, with the fixture's private HOME)
/// under OpenSSH's sshd.
final class ShellTests: XCTestCase {
  func testPromptAppearsWithTheRequestedTerm() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = ShellOutput(shell)
    try await output.wait("a prompt") { !$0.isEmpty }
    // Computed, so the echo of the typed line never matches.
    try await shell.write(Data("echo term=$TERM sum=$((40+2))\r".utf8))
    try await output.wait("the command's output") { $0.contains("term=xterm-256color sum=42") }
    await shell.close()
  }

  func testSttySizeFollowsResize() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = ShellOutput(shell)
    try await output.wait("a prompt") { !$0.isEmpty }
    try await shell.write(Data("stty size\r".utf8))
    try await output.wait("the opening grid") { $0.contains("24 80") }
    try await shell.resize(columns: 100, rows: 30)
    // The window change and the typed line travel separately: ask until the new grid shows.
    try await output.wait("the resized grid", asking: { try await shell.write(Data("stty size\r".utf8)) }) { $0.contains("30 100") }
    await shell.close()
  }

  func testExitStatus() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = ShellOutput(shell)
    try await output.wait("a prompt") { !$0.isEmpty }
    try await shell.write(Data("exit 3\r".utf8))
    try await output.ended()
    let status = try await shell.exitStatus()
    XCTAssertEqual(status, 3)
    do {
      try await shell.resize(columns: 90, rows: 20)
      XCTFail("a resize after the end succeeded")
    } catch { XCTAssertEqual(error as? SSHTransportError, .channelClosed) }
  }

  func testClosingTheConnectionLosesTheShell() async throws {
    let connection = try await SSHFixture.shared.connect()
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = ShellOutput(shell)
    try await output.wait("a prompt") { !$0.isEmpty }
    await connection.close()
    try await output.ended()
    do {
      _ = try await shell.exitStatus()
      XCTFail("a lost shell reported a status")
    } catch { XCTAssertEqual(error as? SSHTransportError, .channelClosed) }
  }

  /// `close()` closes the channel at once (a PTY has no end of file): the shell ends without a status and the
  /// connection stays up for the next one.
  func testCloseEndsTheShellAndKeepsTheConnection() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = ShellOutput(shell)
    try await output.wait("a prompt") { !$0.isEmpty }
    await shell.close()
    try await output.ended()
    do {
      _ = try await shell.exitStatus()
      XCTFail("a closed shell reported a status")
    } catch { XCTAssertEqual(error as? SSHTransportError, .channelClosed) }
    XCTAssertTrue(connection.isActive)
    let next = try await connection.run("echo still")
    XCTAssertEqual(next.text, "still\n")
  }

  /// Detaching closes the shell while its reader waits in `read`: neither that read nor a later write, resize or
  /// close may touch the next socket that takes the number (a new shell, another host's channel).
  func testCloseWhileReadingNeverTouchesASocketThatReusedTheNumber() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let shell = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
    let output = ShellOutput(shell)
    try await output.wait("a prompt") { !$0.isEmpty }
    let number = try XCTUnwrap(shell.descriptor.fd)
    await shell.close()
    try await output.ended()
    var pair: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
    guard pair.contains(number) else { throw XCTSkip("Another thread took the descriptor number first") }
    let other = pair[0] == number ? pair[1] : pair[0]
    var one: Int32 = 1
    setsockopt(other, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    await shell.close()
    do {
      try await shell.write(Data("typed".utf8))
      XCTFail("a write after the close succeeded")
    } catch { XCTAssertEqual(error as? SSHTransportError, .channelClosed) }
    do {
      try await shell.resize(columns: 90, rows: 20)
      XCTFail("a resize after the close succeeded")
    } catch { XCTAssertEqual(error as? SSHTransportError, .channelClosed) }
    XCTAssertEqual(Darwin.write(other, "x", 1), 1, "The unrelated socket was shut down")
    _ = fcntl(other, F_SETFL, fcntl(other, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 16)
    XCTAssertEqual(Darwin.read(other, &buffer, buffer.count), -1, "The closed shell wrote into the unrelated socket")
    _ = fcntl(number, F_SETFL, fcntl(number, F_GETFL) | O_NONBLOCK)
    XCTAssertEqual(Darwin.read(number, &buffer, buffer.count), 1)
    XCTAssertEqual(buffer[0], UInt8(ascii: "x"))
  }

  /// A refused pty-req throws what a refused exec does.
  func testRefusedTerminalIsARefusal() async throws {
    let fixture = try SSHFixture(extraConfiguration: ["PermitTTY no"])
    defer { fixture.stop() }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    do {
      _ = try await connection.shell(term: "xterm-256color", columns: 80, rows: 24)
      XCTFail("the shell opened without a terminal")
    } catch SSHTransportError.commandFailed(let status, _) {
      XCTAssertEqual(status, -1)
    }
    XCTAssertTrue(connection.isActive, "a refused channel leaves the connection up")
  }
}

/// Collects a shell's output on a task of its own, for waits with a deadline.
private final class ShellOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()
  private var finished = false
  private var failure: (any Error)?

  init(_ shell: SSHShell) {
    Task.detached { [self] in
      do {
        for try await chunk in shell { lock.withLock { data.append(chunk) } }
      } catch { lock.withLock { failure = error } }
      lock.withLock { finished = true }
    }
  }

  var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

  /// Waits until `condition` holds for everything read so far, calling `asking` (if any) every half second.
  func wait(_ what: String, timeout: Duration = .seconds(10), asking: (@Sendable () async throws -> Void)? = nil,
            until condition: (String) -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    var asked = ContinuousClock.now - .seconds(1)
    while !condition(text) {
      if let asking, ContinuousClock.now - asked >= .milliseconds(500) {
        try await asking()
        asked = .now
      }
      guard ContinuousClock.now < deadline else { throw ShellTimeout(what: what, output: text) }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  /// Waits for the iteration to end (output closed and the channel ended).
  func ended(timeout: Duration = .seconds(10)) async throws {
    let deadline = ContinuousClock.now + timeout
    while !lock.withLock({ finished }) {
      guard ContinuousClock.now < deadline else { throw ShellTimeout(what: "the end of the shell", output: text) }
      try await Task.sleep(for: .milliseconds(20))
    }
    if let failure = lock.withLock({ failure }) { throw failure }
  }
}

private struct ShellTimeout: Error, CustomStringConvertible {
  let what: String
  let output: String
  var description: String { "Timed out waiting for \(what); output so far: \(output.debugDescription)" }
}
#endif
