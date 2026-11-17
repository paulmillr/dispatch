import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// Key file formats without ssh-keygen: keys generated in-process (CryptoKit, Security) and encoded by the tests' own
/// writers, or by Apple's (CryptoKit's `pemRepresentation`, Security's PKCS#1 export); every refusal by its distinct
/// error; the armor's and DER's rules.
final class KeyFileFormatTests: XCTestCase {
  // MARK: Read

  func testOpenSSHKeysBuiltInProcess() throws {
    let ed25519 = Curve25519.Signing.PrivateKey()
    let p256 = P256.Signing.PrivateKey(), p384 = P384.Signing.PrivateKey(), p521 = P521.Signing.PrivateKey()
    let rsa = try TestRSAKey()
    let cases: [(OpenSSHParts, [UInt8])] = [
      (.ed25519(ed25519, comment: "Zoë's fictional key"), Raw.string("ssh-ed25519") + Raw.string(Array(ed25519.publicKey.rawRepresentation))),
      (.p256(p256), PublicKeyBlob.ecdsa(.p256, point: Array(p256.publicKey.x963Representation)).encoded),
      (.p384(p384), PublicKeyBlob.ecdsa(.p384, point: Array(p384.publicKey.x963Representation)).encoded),
      (.p521(p521), PublicKeyBlob.ecdsa(.p521, point: Array(p521.publicKey.x963Representation)).encoded),
      (rsa.openSSH, rsa.publicBlob),
    ]
    for (parts, blob) in cases {
      guard let key = parseKey(parts.file) else { continue }
      XCTAssertEqual(key.publicKeyBlob, blob)
      checkSigns(key)
    }
    XCTAssertEqual(parseKey(cases[0].0.file)?.comment, "Zoë's fictional key")
    XCTAssertTrue(parseKey(cases[0].0.file)?.authorizedKeysLine.hasSuffix(" Zoë's fictional key") ?? false)
    // A comment's line break cannot split the authorized_keys line; an empty comment adds nothing.
    let broken = parseKey(OpenSSHParts.ed25519(ed25519, comment: "fictional\nssh-ed25519 AAAA").file)
    XCTAssertEqual(broken?.authorizedKeysLine.contains("\n"), false)
    let bare = parseKey(OpenSSHParts.ed25519(ed25519, comment: "").file)
    XCTAssertEqual(bare?.authorizedKeysLine.split(separator: " ").count, 2)
    // P-521's scalar may be shorter than 66 bytes (its top byte is 0 or 1): an mpint drops leading zeros.
    let shortScalar = OpenSSHParts.ecdsa(.p521, scalar: Array(p521.rawRepresentation.drop { $0 == 0 }),
                                        point: Array(p521.publicKey.x963Representation))
    XCTAssertNotNil(parseKey(shortScalar.file))
  }

