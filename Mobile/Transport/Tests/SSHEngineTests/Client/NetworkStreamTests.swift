#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import SSHEngine

/// Network.framework's stream connector against loopback listeners: nothing of an attempt outlives its `connect`.
final class NetworkStreamTests: XCTestCase {
  /// The attempt (and through it the `NWConnection`, with its parameters and protocol stack) went once the connect
  /// returned and the stream closed, long before the connect's deadline: its deadline item, cancelled but queued until
  /// its time, held the attempt for that long (every connection's network objects outlived it by the handshake
  /// timeout, 15 s in the app).
  func testAConnectedAttemptGoesWithItsStream() async throws {
    let listener = try SilentListener()
    defer { withExtendedLifetime(listener) {} }
    let before = NetworkStreamConnector.liveAttempts
    let stream = try await NetworkStreamConnector().connect(host: "127.0.0.1", port: UInt16(listener.port),
                                                              deadline: .now + .seconds(120))
    await stream.close()
    let released = try await Self.released(to: before)
    XCTAssertTrue(released, "the attempt was still alive 2 s later")
  }

  /// A refused connect releases its attempt too.
  func testARefusedAttemptIsReleased() async throws {
    let port = UInt16(try SilentListener.closedPort())
    let before = NetworkStreamConnector.liveAttempts
    do {
      _ = try await NetworkStreamConnector().connect(host: "127.0.0.1", port: port, deadline: .now + .seconds(120))
      XCTFail("connected to a closed port")
    } catch {
      XCTAssertEqual(error, .connectionRefused)
    }
    let released = try await Self.released(to: before)
    XCTAssertTrue(released, "the attempt was still alive 2 s later")
  }

  /// Whether the live attempts came back to `count` within 2 s.
  static func released(to count: Int) async throws -> Bool {
    for _ in 0..<100 {
      if NetworkStreamConnector.liveAttempts == count { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }
}
#endif
