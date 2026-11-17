import Foundation

/// One host's live session as the app holds it: the SSH connection plus the helper's stdio channel.
public struct SSHHostSession: HostSession {
  public let connection: SSHConnection
  public let helper: HelperChannel
  private let launch: Launch

  /// How the helper was started: installed first (`HelperBootstrap.install`, then `launchCommand`), or straight from the
  /// cache (`cachedLaunchCommand`) for these bundled helpers.
  private enum Launch: Sendable {
    case installed(HelperBootstrap.Installed)
    case cache([HelperBootstrap.Bundled])
  }

  /// What runs and from where (`HelperBootstrap.fallbackRoot`, `launchFailure`). A launch from the cache knows it once
  /// its script said so on stderr, which it does just before it starts the helper, so always by the time the channel
  /// ended: nil until then, and for good when it started none (the cache lacked the helper or failed a check; then
  /// `bootstrapHelper(fromCache: false)` installs and starts it).
  public var installed: HelperBootstrap.Installed? {
    switch launch {
    case .installed(let installed): installed
    case .cache(let bundled): HelperBootstrap.launched(helper.stderrSoFar, candidates: bundled)?.installed
    }
  }

  /// The start of what the helper wrote to stderr: for a launch from the cache without the script's report lines.
  public func stderr() async -> String {
    let stderr = await helper.stderr()
    guard case .cache(let bundled) = launch else { return stderr }
    return HelperBootstrap.launched(stderr, candidates: bundled)?.stderr ?? stderr
  }

  public func closed() async { await connection.closed() }

  public var lossError: (any Error)? { connection.endReason }

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
  ///
  /// `fromCache` (for `.home`): one exec channel instead, `HelperBootstrap.cachedLaunchCommand`, which starts the helper
  /// when the cache already holds it (at home, or in the runtime folder when the home cannot run programs) and otherwise
  /// starts nothing: the channel then ends with no `installed`, and the caller comes back with `fromCache` false. The
  /// channel is returned at once, before the host checked anything: the caller's `hello` waits in it for the helper.
  public static func bootstrapHelper(
    on connection: SSHConnection, binaries: URL, capabilities: String, environment: [String: String] = [:],
    root: HelperBootstrap.Root = .home, fromCache: Bool = false, phase: @escaping @Sendable (HostConnectionPhase) async -> Void
  ) async throws -> SSHHostSession {
    await phase(.bootstrapping)
    if fromCache, root == .home {
      let bundled = HelperBootstrap.bundled(in: binaries)
      if !bundled.isEmpty {
        let helper = try await HelperChannel.open(
          on: connection,
          command: HelperBootstrap.cachedLaunchCommand(bundled, capabilities: capabilities, environment: environment))
        return SSHHostSession(connection: connection, helper: helper, launch: .cache(bundled))
      }
    }
    let installed = try await HelperBootstrap.install(on: connection, binaries: binaries, environment: environment, root: root)
    let helper = try await HelperChannel.open(
      on: connection, command: HelperBootstrap.launchCommand(installed, capabilities: capabilities, environment: environment))
    return SSHHostSession(connection: connection, helper: helper, launch: .installed(installed))
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
