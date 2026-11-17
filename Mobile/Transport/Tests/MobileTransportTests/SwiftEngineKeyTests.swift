#if os(macOS)
// ssh-keygen makes the key files: macOS only.
import Foundation
@testable import MobileTransport
import SSHEngine
import XCTest

/// Key files through the engines' `parseKey`: files ssh-keygen makes now (fictional comments) give the algorithm,
/// public line and fingerprint ssh-keygen prints, on the Swift engine and (in a `DISPATCH_RUSSH` build) the same on
/// russh; a missing or wrong passphrase is `wrongPassphrase` on each; the formats the Swift engine refuses say what to
/// do instead.
final class SwiftEngineKeyTests: XCTestCase {
  static let passphrase = "fictional passphrase"
  static let swift = SwiftEngine(connector: ScriptedConnector { _, _ throws(SSHError) in throw .closed(.alreadyEnded) })
  /// Every engine this build has.
  static var engines: [any EngineBackend] {
    #if DISPATCH_RUSSH
    [swift, RusshEngine.shared]
    #else
    [swift]
    #endif
  }

  struct Made: Sendable {
    let name: String
    let file: Data
    /// The `.pub` line ssh-keygen wrote (type, base64, comment).
    let line: String
    let fingerprint: String
    let encrypted: Bool
    /// openssh-key-v1 (keeps the comment); PEM and PKCS#8 files have none.
    let openSSH: Bool
  }

  /// Every key type in every format ssh-keygen writes that both engines read, made once per run in a directory that is
  /// removed at once.
  static let made: [Made] = {
    do {
      return try inDirectory { directory in
        var made: [Made] = []
        let types: [(String, [String])] = [
          ("ed25519", ["-t", "ed25519"]), ("ecdsa256", ["-t", "ecdsa", "-b", "256"]), ("ecdsa384", ["-t", "ecdsa", "-b", "384"]),
          ("ecdsa521", ["-t", "ecdsa", "-b", "521"]), ("rsa2048", ["-t", "rsa", "-b", "2048"]), ("rsa4096", ["-t", "rsa", "-b", "4096"]),
        ]
        for (type, arguments) in types {
          var formats: [(String, [String], Bool)] = [("openssh", [], false), ("openssh-encrypted", [], true)]
          // ssh-keygen writes Ed25519 only as openssh-key-v1.
          if type != "ed25519" { formats += [("pem", ["-m", "PEM"], false), ("pkcs8", ["-m", "PKCS8"], false)] }
          for (format, extra, encrypted) in formats {
            let name = "\(type)-\(format)"
            let file = directory.appendingPathComponent(name)
            try SSHFixture.keygen(arguments + extra + ["-N", encrypted ? passphrase : "", "-C", "sam@\(name).example",
                                                       "-f", file.path])
            let line = try String(contentsOf: URL(fileURLWithPath: file.path + ".pub"), encoding: .utf8)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            made.append(Made(name: name, file: try Data(contentsOf: file), line: line,
                             fingerprint: try SSHFixture.fingerprint(file.path + ".pub"),
                             encrypted: encrypted, openSSH: format.hasPrefix("openssh")))
          }
        }
        return made
      }
    } catch { fatalError("ssh-keygen: \(error)") }
  }()

