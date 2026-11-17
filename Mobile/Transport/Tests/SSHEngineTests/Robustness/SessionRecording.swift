import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

// Whole sessions of the scripted server, recorded as what the server sealed (payloads, the version line, each new
// set of server-to-client keys), so `SessionReplayTests` can seal them again with corruption applied before or after
// sealing and feed them to a fresh `ClientCore` with the same seed. The client is deterministic (`SeededRandom` makes
// its KEXINIT cookie and ephemeral keys), so the unmodified replay reaches the same keys and the same events as the
// recording, and every server byte after the first exchange stays decryptable when only its plaintext was changed.

/// What the client does in a session apart from answering events: placed between server deliveries.
enum Interjection: Equatable {
  case fire(CoreTimer)
  case write(channel: Int, bytes: [UInt8])
  case finishInput(channel: Int)
  case resize(channel: Int, TerminalSize)
  case closeChannel(Int)
  /// The client closes the connection (`closed(.byClient)`).
  case end
}

/// A login the pilot tries, in order: the next once the previous was refused.
enum LoginPlan {
  case password(String)
  case publicKey(direct: Bool)
  /// The answers per round (one per prompt; missing ones are filled in).
  case keyboardInteractive([[String]])
}

/// A channel the pilot opens once logged in, in order.
enum ChannelPlan {
  /// Writes `input` once open (as the window allows), then EOF if `finish`.
  case exec(String, input: [UInt8], finish: Bool)
  case shell(term: String, size: TerminalSize, input: [UInt8])
}

/// After the reactive part settled: what the client or the server does next, each followed by a settle.
enum ScenarioStep {
  case client(Interjection)
  case serverRekey
  case serverSends([UInt8])
}

/// One session: the server's transport configuration and script, and what the client does.
struct Scenario {
  var name: String
  var configuration = ScriptedServer.Configuration()
  var identity: ServerHostKey = .ed25519(seed: 0x51)
  var keepalive: Duration? = .seconds(15)
  var logins: [LoginPlan]
  var channels: [ChannelPlan] = []
  var steps: [ScenarioStep] = [.client(.end)]
  var script: (ServerScript) -> Void = { _ in }

  var options: ConnectOptions {
    ConnectOptions(host: "server.invalid", port: 22, handshakeTimeout: .seconds(10), keepaliveInterval: keepalive,
                   directAnswer: .seconds(10))
  }
}

/// One step of a recorded session, in order.
enum Beat {
  /// Something the server sealed (or wrote raw), in the order it wrote it.
  case record(ScriptedServer.SealRecord)
  /// Everything recorded since the previous delivery reaches the client in one read.
  case deliver
  case client(Interjection)
}

struct RecordedSession {
  let scenario: Scenario
  let seed: UInt64
  let beats: [Beat]
  /// The host key the client was asked to trust, and the exchange hash that key signed.
  let hostKey: HostKey
  let sessionID: [UInt8]
  /// The client's events in the recording (the baseline a replay is compared with).
  let events: [ClientEvent]
  /// The payloads the server sent (for "a message from another phase").
  var payloads: [[UInt8]] {
    beats.compactMap { if case .record(.payload(let payload)) = $0 { payload } else { nil } }
  }
}

/// The fixed user secrets of every scenario: none may appear in an error's text.
enum RobustSecrets {
  static let password = "fictional-pass-8c41"
  static let kbdAnswer = "fictional-code-77e2"
  static let userKey: Curve25519.Signing.PrivateKey = {
    // swiftlint:disable:next force_try
    try! Curve25519.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: 0x5C, count: 32))
  }()
}

/// The client's side: answers the core's events as a driver and the app would, the same way in the recording and in
/// every replay, and checks what it sees. Never traps on odd orders of events: a hostile stream produces them.
final class Pilot {
  let core: ClientCore
  let scenario: Scenario
  /// Replays: the recorded key and exchange hash; nil while recording (trust what comes, and remember it).
  let expected: (key: HostKey, sessionID: [UInt8])?
  /// Grant the window back as output arrives (else never: the server must stop at the window).
  let consumes: Bool
  /// Answer the host key question only when `answerDeferredTrust` is called (a user deciding while bytes arrive).
  var defersTrust = false
  private var trustWaiting = false

