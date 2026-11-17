import CryptoKit
import Foundation
import Security
import XCTest
@testable import SSHEngine

/// The system's ssh-keygen (and openssl, where a test needs it) in a private temporary directory that is removed
/// afterwards. Each tool runs with a minimal environment: HOME is the directory and there is no agent socket, so
/// nothing reads or writes the user's ~/.ssh. Keys are generated at test time with fictional comments and passphrases.
final class KeyTool {
  static let keygen = "/usr/bin/ssh-keygen"
  static let openssl = "/usr/bin/openssl"
  static let passphrase = "fictional passphrase for a throwaway key"
  static let wrongPassphrase = "not the fictional passphrase"

  let directory: URL

  /// Skips the test when ssh-keygen is missing (or not on macOS).
  init() throws {
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: Self.keygen) else {
      throw XCTSkip("\(Self.keygen) is not available: the ssh-keygen oracle cannot run")
    }
    directory = FileManager.default.temporaryDirectory.appendingPathComponent("sshengine-keys-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    #else
    throw XCTSkip("ssh-keygen runs on macOS only")
    #endif
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }

  static var hasOpenSSL: Bool { FileManager.default.isExecutableFile(atPath: openssl) }

  func path(_ name: String) -> String { directory.appendingPathComponent(name).path }

  struct Output {
    var status: Int32
    var standardOutput: String
    var standardError: String
  }

  /// Runs `tool` with `arguments` in the directory; fails the test (and throws) on a non-zero exit unless `check` is
  /// false. Passphrases never appear in failure messages.
  @discardableResult
  func run(_ arguments: [String], input: [UInt8]? = nil, check: Bool = true, file: StaticString = #filePath,
           line: UInt = #line) throws -> Output {
    try run(Self.keygen, arguments, input: input, check: check, file: file, line: line)
  }

  @discardableResult
  func run(_ tool: String, _ arguments: [String], input: [UInt8]? = nil,
           check: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws -> Output {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "LC_ALL": "C"]
    let output = Pipe(), errors = Pipe(), stdin = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    try process.run()
    if let input {
      stdin.fileHandleForWriting.write(Data(input))
      try stdin.fileHandleForWriting.close()
    }
    let out = output.fileHandleForReading.readDataToEndOfFile()
    let err = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let result = Output(status: process.terminationStatus, standardOutput: String(decoding: out, as: UTF8.self),
                        standardError: String(decoding: err, as: UTF8.self))
    if check, result.status != 0 {
      let shown = arguments.map { [Self.passphrase, Self.wrongPassphrase].contains($0) ? "<passphrase>" : $0 }
      XCTFail("\((tool as NSString).lastPathComponent) \(shown) failed (\(result.status)): \(result.standardError)",
              file: file, line: line)
      throw CocoaError(.executableLoad)
    }
    return result
    #else
    throw XCTSkip("no tools off macOS")
    #endif
  }

  /// `ssh-keygen -t type [-b bits] -N passphrase -C comment -f name` plus `extra` (`-m PEM`, `-Z cipher`, `-a n`).
  func generate(_ name: String, type: String, bits: Int? = nil, comment: String, passphrase: String = "",
                extra: [String] = []) throws {
    var arguments = ["-q", "-t", type, "-N", passphrase, "-C", comment, "-f", path(name)]
    if let bits { arguments += ["-b", String(bits)] }
    try run(arguments + extra)
  }

  /// A copy of `source` rewritten by `ssh-keygen -p` (new passphrase, format, cipher, rounds).
  func convert(_ source: String, to name: String, from old: String = "", passphrase new: String = "",
               extra: [String] = []) throws {
    try? FileManager.default.removeItem(atPath: path(name))
    try FileManager.default.copyItem(atPath: path(source), toPath: path(name))
    try run(["-q", "-p", "-f", path(name), "-P", old, "-N", new] + extra)
  }

