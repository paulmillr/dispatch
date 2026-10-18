#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Foundation
import MobileTransport
import XCTest

/// Requirement 5: the helper's stdio session on an exec channel, consumed by Dispatch/Helper's
/// HelperConnection and HelperTransport exactly as the Mac uses them with a Process's pipes.
final class HelperChannelTests: XCTestCase {
  static let realHelpers = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/helper-rust/bin")

  /// Raw bytes through `cat`: both directions at once, larger than every buffer on the way, then EOF
  /// from our side ends the remote command, whose EOF reaches our read handle.
  func testCatEchoWithBackpressureAndEOF() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let channel = try await HelperChannel.open(on: connection, command: "exec cat")
    let size = 24 << 20
    let payload: Data = {
      var bytes = Data(count: size)
      for index in stride(from: 0, to: size, by: 4096) { bytes[index] = UInt8(truncatingIfNeeded: index >> 12) }
      return bytes
    }()
    let start = ContinuousClock.now
    let writer = Task.detached { [write = channel.write, payload] in
      for offset in stride(from: 0, to: size, by: 1 << 20) {
        try write.write(contentsOf: payload.subdata(in: offset..<min(offset + (1 << 20), size)))
      }
      // One socket carries both directions: half-close it (EOF to cat) and keep reading.
      _ = shutdown(write.fileDescriptor, SHUT_WR)
    }
    let echoed = try await Task.detached { [read = channel.read] in
      var echoed = Data()
      while let chunk = try read.read(upToCount: 1 << 16), !chunk.isEmpty { echoed.append(chunk) }
      try read.close()
      return echoed
    }.value
    try await writer.value
    let elapsed = seconds(ContinuousClock.now - start)
    XCTAssertEqual(echoed.count, size)
    XCTAssertTrue(echoed == payload)
    let status = await channel.exitStatus()
    XCTAssertEqual(status, 0)
    report(String(format: "pipe bridge cat echo 24 MiB each way: %.2f s, %.1f MB/s per direction", elapsed, Double(size) / elapsed / 1e6))
  }

  /// `close()` ends this channel's socket only: after its consumer closed the handle (HelperTransport does when its
  /// connection ends), the number goes to the next socket opened, another host's channel, which it must not cut.
  func testCloseNeverShutsDownASocketThatReusedTheHandlesNumber() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let channel = try await HelperChannel.open(on: connection, command: "exec cat")
    let number = channel.read.fileDescriptor
    try channel.read.close()
    var pair: [Int32] = [-1, -1]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
    defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
    guard pair.contains(number) else { throw XCTSkip("Another thread took the descriptor number first") }
    let other = pair[0] == number ? pair[1] : pair[0]
    var one: Int32 = 1
    setsockopt(other, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    await channel.close()
    XCTAssertEqual(Darwin.write(other, "x", 1), 1, "The unrelated socket was shut down")
    var byte: UInt8 = 0
    XCTAssertEqual(Darwin.read(number, &byte, 1), 1)
    XCTAssertEqual(byte, UInt8(ascii: "x"))
  }

  /// The remote side ending first (exit) closes our read handle after its last bytes.
  func testRemoteExitEndsReadHandle() async throws {
    let connection = try await SSHFixture.shared.connect()
    defer { Task { await connection.close() } }
    let channel = try await HelperChannel.open(on: connection, command: "printf done; echo oops >&2; exit 3")
    let read = channel.read
    let bytes = try await Task.detached { try read.readToEnd() ?? Data() }.value
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "done")
    let status = await channel.exitStatus()
    XCTAssertEqual(status, 3)
    let stderr = await channel.stderr()
    XCTAssertEqual(stderr, "oops\n")
    // Writing after the remote went away fails instead of raising SIGPIPE.
    try? await Task.sleep(for: .milliseconds(100))
    XCTAssertThrowsError(try channel.write.write(contentsOf: Data(repeating: 0, count: 1 << 20)))
  }

  /// The real helper, installed by HelperBootstrap, greets HelperConnection with the schema id this
  /// checkout's HelperBinary.swift was generated with.
  func testHelloWithRealHelper() async throws {
    guard FileManager.default.fileExists(atPath: Self.realHelpers.appendingPathComponent("darwin-universal").path) else {
      throw XCTSkip("No helper build at \(Self.realHelpers.path) (scripts/build-ssh-helper.py --build-only)")
    }
    let fixture = try SSHFixture()
    defer { fixture.stop() }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let installed = try await HelperBootstrap.install(on: connection, binaries: Self.realHelpers)
    let start = ContinuousClock.now
    // The iPhone grant: the Mac's full profile with hooks (docs/ios-helper-spike.md on `mobile`).
    let capabilities = "agent.events,agent.inspect,agent.pi,agent.pi.configure,agent.queue,agent.side,agent.submit,agent.version,"
      + "backend.register,cancel,events,file.read,file.text,herdr.rpc,herdr.start,herdr.terminal,hooks.configure,host.identity,"
      + "input.window,shell.lifecycle,stats.ping,stats.processes,stats.sample,tmux.pane"
    let channel = try await HelperChannel.open(
      on: connection, command: HelperBootstrap.launchCommand(installed, capabilities: capabilities))
    let helper = HelperConnection(read: channel.read, write: channel.write)
    let info: Hello
    do {
      info = try await helper.request("hello", params: [String: String]())
    } catch {
      let stderr = await channel.stderr()
      XCTFail("hello failed: \(error); helper stderr: \(stderr)")
      throw error
    }
    let hello = seconds(ContinuousClock.now - start)
    XCTAssertEqual(info.version, HelperBinary.version, "schema id")
    XCTAssertEqual(info.os, "macos")
    XCTAssertEqual(info.account?.uid, getuid())
    let limit = try XCTUnwrap(info.frame_limit), kind = try XCTUnwrap(info.chunk_kind), chunk = try XCTUnwrap(info.chunk_limit)
    try await helper.configure(limit: limit, chunkKind: kind, chunkLimit: chunk, ops: info.ops)
    if info.ops.contains("multiplexers.list") {
      let multiplexers: [Multiplexer] = try await helper.request("multiplexers.list", params: [String: String]())
      XCTAssertFalse(multiplexers.isEmpty)
      report("helper multiplexers over a pure stdio channel: " + multiplexers.map(\.name).joined(separator: ", "))
    }
    report(String(format: "helper channel open + hello: %.0f ms (ops: %d)", hello * 1000, info.ops.count))
    // EOF on stdin is the helper's orderly shutdown. Closing the connection closes only its handle: the channel keeps
    // a second descriptor of the socket (`HelperChannel.control`), so the EOF comes from `channel.close()`, as the app's
    // link closes its SSH session. (Awaiting the exit after `helper.close()` alone waited forever.)
    helper.close()
    await channel.close()
    let status = await Self.within(.seconds(10)) { await channel.exitStatus() }
    XCTAssertEqual(status, .some(0), "the helper exits on EOF")
  }

  /// `body`'s value, or nil when it takes longer than `limit` (a hang fails the test instead of the run).
  static func within<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
      group.addTask { await body() }
      group.addTask {
        try? await Task.sleep(for: limit)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  struct Hello: Decodable, Sendable {
    struct Account: Decodable, Sendable { let uid: UInt32; let home: String }
    let version: UInt64
    let os: String
    let arch: String
    let ops: [String]
    let frame_limit: UInt32?
    let chunk_kind: UInt8?
    let chunk_limit: UInt32?
    let account: Account?
  }

  struct Multiplexer: Decodable, Sendable {
    let mux: UInt64
    let name: String
  }
}
#endif
