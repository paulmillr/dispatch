#if os(macOS)
import Foundation
import XCTest
@testable import SSHEngine

/// The Swift engine through its own facade (`ClientConnector` over Network.framework, the production verifier) against
/// every server in the interop profile (InteropSupport.swift): what only the facade can choose or see. Each algorithm
/// the server offers and the engine implements, one category constrained per run (key exchange, host key, cipher with
/// each MAC), checked against the negotiated set and the host key the server was given; on a server without strict key
/// exchange, ChaCha20-Poly1305 and AES-CTR with an encrypt-then-MAC MAC must be refused by
/// `AlgorithmPolicy.truncatableModesRequireStrictKex` before anything is trusted, and the other modes must connect. Logins with every key kind, asked and direct, and the server's answers as `AuthOutcome` (two methods in
/// sequence: a partial success). Re-exchanges from both sides under a 16 MiB transfer; keepalives before and after
/// the login. The public API's tests on both engines are `InteropSessionTests`.
final class InteropEngineTests: XCTestCase {
  override class func tearDown() {
    InteropRecord.shared.flush("InteropEngineTests (Swift engine facade)")
    super.tearDown()
  }

  // MARK: Connecting

  static func options(_ server: InteropProfile.Server, _ algorithms: AlgorithmPolicy.Preferences = .standard,
                      keepalive: Duration? = nil, count: Int = 3) -> ConnectOptions {
    ConnectOptions(host: "127.0.0.1", port: UInt16(server.port), handshakeTimeout: .seconds(20),
                   keepaliveInterval: keepalive, keepaliveCountMax: count, algorithms: algorithms)
  }

  /// Connects, trusting only the host keys the server was given (each question recorded).
  static func connect(_ server: InteropProfile.Server, _ options: ConnectOptions, tuning: DriverTuning = DriverTuning(),
                      asked: Locked<[HostKey]> = Locked([])) async throws(SSHError) -> any SSHSession {
    let blobs = server.hostKeyBlobs
    let connector = ClientConnector(streams: NetworkStreamConnector(), tuning: tuning)
    return try await connector.connect(options) { key in
      asked.update { $0.append(key) }
      return blobs.contains(Data(key.blob).base64EncodedString())
    }
  }

  static func password(_ profile: InteropProfile) -> Credential { .password(SecretBytes(utf8: profile.password)) }

  static func run(_ session: any SSHSession, _ command: String, input: [UInt8]? = nil) async throws
    -> (Collected, ChannelExit)
  {
    let exec = try await session.exec(command)
    let writer = Task {
      if let input { try await exec.write(input) }
      await exec.finishInput()
    }
    let output = try await Collected.all(exec)
    try await writer.value
    return (output, await exec.exit())
  }

  // MARK: Algorithms

  /// One run with `algorithms`: either it connects (then the negotiated set is the expected one, the host key the
  /// server's of that type, and a password login, a command and 64 KiB through `cat` work), or the policy refuses it
  /// before any trust question, exactly when the expected cipher needs strict key exchange the server lacks.
  static func attempt(_ profile: InteropProfile, _ server: InteropProfile.Server, _ offer: ServerOffer,
                      _ algorithms: AlgorithmPolicy.Preferences) async throws -> String {
    let kex = try XCTUnwrap(algorithms.keyExchange.first { offer.keyExchange.contains($0.rawValue) })
    let hostKey = try XCTUnwrap(algorithms.hostKey.first { offer.hostKey.contains($0.rawValue) })
    let mode = try XCTUnwrap(offer.mode(algorithms))
    let (cipher, mac) = (mode.cipher, mode.mac)
    let asked = Locked<[HostKey]>([])
    let session: any SSHSession
    do {
      session = try await connect(server, options(server, algorithms), asked: asked)
    } catch {
      try require(!offer.policyAllows(mode) && error == ServerOffer.refusal(mode), "\(kex.rawValue)/\(hostKey.rawValue)/"
                  + "\(cipher.rawValue)/\(mac?.rawValue ?? "-"): \(error) (\(offer))")
      try require(asked.current.isEmpty, "a refused connection asked about the host key")
      return "refused: \(error)"
    }
    defer { Task { await session.close() } }
    try require(offer.policyAllows(mode), "\(mode) connected without strict key exchange")
    let current = await session.driver.negotiated
    let negotiated = try XCTUnwrap(current)
    let expected = NegotiatedAlgorithms.Direction(cipher: cipher, mac: mac)
    try require(negotiated.keyExchange == kex && negotiated.hostKey == hostKey && negotiated.clientToServer == expected
                && negotiated.serverToClient == expected && negotiated.strictKex == offer.strictKex,
                "negotiated \(negotiated), expected \(kex) \(hostKey) \(expected) strict \(offer.strictKex)")
    let keyName = ["ssh-ed25519": "ed25519", "ecdsa-sha2-nistp256": "ecdsa256", "ecdsa-sha2-nistp384": "ecdsa384",
                   "ecdsa-sha2-nistp521": "ecdsa521", "ssh-rsa": "rsa"][hostKey.keyType] ?? ""
    try require(server.hostKeys[keyName] == session.hostKey.openSSH,
                "presented \(session.hostKey.openSSH), the server's \(keyName) is \(server.hostKeys[keyName] ?? "none")")
    try require(asked.current.count == 1, "asked \(asked.current.count) times")
    let outcome = try await session.authenticate(user: profile.user, with: password(profile))
    try require(outcome == .success, "password: \(outcome)")
    let data = LiveClientTests.pseudoRandom(64 * 1024, seed: 11)
    let (echoed, exit) = try await run(session, "cat", input: data)
    try require(echoed.stdout == data && exit == .status(0), "cat: \(echoed.stdout.count) bytes, \(exit)")
    await session.close()
    return "ok\(negotiated.strictKex ? "" : " (no strict kex)")"
  }

