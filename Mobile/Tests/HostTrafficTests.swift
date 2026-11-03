import Foundation
import Synchronization
import XCTest
@testable import DispatchMobile

/// The phone's periodic traffic on one clock (docs/ios.md, Traffic): the stats' samples, the liveness ping and the
/// branch poll end their waits on the same 15 s ticks; a tick a sample covers sends no `echo`, yet the helper hears a
/// frame every tick (`stdio.liveness`); only a viewer's samples ask for the process list.
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
        stats.readLowPower = { false }
        stats.sleep = { try await sleeper.sleep($0) }
        stats.pulse = pulse
        return (stats, helper)
    }

    func testTheSharedClock() {
        XCTAssertEqual(HostTraffic.interval, SSHHostSessionDriver.livenessPing, "a frame every tick keeps the helper alive")
        XCTAssertEqual(SSHHostSessionDriver().pingInterval, HostTraffic.interval)
        XCTAssertEqual(HostStatistics.cadence(viewing: false, lowPower: false), HostTraffic.interval)
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
        // The stats stopped (the background, a sheet's 2 s samples): the next tick is the ping's.
        pulse.expect(nil)
        XCTAssertFalse(pulse.covers(tick.addingTimeInterval(15)))
    }

    /// The stats tell the pulse the tick they sample on; the sample's round trip is the latency. A viewer's samples are
    /// off the clock: the ping takes the ticks (and the latency) back.
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
        XCTAssertFalse(pulse.covers(Self.tick.addingTimeInterval(15)), "a viewer's samples are off the clock")
        XCTAssertEqual(trips.count, 1, "the ping measures while a sheet shows")
        stats.endViewing(token)
        try await TestSupport.eventually { sleeper.pending == 1 && pulse.covers(Self.tick.addingTimeInterval(15)) }
        stats.active = false
        XCTAssertFalse(pulse.covers(Self.tick.addingTimeInterval(15)), "the background samples nothing: the ping keeps the link")
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
        stats.readLowPower = { false }
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
