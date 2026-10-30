import XCTest
import os
@testable import DispatchApp

@MainActor
final class SSHStatisticsStoreTests: XCTestCase {
    func testResetOneHostClearsHistoryAndPreservesOtherProviders() throws {
        let store = SSHStatisticsStore(), host = HostID.authenticated("reset-one"), other = HostID.authenticated("keep-other")
        defer { store.reset() }
        let first = Provider(), second = Provider(account: "bob")
        let key = try XCTUnwrap(store.register(first, grant: .init(profile: .statistics), hostID: host))
        let otherKey = try XCTUnwrap(store.register(second, grant: .init(profile: .statistics), hostID: other))
        store.remove(first.id)
        XCTAssertNotNil(store.series[key])
        store.reset(host)
        XCTAssertNil(store.series[key])
        XCTAssertEqual(store.key(for: second.id), otherKey)
        XCTAssertEqual(store.keys(for: other), [otherKey])
    }

    private final class Provider: SSHStatisticsSampling {
        let id = SSHConnectionID()
        let scope: SSHIntegrationScope
        let host = "authenticated-machine"
        let uid: UInt32 = 1000
        var supportsStatistics = true
        var samples = 0
        var repeatsCounters = false
        var counter = 0
        var diskSamples = 0
        var failing = false
        var pending = 0
        var maximumPending = 0
        var supportsLatency = false
        var pingCalls = 0
        var pingFails = false
        var pendingPings = 0
        var maximumPendingPings = 0
        var blockPing = false
        var finishPing: CheckedContinuation<Void, Never>?
        init(account: String = "alice") {
            scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "build", configuration: "hostname host\nuser \(account)\n")!
        }
        // Outcomes are decided when called: a flag the test flips while a call is in flight changes only later calls.
        // A call takes its time through System.sleep, as the helper round trip it stands in for is recorded: on wall time
        // the providers' calls end in another order in replay, and identical timers take their recorded wakes in recorded
        // order (one account's 20 ms metrics loop then got another's 15 s timer and never sampled again).
        func sample() async throws -> SSHStatisticsCounters {
            samples += 1; pending += 1; maximumPending = max(maximumPending, pending)
            defer { pending -= 1 }
            let fails = failing
            try await System.sleep(for: .milliseconds(5), "sample")
            if fails { throw HerdrFailure("Disconnected") }
            if !repeatsCounters { counter += 1 }
            return .init(boot: "boot", monotonic: Double(samples * 2),
                         cpu: [.init(name: "cpu", busy: UInt64(counter), total: UInt64(counter * 2))])
        }
        func disks() async throws -> [SSHStatisticsDisk] {
            diskSamples += 1
            // Simulate a filesystem slower than the fast counter sampler.
            try await System.sleep(for: .milliseconds(150), "disks")
            return []
        }
        func ping() async throws {
            pingCalls += 1; pendingPings += 1
            maximumPendingPings = max(maximumPendingPings, pendingPings)
            defer { pendingPings -= 1 }
            if blockPing { await withCheckedContinuation { finishPing = $0 } }
            else { try await System.sleep(for: .milliseconds(5), "ping") }
            // Read as the reply comes: a ping in flight when a test flips pingFails answers the new way, so no success
            // lands after a test has turned replies into failures.
            if pingFails { throw HerdrFailure("Latency timeout") }
        }
    }

    func testBackgroundSamplingSlowsWithoutSubscribersAndOneSamplerServesMultipleViews() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(10), backgroundInterval: .milliseconds(40)), provider = Provider()
        let key = store.register(provider, grant: .init(profile: .statistics))!
        try await TestSupport.pause(for: .milliseconds(30))
        XCTAssertGreaterThan(provider.samples, 0)
        XCTAssertEqual(provider.diskSamples, 0)
        let background = provider.samples
        try await TestSupport.eventually { provider.samples > background }
        let first = store.subscribe(key)!, second = store.subscribe(key)!
        try await TestSupport.pause(for: .milliseconds(80))
        XCTAssertGreaterThan(provider.samples, 2)
        XCTAssertEqual(provider.maximumPending, 1)
        XCTAssertEqual(provider.diskSamples, 1)
        store.unsubscribe(first, from: key)
        let previous = provider.samples
        try await TestSupport.pause(for: .milliseconds(30))
        XCTAssertGreaterThan(provider.samples, previous)
        store.unsubscribe(second, from: key)
        try await TestSupport.pause(for: .milliseconds(20))
        let slowed = provider.samples
        try await TestSupport.eventually { provider.samples > slowed }
        try await TestSupport.eventually { provider.pending == 0 }
    }

    /// An unanswered latency probe ends at its limit instead of waiting for the reply
    /// (ported from SSHProtocolV2Tests' latency timeout).
    func testTimeoutEndsAnUnansweredOperationWithoutWaitingForIt() async throws {
        let started = ContinuousClock.now
        let unanswered = await Task { try await SSHTimeout.run(.milliseconds(100), "unanswered") { try await Task.sleep(for: .seconds(60)); return 0 } }.result
        XCTAssertThrowsError(try unanswered.get())
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        let answered = try await SSHTimeout.run(.seconds(5), "answered") { 42 }
        XCTAssertEqual(answered, 42)
    }

    func testLatencyTimeoutCancelsOnlyTheProbeAndLeavesTheHelperUsable() async throws {
        struct Nonce: Codable, Equatable, Sendable { let nonce: UInt64 }
        struct Request: Decodable { let method: String; let params: Nonce }
        struct Reply: Decodable { let result: Nonce }
        let frames = try HelperClientTests.fixture("live-tmux").frames
        let captured = try XCTUnwrap(frames["read"]?.last)
        let echo = try HelperClientTests.decode(Request.self, captured.body)
        let response = try XCTUnwrap(frames["write"]?.last)
        let expected = try HelperClientTests.decode(Reply.self, response.body).result
        let incoming = Pipe(), outgoing = Pipe()
        let client = HelperConnection(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting)
        let replay = HelperTransport(read: outgoing.fileHandleForReading, write: incoming.fileHandleForWriting)
        let canceled = expectation(description: "Only the unanswered probe was canceled")
        var decoder = HelperWire.Decoder(), requests: [UInt64] = [], cancellations: [UInt64] = []
        let sent = OSAllocatedUnfairLock(initialState: 0)
        replay.start(receive: { bytes in
            do {
                try decoder.feed(bytes) { message in
                    if message.kind == .cancel {
                        cancellations.append(message.id)
                        XCTAssertEqual(cancellations, [1]); canceled.fulfill()
                    } else {
                        requests.append(message.id); sent.withLock { $0 += 1 }
                        XCTAssertEqual(message.body, captured.body)
                        if requests.count == 2 {
                            replay.send(try HelperWire.encode(.init(kind: .response, id: message.id, body: response.body)))
                        }
                    }
                }
            } catch { XCTFail(String(describing: error)) }
        }, closed: { _ in })
        defer { client.close(); replay.close() }
        do {
            let _: Nonce = try await SSHTimeout.run(.milliseconds(100), "probe") {
                async let reply: Nonce = client.request(echo.method, params: echo.params)
                // The probe is out before its timeout ends it: replay ends the timer where capture did, and the pipe
                // between them is not recorded.
                try await TestSupport.eventually { sent.withLock { $0 } == 1 }
                return try await reply
            }
            XCTFail("An unanswered latency probe must time out")
        } catch { }
        let answered: Nonce = try await client.request(echo.method, params: echo.params)
        XCTAssertEqual(answered, expected)
        await fulfillment(of: [canceled], timeout: 5)
        XCTAssertEqual(requests, [1, 2]); XCTAssertEqual(cancellations, [1])
    }

    func testResetClearsRetainedSamplesAndCancelsInFlightLatency() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(10), backgroundInterval: .milliseconds(10),
            latencyInterval: .milliseconds(10), backgroundLatencyInterval: .milliseconds(10))
        let provider = Provider(); provider.supportsLatency = true
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        let entry = try XCTUnwrap(store.series[key])
        try await TestSupport.eventually { entry.latest != nil && entry.latency.milliseconds != nil }
        provider.blockPing = true
        _ = store.subscribe(key)
        try await TestSupport.eventually { provider.finishPing != nil }
        store.reset()
        XCTAssertTrue(store.series.isEmpty)
        XCTAssertNil(entry.latest)
        XCTAssertTrue(entry.history.isEmpty)
        XCTAssertNil(entry.latency.milliseconds)
        XCTAssertNil(entry.latency.date)
        provider.finishPing?.resume(); provider.finishPing = nil
        try await TestSupport.pause(for: .milliseconds(50))
        XCTAssertNil(entry.latest)
        XCTAssertNil(entry.disks)
        XCTAssertNil(entry.latency.milliseconds)
        XCTAssertTrue(entry.history.isEmpty)
        XCTAssertTrue(entry.providers.isEmpty)
        XCTAssertEqual(provider.pending, 0)
    }

    func testBackgroundHistoryKeepsCPUBaselineAcrossPopupCadenceChanges() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(10), backgroundInterval: .milliseconds(30)), provider = Provider()
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        let entry = try XCTUnwrap(store.series[key])
        try await TestSupport.eventually { entry.latest?.cpu == 50 }

        let beforeOpen = provider.samples
        let popup = try XCTUnwrap(store.subscribe(key))
        try await TestSupport.eventually { provider.samples > beforeOpen }
        XCTAssertEqual(entry.latest?.cpu, 50)

        provider.repeatsCounters = true
        let beforeRepeatedCounter = provider.samples
        try await TestSupport.eventually { provider.samples > beforeRepeatedCounter }
        XCTAssertNil(entry.history.last?.cpu)
        XCTAssertEqual(entry.latest?.cpu, 50, "A missing fresh rate must keep the last same-boot CPU value visible")
        provider.repeatsCounters = false
        try await TestSupport.eventually { entry.history.last?.cpu == 50 }

        store.unsubscribe(popup, from: key)
        XCTAssertEqual(entry.state, .ready)
        XCTAssertNotNil(entry.history.last?.cpu, "Closing the popup must not insert a chart gap")
        let beforeBackground = provider.samples
        try await TestSupport.eventually { provider.samples > beforeBackground }
        XCTAssertEqual(entry.latest?.cpu, 50)
    }

    func testFailoverUsesOnlyAlreadyLiveSameAccountConnections() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(10))
        let first = Provider(), second = Provider(), other = Provider(account: "bob")
        first.failing = true
        let key = store.register(first, grant: .init(profile: .statistics))!
        XCTAssertEqual(store.register(second, grant: .init(profile: .statistics)), key)
        XCTAssertNotEqual(store.register(other, grant: .init(profile: .statistics)), key)
        try await TestSupport.eventually { other.samples > 0 }
        let independentAccountSamples = other.samples
        let token = store.subscribe(key, preferred: first.id)!
        try await TestSupport.pause(for: .milliseconds(80))
        XCTAssertEqual(first.samples, 1)
        XCTAssertGreaterThan(second.samples, 0)
        XCTAssertEqual(other.samples, independentAccountSamples)
        XCTAssertEqual(store.series[key]?.state, .ready)
        store.remove(second.id)
        XCTAssertEqual(store.series[key]?.state, .stale)
        XCTAssertNotNil(store.series[key]?.latest)
        XCTAssertNil(store.series[key]?.history.last?.cpu)
        store.unsubscribe(token, from: key)
    }

    func testOrdinaryAndIncompatibleConnectionsCannotRegister() {
        let store = SSHStatisticsStore(), provider = Provider()
        XCTAssertNil(store.register(provider, grant: .init(profile: .ordinary)))
        provider.supportsStatistics = false
        XCTAssertNil(store.register(provider, grant: .init(profile: .statistics)))
        XCTAssertTrue(store.series.isEmpty)
    }

    func testLatencyRefreshesImmediatelyOnOpenSharesPollingAndSlowsAfterClose() async throws {
        let store = SSHStatisticsStore(latencyInterval: .milliseconds(20)), provider = Provider()
        provider.supportsLatency = true
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        defer { store.remove(provider.id) }
        let latency = try XCTUnwrap(store.series[key]?.latency)
        try await TestSupport.eventually { latency.state == .ready }
        XCTAssertGreaterThan(latency.milliseconds ?? 0, 0)
        let initial = provider.pingCalls
        try await TestSupport.pause(for: .milliseconds(80))
        XCTAssertEqual(provider.pingCalls, initial, "Closed popups use the 60-second interval")
        let one = try XCTUnwrap(store.subscribeLatency(key)), two = try XCTUnwrap(store.subscribeLatency(key))
        try await TestSupport.eventually { provider.pingCalls >= initial + 3 }
        XCTAssertEqual(provider.maximumPendingPings, 1)
        store.unsubscribeLatency(one, from: key)
        let previous = provider.pingCalls
        try await TestSupport.eventually { provider.pingCalls > previous }
        store.unsubscribeLatency(two, from: key)
        let closed = provider.pingCalls
        let metricSamples = provider.samples
        try await TestSupport.pause(for: .milliseconds(80))
        XCTAssertEqual(provider.pingCalls, closed)
        XCTAssertEqual(provider.samples, metricSamples, "Latency polling must not accelerate background metrics collection")
    }

    func testBackgroundLatencyPausesForSleepAndDisconnectAndRefreshesOnWake() async throws {
        let store = SSHStatisticsStore(backgroundLatencyInterval: .milliseconds(30)), provider = Provider()
        provider.supportsLatency = true
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .full)))
        let latency = try XCTUnwrap(store.series[key]?.latency)
        try await TestSupport.eventually { provider.pingCalls > 2 && latency.state == .ready }
        store.setSleeping(true)
        XCTAssertEqual(latency.state, .stale)
        let sleeping = provider.pingCalls
        try await TestSupport.pause(for: .milliseconds(90))
        XCTAssertEqual(provider.pingCalls, sleeping)
        store.setSleeping(false)
        try await TestSupport.eventually { provider.pingCalls > sleeping && latency.state == .ready }
        store.remove(provider.id)
        let disconnected = provider.pingCalls
        XCTAssertEqual(latency.state, .stale)
        XCTAssertNotNil(latency.date)
        try await TestSupport.pause(for: .milliseconds(90))
        XCTAssertEqual(provider.pingCalls, disconnected)
    }

    func testLatencyFailureRecoversWithoutStoppingMetricsOrUsingAnotherAccount() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(20), latencyInterval: .milliseconds(20))
        let provider = Provider(), other = Provider(account: "bob")
        provider.supportsLatency = true; provider.pingFails = true
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        let otherKey = try XCTUnwrap(store.register(other, grant: .init(profile: .statistics)))
        let latency = try XCTUnwrap(store.series[key]?.latency)
        let metrics = try XCTUnwrap(store.subscribe(key)), popup = try XCTUnwrap(store.subscribeLatency(key))
        defer {
            store.unsubscribe(metrics, from: key); store.unsubscribeLatency(popup, from: key)
            store.remove(provider.id); store.remove(other.id)
        }
        try await TestSupport.eventually { provider.pingCalls > 2 && provider.samples > 2 }
        XCTAssertEqual(latency.state, .unavailable)
        XCTAssertNil(latency.milliseconds)
        XCTAssertEqual(store.series[key]?.state, .ready)
        XCTAssertEqual(other.pingCalls, 0, "Older helpers are never sent an unsupported probe")
        XCTAssertNil(store.series[otherKey]?.latency.milliseconds)
        provider.pingFails = false
        try await TestSupport.eventually { latency.state == .ready }
        let last = latency.date
        provider.pingFails = true
        try await TestSupport.eventually { latency.state == .stale }
        XCTAssertEqual(latency.date, last)
    }

    func testReconnectDiscardsLateProbeAndPrefersThePopupConnection() async throws {
        let store = SSHStatisticsStore(latencyInterval: .milliseconds(20))
        let old = Provider(), replacement = Provider()
        old.supportsLatency = true; old.blockPing = true
        replacement.supportsLatency = true; replacement.pingFails = true
        let key = try XCTUnwrap(store.register(old, grant: .init(profile: .statistics)))
        let latency = try XCTUnwrap(store.series[key]?.latency)
        try await TestSupport.eventually { old.finishPing != nil }
        store.remove(old.id)
        XCTAssertEqual(store.register(replacement, grant: .init(profile: .statistics)), key)
        let popup = try XCTUnwrap(store.subscribeLatency(key, preferred: replacement.id))
        old.finishPing?.resume(); old.finishPing = nil
        try await TestSupport.eventually { replacement.pingCalls > 1 }
        XCTAssertNil(latency.milliseconds, "A reply from the retired connection must not become a reading")
        replacement.pingFails = false
        try await TestSupport.eventually { latency.state == .ready }
        old.blockPing = false
        XCTAssertEqual(store.register(old, grant: .init(profile: .statistics)), key)
        let oldCalls = old.pingCalls, newCalls = replacement.pingCalls
        try await TestSupport.eventually { replacement.pingCalls > newCalls }
        XCTAssertEqual(old.pingCalls, oldCalls, "The popup's preferred connection wins over background selection")
        store.unsubscribeLatency(popup, from: key)
        store.remove(old.id); store.remove(replacement.id)
    }
}

