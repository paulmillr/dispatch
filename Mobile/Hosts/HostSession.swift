import Foundation
import Observation

/// A step after a connection is ready (see `HostSession.postConnect`).
typealias HostPostConnectStep = @MainActor (HostSession, HelperClient) async -> Void

/// A host's connection state (docs/ios.md, Areas and seams).
enum HostLink: Equatable, Sendable {
    case disconnected, connecting, authenticating, bootstrapping, connected
    case reconnecting(attempt: Int, since: Date)
    case failed(String)

    var isConnected: Bool { self == .connected }
    /// On its way to connected.
    var isPending: Bool {
        switch self {
        case .connecting, .authenticating, .bootstrapping, .reconnecting: true
        default: false
        }
    }
}

/// The one object the UI observes per host (docs/ios.md, Areas and seams): its link, and while connected the helper
/// client, the `hello` record, the multiplexers and the latest topology. Other areas take the `HelperClient` and
/// topology from here and never see SSH.
@MainActor @Observable
final class HostSession: Identifiable {
    /// The saved record; `HostSessions` updates it in place when an edit keeps the connection (a rename, the
    /// multiplexer preference, the last connection time).
    private(set) var host: HostRecord
    nonisolated var id: UUID { hostID }
    private(set) var link: HostLink = .disconnected
    /// Non-nil only while connected.
    private(set) var client: HelperClient?
    /// The last `hello` (identity, OS line, schema); kept while offline for the host's labels.
    private(set) var hello: HelperSession.Info?
    /// The multiplexers installed on the host.
    private(set) var multiplexers: [HelperClient.Multiplexer] = []
    /// Their versions by name, when the driver knows them ("herdr": "0.9.3").
    private(set) var multiplexerVersions: [String: String] = [:]
    /// The multiplexer the driver follows (its topology is `topology`), when it chose one.
    private(set) var following: String?
    /// The latest snapshot; kept while reconnecting so Host detail keeps its spaces.
    private(set) var topology: HelperTopology?
    /// Whether `topology` came from the current connection's helper. False for the launch cache's snapshot and, after a
    /// reconnect, for the previous helper's until the first live one arrives: node ids are per helper connection, so
    /// nothing that sends them (terminal presences, tab commands, chat) may use a snapshot that is not live, and its
    /// rows show as stale. The client stays usable for what needs no node id (`backends.create`, `backends.open`).
    private(set) var topologyIsLive = false
    private(set) var latency: Duration?
    /// Set when the server's key differs from the trusted one: a hard stop until the user removes it and retries.
    private(set) var hostKeyMismatch: HostKeyOffer?

    @ObservationIgnored private let hostID: UUID
    @ObservationIgnored private let driver: any HostSessionDriver
    @ObservationIgnored private let context: (HostSession) -> HostSessionContext
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var retry: AsyncStream<Void>.Continuation?
    /// The running driver's multiplexer preference (`HostSessionContext.preferences`).
    @ObservationIgnored private var preference: AsyncStream<HostRecord.MultiplexerPreference>.Continuation?
    /// Called on the main actor with each `hello` (HostSessions saves the OS and the connection time).
    @ObservationIgnored var helloReceived: ((HostSession, HelperSession.Info) -> Void)?
    /// Runs after each connection is ready, in order, with that connection's client (`HostSessions.postConnect`:
    /// enabling Pi with `installation.install` on every connection, docs/ios.md, Helper contract). Cancelled when the
    /// connection goes away; the link is already `.connected` while it runs.
    @ObservationIgnored var postConnect: [HostPostConnectStep] = []
    @ObservationIgnored private var postConnectTask: Task<Void, Never>?
    /// Called on the main actor when a connection's client goes away (a drop, a reconnect, disconnect): what used it
    /// stops (`TerminalPresences.stopAll(host:)`) and reattaches after the next `.ready`.
    @ObservationIgnored var clientEnded: ((HostSession) -> Void)?
    /// Called on the main actor after anything the areas read changed (`HostSessions.changed`).
    @ObservationIgnored var changed: ((HostSession) -> Void)?
    /// Asked before each connection: a reason none may start now (the trusted host keys are unreadable); the link then
    /// fails with it and nothing is sent.
    @ObservationIgnored var refusal: (() -> String?)?

    /// `context` makes the driver's context for each run (host keys, secrets).
    init(host: HostRecord, driver: any HostSessionDriver, context: @escaping (HostSession) -> HostSessionContext) {
        self.host = host
        hostID = host.id
        self.driver = driver
        self.context = context
    }

