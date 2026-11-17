import SSHEngine
import XCTest

/// The contract types that carry behaviour: host keys and the rekey pin, error codes and texts, extensions, options.
final class ContractTests: XCTestCase {
  func testHostKey() throws {
    let key = try HostKey(algorithm: .ed25519, blob: Fixture.ed25519Blob)
    XCTAssertEqual(key.keyType, "ssh-ed25519")
    // Checked against Python's hashlib and base64 for the same fictional blob.
    XCTAssertEqual(key.fingerprint, "SHA256:SQfC+vTbLURn9cTkVxIS8fGQ3FKNAJWeB0o139+gV4M")
    XCTAssertEqual(key.openSSH, "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBERERERERERERERERERERERERERERERERERERERERER")
    let rsa = try HostKey(algorithm: .rsaSHA256, blob: Fixture.rsaBlob)
    XCTAssertEqual(rsa.keyType, "ssh-rsa")
    XCTAssertTrue(rsa.openSSH.hasPrefix("ssh-rsa AAAAB3NzaC1yc2E"))
  }

  func testHostKeyRefusals() {
    XCTAssertThrows(SSHError.protocolViolation(.keyExchange(.hostKeyTypeMismatch))) { () throws(SSHError) in
      try HostKey(algorithm: .ecdsaP256, blob: Fixture.ed25519Blob)
    }
    XCTAssertThrows(SSHError.protocolViolation(.keyExchange(.hostKeyTypeMismatch))) { () throws(SSHError) in
      try HostKey(algorithm: .ed25519, blob: Fixture.ed25519Blob + [0])
    }
    let certificate = Raw.string("ssh-ed25519-cert-v01@openssh.com") + Raw.string([UInt8](repeating: 0, count: 32))
    XCTAssertThrows(SSHError.protocolViolation(.keyExchange(.hostKeyCertificate))) { () throws(SSHError) in
      try HostKey(algorithm: .ed25519, blob: certificate)
    }
  }

  func testThePinHoldsEveryReexchangeToTheFirstKey() throws {
    let pin = HostKeyPin(try HostKey(algorithm: .ed25519, blob: Fixture.ed25519Blob))
    XCTAssertNoThrow(try pin.check(algorithm: .ed25519, blob: Fixture.ed25519Blob))
    XCTAssertThrows(SSHError.hostKeyChangedAtRekey(.differentKey)) { () throws(SSHError) in
      try pin.check(algorithm: .ed25519, blob: Fixture.otherEd25519Blob)
    }
    // A certificate, garbage: a change, not a parse error.
    XCTAssertThrows(SSHError.hostKeyChangedAtRekey(.differentKey)) { () throws(SSHError) in
      try pin.check(algorithm: .ed25519, blob: [1, 2, 3])
    }
    let changed = SSHError.hostKeyChangedAtRekey(.differentAlgorithm(trusted: .ed25519, presented: .ecdsaP256))
    XCTAssertThrows(changed) { () throws(SSHError) in try pin.check(algorithm: .ecdsaP256, blob: Fixture.ecdsaBlob(.p256)) }
    // The russh engine's texts, which the app shows.
    XCTAssertEqual("\(changed)", "the host key algorithm changed at a key re-exchange (ssh-ed25519, now ecdsa-sha2-nistp256)")
    XCTAssertEqual("\(SSHError.hostKeyChangedAtRekey(.differentKey))",
                   "the server presented a different host key at a key re-exchange")
    // RSA's two algorithms are two: stricter than OpenSSH.
    let rsa = HostKeyPin(try HostKey(algorithm: .rsaSHA512, blob: Fixture.rsaBlob))
    XCTAssertThrows(SSHError.hostKeyChangedAtRekey(.differentAlgorithm(trusted: .rsaSHA512, presented: .rsaSHA256))) {
      () throws(SSHError) in try rsa.check(algorithm: .rsaSHA256, blob: Fixture.rsaBlob)
    }
  }

