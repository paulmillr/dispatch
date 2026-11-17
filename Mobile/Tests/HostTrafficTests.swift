import Foundation
import Synchronization
import XCTest
@testable import DispatchMobile

/// The phone's periodic traffic on one clock (docs/ios.md, Traffic): the stats' samples, the liveness ping and the
/// branch poll end their waits on the same 15 s ticks; a tick a sample covers sends no `echo`, yet the helper hears a
/// frame every tick (`stdio.liveness`), every other tick under frugal mode; only a viewer's samples ask for the process
/// list.
@MainActor
final class HostTrafficTests: XCTestCase {
    /// 5 s past a tick of the shared clock.
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private static let tick = Date(timeIntervalSinceReferenceDate: 800_000_010)

    /// A helper answering as the demo's mba2, its handler made outside the main actor (it runs on the transport's thread).
    nonisolated private static func demoHelper() -> ScriptedHelper {
        ScriptedHelper { request in
            HostStatsDemo.answer(request.method, host: "mba2", home: "/Users/alex").map { .result($0) } ?? .open
        }
    }

    nonisolated private static func echoHelper() -> ScriptedHelper {
        ScriptedHelper.scripted { $0.method == "echo" ? .result([String: String]()) : nil }
    }

    /// Never answers.
    nonisolated private static func silentHelper() -> ScriptedHelper {
        ScriptedHelper.scripted { _ in nil }
    }

    /// The demo's mba2, answering `echo` too.
    nonisolated private static func echoingDemoHelper() -> ScriptedHelper {
        ScriptedHelper { request in
            if request.method == "echo" { return .result([String: String]()) }
            return HostStatsDemo.answer(request.method, host: "mba2", home: "/Users/alex").map { .result($0) } ?? .open
        }
    }

    private func store(_ sleeper: SteppedSleeper, pulse: HostPulse? = nil) -> (HostStatistics, ScriptedHelper) {
        let helper = Self.demoHelper()
        let stats = HostStatistics()
        stats.now = { [unowned self] in self.clock }
        stats.readFrugal = { nil }
        stats.sleep = { try await sleeper.sleep($0) }
        stats.pulse = pulse
        return (stats, helper)
    }

