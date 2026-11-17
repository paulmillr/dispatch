import CryptoKit
import Foundation
import MobileTransport
import Synchronization

/// The app's `HostSessionDriver` (docs/ios.md, Areas and seams): one SSH connection per host through
/// `MobileTransport`, kept up by its `HostConnection` reconnect policy. Each connection verifies the host key through
/// the session (trust on first use, a mismatch is the hard stop Hosts shows), logs in with the host's key or password
/// (and keyboard-interactive through the Hosts sheet), installs the bundled helper for the host's platform under its
/// hash-named path, starts it on a plain exec channel (straight from the host's cache in one command when it is there:
/// `helper(on:)`) and greets it with the iPhone's features. While connected it
/// follows the topology of the host's multiplexer (`backends.open` of the chosen backend) and measures latency with
/// `echo`, on the shared clock's ticks the stats' samples leave free (`HostTraffic`). A host with its Helper switch
/// off stops after the login: the connection is plain SSH (`.plain(nil)`, shells only). So does a connection whose helper cannot start while the SSH connection stays up (`fallback`:
/// `.plain(reason)`); login, host key and network failures stay refusals and reconnects. Each connection decides again.
/// Cancelling the run (`HostSession.disconnect()`) closes the connection; nothing on the host stops.
struct SSHHostSessionDriver: HostSessionDriver {
    /// The hello features the phone asks for (docs/ios.md, Helper contract); what the reply accepted is
    /// `HostSession.features`. With `stdio.liveness` the helper ends after 45 s without a frame from the phone: the
    /// latency ping (`pingInterval`, or the stats' sample on the ticks it covers) keeps it alive while connected, so it
    /// must stay at most `livenessPing`. With
    /// `screens.host` the helper reads the screens of the terminals the phone attaches from tmux or herdr itself, so the
    /// phone publishes none (`TerminalFeed.hostsScreens`); with `terminals.follow` too a terminal only a conversation
    /// uses holds its output (`TerminalPresence`). With `sizes.steady` opening a tab resizes its tmux window alone, not
    /// every other window of its session. With `topology.bound` the first topology names the agents already running in
    /// tmux (the helper's discovery looked at its panes first, at most 1 s, within `firstTopology`). With
    /// `agents.activity` the followed backend's `agent.changed` says when an agent's state, newest message or turn
    /// changed, so Agents reads its rows again (`ChatConversations.activityChanged`) without the thread open. With
    /// `chat.limits` the unfolded working row reads the agent's plan limits (`ChatLimitsReader`).
    static let features = ["interaction.options", "chat.list", "projects.recent", "multiplexers.versions", "terminals.coalesce",
                           "launch.names", "stdio.liveness", ChatAttachment.feature,
                           "memberships.append", HelperSession.screensHost, HelperSession.terminalsFollow, "sizes.steady",
                           "topology.bound", "agents.activity", HelperSession.chatLimits]
    /// The longest a `topology.bound` helper holds a tmux server's first topology (helper/PROTOCOL.md, `BOUND_WAIT`).
    static let boundWait: Duration = .seconds(1)
    /// The longest gap between pings `stdio.liveness` allows (helper/PROTOCOL.md: at least every 15 s).
    static let livenessPing: Duration = .seconds(15)

