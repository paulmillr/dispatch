import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// External signers return what MobileTransport's `SSHKey(ed25519:)`, `SSHKey(p256:)` and `SSHKey(secureEnclave:)`
/// return: CryptoKit's Ed25519 signature (64 bytes) or `ECDSASignature.rawRepresentation` (r‖s). Software P-256
/// stands in for the Secure Enclave, whose signature type is the same `P256.Signing.ECDSASignature`.
final class ExternalSignerTests: XCTestCase {
  private let data = Array("fictional session id and userauth request".utf8)

  func testEd25519AndECDSASignersProduceVerifyingBlobs() async throws {
    let ed25519 = Curve25519.Signing.PrivateKey()
    let p256 = P256.Signing.PrivateKey(), p384 = P384.Signing.PrivateKey(), p521 = P521.Signing.PrivateKey()
    let signers: [(ExternalSignerKey, SignatureAlgorithm)] = [
      (try ExternalSignerKey(publicKeyBlob: Raw.string("ssh-ed25519") + Raw.string(Array(ed25519.publicKey.rawRepresentation))) {
        (data) throws(SSHError) in Array(try! ed25519.signature(for: data)) }, .ed25519),
      (try ExternalSignerKey(publicKeyBlob: PublicKeyBlob.ecdsa(.p256, point: Array(p256.publicKey.x963Representation)).encoded) {
        (data) throws(SSHError) in Array(try! p256.signature(for: data).rawRepresentation) }, .ecdsaP256),
      (try ExternalSignerKey(publicKeyBlob: PublicKeyBlob.ecdsa(.p384, point: Array(p384.publicKey.x963Representation)).encoded) {
        (data) throws(SSHError) in Array(try! p384.signature(for: data).rawRepresentation) }, .ecdsaP384),
      (try ExternalSignerKey(publicKeyBlob: PublicKeyBlob.ecdsa(.p521, point: Array(p521.publicKey.x963Representation)).encoded) {
        (data) throws(SSHError) in Array(try! p521.signature(for: data).rawRepresentation) }, .ecdsaP521),
    ]
    for (key, algorithm) in signers {
      let blob = try await key.sign(data, algorithm: algorithm)
      XCTAssertEqual(try SignatureBlob(decoding: blob).algorithm, algorithm.rawValue)
      XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: blob, over: data, key: key.publicKey, algorithm: algorithm))
      XCTAssertTrue(key.authorizedKeysLine.hasPrefix(algorithm.keyType + " "))
      XCTAssertTrue(key.fingerprint.hasPrefix("SHA256:"))
    }
  }

  func testRawSignatureLengths() throws {
    XCTAssertThrows(SSHError.invalidKey("Ed25519 signatures are 64 bytes")) { () throws(SSHError) in
      try ExternalSignature.blob(raw: [UInt8](repeating: 1, count: 63), algorithm: .ed25519)
    }
    XCTAssertThrows(SSHError.invalidKey("Ed25519 signatures are 64 bytes")) { () throws(SSHError) in
      try ExternalSignature.blob(raw: [UInt8](repeating: 1, count: 65), algorithm: .ed25519)
    }
    // DER (what SecKeyCreateSignature returns for ECDSA) is never r‖s's length; r‖s of another curve neither.
    let p256 = P256.Signing.PrivateKey()
    let signature = try p256.signature(for: data)
    XCTAssertThrows(SSHError.invalidKey("ECDSA signature has the wrong length")) { () throws(SSHError) in
      try ExternalSignature.blob(raw: Array(signature.derRepresentation), algorithm: .ecdsaP256)
    }
    for (count, algorithm) in [(64, SignatureAlgorithm.ecdsaP384), (96, .ecdsaP256), (132, .ecdsaP384), (130, .ecdsaP521)] {
      XCTAssertThrows(SSHError.invalidKey("ECDSA signature has the wrong length")) { () throws(SSHError) in
        try ExternalSignature.blob(raw: [UInt8](repeating: 1, count: count), algorithm: algorithm)
      }
    }
    // A zero r or s.
    XCTAssertThrows(SSHError.invalidKey("ECDSA signature has the wrong length")) { () throws(SSHError) in
      try ExternalSignature.blob(raw: [UInt8](repeating: 0, count: 32) + [UInt8](repeating: 1, count: 32), algorithm: .ecdsaP256)
    }
    XCTAssertThrows(SSHError.unsupported("external signing for ssh-rsa is unsupported")) { () throws(SSHError) in
      try ExternalSignature.blob(raw: [UInt8](repeating: 1, count: 256), algorithm: .rsaSHA512)
    }
    // r‖s with leading zeros encodes as minimal mpints.
    let raw = [UInt8](repeating: 0, count: 31) + [5] + [0x80] + [UInt8](repeating: 0, count: 31)
    XCTAssertEqual(try ExternalSignature.blob(raw: raw, algorithm: .ecdsaP256),
                   Raw.string("ecdsa-sha2-nistp256") + Raw.string(Raw.string([5]) + Raw.string([0, 0x80] + [UInt8](repeating: 0, count: 31))))
  }

  func testSignerFailures() async throws {
    let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
    let blob = Raw.string("ssh-ed25519") + Raw.string(Array(key.publicKey.rawRepresentation))
    let declining = try ExternalSignerKey(publicKeyBlob: blob) { (_) throws(SSHError) in throw .cancelled }
    await assertSignThrows(.cancelled, declining, .ed25519)
    let wrongKey = try ExternalSignerKey(publicKeyBlob: blob) { (data) throws(SSHError) in Array(try! other.signature(for: data)) }
    await assertSignThrows(.invalidKey("the signer's signature does not verify with its public key"), wrongKey, .ed25519)
    let short = try ExternalSignerKey(publicKeyBlob: blob) { (_) throws(SSHError) in [1, 2, 3] }
    await assertSignThrows(.invalidKey("Ed25519 signatures are 64 bytes"), short, .ed25519)
    await assertSignThrows(.usage(.invalidArgument("a ssh-ed25519 key cannot sign ecdsa-sha2-nistp256")), short, .ecdsaP256)

    XCTAssertThrows(SSHError.unsupported("external signing for ssh-rsa is unsupported")) { () throws(SSHError) in
      try ExternalSignerKey(publicKeyBlob: Fixture.rsaBlob) { (_) throws(SSHError) in [] }
    }
    for bad in [[], Fixture.ed25519Blob + [0], Raw.string("ssh-dss") + Raw.string([1])] {
      XCTAssertThrows(SSHError.invalidKey("the signer's public key blob is not a key the engine takes")) { () throws(SSHError) in
        try ExternalSignerKey(publicKeyBlob: bad) { (_) throws(SSHError) in [] }
      }
    }
  }

  private func assertSignThrows(_ expected: SSHError, _ key: ExternalSignerKey, _ algorithm: SignatureAlgorithm,
                                file: StaticString = #filePath, line: UInt = #line) async {
    do {
      _ = try await key.sign(data, algorithm: algorithm)
      XCTFail("expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error, expected, file: file, line: line)
    }
  }

  /// A file key signs the same way through `UserKey`, and refuses an algorithm of another type (never ssh-rsa: the
  /// type has none).
  func testFileKeyAsUserKey() async throws {
    let key = try XCTUnwrap(parseKey(OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey()).file))
    let userKey: any UserKey = key
    let blob = try await userKey.sign(data, algorithm: .ed25519)
    XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: blob, over: data, key: key.publicKey, algorithm: .ed25519))
    do {
      _ = try await userKey.sign(data, algorithm: .rsaSHA512)
      XCTFail("signed with another type's algorithm")
    } catch {
      XCTAssertEqual(error, .usage(.invalidArgument("a ssh-ed25519 key cannot sign rsa-sha2-512")))
    }
    XCTAssertFalse(String(describing: key).contains(key.comment.isEmpty ? "\u{0}" : key.comment))
  }
}
