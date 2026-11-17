import CryptoKit
import Foundation
import MobileTransport
import XCTest
@testable import SSHEngine

/// The parity suite's server: `LoopbackServer` with a fresh Ed25519 host key and `ParityServer.script`, the Rust
/// engine tests' server (Core/tests/engine.rs) restated: user `phone`, password `s3cret`, two keyboard-interactive
/// rounds (a password, then a code), the commands `echo`, `cat`, `refuse`, `noreply`, `early` and `signal`, a shell that
/// echoes and exits on `exit <n>`, and a terminal named `refused` refused. Every cipher, MAC and key exchange method the
/// engine implements is offered, so each client picks its own preference.
final class ParityServer: @unchecked Sendable {
  let server: LoopbackServer
  let hostKey: Curve25519.Signing.PrivateKey
  /// The host key as the trust sheet shows it (`ssh-ed25519 <base64>`).
  let openSSH: String
  let trust: RecordingTrust
  let endpoint: SSHEndpoint

  static var script: SessionScript {
    var script = SessionScript()
    script.keyboardInteractive = [
      .init(name: "Login", instruction: "Two steps", prompts: [("Password: ", false)], answers: ["s3cret"]),
      .init(prompts: [("Code: ", true)], answers: ["123456"]),
    ]
    script.commands = [
      "echo": .output("hello", stderr: "warn", status: 7),
      "cat": .echoing,
      "refuse": .declined,
      "noreply": SessionScript.Command(start: [], echo: true),
      "early": SessionScript.Command(start: [.stdout(Array("early".utf8)), .reply(true), .exitStatus(5), .eof, .close]),
      "signal": SessionScript.Command(start: [.reply(true), .stdout(Array("bye".utf8)), .exitSignal("TERM"), .eof, .close]),
    ]
    return script
  }

  /// Starts a server with `script` (and transport changes); the test's teardown shuts it down and checks that no
  /// connection saw a violation or failed, unless `clean` is false.
  static func start(_ test: XCTestCase, script: SessionScript = ParityServer.script, clean: Bool = true,
                    transport: (inout ScriptedServer.Configuration) -> Void = { _ in }) throws -> ParityServer {
    var configuration = ScriptedServer.Configuration()
    configuration.session = script
    configuration.extensions = [("server-sig-algs", Array(script.publicKeyAlgorithms.joined(separator: ",").utf8))]
    transport(&configuration)
    let server = try ParityServer(configuration: configuration)
    test.addTeardownBlock {
      XCTAssertTrue(server.server.shutdown(), "every server thread finished")
      guard clean else { return }
      for connection in server.server.connections {
        let log = connection.log.value
        XCTAssertEqual(log.violations, [], "connection \(connection.index)")
        XCTAssertNil(log.failure, "connection \(connection.index)")
      }
    }
    return server
  }

  private init(configuration: ScriptedServer.Configuration) throws {
    hostKey = Curve25519.Signing.PrivateKey()
    let identity = ServerHostKey.ed25519(hostKey)
    openSSH = "ssh-ed25519 " + Data(identity.publicBlob).base64EncodedString()
    server = try LoopbackServer(configuration: configuration, identity: identity)
    trust = RecordingTrust(expected: openSSH)
    endpoint = SSHEndpoint(host: "127.0.0.1", port: server.port, username: "phone")
  }

  /// The `index`-th connection's log.
  func log(_ index: Int = 0) async throws -> Watched<ServerLog> { try await server.connection(index).log }

  func connect(_ credentials: [SSHCredential], trust: (any MobileTransport.HostKeyTrust)? = nil, timeout: Duration = .seconds(10))
    async throws -> SSHConnection
  {
    try await SSHConnection.connect(to: endpoint, credentials: credentials, trust: trust ?? self.trust, timeout: timeout)
  }

  /// Connected and logged in with the password.
  func loggedIn() async throws -> SSHConnection { try await connect([.password("s3cret")]) }
}

/// Trusts the server's key (anything else is a mismatch, or `decision` when set) and records every question.
final class RecordingTrust: MobileTransport.HostKeyTrust, @unchecked Sendable {
  let expected: String
  let decision: HostKeyDecision?
  let asked = Watched<[HostKeyInfo]>([])

  init(expected: String, decision: HostKeyDecision? = nil) {
    self.expected = expected
    self.decision = decision
  }

  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
    asked.update { $0.append(key) }
    if let decision { return decision }
    return key.openSSH == expected ? .trust : .mismatch(expected: expected)
  }
}

/// User keys made once per run with the system's ssh-keygen (fictional comments, a fictional passphrase, bcrypt at 2
/// rounds), in a private directory removed by `ParityKeys.remove()` at the suite's end.
final class ParityKeys: @unchecked Sendable {
  static let names = ["ed25519", "ecdsa256", "ecdsa384", "ecdsa521", "rsa"]
  private static let lock = NSLock()
  nonisolated(unsafe) private static var made: ParityKeys?

  let tool: KeyTool

  static func shared() throws -> ParityKeys {
    try lock.withLock {
      if let made { return made }
      let keys = try ParityKeys()
      made = keys
      return keys
    }
  }

