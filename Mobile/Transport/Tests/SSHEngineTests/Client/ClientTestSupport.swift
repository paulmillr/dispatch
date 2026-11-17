import CryptoKit
import Foundation
import XCTest
@testable import SSHEngine

// MARK: - A scripted server's upper layers

/// A client's USERAUTH_REQUEST, decoded far enough for a script to answer it.
struct UserauthRequest: Sendable, Equatable {
  var user = ""
  var method = ""
  /// publickey: whether a signature follows, the algorithm and blob named.
  var signed = false
  var algorithm = ""
  var blob: [UInt8] = []

  static func parse(_ payload: [UInt8]) -> UserauthRequest? {
    try? WireReader.decode(payload) { (reader: inout WireReader) throws(WireError) -> UserauthRequest in
      _ = try reader.readByte()
      var request = UserauthRequest()
      request.user = try reader.readText(limit: 1024)
      _ = try reader.readName()
      request.method = try reader.readName()
      if request.method == "publickey" {
        request.signed = try reader.readBoolean()
        request.algorithm = try reader.readName()
        request.blob = try reader.readString(limit: 4096)
      }
      _ = reader.readRemaining()
      return request
    }
  }
}

/// What a scripted command does once its exec request arrived.
enum CommandStep: Sendable {
  case stdout([UInt8])
  case stderr([UInt8])
  case exitStatus(UInt32)
  case exitSignal(String)
  case eof
  case close
  /// Echo the client's data back from now on; at the client's EOF: EOF, exit-status 0, CLOSE.
  case echo
}

/// The server's half of the userauth service and the connection protocol, answering what the client sends: a
/// script's logins and commands. Deterministic and synchronous, shared by the in-memory peer (async, through the
/// driver) and the composed core's harness (synchronous).
final class ServerScript {
  /// Answers a USERAUTH_REQUEST (`[]`: never). Default: a signed request or a password succeeds, a query gets PK_OK,
  /// keyboard-interactive asks one prompt, anything else is refused.
  var login: (UserauthRequest) -> [[UInt8]] = ServerScript.acceptEverything
  /// Answers an INFO_RESPONSE.
  var infoResponse: ([UInt8]) -> [[UInt8]] = { _ in [[52]] }
  /// The steps of each command; an unknown command echoes.
  var commands: [String: [CommandStep]] = [:]
  /// The server's exec answer: nil never answers.
  var execReply: (String) -> Bool? = { _ in true }
  /// Shell requests' answers: nil never answers.
  var ptyReply: Bool? = true
  var shellReply: Bool? = true
  /// The window and maximum packet the server grants each channel.
  var window: UInt32 = 2 * 1024 * 1024
  var maximumPacket: UInt32 = 32 * 1024
  /// Refuse every channel open.
  var refuseOpen = false
  /// Never answer a channel open.
  var holdOpen = false
  /// Grant the client's window back as its data arrives.
  var adjustWindow = true
  /// Answer the client's CLOSE with the server's.
  var answerClose = true

  /// Every payload of the client's upper layers seen, in order.
  private(set) var seen: [[UInt8]] = []
  /// The last window-change size per server channel.
  private(set) var windowChanges: [(columns: UInt32, rows: UInt32)] = []
  /// Data received per client channel number.
  private(set) var input: [UInt32: [UInt8]] = [:]

  private struct ServerChannel {
    var client: UInt32
    var echo = false
  }

  private var channels: [UInt32: ServerChannel] = [:]
  private var nextChannel: UInt32 = 100

  static func acceptEverything(_ request: UserauthRequest) -> [[UInt8]] {
    switch request.method {
    case "publickey":
      request.signed ? [[52]] : [[60] + Raw.string(request.algorithm) + Raw.string(request.blob)]
    case "password": [[52]]
    case "keyboard-interactive":
      [[60] + Raw.string("login") + Raw.string("") + Raw.string("") + Raw.u32(1) + Raw.string("Code: ") + [0]]
    default: [[51] + Raw.string("publickey,password,keyboard-interactive") + [0]]
    }
  }

  /// The server's answer to one client payload (message number 50 and up).
  func respond(to payload: [UInt8]) -> [[UInt8]] {
    guard let number = payload.first, number >= 50 else { return [] }
    seen.append(payload)
    switch number {
    case 50:
      guard let request = UserauthRequest.parse(payload) else { return [] }
      return login(request)
    case 61:
      return infoResponse(payload)
    case 90:
      return open(payload)
    case 94:
      return data(payload)
    case 96:
      return eof(payload)
    case 97:
      return close(payload)
    case 98:
      return request(payload)
    default:
      return []
    }
  }

