#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import Foundation
import MobileTransport

/// Trusts exactly the fixture's host key.
struct FixtureTrust: HostKeyTrust {
  let expected: String
  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
    key.openSSH == expected ? .trust : .mismatch(expected: expected)
  }
}

extension SSHFixture {
  var endpoint: SSHEndpoint { SSHEndpoint(host: "127.0.0.1", port: port, username: user) }
  var trust: FixtureTrust { FixtureTrust(expected: hostPublicKey) }

  func connect(_ credentials: [SSHCredential]? = nil) async throws -> SSHConnection {
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    return try await SSHConnection.connect(to: endpoint, credentials: credentials ?? [.key(key)], trust: trust)
  }
}
#endif
