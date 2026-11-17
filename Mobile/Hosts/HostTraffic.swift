import Foundation
import Synchronization

/// The phone's periodic traffic to its hosts on one clock (docs/ios.md, Traffic), as the Mac's stats waits share one
/// (`System.sleep(every:)`): the stats samples, the liveness ping and the branch poll end their waits on the same
/// 15 s ticks of the wall clock (the stats chart's bars), so every host's frames leave together and a cellular radio,
/// whose tail lasts about 10 s after a burst, can idle between them instead of never. A tick a sample covers sends no
/// ping (`HostPulse`). Under frugal mode (`Frugal`) the samples and the polls go every other tick (`frugalInterval`)
/// and the ping skips the ticks between, so nothing periodic leaves on them.
enum HostTraffic {
    /// The shared cadence: one stats sample per chart bar, and the ping `stdio.liveness` needs at least every 15 s
    /// (helper/PROTOCOL.md; the helper's limit is 45 s).
    static let interval: Duration = .seconds(15)
    /// The frugal cadence (`Frugal`): every other tick of the shared clock, the stats' samples and so the only ticks
    /// with traffic of their own.
    static let frugalInterval: Duration = .seconds(30)

    /// A poll's cadence of `interval` now: under frugal mode at least `frugalInterval`, so it leaves with the stats'
    /// samples instead of waking the radio on the ticks between.
    @MainActor static func cadence(_ interval: Duration, frugal: Bool = Frugal.active) -> Duration {
        frugal ? max(interval, frugalInterval) : interval
    }

    /// The first tick of `grid` (its multiples on the wall clock) at least `minimum` after `date`.
    static func tick(after date: Date, minimum: Duration, grid: Duration = interval) -> Date {
        let span = grid.seconds
        guard span > 0 else { return date.addingTimeInterval(minimum.seconds) }
        let time = date.timeIntervalSinceReferenceDate + minimum.seconds
        return Date(timeIntervalSinceReferenceDate: (time / span).rounded(.up) * span)
    }

    /// A loop's wait until its next tick of `grid` at least half of one away (a read taken off the grid, a viewer that
    /// closed, a reconnect, moves onto it within one and a half), and that tick.
    static func wait(every grid: Duration = interval, from date: Date) -> (delay: Duration, tick: Date) {
        let tick = tick(after: date, minimum: grid / 2, grid: grid)
        return (.milliseconds(Int((tick.timeIntervalSince(date) * 1000).rounded(.up))), tick)
    }
}

extension Duration {
    /// In seconds, with the fraction.
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// What one host's periodic senders tell its liveness ping (`SSHHostSessionDriver`): the tick of the shared clock the
/// stats sample next (`HostStatistics`), so the ping skips the ticks a sample covers and the helper still hears a
/// frame at least every 30 s (its limit is 45 s). One per `HostSession`, handed to each run through `HostSessionContext`.
final class HostPulse: Sendable {
    private struct Ticks {
        /// The tick the stats sample next.
        var next: Date?
        /// The tick of the stats' last sample, sent or under way.
        var last: Date?
        /// The sample's tick the ping last relied on when it skipped one (`covers`).
        var relied: Date?
    }
    private let ticks = Mutex(Ticks())

    /// The longest gap between two samples whose tick between them the ping leaves to them: the frugal cadence's
    /// (`HostTraffic.frugalInterval`, every other tick), with the half second a tick may be off.
    static let span: TimeInterval = 30.5

    init() {}

    /// The stats sample at `tick` (on the shared clock), or nil: none due on the clock (no client, the background, a
    /// viewer's first sample).
    func expect(_ tick: Date?) {
        ticks.withLock { $0.next = tick }
    }

    /// The stats' sample for `tick` is going out now (its own frames keep the helper's liveness for that tick).
    func sampled(_ tick: Date) {
        ticks.withLock { $0.last = tick }
    }

    /// Whether the ping may skip `tick` (asked by the ping, which then relies on the sample): a sample goes out at
    /// `tick` (one is due then, or already went: the ping and the sample wake on the same tick, in either order), or
    /// `tick` lies between the last sample and the next with at most `span` between them (the frugal 30 s cadence's
    /// ticks between its samples), so the helper hears the phone at least every 30 s.
    func covers(_ tick: Date) -> Bool {
        ticks.withLock { ticks in
            let near = { (date: Date?) in date.map { abs($0.timeIntervalSince(tick)) < 0.5 } ?? false }
            if near(ticks.next) || near(ticks.last) {
                ticks.relied = near(ticks.last) ? ticks.last : ticks.next
                return true
            }
            guard let last = ticks.last, let next = ticks.next, last < tick, tick < next,
                  next.timeIntervalSince(last) <= Self.span else {
                // The ping sends this tick's frame itself: nothing is owed.
                ticks.relied = nil
                return false
            }
            ticks.relied = next
            return true
        }
    }

    /// The stats stop sampling (`HostStatistics` reschedules): true, once, when the ping skipped a tick for a sample
    /// that has not gone and was due by `now` (at most half a second ahead). Its `echo` is then the stats' to send now,
    /// or the helper would wait for the ping's next tick, up to 45 s after the last frame under the frugal cadence.
    func owed(at now: Date) -> Bool {
        ticks.withLock { ticks in
            guard let relied = ticks.relied, relied.timeIntervalSince(now) < 0.5 else { return false }
            ticks.relied = nil
            return ticks.last.map { relied.timeIntervalSince($0) > 0.5 } ?? true
        }
    }
}