  private func u32(_ payload: [UInt8], at offset: Int) -> UInt32? {
    guard payload.count >= offset + 4 else { return nil }
    return payload[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
  }

  private func open(_ payload: [UInt8]) -> [[UInt8]] {
    guard let sender = try? WireReader.decode(payload, { (reader: inout WireReader) throws(WireError) -> UInt32 in
      _ = try reader.readByte()
      _ = try reader.readName()
      let sender = try reader.readUInt32()
      _ = reader.readRemaining()
      return sender
    }) else { return [] }
    if holdOpen { return [] }
    if refuseOpen { return [[92] + Raw.u32(sender) + Raw.u32(1) + Raw.string("no channels here") + Raw.string("")] }
    let number = nextChannel
    nextChannel += 1
    channels[number] = ServerChannel(client: sender)
    return [[91] + Raw.u32(sender) + Raw.u32(number) + Raw.u32(window) + Raw.u32(maximumPacket)]
  }

  private func data(_ payload: [UInt8]) -> [[UInt8]] {
    guard let number = u32(payload, at: 1), let channel = channels[number],
      let bytes = try? WireReader.decode(Array(payload.dropFirst(5)), { (reader: inout WireReader) throws(WireError) in
        try reader.readString(limit: 1 << 20)
      })
    else { return [] }
    input[channel.client, default: []] += bytes
    // The server consumed it: the window goes back (unless the script holds it).
    let adjust: [[UInt8]] = adjustWindow && !bytes.isEmpty ? [[93] + Raw.u32(channel.client) + Raw.u32(UInt32(bytes.count))] : []
    return adjust + (channel.echo ? [[94] + Raw.u32(channel.client) + Raw.string(bytes)] : [])
  }

  private func eof(_ payload: [UInt8]) -> [[UInt8]] {
    guard let number = u32(payload, at: 1), let channel = channels[number], channel.echo else { return [] }
    let client = channel.client
    channels[number] = nil
    return [[96] + Raw.u32(client), [98] + Raw.u32(client) + Raw.string("exit-status") + [0] + Raw.u32(0),
            [97] + Raw.u32(client)]
  }

  private func close(_ payload: [UInt8]) -> [[UInt8]] {
    guard answerClose, let number = u32(payload, at: 1), let channel = channels.removeValue(forKey: number) else { return [] }
    return [[97] + Raw.u32(channel.client)]
  }

  private func request(_ payload: [UInt8]) -> [[UInt8]] {
    guard let number = u32(payload, at: 1), var channel = channels[number],
      let (name, rest) = try? WireReader.decode(Array(payload.dropFirst(5)), { (reader: inout WireReader) throws(WireError) in
        let name = try reader.readName()
        _ = try reader.readBoolean()
        return (name, reader.readRemaining())
      })
    else { return [] }
    let client = channel.client
    switch name {
    case "exec":
      let command = (try? WireReader.decode(rest) { (reader: inout WireReader) throws(WireError) in
        try reader.readText(limit: 1 << 16)
      }) ?? ""
      guard let accepted = execReply(command) else { return [] }
      guard accepted else { return [[100] + Raw.u32(client)] }
      var replies: [[UInt8]] = [[99] + Raw.u32(client)]
      for step in commands[command] ?? [.echo] {
        switch step {
        case .stdout(let bytes): replies.append([94] + Raw.u32(client) + Raw.string(bytes))
        case .stderr(let bytes): replies.append([95] + Raw.u32(client) + Raw.u32(1) + Raw.string(bytes))
        case .exitStatus(let status):
          replies.append([98] + Raw.u32(client) + Raw.string("exit-status") + [0] + Raw.u32(status))
        case .exitSignal(let signal):
          replies.append([98] + Raw.u32(client) + Raw.string("exit-signal") + [0] + Raw.string(signal) + [0]
            + Raw.string("killed") + Raw.string(""))
        case .eof: replies.append([96] + Raw.u32(client))
        case .close:
          // The client's CLOSE that answers this one gets no other.
          replies.append([97] + Raw.u32(client))
          channels[number] = nil
          return replies
        case .echo:
          channel.echo = true
          channels[number] = channel
        }
      }
      return replies
    case "pty-req":
      guard let reply = ptyReply else { return [] }
      return [[reply ? 99 : 100] + Raw.u32(client)]
    case "shell":
      guard let reply = shellReply else { return [] }
      if reply {
        channel.echo = true
        channels[number] = channel
      }
      return [[reply ? 99 : 100] + Raw.u32(client)]
    case "window-change":
      if rest.count >= 8 { windowChanges.append((u32(rest, at: 0) ?? 0, u32(rest, at: 4) ?? 0)) }
      return []
    default:
      return []
    }
  }
}

// MARK: - The in-memory peer

/// A scripted SSH server on the far end of a `MemoryByteStream`: `ScriptedServer` for the transport (key exchange,
/// SERVICE_ACCEPT, keepalives) and a `ServerScript` for the layers above, run by one loop that reads, answers and
/// writes, as a TCP peer would. Tests hold its output back (`gate`), go silent, cut the stream or inject payloads.
actor ScriptedPeer {
  let server: ScriptedServer
  let script: ServerScript
  private let stream: MemoryByteStream
  /// Outbound bytes wait while this is false for what the client sent so far.
  private var gate: (@Sendable ([[UInt8]]) -> Bool)?
  /// Reads nothing and sends nothing more (a dead network that keeps the socket).
  private var silent = false
  private var flushing = false
  private var waiters: [(predicate: @Sendable ([[UInt8]]) -> Bool, continuation: CheckedContinuation<[[UInt8]], Never>)] = []
  private var silenceWaiter: CheckedContinuation<Void, Never>?
  private(set) var clientClosed = false
  private(set) var failure: String?

  init(stream: MemoryByteStream, configuration: ScriptedServer.Configuration = .init(), script: sending ServerScript) {
    self.stream = stream
    server = ScriptedServer(configuration: configuration)
    self.script = script
  }

  /// Every payload the client sent, transport messages included.
  var received: [[UInt8]] { server.received }

  var identityBlob: [UInt8] { server.identity.publicBlob }

  /// The data the server got on the client's channel `number`.
  func input(_ number: UInt32) -> [UInt8] { script.input[number] ?? [] }

  var windowChanges: [TerminalSize] { script.windowChanges.map { TerminalSize(columns: $0.columns, rows: $0.rows) } }

  func start() {
    server.start()
    Task { await self.run() }
  }

  /// Sends the version line (and the first KEXINIT unless held), then reads and answers nothing: a server that
  /// stalls in the handshake.
  func startThenStall() async {
    server.start()
    await flush()
    silent = true
    Task { await self.run() }
  }

  /// Returns once the client closed its end (EOF or a reset reached the peer's read).
  func waitUntilClientClosed() async {
    _ = await waitFor { _ in false }
  }

  func setGate(_ gate: (@Sendable ([[UInt8]]) -> Bool)?) async {
    self.gate = gate
    await flush()
  }

  func setSilent(_ silent: Bool) {
    self.silent = silent
    if !silent {
      silenceWaiter?.resume()
      silenceWaiter = nil
    }
  }

  /// Sends one payload under the current keys.
  func send(_ payload: [UInt8]) async {
    server.send(payload)
    await flush()
  }

  /// Sends bytes without packet framing (a hostile packet length, for example).
  func sendRaw(_ bytes: [UInt8]) async {
    server.sendRaw(bytes)
    await flush()
  }

  /// The host key the next exchange presents.
  func setIdentity(_ identity: ServerHostKey) { server.identity = identity }

  func startRekey() async {
    exchangeMark = server.exchanges
    server.startRekey()
    await flush()
  }

  /// While a re-exchange runs (from a KEXINIT either way until the client's NEWKEYS), the script's replies wait:
  /// RFC 4253 §7.1 lets nothing but the exchange through, and the client holds the server to it.
  private var exchangeMark: Int?
  private var heldReplies: [[UInt8]] = []

  func edit(_ body: @Sendable (ServerScript) -> Void) { body(script) }

  /// EOF to the client (the server closed its side).
  func finishWriting() async { await stream.finishWriting() }

  /// Both directions fail from now on (a reset).
  func reset() async { await stream.reset() }

  /// Returns the client's payloads once `predicate` holds for them, or once the client closed.
  func waitFor(_ predicate: @escaping @Sendable ([[UInt8]]) -> Bool) async -> [[UInt8]] {
    if predicate(server.received) || clientClosed { return server.received }
    return await withCheckedContinuation { continuation in waiters.append((predicate, continuation)) }
  }

  private func run() async {
    await flush()
    while true {
      if silent {
        await withCheckedContinuation { continuation in silenceWaiter = continuation }
        continue
      }
      let bytes: [UInt8]
      do {
        bytes = try await stream.read(maximum: 64 * 1024)
      } catch {
        clientClosed = true
        break
      }
      if bytes.isEmpty {
        clientClosed = true
        break
      }
      // Gone silent while this read was in flight: keep the bytes for when it speaks again.
      while silent { await withCheckedContinuation { continuation in silenceWaiter = continuation } }
      let before = server.received.count
      do {
        try server.receive(bytes)
      } catch {
        failure = "\(error)"
        break
      }
      for payload in server.received[before...] {
        if payload.first == MessageNumber.kexInit.rawValue, server.exchanges >= 1, exchangeMark == nil {
          exchangeMark = server.exchanges
        }
        heldReplies += script.respond(to: payload)
      }
      if let mark = exchangeMark, server.exchanges > mark { exchangeMark = nil }
      if exchangeMark == nil {
        for reply in heldReplies { server.send(reply) }
        heldReplies = []
      }
      wake()
      await flush()
    }
    wake()
  }

  private func wake() {
    let received = server.received
    var waiting: [(predicate: @Sendable ([[UInt8]]) -> Bool, continuation: CheckedContinuation<[[UInt8]], Never>)] = []
    for waiter in waiters {
      if waiter.predicate(received) || clientClosed { waiter.continuation.resume(returning: received) } else {
        waiting.append(waiter)
      }
    }
    waiters = waiting
  }

  private func flush() async {
    guard !flushing else { return }
    flushing = true
    defer { flushing = false }
    while !silent, gate.map({ $0(server.received) }) ?? true {
      let bytes = server.takeOutbound()
      guard !bytes.isEmpty else { return }
      do { try await stream.write(bytes) } catch { return }
    }
  }
}

extension Array where Element == [UInt8] {
  /// Payloads with this message number.
  func numbered(_ number: UInt8) -> [[UInt8]] { filter { $0.first == number } }
}

// MARK: - Connecting in memory

/// A client connected in memory to a `ScriptedPeer`: the connector, the peer and the stream it uses.
struct MemoryWorld {
  enum Start { case normally, stallingAfterVersion, not }