extension SSHStatisticsStoreTests {
    @MainActor private final class ProcessProvider: SSHStatisticsSampling {
        let id = SSHConnectionID()
        let scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: "stats", configuration: "user test")!
        let host = "host"
        let uid: UInt32 = 1000
        let supportsStatistics = true
        var supportsProcesses = true
        var processCalls = 0
        var aggregateCalls = 0
        var failing = false
        var invalid = false
        var slow = false
        func sample() async throws -> SSHStatisticsCounters {
            aggregateCalls += 1
            return .init(boot: "boot", monotonic: Double(aggregateCalls * 2), memoryTotal: 1024, memoryUsed: 512)
        }
        func disks() async throws -> [SSHStatisticsDisk] { [] }
        func processes() async throws -> SSHProcessCounters {
            processCalls += 1
            if slow { try await System.sleep(for: .milliseconds(150), "processes") }
            if failing { throw HerdrFailure("Process permission denied") }
            return .init(boot: "boot", monotonic: Double(processCalls * 2), truncated: true,
                         processes: [.init(pid: 7, start: "1", name: invalid ? "bad\nname" : "worker", cpuNanos: UInt64(processCalls) * 4_000_000_000, rss: 100)])
        }
    }
    func testProcessesShareSubscriptionsFailIndependentlyRecoverAndStayStale() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(20)), provider = ProcessProvider()
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        XCTAssertEqual(provider.processCalls, 0)
        let one = try XCTUnwrap(store.subscribe(key)), two = try XCTUnwrap(store.subscribe(key))
        let entry = try XCTUnwrap(store.series[key])
        try await TestSupport.eventually { entry.processes?.first?.cpu == 200 }
        XCTAssertTrue(entry.processesPartial)
        XCTAssertEqual(entry.subscriptions.count, 2)
        provider.failing = true
        try await TestSupport.eventually { entry.processes == nil }
        XCTAssertEqual(entry.state, .ready)
        let count = provider.aggregateCalls
        try await TestSupport.eventually { provider.aggregateCalls > count + 1 }
        provider.failing = false
        try await TestSupport.eventually { entry.processes?.first?.cpu == 200 }
        provider.invalid = true
        try await TestSupport.eventually { entry.processes == nil }
        provider.invalid = false
        try await TestSupport.eventually { entry.processes != nil }
        store.unsubscribe(one, from: key)
        let calls = provider.processCalls
        try await TestSupport.eventually { provider.processCalls > calls }
        store.unsubscribe(two, from: key)
        XCTAssertEqual(entry.state, .ready); XCTAssertNotNil(entry.processes)
        let stopped = provider.processCalls
        try await TestSupport.pause(for: .milliseconds(60)); XCTAssertEqual(provider.processCalls, stopped)
        store.remove(provider.id); XCTAssertNotNil(entry.processes)
    }
    func testOlderHelperAndBlockedProcessesKeepAggregateSampling() async throws {
        let store = SSHStatisticsStore(interval: .milliseconds(20)), old = ProcessProvider()
        old.supportsProcesses = false
        let key = try XCTUnwrap(store.register(old, grant: .init(profile: .statistics)))
        let token = try XCTUnwrap(store.subscribe(key))
        try await TestSupport.eventually { old.aggregateCalls > 2 }
        XCTAssertEqual(old.processCalls, 0); XCTAssertNil(store.series[key]?.processes)
        store.unsubscribe(token, from: key)
        old.supportsProcesses = true; old.slow = true
        let next = try XCTUnwrap(store.subscribe(key))
        let baseline = old.aggregateCalls
        try await TestSupport.eventually { old.aggregateCalls > baseline + 3 }
        XCTAssertEqual(old.processCalls, 1)
        store.unsubscribe(next, from: key)
    }
}

