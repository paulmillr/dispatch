import Foundation

/// Where to connect and as whom.
public struct SSHEndpoint: Sendable, Hashable {
  public var host: String
  public var port: Int
  public var username: String

  public init(host: String, port: Int = 22, username: String) {
    self.host = host
    self.port = port
    self.username = username
  }
}

/// One way to log in. Offered in order; each method the server allows is tried once.
public enum SSHCredential: Sendable {
  case key(SSHKey)
  /// `key` sent at once: its signed request goes without first asking whether the server takes the key (RFC 4252 §7
  /// makes that optional) and, as the connection's first request, without waiting for the server to accept the
  /// userauth service. One round trip where `.key` takes two, or three as the first request. For a key known to log in
  /// on the host: a refused one still costs a signature (a Face ID prompt for a Secure Enclave key) and counts as a
  /// failed attempt there. `answered` hears once how the attempt ended (`DirectKeyAnswer`); an attempt that never
  /// started calls nothing. An attempt the server does not answer is the connection's end, never a refusal: the
  /// connect throws `channelClosed`, or `timedOut` when no answer came within 10 s of the request (the engine then
  /// closes the connection), so the host connects again instead of stopping at a failed login.
  case directKey(SSHKey, answered: @Sendable (DirectKeyAnswer) -> Void)
  case password(String)
  /// RFC 4256 (PAM passwords, one-time codes): the handler answers each round's prompts, or nil to cancel.
  case keyboardInteractive(@Sendable (KeyboardInteractiveChallenge) async -> [String]?)
}

/// How a `.directKey` attempt ended.
public enum DirectKeyAnswer: Sendable, Equatable {
  /// The server took the request: logged in.
  case loggedIn
  /// The server answered no (a partial success too); the login goes on with the next credential.
  case refused
  /// Nothing learnt about the server: the signer declined, or the login was cancelled.
  case withdrawn
  /// No answer: the connection ended first, or none came in time. How a server that cannot take a request sent this way
  /// would show.
  case unanswered
}

public struct KeyboardInteractiveChallenge: Sendable {
  public struct Prompt: Sendable {
    public let text: String
    public let echo: Bool
  }
  public let name: String
  public let instruction: String
  public let prompts: [Prompt]
}

extension SSHCredential {
  var method: UInt32 {
    switch self {
    case .key, .directKey: 2
    case .password: 1
    case .keyboardInteractive: 4
    }
  }
}
