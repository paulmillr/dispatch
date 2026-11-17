/// The userauth service (RFC 4252, RFC 4256) as a synchronous state machine over a `TransportLink`: SERVICE_REQUEST
/// for `ssh-userauth`, then one login attempt at a time with a `Credential` (password; public key queried or direct;
/// keyboard-interactive). Sans-I/O: the driver feeds it the messages the transport routed to the service, the answers
/// of the signer and the prompt, timer firings and the connection's end, and drains `poll` after every call; it sends
/// through the link and asks for what takes time (`AuthEvent.sign`, `.prompt`) without waiting for anything itself.
///
/// Invariants:
/// - `servicePhase` is what the driver passes to `TransportCore.poll` before each packet (`MessagePolicy`).
/// - Each `start` that returned without throwing ends with exactly one `.finished`, the attempt's last event.
/// - Nothing secret is kept past its send: a password lives in its `Credential` (the caller's) and in the payload,
///   built with `WireWriter.finishSecret` and sent with `send(secret:)`; keyboard-interactive answers likewise.
/// - A server message the state does not expect, or one that does not decode, ends the connection
///   (`TransportLink.end`) and the attempt with that protocol violation. Nothing here traps on server data.
public final class UserauthCore {
  private let link: any TransportLink
  private let directAnswer: Duration

  private enum Service { case notRequested, requested, accepted }
  private var service = Service.notRequested
  public private(set) var isAuthenticated = false
  /// The connection's end, once known (from `connectionEnded` or an end this core caused).
  public private(set) var endedWith: SSHError?
  /// The server refused an attempt on this connection (a USERAUTH_FAILURE without partial success).
  private var refusedBefore = false
  private var attempt: Attempt?
  private var events: [AuthEvent] = []
  private var lastQuestion: UInt64 = 0

  /// `directAnswer`: how long a direct request waits for its answer (`ConnectOptions.directAnswer`).
  public init(link: any TransportLink, directAnswer: Duration = Limits.directAnswer) {
    self.link = link
    self.directAnswer = directAnswer
  }

  // MARK: The phase

  /// The phase the message policy checks the next packet against.
  public var servicePhase: MessagePolicy.ServicePhase {
    if isAuthenticated { return .connection }
    switch service {
    case .notRequested: return .serviceNotRequested
    case .requested: return .serviceRequested
    case .accepted: return .userauth(attempt?.wait ?? .idle)
    }
  }

  /// An attempt started and not yet finished.
  public var isAttemptInProgress: Bool { attempt != nil }

  // MARK: Driving

  /// Starts one login attempt as `user`. Sends SERVICE_REQUEST first if no attempt did; a direct public key request
  /// then goes without waiting for SERVICE_ACCEPT, every other request once it arrived. Throws, starting nothing:
  /// `closed(.alreadyEnded)` after the end, `usage(.alreadyAuthenticated)`, `usage(.authenticationInProgress)`,
  /// `invalidKey` for a public blob that is no key the engine signs with, `unsupported` for a certificate.
  public func start(user: String, credential: Credential) throws(SSHError) {
    guard endedWith == nil, link.isOpen else { throw .closed(.alreadyEnded) }
    guard !isAuthenticated else { throw .usage(.alreadyAuthenticated) }
    guard attempt == nil else { throw .usage(.authenticationInProgress) }
    let method: Method
    switch credential {
    case .password(let password): method = .password(password)
    case .publicKey(let key, let direct): method = .publicKey(try Self.decodeUserKey(key.publicKeyBlob), direct: direct)
    case .keyboardInteractive: method = .keyboardInteractive
    }
    attempt = Attempt(user: user, method: method, step: .starting)
    if service == .notRequested {
      var writer = WireWriter(.serviceRequest)
      writer.writeName(Self.userauthService)
      guard send(writer) else { return }
      service = .requested
    }
    proceed()
  }

  /// A message the transport routed to the layers above while `servicePhase` was not `.connection`.
  public func receive(_ message: InboundMessage) {
    guard endedWith == nil else { return }
    do throws(SSHError) {
      try handle(message)
    } catch {
      fail(error)
    }
  }