// At the end of the file: replays mark test steps by source line, so lines added above a recorded step stall it.
extension SSHStatisticsStoreTests {
    @MainActor private final class Cadence { var value: Duration; init(_ value: Duration) { self.value = value } }

    func testBackgroundCadenceIsAChartBarWhileShownAndAMinuteOtherwise() {
        XCTAssertEqual(StatisticsCadence.background(shown: true, lowPower: false), .seconds(15), "one sample per 15 s chart bar")
        XCTAssertEqual(StatisticsCadence.background(shown: false, lowPower: false), .seconds(60), "inactive or every window covered")
        XCTAssertEqual(StatisticsCadence.background(shown: true, lowPower: true), .seconds(60), "Low Power Mode")
        XCTAssertEqual(StatisticsCadence.background(shown: false, lowPower: true), .seconds(60))
    }

    func testBackgroundCadenceChangeAppliesFromTheNextSampleAndOpeningSamplesAtOnce() async throws {
        let cadence = Cadence(.milliseconds(10)), provider = Provider()
        let store = SSHStatisticsStore(interval: .milliseconds(10), backgroundCadence: { cadence.value })
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        defer { store.remove(provider.id) }
        try await TestSupport.eventually { provider.samples >= 3 }
        // Hidden: the wait in progress ends as it began, the one after the next sample takes the new cadence.
        cadence.value = .seconds(3600)
        try await TestSupport.pause(for: .milliseconds(100))
        try await TestSupport.eventually { provider.pending == 0 }
        let napping = provider.samples
        try await TestSupport.pause(for: .milliseconds(150))
        XCTAssertEqual(provider.samples, napping, "The hour-long cadence applies from the next sample")
        // Opening the stats view samples at once, not after the background wait.
        let viewer = try XCTUnwrap(store.subscribe(key))
        try await TestSupport.eventually(timeout: .seconds(2)) { provider.samples > napping }
        try await TestSupport.eventually { provider.samples > napping + 3 }
        XCTAssertEqual(provider.maximumPending, 1)
        // Shown again and closed: background sampling resumes at the cadence read for that wait.
        cadence.value = .milliseconds(10)
        store.unsubscribe(viewer, from: key)
        let closed = provider.samples
        try await TestSupport.eventually { provider.samples > closed + 2 }
    }

