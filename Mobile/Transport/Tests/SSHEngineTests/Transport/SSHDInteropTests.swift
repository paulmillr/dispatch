#if os(macOS)
import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

/// The transport against the real OpenSSH server on this Mac (`/usr/sbin/sshd`, a private instance on a free loopback
/// port): the independent check of every key exchange method (ML-KEM and X25519 included), cipher (the hand-assembled
/// ChaCha20-Poly1305 included), MAC and host key type. Each combination:
///
/// 1. completes the first exchange with the host key sshd serves for the negotiated algorithm (its signature checked
///    by the test-only verifier) and gets SERVICE_ACCEPT and sshd's EXT_INFO;
/// 2. has a `none` login refused, then logs in with a signed `publickey` request (a test-only Ed25519 key; the test
///    drives `ClientTransport` alone, without the auth layer, so it builds the two messages itself; `LiveClientTests`
///    runs the whole engine);
/// 3. runs a re-exchange of its own, then streams data of every size up to the 32 KiB channel maximum through
///    `/bin/cat` (sshd's `ForceCommand`) and back, while sshd starts re-exchanges of its own (`RekeyLimit 32K`), and
///    ends with one more re-exchange of ours and a keepalive sshd answers.
///
/// Skipped when sshd cannot be started. `SSHENGINE_SSHD_FULL=1` runs the full cross product instead of the covering
/// set.
final class SSHDInteropTests: XCTestCase {
  nonisolated(unsafe) private static var sshd: LiveSSHD?
  nonisolated(unsafe) private static var startFailure: String?
  nonisolated(unsafe) private static var userKey = Curve25519.Signing.PrivateKey()
  /// What passed, one line per combination, printed at the end for the record.
  nonisolated(unsafe) private static var passed: [String] = []

  override class func setUp() {
    super.setUp()
    let blob = PublicKeyBlob.ed25519(Array(userKey.publicKey.rawRepresentation)).encoded
    do { sshd = try LiveSSHD(authorizedKey: "ssh-ed25519 " + Data(blob).base64EncodedString(), rekeyLimit: "32K none") } catch {
      startFailure = "\(error)"
    }
  }

  override class func tearDown() {
    if let sshd {
      print("SSHDInteropTests against \(sshd.version): \(passed.count) combinations passed")
      for line in passed { print("  ok \(line)") }
    }
    sshd?.stop()
    sshd = nil
    super.tearDown()
  }

  private func server() throws -> LiveSSHD {
    guard let sshd = Self.sshd else { throw XCTSkip("sshd could not be started: \(Self.startFailure ?? "unknown")") }
    return sshd
  }

  static var full: Bool { ProcessInfo.processInfo.environment["SSHENGINE_SSHD_FULL"] == "1" }

  private func session(_ algorithms: AlgorithmPolicy.Preferences = .standard, keepalive: Duration? = .seconds(15),
                       count: Int = 3) throws -> (ClientTransport, SocketDriver) {
    let sshd = try server()
    let options = ConnectOptions(host: "127.0.0.1", port: UInt16(sshd.port), keepaliveInterval: keepalive,
                                 keepaliveCountMax: count, algorithms: algorithms)
    let core = try ClientTransport(options: options, verifier: TestSignatureVerifier(), random: SystemRandom())
    return (core, try SocketDriver(port: sshd.port, core: core))
  }

  // MARK: Steps of a session

