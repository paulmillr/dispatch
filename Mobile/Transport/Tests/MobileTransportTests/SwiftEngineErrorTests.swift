#if DISPATCH_RUSSH
import DispatchMobileSSHCore
#endif
import Foundation
@testable import MobileTransport
import SSHEngine
import XCTest

/// Every `SSHError` as the package's error, against what `RusshEngine.error` makes of russh's code and text for the
/// same condition: equal, or (where the texts come from each engine's own code) the same case. The exceptions are
/// listed in `differences`. Without `DISPATCH_RUSSH` (no russh in the build) the Swift engine's side alone: each error
/// against the case and text russh gave, which the rows keep.
final class SwiftEngineErrorTests: XCTestCase {
  private struct Row {
    let error: SSHError
    let expected: SSHTransportError
    /// russh's code and text for the same condition.
    let russh: (code: Int32, text: String)
    /// russh's text is this engine's too (else only the case must match).
    var sameText = true
  }

  private static var rows: [Row] {
    func same(_ error: SSHError, _ expected: SSHTransportError, text: String? = nil) -> Row {
      Row(error: error, expected: expected, russh: (error.dmsCode, text ?? error.description))
    }
    func caseOnly(_ error: SSHError, _ expected: SSHTransportError, code: Int32? = nil, russh text: String) -> Row {
      Row(error: error, expected: expected, russh: (code ?? error.dmsCode, text), sameText: false)
    }
    let endpoint = (host: "", port: 0)
    var rows: [Row] = [
      same(.hostNotFound, .connectFailed(.hostNotFound, host: endpoint.host, port: endpoint.port), text: "failed to lookup address information"),
      same(.connectionRefused, .connectFailed(.refused, host: "", port: 0), text: "Connection refused (os error 61)"),
      same(.unreachable, .connectFailed(.unreachable, host: "", port: 0), text: "No route to host (os error 65)"),
      same(.noAnswer, .connectFailed(.noAnswer, host: "", port: 0), text: "connection timed out"),
      same(.network("Operation not permitted"), .network("Operation not permitted")),
      same(.timedOut(.lookup), .timedOut("looking up the host's address")),
      same(.timedOut(.handshake), .timedOut("the SSH handshake")),
      same(.timedOut(.keepalive), .timedOut("the host stopped answering")),
      same(.timedOut(.directAnswer), .timedOut("the login")),
      // russh's rejected-key code has no mapping of its own: its text, as a protocol error.
      same(.hostKeyRejected, .protocolError("Unknown server key"), text: "Unknown server key"),
      same(.hostKeyChangedAtRekey(.differentKey),
           .hostKeyChangedAtRekey("the server presented a different host key at a key re-exchange")),
      same(.hostKeyChangedAtRekey(.differentAlgorithm(trusted: .rsaSHA512, presented: .rsaSHA256)),
           .hostKeyChangedAtRekey("the host key algorithm changed at a key re-exchange (rsa-sha2-512, now rsa-sha2-256)")),
      caseOnly(.protocolViolation(.packet(.integrity)), .protocolError("packet: integrity"), russh: "Wrong packet authentication code"),
      // A server offering nothing acceptable is final on both engines, with one sentence (russh 0.65's text mapped).
      same(.protocolViolation(.negotiation(.noCommonAlgorithm(.keyExchange))), .noCommonAlgorithm("key exchange"),
           text: "No common Kex algorithm - ours: [\"curve25519-sha256\"], theirs: [\"diffie-hellman-group1-sha1\"]"),
      caseOnly(.protocolViolation(.keyExchange(.hostKeyCertificate)), .protocolError("key exchange: hostKeyCertificate"),
               russh: "Unknown server key"),
      caseOnly(.protocolViolation(.channel(.maximumPacketTooSmall)), .protocolError("channel: maximumPacketTooSmall"),
               russh: "Failed to open channel (ConnectFailed)"),
      same(.cancelled, .cancelled),
      same(.invalidKey("Ed25519 signatures are 64 bytes"), .invalidKey("Ed25519 signatures are 64 bytes")),
      same(.wrongPassphrase, .wrongPassphrase, text: "the passphrase is wrong"),
      same(.unsupported("external signing for ssh-rsa is unsupported"), .unsupportedAuthentication("external signing for ssh-rsa is unsupported")),
      // russh reports a refused channel open as a protocol error (DMS_PROTOCOL), not as DMS_REFUSED, which `dmsCode` names.
      caseOnly(.channelOpenFailed(.administrativelyProhibited, description: "no more sessions"),
               .protocolError(SSHError.channelOpenFailed(.administrativelyProhibited, description: "no more sessions").description),
               code: -4, russh: "Failed to open channel (AdministrativelyProhibited)"),
      same(.requestRefused(.ptyRequest), .commandFailed(status: -1, stderr: "the server refused the terminal (pty-req)")),
      same(.requestRefused(.shell), .commandFailed(status: -1, stderr: "the server refused the shell request")),
    ]
    for reason in [SSHError.CloseReason.byClient, .byServer(.byApplication, description: "bye"), .connectionLost, .alreadyEnded,
                   .channelClosed] {
      rows.append(same(.closed(reason), .channelClosed, text: "the connection was reset"))
    }
    for usage in [SSHError.UsageError.notAuthenticated, .alreadyAuthenticated, .authenticationInProgress, .tooManyChannels,
                  .invalidArgument("port 0"), .channelClosed] {
      rows.append(caseOnly(.usage(usage), .protocolError(SSHError.usage(usage).description), russh: "invalid arguments"))
    }
    return rows
  }