  /// The transport delivered or absorbed a packet (an EXT_INFO the layers above never see): an RSA key waiting for
  /// `serverExtensions` goes on once they are known. Cheap; call it after each `poll` that returned an event.
  public func linkProgressed() {
    guard endedWith == nil, let attempt, case .awaitingExtensions = attempt.step else { return }
    proceed()
  }

  /// The signer's answer to `AuthEvent.sign(question, ...)`: the signature blob (`SignatureBlob`). One whose
  /// algorithm is not the one asked for ends the attempt with `invalidKey`, sending nothing. An answer to a question
  /// that is no longer open is ignored.
  public func signed(_ question: AuthQuestion, signature: [UInt8]) {
    guard endedWith == nil, var attempt, case .signing(question, let algorithm, let request, let direct) = attempt.step
    else { return }
    guard let blob = try? SignatureBlob(decoding: signature), blob.algorithm == algorithm.rawValue else {
      finish(.failure(.invalidKey("the signature is not one of the key's algorithm")))
      return
    }
    var writer = WireWriter(capacity: request.count + signature.count + 4)
    writer.writeBytes(request)
    writer.writeString(signature)
    attempt.step = .answer(.publicKeySigned(direct: direct))
    self.attempt = attempt
    guard send(writer) else { return }
    if direct {
      self.attempt?.directTimer = true
      events.append(.timer(.schedule(.directAnswer, after: directAnswer)))
    }
  }

  /// The signer did not sign (`SSHError.cancelled` when declined): the attempt ends with `error`, sending nothing
  /// more; the session stays usable. Ignored unless `question` is open.
  public func signingFailed(_ question: AuthQuestion, error: SSHError) {
    guard endedWith == nil, let attempt, case .signing(question, _, _, _) = attempt.step else { return }
    finish(.failure(error))
  }

  /// The answers to `AuthEvent.prompt(question, ...)`, one per prompt, or nil to cancel. nil or a wrong count ends
  /// the attempt with `cancelled`, sending nothing more (the session stays usable). Ignored unless `question` is open.
  public func answered(_ question: AuthQuestion, with answers: [SecretBytes]?) {
    guard endedWith == nil, var attempt, case .prompting(question, let count) = attempt.step else { return }
    guard let answers, answers.count == count else {
      finish(.failure(.cancelled))
      return
    }
    attempt.step = .answer(.keyboardInteractive)
    self.attempt = attempt
    sendInfoResponse(answers)
  }

  /// A timer this core scheduled fired: a direct request still unanswered ends the connection
  /// (`timedOut(.directAnswer)`). Stale firings do nothing.
  public func timerFired(_ timer: CoreTimer) {
    guard timer == .directAnswer, endedWith == nil, let attempt, attempt.directTimer,
      case .answer(.publicKeySigned(direct: true)) = attempt.step
    else { return }
    fail(.timedOut(.directAnswer))
  }

  /// The attempt's task was cancelled. Before its request is on the wire (waiting for SERVICE_ACCEPT, the extensions,
  /// the signer or a prompt) the attempt ends with `cancelled` and the session stays usable; once a request waits for
  /// the server's answer the connection ends (`cancelled`): a late answer could not be told from the next attempt's.
  public func cancel() {
    guard endedWith == nil, let attempt else { return }
    if case .answer = attempt.step {
      fail(.cancelled)
    } else {
      finish(.failure(.cancelled))
    }
  }

