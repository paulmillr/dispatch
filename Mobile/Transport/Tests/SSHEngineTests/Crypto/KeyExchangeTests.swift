import CryptoKit
import XCTest
@testable import SSHEngine

/// The key exchange methods, the exchange hash and the key derivation: recomputed here from their definitions with
/// CryptoKit directly, the server side agreeing, deterministic ephemeral keys, and every refusal of a server value.
final class KeyExchangeTests: XCTestCase {
  static let transcript = KeyExchangeTranscript(
    clientVersion: Array("SSH-2.0-Client".utf8), serverVersion: Array("SSH-2.0-Server".utf8),
    clientKexInit: [20] + [UInt8](repeating: 1, count: 30), serverKexInit: [20] + [UInt8](repeating: 2, count: 40))
  static let hostKeyBlob = ServerHostKey.ed25519(seed: 0x51).publicBlob

  static func reply(_ value: [UInt8], hostKey: [UInt8] = hostKeyBlob, signature: [UInt8] = Raw.string("ssh-ed25519") + Raw.string([UInt8](repeating: 0, count: 64))) -> [UInt8] {
    [MessageNumber.kexECDHReply.rawValue] + Raw.string(hostKey) + Raw.string(value) + Raw.string(signature)
  }

  /// The client's value from its message 30.
  static func value(_ initMessage: [UInt8]) -> [UInt8] { Array(initMessage.dropFirst(5)) }

  // MARK: Agreement with the server side

  func testEveryMethodAgreesWithTheServerAndHashesAsSpecified() throws {
    for algorithm in KeyExchangeAlgorithm.allCases {
      let method = KeyExchangeMethods.make(algorithm, random: SeededRandom(seed: 5))
      XCTAssertEqual(method.algorithm, algorithm)
      let initMessage = try method.makeInit()
      XCTAssertEqual(initMessage.first, MessageNumber.kexECDHInit.rawValue)
      let clientValue = Self.value(initMessage)
      XCTAssertEqual(Array(initMessage[1..<5]), Raw.u32(UInt32(clientValue.count)))
      let (serverValue, serverK) = try ScriptedServer.serverSide(algorithm, clientValue: clientValue, random: SeededRandom(seed: 6))
      let output = try method.receiveReply(Self.reply(serverValue), transcript: Self.transcript)
      XCTAssertTrue(output.encodedSharedSecret.constantTimeEquals(serverK), "\(algorithm)")
      XCTAssertEqual(output.hash, algorithm.hash)
      XCTAssertEqual(output.hostKeyBlob, Self.hostKeyBlob)
      // H, recomputed by hand: every field a string, then K as encoded.
      var hashed = Raw.string(Self.transcript.clientVersion) + Raw.string(Self.transcript.serverVersion)
        + Raw.string(Self.transcript.clientKexInit) + Raw.string(Self.transcript.serverKexInit) + Raw.string(Self.hostKeyBlob)
        + Raw.string(clientValue) + Raw.string(serverValue)
      hashed += output.encodedSharedSecret.withUnsafeBytes { Array($0) }
      let expected: [UInt8] = switch algorithm.hash {
      case .sha256: Array(SHA256.hash(data: hashed))
      case .sha384: Array(SHA384.hash(data: hashed))
      case .sha512: Array(SHA512.hash(data: hashed))
      }
      XCTAssertEqual(output.exchangeHash, expected, "\(algorithm)")
      // K's encoding: an mpint for ECDH and X25519, a 32-byte string for the hybrid.
      let k = output.encodedSharedSecret.withUnsafeBytes { Array($0) }
      if algorithm == .mlkem768x25519 {
        XCTAssertEqual(Array(k.prefix(4)), Raw.u32(32))
        XCTAssertEqual(k.count, 36)
      } else {
        let length = Int(Raw.u32(UInt32(k.count - 4)) == Array(k.prefix(4)) ? k.count - 4 : -1)
        XCTAssertGreaterThan(length, 0, "\(algorithm)")
        // Minimal: no leading zero unless the next byte's high bit is set.
        if k[4] == 0 { XCTAssertGreaterThanOrEqual(k[5], 0x80) } else { XCTAssertLessThan(k[4], 0x80) }
      }
    }
  }

  func testClientValueSizes() throws {
    let sizes: [KeyExchangeAlgorithm: Int] = [.curve25519: 32, .curve25519LibSSH: 32, .ecdhP256: 65, .ecdhP384: 97,
                                              .ecdhP521: 133, .mlkem768x25519: 1184 + 32]
    for algorithm in KeyExchangeAlgorithm.allCases {
      let value = Self.value(try KeyExchangeMethods.make(algorithm, random: SeededRandom(seed: 1)).makeInit())
      XCTAssertEqual(value.count, sizes[algorithm], "\(algorithm)")
      if case .ecdhP256 = algorithm { XCTAssertEqual(value.first, 0x04) }
    }
  }

