import Foundation

public enum SSHTransportError: Error, Sendable, Equatable, LocalizedError {
  case hostKeyRejected(HostKeyInfo)
  case hostKeyMismatch(HostKeyInfo, expected: String)
  /// The server refused every offered credential. `methods` are the ones it still allows.
  case authenticationFailed(methods: [String])
  /// A key type or method the engine does not support.
  case unsupportedAuthentication(String)
  case invalidKey(String)
  /// The user dismissed a prompt or signature request.
  case cancelled
  /// TCP or socket failure: unreachable, refused, reset.
  case network(String)
  case protocolError(String)
  case wrongPassphrase
  case timedOut(String)
  case channelClosed
  case commandFailed(status: Int32, stderr: String)
  case outputLimit(Int)
  case bootstrap(String)

  public var errorDescription: String? {
    switch self {
    case .hostKeyRejected(let key): "The host key \(key.fingerprint) was not trusted."
    case .hostKeyMismatch(let key, _): "The host key of \(key.hostPattern) changed (now \(key.fingerprint))."
    case .authenticationFailed(let methods): "Authentication failed (server allows: \(methods.joined(separator: ", ")))."
    case .unsupportedAuthentication(let method): "The \(method) authentication method is not supported."
    case .invalidKey(let reason): "Invalid private key: \(reason)."
    case .cancelled: "Cancelled."
    case .network(let reason): "The host is unreachable: \(reason)."
    case .protocolError(let reason): "SSH error: \(reason)."
    case .wrongPassphrase: "The passphrase is wrong."
    case .timedOut(let what): "Timed out: \(what)."
    case .channelClosed: "The SSH channel closed."
    case .commandFailed(let status, let stderr): "The remote command failed (\(status)): \(stderr)"
    case .outputLimit(let limit): "Remote output exceeded \(limit) bytes."
    case .bootstrap(let reason): reason
    }
  }
}