    func connect() {
        guard task == nil else { return }
        if let reason = refusal?() {
            if link != .failed(reason) { link = .failed(reason) }
            changed?(self)
            return
        }
        hostKeyMismatch = nil
        // At once, not with the driver's first event: no frame shows a host offline after it was asked to connect.
        if !link.isPending { link = .connecting }
        defer { changed?(self) }
        let (retries, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        retry = continuation
        let (preferences, preferring) = AsyncStream<HostRecord.MultiplexerPreference>.makeStream(bufferingPolicy: .bufferingNewest(1))
        preference = preferring
        let base = context(self)
        let context = HostSessionContext(launch: base.launch, verifyHostKey: base.verifyHostKey, key: base.key,
                                         password: base.password, retries: retries, keyboardInteractive: base.keyboardInteractive,
                                         keyAvailable: base.keyAvailable, preferences: preferences)
        let events = driver.run(host, context: context)
        task = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.apply(event)
            }
            guard let self, !Task.isCancelled else { return }
            self.ended()
        }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        retry?.finish()
        retry = nil
        preference?.finish()
        preference = nil
        if link != .disconnected { link = .disconnected }
        drop()
        changed?(self)
    }

    /// Network change, foregrounding: a waiting reconnect tries at once, a connected session checks that its link
    /// still answers (the driver reconnects when it does not), a failed or idle session connects again, except after
    /// a host key mismatch: that hard stop waits for the user (Remove and retry, an edit), never re-handshaking by
    /// itself.
    func retryNow() {
        if task != nil {
            switch link {
            case .reconnecting, .connected: retry?.yield()
            default: break
            }
            return
        }
        guard hostKeyMismatch == nil else { return }
        connect()
    }

    /// The last-known state from the device's cache (`HostCache`, at launch): the lists show it at once and the live
    /// data replaces it as it arrives. Ignored once the session has heard from its helper.
    func restore(hello: HelperSession.Info?, multiplexers: [HelperClient.Multiplexer], versions: [String: String],
                 following: String?, topology: HelperTopology?) {
        guard client == nil, self.hello == nil, self.topology == nil else { return }
        self.hello = hello
        self.multiplexers = multiplexers.filter { $0.name != "native" }
        multiplexerVersions = versions
        self.following = following
        self.topology = topology
        changed?(self)
    }

    /// Records a host key mismatch (the session ends with a failure right after).
    func reportMismatch(_ offer: HostKeyOffer) { hostKeyMismatch = offer }

    /// A saved edit that kept the connection (`HostRecord.sameConnection`).
    /// A new multiplexer preference goes to the running driver, which follows it on the same connection.
    func update(_ record: HostRecord) {
        guard record.id == hostID, record != host else { return }
        let preferenceChanged = record.multiplexer != host.multiplexer
        host = record
        if preferenceChanged { preference?.yield(record.multiplexer) }
        changed?(self)
    }

    private func apply(_ event: HostSessionEvent) {
        defer { changed?(self) }
        switch event {
        case .link(let next):
            // `.connected` only arrives with `.ready`: a client, a hello and the multiplexers in the same update.
            guard next != .connected, next != link else { return }
            link = next
            if client != nil { drop() }
        case .ready(let client, let hello, let multiplexers, let versions, let topology):
            if let previous = self.client, previous !== client { clientEnded?(self) }
            self.client = client
            self.hello = hello
            self.multiplexers = multiplexers.filter { $0.name != "native" }
            multiplexerVersions = versions
            if let topology { self.topology = topology }
            // Without a first snapshot the one kept is the cache's or the last helper's: stale until a live one comes.
            if topologyIsLive != (topology != nil) { topologyIsLive = topology != nil }
            link = .connected
            helloReceived?(self, hello)
            postConnectTask?.cancel()
            if !postConnect.isEmpty {
                let steps = postConnect
                postConnectTask = Task { [weak self] in
                    for step in steps {
                        guard let self, !Task.isCancelled, self.client === client else { return }
                        await step(self, client)
                    }
                }
            }
        case .topology(let snapshot):
            // A snapshot still in flight when the link dropped is not this (absent) connection's.
            guard client != nil else { return }
            if topology != snapshot { topology = snapshot }
            if !topologyIsLive { topologyIsLive = true }
        case .noBackend:
            guard client != nil else { return }
            // No server: the kept snapshot's spaces are not there any more (or never were on this connection).
            if topology != nil { topology = nil }
            if !topologyIsLive { topologyIsLive = true }
        case .following(let name):
            guard following != name else { return }
            // Another multiplexer's spaces (the preference changed): the old one's snapshot is not this host's spaces any
            // more. A first choice (nil before) keeps the snapshot it had, cached or from the last connection.
            if following != nil, name != nil { topology = nil }
            following = name
        case .latency(let value):
            guard link == .connected else { return }
            latency = value
        }
    }

    private func ended() {
        task = nil
        retry?.finish()
        retry = nil
        preference?.finish()
        preference = nil
        if case .failed = link {} else { link = .disconnected }
        drop()
        changed?(self)
    }

    /// What exists only while connected.
    private func drop() {
        postConnectTask?.cancel()
        postConnectTask = nil
        if client != nil {
            client = nil
            clientEnded?(self)
        }
        if latency != nil { latency = nil }
        if topologyIsLive { topologyIsLive = false }
    }
}

extension HostSession {
    /// The multiplexer whose sessions are this host's spaces: the one the driver follows, else the host's preference
    /// when installed, else herdr, else tmux (plan 3.2).
    var activeMultiplexer: HelperClient.Multiplexer? {
        let installed = multiplexers
        if let following, let chosen = installed.first(where: { $0.name == following }) { return chosen }
        if host.multiplexer != .automatic, let chosen = installed.first(where: { $0.name == host.multiplexer.rawValue }) {
            return chosen
        }
        return installed.first { $0.name == "herdr" } ?? installed.first { $0.name == "tmux" }
    }

    /// "herdr 0.9.3", "tmux 3.7", "tmux", or "none" (M1f); nil before the host has been reached.
    var multiplexerLine: String? {
        guard hello != nil else { return nil }
        guard let active = activeMultiplexer else { return "none" }
        return [active.name, multiplexerVersions[active.name]].compactMap { $0 }.joined(separator: " ")
    }
}
