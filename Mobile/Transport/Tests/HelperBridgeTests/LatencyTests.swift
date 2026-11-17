#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only.
import Foundation
import MobileTransport
import XCTest

/// A reconnect over a slow link: from the connect to the real helper's answer to `hello`, with the helper already in
/// the host's cache, through a `DelayRelay` at several round trip times. Two ways: as a first connection goes (the key
/// asked first, the full bootstrap: probe, cache check, start) and as a reconnect goes (the key sent direct, the helper
/// started straight from the cache). Printed as `MEASURE` lines, with the round trips each took: its time beyond the
/// same exchange at no delay, in units of the round trip.
///
/// The `hello` costs a round trip of its own after the exec request either way: OpenSSH's sshd opens a session channel
/// with a window of zero and grants it only once the command started, so nothing written at once can leave with the
/// request.
final class LatencyTests: XCTestCase {
  /// Milliseconds; 0 measures the exchange itself.
  static let roundTrips = [0, 50, 100, 200, 400]
  static let samples = 3

  func testReconnectOverASlowLink() async throws {
    guard FileManager.default.fileExists(atPath: HelperChannelTests.realHelpers.appendingPathComponent("darwin-arm64").path) else {
      throw XCTSkip("No helper build at \(HelperChannelTests.realHelpers.path) (scripts/build-ssh-helper.py --build-only)")
    }
    let fixture = try SSHFixture()
    defer { fixture.stop() }
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let warm = try await fixture.connect()
    _ = try await HelperBootstrap.install(on: warm, binaries: HelperChannelTests.realHelpers)
    await warm.close()

    let ways = [(name: "asked first, full bootstrap", fast: false), (name: "direct, from the cache", fast: true)]
    var floor: [Bool: Double] = [:], trips: [Bool: Double] = [:]
    for roundTrip in Self.roundTrips {
      let relay = try DelayRelay(to: fixture.port, oneWay: .microseconds(roundTrip * 500))
      defer { relay.stop() }
      let endpoint = SSHEndpoint(host: "127.0.0.1", port: relay.port, username: fixture.user)
      for way in ways {
        var logins: [Double] = [], channels: [Double] = [], hellos: [Double] = []
        for _ in 0..<Self.samples {
          let start = ContinuousClock.now
          let credential: SSHCredential = way.fast ? .directKey(key, answered: { _ in }) : .key(key)
          let connection = try await SSHConnection.connect(to: endpoint, credentials: [credential], trust: fixture.trust)
          logins.append(seconds(ContinuousClock.now - start))
          let session = try await SSHHostSession.bootstrapHelper(
            on: connection, binaries: HelperChannelTests.realHelpers, capabilities: "host.identity,stats.ping,events,cancel",
            fromCache: way.fast, phase: { _ in })
          channels.append(seconds(ContinuousClock.now - start))
          let helper = HelperConnection(read: session.helper.read, write: session.helper.write)
          let _: HelperChannelTests.Hello = try await helper.request("hello", params: [String: String]())
          hellos.append(seconds(ContinuousClock.now - start))
          helper.close()
          await session.helper.close()
          await connection.close()
        }
        let login = Self.median(logins), channel = Self.median(channels), hello = Self.median(hellos)
        var line = String(format: "reconnect at %3d ms round trip, ", roundTrip) + way.name
          + String(format: ": login after %.0f ms, helper channel after %.0f ms, hello answered after %.0f ms", login * 1000,
                   channel * 1000, hello * 1000)
        if roundTrip == 0 {
          floor[way.fast] = hello
        } else {
          let taken = (hello - (floor[way.fast] ?? 0)) * 1000 / Double(roundTrip)
          trips[way.fast] = taken
          line += String(format: " (%.1f round trips)", taken)
        }
        report(line)
      }
    }
    // At the longest round trip the link's delay is nearly all of the time: 13 round trips asked first (the TCP
    // handshake, 2 for the key exchange, 3 for the login, 6 for three commands, the `hello`), 7 direct from the cache
    // (1, 2, 1, the channel, the command, the `hello`).
    let slow = try XCTUnwrap(trips[false]), fast = try XCTUnwrap(trips[true])
    XCTAssertLessThan(fast, 8, "direct from the cache")
    XCTAssertGreaterThan(slow, fast + 4, "asked first with the full bootstrap")
  }

  private static func median(_ values: [Double]) -> Double {
    values.sorted()[values.count / 2]
  }
}
#endif
