import Foundation

/// Why the TCP connection to a host failed, before any SSH.
public enum SSHConnectFailure: Sendable, Equatable {
  /// Name resolution found no address for the host.
  case hostNotFound
  /// Nothing accepted the connection on the port.
  case refused
  /// No route from this network; on iOS also Local Network access denied for a host on the LAN.
  case unreachable
  /// No answer before the deadline.
  case noAnswer
}

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
  /// Another socket failure (the OS's text).
  case network(String)
  /// The TCP connection to `host`:`port` failed (`SSHConnectFailure`).
  case connectFailed(SSHConnectFailure, host: String, port: Int)
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
    case .network(let reason): "Network error: \(reason)."
    case .connectFailed(let failure, let host, let port): Self.describe(failure, host: host, port: port)
    case .protocolError(let reason): "SSH error: \(reason)."
    case .wrongPassphrase: "The passphrase is wrong."
    case .timedOut(let what): "Timed out: \(what)."
    case .channelClosed: "The SSH channel closed."
    case .commandFailed(let status, let stderr): "The remote command failed (\(status)): \(stderr)"
    case .outputLimit(let limit): "Remote output exceeded \(limit) bytes."
    case .bootstrap(let reason): reason
    }
  }

  /// What failed, and what usually fixes it: Tailscale for its names and addresses, Local Network access for a host
  /// on the LAN (iOS answers "no route" when it is denied).
  static func describe(_ failure: SSHConnectFailure, host: String, port: Int) -> String {
    let tailscale = host.hasSuffix(".ts.net") || !host.contains(".") && !host.contains(":") || Self.tailscaleAddress(host)
    switch failure {
    case .hostNotFound:
      return tailscale ? "Can’t find \(host). Check the name, and that Tailscale is on." : "Can’t find \(host). Check the address."
    case .refused:
      return "\(host) refused the connection on port \(port). Check that SSH (Remote Login on a Mac) is on and the port is right."
    case .unreachable:
      if Self.localAddress(host) {
        return "Can’t reach \(host) from this network. On the same Wi-Fi, allow Dispatch in Settings › Privacy & Security › Local Network."
      }
      return tailscale ? "Can’t reach \(host) from this network. Check that Tailscale is on." : "Can’t reach \(host) from this network."
    case .noAnswer:
      return tailscale ? "\(host) didn’t answer on port \(port). Check that Tailscale is on and the host is awake."
        : "\(host) didn’t answer on port \(port). Check that it’s awake and reachable from this network."
    }
  }

  /// 100.64.0.0/10, the range Tailscale gives its devices.
  static func tailscaleAddress(_ host: String) -> Bool {
    let parts = host.split(separator: ".").compactMap { Int($0) }
    return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
  }

  /// A private, link-local or `.local` address: a host on the same network.
  static func localAddress(_ host: String) -> Bool {
    let lower = host.lowercased()
    if lower.hasSuffix(".local") || lower.hasPrefix("fe80:") || lower.hasPrefix("fd") && lower.contains(":") { return true }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 10 || parts[0] == 192 && parts[1] == 168 || parts[0] == 172 && (16...31).contains(parts[1])
      || parts[0] == 169 && parts[1] == 254
  }
}