  func testBothEnginesReadEveryFormatAlike() throws {
    XCTAssertEqual(Self.made.count, 2 + 5 * 4)
    #if DISPATCH_RUSSH
    var russhCannot: [String] = []
    #endif
    for key in Self.made {
      let swift = try Self.parse(Self.swift, key.file, key.encrypted ? Self.passphrase : nil)
      #if DISPATCH_RUSSH
      do {
        let russh = try Self.parse(RusshEngine.shared, key.file, key.encrypted ? Self.passphrase : nil)
        XCTAssertEqual(swift.algorithm, russh.algorithm, key.name)
        XCTAssertEqual(swift.publicKey, russh.publicKey, key.name)
        XCTAssertEqual(swift.fingerprint, russh.fingerprint, key.name)
      } catch {
        russhCannot.append("\(key.name) (\(error))")
      }
      #endif
      XCTAssertEqual(swift.fingerprint, key.fingerprint, "\(key.name): as ssh-keygen -lf prints it")
      let parts = key.line.split(separator: " ", maxSplits: 2)
      XCTAssertEqual(swift.algorithm, String(parts[0]), key.name)
      XCTAssertEqual(swift.publicKey, key.openSSH ? key.line : parts.prefix(2).joined(separator: " "), key.name)
      XCTAssertNotNil(SSHKey.Kind(rawValue: swift.algorithm), key.name)
    }
    // Formats only the Swift engine reads are checked against ssh-keygen alone.
    #if DISPATCH_RUSSH
    report("swift engine keys: russh cannot read \(russhCannot.isEmpty ? "none" : russhCannot.joined(separator: ", "))")
    XCTAssertTrue(russhCannot.allSatisfy { $0.contains("pkcs8") }, "\(russhCannot)")
    #endif
  }

  func testAMissingOrWrongPassphrase() throws {
    for key in Self.made where key.encrypted {
      for passphrase in [nil, "", "wrong"] as [String?] {
        for engine in Self.engines {
          XCTAssertThrowsError(try Self.parse(engine, key.file, passphrase)) {
            XCTAssertEqual($0 as? SSHTransportError, .wrongPassphrase,
                           "\(key.name) \(String(describing: passphrase)) \(type(of: engine))")
          }
        }
      }
    }
    // A passphrase for a plain file is ignored.
    let plain = try XCTUnwrap(Self.made.first { !$0.encrypted })
    XCTAssertEqual(try Self.parse(Self.swift, plain.file, "unused").fingerprint, plain.fingerprint)
  }

  /// Unreadable files are `invalidKey` on both engines (the texts are each engine's), so the app tells them from a
  /// passphrase problem.
  func testUnreadableFiles() throws {
    let cases: [(String, Data, String?)] = [
      ("binary", Data([0xFF, 0xFE, 0x00, 0x01]), "not a text key file"),
      ("text", Data("not a key\n".utf8), nil),
      ("empty", Data(), nil),
      ("damaged", Data("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n".utf8), nil),
    ]
    for (name, file, text) in cases {
      for engine in Self.engines {
        XCTAssertThrowsError(try Self.parse(engine, file, nil)) { error in
          guard case SSHTransportError.invalidKey(let reason)? = error as? SSHTransportError else {
            return XCTFail("\(name) on \(type(of: engine)): \(error)")
          }
          if let text { XCTAssertEqual(reason, text, name) }
        }
      }
    }
    let line = try XCTUnwrap(Self.made.first).line
    XCTAssertThrowsError(try Self.parse(Self.swift, Data(line.utf8), nil)) {
      XCTAssertEqual($0 as? SSHTransportError, .invalidKey("this is a public key: choose the private key file"))
    }
  }

