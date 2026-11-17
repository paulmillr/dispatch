/// The client's transport (`TransportCore`, RFC 4253): version exchange, framing, the message policy on every packet,
/// KEXINIT and negotiation, the key exchanges (the first with the host key's trust, every later one held to its pin),
/// NEWKEYS, EXT_INFO, keepalive, re-exchanges started by either side, DISCONNECT. Sans-I/O and single-owner: bytes,
/// timer firings and answers in; events and sealed bytes out. Every failure becomes `TransportEvent.ended`, once.
///
/// The driver's side: after every call that may produce something (`start`, `receive`, `receiveEnd`, `send`,
/// `answerHostKey`, `timerFired`, `end`) it drains `poll` until nil and writes `takeOutbound`. `poll` itself may queue
/// bytes without returning an event (a re-exchange that was waiting for the connection phase). Before the first
/// exchange completed, `sessionID` is empty and `hostKey` a placeholder; the layers above never see either.
///
/// Decisions beyond the contract's text:
///
/// - Nothing is decoded while the trust callback decides: the server's NEWKEYS and what follows wait in the buffer
///   until `answerHostKey(trusted: true)`, so no byte under the new keys is read for a key nobody trusted yet.
/// - A re-exchange's KEXINIT offers the same algorithms without `ext-info-c` and the strict signal (both count only
///   in the first; see `KexInit.client`). Strictness is the first exchange's for the connection's life.
/// - Payloads sent while an exchange runs (from our KEXINIT to our NEWKEYS) wait in order, keepalives and refusals of
///   the server's global requests among them, and leave under the new keys. DISCONNECT never waits.
/// - The keepalive timer is rescheduled once per batch of packets (when `poll` has decoded everything buffered and
///   at least one packet came), not once per packet: packets of one read arrive at the same instant, so the timing is
///   the contract's with fewer timer events. More than `Limits.keepaliveCountMax` keepalives without a reply (a server
///   that talks but never answers them) also end the connection as a keepalive timeout.
/// - The inbound buffer is checked when bytes arrive: holding more than `Limits.inboundBufferBytes` from earlier
///   reads (the driver drained `poll`, so that is never one packet's worth) ends the connection. Memory is bounded by
///   that plus one read.
/// - Our own re-exchanges (limits, the timer) wait for the connection phase, the service phase `poll` was last given:
///   OpenSSH's sshd answers a KEXINIT before authentication with UNIMPLEMENTED (its preauth dispatcher has no
///   handler for it), and OpenSSH's client never rekeys before authentication either. A re-exchange the server starts
///   is taken in any phase.
/// - Keepalives start with the connection phase (the first `poll` given `.connection`, after USERAUTH_SUCCESS): no
///   keepalive timer runs before the login. A global request (80) before authentication is an error the server must
///   disconnect for (RFC 4252 §6), and Dropbear does ("Received message 80 before userauth"); the seam's contract,
///   russh and OpenSSH's client start them once logged in too. Before the login a dead link is bounded only by the
///   driver's handshake deadline (up to the first exchange) and, for a direct key, the direct answer's.
/// - The client sends no DISCONNECT after the server's own, after EOF, when the server is not SSH (version errors) or
///   when a sequence number ran out; otherwise every end sends one with `SSHError.disconnectReason`.
public final class ClientTransport: TransportCore {
  /// The software version in the client's identification line.
  public static let softwareVersion = "DispatchSSH_1.0"

  /// The limits on one set of keys before the client starts a re-exchange (`Limits` by default; tests lower them).
  struct RekeyThresholds {
    var bytes: UInt64 = Limits.rekeyBytes
    var packets: UInt64 = Limits.rekeyPackets
    var interval: Duration = Limits.rekeyInterval
  }

  private enum Stage {
    /// Our KEXINIT is out, the server's has not come.
    case awaitingKexInit
    case awaitingReply
    case awaitingNewKeys
  }

