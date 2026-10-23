import Foundation
import MobileTransport

/// One connection's SSH login (`SSHHostSessionDriver.login`): endpoint, credentials in order, host key trust, keepalive
/// interval and count, and the phases to report.
typealias HostLoginStep = @Sendable (_ endpoint: SSHEndpoint, _ credentials: [SSHCredential], _ trust: any HostKeyTrust,
                                     _ keepalive: Duration, _ keepaliveMax: Int,
                                     _ phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> any HostLogin

/// An authenticated SSH connection the driver goes on from: the helper on it, or plain SSH shells. The seam
/// SSHDriverTests script (bootstrap failures, a host without the helper); `SSHLogin` is the real one.
protocol HostLogin: AnyObject, Sendable {
    /// Whether the SSH connection is still up.
    var isOpen: Bool { get }
    /// Why the connection ended, once `closed()` returned; nil when not known.
    var lossReason: String? { get }
    /// Opens PTY shells on this connection (plain SSH).
    var shells: any ShellOpener { get }
    func closed() async
    func close() async
    /// Whether the connection still answers a round trip within `timeout` (after a network change, while plain).
    func alive(timeout: Duration) async -> Bool
    /// Installs the helper under `root` if needed and starts its `--stdio` session, reporting `.bootstrapping`. A failure
    /// leaves the connection open.
    func bootstrapHelper(binaries: URL, capabilities: String, environment: [String: String], root: HelperBootstrap.Root,
                         phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> any HelperProcess
}

/// The helper's `--stdio` session on a login.
protocol HelperProcess: Sendable {
    /// Its stdio, framed (made once; the driver greets and configures it).
    var connection: HelperConnection { get }
    /// What was installed and where (`HelperBootstrap.fallbackRoot`, `launchFailure`).
    var installed: HelperBootstrap.Installed { get }
    /// Waits for the helper's channel to end: its exit status, nil after a signal or a lost channel.
    func exitStatus() async -> Int32?
    /// The start of what it wrote to stderr.
    func stderr() async -> String
    /// Ends the session (EOF to the helper); the SSH connection stays.
    func close() async
}

/// `HostLogin` over a MobileTransport `SSHConnection`.
final class SSHLogin: HostLogin {
    let connection: SSHConnection

    init(_ connection: SSHConnection) { self.connection = connection }

    @Sendable static func connect(endpoint: SSHEndpoint, credentials: [SSHCredential], trust: any HostKeyTrust,
                                  keepalive: Duration, keepaliveMax: Int,
                                  phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> any HostLogin {
        SSHLogin(try await SSHHostSession.connect(endpoint: endpoint, credentials: credentials, trust: trust,
                                                  keepalive: keepalive, keepaliveMax: keepaliveMax, phase: phase))
    }

    var isOpen: Bool { connection.isActive }

    var lossReason: String? {
        switch connection.endReason {
        case nil: nil
        case .channelClosed?: "The connection closed."
        case let reason?: HostConnectionPolicy.describe(reason)
        }
    }

    var shells: any ShellOpener { SSHShellOpener(connection: connection) }

    func closed() async { await connection.closed() }
    func close() async { await connection.close() }

    /// The engine has no channel-level ping (no global request or bare channel open in its API), so the round trip is
    /// `:` on an exec channel: the login shell's no-op builtin, which changes nothing on the host (docs/security.md).
    /// Any answer from the server counts (`answered`), a refused exec included; silence past `timeout` does not.
    func alive(timeout: Duration) async -> Bool {
        guard isOpen else { return false }
        let connection = connection
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let asking = Task {
                let result: Result<Void, any Error>
                do {
                    _ = try await connection.run(":", limit: 4_096)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                let answered = Self.answered(result) && connection.isActive
                once.run { continuation.resume(returning: answered) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.run { continuation.resume(returning: false) }
                asking.cancel()
            }
        }
    }

    /// Whether a liveness probe's outcome is the server answering: a finished command (any status), and also a refused
    /// exec (`commandFailed`: plain SSH hosts are often exactly those) or too much output. A closed channel, a network
    /// failure, a timeout or a protocol error mean the connection is gone.
    static func answered(_ result: Result<Void, any Error>) -> Bool {
        guard case .failure(let error) = result else { return true }
        guard let error = error as? SSHTransportError else { return false }
        switch error {
        case .commandFailed, .outputLimit:
            return true
        default:
            return false
        }
    }

    func bootstrapHelper(binaries: URL, capabilities: String, environment: [String: String], root: HelperBootstrap.Root,
                         phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> any HelperProcess {
        SSHHelperProcess(try await SSHHostSession.bootstrapHelper(
            on: connection, binaries: binaries, capabilities: capabilities, environment: environment, root: root, phase: phase))
    }
}

/// The helper's channel of an `SSHHostSession`, with the `HelperConnection` over it.
final class SSHHelperProcess: HelperProcess {
    let session: SSHHostSession
    let connection: HelperConnection

    init(_ session: SSHHostSession) {
        self.session = session
        connection = HelperConnection(read: session.helper.read, write: session.helper.write)
    }

    var installed: HelperBootstrap.Installed { session.installed }
    func exitStatus() async -> Int32? { await session.helper.exitStatus() }
    func stderr() async -> String { await session.helper.stderr() }
    func close() async { await session.helper.close() }
}
