import Foundation
import Observation
import XCTest
@testable import DispatchMobile

/// The watch's statistics from the phone's own stores (docs/watch.md, Seams): `HostStatistics.summary(at:)` in the
/// watch's terms, new numbers at most every 15 s, staleness at once, the sample only where a host has none.
@MainActor
final class WatchHostStatsFeedTests: XCTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let record = HostRecord(name: "mba2", address: "mba2.local", user: "alex", auth: .password, order: 0, tintSeed: "mba2")

    /// One saved host that never connects by itself: the test hands its stats store a client.
    private func hosts() -> HostSessions {
        HostSessions(store: HostStore(url: nil, hosts: [record]),
                     keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                     knownHosts: KnownHostStore(url: nil), driver: ScriptedHostSessionDriver { _ in [] })
    }

    nonisolated private static func helper() -> ScriptedHelper {
        ScriptedHelper { request in
            HostStatsDemo.answer(request.method, host: "mba2", home: "/Users/alex").map { .result($0) } ?? .open
        }
    }

    private func sampling(_ stats: HostStatistics, _ sleeper: SteppedSleeper) {
        stats.now = { [unowned self] in clock }
        stats.readLowPower = { false }
        stats.sleep = { try await sleeper.sleep($0) }
    }

    func testTheStoresNumbersReachTheWatchAtMostEvery15Seconds() async throws {
        let hosts = hosts()
        let stats = try XCTUnwrap(hosts.session(record.id)).stats
        let sampler = SteppedSleeper(), waits = SteppedSleeper()
        sampling(stats, sampler)
        let feed = WatchHostStatsFeed(hosts: hosts, now: { [unowned self] in clock }, sleep: { try await waits.sleep($0) })
        XCTAssertNil(feed.stats(for: record.id), "nothing read yet")

        // The first sample goes at once.
        let helper = Self.helper()
        stats.active = true
        stats.attach(helper.client)
        try await TestSupport.eventually { sampler.pending == 1 }
        clock += 5
        sampler.step()
        try await TestSupport.eventually { feed.stats(for: record.id) != nil }
        let first = try XCTUnwrap(feed.stats(for: record.id))
        let gib = Int64(HostStatsDemo.gib)
        XCTAssertEqual(first.cpu, 34)
        XCTAssertEqual(first.load, 2.71)
        XCTAssertEqual(first.memoryUsed, 11 * gib)
        XCTAssertEqual(first.memoryTotal, 32 * gib)
        XCTAssertEqual(first.diskFree, 48 * gib)
        XCTAssertEqual(first.diskTotal, 480 * gib)
        XCTAssertEqual(first.warnings, [.disk], "90 % of the disk used")
        XCTAssertEqual(first.history.count, WatchHostStats.historyCount)
        XCTAssertEqual(first.history.last, 34)
        XCTAssertEqual(first.sampled, clock)
        XCTAssertFalse(first.stale)

        // The next samples wait for the end of the 15 s, in one publish.
        clock += 5
        sampler.step()
        try await TestSupport.eventually { stats.history.count == 2 && waits.pending == 1 }
        XCTAssertEqual(waits.durations, [.seconds(10)])
        XCTAssertEqual(feed.stats(for: record.id)?.sampled, first.sampled, "not yet")
        clock += 5
        sampler.step()
        try await TestSupport.eventually { stats.history.count == 3 && sampler.pending == 1 }
        XCTAssertEqual(waits.durations.count, 1, "one publish waits")
        clock += 5
        waits.step()
        try await TestSupport.eventually { feed.stats(for: record.id)?.sampled == stats.sample?.date }
        XCTAssertEqual(feed.stats(for: record.id)?.sampled, first.sampled?.addingTimeInterval(10))

        // The link drops: stale at once, whatever the interval.
        clock += 1
        stats.attach(nil)
        try await TestSupport.eventually { feed.stats(for: record.id)?.stale == true }
        XCTAssertEqual(feed.stats(for: record.id)?.cpu, 34, "the last numbers, kept")
    }

    /// The snapshot builder reads the feed inside its observation tracking: a publish schedules the next push.
    func testAPublishIsAChangeTheSnapshotSees() async throws {
        let hosts = hosts()
        let stats = try XCTUnwrap(hosts.session(record.id)).stats
        let feed = WatchHostStatsFeed(hosts: hosts, now: { [unowned self] in clock })
        let changed = Changed()
        _ = withObservationTracking { feed.stats(for: record.id) } onChange: { changed.fired = true }
        stats.seed(sample: .init(date: clock, cpu: 20, load: 1, memoryUsed: 1 << 30, memoryTotal: 8 << 30),
                   history: [.init(date: clock, cpu: 20, memory: 12.5)], processes: [], disk: nil)
        try await TestSupport.eventually { feed.stats(for: record.id) != nil }
        XCTAssertTrue(changed.fired)
        XCTAssertEqual(feed.stats(for: record.id)?.stale, true, "seeded, not sampled by this connection")
    }

    /// The fallback (Debug's scripted hosts) answers only for a host without numbers of its own.
    func testTheSampleOnlyWhereAHostHasNone() throws {
        let hosts = hosts()
        let other = UUID()
        let sample = WatchSampleStats(now: { [unowned self] in clock })
        let feed = WatchHostStatsFeed(hosts: hosts, fallback: sample, now: { [unowned self] in clock })
        XCTAssertEqual(feed.stats(for: other), sample.stats(for: other))
        XCTAssertEqual(feed.stats(for: record.id), sample.stats(for: record.id), "no sample yet")
        let stats = try XCTUnwrap(hosts.session(record.id)).stats
        stats.seed(sample: .init(date: clock, cpu: 20, load: 1, memoryUsed: nil, memoryTotal: nil), history: [],
                   processes: [], disk: nil)
        let feed2 = WatchHostStatsFeed(hosts: hosts, fallback: sample, now: { [unowned self] in clock })
        XCTAssertEqual(feed2.stats(for: record.id)?.cpu, 20, "its own")
        XCTAssertEqual(feed2.stats(for: other), sample.stats(for: other))
    }

    private final class Changed: @unchecked Sendable {
        var fired = false
    }
}