  /// The connection ended (`TransportEvent.ended`): an attempt in progress ends with `error`, except one the server
  /// ended at its attempt limit. That is an asked-for request on the wire (a password, keyboard-interactive answers, a
  /// queried key's query or signature; never a direct key, whose unanswered request stays the connection's end), when
  /// the server ended the connection and either sent a DISCONNECT (OpenSSH: "Too many authentication failures") or
  /// had already refused an attempt on it (Dropbear closes without one): `.refused(remaining: [])`, so the login reads
  /// as failed and is not retried on a new connection. The DISCONNECT's text stays in `endedWith`. Any other end (a
  /// drop before any refusal, the client's close, a timeout, a violation) is the end as it came. Idempotent.
  public func connectionEnded(_ error: SSHError) {
    guard endedWith == nil else { return }
    endedWith = error
    guard let attempt else { return }
    if Self.endsAtTheLimit(attempt, error, refusedBefore: refusedBefore) {
      finish(.success(.refused(remaining: [], partialSuccess: false)))
    } else {
      finish(.failure(error))
    }
  }

  /// Whether `error` ending the connection during `attempt` is the server's attempt limit (`connectionEnded`).
  private static func endsAtTheLimit(_ attempt: Attempt, _ error: SSHError, refusedBefore: Bool) -> Bool {
    guard case .answer(let answer) = attempt.step else { return false }
    if case .publicKeySigned(direct: true) = answer { return false }
    switch error {
    case .closed(.byServer): return true
    case .closed(.connectionLost): return refusedBefore
    default: return false
    }
  }

  /// The next event, in order; nil when none is queued. Drain after every call.
  public func poll() -> AuthEvent? {
    events.isEmpty ? nil : events.removeFirst()
  }

  // MARK: The attempt

  static let userauthService = "ssh-userauth"
  static let connectionService = "ssh-connection"

  private enum Method {
    case password(SecretBytes)
    case publicKey(PublicKeyBlob, direct: Bool)
    case keyboardInteractive
  }

  private enum Step {
    /// Not yet past `proceed`.
    case starting
    /// A request that waits for SERVICE_ACCEPT (all but a direct one).
    case awaitingService
    /// An RSA key waits for `serverExtensions` to pick its hash.
    case awaitingExtensions
    /// The signer has the bytes; `request` is the signed request without its signature.
    case signing(AuthQuestion, SignatureAlgorithm, request: [UInt8], direct: Bool)
    /// A prompt round is with the user.
    case prompting(AuthQuestion, count: Int)
    /// A request is on the wire.
    case answer(Answer)
  }

  private enum Answer {
    case password
    case publicKeyQuery(SignatureAlgorithm, blob: [UInt8])
    case publicKeySigned(direct: Bool)
    case keyboardInteractive
  }

  private struct Attempt {
    let user: String
    let method: Method
    var step: Step
    var rounds = 0
    var directTimer = false

    var wait: MessagePolicy.UserauthWait {
      guard case .answer(let answer) = step else { return .idle }
      switch answer {
      case .password: return .password
      case .publicKeyQuery: return .publicKeyQuery
      case .publicKeySigned: return .publicKeySigned
      case .keyboardInteractive: return .keyboardInteractive
      }
    }
  }

  /// Moves the attempt as far as it can go without the server.
  private func proceed() {
    guard var attempt else { return }
    switch attempt.method {
    case .publicKey(let key, let direct):
      guard direct || service == .accepted else {
        attempt.step = .awaitingService
        self.attempt = attempt
        return
      }
      guard let algorithm = signatureAlgorithm(for: key) else {
        attempt.step = .awaitingExtensions
        self.attempt = attempt
        return
      }
      if direct {
        askSigner(algorithm: algorithm, blob: key.encoded, direct: true)
      } else {
        var writer = publicKeyRequest(user: attempt.user, signed: false, algorithm: algorithm, blob: key.encoded)
        attempt.step = .answer(.publicKeyQuery(algorithm, blob: key.encoded))
        self.attempt = attempt
        _ = send(writer.take())
      }
    case .password(let password):
      guard service == .accepted else {
        attempt.step = .awaitingService
        self.attempt = attempt
        return
      }
      attempt.step = .answer(.password)
      self.attempt = attempt
      sendPassword(user: attempt.user, password: password)
    case .keyboardInteractive:
      guard service == .accepted else {
        attempt.step = .awaitingService
        self.attempt = attempt
        return
      }
      attempt.step = .answer(.keyboardInteractive)
      self.attempt = attempt
      var writer = Self.requestHeader(user: attempt.user, method: "keyboard-interactive", extra: 8)
      writer.writeString([])  // language tag (deprecated, RFC 4256 §3.1)
      writer.writeString([])  // submethods: none
      _ = send(writer)
    }
  }