  func bytes(_ name: String) throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path(name)))) }
  func secret(_ name: String) throws -> SecretBytes { SecretBytes(copying: try bytes(name)) }
  func text(_ name: String) throws -> String { String(decoding: try bytes(name), as: UTF8.self) }
  func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path(name))) }
  func write(_ name: String, bytes: [UInt8]) throws { try Data(bytes).write(to: URL(fileURLWithPath: path(name))) }

  /// The `.pub` file's line without its line break.
  func publicLine(_ name: String) throws -> String {
    try text(name + ".pub").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `ssh-keygen -l -E sha256 -f name.pub`'s fingerprint field.
  func fingerprint(_ name: String) throws -> String {
    let output = try run(["-l", "-E", "sha256", "-f", path(name + ".pub")]).standardOutput
    return output.split(separator: " ").dropFirst().first.map(String.init) ?? ""
  }
}

func secret(_ text: String) -> SecretBytes { SecretBytes(utf8: text) }

/// Parses a key file, reporting the error as the test's failure.
func parseKey(_ file: SecretBytes, passphrase: String? = nil, maximumRounds: Int = Limits.keyFileBcryptRounds,
              file path: StaticString = #filePath, line: UInt = #line) -> FileKey? {
  do {
    return try KeyFile.parse(file, passphrase: passphrase.map(secret), maximumRounds: maximumRounds)
  } catch {
    XCTFail("parse failed: \(error)", file: path, line: line)
    return nil
  }
}

/// The error parsing gives (nil, and a test failure, if it parsed).
func parseError(_ file: SecretBytes, passphrase: String? = nil, maximumRounds: Int = Limits.keyFileBcryptRounds,
                file path: StaticString = #filePath, line: UInt = #line) -> SSHError? {
  do {
    let key = try KeyFile.parse(file, passphrase: passphrase.map(secret), maximumRounds: maximumRounds)
    XCTFail("expected an error, parsed \(key)", file: path, line: line)
    return nil
  } catch {
    return error
  }
}

/// Every algorithm of `key` signs, and the signature verifies with the engine's verifier (and fails over other data).
func checkSigns(_ key: FileKey, file: StaticString = #filePath, line: UInt = #line) {
  let data = Array("fictional session id and request".utf8)
  for algorithm in key.algorithms {
    do {
      let blob = try key.signature(for: data, algorithm: algorithm)
      XCTAssertTrue(SSHSignatureVerifier.isValid(signatureBlob: blob, over: data, key: key.publicKey, algorithm: algorithm),
                    "\(algorithm.rawValue) signature does not verify", file: file, line: line)
      XCTAssertFalse(SSHSignatureVerifier.isValid(signatureBlob: blob, over: data + [0], key: key.publicKey,
                                                  algorithm: algorithm), file: file, line: line)
      XCTAssertEqual(try SignatureBlob(decoding: blob).algorithm, algorithm.rawValue, file: file, line: line)
    } catch {
      XCTFail("\(algorithm.rawValue): \(error)", file: file, line: line)
    }
  }
}

// MARK: - Armor and openssh-key-v1, built by hand

enum KeyArmor {
  /// `-----BEGIN label-----`, base64 in lines of `width`, `-----END label-----`.
  static func armor(_ bytes: [UInt8], label: String, width: Int = 70) -> String {
    let base64 = Data(bytes).base64EncodedString()
    var lines: [String] = []
    var index = base64.startIndex
    while index < base64.endIndex {
      let next = base64.index(index, offsetBy: width, limitedBy: base64.endIndex) ?? base64.endIndex
      lines.append(String(base64[index..<next]))
      index = next
    }
    return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
  }

  static func secret(_ bytes: [UInt8], label: String) -> SecretBytes { SecretBytes(utf8: armor(bytes, label: label)) }

  /// The decoded body of an armored file and its label.
  static func decode(_ text: String) throws -> (label: String, body: [UInt8]) {
    let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    let begin = try XCTUnwrap(lines.first { $0.hasPrefix("-----BEGIN ") })
    let label = String(begin.dropFirst("-----BEGIN ".count).dropLast(5))
    let body = lines.filter { !$0.hasPrefix("-----") && !$0.contains(":") }.joined()
    return (label, Array(try XCTUnwrap(Data(base64Encoded: body))))
  }
}

/// `openssh-key-v1`'s parts (PROTOCOL.key), split and joined independently of the engine's parser.
struct OpenSSHParts {
  var cipher = "none"
  var kdf = "none"
  var kdfOptions: [UInt8] = []
  var count: UInt32 = 1
  var publicBlob: [UInt8]
  var section: [UInt8]
  /// Bytes after the section (an AEAD tag, or trailing data).
  var tail: [UInt8] = []