  private(set) var events: [ClientEvent] = []
  private(set) var trustedKey: HostKey?
  private(set) var trustedSessionID: [UInt8]?
  private(set) var trustAsked = 0
  private(set) var trusted = false
  /// Violations of the engine's contract the pilot saw (empty for a pass).
  private(set) var violations: [String] = []
  /// Errors thrown by the core's requests made in answer to its own events (not after its end).
  private(set) var requestErrors: [SSHError] = []
  /// Every error the core reported (ends, failed logins and opens, lost channels).
  private(set) var reportedErrors: [SSHError] = []
  /// The most events one input produced, and the total.
  private(set) var mostEventsPerInput = 0
  private(set) var totalEvents = 0

  private var loginIndex = 0
  private var loginsStarted = 0
  private var loginsFinished = 0
  private var kbdRound = 0
  private var channelIDs: [ChannelID?]
  private var pendingInput: [Int: ArraySlice<UInt8>] = [:]
  private var finishAfterInput: Set<Int> = []
  private var liveChannels: Set<UInt32> = []
  private var endedChannels: Set<UInt32> = []
  private var eofChannels: Set<UInt32> = []
  private var unconsumed: [UInt32: Int] = [:]
  private var ended = false
  /// Channels the app closed itself (their `.closed` is the app's, not the server's).
  private(set) var closedByApp: Set<UInt32> = []

  init(scenario: Scenario, seed: UInt64, expected: (key: HostKey, sessionID: [UInt8])?, consumes: Bool = true) throws {
    core = try ClientCore(options: scenario.options, verifier: SSHSignatureVerifier(), random: SeededRandom(seed: seed))
    self.scenario = scenario
    self.expected = expected
    self.consumes = consumes
    channelIDs = Array(repeating: nil, count: scenario.channels.count)
  }

  var hasEnded: Bool { ended }

  /// Answers a deferred host key question; true when one was waiting.
  @discardableResult
  func answerDeferredTrust() -> Bool {
    guard trustWaiting else { return false }
    trustWaiting = false
    core.answerHostKey(trusted: trusted)
    return true
  }

  func violation(_ text: String) { violations.append(text) }

  /// Drains the core's events, answering each; `budget` bounds the events one input may produce.
  func drain(budget: Int) {
    var count = 0
    while let event = core.poll() {
      count += 1
      totalEvents += 1
      if count > budget {
        violation("more than \(budget) events from one input")
        return
      }
      if ended { violation("an event after the end: \(event)") }
      events.append(event)
      react(event)
    }
    mostEventsPerInput = max(mostEventsPerInput, count)
  }

  /// Interjections between deliveries (a replay runs them even after the end: requests must then throw, not trap).
  func interject(_ interjection: Interjection) {
    switch interjection {
    case .fire(let timer):
      core.timerFired(timer)
    case .write(let index, let bytes):
      guard let id = channel(index) else { return }
      pendingInput[index, default: []] += bytes
      flushInput(index, id)
    case .finishInput(let index):
      guard let id = channel(index) else { return }
      finishAfterInput.insert(index)
      flushInput(index, id)
    case .resize(let index, let size):
      guard let id = channel(index) else { return }
      request { () throws(SSHError) in try core.resize(id, to: size) }
    case .closeChannel(let index):
      guard let id = channel(index) else { return }
      closedByApp.insert(id.rawValue)
      core.closeChannel(id)
    case .end:
      core.end(.closed(.byClient))
    }
  }

  /// The channel the app holds (as the facade: only once `.opened`, until it ended).
  private func channel(_ index: Int) -> ChannelID? {
    guard index < channelIDs.count, let id = channelIDs[index], liveChannels.contains(id.rawValue),
      !endedChannels.contains(id.rawValue)
    else { return nil }
    return id
  }

  /// A request the pilot makes in answer to an event: after the end it must throw, before it must not throw a usage
  /// error the pilot's own order cannot explain (those are recorded for the test to look at).
  private func request(_ body: () throws(SSHError) -> Void) {
    do { try body() } catch {
      if !ended && !core.isEnded { requestErrors.append(error) }
    }
  }

