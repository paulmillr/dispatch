import CryptoKit
import XCTest
@testable import SSHEngine

/// A user key whose private half the test holds (CryptoKit), so the signature the core asked for is made by hand and
/// verified with CryptoKit. Fictional keys from fixed seeds. The core never calls `sign` (the driver would): tests
/// answer `AuthEvent.sign` with `signatureBlob(for:)`.
enum TestKey: UserKey {
  case ed(Curve25519.Signing.PrivateKey)
  case ecdsa(P256.Signing.PrivateKey)
  /// An RSA key the test cannot sign with (the real one is Keys/): a fixed blob and a placeholder signature.
  case rsa

  static let ed25519 = TestKey.ed(try! Curve25519.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: 0x42, count: 32)))
  static let otherEd25519 = TestKey.ed(try! Curve25519.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: 0x43, count: 32)))
  static let p256 = TestKey.ecdsa(try! P256.Signing.PrivateKey(rawRepresentation: [UInt8](repeating: 0x24, count: 32)))

  var publicKeyBlob: [UInt8] {
    switch self {
    case .ed(let key): Raw.string("ssh-ed25519") + Raw.string(Array(key.publicKey.rawRepresentation))
    case .ecdsa(let key):
      Raw.string("ecdsa-sha2-nistp256") + Raw.string("nistp256") + Raw.string(Array(key.publicKey.x963Representation))
    case .rsa: Fixture.rsaBlob
    }
  }

  var algorithm: SignatureAlgorithm {
    switch self {
    case .ed: .ed25519
    case .ecdsa: .ecdsaP256
    case .rsa: .rsaSHA512
    }
  }

  func sign(_ data: [UInt8], algorithm: SignatureAlgorithm) async throws(SSHError) -> [UInt8] {
    signatureBlob(for: data, algorithm: algorithm)
  }

  /// The signature blob over `data` (RFC 4253 §6.6; ECDSA's inner encoding RFC 5656 §3.1.2).
  func signatureBlob(for data: [UInt8], algorithm: SignatureAlgorithm? = nil) -> [UInt8] {
    switch self {
    case .ed(let key):
      return Raw.string("ssh-ed25519") + Raw.string(Array(try! key.signature(for: data)))
    case .ecdsa(let key):
      let raw = Array(try! key.signature(for: data).rawRepresentation)
      return Raw.string("ecdsa-sha2-nistp256") + Raw.string(try! ECDSASignature.inner(fromRaw: raw, curve: .p256))
    case .rsa:
      return Raw.string((algorithm ?? .rsaSHA512).rawValue) + Raw.string([UInt8](repeating: 0x5C, count: 256))
    }
  }

  /// Whether `blob` is a valid signature of this key over `data`.
  func verifies(_ blob: [UInt8], over data: [UInt8]) -> Bool {
    guard let decoded = try? SignatureBlob(decoding: blob) else { return false }
    switch self {
    case .ed(let key):
      return decoded.algorithm == "ssh-ed25519" && key.publicKey.isValidSignature(decoded.signature, for: data)
    case .ecdsa(let key):
      guard decoded.algorithm == "ecdsa-sha2-nistp256",
        let raw = try? ECDSASignature.raw(fromInner: decoded.signature, curve: .p256),
        let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw)
      else { return false }
      return key.publicKey.isValidSignature(signature, for: data)
    case .rsa:
      return false
    }
  }
}

/// Server payloads, built by hand (RFC 4252, RFC 4256, RFC 8308).
enum ServerAuth {
  static let accept: [UInt8] = [6] + Raw.string("ssh-userauth")
  static let success: [UInt8] = [52]

  static func failure(_ methods: String = "publickey,password", partial: Bool = false) -> [UInt8] {
    [51] + Raw.string(methods) + [partial ? 1 : 0]
  }

  static func pkOK(_ algorithm: String, _ blob: [UInt8]) -> [UInt8] { [60] + Raw.string(algorithm) + Raw.string(blob) }

  static func passwordChange(_ prompt: [UInt8]) -> [UInt8] { [60] + Raw.string(prompt) + Raw.string("") }

  static func banner(_ text: [UInt8]) -> [UInt8] { [53] + Raw.string(text) + Raw.string("en") }

  static func infoRequest(name: [UInt8] = [], instruction: [UInt8] = [], prompts: [([UInt8], Bool)]) -> [UInt8] {
    var payload: [UInt8] = [60] + Raw.string(name) + Raw.string(instruction) + Raw.string("") + Raw.u32(UInt32(prompts.count))
    for (text, echo) in prompts { payload += Raw.string(text) + [echo ? 1 : 0] }
    return payload
  }

  static func extInfo(_ values: [(String, String)]) -> [UInt8] {
    var payload: [UInt8] = [7] + Raw.u32(UInt32(values.count))
    for (name, value) in values { payload += Raw.string(name) + Raw.string(value) }
    return payload
  }

  static let serverSigAlgs = extInfo([("server-sig-algs", "ssh-ed25519,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256")])
}

/// The requests the client must send, built by hand (RFC 4252 §5-§8, RFC 4256 §3).
enum ClientAuth {
  static let serviceRequest: [UInt8] = [5] + Raw.string("ssh-userauth")

  static func header(_ user: String, _ method: String) -> [UInt8] {
    [50] + Raw.string(user) + Raw.string("ssh-connection") + Raw.string(method)
  }

  static func password(_ user: String, _ password: String) -> [UInt8] {
    header(user, "password") + [0] + Raw.string(password)
  }

