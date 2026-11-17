#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import MobileTransport
import XCTest
@testable import SSHEngine

/// The interop tests' servers: standard, unmodified SSH servers in a Lima Linux VM (Dropbear and OpenSSH, current and
/// older releases), set up and started by `scripts/ssh-interop-vm.py`, which writes this profile (ports, the fictional
/// accounts' generated password, the user keys it generated, each server's host keys). docs/vm_testing.md, "Swift SSH
/// interop". Without the profile every interop test skips; `SSHENGINE_INTEROP_REQUIRED=1` makes that a failure.
struct InteropProfile: Decodable, Sendable {
  let vm: String
  let user: String
  let multiFactorUser: String
  let password: String
  let banner: String
  let keys: [String: Key]
  /// The command (and its first arguments) that signals the processes serving one connection in the guest:
  /// `signal + [server, pid, "TERM"]`.
  let signal: [String]
  let servers: [Server]

  struct Key: Decodable, Sendable {
    let path: String
    let `public`: String
  }

  struct Server: Decodable, Sendable, CustomStringConvertible {
    let name: String
    /// `openssh` or `dropbear`.
    let implementation: String
    let release: String
    let identification: String
    let port: Int
    /// OpenSSH built `--without-openssl`: Ed25519 keys, curve25519, ChaCha20-Poly1305 and AES-CTR only.
    let openssl: Bool
    /// The host keys' OpenSSH lines by the script's names (`ed25519`, `ecdsa256`, ..., `rsa`).
    let hostKeys: [String: String]
    let keyboardInteractive: Bool
    /// The account that must log in with a key and then a password or keyboard-interactive (OpenSSH only), with one
    /// session at a time and no PTY.
    let multiFactorUser: String?
    /// The account whose pre-login banner holds a Latin-1 byte (OpenSSH only); everyone else's is UTF-8.
    let latin1BannerUser: String?
    /// The server starts re-exchanges after 1 MiB.
    let serverRekeys: Bool
    let maxAuthTries: Int
    let serverKeepaliveSeconds: Int

    var description: String { name }
    var isDropbear: Bool { implementation == "dropbear" }

    /// The user key names this server takes (every type, or Ed25519 only without OpenSSL).
    func acceptsKey(_ name: String) -> Bool { name != "stranger" && (openssl || name == "ed25519") }