  /// Ephemeral keys come from the injected randomness, so a seed gives the same message every time (CryptoKit
  /// allows it for every method: raw X25519 and P-curve scalars, ML-KEM's seed).
  func testEphemeralKeysAreReproducibleFromTheSeed() throws {
    for algorithm in KeyExchangeAlgorithm.allCases {
      let first = try KeyExchangeMethods.make(algorithm, random: SeededRandom(seed: 77)).makeInit()
      let again = try KeyExchangeMethods.make(algorithm, random: SeededRandom(seed: 77)).makeInit()
      let other = try KeyExchangeMethods.make(algorithm, random: SeededRandom(seed: 78)).makeInit()
      XCTAssertEqual(first, again, "\(algorithm)")
      XCTAssertNotEqual(first, other, "\(algorithm)")
    }
  }

  func testAMethodIsUsedOnceInOrder() throws {
    let method = KeyExchangeMethods.make(.curve25519, random: SeededRandom(seed: 1))
    XCTAssertThrows(ExchangeStep.outOfOrder) { () throws(SSHError) in try method.receiveReply(Self.reply([]), transcript: Self.transcript) }
    let initMessage = try method.makeInit()
    XCTAssertThrows(ExchangeStep.outOfOrder) { () throws(SSHError) in try method.makeInit() }
    let (serverValue, _) = try ScriptedServer.serverSide(.curve25519, clientValue: Self.value(initMessage), random: SeededRandom(seed: 2))
    _ = try method.receiveReply(Self.reply(serverValue), transcript: Self.transcript)
    XCTAssertThrows(ExchangeStep.outOfOrder) { () throws(SSHError) in try method.receiveReply(Self.reply(serverValue), transcript: Self.transcript) }
  }

  // MARK: Refusals

  func refuse(_ algorithm: KeyExchangeAlgorithm, _ value: [UInt8], _ expected: SSHError, file: StaticString = #filePath, line: UInt = #line) throws {
    let method = KeyExchangeMethods.make(algorithm, random: SeededRandom(seed: 3))
    _ = try method.makeInit()
    XCTAssertThrows(expected, file: file, line: line) { () throws(SSHError) in try method.receiveReply(Self.reply(value), transcript: Self.transcript) }
  }

