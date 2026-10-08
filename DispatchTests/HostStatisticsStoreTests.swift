import XCTest
@testable import DispatchApp

@MainActor
final class HostStatisticsStoreTests: XCTestCase {
    private final class Provider: SSHStatisticsSampling {
        let id = SSHConnectionID()
        let host = "remote-host"
        let uid: UInt32 = 1000
        let supportsStatistics = true
        let scope: SSHIntegrationScope
        var samples = 0
        init(account: String = "alice", destination: String = "build") {
            scope = SSHIntegrationScope(executable: "/usr/bin/ssh", destination: destination, configuration: "hostname host\nuser \(account)\n")!
        }
        func sample() async throws -> SSHStatisticsCounters {
            samples += 1
            return .init(boot: "boot", monotonic: Double(samples), memoryTotal: 100, memoryUsed: 42, uptime: 123)
        }
        func disks() async throws -> [SSHStatisticsDisk] {
            [.init(paths: ["/", "/home/alice"], identity: "same-fs", total: 1000, free: 900)]
        }
    }

    func testUnknownRemoteNeverInheritsLocalMachineValues() async throws {
        let remote = SSHStatisticsStore(), provider = Provider()
        let host = HostID.authenticated("machine")
        let key = try XCTUnwrap(remote.register(provider, grant: .init(profile: .statistics), hostID: host))
        let store = HostStatisticsStore(local: HostStats(), remote: remote)
        let unknown = store.snapshot(.ssh(key))
        XCTAssertEqual(unknown.host, "remote-host")
        XCTAssertEqual(unknown.account, "alice")
        XCTAssertEqual(unknown.state, .loading)
        XCTAssertNil(unknown.memoryTotal); XCTAssertNil(unknown.uptime); XCTAssertNil(unknown.cpu)
        XCTAssertNil(unknown.receivedPerSecond); XCTAssertNil(unknown.processes); XCTAssertNil(unknown.volumes)
        XCTAssertNil(unknown.peakCPU)
        let token = try XCTUnwrap(store.subscribe(.ssh(key)))
        defer { store.unsubscribe(token) }
        try await Task.sleep(for: .milliseconds(30))
        let value = store.snapshot(.ssh(key))
        XCTAssertEqual(value.memoryPercent, 42)
        XCTAssertEqual(value.uptime, 123)
        XCTAssertNil(value.cpu); XCTAssertNil(value.receivedPerSecond)
        XCTAssertEqual(value.volumes?.count, 1)
        XCTAssertEqual(value.volumes?.first?.path, "/ · /home/alice")
    }

    func testHostGroupingDoesNotMergeAccountsOrAuthorizationAndPrefersCurrentTerminal() throws {
        let remote = SSHStatisticsStore(), store = HostStatisticsStore(local: HostStats(), remote: remote)
        let a = Provider(), b = Provider(account: "bob"), alias = Provider(destination: "other-alias")
        let host = HostID.authenticated("shared-display-machine")
        let alice = try XCTUnwrap(remote.register(a, grant: .init(profile: .statistics), hostID: host))
        let bob = try XCTUnwrap(remote.register(b, grant: .init(profile: .statistics), hostID: host))
        let other = try XCTUnwrap(remote.register(alias, grant: .init(profile: .statistics), hostID: host))
        XCTAssertEqual(remote.keys(for: host).count, 3)
        XCTAssertNotEqual(alice, bob); XCTAssertNotEqual(alice, other)
        XCTAssertEqual(store.source(host: host, preferred: b.id), .ssh(bob))
        XCTAssertEqual(store.source(host: host, preferred: b.id, selected: alice), .ssh(alice))
        XCTAssertEqual(store.source(host: .local, preferred: b.id), .local)
        let different = HostID.authenticated("unrelated")
        XCTAssertEqual(store.source(host: different, preferred: b.id, selected: alice), .unavailable(different))
        XCTAssertEqual(a.samples + b.samples + alias.samples, 0)
    }

