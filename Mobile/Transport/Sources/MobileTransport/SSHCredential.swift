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
  case password(String)
  /// RFC 4256 (PAM passwords, one-time codes): the handler answers each round's prompts, or nil to cancel.
  case keyboardInteractive(@Sendable (KeyboardInteractiveChallenge) async -> [String]?)
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
    case .key: 2
    case .password: 1
    case .keyboardInteractive: 4
    }
  }
}
