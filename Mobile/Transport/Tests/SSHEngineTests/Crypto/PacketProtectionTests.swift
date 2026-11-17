import CryptoKit
import XCTest
@testable import SSHEngine

/// The packet protection families. AES-GCM, AES-CTR and HMAC are Apple's, so these test the assembly: the nonce's
/// progression and the associated data, CTR's counter carried across packets (with NIST's vectors), which bytes each
/// MAC form covers, ChaCha20-Poly1305's two keys, nonce and tag layout. The live sshd tests are the independent check
/// of all of it; here every byte flipped in a packet must fail it.
final class PacketProtectionTests: XCTestCase {
  typealias T = PrimitiveTestSupport

  static func keys(_ cipher: CipherAlgorithm, _ mac: MACAlgorithm?, seed: UInt8) -> DirectionKeys {
    func bytes(_ count: Int, _ salt: UInt8) -> SecretBytes {
      SecretBytes(copying: (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ Int(seed) &+ Int(salt)) })
    }
    return DirectionKeys(iv: bytes(cipher.ivBytes, 1), key: bytes(cipher.keyBytes, 2), macKey: mac.map { bytes($0.keyBytes, 3) })
  }

  static let families: [(CipherAlgorithm, MACAlgorithm?)] = {
    var cases: [(CipherAlgorithm, MACAlgorithm?)] = [(.aes256GCM, nil), (.aes128GCM, nil), (.chacha20Poly1305, nil)]
    for cipher in [CipherAlgorithm.aes256CTR, .aes192CTR, .aes128CTR] {
      for mac in MACAlgorithm.allCases { cases.append((cipher, mac)) }
    }
    return cases
  }()

  /// A padded packet as the framer builds it, for `sealer`.
  static func packet(_ payload: [UInt8], for sealer: any PacketSealer) -> [UInt8] {
    var framer = OutboundFramer()
    framer.install(sealer)
    let (length, padding) = framer.packetBytes(payload: payload.count)
    return Raw.u32(UInt32(length)) + [UInt8(padding)] + payload + [UInt8](repeating: 0xEE, count: padding)
  }

  // MARK: Round trips

  func testEveryFamilyRoundTripsAcrossManyPackets() throws {
    for (cipher, mac) in Self.families {
      let sealer = try PacketProtection.sealer(cipher: cipher, mac: mac, keys: Self.keys(cipher, mac, seed: 9))
      let opener = try PacketProtection.opener(cipher: cipher, mac: mac, keys: Self.keys(cipher, mac, seed: 9))
      XCTAssertEqual(sealer.tagBytes, opener.tagBytes)
      XCTAssertEqual(sealer.blockBytes, opener.blockBytes)
      XCTAssertEqual(sealer.lengthIsAligned, opener.lengthIsAligned)
      for (index, size) in [0, 1, 7, 8, 15, 16, 17, 100, 1000, 32768, 65000].enumerated() {
        let sequence = UInt32(1000 + index)
        let plain = Self.packet((0..<size).map { UInt8(truncatingIfNeeded: $0) }, for: sealer)
        let wire = try sealer.seal(plain, sequence: sequence)
        XCTAssertEqual(wire.count, plain.count + sealer.tagBytes, "\(cipher)")
        XCTAssertNotEqual(Array(wire[4..<plain.count]), Array(plain[4...]), "\(cipher): not encrypted")
        let length = try opener.packetLength(Array(wire.prefix(opener.lengthPrefixBytes)), sequence: sequence)
        XCTAssertEqual(Int(length), plain.count - 4, "\(cipher)")
        XCTAssertEqual(try opener.open(wire, sequence: sequence), Array(plain[4...]), "\(cipher) \(String(describing: mac)) \(size)")
      }
    }
  }

  func testEveryByteFlippedFailsThePacket() throws {
    for (cipher, mac) in Self.families {
      let sealer = try PacketProtection.sealer(cipher: cipher, mac: mac, keys: Self.keys(cipher, mac, seed: 4))
      let plain = Self.packet(Array("flip every bit".utf8), for: sealer)
      let wire = try sealer.seal(plain, sequence: 7)
      for position in 0..<wire.count {
        // A fresh opener each time (CTR's keystream and GCM's counter advance only on success).
        let opener = try PacketProtection.opener(cipher: cipher, mac: mac, keys: Self.keys(cipher, mac, seed: 4))
        var tampered = wire
        tampered[position] ^= 0x01
        do {
          let length = try opener.packetLength(Array(tampered.prefix(opener.lengthPrefixBytes)), sequence: 7)
          guard Int(length) == plain.count - 4 else { continue }  // the framer would refuse or wait: covered there
          _ = try opener.open(tampered, sequence: 7)
          XCTFail("\(cipher) \(String(describing: mac)): byte \(position) flipped and the packet opened")
        } catch {
          // Past the length, always the integrity check.
          if position >= 4 {
            XCTAssertEqual(error, .protocolViolation(.packet(.integrity)), "\(cipher) \(String(describing: mac)) byte \(position)")
          }
        }
      }
      // The wrong sequence number fails it too, except AES-GCM, whose nonce is its own counter.
      let opener = try PacketProtection.opener(cipher: cipher, mac: mac, keys: Self.keys(cipher, mac, seed: 4))
      if cipher.isAESGCM {
        XCTAssertNoThrow(try opener.open(wire, sequence: 8))
      } else {
        _ = try? opener.packetLength(Array(wire.prefix(opener.lengthPrefixBytes)), sequence: 8)
        XCTAssertThrowsError(try opener.open(wire, sequence: 8), "\(cipher)")
      }
    }
  }

  func testKeysOfTheWrongSizeAreRefused() {
    let good = Self.keys(.aes256GCM, nil, seed: 1)
    let bad = DirectionKeys(iv: good.iv, key: SecretBytes(copying: [UInt8](repeating: 0, count: 16)), macKey: nil)
    XCTAssertThrows(PacketProtection.invalid) { () throws(SSHError) in try PacketProtection.sealer(cipher: .aes256GCM, mac: nil, keys: bad) }
    XCTAssertThrows(PacketProtection.invalid) { () throws(SSHError) in
      try PacketProtection.opener(cipher: .aes256CTR, mac: nil, keys: Self.keys(.aes256CTR, nil, seed: 1))
    }
    XCTAssertThrows(PacketProtection.invalid) { () throws(SSHError) in
      try PacketProtection.opener(cipher: .aes256GCM, mac: .hmacSHA256, keys: Self.keys(.aes256GCM, .hmacSHA256, seed: 1))
    }
  }

  // MARK: AES-GCM

  /// The 12-byte nonce is the IV; its last 8 bytes count packets (wrapping within those 8), the first 4 never change;
  /// the clear length is the associated data.
  func testAESGCMNonceProgressionAndAssociatedData() throws {
    let key = [UInt8](repeating: 0x42, count: 32)
    let iv: [UInt8] = [0xA1, 0xA2, 0xA3, 0xA4] + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]
    let keys = DirectionKeys(iv: SecretBytes(copying: iv), key: SecretBytes(copying: key), macKey: nil)
    let sealer = try PacketProtection.sealer(cipher: .aes256GCM, mac: nil, keys: keys)
    let counters: [[UInt8]] = [[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE], [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
                               [0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 1]]
    for (index, counter) in counters.enumerated() {
      let plain = Self.packet([UInt8](repeating: UInt8(index), count: 20 + index), for: sealer)
      let wire = try sealer.seal(plain, sequence: UInt32(index))
      let expected = try AES.GCM.seal(plain[4...], using: SymmetricKey(data: key),
                                      nonce: AES.GCM.Nonce(data: Array(iv.prefix(4)) + counter), authenticating: plain[0..<4])
      XCTAssertEqual(wire, Array(plain[0..<4]) + Array(expected.ciphertext) + Array(expected.tag), "packet \(index)")
    }
  }

  // MARK: AES-CTR

  /// NIST SP 800-38A F.5.1, F.5.3, F.5.5: CTR-AES128/192/256 encryption, four blocks, the counter crossing a byte
  /// boundary. Split across two calls: the counter carries over.
  func testAESCTRAgainstNISTVectors() throws {
    let counter = "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
    let plaintext = "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
    let vectors: [(String, String)] = [
      ("2b7e151628aed2a6abf7158809cf4f3c",
       "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee"),
      ("8e73b0f7da0e6452c810f32b809079e562f8ead2522c6b7b",
       "1abc932417521ca24f2b0459fe7e6e0b090339ec0aa6faefd5ccc2c6f4ce8e941e36b26bd1ebc670d1bd1d665620abf74f78a7f6d29809585a97daec58c6b050"),
      ("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4",
       "601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c52b0930daa23de94ce87017ba2d84988ddfc9c58db67aada613c2dd08457941a6"),
    ]
    for (key, ciphertext) in vectors {
      let stream = try AESCTRStream(key: SecretBytes(copying: T.bytes(key)), iv: SecretBytes(copying: T.bytes(counter)))
      var first = Array(T.bytes(plaintext).prefix(16))
      var rest = Array(T.bytes(plaintext).dropFirst(16))
      try stream.apply(&first)
      try stream.apply(&rest)
      XCTAssertEqual(T.hex(first + rest), ciphertext, "key \(key.count * 4) bits")
    }
  }

  /// AES-GCM encrypts with AES-CTR from counter block IV ‖ 00000002: CommonCrypto's CTR must give the same keystream
  /// over many blocks (a second, Apple-internal cross-check of the mode and its counter).
  func testAESCTRMatchesGCMsKeystream() throws {
    let random = SeededRandom(seed: 41)
    for keyBytes in [16, 24, 32] where keyBytes != 24 {
      let key = try random.bytes(keyBytes)
      let nonce = try random.bytes(12)
      let plaintext = try random.bytes(16 * 70)
      let gcm = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
      let stream = try AESCTRStream(key: SecretBytes(copying: key), iv: SecretBytes(copying: nonce + [0, 0, 0, 2]))
      var bytes = plaintext
      for start in stride(from: 0, to: bytes.count, by: 16 * 7) {
        var part = Array(bytes[start..<min(bytes.count, start + 16 * 7)])
        try stream.apply(&part)
        bytes.replaceSubrange(start..<start + part.count, with: part)
      }
      XCTAssertEqual(bytes, Array(gcm.ciphertext))
    }
  }

  /// `-etm@openssh.com`: length clear, the rest encrypted, MAC = HMAC(seq ‖ length ‖ ciphertext). Encrypt-and-MAC:
  /// everything encrypted (the length too), MAC = HMAC(seq ‖ plaintext packet).
  func testTheTwoMACLayouts() throws {
    for mac in MACAlgorithm.allCases {
      let keys = Self.keys(.aes128CTR, mac, seed: 3)
      let sealer = try PacketProtection.sealer(cipher: .aes128CTR, mac: mac, keys: keys)
      let reference = try AESCTRStream(key: keys.key, iv: keys.iv)
      let macKey = keys.macKey!.withUnsafeBytes { SymmetricKey(data: $0) }
      for sequence: UInt32 in [0, 1, 0xDEAD_BEEF] {
        let plain = Self.packet(Array("layout \(sequence)".utf8), for: sealer)
        let wire = try sealer.seal(plain, sequence: sequence)
        func hmac(_ data: [UInt8]) -> [UInt8] {
          let message = Raw.u32(sequence) + data
          return mac.tagBytes == 32 ? Array(HMAC<SHA256>.authenticationCode(for: message, using: macKey))
            : Array(HMAC<SHA512>.authenticationCode(for: message, using: macKey))
        }
        if mac.isEncryptThenMAC {
          var body = Array(plain[4...])
          try reference.apply(&body)
          XCTAssertEqual(wire, Array(plain[0..<4]) + body + hmac(Array(plain[0..<4]) + body), "\(mac)")
        } else {
          var body = plain
          try reference.apply(&body)
          XCTAssertEqual(wire, body + hmac(plain), "\(mac)")
        }
      }
    }
  }

  // MARK: ChaCha20-Poly1305

  /// The payload's ciphertext is RFC 8439's ChaCha20 under the first 32 key bytes from block 1 with the nonce
  /// 0^4 ‖ uint64(seq): exactly CryptoKit's ChaChaPoly ciphertext for that key and nonce. The length is encrypted
  /// under the last 32 bytes at block 0; the tag is Poly1305, keyed by the main key's block 0, over both.
  func testChaChaPolyLayout() throws {
    let key = (0..<64).map { UInt8($0) }
    let keys = DirectionKeys(iv: SecretBytes(copying: []), key: SecretBytes(copying: key), macKey: nil)
    let sealer = try PacketProtection.sealer(cipher: .chacha20Poly1305, mac: nil, keys: keys)
    for sequence: UInt32 in [0, 1, 0x0102_0304, .max] {
      let plain = Self.packet([UInt8](repeating: 0x5A, count: 77), for: sealer)
      let wire = try sealer.seal(plain, sequence: sequence)
      let nonce64 = [0, 0, 0, 0] + Raw.u32(sequence)
      let kit = try ChaChaPoly.seal(plain[4...], using: SymmetricKey(data: key[0..<32]),
                                    nonce: ChaChaPoly.Nonce(data: [0, 0, 0, 0] + nonce64))
      XCTAssertEqual(Array(wire[4..<plain.count]), Array(kit.ciphertext), "payload, sequence \(sequence)")
      let header = try ChaCha20(key: Array(key[32..<64]), nonce: nonce64)
      var length = Array(plain[0..<4])
      header.xor(&length, counter: 0)
      XCTAssertEqual(Array(wire[0..<4]), length, "length, sequence \(sequence)")
      let main = try ChaCha20(key: Array(key[0..<32]), nonce: nonce64)
      let tag = Poly1305.authenticate(Array(wire[0..<plain.count]), key: Array(main.block(counter: 0).prefix(32)))
      XCTAssertEqual(Array(wire[plain.count...]), tag, "tag, sequence \(sequence)")
    }
  }
}