  /// PEM and PKCS#8 as Apple's encoders write them (named curves), and as the tests' DER writer builds them.
  func testPEMKeysBuiltInProcess() throws {
    let p256 = P256.Signing.PrivateKey(), p384 = P384.Signing.PrivateKey(), p521 = P521.Signing.PrivateKey()
    for (pem, point) in [(p256.pemRepresentation, p256.publicKey.x963Representation),
                         (p384.pemRepresentation, p384.publicKey.x963Representation),
                         (p521.pemRepresentation, p521.publicKey.x963Representation)] {
      let key = parseKey(secret(pem))
      XCTAssertEqual(key.map { Array($0.publicKey.encoded) },
                     key.map { PublicKeyBlob.ecdsa($0.publicKey.ecdsaCurve!, point: Array(point)).encoded })
      key.map { checkSigns($0) }
    }

    // SEC1 with a named curve and the public key, and without the public key (then PKCS#8 names the curve).
    let scalar = Array(p256.rawRepresentation), point = Array(p256.publicKey.x963Representation)
    let sec1 = TestDER.sequence(TestDER.integer(1), TestDER.octetString(scalar), TestDER.tlv(0xA0, TestDER.oid(TestDER.prime256v1)),
                                TestDER.tlv(0xA1, TestDER.bitString(point)))
    XCTAssertEqual(parseKey(KeyArmor.secret(sec1, label: "EC PRIVATE KEY"))?.publicKey, .ecdsa(.p256, point: point))
    let bareSEC1 = TestDER.sequence(TestDER.integer(1), TestDER.octetString(scalar))
    let p8 = TestDER.pkcs8(algorithm: TestDER.ecPublicKey, parameters: TestDER.oid(TestDER.prime256v1), privateKey: bareSEC1)
    XCTAssertEqual(parseKey(KeyArmor.secret(p8, label: "PRIVATE KEY"))?.publicKey, .ecdsa(.p256, point: point))
    // Without a curve anywhere it is damaged; a SEC1 curve other than PKCS#8's too.
    XCTAssertEqual(parseError(KeyArmor.secret(bareSEC1, label: "EC PRIVATE KEY")), KeyFileProblem.damaged.error)
    let otherCurve = TestDER.pkcs8(algorithm: TestDER.ecPublicKey, parameters: TestDER.oid(TestDER.prime256v1),
      privateKey: TestDER.sequence(TestDER.integer(1), TestDER.octetString(scalar),
                                   TestDER.tlv(0xA0, TestDER.oid([0x2B, 0x81, 0x04, 0x00, 0x22]))))
    XCTAssertEqual(parseError(KeyArmor.secret(otherCurve, label: "PRIVATE KEY")), KeyFileProblem.damaged.error)
    // A public key that is another key's.
    let otherPoint = Array(P256.Signing.PrivateKey().publicKey.x963Representation)
    let mismatched = TestDER.sequence(TestDER.integer(1), TestDER.octetString(scalar),
                                      TestDER.tlv(0xA0, TestDER.oid(TestDER.prime256v1)),
                                      TestDER.tlv(0xA1, TestDER.bitString(otherPoint)))
    XCTAssertEqual(parseError(KeyArmor.secret(mismatched, label: "EC PRIVATE KEY")), KeyFileProblem.mismatchedHalves.error)

    // RSA: Security's own PKCS#1 export, and PKCS#8 around it.
    let rsa = try TestRSAKey()
    for (body, label) in [(rsa.pkcs1, "RSA PRIVATE KEY"), (rsa.pkcs8, "PRIVATE KEY")] {
      let key = parseKey(KeyArmor.secret(body, label: label))
      XCTAssertEqual(key?.publicKeyBlob, rsa.publicBlob, label)
      key.map { checkSigns($0) }
    }
    let noParameters = TestDER.pkcs8(algorithm: TestDER.rsaEncryption, privateKey: rsa.pkcs1)
    XCTAssertEqual(parseKey(KeyArmor.secret(noParameters, label: "PRIVATE KEY"))?.publicKeyBlob, rsa.publicBlob)
    let withPublic = TestDER.pkcs8(algorithm: TestDER.rsaEncryption, parameters: [5, 0], privateKey: rsa.pkcs1,
                                   publicKey: TestDER.sequence(TestDER.integer(rsa.n), TestDER.integer(rsa.e)))
    XCTAssertEqual(parseKey(KeyArmor.secret(withPublic, label: "PRIVATE KEY"))?.publicKeyBlob, rsa.publicBlob)
    let otherRSA = try TestRSAKey()
    let wrongPublic = TestDER.pkcs8(algorithm: TestDER.rsaEncryption, parameters: [5, 0], privateKey: rsa.pkcs1,
                                    publicKey: TestDER.sequence(TestDER.integer(otherRSA.n), TestDER.integer(otherRSA.e)))
    XCTAssertEqual(parseError(KeyArmor.secret(wrongPublic, label: "PRIVATE KEY")), KeyFileProblem.mismatchedHalves.error)
  }

