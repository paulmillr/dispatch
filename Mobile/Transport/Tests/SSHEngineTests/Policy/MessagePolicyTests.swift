import SSHEngine
import XCTest

/// The message policy as a table: for each phase, exactly the numbers accepted (all 256 are tried) and where they go.
final class MessagePolicyTests: XCTestCase {
  typealias Context = MessagePolicy.Context

  static func connected(_ service: MessagePolicy.ServicePhase, first: Bool = false, extInfo: Int = 0,
                        transport: MessagePolicy.TransportPhase = .established) -> Context {
    Context(transport: transport, service: service, firstPacketAfterNewKeys: first, extInfoReceived: extInfo)
  }

  /// Every phase shape, for the table and the mutation loop.
  static let contexts: [Context] = {
    var contexts: [Context] = [Context(transport: .awaitingFirstKexInit)]
    for stage in [MessagePolicy.KeyExchangeStage.awaitingReply, .awaitingNewKeys] {
      contexts += [Context(transport: .initialExchange(stage, strict: true)),
                   Context(transport: .initialExchange(stage, strict: false)),
                   MessagePolicyTests.connected(.connection, transport: .reexchange(stage))]
    }
    let waits: [MessagePolicy.UserauthWait] = [.idle, .noneMethod, .password, .publicKeyQuery, .publicKeySigned,
                                               .keyboardInteractive]
    let services: [MessagePolicy.ServicePhase] = [.serviceNotRequested, .serviceRequested, .connection]
      + waits.map { .userauth($0) }
    for transport in [MessagePolicy.TransportPhase.established, .rekeyRequested] {
      for service in services {
        for (first, extInfo) in [(true, 0), (false, 0), (false, 1), (false, 2)] {
          contexts.append(MessagePolicyTests.connected(service, first: first, extInfo: extInfo, transport: transport))
        }
      }
    }
    return contexts
  }()

  func accepted(_ context: Context) -> Set<UInt8> {
    Set((0...255).map(UInt8.init).filter { MessagePolicy.route(for: MessageNumber($0), in: context) != nil })
  }

  /// Transport generics after the initial exchange, and the global replies the keepalive owns.
  let generics: Set<UInt8> = [1, 2, 3, 4, 20, 81, 82]

  func testInitialExchange() {
    XCTAssertEqual(accepted(Context(transport: .awaitingFirstKexInit)), [1, 2, 4, 20])
    XCTAssertEqual(accepted(Context(transport: .initialExchange(.awaitingReply, strict: true))), [1, 31])
    XCTAssertEqual(accepted(Context(transport: .initialExchange(.awaitingNewKeys, strict: true))), [1, 21])
    XCTAssertEqual(accepted(Context(transport: .initialExchange(.awaitingReply, strict: false))), [1, 2, 4, 31])
    XCTAssertEqual(accepted(Context(transport: .initialExchange(.awaitingNewKeys, strict: false))), [1, 2, 4, 21])
  }

  func testAReexchangeStopsTheUpperLayers() {
    for service in [MessagePolicy.ServicePhase.connection, .userauth(.publicKeySigned), .serviceRequested] {
      XCTAssertEqual(accepted(MessagePolicyTests.connected(service, transport: .reexchange(.awaitingReply))), [1, 2, 3, 4, 31])
      XCTAssertEqual(accepted(MessagePolicyTests.connected(service, transport: .reexchange(.awaitingNewKeys))), [1, 2, 3, 4, 21])
    }
  }

