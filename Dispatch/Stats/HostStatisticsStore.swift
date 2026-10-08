import Foundation

/// The presentation and terminal feed share this model. Missing remote values
/// never inherit this Mac's memory, uptime, name, or a synthetic zero rate.
struct HostStatisticsSnapshot: Codable, Sendable {
    static let historyWindow: TimeInterval = 15 * 60

    struct Point: Codable, Sendable {
        let date: Date
        var cpu: Double?
        var memoryPercent: Double?
    }
    enum State: String, Codable, Sendable { case loading, ready, stale, unavailable }
    let host: String
    let account: String?
    let remote: Bool
    var state: State
    var date: Date
    var cpu: Double?
    var cores: [Double]?
    var load: [Double]?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var swapUsed: UInt64?
    var uptime: Double?
    var receivedPerSecond: Double?
    var sentPerSecond: Double?
    var volumes: [HostVolume]?
    var disksStale = true
    var processes: [HostProcess]?
    var processesPartial = false
    var history: [Point] = []

    var peakCPU: Double? {
        let now = Date()
        let peak = history.filter { $0.date >= now.addingTimeInterval(-Self.historyWindow) && $0.date <= now }.compactMap(\.cpu).filter { $0.isFinite && (0...100).contains($0) }.max()
        if let peak { return peak }
        guard let cpu, cpu.isFinite, (0...100).contains(cpu) else { return nil }
        return cpu
    }

    var diskTotal: UInt64? { volumes?.first?.total }
    var diskFree: UInt64? { volumes?.first?.free }
    var diskUsed: UInt64? {
        guard let total = diskTotal, let free = diskFree, free <= total else { return nil }
        return total - free
    }
    var memoryPercent: Double? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0, used <= total else { return nil }
        return Double(used) / Double(total) * 100
    }
    var diskPercent: Double? {
        guard let used = diskUsed, let total = diskTotal, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
    var topCPU: [HostProcess] { Array((processes ?? []).filter { $0.cpu?.isFinite == true }.sorted { ($0.cpu ?? 0, -$0.id) > ($1.cpu ?? 0, -$1.id) }.prefix(5)) }
    var topMemory: [HostProcess] { Array((processes ?? []).sorted { ($0.memory, -$0.id) > ($1.memory, -$1.id) }.prefix(5)) }
    var uptimeText: String {
        guard let uptime, uptime.isFinite, uptime >= 0, uptime < Double(Int.max) else { return "uptime unavailable" }
        return "up \(Int(uptime) / 86400)d \(Int(uptime) / 3600 % 24)h"
    }
    var statusText: String? {
        switch state {
        case .loading: "Loading stats…"
        case .ready: nil
        case .stale: "Disconnected or paused · last sample \(date.formatted(date: .omitted, time: .standard))"
        case .unavailable: "Stats unavailable"
        }
    }
    /// Use wall time only for the chart's visible window. The counter sampler
    /// uses remote monotonic time, independently of this presentation clock.
    func historySegments(memory: Bool, at now: Date) -> [[Point]] {
        var result: [[Point]] = [], segment: [Point] = []
        var previous: Date?
        for point in history where point.date >= now.addingTimeInterval(-Self.historyWindow) && point.date <= now {
            let value = memory ? point.memoryPercent : point.cpu
            if value?.isFinite != true || previous.map({ point.date.timeIntervalSince($0) > 6 || point.date < $0 }) == true {
                if !segment.isEmpty { result.append(segment); segment.removeAll(keepingCapacity: true) }
            }
            if value?.isFinite == true { segment.append(point) }
            previous = point.date
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }

    static func gib(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(0...1)))
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.2f", value / 1_000_000)
    }
}

@MainActor
final class HostStatisticsStore {
    static let shared = HostStatisticsStore()
    enum Source: Hashable, Codable, Sendable {
        case local
        case ssh(SSHStatisticsStore.Key)
        case unavailable(HostID)
    }
    struct Subscription { let source: Source; let token: UUID }
    let local: HostStats
    let remote: SSHStatisticsStore
    init(local: HostStats = .shared, remote: SSHStatisticsStore = .shared) {
        self.local = local; self.remote = remote
    }

