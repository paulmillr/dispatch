import Foundation
import Synchronization

/// The host's multiplexer preference while a driver runs: host detail and Settings change it on a live connection, and
/// the follower picks the new choice without reconnecting (`HostSessionContext.preferences`).
final class FollowPreference: Sendable {
    private struct State {
        var value: HostRecord.MultiplexerPreference
        var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state: Mutex<State>

    init(_ value: HostRecord.MultiplexerPreference) { state = Mutex(State(value: value)) }

    var value: HostRecord.MultiplexerPreference { state.withLock { $0.value } }

    /// "herdr" or "tmux" when the host names one, nil for Automatic.
    var override: String? {
        let value = value
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
/// server and is tried again every `reopenDelay` (New space's `backends.create` may start one).
struct MultiplexerFollower: Sendable {
    let client: HelperClient
    /// `multiplexers.list` as the connection began (with the `multiplexers.versions` fields).
    var rows: [TabsMultiplexer]
    var backends: [HelperBackend]
    let preference: FollowPreference
    var reopenDelay: Duration = .seconds(2)

    /// Until cancelled: `following` with each new choice (nil: none), `topology` with each snapshot of the followed one,
    /// `none` after each round in which the followed multiplexer gave no snapshot (none chosen, herdr not running,
    /// tmux's open failed without a server): the host has no spaces now.
    func run(following: @escaping @Sendable (String?) -> Void, topology: @escaping @Sendable (HelperTopology) -> Void,
             none: @escaping @Sendable () -> Void = {}) async {
        var rows = rows, backends = backends
        var reported: String??
        while !Task.isCancelled {
            // Before reading the preference: a change from here on ends this round at once.
            let changes = preference.changes()
            let override = preference.override
            if Self.reportsRunning(rows), let fresh: [TabsMultiplexer] = try? await client.connection.request(
                "multiplexers.list", params: [String: String]()) {
                rows = fresh
            }
            let herdrRunning = await Self.herdrRunning(rows) { await Self.processes(client) }
            let choice = SSHHostSessionDriver.choose(rows: rows, backends: backends, override: override, herdrRunning: herdrRunning)
            if reported != .some(choice?.name) {
                reported = .some(choice?.name)
                following(choice?.name)
            }
            let follow = choice.flatMap { $0.name != "herdr" || herdrRunning ? $0.route : nil }
            let client = client, delay = reopenDelay
            _ = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    var delivered = false
                    if let follow { delivered = await Self.follow(follow, on: client, topology: topology) }
                    guard !Task.isCancelled else { return false }
                    if !delivered { none() }
                    // No server yet (or it went away): look again after a while.
                    try? await Task.sleep(for: delay)
                    return false
                }
                group.addTask {
                    var iterator = changes.makeAsyncIterator()
                    return await iterator.next() != nil
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            guard !Task.isCancelled else { return }
            if let fresh = try? await client.backends() { backends = fresh }
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
    @discardableResult
    static func follow(_ route: HelperBackend.Route, on client: HelperClient,
                       topology: @escaping @Sendable (HelperTopology) -> Void) async -> Bool {
        let (ended, end) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delivered = Flag()
        let id: UInt64
        do {
            id = try await client.connection.subscribe("backends.open", params: route, notify: { method, params in
                if case .topology(let value)? = try? HelperClient.Update.decode(method, params) {
                    delivered.set()
                    topology(value)
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

    private final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }
}