  private func react(_ event: ClientEvent) {
    switch event {
    case .hostKeyNeedsTrust(let key):
      trustAsked += 1
      if trustAsked > 1 { violation("the host key question came twice") }
      if let expected {
        let sameKey = key == expected.key
        let sameHash = core.sessionID == expected.sessionID
        if !sameKey || !sameHash {
          violation("a host key reported for trust that is not the recorded exchange (key \(sameKey), hash \(sameHash))")
        }
        trusted = sameKey && sameHash
      } else {
        trusted = true
      }
      if trusted {
        trustedKey = key
        trustedSessionID = core.sessionID
      }
      if defersTrust {
        trustWaiting = true
      } else {
        core.answerHostKey(trusted: trusted)
      }
    case .established:
      if !trusted { violation("established without a trusted host key") }
      startNextLogin()
    case .authFinished(let result):
      loginsFinished += 1
      if loginsFinished > loginsStarted { violation("a login finished that was not started") }
      switch result {
      case .success(.success):
        if !trusted { violation("a login reported as succeeded without a trusted host key") }
        openPlannedChannels()
      case .success(.refused), .success(.passwordChangeRequested):
        loginIndex += 1
        startNextLogin()
      case .failure(let error):
        reportedErrors.append(error)
      }
    case .sign(let question, let data, let algorithm):
      guard algorithm == .ed25519, let signature = try? RobustSecrets.userKey.signature(for: data) else {
        core.signingFailed(question, error: .cancelled)
        return
      }
      core.signed(question, signature: Raw.string("ssh-ed25519") + Raw.string(Array(signature)))
    case .prompt(let question, let challenge):
      var answers: [String] = []
      if case .keyboardInteractive(let rounds) = currentLogin, kbdRound < rounds.count { answers = rounds[kbdRound] }
      kbdRound += 1
      while answers.count < challenge.prompts.count { answers.append(RobustSecrets.kbdAnswer) }
      core.answered(question, with: answers.prefix(challenge.prompts.count).map { SecretBytes(utf8: $0) })
    case .opened(let id):
      if liveChannels.contains(id.rawValue) || endedChannels.contains(id.rawValue) { violation("\(id) opened twice") }
      liveChannels.insert(id.rawValue)
      if let index = channelIDs.firstIndex(of: id) { flushInput(index, id) }
    case .openFailed(let id, let error):
      reportedErrors.append(error)
      endChannel(id)
    case .output(let id, let output):
      if !liveChannels.contains(id.rawValue) { violation("output on \(id), which is not open") }
      if eofChannels.contains(id.rawValue) { violation("output on \(id) after its EOF") }
      let count: Int
      switch output {
      case .stdout(let bytes), .stderr(let bytes): count = bytes.count
      }
      if consumes {
        core.consumed(count, on: id)
      } else {
        unconsumed[id.rawValue, default: 0] += count
        if let held = unconsumed[id.rawValue], held > Int(Limits.channelWindow) {
          violation("\(id) delivered \(held) bytes the app did not read, past the window")
        }
      }
    case .eof(let id):
      if !liveChannels.contains(id.rawValue) { violation("EOF on \(id), which is not open") }
      eofChannels.insert(id.rawValue)
    case .closed(let id, _, let lost):
      if !liveChannels.contains(id.rawValue) { violation("\(id) closed without being open") }
      if let lost { reportedErrors.append(lost) }
      endChannel(id)
    case .writable(let id):
      if let index = channelIDs.firstIndex(of: id) { flushInput(index, id) }
    case .rekeyed:
      if !trusted { violation("a re-exchange without a trusted host key") }
    case .timer:
      break
    case .ended(let error):
      if ended { violation("a second end") }
      ended = true
      reportedErrors.append(error)
      if loginsFinished != loginsStarted { violation("ended with a login unfinished") }
      let open = liveChannels.subtracting(endedChannels)
      if !open.isEmpty { violation("ended with channels open: \(open.sorted())") }
      let opening = channelIDs.compactMap { $0 }.filter { !endedChannels.contains($0.rawValue) }
      if !opening.isEmpty { violation("ended with channels not answered: \(opening)") }
    }
  }

  private func endChannel(_ id: ChannelID) {
    if endedChannels.contains(id.rawValue) { violation("\(id) ended twice") }
    endedChannels.insert(id.rawValue)
    pendingInput[channelIDs.firstIndex(of: id) ?? -1] = nil
  }

  private var currentLogin: LoginPlan? {
    loginIndex < scenario.logins.count ? scenario.logins[loginIndex] : nil
  }

  private func startNextLogin() {
    guard let login = currentLogin, !core.isAuthenticated else { return }
    kbdRound = 0
    let credential: Credential
    switch login {
    case .password(let text):
      credential = .password(SecretBytes(utf8: text))
    case .publicKey(let direct):
      let blob = PublicKeyBlob.ed25519(Array(RobustSecrets.userKey.publicKey.rawRepresentation)).encoded
      guard let key = try? ExternalSignerKey(publicKeyBlob: blob, sign: { (_: [UInt8]) async throws(SSHError) -> [UInt8] in
        throw .cancelled
      }) else { return violation("the user key") }
      credential = .publicKey(key, direct: direct)
    case .keyboardInteractive:
      credential = .keyboardInteractive { _ in nil }
    }
    do {
      try core.authenticate(user: "phone", credential: credential)
      loginsStarted += 1
    } catch {
      if !core.isEnded { requestErrors.append(error) }
    }
  }

