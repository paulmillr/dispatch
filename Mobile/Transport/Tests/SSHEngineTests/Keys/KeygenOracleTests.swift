import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// The system's ssh-keygen as the oracle: keys of every type and size it generates, in every format and cipher it
/// writes, must parse to exactly the public key and comment of its `.pub` file and its fingerprint, sign with every
/// algorithm, and be refused with the passphrase error for a wrong or missing passphrase. Signatures are checked
/// independently in both directions through SSHSIG (`ssh-keygen -Y sign` / `-Y verify`), rsa-sha2-256 through openssl.
final class KeygenOracleTests: XCTestCase {
  private struct Spec {
    var name: String
    var type: String
    var bits: Int?
    var comment: String { "fictional-\(name)@example.invalid" }
  }

  private static let specs = [
    Spec(name: "ed25519", type: "ed25519"),
    Spec(name: "p256", type: "ecdsa", bits: 256), Spec(name: "p384", type: "ecdsa", bits: 384),
    Spec(name: "p521", type: "ecdsa", bits: 521),
    Spec(name: "rsa2048", type: "rsa", bits: 2048), Spec(name: "rsa3072", type: "rsa", bits: 3072),
    Spec(name: "rsa4096", type: "rsa", bits: 4096),
  ]

  /// Every type and size; OpenSSH format plain and encrypted (ssh-keygen's default cipher, aes256-ctr), PEM and
  /// PKCS#8 (which ssh-keygen cannot write for Ed25519: `KeyFileFormatTests` builds those); signatures both ways.
  func testEveryTypeSizeAndFormat() throws {
    let tool = try KeyTool()
    defer { tool.remove() }
    for spec in Self.specs {
      try tool.generate(spec.name, type: spec.type, bits: spec.bits, comment: spec.comment)
      let line = try tool.publicLine(spec.name)
      let bare = line.split(separator: " ").prefix(2).joined(separator: " ")
      let fingerprint = try tool.fingerprint(spec.name)

      guard let plain = parseKey(try tool.secret(spec.name)) else { continue }
      XCTAssertEqual(plain.authorizedKeysLine, line, spec.name)
      XCTAssertEqual(plain.comment, spec.comment, spec.name)
      XCTAssertEqual(plain.fingerprint, fingerprint, spec.name)
      XCTAssertEqual(plain.keyType, String(line.split(separator: " ")[0]), spec.name)
      checkSigns(plain)
      // A passphrase for an unencrypted file is ignored.
      XCTAssertEqual(parseKey(try tool.secret(spec.name), passphrase: KeyTool.passphrase)?.publicKeyBlob,
                     plain.publicKeyBlob)

      try tool.convert(spec.name, to: spec.name + "-enc", passphrase: KeyTool.passphrase, extra: ["-a", "2"])
      let encryptedFile = try tool.secret(spec.name + "-enc")
      XCTAssertEqual(try OpenSSHParts(KeyArmor.decode(tool.text(spec.name + "-enc")).body).cipher, "aes256-ctr")
      let encrypted = parseKey(encryptedFile, passphrase: KeyTool.passphrase)
      XCTAssertEqual(encrypted?.authorizedKeysLine, line, spec.name)
      XCTAssertEqual(encrypted?.fingerprint, fingerprint, spec.name)
      encrypted.map { checkSigns($0) }
      for passphrase in [KeyTool.wrongPassphrase, "", nil] {
        XCTAssertEqual(parseError(encryptedFile, passphrase: passphrase), .wrongPassphrase,
                       "\(spec.name) passphrase \(passphrase == nil ? "missing" : "wrong")")
      }

      if spec.type != "ed25519" {
        for format in ["PEM", "PKCS8"] {
          let name = spec.name + "-" + format
          try tool.convert(spec.name, to: name, extra: ["-m", format])
          let header = try tool.text(name).split(separator: "\n")[0]
          XCTAssertEqual(header, format == "PEM" ? (spec.type == "rsa" ? "-----BEGIN RSA PRIVATE KEY-----"
            : "-----BEGIN EC PRIVATE KEY-----") : "-----BEGIN PRIVATE KEY-----")
          guard let key = parseKey(try tool.secret(name)) else { continue }
          // PEM has no comment.
          XCTAssertEqual(key.authorizedKeysLine, bare, name)
          XCTAssertEqual(key.comment, "", name)
          XCTAssertEqual(key.fingerprint, fingerprint, name)
          checkSigns(key)
        }
      }

      try crossCheckSignatures(tool, spec.name, key: plain)
    }
  }

