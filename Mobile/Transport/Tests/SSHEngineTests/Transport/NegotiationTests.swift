import XCTest
@testable import SSHEngine

/// KEXINIT's encoding and decoding, RFC 4253 §7.1 negotiation, and the framer's padding.
final class NegotiationTests: XCTestCase {
  static let small = AlgorithmPolicy.Preferences(keyExchange: [.curve25519], hostKey: [.ed25519], cipher: [.aes256GCM],
                                                 mac: [.hmacSHA256ETM])

  func testTheClientKexInitEncoding() throws {
    let cookie = [UInt8](repeating: 0xC0, count: 16)
    let first = try KexInit.client(Self.small, cookie: cookie, initial: true).encoded()
    let expected: [UInt8] = [20] + cookie
      + Raw.string("curve25519-sha256,ext-info-c,kex-strict-c-v00@openssh.com") + Raw.string("ssh-ed25519")
      + Raw.string("aes256-gcm@openssh.com") + Raw.string("aes256-gcm@openssh.com")
      + Raw.string("hmac-sha2-256-etm@openssh.com") + Raw.string("hmac-sha2-256-etm@openssh.com")
      + Raw.string("none") + Raw.string("none") + Raw.string("") + Raw.string("") + [0] + Raw.u32(0)
    XCTAssertEqual(first, expected)
    let later = KexInit.client(Self.small, cookie: cookie, initial: false)
    XCTAssertEqual(later.keyExchange, ["curve25519-sha256"])
    XCTAssertEqual(try KexInit(decoding: first), KexInit.client(Self.small, cookie: cookie, initial: true))
  }