  let connector: ClientConnector
  let peer: ScriptedPeer
  let drivers: DriverBox

  static let options = ConnectOptions(host: "server.invalid", port: 22, handshakeTimeout: .seconds(10),
                                      keepaliveInterval: nil, directAnswer: .seconds(10))

  /// `script` answers the upper layers; `configuration` the transport.
  static func make(script: sending ServerScript = ServerScript(), configuration: ScriptedServer.Configuration = .init(),
                   tuning: DriverTuning = DriverTuning(), capacity: Int = 256 * 1024, start: Start = .normally)
    async -> MemoryWorld
  {
    let (client, server) = MemoryByteStream.pair(capacity: capacity)
    let peer = ScriptedPeer(stream: server, configuration: configuration, script: script)
    switch start {
    case .normally: await peer.start()
    case .stallingAfterVersion: await peer.startThenStall()
    case .not: break
    }
    let seed = SeedCounter.shared.next()
    let drivers = DriverBox()
    // A test watching for the driver's release must not have the box hold it.
    var created: (@Sendable (ConnectionDriver) -> Void)?
    if tuning.released == nil { created = { drivers.add($0) } }
    let connector = ClientConnector(streams: MemoryConnector(result: .success(client)),
                                    random: { SeededRandom(seed: seed) }, tuning: tuning, created: created)
    return MemoryWorld(connector: connector, peer: peer, drivers: drivers)
  }