  /// One key exchange in progress, from our KEXINIT to the server's NEWKEYS.
  private final class Exchange {
    let initial: Bool
    let clientKexInit: [UInt8]
    var serverKexInit: [UInt8] = []
    var negotiated: NegotiatedAlgorithms?
    var method: (any KeyExchangeMethod)?
    var stage = Stage.awaitingKexInit
    var sealer: (any PacketSealer)?
    var opener: (any PacketOpener)?
    var sentNewKeys = false

    init(initial: Bool, clientKexInit: [UInt8]) {
      self.initial = initial
      self.clientKexInit = clientKexInit
    }
  }

  /// What waits for our NEWKEYS.
  private enum Held {
    case payload([UInt8])
    case secret(SecretBytes)
    case keepalive

    var count: Int {
      switch self {
      case .payload(let bytes): bytes.count
      case .secret(let secret): secret.count
      case .keepalive: ClientTransport.keepaliveRequest.count
      }
    }
  }

  static let keepaliveName = "keepalive@openssh.com"
  static let keepaliveRequest: [UInt8] = {
    var writer = WireWriter(.globalRequest, capacity: 32)
    writer.writeName(keepaliveName)
    writer.writeBoolean(true)
    return (try? writer.finish()) ?? []
  }()

  private let preferences: AlgorithmPolicy.Preferences
  private let keepaliveInterval: Duration?
  private let keepaliveCountMax: Int
  private let verifier: any HostKeySignatureVerifier
  private let random: any RandomSource
  var thresholds = RekeyThresholds()

  private let clientVersion: [UInt8]
  private var serverVersion: [UInt8]?
  private var preVersionLines = 0
  private var started = false

  private var inbound = InboundFramer()
  private var outbound = OutboundFramer()

  private var exchange: Exchange?
  private var established = false
  private var strict = false
  private var serverSendsExtInfo = false
  private var session: [UInt8]?
  private var pin: HostKeyPin?
  private var candidate: HostKey?
  private var awaitingTrust = false

  private var held: [Held] = []
  private var heldBytes = 0

  private var events: [TransportEvent] = []

  private var extensions: ServerExtensions?
  private var extInfoCount = 0
  private var firstPacketAfterNewKeys = false

  private var unanswered = 0
  /// The connection phase began: keepalives run (scheduled once there, then per batch of packets).
  private var keepalivesStarted = false
  /// Sequence numbers of keepalives sent and not answered yet, oldest first.
  private var outstandingKeepalives: [UInt32] = []
  private var packetsSinceKeepaliveScheduled = false

  private var inboundBytes: UInt64 = 0
  private var inboundPackets: UInt64 = 0
  private var outboundBytes: UInt64 = 0
  private var outboundPackets: UInt64 = 0

  private var endReason: SSHError?
  private var streamEnded = false
  /// The service phase `poll` was last given, and whether one of our re-exchanges waits for the connection phase.
  private var service = MessagePolicy.ServicePhase.serviceNotRequested
  private var reexchangeDue = false

  /// `options` supplies the algorithms and keepalive settings (validated; host and port are the driver's).
  public init(options: ConnectOptions, verifier: any HostKeySignatureVerifier, random: any RandomSource) throws(SSHError) {
    try options.validate()
    preferences = options.algorithms
    keepaliveInterval = options.keepaliveInterval
    keepaliveCountMax = options.keepaliveCountMax
    self.verifier = verifier
    self.random = random
    clientVersion = Array(VersionExchange.clientLine(Self.softwareVersion).dropLast(2))
  }

  // MARK: TransportLink

  public var sessionID: [UInt8] { session ?? [] }

  public var hostKey: HostKey { pin?.trusted ?? candidate ?? Self.placeholderKey }

  public var serverExtensions: ServerExtensions? { extensions }

  public var outboundBacklog: Int { outbound.output.count + heldBytes }

  public var isOpen: Bool { endReason == nil }