    func testDefaultSourceUsesAvailableConnectionsBeforeRetainedHistory() throws {
        let remote = SSHStatisticsStore(), store = HostStatisticsStore(local: HostStats(), remote: remote)
        defer { remote.reset() }
        let host = HostID.authenticated("shared-machine"), a = Provider(destination: "a"), b = Provider(destination: "b")
        let first = try XCTUnwrap(remote.register(a, grant: .init(profile: .statistics), hostID: host))
        let second = try XCTUnwrap(remote.register(b, grant: .init(profile: .statistics), hostID: host))
        var sources = [store.source(host: host)]
        remote.remove(a.id)
        sources += [store.source(host: host), store.source(host: host, preferred: b.id),
                    store.source(host: host, preferred: b.id, selected: first)]
        try XCTUnwrap(remote.series[second]).failed.insert(b.id)
        sources.append(store.source(host: host))
        remote.register(b, grant: .init(profile: .statistics), hostID: host)
        sources.append(store.source(host: host))
        remote.remove(b.id)
        sources.append(store.source(host: host))
        XCTAssertEqual(sources, [.ssh(first), .ssh(second), .ssh(second), .ssh(first),
                                 .ssh(first), .ssh(second), .ssh(first)])
    }

    func testUnsubscribeKeepsSamplingAndOnlyDisconnectCreatesGap() async throws {
        let remote = SSHStatisticsStore(interval: .milliseconds(10), backgroundInterval: .milliseconds(20)), provider = Provider()
        let key = try XCTUnwrap(remote.register(provider, grant: .init(profile: .statistics)))
        let store = HostStatisticsStore(local: HostStats(), remote: remote)
        let token = try XCTUnwrap(store.subscribe(.ssh(key)))
        try await Task.sleep(for: .milliseconds(30))
        store.unsubscribe(token)
        let count = provider.samples
        try await TestSupport.eventually { provider.samples > count }
        XCTAssertEqual(store.snapshot(.ssh(key)).state, .ready)
        XCTAssertNotNil(store.snapshot(.ssh(key)).history.last?.memoryPercent)
        remote.remove(provider.id)
        let value = store.snapshot(.ssh(key))
        XCTAssertEqual(value.state, .stale); XCTAssertEqual(value.memoryPercent, 42)
        XCTAssertNil(value.history.last?.memoryPercent)
        XCTAssertTrue(value.disksStale)
    }

    func testChartsBreakAtMissingSamplesAndAdvancePastDisconnectedHistory() {
        let now = Date()
        var snapshot = HostStatisticsSnapshot(host: "remote", account: "alice", remote: true, state: .stale, date: now)
        snapshot.history = [
            .init(date: now.addingTimeInterval(-901), cpu: 99),
            .init(date: now.addingTimeInterval(-20), cpu: 10),
            .init(date: now.addingTimeInterval(-18)),
            .init(date: now.addingTimeInterval(-16), cpu: 20),
            .init(date: now.addingTimeInterval(-14), cpu: 30),
            .init(date: now.addingTimeInterval(-2), cpu: 40),
        ]
        let segments = snapshot.historySegments(memory: false, at: now)
        XCTAssertEqual(segments.map { $0.compactMap(\.cpu) }, [[10], [20, 30], [40]])
        XCTAssertTrue(snapshot.historySegments(memory: true, at: now).isEmpty)
        XCTAssertTrue(snapshot.historySegments(memory: false, at: now.addingTimeInterval(901)).isEmpty)
        XCTAssertEqual(snapshot.date, now, "The last sample timestamp must not move with the chart clock")
        XCTAssertEqual(snapshot.peakCPU, 40)
        snapshot.history = [.init(date: now, cpu: .nan), .init(date: now, cpu: .infinity)]
        XCTAssertNil(snapshot.peakCPU)
    }

    func testAllHistoryAppendPathsAreBounded() {
        let entry = SSHStatisticsStore.Series(scope: Provider().scope)
        let now = Date()
        entry.append(.init(date: now.addingTimeInterval(-3601), cpu: 12))
        entry.append(.init(date: now, cpu: 13))
        XCTAssertEqual(entry.history.count, 1)
        for _ in 0..<2000 { entry.append(.init(date: now)) }
        XCTAssertEqual(entry.history.count, 1801)
        XCTAssertNil(entry.history.last?.cpu)
    }

