import SSHEngine
import XCTest

final class AlgorithmPolicyTests: XCTestCase {
  func testTheOfferedLists() {
    let standard = AlgorithmPolicy.Preferences.standard
    XCTAssertEqual(standard.keyExchangeNames, [
      "mlkem768x25519-sha256", "curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256",
      "ecdh-sha2-nistp384", "ecdh-sha2-nistp521", "ext-info-c", "kex-strict-c-v00@openssh.com",
    ])
    XCTAssertEqual(standard.hostKey.map(\.rawValue), [
      "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "rsa-sha2-512", "rsa-sha2-256",
    ])
    // A server without strict key exchange lands on an allowed mode whenever it has one: AES-GCM, then AES-CTR with
    // the encrypt-and-MAC MACs first, ChaCha20-Poly1305 last.
    XCTAssertEqual(standard.cipher.map(\.rawValue), [
      "aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "aes256-ctr", "aes192-ctr", "aes128-ctr",
      "chacha20-poly1305@openssh.com",
    ])
    XCTAssertEqual(standard.mac.map(\.rawValue), [
      "hmac-sha2-256", "hmac-sha2-512", "hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com",
    ])
    XCTAssertEqual(AlgorithmPolicy.Preferences.compressionNames, ["none"])
    // Never SHA-1, DSA, CBC or finite-field DH.
    let everything = standard.keyExchangeNames + standard.hostKey.map(\.rawValue) + standard.cipher.map(\.rawValue)
      + standard.mac.map(\.rawValue)
    for refused in ["ssh-rsa", "ssh-dss", "diffie-hellman", "cbc", "sha1", "-cert-"] {
      XCTAssertFalse(everything.contains { $0.contains(refused) }, refused)
    }
  }

  /// Every mode both ways, strict and not: without strict key exchange, ChaCha20-Poly1305 and AES-CTR with an
  /// encrypt-then-MAC MAC are refused in either direction (Terrapin's truncatable modes, the paper's Table 1); AES-GCM
  /// and AES-CTR with an encrypt-and-MAC MAC pass; with it, everything passes. The refusal names the mode.
  func testOnlyTruncatableModesNeedStrictKex() {
    XCTAssertTrue(AlgorithmPolicy.truncatableModesRequireStrictKex)
    let modes = PacketProtectionTests.families.map { NegotiatedAlgorithms.Direction(cipher: $0.0, mac: $0.1) }
    func negotiated(_ c2s: NegotiatedAlgorithms.Direction, _ s2c: NegotiatedAlgorithms.Direction, strict: Bool)
      -> NegotiatedAlgorithms
    {
      NegotiatedAlgorithms(keyExchange: .curve25519, hostKey: .ed25519, clientToServer: c2s, serverToClient: s2c,
                           strictKex: strict, serverSendsExtInfo: true)
    }
    func refusal(_ mode: NegotiatedAlgorithms.Direction) -> SSHError {
      if let mac = mode.mac { return .protocolViolation(.negotiation(.encryptThenMACRequiresStrictKex(mode.cipher, mac))) }
      return .protocolViolation(.negotiation(.cipherRequiresStrictKex(mode.cipher)))
    }
    for c2s in modes {
      for s2c in modes {
        XCTAssertNoThrow(try AlgorithmPolicy.check(negotiated(c2s, s2c, strict: true)), "\(c2s) \(s2c) strict")
        let truncatable = [c2s, s2c].filter(AlgorithmPolicy.isTruncatable)
        if let first = truncatable.first {
          XCTAssertThrows(refusal(first)) { () throws(SSHError) in
            try AlgorithmPolicy.check(negotiated(c2s, s2c, strict: false))
          }
        } else {
          XCTAssertNoThrow(try AlgorithmPolicy.check(negotiated(c2s, s2c, strict: false)), "\(c2s) \(s2c)")
        }
      }
    }
    // Which modes those are, by name.
    let truncatable = modes.filter(AlgorithmPolicy.isTruncatable).map { "\($0.cipher.rawValue)+\($0.mac?.rawValue ?? "-")" }
    XCTAssertEqual(truncatable, ["chacha20-poly1305@openssh.com+-"] + ["aes256-ctr", "aes192-ctr", "aes128-ctr"].flatMap {
      ["\($0)+hmac-sha2-256-etm@openssh.com", "\($0)+hmac-sha2-512-etm@openssh.com"]
    })
    XCTAssertEqual("\(refusal(.init(cipher: .aes128CTR, mac: .hmacSHA512ETM)))",
                   "aes128-ctr with hmac-sha2-512-etm@openssh.com needs strict key exchange, which the server did not offer")
    XCTAssertEqual("\(refusal(.init(cipher: .chacha20Poly1305, mac: nil)))",
                   "chacha20-poly1305@openssh.com needs strict key exchange, which the server did not offer")
  }

  func testAlgorithmFacts() {
    XCTAssertEqual(KeyExchangeAlgorithm.ecdhP384.hash, .sha384)
    XCTAssertEqual(KeyExchangeAlgorithm.ecdhP521.hash.digestBytes, 64)
    XCTAssertEqual(KeyExchangeAlgorithm.mlkem768x25519.hash, .sha256)
    XCTAssertEqual(SignatureAlgorithm.rsaSHA256.keyType, "ssh-rsa")
    XCTAssertEqual(SignatureAlgorithm.ecdsaP521.keyType, "ecdsa-sha2-nistp521")
    XCTAssertEqual(CipherAlgorithm.chacha20Poly1305.keyBytes, 64)
    XCTAssertEqual(CipherAlgorithm.chacha20Poly1305.blockBytes, 8)
    XCTAssertEqual(CipherAlgorithm.aes128GCM.ivBytes, 12)
    XCTAssertEqual(MACAlgorithm.hmacSHA512ETM.tagBytes, 64)
    XCTAssertTrue(MACAlgorithm.hmacSHA256ETM.isEncryptThenMAC)
    XCTAssertFalse(MACAlgorithm.hmacSHA512.isEncryptThenMAC)
  }
}
