import CryptoKit
import Foundation
@testable import SSHEngine

/// An in-memory SSH server for the transport's tests: the server side of every supported key exchange method, an
/// Ed25519 (or ECDSA P-256) host key signed with CryptoKit, every cipher and MAC. It reuses the engine's packet
/// protection, framer, key derivation and exchange hash for the server role (the live sshd tests are the independent
/// check), and answers on its own: KEXINIT (re-exchanges included), the method message, NEWKEYS, EXT_INFO after the
/// first, SERVICE_REQUEST, keepalives. Hooks let a test misbehave on purpose: raw bytes, payloads out of phase, a
/// mutated reply, a corrupted packet, another host key at a re-exchange.
///
/// With `Configuration.session` it is a whole server: `ServerSession` takes the login and channel messages
/// (SERVICE_REQUEST included), whose answers wait while a key exchange the server is part of runs (RFC 4253 §7.1), and
/// the server may start re-exchanges itself after `rekeyAfterBytes`. Without it only the transport answers and
/// upper-layer messages are recorded and dropped, as the transport tests expect. `log` records both directions for
/// tests on other threads (`LoopbackServer`); `holdAt` holds the server's output back from the first message with one
/// of those numbers until `release`, so a test can see what the client sends before it hears that answer.
final class ScriptedServer {
  struct Configuration {
    var version = "SSH-2.0-ScriptedServer_1.0"
    var linesBeforeVersion: [String] = []
    var keyExchange: [String] = KeyExchangeAlgorithm.allCases.map(\.rawValue)
    /// nil: the identity's algorithm.
    var hostKeyAlgorithms: [String]?
    var ciphers: [String] = CipherAlgorithm.allCases.map(\.rawValue)
    var macs: [String] = MACAlgorithm.allCases.map(\.rawValue)
    var compression = ["none"]
    /// Offer `kex-strict-s-v00@openssh.com` (in the first KEXINIT).
    var strict = true
    /// Offer `ext-info-s` and send EXT_INFO after the first NEWKEYS when the client asked for it.
    var extInfo = true
    var extensions: [(String, [UInt8])] = [("server-sig-algs", Array("ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256".utf8))]
    /// Payloads around SERVICE_ACCEPT, for the hostile direct-login orders of `Core/tests/hostile.rs`.
    var beforeServiceAccept: [[UInt8]] = []
    var afterServiceAccept: [[UInt8]] = []
    /// A malformed or unsupported host-key blob to put in the method reply. The identity still signs the exchange.
    var hostKeyBlob: [UInt8]?
    var keepaliveAnswer = KeepaliveAnswer.failure
    var firstKexPacketFollows = false
    /// Plaintext payloads sent before the server's first KEXINIT.
    var beforeKexInit: [[UInt8]] = []
    /// Hold the first KEXINIT until `sendFirstKexInit`.
    var holdFirstKexInit = false
    /// The login and channel layers' script (nil: transport only).
    var session: SessionScript?
    /// Hold every byte from the first message with one of these numbers on (that message included) until `release`.
    var holdAt: Set<UInt8> = []
    /// Start a re-exchange each time this many bytes went out since the last one (once the first completed).
    var rekeyAfterBytes: Int?
  }

  enum KeepaliveAnswer { case failure, success, unimplemented, none }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  var configuration: Configuration
  /// The host key of the next exchange (a test changes it before a re-exchange to test the pin).
  var identity: ServerHostKey
  let random: SeededRandom

  /// Every payload the client sent, in order (transport messages included).
  private(set) var received: [[UInt8]] = []
  /// Both directions by number, the layers' facts and the connection's end, readable from any thread.
  let log: Watched<ServerLog>
  private var session: ServerSession?
  private(set) var clientVersion: [UInt8]?
  /// The client's DISCONNECT reason, if one came.
  private(set) var disconnectReason: UInt32?
  /// Completed exchanges (the first included).
  private(set) var exchanges = 0
  private(set) var negotiatedCipherClientToServer: String?

