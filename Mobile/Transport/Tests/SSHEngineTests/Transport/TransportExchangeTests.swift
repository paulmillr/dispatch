import CryptoKit
import XCTest
@testable import SSHEngine

/// The transport against the scripted server: complete exchanges with every method, cipher and MAC, strict and not,
/// re-exchanges from either side with payloads held across them, the host key's trust and pin, EXT_INFO.
final class TransportExchangeTests: XCTestCase {
  static func only(kex: KeyExchangeAlgorithm = .curve25519, cipher: CipherAlgorithm = .aes256GCM,
                   mac: MACAlgorithm? = nil, hostKey: [SignatureAlgorithm] = [.ed25519, .ecdsaP256]) -> AlgorithmPolicy.Preferences {
    AlgorithmPolicy.Preferences(keyExchange: [kex], hostKey: hostKey, cipher: [cipher], mac: mac.map { [$0] } ?? [])
  }

  static func channelData(_ bytes: [UInt8]) -> [UInt8] {
    [MessageNumber.channelData.rawValue] + Raw.u32(0) + Raw.string(bytes)
  }

  /// A connected harness in the connection phase (SERVICE_REQUEST answered).
  static func connected(_ algorithms: AlgorithmPolicy.Preferences = .standard, server: ScriptedServer = ScriptedServer(),
                        chunk: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> TransportHarness {
    let harness = try TransportHarness(options: TransportHarness.options(algorithms), server: server)
    harness.chunk = chunk
    harness.connect()
    XCTAssertNil(harness.endReason(), file: file, line: line)
    XCTAssertTrue(harness.isEstablished, file: file, line: line)
    try harness.client.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-userauth"))
    harness.service = .serviceRequested
    harness.pump()
    XCTAssertEqual(harness.messages.last?.number, .serviceAccept, file: file, line: line)
    // As if USERAUTH_SUCCESS had come: our own re-exchanges wait for the connection phase.
    harness.service = .connection
    harness.drain()
    return harness
  }

  /// Payloads of several sizes both ways; each arrives intact and in order.
  static func exchangeTraffic(_ harness: TransportHarness, file: StaticString = #filePath, line: UInt = #line) throws {
    let sizes = [0, 1, 15, 16, 17, 255, 1000, 4096, 32 * 1024, 100_000]
    let before = harness.messages.count
    let sentBefore = harness.serverReceived([94]).count
    for (index, size) in sizes.enumerated() {
      let bytes = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) }
      harness.server.send(channelData(bytes))
      try harness.client.send(channelData(bytes.reversed()))
    }
    harness.pump()
    XCTAssertNil(harness.endReason(), file: file, line: line)
    XCTAssertNil(harness.serverError, file: file, line: line)
    let delivered = Array(harness.messages[before...]).map(\.payload)
    let received = Array(harness.serverReceived([94])[sentBefore...])
    XCTAssertEqual(delivered.count, sizes.count, file: file, line: line)
    XCTAssertEqual(received.count, sizes.count, file: file, line: line)
    for (index, size) in sizes.enumerated() where index < delivered.count && index < received.count {
      let bytes = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) }
      XCTAssertEqual(delivered[index], channelData(bytes), "server to client, \(size) bytes", file: file, line: line)
      XCTAssertEqual(received[index], channelData(bytes.reversed()), "client to server, \(size) bytes", file: file, line: line)
    }
  }

  // MARK: The first exchange

  func testTheFirstExchangeCompletesWithTheStandardPreferences() throws {
    let harness = try TransportHarness()
    let events = harness.connect()
    XCTAssertNil(harness.serverError)
    XCTAssertNil(harness.endReason())
    let key = try HostKey(algorithm: .ed25519, blob: harness.server.identity.publicBlob)
    XCTAssertEqual(events.first, .hostKeyNeedsTrust(key))
    XCTAssertEqual(events.filter { if case .hostKeyNeedsTrust = $0 { true } else { false } }.count, 1)
    XCTAssertTrue(harness.isEstablished)
    XCTAssertEqual(harness.client.hostKey, key)
    XCTAssertEqual(harness.client.sessionID.count, 32)
    XCTAssertEqual(harness.client.negotiated?.keyExchange, .mlkem768x25519)
    XCTAssertEqual(harness.client.negotiated?.clientToServer.cipher, .aes256GCM)
    XCTAssertTrue(harness.client.negotiated?.strictKex ?? false)
    XCTAssertTrue(harness.client.negotiated?.serverSendsExtInfo ?? false)
    // The EXT_INFO right behind NEWKEYS.
    XCTAssertEqual(harness.client.serverExtensions?.serverSignatureAlgorithms?.first, "ssh-ed25519")
    // Timers: the time-based rekey from established on; keepalives only once logged in (the connection phase).
    XCTAssertFalse(events.contains(.timer(.schedule(.keepalive, after: .seconds(15)))))
    XCTAssertTrue(events.contains(.timer(.schedule(.rekey, after: Limits.rekeyInterval))))
    harness.service = .connection
    XCTAssertEqual(harness.pump(), [.timer(.schedule(.keepalive, after: .seconds(15)))])
    // The client's lines: its version, then KEXINIT with both signals.
    XCTAssertEqual(harness.server.clientVersion, Array("SSH-2.0-\(ClientTransport.softwareVersion)".utf8))
    let kexInit = try KexInit(decoding: harness.server.received[0])
    XCTAssertEqual(Array(kexInit.keyExchange.suffix(2)), [KexSignal.extInfoClient, KexSignal.strictClient])
    XCTAssertEqual(kexInit.compressionClientToServer, ["none"])
  }

  func testEveryKeyExchangeMethod() throws {
    let valueSizes: [KeyExchangeAlgorithm: Int] = [.curve25519: 32, .curve25519LibSSH: 32, .ecdhP256: 65, .ecdhP384: 97,
                                                   .ecdhP521: 133, .mlkem768x25519: 1216]
    for method in KeyExchangeAlgorithm.allCases {
      let harness = try Self.connected(Self.only(kex: method))
      XCTAssertEqual(harness.client.negotiated?.keyExchange, method, "\(method)")
      XCTAssertEqual(harness.client.sessionID.count, method.hash.digestBytes, "\(method)")
      let initMessage = try XCTUnwrap(harness.serverReceived([30]).first)
      XCTAssertEqual(initMessage.count, 1 + 4 + (valueSizes[method] ?? 0), "\(method)")
      try Self.exchangeTraffic(harness)
      // And a re-exchange with the same method.
      harness.client.timerFired(.rekey)
      XCTAssertTrue(harness.pump().contains(.rekeyed), "\(method)")
      try Self.exchangeTraffic(harness)
    }
  }

  func testEveryCipherAndMACBothWays() throws {
    var cases: [(CipherAlgorithm, MACAlgorithm?)] = [(.aes256GCM, nil), (.aes128GCM, nil), (.chacha20Poly1305, nil)]
    for cipher in [CipherAlgorithm.aes256CTR, .aes192CTR, .aes128CTR] {
      for mac in MACAlgorithm.allCases { cases.append((cipher, mac)) }
    }
    for (cipher, mac) in cases {
      for chunk in [0, 7] {
        let harness = try Self.connected(Self.only(cipher: cipher, mac: mac), chunk: chunk)
        XCTAssertEqual(harness.client.negotiated?.clientToServer, .init(cipher: cipher, mac: mac))
        XCTAssertEqual(harness.client.negotiated?.serverToClient, .init(cipher: cipher, mac: mac))
        try Self.exchangeTraffic(harness)
        harness.client.timerFired(.rekey)
        XCTAssertTrue(harness.pump().contains(.rekeyed), "\(cipher) \(String(describing: mac))")
        try Self.exchangeTraffic(harness)
      }
    }
  }

  func testNonStrictExchangeWithAESGCM() throws {
    var configuration = ScriptedServer.Configuration()
    configuration.strict = false
    // Before the server's KEXINIT strictness is unknown: IGNORE and DEBUG are fine there when it is not strict.
    configuration.beforeKexInit = [[MessageNumber.ignore.rawValue] + Raw.string("x"),
                                   [MessageNumber.debug.rawValue, 0] + Raw.string("hello") + Raw.string("")]
    let harness = try Self.connected(Self.only(cipher: .aes128GCM), server: ScriptedServer(configuration: configuration))
    XCTAssertEqual(harness.client.negotiated?.strictKex, false)
    // Without strict key exchange sequence numbers run on from the first packet: the server sent 2 + KEXINIT, reply,
    // NEWKEYS, EXT_INFO and SERVICE_ACCEPT; the client KEXINIT, its init, NEWKEYS and SERVICE_REQUEST.
    XCTAssertEqual(harness.client.sequenceNumbers.inbound, 7)
    XCTAssertEqual(harness.client.sequenceNumbers.outbound, 4)
    try Self.exchangeTraffic(harness)
    harness.client.timerFired(.rekey)
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    try Self.exchangeTraffic(harness)
  }

  func testStrictKeyExchangeResetsSequenceNumbersAtEveryNewKeys() throws {
    let harness = try Self.connected(Self.only())
    // Reset at NEWKEYS: then EXT_INFO and SERVICE_ACCEPT came, SERVICE_REQUEST went.
    XCTAssertEqual(harness.client.sequenceNumbers.inbound, 2)
    XCTAssertEqual(harness.client.sequenceNumbers.outbound, 1)
    harness.client.timerFired(.rekey)
    harness.pump()
    XCTAssertEqual(harness.client.sequenceNumbers.inbound, 0)
    XCTAssertEqual(harness.client.sequenceNumbers.outbound, 0)
    try Self.exchangeTraffic(harness)
  }

  /// Without strict key exchange, every mode through a real handshake: ChaCha20-Poly1305 and AES-CTR with an
  /// encrypt-then-MAC MAC (Terrapin's truncatable modes) are refused before the method's first message, with a
  /// DISCONNECT; AES-GCM and AES-CTR with an encrypt-and-MAC MAC establish, carry traffic and re-exchange.
  func testWithoutStrictKeyExchangeTheTruncatableModesAreRefused() throws {
    for cipher in CipherAlgorithm.allCases {
      for mac in cipher.isAEAD ? [nil] : MACAlgorithm.allCases.map(Optional.some) {
        let mode = NegotiatedAlgorithms.Direction(cipher: cipher, mac: mac)
        var configuration = ScriptedServer.Configuration()
        configuration.strict = false
        let harness = try TransportHarness(options: TransportHarness.options(Self.only(cipher: cipher, mac: mac)),
                                           server: ScriptedServer(configuration: configuration))
        harness.connect()
        if AlgorithmPolicy.isTruncatable(mode) {
          let expected: SSHError = mac.map { .protocolViolation(.negotiation(.encryptThenMACRequiresStrictKex(cipher, $0))) }
            ?? .protocolViolation(.negotiation(.cipherRequiresStrictKex(cipher)))
          XCTAssertEqual(harness.endReason(), expected, "\(mode)")
          XCTAssertTrue(harness.serverReceived([30]).isEmpty, "\(mode): refused before the method's first message")
          XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.keyExchangeFailed.rawValue, "\(mode)")
        } else {
          XCTAssertTrue(harness.isEstablished, "\(mode)")
          XCTAssertEqual(harness.client.negotiated?.strictKex, false)
          XCTAssertEqual(harness.client.negotiated?.clientToServer, mode)
          XCTAssertEqual(harness.client.negotiated?.serverToClient, mode)
          harness.service = .connection
          harness.client.timerFired(.rekey)
          XCTAssertTrue(harness.pump().contains(.rekeyed), "\(mode)")
          try Self.exchangeTraffic(harness)
          XCTAssertNil(harness.endReason(), "\(mode)")
        }
      }
    }
  }

  /// The standard order against servers without strict key exchange: one KEXINIT from the client, no waiting for the
  /// server's, lands on an allowed mode whenever the server has one (Dropbear's chacha20 + CTR + hmac-sha2-256 and
  /// OpenSSH 7.x without OpenSSL: AES-CTR with hmac-sha2-256), and only a server with nothing else is refused.
  func testTheStandardOrderLandsOnAnAllowedModeWithoutStrictKeyExchange() throws {
    let cases: [([CipherAlgorithm], [MACAlgorithm], Result<NegotiatedAlgorithms.Direction, SSHError>)] = [
      ([.chacha20Poly1305, .aes128CTR, .aes256CTR], [.hmacSHA256], .success(.init(cipher: .aes256CTR, mac: .hmacSHA256))),
      ([.chacha20Poly1305, .aes128CTR, .aes192CTR, .aes256CTR], MACAlgorithm.allCases,
       .success(.init(cipher: .aes256CTR, mac: .hmacSHA256))),
      ([.chacha20Poly1305, .aes128CTR, .aes256CTR, .aes128GCM, .aes256GCM], MACAlgorithm.allCases,
       .success(.init(cipher: .aes256GCM, mac: nil))),
      ([.chacha20Poly1305], MACAlgorithm.allCases,
       .failure(.protocolViolation(.negotiation(.cipherRequiresStrictKex(.chacha20Poly1305))))),
      ([.chacha20Poly1305, .aes128CTR], [.hmacSHA256ETM, .hmacSHA512ETM],
       .failure(.protocolViolation(.negotiation(.encryptThenMACRequiresStrictKex(.aes128CTR, .hmacSHA256ETM))))),
    ]
    for (ciphers, macs, expected) in cases {
      var configuration = ScriptedServer.Configuration()
      configuration.strict = false
      configuration.ciphers = ciphers.map(\.rawValue)
      configuration.macs = macs.map(\.rawValue)
      let harness = try TransportHarness(server: ScriptedServer(configuration: configuration))
      harness.connect()
      let label = "\(ciphers.map(\.rawValue)) \(macs.map(\.rawValue))"
      switch expected {
      case .success(let mode):
        XCTAssertTrue(harness.isEstablished, label)
        XCTAssertEqual(harness.client.negotiated?.clientToServer, mode, label)
        XCTAssertEqual(harness.client.negotiated?.serverToClient, mode, label)
      case .failure(let error):
        XCTAssertEqual(harness.endReason(), error, label)
      }
    }
  }

  // MARK: Re-exchanges

  func testOurReexchangeHoldsPayloadsInOrder() throws {
    let harness = try Self.connected()
    harness.client.timerFired(.rekey)
    let payloads = (0..<3).map { Self.channelData([UInt8](repeating: UInt8($0), count: 100 * ($0 + 1))) }
    for payload in payloads { try harness.client.send(payload) }
    try harness.client.send(secret: SecretBytes(copying: Self.channelData(Array("a secret".utf8))))
    XCTAssertGreaterThanOrEqual(harness.client.outboundBacklog, payloads.map(\.count).reduce(0, +))
    // Only the KEXINIT goes before the server answered.
    let early = harness.client.takeOutbound()
    try harness.server.receive(early)
    XCTAssertEqual(harness.server.received.last?.first, MessageNumber.kexInit.rawValue)
    XCTAssertEqual(harness.client.outboundBacklog, payloads.map(\.count).reduce(0, +) + Self.channelData(Array("a secret".utf8)).count)
    // The server sends channel data before it saw our KEXINIT: it still arrives (rekey requested).
    let events = harness.pump()
    XCTAssertTrue(events.contains(.rekeyed))
    XCTAssertNil(harness.endReason())
    let numbers = harness.server.received.map { $0.first ?? 0 }
    let newKeys = try XCTUnwrap(numbers.lastIndex(of: MessageNumber.newKeys.rawValue))
    XCTAssertEqual(Array(harness.server.received[(newKeys + 1)...]), payloads + [Self.channelData(Array("a secret".utf8))])
    XCTAssertEqual(harness.server.exchanges, 2)
    XCTAssertTrue(events.contains(.timer(.schedule(.rekey, after: Limits.rekeyInterval))))
    try Self.exchangeTraffic(harness)
  }

  func testMessagesStillArriveWhileOurKexInitIsUnanswered() throws {
    let harness = try Self.connected()
    harness.client.timerFired(.rekey)
    // The server's data crosses our KEXINIT.
    harness.server.send(Self.channelData([1, 2, 3]))
    harness.deliver(harness.server.takeOutbound())
    harness.drain()
    XCTAssertEqual(harness.messages.last?.payload, Self.channelData([1, 2, 3]))
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertNil(harness.endReason())
  }

  func testTheServersReexchangeHoldsPayloadsInOrder() throws {
    let harness = try Self.connected()
    harness.server.startRekey()
    harness.deliver(harness.server.takeOutbound())
    harness.drain()
    // The client answered with its KEXINIT and method message; now payloads wait.
    let payloads = (0..<4).map { Self.channelData([UInt8](repeating: UInt8($0), count: 10)) }
    for payload in payloads { try harness.client.send(payload) }
    let events = harness.pump()
    XCTAssertTrue(events.contains(.rekeyed))
    XCTAssertNil(harness.endReason())
    let numbers = harness.server.received.map { $0.first ?? 0 }
    let newKeys = try XCTUnwrap(numbers.lastIndex(of: MessageNumber.newKeys.rawValue))
    XCTAssertEqual(Array(harness.server.received[(newKeys + 1)...]), payloads)
    // The re-exchange KEXINIT offers the same algorithms, without the two signals.
    let kexInits = harness.serverReceived([20]).map { try? KexInit(decoding: $0) }
    XCTAssertEqual(kexInits.count, 2)
    XCTAssertEqual(kexInits[1]?.keyExchange, AlgorithmPolicy.Preferences.standard.keyExchange.map(\.rawValue))
    XCTAssertEqual(kexInits[1]?.hostKey, kexInits[0]?.hostKey)
    XCTAssertEqual(kexInits[1]?.cipherClientToServer, kexInits[0]?.cipherClientToServer)
    try Self.exchangeTraffic(harness)
  }

  func testTheLayersAboveGetNothingDuringAReexchange() throws {
    let harness = try Self.connected()
    harness.server.startRekey()
    harness.server.send(Self.channelData([9]))
    harness.pump()
    XCTAssertTrue(harness.endReason()?.isUnexpected(.channelData) ?? false, "\(String(describing: harness.endReason()))")
  }

  func testRepeatedReexchangesFromBothSides() throws {
    let harness = try Self.connected()
    for round in 0..<6 {
      if round % 2 == 0 { harness.client.timerFired(.rekey) } else { harness.server.startRekey() }
      XCTAssertTrue(harness.pump().contains(.rekeyed), "round \(round)")
      try Self.exchangeTraffic(harness)
    }
    XCTAssertEqual(harness.server.exchanges, 7)
    XCTAssertEqual(harness.events.filter { $0 == .established }.count, 1)
  }

  func testSimultaneousKexInits() throws {
    let harness = try Self.connected()
    harness.client.timerFired(.rekey)
    harness.server.startRekey()
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertNil(harness.endReason())
    XCTAssertEqual(harness.serverReceived([20]).count, 2)
    try Self.exchangeTraffic(harness)
  }

  func testOurReexchangeStartsAtThePacketAndByteLimits() throws {
    let harness = try Self.connected()
    harness.client.thresholds.packets = 10
    for index in 0..<12 { try harness.client.send(Self.channelData([UInt8(index)])) }
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertEqual(harness.serverReceived([94]).count, 12)
    harness.client.thresholds.packets = Limits.rekeyPackets
    harness.client.thresholds.bytes = 10_000
    harness.server.send(Self.channelData([UInt8](repeating: 7, count: 20_000)))
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertEqual(harness.server.exchanges, 3)
    try Self.exchangeTraffic(harness)
  }

  func testOurReexchangeWaitsForTheConnectionPhase() throws {
    let harness = try TransportHarness()
    harness.connect()
    harness.client.thresholds.packets = 2
    harness.client.timerFired(.rekey)
    try harness.client.send([MessageNumber.serviceRequest.rawValue] + Raw.string("ssh-userauth"))
    harness.service = .serviceRequested
    harness.pump()
    harness.service = .userauth(.noneMethod)
    try harness.client.send([MessageNumber.userauthRequest.rawValue] + Raw.string("u") + Raw.string("ssh-connection") + Raw.string("none"))
    harness.pump()
    // Due twice over (the timer, the packet limit), and still no KEXINIT before the connection phase.
    XCTAssertEqual(harness.serverReceived([20]).count, 1)
    XCTAssertFalse(harness.events.contains(.rekeyed))
    harness.service = .connection
    XCTAssertTrue(harness.pump().contains(.rekeyed))
    XCTAssertEqual(harness.serverReceived([20]).count, 2)
    // One re-exchange satisfied both; the server's own is taken before the connection phase too.
    harness.pump()
    XCTAssertEqual(harness.serverReceived([20]).count, 2)
    let early = try TransportHarness()
    early.connect()
    early.server.startRekey()
    XCTAssertTrue(early.pump().contains(.rekeyed))
  }

  // MARK: Host key trust and the pin

  func testNothingIsSentOrReadPastTheExchangeUntilTheKeyIsTrusted() throws {
    let harness = try TransportHarness()
    harness.trust = nil
    harness.connect()
    guard case .hostKeyNeedsTrust = harness.events.last else { return XCTFail("\(harness.events)") }
    XCTAssertTrue(harness.serverReceived([21]).isEmpty)
    // What the server sends meanwhile waits.
    harness.server.send([MessageNumber.ignore.rawValue] + Raw.string(""))
    harness.pump()
    XCTAssertNil(harness.client.poll(service: .serviceNotRequested))
    XCTAssertFalse(harness.isEstablished)
    harness.client.answerHostKey(trusted: true)
    harness.pump()
    XCTAssertTrue(harness.isEstablished)
    XCTAssertEqual(harness.serverReceived([21]).count, 1)
    // A second answer does nothing.
    harness.client.answerHostKey(trusted: false)
    harness.pump()
    XCTAssertNil(harness.endReason())
  }

  func testARejectedKeyEndsTheConnectionWithoutNewKeys() throws {
    let harness = try TransportHarness()
    harness.trust = false
    harness.connect()
    XCTAssertEqual(harness.endReason(), .hostKeyRejected)
    XCTAssertTrue(harness.serverReceived([21]).isEmpty)
    XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.hostKeyNotVerifiable.rawValue)
    XCTAssertFalse(harness.client.isOpen)
  }

  func testABadSignatureIsRefusedBeforeTheTrustQuestion() throws {
    let server = ScriptedServer()
    server.signWrongData = true
    let harness = try TransportHarness(server: server)
    harness.connect()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.keyExchange(.invalidSignature)))
    XCTAssertFalse(harness.events.contains { if case .hostKeyNeedsTrust = $0 { true } else { false } })
  }

  func testAHostKeyOfAnotherTypeThanNegotiatedIsRefused() throws {
    var configuration = ScriptedServer.Configuration()
    configuration.hostKeyAlgorithms = ["ssh-ed25519"]
    let harness = try TransportHarness(server: ScriptedServer(configuration: configuration, identity: .ecdsaP256(seed: 3)))
    harness.connect()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.keyExchange(.hostKeyTypeMismatch)))
  }

  /// `Core/tests/hostile.rs`' nested certificate: a certificate is refused by its type name, so nothing nests.
  func testACertificateHostKeyIsRefusedByName() throws {
    for depth in [1, 2000] {
      var certificate = Raw.string("ssh-ed25519-cert-v01@openssh.com") + Raw.string([UInt8](repeating: 0, count: 32))
      for _ in 1..<depth { certificate = Raw.string("ssh-ed25519-cert-v01@openssh.com") + Raw.string(certificate) }
      let server = ScriptedServer()
      server.replyMutator = { reply in
        var reader = WireReader(reply)
        _ = try? reader.readByte()
        _ = try? reader.readString(limit: Limits.publicKeyBlobBytes)
        return [MessageNumber.kexECDHReply.rawValue] + Raw.string(certificate) + reader.readRemaining()
      }
      let harness = try TransportHarness(server: server)
      harness.connect()
      let expected: SSHError = certificate.count > Limits.publicKeyBlobBytes
        ? .protocolViolation(.malformed(.kexECDHReply, .tooLong(limit: Limits.publicKeyBlobBytes)))
        : .protocolViolation(.keyExchange(.hostKeyCertificate))
      XCTAssertEqual(harness.endReason(), expected, "depth \(depth)")
      XCTAssertFalse(harness.events.contains { if case .hostKeyNeedsTrust = $0 { true } else { false } })
    }
  }

  func testTheSameKeyAtEveryReexchangeKeepsTheSession() throws {
    let harness = try Self.connected()
    let sessionID = harness.client.sessionID
    for _ in 0..<3 {
      harness.server.startRekey()
      XCTAssertTrue(harness.pump().contains(.rekeyed))
    }
    XCTAssertEqual(harness.client.sessionID, sessionID)
    XCTAssertEqual(harness.events.filter { if case .hostKeyNeedsTrust = $0 { true } else { false } }.count, 1)
  }

  func testAnotherKeyAtAReexchangeEndsTheConnectionBeforeItsKeysCarryAnything() throws {
    for serverStarts in [true, false] {
      let harness = try Self.connected()
      harness.server.identity = .ed25519(seed: 0x77)
      if serverStarts {
        // Once the client has the server's KEXINIT, its payloads wait for the new keys.
        harness.server.startRekey()
        harness.deliver(harness.server.takeOutbound())
        harness.drain()
      } else {
        harness.client.timerFired(.rekey)
      }
      try harness.client.send(Self.channelData([1]))
      harness.pump()
      XCTAssertEqual(harness.endReason(), .hostKeyChangedAtRekey(.differentKey))
      // The client never sent NEWKEYS for it, nor the payload waiting for it.
      XCTAssertEqual(harness.serverReceived([21]).count, 1)
      XCTAssertTrue(harness.serverReceived([94]).isEmpty)
      XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.hostKeyNotVerifiable.rawValue)
      XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try harness.client.send(Self.channelData([2])) }
    }
  }

  func testAnotherAlgorithmAtAReexchangeIsAChange() throws {
    let harness = try Self.connected()
    harness.server.identity = .ecdsaP256(seed: 9)
    harness.server.startRekey()
    harness.pump()
    XCTAssertEqual(harness.endReason(), .hostKeyChangedAtRekey(.differentAlgorithm(trusted: .ed25519, presented: .ecdsaP256)))
    XCTAssertEqual(harness.serverReceived([21]).count, 1)
  }

  func testAGoodRekeysThenAChangedKeyWhileDataFlows() throws {
    let harness = try Self.connected()
    for _ in 0..<2 {
      harness.server.startRekey()
      XCTAssertTrue(harness.pump().contains(.rekeyed))
      try Self.exchangeTraffic(harness)
    }
    harness.server.identity = .ed25519(seed: 0x78)
    harness.server.startRekey()
    harness.deliver(harness.server.takeOutbound())
    harness.drain()
    // Writes during the refused exchange wait, then fail once it ended: nothing blocks.
    for index in 0..<50 { try? harness.client.send(Self.channelData([UInt8(index)])) }
    harness.pump()
    XCTAssertEqual(harness.endReason(), .hostKeyChangedAtRekey(.differentKey))
    XCTAssertEqual(harness.client.outboundBacklog, harness.client.takeOutbound().count)
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try harness.client.send(Self.channelData([0])) }
  }

  // MARK: EXT_INFO

  func testWithoutExtInfoTheExtensionsAreEmptyOnceTheNextPacketCame() throws {
    var configuration = ScriptedServer.Configuration()
    configuration.extInfo = false
    let harness = try TransportHarness(server: ScriptedServer(configuration: configuration))
    harness.connect()
    XCTAssertTrue(harness.isEstablished)
    XCTAssertNil(harness.client.serverExtensions)
    harness.server.send([MessageNumber.ignore.rawValue] + Raw.string(""))
    harness.pump()
    XCTAssertEqual(harness.client.serverExtensions, ServerExtensions())
    XCTAssertEqual(harness.client.serverExtensions?.rsaAlgorithm, .rsaSHA512)
  }

  func testASecondExtInfoWhileARequestIsOutUpdatesTheExtensionsAndAThirdEnds() throws {
    let harness = try Self.connected()
    harness.service = .userauth(.password)
    var writer = WireWriter(.extInfo)
    writer.writeUInt32(2)
    writer.writeName("server-sig-algs")
    writer.writeString(Array("rsa-sha2-256".utf8))
    writer.writeName("ping@openssh.com")
    writer.writeString(Array("0".utf8))
    let second = try writer.finish()
    harness.server.send(second)
    harness.pump()
    XCTAssertNil(harness.endReason())
    XCTAssertEqual(harness.client.serverExtensions?.serverSignatureAlgorithms, ["rsa-sha2-256"])
    XCTAssertEqual(harness.client.serverExtensions?.rsaAlgorithm, .rsaSHA256)
    XCTAssertEqual(harness.client.serverExtensions?.values["ping@openssh.com"], Array("0".utf8))
    harness.server.send(second)
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.tooManyExtInfo))
  }

  func testAnExtInfoClaimingMoreThanItHoldsIsMalformed() throws {
    var configuration = ScriptedServer.Configuration()
    configuration.extInfo = false
    let harness = try TransportHarness(server: ScriptedServer(configuration: configuration))
    harness.connect()
    harness.server.send([MessageNumber.extInfo.rawValue] + Raw.u32(10_000) + Raw.string("a") + Raw.string("b"))
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.malformed(.extInfo, .tooMany(limit: Limits.extInfoExtensions))))
  }

  // MARK: Secrets

  func testSecretPayloadsArriveIntact() throws {
    let harness = try Self.connected(Self.only(cipher: .chacha20Poly1305))
    let secret = [MessageNumber.userauthRequest.rawValue] + Raw.string("alice") + Raw.string("ssh-connection")
      + Raw.string("password") + [0] + Raw.string("correct horse")
    try harness.client.send(secret: SecretBytes(copying: secret))
    harness.pump()
    XCTAssertEqual(harness.serverReceived([50]), [secret])
  }
}
