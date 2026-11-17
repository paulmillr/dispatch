import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// Blowfish against Eric Young's published vectors; bcrypt_pbkdf against the vectors pyca/bcrypt publishes in its test
/// suite (tests/test_bcrypt.py, `test_kdf`, produced by OpenBSD's bcrypt_pbkdf.c, which pyca wrapped) and against
/// the system's ssh-keygen as an oracle: keys it encrypts must decrypt with the key and IV we derive.
final class BcryptPBKDFTests: XCTestCase {
  private typealias T = PrimitiveTestSupport

  func testBlowfishECBVectors() {
    for (key, clear, cipher) in BlowfishVectors.ecb {
      XCTAssertEqual(Self.blowfish(key: T.bytes(key), clear: T.bytes(clear)), cipher.lowercased(), "key \(key)")
    }
  }

  /// Keys of 1 to 24 bytes: the key schedule's cycling over the key.
  func testBlowfishVariableKeyVectors() {
    for (key, cipher) in BlowfishVectors.variableKey {
      XCTAssertEqual(Self.blowfish(key: T.bytes(key), clear: T.bytes(BlowfishVectors.variableKeyClear)), cipher.lowercased(),
                     "key \(key)")
    }
  }

  private static func blowfish(key: [UInt8], clear: [UInt8]) -> String {
    let cipher = Blowfish()
    key.withUnsafeBytes { cipher.expand0State(key: $0) }
    var block = clear
    block.withUnsafeMutableBytes { cipher.encrypt($0) }
    return T.hex(block)
  }

  /// pyca/bcrypt's `test_kdf` vectors: (rounds, password, salt, key). Lengths 16 to 256 bytes, so strides 1 to 8.
  private static let pycaVectors: [(Int, [UInt8], [UInt8], String)] = [
    (4, T.bytes("70617373776f7264"), T.bytes("73616c74"),
     "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9"),
    (4, T.bytes("70617373776f7264"), T.bytes("00"),
     "c12b566235eee04c212598970a579a67"),
    (4, T.bytes("00"), T.bytes("73616c74"),
     "6051be18c2f4f82cbf0efee5471b4bb9"),
    (4, T.bytes("70617373776f726400"), T.bytes("73616c7400"),
     "7410e44cf4fa07bfaac8a928b1727fac001375e7bf7384370f48efd121743050"),
    (4, T.bytes("7061737300776f72"), T.bytes("7361006c"),
     "c2bffd9db38f6569efef4372f4de83c0"),
    (4, T.bytes("7061737300776f7264"), T.bytes("7361006c74"),
     "4ba4ac3925c0e8d7f0cdb6bb1684a56f"),
    (8, T.bytes("70617373776f7264"), T.bytes("73616c74"),
     "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec76227ea66088b849b20ab7aa478010246"
       + "e74bba51723fefa9f9474d6508845e8d"),
    (42, T.bytes("70617373776f7264"), T.bytes("73616c74"),
     "833cf0dcf56db65608e8f0dc0ce882bd"),
    (8, T.bytes("4c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963"
       + "696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61"
       + "626f726520657420646f6c6f7265206d61676e6120616c697175612e20557420656e696d206164206d696e696d207665"
       + "6e69616d2c2071756973206e6f737472756420657865726369746174696f6e20756c6c616d636f206c61626f72697320"
       + "6e69736920757420616c697175697020657820656120636f6d6d6f646f20636f6e7365717561742e2044756973206175"
       + "746520697275726520646f6c6f7220696e20726570726568656e646572697420696e20766f6c7570746174652076656c"
       + "697420657373652063696c6c756d20646f6c6f726520657520667567696174206e756c6c612070617269617475722e20"
       + "4578636570746575722073696e74206f6363616563617420637570696461746174206e6f6e2070726f6964656e742c20"
       + "73756e7420696e2063756c706120717569206f666669636961206465736572756e74206d6f6c6c697420616e696d2069"
       + "6420657374206c61626f72756d2e"), T.bytes("73616c697300"),
     "10978b07253df57f71a162eb0e8ad30a"),
    (8, T.bytes("0db3ac94b3ee53284f4a22893b3c24ae"), T.bytes("3a62f0f0dbcef823cfcc854856ea1028"),
     "204438175eee7ce136c91b49a67923ff"),
    (8, T.bytes("0db3ac94b3ee53284f4a22893b3c24ae"), T.bytes("3a62f0f0dbcef823cfcc854856ea1028"),
     "2054b9fff34e3721440334746828e9ed38de4b72e0a69adc170a13b5e8d646385ea4034ae6d26600ee2332c5ed40ad55"
       + "7c86e3403fbb30e4e1dc1ae06b99a071368f518d2c426651c9e7e437fd6c915b1bbfc3a4cea71491490ea7afb7dd0290"
       + "a678a4f441128db1792eab2776b21eb4238e0715add4127dff44e4b3e4cc4c4f9970083f3f74bd698873fdf648844f75"
       + "c9bf7f9e0c4d9e5d89a7783997492966616707611cb901de31a19726b6e08c3a8001661f2d5c9dcc33b4aa072f90dd0b"
       + "3f548d5eeba4211397e2fb062e526e1d68f46a4ce256185b4badc2685fbe78e1c7657b59f83ab9ab80cf9318d6add1f5"
       + "933f12d6f36182c8e8115f68030a1244"),
    (8, T.bytes("e1bd88ceb4cf85cf83cf83ceb5cf8dcf82"), T.bytes("cea4ceb7cebbceadcebcceb1cf87cebfcf82"),
     "43666c9b09ef33ed8c27e8e8f3e2d8e6"),
  ]