  func connect(_ options: ConnectOptions = MemoryWorld.options, trust: @escaping HostKeyTrust = { _ in true })
    async throws(SSHError) -> any SSHSession
  {
    try await connector.connect(options, trust: trust)
  }

  /// Connected and logged in with a password.
  func loggedIn(_ options: ConnectOptions = MemoryWorld.options) async throws -> any SSHSession {
    let session = try await connect(options)
    let outcome = try await session.authenticate(user: "phone", with: .password(SecretBytes(utf8: "fictional")))
    XCTAssertEqual(outcome, .success)
    return session
  }
}

/// The drivers a connector made, in order; `first()` waits for one.
final class DriverBox: @unchecked Sendable {
  private let made = Locked<[ConnectionDriver]>([])
  private let signal = Signal()

  func add(_ driver: ConnectionDriver) {
    made.update { $0.append(driver) }
    signal.fire()
  }

  func first() async -> ConnectionDriver {
    await signal.wait()
    return made.current[0]
  }
}

final class SeedCounter: @unchecked Sendable {
  static let shared = SeedCounter()
  private let lock = NSLock()
  private var value: UInt64 = 0x5EED

  func next() -> UInt64 { lock.withLock { value &+= 1; return value } }
}

extension SSHSession {
  var driver: ConnectionDriver { (self as! ClientSession).driver }
}

/// Asserts that `body` throws exactly `expected` (an engine error).
func assertThrows<T>(_ expected: SSHError, _ message: @autoclosure () -> String = "", file: StaticString = #filePath,
                     line: UInt = #line, _ body: () async throws -> T) async {
  do {
    let value = try await body()
    XCTFail("expected \(expected), got \(value) \(message())", file: file, line: line)
  } catch let error as SSHError {
    XCTAssertEqual(error, expected, message(), file: file, line: line)
  } catch {
    XCTFail("expected \(expected), got \(error) \(message())", file: file, line: line)
  }
}

// MARK: - Bounded waits

struct TimedOut: Error, CustomStringConvertible {
  let what: String
  var description: String { "timed out: \(what)" }
}

/// Runs `body`, failing with `TimedOut` after `seconds` (the body's task is cancelled then, and left to end on its
/// own: a wait that does not honour cancellation cannot hang the test).
func bounded<T: Sendable>(_ seconds: Double = 20, _ what: String = "the operation",
                          _ body: @escaping @Sendable () async throws -> T) async throws -> T {
  let once = Once<T>()
  return try await withCheckedThrowingContinuation { continuation in
    once.install(continuation)
    let work = Task {
      do { once.resume(.success(try await body())) } catch { once.resume(.failure(error)) }
    }
    let timer = Task {
      try? await Task.sleep(for: .seconds(seconds))
      if !Task.isCancelled, once.resume(.failure(TimedOut(what: what))) { work.cancel() }
    }
    once.onResume { timer.cancel() }
  }
}

private final class Once<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, any Error>?
  private var done = false
  private var after: (@Sendable () -> Void)?

