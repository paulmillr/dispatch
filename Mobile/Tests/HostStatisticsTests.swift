import Foundation
import XCTest
@testable import DispatchMobile

/// A sleep the test lets end: each call is recorded and waits for `step()` (or its task's cancellation).
final class SteppedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var log: [Duration] = []
    private var serial = 0

    var durations: [Duration] { lock.withLock { log } }
    var pending: Int { lock.withLock { waiting.count } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            serial += 1
            log.append(duration)
            return serial
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiting.append((id, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let found = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return waiting.remove(at: index).continuation
            }
            found?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest waiting sleep.
    func step() {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst().continuation }
        next?.resume()
    }
}

@MainActor
final class HostStatisticsTests: XCTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var lowPower = false

    /// A store on the test's clock and sleeper, its helper answering as the demo's mba2.
    private func store(_ sleeper: SteppedSleeper) -> (HostStatistics, ScriptedHelper) {
        let helper = Self.demoHelper()
        let stats = HostStatistics()
        stats.now = { [unowned self] in self.clock }
        stats.readLowPower = { [unowned self] in self.lowPower }
        stats.sleep = { try await sleeper.sleep($0) }
        return (stats, helper)
    }

    func testCadence() {
        XCTAssertEqual(HostStatistics.cadence(viewing: false, lowPower: false), .seconds(15), "one sample per 15 s bar")
        XCTAssertEqual(HostStatistics.cadence(viewing: true, lowPower: false), .seconds(2), "a sheet or popover shows it")
        XCTAssertEqual(HostStatistics.cadence(viewing: true, lowPower: true), .seconds(30), "Low Power Mode wins")
        XCTAssertEqual(HostStatistics.cadence(viewing: false, lowPower: true), .seconds(30))
        XCTAssertGreaterThan(HostStatistics.barHold, 30, "Low Power Mode's bars between samples take the later one")
        XCTAssertLessThan(HostStatistics.barHold, 45, "a missed sample is still a gap")
    }

    /// Low Power Mode samples every 30 s, so every other bar has no sample of its own: it takes the later one (as the Mac's
    /// 15 s cadence drifting past a bar does), and the chart has no holes; a minute of nothing is still a gap.
    func testLowPowerCadenceFillsEveryBar() {
        let now = Date(timeIntervalSinceReferenceDate: 15 * 1000 + 14)
        let start = HostStatistics.barStart(0, at: now)
        // Every 30 s, each landing a little later than the last (the requests' own time).
        let history = (0..<20).map { index in
            HostStatistics.Point(date: start.addingTimeInterval(Double(index) * 30 + 1 + Double(index) * 0.2), cpu: Double(index), memory: 50)
        }
        let bars = HostStatistics.bars(history, metric: .cpu, at: now)
        XCTAssertEqual(bars.prefix(39).filter { $0 == nil }.count, 0, "\(bars)")
        XCTAssertEqual(bars[1], 1, "the bar between two samples takes the later one")
        let gapped = history.filter { $0.cpu != 10 && $0.cpu != 11 }
        XCTAssertNil(HostStatistics.bars(gapped, metric: .cpu, at: now)[21], "90 s without a sample is a gap")
    }

    /// No sample before anything shows the stats: the first one a cadence after the connection came up; a viewer
    /// samples now and every 2 s; Low Power Mode every 30 s; the disks at most every 15 s.
    func testCadenceSwitchesWithViewersAndLowPowerMode() async throws {
        let sleeper = SteppedSleeper()
        let (stats, helper) = store(sleeper)
        stats.active = true
        stats.attach(helper.client)
        XCTAssertFalse(stats.live, "no sample of this connection yet")
        try await TestSupport.eventually { sleeper.pending == 1 }
        XCTAssertEqual(sleeper.durations, [.seconds(15)], "nothing shows it yet")
        XCTAssertTrue(helper.requests.isEmpty)

        clock += 15
        sleeper.step()
        try await TestSupport.eventually { stats.sample != nil && sleeper.pending == 1 }
        XCTAssertEqual(helper.methods, ["stats.sample", "stats.processes", "stats.disks"])
        XCTAssertTrue(stats.live)
        XCTAssertEqual(sleeper.durations.last, .seconds(15))
        XCTAssertEqual(stats.sample?.cpu, 34)
        XCTAssertEqual(stats.sample?.load, 2.71)
        XCTAssertEqual(stats.sample?.memoryTotal, UInt64(32 * HostStatsDemo.gib))
        XCTAssertEqual(stats.disk?.free, UInt64(48 * HostStatsDemo.gib))
        XCTAssertEqual(stats.top(.cpu).map(\.name), ["node", "cargo", "rust-analyzer"])
        XCTAssertEqual(stats.top(.memory).map(\.name), ["fixture-helper", "postgres", "rust-analyzer"])

        // A sheet opens a second later: the next sample is due 2 s after the last.
        clock += 1
        let token = stats.beginViewing()
        try await TestSupport.eventually { sleeper.durations.count == 3 && sleeper.pending == 1 }
        XCTAssertEqual(sleeper.durations.last, .seconds(1))
        clock += 1
        sleeper.step()
        try await TestSupport.eventually { helper.requests("stats.sample").count == 2 && sleeper.pending == 1 }
        XCTAssertEqual(helper.requests("stats.disks").count, 1, "the disks every 15 s only")
        XCTAssertEqual(sleeper.durations.last, .seconds(2))

        lowPower = true
        stats.powerStateChanged()
        XCTAssertTrue(stats.lowPower)
        try await TestSupport.eventually { sleeper.durations.last == .seconds(30) && sleeper.pending == 1 }
        clock += 30
        sleeper.step()
        try await TestSupport.eventually { helper.requests("stats.sample").count == 3 && sleeper.pending == 1 }
        XCTAssertEqual(helper.requests("stats.disks").count, 2, "15 s since the last disks")

        lowPower = false
        stats.powerStateChanged()
        stats.endViewing(token)
        try await TestSupport.eventually { sleeper.durations.last == .seconds(15) && sleeper.pending == 1 }
        XCTAssertEqual(stats.history.count, 3)
    }

    /// The background, a dropped link and a plain connection sample nothing; the last sample stays, stale.
    func testNothingSamplesInTheBackgroundAndTheLastSampleStays() async throws {
        let sleeper = SteppedSleeper()
        let (stats, helper) = store(sleeper)
        stats.attach(helper.client)
        _ = stats.beginViewing()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(stats.live, "not in the foreground")
        XCTAssertTrue(sleeper.durations.isEmpty)
        XCTAssertTrue(helper.requests.isEmpty)

        stats.active = true
        try await TestSupport.eventually { stats.sample != nil }
        XCTAssertTrue(stats.live)
        XCTAssertFalse(stats.stale)
        let sample = stats.sample

        stats.attach(nil)
        XCTAssertFalse(stats.live)
        XCTAssertTrue(stats.stale)
        XCTAssertEqual(stats.sample, sample, "kept, with its time")
        stats.attach(helper.client)
        try await TestSupport.eventually { stats.live && helper.requests("stats.sample").count == 2 }
        stats.active = false
        XCTAssertTrue(stats.stale)
        let count = helper.requests.count
        clock += 30
        sleeper.step()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(helper.requests.count, count, "the background samples nothing")
    }

    /// A connection's first CPU has no interval behind it: the last sample stays, stale, until the next one.
    func testFirstSampleWithoutCPUKeepsTheLastOne() async throws {
        let sleeper = SteppedSleeper()
        let (stats, _) = store(sleeper)
        let helper = Self.sampleHelper(cpu: 20)
        stats.active = true
        _ = stats.beginViewing()
        stats.attach(helper.client)
        try await TestSupport.eventually { stats.sample?.cpu == 20 }
        let other = Self.sampleHelper(cpu: nil)
        stats.attach(other.client)
        try await TestSupport.eventually { other.requests("stats.sample").count == 1 && stats.history.count == 2 }
        XCTAssertEqual(stats.sample?.cpu, 20, "the last sample")
        XCTAssertFalse(stats.live, "not presented as current")
        XCTAssertTrue(stats.stale)
        XCTAssertNil(stats.history.last?.cpu, "the history keeps no made-up value")
        XCTAssertEqual(stats.processes, [], "failed requests leave the rest as it was")
        try await TestSupport.eventually { sleeper.pending == 1 }
        clock += 2
        sleeper.step()
        try await TestSupport.eventually { stats.live }
        XCTAssertNil(stats.sample?.cpu, "the next sample is the connection's own")
        XCTAssertNil(stats.sample?.memoryPercent)
    }

    /// A new connection's numbers are stale (the watch and the sheet show them as such) until its first sample.
    func testANewConnectionIsStaleUntilItsFirstSample() async throws {
        let sleeper = SteppedSleeper()
        let (stats, helper) = store(sleeper)
        stats.active = true
        HostStatsDemo.seed(stats, host: "mba2", home: "/Users/alex", now: clock)
        XCTAssertTrue(stats.stale)
        stats.attach(helper.client)
        try await TestSupport.eventually { sleeper.pending == 1 }
        XCTAssertFalse(stats.live)
        XCTAssertEqual(stats.summary(at: clock)?.stale, true, "hours-old numbers are not current")
        let other = Self.sampleHelper(cpu: 61)
        clock += 5
        sleeper.step()
        try await TestSupport.eventually { stats.live }
        XCTAssertEqual(stats.summary(at: clock)?.stale, false)
        stats.attach(other.client)
        XCTAssertFalse(stats.live, "another connection: stale again")
        try await TestSupport.eventually { sleeper.pending == 1 }
        clock += 5
        sleeper.step()
        try await TestSupport.eventually { stats.live }
        XCTAssertEqual(stats.sample?.cpu, 61)
    }

    /// A request that never answers is given up after the timeout (and cancelled): sampling goes on.
    func testAStuckRequestDoesNotStallSampling() async throws {
        let sleeper = SteppedSleeper()
        let (stats, _) = store(sleeper)
        let helper = Self.stuckProcessesHelper()
        stats.timeout = .milliseconds(100)
        stats.active = true
        _ = stats.beginViewing()
        stats.attach(helper.client)
        try await TestSupport.eventually { stats.live && sleeper.pending == 1 }
        XCTAssertEqual(stats.sample?.cpu, 12)
        let stuck = try XCTUnwrap(helper.requests("stats.processes").first)
        try await TestSupport.eventually { helper.cancellations.contains(stuck.id) }
        XCTAssertEqual(helper.requests("stats.disks").count, 1, "the next request went out")
        clock += 2
        sleeper.step()
        try await TestSupport.eventually { helper.requests("stats.sample").count == 2 }
    }

    /// 60 bars of 15 s on a wall-clock grid: a bar is the peak of its samples, a bar between two samples at most
    /// `barHold` apart takes the later one, and a longer silence is a gap.
    func testBarsBucketsAndGaps() {
        let now = Date(timeIntervalSinceReferenceDate: 15 * 1000 + 14)
        let start = HostStatistics.barStart(0, at: now)
        XCTAssertEqual(HostStatistics.barStart(59, at: now), Date(timeIntervalSinceReferenceDate: 15 * 1000))
        func at(_ bar: Int, _ offset: TimeInterval = 1) -> Date { start.addingTimeInterval(Double(bar) * 15 + offset) }
        let history = [
            HostStatistics.Point(date: at(0), cpu: 10, memory: 40),
            HostStatistics.Point(date: at(0, 6), cpu: 30, memory: 41),
            HostStatistics.Point(date: at(1, 14), cpu: 20, memory: nil),
            // 17 s later, past bar 2: bar 2 takes this one's value.
            HostStatistics.Point(date: at(3, 1), cpu: 50, memory: 42),
            // Then a minute of nothing: a gap.
            HostStatistics.Point(date: at(8), cpu: 70, memory: 43),
            HostStatistics.Point(date: at(59), cpu: 120, memory: 44),
        ]
        let bars = HostStatistics.bars(history, metric: .cpu, at: now)
        XCTAssertEqual(bars.count, 60)
        XCTAssertEqual(bars[0], 30, "the peak of its samples")
        XCTAssertEqual(bars[1], 20)
        XCTAssertEqual(bars[2], 50, "held from the next sample")
        XCTAssertEqual(bars[3], 50)
        XCTAssertNil(bars[4], "a gap")
        XCTAssertNil(bars[7])
        XCTAssertEqual(bars[8], 70)
        XCTAssertEqual(bars[59], 100, "clamped")
        let memory = HostStatistics.bars(history, metric: .memory, at: now)
        XCTAssertEqual(memory[0], 41)
        XCTAssertNil(memory[1], "no memory in that sample")
        XCTAssertEqual(memory[2], 42)
        XCTAssertEqual(Sparkline.segments(Array(bars.prefix(10)), size: CGSize(width: 90, height: 100)).map(\.count), [4, 1],
                       "the line breaks at the gap")
    }

    func testPeakAverageAndSummary() async throws {
        let sleeper = SteppedSleeper()
        let (stats, _) = store(sleeper)
        HostStatsDemo.seed(stats, host: "mba2", home: "/Users/alex", now: clock)
        let values = stats.history.compactMap(\.cpu)
        XCTAssertEqual(stats.history.count, 56, "60 bars less the 4-bar gap")
        XCTAssertEqual(stats.peak(.cpu, at: clock), values.max())
        XCTAssertEqual(try XCTUnwrap(stats.average(.cpu, at: clock)), values.reduce(0, +) / Double(values.count), accuracy: 0.001)
        XCTAssertNil(stats.peak(.cpu, at: clock.addingTimeInterval(3600)), "nothing in the last 15 minutes")
        let bars = stats.bars(.cpu, at: clock)
        XCTAssertEqual(bars.filter { $0 == nil }.count, 4, "the sleep gap")
        XCTAssertEqual(bars.last, 34)

        let summary = try XCTUnwrap(stats.summary(at: clock))
        XCTAssertTrue(summary.stale, "seeded, not live")
        XCTAssertEqual(summary.cpu, 34)
        XCTAssertFalse(summary.cpuHigh)
        XCTAssertFalse(summary.memoryHigh)
        XCTAssertTrue(summary.diskHigh, "90 % used")
        XCTAssertEqual(summary.bars, bars)
    }

    func testFormats() {
        let gib = UInt64(HostStatsDemo.gib)
        XCTAssertEqual(HostStatsFormat.size(11 * gib).value, "11")
        XCTAssertEqual(HostStatsFormat.size(gib * 74 / 10).value, "7.4")
        XCTAssertEqual(HostStatsFormat.size(1229 * gib).unit, "TB")
        XCTAssertEqual(HostStatsFormat.size(1229 * gib).value, "1.2")
        XCTAssertEqual(HostStatsFormat.sizeText(gib / 2), "512 MB")
        XCTAssertEqual(HostStatsFormat.sizeText(2 * gib), "2 GB")
        XCTAssertEqual(HostStatsFormat.size(nil).value, "—")
        XCTAssertEqual(HostStatsFormat.percent(33.6), "34")
        XCTAssertEqual(HostStatsFormat.load(2.714), "2.71 load")
        XCTAssertEqual(HostStatsFormat.peakLine(peak: 82.2, average: 31.4), "peak 82% · avg 31%")
        XCTAssertNil(HostStatsFormat.peakLine(peak: nil, average: nil))
        XCTAssertTrue(HostStatsFormat.diskHigh(81))
        XCTAssertFalse(HostStatsFormat.diskHigh(80))
        XCTAssertTrue(HostStatsFormat.cpuHigh(90))
        XCTAssertFalse(HostStatsFormat.memoryHigh(90))
        XCTAssertEqual(Sparkline.index(at: 0, width: 590, count: 60), 0)
        XCTAssertEqual(Sparkline.index(at: 590, width: 590, count: 60), 59)
        XCTAssertEqual(Sparkline.index(at: 300, width: 590, count: 60), 30)
    }

    /// A helper answering only `stats.sample`: this CPU (nil: none yet), memory with it.
    /// Answers `stats.sample` with 12 % and never answers `stats.processes`.
    nonisolated private static func stuckProcessesHelper() -> ScriptedHelper {
        ScriptedHelper { request in
            switch request.method {
            case "stats.sample": .result(["cpu": 12.0, "load": [1.0]] as [String: Any])
            case "stats.processes": .open
            default: .error(code: "unavailable", message: "no")
            }
        }
    }

    nonisolated private static func sampleHelper(cpu: Double?) -> ScriptedHelper {
        ScriptedHelper { request in
            guard request.method == "stats.sample" else { return .error(code: "unavailable", message: "no") }
            guard let cpu else { return .result(["cpu": NSNull(), "load": [1.0]] as [String: Any]) }
            return .result(["cpu": cpu, "load": [1.0], "memory": [UInt64(100), UInt64(50)]] as [String: Any])
        }
    }

    // MARK: Sessions

    /// A helper answering as the demo's mba2, its handler made outside the main actor (it runs on the transport's thread).
    nonisolated private static func demoHelper() -> ScriptedHelper {
        ScriptedHelper { request in
            HostStatsDemo.answer(request.method, host: "mba2", home: "/Users/alex").map { .result($0) } ?? .open
        }
    }

    private func registry(_ record: HostRecord, steps: @escaping @Sendable (HostRecord) -> [ScriptedHostSessionDriver.Step])
        -> (HostSessions, ScriptedHostSessionDriver) {
        let driver = ScriptedHostSessionDriver(script: steps)
        let sessions = HostSessions(store: HostStore(url: nil, hosts: [record]),
                                    keys: KeyStore(url: nil, vault: MemoryVault(), keyProtection: .none, secureEnclaveAvailable: false),
                                    knownHosts: KnownHostStore(url: nil), driver: driver, active: true)
        return (sessions, driver)
    }

    /// The session hands each helper connection's client to its stats and takes it back when the connection goes; the
    /// foreground decides whether they sample.
    func testSessionsDriveTheirStats() async throws {
        let helper = Self.demoHelper()
        let client = helper.client
        let record = HostRecord(name: "mba2", address: "mba2.tail3f.ts.net", user: "alex", auth: .password)
        let (sessions, _) = registry(record) { _ in
            [.readyWith(client: { client }, hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]),
                        versions: [:], topology: nil), .hold]
        }
        let session = try XCTUnwrap(sessions.session(record.id))
        XCTAssertTrue(session.stats.active, "the registry is in the foreground")
        try await TestSupport.eventually { session.link.isConnected }
        XCTAssertFalse(session.stats.live, "the first sample waits for a viewer or a cadence")
        let token = session.stats.beginViewing()
        try await TestSupport.eventually { session.stats.live && session.stats.sample != nil }
        sessions.setActive(false)
        XCTAssertFalse(session.stats.active)
        XCTAssertFalse(session.stats.live)
        XCTAssertTrue(session.stats.stale)
        session.stats.endViewing(token)
    }

    /// Disconnect in the stats keeps the host off through everything that reconnects (the foreground, a network change,
    /// pull to refresh, an edit) until Connect.
    func testDisconnectStaysOffUntilConnect() async throws {
        let record = HostRecord(name: "mba2", address: "mba2.tail3f.ts.net", user: "alex", auth: .password)
        let (sessions, driver) = registry(record) { _ in
            [.ready(hello: HostFixture.hello(), multiplexers: HostFixture.multiplexers(["tmux"]), versions: [:], topology: nil), .hold]
        }
        let session = try XCTUnwrap(sessions.session(record.id))
        try await TestSupport.eventually { session.link.isConnected }
        session.park()
        XCTAssertTrue(session.parked)
        XCTAssertEqual(session.link, .disconnected)
        sessions.setActive(true)
        sessions.networkChanged()
        sessions.setActive(false)
        sessions.setActive(true)
        await sessions.refresh(timeout: .milliseconds(100))
        var edited = record
        edited.address = "mba2.local"
        sessions.update(edited)
        let replacement = try XCTUnwrap(sessions.session(record.id))
        XCTAssertTrue(replacement.parked, "an edit that reconnects keeps it off")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(replacement.link, .disconnected)
        XCTAssertEqual(driver.runs(record.id), 1)

        replacement.connectByUser()
        XCTAssertFalse(replacement.parked)
        try await TestSupport.eventually { replacement.link.isConnected }
        XCTAssertEqual(driver.runs(record.id), 2)
    }

    /// New host's verifying connection samples nothing; the session it becomes does.
    func testProbesSampleNothing() async throws {
        let record = HostRecord(name: "mba2", address: "mba2.tail3f.ts.net", user: "alex", auth: .password)
        let (sessions, _) = registry(record) { _ in [.hold] }
        let new = HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .password)
        let probe = sessions.probe(new)
        XCTAssertFalse(probe.stats.active)
        sessions.add(new, probe: probe)
        XCTAssertTrue(sessions.session(new.id) === probe)
        XCTAssertTrue(probe.stats.active)
    }

    /// The Color picker: a colour is the user's; Automatic gives back the colour the fewest other hosts show.
    func testColorChoice() throws {
        var other = HostRecord(name: "studio", address: "studio.local", user: "alex", auth: .password)
        other.color = .blue
        var record = HostRecord(name: "mba2", address: "mba2.local", user: "alex", auth: .password)
        record.color = .blue
        let (sessions, _) = registry(record) { _ in [.hold] }
        sessions.add(other)
        XCTAssertEqual(sessions.automaticColor(of: record.id), .blue, "not picked: the colour it has")
        XCTAssertNil(sessions.colorOwner(of: record.id))
        sessions.setColor(.green, host: record.id)
        let automatic = try XCTUnwrap(sessions.automaticColor(of: record.id))
        XCTAssertNotEqual(automatic, .blue, "what Automatic would give: the colour the fewest other hosts show")
        XCTAssertEqual(sessions.store.record(record.id)?.color, .green)
        XCTAssertEqual(sessions.store.record(record.id)?.colorPicked, true)
        let session = try XCTUnwrap(sessions.session(record.id))
        XCTAssertEqual(HostStatsPresentation(session: session).color, "Green")
        sessions.setColor(nil, host: record.id)
        let back = try XCTUnwrap(sessions.store.record(record.id))
        XCTAssertFalse(back.colorPicked)
        XCTAssertEqual(back.color, automatic, "the colour the Automatic row showed")

        // A second host of the same machine shows the first's colour: its picker names it.
        let twin = HostRecord(name: "mba2-lan", address: "192.168.1.20", user: "alex", auth: .password, tintSeed: record.tintSeed)
        sessions.add(twin)
        XCTAssertEqual(sessions.colorOwner(of: twin.id)?.id, record.id)
        XCTAssertNil(sessions.colorOwner(of: record.id))
        XCTAssertEqual(HostStatsPresentation(session: session).color, "Automatic")

        // Saved and read back; a record from before the picker reads as Automatic.
        let data = try JSONEncoder().encode(sessions.store.record(record.id))
        XCTAssertEqual(try JSONDecoder().decode(HostRecord.self, from: data), sessions.store.record(record.id))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["colorPicked"] = nil
        let old = try JSONDecoder().decode(HostRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(old.colorPicked)
    }
}