  init(publicBlob: [UInt8], section: [UInt8]) {
    self.publicBlob = publicBlob
    self.section = section
  }

  init(_ binary: [UInt8]) throws {
    var reader = TestReader(binary)
    XCTAssertEqual(try reader.bytes(15), Array("openssh-key-v1\u{0}".utf8))
    cipher = String(decoding: try reader.string(), as: UTF8.self)
    kdf = String(decoding: try reader.string(), as: UTF8.self)
    kdfOptions = try reader.string()
    count = try reader.uint32()
    publicBlob = try reader.string()
    section = try reader.string()
    tail = Array(binary[reader.offset...])
  }

  var binary: [UInt8] {
    Array("openssh-key-v1\u{0}".utf8) + Raw.string(cipher) + Raw.string(kdf) + Raw.string(kdfOptions) + Raw.u32(count)
      + Raw.string(publicBlob) + Raw.string(section) + tail
  }

  var file: SecretBytes { KeyArmor.secret(binary, label: "OPENSSH PRIVATE KEY") }

  /// An unencrypted private section: check integers, `fields` (type name first), comment, padding to `block`.
  static func section(_ fields: [UInt8], comment: String = "fictional@example.invalid", check: (UInt32, UInt32) = (7, 7),
                      block: Int = 8, padding: [UInt8]? = nil) -> [UInt8] {
    var section = Raw.u32(check.0) + Raw.u32(check.1) + fields + Raw.string(comment)
    if let padding {
      section += padding
    } else {
      var next: UInt8 = 1
      while section.count % block != 0 {
        section.append(next)
        next += 1
      }
    }
    return section
  }

  /// An unencrypted Ed25519 file for `key`; `privateKey` may be another key's (a mismatch).
  static func ed25519(_ key: Curve25519.Signing.PrivateKey, privateKey: Curve25519.Signing.PrivateKey? = nil,
                      comment: String = "fictional@example.invalid") -> OpenSSHParts {
    let point = Array(key.publicKey.rawRepresentation)
    let other = privateKey ?? key
    let otherPoint = Array(other.publicKey.rawRepresentation)
    let fields = Raw.string("ssh-ed25519") + Raw.string(otherPoint)
      + Raw.string(Array(other.rawRepresentation) + otherPoint)
    return OpenSSHParts(publicBlob: Raw.string("ssh-ed25519") + Raw.string(point),
                        section: section(fields, comment: comment))
  }

  /// An unencrypted P-256 file for `key`.
  static func p256(_ key: P256.Signing.PrivateKey, comment: String = "fictional@example.invalid") -> OpenSSHParts {
    let point = Array(key.publicKey.x963Representation)
    var writer = WireWriter()
    writer.writeMPInt(magnitude: Array(key.rawRepresentation))
    let fields = Raw.string("ecdsa-sha2-nistp256") + Raw.string("nistp256") + Raw.string(point) + (try! writer.finish())
    return OpenSSHParts(publicBlob: Raw.string("ecdsa-sha2-nistp256") + Raw.string("nistp256") + Raw.string(point),
                        section: section(fields, comment: comment))
  }
}

/// Plain SSH wire reads for tests (independent of `WireReader`).
struct TestReader {
  let data: [UInt8]
  var offset = 0
  init(_ data: [UInt8]) { self.data = data }
  var atEnd: Bool { offset == data.count }

  mutating func bytes(_ count: Int) throws -> [UInt8] {
    guard count >= 0, data.count - offset >= count else { throw CocoaError(.coderReadCorrupt) }
    defer { offset += count }
    return Array(data[offset..<(offset + count)])
  }

  mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
  mutating func string() throws -> [UInt8] { try bytes(Int(uint32())) }
}

/// DER INTEGERs of a PKCS#1 `RSAPrivateKey`, read with a walker of the test's own.
func pkcs1Integers(_ der: [UInt8]) throws -> [[UInt8]] {
  func element(_ bytes: [UInt8], _ at: inout Int) throws -> (tag: UInt8, contents: [UInt8]) {
    let tag = bytes[at]
    var length = Int(bytes[at + 1])
    at += 2
    if length & 0x80 != 0 {
      let count = length & 0x7F
      length = bytes[at..<(at + count)].reduce(0) { $0 << 8 | Int($1) }
      at += count
    }
    defer { at += length }
    return (tag, Array(bytes[at..<(at + length)]))
  }
  var at = 0
  let sequence = try element(der, &at)
  XCTAssertEqual(sequence.tag, 0x30)
  var inner = 0
  var integers: [[UInt8]] = []
  while inner < sequence.contents.count {
    let value = try element(sequence.contents, &inner)
    XCTAssertEqual(value.tag, 0x02)
    integers.append(Array(value.contents.drop { $0 == 0 }))
  }
  return integers
}

