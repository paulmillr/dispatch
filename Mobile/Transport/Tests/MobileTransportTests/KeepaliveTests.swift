#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Foundation
import MobileTransport
import XCTest

/// A silent server (frozen, socket still open, as after a network drop) ends the connection through the keepalives of
/// the engine `SSHTransportEngine.preferred` names (the Swift engine, or russh with `DISPATCH_SSH_ENGINE=russh` in a
/// `DISPATCH_RUSSH` build), which
/// `HostConnection` then sees as a loss. At 1 s × 2 the end is due 3 s after the server's last packet; the test only
/// checks it comes within 15 s, and reports the time it took.
final class KeepaliveTests: XCTestCase {
  func testSilentServerIsADisconnect() async throws {
    let fixture = try SSHFixture()
    defer { fixture.stop() }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let connection = try await SSHConnection.connect(
      to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust, keepalive: .seconds(1), keepaliveMax: 2)
    let probe = try await connection.run("echo up")
    XCTAssertEqual(probe.text, "up\n")
    let frozen = fixture.freezeSessions()
    XCTAssertFalse(frozen.isEmpty, "found the per-connection sshd")
    defer { fixture.thaw(frozen) }
    let start = ContinuousClock.now
    let ended = await withTaskGroup(of: Bool.self) { group in
      group.addTask { await connection.closed(); return true }
      group.addTask { try? await Task.sleep(for: .seconds(15)); return false }
      defer { group.cancelAll() }
      return await group.next()!
    }
    XCTAssertTrue(ended, "keepalives noticed the silent server")
    XCTAssertFalse(connection.isActive)
    report(String(format: "silent server detected after %.1f s (keepalive 1 s, max 2): %@",
                  seconds(ContinuousClock.now - start), connection.endReason?.localizedDescription ?? "?"))
  }
}
#endif
