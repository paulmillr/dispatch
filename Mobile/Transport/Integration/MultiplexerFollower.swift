import Foundation
import Synchronization

/// The host's multiplexer preference while a driver runs: Edit host and Settings change it on a live connection, and
/// the follower picks the new choice without reconnecting (`HostSessionContext.preferences`).
final class FollowPreference: Sendable {
    private struct State {
        var value: HostRecord.MultiplexerPreference
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state: Mutex<State>

    init(_ value: HostRecord.MultiplexerPreference) { state = Mutex(State(value: value)) }

    /// "herdr" or "tmux" when the host names one, nil for Automatic.
    var override: String? {
        let value = state.withLock { $0.value }
        return value == .automatic ? nil : value.rawValue
    }

    func set(_ value: HostRecord.MultiplexerPreference) {
        let waiters = state.withLock { state -> [AsyncStream<Void>.Continuation] in
            guard state.value != value else { return [] }
            state.value = value
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.yield() }
    }

    /// Yields once for each later change. Take it before reading `value`, so no change falls between the two.
    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.waiters[id] = continuation }
        continuation.onTermination = { [weak self] _ in _ = self?.state.withLock { $0.waiters.removeValue(forKey: id) } }
        return stream
    }
}

/// Follows one multiplexer's topology on a connected helper (`backends.open` of its backend) and switches when the
/// host's preference changes, on the same connection. Connecting never starts a server: herdr's open starts one (and a
/// first workspace) when none runs, so herdr is followed only while its server runs; tmux's open just fails without a
/// server. Each round looks again (`multiplexers.list` with `running`, `backends.open`, `backends.list`; on the host a
/// `tmux -V` and a server probe) after a wait that starts at `reopenDelay` and doubles with each round in a row that
/// found no server, up to `reopenLimit` (2, 4, 8 … 60 s): a host without a server is not asked every 2 s for as long as
/// the phone stays connected. The backoff starts over after a round that followed a server, on a preference change
/// (which ends the round at once) and when `wake` rings (`HostSession.rediscover`: New space's `backends.create` may
/// have started a server, pull to refresh, foregrounding), which also ends the wait at once.
struct MultiplexerFollower: Sendable {
    let client: HelperClient
    /// `multiplexers.list` as the connection began (with the `multiplexers.versions` fields).
    var rows: [TabsMultiplexer]
    var backends: [HelperBackend]
    let preference: FollowPreference
    var reopenDelay: Duration = .seconds(2)
    var reopenLimit: Duration = .seconds(60)
    var wake = MultiplexerWake()
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// How one round ended.
    private enum Round: Sendable {
        /// The preference changed, or the wake rang: the next round now, the backoff from the start.
        case changed, woken
        /// The wait after the round passed; `delivered`: the round followed a server.
        case waited(delivered: Bool)
        case cancelled
    }

    /// The wait after a round that found no server, when `misses` rounds before it found none either.
    static func backoff(after misses: Int, first: Duration, limit: Duration) -> Duration {
        var delay = first
        for _ in 0..<min(max(misses, 0), 16) where delay < limit { delay *= 2 }
        return min(delay, limit)
    }