  /// SERVICE_REQUEST, a refused `none`, then a signed publickey request: the connection phase.
  private func logIn(_ core: ClientTransport, _ driver: SocketDriver, _ label: String) throws {
    try core.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-userauth"))
    driver.service = .serviceRequested
    let accept = try driver.nextMessage()
    XCTAssertEqual(accept.payload, [MessageNumber.serviceAccept.rawValue] + Raw.string("ssh-userauth"), label)
    // OpenSSH sends EXT_INFO right behind its NEWKEYS, with server-sig-algs.
    XCTAssertNotNil(core.serverExtensions?.serverSignatureAlgorithms, label)
    let user = NSUserName()
    let none = [MessageNumber.userauthRequest.rawValue] + Raw.string(user) + Raw.string("ssh-connection") + Raw.string("none")
    try core.send(none)
    driver.service = .userauth(.noneMethod)
    XCTAssertEqual(try driver.nextMessage().number, .userauthFailure, label)
    let blob = PublicKeyBlob.ed25519(Array(Self.userKey.publicKey.rawRepresentation)).encoded
    let request = [MessageNumber.userauthRequest.rawValue] + Raw.string(user) + Raw.string("ssh-connection")
      + Raw.string("publickey") + [1] + Raw.string("ssh-ed25519") + Raw.string(blob)
    let signature = try Self.userKey.signature(for: Raw.string(core.sessionID) + request)
    let signed = request + Raw.string(Raw.string("ssh-ed25519") + Raw.string(Array(signature)))
    try core.send(signed)
    driver.service = .userauth(.publicKeySigned)
    let answer = try driver.nextMessage()
    XCTAssertEqual(answer.number, .userauthSuccess, "\(label): \(answer.payload)")
    try driver.enter(.connection)
  }

  private func rekey(_ core: ClientTransport, _ driver: SocketDriver, _ label: String) throws {
    core.timerFired(.rekey)
    XCTAssertEqual(try driver.run { $0 == .rekeyed }, .rekeyed, "\(label): \(driver.events.suffix(4))")
  }

  /// A session channel running `/bin/cat`; returns the server's channel number and window.
  private func openCat(_ core: ClientTransport, _ driver: SocketDriver, _ label: String) throws -> (UInt32, UInt32) {
    try core.send([MessageNumber.channelOpen.rawValue] + Raw.string("session") + Raw.u32(0) + Raw.u32(Limits.channelWindow)
                  + Raw.u32(Limits.channelMaximumPacket))
    let confirmation = try driver.nextMessage()
    XCTAssertEqual(confirmation.number, .channelOpenConfirmation, label)
    let (remote, window) = try confirmation.decode { (reader: inout WireReader) throws(WireError) -> (UInt32, UInt32) in
      _ = try reader.readUInt32()
      let remote = try reader.readUInt32()
      let window = try reader.readUInt32()
      _ = try reader.readUInt32()
      return (remote, window)
    }
    try core.send([MessageNumber.channelRequest.rawValue] + Raw.u32(remote) + Raw.string("exec") + [1] + Raw.string("cat"))
    while true {
      let message = try driver.nextMessage()
      if message.number == .channelSuccess { break }
      XCTAssertEqual(message.number, .channelWindowAdjust, label)
    }
    return (remote, window)
  }

