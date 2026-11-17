/// SSH_MSG_KEXINIT (RFC 4253 §7.1): a 16-byte cookie, ten name-lists, `first_kex_packet_follows`, a reserved uint32.
struct KexInit: Equatable {
  var cookie: [UInt8]
  var keyExchange: [String]
  var hostKey: [String]
  var cipherClientToServer: [String]
  var cipherServerToClient: [String]
  var macClientToServer: [String]
  var macServerToClient: [String]
  var compressionClientToServer: [String]
  var compressionServerToClient: [String]
  var languageClientToServer: [String]
  var languageServerToClient: [String]
  var firstKexPacketFollows: Bool
  var reserved: UInt32

  static let cookieBytes = 16

  /// The client's KEXINIT for `preferences`. The first one ends its key exchange list with `ext-info-c` and the strict
  /// signal; a re-exchange's offers the same algorithms without them (both signals count only in the first KEXINIT:
  /// RFC 8308 §2.1 and OpenSSH's PROTOCOL; a server that saw ext-info-c again might send an EXT_INFO the policy refuses).
  static func client(_ preferences: AlgorithmPolicy.Preferences, cookie: [UInt8], initial: Bool) -> KexInit {
    let ciphers = preferences.cipher.map(\.rawValue)
    // An AEAD cipher ignores the MAC list (as OpenSSH does); it is sent as configured either way.
    let macs = preferences.mac.map(\.rawValue)
    return KexInit(
      cookie: cookie,
      keyExchange: initial ? preferences.keyExchangeNames : preferences.keyExchange.map(\.rawValue),
      hostKey: preferences.hostKey.map(\.rawValue),
      cipherClientToServer: ciphers, cipherServerToClient: ciphers,
      macClientToServer: macs, macServerToClient: macs,
      compressionClientToServer: AlgorithmPolicy.Preferences.compressionNames,
      compressionServerToClient: AlgorithmPolicy.Preferences.compressionNames,
      languageClientToServer: [], languageServerToClient: [],
      firstKexPacketFollows: false, reserved: 0)
  }

  /// The payload, message number first.
  func encoded() throws(SSHError) -> [UInt8] {
    var writer = WireWriter(.kexInit, capacity: 1024)
    writer.writeBytes(cookie)
    for list in lists { writer.writeNameList(list) }
    writer.writeBoolean(firstKexPacketFollows)
    writer.writeUInt32(reserved)
    do { return try writer.finish() } catch { throw .protocolViolation(.malformed(.kexInit, error)) }
  }

  private var lists: [[String]] {
    [keyExchange, hostKey, cipherClientToServer, cipherServerToClient, macClientToServer, macServerToClient,
     compressionClientToServer, compressionServerToClient, languageClientToServer, languageServerToClient]
  }
}

// In an extension, so the struct keeps its memberwise initializer.
extension KexInit {
  /// The server's KEXINIT payload, every list within `Limits.nameListBytes` and `Limits.nameListCount`. Names the
  /// engine does not know are kept (they never match).
  init(decoding payload: [UInt8]) throws(SSHError) {
    do {
      self = try WireReader.decode(payload) { (reader: inout WireReader) throws(WireError) -> KexInit in
        guard try reader.readMessageNumber() == .kexInit else { throw .invalidValue }
        let cookie = try reader.readBytes(count: Self.cookieBytes)
        var lists: [[String]] = []
        for _ in 0..<10 { lists.append(try reader.readNameList()) }
        return KexInit(
          cookie: cookie, keyExchange: lists[0], hostKey: lists[1], cipherClientToServer: lists[2],
          cipherServerToClient: lists[3], macClientToServer: lists[4], macServerToClient: lists[5],
          compressionClientToServer: lists[6], compressionServerToClient: lists[7], languageClientToServer: lists[8],
          languageServerToClient: lists[9], firstKexPacketFollows: try reader.readBoolean(), reserved: try reader.readUInt32())
      }
    } catch {
      throw .protocolViolation(.malformed(.kexInit, error))
    }
  }
}

/// Algorithm negotiation (RFC 4253 §7.1): in each category the first of the client's algorithms the server also
/// lists. Every supported method needs a signature-capable host key, which every supported host key algorithm is, so
/// the key exchange method is simply the first common one. A MAC is negotiated only for a CTR cipher. Compression
/// must be `none` both ways. `first_kex_packet_follows` is refused (no supported method lets a server guess first).
enum Negotiation {
  /// `strict` and the EXT_INFO signal come from the first exchange's KEXINITs and are passed in for later ones.
  static func negotiate(_ preferences: AlgorithmPolicy.Preferences, server: KexInit, strict: Bool,
                        serverSendsExtInfo: Bool) throws(SSHError) -> NegotiatedAlgorithms {
    guard !server.firstKexPacketFollows else { throw .protocolViolation(.negotiation(.firstKexPacketFollows)) }
    func first<T: RawRepresentable>(_ ours: [T], in theirs: [String], _ category: ProtocolViolation.AlgorithmCategory)
      throws(SSHError) -> T where T.RawValue == String
    {
      guard let match = ours.first(where: { theirs.contains($0.rawValue) }) else {
        throw .protocolViolation(.negotiation(.noCommonAlgorithm(category)))
      }
      return match
    }
    func direction(ciphers: [String], macs: [String], compression: [String]) throws(SSHError) -> NegotiatedAlgorithms.Direction {
      let cipher = try first(preferences.cipher, in: ciphers, .cipher)
      let mac: MACAlgorithm? = cipher.isAEAD ? nil : try first(preferences.mac, in: macs, .mac)
      guard compression.contains("none") else { throw .protocolViolation(.negotiation(.noCommonAlgorithm(.compression))) }
      return .init(cipher: cipher, mac: mac)
    }
    let keyExchange = try first(preferences.keyExchange, in: server.keyExchange, .keyExchange)
    let hostKey = try first(preferences.hostKey, in: server.hostKey, .hostKey)
    let clientToServer = try direction(ciphers: server.cipherClientToServer, macs: server.macClientToServer,
                                       compression: server.compressionClientToServer)
    let serverToClient = try direction(ciphers: server.cipherServerToClient, macs: server.macServerToClient,
                                       compression: server.compressionServerToClient)
    return NegotiatedAlgorithms(keyExchange: keyExchange, hostKey: hostKey, clientToServer: clientToServer,
                                serverToClient: serverToClient, strictKex: strict, serverSendsExtInfo: serverSendsExtInfo)
  }
}
