import Foundation
import MobileTransport
import Synchronization

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
    /// The error it ended with (`MobileTransport.HostSession.lossError`); nil when not known.
    var lossError: (any Error)? { get }
    /// Which of the login's credentials logged in (its index); nil when not known.
    var credential: Int? { get }
    /// Opens PTY shells on this connection (plain SSH).
    var shells: any ShellOpener { get }
    func closed() async
    func close() async
    /// Whether the connection still answers a round trip within `timeout` (after a network change, while plain).
    func alive(timeout: Duration) async -> Bool
    /// Installs the helper under `root` if needed and starts its `--stdio` session, reporting `.bootstrapping`. A failure
    /// leaves the connection open. `fromCache`: one command that starts the helper only when the host's cache already
    /// holds it (`SSHHostSession.bootstrapHelper`); a process that then started none ends with no `installed`.
    func bootstrapHelper(binaries: URL, capabilities: String, environment: [String: String], root: HelperBootstrap.Root,
                         fromCache: Bool, phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws
        -> any HelperProcess
}

extension HostLogin {
    var lossError: (any Error)? { nil }
    var credential: Int? { nil }
}

/// Which keys logged in where (docs/ios.md, Connection). A key that logged in at an endpoint (address, port and user as
/// the host names them) is offered there first as a direct attempt on the next connection (`SSHCredential.directKey`:
/// one round trip instead of three), then as usual. A direct attempt the server refuses forgets it, so the next
/// connection asks first again; one whose signer declined or that was cancelled changes nothing. A key is never sent
/// direct to an endpoint again this run (`barred`) once a direct attempt there went unanswered (the connection ended
/// first, or no answer came in time: a server that cannot take a request sent before its service accept would show so,
/// and would otherwise fail every second connection), or was refused while the same key, asked first, then logged in on
/// that connection.
///
/// With a `url` what is remembered is saved there (`key-logins.json`: address, port, user and the key's fingerprint,
/// one key per endpoint), so the first connection after a launch goes direct too. What is barred never is: a
/// connection lost during one login must not cost every later launch its direct login, so each run finds out again.
/// The file only saves round trips: one that is missing or cannot be read is an empty memory, and a failed save is
/// not reported (the next change writes all of it again).
final class KeyLogins: Sendable {
    /// For the run only: what a driver uses unless it is given the app's (`HostSessions.keyLogins`).
    static let shared = KeyLogins()

    /// One connection's key credentials, in order.
    struct Plan: Sendable {
        let credentials: [SSHCredential]
        fileprivate let site: Site
        fileprivate var direct: Bool { credentials.count == 2 }
    }

    fileprivate struct Site: Hashable, Sendable {
        let endpoint: SSHEndpoint
        let key: String
    }

    private struct Document: Codable {
        struct Login: Codable {
            let host: String
            let port: Int
            let user: String
            /// The public key's fingerprint (`SSHKey.fingerprint`).
            let key: String
        }

        var version = 1
        var logins: [Login]
    }

    private typealias State = (remembered: Set<Site>, barred: Set<Site>)

    private let url: URL?
    private let state: Mutex<State>

    /// `url` nil remembers for the run only (tests, previews, a store kept in memory).
    init(url: URL? = nil) {
        self.url = url
        let saved = url.flatMap { MobileFiles.read(Document.self, from: $0, version: 1, keep: false)?.logins } ?? []
        let remembered = Set(saved.map { Site(endpoint: SSHEndpoint(host: $0.host, port: $0.port, username: $0.user), key: $0.key) })
        state = Mutex((remembered, []))
    }