  public func send(_ payload: [UInt8]) throws(SSHError) {
    guard endReason == nil else { throw .closed(.alreadyEnded) }
    try Self.checkUpperPayload(first: payload.first, count: payload.count)
    try transmit(.payload(payload))
  }

  public func send(secret payload: SecretBytes) throws(SSHError) {
    guard endReason == nil else { throw .closed(.alreadyEnded) }
    let first = payload.withUnsafeBytes { $0.first }
    try Self.checkUpperPayload(first: first, count: payload.count)
    try transmit(.secret(payload))
  }

  public func end(_ error: SSHError) { finish(error) }

  // MARK: TransportCore

  public func start() {
    guard !started, endReason == nil else { return }
    started = true
    outbound.output.append(contentsOf: clientVersion + [0x0D, 0x0A])
    do { try sendKexInit(initial: true) } catch { finish(error) }
  }

  public func receive(_ bytes: [UInt8]) {
    guard endReason == nil, !streamEnded else { return }
    guard inbound.buffered <= Limits.inboundBufferBytes else {
      finish(.protocolViolation(.packet(.bufferOverflow)))
      return
    }
    inbound.append(bytes)
  }

  public func receiveEnd() { streamEnded = true }

  public func poll(service: MessagePolicy.ServicePhase) -> TransportEvent? {
    if !events.isEmpty { return events.removeFirst() }
    guard endReason == nil, started else { return nil }
    self.service = service
    if !keepalivesStarted, established, service == .connection, let interval = keepaliveInterval {
      keepalivesStarted = true
      packetsSinceKeepaliveScheduled = false
      queue(.timer(.schedule(.keepalive, after: interval)))
    }
    if reexchangeDue { startReexchange() }
    while events.isEmpty && endReason == nil {
      do {
        if awaitingTrust {
          if streamEnded { finish(.closed(.connectionLost)) }
          break
        }
        if serverVersion == nil {
          try readVersion()
          guard serverVersion != nil else {
            if streamEnded { finish(.closed(.connectionLost)) }
            break
          }
        }
        guard let packet = try inbound.next() else {
          if streamEnded {
            finish(.closed(.connectionLost))
          } else if packetsSinceKeepaliveScheduled, let interval = keepaliveInterval, keepalivesStarted {
            packetsSinceKeepaliveScheduled = false
            queue(.timer(.schedule(.keepalive, after: interval)))
          }
          break
        }
        try handle(packet, service: service)
        checkRekeyThresholds()
      } catch {
        finish(error)
      }
    }
    return events.isEmpty ? nil : events.removeFirst()
  }

  public func answerHostKey(trusted: Bool) {
    guard awaitingTrust, endReason == nil else { return }
    awaitingTrust = false
    guard trusted, let candidate else {
      finish(.hostKeyRejected)
      return
    }
    pin = HostKeyPin(candidate)
    do { try sendNewKeys() } catch { finish(error) }
  }

  public func timerFired(_ timer: CoreTimer) {
    guard endReason == nil else { return }
    switch timer {
    case .keepalive:
      // None before the login (RFC 4252 §6; see the header): a stray firing then does nothing.
      guard keepalivesStarted, let interval = keepaliveInterval else { return }
      guard unanswered < keepaliveCountMax, outstandingKeepalives.count < Limits.keepaliveCountMax else {
        finish(.timedOut(.keepalive))
        return
      }
      unanswered += 1
      do { try transmit(.keepalive) } catch { return }
      queue(.timer(.schedule(.keepalive, after: interval)))
    case .rekey:
      reexchangeDue = true
      startReexchange()
    case .directAnswer:
      // The auth layer's timer: the composer routes it there.
      return
    }
  }

  public func takeOutbound() -> [UInt8] {
    defer { outbound.output = [] }
    return outbound.output
  }

  // MARK: Test hooks

  /// The next sequence numbers both ways (tests drive them to the wrap).
  var sequenceNumbers: (inbound: UInt64, outbound: UInt64) { (inbound.nextSequence, outbound.nextSequence) }