// MARK: - SSHSIG (OpenSSH PROTOCOL.sshsig), for ssh-keygen -Y sign / verify

enum SSHSig {
  static let namespace = "fictional-namespace@example.invalid"

  /// What an SSHSIG signature signs: the preamble, namespace, reserved, hash algorithm and the message's SHA-512.
  static func signedData(_ message: [UInt8], namespace: String = SSHSig.namespace) -> [UInt8] {
    Array("SSHSIG".utf8) + Raw.string(namespace) + Raw.string("") + Raw.string("sha512")
      + Raw.string(Array(SHA512.hash(data: message)))
  }

  /// The armored signature file ssh-keygen -Y verify reads.
  static func armored(publicKeyBlob: [UInt8], signatureBlob: [UInt8], namespace: String = SSHSig.namespace) -> String {
    let body = Array("SSHSIG".utf8) + Raw.u32(1) + Raw.string(publicKeyBlob) + Raw.string(namespace) + Raw.string("")
      + Raw.string("sha512") + Raw.string(signatureBlob)
    return KeyArmor.armor(body, label: "SSH SIGNATURE", width: 76)
  }

  /// A signature file ssh-keygen -Y sign wrote: its public key and signature blob (namespace and hash checked).
  static func parse(_ text: String) throws -> (publicKeyBlob: [UInt8], signatureBlob: [UInt8]) {
    let (label, body) = try KeyArmor.decode(text)
    XCTAssertEqual(label, "SSH SIGNATURE")
    var reader = TestReader(body)
    XCTAssertEqual(try reader.bytes(6), Array("SSHSIG".utf8))
    XCTAssertEqual(try reader.uint32(), 1)
    let publicKey = try reader.string()
    XCTAssertEqual(try reader.string(), Array(namespace.utf8))
    _ = try reader.string()
    XCTAssertEqual(try reader.string(), Array("sha512".utf8))
    let signature = try reader.string()
    XCTAssertTrue(reader.atEnd)
    return (publicKey, signature)
  }
}

// MARK: - Keys generated in-process, encoded by the test's own writers

/// DER built by hand for tests (independent of `DERWriter`).
enum TestDER {
  static func length(_ count: Int) -> [UInt8] {
    if count < 0x80 { return [UInt8(count)] }
    let bytes = withUnsafeBytes(of: UInt32(count).bigEndian) { Array($0) }.drop { $0 == 0 }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  static func tlv(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] { [tag] + length(contents.count) + contents }
  static func sequence(_ elements: [UInt8]...) -> [UInt8] { tlv(0x30, elements.flatMap { $0 }) }

  static func integer(_ magnitude: [UInt8]) -> [UInt8] {
    let trimmed = Array(magnitude.drop { $0 == 0 })
    if trimmed.isEmpty { return [0x02, 0x01, 0x00] }
    return tlv(0x02, (trimmed[0] & 0x80 != 0 ? [0] : []) + trimmed)
  }

  static func integer(_ value: Int) -> [UInt8] { integer(withUnsafeBytes(of: UInt64(value).bigEndian) { Array($0) }) }
  static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
  static func oid(_ contents: [UInt8]) -> [UInt8] { tlv(0x06, contents) }
  static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }

  static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
  static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
  static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]
  static let x25519: [UInt8] = [0x2B, 0x65, 0x6E]
  static let dsa: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x38, 0x04, 0x01]
  static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
  static let secp256k1: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x0A]

  /// PKCS#8 v1 (`PrivateKeyInfo`), or v2 with a public key.
  static func pkcs8(algorithm: [UInt8], parameters: [UInt8] = [], privateKey: [UInt8], publicKey: [UInt8]? = nil) -> [UInt8] {
    sequence(integer(publicKey == nil ? 0 : 1), sequence(oid(algorithm), parameters), octetString(privateKey),
             publicKey.map { tlv(0x81, [0] + $0) } ?? [])
  }

  static func ed25519PKCS8(_ key: Curve25519.Signing.PrivateKey, publicKey: [UInt8]? = nil) -> [UInt8] {
    pkcs8(algorithm: ed25519, privateKey: octetString(Array(key.rawRepresentation)), publicKey: publicKey)
  }
}