    func testInactiveHistoryExpiresWithoutSamplingAndPreservesLastStaleSample() async throws {
        let remote = SSHStatisticsStore(interval: .milliseconds(10), historyRetention: 0.05), provider = Provider()
        let key = try XCTUnwrap(remote.register(provider, grant: .init(profile: .statistics)))
        let token = try XCTUnwrap(remote.subscribe(key))
        try await TestSupport.eventually { provider.samples > 0 }
        remote.unsubscribe(token, from: key); remote.remove(provider.id)
        let entry = try XCTUnwrap(remote.series[key]), sampled = provider.samples
        XCTAssertFalse(entry.history.isEmpty)
        try await TestSupport.eventually(timeout: .seconds(1)) { entry.history.isEmpty }
        XCTAssertEqual(entry.history.capacity, 0, "Expired chart points must release their backing storage")
        XCTAssertEqual(provider.samples, sampled, "History expiry must not poll or reopen SSH")
        XCTAssertEqual(entry.state, .stale)
        XCTAssertEqual(entry.latest?.counters.memoryUsed, 42)
        let local = HostStats(historyRetention: 0.025)
        local.latest.memoryTotal = 100; local.latest.memoryUsed = 42; local.state = .ready
        local.history = [local.latest]; local.stop()
        try await TestSupport.eventually(timeout: .seconds(1)) { local.history.isEmpty }
        XCTAssertEqual(local.history.capacity, 0)
        XCTAssertEqual(local.latest.memoryUsed, 42); XCTAssertEqual(local.state, .stale)
    }

    func testLocalBackgroundHistoryContinuesAfterLastViewerCloses() async throws {
        let local = HostStats()
        defer { local.stop() }
        local.startBackgroundHistory()
        try await TestSupport.eventually { !local.history.isEmpty }
        XCTAssertTrue(local.latest.processes.isEmpty)
        XCTAssertTrue(local.disksStale)
        let viewer = local.subscribe()
        local.unsubscribe(viewer)
        let count = local.history.count
        try await TestSupport.eventually(timeout: .seconds(8)) { local.history.count > count }
        XCTAssertEqual(local.state, .ready)
        XCTAssertTrue(local.latest.cpuAvailable, "Opening and closing a view must not reset the CPU baseline")
        XCTAssertTrue(local.latest.processes.isEmpty)
        local.stop()
        XCTAssertEqual(local.state, .stale)
        let stoppedCount = local.history.count
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(local.history.count, stoppedCount)
    }

    func testLocalFirstRatesAreUnknownAndMemoryIsExplicitlyCollected() async throws {
        var sampler = HostSampler()
        let value = try await sampler.sample(includeStorage: false)
        XCTAssertFalse(value.cpuAvailable); XCTAssertFalse(value.networkAvailable)
        XCTAssertGreaterThan(value.memoryTotal, 0)
        XCTAssertEqual(HostSample().memoryTotal, 0)
        XCTAssertEqual(HostSample().uptime, 0)
    }
}

extension HostStatisticsStoreTests {
    func testRemoteProcessSortingUnknownCPUAndPartialSnapshot() throws {
        let remote = SSHStatisticsStore(), provider = Provider()
        let key = try XCTUnwrap(remote.register(provider, grant: .init(profile: .statistics)))
        let entry = try XCTUnwrap(remote.series[key])
        entry.processes = [
            .init(id: 7, name: "memory first", cpu: nil, memory: 900),
            .init(id: 8, name: "cpu first", cpu: 250, memory: 100),
            .init(id: 9, name: "second", cpu: 20, memory: 200),
        ]
        entry.processesPartial = true; entry.state = .stale
        let snapshot = HostStatisticsStore(local: HostStats(), remote: remote).snapshot(.ssh(key))
        XCTAssertEqual(snapshot.topCPU.map(\.id), [8, 9])
        XCTAssertEqual(snapshot.topMemory.map(\.id), [7, 9, 8])
        XCTAssertTrue(snapshot.processesPartial); XCTAssertEqual(snapshot.state, .stale)
        XCTAssertTrue(snapshot.history.isEmpty)
    }
}