  /// Rewrites the method reply before it is sent.
  var replyMutator: (([UInt8]) -> [UInt8])?
  /// Rewrites the next sealed packet's wire bytes, once.
  var corruptNextPacket: ((inout [UInt8]) -> Void)?
  /// Sign this instead of H (an invalid signature).
  var signWrongData = false
  /// Hears everything the server writes as the replay tests re-create it: raw bytes (the lines before and the version
  /// line), each payload before it is sealed, and each new sealer as it is installed (after NEWKEYS), with its keys.
  var sealLog: ((SealRecord) -> Void)?

  enum SealRecord {
    case raw([UInt8])
    case payload([UInt8])
    /// The server-to-client keys from here on; `resetSequence` under strict key exchange.
    case install(cipher: CipherAlgorithm, mac: MACAlgorithm?, keys: DirectionKeys, resetSequence: Bool)
  }

  private var inbound = InboundFramer()
  private var outbound = OutboundFramer()
  private var output: [UInt8] = []

  private var strictActive = false
  private var clientSentExtInfoSignal = false
  private var ourKexInit: [UInt8]?
  private var theirKexInit: [UInt8]?
  private var negotiated: (kex: String, c2s: (String, String?), s2c: (String, String?))?
  private var pendingOpener: (any PacketOpener)?
  private var sessionID: [UInt8]?
  private var started = false
  /// Our KEXINIT went and our NEWKEYS not yet: upper-layer messages wait in `deferred`.
  private var exchanging = false
  private var deferred: [[UInt8]] = []
  private var holding = false
  private var released = false
  private var heldOutput: [UInt8] = []
  private var bytesSinceExchange = 0

  init(configuration: Configuration = Configuration(), identity: ServerHostKey = .ed25519(seed: 0x51), seed: UInt64 = 0x5E4E,
       log: Watched<ServerLog> = Watched(ServerLog())) {
    self.configuration = configuration
    self.identity = identity
    random = SeededRandom(seed: seed)
    self.log = log
    session = configuration.session.map { ServerSession(script: $0, log: log) }
  }

  /// The first exchange's H, once it ran.
  var sessionIdentifier: [UInt8]? { sessionID }

  var serverVersionLine: [UInt8] { Array(configuration.version.utf8) }

  /// Queues the lines before the version, the version line, and the first KEXINIT (unless held).
  func start() {
    guard !started else { return }
    started = true
    for line in configuration.linesBeforeVersion { sendRaw(Array((line + "\r\n").utf8)) }
    sendRaw(serverVersionLine + [0x0D, 0x0A])
    for payload in configuration.beforeKexInit { send(payload) }
    if !configuration.holdFirstKexInit { sendKexInit(initial: true) }
  }

  func sendFirstKexInit() { sendKexInit(initial: true) }

  /// Starts a re-exchange from the server's side.
  func startRekey() {
    log.update { $0.rekeysStartedByServer += 1 }
    sendKexInit(initial: false)
  }

  /// Lets the held output go, and holds nothing more.
  func release() {
    guard holding else { return }
    holding = false
    released = true
    output += heldOutput
    heldOutput = []
    log.update { $0.holding = false }
  }

  /// Sends an upper-layer message, or keeps it until our NEWKEYS when a key exchange runs. Starts a re-exchange once
  /// `rekeyAfterBytes` went out since the last.
  func sendUpper(_ payload: [UInt8]) {
    guard !exchanging else { return deferred.append(payload) }
    send(payload)
    rekeyIfDue()
  }

  private func rekeyIfDue() {
    guard let limit = configuration.rekeyAfterBytes, bytesSinceExchange >= limit, !exchanging, ourKexInit == nil,
      exchanges > 0, !holding
    else { return }
    bytesSinceExchange = 0
    startRekey()
  }

  func takeOutbound() -> [UInt8] {
    defer { output = [] }
    return output
  }

