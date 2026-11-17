#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import CryptoKit
import Foundation
import MobileTransport
import XCTest

/// Direct public key logins (`SSHCredential.directKey`) against OpenSSH's sshd: the signed request without the query.
/// sshd's VERBOSE log notes every query of an acceptable key as "Postponed publickey" before the signed request that
/// follows it is "Accepted publickey"; a direct login leaves only the second. (That the request also leaves before the
/// service accept is the engine's tests/hostile.rs: sshd's log does not show it.)
final class DirectLoginTests: XCTestCase {
  private static let postponed = "Postponed publickey"
  private static let accepted = "Accepted publickey"

  /// Records how each direct attempt ended.
  private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DirectKeyAnswer] = []
    var all: [DirectKeyAnswer] { lock.withLock { values } }
    var record: @Sendable (DirectKeyAnswer) -> Void { { value in self.lock.withLock { self.values.append(value) } } }
  }

  private func count(_ text: String, in fixture: SSHFixture) -> Int {
    fixture.log.components(separatedBy: text).count - 1
  }

  /// Connects with `credentials` and waits until sshd logged the login; returns the connection's credential index and
  /// how many queries sshd noted for it.
  private func login(_ credentials: [SSHCredential], on fixture: SSHFixture) async throws -> (credential: Int, queries: Int) {
    let (queries, logins) = (count(Self.postponed, in: fixture), count(Self.accepted, in: fixture))
    let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: credentials, trust: fixture.trust)
    let whoami = try await connection.run("id -un")
    XCTAssertEqual(whoami.text, fixture.user + "\n")
    await connection.close()
    // The monitor writes sshd's lines; give the login's a moment.
    let deadline = ContinuousClock.now + .seconds(5)
    while count(Self.accepted, in: fixture) < logins + 1 {
      guard ContinuousClock.now < deadline else { throw XCTSkip("sshd did not log the login: \(fixture.log)") }
      try await Task.sleep(for: .milliseconds(20))
    }
    return (connection.credential, count(Self.postponed, in: fixture) - queries)
  }

  /// An ED25519 file key, a CryptoKit signer (ED25519 and P-256) and RSA: queried first with `.key`, never with
  /// `.directKey`, which reports that it logged in.
  func testDirectLoginsSendNoQuery() async throws {
    let fixture = try SSHFixture(logLevel: "VERBOSE")
    defer { fixture.stop() }
    var keys = [try SSHKey.openSSH(TestKeys.shared.data("ed25519")), try SSHKey.openSSH(TestKeys.shared.data("rsa"))]
    for signer in [SSHKey(ed25519: Curve25519.Signing.PrivateKey()), SSHKey(p256: P256.Signing.PrivateKey())] {
      try fixture.authorize(signer.publicKey)
      keys.append(signer)
    }
    for key in keys {
      let classic = try await login([.key(key)], on: fixture)
      XCTAssertEqual(classic.queries, 1, "\(key.kind): the query shows in sshd's log")
      let answers = Answers()
      let direct = try await login([.directKey(key, answered: answers.record)], on: fixture)
      XCTAssertEqual(direct.queries, 0, "\(key.kind): \(fixture.log)")
      XCTAssertEqual(direct.credential, 0)
      XCTAssertEqual(answers.all, [.loggedIn], "\(key.kind)")
    }
  }

  /// RSA picks its hash from sshd's server-sig-algs (its PubkeyAcceptedAlgorithms) for a direct request too: only
  /// rsa-sha2-256 accepted logs in with it; only ssh-rsa (SHA-1) accepted refuses the key, which never signs SHA-1.
  func testDirectRSAFollowsServerSigAlgs() async throws {
    let key = try SSHKey.openSSH(TestKeys.shared.data("rsa"))
    let sha256 = try SSHFixture(extraConfiguration: ["PubkeyAcceptedAlgorithms rsa-sha2-256"], logLevel: "VERBOSE")
    defer { sha256.stop() }
    let answers = Answers()
    let direct = try await login([.directKey(key, answered: answers.record)], on: sha256)
    XCTAssertEqual(direct.queries, 0)
    XCTAssertEqual(answers.all, [.loggedIn])

    let sha1 = try SSHFixture(extraConfiguration: ["PubkeyAcceptedAlgorithms ssh-rsa"])
    defer { sha1.stop() }
    let refused = Answers()
    do {
      _ = try await SSHConnection.connect(to: sha1.endpoint, credentials: [.directKey(key, answered: refused.record)], trust: sha1.trust)
      XCTFail("logged in although only ssh-rsa signatures are accepted")
    } catch SSHTransportError.authenticationFailed {}
    XCTAssertEqual(refused.all, [.refused])
  }

  /// A remembered key the server no longer takes: the direct attempt is refused (reported so) and the login goes on
  /// on the same connection, here with the right key asked first as usual.
  func testAWrongRememberedKeyFallsBack() async throws {
    let fixture = try SSHFixture(logLevel: "VERBOSE")
    defer { fixture.stop() }
    let stranger = SSHKey(ed25519: Curve25519.Signing.PrivateKey())
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let answers = Answers()
    let result = try await login([.directKey(stranger, answered: answers.record), .key(key)], on: fixture)
    XCTAssertEqual(result.credential, 1, "the key asked first logged in")
    XCTAssertEqual(result.queries, 1)
    XCTAssertEqual(answers.all, [.refused])

    // A direct attempt whose signer declines (Face ID dismissed) is cancelled, as with `.key`, and reported withdrawn.
    let declined = Answers()
    let declining = SSHKey(kind: .ed25519, publicKeyBlob: Self.blob(of: key), hardwareBacked: true) { _ in throw CancellationError() }
    do {
      _ = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.directKey(declining, answered: declined.record)], trust: fixture.trust)
      XCTFail("a declined signature logged in")
    } catch SSHTransportError.cancelled {}
    XCTAssertEqual(declined.all, [.withdrawn])
  }

  private static func blob(of key: SSHKey) -> Data {
    Data(base64Encoded: String(key.publicKey.split(separator: " ")[1]))!
  }
}
#endif