  static func query(_ user: String, _ algorithm: String, _ blob: [UInt8]) -> [UInt8] {
    header(user, "publickey") + [0] + Raw.string(algorithm) + Raw.string(blob)
  }

  /// The signed request without its signature: what follows the session id in the signed data.
  static func signedFields(_ user: String, _ algorithm: String, _ blob: [UInt8]) -> [UInt8] {
    header(user, "publickey") + [1] + Raw.string(algorithm) + Raw.string(blob)
  }

  /// RFC 4252 §7: the session id as a string, then the request's fields.
  static func signedData(sessionID: [UInt8], _ user: String, _ algorithm: String, _ blob: [UInt8]) -> [UInt8] {
    Raw.string(sessionID) + signedFields(user, algorithm, blob)
  }

  static func keyboardInteractive(_ user: String) -> [UInt8] {
    header(user, "keyboard-interactive") + Raw.string("") + Raw.string("")
  }

  static func infoResponse(_ answers: [String]) -> [UInt8] {
    answers.reduce([61] + Raw.u32(UInt32(answers.count))) { $0 + Raw.string($1) }
  }
}

/// A userauth core on a fake link, with the server's messages routed through the message policy at the core's phase,
/// as the transport and the driver would.
final class AuthHarness {
  let link: FakeTransportLink
  let auth: UserauthCore
  private(set) var events: [AuthEvent] = []

  /// `extensions`: what `serverExtensions` is before the first packet after NEWKEYS (nil: not known yet; the first
  /// delivered packet then makes it known, as the transport does).
  init(extensions: ServerExtensions? = ServerExtensions(), directAnswer: Duration = .seconds(10),
       sessionID: [UInt8] = [UInt8](repeating: 0x5E, count: 32)) {
    link = FakeTransportLink(sessionID: sessionID, serverExtensions: extensions)
    auth = UserauthCore(link: link, directAnswer: directAnswer)
  }

  /// A harness whose attempt with `credential` started and whose SERVICE_ACCEPT came.
  static func accepted(_ credential: Credential) -> AuthHarness {
    let harness = AuthHarness()
    harness.start(credential)
    harness.server(ServerAuth.accept)
    return harness
  }

  var phase: MessagePolicy.ServicePhase { auth.servicePhase }
  var sent: [[UInt8]] { link.sent }

  func start(_ credential: Credential) { start("phone", credential) }

  func start(_ user: String, _ credential: Credential) {
    XCTAssertNoThrow(try auth.start(user: user, credential: credential))
    drain()
  }

  /// One server payload: through the policy (a refusal ends the connection as the transport would), EXT_INFO
  /// absorbed into `serverExtensions`, the rest handed to the core.
  func server(_ payload: [UInt8]) {
    let wasKnown = link.serverExtensions != nil
    do throws(SSHError) {
      if let message = try link.deliver(payload, service: auth.servicePhase) {
        if !wasKnown { link.serverExtensions = ServerExtensions() }
        auth.receive(message)
      } else {
        if payload.first == MessageNumber.extInfo.rawValue { absorbExtInfo(payload) }
        auth.linkProgressed()
      }
    } catch {
      link.end(error)
      auth.connectionEnded(error)
    }
    drain()
  }

  func drain() {
    while let event = auth.poll() { events.append(event) }
  }

  /// Ends the connection with `error`, as the transport would.
  func endConnection(_ error: SSHError) {
    link.end(error)
    auth.connectionEnded(error)
    drain()
  }

  /// The events since the last `take`.
  func take() -> [AuthEvent] {
    defer { events = [] }
    return events
  }

  /// The question of the only pending `.sign` event, taken.
  func signRequest(file: StaticString = #filePath, line: UInt = #line) -> (AuthQuestion, [UInt8], SignatureAlgorithm)? {
    let taken = take()
    guard taken.count == 1, case .sign(let question, let data, let algorithm) = taken[0] else {
      XCTFail("expected one sign request, got \(taken)", file: file, line: line)
      return nil
    }
    return (question, data, algorithm)
  }

  func promptRequest(file: StaticString = #filePath, line: UInt = #line) -> (AuthQuestion, KeyboardInteractiveChallenge)? {
    let taken = take()
    guard taken.count == 1, case .prompt(let question, let challenge) = taken[0] else {
      XCTFail("expected one prompt, got \(taken)", file: file, line: line)
      return nil
    }
    return (question, challenge)
  }

  func sign(_ key: TestKey, _ question: AuthQuestion, _ data: [UInt8], _ algorithm: SignatureAlgorithm) {
    auth.signed(question, signature: key.signatureBlob(for: data, algorithm: algorithm))
    drain()
  }

  func answer(_ question: AuthQuestion, _ answers: [String]?) {
    auth.answered(question, with: answers?.map { SecretBytes(utf8: $0) })
    drain()
  }

  /// The transport's EXT_INFO handling: its decoder, the values replacing earlier ones.
  private func absorbExtInfo(_ payload: [UInt8]) {
    guard let entries = try? InboundMessage(payload: payload)?.decode(ClientTransport.extInfoEntries) else { return }
    var extensions = link.serverExtensions ?? ServerExtensions()
    for (name, value) in entries { extensions.values[name] = value }
    link.serverExtensions = extensions
  }
}

extension AuthEvent {
  static func outcome(_ outcome: AuthOutcome) -> AuthEvent { .finished(.success(outcome)) }
  static func failed(_ error: SSHError) -> AuthEvent { .finished(.failure(error)) }
}