  /// The algorithm `key` signs with; nil while an RSA key waits for the server's extensions.
  private func signatureAlgorithm(for key: PublicKeyBlob) -> SignatureAlgorithm? {
    let algorithms = SignatureAlgorithm.algorithms(for: key)
    guard algorithms.count > 1 else { return algorithms.first }
    return link.serverExtensions?.rsaAlgorithm
  }

  /// Emits the signature question for the signed request of `blob`: RFC 4252 §7, the session id as a string, then
  /// the request's fields up to the public key.
  private func askSigner(algorithm: SignatureAlgorithm, blob: [UInt8], direct: Bool) {
    guard var attempt else { return }
    var request = publicKeyRequest(user: attempt.user, signed: true, algorithm: algorithm, blob: blob)
    let fields = request.take()
    var data = WireWriter(capacity: fields.count + link.sessionID.count + 4)
    data.writeString(link.sessionID)
    data.writeBytes(fields)
    guard let signedData = try? data.finish() else {
      finish(.failure(.usage(.invalidArgument("a request too large to sign"))))
      return
    }
    let question = nextQuestion()
    attempt.step = .signing(question, algorithm, request: fields, direct: direct)
    self.attempt = attempt
    events.append(.sign(question, data: signedData, algorithm: algorithm))
  }

  private func nextQuestion() -> AuthQuestion {
    lastQuestion &+= 1
    return AuthQuestion(rawValue: lastQuestion)
  }

  // MARK: Server messages

  private func handle(_ message: InboundMessage) throws(SSHError) {
    switch message.number {
    case .serviceAccept where service == .requested && !isAuthenticated:
      let name = try message.decode { (reader: inout WireReader) throws(WireError) in try reader.readName() }
      guard name == Self.userauthService else { throw .protocolViolation(.authentication(.unexpectedService)) }
      service = .accepted
      if let attempt {
        switch attempt.step {
        case .awaitingService, .awaitingExtensions: proceed()
        default: break
        }
      }
    case .userauthBanner where service == .accepted && !isAuthenticated:
      // RFC 4252 §5.4: display text, accepted and dropped (the app shows no banner).
      _ = try message.decode { (reader: inout WireReader) throws(WireError) in
        _ = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
        _ = try reader.readDisplayText(limit: Limits.languageTagBytes)
      }
    case .userauthFailure where requestOutstanding:
      let (names, partial) = try message.decode { (reader: inout WireReader) throws(WireError) in
        (try reader.readNameList(), try reader.readBoolean())
      }
      if !partial { refusedBefore = true }
      finish(.success(.refused(remaining: AuthMethods(names: names), partialSuccess: partial)))
    case .userauthSuccess where requestOutstanding:
      try message.decode { (_: inout WireReader) throws(WireError) in }
      isAuthenticated = true
      finish(.success(.success))
    case MessageNumber(60) where service == .accepted:
      try handle60(message)
    default:
      throw unexpected(message.number)
    }
  }

  /// A userauth request waits for its answer and the service is accepted (the server answers in order, so nothing
  /// for a request sent before SERVICE_ACCEPT can come before it).
  private var requestOutstanding: Bool {
    guard service == .accepted, let attempt, case .answer = attempt.step else { return false }
    return true
  }