  func setSequenceNumbers(inbound inboundNext: UInt64? = nil, outbound outboundNext: UInt64? = nil) {
    if let inboundNext { inbound.setSequence(inboundNext) }
    if let outboundNext { outbound.setSequence(outboundNext) }
  }

  /// Keepalives sent and not answered yet.
  var keepalivesOutstanding: Int { outstandingKeepalives.count }

  /// Bytes received and not decoded yet (the robustness tests bound it).
  var inboundBuffered: Int { inbound.buffered }

  /// The negotiated algorithms of the exchange in progress or, once none is, of the last one.
  private(set) var negotiated: NegotiatedAlgorithms?

  // MARK: Outbound

  /// While an exchange runs, from our KEXINIT until our NEWKEYS (and before `start`), payloads wait.
  private var holding: Bool {
    guard started else { return true }
    guard let exchange else { return false }
    return !exchange.sentNewKeys
  }

  private func transmit(_ item: Held) throws(SSHError) {
    if holding {
      held.append(item)
      heldBytes += item.count
      return
    }
    do {
      try seal(item)
    } catch {
      finish(error)
      throw .closed(.alreadyEnded)
    }
    checkRekeyThresholds()
  }

  private func seal(_ item: Held) throws(SSHError) {
    switch item {
    case .payload(let payload):
      try sealNow(payload)
    case .secret(let secret):
      var result: Result<(UInt32, Int), SSHError> = .failure(.closed(.alreadyEnded))
      secret.withUnsafeBytes { raw in
        do throws(SSHError) { result = .success(try outbound.seal(raw, random: random)) } catch { result = .failure(error) }
      }
      count(outbound: try result.get().1)
    case .keepalive:
      let sequence = try sealNow(Self.keepaliveRequest)
      outstandingKeepalives.append(sequence)
    }
  }

  @discardableResult
  private func sealNow(_ payload: [UInt8]) throws(SSHError) -> UInt32 {
    let (sequence, bytes) = try outbound.seal(payload, random: random)
    count(outbound: bytes)
    return sequence
  }

  private func count(outbound bytes: Int) {
    outboundBytes &+= UInt64(bytes)
    outboundPackets &+= 1
  }

  private func sendKexInit(initial: Bool) throws(SSHError) {
    let cookie = try random.bytes(KexInit.cookieBytes)
    let payload = try KexInit.client(preferences, cookie: cookie, initial: initial).encoded()
    exchange = Exchange(initial: initial, clientKexInit: payload)
    try sealNow(payload)
  }

  private func sendNewKeys() throws(SSHError) {
    guard let exchange, let sealer = exchange.sealer else { throw Self.outOfPhase(.newKeys) }
    try sealNow([MessageNumber.newKeys.rawValue])
    outbound.install(sealer)
    exchange.sealer = nil
    if strict { outbound.resetSequence() }
    outboundBytes = 0
    outboundPackets = 0
    exchange.sentNewKeys = true
    let waiting = held
    held = []
    heldBytes = 0
    for item in waiting { try seal(item) }
  }

  private func checkRekeyThresholds() {
    guard established, exchange == nil, endReason == nil else { return }
    let limit = thresholds
    guard inboundBytes >= limit.bytes || outboundBytes >= limit.bytes || inboundPackets >= limit.packets
      || outboundPackets >= limit.packets
    else { return }
    reexchangeDue = true
    startReexchange()
  }

  /// Starts the re-exchange that is due, once nothing stands in its way: the first exchange is done, none is running,
  /// and the layers above are in the connection phase.
  private func startReexchange() {
    guard reexchangeDue, established, exchange == nil, endReason == nil, service == .connection else { return }
    reexchangeDue = false
    do { try sendKexInit(initial: false) } catch { finish(error) }
  }

  // MARK: Inbound