  /// Seals one payload under the current keys.
  func send(_ payload: [UInt8]) {
    sealLog?(.payload(payload))
    let mark = outbound.output.count
    _ = try? outbound.seal(payload, random: random)
    var wire = Array(outbound.output[mark...])
    outbound.output = []
    if let corrupt = corruptNextPacket {
      corruptNextPacket = nil
      corrupt(&wire)
    }
    bytesSinceExchange += wire.count
    let number = payload.first ?? 0
    if !holding, !released, configuration.holdAt.contains(number) {
      holding = true
      log.update {
        $0.holding = true
        $0.held = true
      }
    }
    let holding = holding
    log.update { $0.traffic.append(.init(inbound: false, number: number, held: holding)) }
    if holding { heldOutput += wire } else { output += wire }
  }

  func sendRaw(_ bytes: [UInt8]) {
    sealLog?(.raw(bytes))
    output += bytes
  }

  /// DISCONNECT (RFC 4253 §11.1) with `reason` and `text`, past any hold: the last thing the server sends.
  func sendDisconnect(_ reason: UInt32, _ text: String) {
    release()
    send([MessageNumber.disconnect.rawValue] + Raw.u32(reason) + Raw.string(text) + Raw.string(""))
  }

  /// Moves the server's sequence numbers (for the wrap tests).
  func setSequenceNumbers(inbound inboundNext: UInt64? = nil, outbound outboundNext: UInt64? = nil) {
    if let inboundNext { inbound.setSequence(inboundNext) }
    if let outboundNext { outbound.setSequence(outboundNext) }
  }

  // MARK: Input

  func receive(_ bytes: [UInt8]) throws {
    inbound.append(bytes)
    if clientVersion == nil {
      let (line, consumed) = try VersionExchange.takeLine(inbound.unconsumed)
      guard case .line(let raw) = line else { return }
      inbound.consume(consumed)
      clientVersion = raw.last == 0x0D ? Array(raw.dropLast()) : raw
    }
    while let packet = try inbound.next() {
      try handle(packet.payload, sequence: packet.sequence)
    }
    rekeyIfDue()
  }

  private func handle(_ payload: [UInt8], sequence: UInt32) throws {
    received.append(payload)
    guard let number = payload.first else { throw Failure(description: "an empty payload") }
    let holding = holding
    log.update { $0.traffic.append(.init(inbound: true, number: number, held: holding)) }
    if let session, ServerSession.handles(number) { return try session.handle(payload, on: self) }
    switch MessageNumber(number) {
    case .kexInit:
      theirKexInit = payload
      if ourKexInit == nil { sendKexInit(initial: sessionID == nil) }
      try negotiate()
    case .kexECDHInit:
      try reply(to: payload)
    case .newKeys:
      guard let pendingOpener else { throw Failure(description: "NEWKEYS out of order") }
      inbound.install(pendingOpener)
      self.pendingOpener = nil
      if strictActive { inbound.resetSequence() }
      exchanges += 1
      log.update { $0.exchanges += 1 }
      ourKexInit = nil
      theirKexInit = nil
    case .serviceRequest:
      var reader = WireReader(payload)
      _ = try reader.readByte()
      let name = try reader.readName()
      var writer = WireWriter(.serviceAccept)
      writer.writeName(name)
      configuration.beforeServiceAccept.forEach(send)
      send(try writer.finish())
      configuration.afterServiceAccept.forEach(send)
    case .globalRequest:
      switch configuration.keepaliveAnswer {
      case .failure: send([MessageNumber.requestFailure.rawValue])
      case .success: send([MessageNumber.requestSuccess.rawValue])
      case .unimplemented: send([MessageNumber.unimplemented.rawValue] + Raw.u32(sequence))
      case .none: break
      }
    case .disconnect:
      var reader = WireReader(payload)
      _ = try reader.readByte()
      disconnectReason = try reader.readUInt32()
      let reason = disconnectReason
      log.update { $0.disconnectReason = reason }
    default:
      break
    }
  }

  // MARK: Key exchange