  /// 60 is PASSWD_CHANGEREQ, PK_OK or INFO_REQUEST by the request outstanding.
  private func handle60(_ message: InboundMessage) throws(SSHError) {
    guard var attempt, case .answer(let answer) = attempt.step else { throw unexpected(message.number) }
    switch answer {
    case .password:
      _ = try message.decode { (reader: inout WireReader) throws(WireError) in
        _ = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
        _ = try reader.readDisplayText(limit: Limits.languageTagBytes)
      }
      finish(.success(.passwordChangeRequested))
    case .publicKeyQuery(let algorithm, let blob):
      let (name, key) = try message.decode { (reader: inout WireReader) throws(WireError) in
        (try reader.readName(), try reader.readString(limit: Limits.publicKeyBlobBytes))
      }
      guard name == algorithm.rawValue, key == blob else { throw .protocolViolation(.authentication(.pkOKMismatch)) }
      askSigner(algorithm: algorithm, blob: blob, direct: false)
    case .keyboardInteractive:
      guard attempt.rounds < Limits.keyboardInteractiveRounds else {
        throw .protocolViolation(.authentication(.tooManyRounds))
      }
      attempt.rounds += 1
      let challenge = try message.decode { (reader: inout WireReader) throws(WireError) in
        let name = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
        let instruction = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
        _ = try reader.readDisplayText(limit: Limits.languageTagBytes)
        let count = try reader.readCount(limit: Limits.keyboardInteractivePrompts, elementBytes: 5)
        var prompts: [KeyboardInteractiveChallenge.Prompt] = []
        prompts.reserveCapacity(count)
        for _ in 0..<count {
          let text = try reader.readDisplayText(limit: Limits.authenticationTextBytes)
          prompts.append(.init(text: PromptText.sanitize(text, multiline: false), echo: try reader.readBoolean()))
        }
        return KeyboardInteractiveChallenge(
          name: PromptText.sanitize(name, multiline: false), instruction: PromptText.sanitize(instruction, multiline: true),
          prompts: prompts)
      }
      if challenge.prompts.isEmpty {
        // A round with nothing to ask is answered at once (RFC 4256 §3.4 allows num-responses 0).
        self.attempt = attempt
        sendInfoResponse([])
      } else {
        let question = nextQuestion()
        attempt.step = .prompting(question, count: challenge.prompts.count)
        self.attempt = attempt
        events.append(.prompt(question, challenge))
      }
    case .publicKeySigned:
      throw unexpected(message.number)
    }
  }

  private func unexpected(_ number: MessageNumber) -> SSHError {
    // Reached only when the driver passed another phase than `servicePhase`, or for a reply the policy cannot tell.
    .protocolViolation(.unexpectedMessage(number, MessagePolicy.Context(transport: .established, service: servicePhase)))
  }

  // MARK: Requests

  /// `byte 50, string user, string "ssh-connection", string method`; `extra` bytes reserved for the fields after.
  private static func requestHeader(user: String, method: String, extra: Int) -> WireWriter {
    var writer = WireWriter(.userauthRequest, capacity: 1 + 12 + user.utf8.count + connectionService.utf8.count
      + method.utf8.count + extra)
    writer.writeString(user)
    writer.writeName(connectionService)
    writer.writeName(method)
    return writer
  }

  /// RFC 4252 §7: `boolean signed, string algorithm, string blob` after the header (no signature yet).
  private func publicKeyRequest(user: String, signed: Bool, algorithm: SignatureAlgorithm, blob: [UInt8]) -> Builder {
    var writer = Self.requestHeader(user: user, method: "publickey", extra: 9 + algorithm.rawValue.utf8.count + blob.count)
    writer.writeBoolean(signed)
    writer.writeName(algorithm.rawValue)
    writer.writeString(blob)
    return Builder(writer: writer)
  }

  /// RFC 4252 §8, sent as a secret: `boolean FALSE, string password`. The writer reserves all it needs, so the only
  /// copies are the writer's (wiped by `finishSecret`) and the transport's (wiped once sealed).
  private func sendPassword(user: String, password: SecretBytes) {
    var writer = Self.requestHeader(user: user, method: "password", extra: 5 + password.count)
    writer.writeBoolean(false)
    writer.writeString(password)
    sendSecret(&writer)
  }

  /// RFC 4256 §3.4: `byte 61, uint32 count, string response...`, as a secret.
  private func sendInfoResponse(_ answers: [SecretBytes]) {
    var writer = WireWriter(.userauthInfoResponse, capacity: 5 + answers.reduce(0) { $0 + 4 + $1.count })
    guard let count = UInt32(exactly: answers.count) else { return }
    writer.writeUInt32(count)
    for answer in answers { writer.writeString(answer) }
    sendSecret(&writer)
  }