    /// The bundled helpers (`darwin-arm64`, `linux-aarch64`, `linux-x86_64`), the app's `helper` folder.
    var binaries = Bundle.main.bundleURL.appendingPathComponent("helper", isDirectory: true)
    /// The latency ping, which is also the liveness traffic `stdio.liveness` needs (at most `livenessPing`): on each tick
    /// of the shared clock (`HostTraffic.interval`) that no stats sample covers (`HostPulse`).
    var pingInterval: Duration = HostTraffic.interval
    /// How long `.ready` waits for the first topology, so no row shows a connected host without its spaces.
    var firstTopology: Duration = .seconds(2)
    /// Between `backends.open` attempts while no multiplexer server runs (New space starts one).
    var reopenDelay: Duration = .seconds(2)
    /// A keepalive after each `keepalive` of silence from the server; the one falling due while `keepaliveMax` are
    /// unanswered ends the connection, so a silent link counts as lost after (`keepaliveMax` + 1) × `keepalive`
    /// (60 s at 15 s × 3) on either engine.
    var keepalive: Duration = .seconds(15)
    var keepaliveMax = 3
    /// How long a connected link may take to answer `echo` after a network change before it counts as lost.
    var probeTimeout: Duration = .seconds(3)
    var clock: any ReconnectClock = SystemReconnectClock()
    /// After a failed `hello`, how long the helper's channel may take to end before the helper counts as running but not
    /// answering rather than exited.
    var exitWait: Duration = .seconds(2)
    /// The SSH login each connection starts from (SSHDriverTests script it, and the helper on it).
    var login: HostLoginStep = SSHLogin.connect
    /// Which keys logged in where: a key host's next connection sends that key direct first. The app's is saved
    /// (`HostSessions.keyLogins`); this one is for the run only.
    var keyLogins = KeyLogins.shared

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
        // Once connected, the automatic reconnects ask the user nothing, as the Mac's (BatchMode): a host that needs a
        // keyboard-interactive answer (a one-time code) fails them, and Connect asks again.
        let connectedOnce = Once()
        let connection = HostConnection<DriverLink>(clock: clock, refused: Self.refused) { phase in
            try await driver.establish(host, context: context, keys: keys, interactive: !connectedOnce.isSet, phase: phase)
        }
        let states = await connection.states()
        let probeTimeout = probeTimeout
        // retryNow (network change, foregrounding) races the policy's wait; while connected it checks the link, which a
        // change of network can leave dead until the keepalive gives up (60 s after the server's last packet).
        let retrying = Task {
            for await _ in context.retries {
                let session = await connection.state == .connected ? connection.session : nil
                if case .plain(let link)? = session {
                    // No helper to ask: a round trip on the SSH connection itself (no latency: it is not the helper's).
                    if await !link.login.alive(timeout: probeTimeout) { await link.close() }
                } else if case .helper(let link)? = session {
                    // An answer is a round trip like the ping's: the host's last update is now (pull to refresh).
                    let started = ContinuousClock.now
                    if await Self.alive(link.client, timeout: probeTimeout) {
                        events.yield(.latency(ContinuousClock.now - started))
                    } else {
                        await link.close()
                    }
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
        states: for await state in states {
            switch state {
            case .disconnected:
                continue
            case .connected:
                guard let session = await connection.session else { continue }
                connectedOnce.set()
                live?.cancel()
                live = nil
                switch session {
                case .plain(let plain):
                    events.yield(.plain(reason: plain.reason, shells: plain.login.shells))
                case .helper(let link):
                    let gate = ReadyGate()
                    live = Task {
                        await driver.serve(link, preference: preference, gate: gate, pulse: context.pulse, events: events)
                    }
                    let first = await gate.first(timeout: firstTopology)
                    guard !Task.isCancelled else { break }
                    events.yield(.ready(client: link.client, hello: link.hello,
                                        multiplexers: HelperLink.installed(link.rows),
                                        versions: HelperLink.versions(link.rows), topology: first))
                    switch gate.open() {
                    case .topology(let later): events.yield(.topology(later))
                    case .noBackend: events.yield(.noBackend)
                    case nil: break
                    }
                }
            case .reconnecting, .connecting, .authenticating, .bootstrapping:
                if case .reconnecting = state { live?.cancel(); live = nil }
                events.yield(.link(HostLink(state)))
            case .failed:
                live?.cancel()
                live = nil
                events.yield(.link(HostLink(state)))
                break states
            }
            if Task.isCancelled { break }
        }
        live?.cancel()
        retrying.cancel()
        preferring.cancel()
        await connection.cancel()
        events.finish()
    }

    /// SSH, then the helper and its greeting unless the host goes without (`HostRecord.helper`) or the helper cannot
    /// start (`fallback`): the session `HostConnection` keeps until it is lost.
    private func establish(_ host: HostRecord, context: HostSessionContext, keys: KeyCache, interactive: Bool,
                           phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> DriverLink {
        let endpoint = host.endpoint
        var credentials: [SSHCredential] = []
        var keyPlan: KeyLogins.Plan?
        switch host.auth {
        case .key:
            let plan = keyLogins.plan(try await keys.key(context), at: endpoint)
            credentials += plan.credentials
            keyPlan = plan
        case .password:
            let password: String?
            do { password = try await context.password() } catch { throw HostRefusal(error.localizedDescription) }
            if let password { credentials.append(.password(password)) }
        }
        // Keyboard-interactive last: PAM passwords and one-time codes, answered in the Hosts sheet (never on an automatic
        // reconnect).
        if interactive {
            credentials.append(.keyboardInteractive { challenge in
                await context.keyboardInteractive(HostLoginChallenge(
                    name: challenge.name, instruction: challenge.instruction,
                    prompts: challenge.prompts.map { .init(text: $0.text, echo: $0.echo) }))
            })
        }
        let login = try await self.login(endpoint, credentials, HostKeyQuestion(verify: context.verifyHostKey), keepalive,
                                         keepaliveMax, phase)
        if let keyPlan { keyLogins.loggedIn(keyPlan, credential: login.credential) }
        guard host.helper else { return .plain(PlainLink(login: login, reason: nil)) }
        do {
            return .helper(try await helper(on: login, host: host, context: context, phase: phase))
        } catch {
            // Cancelled (a disconnect): nothing more runs on the host for a connection nobody wants.
            guard !Task.isCancelled else {
                await login.close()
                throw error
            }
            var open = login.isOpen
            // A channel that ended without a word may be the connection going: its disconnect can arrive after the
            // channel's end, so ask the connection itself before calling it a helper failure.
            if open, Self.ambiguous(error) { open = await login.alive(timeout: probeTimeout) }
            if let reason = Self.fallback(error, open: open) { return .plain(PlainLink(login: login, reason: reason)) }
            await login.close()
            // The connection dropped meanwhile: whatever the step reported, this is a loss to reconnect from, unless the
            // connection's own end is final (a host key changed at a rekey), as it is once connected.
            if !open, !(error is CancellationError) {
                if let end = login.lossError, Self.refused(end) { throw end }
                throw ConnectionLost(login.lossReason ?? HostConnectionPolicy.describe(error))
            }
            throw error
        }
    }

    /// The helper on `login`, greeted, with its multiplexers. The first attempt starts it straight from the host's cache
    /// in one command, its `hello` written at once (`fromCache`); when that command started no helper (`CacheMiss`: the cache
    /// lacks it or failed a check, another platform, anything unexpected) the full bootstrap follows on the same
    /// connection (probe, cache check, upload, start) and greets again. A helper that exits before greeting
    /// (`HelperExited`: a home mounted noexec answers 126) is installed and started once more under the fallback root the
    /// bootstrap names (`HelperBootstrap.fallbackRoot`), on the same connection; a second failure, or none named, is the
    /// failure. Each attempt's channel is closed when it fails; the login is the caller's. A cancelled run starts no
    /// further attempt.
    private func helper(on login: any HostLogin, host: HostRecord, context: HostSessionContext,
                        phase: @escaping @Sendable (HostConnectionPhase) async -> Void) async throws -> HelperLink {
        var root = HelperBootstrap.Root.home, retried = false, fromCache = true
        while true {
            try Task.checkCancellation()
            let process = try await login.bootstrapHelper(binaries: binaries, capabilities: context.launch.capabilities,
                                                          environment: context.launch.environment, root: root,
                                                          fromCache: fromCache, phase: phase)
            do {
                return try await greet(process, on: login, host: host)
            } catch is CacheMiss where fromCache && login.isOpen {
                fromCache = false
            } catch let exited as HelperExited {
                guard !retried, login.isOpen,
                      let next = HelperBootstrap.fallbackRoot(after: exited.status, installed: exited.installed) else { throw exited }
                root = next
                retried = true
                fromCache = false
            }
        }
    }

    /// `hello`, the transport limits and the multiplexers of a started helper. A helper that is there but unusable (it
    /// exited before answering: `HelperExited`; no answer, another protocol version, no transport limits:
    /// `HelperUnavailable`) closes its channel. A channel that ended without starting a helper is `CacheMiss` (a launch
    /// from the cache that found none), or the server's refusal of the exec request.
    private func greet(_ process: any HelperProcess, on login: any HostLogin, host: HostRecord) async throws -> HelperLink {
        let connection = process.connection
        do {
            let hello: HelperSession.Info
            do {
                hello = try await connection.request("hello", params: HelperHello(features: Self.features))
            } catch let error where !(error is CancellationError) {
                // The channel closed under the request: a helper that exited (it could not run, its cached copy failed the
                // check) says why in its status and on stderr.
                if let end = await Self.end(of: process, within: exitWait) {
                    // Refused before anything ran: what a refused exec channel always gave (`fallback`).
                    if let refusal = end.refusal { throw refusal }
                    // Every report line arrived before the channel's end: no `installed` now is a launch from the cache
                    // that started no helper, not a helper's exit.
                    guard let installed = process.installed else { throw CacheMiss() }
                    throw HelperExited(status: end.status, stderr: await process.stderr(), installed: installed)
                }
                throw HelperUnavailable("The helper on \(host.name) did not answer: \(HostConnectionPolicy.describe(error))")
            }
            do {
                try await hello.configure(connection)
            } catch HelperHello.Failure.protocolVersion {
                throw HelperUnavailable("The helper on \(host.name) speaks another protocol version. Update Dispatch.")
            } catch HelperHello.Failure.transportLimits {
                throw HelperUnavailable("The helper on \(host.name) did not report its transport limits.")
            }
            let client = HelperClient(connection)
            async let kinds = client.multiplexers()
            async let backends = client.backends()
            let rows = try await kinds
            return HelperLink(login: login, process: process, client: client, hello: hello, rows: rows,
                              backends: (try? await backends) ?? [])
        } catch {
            connection.close()
            await process.close()
            throw error
        }
    }

    /// The helper's end, when its channel ends within `wait` (`status` nil: no exit status, a signal, a lost channel or
    /// a refused exec request, `refusal`); nil while it still runs.
    static func end(of process: any HelperProcess, within wait: Duration) async -> HelperEnd? {
        // An exit status wait does not end on cancellation, only with the channel (closed right after).
        await answer(within: wait, or: nil) {
            do { return HelperEnd(status: try await process.exitStatus()) } catch {
                return HelperEnd(status: nil, refusal: error as? SSHTransportError ?? .channelClosed)
            }
        }
    }

    /// A helper step failure that a lost connection also produces (the channel ended with no status or word): checked
    /// with `HostLogin.alive` before it counts as the helper's.
    static func ambiguous(_ error: any Error) -> Bool {
        if let exited = error as? HelperExited { return exited.status == nil }
        return (error as? SSHTransportError) == .channelClosed
    }

    /// The text a connection goes on as plain SSH with when the helper step failed with `error` while the SSH connection
    /// is still `open`; nil when it is not a helper failure (the connection reconnects or is refused, as without a
    /// fallback). Helper failures: the bootstrap's (platform unidentified or unsupported, missing binary, upload or cache
    /// failure), a refused or closed exec channel, too much probe output, a helper that exited before greeting
    /// (`HelperExited`, the bootstrap's text for its status and stderr), and `HelperUnavailable`.
    static func fallback(_ error: any Error, open: Bool) -> String? {
        guard open else { return nil }
        // The bundled helper file could not be read (`HelperBootstrap.install` reads it with `Data(contentsOf:)`): the
        // bootstrap's own text for a missing helper. Classified here, the one mapping, rather than in the transport.
        if let file = error as? CocoaError, file.isFileError { return "SSH helper is missing or invalid." }
        if let unavailable = error as? HelperUnavailable { return unavailable.message }
        if let exited = error as? HelperExited {
            return HelperBootstrap.launchFailure(status: exited.status, stderr: exited.stderr, installed: exited.installed)
        }
        guard let error = error as? SSHTransportError else { return nil }
        switch error {
        case .bootstrap(let reason):
            return reason
        case .commandFailed(status: -1, let stderr):
            // The engine's refused channel request (`DMS_REFUSED`).
            return stderr.isEmpty ? "The host refused to run the helper." : "The host refused to run the helper: \(stderr)"
        case .commandFailed, .outputLimit, .channelClosed:
            return HostConnectionPolicy.describe(error)
        default:
            return nil
        }
    }

    /// While connected: the chosen multiplexer's topology (following the host's preference live) and the latency.
    /// Ends when cancelled (the link was lost).
    private func serve(_ link: HelperLink, preference: FollowPreference, gate: ReadyGate, pulse: HostPulse,
                       events: AsyncStream<HostSessionEvent>.Continuation) async {
        let interval = pingInterval
        let pinging = Task {
            await Self.ping(link.client, every: interval, pulse: pulse) { events.yield(.latency($0)) }
        }
        defer { pinging.cancel() }
        let follower = MultiplexerFollower(client: link.client, rows: link.rows, backends: link.backends,
                                           preference: preference, reopenDelay: reopenDelay)
        await follower.run(following: { events.yield(.following($0)) }, topology: { topology in
            if gate.offer(topology) { events.yield(.topology(topology)) }
        }, activity: { events.yield(.agentActivity) }, none: {
            if gate.none() { events.yield(.noBackend) }
        })
    }

    /// The liveness ping and the latency while connected, until cancelled: `echo` at once (the latency on connecting),
    /// then on each tick of `interval` on the shared clock (`HostTraffic`; the first at most a second late) that the
    /// stats' sample does not cover (`HostPulse`): the helper hears a frame every tick, and a tick's frames leave together.
    /// A ping does not wait for the last one's answer, which can sit behind a flood of output for a minute (the helper
    /// reads the request at once, `requests.backlog`): the next tick sends its own.
    static func ping(_ client: HelperClient, every interval: Duration, pulse: HostPulse,
                     now: @escaping @Sendable () -> Date = { System.date() },
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     latency: @escaping @Sendable (Duration) -> Void) async {
        await withDiscardingTaskGroup { group in
            var tick: Date?
            while !Task.isCancelled {
                if tick.map({ !pulse.covers($0) }) ?? true {
                    group.addTask {
                        let started = ContinuousClock.now
                        if await Self.echo(client) { latency(ContinuousClock.now - started) }
                    }
                }
                let date = now()
                let next = HostTraffic.tick(after: date, minimum: min(.seconds(1), interval / 2), grid: interval)
                do { try await sleep(.milliseconds(Int((next.timeIntervalSince(date) * 1000).rounded(.up)))) } catch {
                    group.cancelAll()
                    return
                }
                tick = next
            }
            group.cancelAll()
        }
    }

    /// Whether the helper answers `echo` within `timeout` (after a network change: a dead link is closed and reconnects).
    static func alive(_ client: HelperClient, timeout: Duration) async -> Bool {
        await answer(within: timeout, or: false) { await Self.echo(client) }
    }

    /// Whether the helper answered an `echo`.
    private static func echo(_ client: HelperClient) async -> Bool {
        let echoed: [String: String]? = try? await client.connection.request("echo", params: [String: String]())
        return echoed != nil
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

}

/// The helper started but cannot be used on this connection (no answer to `hello`, another protocol version, no transport
/// limits): the connection goes on as plain SSH with this text (`SSHHostSessionDriver.fallback`).
struct HelperUnavailable: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// How a helper's channel ended: its exit status, nil after a signal or a lost channel; `refusal` when the server refused
/// the exec request.
struct HelperEnd: Equatable, Sendable {
    let status: Int32?
    var refusal: SSHTransportError?
}

/// A launch from the cache (`HostLogin.bootstrapHelper(fromCache: true)`) ended without starting a helper: the full
/// bootstrap follows on the same connection. Never the connection's end: if it escapes (the connection went meanwhile),
/// it is a loss like any other.
struct CacheMiss: Error, Equatable {}

/// The helper's channel ended before it answered `hello` (`status` nil: no exit status). Retried once under the
/// fallback root, else the connection goes on as plain SSH with `HelperBootstrap.launchFailure`'s text.
struct HelperExited: Error, Equatable {
    let status: Int32?
    let stderr: String
    let installed: HelperBootstrap.Installed
}

/// The SSH connection dropped while the helper was being started: retried like any loss.
struct ConnectionLost: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A failure only the user can fix; its text is the host's failed line.
struct HostRefusal: Error, LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What the reconnect policy keeps per connection: the helper's link, or the plain SSH login.
enum DriverLink: MobileTransport.HostSession {
    case helper(HelperLink)
    case plain(PlainLink)

    private var session: any MobileTransport.HostSession {
        switch self {
        case .helper(let link): link
        case .plain(let link): link
        }
    }

    func closed() async { await session.closed() }
    func close() async { await session.close() }
    var lossReason: String? { session.lossReason }
    var lossError: (any Error)? { session.lossError }
}

/// A connection without a helper (plain SSH): the login, and why there is no helper (nil: the host's switch is off).
struct PlainLink: MobileTransport.HostSession {
    let login: any HostLogin
    let reason: String?

    func closed() async { await login.closed() }
    func close() async { await login.close() }
    var lossReason: String? { login.lossReason }
    var lossError: (any Error)? { login.lossError }
}

/// The live connection the reconnect policy watches: SSH, the helper's stdio channel and the greeted client.
final class HelperLink: MobileTransport.HostSession {
    let login: any HostLogin
    let process: any HelperProcess
    let client: HelperClient
    let hello: HelperSession.Info
    /// `multiplexers.list` with the `multiplexers.versions` fields.
    let rows: [TabsMultiplexer]
    let backends: [HelperBackend]

    init(login: any HostLogin, process: any HelperProcess, client: HelperClient, hello: HelperSession.Info,
         rows: [TabsMultiplexer], backends: [HelperBackend]) {
        self.login = login
        self.process = process
        self.client = client
        self.hello = hello
        self.rows = rows
        self.backends = backends
    }

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
        let login = login, process = process
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { await login.closed(); once.run { continuation.resume() } }
            Task { _ = try? await process.exitStatus(); once.run { continuation.resume() } }
        }
        // Before closing: afterwards the SSH connection's end is this close.
        let reason = login.lossReason ?? "The helper on the host stopped."
        let error = login.lossError as? SSHTransportError
        end.withLock { $0 = (reason, error) }
        await close()
    }

    private let end = Mutex<(reason: String?, error: SSHTransportError?)>((nil, nil))
    var lossReason: String? { end.withLock { $0.reason } }
    var lossError: (any Error)? { end.withLock { $0.error } }

    func close() async {
        client.connection.close()
        await process.close()
        await login.close()
    }
}

/// Runs its body once, from whichever caller comes first; also a flag set once (`set`, `isSet`).
final class Once: Sendable {
    private let done = Mutex(false)
    var isSet: Bool { done.withLock { $0 } }
    func set() { done.withLock { $0 = true } }
    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

/// `body`'s answer, or `late` once `timeout` passed first (`body`'s task is then cancelled). Both run on tasks of their
/// own: the caller's cancellation ends neither.
func answer<Answer: Sendable>(within timeout: Duration, or late: Answer,
                              _ body: @escaping @Sendable () async -> Answer) async -> Answer {
    let once = Once()
    return await withCheckedContinuation { continuation in
        let asking = Task {
            let value = await body()
            once.run { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            once.run { continuation.resume(returning: late) }
            asking.cancel()
        }
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
/// A key deleted since is dropped, never used for another login. An imported file is parsed by the SSH engine, whose
/// connections alone can use it: once Settings picked the other engine, the next connection reads the file again.
actor KeyCache {
    private var cached: SSHKey?
    /// The engine that parsed `cached`; nil for a key that signs in Swift (either engine takes it).
    private var parsedBy: SSHTransportEngine?
    static var missing: String { "This host's key is no longer on this \(MobileDevice.name). Choose another in Edit." }

    func key(_ context: HostSessionContext) async throws -> SSHKey {
        if let cached, parsedBy == nil || parsedBy == SSHTransportEngine.preferred {
            guard await context.keyAvailable() else {
                self.cached = nil
                throw HostRefusal(Self.missing)
            }
            return cached
        }
        cached = nil
        let material: KeyMaterial?
        do { material = try await context.key() } catch { throw HostRefusal(error.localizedDescription) }
        guard let read = material else { throw HostRefusal(Self.missing) }
        // An imported file and its passphrase are wiped once the engine holds the parsed key (and on failure).
        defer {
            if case .openSSH(let file, let passphrase) = read {
                file.wipe()
                passphrase?.wipe()
            }
        }
        let key: SSHKey
        var engine: SSHTransportEngine?
        switch read {
        case .ed25519(let value): key = SSHKey(ed25519: value)
        case .secureEnclaveP256(let value): key = SSHKey(secureEnclave: value)
        case .openSSH(let file, let passphrase):
            engine = SSHTransportEngine.preferred
            do { key = try SSHKey.openSSH(file.data, passphrase: passphrase?.data) } catch { throw HostRefusal(error.localizedDescription) }
        }
        cached = key
        parsedBy = engine
        return key
    }
}

/// Import key's parser in the app (`KeyStore.parser`): the built-in reader, then, for a file the store keeps for the
/// engine (every key but an unencrypted Ed25519 one, whose seed it keeps), the SSH engine in use, so a file that engine
/// refuses (a key type, an RSA key under 2048 bits, too many bcrypt rounds) or a wrong passphrase shows at import, with
/// the engine's text, rather than at the first connection.
struct EngineCheckedKeyParser: OpenSSHPrivateKeyParsing {
    var builtIn = BuiltInOpenSSHKeyParser()

    func parse(_ file: Data, passphrase: String?) throws -> ParsedOpenSSHKey {
        let parsed = try builtIn.parse(file, passphrase: passphrase)
        guard parsed.ed25519Seed == nil else { return parsed }
        let key: SSHKey
        do {
            key = try SSHKey.openSSH(file, passphrase: passphrase)
        } catch SSHTransportError.wrongPassphrase {
            throw OpenSSHKeyError.wrongPassphrase
        } catch {
            throw OpenSSHKeyError.unsupported(error.localizedDescription)
        }
        // The engine read the same key the file names.
        guard SSHKeyEncoding.fingerprint(parsed.publicKeyBlob) == key.fingerprint else { throw OpenSSHKeyError.malformed }
        return ParsedOpenSSHKey(algorithm: parsed.algorithm, publicKeyBlob: parsed.publicKeyBlob, comment: parsed.comment,
                                encrypted: parsed.encrypted, ed25519Seed: nil, passphraseVerified: true)
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
