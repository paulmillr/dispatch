#if os(iOS)
import Foundation
import MobileTransport
import XCTest

/// From the simulator: bootstrap the real helper onto the Mac fixture and greet it over the stdio channel
/// with HelperConnection, as the iPhone app will.
final class SimulatorHelperTests: XCTestCase {
  struct Profile: Decodable { let host: String; let port: Int; let user: String; let hostKey: String; let keyFile: String; let helpers: String }
  struct Trust: HostKeyTrust {
    let expected: String
    func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision { key.openSSH == expected ? .trust : .mismatch(expected: expected) }
  }
  struct Hello: Decodable, Sendable { let version: UInt64; let ops: [String] }

  func testHelloFromTheSimulator() async throws {
    guard let path = ProcessInfo.processInfo.environment["DMS_FIXTURE"] else { throw XCTSkip("No Mac fixture") }
    let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let key = try SSHKey.openSSH(Data(contentsOf: URL(fileURLWithPath: profile.keyFile)))
    let connection = try await SSHConnection.connect(
      to: SSHEndpoint(host: profile.host, port: profile.port, username: profile.user), credentials: [.key(key)],
      trust: Trust(expected: profile.hostKey))
    defer { Task { await connection.close() } }
    let installed = try await HelperBootstrap.install(on: connection, binaries: URL(fileURLWithPath: profile.helpers))
    let channel = try await HelperChannel.open(
      on: connection, command: HelperBootstrap.launchCommand(installed, capabilities: "host.identity,stats.ping,events,cancel"))
    let helper = HelperConnection(read: channel.read, write: channel.write)
    let hello: Hello = try await helper.request("hello", params: [String: String]())
    XCTAssertEqual(hello.version, HelperBinary.version)
    helper.close()
    let status = await channel.exitStatus()
    XCTAssertEqual(status, 0)
    report("simulator: helper hello over the stdio channel, \(hello.ops.count) ops")
  }
}
#endif