  private func openPlannedChannels() {
    for (index, plan) in scenario.channels.enumerated() where channelIDs[index] == nil {
      do throws(SSHError) {
        switch plan {
        case .exec(let command, let input, let finish):
          channelIDs[index] = try core.openExec(command)
          pendingInput[index] = input[...]
          if finish { finishAfterInput.insert(index) }
        case .shell(let term, let size, let input):
          channelIDs[index] = try core.openShell(term: term, size: size)
          pendingInput[index] = input[...]
        }
      } catch {
        if !core.isEnded { requestErrors.append(error) }
      }
    }
  }

  private func flushInput(_ index: Int, _ id: ChannelID) {
    guard liveChannels.contains(id.rawValue), !endedChannels.contains(id.rawValue) else { return }
    if let pending = pendingInput[index], !pending.isEmpty {
      do throws(SSHError) {
        let taken = try core.write(pending, to: id)
        if taken < 0 || taken > pending.count { violation("write took \(taken) of \(pending.count)") }
        pendingInput[index] = pending.dropFirst(max(0, taken))
      } catch {
        if !core.isEnded { requestErrors.append(error) }
      }
    }
    if pendingInput[index]?.isEmpty ?? true, finishAfterInput.remove(index) != nil {
      core.finishInput(id)
    }
  }
}

extension ClientCore {
  var isEnded: Bool { endedWith != nil }
}

// MARK: - Recording

enum SessionRecorder {
  /// Runs `scenario` against the scripted server and records it. Fails the test when the session does not reach what
  /// the scenario expects (each scenario is a well-formed session).
  static func record(_ scenario: Scenario, seed: UInt64) throws -> RecordedSession {
    let pilot = try Pilot(scenario: scenario, seed: seed, expected: nil)
    let server = ScriptedServer(configuration: scenario.configuration, identity: scenario.identity, seed: seed ^ 0xA5A5)
    let script = ServerScript()
    scenario.script(script)
    var beats: [Beat] = []
    server.sealLog = { beats.append(.record($0)) }
    let core = pilot.core

    func settle() {
      for _ in 0..<10_000 {
        pilot.drain(budget: 100_000)
        var moved = false
        while true {
          let fromClient = core.takeOutbound()
          pilot.drain(budget: 100_000)
          guard !fromClient.isEmpty else { break }
          moved = true
          let before = server.received.count
          do { try server.receive(fromClient) } catch {
            pilot.violation("the scripted server failed: \(error)")
            return
          }
          for payload in server.received[before...] {
            for reply in script.respond(to: payload) { server.sendUpper(reply) }
          }
        }
        let fromServer = server.takeOutbound()
        if !fromServer.isEmpty {
          moved = true
          beats.append(.deliver)
          core.receive(fromServer)
          pilot.drain(budget: 100_000)
        }
        if !moved { return }
      }
      pilot.violation("the recording did not settle")
    }

    core.start()
    server.start()
    settle()
    for step in scenario.steps {
      switch step {
      case .client(let interjection):
        beats.append(.client(interjection))
        pilot.interject(interjection)
      case .serverRekey:
        server.startRekey()
      case .serverSends(let payload):
        server.sendUpper(payload)
      }
      settle()
    }
    if !pilot.hasEnded {
      // The server's EOF: the replay ends the stream after the last delivery too.
      core.receiveEnd()
      pilot.drain(budget: 100_000)
    }
    guard pilot.violations.isEmpty, pilot.requestErrors.isEmpty, let key = pilot.trustedKey,
      let sessionID = pilot.trustedSessionID
    else {
      throw RecordingFailure(description: "\(scenario.name): \(pilot.violations) \(pilot.requestErrors)")
    }
    return RecordedSession(scenario: scenario, seed: seed, beats: beats, hostKey: key, sessionID: sessionID,
                           events: pilot.events)
  }

  struct RecordingFailure: Error, CustomStringConvertible {
    let description: String
  }
}

// MARK: - The sessions

enum RobustScenarios {
  static let ctrMACs = MACAlgorithm.allCases.map(\.rawValue)