  func testX25519Refusals() throws {
    let invalidValue = SSHError.protocolViolation(.keyExchange(.invalidServerValue))
    let degenerate = SSHError.protocolViolation(.keyExchange(.invalidSharedSecret))
    for algorithm in [KeyExchangeAlgorithm.curve25519, .curve25519LibSSH] {
      for count in [0, 31, 33, 64] { try refuse(algorithm, [UInt8](repeating: 9, count: count), invalidValue) }
      // Points of small order (RFC 7748 §6.1, and the list every implementation refuses): the output is all zero.
      let lowOrder = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
      ]
      for point in lowOrder { try refuse(algorithm, PrimitiveTestSupport.bytes(point), degenerate) }
    }
  }

  func testECDHRefusals() throws {
    let invalid = SSHError.protocolViolation(.keyExchange(.invalidServerValue))
    for (algorithm, curve) in [(KeyExchangeAlgorithm.ecdhP256, ECDSACurve.p256), (.ecdhP384, .p384), (.ecdhP521, .p521)] {
      // The right size but not on the curve; compressed; another prefix; the wrong sizes.
      try refuse(algorithm, [0x04] + [UInt8](repeating: 1, count: 2 * curve.scalarBytes), invalid)
      try refuse(algorithm, [0x02] + [UInt8](repeating: 1, count: curve.scalarBytes), invalid)
      try refuse(algorithm, [0x05] + [UInt8](repeating: 1, count: 2 * curve.scalarBytes), invalid)
      try refuse(algorithm, [], invalid)
      // A valid point of another curve.
      let other = curve == .p256 ? Array(P384.KeyAgreement.PrivateKey().publicKey.x963Representation)
        : Array(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
      try refuse(algorithm, other, invalid)
      // A valid point with a byte too many.
      let good = curve == .p256 ? Array(P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        : curve == .p384 ? Array(P384.KeyAgreement.PrivateKey().publicKey.x963Representation)
        : Array(P521.KeyAgreement.PrivateKey().publicKey.x963Representation)
      try refuse(algorithm, good + [0], invalid)
    }
  }

  func testMLKEMHybridRefusals() throws {
    let invalid = SSHError.protocolViolation(.keyExchange(.invalidServerValue))
    for count in [0, 32, 1088, 1119, 1121] { try refuse(.mlkem768x25519, [UInt8](repeating: 7, count: count), invalid) }
    // A ciphertext of the right size (implicit rejection gives some K) with a degenerate X25519 half.
    try refuse(.mlkem768x25519, [UInt8](repeating: 7, count: 1088) + [UInt8](repeating: 0, count: 32),
               .protocolViolation(.keyExchange(.invalidSharedSecret)))
  }

  func testMalformedReplies() throws {
    let method = KeyExchangeMethods.make(.curve25519, random: SeededRandom(seed: 3))
    _ = try method.makeInit()
    XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexECDHReply, .trailingBytes))) { () throws(SSHError) in
      try method.receiveReply(Self.reply([UInt8](repeating: 9, count: 32)) + [0], transcript: Self.transcript)
    }
    for (payload, error) in [
      (Self.reply([1], hostKey: [UInt8](repeating: 0, count: Limits.publicKeyBlobBytes + 1)), WireError.tooLong(limit: Limits.publicKeyBlobBytes)),
      (Self.reply([UInt8](repeating: 0, count: Limits.keyExchangeValueBytes + 1)), .tooLong(limit: Limits.keyExchangeValueBytes)),
      ([MessageNumber.kexECDHReply.rawValue] + Raw.u32(0xFFFF_FFFF), .tooLong(limit: Limits.publicKeyBlobBytes)),
      ([MessageNumber.kexECDHReply.rawValue] + Raw.string(Self.hostKeyBlob), .truncated),
    ] {
      let fresh = KeyExchangeMethods.make(.curve25519, random: SeededRandom(seed: 3))
      _ = try fresh.makeInit()
      XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexECDHReply, error))) { () throws(SSHError) in
        try fresh.receiveReply(payload, transcript: Self.transcript)
      }
    }
  }

  // MARK: Encodings and derivation

  func testSharedSecretEncodings() {
    func mpint(_ bytes: [UInt8]) -> [UInt8] {
      bytes.withUnsafeBytes { raw in SecretBytes.mpint(magnitude: raw).withUnsafeBytes { Array($0) } }
    }
    XCTAssertEqual(mpint([0x00, 0x00, 0x7F, 0x01]), Raw.u32(2) + [0x7F, 0x01])
    XCTAssertEqual(mpint([0x00, 0x80, 0x01]), Raw.u32(3) + [0x00, 0x80, 0x01])
    XCTAssertEqual(mpint([0xFF]), Raw.u32(2) + [0x00, 0xFF])
    XCTAssertEqual(mpint([0, 0, 0]), Raw.u32(0))
    XCTAssertEqual(mpint([]), Raw.u32(0))
    let string = [UInt8](repeating: 3, count: 32).withUnsafeBytes { raw in SecretBytes.string(raw).withUnsafeBytes { Array($0) } }
    XCTAssertEqual(string, Raw.u32(32) + [UInt8](repeating: 3, count: 32))
  }

  /// RFC 4253 §7.2, computed here with CryptoKit from the definition, for key sizes within one digest and beyond it.
  func testKeyDerivationFollowsRFC4253() {
    let k = SecretBytes(copying: Raw.u32(3) + [0x01, 0x02, 0x03])
    let h = (0..<32).map { UInt8($0) }
    let session = (0..<32).map { UInt8(255 - $0) }
    for (hash, count) in [(HashAlgorithm.sha256, 12), (.sha256, 32), (.sha256, 64), (.sha256, 100), (.sha384, 48),
                          (.sha512, 16), (.sha512, 64), (.sha512, 130)] {
      for letter in "ABCDEF" {
        func digest(_ data: [UInt8]) -> [UInt8] {
          switch hash {
          case .sha256: Array(SHA256.hash(data: data))
          case .sha384: Array(SHA384.hash(data: data))
          case .sha512: Array(SHA512.hash(data: data))
          }
        }
        let kBytes = k.withUnsafeBytes { Array($0) }
        var expected = digest(kBytes + h + [letter.asciiValue!] + session)
        while expected.count < count { expected += digest(kBytes + h + expected) }
        let derived = KeyDerivation.derive(letter, count: count, sharedSecret: k, exchangeHash: h, sessionID: session, hash: hash)
        XCTAssertEqual(derived.withUnsafeBytes { Array($0) }, Array(expected.prefix(count)), "\(hash) \(count) \(letter)")
      }
    }
  }

  func testDirectionKeysUseTheirLettersAndSizes() {
    let k = SecretBytes(copying: Raw.u32(1) + [0x42])
    let h = [UInt8](repeating: 0xAA, count: 32)
    let negotiated = NegotiatedAlgorithms(
      keyExchange: .curve25519, hostKey: .ed25519, clientToServer: .init(cipher: .aes192CTR, mac: .hmacSHA512),
      serverToClient: .init(cipher: .chacha20Poly1305, mac: nil), strictKex: true, serverSendsExtInfo: true)
    let keys = KeyDerivation.keys(for: negotiated, sharedSecret: k, exchangeHash: h, sessionID: h, hash: .sha256)
    func derive(_ letter: Character, _ count: Int) -> [UInt8] {
      KeyDerivation.derive(letter, count: count, sharedSecret: k, exchangeHash: h, sessionID: h, hash: .sha256).withUnsafeBytes { Array($0) }
    }
    func bytes(_ secret: SecretBytes?) -> [UInt8]? { secret?.withUnsafeBytes { Array($0) } }
    XCTAssertEqual(bytes(keys.clientToServer.iv), derive("A", 16))
    XCTAssertEqual(bytes(keys.serverToClient.iv), [])
    XCTAssertEqual(bytes(keys.clientToServer.key), derive("C", 24))
    XCTAssertEqual(bytes(keys.serverToClient.key), derive("D", 64))
    XCTAssertEqual(bytes(keys.clientToServer.macKey), derive("E", 64))
    XCTAssertNil(keys.serverToClient.macKey)
  }
}