    func testTheSharedClock() {
        XCTAssertEqual(HostTraffic.interval, SSHHostSessionDriver.livenessPing, "a frame every tick keeps the helper alive")
        XCTAssertEqual(SSHHostSessionDriver().pingInterval, HostTraffic.interval)
        XCTAssertEqual(HostStatistics.cadence(viewing: false, frugal: false), HostTraffic.interval)
        XCTAssertEqual(SpaceGitFacts.branchInterval, HostTraffic.interval)
        let tick = Self.tick
        XCTAssertEqual(HostTraffic.tick(after: tick.addingTimeInterval(-14), minimum: .seconds(1)), tick)
        XCTAssertEqual(HostTraffic.tick(after: tick.addingTimeInterval(-0.5), minimum: .seconds(1)), tick.addingTimeInterval(15),
                       "at most a second late, never two ticks a moment apart")
        // A loop's next tick is at least half a cadence away: a read just off the grid moves onto it.
        XCTAssertEqual(HostTraffic.wait(every: .seconds(15), from: tick.addingTimeInterval(-8)).tick, tick)
        XCTAssertEqual(HostTraffic.wait(every: .seconds(15), from: tick.addingTimeInterval(-7)).tick, tick.addingTimeInterval(15))
        XCTAssertEqual(HostTraffic.wait(every: .seconds(15), from: tick.addingTimeInterval(-8)).delay, .seconds(8))
        // Low Power Mode's 30 s ticks are ticks of the 15 s clock: every other one.
        let slow = HostTraffic.wait(every: .seconds(30), from: tick).tick
        XCTAssertEqual(slow.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 15), 0)
        XCTAssertGreaterThanOrEqual(slow.timeIntervalSince(tick), 15)
    }

    func testThePulseCoversTheStatsTicks() {
        let pulse = HostPulse()
        let tick = Self.tick
        XCTAssertFalse(pulse.covers(tick))
        pulse.expect(tick)
        XCTAssertTrue(pulse.covers(tick))
        XCTAssertFalse(pulse.covers(tick.addingTimeInterval(15)))
        // The sample went and the next is announced before the ping looked at this tick: still covered.
        pulse.sampled(tick)
        pulse.expect(tick.addingTimeInterval(15))
        XCTAssertTrue(pulse.covers(tick))
        XCTAssertTrue(pulse.covers(tick.addingTimeInterval(15)))
        // The stats stopped (the background, a viewer's first sample): the next tick is the ping's.
        pulse.expect(nil)
        XCTAssertFalse(pulse.covers(tick.addingTimeInterval(15)))
    }

    /// The stats tell the pulse the tick they sample on; the sample's round trip is the latency. A viewer's first sample
    /// is off the clock; the rest land on its 5 s marks, every third a tick the ping leaves to them.
    func testTheStatsAnnounceTheirTicks() async throws {
        let sleeper = SteppedSleeper()
        let pulse = HostPulse()
        let (stats, helper) = store(sleeper, pulse: pulse)
        var trips: [Duration] = []
        stats.roundTrip = { trips.append($0) }
        stats.active = true
        stats.attach(helper.client)
        try await TestSupport.eventually { sleeper.pending == 1 }
        XCTAssertTrue(pulse.covers(Self.tick), "the first sample's tick")
        clock = Self.tick
        sleeper.step()
        try await TestSupport.eventually { stats.live && sleeper.pending == 1 }
        XCTAssertTrue(pulse.covers(Self.tick), "sampled")
        XCTAssertTrue(pulse.covers(Self.tick.addingTimeInterval(15)), "the next")
        XCTAssertEqual(trips.count, 1, "the sample's round trip is the latency")

        let token = stats.beginViewing()
        try await TestSupport.eventually { helper.requests("stats.sample").count == 2 && sleeper.pending == 1 }
        XCTAssertEqual(trips.count, 1, "a sample off the clock leaves the latency to the ping")
        XCTAssertEqual(sleeper.durations.last, .seconds(5), "then the clock's next 5 s mark")
        XCTAssertTrue(pulse.covers(Self.tick.addingTimeInterval(5)))
        for step in 1...3 {
            clock = Self.tick.addingTimeInterval(Double(step) * 5)
            sleeper.step()
            try await TestSupport.eventually { helper.requests("stats.sample").count == 2 + step && sleeper.pending == 1 }
        }
        XCTAssertTrue(pulse.covers(Self.tick.addingTimeInterval(15)), "a viewer's sample on the tick: no ping")
        XCTAssertEqual(trips.count, 4, "the samples on the clock are the latency")
        stats.endViewing(token)
        try await TestSupport.eventually { sleeper.pending == 1 && pulse.covers(Self.tick.addingTimeInterval(30)) }
        XCTAssertEqual(sleeper.durations.last, .seconds(15), "back to the 15 s ticks")
        stats.active = false
        XCTAssertFalse(pulse.covers(Self.tick.addingTimeInterval(30)), "the background samples nothing: the ping keeps the link")
    }

    /// Only a viewer asks for the process list: its first sample goes at once with it, even right after a tick's sample;
    /// without a viewer the disks are asked once a minute.
    func testOnlyAViewerAsksForTheProcessList() async throws {
        let sleeper = SteppedSleeper()
        let (stats, helper) = store(sleeper)
        stats.active = true
        stats.attach(helper.client)
        for index in 1...5 {
            try await TestSupport.eventually { sleeper.pending == 1 }
            clock = Self.tick.addingTimeInterval(Double(index - 1) * 15)
            sleeper.step()
            try await TestSupport.eventually { helper.requests("stats.sample").count == index }
        }
        try await TestSupport.eventually { sleeper.pending == 1 }
        XCTAssertTrue(helper.requests("stats.processes").isEmpty, "nothing shows the processes")
        XCTAssertEqual(stats.processes, [])
        XCTAssertEqual(helper.requests("stats.disks").count, 2, "the disks once a minute: at the first tick and four later")

        // A sheet opens half a second after a tick's sample: the processes now, not at the next sample.
        clock += 0.5
        let token = stats.beginViewing()
        try await TestSupport.eventually { !stats.processes.isEmpty }
        XCTAssertEqual(helper.requests("stats.processes").count, 1)
        XCTAssertEqual(helper.requests("stats.sample").count, 6, "with a sample")
        stats.endViewing(token)
    }

    /// The driver's ping: `echo` at once on connecting, then on each tick the stats do not cover; every tick has a frame.
    func testThePingSkipsTheTicksTheStatsCover() async throws {
        let helper = Self.echoHelper()
        let sleeper = SteppedSleeper()
        let pulse = HostPulse()
        let now = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let latencies = Mutex(0)
        let tick = Self.tick
        let ping = Task {
            await SSHHostSessionDriver.ping(helper.client, every: .seconds(15), pulse: pulse, now: { now.withLock { $0 } },
                                            sleep: { try await sleeper.sleep($0) }) { _ in latencies.withLock { $0 += 1 } }
        }
        try await TestSupport.eventually { sleeper.pending == 1 && latencies.withLock { $0 } == 1 }
        XCTAssertEqual(helper.requests("echo").count, 1, "at once: the latency on connecting")
        XCTAssertEqual(sleeper.durations, [.seconds(10)], "then the shared clock's tick")

        // The stats sample on that tick: no echo.
        pulse.expect(tick)
        now.withLock { $0 = tick }
        sleeper.step()
        try await TestSupport.eventually { sleeper.durations.count == 2 && sleeper.pending == 1 }
        XCTAssertEqual(sleeper.durations.last, .seconds(15))

        // They stop sampling (the background's linger): the ping takes the next tick.
        pulse.expect(nil)
        now.withLock { $0 = tick.addingTimeInterval(15) }
        sleeper.step()
        try await TestSupport.eventually { sleeper.durations.count == 3 && latencies.withLock { $0 } == 2 }
        ping.cancel()
        await ping.value
        XCTAssertEqual(helper.requests("echo").count, 2, "none on the tick the sample covered")
    }

    /// Frugal mode: the stats sample every other tick and the ping leaves the ticks between to them too, so the helper
    /// hears the phone every 30 s (its limit is 45 s); a gap over 30 s (a new cadence's first wait) keeps the ping.
    func testTheFrugalPulseCoversTheTicksBetweenSamples() {
        let pulse = HostPulse()
        let tick = Self.tick
        pulse.sampled(tick)
        pulse.expect(tick + 30)
        XCTAssertTrue(pulse.covers(tick + 15), "between two samples 30 s apart")
        XCTAssertFalse(pulse.owed(at: tick + 15), "the sample it relies on is not due yet")
        XCTAssertTrue(pulse.covers(tick + 30))
        // That sample is cancelled (a sheet opens, the background) just after the ping skipped its tick: its frame is owed.
        XCTAssertTrue(pulse.owed(at: tick + 30.2))
        XCTAssertFalse(pulse.owed(at: tick + 30.2), "once")

        pulse.expect(tick + 75)
        XCTAssertFalse(pulse.covers(tick + 45), "45 s between the samples: the ping goes")
        XCTAssertFalse(pulse.owed(at: tick + 75), "the ping sent its own frame")
        pulse.expect(tick + 90)
        XCTAssertTrue(pulse.covers(tick + 90))
        pulse.sampled(tick + 90)
        XCTAssertFalse(pulse.owed(at: tick + 90.1), "the sample went")
    }

    /// Frugal stats sample on the 30 s ticks and tell the pulse, which covers the ticks between; leaving just after the
    /// ping skipped a sample's tick sends that tick's `echo` from the stats.
    func testFrugalStatsCoverTheTicksBetweenAndSendACancelledTicksEcho() async throws {
        let sleeper = SteppedSleeper()
        let pulse = HostPulse()
        let helper = Self.echoingDemoHelper()
        let stats = HostStatistics()
        stats.now = { [unowned self] in self.clock }
        stats.readFrugal = { .lowData }
        stats.sleep = { try await sleeper.sleep($0) }
        stats.pulse = pulse
        stats.active = true
        stats.attach(helper.client)
        try await TestSupport.eventually { sleeper.pending == 1 }
        // The first 30 s tick at least 15 s away.
        let first = Date(timeIntervalSinceReferenceDate: 800_000_040)
        XCTAssertEqual(sleeper.durations, [.seconds(40)])
        XCTAssertTrue(pulse.covers(first))
        clock = first
        sleeper.step()
        try await TestSupport.eventually { helper.requests("stats.sample").count == 1 && sleeper.pending == 1 }
        XCTAssertEqual(sleeper.durations.last, .seconds(30))
        XCTAssertTrue(pulse.covers(first + 15), "the tick between two samples: no echo")
        XCTAssertTrue(pulse.covers(first + 30), "the next sample's")
        XCTAssertTrue(helper.requests("echo").isEmpty)
        // The app leaves just after the ping skipped that tick: its echo goes now.
        clock = first + 30.1
        stats.active = false
        try await TestSupport.eventually { helper.requests("echo").count == 1 }
        XCTAssertEqual(helper.requests("stats.sample").count, 1)
    }

    /// Frugal mode: Low Power Mode or Low Data Mode (a constrained path; cellular alone is not), posted when it changes;
    /// the polls' cadence doubles under it.
    func testFrugalModeFollowsThePathAndPostsItsChanges() throws {
        guard !System.lowPowerMode else { throw XCTSkip("Low Power Mode is on") }
        Frugal.path(constrained: false)
        defer { Frugal.unpin(); Frugal.path(constrained: false) }
        XCTAssertFalse(Frugal.active)
        let posts = Recorder<Int>()
        let observer = NotificationCenter.default.addObserver(forName: Frugal.changed, object: nil, queue: nil) { _ in posts.append(1) }
        defer { NotificationCenter.default.removeObserver(observer) }
        Frugal.path(constrained: true)
        XCTAssertEqual(Frugal.reason, .lowData)
        Frugal.path(constrained: true)
        XCTAssertEqual(posts.values.count, 1, "only changes post")
        Frugal.pin(nil)
        XCTAssertFalse(Frugal.active, "pinned by a test")
        Frugal.unpin()
        XCTAssertTrue(Frugal.active)
        Frugal.path(constrained: false)
        XCTAssertFalse(Frugal.active)
        XCTAssertEqual(posts.values.count, 4)
        XCTAssertEqual(HostTraffic.cadence(.seconds(15), frugal: true), .seconds(30))
        XCTAssertEqual(HostTraffic.cadence(.seconds(15), frugal: false), .seconds(15))
        XCTAssertEqual(HostTraffic.cadence(.seconds(60), frugal: true), .seconds(60))
    }

    /// A ping whose answer sits behind output does not hold the next one: each tick sends its own.
    func testAPingDoesNotWaitForTheLastAnswer() async throws {
        let helper = Self.silentHelper()
        let sleeper = SteppedSleeper()
        let now = Mutex(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let ping = Task {
            await SSHHostSessionDriver.ping(helper.client, every: .seconds(15), pulse: HostPulse(), now: { now.withLock { $0 } },
                                            sleep: { try await sleeper.sleep($0) }) { _ in }
        }
        try await TestSupport.eventually { sleeper.pending == 1 && helper.requests("echo").count == 1 }
        now.withLock { $0 = Self.tick }
        sleeper.step()
        try await TestSupport.eventually { helper.requests("echo").count == 2 }
        ping.cancel()
        await ping.value
    }

    /// A tick's sample that cannot leave (a connection whose profile lacks `stats.sample` refuses it before sending)
    /// still gives the helper that tick's frame: the stats send the `echo` the ping skipped, and its round trip is the
    /// latency.
    func testATickWhoseSampleCannotLeaveStillPings() async throws {
        let sleeper = SteppedSleeper()
        let pulse = HostPulse()
        let helper = Self.echoingDemoHelper()
        try await helper.client.connection.configure(limit: 12_000_013, ops: ["hello", "echo", "stats.disks"])
        let stats = HostStatistics()
        stats.now = { [unowned self] in self.clock }
        stats.readFrugal = { nil }
        stats.sleep = { try await sleeper.sleep($0) }
        stats.pulse = pulse
        var trips = 0
        stats.roundTrip = { _ in trips += 1 }
        stats.active = true
        stats.attach(helper.client)
        try await TestSupport.eventually { sleeper.pending == 1 }
        XCTAssertTrue(pulse.covers(Self.tick), "the ping leaves this tick to the sample")
        clock = Self.tick
        sleeper.step()
        try await TestSupport.eventually { helper.requests("echo").count == 1 && trips == 1 && sleeper.pending == 1 }
        XCTAssertTrue(helper.requests("stats.sample").isEmpty, "refused before it left")
        XCTAssertEqual(helper.requests("stats.disks").count, 1)
    }
}
