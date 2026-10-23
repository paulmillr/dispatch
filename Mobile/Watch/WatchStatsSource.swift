import Foundation

/// Where the watch snapshot's host statistics come from (docs/watch.md, Field sources: `WatchHost.stats`): the phone's
/// own stores through `WatchHostStatsFeed` (each host's `HostStatistics`, at most one change of numbers per 15 s), with
/// the sample below where a host has none in Debug's scripted modes. `WatchSnapshotBuilder` reads it inside its
/// observation tracking, so an `@Observable` source pushes a new snapshot when its numbers change (the bridge's 1 s
/// coalescing keeps that to one push a second).
@MainActor
protocol WatchStatsSource: AnyObject {
    /// The host's current statistics and its last 15 minutes of CPU, or nil when none were read.
    func stats(for host: UUID) -> WatchHostStats?
}

/// Fixed statistics for tests and the phone's scripted hosts: every host gets plausible numbers derived from its id,
/// the same each time, with a 15-minute CPU series that has a gap and a peak.
@MainActor
final class WatchSampleStats: WatchStatsSource {
    private let now: () -> Date
    /// Statistics given explicitly, by host, over the derived ones.
    var overrides: [UUID: WatchHostStats] = [:]

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func stats(for host: UUID) -> WatchHostStats? {
        if let stats = overrides[host] { return stats }
        let seed = host.uuidString.utf8.reduce(UInt64(11)) { $0 &* 31 &+ UInt64($1) }
        let history = Self.history(seed: seed)
        let gib = 1_073_741_824.0
        let cpu = history.last.flatMap { $0 } ?? 20
        let memoryTotal = [8.0, 16, 24, 32][Int(seed % 4)], diskTotal = [256.0, 494, 1000][Int(seed % 3)]
        let memory = memoryTotal * (0.3 + Double(seed % 50) / 100), disk = diskTotal * Double(seed % 40 + 5) / 100
        return WatchHostStats(cpu: cpu, load: cpu / 25, memoryUsed: Int64(memory * gib), memoryTotal: Int64(memoryTotal * gib),
                              diskFree: Int64(disk * gib), diskTotal: Int64(diskTotal * gib),
                              warnings: disk / diskTotal < 0.1 ? [.disk] : [], history: history, sampled: now())
    }

    /// 60 buckets: a random walk between 4 and 96 with a gap of four buckets.
    static func history(seed: UInt64) -> [Double?] {
        var state = seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var values: [Double?] = [], value = 28.0
        for index in 0..<WatchHostStats.historyCount {
            value = max(4, min(96, value + (random() - 0.5) * 18))
            values.append((12...15).contains(index) ? nil : value.rounded())
        }
        return values
    }
}
