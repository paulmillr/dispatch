import Foundation

/// One host's live session as the app holds it: the SSH connection plus the helper's stdio channel.
public struct SSHHostSession: HostSession {
  public let connection: SSHConnection
  public let installed: HelperBootstrap.Installed
  public let helper: HelperChannel

  public func closed() async { await connection.closed() }

  public var lossReason: String? {
    switch connection.endReason {
    case nil: nil
    case .channelClosed?: "The connection closed."
    case let reason?: HostConnectionPolicy.describe(reason)
    }
  }

  public func close() async {
    await helper.close()
    await connection.close()
  }

  /// Connects and authenticates (reporting `.authenticating` once the host key is trusted): the connection both modes
  /// start from. Plain SSH (docs/ios.md) stops here and opens shells on it; the helper path goes on with
  /// `bootstrapHelper(on:)`.
  public static func connect(
    endpoint: SSHEndpoint, credentials: [SSHCredential], trust: any HostKeyTrust, keepalive: Duration = .seconds(15),
    keepaliveMax: Int = 3, phase: @escaping @Sendable (HostConnectionPhase) async -> Void
  ) async throws -> SSHConnection {
    try await SSHConnection.connect(
      to: endpoint, credentials: credentials, trust: trust, keepalive: keepalive, keepaliveMax: keepaliveMax,
      authenticating: { await phase(.authenticating) })
  }

  /// Installs the helper under `root` if needed (`HelperBootstrap.install`, which may move on to the runtime folder) and
  /// starts its `--stdio` session on `connection` from where it was installed, reporting `.bootstrapping`. A
  /// failure leaves the connection open (the caller decides: close it, or carry on as plain SSH); nothing of the helper
  /// is left running, as the channel is its last step. The caller greets the helper (`hello` through HelperConnection
  /// on `helper.read`/`helper.write`) before treating the host as connected.
  public static func bootstrapHelper(
    on connection: SSHConnection, binaries: URL, capabilities: String, environment: [String: String] = [:],
    root: HelperBootstrap.Root = .home, phase: @escaping @Sendable (HostConnectionPhase) async -> Void
  ) async throws -> SSHHostSession {
    await phase(.bootstrapping)
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment, root: root)
    let helper = try await HelperChannel.open(
      on: connection, command: HelperBootstrap.launchCommand(installed, capabilities: capabilities, environment: environment))
    return SSHHostSession(connection: connection, installed: installed, helper: helper)
  }

  /// `connect` then `bootstrapHelper`, closing the connection when the helper cannot start.
  public static func establish(
    endpoint: SSHEndpoint, credentials: [SSHCredential], trust: any HostKeyTrust, binaries: URL,
    capabilities: String, environment: [String: String] = [:], keepalive: Duration = .seconds(15), keepaliveMax: Int = 3,
    phase: @escaping @Sendable (HostConnectionPhase) async -> Void
  ) async throws -> SSHHostSession {
    let connection = try await connect(endpoint: endpoint, credentials: credentials, trust: trust, keepalive: keepalive,
                                       keepaliveMax: keepaliveMax, phase: phase)
    do {
      return try await bootstrapHelper(on: connection, binaries: binaries, capabilities: capabilities,
                                       environment: environment, phase: phase)
    } catch {
      await connection.close()
      throw error
    }
  }
}
