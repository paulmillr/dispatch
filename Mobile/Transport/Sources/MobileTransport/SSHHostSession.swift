import Foundation

/// One host's live session as the app holds it: the SSH connection plus the helper's stdio channel.
public struct SSHHostSession: HostSession {
  public let connection: SSHConnection
  public let installed: HelperBootstrap.Installed
  public let helper: HelperChannel

  public func closed() async { await connection.closed() }

  public func close() async {
    await helper.close()
    await connection.close()
  }

  /// Connect, authenticate, install the helper if needed and start its `--stdio` session, reporting
  /// phases for `HostConnectionState`. The caller greets the helper (`hello` through HelperConnection
  /// on `helper.read`/`helper.write`) before treating the host as connected.
  public static func establish(
    endpoint: SSHEndpoint, credentials: [SSHCredential], trust: any HostKeyTrust, binaries: URL,
    capabilities: String, environment: [String: String] = [:], keepalive: Duration = .seconds(15), keepaliveMax: Int = 3,
    phase: @escaping @Sendable (HostConnectionPhase) async -> Void
  ) async throws -> SSHHostSession {
    let connection = try await SSHConnection.connect(
      to: endpoint, credentials: credentials, trust: trust, keepalive: keepalive, keepaliveMax: keepaliveMax,
      authenticating: { await phase(.authenticating) })
    do {
      await phase(.bootstrapping)
      let installed = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment)
      let helper = try await HelperChannel.open(
        on: connection, command: HelperBootstrap.launchCommand(installed, capabilities: capabilities, environment: environment))
      return SSHHostSession(connection: connection, installed: installed, helper: helper)
    } catch {
      await connection.close()
      throw error
    }
  }
}