  /// Encrypted legacy PEM and PKCS#8: refused with what to do, which works (`ssh-keygen -p` saves the file as
  /// openssh-key-v1, which the engine then reads with the new passphrase).
  func testEncryptedPEMAndPKCS8SayHowToConvert() throws {
    try Self.inDirectory { directory in
      var files: [(String, URL, KeyFileRefusal)] = []
      for (name, arguments) in [("rsa", ["-t", "rsa", "-b", "2048"]), ("ecdsa", ["-t", "ecdsa", "-b", "256"])] {
        let file = directory.appendingPathComponent("\(name)-pem")
        try SSHFixture.keygen(arguments + ["-m", "PEM", "-N", Self.passphrase, "-C", "sam@pem.example",
                                           "-f", file.path])
        files.append((name + " PEM", file, .encryptedPEM))
      }
      let pkcs8 = directory.appendingPathComponent("pkcs8")
      try SSHFixture.run("/usr/bin/openssl", ["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                                              "-aes-256-cbc", "-pass", "pass:" + Self.passphrase, "-out", pkcs8.path])
      chmod(pkcs8.path, 0o600)
      files.append(("PKCS#8", pkcs8, .encryptedPKCS8))
      for (name, file, refusal) in files {
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try Self.parse(Self.swift, data, Self.passphrase)) { error in
          let error = error as? SSHTransportError
          XCTAssertEqual(error, refusal.transportError, name)
          XCTAssertEqual(error?.errorDescription?.contains("ssh-keygen -p -f <file>"), true, name)
          XCTAssertEqual(error?.errorDescription?.contains("OpenSSH format"), true, name)
        }
        // The advice, followed.
        try SSHFixture.keygen(["-p", "-f", file.path, "-P", Self.passphrase, "-N", "new " + Self.passphrase])
        let converted = try Self.parse(Self.swift, try Data(contentsOf: file), "new " + Self.passphrase)
        XCTAssertFalse(converted.fingerprint.isEmpty, name)
      }
    }
  }

  /// PuTTY files: refused, saying to export the key in OpenSSH format from PuTTYgen.
  func testPuTTYFilesSayHowToExport() throws {
    // Fictional and incomplete: the header alone decides.
    let ppk = Data("""
      PuTTY-User-Key-File-3: ssh-ed25519
      Encryption: none
      Comment: sam@ppk.example
      Public-Lines: 2
      AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
      AAAA
      """.utf8)
    XCTAssertThrowsError(try Self.parse(Self.swift, ppk, nil)) { error in
      let error = error as? SSHTransportError
      XCTAssertEqual(error, KeyFileRefusal.puttyKey.transportError)
      XCTAssertEqual(error?.errorDescription,
                     "Invalid private key: PuTTY key files (.ppk) are not supported; in PuTTYgen, choose Conversions › Export OpenSSH key and import that file.")
    }
  }

  /// The OpenSSH files the app stores (Import key takes `openssh-key-v1` only) that russh reads (checked in a
  /// `DISPATCH_RUSSH` build) and the Swift engine refuses: RSA keys under 2048 bits, and files encrypted with more
  /// bcrypt rounds than `Limits.keyFileBcryptRounds`. Each says what to do; for the rounds the advice, followed, gives a
  /// file the Swift engine reads.
  func testStoredFilesOnlyRusshReads() throws {
    try Self.inDirectory { directory in
      let small = directory.appendingPathComponent("rsa1024")
      try SSHFixture.keygen(["-t", "rsa", "-b", "1024", "-N", "", "-C", "sam@rsa1024.example", "-f", small.path])
      let rounds = directory.appendingPathComponent("rounds")
      try SSHFixture.keygen(["-t", "ed25519", "-a", String(Limits.keyFileBcryptRounds + 1), "-N", Self.passphrase,
                       "-C", "sam@rounds.example", "-f", rounds.path])
      let cases: [(URL, String?, KeyFileRefusal)] = [(small, nil, .rsaKeySize), (rounds, Self.passphrase, .bcryptRounds)]
      for (file, passphrase, refusal) in cases {
        let data = try Data(contentsOf: file)
        #if DISPATCH_RUSSH
        XCTAssertNoThrow(try Self.parse(RusshEngine.shared, data, passphrase), file.lastPathComponent)
        #endif
        XCTAssertThrowsError(try Self.parse(Self.swift, data, passphrase)) {
          XCTAssertEqual($0 as? SSHTransportError, refusal.transportError, file.lastPathComponent)
        }
      }
      // The advice, followed: ssh-keygen's default rounds.
      try SSHFixture.keygen(["-p", "-f", rounds.path, "-P", Self.passphrase, "-N", Self.passphrase])
      XCTAssertEqual(try Self.parse(Self.swift, try Data(contentsOf: rounds), Self.passphrase).algorithm, "ssh-ed25519")
    }
  }

  // MARK: Helpers

  static func parse(_ engine: any EngineBackend, _ file: Data, _ passphrase: String?) throws -> any EngineKey {
    guard let passphrase else { return try engine.parseKey(file, passphrase: nil) }
    return try passphrase.withCString { try engine.parseKey(file, passphrase: $0) }
  }

  static func inDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = URL(fileURLWithPath: "/tmp/sek-\(getpid())-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
  }

}
#endif
