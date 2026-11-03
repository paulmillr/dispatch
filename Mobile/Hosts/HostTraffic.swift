import Foundation
import Synchronization

/// The phone's periodic traffic to its hosts on one clock (docs/ios.md, Traffic), as the Mac's stats waits share one
/// (`System.sleep(every:)`): the stats samples, the liveness ping and the branch poll end their waits on the same
/// 15 s ticks of the wall clock (the stats chart's bars), so every host's frames leave together and a cellular radio,
/// whose tail lasts about 10 s after a burst, can idle between them instead of never. A tick a sample covers sends no
/// ping (`HostPulse`).
enum HostTraffic {
    /// The shared cadence: one stats sample per chart bar, and the ping `stdio.liveness` needs at least every 15 s
    /// (helper/PROTOCOL.md; the helper's limit is 45 s).
    static let interval: Duration = .seconds(15)

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
/// frame every 15 s. One per `HostSession`, handed to each run through `HostSessionContext`.
final class HostPulse: Sendable {
    private struct Ticks {
        /// The tick the stats sample next.
        var next: Date?
        /// The tick of the stats' last sample, sent or under way.
        var last: Date?
    }
    private let ticks = Mutex(Ticks())

    init() {}

    /// The stats sample at `tick` (on the shared clock), or nil: none due on a tick (no client, the background, a sheet's
    /// 2 s samples).
    func expect(_ tick: Date?) {
        ticks.withLock { $0.next = tick }
    }

    /// The stats' sample for `tick` is going out now (its own frames keep the helper's liveness for that tick).
    func sampled(_ tick: Date) {
        ticks.withLock { $0.last = tick }
    }

    /// Whether a sample goes out at `tick`, so the ping need not: one is due then, or already went (the ping and the
    /// sample wake on the same tick, in either order).
    func covers(_ tick: Date) -> Bool {
        ticks.withLock { ticks in
            [ticks.next, ticks.last].contains { $0.map { abs($0.timeIntervalSince(tick)) < 0.5 } ?? false }
        }
    }
}
