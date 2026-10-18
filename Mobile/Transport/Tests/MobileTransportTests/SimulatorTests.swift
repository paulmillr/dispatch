#if os(iOS)
import Foundation
import MobileTransport
import XCTest

/// The iPhone build of the engine, in the simulator, against the Mac's loopback sshd (the simulator shares
/// the Mac's network). The Mac side: `scripts/mobile-ssh-fixture.py start /tmp/sim-<n>`, then
/// `TEST_RUNNER_DMS_FIXTURE=<its profile.json> xcodebuild test … -destination 'platform=iOS Simulator,…'`.
struct SimulatorFixture: Decodable {
  let host: String
  let port: Int
  let user: String
  let hostKey: String
  let keyFile: String
  let helpers: String
  let home: String

  static func load() throws -> SimulatorFixture {
    guard let path = ProcessInfo.processInfo.environment["DMS_FIXTURE"] else {
      throw XCTSkip("No Mac fixture (TEST_RUNNER_DMS_FIXTURE=<profile.json>, scripts/mobile-ssh-fixture.py)")
    }
    return try JSONDecoder().decode(SimulatorFixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  }

  var endpoint: SSHEndpoint { SSHEndpoint(host: host, port: port, username: user) }

  struct Trust: HostKeyTrust {
    let expected: String
    func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision { key.openSSH == expected ? .trust : .mismatch(expected: expected) }
  }

  func connect() async throws -> SSHConnection {
    let key = try SSHKey.openSSH(Data(contentsOf: URL(fileURLWithPath: keyFile)))
    return try await SSHConnection.connect(to: endpoint, credentials: [.key(key)], trust: Trust(expected: hostKey))
  }
}

final class SimulatorTests: XCTestCase {
  func testConnectsFromTheSimulatorToTheMac() async throws {
    let fixture = try SimulatorFixture.load()
    var latencies: [Double] = []
    for _ in 0..<10 {
      let connection = try await fixture.connect()
      latencies.append(seconds(connection.timings.total) * 1000)
      await connection.close()
    }
    let connection = try await fixture.connect()
    defer { Task { await connection.close() } }
    let uname = try await connection.run("uname -s; echo $HOME")
    XCTAssertEqual(uname.text, "Darwin\n" + fixture.home + "\n")

    // 32 MiB through cat and back at once: the socketpair pump in the iOS build.
    let size = 32 << 20
    let exec = try await connection.exec("cat")
    let chunk = Data(repeating: 0x5a, count: 1 << 20)
    let start = ContinuousClock.now
    let writer = Task {
      for _ in 0..<(size >> 20) { try await exec.write(chunk) }
      try await exec.finishInput()
    }
    var received = 0
    for try await output in exec { if case .stdout(let data) = output { received += data.count } }
    try await writer.value
    let elapsed = seconds(ContinuousClock.now - start)
    XCTAssertEqual(received, size)
    let status = try await exec.exitStatus()
    XCTAssertEqual(status, 0)
    report(String(format: "simulator: connect+auth median %.1f ms; cat echo 32 MiB each way %.1f MB/s per direction",
                  latencies.sorted()[latencies.count / 2], Double(size) / elapsed / 1e6))
  }
}
#endif