  /// Each key exchange method, each cipher family (and each MAC with AES-CTR), each login method, exec with output,
  /// a shell, re-exchanges both ways and keepalives, strict and not.
  static var all: [Scenario] {
    var scenarios: [Scenario] = []

    // ML-KEM hybrid, AES-256-GCM, a password, an exec with stdout, stderr and an exit status.
    var mlkem = Scenario(name: "mlkem768x25519 aes256-gcm password exec", logins: [.password(RobustSecrets.password)])
    mlkem.configuration.keyExchange = ["mlkem768x25519-sha256"]
    mlkem.configuration.ciphers = ["aes256-gcm@openssh.com"]
    mlkem.channels = [.exec("report", input: [], finish: true)]
    mlkem.script = { script in
      script.commands["report"] = [.stdout(Array("out line\n".utf8)), .stderr(Array("err line\n".utf8)),
                                   .stdout([UInt8](repeating: 0x41, count: 3000)), .exitStatus(3), .eof, .close]
    }
    scenarios.append(mlkem)

    // curve25519, AES-128-GCM, a queried public key, a shell: echo, a resize, then the client closes it.
    var shell = Scenario(name: "curve25519 aes128-gcm publickey shell", logins: [.publicKey(direct: false)])
    shell.configuration.keyExchange = ["curve25519-sha256"]
    shell.configuration.ciphers = ["aes128-gcm@openssh.com"]
    shell.channels = [.shell(term: "xterm-256color", size: TerminalSize(columns: 80, rows: 24), input: Array("ls\r".utf8))]
    shell.steps = [.client(.resize(channel: 0, TerminalSize(columns: 120, rows: 40))),
                   .client(.write(channel: 0, bytes: Array("echo two\r".utf8))), .client(.closeChannel(0)), .client(.end)]
    scenarios.append(shell)

    // curve25519@libssh, ChaCha20-Poly1305, a direct public key, an echoing exec across a client re-exchange.
    var chacha = Scenario(name: "curve25519@libssh chacha20 direct-publickey exec client-rekey",
                          logins: [.publicKey(direct: true)])
    chacha.configuration.keyExchange = ["curve25519-sha256@libssh.org"]
    chacha.configuration.ciphers = ["chacha20-poly1305@openssh.com"]
    chacha.channels = [.exec("cat", input: Array("first".utf8), finish: false)]
    chacha.steps = [.client(.fire(.rekey)), .client(.write(channel: 0, bytes: Array(repeating: 0x62, count: 5000))),
                    .client(.finishInput(channel: 0)), .client(.end)]
    scenarios.append(chacha)

    // nistp256, AES-256-CTR with each MAC in turn (one scenario per MAC), keyboard-interactive over two rounds,
    // keepalives answered three ways.
    for (index, mac) in ctrMACs.enumerated() {
      let kex = ["ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521", "curve25519-sha256"][index % 4]
      let cipher = ["aes256-ctr", "aes192-ctr", "aes128-ctr", "aes256-ctr"][index % 4]
      var ctr = Scenario(name: "\(kex) \(cipher) \(mac)", logins: [])
      ctr.configuration.keyExchange = [kex]
      ctr.configuration.ciphers = [cipher]
      ctr.configuration.macs = [mac]
      ctr.configuration.keepaliveAnswer = [.success, .failure, .unimplemented, .success][index % 4]
      switch index % 4 {
      case 0:
        // Keyboard-interactive: two rounds, an empty one, then success.
        ctr.logins = [.keyboardInteractive([["fictional-a", RobustSecrets.kbdAnswer], [RobustSecrets.kbdAnswer]])]
        ctr.script = { script in
          var rounds: [[[UInt8]]] = [
            [ServerAuth.infoRequest(name: Array("second".utf8), prompts: [(Array("Token: ".utf8), true)])],
            [ServerAuth.infoRequest(prompts: [])], [ServerAuth.success],
          ]
          script.login = { request in
            request.method == "keyboard-interactive"
              ? [ServerAuth.infoRequest(instruction: Array("two".utf8),
                                        prompts: [(Array("Password: ".utf8), false), (Array("Code: ".utf8), true)])]
              : [ServerAuth.failure()]
          }
          script.infoResponse = { _ in rounds.isEmpty ? [ServerAuth.failure()] : rounds.removeFirst() }
          script.commands["status"] = [.stdout(Array("ok".utf8)), .exitStatus(0), .eof, .close]
        }
        ctr.channels = [.exec("status", input: [], finish: true)]
      case 1:
        // A banner, a refused password, then a queried public key; an exec killed by a signal.
        ctr.logins = [.password(RobustSecrets.password), .publicKey(direct: false)]
        ctr.script = { script in
          script.login = { request in
            switch request.method {
            case "password": [ServerAuth.banner(Array("Fictional banner\r\n".utf8)), ServerAuth.failure("publickey")]
            default: ServerScript.acceptEverything(request)
            }
          }
          script.commands["crash"] = [.stdout(Array("partial".utf8)), .exitSignal("SEGV"), .close]
        }
        ctr.channels = [.exec("crash", input: [], finish: true)]
      case 2:
        // A password change request, then a password; two execs at once.
        ctr.logins = [.password("fictional-old"), .password(RobustSecrets.password)]
        ctr.script = { script in
          var first = true
          script.login = { request in
            guard request.method == "password" else { return [ServerAuth.failure()] }
            defer { first = false }
            return first ? [ServerAuth.passwordChange(Array("expired".utf8))] : [ServerAuth.success]
          }
          script.commands["one"] = [.stdout(Array("1".utf8)), .exitStatus(0), .eof, .close]
          script.commands["two"] = [.stderr(Array("2".utf8)), .exitStatus(1), .eof, .close]
        }
        ctr.channels = [.exec("one", input: [], finish: true), .exec("two", input: [], finish: true)]
      default:
        // An echoing exec across a server re-exchange.
        ctr.logins = [.password(RobustSecrets.password)]
        ctr.channels = [.exec("cat", input: Array("abc".utf8), finish: false)]
        ctr.steps = [.serverRekey, .client(.write(channel: 0, bytes: Array("after".utf8))), .client(.finishInput(channel: 0))]
      }
      ctr.steps = [.client(.fire(.keepalive)), .client(.fire(.keepalive))] + ctr.steps
      scenarios.append(ctr)
    }

    // Not strict, an ECDSA host key, IGNORE and DEBUG before the exchange, EXT_INFO with several values, a server
    // re-exchange while an exec streams, a server global request and channel open refused, then the server's
    // DISCONNECT.
    var loose = Scenario(name: "not-strict ecdsa-hostkey nistp521 aes256-gcm", identity: .ecdsaP256(seed: 0x52),
                         logins: [.password(RobustSecrets.password)])
    loose.configuration.strict = false
    loose.configuration.keyExchange = ["ecdh-sha2-nistp521"]
    loose.configuration.ciphers = ["aes256-gcm@openssh.com"]
    loose.configuration.linesBeforeVersion = ["fictional pre-version line"]
    loose.configuration.beforeKexInit = [[2] + Raw.string("ignored"), [4, 1] + Raw.string("debug text") + Raw.string("")]
    loose.configuration.extensions = [("server-sig-algs", Array("ssh-ed25519,rsa-sha2-512".utf8)),
                                      ("no-flow-control", Array("p".utf8)), ("ping@openssh.com", Array("0".utf8))]
    loose.channels = [.exec("cat", input: Array(repeating: 0x63, count: 2000), finish: false)]
    loose.steps = [
      .serverSends([80] + Raw.string("fictional@example.invalid") + [1]),
      .serverSends([90] + Raw.string("x11") + Raw.u32(7) + Raw.u32(1024) + Raw.u32(1024) + Raw.string("127.0.0.1") + Raw.u32(1)),
      .serverRekey,
      .client(.write(channel: 0, bytes: Array(repeating: 0x64, count: 2000))),
      .client(.fire(.keepalive)),
      .serverSends([1] + Raw.u32(11) + Raw.string("fictional goodbye") + Raw.string("")),
    ]
    scenarios.append(loose)

    // ChaCha20-Poly1305 with nistp384: keyboard-interactive, a shell, a server re-exchange during output, keepalive.
    var mix = Scenario(name: "nistp384 chacha20 kbd-interactive shell server-rekey", logins: [.keyboardInteractive([])])
    mix.configuration.keyExchange = ["ecdh-sha2-nistp384"]
    mix.configuration.ciphers = ["chacha20-poly1305@openssh.com"]
    mix.configuration.keepaliveAnswer = .success
    mix.channels = [.shell(term: "vt100", size: TerminalSize(columns: 40, rows: 10), input: Array("pwd\r".utf8))]
    mix.steps = [.serverRekey, .client(.write(channel: 0, bytes: Array("whoami\r".utf8))), .client(.fire(.keepalive)),
                 .client(.fire(.rekey)), .client(.resize(channel: 0, TerminalSize(columns: 41, rows: 11))), .client(.end)]
    scenarios.append(mix)

    return scenarios
  }
}
