import Foundation
import Observation

/// The watch's host statistics from the phone's own stores (docs/watch.md, Seams): each host's
/// `HostStatistics.summary(at:)` (Mobile/Stats) as `WatchHostStats`. The stores sample every 2 to 15 s; the snapshot
/// reads `published`, which takes new numbers at most once per `interval` (15 s, one bar of the CPU history), so a stats
/// sheet open on the phone does not push a snapshot every 2 s. A host's numbers appearing or going, or turning stale or
/// current (a drop, the background, a new connection's first sample), are published at once. Where a host has no
/// reading, `fallback` answers (Debug's scripted hosts, whose helpers send no stats: `WatchSampleStats`).
@MainActor @Observable
final class WatchHostStatsFeed: WatchStatsSource {
    nonisolated static let interval: Duration = .seconds(15)

    /// What the snapshot carries, by host.
    private(set) var published: [UUID: WatchHostStats] = [:]

    let interval: Duration
    @ObservationIgnored private weak var hosts: HostSessions?
    private let fallback: (any WatchStatsSource)?
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var publishedAt: Date?
    /// The publish waiting for the end of the interval.
    @ObservationIgnored private var deferred: Task<Void, Never>?

    init(hosts: HostSessions, fallback: (any WatchStatsSource)? = nil, interval: Duration = WatchHostStatsFeed.interval,
         now: @escaping @MainActor () -> Date = { System.date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.hosts = hosts
        self.fallback = fallback
        self.interval = interval
        self.now = now
        self.sleep = sleep
        publish(observe())
    }

    isolated deinit {
        deferred?.cancel()
    }

    func stats(for host: UUID) -> WatchHostStats? {
        published[host] ?? fallback?.stats(for: host)
    }

    /// Every host's numbers now, tracked: the next change of what they read (a sample, a drop, a session replaced, a
    /// host added or removed) calls `changed`.
    private func observe() -> [UUID: WatchHostStats] {
        withObservationTracking { current() } onChange: { [weak self] in
            // Called before the change is made: read it on the next turn.
            Task { @MainActor in self?.changed() }
        }
    }

    private func current() -> [UUID: WatchHostStats] {
        guard let hosts else { return [:] }
        let date = now()
        var all: [UUID: WatchHostStats] = [:]
        for session in hosts.ordered {
            if let summary = session.stats.summary(at: date) { all[session.id] = WatchHostStats(summary) }
        }
        return all
    }

    private func changed() {
        let next = observe()
        guard next != published else { return }
        // Which hosts have numbers and whether they are current: at once.
        if next.mapValues(\.stale) != published.mapValues(\.stale) { return publish(next) }
        guard deferred == nil else { return }
        let elapsed = publishedAt.map { now().timeIntervalSince($0) } ?? .infinity
        let remaining = interval - .milliseconds(Int(min(max(elapsed, 0), 1e6) * 1000))
        guard remaining > .zero else { return publish(next) }
        let sleep = sleep
        deferred = Task { [weak self] in
            do { try await sleep(remaining) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.deferred = nil
            self.publish(self.current())
        }
    }

    private func publish(_ next: [UUID: WatchHostStats]) {
        deferred?.cancel()
        deferred = nil
        publishedAt = now()
        if next != published { published = next }
    }
}

extension WatchHostStats {
    /// The phone's summary in the watch's terms: bytes, the warning flags its strip draws red, the 60 × 15 s CPU bars.
    init(_ summary: HostStatsSummary) {
        var warnings: [Warning] = []
        if summary.cpuHigh { warnings.append(.cpu) }
        if summary.memoryHigh { warnings.append(.memory) }
        if summary.diskHigh { warnings.append(.disk) }
        self.init(cpu: summary.cpu, load: summary.load, memoryUsed: summary.memoryUsed.map(Int64.init(clamping:)),
                  memoryTotal: summary.memoryTotal.map(Int64.init(clamping:)), diskFree: summary.diskFree.map(Int64.init(clamping:)),
                  diskTotal: summary.diskTotal.map(Int64.init(clamping:)), warnings: warnings, history: summary.bars,
                  sampled: summary.date, stale: summary.stale)
    }
}
