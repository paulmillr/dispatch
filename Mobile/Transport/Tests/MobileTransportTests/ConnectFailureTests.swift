import Foundation
import MobileTransport
import XCTest

/// What a failed TCP connection says (a bad network, a mistyped address, SSH off): the engine's kind of failure,
/// named with the endpoint and what usually fixes it.
final class ConnectFailureTests: XCTestCase {
  private struct NeverAsked: HostKeyTrust {
    func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
      XCTFail("No host key without a connection")
      return .reject
    }
  }

  private func failure(_ host: String, port: Int) async -> SSHTransportError? {
    do {
      let connection = try await SSHConnection.connect(
        to: SSHEndpoint(host: host, port: port, username: "sam"), credentials: [], trust: NeverAsked(), timeout: .seconds(10))
      await connection.close()
      return nil
    } catch {
      return error as? SSHTransportError
    }
  }

  func testAClosedPortIsRefusedOnThatPort() async throws {
    let port = try closedLoopbackPort()
    let error = await failure("127.0.0.1", port: port)
    XCTAssertEqual(error, .connectFailed(.refused, host: "127.0.0.1", port: port))
    XCTAssertEqual(error?.errorDescription?.contains("port \(port)"), true)
  }

  func testANameThatDoesNotResolveIsNotFound() async throws {
    // RFC 6761: .invalid never resolves.
    let error = await failure("dispatch-test.invalid", port: 22)
    XCTAssertEqual(error, .connectFailed(.hostNotFound, host: "dispatch-test.invalid", port: 22))
    XCTAssertEqual(error?.errorDescription, "Can’t find dispatch-test.invalid. Check the address.")
  }

  func testDescriptionsNameTheLikelyFix() {
    func text(_ failure: SSHConnectFailure, _ host: String, _ port: Int = 22) -> String {
      SSHTransportError.connectFailed(failure, host: host, port: port).errorDescription ?? ""
    }
    // Tailscale's names (MagicDNS short and full) and its 100.64.0.0/10 addresses.
    XCTAssertEqual(text(.hostNotFound, "studio.tail3f.ts.net"), "Can’t find studio.tail3f.ts.net. Check the name, and that Tailscale is on.")
    XCTAssertTrue(text(.hostNotFound, "studio").contains("Tailscale"))
    XCTAssertTrue(text(.noAnswer, "100.101.2.3").contains("Tailscale is on"))
    XCTAssertFalse(text(.noAnswer, "example.com").contains("Tailscale"))
    // iOS answers "no route" for a LAN host when Local Network access is denied.
    for host in ["192.168.1.5", "10.0.0.2", "172.20.1.1", "studio.local"] {
      XCTAssertTrue(text(.unreachable, host).contains("Local Network"), host)
    }
    XCTAssertFalse(text(.unreachable, "203.0.113.9").contains("Local Network"))
    XCTAssertEqual(text(.refused, "example.com", 2222),
                   "example.com refused the connection on port 2222. Check that SSH (Remote Login on a Mac) is on and the port is right.")
  }
}
