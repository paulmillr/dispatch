import XCTest
@testable import SSHEngine

/// What a hostile or broken server sends, at the transport (the transport's share of `Core/tests/hostile.rs`, and
/// more): every case ends the connection with its error, exactly once, without a trap, a hang or unbounded memory.
final class TransportHostileTests: XCTestCase {
  // MARK: Helpers

  /// A client fed `bytes` as the server's stream (optionally followed by EOF), drained.
  static func feed(_ bytes: [UInt8], end: Bool = false, chunk: Int = 0) throws -> (ClientTransport, [TransportEvent]) {
    let client = try ClientTransport(options: TransportHarness.options(), verifier: TestSignatureVerifier(),
                                     random: SeededRandom(seed: 1))
    client.start()
    var events: [TransportEvent] = []
    func drain() { while let event = client.poll(service: .serviceNotRequested) { events.append(event) } }
    if chunk > 0 {
      var offset = 0
      while offset < bytes.count {
        client.receive(Array(bytes[offset..<min(bytes.count, offset + chunk)]))
        offset += chunk
        drain()
      }
    } else {
      client.receive(bytes)
      drain()
    }
    if end {
      client.receiveEnd()
      drain()
    }
    XCTAssertNil(client.poll(service: .serviceNotRequested))
    return (client, events)
  }

  static func ended(_ events: [TransportEvent]) -> SSHError? {
    guard case .ended(let error) = events.last else { return nil }
    XCTAssertEqual(events.filter { if case .ended = $0 { true } else { false } }.count, 1)
    return error
  }

  static let serverLine = Array("SSH-2.0-Hostile_1.0\r\n".utf8)

  /// A plaintext packet (block 8, the length included in the alignment) with `padding` bytes of padding.
  static func plaintextPacket(_ payload: [UInt8], padding: Int? = nil) -> [UInt8] {
    let pad = padding ?? {
      var pad = 8 - (5 + payload.count) % 8
      if pad < 4 { pad += 8 }
      return pad
    }()
    return Raw.u32(UInt32(1 + payload.count + pad)) + [UInt8(pad)] + payload + [UInt8](repeating: 0, count: pad)
  }

  static func serverKexInit(strict: Bool = true, kex: [String] = ["curve25519-sha256"], cipher: [String] = ["aes256-gcm@openssh.com"],
                            compression: [String] = ["none"], follows: Bool = false) -> [UInt8] {
    var kexInit = NegotiationTests.server(kex: kex + (strict ? [KexSignal.strictServer] : []), ciphers: cipher,
                                          compression: compression)
    kexInit.firstKexPacketFollows = follows
    return (try? kexInit.encoded()) ?? []
  }

  // MARK: The version exchange

  func testLinesBeforeTheVersionWithinTheBounds() throws {
    let lines = (0..<Limits.preVersionLines).flatMap { Array("banner line \($0) ✓\r\n".utf8) }
    let (client, events) = try Self.feed(lines + Self.serverLine + Self.plaintextPacket(Self.serverKexInit()), chunk: 5)
    XCTAssertNil(Self.ended(events))
    XCTAssertTrue(client.isOpen)
  }

  func testTooManyLinesBeforeTheVersion() throws {
    let lines = (0...Limits.preVersionLines).flatMap { Array("line \($0)\r\n".utf8) }
    XCTAssertEqual(Self.ended(try Self.feed(lines + Self.serverLine).1), .protocolViolation(.version(.tooManyLines)))
  }

  func testALineTooLong() throws {
    // 254 bytes and LF fit; 255 without an LF do not.
    let fits = [UInt8](repeating: 0x41, count: Limits.versionLineBytes - 1) + [0x0A]
    XCTAssertNil(Self.ended(try Self.feed(fits + Self.serverLine).1))
    let garbage = [UInt8](repeating: 0x00, count: Limits.versionLineBytes)
    XCTAssertEqual(Self.ended(try Self.feed(garbage).1), .protocolViolation(.version(.lineTooLong)))
    // Checked as the bytes arrive, without waiting for more.
    XCTAssertEqual(Self.ended(try Self.feed(garbage, chunk: 1).1), .protocolViolation(.version(.lineTooLong)))
    let longVersion = Array("SSH-2.0-".utf8) + [UInt8](repeating: 0x61, count: 300) + [0x0D, 0x0A]
    XCTAssertEqual(Self.ended(try Self.feed(longVersion).1), .protocolViolation(.version(.lineTooLong)))
  }