    /// Until cancelled: `following` with each new choice (nil: none), `topology` with each snapshot of the followed one,
    /// `none` after each round in which the followed multiplexer gave no snapshot (none chosen, herdr not running,
    /// tmux's open failed without a server): the host has no spaces now.
    func run(following: @escaping @Sendable (String?) -> Void, topology: @escaping @Sendable (HelperTopology) -> Void,
             activity: @escaping @Sendable () -> Void = {}, none: @escaping @Sendable () -> Void = {}) async {
        var rows = rows, backends = backends
        var reported: String??
        /// Rounds in a row that found no server.
        var misses = 0
        while !Task.isCancelled {
            // Before reading the preference: a change from here on ends this round at once. A ring from here on ends
            // its wait.
            let changes = preference.changes()
            let rings = wake.rings()
            let override = preference.override
            if Self.reportsRunning(rows), let fresh = try? await client.multiplexers() {
                rows = fresh
            }
            let herdrRunning = await Self.herdrRunning(rows) { await Self.processes(client) }
            let choice = SSHHostSessionDriver.choose(rows: rows, backends: backends, override: override, herdrRunning: herdrRunning)
            if reported != .some(choice?.name) {
                reported = .some(choice?.name)
                following(choice?.name)
            }
            let follow = choice.flatMap { $0.name != "herdr" || herdrRunning ? $0.route : nil }
            let client = client, sleep = sleep, first = reopenDelay
            let retry = Self.backoff(after: misses, first: reopenDelay, limit: reopenLimit)
            let round = await withTaskGroup(of: Round.self) { group in
                group.addTask {
                    var delivered = false
                    if let follow { delivered = await Self.follow(follow, on: client, topology: topology, activity: activity) }
                    guard !Task.isCancelled else { return .cancelled }
                    if !delivered { none() }
                    // No server yet (or it went away): look again after a while, at once on a ring.
                    let woken = await Self.wait(delivered ? first : retry, sleep: sleep, or: rings)
                    return woken ? .woken : .waited(delivered: delivered)
                }
                group.addTask {
                    var iterator = changes.makeAsyncIterator()
                    return await iterator.next() != nil ? .changed : .cancelled
                }
                let ended = await group.next() ?? .cancelled
                group.cancelAll()
                return ended
            }
            guard !Task.isCancelled else { return }
            switch round {
            case .changed, .woken: misses = 0
            case .waited(let delivered): misses = delivered ? 0 : misses + 1
            case .cancelled: break
            }
            if let fresh = try? await client.backends() { backends = fresh }
        }
    }

    /// Waits `delay`; true when `rings` yields first.
    private static func wait(_ delay: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
                             or rings: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await sleep(delay)
                return false
            }
            group.addTask {
                var iterator = rings.makeAsyncIterator()
                return await iterator.next() != nil
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Whether the rows carry the helper's `running` field (newer helpers, `multiplexers.versions`).
    static func reportsRunning(_ rows: [TabsMultiplexer]) -> Bool { rows.contains { $0.running != nil } }

    /// Whether a herdr server runs for this account, when herdr is installed: the helper's `running` field when its rows
    /// carry one, else a process named herdr in `stats.processes` (older helpers).
    static func herdrRunning(_ rows: [TabsMultiplexer], processes: @Sendable () async -> [String]?) async -> Bool {
        guard let herdr = rows.first(where: { $0.name == "herdr" && $0.external && $0.installed != false }) else { return false }
        if let running = herdr.running { return running }
        return await processes()?.contains("herdr") ?? false
    }

    /// The names of the account's processes (`stats.processes`), nil when the helper cannot say.
    static func processes(_ client: HelperClient) async -> [String]? {
        struct Row: Decodable { let name: String }
        struct Processes: Decodable {
            let rows: [Row]
            init(from decoder: any Decoder) throws {
                var values = try decoder.unkeyedContainer()
                rows = try values.decode([Row].self)
            }
        }
        let processes: Processes? = try? await client.connection.request("stats.processes", params: [String: String]())
        return processes?.rows.map(\.name)
    }

    /// `backends.open` until the subscription ends (the server went away, the open failed) or the task is cancelled.
    /// True when it delivered at least one topology.
    static func follow(_ route: HelperBackend.Route, on client: HelperClient,
                       topology: @escaping @Sendable (HelperTopology) -> Void,
                       activity: @escaping @Sendable () -> Void) async -> Bool {
        let (ended, end) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delivered = Once()
        let id: UInt64
        do {
            id = try await client.connection.subscribe("backends.open", params: route, notify: { method, params in
                switch try? HelperClient.Update.decode(method, params) {
                case .topology(let value)?:
                    delivered.set()
                    topology(value)
                // An agent's state or newest message changed (`agents.activity`): what changed is read with `chat.list`.
                case .agent?: activity()
                default: break
                }
            }, ended: { _ in end.yield() })
        } catch { return false }
        await withTaskCancellationHandler {
            var iterator = ended.makeAsyncIterator()
            _ = await iterator.next()
        } onCancel: {
            client.connection.cancel(id)
            end.finish()
        }
        return delivered.isSet
    }
}
