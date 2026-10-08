import Foundation
import Darwin
import Observation

struct HostProcess: Identifiable, Codable, Sendable {
    let id: Int
    let name: String
    let cpu: Double?
    let memory: UInt64
}
struct HostVolume: Codable, Sendable {
    let path: String
    let total: UInt64
    let free: UInt64
}
struct HostSample: Codable, Sendable {
    static var hostName: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "this Mac" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    var date = Date()
    var cpuAvailable = true
    var networkAvailable = true
    var memoryAvailable = true
    var swapAvailable = true
    var cpu: Double = 0
    var cores: [Double] = []
    var load: [Double] = []
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var processes: [HostProcess] = []
    var volumes: [HostVolume] = []
    var receivedPerSecond: Double = 0
    var sentPerSecond: Double = 0
    var uptime: Double = 0
    var diskUsed: UInt64 { diskTotal - min(diskFree, diskTotal) }
    var memoryPercent: Double { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) * 100 : 0 }
    var diskPercent: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0 }
    var topCPU: [HostProcess] { Array(processes.filter { $0.cpu != nil }.sorted { ($0.cpu ?? 0) > ($1.cpu ?? 0) }.prefix(5)) }
    var topMemory: [HostProcess] { Array(processes.sorted { $0.memory > $1.memory }.prefix(5)) }
    static func bytes(_ bytes: UInt64) -> String { String(format: "%.1f GiB", Double(bytes) / 1_073_741_824) }
    var uptimeText: String { "up \(Int(uptime) / 86400)d \(Int(uptime) / 3600 % 24)h" }
}

/// This Mac's counters, read by the helper's stats plugin.
struct HostSampler: Sendable {
    private var helperStarted = false

    mutating func sample(includeStorage: Bool = true, includeProcesses: Bool = true) async throws -> HostSample {
        if !helperStarted {
            try await HelperStatistics.reset()
            helperStarted = true
        }
        return try await HelperStatistics.sample(includeStorage: includeStorage, includeProcesses: includeProcesses)
    }
}

@MainActor @Observable
final class HostStats {
    static let shared = HostStats()
    var latest = HostSample()
    var history: [HostSample] = []
    var state = SSHStatisticsStore.State.loading
    var disksStale = true
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var disksTask: Task<Void, Never>?
    @ObservationIgnored private var retired: Task<Void, Never>?
    @ObservationIgnored private var retiredDisks: Task<Void, Never>?
    @ObservationIgnored private var subscriptions: Set<UUID> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tracksHistoryInBackground = false
    @ObservationIgnored private let worker = HostSamplingWorker()
    @ObservationIgnored private let diskWorker = HostDiskSamplingWorker()
    @ObservationIgnored private let historyExpiry = StatisticsHistoryExpiry()
    @ObservationIgnored private let historyRetention: TimeInterval

    init(historyRetention: TimeInterval = 3600) {
        self.historyRetention = historyRetention.isFinite ? min(3600, max(0.001, historyRetention)) : 3600
    }
    private func trimHistory() {
        let cutoff = Date().addingTimeInterval(-historyRetention)
        history.removeAll { $0.date <= cutoff }
        if history.isEmpty { history = [] }
        if history.count > 1801 { history.removeFirst(history.count - 1801) }
        historyExpiry.schedule(at: history.lazy.map(\.date).min()?.addingTimeInterval(historyRetention)) { [weak self] in self?.trimHistory() }
    }

    func subscribe() -> UUID {
        let token = UUID(); subscriptions.insert(token); start(); startDisks(); return token
    }
    func unsubscribe(_ token: UUID) {
        subscriptions.remove(token)
        if subscriptions.isEmpty {
            if tracksHistoryInBackground {
                disksTask?.cancel(); retiredDisks = disksTask ?? retiredDisks; disksTask = nil
                disksStale = true
            } else { stop() }
        }
    }
    /// Keep the rolling chart populated for the app lifetime, even with no views open.
    func startBackgroundHistory() {
        tracksHistoryInBackground = true
        start()
    }
    func start() {
        guard task == nil else { return }
        let generation = generation, retired = retired
        self.retired = nil
        task = Task { [weak self, worker] in
            await retired?.value
            await worker.reset()
            while !Task.isCancelled {
                do {
                    let sample = try await worker.sample(includeProcesses: self?.subscriptions.isEmpty == false)
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    var value = sample
                    value.diskTotal = latest.diskTotal; value.diskFree = latest.diskFree; value.volumes = latest.volumes
                    latest = value; state = .ready
                    // Keep chart values only, never an hour of process tables.
                    var point = sample; point.processes = []; point.volumes = []; point.cores = []; point.load = []
                    history.append(point)
                    trimHistory()
                } catch {
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    state = state == .ready || state == .stale ? .stale : .unavailable
                    var point = HostSample()
                    point.cpuAvailable = false; point.networkAvailable = false
                    point.memoryAvailable = false; point.swapAvailable = false
                    history.append(point)
                    trimHistory()
                }
                guard let self else { return }
                let interval: Duration = subscriptions.isEmpty ? .seconds(5) : .seconds(2)
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
        if !subscriptions.isEmpty { startDisks() }
    }
    private func startDisks() {
        guard disksTask == nil else { return }
        let generation = generation, retiredDisks = retiredDisks
        self.retiredDisks = nil
        disksTask = Task { [weak self, diskWorker] in
            await retiredDisks?.value
            while !Task.isCancelled {
                do {
                    let sample = try await diskWorker.sample()
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    latest.diskTotal = sample.diskTotal; latest.diskFree = sample.diskFree; latest.volumes = sample.volumes
                    disksStale = sample.diskTotal == 0
                } catch {
                    guard let self, !Task.isCancelled, self.generation == generation else { return }
                    disksStale = true
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    func stop() {
        tracksHistoryInBackground = false
        generation = UUID()
        task?.cancel(); retired = task ?? retired; task = nil
        disksTask?.cancel(); retiredDisks = disksTask ?? retiredDisks; disksTask = nil
        if state == .ready { state = .stale }
        disksStale = true
        trimHistory()
    }
}

/// Expiry only removes chart points; it cannot sample or own any connection.
/// One sleeping timer per history is rescheduled only when its oldest point
/// changes, and disappears once the history is empty. Last samples are separate.
@MainActor
final class StatisticsHistoryExpiry {
    private var deadline: Date?
    private var task: Task<Void, Never>?
    func schedule(at date: Date?, action: @escaping @MainActor () -> Void) {
        guard date != deadline else { return }
        task?.cancel(); task = nil; deadline = date
        guard let date else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            deadline = nil; task = nil
            action()
        }
    }
    deinit { task?.cancel() }
}
private actor HostSamplingWorker {
    var sampler = HostSampler()
    func reset() { sampler = HostSampler() }
    func sample(includeProcesses: Bool) async throws -> HostSample {
        // HostStats waits for its retired sampler before resetting or starting another loop.
        var value = sampler
        defer { sampler = value }
        return try await value.sample(includeStorage: false, includeProcesses: includeProcesses)
    }
}
private actor HostDiskSamplingWorker {
    func sample() async throws -> HostSample {
        try await HelperStatistics.storage()
    }
}
