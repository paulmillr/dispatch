import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// Hostile key files: truncations, huge lengths and counts, a huge bcrypt round count, mismatched public and private
/// halves, bad check integers and padding, trailing data; then a deterministic mutation loop over valid files of
/// every kind. The outcome is always an error or a valid key: never a trap, never a hang.
final class HostileKeyFileTests: XCTestCase {
  // MARK: Truncation and lengths

  func testEveryTruncationFails() throws {
    let rsa = try TestRSAKey()
    let binaries: [([UInt8], String)] = [
      (OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey()).binary, "OPENSSH PRIVATE KEY"),
      (OpenSSHParts.p256(P256.Signing.PrivateKey()).binary, "OPENSSH PRIVATE KEY"),
      (rsa.openSSH.binary, "OPENSSH PRIVATE KEY"),
      (rsa.pkcs1, "RSA PRIVATE KEY"),
      (rsa.pkcs8, "PRIVATE KEY"),
      (TestDER.ed25519PKCS8(Curve25519.Signing.PrivateKey()), "PRIVATE KEY"),
      (Array(P384.Signing.PrivateKey().derRepresentation), "PRIVATE KEY"),
    ]
    for (binary, label) in binaries {
      XCTAssertNotNil(parseKey(KeyArmor.secret(binary, label: label)), label)
      // Every prefix (RSA's in steps, each costs an import).
      let step = binary.count > 400 ? 7 : 1
      for length in stride(from: 0, to: binary.count, by: step) {
        let error = parseError(KeyArmor.secret(Array(binary.prefix(length)), label: label))
        XCTAssertTrue(error.map { KeyFileProblem($0) != nil } ?? false, "\(label) cut to \(length): \(String(describing: error))")
      }
    }
    // The text cut short.
    let text = KeyArmor.armor(OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey()).binary, label: "OPENSSH PRIVATE KEY")
    for length in stride(from: 0, to: text.utf8.count, by: 3) {
      XCTAssertNotNil(parseError(SecretBytes(copying: text.utf8.prefix(length))), "text cut to \(length)")
    }
  }

  func testHugeLengthsAndCounts() {
    let parts = OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey())
    let binary = parts.binary
    // Offsets of the envelope's length fields: magic (15), cipher, kdf, options, count, public blob, section.
    let cipherLength = 15, kdfLength = cipherLength + 4 + 4, optionsLength = kdfLength + 4 + 4
    let countField = optionsLength + 4, publicLength = countField + 4
    let sectionLength = publicLength + 4 + parts.publicBlob.count
    func patched(_ offset: Int, _ value: UInt32) -> SecretBytes {
      var copy = binary
      copy.replaceSubrange(offset..<(offset + 4), with: Raw.u32(value))
      return KeyArmor.secret(copy, label: "OPENSSH PRIVATE KEY")
    }
    for offset in [cipherLength, kdfLength, optionsLength, publicLength, sectionLength] {
      for value: UInt32 in [0xFFFF_FFFF, 0x7FFF_FFFF, 0x8000_0000, UInt32(binary.count)] {
        XCTAssertEqual(parseError(patched(offset, value)), KeyFileProblem.damaged.error, "length at \(offset) = \(value)")
      }
    }
    XCTAssertEqual(parseError(patched(countField, 0)), KeyFileProblem.damaged.error)
    for count: UInt32 in [2, 0xFFFF_FFFF] {
      XCTAssertEqual(parseError(patched(countField, count)), KeyFileProblem.moreThanOneKey.error)
    }

    // Inside the private section: the key's lengths and the comment's.
    let key = Curve25519.Signing.PrivateKey()
    let point = Array(key.publicKey.rawRepresentation)
    let blob = Raw.string("ssh-ed25519") + Raw.string(point)
    let fields = [
      Raw.string("ssh-ed25519") + Raw.u32(0xFFFF_FFFF) + point,
      Raw.string("ssh-ed25519") + Raw.string(point) + Raw.u32(0xFFFF_FFF0) + Array(key.rawRepresentation) + point,
      Raw.string("ssh-ed25519") + Raw.string(point) + Raw.string(Array(key.rawRepresentation) + point) + Raw.u32(0xFFFF_FFFF),
      Raw.string("ssh-ed25519") + Raw.string(point) + Raw.string(Array(key.rawRepresentation) + point)
        + Raw.string([UInt8](repeating: 0x61, count: Limits.keyFileCommentBytes + 1)),
    ]
    for (index, field) in fields.enumerated() {
      var section = Raw.u32(7) + Raw.u32(7) + field
      while section.count % 8 != 0 { section.append(UInt8(section.count % 8)) }
      let file = OpenSSHParts(publicBlob: blob, section: section).file
      XCTAssertEqual(parseError(file), KeyFileProblem.damaged.error, "field \(index)")
    }
  }

  // MARK: bcrypt

  func testBcryptRoundsAreBounded() {
    for rounds: UInt32 in [0xFFFF_FFFF, 0x8000_0000, UInt32(Limits.keyFileBcryptRounds + 1)] {
      let start = Date()
      let file = OpenSSHParts.bcryptEnvelope(rounds: rounds).file
      XCTAssertEqual(parseError(file, passphrase: KeyTool.passphrase), KeyFileRefusal.bcryptRounds.error, "\(rounds)")
      XCTAssertEqual(parseError(file), KeyFileRefusal.bcryptRounds.error, "refused before asking for a passphrase")
      XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "refused without deriving")
    }
    // The bound applies as given (tests lower it to keep the mutation loop cheap).
    XCTAssertEqual(parseError(OpenSSHParts.bcryptEnvelope(rounds: 5).file, passphrase: "fictional", maximumRounds: 4),
                   KeyFileRefusal.bcryptRounds.error)
    XCTAssertEqual(parseError(OpenSSHParts.bcryptEnvelope(rounds: 0).file, passphrase: "fictional"), KeyFileProblem.damaged.error)
    // Salt: empty and over the limit; options with trailing bytes.
    for salt in [[], [UInt8](repeating: 1, count: Limits.keyFileSaltBytes + 1)] {
      XCTAssertEqual(parseError(OpenSSHParts.bcryptEnvelope(rounds: 1, salt: salt).file, passphrase: "fictional"),
                     KeyFileProblem.damaged.error)
    }
    var trailing = OpenSSHParts.bcryptEnvelope(rounds: 1)
    trailing.kdfOptions += [0]
    XCTAssertEqual(parseError(trailing.file, passphrase: "fictional"), KeyFileProblem.damaged.error)
    // A section that is not whole blocks is damaged before the KDF runs; one that decrypts to unequal check integers
    // is the passphrase's fault (as OpenSSH reports it). An AEAD file's tag must be there.
    XCTAssertEqual(parseError(OpenSSHParts.bcryptEnvelope(rounds: 1, section: [UInt8](repeating: 1, count: 30)).file,
                              passphrase: "fictional"), KeyFileProblem.damaged.error)
    XCTAssertEqual(parseError(OpenSSHParts.bcryptEnvelope(rounds: 1).file, passphrase: "fictional"), .wrongPassphrase)
    XCTAssertEqual(parseError(OpenSSHParts.bcryptEnvelope(rounds: 1).file), .wrongPassphrase, "no passphrase")
    let gcm = OpenSSHParts.bcryptEnvelope(cipher: "aes256-gcm@openssh.com", rounds: 1)
    XCTAssertEqual(parseError(gcm.file, passphrase: "fictional"), KeyFileProblem.damaged.error, "no tag")
    var tagged = gcm
    tagged.tail = [UInt8](repeating: 3, count: 16)
    XCTAssertEqual(parseError(tagged.file, passphrase: "fictional"), .wrongPassphrase, "the tag fails")
    tagged.tail += [0]
    XCTAssertEqual(parseError(tagged.file, passphrase: "fictional"), KeyFileProblem.damaged.error, "trailing after the tag")
    var chacha = OpenSSHParts.bcryptEnvelope(cipher: "chacha20-poly1305@openssh.com", rounds: 1)
    chacha.tail = [UInt8](repeating: 3, count: 16)
    XCTAssertEqual(parseError(chacha.file, passphrase: "fictional"), .wrongPassphrase)
    // A known cipher with kdf none, or cipher none with bcrypt.
    var noKDF = OpenSSHParts.bcryptEnvelope(rounds: 1)
    noKDF.kdf = "none"
    noKDF.kdfOptions = []
    XCTAssertEqual(parseError(noKDF.file, passphrase: "fictional"), KeyFileProblem.damaged.error)
    var noCipher = OpenSSHParts.bcryptEnvelope(rounds: 1)
    noCipher.cipher = "none"
    XCTAssertEqual(parseError(noCipher.file), KeyFileProblem.damaged.error)
  }

  // MARK: Consistency

  func testMismatchedHalves() throws {
    let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
    XCTAssertEqual(parseError(OpenSSHParts.ed25519(key, privateKey: other).file), KeyFileProblem.mismatchedHalves.error)
    // Ed25519: the 64-byte secret's public half is another key's; the seed is another key's.
    let point = Array(key.publicKey.rawRepresentation), otherPoint = Array(other.publicKey.rawRepresentation)
    let blob = Raw.string("ssh-ed25519") + Raw.string(point)
    for fields in [
      Raw.string("ssh-ed25519") + Raw.string(point) + Raw.string(Array(key.rawRepresentation) + otherPoint),
      Raw.string("ssh-ed25519") + Raw.string(point) + Raw.string(Array(other.rawRepresentation) + point),
      Raw.string("ecdsa-sha2-nistp256") + Raw.string(point),
    ] {
      let file = OpenSSHParts(publicBlob: blob, section: OpenSSHParts.section(fields)).file
      XCTAssertEqual(parseError(file), KeyFileProblem.mismatchedHalves.error)
    }
    // ECDSA: the public point in the section, or the scalar, is another key's.
    let p256 = P256.Signing.PrivateKey(), otherP256 = P256.Signing.PrivateKey()
    let p256Point = Array(p256.publicKey.x963Representation)
    var wrongScalar = OpenSSHParts.ecdsa(.p256, scalar: Array(otherP256.rawRepresentation), point: p256Point)
    XCTAssertEqual(parseError(wrongScalar.file), KeyFileProblem.mismatchedHalves.error)
    wrongScalar.publicBlob = PublicKeyBlob.ecdsa(.p256, point: Array(otherP256.publicKey.x963Representation)).encoded
    XCTAssertEqual(parseError(wrongScalar.file), KeyFileProblem.mismatchedHalves.error)
    // RSA: another key's section; this key's n and e with another key's d, iqmp or p and q.
    let rsa = try TestRSAKey(), otherRSA = try TestRSAKey()
    var swapped = rsa.openSSH
    swapped.section = otherRSA.openSSH.section
    XCTAssertEqual(parseError(swapped.file), KeyFileProblem.mismatchedHalves.error)
    for fields in [rsa.openSSHFields(d: otherRSA.integers[3]), rsa.openSSHFields(iqmp: otherRSA.integers[8]),
                   rsa.openSSHFields(p: otherRSA.integers[4], q: otherRSA.integers[5]),
                   rsa.openSSHFields(p: rsa.integers[5], q: rsa.integers[4])] {
      let file = OpenSSHParts(publicBlob: rsa.publicBlob, section: OpenSSHParts.section(fields)).file
      XCTAssertEqual(parseError(file), KeyFileProblem.mismatchedHalves.error)
    }
    // An even "prime" cannot give d mod (p - 1).
    var evenP = rsa.integers[4]
    evenP[evenP.count - 1] &= 0xFE
    let even = OpenSSHParts(publicBlob: rsa.publicBlob, section: OpenSSHParts.section(rsa.openSSHFields(p: evenP))).file
    XCTAssertEqual(parseError(even), KeyFileProblem.mismatchedHalves.error)
  }

  func testCheckIntegersPaddingAndTrailingData() {
    let key = Curve25519.Signing.PrivateKey()
    let point = Array(key.publicKey.rawRepresentation)
    let fields = Raw.string("ssh-ed25519") + Raw.string(point) + Raw.string(Array(key.rawRepresentation) + point)
    let blob = Raw.string("ssh-ed25519") + Raw.string(point)
    func file(_ section: [UInt8], tail: [UInt8] = []) -> SecretBytes {
      var parts = OpenSSHParts(publicBlob: blob, section: section)
      parts.tail = tail
      return parts.file
    }
    XCTAssertNotNil(parseKey(file(OpenSSHParts.section(fields))))
    let unaligned = Raw.u32(7) + Raw.u32(7) + fields + Raw.string("fictional")
    let damaged: [(String, SecretBytes)] = [
      ("unequal check integers", file(OpenSSHParts.section(fields, check: (7, 8)))),
      ("padding 2, 3, ...", file(OpenSSHParts.section(fields, comment: "fictional!", padding: [2, 3, 4, 5, 6, 7]))),
      ("unaligned", file(unaligned + (unaligned.count % 8 == 0 ? [1] : []))),
      ("padding of 16", file(OpenSSHParts.section(fields, comment: "",
                                                  padding: (1...16).map { UInt8($0) } + [UInt8](repeating: 0, count: 0)))),
      ("trailing after the section", file(OpenSSHParts.section(fields), tail: [0])),
      ("no comment", file(Raw.u32(7) + Raw.u32(7) + fields)),
    ]
    for (name, file) in damaged { XCTAssertEqual(parseError(file), KeyFileProblem.damaged.error, name) }
  }

  // MARK: Mutation loop

  /// Valid files of every kind, mutated deterministically (byte changes, truncation, insertion, deletion, length
  /// fields set to extremes) in their decoded body, re-armored, and parsed with bcrypt held to 4 rounds (the
  /// encrypted ones are written with 1). Each outcome must be an `SSHError` or a key that signs and verifies, and each
  /// parse must take under 2 s.
  func testMutatedFilesNeverTrap() throws {
    var corpus: [(name: String, label: String, body: [UInt8], passphrase: String?, rounds: Int)] = []
    let rsa = try TestRSAKey()
    corpus += [
      ("openssh-ed25519", "OPENSSH PRIVATE KEY", OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey()).binary, nil, 300),
      ("openssh-p256", "OPENSSH PRIVATE KEY", OpenSSHParts.p256(P256.Signing.PrivateKey()).binary, nil, 300),
      ("openssh-p521", "OPENSSH PRIVATE KEY", OpenSSHParts.p521(P521.Signing.PrivateKey()).binary, nil, 300),
      ("openssh-rsa", "OPENSSH PRIVATE KEY", rsa.openSSH.binary, nil, 300),
      ("pkcs1-rsa", "RSA PRIVATE KEY", rsa.pkcs1, nil, 300),
      ("pkcs8-rsa", "PRIVATE KEY", rsa.pkcs8, nil, 300),
      ("pkcs8-p256", "PRIVATE KEY", Array(P256.Signing.PrivateKey().derRepresentation), nil, 300),
      ("pkcs8-p521", "PRIVATE KEY", Array(P521.Signing.PrivateKey().derRepresentation), nil, 300),
      ("pkcs8-ed25519", "PRIVATE KEY", TestDER.ed25519PKCS8(Curve25519.Signing.PrivateKey()), nil, 300),
      ("bcrypt-envelope", "OPENSSH PRIVATE KEY", OpenSSHParts.bcryptEnvelope(rounds: 1).binary, "fictional", 150),
    ]
    // Encrypted files and explicit-parameter PEM files need ssh-keygen; without it the rest still runs.
    if let tool = try? KeyTool() {
      defer { tool.remove() }
      try tool.generate("ed25519", type: "ed25519", comment: "fictional-mutation@example.invalid")
      try tool.generate("p256", type: "ecdsa", bits: 256, comment: "fictional-mutation@example.invalid")
      for cipher in ["aes256-ctr", "aes256-cbc", "aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com"] {
        try tool.convert("ed25519", to: cipher, passphrase: KeyTool.passphrase, extra: ["-Z", cipher, "-a", "1"])
        corpus.append(("openssh-ed25519-" + cipher, "OPENSSH PRIVATE KEY", try KeyArmor.decode(tool.text(cipher)).body,
                       KeyTool.passphrase, 120))
      }
      for format in ["PEM", "PKCS8"] {
        try tool.convert("p256", to: "p256-" + format, extra: ["-m", format])
        let (label, body) = try KeyArmor.decode(tool.text("p256-" + format))
        corpus.append(("explicit-p256-" + format, label, body, nil, 300))
      }
    }

    let random = SeededRandom(seed: 0x5EED_4B45_5953)
    var outcomes: [String: Int] = [:]
    var slowest = 0.0
    for entry in corpus {
      // Every entry but the bcrypt envelope (whose section is not real ciphertext) is a valid key unmutated.
      if entry.name != "bcrypt-envelope" {
        XCTAssertNotNil(parseKey(KeyArmor.secret(entry.body, label: entry.label), passphrase: entry.passphrase,
                                 maximumRounds: 4), entry.name)
      }
      for iteration in 0..<entry.rounds {
        let mutated = Self.mutate(entry.body, random)
        let file = iteration % 10 == 9
          ? Self.mutateText(KeyArmor.armor(mutated, label: entry.label), random)
          : KeyArmor.secret(mutated, label: entry.label)
        let start = Date()
        do {
          let key = try KeyFile.parse(file, passphrase: entry.passphrase.map(secret), maximumRounds: 4)
          outcomes["parsed", default: 0] += 1
          XCTAssertEqual(try? PublicKeyBlob(decoding: key.publicKeyBlob), key.publicKey, entry.name)
          let data = Array("fictional".utf8)
          let algorithm = key.algorithms[0]
          let blob = try key.signature(for: data, algorithm: algorithm)
          XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: blob, over: data, key: key.publicKey, algorithm: algorithm),
                        "\(entry.name) #\(iteration) parsed to a key that does not verify")
        } catch {
          let kind = KeyFileProblem(error).map { "\($0)" } ?? KeyFileRefusal(error).map { "\($0)" } ?? "\(error)"
          outcomes[kind, default: 0] += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        slowest = max(slowest, elapsed)
        XCTAssertLessThan(elapsed, 2, "\(entry.name) #\(iteration) took \(elapsed) s")
      }
    }
    print("HostileKeyFileTests: \(corpus.count) files, outcomes \(outcomes.sorted { $0.key < $1.key }), slowest "
      + String(format: "%.3f s", slowest))
  }

  private static let extremes: [UInt32] = [0, 1, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF]

  static func mutate(_ input: [UInt8], _ random: SeededRandom) -> [UInt8] {
    var bytes = input
    for _ in 0..<(1 + random.below(3)) {
      guard !bytes.isEmpty else { break }
      let at = random.below(bytes.count)
      switch random.below(8) {
      case 0: bytes[at] ^= UInt8(1 << random.below(8))
      case 1: bytes[at] = [0x00, 0xFF, 0x7F, 0x80, 0x01][random.below(5)]
      case 2: bytes = Array(bytes.prefix(at))
      case 3: bytes.insert(contentsOf: (0..<(1 + random.below(8))).map { _ in UInt8(random.below(256)) }, at: at)
      case 4: bytes.removeSubrange(at..<min(bytes.count, at + 1 + random.below(16)))
      case 5, 6:
        let start = min(at, max(0, bytes.count - 4))
        let value = random.below(3) == 0 ? UInt32(bytes.count - start) : extremes[random.below(extremes.count)]
        bytes.replaceSubrange(start..<min(bytes.count, start + 4), with: Raw.u32(value))
      default: bytes += bytes[at..<min(bytes.count, at + 1 + random.below(32))]
      }
    }
    return bytes
  }

  static func mutateText(_ text: String, _ random: SeededRandom) -> SecretBytes {
    var bytes = Array(text.utf8)
    let at = random.below(bytes.count)
    switch random.below(4) {
    case 0: bytes[at] = [UInt8(ascii: "="), UInt8(ascii: "-"), 0x0A, 0x20, UInt8(ascii: ":"), 0x80][random.below(6)]
    case 1: bytes.remove(at: at)
    case 2: bytes.insert(contentsOf: Array("-----END OPENSSH PRIVATE KEY-----\n".utf8), at: at)
    default: bytes.insert(contentsOf: Array("\r\n".utf8), at: at)
    }
    return SecretBytes(copying: bytes)
  }
}