  func install(_ continuation: CheckedContinuation<T, any Error>) { lock.withLock { self.continuation = continuation } }

  func onResume(_ body: @escaping @Sendable () -> Void) {
    let run = lock.withLock { () -> Bool in
      if done { return true }
      after = body
      return false
    }
    if run { body() }
  }

  @discardableResult
  func resume(_ result: Result<T, any Error>) -> Bool {
    let (continuation, after) = lock.withLock { () -> (CheckedContinuation<T, any Error>?, (@Sendable () -> Void)?) in
      guard !done else { return (nil, nil) }
      done = true
      defer { self.continuation = nil; self.after = nil }
      return (self.continuation, self.after)
    }
    guard let continuation else { return false }
    continuation.resume(with: result)
    after?()
    return true
  }
}

/// A value several tasks touch, behind a lock.
final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) { self.value = value }

  var current: Value { lock.withLock { value } }

  @discardableResult
  func update<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

/// A one-shot signal a task waits for (a gate the test opens).
final class Signal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func fire() {
    let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      fired = true
      defer { waiters = [] }
      return waiters
    }
    for waiter in waiting { waiter.resume() }
  }

  var hasFired: Bool { lock.withLock { fired } }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        if fired { return true }
        waiters.append(continuation)
        return false
      }
      if ready { continuation.resume() }
    }
  }
}

/// Suspends until the calling task is cancelled (a callback that never answers by itself).
func untilCancelled() async {
  try? await Task.sleep(for: .seconds(86_400))
}

// MARK: - Keys

/// A CryptoKit Ed25519 key behind `ExternalSignerKey` (a fresh fictional key per call).
func cryptoKitEd25519(_ key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
                      before: (@Sendable () async throws(SSHError) -> Void)? = nil) throws -> ExternalSignerKey {
  let blob = PublicKeyBlob.ed25519(Array(key.publicKey.rawRepresentation)).encoded
  return try ExternalSignerKey(publicKeyBlob: blob) { (data: [UInt8]) async throws(SSHError) -> [UInt8] in
    if let before { try await before() }
    do { return Array(try key.signature(for: data)) } catch { throw .cancelled }
  }
}

func cryptoKitP256(_ key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) throws -> ExternalSignerKey {
  let blob = PublicKeyBlob.ecdsa(.p256, point: Array(key.publicKey.x963Representation)).encoded
  return try ExternalSignerKey(publicKeyBlob: blob) { (data: [UInt8]) async throws(SSHError) -> [UInt8] in
    do { return Array(try key.signature(for: data).rawRepresentation) } catch { throw .cancelled }
  }
}

extension ExternalSignerKey {
  /// The `authorized_keys` line.
  var line: String { authorizedKeysLine }
}

/// Collects an exec's output until its end.
struct Collected: Sendable {
  var stdout: [UInt8] = []
  var stderr: [UInt8] = []

  static func all(_ channel: any ExecChannel) async throws(SSHError) -> Collected {
    var collected = Collected()
    while let chunk = try await channel.read() {
      switch chunk {
      case .stdout(let bytes): collected.stdout += bytes
      case .stderr(let bytes): collected.stderr += bytes
      }
    }
    return collected
  }
}
