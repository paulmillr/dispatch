import CryptoKit
import Foundation
import MobileTransport
import Synchronization

/// The app's `HostSessionDriver` (docs/ios.md, Areas and seams): one SSH connection per host through
/// `MobileTransport`, kept up by its `HostConnection` reconnect policy. Each connection verifies the host key through
/// the session (trust on first use, a mismatch is the hard stop Hosts shows), logs in with the host's key or password
/// (and keyboard-interactive through the Hosts sheet), installs the bundled helper for the host's platform under its
/// hash-named path, starts it on a plain exec channel and greets it with the iPhone's features. While connected it
/// follows the topology of the host's multiplexer (`backends.open` of the chosen backend) and measures latency with
/// `echo`. Cancelling the run (`HostSession.disconnect()`) closes the connection; nothing on the host stops.
struct SSHHostSessionDriver: HostSessionDriver {
    /// The hello features the phone asks for (docs/ios.md, Helper contract). With
    /// `stdio.liveness` the helper ends after 45 s without a frame from the phone: the latency ping (`pingInterval`)
    /// keeps it alive while connected, so it must stay at most `livenessPing`.
    static let features = ["interaction.options", "chat.list", "projects.recent", "multiplexers.versions", "terminals.coalesce",
                           "launch.names", "stdio.liveness", "terminals.activity"]
    /// The longest gap between pings `stdio.liveness` allows (helper/PROTOCOL.md: at least every 15 s).
    static let livenessPing: Duration = .seconds(15)

    /// The bundled helpers (`darwin-universal`, `linux-aarch64`, `linux-x86_64`), the app's `helper` folder.
    var binaries = Bundle.main.bundleURL.appendingPathComponent("helper", isDirectory: true)
    /// The latency ping, which is also the liveness traffic `stdio.liveness` needs (at most `livenessPing`).
    var pingInterval: Duration = .seconds(10)
    /// How long `.ready` waits for the first topology, so no row shows a connected host without its spaces.
    var firstTopology: Duration = .seconds(2)
    /// Between `backends.open` attempts while no multiplexer server runs (New space starts one).
    var reopenDelay: Duration = .seconds(2)
    /// Silence before a connection counts as lost: `keepalive × keepaliveMax`.
    var keepalive: Duration = .seconds(15)
    var keepaliveMax = 3
    /// How long a connected link may take to answer `echo` after a network change before it counts as lost.
    var probeTimeout: Duration = .seconds(3)
    var clock: any ReconnectClock = SystemReconnectClock()