  private func readVersion() throws(SSHError) {
    while serverVersion == nil {
      let (line, consumed) = try VersionExchange.takeLine(inbound.unconsumed)
      guard case .line(let raw) = line else { return }
      inbound.consume(consumed)
      if let identification = try VersionExchange.identification(raw) {
        serverVersion = identification
      } else {
        preVersionLines += 1
        guard preVersionLines <= Limits.preVersionLines else { throw .protocolViolation(.version(.tooManyLines)) }
      }
    }
  }

  private var policyPhase: MessagePolicy.TransportPhase {
    guard let exchange else { return established ? .established : .awaitingFirstKexInit }
    switch (exchange.initial, exchange.stage) {
    case (true, .awaitingKexInit): return .awaitingFirstKexInit
    case (true, .awaitingReply): return .initialExchange(.awaitingReply, strict: strict)
    case (true, .awaitingNewKeys): return .initialExchange(.awaitingNewKeys, strict: strict)
    case (false, .awaitingKexInit): return .rekeyRequested
    case (false, .awaitingReply): return .reexchange(.awaitingReply)
    case (false, .awaitingNewKeys): return .reexchange(.awaitingNewKeys)
    }
  }

  private func handle(_ packet: InboundFramer.Packet, service: MessagePolicy.ServicePhase) throws(SSHError) {
    guard let message = InboundMessage(payload: packet.payload) else { throw .protocolViolation(.packet(.invalidPadding)) }
    inboundBytes &+= UInt64(packet.wireBytes)
    inboundPackets &+= 1
    let context = MessagePolicy.Context(transport: policyPhase, service: service,
                                        firstPacketAfterNewKeys: firstPacketAfterNewKeys, extInfoReceived: extInfoCount)
    let route = try MessagePolicy.check(message.number, in: context)
    if firstPacketAfterNewKeys {
      // RFC 8308 §2.4: now it is known whether the server sent EXT_INFO in its place.
      firstPacketAfterNewKeys = false
      if extensions == nil { extensions = ServerExtensions() }
    }
    if established {
      unanswered = 0
      packetsSinceKeepaliveScheduled = keepaliveInterval != nil
    }
    switch route {
    case .service:
      queue(.message(message))
    case .transport:
      try handleTransport(message, sequence: packet.sequence)
    }
  }