  /// Sends `bytes` through cat in pieces of the given sizes and reads them back. Returns the re-exchanges sshd ran
  /// meanwhile.
  private func echo(_ core: ClientTransport, _ driver: SocketDriver, channel: UInt32, sizes: [Int], _ label: String) throws -> Int {
    let rekeysBefore = driver.events.filter { $0 == .rekeyed }.count
    var expected: [UInt8] = []
    var received: [UInt8] = []
    for (index, size) in sizes.enumerated() {
      let chunk = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index &* 13) }
      expected += chunk
      try core.send([MessageNumber.channelData.rawValue] + Raw.u32(channel) + Raw.string(chunk))
      while received.count < expected.count {
        let message = try driver.nextMessage()
        switch message.number {
        case .channelData:
          let data = try message.decode { (reader: inout WireReader) throws(WireError) -> [UInt8] in
            _ = try reader.readUInt32()
            return try reader.readString(limit: Int(Limits.channelMaximumPacket))
          }
          received += data
        case .channelWindowAdjust:
          continue
        default:
          XCTFail("\(label): \(message.number)")
          return 0
        }
      }
    }
    XCTAssertEqual(received, expected, label)
    return driver.events.filter { $0 == .rekeyed }.count - rekeysBefore
  }

  /// One combination, end to end.
  private func run(kex: KeyExchangeAlgorithm, cipher: CipherAlgorithm, mac: MACAlgorithm?, hostKey: SignatureAlgorithm,
                   file: StaticString = #filePath, line: UInt = #line) throws {
    let sshd = try server()
    let label = "\(kex.rawValue) \(cipher.rawValue) \(mac?.rawValue ?? "-") \(hostKey.rawValue)"
    let (core, driver) = try session(AlgorithmPolicy.Preferences(keyExchange: [kex], hostKey: [hostKey], cipher: [cipher],
                                                                 mac: mac.map { [$0] } ?? []))
    defer { driver.close() }
    var presented: HostKey?
    driver.trust = { key in
      presented = key
      return true
    }
    core.start()
    let established = try driver.run { $0 == .established }
    guard established == .established else {
      return XCTFail("\(label): \(driver.events) \(sshd.log)", file: file, line: line)
    }
    XCTAssertEqual(presented?.algorithm, hostKey, label, file: file, line: line)
    XCTAssertEqual(presented?.blob, sshd.hostKeyBlobs[hostKey.keyType], label, file: file, line: line)
    XCTAssertEqual(core.negotiated?.keyExchange, kex, label, file: file, line: line)
    XCTAssertEqual(core.negotiated?.clientToServer, .init(cipher: cipher, mac: mac), label, file: file, line: line)
    XCTAssertEqual(core.negotiated?.serverToClient, .init(cipher: cipher, mac: mac), label, file: file, line: line)
    XCTAssertEqual(core.negotiated?.strictKex, true, label, file: file, line: line)
    XCTAssertEqual(core.sessionID.count, kex.hash.digestBytes, label, file: file, line: line)

    try logIn(core, driver, label)
    try rekey(core, driver, label)
    let (channel, _) = try openCat(core, driver, label)
    let sizes = [1, 2, 15, 16, 17, 31, 32, 33, 255, 256, 1000, 4095, 4096, 4097, 16383, 16384, 32767, 32768, 32768, 32768]
    let serverRekeys = try echo(core, driver, channel: channel, sizes: sizes, label)
    XCTAssertGreaterThan(serverRekeys, 0, "\(label): sshd's RekeyLimit started no re-exchange")
    try rekey(core, driver, label)
    _ = try echo(core, driver, channel: channel, sizes: [5000, 1], label)
    // A keepalive after authentication: sshd answers REQUEST_FAILURE, which counts as the answer.
    core.timerFired(.keepalive)
    _ = try echo(core, driver, channel: channel, sizes: [3], label)
    XCTAssertTrue(core.isOpen, label, file: file, line: line)
    XCTAssertNil(driver.events.first { if case .ended = $0 { true } else { false } }, label, file: file, line: line)
    core.end(.closed(.byClient))
    try? driver.flush()
    Self.passed.append("\(label) (sshd re-exchanges: \(serverRekeys))")
  }

  // MARK: The matrix

  func testEveryKeyExchangeMethodWithEveryAEADCipher() throws {
    for kex in KeyExchangeAlgorithm.allCases {
      for cipher in [CipherAlgorithm.aes256GCM, .aes128GCM, .chacha20Poly1305] {
        try run(kex: kex, cipher: cipher, mac: nil, hostKey: .ed25519)
      }
    }
  }

  func testEveryCTRCipherWithEveryMAC() throws {
    for cipher in [CipherAlgorithm.aes256CTR, .aes192CTR, .aes128CTR] {
      for mac in MACAlgorithm.allCases {
        try run(kex: .curve25519, cipher: cipher, mac: mac, hostKey: .ed25519)
        try run(kex: .mlkem768x25519, cipher: cipher, mac: mac, hostKey: .ecdsaP256)
      }
    }
  }

  func testEveryHostKeyAlgorithm() throws {
    for hostKey in SignatureAlgorithm.allCases {
      try run(kex: .curve25519, cipher: .chacha20Poly1305, mac: nil, hostKey: hostKey)
      try run(kex: .mlkem768x25519, cipher: .aes256GCM, mac: nil, hostKey: hostKey)
      try run(kex: .ecdhP521, cipher: .aes128CTR, mac: .hmacSHA512ETM, hostKey: hostKey)
    }
  }

  func testTheFullCrossProduct() throws {
    guard Self.full else { throw XCTSkip("set SSHENGINE_SSHD_FULL=1 for every combination") }
    for kex in KeyExchangeAlgorithm.allCases {
      for hostKey in SignatureAlgorithm.allCases {
        for (cipher, mac) in PacketProtectionTests.families {
          try run(kex: kex, cipher: cipher, mac: mac, hostKey: hostKey)
        }
      }
    }
  }

  // MARK: Behaviour against sshd

  /// The standard preferences negotiate ML-KEM, Ed25519 and AES-256-GCM with sshd 10 (the engine's order).
  func testTheStandardPreferences() throws {
    let (core, driver) = try session()
    defer { driver.close() }
    core.start()
    XCTAssertEqual(try driver.run { $0 == .established }, .established, "\(driver.events)")
    XCTAssertEqual(core.negotiated?.keyExchange, .mlkem768x25519)
    XCTAssertEqual(core.negotiated?.hostKey, .ed25519)
    XCTAssertEqual(core.negotiated?.clientToServer.cipher, .aes256GCM)
    XCTAssertTrue(core.negotiated?.serverSendsExtInfo ?? false)
  }

  /// A re-exchange of ours due before authentication waits for the connection phase (sshd answers a KEXINIT before
  /// authentication with UNIMPLEMENTED), then runs at once.
  func testOurReexchangeWaitsForTheConnectionPhase() throws {
    let (core, driver) = try session()
    defer { driver.close() }
    core.start()
    XCTAssertEqual(try driver.run { $0 == .established }, .established)
    core.timerFired(.rekey)
    try logIn(core, driver, "deferred")
    XCTAssertEqual(try driver.run { $0 == .rekeyed }, .rekeyed, "\(driver.events)")
    XCTAssertTrue(core.isOpen)
  }

  /// Keepalives after authentication: sshd answers each (REQUEST_FAILURE), the answer is matched to the keepalive and
  /// resets the count, so a count of 1 survives many. Before authentication none goes, even when the timer is fired
  /// (RFC 4252 §6: sshd would answer UNIMPLEMENTED, Dropbear disconnects).
  func testKeepalivesAreAnswered() throws {
    let (core, driver) = try session(keepalive: .seconds(1), count: 1)
    defer { driver.close() }
    core.start()
    XCTAssertEqual(try driver.run { $0 == .established }, .established)
    func keepalives(_ phase: String) throws {
      for _ in 0..<5 {
        core.timerFired(.keepalive)
        XCTAssertEqual(core.keepalivesOutstanding, 1)
        let event = try driver.run(timeout: 5) { _ in core.keepalivesOutstanding == 0 }
        XCTAssertEqual(core.keepalivesOutstanding, 0, "\(phase): \(event)")
      }
    }
    for _ in 0..<3 {
      core.timerFired(.keepalive)
      XCTAssertEqual(core.keepalivesOutstanding, 0, "a keepalive before authentication")
    }
    try logIn(core, driver, "keepalive")
    try keepalives("after authentication")
    XCTAssertTrue(core.isOpen)
  }

  /// sshd's own DISCONNECT, read under the new keys: a SERVICE_REQUEST for a service it does not have.
  func testSSHDsDisconnect() throws {
    let (core, driver) = try session()
    defer { driver.close() }
    core.start()
    XCTAssertEqual(try driver.run { $0 == .established }, .established)
    try core.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-nonexistent"))
    driver.service = .serviceRequested
    let event = try driver.run { _ in false }
    guard case .ended(.closed(.byServer(let reason, let description))) = event else { return XCTFail("\(event)") }
    XCTAssertEqual(reason, .protocolError)
    XCTAssertTrue(description.contains("ssh-nonexistent"), description)
  }

  /// A host key the client does not trust: no NEWKEYS goes, sshd sees the DISCONNECT.
  func testARejectedHostKey() throws {
    let (core, driver) = try session()
    defer { driver.close() }
    driver.trust = { _ in false }
    core.start()
    XCTAssertEqual(try driver.run { _ in false }, .ended(.hostKeyRejected))
  }
}
#endif