    func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
        let (stream, continuation) = AsyncStream<HostSessionEvent>.makeStream()
        let driver = self
        let task = Task { await driver.drive(host, context: context, events: continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func drive(_ host: HostRecord, context: HostSessionContext, events: AsyncStream<HostSessionEvent>.Continuation) async {
        let keys = KeyCache()
        let driver = self
        let connection = HostConnection<HelperLink>(clock: clock, refused: Self.refused) { phase in
            try await driver.establish(host, context: context, keys: keys, phase: phase)
        }
        let states = await connection.states()
        let probeTimeout = probeTimeout
        // retryNow (network change, foregrounding) races the policy's wait; while connected it checks the link, which a
        // change of network can leave dead until the keepalive gives up (45 s).
        let retrying = Task {
            for await _ in context.retries {
                if await connection.state == .connected, let link = await connection.session {
                    if await !Self.alive(link.client, timeout: probeTimeout) { await link.close() }
                } else {
                    await connection.retryNow()
                }
            }
        }
        let preference = FollowPreference(host.multiplexer)
        let preferring = Task {
            for await value in context.preferences { preference.set(value) }
        }
        await connection.start()
        var live: Task<Void, Never>?
        var finished = false
        for await state in states {
            switch state {
            case .disconnected:
                continue
            case .connected:
                guard let link = await connection.session else { continue }
                live?.cancel()
                let gate = ReadyGate()
                live = Task { await driver.serve(link, preference: preference, gate: gate, events: events) }
                let first = await gate.first(timeout: firstTopology)
                guard !Task.isCancelled else { break }
                events.yield(.ready(client: link.client, hello: link.hello, multiplexers: link.multiplexers,
                                    versions: link.versions, topology: first))
                switch gate.open() {
                case .topology(let later): events.yield(.topology(later))
                case .noBackend: events.yield(.noBackend)
                case nil: break
                }
            case .reconnecting, .connecting, .authenticating, .bootstrapping:
                if case .reconnecting = state { live?.cancel(); live = nil }
                events.yield(.link(HostLink(state)))
            case .failed:
                live?.cancel()
                live = nil
                events.yield(.link(HostLink(state)))
                finished = true
            }
            if finished || Task.isCancelled { break }
        }
        live?.cancel()
        retrying.cancel()
        preferring.cancel()
        await connection.cancel()
        events.finish()
    }

    /// SSH, the helper and its greeting: the session `HostConnection` keeps until it is lost.
    private func establish(_ host: HostRecord, context: HostSessionContext, keys: KeyCache,
                           phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> HelperLink {
        var credentials: [SSHCredential] = []
        switch host.auth {
        case .key:
            credentials.append(.key(try await keys.key(context)))
        case .password:
            let password: String?
            do { password = try await context.password() } catch { throw HostRefusal(error.localizedDescription) }
            if let password { credentials.append(.password(password)) }
        }
        // Keyboard-interactive last: PAM passwords and one-time codes, answered in the Hosts sheet.
        credentials.append(.keyboardInteractive { challenge in
            await context.keyboardInteractive(HostLoginChallenge(
                name: challenge.name, instruction: challenge.instruction,
                prompts: challenge.prompts.map { .init(text: $0.text, echo: $0.echo) }))
        })
        let ssh = try await SSHHostSession.establish(
            endpoint: SSHEndpoint(host: host.address, port: host.port, username: host.user), credentials: credentials,
            trust: HostKeyQuestion(verify: context.verifyHostKey), binaries: binaries,
            capabilities: context.launch.capabilities, environment: context.launch.environment,
            keepalive: keepalive, keepaliveMax: keepaliveMax, phase: phase)
        let connection = HelperConnection(read: ssh.helper.read, write: ssh.helper.write)
        do {
            let hello: HelperSession.Info = try await connection.request("hello", params: Hello(features: Self.features))
            guard hello.version == HelperBinary.version else {
                throw HostRefusal("The helper on \(host.name) speaks another protocol version. Update Dispatch.")
            }
            guard let limit = hello.limit, let chunkKind = hello.chunkKind, let chunkLimit = hello.chunkLimit else {
                throw HostRefusal("The helper on \(host.name) did not report its transport limits.")
            }
            try await connection.configure(limit: limit, chunkKind: chunkKind, chunkLimit: chunkLimit, ops: hello.ops)
            let client = HelperClient(connection)
            async let kinds: [TabsMultiplexer] = connection.request("multiplexers.list", params: [String: String]())
            async let backends = client.backends()
            let rows = try await kinds
            return HelperLink(ssh: ssh, client: client, hello: hello, rows: rows, backends: (try? await backends) ?? [])
        } catch {
            connection.close()
            await ssh.close()
            throw error
        }
    }

    /// While connected: the chosen multiplexer's topology (following the host's preference live) and the latency.
    /// Ends when cancelled (the link was lost).
    private func serve(_ link: HelperLink, preference: FollowPreference, gate: ReadyGate,
                       events: AsyncStream<HostSessionEvent>.Continuation) async {
        let pinging = Task {
            while !Task.isCancelled {
                let started = ContinuousClock.now
                let echoed: [String: String]? = try? await link.client.connection.request("echo", params: [String: String]())
                if echoed != nil { events.yield(.latency(ContinuousClock.now - started)) }
                try? await Task.sleep(for: pingInterval)
            }
        }
        defer { pinging.cancel() }
        let follower = MultiplexerFollower(client: link.client, rows: link.rows, backends: link.backends,
                                           preference: preference, reopenDelay: reopenDelay)
        await follower.run(following: { events.yield(.following($0)) }, topology: { topology in
            if gate.offer(topology) { events.yield(.topology(topology)) }
        }, none: {
            if gate.none() { events.yield(.noBackend) }
        })
    }

    /// Whether the helper answers `echo` within `timeout` (after a network change: a dead link is closed and reconnects).
    static func alive(_ client: HelperClient, timeout: Duration) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let asking = Task {
                let echoed: [String: String]? = try? await client.connection.request("echo", params: [String: String]())
                once.run { continuation.resume(returning: echoed != nil) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.run { continuation.resume(returning: false) }
                asking.cancel()
            }
        }
    }

    /// The multiplexer whose topology a session follows, without starting anything on the host: the host's choice;
    /// else herdr while its server runs (herdr is preferred, plan 3.2); else tmux (its open just fails without a
    /// server); else herdr. New space goes to the same one (`HostSession.following`).
    static func choose(rows: [TabsMultiplexer], backends: [HelperBackend], override: String?, herdrRunning: Bool) -> MultiplexerChoice? {
        MultiplexerChoice.choose(multiplexers: rows, backends: backends, override: override ?? (herdrRunning ? "herdr" : "tmux"))
    }

    /// Final failures need the user (no retry): the transport's refusals, a key that cannot be read, an incompatible
    /// helper. Everything else (network, a helper that died) is retried with the backoff.
    @Sendable static func refused(_ error: any Error) -> Bool {
        error is HostRefusal || HostConnectionPolicy.refused(error)
    }

    private struct Hello: Encodable, Sendable { let features: [String] }
}

/// A failure only the user can fix; its text is the host's failed line.
struct HostRefusal: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The live connection the reconnect policy watches: SSH, the helper's stdio channel and the greeted client.
final class HelperLink: MobileTransport.HostSession {
    let ssh: SSHHostSession
    let client: HelperClient
    let hello: HelperSession.Info
    /// `multiplexers.list` with the `multiplexers.versions` fields.
    let rows: [TabsMultiplexer]
    let backends: [HelperBackend]

    init(ssh: SSHHostSession, client: HelperClient, hello: HelperSession.Info, rows: [TabsMultiplexer], backends: [HelperBackend]) {
        self.ssh = ssh
        self.client = client
        self.hello = hello
        self.rows = rows
        self.backends = backends
    }

    var multiplexers: [HelperClient.Multiplexer] { Self.installed(rows) }
    var versions: [String: String] { Self.versions(rows) }

    /// The multiplexers installed on the host, as the host session lists them (the helper's native one aside).
    static func installed(_ rows: [TabsMultiplexer]) -> [HelperClient.Multiplexer] {
        rows.filter { $0.installed != false && $0.name != "native" }
            .map { HelperClient.Multiplexer(mux: $0.mux, name: $0.name, external: $0.external, program: $0.program) }
    }

    /// Versions by name ("tmux": "3.7").
    static func versions(_ rows: [TabsMultiplexer]) -> [String: String] {
        Dictionary(rows.compactMap { row in row.version.map { (row.name, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Lost when the SSH connection ends or the helper exits; then both are closed, so a helper that died never
    /// leaves its SSH connection open behind the next one.
    func closed() async {
        let ssh = ssh
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await ssh.connection.closed(); once.run { continuation.resume() } }
            Task { _ = await ssh.helper.exitStatus(); once.run { continuation.resume() } }
        }
        await close()
    }

    func close() async {
        client.connection.close()
        await ssh.close()
    }
}

/// Runs its body once, from whichever caller comes first.
final class Once: Sendable {
    private let done = Mutex(false)
    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// The host key decision, through the session's trust on first use.
private struct HostKeyQuestion: HostKeyTrust {
    let verify: @Sendable (HostKeyOffer) async -> Bool

    func evaluate(_ key: HostKeyInfo) async -> HostKeyDecision {
        guard let offer = HostKeyOffer(key) else { return .reject }
        return await verify(offer) ? .trust : .reject
    }
}

extension HostKeyOffer {
    /// The offer from the key the server presented (its OpenSSH line holds the wire blob).
    init?(_ key: HostKeyInfo) {
        let parts = key.openSSH.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        self.init(host: key.host, port: key.port, algorithm: key.algorithm, key: blob)
    }
}

/// The host's key, read from the Keychain once per run (Face ID asks once per foreground session, not per reconnect).
/// A key deleted since is dropped, never used for another login.
actor KeyCache {
    private var cached: SSHKey?
    static let missing = "This host's key is no longer on this iPhone. Choose another in Edit."

    func key(_ context: HostSessionContext) async throws -> SSHKey {
        if let cached {
            guard await context.keyAvailable() else {
                self.cached = nil
                throw HostRefusal(Self.missing)
            }
            return cached
        }
        var material: KeyMaterial?
        do { material = try await context.key() } catch { throw HostRefusal(error.localizedDescription) }
        guard let read = material else { throw HostRefusal(Self.missing) }
        // An imported file and its passphrase are wiped once the engine holds the parsed key (and on failure).
        defer {
            if case .openSSH(let file, let passphrase) = read {
                file.wipe()
                passphrase?.wipe()
            }
            material = nil
        }
        let key: SSHKey
        switch read {
        case .ed25519(let value): key = SSHKey(ed25519: value)
        case .secureEnclaveP256(let value): key = SSHKey(secureEnclave: value)
        case .openSSH(let file, let passphrase):
            do { key = try SSHKey.openSSH(file.data, passphrase: passphrase?.data) } catch { throw HostRefusal(error.localizedDescription) }
        }
        cached = key
        return key
    }
}

/// Holds back topologies until `.ready` went out with the first one; afterwards the caller yields them itself. The
/// helper saying it has no backend (`none`) ends the wait early: `.ready` goes out without a topology and opening the
/// gate hands over the `.noBackend` to send after it.
final class ReadyGate: Sendable {
    /// What arrived while the gate was closed and did not go out with `.ready`.
    enum Pending: Equatable, Sendable {
        case topology(HelperTopology)
        case noBackend
    }
    private struct State {
        var open = false
        /// The wait is over (`.ready` has or will have its answer): a later arrival is pending.
        var resolved = false
        var first: HelperTopology?
        var pending: Pending?
        var waiter: CheckedContinuation<HelperTopology?, Never>?
    }
    private let state = Mutex(State())

    /// A topology arrived; true when the gate is open and the caller should yield it.
    func offer(_ topology: HelperTopology) -> Bool {
        let (yield, waiter) = state.withLock { state -> (Bool, CheckedContinuation<HelperTopology?, Never>?) in
            if state.open { return (true, nil) }
            if state.first == nil, !state.resolved {
                state.first = topology
                guard let waiter = state.waiter else { return (false, nil) }
                state.waiter = nil
                state.resolved = true
                return (false, waiter)
            }
            state.pending = .topology(topology)
            return (false, nil)
        }
        waiter?.resume(returning: topology)
        return yield
    }

    /// The followed multiplexer has no server; true when the gate is open and the caller should yield `.noBackend`.
    func none() -> Bool {
        let (yield, waiter) = state.withLock { state -> (Bool, CheckedContinuation<HelperTopology?, Never>?) in
            if state.open { return (true, nil) }
            state.pending = .noBackend
            guard state.first == nil, !state.resolved else { return (false, nil) }
            state.resolved = true
            defer { state.waiter = nil }
            return (false, state.waiter)
        }
        waiter?.resume(returning: nil)
        return yield
    }

    /// The first topology, or nil after `timeout`, once the helper said it has no backend, or at once when the
    /// waiting task is cancelled (a disconnect must not keep the link for the rest of the wait).
    func first(timeout: Duration) async -> HelperTopology? {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.expire()
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> HelperTopology?? in
                    if let first = state.first, !state.resolved { state.resolved = true; return .some(first) }
                    if state.resolved { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            expire()
        }
    }

    /// The wait is over without a first topology: the waiter (if any) gets nil.
    private func expire() {
        let waiter = state.withLock { state -> CheckedContinuation<HelperTopology?, Never>? in
            state.resolved = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// Opens the gate; returns what arrived while it was closed and did not go out with `.ready`: a later topology,
    /// the first when it came just after the wait expired, or the helper's report that it has no backend.
    func open() -> Pending? {
        state.withLock { state in
            state.open = true
            defer { state.pending = nil }
            return state.pending
        }
    }
}