  static func walk(_ test: String, seconds: Double = 300,
                   _ variants: @escaping @Sendable (ServerOffer) -> [(String, AlgorithmPolicy.Preferences)]) async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, test, engine: "swift", seconds: seconds,
                        serverBug: KnownServerBug.swiftEngine) { server in
      let offer = try InteropProbe.offer(port: server.port)
      var notes: [String] = []
      var failures: [String] = []
      for (label, algorithms) in variants(offer) {
        do {
          notes.append("\(label) \(try await attempt(profile, server, offer, algorithms))")
        } catch {
          failures.append("\(label): \(error)")
        }
      }
      try require(failures.isEmpty, failures.joined(separator: "; "))
      try require(!notes.isEmpty, "nothing in common: \(offer)")
      return notes.joined(separator: "; ")
    }
  }

  /// What each server offers, for the record (and the standard preferences' outcome).
  func testStandardPreferences() async throws {
    try await Self.walk("standard preferences") { offer in
      print("INTEROP OFFER \(offer)")
      return [("standard", .standard)]
    }
  }

  /// Every key exchange method both sides have, with the standard host keys and ciphers.
  func testEveryKeyExchangeMethod() async throws {
    try await Self.walk("key exchange") { offer in
      offer.engineKeyExchange.map { kex in
        var algorithms = AlgorithmPolicy.Preferences.standard
        algorithms.keyExchange = [kex]
        return (kex.rawValue, algorithms)
      }
    }
  }

  /// Every host key algorithm both sides have (the server holds a key of each type it offers).
  func testEveryHostKeyAlgorithm() async throws {
    try await Self.walk("host key") { offer in
      offer.engineHostKey.map { hostKey in
        var algorithms = AlgorithmPolicy.Preferences.standard
        algorithms.hostKey = [hostKey]
        return (hostKey.rawValue, algorithms)
      }
    }
  }

  /// Every cipher both sides have, a CTR cipher with each MAC: on a server without strict key exchange, only AES-GCM
  /// connects.
  func testEveryCipherAndMAC() async throws {
    try await Self.walk("cipher and MAC") { offer in
      offer.engineCiphers.flatMap { cipher -> [(String, AlgorithmPolicy.Preferences)] in
        let macs: [[MACAlgorithm]] = cipher.isAEAD ? [AlgorithmPolicy.Preferences.standard.mac] : offer.engineMACs.map { [$0] }
        return macs.map { mac in
          var algorithms = AlgorithmPolicy.Preferences.standard
          algorithms.cipher = [cipher]
          algorithms.mac = mac
          return (cipher.isAEAD ? cipher.rawValue : "\(cipher.rawValue)+\(mac[0].rawValue)", algorithms)
        }
      }
    }
  }

  // MARK: Logins

  /// Every user key, asked first and direct: the keys the server takes log in, the others are refused with publickey
  /// still allowed; the stranger is refused; then the password logs in on the connection that refused it.
  func testEveryUserKeyAskedAndDirect() async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, "user keys (facade)", engine: "swift", seconds: 300, serverBug: KnownServerBug.swiftEngine) { server in
      guard try InteropProbe.offer(port: server.port).engineConnects else { throw XCTSkip("refused by policy") }
      var notes: [String] = []
      for name in profile.keyNames + ["stranger"] {
        let key = try profile.fileKey(name)
        for direct in [false, true] {
          let session = try await Self.connect(server, Self.options(server))
          let outcome = try await session.authenticate(user: profile.user, with: .publicKey(key, direct: direct))
          if server.acceptsKey(name) {
            try require(outcome == .success, "\(name) direct \(direct): \(outcome)")
            let (output, _) = try await Self.run(session, "id -un")
            try require(output.stdout == Array("\(profile.user)\n".utf8), "\(name): \(output)")
          } else {
            guard case .refused(let remaining, false) = outcome, remaining.contains(.publicKey) else {
              throw InteropFailure("\(name) direct \(direct): \(outcome)")
            }
            let next = try await session.authenticate(user: profile.user, with: Self.password(profile))
            try require(next == .success, "password after the refused \(name): \(next)")
            notes.append("\(name)\(direct ? " direct" : "") refused (\(remaining.names.joined(separator: ",")))")
          }
          await session.close()
        }
      }
      return notes.isEmpty ? "every key logs in" : "ok; " + notes.joined(separator: "; ")
    }
  }

  /// Keyboard-interactive answered with the password (PAM's prompt on OpenSSH; Dropbear has no such method).
  func testKeyboardInteractive() async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, "keyboard-interactive (facade)", engine: "swift", serverBug: KnownServerBug.swiftEngine) { server in
      guard try InteropProbe.offer(port: server.port).engineConnects else { throw XCTSkip("refused by policy") }
      let session = try await Self.connect(server, Self.options(server))
      defer { Task { await session.close() } }
      let prompts = Locked<[String]>([])
      let password = profile.password
      let outcome = try await session.authenticate(user: profile.user, with: .keyboardInteractive { challenge in
        prompts.update { $0 += challenge.prompts.map(\.text) }
        return challenge.prompts.map { _ in SecretBytes(utf8: password) }
      })
      guard server.keyboardInteractive else {
        guard case .refused(let remaining, false) = outcome, !remaining.contains(.keyboardInteractive) else {
          throw InteropFailure("\(outcome)")
        }
        return "refused, as the server has no keyboard-interactive (\(remaining.names.joined(separator: ",")))"
      }
      try require(outcome == .success, "\(outcome), prompts \(prompts.current)")
      return "ok, prompts \(prompts.current)"
    }
  }

  /// OpenSSH's `AuthenticationMethods publickey,password publickey,keyboard-interactive`: the key is a partial success
  /// naming what is left, then the password or keyboard-interactive logs in; a password first is refused.
  func testTwoMethodsInSequence() async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, "two methods (facade)", engine: "swift", serverBug: KnownServerBug.swiftEngine) { server in
      guard let user = server.multiFactorUser else { throw XCTSkip("Dropbear has no AuthenticationMethods") }
      guard try InteropProbe.offer(port: server.port).engineConnects else { throw XCTSkip("refused by policy") }
      let key = try profile.fileKey("ed25519")
      let session = try await Self.connect(server, Self.options(server))
      let early = try await session.authenticate(user: user, with: Self.password(profile))
      try require(early == .refused(remaining: [.publicKey], partialSuccess: false), "password first: \(early)")
      let partial = try await session.authenticate(user: user, with: .publicKey(key, direct: false))
      try require(partial == .refused(remaining: [.password, .keyboardInteractive], partialSuccess: true), "key: \(partial)")
      let done = try await session.authenticate(user: user, with: Self.password(profile))
      try require(done == .success, "then the password: \(done)")
      let (output, _) = try await Self.run(session, "id -un")
      try require(output.stdout == Array("\(user)\n".utf8), "\(output)")
      await session.close()
      // Direct, then keyboard-interactive.
      let second = try await Self.connect(server, Self.options(server))
      let directPartial = try await second.authenticate(user: user, with: .publicKey(key, direct: true))
      try require(directPartial == .refused(remaining: [.password, .keyboardInteractive], partialSuccess: true),
                  "direct key: \(directPartial)")
      let password = profile.password
      let kbd = try await second.authenticate(user: user, with: .keyboardInteractive { challenge in
        challenge.prompts.map { _ in SecretBytes(utf8: password) }
      })
      try require(kbd == .success, "then keyboard-interactive: \(kbd)")
      await second.close()
      return "ok: \(early), \(partial), success"
    }
  }

  /// Wrong passwords on one connection up to the server's limit (MaxAuthTries / dropbear -T 3): the refusals, then
  /// how the server ends it, as the facade reports it.
  func testTheServersLimitOnAttempts() async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, "attempt limit (facade)", engine: "swift", serverBug: KnownServerBug.swiftEngine) { server in
      guard try InteropProbe.offer(port: server.port).engineConnects else { throw XCTSkip("refused by policy") }
      let session = try await Self.connect(server, Self.options(server))
      var outcomes: [AuthOutcome] = []
      for attempt in 1...server.maxAuthTries {
        outcomes.append(try await session.authenticate(user: profile.user,
                                                       with: .password(SecretBytes(utf8: "wrong-\(attempt)"))))
      }
      // The server ends the connection at its limit, while the last attempt waits: that attempt is a refusal naming no
      // method (UserauthCore.connectionEnded), so the login reads as failed instead of as a lost link.
      guard outcomes.dropLast().allSatisfy({ if case .refused(let remaining, false) = $0 { !remaining.isEmpty } else { false } }),
        outcomes.last == .refused(remaining: [], partialSuccess: false)
      else { throw InteropFailure("outcomes \(outcomes)") }
      let end = try await bounded(10, "the end") { await session.ended() }
      var next: SSHError?
      do throws(SSHError) {
        _ = try await session.authenticate(user: profile.user, with: Self.password(profile))
      } catch { next = error }
      try require(next == .closed(.alreadyEnded), "another attempt: \(String(describing: next))")
      return "refused \(outcomes.count) times, the last with no method left; ended: \(end)"
    }
  }

  // MARK: Re-exchanges and keepalives

  /// 16 MiB through `cat` while re-exchanges run: started by the server (RekeyLimit 1M) where it has one, then by the
  /// client (its threshold lowered to 1 MiB) on every server.
  func testReexchangesUnderLoadFromBothSides() async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, "re-exchanges (facade)", engine: "swift", seconds: 600, serverBug: KnownServerBug.swiftEngine) { server in
      guard try InteropProbe.offer(port: server.port).engineConnects else { throw XCTSkip("refused by policy") }
      var notes: [String] = []
      for side in ["server", "client"] {
        if side == "server", !server.serverRekeys {
          notes.append("server: none (no rekey limit)")
          continue
        }
        var tuning = DriverTuning()
        if side == "client" { tuning.rekeyBytes = 1 << 20 }
        let session = try await Self.connect(server, Self.options(server), tuning: tuning)
        let outcome = try await session.authenticate(user: profile.user, with: Self.password(profile))
        try require(outcome == .success, "\(outcome)")
        let data = LiveClientTests.pseudoRandom(16 << 20, seed: side == "server" ? 21 : 22)
        let (output, exit) = try await Self.run(session, "cat", input: data)
        try require(output.stdout == data, "\(side): \(output.stdout.count) of \(data.count) bytes came back")
        try require(exit == .status(0), "\(side): \(exit)")
        let stats = await session.driver.stats
        try require(stats.rekeys >= 8, "\(side): \(stats.rekeys) re-exchanges")
        let end = await session.driver.endReason
        try require(end == nil, "\(side): ended \(String(describing: end))")
        await session.close()
        notes.append("\(side): \(stats.rekeys) re-exchanges")
      }
      return notes.joined(separator: "; ")
    }
  }

  /// The login held 3.5 s (the user at a password prompt) with a 1 s keepalive interval: no keepalive goes before the
  /// login (Dropbear would end the connection), the login and a command work, and after it keepalives go and are
  /// answered (a count of 1 tolerates no silence).
  func testKeepalivesBeforeAndAfterTheLogin() async throws {
    let profile = try InteropProfile.load()
    await forEachServer(profile, "keepalives (facade)", engine: "swift", serverBug: KnownServerBug.swiftEngine) { server in
      guard try InteropProbe.offer(port: server.port).engineConnects else { throw XCTSkip("refused by policy") }
      let session = try await Self.connect(server, Self.options(server, keepalive: .seconds(1), count: 1))
      try await Task.sleep(for: .milliseconds(3500))
      let before = await session.driver.stats
      let early = await session.driver.endReason
      try require(early == nil, "ended before the login: \(String(describing: early))")
      try require(before.keepalivesFired == 0, "\(before.keepalivesFired) keepalives before the login")
      let outcome = try await session.authenticate(user: profile.user, with: Self.password(profile))
      try require(outcome == .success, "\(outcome)")
      let fired = before.keepalivesFired
      if server.release == "dropbear-2022.83" {
        // Dropbear before 2024.84 answers no global request when remote forwarding is disabled (-k): unanswered
        // keepalives end an idle connection after (count + 1) intervals, unless the server's own -K keepalives come
        // first. Recorded, not failed.
        let end = try? await bounded(10, "the keepalive timeout") { await session.ended() }
        await session.close()
        return "fails, Dropbear before 2024.84 answers no global request with -k: \(String(describing: end))"
      }
      let after = try await bounded(20, "keepalives after the login") {
        await session.driver.waitForStats { $0.keepalivesFired >= fired + 4 }
      }
      let end = await session.driver.endReason
      try require(end == nil, "ended after the login: \(String(describing: end))")
      let (output, _) = try await Self.run(session, "echo alive")
      try require(output.stdout == Array("alive\n".utf8), "\(output)")
      await session.close()
      return "ok: no keepalive in 3.5 s before the login, \(after.keepalivesFired - fired) answered after"
    }
  }
}
#endif