    /// `key` for a connection to `endpoint`: asked first (`.key`), after a direct attempt when it logged in there before.
    func plan(_ key: SSHKey, at endpoint: SSHEndpoint) -> Plan {
        let site = Site(endpoint: endpoint, key: key.fingerprint)
        let direct = state.withLock { $0.remembered.contains(site) && !$0.barred.contains(site) }
        guard direct else { return Plan(credentials: [.key(key)], site: site) }
        let answered: @Sendable (DirectKeyAnswer) -> Void = { [self] answer in
            change { state in
                switch answer {
                case .loggedIn, .withdrawn: break
                case .refused: state.remembered.remove(site)
                case .unanswered:
                    state.remembered.remove(site)
                    state.barred.insert(site)
                }
            }
        }
        return Plan(credentials: [.directKey(key, answered: answered), .key(key)], site: site)
    }

    /// The login `plan` was part of succeeded with its credential at `index` (`HostLogin.credential`, counted from the
    /// plan's first). The key asked first: remembered, in place of any other key remembered at that endpoint, unless
    /// its direct attempt had just been refused.
    func loggedIn(_ plan: Plan, credential index: Int?) {
        guard index == plan.credentials.count - 1 else { return }
        change { state in
            if plan.direct {
                state.barred.insert(plan.site)
                state.remembered.remove(plan.site)
            } else if !state.barred.contains(plan.site), !state.remembered.contains(plan.site) {
                state.remembered = state.remembered.filter { $0.endpoint != plan.site.endpoint }
                state.remembered.insert(plan.site)
            }
        }
    }

    /// The saved hosts are `hosts`: forgets every endpoint none of them names (a removed host, an edited address, port
    /// or user, a host tried in Add host and never saved).
    func keep(_ hosts: [HostRecord]) {
        let endpoints = Set(hosts.map(\.endpoint))
        change { state in
            state.remembered = state.remembered.filter { endpoints.contains($0.endpoint) }
            state.barred = state.barred.filter { endpoints.contains($0.endpoint) }
        }
    }

    /// Forgets everything and removes the file (Settings' Remove all data).
    func removeAll() {
        state.withLock { state in
            state = ([], [])
            if let url { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Changes the memory and saves what is remembered when that changed, under the lock: saves land in order.
    private func change(_ body: (inout State) -> Void) {
        state.withLock { state in
            let before = state.remembered
            body(&state)
            guard let url, state.remembered != before else { return }
            let logins = state.remembered
                .map { Document.Login(host: $0.endpoint.host, port: $0.endpoint.port, user: $0.endpoint.username, key: $0.key) }
                .sorted { ($0.host, $0.port, $0.user, $0.key) < ($1.host, $1.port, $1.user, $1.key) }
            try? MobileFiles.write(Document(logins: logins), to: url)
        }
    }
}

extension HostRecord {
    /// Where its connections go, as `KeyLogins` names them.
    var endpoint: SSHEndpoint { SSHEndpoint(host: address, port: port, username: user) }
}

/// The helper's `--stdio` session on a login.
protocol HelperProcess: Sendable {
    /// Its stdio, framed (made once; the driver greets and configures it).
    var connection: HelperConnection { get }
    /// What was installed and where (`HelperBootstrap.fallbackRoot`, `launchFailure`). A launch from the cache knows it
    /// by the time its channel ended, and has none when it started no helper.
    var installed: HelperBootstrap.Installed? { get }
    /// Waits for the helper's channel to end: its exit status, nil after a signal or a lost channel. Throws the server's
    /// refusal of the exec request (`commandFailed(status: -1, …)`), which the engine reports as the channel's end.
    func exitStatus() async throws -> Int32?
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

    var lossError: (any Error)? { connection.endReason }

    var credential: Int? { connection.credential }

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
                         fromCache: Bool, phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws
        -> any HelperProcess {
        SSHHelperProcess(try await SSHHostSession.bootstrapHelper(
            on: connection, binaries: binaries, capabilities: capabilities, environment: environment, root: root,
            fromCache: fromCache, phase: phase))
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

    var installed: HelperBootstrap.Installed? { session.installed }
    func exitStatus() async throws -> Int32? {
        let status = await session.helper.exitStatus()
        if let refusal = session.helper.refusal { throw refusal }
        return status
    }
    func stderr() async -> String { await session.stderr() }
    func close() async { await session.helper.close() }
}