  static func remove() {
    lock.withLock {
      made?.tool.remove()
      made = nil
    }
  }

  private init() throws {
    tool = try KeyTool()
    do {
      for (name, type, bits) in [("ed25519", "ed25519", nil), ("ecdsa256", "ecdsa", 256), ("ecdsa384", "ecdsa", 384),
                                 ("ecdsa521", "ecdsa", 521), ("rsa", "rsa", 3072)] as [(String, String, Int?)] {
        try tool.generate(name, type: type, bits: bits, comment: "fictional-\(name)@example.invalid")
        try tool.convert(name, to: name + "-encrypted", passphrase: KeyTool.passphrase, extra: ["-a", "2"])
      }
    } catch {
      tool.remove()
      throw error
    }
  }

  func file(_ name: String) throws -> Data { Data(try tool.bytes(name)) }

  /// The key parsed by the engine `SSHTransportEngine.preferred` names.
  func key(_ name: String) throws -> SSHKey {
    try SSHKey.openSSH(file(name), passphrase: name.hasSuffix("-encrypted") ? KeyTool.passphrase : nil)
  }

  /// The public key blob of `name` (from its `.pub` file; an encrypted copy has its plain original's).
  func blob(_ name: String) throws -> [UInt8] {
    let base = name.replacingOccurrences(of: "-encrypted", with: "")
    let fields = try tool.publicLine(base).split(separator: " ")
    return Array(try XCTUnwrap(Data(base64Encoded: String(fields[1]))))
  }

  func fingerprint(_ name: String) throws -> String {
    try tool.fingerprint(name.replacingOccurrences(of: "-encrypted", with: ""))
  }
}

/// CryptoKit keys as external signers: what the engine is asked to sign is signed in Swift.
enum SignerKeys {
  static func p384Blob(_ key: P384.Signing.PublicKey) -> [UInt8] {
    Raw.string("ecdsa-sha2-nistp384") + Raw.string("nistp384") + Raw.string(Array(key.x963Representation))
  }

  static func ed25519Blob(_ key: Curve25519.Signing.PublicKey) -> [UInt8] {
    Raw.string("ssh-ed25519") + Raw.string(Array(key.rawRepresentation))
  }

  static func p256Blob(_ key: P256.Signing.PublicKey) -> [UInt8] {
    Raw.string("ecdsa-sha2-nistp256") + Raw.string("nistp256") + Raw.string(Array(key.x963Representation))
  }
}

/// A value recorded once, readable after.
final class Recorder<Value: Sendable>: @unchecked Sendable {
  let values = Watched<[Value]>([])
  func record(_ value: Value) { values.update { $0.append(value) } }
  var all: [Value] { values.value }
}

/// Reads a shell's or an exec's output across calls (one iterator), each read bounded.
final class OutputReader: @unchecked Sendable {
  private var shell: SSHShell.AsyncIterator?
  private var exec: SSHExec.AsyncIterator?
  private(set) var stdout = Data()
  private(set) var stderr = Data()
  private(set) var ended = false

  init(_ shell: SSHShell) { self.shell = shell.makeAsyncIterator() }
  init(_ exec: SSHExec) { self.exec = exec.makeAsyncIterator() }

  /// Reads until stdout holds `expected` from `from` on, or the output ends. Returns stdout from `from` on.
  @discardableResult
  func read(until expected: String, from: Int = 0, timeout: Double = 10) async throws -> String {
    let needle = Data(expected.utf8)
    let seen = String(decoding: stdout, as: UTF8.self).debugDescription
    try await bounded(timeout, "output \(expected.debugDescription); seen \(seen)") {
      while !self.ended, self.stdout.dropFirst(from).range(of: needle) == nil { try await self.next() }
    }
    return String(decoding: stdout.dropFirst(from), as: UTF8.self)
  }

  /// Reads until the output ends; returns all of stdout.
  @discardableResult
  func readToEnd(timeout: Double = 30) async throws -> Data {
    try await bounded(timeout, "the end of the output") {
      while !self.ended { try await self.next() }
    }
    return stdout
  }

  private func next() async throws {
    if shell != nil {
      if let data = try await shell!.next() { stdout.append(data) } else { ended = true }
    } else if let chunk = try await exec!.next() {
      switch chunk {
      case .stdout(let data): stdout.append(data)
      case .stderr(let data): stderr.append(data)
      }
    } else {
      ended = true
    }
  }
}

/// Asserts that `body` throws exactly `expected`.
func XCTAssertThrowsAsync<T>(_ expected: SSHTransportError, _ message: String = "", file: StaticString = #filePath,
                             line: UInt = #line, _ body: () async throws -> T) async {
  do {
    let value = try await body()
    XCTFail("expected \(expected), got \(value) \(message)", file: file, line: line)
  } catch {
    XCTAssertEqual(error as? SSHTransportError, expected, "\(error) \(message)", file: file, line: line)
  }
}

/// `XCTAssertEqual` for a value computed with `await` (XCTest's autoclosures cannot await).
func assertEqual<T: Equatable>(_ value: T, _ expected: T, _ message: String = "", file: StaticString = #filePath,
                               line: UInt = #line) {
  XCTAssertEqual(value, expected, message, file: file, line: line)
}