  private func sendKexInit(initial: Bool) {
    let kex = configuration.keyExchange + (initial && configuration.extInfo ? [KexSignal.extInfoServer] : [])
      + (initial && configuration.strict ? [KexSignal.strictServer] : [])
    let hostKeys = configuration.hostKeyAlgorithms ?? [identity.algorithm.rawValue]
    var writer = WireWriter(.kexInit, capacity: 1024)
    writer.writeBytes((try? random.bytes(16)) ?? [UInt8](repeating: 0, count: 16))
    for list in [kex, hostKeys, configuration.ciphers, configuration.ciphers, configuration.macs, configuration.macs,
                 configuration.compression, configuration.compression, [], []] {
      writer.writeNameList(list)
    }
    writer.writeBoolean(configuration.firstKexPacketFollows)
    writer.writeUInt32(0)
    // swiftlint:disable:next force_try
    let payload = try! writer.finish()
    ourKexInit = payload
    exchanging = true
    send(payload)
    if theirKexInit != nil { try? negotiate() }
  }

  private func negotiate() throws {
    guard let ours = ourKexInit, let theirs = theirKexInit else { return }
    let client = try KexInit(decoding: theirs)
    let server = try KexInit(decoding: ours)
    if sessionID == nil {
      strictActive = configuration.strict && client.keyExchange.contains(KexSignal.strictClient)
      clientSentExtInfoSignal = client.keyExchange.contains(KexSignal.extInfoClient)
    }
    func choose(_ client: [String], _ server: [String]) throws -> String {
      guard let match = client.first(where: { server.contains($0) }) else { throw Failure(description: "no common algorithm") }
      return match
    }
    func direction(_ ciphers: [String], _ macs: [String]) throws -> (String, String?) {
      let cipher = try choose(ciphers, server.cipherClientToServer)
      let aead = CipherAlgorithm(rawValue: cipher)?.isAEAD ?? true
      return (cipher, aead ? nil : try choose(macs, server.macClientToServer))
    }
    let kex = try choose(client.keyExchange.filter { KeyExchangeAlgorithm(rawValue: $0) != nil }, server.keyExchange)
    negotiated = (kex, try direction(client.cipherClientToServer, client.macClientToServer),
                  try direction(client.cipherServerToClient, client.macServerToClient))
    negotiatedCipherClientToServer = negotiated?.c2s.0
  }

  private func reply(to payload: [UInt8]) throws {
    guard let negotiated, let algorithm = KeyExchangeAlgorithm(rawValue: negotiated.kex), let clientVersion,
      let ours = ourKexInit, let theirs = theirKexInit
    else { throw Failure(description: "the method message out of order") }
    let clientValue = try WireReader.decode(payload) { (reader: inout WireReader) throws(WireError) -> [UInt8] in
      _ = try reader.readByte()
      return try reader.readString(limit: 4096)
    }
    let (serverValue, encoded) = try Self.serverSide(algorithm, clientValue: clientValue, random: random)
    let transcript = KeyExchangeTranscript(clientVersion: clientVersion, serverVersion: serverVersionLine,
                                           clientKexInit: theirs, serverKexInit: ours)
    let hostKeyBlob = configuration.hostKeyBlob ?? identity.publicBlob
    let hash = ExchangeHash.compute(algorithm.hash, transcript: transcript, hostKeyBlob: hostKeyBlob,
                                    clientValue: clientValue, serverValue: serverValue, encodedSharedSecret: encoded)
    if sessionID == nil { sessionID = hash }
    let signature = identity.sign(signWrongData ? hash.map { $0 ^ 1 } : hash)
    var writer = WireWriter(.kexECDHReply, capacity: 2048)
    writer.writeString(hostKeyBlob)
    writer.writeString(serverValue)
    writer.writeString(signature)
    var reply = try writer.finish()
    if let replyMutator { reply = replyMutator(reply) }
    send(reply)

    guard let sessionID else { return }
    func cipher(_ name: (String, String?)) throws -> NegotiatedAlgorithms.Direction {
      guard let cipher = CipherAlgorithm(rawValue: name.0) else { throw Failure(description: "cipher") }
      return .init(cipher: cipher, mac: name.1.flatMap(MACAlgorithm.init(rawValue:)))
    }
    let settled = NegotiatedAlgorithms(keyExchange: algorithm, hostKey: identity.algorithm,
                                       clientToServer: try cipher(negotiated.c2s), serverToClient: try cipher(negotiated.s2c),
                                       strictKex: strictActive, serverSendsExtInfo: configuration.extInfo)
    let keys = KeyDerivation.keys(for: settled, sharedSecret: encoded, exchangeHash: hash, sessionID: sessionID,
                                  hash: algorithm.hash)
    pendingOpener = try PacketProtection.opener(cipher: settled.clientToServer.cipher, mac: settled.clientToServer.mac,
                                                keys: keys.clientToServer)
    let sealer = try PacketProtection.sealer(cipher: settled.serverToClient.cipher, mac: settled.serverToClient.mac,
                                             keys: keys.serverToClient)
    let first = exchanges == 0
    send([MessageNumber.newKeys.rawValue])
    outbound.install(sealer)
    if strictActive { outbound.resetSequence() }
    sealLog?(.install(cipher: settled.serverToClient.cipher, mac: settled.serverToClient.mac, keys: keys.serverToClient,
                      resetSequence: strictActive))
    if first && configuration.extInfo && clientSentExtInfoSignal {
      var writer = WireWriter(.extInfo, capacity: 256)
      writer.writeUInt32(UInt32(configuration.extensions.count))
      for (name, value) in configuration.extensions {
        writer.writeName(name)
        writer.writeString(value)
      }
      send(try writer.finish())
    }
    exchanging = false
    bytesSinceExchange = 0
    let waiting = deferred
    deferred = []
    waiting.forEach(send)
  }

