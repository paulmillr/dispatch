#if os(macOS)
// The loopback sshd fixture spawns processes: macOS only (SimulatorTests covers the iPhone build).
import CryptoKit
import Foundation
import MobileTransport
import XCTest

/// Requirement 2 against OpenSSH 10.3's default policy: every key type from OpenSSH files (plain and
/// encrypted, parsed by the engine), RSA with SHA-2 only, CryptoKit and Secure Enclave keys signing in
/// Swift, and the password and keyboard-interactive paths. Successful password and keyboard-interactive
/// logins need PAM, which a user-owned sshd lacks: the engine tests prove those against a russh server.
final class AuthenticationTests: XCTestCase {
  @discardableResult
  private func login(_ name: String, passphrase: String? = nil, fixture: SSHFixture = .shared) async throws -> SSHKey {
    let key = try SSHKey.openSSH(TestKeys.shared.data(name), passphrase: passphrase)
    XCTAssertEqual(key.fingerprint, try TestKeys.shared.fingerprint(name), name)
    let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
    let whoami = try await connection.run("id -un")
    XCTAssertEqual(whoami.text, fixture.user + "\n")
    await connection.close()
    return key
  }

  func testED25519() async throws {
    let key = try await login("ed25519")
    XCTAssertEqual(key.kind, .ed25519)
    try await login("ed25519-encrypted", passphrase: SSHFixture.passphrase)
    // The app passes a stored passphrase as bytes, never a String.
    let fromBytes = try SSHKey.openSSH(TestKeys.shared.data("ed25519-encrypted"), passphrase: Data(SSHFixture.passphrase.utf8))
    XCTAssertEqual(fromBytes.fingerprint, try TestKeys.shared.fingerprint("ed25519-encrypted"))
    XCTAssertThrowsError(try SSHKey.openSSH(TestKeys.shared.data("ed25519-encrypted"), passphrase: Data("wrong".utf8)))
  }

  func testECDSA() async throws {
    for (name, kind) in [("ecdsa", SSHKey.Kind.ecdsaP256), ("ecdsa384", .ecdsaP384), ("ecdsa521", .ecdsaP521)] {
      let key = try await login(name)
      XCTAssertEqual(key.kind, kind)
      try await login(name + "-encrypted", passphrase: SSHFixture.passphrase)
    }
  }

  /// RSA under OpenSSH's default PubkeyAcceptedAlgorithms: the engine signs rsa-sha2-512.
  func testRSA() async throws {
    let key = try await login("rsa")
    XCTAssertEqual(key.kind, .rsa)
    try await login("rsa-encrypted", passphrase: SSHFixture.passphrase)
  }

  /// A server that accepts only ssh-rsa (SHA-1) signatures refuses us: the engine never signs SHA-1.
  func testRSANeverSignsSHA1() async throws {
    let fixture = try SSHFixture(extraConfiguration: ["PubkeyAcceptedAlgorithms ssh-rsa"])
    defer { fixture.stop() }
    let key = try SSHKey.openSSH(TestKeys.shared.data("rsa"))
    do {
      _ = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
      XCTFail("logged in although only ssh-rsa signatures are accepted")
    } catch SSHTransportError.authenticationFailed {}
  }

  func testWrongOrMissingPassphrase() throws {
    for name in ["ed25519-encrypted", "ecdsa-encrypted", "rsa-encrypted"] {
      XCTAssertThrowsError(try SSHKey.openSSH(TestKeys.shared.data(name), passphrase: "wrong")) {
        XCTAssertEqual($0 as? SSHTransportError, .wrongPassphrase, name)
      }
      XCTAssertThrowsError(try SSHKey.openSSH(TestKeys.shared.data(name))) {
        XCTAssertEqual($0 as? SSHTransportError, .wrongPassphrase, name)
      }
    }
    XCTAssertThrowsError(try SSHKey.openSSH(Data("not a key".utf8)))
  }

  /// CryptoKit keys sign in Swift; only the public key crosses the FFI.
  func testCryptoKitKeys() async throws {
    let fixture = SSHFixture.shared
    for key in [SSHKey(p256: P256.Signing.PrivateKey()), SSHKey(ed25519: Curve25519.Signing.PrivateKey())] {
      try fixture.authorize(key.publicKey)
      let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
      XCTAssertTrue(connection.isActive)
      await connection.close()
    }
  }

  /// The Secure Enclave signs, where this Mac has one and lets an unsigned test process use it.
  func testSecureEnclaveP256() async throws {
    guard SecureEnclave.isAvailable else { throw XCTSkip("No Secure Enclave") }
    let enclave: SecureEnclave.P256.Signing.PrivateKey
    do { enclave = try SecureEnclave.P256.Signing.PrivateKey() } catch {
      throw XCTSkip("Secure Enclave key creation refused here: \(error)")
    }
    let key = SSHKey(secureEnclave: enclave)
    XCTAssertTrue(key.hardwareBacked)
    let fixture = SSHFixture.shared
    try fixture.authorize(key.publicKey)
    let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
    await connection.close()
  }

  /// A signer that fails (Face ID dismissed) cancels that credential.
  func testSignerFailureIsCancelled() async throws {
    let fixture = SSHFixture.shared
    let real = P256.Signing.PrivateKey()
    let blob = SSHKey(p256: real).publicKey.split(separator: " ").last.flatMap { Data(base64Encoded: String($0)) }!
    let key = SSHKey(kind: .ecdsaP256, publicKeyBlob: blob, hardwareBacked: true) { _ in throw CancellationError() }
    try fixture.authorize(key.publicKey)
    do {
      _ = try await SSHConnection.connect(to: fixture.endpoint, credentials: [.key(key)], trust: fixture.trust)
      XCTFail("a cancelled signature logged in")
    } catch SSHTransportError.cancelled {}
  }

  /// Unaccepted credentials fall through to the next: an unknown key, a password the server cannot
  /// check, keyboard-interactive with no PAM behind it, then the real key.
  func testCredentialsFallThrough() async throws {
    let fixture = try SSHFixture(extraConfiguration: ["PasswordAuthentication yes"])
    defer { fixture.stop() }
    let stranger = SSHKey(ed25519: Curve25519.Signing.PrivateKey())
    let key = try SSHKey.openSSH(TestKeys.shared.data("ed25519"))
    let prompted = Counter()
    let connection = try await SSHConnection.connect(to: fixture.endpoint, credentials: [
      .key(stranger), .password("not checked"),
      .keyboardInteractive { challenge in
        await prompted.add()
        return challenge.prompts.map { _ in "" }
      },
      .key(key),
    ], trust: fixture.trust)
    XCTAssertTrue(connection.isActive)
    await connection.close()
    do {
      _ = try await SSHFixture.shared.connect([.key(stranger)])
      XCTFail("an unauthorized key logged in")
    } catch SSHTransportError.authenticationFailed(let methods) {
      XCTAssertTrue(methods.contains("publickey"), "\(methods)")
    }
  }
}

actor Counter {
  private(set) var value = 0
  func add() { value += 1 }
}
#endif