    func source(host: HostID, preferred: SSHConnectionID? = nil, selected: SSHStatisticsStore.Key? = nil) -> Source {
        guard host != .local else { return .local }
        let keys = remote.keys(for: host)
        if let selected, keys.contains(selected) { return .ssh(selected) }
        if let preferred, let key = remote.key(for: preferred), keys.contains(key) { return .ssh(key) }
        if let key = keys.first(where: { remote.series[$0]?.provider() != nil }) ?? keys.first { return .ssh(key) }
        return .unavailable(host)
    }
    func subscribe(_ source: Source, preferred: SSHConnectionID? = nil) -> Subscription? {
        switch source {
        case .local: return .init(source: source, token: local.subscribe())
        case .ssh(let key): return remote.subscribe(key, preferred: preferred).map { .init(source: source, token: $0) }
        case .unavailable: return nil
        }
    }
    func unsubscribe(_ subscription: Subscription) {
        switch subscription.source {
        case .local: local.unsubscribe(subscription.token)
        case .ssh(let key): remote.unsubscribe(subscription.token, from: key)
        case .unavailable: break
        }
    }
    func snapshot(_ source: Source, includingHistory: Bool = true) -> HostStatisticsSnapshot {
        switch source {
        case .local:
            let value = local.latest
            var result = HostStatisticsSnapshot(host: HostSample.hostName, account: nil, remote: false,
                state: Self.state(local.state), date: value.date)
            if local.state != .loading || !local.history.isEmpty {
                result.cpu = value.cpuAvailable ? value.cpu : nil; result.cores = value.cpuAvailable ? value.cores : nil; result.load = value.load.isEmpty ? nil : value.load
                result.memoryUsed = value.memoryAvailable ? value.memoryUsed : nil; result.memoryTotal = value.memoryTotal
                result.swapUsed = value.swapAvailable ? value.swapUsed : nil; result.uptime = value.uptime
                result.receivedPerSecond = value.networkAvailable ? value.receivedPerSecond : nil; result.sentPerSecond = value.networkAvailable ? value.sentPerSecond : nil
                result.processes = value.processes
            }
            if value.diskTotal > 0 {
                result.volumes = [HostVolume(path: NSHomeDirectory(), total: value.diskTotal, free: value.diskFree)] + value.volumes
            }
            result.disksStale = local.disksStale
            if includingHistory { result.history = local.history.map { .init(date: $0.date, cpu: $0.cpuAvailable ? $0.cpu : nil, memoryPercent: $0.memoryAvailable ? $0.memoryPercent : nil) } }
            return result
        case .ssh(let key):
            guard let entry = remote.series[key] else { return .init(host: key.host, account: nil, remote: true, state: .unavailable, date: Date()) }
            var result = HostStatisticsSnapshot(host: entry.hostname ?? key.host, account: entry.scope.account, remote: true,
                state: Self.state(entry.state), date: entry.latest?.date ?? Date())
            if let value = entry.latest {
                result.cpu = value.cpu; result.cores = value.cores; result.load = value.counters.load
                result.memoryUsed = value.counters.memoryUsed; result.memoryTotal = value.counters.memoryTotal
                result.swapUsed = value.counters.swapUsed; result.uptime = value.counters.uptime
                result.receivedPerSecond = value.receivedPerSecond; result.sentPerSecond = value.sentPerSecond
            }
            result.volumes = entry.disks?.filter { $0.free <= $0.total }.map {
                HostVolume(path: $0.paths.joined(separator: " · "), total: $0.total, free: $0.free)
            }
            result.processes = entry.processes; result.processesPartial = entry.processesPartial
            result.disksStale = entry.disksStale
            if includingHistory { result.history = entry.history.map { .init(date: $0.date, cpu: $0.cpu, memoryPercent: $0.memoryPercent) } }
            return result
        case .unavailable(let host):
            return .init(host: host.rawValue, account: nil, remote: true, state: .unavailable, date: Date())
        }
    }
    private static func state(_ value: SSHStatisticsStore.State) -> HostStatisticsSnapshot.State {
        switch value { case .loading: .loading; case .ready: .ready; case .stale: .stale; case .unavailable: .unavailable }
    }
}