  /// The engine's case names, from a switch the compiler holds exhaustive: a new case fails this file until mapped.
  private static func name(_ error: SSHError) -> String {
    switch error {
    case .hostNotFound: "hostNotFound"
    case .connectionRefused: "connectionRefused"
    case .unreachable: "unreachable"
    case .noAnswer: "noAnswer"
    case .network: "network"
    case .timedOut: "timedOut"
    case .hostKeyRejected: "hostKeyRejected"
    case .hostKeyChangedAtRekey: "hostKeyChangedAtRekey"
    case .protocolViolation: "protocolViolation"
    case .closed: "closed"
    case .cancelled: "cancelled"
    case .invalidKey: "invalidKey"
    case .wrongPassphrase: "wrongPassphrase"
    case .unsupported: "unsupported"
    case .channelOpenFailed: "channelOpenFailed"
    case .requestRefused: "requestRefused"
    case .usage: "usage"
    }
  }

  private static func name(_ error: SSHTransportError) -> String {
    String(String(describing: error).prefix { $0 != "(" })
  }

  func testEveryEngineErrorMapsAsRusshDoes() {
    let rows = Self.rows
    XCTAssertEqual(Set(rows.map { Self.name($0.error) }).count, 17, "every case of SSHError has a row")
    for row in rows {
      XCTAssertEqual(row.error.transportError, row.expected, "\(row.error)")
      #if DISPATCH_RUSSH
      let russh = row.russh.text.withCString { RusshEngine.error(row.russh.code, $0) }
      if row.sameText {
        XCTAssertEqual(russh, row.expected, "russh for \(row.error)")
        XCTAssertEqual(row.russh.code, row.error.dmsCode)
      } else {
        XCTAssertEqual(Self.name(russh), Self.name(row.expected), "russh's case for \(row.error)")
      }
      // The app retries the same conditions on both engines.
      XCTAssertEqual(HostConnectionPolicy.refused(row.expected), HostConnectionPolicy.refused(russh), "\(row.error)")
      #endif
    }
  }

  /// The texts the seam quotes, as the user reads them.
  func testTheTextsTheAppShows() {
    XCTAssertEqual(SSHError.timedOut(.lookup).transportError.errorDescription, "Timed out: looking up the host's address.")
    XCTAssertEqual(SSHError.timedOut(.handshake).transportError.errorDescription, "Timed out: the SSH handshake.")
    XCTAssertEqual(SSHError.noAnswer.transportError, .connectFailed(.noAnswer, host: "", port: 0))
    XCTAssertEqual(SSHError.timedOut(.keepalive).transportError.errorDescription, "Timed out: the host stopped answering.")
    XCTAssertEqual(SSHError.timedOut(.directAnswer).transportError, .timedOut("the login"))
    XCTAssertEqual(SwiftEngineBridge.exit(.refused), .refused("the server refused the exec request"))
  }

  /// Key files: a passphrase problem, an unreadable file and a refusal stay apart; every refusal is `invalidKey` and
  /// reads as one sentence ("Invalid private key: …."): what is refused, then (where the engine refuses on purpose
  /// something the user can change) what to do about it.
  func testKeyFileErrors() {
    XCTAssertEqual(SSHError.wrongPassphrase.keyFileError, .wrongPassphrase)
    for problem in KeyFileProblem.allCases {
      XCTAssertEqual(problem.error.keyFileError, .invalidKey(problem.rawValue))
    }
    for refusal in KeyFileRefusal.allCases {
      let error = refusal.error.keyFileError
      guard case .invalidKey(let reason) = error, let text = error.errorDescription else {
        XCTFail("\(refusal): \(error)")
        continue
      }
      XCTAssertTrue(text.hasPrefix("Invalid private key: ") && text.hasSuffix("."), text)
      XCTAssertEqual(text.filter { $0 == "." }.count, refusal == .puttyKey ? 2 : 1, "one sentence: \(text)")
      switch refusal {
      case .puttyKey:
        XCTAssertTrue(reason.contains("PuTTYgen") && reason.contains("Export OpenSSH key"), reason)
      case .encryptedPEM, .encryptedPKCS8, .cipher, .kdf, .bcryptRounds:
        XCTAssertTrue(reason.hasPrefix(refusal.rawValue.prefix(12)), reason)
        XCTAssertTrue(reason.contains("ssh-keygen -p -f <file>") && reason.hasSuffix("import it again"), reason)
      case .rsaKeySize, .dsa, .securityKey, .keyType:
        XCTAssertTrue(reason.contains("ssh-keygen -t ed25519") && reason.hasSuffix("add it to the host"), reason)
      case .certificate, .publicKey, .foreignFormat:
        XCTAssertEqual(reason, refusal.rawValue)
      }
      XCTAssertTrue(HostConnectionPolicy.refused(error), "\(refusal): final, as a bad key is")
    }
    XCTAssertEqual(KeyFileRefusal.rsaKeySize.transportError.errorDescription,
                   "Invalid private key: RSA keys must have 2048 to 16384 bits; make a new key, such as with “ssh-keygen -t ed25519”, and add it to the host.")
    XCTAssertEqual(KeyFileRefusal.bcryptRounds.transportError.errorDescription,
                   "Invalid private key: the key file asks for more than 1024 bcrypt rounds; run “ssh-keygen -p -f <file>” on it, which saves it with ssh-keygen’s default rounds, and import it again.")
  }