    func testOnlyALatencySubscriberPutsTheProbeOnItsForegroundCadence() async throws {
        let store = SSHStatisticsStore(backgroundInterval: .seconds(3600), latencyInterval: .milliseconds(10),
                                       backgroundLatencyInterval: .seconds(3600)), provider = Provider()
        provider.supportsLatency = true
        let key = try XCTUnwrap(store.register(provider, grant: .init(profile: .statistics)))
        defer { store.remove(provider.id) }
        let latency = try XCTUnwrap(store.series[key]?.latency)
        // A connection measures once, then waits the background interval: what a sidebar glyph (no subscriber) gets.
        try await TestSupport.eventually { latency.state == .ready }
        try await TestSupport.pause(for: .milliseconds(100))
        XCTAssertEqual(provider.pingCalls, 1)
        // A stats view without the identity header (metrics only) leaves the probe in the background.
        let metrics = try XCTUnwrap(store.subscribe(key))
        try await TestSupport.pause(for: .milliseconds(100))
        XCTAssertEqual(provider.pingCalls, 1, "Metrics subscribers do not speed up latency")
        // The popover's header: measured at once, then every latencyInterval, back in the background once it closes.
        let header = try XCTUnwrap(store.subscribeLatency(key))
        try await TestSupport.eventually { provider.pingCalls >= 4 }
        store.unsubscribeLatency(header, from: key)
        try await TestSupport.eventually { provider.pendingPings == 0 }
        let closed = provider.pingCalls
        try await TestSupport.pause(for: .milliseconds(100))
        XCTAssertEqual(provider.pingCalls, closed)
        store.unsubscribe(metrics, from: key)
    }
}