  /// The server's value and K (encoded as hashed) for `algorithm`, given the client's value.
  static func serverSide(_ algorithm: KeyExchangeAlgorithm, clientValue: [UInt8], random: any RandomSource) throws
    -> ([UInt8], SecretBytes)
  {
    switch algorithm {
    case .curve25519, .curve25519LibSSH:
      let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try random.bytes(32))
      let shared = try key.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientValue))
      return (Array(key.publicKey.rawRepresentation), shared.withUnsafeBytes { SecretBytes.mpint(magnitude: $0) })
    case .ecdhP256:
      let key = P256.KeyAgreement.PrivateKey()
      let shared = try key.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: clientValue))
      return (Array(key.publicKey.x963Representation), shared.withUnsafeBytes { SecretBytes.mpint(magnitude: $0) })
    case .ecdhP384:
      let key = P384.KeyAgreement.PrivateKey()
      let shared = try key.sharedSecretFromKeyAgreement(with: try P384.KeyAgreement.PublicKey(x963Representation: clientValue))
      return (Array(key.publicKey.x963Representation), shared.withUnsafeBytes { SecretBytes.mpint(magnitude: $0) })
    case .ecdhP521:
      let key = P521.KeyAgreement.PrivateKey()
      let shared = try key.sharedSecretFromKeyAgreement(with: try P521.KeyAgreement.PublicKey(x963Representation: clientValue))
      return (Array(key.publicKey.x963Representation), shared.withUnsafeBytes { SecretBytes.mpint(magnitude: $0) })
    case .mlkem768x25519:
      guard clientValue.count == 1184 + 32 else { throw Failure(description: "C_INIT size") }
      let encapsulation = try MLKEM768.PublicKey(rawRepresentation: clientValue[0..<1184]).encapsulate()
      let curve = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try random.bytes(32))
      let classical = try curve.sharedSecretFromKeyAgreement(
        with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientValue[1184...]))
      var hasher = SHA256()
      encapsulation.sharedSecret.withUnsafeBytes { hasher.update(bufferPointer: $0) }
      classical.withUnsafeBytes { hasher.update(bufferPointer: $0) }
      let encoded = hasher.finalize().withUnsafeBytes { SecretBytes.string($0) }
      return (Array(encapsulation.encapsulated) + Array(curve.publicKey.rawRepresentation), encoded)
    }
  }
}