  func testServiceRequest() {
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.serviceNotRequested, first: true)), generics.union([7]))
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.serviceNotRequested)), generics)
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.serviceRequested, first: true)), generics.union([6, 7]))
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.serviceRequested)), generics.union([6]))
    // The first packet after NEWKEYS, but an EXT_INFO already came: not a second one here.
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.serviceRequested, first: true, extInfo: 1)), generics.union([6]))
  }

  func testUserauth() {
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.userauth(.idle))), generics.union([53]))
    let answers: Set<UInt8> = [7, 51, 52, 53]
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.userauth(.noneMethod))), generics.union(answers))
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.userauth(.publicKeySigned), extInfo: 1)), generics.union(answers))
    for wait in [MessagePolicy.UserauthWait.password, .publicKeyQuery, .keyboardInteractive] {
      XCTAssertEqual(accepted(MessagePolicyTests.connected(.userauth(wait), extInfo: 1)), generics.union(answers).union([60]), "\(wait)")
    }
    // Never a third EXT_INFO.
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.userauth(.publicKeySigned), extInfo: 2)), generics.union([51, 52, 53]))
  }

  func testConnection() {
    let channels = Set<UInt8>(90...100)
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.connection)), generics.union([80]).union(channels))
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.connection, transport: .rekeyRequested)), generics.union([80]).union(channels))
    XCTAssertEqual(accepted(MessagePolicyTests.connected(.connection, first: true)), generics.union([80]).union(channels), "no EXT_INFO")
  }

  func testNothingReservedOrUnknownIsEverAccepted() {
    let neverAccepted = Set<UInt8>([0, 5, 8, 30] + Array(9...19) + Array(22...29) + Array(32...49) + [50] + Array(54...59)
      + Array(61...79) + Array(83...89) + Array(101...255))
    for context in Self.contexts {
      XCTAssertTrue(accepted(context).isDisjoint(with: neverAccepted), "\(context)")
    }
  }

  func testRoutes() {
    let connection = MessagePolicyTests.connected(.connection)
    for number: UInt8 in [1, 2, 3, 4, 20, 80, 81, 82] {
      XCTAssertEqual(MessagePolicy.route(for: MessageNumber(number), in: connection), .transport, "\(number)")
    }
    for number in 90...100 {
      XCTAssertEqual(MessagePolicy.route(for: MessageNumber(UInt8(number)), in: connection), .service)
    }
    let userauth = MessagePolicyTests.connected(.userauth(.keyboardInteractive))
    for number: UInt8 in [51, 52, 53, 60] { XCTAssertEqual(MessagePolicy.route(for: MessageNumber(number), in: userauth), .service) }
    XCTAssertEqual(MessagePolicy.route(for: .extInfo, in: userauth), .transport)
    XCTAssertEqual(MessagePolicy.route(for: .serviceAccept, in: MessagePolicyTests.connected(.serviceRequested)), .service)
    XCTAssertEqual(MessagePolicy.route(for: .kexECDHReply, in: Context(transport: .initialExchange(.awaitingReply, strict: true))), .transport)
  }

  func testRejectionsSayWhatAndWhere() {
    let context = MessagePolicyTests.connected(.userauth(.publicKeySigned), extInfo: 1)
    XCTAssertThrows(SSHError.protocolViolation(.unexpectedMessage(.userauthPKOK, context))) { () throws(SSHError) in
      try MessagePolicy.check(.userauthPKOK, in: context)
    }
    XCTAssertThrows(SSHError.protocolViolation(.tooManyExtInfo)) { () throws(SSHError) in
      try MessagePolicy.check(.extInfo, in: MessagePolicyTests.connected(.userauth(.publicKeySigned), extInfo: 2))
    }
    XCTAssertEqual(try MessagePolicy.check(.channelData, in: MessagePolicyTests.connected(.connection)), .service)
    let strict = Context(transport: .initialExchange(.awaitingReply, strict: true))
    XCTAssertThrows(SSHError.protocolViolation(.unexpectedMessage(.ignore, strict))) { () throws(SSHError) in
      try MessagePolicy.check(.ignore, in: strict)
    }
    XCTAssertEqual("\(SSHError.protocolViolation(.unexpectedMessage(.ignore, strict)))",
                   "unexpected IGNORE (initial key exchange, awaitingReply, strict)")
  }

  func testStrictKexInitMustBeTheFirstPacket() {
    XCTAssertNoThrow(try MessagePolicy.checkFirstKexInit(sequence: 0, strict: true))
    XCTAssertNoThrow(try MessagePolicy.checkFirstKexInit(sequence: 2, strict: false))
    XCTAssertThrows(SSHError.protocolViolation(.strictKeyExchange)) { () throws(SSHError) in
      try MessagePolicy.checkFirstKexInit(sequence: 1, strict: true)
    }
  }

  /// The orders the hostile server of `Core/tests/hostile.rs` sends around a direct login are accepted: EXT_INFO
  /// before or after a held SERVICE_ACCEPT, or both; and the russh engine's "two back to back after NEWKEYS" is
  /// refused at the second (RFC 8308 places the second before USERAUTH_SUCCESS).
  func testDirectLoginOrders() throws {
    let accept = [6] + Raw.string("ssh-userauth")
    let extInfo = [7] + Raw.u32(0)
    for held in [[extInfo, accept], [accept, extInfo], [extInfo, accept, extInfo]] {
      let link = FakeTransportLink()
      var service = MessagePolicy.ServicePhase.serviceRequested
      for payload in held + [[52]] {
        if let message = try link.deliver(payload, service: service) {
          service = message.number == .serviceAccept ? .userauth(.publicKeySigned) : .connection
        }
      }
      XCTAssertEqual(service, .connection)
    }
    let link = FakeTransportLink()
    XCTAssertNil(try link.deliver(extInfo, service: .serviceRequested))
    XCTAssertThrows(SSHError.protocolViolation(.unexpectedMessage(.extInfo, MessagePolicyTests.connected(.serviceRequested, extInfo: 1)))) {
      () throws(SSHError) in try link.deliver(extInfo, service: .serviceRequested)
    }
  }
}