  func testErrorCodesMatchTheCABI() {
    let cases: [(SSHError, Int32)] = [
      (.hostNotFound, -11), (.connectionRefused, -12), (.unreachable, -13), (.noAnswer, -14), (.network("reset"), -1),
      (.timedOut(.keepalive), -2), (.timedOut(.directAnswer), -2), (.hostKeyRejected, -3),
      (.hostKeyChangedAtRekey(.differentKey), -15), (.protocolViolation(.tooManyExtInfo), -4),
      (.usage(.notAuthenticated), -4), (.closed(.byClient), -9), (.closed(.connectionLost), -9), (.cancelled, -7),
      (.invalidKey("not a key file"), -5), (.wrongPassphrase, -6), (.unsupported("DSA keys"), -8),
      (.channelOpenFailed(.administrativelyProhibited, description: ""), -10), (.requestRefused(.ptyRequest), -10),
    ]
    for (error, code) in cases { XCTAssertEqual(error.dmsCode, code, "\(error)") }
    XCTAssertEqual(ChannelExit.status(0).dmsKind, 0)
    XCTAssertEqual(ChannelExit.signal(name: "TERM", coreDumped: false, message: "").dmsKind, 1)
    XCTAssertEqual(ChannelExit.lost.dmsKind, 2)
    XCTAssertEqual(ChannelExit.refused.dmsKind, 3)
  }

  func testErrorTexts() {
    XCTAssertEqual("\(SSHError.timedOut(.directAnswer))", "the login")
    XCTAssertEqual("\(SSHError.timedOut(.keepalive))", "the host stopped answering")
    XCTAssertEqual("\(SSHError.closed(.byServer(.byApplication, description: "bye")))", "disconnected by the server: bye")
    XCTAssertEqual("\(SSHError.requestRefused(.ptyRequest))", "the server refused the terminal (pty-req)")
    XCTAssertEqual("\(SSHError.protocolViolation(.malformed(.kexInit, .truncated)))", "malformed KEXINIT: truncated")
    XCTAssertEqual("\(SSHError.protocolViolation(.negotiation(.cipherRequiresStrictKex(.chacha20Poly1305))))",
                   "chacha20-poly1305@openssh.com needs strict key exchange, which the server did not offer")
  }

  func testDisconnectReasonsTheClientSends() {
    XCTAssertEqual(SSHError.protocolViolation(.packet(.integrity)).disconnectReason, .macError)
    XCTAssertEqual(SSHError.protocolViolation(.channel(.windowExceeded)).disconnectReason, .protocolError)
    XCTAssertEqual(SSHError.protocolViolation(.negotiation(.noCommonAlgorithm(.cipher))).disconnectReason, .keyExchangeFailed)
    XCTAssertEqual(SSHError.hostKeyChangedAtRekey(.differentKey).disconnectReason, .hostKeyNotVerifiable)
    XCTAssertEqual(SSHError.closed(.byClient).disconnectReason, .byApplication)
    XCTAssertEqual(SSHError.timedOut(.keepalive).disconnectReason, .connectionLost)
  }

  func testDisplayTextIsSafeToShow() {
    XCTAssertEqual(DisplayText.sanitize(Array("bye\u{1B}[2J\r\nnow".utf8)), "bye [2J now")
    XCTAssertEqual(DisplayText.sanitize(Array("a\u{202E}b\u{200B}c".utf8)), "a b c")
    XCTAssertEqual(DisplayText.sanitize([0x66, 0xFF, 0x6F]), "f o")
    XCTAssertEqual(DisplayText.sanitize(Array("   ".utf8)), "")
    XCTAssertEqual(DisplayText.sanitize(Array(String(repeating: "x", count: 300).utf8), limit: 4), "xxxx…")
    XCTAssertEqual(DisplayText.sanitize(Array("ab cd".utf8), limit: 2), "ab…")
  }