  /// Each of our algorithms' signatures verifies with `ssh-keygen -Y verify`, and ssh-keygen's own signature
  /// (`-Y sign`) verifies with ours; a changed message fails both.
  private func crossCheckSignatures(_ tool: KeyTool, _ name: String, key: FileKey) throws {
    let message = Array("a fictional message signed for \(name)".utf8)
    try tool.write("message", bytes: message)
    try tool.write("allowed", "fictional-signer@example.invalid " + key.authorizedKeysLine + "\n")
    let verify = ["-Y", "verify", "-f", tool.path("allowed"), "-I", "fictional-signer@example.invalid",
                  "-n", SSHSig.namespace, "-s", tool.path("ours.sig")]
    for algorithm in key.algorithms {
      let blob = try key.signature(for: SSHSig.signedData(message), algorithm: algorithm)
      try tool.write("ours.sig", SSHSig.armored(publicKeyBlob: key.publicKeyBlob, signatureBlob: blob))
      let good = try tool.run(verify, input: message, check: false)
      XCTAssertEqual(good.status, 0, "\(name) \(algorithm.rawValue): ssh-keygen -Y verify: \(good.standardError)")
      XCTAssertNotEqual(try tool.run(verify, input: message + [0x21], check: false).status, 0, "\(name) changed message")
    }

    try? FileManager.default.removeItem(atPath: tool.path("message.sig"))
    try tool.run(["-Y", "sign", "-f", tool.path(name), "-n", SSHSig.namespace, tool.path("message")])
    let (publicKey, signature) = try SSHSig.parse(tool.text("message.sig"))
    XCTAssertEqual(publicKey, key.publicKeyBlob)
    let algorithm = try XCTUnwrap(SignatureAlgorithm(rawValue: SignatureBlob(decoding: signature).algorithm))
    XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: signature, over: SSHSig.signedData(message),
                                               key: key.publicKey, algorithm: algorithm), "\(name): ssh-keygen -Y sign")
    XCTAssertFalse(SSHSignatureVerifier.isValid(signatureBlob: signature, over: SSHSig.signedData(message + [0x21]),
                                                key: key.publicKey, algorithm: algorithm))
  }

  /// Every cipher ssh-keygen writes (`-Z`), for an Ed25519, a P-384 and an RSA key (whose private section spans many
  /// blocks); the file must really use that cipher. 3des-cbc is refused.
  func testEveryCipher() throws {
    let tool = try KeyTool()
    defer { tool.remove() }
    for spec in [Self.specs[0], Self.specs[2], Self.specs[4]] {
      try tool.generate(spec.name, type: spec.type, bits: spec.bits, comment: spec.comment)
      let line = try tool.publicLine(spec.name)
      for cipher in KeyFileCipher.allCases {
        let name = "\(spec.name)-\(cipher.rawValue)"
        try tool.convert(spec.name, to: name, passphrase: KeyTool.passphrase, extra: ["-Z", cipher.rawValue, "-a", "2"])
        let parts = try OpenSSHParts(KeyArmor.decode(tool.text(name)).body)
        XCTAssertEqual(parts.cipher, cipher.rawValue)
        XCTAssertEqual(parts.kdf, "bcrypt")
        XCTAssertEqual(parts.tail.count, cipher.tagBytes, "\(cipher.rawValue)'s tag follows the section")
        let file = try tool.secret(name)
        let key = parseKey(file, passphrase: KeyTool.passphrase)
        XCTAssertEqual(key?.authorizedKeysLine, line, name)
        key.map { checkSigns($0) }
        XCTAssertEqual(parseError(file, passphrase: KeyTool.wrongPassphrase), .wrongPassphrase, name)
      }
      try tool.convert(spec.name, to: spec.name + "-3des", passphrase: KeyTool.passphrase, extra: ["-Z", "3des-cbc"])
      XCTAssertEqual(parseError(try tool.secret(spec.name + "-3des"), passphrase: KeyTool.passphrase),
                     KeyFileRefusal.cipher.error)
    }
  }

  /// bcrypt round counts: 1, 16 (older ssh-keygen's default), ssh-keygen's current default (24 in OpenSSH 10.5) and
  /// the commonly advised 100. The time each takes in this (debug) build is printed; `Limits.keyFileBcryptRounds`
  /// documents the optimized cost.
  func testRoundCounts() throws {
    let tool = try KeyTool()
    try tool.generate("key", type: "ed25519", comment: "fictional-rounds@example.invalid")
    defer { tool.remove() }
    let line = try tool.publicLine("key")
    for rounds in [1, 16, nil, 100] {
      let name = "key-\(rounds ?? 0)"
      try tool.convert("key", to: name, passphrase: KeyTool.passphrase, extra: rounds.map { ["-a", String($0)] } ?? [])
      let parts = try OpenSSHParts(KeyArmor.decode(tool.text(name)).body)
      var options = TestReader(parts.kdfOptions)
      XCTAssertEqual(try options.string().count, 16)
      let written = Int(try options.uint32())
      if let rounds { XCTAssertEqual(written, rounds) } else { XCTAssertTrue([16, 24].contains(written), "\(written)") }
      let start = Date()
      XCTAssertEqual(parseKey(try tool.secret(name), passphrase: KeyTool.passphrase)?.authorizedKeysLine, line)
      print("KeygenOracleTests: \(written) bcrypt rounds (aes256-ctr\(rounds == nil ? ", ssh-keygen's default" : "")): "
        + String(format: "%.3f s", Date().timeIntervalSince(start)))
    }
  }

  /// The hand-written CRT arithmetic against OpenSSL's: the d mod (p - 1) and d mod (q - 1) that `ssh-keygen -p -m
  /// PEM` writes (computed by OpenSSL's BIGNUM) equal ours for the same d, p and q; OpenSSH's iqmp is PKCS#1's
  /// coefficient; and the OpenSSH file (where ours are used) signs.
  func testRSACRTExponentsMatchOpenSSL() throws {
    let tool = try KeyTool()
    defer { tool.remove() }
    for (index, bits) in [2048, 2048, 2048, 2048, 2048, 3072, 4096, 2056, 3000].enumerated() {
      let name = "rsa\(index)"
      try tool.generate(name, type: "rsa", bits: bits, comment: "fictional-crt-\(index)@example.invalid")
      try tool.convert(name, to: name + ".pem", extra: ["-m", "PEM"])
      let integers = try pkcs1Integers(KeyArmor.decode(tool.text(name + ".pem")).body)
      XCTAssertEqual(integers.count, 9)
      let (d, p, q, dP, dQ, qInv) = (integers[3], integers[4], integers[5], integers[6], integers[7], integers[8])
      let ours = (RSAArithmetic.exponent(SecretBytes(copying: d), prime: SecretBytes(copying: p)),
                  RSAArithmetic.exponent(SecretBytes(copying: d), prime: SecretBytes(copying: q)))
      XCTAssertEqual(ours.0.map { Array($0.withUnsafeBytes { Array($0) }.drop { $0 == 0 }) }, dP, "\(bits) bits: dP")
      XCTAssertEqual(ours.1.map { Array($0.withUnsafeBytes { Array($0) }.drop { $0 == 0 }) }, dQ, "\(bits) bits: dQ")

      // OpenSSH's private section: n, e, d, iqmp, p, q.
      var section = TestReader(try OpenSSHParts(KeyArmor.decode(tool.text(name)).body).section)
      _ = try section.bytes(8)
      _ = try section.string()
      let fields = try (0..<6).map { _ in Array(try section.string().drop { $0 == 0 }) }
      XCTAssertEqual(fields[2], d)
      XCTAssertEqual(fields[3], qInv, "iqmp is PKCS#1's coefficient q⁻¹ mod p")
      XCTAssertEqual(fields[4], p)
      XCTAssertEqual(fields[5], q)
      guard let key = parseKey(try tool.secret(name)) else { continue }
      XCTAssertEqual(key.publicKey.rsaModulusBits, bits)
      checkSigns(key)
    }
  }

  /// rsa-sha2-256 and -512 checked by a third implementation: openssl verifies our signatures with the public key
  /// ssh-keygen exports, and our verifier takes openssl's.
  func testRSASignaturesAgainstOpenSSL() throws {
    guard KeyTool.hasOpenSSL else { throw XCTSkip("\(KeyTool.openssl) is not available") }
    let tool = try KeyTool()
    defer { tool.remove() }
    try tool.generate("rsa", type: "rsa", bits: 2048, comment: "fictional-openssl@example.invalid")
    try tool.convert("rsa", to: "rsa.pem", extra: ["-m", "PEM"])
    try tool.write("public.pem", try tool.run(["-e", "-m", "PKCS8", "-f", tool.path("rsa.pub")]).standardOutput)
    let key = try XCTUnwrap(parseKey(try tool.secret("rsa")))
    let message = Array("fictional message for openssl".utf8)
    try tool.write("message", bytes: message)
    for (algorithm, digest) in [(SignatureAlgorithm.rsaSHA256, "-sha256"), (.rsaSHA512, "-sha512")] {
      let blob = try SignatureBlob(decoding: key.signature(for: message, algorithm: algorithm))
      try tool.write("ours.bin", bytes: blob.signature)
      let verified = try tool.run(KeyTool.openssl, ["dgst", digest, "-verify", tool.path("public.pem"), "-signature",
                                                     tool.path("ours.bin"), tool.path("message")], check: false)
      XCTAssertEqual(verified.status, 0, "\(algorithm.rawValue): \(verified.standardOutput) \(verified.standardError)")

      try tool.run(KeyTool.openssl, ["dgst", digest, "-sign", tool.path("rsa.pem"), "-out", tool.path("theirs.bin"),
                                     tool.path("message")])
      let theirs = try SignatureBlob(algorithm: algorithm.rawValue, signature: tool.bytes("theirs.bin")).encoded()
      XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: theirs, over: message, key: key.publicKey,
                                                 algorithm: algorithm), algorithm.rawValue)
      let other: SignatureAlgorithm = algorithm == .rsaSHA256 ? .rsaSHA512 : .rsaSHA256
      let relabelled = try SignatureBlob(algorithm: other.rawValue, signature: tool.bytes("theirs.bin")).encoded()
      XCTAssertFalse(SSHSignatureVerifier.isValid(signatureBlob: relabelled, over: message, key: key.publicKey,
                                                  algorithm: other), "a \(algorithm.rawValue) signature as \(other)")
    }
  }

  /// Named-curve SEC1 and PKCS#8 files as OpenSSL writes them (ssh-keygen here writes explicit parameters): they
  /// parse to the key `ssh-keygen -y` derives. secp256k1 is refused.
  func testNamedCurveFilesFromOpenSSL() throws {
    guard KeyTool.hasOpenSSL else { throw XCTSkip("\(KeyTool.openssl) is not available") }
    let tool = try KeyTool()
    defer { tool.remove() }
    for curve in ["prime256v1", "secp384r1", "secp521r1", "secp256k1"] {
      try tool.run(KeyTool.openssl, ["ecparam", "-name", curve, "-genkey", "-noout", "-out", tool.path(curve + ".pem")])
      try tool.run(KeyTool.openssl, ["pkcs8", "-topk8", "-nocrypt", "-in", tool.path(curve + ".pem"),
                                     "-out", tool.path(curve + ".p8")])
      // ssh-keygen -y reads only files no one else may read.
      for name in [curve + ".pem", curve + ".p8"] {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tool.path(name))
      }
      for name in [curve + ".pem", curve + ".p8"] {
        if curve == "secp256k1" {
          XCTAssertEqual(parseError(try tool.secret(name)), KeyFileRefusal.keyType.error, name)
          continue
        }
        let derived = try tool.run(["-y", "-f", tool.path(name)]).standardOutput
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = parseKey(try tool.secret(name))
        XCTAssertEqual(key?.authorizedKeysLine, derived, name)
        key.map { checkSigns($0) }
      }
    }
  }

  /// What ssh-keygen writes that is refused: encrypted PEM and PKCS#8, RSA below 2048 bits (each format), a
  /// certificate, public keys in each export format.
  func testRefusedOutputs() throws {
    let tool = try KeyTool()
    defer { tool.remove() }
    try tool.generate("ec", type: "ecdsa", bits: 256, comment: "fictional-refused@example.invalid")
    try tool.convert("ec", to: "ec-pem-enc", passphrase: KeyTool.passphrase, extra: ["-m", "PEM"])
    XCTAssertTrue(try tool.text("ec-pem-enc").contains("Proc-Type: 4,ENCRYPTED"))
    XCTAssertEqual(parseError(try tool.secret("ec-pem-enc"), passphrase: KeyTool.passphrase),
                   KeyFileRefusal.encryptedPEM.error)
    try tool.convert("ec", to: "ec-p8-enc", passphrase: KeyTool.passphrase, extra: ["-m", "PKCS8"])
    XCTAssertEqual(parseError(try tool.secret("ec-p8-enc"), passphrase: KeyTool.passphrase),
                   KeyFileRefusal.encryptedPKCS8.error)
    try tool.generate("rsa", type: "rsa", bits: 2048, comment: "fictional-rsa@example.invalid")
    try tool.convert("rsa", to: "rsa-pem-enc", passphrase: KeyTool.passphrase, extra: ["-m", "PEM"])
    XCTAssertEqual(parseError(try tool.secret("rsa-pem-enc")), KeyFileRefusal.encryptedPEM.error)

    try tool.generate("small", type: "rsa", bits: 1024, comment: "fictional-small@example.invalid")
    XCTAssertEqual(parseError(try tool.secret("small")), KeyFileRefusal.rsaKeySize.error)
    for format in ["PEM", "PKCS8"] {
      try tool.convert("small", to: "small-" + format, extra: ["-m", format])
      XCTAssertEqual(parseError(try tool.secret("small-" + format)), KeyFileRefusal.rsaKeySize.error, format)
    }
    try tool.convert("small", to: "small-enc", passphrase: KeyTool.passphrase, extra: ["-a", "1"])
    XCTAssertEqual(parseError(try tool.secret("small-enc")), KeyFileRefusal.rsaKeySize.error,
                   "refused before the passphrase is asked for")

    try tool.generate("ca", type: "ed25519", comment: "fictional-ca@example.invalid")
    try tool.run(["-q", "-s", tool.path("ca"), "-I", "fictional-identity", "-n", "fictional", tool.path("ec.pub")])
    XCTAssertEqual(parseError(try tool.secret("ec-cert.pub")), KeyFileRefusal.certificate.error)

    XCTAssertEqual(parseError(try tool.secret("ec.pub")), KeyFileRefusal.publicKey.error)
    for format in ["RFC4716", "PKCS8", "PEM"] {
      try tool.write("ec.pub." + format, try tool.run(["-e", "-m", format, "-f", tool.path("ec.pub")]).standardOutput)
      XCTAssertEqual(parseError(try tool.secret("ec.pub." + format)), KeyFileRefusal.publicKey.error, format)
    }
  }
}