  func testVersionLines() throws {
    let cases: [(String, SSHError?)] = [
      ("SSH-2.0-OpenSSH_10.5\r\n", nil),
      ("SSH-2.0-OpenSSH_10.5 with a comment\r\n", nil),
      ("SSH-1.99-Legacy\r\n", nil),
      ("SSH-2.0-BareLF\n", nil),
      ("SSH-1.5-Old\r\n", .protocolViolation(.version(.notSSH2))),
      ("SSH-2.1-Future\r\n", .protocolViolation(.version(.notSSH2))),
      ("SSH-\r\n", .protocolViolation(.version(.notSSH2))),
      ("SSH-2.0-\r\n", .protocolViolation(.version(.malformedLine))),
      ("SSH-2.0- leading space\r\n", .protocolViolation(.version(.malformedLine))),
      ("SSH-2.0-Tab\there\r\n", .protocolViolation(.version(.malformedLine))),
      ("SSH-2.0-CR\rinside\r\n", .protocolViolation(.version(.malformedLine))),
    ]
    for (line, expected) in cases {
      XCTAssertEqual(Self.ended(try Self.feed(Array(line.utf8)).1), expected, line)
    }
    XCTAssertEqual(Self.ended(try Self.feed(Array("SSH-2.0-Nul\0\r\n".utf8)).1), .protocolViolation(.version(.malformedLine)))
  }

  func testEndOfStreamBeforeTheVersionIsALoss() throws {
    XCTAssertEqual(Self.ended(try Self.feed(Array("SSH-2.0-Trunc".utf8), end: true).1), .closed(.connectionLost))
    XCTAssertEqual(Self.ended(try Self.feed([], end: true).1), .closed(.connectionLost))
  }

  func testGarbageAfterTheVersionLine() throws {
    let random = SeededRandom(seed: 77)
    for _ in 0..<200 {
      let garbage = try random.bytes(1 + random.below(600))
      let (_, events) = try Self.feed(Self.serverLine + garbage, end: true)
      let error = try XCTUnwrap(Self.ended(events))
      switch error {
      case .protocolViolation, .closed(.connectionLost): break
      default: XCTFail("\(error)")
      }
    }
  }

  // MARK: Framing

  func testAnOversizedLengthIsRefusedFromTheLengthAlone() throws {
    for length: UInt32 in [0xFFFF_FFFF, 0x4000_0000, UInt32(Limits.packetLength + 4)] {
      // Only the 4 length bytes: no more is waited for.
      let (client, events) = try Self.feed(Self.serverLine + Raw.u32(length))
      XCTAssertEqual(Self.ended(events), .protocolViolation(.packet(.lengthOutOfRange)), "\(length)")
      XCTAssertFalse(client.isOpen)
    }
    // The largest aligned length within the limit is waited for.
    let (client, events) = try Self.feed(Self.serverLine + Raw.u32(UInt32(Limits.packetLength - 4)))
    XCTAssertNil(Self.ended(events))
    XCTAssertTrue(client.isOpen)
  }