  func testDecodingRefusals() {
    let valid = (try? KexInit.client(.standard, cookie: [UInt8](repeating: 0, count: 16), initial: true).encoded()) ?? []
    XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexInit, .trailingBytes))) { () throws(SSHError) in
      try KexInit(decoding: valid + [0])
    }
    XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexInit, .truncated))) { () throws(SSHError) in
      try KexInit(decoding: Array(valid.prefix(10)))
    }
    // 129 names in one list.
    let many = (0...Limits.nameListCount).map { "a\($0)" }.joined(separator: ",")
    var payload: [UInt8] = [20] + [UInt8](repeating: 0, count: 16) + Raw.string(many)
    for _ in 0..<9 { payload += Raw.string("none") }
    payload += [0] + Raw.u32(0)
    XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexInit, .tooMany(limit: Limits.nameListCount)))) { () throws(SSHError) in
      try KexInit(decoding: payload)
    }
    // An empty element, a non-printable name, a boolean of 2.
    for list in ["a,,b", "a\u{7F}"] {
      var bad: [UInt8] = [20] + [UInt8](repeating: 0, count: 16) + Raw.string(list)
      for _ in 0..<9 { bad += Raw.string("none") }
      bad += [0] + Raw.u32(0)
      XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexInit, .invalidName))) { () throws(SSHError) in try KexInit(decoding: bad) }
    }
    XCTAssertThrows(SSHError.protocolViolation(.malformed(.kexInit, .invalidBoolean))) { () throws(SSHError) in
      try KexInit(decoding: Array(valid.dropLast(5)) + [2] + Raw.u32(0))
    }
  }

  static func server(kex: [String] = ["curve25519-sha256"], hostKey: [String] = ["ssh-ed25519"],
                     ciphers: [String] = ["aes256-gcm@openssh.com"], macs: [String] = ["hmac-sha2-256"]) -> KexInit {
    KexInit(cookie: [UInt8](repeating: 0, count: 16), keyExchange: kex, hostKey: hostKey, cipherClientToServer: ciphers,
            cipherServerToClient: ciphers, macClientToServer: macs, macServerToClient: macs,
            compressionClientToServer: ["zlib", "none"], compressionServerToClient: ["none"], languageClientToServer: [],
            languageServerToClient: [], firstKexPacketFollows: false, reserved: 0)
  }

  func testTheClientsOrderDecides() throws {
    let server = Self.server(kex: ["ecdh-sha2-nistp256", "sntrup761x25519-sha512@openssh.com", "curve25519-sha256"],
                             hostKey: ["rsa-sha2-256", "ecdsa-sha2-nistp256", "ssh-ed25519"],
                             ciphers: ["aes128-ctr", "chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com"],
                             macs: ["hmac-sha2-512", "hmac-sha2-256-etm@openssh.com"])
    let negotiated = try Negotiation.negotiate(.standard, server: server, strict: true, serverSendsExtInfo: false)
    XCTAssertEqual(negotiated.keyExchange, .curve25519)
    XCTAssertEqual(negotiated.hostKey, .ed25519)
    XCTAssertEqual(negotiated.clientToServer, .init(cipher: .aes256GCM, mac: nil))
    // A CTR cipher gets the client's first common MAC.
    let ctr = AlgorithmPolicy.Preferences(keyExchange: [.ecdhP256], hostKey: [.rsaSHA512, .rsaSHA256], cipher: [.aes128CTR],
                                          mac: [.hmacSHA256ETM, .hmacSHA512])
    let settled = try Negotiation.negotiate(ctr, server: server, strict: true, serverSendsExtInfo: true)
    XCTAssertEqual(settled.hostKey, .rsaSHA256)
    XCTAssertEqual(settled.clientToServer, .init(cipher: .aes128CTR, mac: .hmacSHA256ETM))
    XCTAssertTrue(settled.serverSendsExtInfo)
  }

  func testNoCommonAlgorithm() {
    let cases: [(KexInit, ProtocolViolation.AlgorithmCategory)] = [
      (Self.server(kex: ["diffie-hellman-group1-sha1", "ext-info-s", "kex-strict-s-v00@openssh.com"]), .keyExchange),
      (Self.server(hostKey: ["ssh-rsa", "ssh-dss", "ssh-ed25519-cert-v01@openssh.com"]), .hostKey),
      (Self.server(ciphers: ["aes128-cbc"]), .cipher),
      (Self.server(ciphers: ["aes128-ctr"], macs: ["hmac-sha1", "umac-64@openssh.com"]), .mac),
    ]
    for (server, category) in cases {
      XCTAssertThrows(SSHError.protocolViolation(.negotiation(.noCommonAlgorithm(category)))) { () throws(SSHError) in
        try Negotiation.negotiate(.standard, server: server, strict: true, serverSendsExtInfo: false)
      }
    }
    var follows = Self.server()
    follows.firstKexPacketFollows = true
    XCTAssertThrows(SSHError.protocolViolation(.negotiation(.firstKexPacketFollows))) { () throws(SSHError) in
      try Negotiation.negotiate(.standard, server: follows, strict: true, serverSendsExtInfo: false)
    }
  }

  /// Every payload size pads to the alignment with at least 4 bytes and at most a block more, in each family.
  func testPadding() throws {
    let sealers: [any PacketSealer] = [PlaintextSealer()] + (try PacketProtectionTests.families.map {
      try PacketProtection.sealer(cipher: $0.0, mac: $0.1, keys: PacketProtectionTests.keys($0.0, $0.1, seed: 1))
    })
    for sealer in sealers {
      var framer = OutboundFramer()
      framer.install(sealer)
      for size in 0..<200 {
        let (length, padding) = framer.packetBytes(payload: size)
        XCTAssertEqual(length, 1 + size + padding)
        XCTAssertGreaterThanOrEqual(padding, Limits.minimumPadding)
        XCTAssertLessThan(padding, Limits.minimumPadding + sealer.blockBytes)
        XCTAssertEqual(((sealer.lengthIsAligned ? 4 : 0) + length) % sealer.blockBytes, 0)
      }
    }
  }
}