  private func sendSecret(_ writer: inout WireWriter) {
    let payload: SecretBytes
    do throws(WireError) {
      payload = try writer.finishSecret()
    } catch {
      finish(.failure(.usage(.invalidArgument("a request that cannot be encoded"))))
      return
    }
    do throws(SSHError) {
      try link.send(secret: payload)
    } catch {
      sendFailed(error)
    }
  }

  /// Sends `writer`'s payload; false (and the attempt ended) when it could not.
  private func send(_ writer: WireWriter) -> Bool {
    guard let payload = try? writer.finish() else {
      finish(.failure(.usage(.invalidArgument("a request that cannot be encoded"))))
      return false
    }
    do throws(SSHError) {
      try link.send(payload)
      return true
    } catch {
      sendFailed(error)
      return false
    }
  }

  private func send(_ payload: [UInt8]) -> Bool {
    do throws(SSHError) {
      try link.send(payload)
      return true
    } catch {
      sendFailed(error)
      return false
    }
  }

  /// A send that threw: after the end the connection's end decides (`connectionEnded`); otherwise the request did
  /// not fit (a user name too long for a packet) and only the attempt ends.
  private func sendFailed(_ error: SSHError) {
    if link.isOpen {
      finish(.failure(error))
    } else if attempt != nil {
      // The transport reports its end; until then the attempt waits for `connectionEnded`.
      attempt?.step = .starting
    }
  }

  // MARK: Ending

  private func finish(_ result: Result<AuthOutcome, SSHError>) {
    guard let attempt else { return }
    if attempt.directTimer { events.append(.timer(.cancel(.directAnswer))) }
    self.attempt = nil
    events.append(.finished(result))
  }

  /// Ends the connection because of `error`, and the attempt with it.
  private func fail(_ error: SSHError) {
    link.end(error)
    connectionEnded(error)
  }

  /// A public key blob the engine signs with (`PublicKeyBlob`, canonical), or why not.
  private static func decodeUserKey(_ blob: [UInt8]) throws(SSHError) -> PublicKeyBlob {
    do {
      return try PublicKeyBlob(decoding: blob)
    } catch .unsupportedType(let type) where type.hasSuffix(PublicKeyBlob.certificateSuffix) {
      throw .unsupported("user certificates")
    } catch .unsupportedType(let type) {
      throw .unsupported("the key type \(type)")
    } catch {
      throw .invalidKey("the public key blob is not a key the engine accepts")
    }
  }

  /// A writer whose bytes are taken once (keeps `finish`'s failure out of the call sites: every field written here
  /// is bounded and named by the engine).
  private struct Builder {
    var writer: WireWriter

    mutating func take() -> [UInt8] { (try? writer.finish()) ?? [] }
  }
}

/// Names one question the auth core asked (a signature, a prompt round), so a late answer to a withdrawn question is
/// never taken for the next one's.
public struct AuthQuestion: Sendable, Hashable {
  public let rawValue: UInt64
}

/// What the auth core asks of its driver, in order.
public enum AuthEvent: Sendable, Equatable {
  /// Sign `data` (session id and request, RFC 4252 §7) with the attempt's key and `algorithm` (`UserKey.sign`), then
  /// answer `signed(_:signature:)` or `signingFailed(_:error:)`. The signer's time counts against no deadline.
  case sign(AuthQuestion, data: [UInt8], algorithm: SignatureAlgorithm)
  /// Ask the attempt's `KeyboardInteractiveResponder`, then answer `answered(_:with:)`.
  case prompt(AuthQuestion, KeyboardInteractiveChallenge)
  /// Run or cancel the `.directAnswer` timer; its firing goes to `timerFired`.
  case timer(TimerRequest)
  /// The attempt ended: the server's answer, or why there was none. The attempt's last event.
  case finished(Result<AuthOutcome, SSHError>)
}