  private func handleTransport(_ message: InboundMessage, sequence: UInt32) throws(SSHError) {
    switch message.number {
    case .disconnect:
      let (reason, description) = try message.decode { (reader: inout WireReader) throws(WireError) in
        let reason = try reader.readUInt32()
        let description = try reader.readString(limit: Limits.descriptionBytes)
        _ = try reader.readString(limit: Limits.languageTagBytes)
        return (reason, description)
      }
      finish(.closed(.byServer(DisconnectReason(reason), description: DisplayText.sanitize(description))))
    case .ignore:
      return
    case .debug:
      _ = try message.decode { (reader: inout WireReader) throws(WireError) in
        _ = try reader.readBoolean()
        _ = try reader.readDisplayText(limit: Limits.descriptionBytes)
        _ = try reader.readString(limit: Limits.languageTagBytes)
      }
    case .unimplemented:
      let number = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readUInt32() }
      // Only a keepalive may go unimplemented (a server without global requests may answer so; sshd did before
      // authentication, when keepalives went then).
      guard let index = outstandingKeepalives.firstIndex(of: number) else {
        throw .protocolViolation(.unimplemented(sequence: number))
      }
      outstandingKeepalives.removeSubrange(0...index)
    case .extInfo:
      try receiveExtInfo(message)
    case .kexInit:
      try receiveKexInit(message.payload, sequence: sequence)
    case .kexECDHReply:
      try receiveReply(message.payload)
    case .newKeys:
      try receiveNewKeys(message)
    case .globalRequest:
      try refuseGlobalRequest(message)
    case .requestSuccess, .requestFailure:
      guard !outstandingKeepalives.isEmpty else { throw .protocolViolation(.channel(.unexpectedGlobalReply)) }
      if message.number == .requestFailure { try message.decode { (_: inout WireReader) throws(WireError) in } }
      outstandingKeepalives.removeFirst()
    default:
      throw Self.outOfPhase(message.number)
    }
  }

  private func receiveExtInfo(_ message: InboundMessage) throws(SSHError) {
    let entries = try message.decode { (reader: inout WireReader) throws(WireError) -> [(String, [UInt8])] in
      let count = try reader.readCount(limit: Limits.extInfoExtensions, elementBytes: 8)
      var entries: [(String, [UInt8])] = []
      for _ in 0..<count { entries.append((try reader.readName(), try reader.readString(limit: Limits.extensionValueBytes))) }
      return entries
    }
    var updated = extensions ?? ServerExtensions()
    for (name, value) in entries { updated.values[name] = value }
    extensions = updated
    extInfoCount += 1
  }

  private func refuseGlobalRequest(_ message: InboundMessage) throws(SSHError) {
    let wantReply = try message.decode { (reader: inout WireReader) throws(WireError) -> Bool in
      _ = try reader.readName()
      let wantReply = try reader.readBoolean()
      _ = reader.readRemaining()
      return wantReply
    }
    if wantReply { try transmit(.payload([MessageNumber.requestFailure.rawValue])) }
  }

  private func receiveKexInit(_ payload: [UInt8], sequence: UInt32) throws(SSHError) {
    let server = try KexInit(decoding: payload)
    // The server starts a re-exchange: answer with ours first (RFC 4253 §7.1). It satisfies one of ours that was due.
    if exchange == nil {
      reexchangeDue = false
      try sendKexInit(initial: false)
    }
    guard let exchange, exchange.stage == .awaitingKexInit else { throw Self.outOfPhase(.kexInit) }
    if exchange.initial {
      strict = server.keyExchange.contains(KexSignal.strictServer)
      try MessagePolicy.checkFirstKexInit(sequence: sequence, strict: strict)
      serverSendsExtInfo = server.keyExchange.contains(KexSignal.extInfoServer)
    }
    let negotiated = try Negotiation.negotiate(preferences, server: server, strict: strict,
                                               serverSendsExtInfo: serverSendsExtInfo)
    try AlgorithmPolicy.check(negotiated)
    let method = KeyExchangeMethods.make(negotiated.keyExchange, random: random)
    let initPayload = try method.makeInit()
    exchange.serverKexInit = payload
    exchange.negotiated = negotiated
    exchange.method = method
    exchange.stage = .awaitingReply
    self.negotiated = negotiated
    try sealNow(initPayload)
  }

  private func receiveReply(_ payload: [UInt8]) throws(SSHError) {
    guard let exchange, exchange.stage == .awaitingReply, let method = exchange.method,
      let negotiated = exchange.negotiated, let serverVersion
    else { throw Self.outOfPhase(.kexECDHReply) }
    exchange.method = nil
    let transcript = KeyExchangeTranscript(clientVersion: clientVersion, serverVersion: serverVersion,
                                           clientKexInit: exchange.clientKexInit, serverKexInit: exchange.serverKexInit)
    let output = try method.receiveReply(payload, transcript: transcript)
    if exchange.initial {
      let key = try HostKey(algorithm: negotiated.hostKey, blob: output.hostKeyBlob)
      try verifier.verify(signatureBlob: output.signature, over: output.exchangeHash, key: key.key,
                          algorithm: negotiated.hostKey)
      candidate = key
      session = output.exchangeHash
    } else {
      guard let pin else { throw Self.outOfPhase(.kexECDHReply) }
      try pin.check(algorithm: negotiated.hostKey, blob: output.hostKeyBlob)
      try verifier.verify(signatureBlob: output.signature, over: output.exchangeHash, key: pin.trusted.key,
                          algorithm: negotiated.hostKey)
    }
    guard let session else { throw Self.outOfPhase(.kexECDHReply) }
    let keys = KeyDerivation.keys(for: negotiated, sharedSecret: output.encodedSharedSecret,
                                  exchangeHash: output.exchangeHash, sessionID: session, hash: output.hash)
    exchange.sealer = try PacketProtection.sealer(cipher: negotiated.clientToServer.cipher,
                                                  mac: negotiated.clientToServer.mac, keys: keys.clientToServer)
    exchange.opener = try PacketProtection.opener(cipher: negotiated.serverToClient.cipher,
                                                  mac: negotiated.serverToClient.mac, keys: keys.serverToClient)
    exchange.stage = .awaitingNewKeys
    if exchange.initial, let candidate {
      awaitingTrust = true
      queue(.hostKeyNeedsTrust(candidate))
    } else {
      try sendNewKeys()
    }
  }

  private func receiveNewKeys(_ message: InboundMessage) throws(SSHError) {
    try message.decode { (_: inout WireReader) throws(WireError) in }
    guard let exchange, exchange.stage == .awaitingNewKeys, exchange.sentNewKeys, let opener = exchange.opener else {
      throw Self.outOfPhase(.newKeys)
    }
    inbound.install(opener)
    exchange.opener = nil
    if strict { inbound.resetSequence() }
    inboundBytes = 0
    inboundPackets = 0
    self.exchange = nil
    if exchange.initial {
      established = true
      firstPacketAfterNewKeys = true
      queue(.established)
    } else {
      queue(.rekeyed)
    }
    queue(.timer(.schedule(.rekey, after: thresholds.interval)))
  }

  // MARK: The end

  private func queue(_ event: TransportEvent) {
    guard endReason == nil else { return }
    events.append(event)
  }

  private func finish(_ error: SSHError) {
    guard endReason == nil else { return }
    endReason = error
    events = [.ended(error)]
    held = []
    heldBytes = 0
    exchange = nil
    candidate = nil
    awaitingTrust = false
    outstandingKeepalives = []
    guard started, Self.sendsDisconnect(error) else { return }
    var writer = WireWriter(.disconnect, capacity: 16)
    writer.writeUInt32(error.disconnectReason.rawValue)
    writer.writeString([UInt8]())
    writer.writeString([UInt8]())
    if let payload = try? writer.finish() { _ = try? outbound.seal(payload, random: random) }
  }

  private static func sendsDisconnect(_ error: SSHError) -> Bool {
    switch error {
    case .closed(.byServer), .closed(.connectionLost), .protocolViolation(.version),
         .protocolViolation(.packet(.sequenceExhausted)):
      false
    default:
      true
    }
  }

  // MARK: Helpers

  /// The layers above may send SERVICE_REQUEST, userauth and channel messages, each fitting one packet.
  private static func checkUpperPayload(first: UInt8?, count: Int) throws(SSHError) {
    guard let first, first == MessageNumber.serviceRequest.rawValue || (50...79).contains(first)
      || (90...127).contains(first), count <= Limits.packetLength - 64
    else { throw .usage(.invalidArgument("a message the layers above may not send")) }
  }

  /// A message the policy routed here although this state cannot take it (a defensive check: the policy's table and
  /// this state machine agree, so it does not happen).
  private static func outOfPhase(_ number: MessageNumber) -> SSHError {
    .protocolViolation(.unexpectedMessage(number, MessagePolicy.Context(transport: .established)))
  }

  /// Returned by `hostKey` before the first exchange: the layers above never see it (they start at `established`).
  private static let placeholderKey: HostKey = {
    let blob: [UInt8] = [0, 0, 0, 11] + Array("ssh-ed25519".utf8) + [0, 0, 0, 32] + [UInt8](repeating: 0, count: 32)
    do { return try HostKey(algorithm: .ed25519, blob: blob) } catch { preconditionFailure("a constant, valid blob") }
  }()
}