  /// A throwaway key (`ssh-keygen -t ecdsa -b 256 -m PKCS8`, explicit curve parameters, never used anywhere): the Swift
  /// engine reads it, russh does not ("Spki: ASN.1 error"), so parsing it tells which engine ran.
  static let pkcs8ECDSA = Data("""
    -----BEGIN PRIVATE KEY-----
    MIIBeQIBADCCAQMGByqGSM49AgEwgfcCAQEwLAYHKoZIzj0BAQIhAP////8AAAAB
    AAAAAAAAAAAAAAAA////////////////MFsEIP////8AAAABAAAAAAAAAAAAAAAA
    ///////////////8BCBaxjXYqjqT57PrvVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMV
    AMSdNgiG5wSTamZ44ROdJreBn36QBEEEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg
    9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9QIhAP////8A
    AAAA//////////+85vqtpxeehPO5ysL8YyVRAgEBBG0wawIBAQQgiGjqjaJcKVJ1
    TV4cK7zts0GR8lOxVb5xAptiAeV3dZ6hRANCAAR3amRQUNhzv5Ailz5LYkWRjcL2
    iuhvyIX2IbMRMuDLHs6WrcRn6r2E+8cMyIbkXV9+VJzLvN8yFkK+z3PFOwi8
    -----END PRIVATE KEY-----

    """.utf8)

  /// The `.swift` engine is the adapter over the driver, for connections and key files alike, and the default. A key
  /// file only it reads parses there (and not on russh, in a `DISPATCH_RUSSH` build), and a connect to a closed
  /// loopback port fails as the seam says, from its own socket.
  func testTheSwiftEngineRunsConnectionsAndKeyFiles() async throws {
    XCTAssertTrue(try SSHTransportEngine.swift.backend is SwiftEngine)
    XCTAssertEqual(SSHTransportEngine.standard, .swift)
    XCTAssertEqual(SSHTransportEngine.preferred, SSHTransportEngine.environmentChoice ?? .swift, "the Swift engine unless chosen")
    let previous = SSHTransportEngine.preferred
    defer { SSHTransportEngine.preferred = previous }
    #if DISPATCH_RUSSH
    XCTAssertEqual(SSHTransportEngine.allCases, [.swift, .russh])
    XCTAssertTrue(try SSHTransportEngine.russh.backend is RusshEngine)
    SSHTransportEngine.preferred = .russh
    XCTAssertThrowsError(try SSHKey.openSSH(Self.pkcs8ECDSA), "russh does not read this PKCS#8 file")
    #else
    XCTAssertEqual(SSHTransportEngine.allCases, [.swift], "russh is built in only with DISPATCH_RUSSH=1")
    XCTAssertNil(SSHTransportEngine(rawValue: "russh"))
    #endif
    SSHTransportEngine.preferred = .swift
    XCTAssertEqual(try SSHKey.openSSH(Self.pkcs8ECDSA).publicKey,
                   "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBHdqZFBQ2HO/kCKXPktiRZGNwvaK6G/IhfYhsxEy4MsezpatxGfqvYT7xwzIhuRdX35UnMu83zIWQr7Pc8U7CLw=")
    XCTAssertThrowsError(try SSHKey.openSSH(Data("not a key".utf8))) {
      XCTAssertEqual($0 as? SSHTransportError, .invalidKey(KeyFileProblem.notAKey.rawValue))
    }
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                              sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0
      }
    }
    Darwin.close(listener)  // Bound, never listening, now closed: nothing accepts on the port.
    XCTAssertTrue(bound)
    let port = Int(UInt16(bigEndian: address.sin_port))
    do {
      _ = try await SSHConnection.connect(to: SSHEndpoint(host: "127.0.0.1", port: port, username: "sam"), credentials: [],
                                          trust: TrustOnFirstUse { _ in false })
      XCTFail("connected to a closed port")
    } catch {
      XCTAssertEqual(error as? SSHTransportError, .connectFailed(.refused, host: "127.0.0.1", port: port))
    }
  }
}