  /// RFC 8410 Ed25519 PKCS#8 (ssh-keygen cannot write it): v1, v2 with the matching public key, and refusals.
  func testEd25519PKCS8() {
    let key = Curve25519.Signing.PrivateKey()
    let point = Array(key.publicKey.rawRepresentation)
    let v1 = TestDER.ed25519PKCS8(key)
    XCTAssertEqual(v1.count, 48, "RFC 8410's fixed layout")
    let parsed = parseKey(KeyArmor.secret(v1, label: "PRIVATE KEY"))
    XCTAssertEqual(parsed?.publicKey, .ed25519(point))
    parsed.map { checkSigns($0) }
    XCTAssertEqual(parseKey(KeyArmor.secret(TestDER.ed25519PKCS8(key, publicKey: point), label: "PRIVATE KEY"))?.publicKey,
                   .ed25519(point))
    let otherPoint = Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation)
    XCTAssertEqual(parseError(KeyArmor.secret(TestDER.ed25519PKCS8(key, publicKey: otherPoint), label: "PRIVATE KEY")),
                   KeyFileProblem.mismatchedHalves.error)
    // Parameters present (RFC 8410: absent), a 31-byte seed.
    let parameters = TestDER.pkcs8(algorithm: TestDER.ed25519, parameters: [5, 0],
                                   privateKey: TestDER.octetString(Array(key.rawRepresentation)))
    let short = TestDER.pkcs8(algorithm: TestDER.ed25519, privateKey: TestDER.octetString(Array(key.rawRepresentation.prefix(31))))
    for body in [parameters, short] {
      XCTAssertEqual(parseError(KeyArmor.secret(body, label: "PRIVATE KEY")), KeyFileProblem.damaged.error)
    }
  }

  // MARK: Refused, each with its own error

  func testRefusalTextsAreDistinct() {
    let texts = KeyFileRefusal.allCases.map(\.rawValue) + KeyFileProblem.allCases.map(\.rawValue)
    XCTAssertEqual(Set(texts).count, texts.count)
    for refusal in KeyFileRefusal.allCases {
      XCTAssertEqual(KeyFileRefusal(refusal.error), refusal)
      XCTAssertNil(KeyFileProblem(refusal.error))
      XCTAssertEqual(refusal.error.dmsCode, -8)
    }
    for problem in KeyFileProblem.allCases {
      XCTAssertEqual(KeyFileProblem(problem.error), problem)
      XCTAssertEqual(problem.error.dmsCode, -5)
    }
    XCTAssertEqual(SSHError.wrongPassphrase.dmsCode, -6)
    XCTAssertEqual(KeyFileRefusal.rsaKeySize.rawValue,
                   "RSA keys must have \(Limits.rsaMinimumBits) to \(Limits.rsaMaximumBits) bits")
  }

  func testRefusedFormats() {
    func openSSH(type: String, fields: [UInt8]) -> SecretBytes {
      OpenSSHParts(publicBlob: Raw.string(type) + fields, section: OpenSSHParts.section(Raw.string(type) + fields)).file
    }
    var kdf = OpenSSHParts.bcryptEnvelope(rounds: 2)
    kdf.kdf = "scrypt"
    let dsaFields = Raw.string([0x41]) + Raw.string([0x07]) + Raw.string([0x03]) + Raw.string([0x05])
    let cases: [(String, SecretBytes, KeyFileRefusal)] = [
      ("PPK v3", secret("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: fictional\nPublic-Lines: 1\nAAAA\n"),
       .puttyKey),
      ("PPK v2 after a BOM and blank lines",
       SecretBytes(copying: [0xEF, 0xBB, 0xBF] + Array("\n\nPuTTY-User-Key-File-2: ssh-rsa\r\nEncryption: aes256-cbc\r\n".utf8)),
       .puttyKey),
      ("legacy encrypted PEM", secret("-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n"
        + "DEK-Info: AES-128-CBC,000102030405060708090A0B0C0D0E0F\n\nAAAA\n-----END RSA PRIVATE KEY-----\n"), .encryptedPEM),
      ("legacy encrypted EC PEM", secret("-----BEGIN EC PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: DES-EDE3-CBC,0001020304050607\n\nAAAA\n-----END EC PRIVATE KEY-----\n"), .encryptedPEM),
      ("encrypted PKCS#8", KeyArmor.secret([0x30, 0x00], label: "ENCRYPTED PRIVATE KEY"), .encryptedPKCS8),
      ("OpenSSH DSA", openSSH(type: "ssh-dss", fields: dsaFields), .dsa),
      ("PEM DSA", KeyArmor.secret(TestDER.sequence(TestDER.integer(0), TestDER.integer(7)), label: "DSA PRIVATE KEY"), .dsa),
      ("PKCS#8 DSA", KeyArmor.secret(TestDER.pkcs8(algorithm: TestDER.dsa, parameters: TestDER.sequence(TestDER.integer(7)),
                                                   privateKey: TestDER.integer(3)), label: "PRIVATE KEY"), .dsa),
      ("sk-ed25519", openSSH(type: "sk-ssh-ed25519@openssh.com", fields: Raw.string(Fixture.ed25519Key) + Raw.string("ssh:")),
       .securityKey),
      ("sk-ecdsa", openSSH(type: "sk-ecdsa-sha2-nistp256@openssh.com",
                           fields: Raw.string("nistp256") + Raw.string([4] + [UInt8](repeating: 1, count: 64)) + Raw.string("ssh:")),
       .securityKey),
      ("OpenSSH certificate", openSSH(type: "ssh-ed25519-cert-v01@openssh.com", fields: Raw.string([1, 2, 3])), .certificate),
      ("certificate line", secret("ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQ fictional\n"), .certificate),
      ("X.509 certificate", KeyArmor.secret([0x30, 0x00], label: "CERTIFICATE"), .certificate),
      ("public key line", secret("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER fictional\n"),
       .publicKey),
      ("RFC 4716 public key", secret("---- BEGIN SSH2 PUBLIC KEY ----\nComment: \"fictional\"\nAAAA\n---- END SSH2 PUBLIC KEY ----\n"),
       .publicKey),
      ("PEM public key", KeyArmor.secret([0x30, 0x00], label: "PUBLIC KEY"), .publicKey),
      ("ssh.com private key", secret("---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: \"fictional\"\nP2/56w==\n"
        + "---- END SSH2 ENCRYPTED PRIVATE KEY ----\n"), .foreignFormat),
      ("ssh.com private key, five dashes", KeyArmor.secret([1, 2, 3], label: "SSH2 ENCRYPTED PRIVATE KEY"), .foreignFormat),
      ("OpenSSH ssh-ed448", openSSH(type: "ssh-ed448", fields: Raw.string([UInt8](repeating: 1, count: 57))), .keyType),
      ("PKCS#8 X25519", KeyArmor.secret(TestDER.pkcs8(algorithm: TestDER.x25519, privateKey: TestDER.octetString(
        [UInt8](repeating: 1, count: 32))), label: "PRIVATE KEY"), .keyType),
      ("PKCS#8 secp256k1", KeyArmor.secret(TestDER.pkcs8(algorithm: TestDER.ecPublicKey, parameters: TestDER.oid(TestDER.secp256k1),
        privateKey: TestDER.sequence(TestDER.integer(1), TestDER.octetString([UInt8](repeating: 1, count: 32)))),
                                        label: "PRIVATE KEY"), .keyType),
      ("SEC1 secp256k1", KeyArmor.secret(TestDER.sequence(TestDER.integer(1), TestDER.octetString([UInt8](repeating: 1, count: 32)),
        TestDER.tlv(0xA0, TestDER.oid(TestDER.secp256k1))), label: "EC PRIVATE KEY"), .keyType),
      ("unknown cipher", OpenSSHParts.bcryptEnvelope(cipher: "aes256-ofb", rounds: 2).file, .cipher),
      ("3des-cbc", OpenSSHParts.bcryptEnvelope(cipher: "3des-cbc", rounds: 2).file, .cipher),
      ("scrypt KDF", kdf.file, .kdf),
    ]
    for (name, file, refusal) in cases {
      XCTAssertEqual(parseError(file, passphrase: "fictional"), refusal.error, name)
      // A refusal never depends on the passphrase.
      XCTAssertEqual(parseError(file), refusal.error, name)
    }
  }

  /// Explicit curve parameters are accepted only when every field is the named curve's (ssh-keygen writes them; the
  /// oracle tests parse its files). Built here from P-256's constants: one changed field makes another curve.
  func testExplicitCurveParameters() throws {
    let key = P256.Signing.PrivateKey()
    let domain = try XCTUnwrap(ECDomain.all.first { $0.curve == .p256 })
    let generator = ECKeys.generator(.p256)
    XCTAssertEqual(generator.count, 65)
    func file(prime: [UInt8] = domain.prime, a: [UInt8] = domain.a, b: [UInt8] = domain.b, base: [UInt8]? = nil,
              order: [UInt8] = domain.order, cofactor: Int? = 1, fieldType: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x01, 0x01])
      -> SecretBytes {
      let parameters = TestDER.sequence(
        TestDER.integer(1), TestDER.sequence(TestDER.oid(fieldType), TestDER.integer(prime)),
        TestDER.sequence(TestDER.octetString(a), TestDER.octetString(b), TestDER.bitString([UInt8](repeating: 0xC4, count: 20))),
        TestDER.octetString(base ?? generator), TestDER.integer(order), cofactor.map { TestDER.integer($0) } ?? [])
      return KeyArmor.secret(TestDER.sequence(TestDER.integer(1), TestDER.octetString(Array(key.rawRepresentation)),
                                              TestDER.tlv(0xA0, parameters)), label: "EC PRIVATE KEY")
    }
    XCTAssertEqual(parseKey(file())?.publicKey, .ecdsa(.p256, point: Array(key.publicKey.x963Representation)))
    XCTAssertNotNil(parseKey(file(cofactor: nil)), "the cofactor is optional")
    var b = domain.b
    b[5] ^= 1
    var order = domain.order
    order[31] ^= 2
    let refused: [(String, SecretBytes)] = [
      ("b", file(b: b)), ("a", file(a: domain.b)), ("order", file(order: order)), ("cofactor", file(cofactor: 4)),
      ("base", file(base: Array(key.publicKey.x963Representation))), ("prime", file(prime: domain.order)),
      ("field type", file(fieldType: [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x01, 0x02])),
    ]
    for (field, body) in refused { XCTAssertEqual(parseError(body), KeyFileRefusal.keyType.error, field) }
  }

  /// Every curve constant has its curve's width, and the named curves' generators are CryptoKit's.
  func testCurveConstants() {
    for domain in ECDomain.all {
      let width = domain.curve.scalarBytes
      XCTAssertEqual(domain.prime.count, width, "\(domain.curve)")
      XCTAssertEqual(domain.b.count, width, "\(domain.curve)")
      XCTAssertEqual(domain.order.count, width, "\(domain.curve)")
      XCTAssertEqual(domain.prime.last, 0xFF)
      XCTAssertEqual(ECKeys.generator(domain.curve).count, domain.curve.pointBytes)
    }
  }

  // MARK: Text, armor and base64

  func testNotAKeyFile() {
    XCTAssertEqual(parseError(SecretBytes(copying: [0x2D, 0x80, 0x00, 0xFF])), KeyFileProblem.notText.error)
    XCTAssertEqual(parseError(secret("hello, fictional world\n")), KeyFileProblem.notAKey.error)
    XCTAssertEqual(parseError(secret("")), KeyFileProblem.notAKey.error)
    XCTAssertEqual(parseError(KeyArmor.secret([1, 2, 3], label: "FICTIONAL THING")), KeyFileProblem.notAKey.error)
    XCTAssertEqual(parseError(SecretBytes(copying: [UInt8](repeating: 0x41, count: Limits.keyFileBytes + 1))),
                   KeyFileProblem.tooLarge.error)
    // Text before the armor (an OpenSSL "Bag Attributes" export) is not taken.
    let key = OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey())
    let armored = KeyArmor.armor(key.binary, label: "OPENSSH PRIVATE KEY")
    XCTAssertEqual(parseError(secret("Bag Attributes\n" + armored)), KeyFileProblem.notAKey.error)
  }

  func testArmorLayout() {
    let key = OpenSSHParts.ed25519(Curve25519.Signing.PrivateKey())
    let armored = KeyArmor.armor(key.binary, label: "OPENSSH PRIVATE KEY")
    let accepted = [
      armored.replacingOccurrences(of: "\n", with: "\r\n"),
      "\n\n  " + armored.replacingOccurrences(of: "\n", with: "  \n\t") + "\n\n",
      KeyArmor.armor(key.binary, label: "OPENSSH PRIVATE KEY", width: 64),
      KeyArmor.armor(key.binary, label: "OPENSSH PRIVATE KEY", width: 4),
      String(armored.dropLast()),
    ]
    for text in accepted { XCTAssertNotNil(parseKey(secret(text)), text.debugDescription) }
    XCTAssertNotNil(parseKey(SecretBytes(copying: [0xEF, 0xBB, 0xBF] + Array(armored.utf8))), "a byte order mark")

    let lines = armored.split(separator: "\n").map(String.init)
    let body = lines[1..<(lines.count - 1)]
    let damaged: [(String, String)] = [
      ("no end", lines.dropLast().joined(separator: "\n")),
      ("another end", (lines.dropLast() + ["-----END RSA PRIVATE KEY-----"]).joined(separator: "\n")),
      ("text after", armored + "fictional trailing text\n"),
      ("an empty line inside", ([lines[0], body.first!, ""] + body.dropFirst() + [lines.last!]).joined(separator: "\n")),
      ("a header", ([lines[0], "Comment: fictional"] + body + [lines.last!]).joined(separator: "\n")),
      ("a character outside base64", armored.replacingOccurrences(of: "AAAA", with: "AA*A")),
      ("a space inside a line", armored.replacingOccurrences(of: "AAAA", with: "AA A")),
    ]
    for (name, text) in damaged { XCTAssertEqual(parseError(secret(text)), KeyFileProblem.damaged.error, name) }
    XCTAssertEqual(parseError(secret(armored + "\n" + armored)), KeyFileProblem.moreThanOneKey.error)
  }

  func testStrictBase64() throws {
    // "AQID" is 01 02 03; "AQI=" 01 02; "AQ==" 01. Each accepted form, then its non-canonical and malformed variants.
    func decode(_ text: String) -> [UInt8]? {
      let bytes = Array(text.utf8)
      return try? withTypedBytes(of: bytes) { (buffer) throws(SSHError) in
        try Armor.decodeBase64(buffer, lines: [0..<bytes.count]).withUnsafeBytes { Array($0) }
      }
    }
    XCTAssertEqual(decode("AQID"), [1, 2, 3])
    XCTAssertEqual(decode("AQI="), [1, 2])
    XCTAssertEqual(decode("AQ=="), [1])
    XCTAssertEqual(decode("+/+/"), [0xFB, 0xFF, 0xBF])
    for bad in ["AQIDA", "AQI", "AQJ=", "AR==", "A===", "====", "AQ=D", "=QID", ""] {
      XCTAssertNil(decode(bad), bad)
    }
    // Across lines.
    let bytes = Array("AQ\nID".utf8)
    let split = try withTypedBytes(of: bytes) { (buffer) throws(SSHError) in
      try Armor.decodeBase64(buffer, lines: [0..<2, 3..<5]).withUnsafeBytes { Array($0) }
    }
    XCTAssertEqual(split, [1, 2, 3])
  }

  // MARK: DER

  func testStrictDER() throws {
    let rsa = try TestRSAKey()
    func parsed(_ body: [UInt8]) -> SSHError? { parseError(KeyArmor.secret(body, label: "RSA PRIVATE KEY")) }
    XCTAssertNotNil(parseKey(KeyArmor.secret(rsa.pkcs1, label: "RSA PRIVATE KEY")))
    let contents = Array(rsa.pkcs1[4...])
    XCTAssertEqual(rsa.pkcs1[1], 0x82, "a 2048-bit key's SEQUENCE has a two-byte length")
    let damaged: [(String, [UInt8])] = [
      ("indefinite length", [0x30, 0x80] + contents + [0, 0]),
      ("non-minimal length", [0x30, 0x83, 0x00] + Array(rsa.pkcs1[2...])),
      ("length past the end", [0x30, 0x82, 0xFF, 0xFF] + contents),
      ("trailing bytes", rsa.pkcs1 + [0]),
      ("multi-prime version", [0x30, 0x82] + Array(rsa.pkcs1[2..<4]) + [0x02, 0x01, 0x01] + Array(rsa.pkcs1[7...])),
      ("truncated", Array(rsa.pkcs1.dropLast())),
      ("a field missing", TestDER.sequence(TestDER.integer(0), TestDER.integer(rsa.n), TestDER.integer(rsa.e))),
      ("a negative INTEGER", TestDER.tlv(0x30, ([TestDER.integer(0), TestDER.integer(rsa.n), [0x02, 0x01, 0x81]]
        + (3..<9).map { TestDER.integer(rsa.integers[$0]) }).flatMap { $0 })),
      ("a non-minimal INTEGER", TestDER.tlv(0x30, ([TestDER.integer(0), TestDER.integer(rsa.n), [0x02, 0x04, 0x00, 0x01, 0x00, 0x01]]
        + (3..<9).map { TestDER.integer(rsa.integers[$0]) }).flatMap { $0 })),
    ]
    for (name, body) in damaged {
      XCTAssertEqual(parseError(KeyArmor.secret(body, label: "RSA PRIVATE KEY")), KeyFileProblem.damaged.error, name)
    }
    // Structurally sound, inconsistent values. Security signs with the CRT values (p, q, dP, dQ, qInv) and never
    // uses d: a wrong d with right CRT values still makes correct signatures (and parses). A wrong dP does not:
    // Security refuses the key or its signing check fails.
    var wrongD = rsa.integers
    wrongD[3] = try TestRSAKey().integers[3]
    let harmless = TestDER.tlv(0x30, (0..<9).map { TestDER.integer(wrongD[$0]) }.flatMap { $0 })
    if let key = parseKey(KeyArmor.secret(harmless, label: "RSA PRIVATE KEY")) { checkSigns(key) }
    var wrongDP = rsa.integers
    wrongDP[6][wrongDP[6].count - 1] ^= 2
    let inconsistent = TestDER.tlv(0x30, (0..<9).map { TestDER.integer(wrongDP[$0]) }.flatMap { $0 })
    XCTAssertNotNil(parsed(inconsistent))
  }
}

extension PublicKeyBlob {
  var ecdsaCurve: ECDSACurve? {
    if case .ecdsa(let curve, _) = self { return curve }
    return nil
  }
}
