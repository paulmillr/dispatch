#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Foundation
@testable import MobileTransport
import XCTest

/// Requirement 3: exec channels with streamed stdin, stdout/stderr and exit status.
final class ExecTests: XCTestCase {
  func testUnameAndPrivateHome() async throws {
    let fixture = SSHFixture.shared
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let uname = try await connection.run("uname -s; uname -m")
    XCTAssertEqual(uname.status, 0)
    XCTAssertEqual(uname.text, "Darwin\n" + (Self.machine) + "\n")
    let home = try await connection.run("cd -P \"$HOME\" && pwd")
    XCTAssertEqual(home.text.trimmingCharacters(in: .newlines), fixture.resolvedRoot + "/home")
  }

  /// A handed-over exec (the helper's channel, read by HelperConnection) is never iterated: what the host writes to
  /// stderr must not pile up for an iterator for as long as the connection lasts.
  func testAHandedOverExecQueuesNoStderr() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let exec = try await connection.exec("head -c 300000 /dev/zero >&2; printf done; cat >/dev/null")
    let fd = try XCTUnwrap(exec.takeFileDescriptor())
    defer { Darwin.close(fd) }
    // stdout after the stderr: once "done" is read every stderr chunk went through the engine's callback.
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !output.elementsEqual(Data("done".utf8)) {
      let count = read(fd, &buffer, buffer.count)
      guard count > 0 else { return XCTFail("stdout ended early") }
      output.append(contentsOf: buffer[..<count])
    }
    var queued = 0
    while let chunk = exec.state.nextStderr() { queued += chunk.count }
    XCTAssertEqual(queued, 0)
    XCTAssertEqual(exec.state.collectedStderr.count, 65_536, "The first 64 KiB stay for error messages")
  }

  func testStderrAndExitStatus() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let result = try await connection.run("printf out; printf err >&2; exit 7")
    XCTAssertEqual(result.status, 7)
    XCTAssertEqual(result.text, "out")
    XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
  }

  func testStreamedStdinEcho() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let exec = try await connection.exec("cat")
    var received = Data()
    for line in ["one\n", "two\n", "three\n"] {
      try await exec.write(Data(line.utf8))
      // Each line comes back before the next is sent: stdin is streamed, not buffered to EOF.
      while received.count < (["one\n", "two\n", "three\n"].prefix { $0 != line }.joined() + line).utf8.count {
        var iterator = exec.makeAsyncIterator()
        guard case .stdout(let data)? = try await iterator.next() else { return XCTFail("stream ended") }
        received.append(data)
      }
    }
    try await exec.finishInput()
    for try await chunk in exec { if case .stdout(let data) = chunk { received.append(data) } }
    XCTAssertEqual(String(decoding: received, as: UTF8.self), "one\ntwo\nthree\n")
    let status = try await exec.exitStatus()
    XCTAssertEqual(status, 0)
  }

  static var machine: String {
    var name = utsname()
    uname(&name)
    return withUnsafeBytes(of: name.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
}
#endif