    /// The host key blobs (base64) the server may present.
    var hostKeyBlobs: Set<String> {
      Set(hostKeys.values.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) })
    }
  }

  static let path: URL = {
    if let path = ProcessInfo.processInfo.environment["SSHENGINE_INTEROP_PROFILE"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { root.deleteLastPathComponent() }
    return root.appendingPathComponent("build/ssh-interop/profile.json")
  }()

  private static let loaded: Result<InteropProfile, InteropUnavailable> = {
    guard let data = try? Data(contentsOf: path) else {
      return .failure(InteropUnavailable(reason: "no interop profile at \(path.path): create the VM with "
        + "python3 scripts/ssh-vm.py dispatch-swift-ssh-interop, then python3 scripts/ssh-interop-vm.py provision "
        + "and start (docs/vm_testing.md)"))
    }
    do {
      let profile = try JSONDecoder().decode(InteropProfile.self, from: data)
      let answering = profile.servers.filter { InteropProbe.answers(port: $0.port) }
      guard !answering.isEmpty else {
        return .failure(InteropUnavailable(reason: "no interop server answers on the profile's ports: is the VM "
          + "running? python3 scripts/ssh-interop-vm.py start"))
      }
      return .success(profile)
    } catch {
      return .failure(InteropUnavailable(reason: "unreadable interop profile \(path.path): \(error)"))
    }
  }()

  /// The profile, or an `XCTSkip` (a failure under `SSHENGINE_INTEROP_REQUIRED=1`).
  static func load() throws -> InteropProfile {
    switch loaded {
    case .success(let profile): return profile
    case .failure(let unavailable):
      if ProcessInfo.processInfo.environment["SSHENGINE_INTEROP_REQUIRED"] == "1" { throw unavailable }
      throw XCTSkip(unavailable.reason)
    }
  }

  func keyFile(_ name: String) throws -> Data {
    guard let key = keys[name] else { throw InteropUnavailable(reason: "no key \(name) in the profile") }
    return try Data(contentsOf: URL(fileURLWithPath: key.path))
  }

  /// A file key for the Swift engine's facade.
  func fileKey(_ name: String) throws -> FileKey {
    try KeyFile.parse(SecretBytes(copying: try keyFile(name)))
  }

  /// The user key names, the stranger (never authorized) last.
  var keyNames: [String] { keys.keys.filter { $0 != "stranger" }.sorted() }

  /// Sends `signal` (TERM, KILL, STOP, CONT) to the processes in the guest that serve the connection whose session
  /// process is `pid` (and its ancestors below `server`'s listener; the helper refuses anything else). Returns the pids.
  @discardableResult
  func signal(_ server: Server, pid: Int, _ signal: String) throws -> String {
    guard let executable = self.signal.first else { throw InteropUnavailable(reason: "no signal command") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(self.signal.dropFirst()) + [server.name, String(pid), signal]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw InteropUnavailable(reason: "signal \(signal) to \(pid) on \(server.name) failed: \(output)")
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct InteropUnavailable: Error, CustomStringConvertible {
  let reason: String
  var description: String { reason }
}

/// What a server offers in its KEXINIT, read over a raw socket before any exchange (the client sends only its
/// identification line).
struct ServerOffer: Sendable, CustomStringConvertible {
  var identification = ""
  var keyExchange: [String] = []
  var hostKey: [String] = []
  var ciphers: [String] = []
  var macs: [String] = []

  var strictKex: Bool { keyExchange.contains(KexSignal.strictServer) }

  /// Supported by the engine and offered, in the engine's order.
  var engineKeyExchange: [KeyExchangeAlgorithm] { KeyExchangeAlgorithm.allCases.filter { keyExchange.contains($0.rawValue) } }
  var engineHostKey: [SignatureAlgorithm] { SignatureAlgorithm.allCases.filter { hostKey.contains($0.rawValue) } }
  var engineCiphers: [CipherAlgorithm] { CipherAlgorithm.allCases.filter { ciphers.contains($0.rawValue) } }
  var engineMACs: [MACAlgorithm] { MACAlgorithm.allCases.filter { macs.contains($0.rawValue) } }

  /// The mode `algorithms` settle on with this server (the client's first choice the server has, as SSH negotiates;
  /// the MAC only for a CTR cipher). nil when they have no cipher or MAC in common.
  func mode(_ algorithms: AlgorithmPolicy.Preferences = .standard) -> NegotiatedAlgorithms.Direction? {
    guard let cipher = algorithms.cipher.first(where: { ciphers.contains($0.rawValue) }) else { return nil }
    if cipher.isAEAD { return .init(cipher: cipher, mac: nil) }
    guard let mac = algorithms.mac.first(where: { macs.contains($0.rawValue) }) else { return nil }
    return .init(cipher: cipher, mac: mac)
  }

  /// Whether the engine's policy lets `mode` through: strict key exchange, or a mode Terrapin cannot truncate.
  func policyAllows(_ mode: NegotiatedAlgorithms.Direction) -> Bool {
    !AlgorithmPolicy.truncatableModesRequireStrictKex || strictKex || !AlgorithmPolicy.isTruncatable(mode)
  }

  /// The policy's refusal of `mode` (the engine's error).
  static func refusal(_ mode: NegotiatedAlgorithms.Direction) -> SSHError {
    if let mac = mode.mac { return .protocolViolation(.negotiation(.encryptThenMACRequiresStrictKex(mode.cipher, mac))) }
    return .protocolViolation(.negotiation(.cipherRequiresStrictKex(mode.cipher)))
  }

  /// The Swift engine connects with its standard preferences.
  var engineConnects: Bool { mode().map(policyAllows) ?? false }

  var description: String {
    "\(identification): kex \(keyExchange.joined(separator: ",")); host keys \(hostKey.joined(separator: ",")); "
      + "ciphers \(ciphers.joined(separator: ",")); MACs \(macs.joined(separator: ","))"
  }
}

enum InteropProbe {
  private static let cache = Locked<[Int: ServerOffer]>([:])

  static func answers(port: Int) -> Bool {
    guard let fd = try? LiveSSHD.connect(port: port) else { return false }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var byte = [UInt8](repeating: 0, count: 4)
    return Darwin.read(fd, &byte, 4) == 4 && byte == Array("SSH-".utf8)
  }

  /// The server's KEXINIT (cached per port for the run).
  static func offer(port: Int) throws -> ServerOffer {
    if let offer = cache.current[port] { return offer }
    let fd = try LiveSSHD.connect(port: port)
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let hello = Array("SSH-2.0-DispatchInteropProbe\r\n".utf8)
    guard hello.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == hello.count else {
      throw InteropUnavailable(reason: "probe write")
    }
    var buffer: [UInt8] = []
    func fill(_ count: Int) throws {
      var chunk = [UInt8](repeating: 0, count: 4096)
      while buffer.count < count {
        let read = Darwin.read(fd, &chunk, chunk.count)
        guard read > 0 else { throw InteropUnavailable(reason: "probe read on \(port): \(read)") }
        buffer += chunk[0..<read]
      }
    }
    var offer = ServerOffer()
    while true {
      while buffer.firstIndex(of: 0x0a) == nil { try fill(buffer.count + 1) }
      let end = buffer.firstIndex(of: 0x0a)!
      let line = String(decoding: buffer[..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      buffer.removeFirst(end + 1)
      if line.hasPrefix("SSH-") {
        offer.identification = line
        break
      }
    }
    try fill(5)
    let length = Int(UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3]))
    guard length < 64 * 1024 else { throw InteropUnavailable(reason: "probe: packet length \(length)") }
    try fill(4 + length)
    let padding = Int(buffer[4])
    var payload = ArraySlice(buffer[5..<(4 + length - padding)])
    guard payload.first == MessageNumber.kexInit.rawValue else { throw InteropUnavailable(reason: "probe: not KEXINIT") }
    payload = payload.dropFirst(17)
    func nameList() throws -> [String] {
      guard payload.count >= 4 else { throw InteropUnavailable(reason: "probe: short KEXINIT") }
      let bytes = Array(payload.prefix(4))
      let count = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
      payload = payload.dropFirst(4)
      guard payload.count >= count else { throw InteropUnavailable(reason: "probe: short name-list") }
      let text = String(decoding: payload.prefix(count), as: UTF8.self)
      payload = payload.dropFirst(count)
      return text.isEmpty ? [] : text.split(separator: ",").map(String.init)
    }
    offer.keyExchange = try nameList()
    offer.hostKey = try nameList()
    offer.ciphers = try nameList()
    _ = try nameList()
    offer.macs = try nameList()
    cache.update { $0[port] = offer }
    return offer
  }
}

/// One line per (test, server, engine) outcome, printed as a table when the class ends (the record of a run).
final class InteropRecord: @unchecked Sendable {
  static let shared = InteropRecord()
  private let lines = Locked<[(test: String, server: String, engine: String, outcome: String)]>([])

  func add(_ test: String, _ server: String, _ engine: String, _ outcome: String) {
    lines.update { $0.append((test, server, engine, outcome)) }
    print("INTEROP \(test) | \(server) | \(engine) | \(outcome)")
  }

  /// Prints and forgets every line so far.
  func flush(_ title: String) {
    let taken = lines.update { all -> [(test: String, server: String, engine: String, outcome: String)] in
      defer { all = [] }
      return all
    }
    guard !taken.isEmpty else { return }
    print("INTEROP SUMMARY \(title)")
    for line in taken { print("  \(line.test) | \(line.server) | \(line.engine) | \(line.outcome)") }
  }
}

/// A failure of one server's run with a readable cause.
struct InteropFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

/// Documented bugs of the servers in the profile that a case can trigger: the run is recorded with the note, not failed.
enum KnownServerBug {
  /// On the Swift engine, which settles on AES-CTR with hmac-sha2-256 there (ChaCha20-Poly1305 being refused without
  /// strict key exchange): OpenSSH 7.9p1 built without OpenSSL closes every connection that negotiates AES-CTR right
  /// after the algorithms are agreed, before NEWKEYS ("ssh_dispatch_run_fatal: unexpected internal error [preauth]").
  /// OpenSSH 10.5's own client gets the same with any AES-CTR and MAC; the same binary run as `sshd -ddd` (no re-exec,
  /// no privilege separation) completes the exchange; ChaCha20-Poly1305 works either way.
  static func swiftEngine(_ server: InteropProfile.Server) -> String? {
    server.implementation == "openssh" && !server.openssl
      ? "OpenSSH 7.9p1 without OpenSSL resets the connection when AES-CTR is negotiated" : nil
  }
}

/// Runs `body` for every server, each bounded and caught on its own (one server's failure never hides another's),
/// recording the outcome: the returned note, or the failure. `serverBug`: a documented server bug the case can trigger
/// on that server (`KnownServerBug`); its outcome is recorded with the note either way, never failed.
func forEachServer(_ profile: InteropProfile, _ test: String, engine: String, seconds: Double = 120,
                   serverBug: @escaping @Sendable (InteropProfile.Server) -> String? = { _ in nil },
                   file: StaticString = #filePath, line: UInt = #line,
                   _ body: @escaping @Sendable (InteropProfile.Server) async throws -> String) async {
  for server in profile.servers {
    let known = serverBug(server)
    do {
      let note = try await bounded(seconds, "\(test) on \(server.name)") { try await body(server) }
      InteropRecord.shared.add(test, server.name, engine, note + (known.map { " (despite: \($0))" } ?? ""))
    } catch let skip as XCTSkip {
      InteropRecord.shared.add(test, server.name, engine, "n/a: \(skip.message ?? "")")
    } catch {
      if let known {
        InteropRecord.shared.add(test, server.name, engine, "fails, \(known): \(error)")
        continue
      }
      InteropRecord.shared.add(test, server.name, engine, "FAIL: \(error)")
      XCTFail("\(test) on \(server.name) (\(engine)): \(error)", file: file, line: line)
    }
  }
}

/// Fails the server's run unless `condition` holds.
func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  guard condition else { throw InteropFailure(message()) }
}

/// The SHA-256 of `bytes` as lowercase hex (what `sha256sum` prints).
func sha256Hex(_ bytes: some DataProtocol) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
#endif
