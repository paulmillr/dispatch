import Observation
import XCTest
@testable import DispatchMobile

@MainActor
final class HostSessionTests: XCTestCase {
    private typealias Step = ScriptedHostSessionDriver.Step

    private let key = SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(1), count: 32))
    private let otherKey = SSHKeyEncoding.string("ssh-ed25519") + SSHKeyEncoding.string(Array(repeating: UInt8(2), count: 32))

    private func host(_ name: String = "studio", auth: HostRecord.Auth = .password) -> HostRecord {
        HostRecord(name: name, address: name + ".local", user: "alex", auth: auth)
    }

    private func registry(_ driver: ScriptedHostSessionDriver, hosts: [HostRecord] = [], active: Bool = false) -> HostSessions {
        HostSessions(store: HostStore(url: nil, hosts: hosts),
                     keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                     knownHosts: KnownHostStore(url: nil), driver: driver, active: active)
    }

    /// Every value `read` gives as it changes, observed as SwiftUI would.
    @MainActor private final class Recorder<Value> {
        private(set) var seen: [Value] = []
        private let read: @MainActor () -> Value
        init(_ read: @escaping @MainActor () -> Value) {
            self.read = read
            track()
        }
        private func track() {
            seen.append(withObservationTracking { read() } onChange: { [weak self] in
                Task { @MainActor in self?.track() }
            })
        }
    }

    private func steps(_ steps: [Step]) -> ScriptedHostSessionDriver { ScriptedHostSessionDriver { _ in steps } }

    func testConnectRunsThroughTheLinkStatesToConnected() async throws {
        let driver = ScriptedHostSessionDriver()
        let session = registry(driver, hosts: [host()]).ordered[0]
        let links = Recorder { session.link }
        XCTAssertEqual(session.link, .disconnected)
        session.connect()
        try await TestSupport.eventually { session.latency != nil }
        XCTAssertEqual(links.seen.first, .disconnected)
        XCTAssertEqual(links.seen.last, .connected)
        XCTAssertNotNil(session.client)
        XCTAssertEqual(session.hello?.identity?.os_label, "macOS 26.1")
        XCTAssertEqual(session.multiplexers.map(\.name), ["tmux"])
        XCTAssertEqual(session.multiplexerLine, "tmux 3.7")
        XCTAssertEqual(session.latency, .microseconds(160), "The spike's loopback ping")
        XCTAssertEqual(session.topology?.nodes.filter { $0.kind == .workspace }.map(\.name), ["docs", "billing"])

        session.disconnect()
        XCTAssertEqual(session.link, .disconnected)
        XCTAssertNil(session.client, "The client exists only while connected")
        XCTAssertNil(session.latency)
        XCTAssertNotNil(session.topology, "The last topology stays for the host's labels")
    }

    /// The client, hello and multiplexers arrive with `.connected` in one update: no observer sees a connected
    /// session without its client.
    func testConnectedNeverShowsWithoutItsClient() async throws {
        let session = registry(ScriptedHostSessionDriver(), hosts: [host()]).ordered[0]
        let states = Recorder { (link: session.link, client: session.client != nil) }
        session.connect()
        try await TestSupport.eventually { session.latency != nil }
        XCTAssertFalse(states.seen.contains { $0.link == .connected && !$0.client })
        XCTAssertTrue(states.seen.contains { $0.link == .connected && $0.client })
    }

    func testReconnectDropsTheClientAndRetryNowWakesTheDriver() async throws {
        let ready = Step.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["herdr", "tmux"]),
                               versions: ["herdr": "0.9.3"], topology: nil)
        let since = Date()
        let driver = steps([.event(.link(.connecting)), ready,
                            .event(.link(.reconnecting(attempt: 1, since: since))), .awaitRetry,
                            .event(.link(.connecting)), ready, .hold])
        let session = registry(driver, hosts: [host()]).ordered[0]
        session.connect()
        try await TestSupport.eventually { session.link == .reconnecting(attempt: 1, since: since) }
        XCTAssertNil(session.client)
        XCTAssertEqual(session.multiplexerLine, "herdr 0.9.3", "herdr is preferred when both are installed")
        session.retryNow()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertNotNil(session.client)
        XCTAssertEqual(driver.runs(session.id), 1, "Retry wakes the same run rather than starting another")
    }

    func testFailureEndsTheRunAndRetryStartsAnother() async throws {
        let driver = steps([.event(.link(.connecting)), .event(.link(.failed("Connection refused")))])
        let session = registry(driver, hosts: [host()]).ordered[0]
        session.connect()
        try await TestSupport.eventually { session.link == .failed("Connection refused") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(session.link, .failed("Connection refused"), "A failure stays until the user or a retry acts")
        session.retryNow()
        try await TestSupport.eventually { driver.runs(session.id) == 2 }
    }

    func testMultiplexerPreference() async throws {
        let driver = steps([.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["native", "herdr", "tmux"]),
                                   versions: ["tmux": "3.7"], topology: nil), .hold])
        var record = host()
        record.multiplexer = .tmux
        let sessions = registry(driver, hosts: [record])
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertEqual(session.multiplexers.map(\.name), ["herdr", "tmux"], "native is never a space source")
        XCTAssertEqual(session.multiplexerLine, "tmux 3.7")
        record.multiplexer = .automatic
        sessions.update(record)
        XCTAssertTrue(sessions.ordered[0] === session, "A preference change keeps the connection")
        XCTAssertEqual(session.multiplexerLine, "herdr")
    }

    func testNoMultiplexerSaysNone() async throws {
        let driver = steps([.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["native"]),
                                   versions: [:], topology: nil), .hold])
        let session = registry(driver, hosts: [host()]).ordered[0]
        XCTAssertNil(session.multiplexerLine, "Unknown before the host was reached")
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertEqual(session.multiplexerLine, "none")
    }

    func testUnknownHostKeyAsksAndTrustIsRemembered() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        let driver = ScriptedHostSessionDriver { _ in
            [.event(.link(.connecting)), .hostKey(offer), .ready(hello: HostFixture.hello(), multiplexers: [], versions: [:], topology: nil), .hold]
        }
        let sessions = registry(driver, hosts: [host()])
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { sessions.trustRequest != nil }
        let request = try XCTUnwrap(sessions.trustRequest)
        XCTAssertEqual(request.kind, .unknown)
        XCTAssertEqual(request.hostName, "studio")
        XCTAssertEqual(request.offer.fingerprint, SSHKeyEncoding.fingerprint(key))
        XCTAssertEqual(session.link, .connecting, "Nothing proceeds while the question is open")
        sessions.resolve(request, trust: true)
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertEqual(sessions.knownHosts.verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key), .match)

        // The next connection matches without asking.
        session.disconnect()
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertTrue(sessions.trustRequests.isEmpty)
    }

    func testCancelledTrustFailsTheConnection() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        let driver = ScriptedHostSessionDriver { _ in [.hostKey(offer), .hold] }
        let sessions = registry(driver, hosts: [host()])
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { sessions.trustRequest != nil }
        sessions.resolve(try XCTUnwrap(sessions.trustRequest), trust: false)
        try await TestSupport.eventually { session.link == .failed("The host key wasn't trusted.") }
        XCTAssertEqual(sessions.knownHosts.verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key), .unknown)
        XCTAssertEqual(driver.refusals(session.id), 1)
    }

    func testDisconnectWithdrawsAnOpenQuestion() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        let sessions = registry(ScriptedHostSessionDriver { _ in [.hostKey(offer), .hold] }, hosts: [host()])
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { sessions.trustRequest != nil }
        session.disconnect()
        try await TestSupport.eventually { sessions.trustRequests.isEmpty }
    }

    /// The SSH transport asks about the host key and login from tasks that a disconnect does not cancel (the engine's
    /// callbacks): the question still goes when its run ends, and the next run's question replaces it instead of
    /// stacking a second sheet. A changed key shows one sheet however often the network retries.
    func testQuestionsEndWithTheirRunWhateverTheDriversTasks() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        let driver = DetachedQuestionDriver(offer: offer)
        let sessions = HostSessions(store: HostStore(url: nil, hosts: [host()]),
                                    keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                    knownHosts: KnownHostStore(url: nil), driver: driver, active: false)
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { sessions.trustRequests.count == 1 }
        driver.askLogin()
        try await TestSupport.eventually { sessions.trustRequests.count == 1 && sessions.loginPrompts.count == 1 }
        session.disconnect()
        try await TestSupport.eventually { sessions.trustRequests.isEmpty && sessions.loginPrompts.isEmpty }
        try await TestSupport.eventually { driver.answers.count == 2 }
        XCTAssertEqual(Set(driver.answers), ["trust: false", "login: nil"], "The old run's questions were answered as withdrawn")

        // A new run while an old run's question is still up (no disconnect in between): one sheet, the new one.
        session.connect()
        try await TestSupport.eventually { sessions.trustRequests.count == 1 }
        let first = try XCTUnwrap(sessions.trustRequest)
        driver.askAgain()
        try await TestSupport.eventually { sessions.trustRequest?.id != first.id }
        XCTAssertEqual(sessions.trustRequests.count, 1)

        // A changed key fails each retry the same way: still one sheet.
        sessions.knownHosts.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: otherKey)
        sessions.resolve(try XCTUnwrap(sessions.trustRequest), trust: false)
        for _ in 0..<3 { driver.askAgain() }
        try await TestSupport.eventually { driver.answers.filter { $0 == "trust: false" }.count >= 6 }
        XCTAssertEqual(sessions.trustRequests.count, 1)
        guard case .mismatch = sessions.trustRequest?.kind else { return XCTFail("\(String(describing: sessions.trustRequest))") }
    }

    /// Asks from detached tasks, as the transport's engine callbacks do; the stream ends only on cancellation.
    private final class DetachedQuestionDriver: HostSessionDriver, @unchecked Sendable {
        let offer: HostKeyOffer
        private let lock = NSLock()
        private var context: HostSessionContext?
        private var recorded: [String] = []
        var answers: [String] { lock.withLock { recorded } }
        init(offer: HostKeyOffer) { self.offer = offer }

        func run(_ host: HostRecord, context: HostSessionContext) -> AsyncStream<HostSessionEvent> {
            lock.withLock { self.context = context }
            askAgain()
            let (stream, continuation) = AsyncStream<HostSessionEvent>.makeStream()
            continuation.yield(.link(.connecting))
            return stream
        }

        func askAgain() {
            guard let context = lock.withLock({ self.context }) else { return }
            let offer = offer
            Task.detached { [self] in
                let trusted = await context.verifyHostKey(offer)
                self.lock.withLock { self.recorded.append("trust: \(trusted)") }
            }
        }

        func askLogin() {
            guard let context = lock.withLock({ self.context }) else { return }
            Task.detached { [self] in
                let answers = await context.keyboardInteractive(HostLoginChallenge(name: "", instruction: "", prompts: [.init(text: "Code:", echo: false)]))
                self.lock.withLock { self.recorded.append("login: \(answers.map { "\($0)" } ?? "nil")") }
            }
        }
    }

    func testMismatchIsAHardStopUntilRemoveAndRetry() async throws {
        let offer = HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: otherKey)
        let driver = ScriptedHostSessionDriver { _ in
            [.hostKey(offer), .ready(hello: HostFixture.hello(), multiplexers: [], versions: [:], topology: nil), .hold]
        }
        let sessions = registry(driver, hosts: [host()])
        sessions.knownHosts.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { if case .failed = session.link { true } else { false } }
        XCTAssertEqual(session.hostKeyMismatch, offer)
        let request = try XCTUnwrap(sessions.trustRequest)
        guard case .mismatch(let trusted) = request.kind else { return XCTFail("\(request.kind)") }
        XCTAssertEqual(trusted.key, key)

        // Trust is not an answer to a mismatch.
        sessions.resolve(request, trust: true)
        XCTAssertEqual(sessions.knownHosts.entry(host: "studio.local", port: 22)?.key, key)

        // No new handshake until the user acts: not on a network change, not on foregrounding.
        session.retryNow()
        sessions.setActive(true)
        sessions.networkChanged()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(driver.runs(session.id), 1, "the changed key is not asked for again by itself")
        XCTAssertEqual(session.hostKeyMismatch, offer)

        session.connect()
        try await TestSupport.eventually { sessions.trustRequest != nil }
        sessions.removeAndRetry(try XCTUnwrap(sessions.trustRequest))
        XCTAssertNil(session.hostKeyMismatch)
        try await TestSupport.eventually { sessions.trustRequest?.kind == .unknown }
        sessions.resolve(try XCTUnwrap(sessions.trustRequest), trust: true)
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertEqual(sessions.knownHosts.entry(host: "studio.local", port: 22)?.key, otherKey)
    }

    /// Two connections to one address and port (two host entries) ask about their keys at the same time; trusting the
    /// first makes the second, different key a mismatch rather than a second first use that would replace it.
    func testTrustingASecondKeyForTheSameAddressIsAMismatch() async throws {
        let first = HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .password)
        let second = HostRecord(name: "studio-root", address: "Studio.local", user: "root", auth: .password)
        let offers = [first.id: HostKeyOffer(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key),
                      second.id: HostKeyOffer(host: "Studio.local", port: 22, algorithm: "ssh-ed25519", key: otherKey)]
        let driver = ScriptedHostSessionDriver { host in
            [.hostKey(offers[host.id]!), .ready(hello: HostFixture.hello(), multiplexers: [], versions: [:], topology: nil), .hold]
        }
        let sessions = registry(driver, hosts: [first, second])
        for session in sessions.ordered { session.connect() }
        try await TestSupport.eventually { sessions.trustRequests.count == 2 }
        let requests = sessions.trustRequests
        XCTAssertTrue(requests.allSatisfy { $0.kind == .unknown })
        let firstRequest = try XCTUnwrap(requests.first { $0.hostID == first.id })
        let secondRequest = try XCTUnwrap(requests.first { $0.hostID == second.id })

        sessions.resolve(firstRequest, trust: true)
        try await TestSupport.eventually { sessions.session(first.id)?.link == .connected }
        sessions.resolve(secondRequest, trust: true)

        XCTAssertEqual(sessions.knownHosts.entry(host: "studio.local", port: 22)?.key, key, "The first trusted key stays")
        let secondSession = try XCTUnwrap(sessions.session(second.id))
        try await TestSupport.eventually { if case .failed = secondSession.link { true } else { false } }
        XCTAssertEqual(secondSession.hostKeyMismatch, offers[second.id])
        guard case .mismatch(let trusted)? = sessions.trustRequest?.kind else { return XCTFail("\(String(describing: sessions.trustRequest))") }
        XCTAssertEqual(trusted.key, key)
    }

    func testForegroundConnectsAllAndBackgroundDisconnects() async throws {
        let sessions = registry(ScriptedHostSessionDriver(), hosts: [host("a"), host("b")])
        XCTAssertTrue(sessions.ordered.allSatisfy { $0.link == .disconnected })
        sessions.scenePhaseChanged(.active)
        try await TestSupport.eventually { sessions.ordered.allSatisfy { $0.link == .connected } }
        sessions.scenePhaseChanged(.background)
        XCTAssertTrue(sessions.ordered.allSatisfy { $0.link == .disconnected && $0.client == nil })
        sessions.scenePhaseChanged(.inactive)
        XCTAssertTrue(sessions.ordered.allSatisfy { $0.link != .disconnected }, "Coming back connects at once")
        try await TestSupport.eventually { sessions.ordered.allSatisfy { $0.link == .connected } }
    }

    /// An active registry connects in its initializer, so the first frame shows hosts connecting, not offline.
    func testActiveRegistryStartsConnecting() {
        let sessions = registry(steps([.event(.link(.connecting)), .hold]), hosts: [host()], active: true)
        XCTAssertTrue(sessions.active)
        XCTAssertNotNil(sessions.ordered.first)
    }

    func testHelloSavesTheOSAndConnectionTime() async throws {
        let hello = HostFixture.hello(os: "Linux", distribution: "ubuntu", osName: "Ubuntu 24.04.1 LTS", label: "Ubuntu 24.04")
        let sessions = registry(steps([.ready(hello: hello, multiplexers: [], versions: [:], topology: nil), .hold]), hosts: [host()])
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        let saved = try XCTUnwrap(sessions.store.hosts.first)
        XCTAssertEqual(saved.osLabel, "Ubuntu 24.04")
        XCTAssertEqual(saved.system?.distribution, "ubuntu")
        XCTAssertNotNil(saved.lastConnected)
        XCTAssertEqual(session.host, saved)
    }

    func testAddingAVerifiedProbeKeepsItsConnection() async throws {
        let driver = ScriptedHostSessionDriver()
        let sessions = registry(driver, active: true)
        let record = host()
        let probe = sessions.probe(record)
        probe.connect()
        try await TestSupport.eventually { probe.link == .connected }
        sessions.add(record, probe: probe)
        XCTAssertTrue(sessions.session(record.id) === probe)
        XCTAssertEqual(probe.link, .connected)
        XCTAssertEqual(driver.runs(record.id), 1)
    }

    func testConnectionEditsReconnectAndRemovalForgets() async throws {
        let driver = ScriptedHostSessionDriver()
        let first = host("studio"), second = host("studio")
        let sessions = registry(driver, hosts: [first], active: true)
        sessions.knownHosts.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        try sessions.keys.setPassword("pw", for: first.id)
        let session = try XCTUnwrap(sessions.session(first.id))
        try await TestSupport.eventually { session.link == .connected }

        var renamed = first
        renamed.name = "Studio"
        sessions.update(renamed)
        XCTAssertTrue(sessions.session(first.id) === session)
        XCTAssertEqual(session.host.name, "Studio")
        XCTAssertEqual(session.link, .connected)

        var moved = renamed
        moved.port = 2222
        sessions.update(moved)
        let replacement = try XCTUnwrap(sessions.session(first.id))
        XCTAssertFalse(replacement === session)
        XCTAssertEqual(session.link, .disconnected)
        try await TestSupport.eventually { replacement.link == .connected }

        // Another host at the same address keeps the shared host key; the last one forgets it.
        sessions.add(second)
        var secondMoved = second
        secondMoved.port = 2222
        sessions.update(secondMoved)
        sessions.knownHosts.trust(host: "studio.local", port: 2222, algorithm: "ssh-ed25519", key: key)
        sessions.remove(first.id)
        XCTAssertNil(sessions.session(first.id))
        XCTAssertEqual(replacement.link, .disconnected)
        let password = try await sessions.keys.password(for: first.id)
        XCTAssertNil(password)
        XCTAssertNotNil(sessions.knownHosts.entry(host: "studio.local", port: 2222))
        sessions.remove(second.id)
        XCTAssertNil(sessions.knownHosts.entry(host: "studio.local", port: 2222))
        XCTAssertNotNil(sessions.knownHosts.entry(host: "studio.local", port: 22), "Only the removed host's own key")
    }

    /// Line three's OS: the helper's label, else the os-release name, else macOS with its version.
    func testOSLabel() {
        let label = HostFixture.hello(label: "macOS 26.1").identity!
        XCTAssertEqual(HostRecord.osLabel(label), "macOS 26.1")
        let linux = HostFixture.hello(os: "Linux", distribution: "ubuntu", osName: "Ubuntu 24.04.1 LTS", label: nil).identity!
        XCTAssertEqual(HostRecord.osLabel(linux), "Ubuntu 24.04.1 LTS")
        XCTAssertEqual(HostRecord.osLabel(HostFixture.hello(label: nil).identity!), "macOS 26.1", "Version without a label")
        XCTAssertEqual(HostRecord.osLabel(HostFixture.hello(label: nil, version: nil).identity!), "macOS")
    }

    /// After a reconnect the previous helper's snapshot stays for the rows but is stale next to the new client until the
    /// connection's first live one (node ids are per helper); the same for the launch cache's.
    func testAKeptTopologyIsStaleUntilTheConnectionsFirstLiveOne() async throws {
        let first = HostFixture.topology(), second = HostFixture.topology([.init(name: "web", cwd: "/w", tabs: 1, agents: 0)])
        let ready = { (topology: HelperTopology?) in
            Step.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:], topology: topology)
        }
        let driver = steps([ready(first), .awaitRetry, .event(.link(.reconnecting(attempt: 1, since: Date()))), .awaitRetry,
                            ready(nil), .awaitRetry, .event(.topology(second)), .hold])
        let session = registry(driver, hosts: [host()]).ordered[0]
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertTrue(session.topologyIsLive, "ready with this connection's first topology")
        session.retryNow()
        try await TestSupport.eventually { if case .reconnecting = session.link { true } else { false } }
        XCTAssertFalse(session.topologyIsLive)
        XCTAssertEqual(session.topology, first, "kept for the rows while reconnecting")
        session.retryNow()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertNotNil(session.client, "the client is there for backends.create and open")
        XCTAssertEqual(session.topology, first)
        XCTAssertFalse(session.topologyIsLive, "the previous helper's snapshot next to the new client is stale")
        session.retryNow()
        try await TestSupport.eventually { session.topology == second }
        XCTAssertTrue(session.topologyIsLive)

        let cached = registry(steps([ready(nil), .hold]), hosts: [host()]).ordered[0]
        cached.restore(hello: HostFixture.hello(), multiplexers: [], versions: [:], following: "tmux", topology: first)
        XCTAssertFalse(cached.topologyIsLive, "the launch cache's snapshot is never live")
        cached.connect()
        try await TestSupport.eventually { cached.link == .connected }
        XCTAssertFalse(cached.topologyIsLive)
    }

    /// A connection that reports no backend (no tmux server) clears the kept spaces instead of keeping them forever; a
    /// snapshot that arrives after the link dropped does not count as live.
    func testNoBackendClearsTheKeptSpaces() async throws {
        let ready = Step.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:], topology: nil)
        let driver = steps([ready, .awaitRetry, .event(.noBackend),
                            .awaitRetry, .event(.link(.reconnecting(attempt: 1, since: Date()))), .event(.topology(HostFixture.topology())),
                            .hold])
        let session = registry(driver, hosts: [host()]).ordered[0]
        session.restore(hello: HostFixture.hello(), multiplexers: [], versions: [:], following: "tmux", topology: HostFixture.topology())
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertNotNil(session.topology)
        session.retryNow()
        try await TestSupport.eventually { session.topology == nil }
        XCTAssertTrue(session.topologyIsLive, "known now: this connection has no spaces")
        session.retryNow()
        try await TestSupport.eventually { if case .reconnecting = session.link { true } else { false } }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(session.topology, "a snapshot after the drop belongs to no connection")
        XCTAssertFalse(session.topologyIsLive)
    }

    /// A switch of the followed multiplexer drops the old one's snapshot and leaves the host's spaces unknown until the
    /// new one answers, with a snapshot or with no server (Spaces offers New space only once they are known to be none).
    func testAMultiplexerSwitchIsUnknownUntilItAnswers() async throws {
        let ready = Step.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["herdr", "tmux"]), versions: [:],
                               topology: HostFixture.topology())
        let driver = steps([.event(.following("tmux")), ready, .awaitRetry, .event(.following("herdr")), .awaitRetry,
                            .event(.noBackend), .awaitRetry, .event(.following("tmux")), .awaitRetry,
                            .event(.topology(HostFixture.topology())), .hold])
        let session = registry(driver, hosts: [host()]).ordered[0]
        // Spaces' tmux or herdr mark, as each change is observed: never the multiplexer the spaces are leaving.
        let marks = Recorder { session.spacesMultiplexer }
        session.connect()
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertFalse(session.switchingMultiplexer)
        XCTAssertEqual(TabsHost(session).multiplexer, "tmux")
        session.retryNow()
        try await TestSupport.eventually { session.following == "herdr" }
        XCTAssertNil(session.topology)
        XCTAssertTrue(session.switchingMultiplexer)
        XCTAssertFalse(TabsHost(session).live, "Spaces does not know the host's spaces yet")
        XCTAssertNil(TabsHost(session).multiplexer, "nor where they come from")
        session.retryNow()
        try await TestSupport.eventually { !session.switchingMultiplexer }
        XCTAssertTrue(TabsHost(session).live, "known now: herdr has no server")
        XCTAssertEqual(TabsHost(session).multiplexer, "herdr")
        session.retryNow()
        try await TestSupport.eventually { session.following == "tmux" }
        XCTAssertTrue(session.switchingMultiplexer)
        session.retryNow()
        try await TestSupport.eventually { session.topology != nil }
        XCTAssertFalse(session.switchingMultiplexer)
        XCTAssertEqual(session.spacesMultiplexer, "tmux")
        let seen = marks.seen.reduce(into: [String?]()) { seen, mark in if seen.last != .some(mark) { seen.append(mark) } }
        XCTAssertEqual(seen, [nil, "tmux", nil, "herdr", nil, "tmux"])
    }

    /// The mark comes from the launch cache's followed multiplexer at once (with its cached spaces), and a host that
    /// follows none shows none.
    func testTheSpacesMarkStartsFromTheCache() {
        let session = registry(steps([.hold]), hosts: [host()]).ordered[0]
        XCTAssertNil(session.spacesMultiplexer)
        session.restore(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["herdr", "tmux"]), versions: [:],
                        following: "herdr", topology: HostFixture.topology())
        XCTAssertEqual(session.spacesMultiplexer, "herdr")
        XCTAssertEqual(TabsHost(session).multiplexer, "herdr")
    }

    /// Unreadable trusted host keys refuse every connection with a clear state, without running the driver, until the
    /// user resets (or the file reads again); a write failure of the trusted keys reaches Spaces' save notice.
    func testUnreadableKnownHostsRefuseToConnectUntilReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("known_hosts.json")
        try Data("not json".utf8).write(to: url)
        let driver = ScriptedHostSessionDriver()
        let sessions = HostSessions(store: HostStore(url: nil, hosts: [host()]),
                                    keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                    knownHosts: KnownHostStore(url: url), driver: driver, active: true)
        let session = sessions.ordered[0]
        let actions: SpacesHostActions = sessions
        XCTAssertEqual(session.link, .failed(KnownHostStore.unreadableLink))
        XCTAssertTrue(actions.knownHostsUnreadable)
        session.retryNow()
        sessions.networkChanged()
        XCTAssertEqual(driver.runs(session.id), 0, "nothing is sent to any host")
        XCTAssertEqual(sessions.backgroundSession(host()).refusal?(), KnownHostStore.unreadableLink, "background refresh too")

        actions.retryKnownHosts()
        XCTAssertTrue(actions.knownHostsUnreadable, "still unreadable")
        actions.resetKnownHosts()
        XCTAssertFalse(actions.knownHostsUnreadable)
        try await TestSupport.eventually { session.link == .connected }
        XCTAssertEqual(driver.runs(session.id), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".unreadable-") }.count, 1)

        // A failed write of a newly trusted key: kept in memory, named in Spaces' notice, retried.
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        sessions.knownHosts.trust(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key)
        XCTAssertEqual(sessions.knownHosts.verify(host: "studio.local", port: 22, algorithm: "ssh-ed25519", key: key), .match)
        XCTAssertTrue(actions.saveFailure?.hasPrefix("Trusted host keys aren't saved on this iPhone: ") == true)
        try FileManager.default.removeItem(at: folder)
        actions.retrySave()
        XCTAssertNil(actions.saveFailure)
    }

    /// Post-connect steps (Pi's `installation.install` per connection) run after every ready connection, with its client.
    func testPostConnectStepsRunOnEveryConnection() async throws {
        let ready = Step.ready(hello: HostFixture.hello(), multiplexers: [], versions: [:], topology: nil)
        let driver = steps([ready, .event(.link(.reconnecting(attempt: 1, since: Date()))), .awaitRetry, ready, .hold])
        let sessions = registry(driver, hosts: [host()])
        var calls: [(link: HostLink, client: HelperClient)] = []
        sessions.postConnect = [{ session, client in calls.append((session.link, client)) }]
        let session = sessions.ordered[0]
        session.connect()
        try await TestSupport.eventually { calls.count == 1 }
        try await TestSupport.eventually { if case .reconnecting = session.link { true } else { false } }
        session.retryNow()
        try await TestSupport.eventually { calls.count == 2 }
        XCTAssertEqual(calls.map(\.link), [.connected, .connected])
        XCTAssertFalse(calls[0].client === calls[1].client, "Each connection's own client")
    }

    /// The helper runs with the spike's grant, and the New host sheet discloses every capability in it.
    func testHelperGrantMatchesTheSpikeAndTheStatement() {
        XCTAssertEqual(HelperLaunch().command(sha256: "<sha256>"),
                       #"exec "$HOME/.dispatch/bin/versions/<sha256>/dispatch-helper" --remote --capabilities agent.events,agent.inspect,agent.pi,agent.pi.configure,agent.queue,agent.side,agent.submit,agent.version,backend.register,cancel,events,file.read,file.text,herdr.rpc,herdr.start,herdr.terminal,hooks.configure,host.identity,input.window,shell.lifecycle,stats.ping,stats.processes,stats.sample,tmux.pane --stdio"#)
        XCTAssertEqual(HelperLaunch().command(sha256: "abc"), HelperGrant.command(sha256: "abc"))
        XCTAssertFalse(HelperLaunch().pty)
        XCTAssertTrue(HelperLaunch().environment.isEmpty)
        for capability in HelperGrant.capabilities {
            let disclosure = HelperGrant.disclosures.first { capability.hasPrefix($0.prefix) }
            XCTAssertNotNil(disclosure, "\(capability) is not disclosed")
            if let disclosure { XCTAssertTrue(HelperGrant.statement.contains(disclosure.phrase), disclosure.phrase) }
        }
    }
}