  func testAnOversizedLengthUnderTheNewKeys() throws {
    let harness = try TransportExchangeTests.connected(TransportExchangeTests.only(cipher: .aes256GCM))
    // AES-GCM's length is in the clear: 1 GiB, then zeros.
    harness.server.sendRaw(Raw.u32(0x4000_0000) + [UInt8](repeating: 0, count: 64))
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.lengthOutOfRange)))
    XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.protocolError.rawValue)
  }

  func testATooShortLength() throws {
    for length: UInt32 in [0, 1, 4] {
      XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + Raw.u32(length)).1), .protocolViolation(.packet(.lengthOutOfRange)))
    }
  }

  func testMisalignedPackets() throws {
    // Plaintext: 4 + 13 is not a multiple of 8.
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + Raw.u32(13)).1), .protocolViolation(.packet(.misaligned)))
    // AES-GCM: 17 is not a multiple of 16.
    let harness = try TransportExchangeTests.connected(TransportExchangeTests.only(cipher: .aes128GCM))
    harness.server.sendRaw(Raw.u32(17) + [UInt8](repeating: 0, count: 64))
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.misaligned)))
  }

  func testInvalidPadding() throws {
    // Padding below 4.
    var packet = Raw.u32(12) + [3] + [MessageNumber.ignore.rawValue] + Raw.string("abc") + [0, 0, 0]
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + packet).1), .protocolViolation(.packet(.invalidPadding)))
    // Padding covering the whole packet (no payload), and past it.
    packet = Raw.u32(12) + [11] + [UInt8](repeating: 0, count: 11)
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + packet).1), .protocolViolation(.packet(.invalidPadding)))
    packet = Raw.u32(12) + [200] + [UInt8](repeating: 0, count: 11)
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + packet).1), .protocolViolation(.packet(.invalidPadding)))
  }

  func testATamperedPacketInEveryFamily() throws {
    // The last byte (the tag or MAC), a ciphertext byte, and (where the length is covered) the length's last byte.
    let tamperings: [(String, (inout [UInt8]) -> Void)] = [
      ("tag", { $0[$0.count - 1] ^= 0x01 }),
      ("ciphertext", { $0[$0.count / 2] ^= 0x80 }),
      ("padding length", { $0[4] ^= 0x01 }),
    ]
    for (cipher, mac) in PacketProtectionTests.families {
      for (what, tamper) in tamperings {
        let harness = try TransportExchangeTests.connected(TransportExchangeTests.only(cipher: cipher, mac: mac))
        harness.server.corruptNextPacket = tamper
        harness.server.send(TransportExchangeTests.channelData([UInt8](repeating: 0x42, count: 200)))
        harness.pump()
        XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.integrity)), "\(cipher) \(String(describing: mac)) \(what)")
        XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.macError.rawValue)
        // Nothing of the tampered packet reached the layers above.
        XCTAssertNil(harness.messages.first { $0.number == .channelData })
      }
    }
    // A flipped encrypted length (ChaCha20-Poly1305's is under its own key) ends the connection either way.
    let harness = try TransportExchangeTests.connected(TransportExchangeTests.only(cipher: .chacha20Poly1305))
    harness.server.corruptNextPacket = { $0[0] ^= 0x10 }
    harness.server.send(TransportExchangeTests.channelData([1, 2, 3]))
    harness.server.send(TransportExchangeTests.channelData([UInt8](repeating: 0, count: 2000)))
    harness.pump()
    harness.client.receiveEnd()
    harness.drain()
    XCTAssertNotNil(harness.endReason())
    XCTAssertNil(harness.messages.first { $0.number == .channelData })
  }

  func testTheInboundBufferIsBounded() throws {
    let harness = try TransportExchangeTests.connected()
    // A driver that keeps feeding without draining (or a peer flooding while the trust question is open).
    for _ in 0..<5 { harness.client.receive([UInt8](repeating: 0, count: 100_000)) }
    harness.drain()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.bufferOverflow)))
  }

  func testAFloodWhileTheTrustQuestionIsOpen() throws {
    let harness = try TransportHarness()
    harness.trust = nil
    harness.connect()
    for _ in 0..<4 { harness.client.receive([UInt8](repeating: 0x55, count: 100_000)) }
    harness.drain()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.bufferOverflow)))
  }

  // MARK: Sequence numbers

  func testTheInboundSequenceNumberNeverWraps() throws {
    let server = ScriptedServer(configuration: .with { $0.strict = false })
    let harness = try TransportExchangeTests.connected(TransportExchangeTests.only(cipher: .aes256GCM), server: server)
    harness.client.setSequenceNumbers(inbound: UInt64(UInt32.max))
    harness.server.setSequenceNumbers(outbound: UInt64(UInt32.max))
    harness.server.send(TransportExchangeTests.channelData([1]))
    harness.pump()
    // Packet 2^32 - 1 is fine; the next one would wrap.
    XCTAssertNil(harness.endReason())
    XCTAssertEqual(harness.messages.last?.payload, TransportExchangeTests.channelData([1]))
    // The server's framer refuses to wrap too; AES-GCM's nonce does not use the number, so it may start over.
    harness.server.setSequenceNumbers(outbound: 0)
    harness.server.send(TransportExchangeTests.channelData([2]))
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.sequenceExhausted)))
    // No DISCONNECT could carry a sequence number: none is sent.
    XCTAssertNil(harness.server.disconnectReason)
  }

  func testTheOutboundSequenceNumberNeverWraps() throws {
    let server = ScriptedServer(configuration: .with { $0.strict = false })
    let harness = try TransportExchangeTests.connected(TransportExchangeTests.only(cipher: .aes256GCM), server: server)
    harness.client.setSequenceNumbers(outbound: UInt64(UInt32.max))
    harness.server.setSequenceNumbers(inbound: UInt64(UInt32.max))
    try harness.client.send(TransportExchangeTests.channelData([1]))
    harness.pump()
    XCTAssertEqual(harness.serverReceived([94]).count, 1)
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in
      try harness.client.send(TransportExchangeTests.channelData([2]))
    }
    harness.pump()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.packet(.sequenceExhausted)))
  }

  // MARK: Strict key exchange and negotiation

  func testUnderStrictKeyExchangeKexInitMustBeTheFirstPacket() throws {
    for first in [[MessageNumber.ignore.rawValue] + Raw.string(""), [MessageNumber.debug.rawValue, 0] + Raw.string("") + Raw.string("")] {
      let harness = try TransportHarness(server: ScriptedServer(configuration: .with { $0.beforeKexInit = [first] }))
      harness.connect()
      XCTAssertEqual(harness.endReason(), .protocolViolation(.strictKeyExchange))
      XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.keyExchangeFailed.rawValue)
    }
  }

  func testUnderStrictKeyExchangeNothingElseIsTakenDuringTheFirstExchange() throws {
    // An IGNORE between the KEXINIT and the reply.
    let ignore = Self.plaintextPacket([MessageNumber.ignore.rawValue] + Raw.string(""))
    let (_, events) = try Self.feed(Self.serverLine + Self.plaintextPacket(Self.serverKexInit(strict: true)) + ignore)
    XCTAssertTrue(Self.ended(events)?.isUnexpected(.ignore) ?? false, "\(events)")
    // Without strict key exchange (AES-GCM) it is ignored.
    let (client, relaxed) = try Self.feed(Self.serverLine + Self.plaintextPacket(Self.serverKexInit(strict: false)) + ignore)
    XCTAssertNil(Self.ended(relaxed))
    XCTAssertTrue(client.isOpen)
  }

  func testNegotiationFailures() throws {
    let cases: [([UInt8], SSHError)] = [
      (Self.serverKexInit(kex: ["diffie-hellman-group14-sha256"]), .protocolViolation(.negotiation(.noCommonAlgorithm(.keyExchange)))),
      (Self.serverKexInit(cipher: ["aes256-cbc", "3des-cbc"]), .protocolViolation(.negotiation(.noCommonAlgorithm(.cipher)))),
      (Self.serverKexInit(compression: ["zlib@openssh.com"]), .protocolViolation(.negotiation(.noCommonAlgorithm(.compression)))),
      (Self.serverKexInit(follows: true), .protocolViolation(.negotiation(.firstKexPacketFollows))),
    ]
    for (kexInit, expected) in cases {
      let (client, events) = try Self.feed(Self.serverLine + Self.plaintextPacket(kexInit))
      XCTAssertEqual(Self.ended(events), expected)
      // A DISCONNECT (key exchange failed) is the last thing queued.
      let outbound = client.takeOutbound()
      XCTAssertGreaterThan(outbound.count, 0)
    }
    // A malformed KEXINIT.
    let truncated = Array(Self.serverKexInit().dropLast(3))
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + Self.plaintextPacket(truncated)).1),
                   .protocolViolation(.malformed(.kexInit, .truncated)))
  }

  func testAHostKeyAlgorithmOnlyTheServerKnows() throws {
    let server = ScriptedServer(configuration: .with { $0.hostKeyAlgorithms = ["ssh-rsa", "ssh-dss"] })
    let harness = try TransportHarness(server: server)
    harness.connect()
    XCTAssertEqual(harness.endReason(), .protocolViolation(.negotiation(.noCommonAlgorithm(.hostKey))))
  }

  // MARK: Messages out of phase

  func testMessagesOutOfPhaseBeforeAndDuringTheFirstExchange() throws {
    let kexInit = Self.plaintextPacket(Self.serverKexInit())
    let cases: [([UInt8], MessageNumber)] = [
      (Self.plaintextPacket([MessageNumber.serviceAccept.rawValue] + Raw.string("ssh-userauth")), .serviceAccept),
      (Self.plaintextPacket([MessageNumber.newKeys.rawValue]), .newKeys),
      (Self.plaintextPacket([MessageNumber.unimplemented.rawValue] + Raw.u32(0)), .unimplemented),
      (Self.plaintextPacket([MessageNumber.extInfo.rawValue] + Raw.u32(0)), .extInfo),
      (kexInit + Self.plaintextPacket([MessageNumber.newKeys.rawValue]), .newKeys),
      (kexInit + kexInit, .kexInit),
      (kexInit + Self.plaintextPacket([MessageNumber.channelData.rawValue] + Raw.u32(0) + Raw.string("x")), .channelData),
      (kexInit + Self.plaintextPacket([MessageNumber.userauthSuccess.rawValue]), .userauthSuccess),
      (Self.plaintextPacket([0xC0]), MessageNumber(0xC0)),
      (Self.plaintextPacket([0]), MessageNumber(0)),
    ]
    for (stream, number) in cases {
      let error = Self.ended(try Self.feed(Self.serverLine + stream).1)
      XCTAssertTrue(error?.isUnexpected(number) ?? false, "\(number): \(String(describing: error))")
    }
  }

  func testMessagesOutOfPhaseOnceEstablished() throws {
    let cases: [(MessagePolicy.ServicePhase, [UInt8], MessageNumber)] = [
      (.serviceNotRequested, [MessageNumber.serviceAccept.rawValue] + Raw.string("ssh-userauth"), .serviceAccept),
      (.serviceRequested, [MessageNumber.userauthSuccess.rawValue], .userauthSuccess),
      (.userauth(.idle), [MessageNumber.userauthFailure.rawValue] + Raw.string("password") + [0], .userauthFailure),
      (.userauth(.publicKeySigned), [60] + Raw.string("x"), MessageNumber(60)),
      (.userauth(.password), [MessageNumber.globalRequest.rawValue] + Raw.string("hostkeys-00@openssh.com") + [0], .globalRequest),
      (.userauth(.password), [MessageNumber.channelData.rawValue] + Raw.u32(0) + Raw.string("x"), .channelData),
      (.connection, [MessageNumber.serviceAccept.rawValue] + Raw.string("ssh-userauth"), .serviceAccept),
      (.connection, [MessageNumber.newKeys.rawValue], .newKeys),
      (.connection, [MessageNumber.kexECDHReply.rawValue], .kexECDHReply),
      (.connection, [MessageNumber.extInfo.rawValue] + Raw.u32(0), .extInfo),
    ]
    for (service, payload, number) in cases {
      let harness = try TransportExchangeTests.connected()
      harness.service = service
      harness.server.send(payload)
      harness.pump()
      XCTAssertTrue(harness.endReason()?.isUnexpected(number) ?? false, "\(service) \(number): \(String(describing: harness.endReason()))")
    }
  }

  func testAKexInitDuringAReexchangeIsRefused() throws {
    let harness = try TransportExchangeTests.connected()
    harness.server.startRekey()
    harness.deliver(harness.server.takeOutbound())
    harness.drain()
    harness.server.startRekey()
    harness.pump()
    XCTAssertTrue(harness.endReason()?.isUnexpected(.kexInit) ?? false)
  }

  // MARK: The server's own messages

  func testTheServersDisconnect() throws {
    let harness = try TransportExchangeTests.connected()
    harness.server.send([MessageNumber.disconnect.rawValue] + Raw.u32(11) + Raw.string("bye\u{1B}[2J\nnow") + Raw.string("en"))
    harness.pump()
    XCTAssertEqual(harness.endReason(), .closed(.byServer(.byApplication, description: "bye [2J now")))
    // No DISCONNECT back.
    XCTAssertNil(harness.server.disconnectReason)
    // Latin-1 and an unknown reason.
    let latin = try TransportExchangeTests.connected()
    latin.server.send([MessageNumber.disconnect.rawValue] + Raw.u32(4000) + Raw.string([0x41, 0xFC, 0x42]) + Raw.string(""))
    latin.pump()
    XCTAssertEqual(latin.endReason(), .closed(.byServer(DisconnectReason(4000), description: "A B")))
  }

  func testADisconnectFollowedByTheEndOfTheStream() throws {
    let disconnect = Self.plaintextPacket([MessageNumber.disconnect.rawValue] + Raw.u32(2) + Raw.string("no") + Raw.string(""))
    let (_, events) = try Self.feed(Self.serverLine + disconnect, end: true)
    XCTAssertEqual(Self.ended(events), .closed(.byServer(.protocolError, description: "no")))
    // A truncated packet at the end is a loss.
    let (_, cut) = try Self.feed(Self.serverLine + Array(disconnect.dropLast(2)), end: true)
    XCTAssertEqual(Self.ended(cut), .closed(.connectionLost))
  }

  func testAMalformedDisconnectOrDebug() throws {
    let disconnect = Self.plaintextPacket([MessageNumber.disconnect.rawValue] + Raw.u32(2))
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + disconnect).1), .protocolViolation(.malformed(.disconnect, .truncated)))
    let debug = Self.plaintextPacket([MessageNumber.debug.rawValue, 2] + Raw.string("") + Raw.string(""))
    XCTAssertEqual(Self.ended(try Self.feed(Self.serverLine + debug).1), .protocolViolation(.malformed(.debug, .invalidBoolean)))
  }

  func testTheServersGlobalRequestsAreRefused() throws {
    let harness = try TransportExchangeTests.connected()
    harness.server.send([MessageNumber.globalRequest.rawValue] + Raw.string("hostkeys-00@openssh.com") + [0] + Raw.string("blob"))
    harness.server.send([MessageNumber.globalRequest.rawValue] + Raw.string("tcpip-forward") + [1] + Raw.string("0.0.0.0") + Raw.u32(22))
    harness.pump()
    XCTAssertNil(harness.endReason())
    // Only the one that wants a reply gets one: REQUEST_FAILURE.
    XCTAssertEqual(harness.serverReceived([81, 82]), [[MessageNumber.requestFailure.rawValue]])
    XCTAssertTrue(harness.messages.allSatisfy { $0.number != .globalRequest })
  }

  // MARK: The layers above

  func testEndFromAboveSendsDisconnectOnceAndEndsOnce() throws {
    let harness = try TransportExchangeTests.connected()
    harness.client.end(.closed(.byClient))
    harness.client.end(.protocolViolation(.tooManyExtInfo))
    XCTAssertFalse(harness.client.isOpen)
    harness.pump()
    XCTAssertEqual(harness.endReason(), .closed(.byClient))
    XCTAssertEqual(harness.server.disconnectReason, DisconnectReason.byApplication.rawValue)
    XCTAssertNil(harness.client.poll(service: .connection))
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try harness.client.send([5]) }
    // Inputs after the end change nothing.
    harness.client.receive([1, 2, 3])
    harness.client.timerFired(.keepalive)
    harness.client.answerHostKey(trusted: true)
    XCTAssertNil(harness.client.poll(service: .connection))
    XCTAssertTrue(harness.client.takeOutbound().isEmpty)
  }

  func testTheLayersAboveMaySendOnlyTheirMessages() throws {
    let harness = try TransportExchangeTests.connected()
    for payload: [UInt8] in [[], [1], [2], [3], [4], [6], [7], [20], [21], [30], [31], [80], [81], [82], [128], [255]] {
      XCTAssertThrows(SSHError.usage(.invalidArgument("a message the layers above may not send"))) { () throws(SSHError) in
        try harness.client.send(payload)
      }
    }
    XCTAssertThrows(SSHError.usage(.invalidArgument("a message the layers above may not send"))) { () throws(SSHError) in
      try harness.client.send([94] + [UInt8](repeating: 0, count: Limits.packetLength))
    }
    for payload: [UInt8] in [[5], [50], [79], [90], [127]] { XCTAssertNoThrow(try harness.client.send(payload)) }
    XCTAssertTrue(harness.client.isOpen)
  }
}