  func testServerExtensions() {
    XCTAssertNil(ServerExtensions().serverSignatureAlgorithms)
    XCTAssertEqual(ServerExtensions().rsaAlgorithm, .rsaSHA512)
    func extensions(_ list: String) -> ServerExtensions { ServerExtensions(values: ["server-sig-algs": Array(list.utf8)]) }
    XCTAssertEqual(extensions("ssh-ed25519,rsa-sha2-256").serverSignatureAlgorithms, ["ssh-ed25519", "rsa-sha2-256"])
    XCTAssertEqual(extensions("ssh-ed25519,rsa-sha2-256").rsaAlgorithm, .rsaSHA256)
    XCTAssertEqual(extensions("rsa-sha2-256,rsa-sha2-512").rsaAlgorithm, .rsaSHA512)
    XCTAssertEqual(extensions("ssh-rsa").rsaAlgorithm, .rsaSHA512, "never SHA-1")
    XCTAssertEqual(extensions("").serverSignatureAlgorithms, [])
    XCTAssertNil(extensions("a,,b").serverSignatureAlgorithms)
  }

  func testAuthMethods() {
    let methods = AuthMethods(names: ["publickey", "gssapi-with-mic", "keyboard-interactive"])
    XCTAssertEqual(methods, [.publicKey, .keyboardInteractive])
    XCTAssertEqual(methods.rawValue, 6, "DMS_METHOD_* bits")
    XCTAssertEqual(methods.names, ["publickey", "keyboard-interactive"])
    XCTAssertEqual(Credential.password(SecretBytes(utf8: "x")).method, .password)
  }

  func testConnectOptions() {
    XCTAssertNoThrow(try ConnectOptions(host: "devbox.example.test").validate())
    XCTAssertNoThrow(try ConnectOptions(host: "devbox.example.test", keepaliveInterval: nil, keepaliveCountMax: 0).validate())
    let invalid: [ConnectOptions] = [
      ConnectOptions(host: ""), ConnectOptions(host: "h", port: 0), ConnectOptions(host: "h", handshakeTimeout: .zero),
      ConnectOptions(host: "h", keepaliveCountMax: 0), ConnectOptions(host: "h", keepaliveCountMax: Limits.keepaliveCountMax + 1),
      ConnectOptions(host: "h", keepaliveInterval: .seconds(-1)), ConnectOptions(host: "h", directAnswer: .zero),
      ConnectOptions(host: "h", algorithms: .init(keyExchange: [], hostKey: [.ed25519], cipher: [.aes256GCM], mac: [])),
      ConnectOptions(host: "h", algorithms: .init(keyExchange: [.curve25519], hostKey: [.ed25519], cipher: [.aes256CTR], mac: [])),
    ]
    for options in invalid {
      do {
        try options.validate()
        XCTFail("\(options)")
      } catch {
        guard case .usage(.invalidArgument) = error else { return XCTFail("\(error)") }
      }
    }
  }

  func testSystemRandom() throws {
    let random = SystemRandom()
    let a = try random.bytes(32), b = try random.bytes(32)
    XCTAssertEqual(a.count, 32)
    XCTAssertNotEqual(a, b)
    XCTAssertEqual(try random.secret(16).count, 16)
    XCTAssertEqual(try random.bytes(0), [])
    // The seeded source repeats itself.
    XCTAssertEqual(try SeededRandom(seed: 7).bytes(16), try SeededRandom(seed: 7).bytes(16))
  }

  func testTheFakeLinkKeepsTheSendRules() throws {
    let link = FakeTransportLink()
    try link.send([5] + Raw.string("ssh-userauth"))
    try link.send(secret: SecretBytes(copying: [50, 1, 2]))
    XCTAssertEqual(link.sent.count, 2)
    XCTAssertEqual(link.secretIndices, [1])
    for payload in [[UInt8](), [20], [1], [4], [80], [81], [128]] {
      XCTAssertThrows(SSHError.usage(.invalidArgument("a message the layers above may not send"))) { () throws(SSHError) in
        try link.send(payload)
      }
    }
    link.end(.protocolViolation(.channel(.windowOverflow)))
    link.end(.closed(.byClient))
    XCTAssertEqual(link.endedWith, .protocolViolation(.channel(.windowOverflow)), "the first end wins")
    XCTAssertFalse(link.isOpen)
    XCTAssertThrows(SSHError.closed(.alreadyEnded)) { () throws(SSHError) in try link.send([94]) }
  }
}