  func testPublishedVectors() throws {
    for (number, (rounds, password, salt, expected)) in Self.pycaVectors.enumerated() {
      let wanted = T.bytes(expected)
      let key = try BcryptPBKDF.derive(password: password, salt: salt, rounds: rounds, count: wanted.count)
      XCTAssertEqual(T.hex(key), T.hex(wanted), "vector \(number + 1)")
    }
  }

  /// OpenBSD's parameter checks: what bcrypt_pbkdf(3) refuses, this refuses.
  func testRejectsWhatOpenBSDRejects() {
    let cases: [([UInt8], [UInt8], Int, Int)] = [
      ([], [1], 1, 32), ([1], [], 1, 32), ([1], [1], 0, 32), ([1], [1], -1, 32), ([1], [1], 1, 0), ([1], [1], 1, 1025),
      ([1], [UInt8](repeating: 0, count: (1 << 20) + 1), 1, 32),
    ]
    for (password, salt, rounds, count) in cases {
      XCTAssertThrowsError(try BcryptPBKDF.derive(password: password, salt: salt, rounds: rounds, count: count)) {
        XCTAssertEqual($0 as? BcryptPBKDF.Error, .invalidParameters)
      }
    }
    XCTAssertEqual(try BcryptPBKDF.derive(password: [1], salt: [1], rounds: 1, count: 1024).count, 1024)
  }

  /// The output layout: byte i of block n lands at i · stride + n - 1, stride = ⌈count / 32⌉. Lengths with one stride
  /// share their bytes (16 and 32 bytes: stride 1, block 1 in order; 48 and 64: stride 2, blocks 1 and 2 interleaved),
  /// and block 1 is the same block whatever the length.
  func testOutputLayoutAcrossLengths() throws {
    let password = Array("fictional passphrase".utf8)
    let salt = Array("fictional salt..".utf8)
    let a = try BcryptPBKDF.derive(password: password, salt: salt, rounds: 2, count: 32)
    let b = try BcryptPBKDF.derive(password: password, salt: salt, rounds: 2, count: 16)
    XCTAssertEqual(Array(a.prefix(16)), b)
    // 48 bytes: stride 2, block 1 at even positions, block 2 at odd ones; 64 bytes: the same two blocks, full.
    let c = try BcryptPBKDF.derive(password: password, salt: salt, rounds: 2, count: 48)
    let d = try BcryptPBKDF.derive(password: password, salt: salt, rounds: 2, count: 64)
    XCTAssertEqual(c, Array(d.prefix(48)))
    XCTAssertEqual((0..<32).map { d[2 * $0] }, a)
  }

  // MARK: - ssh-keygen as the oracle

  private static let keygen = "/usr/bin/ssh-keygen"
  private static let passphrase = "fictional passphrase for a throwaway key"

  /// ssh-keygen writes passphrase-protected ed25519 keys at several round counts and ciphers; the key and IV we derive
  /// from the file's salt and rounds must decrypt the private section to matching check integers, the key we asked
  /// for (comment, public key, a seed whose public key is that key) and padding 1, 2, 3, …; a wrong passphrase must not.
  func testDecryptsKeysThatSSHKeygenEncrypted() throws {
    #if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: Self.keygen) else {
      throw XCTSkip("\(Self.keygen) is not available: the ssh-keygen oracle cannot run")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sshengine-bcrypt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }

    // nil rounds: ssh-keygen's default.
    let cases: [(rounds: Int?, cipher: String?)] = [(1, nil), (4, nil), (16, nil), (nil, nil), (4, "aes128-ctr"), (4, "aes256-cbc")]
    for (index, (rounds, cipher)) in cases.enumerated() {
      let path = directory.appendingPathComponent("key\(index)").path
      let comment = "fictional-key-\(index)@example.invalid"
      var arguments = ["-q", "-t", "ed25519", "-N", Self.passphrase, "-C", comment, "-f", path]
      if let rounds { arguments += ["-a", String(rounds)] }
      if let cipher { arguments += ["-Z", cipher] }
      try Self.run(Self.keygen, arguments)
      let file = try Self.parse(String(contentsOfFile: path, encoding: .utf8))
      if let rounds { XCTAssertEqual(file.rounds, rounds) }
      XCTAssertEqual(file.cipher, cipher ?? "aes256-ctr")
      XCTAssertEqual(file.kdf, "bcrypt")
      XCTAssertEqual(file.salt.count, 16)

      let start = Date()
      let plain = try Self.decrypt(file, passphrase: Array(Self.passphrase.utf8))
      let seconds = Date().timeIntervalSince(start)
      print("BcryptPBKDFTests: ssh-keygen \(file.cipher) at \(file.rounds) rounds: derived and decrypted in "
        + String(format: "%.3f s", seconds))
      try Self.checkPrivateSection(plain, comment: comment, publicKey: file.publicKey)

      let wrong = try Self.decrypt(file, passphrase: Array("not the fictional passphrase".utf8))
      XCTAssertNotEqual(wrong.prefix(4), wrong.dropFirst(4).prefix(4), "a wrong passphrase gave matching check integers")
    }
    #else
    throw XCTSkip("ssh-keygen runs on macOS only")
    #endif
  }

  private struct KeyFile {
    var cipher: String
    var kdf: String
    var salt: [UInt8]
    var rounds: Int
    var publicKey: [UInt8]
    var encrypted: [UInt8]
  }

  /// Just enough of PROTOCOL.key's `openssh-key-v1`: magic, cipher, KDF and its options, one public key, the private
  /// section.
  private static func parse(_ text: String) throws -> KeyFile {
    let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    var reader = Reader(try XCTUnwrap(Data(base64Encoded: body)).map { $0 })
    XCTAssertEqual(try reader.bytes(15), Array("openssh-key-v1\u{0}".utf8))
    let cipher = try reader.text()
    let kdf = try reader.text()
    var options = Reader(try reader.string())
    let salt = try options.string()
    let rounds = Int(try options.uint32())
    XCTAssertEqual(try reader.uint32(), 1)
    let publicKey = try reader.string()
    let encrypted = try reader.string()
    XCTAssertTrue(reader.atEnd)
    return KeyFile(cipher: cipher, kdf: kdf, salt: salt, rounds: rounds, publicKey: publicKey, encrypted: encrypted)
  }

  /// bcrypt_pbkdf(passphrase, salt, rounds) → key | IV, then the file's cipher through CommonCrypto.
  private static func decrypt(_ file: KeyFile, passphrase: [UInt8]) throws -> [UInt8] {
    let (keySize, mode): (Int, Int) = switch file.cipher {
    case "aes256-ctr": (32, kCCModeCTR)
    case "aes128-ctr": (16, kCCModeCTR)
    case "aes256-cbc": (32, kCCModeCBC)
    default: throw XCTSkip("cipher \(file.cipher) is not covered by this test")
    }
    let derived = try BcryptPBKDF.derive(password: passphrase, salt: file.salt, rounds: file.rounds, count: keySize + 16)
    let key = Array(derived.prefix(keySize))
    let iv = Array(derived.suffix(16))
    var cryptor: CCCryptorRef?
    var status = CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(mode), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                         iv, key, keySize, nil, 0, 0,
                                         CCModeOptions(mode == kCCModeCTR ? kCCModeOptionCTR_BE : 0), &cryptor)
    XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
    defer { CCCryptorRelease(cryptor) }
    var plain = [UInt8](repeating: 0, count: file.encrypted.count)
    var moved = 0
    status = CCCryptorUpdate(cryptor, file.encrypted, file.encrypted.count, &plain, plain.count, &moved)
    XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
    XCTAssertEqual(moved, plain.count)
    return plain
  }

  private static func checkPrivateSection(_ plain: [UInt8], comment: String, publicKey: [UInt8]) throws {
    var reader = Reader(plain)
    let check1 = try reader.uint32()
    let check2 = try reader.uint32()
    XCTAssertEqual(check1, check2, "check integers differ: the derived key or IV is wrong")
    guard check1 == check2 else { return }
    XCTAssertEqual(try reader.text(), "ssh-ed25519")
    let pub = try reader.string()
    let secret = try reader.string()
    XCTAssertEqual(try reader.text(), comment)
    XCTAssertEqual(secret.count, 64)
    XCTAssertEqual(Array(secret.suffix(32)), pub)
    // The outer public key blob is string "ssh-ed25519" | string key.
    var outer = Reader(publicKey)
    XCTAssertEqual(try outer.text(), "ssh-ed25519")
    XCTAssertEqual(try outer.string(), pub)
    let seed = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32))
    XCTAssertEqual(Array(seed.publicKey.rawRepresentation), pub)
    let padding = Array(plain[reader.offset...])
    XCTAssertEqual(padding, (0..<padding.count).map { UInt8($0 + 1) }, "padding is not 1, 2, 3, …")
    XCTAssertLessThan(padding.count, 16)
    XCTAssertEqual(plain.count % 16, 0)
  }

  /// SSH wire reads (RFC 4251 §5): bytes, big-endian uint32, length-prefixed strings.
  private struct Reader {
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
    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
  }

  #if os(macOS)
  private static func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let message = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      XCTFail("ssh-keygen \(arguments.filter { $0 != passphrase }) failed (\(process.terminationStatus)): "
        + String(decoding: message, as: UTF8.self))
      throw CocoaError(.executableLoad)
    }
  }
  #endif
}
