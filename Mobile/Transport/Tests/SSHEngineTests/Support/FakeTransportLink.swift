import SSHEngine

/// An in-memory `TransportLink` for the layers above the transport (Auth/, Connection/): it records what they send
/// and routes the server's messages through `MessagePolicy` as the real transport does, without any cryptography.
/// Enforces the contract's send rules (numbers, the end), so a layer that breaks them fails here first.
final class FakeTransportLink: TransportLink {
  var sessionID: [UInt8]
  var hostKey: HostKey
  var serverExtensions: ServerExtensions?
  var outboundBacklog = 0
  /// Payloads sent, in order (secret payloads included, copied: tests only).
  private(set) var sent: [[UInt8]] = []
  /// Which entries of `sent` came through `send(secret:)`.
  private(set) var secretIndices: [Int] = []
  /// The first `end`, if any.
  private(set) var endedWith: SSHError?
  /// The policy's view of the transport; `.established` unless a test simulates a re-exchange.
  var transportPhase: MessagePolicy.TransportPhase = .established
  var firstPacketAfterNewKeys = true
  private(set) var extInfoReceived = 0

  init(sessionID: [UInt8] = [UInt8](repeating: 0x5E, count: 32), hostKey: HostKey? = nil,
       serverExtensions: ServerExtensions? = ServerExtensions()) {
    self.sessionID = sessionID
    // A fictional key: the fixture blob always decodes.
    self.hostKey = hostKey ?? (try! HostKey(algorithm: .ed25519, blob: Fixture.ed25519Blob))
    self.serverExtensions = serverExtensions
  }

  var isOpen: Bool { endedWith == nil }

  func send(_ payload: [UInt8]) throws(SSHError) {
    try check(payload)
    sent.append(payload)
  }

  func send(secret payload: SecretBytes) throws(SSHError) {
    let copy = payload.withUnsafeBytes { Array($0) }
    try check(copy)
    secretIndices.append(sent.count)
    sent.append(copy)
  }

  func end(_ error: SSHError) {
    if endedWith == nil { endedWith = error }
  }

  /// A server payload as the transport would hand it up while the layers are in `service`: through the policy
  /// (throwing its error for a message the phase refuses), the transport's own messages (EXT_INFO) absorbed.
  /// Returns nil for a message the transport keeps.
  func deliver(_ payload: [UInt8], service: MessagePolicy.ServicePhase) throws(SSHError) -> InboundMessage? {
    guard let message = InboundMessage(payload: payload) else {
      throw .protocolViolation(.malformed(MessageNumber(0), .truncated))
    }
    let context = MessagePolicy.Context(
      transport: transportPhase, service: service, firstPacketAfterNewKeys: firstPacketAfterNewKeys,
      extInfoReceived: extInfoReceived)
    firstPacketAfterNewKeys = false
    switch try MessagePolicy.check(message.number, in: context) {
    case .service:
      return message
    case .transport:
      if message.number == .extInfo { extInfoReceived += 1 }
      return nil
    }
  }

  private func check(_ payload: [UInt8]) throws(SSHError) {
    guard endedWith == nil else { throw .closed(.alreadyEnded) }
    guard let number = payload.first,
      number == MessageNumber.serviceRequest.rawValue || (50...79).contains(number) || (90...127).contains(number),
      payload.count <= Limits.packetLength - 64
    else { throw .usage(.invalidArgument("a message the layers above may not send")) }
  }
}