/// An RSA key from Security (generated here) and its PKCS#1 encoding.
struct TestRSAKey {
  let key: SecKey
  let pkcs1: [UInt8]
  /// version, n, e, d, p, q, dP, dQ, qInv as minimal magnitudes.
  let integers: [[UInt8]]

  init(bits: Int = 2048) throws {
    let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
      let data = SecKeyCopyExternalRepresentation(key, &error) as Data?
    else { throw error!.takeRetainedValue() }
    self.key = key
    pkcs1 = Array(data)
    integers = try pkcs1Integers(pkcs1)
  }

  var n: [UInt8] { integers[1] }
  var e: [UInt8] { integers[2] }
  var publicBlob: [UInt8] { Raw.string("ssh-rsa") + mpint(e) + mpint(n) }
  var publicKey: PublicKeyBlob { .rsa(exponent: e, modulus: n) }

  /// The `openssh-key-v1` private fields: n, e, d, iqmp, p, q (each replaceable).
  func openSSHFields(d: [UInt8]? = nil, iqmp: [UInt8]? = nil, p: [UInt8]? = nil, q: [UInt8]? = nil) -> [UInt8] {
    Raw.string("ssh-rsa") + mpint(n) + mpint(e) + mpint(d ?? integers[3]) + mpint(iqmp ?? integers[8])
      + mpint(p ?? integers[4]) + mpint(q ?? integers[5])
  }

  var openSSH: OpenSSHParts { OpenSSHParts(publicBlob: publicBlob, section: OpenSSHParts.section(openSSHFields())) }
  var pkcs8: [UInt8] { TestDER.pkcs8(algorithm: TestDER.rsaEncryption, parameters: [0x05, 0x00], privateKey: pkcs1) }

  func mpint(_ magnitude: [UInt8]) -> [UInt8] {
    var writer = WireWriter()
    writer.writeMPInt(magnitude: magnitude)
    return try! writer.finish()
  }
}

extension OpenSSHParts {
  /// An unencrypted ECDSA file for a CryptoKit key (`scalar` and `point` as CryptoKit gives them).
  static func ecdsa(_ curve: ECDSACurve, scalar: [UInt8], point: [UInt8], comment: String = "fictional@example.invalid")
    -> OpenSSHParts {
    var writer = WireWriter()
    writer.writeMPInt(magnitude: scalar)
    let fields = Raw.string(curve.keyType) + Raw.string(curve.rawValue) + Raw.string(point) + (try! writer.finish())
    return OpenSSHParts(publicBlob: Raw.string(curve.keyType) + Raw.string(curve.rawValue) + Raw.string(point),
                        section: section(fields, comment: comment))
  }

  static func p384(_ key: P384.Signing.PrivateKey) -> OpenSSHParts {
    ecdsa(.p384, scalar: Array(key.rawRepresentation), point: Array(key.publicKey.x963Representation))
  }

  static func p521(_ key: P521.Signing.PrivateKey) -> OpenSSHParts {
    ecdsa(.p521, scalar: Array(key.rawRepresentation), point: Array(key.publicKey.x963Representation))
  }

  /// An encrypted-looking envelope: `cipher` with bcrypt (`salt`, `rounds`) around `section`, which is not real
  /// ciphertext (a test of everything before and around the decryption).
  static func bcryptEnvelope(cipher: String = "aes256-ctr", rounds: UInt32, salt: [UInt8] = Array(repeating: 9, count: 16),
                             section: [UInt8] = Array(repeating: 0x5A, count: 64), tail: [UInt8] = []) -> OpenSSHParts {
    var parts = OpenSSHParts(publicBlob: Fixture.ed25519Blob, section: section)
    parts.cipher = cipher
    parts.kdf = "bcrypt"
    parts.kdfOptions = Raw.string(salt) + Raw.u32(rounds)
    parts.tail = tail
    return parts
  }
}
