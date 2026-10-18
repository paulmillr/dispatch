import CryptoKit
import Foundation

/// The key a server presented, as the trust-on-first-use sheet shows it.
public struct HostKeyInfo: Sendable, Hashable {
  /// Where the key was seen: `host:port` as the user typed them.
  public let host: String
  public let port: Int
  /// Key format name, such as `ssh-ed25519` or `ecdsa-sha2-nistp256`.
  public let algorithm: String
  /// `SHA256:` plus unpadded base64 of the key blob, as `ssh-keygen -lf` prints it.
  public let fingerprint: String
  /// The OpenSSH public key line (`algorithm base64`), what a known-hosts store keeps.
  public let openSSH: String

  init(host: String, port: Int, algorithm: String, fingerprint: String, openSSH: String) {
    self.host = host
    self.port = port
    self.algorithm = algorithm
    self.fingerprint = fingerprint
    self.openSSH = openSSH
  }

  /// Lookup key of a known-hosts store: OpenSSH's `[host]:port` form (bare host on port 22).
  public var hostPattern: String { port == 22 ? host : "[\(host)]:\(port)" }
}


/// Decides whether to trust a host key. The app's implementation asks once (trust on first use)
/// and remembers the answer; a changed key must be refused.
public protocol HostKeyTrust: Sendable {
  func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision
}

public enum HostKeyDecision: Sendable, Equatable {
  case trust
  /// Refused: the connection fails with `SSHTransportError.hostKeyRejected`.
  case reject
  /// Refused because a different key is remembered for this host (a hard stop in the UI).
  case mismatch(expected: String)
}

/// In-memory trust on first use: known keys must match; unknown ones go to `confirm`, and a yes is
/// remembered. The app persists `known` (known_hosts.json); this type only holds the policy.
public actor TrustOnFirstUse: HostKeyTrust {
  public private(set) var known: [String: String]
  private let confirm: @Sendable (HostKeyInfo) async -> Bool

  public init(known: [String: String] = [:], confirm: @escaping @Sendable (HostKeyInfo) async -> Bool) {
    self.known = known
    self.confirm = confirm
  }

  public func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
    if let expected = known[key.hostPattern] {
      return expected == key.openSSH ? .trust : .mismatch(expected: expected)
    }
    guard await confirm(key) else { return .reject }
    // A concurrent first connection to the same host may have stored a key meanwhile.
    if let expected = known[key.hostPattern], expected != key.openSSH { return .mismatch(expected: expected) }
    known[key.hostPattern] = key.openSSH
    return .trust
  }

  public func forget(_ hostPattern: String) { known.removeValue(forKey: hostPattern) }
}
