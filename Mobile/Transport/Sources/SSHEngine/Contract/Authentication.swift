/// User authentication's inputs and outcomes (RFC 4252, RFC 4256), as the client facade takes and returns them.
/// C implements the userauth state machine in Auth/; K implements `UserKey` for key files in Keys/; the app
/// implements it for Keychain and Secure Enclave keys (the private key never enters the engine).

/// Methods a server lists in USERAUTH_FAILURE as able to continue. The bits are the C ABI's (`DMS_METHOD_*`).
public struct AuthMethods: OptionSet, Sendable, Hashable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  public static let password = AuthMethods(rawValue: 1)
  public static let publicKey = AuthMethods(rawValue: 2)
  public static let keyboardInteractive = AuthMethods(rawValue: 4)
  public static let hostBased = AuthMethods(rawValue: 8)

  private static let byName: [(String, AuthMethods)] = [
    ("password", .password), ("publickey", .publicKey), ("keyboard-interactive", .keyboardInteractive),
    ("hostbased", .hostBased),
  ]

  /// From a USERAUTH_FAILURE name-list; names the engine does not know (gssapi-with-mic, ...) are dropped.
  public init(names: [String]) {
    self = Self.byName.reduce(into: []) { methods, entry in if names.contains(entry.0) { methods.insert(entry.1) } }
  }

  /// The wire names, in a fixed order.
  public var names: [String] { Self.byName.filter { contains($0.1) }.map(\.0) }
}

/// How one login attempt ended when the server answered it.
public enum AuthOutcome: Sendable, Equatable {
  /// USERAUTH_SUCCESS: the session is logged in (DMS_OK).
  case success
  /// USERAUTH_FAILURE: this credential did not log in (`partialSuccess`: it was accepted, but the server asks for
  /// more). The next attempt may go on the same connection. DMS_AUTH_FAILED with `remaining`'s bits.
  case refused(remaining: AuthMethods, partialSuccess: Bool)
  /// PASSWD_CHANGEREQ: the server wants a new password. The engine does not change passwords; other credentials
  /// may still be tried on the connection. DMS_AUTH_FAILED with the password bit.
  case passwordChangeRequested
}

/// A user key that signs: the public half is known to the engine, the signing happens wherever the key lives.
public protocol UserKey: Sendable {
  /// The public key blob (canonical, `PublicKeyBlob`): what the request names and the server checks.
  var publicKeyBlob: [UInt8] { get }

  /// Signs `data` (the RFC 4252 §7 bytes: session id, then the request) with `algorithm`, one of
  /// `SignatureAlgorithm.algorithms(for:)` for this key (for RSA the auth layer picks from
  /// `ServerExtensions.rsaAlgorithm`; never ssh-rsa). Returns the signature blob (`SignatureBlob`): the auth layer
  /// refuses one whose algorithm is not `algorithm`. May take as long as the user needs (Face ID); throws
  /// `SSHError.cancelled` when declined, which sends nothing more for this attempt.
  func sign(_ data: [UInt8], algorithm: SignatureAlgorithm) async throws(SSHError) -> [UInt8]
}

/// One keyboard-interactive round (RFC 4256 §3.2). Name, instruction and prompts are display text: read with
/// `WireReader.readDisplayText` within `Limits.authenticationTextBytes`, so invalid UTF-8 (a Latin-1 PAM prompt)
/// shows replacement characters instead of failing the login. The language tag is read and ignored.
public struct KeyboardInteractiveChallenge: Sendable, Equatable {
  public struct Prompt: Sendable, Equatable {
    public let text: String
    /// Whether the answer may be shown as typed.
    public let echo: Bool

    public init(text: String, echo: Bool) {
      self.text = text
      self.echo = echo
    }
  }

  public let name: String
  public let instruction: String
  public let prompts: [Prompt]

  public init(name: String, instruction: String, prompts: [Prompt]) {
    self.name = name
    self.instruction = instruction
    self.prompts = prompts
  }
}

/// Answers each round's prompts, one answer per prompt, or nil to cancel the attempt (`SSHError.cancelled`). A wrong
/// number of answers cancels too. A round with no prompts is answered by the engine without asking.
public typealias KeyboardInteractiveResponder = @Sendable (KeyboardInteractiveChallenge) async -> [SecretBytes]?

/// One way to log in (the C ABI's four logins: `dms_auth_password`, `dms_auth_key`, `dms_auth_signer` and
/// `dms_auth_keyboard_interactive`; a file key and an external signer are both a `UserKey`).
public enum Credential: Sendable {
  case password(SecretBytes)

  /// `direct: false`: as SSH clients send a key: a query (RFC 4252 §7, no signature), then once the server answered
  /// PK_OK the signed request; a key the server does not take is never signed.
  ///
  /// `direct: true`: the signed request goes at once without the query, and as the connection's first request right
  /// behind SERVICE_REQUEST, without waiting for SERVICE_ACCEPT: one round trip instead of three (docs/ios.md,
  /// Transport). The signer is asked before the server said anything about the key. A refusal is an ordinary
  /// `.refused`, and later attempts on the connection work as usual. A request the server never answers is the
  /// connection's end, never a refusal: `SSHError.closed` when the connection ended first, `.timedOut(.directAnswer)`
  /// when no answer came within `ConnectOptions.directAnswer` of the request leaving (the signer's time does not
  /// count), after which the engine closes the connection.
  case publicKey(any UserKey, direct: Bool)

  case keyboardInteractive(KeyboardInteractiveResponder)

  /// The method bit this credential uses (`AuthMethods`).
  public var method: AuthMethods {
    switch self {
    case .password: .password
    case .publicKey: .publicKey
    case .keyboardInteractive: .keyboardInteractive
    }
  }
}
