import AppKit
import Observation

/// One bounded echo at a time, borrowing an existing SSH provider. Latency
/// failures never retire the connection or interfere with statistics sampling.
@MainActor @Observable
final class SSHLatency {
    enum State { case loading, ready, stale, unavailable }
    private(set) var state = State.unavailable
    private(set) var milliseconds: Double?
    private(set) var date: Date?
    @ObservationIgnored private weak var provider: (any SSHStatisticsSampling)?
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let backgroundInterval: Duration

    init(interval: Duration = .seconds(2), backgroundInterval: Duration = .seconds(60)) {
        self.interval = interval; self.backgroundInterval = backgroundInterval
    }
    deinit { task?.cancel() }

    func reset() {
        generation = UUID()
        task?.cancel(); task = nil; provider = nil
        milliseconds = nil; date = nil; state = .unavailable
        foreground = false; sleeping = false
    }

    var label: String {
        guard let milliseconds else { return "—" }
        return milliseconds < 1 ? "<1 ms" : String(format: "%.0f ms", milliseconds)
    }
    var help: String {
        var text = "SSH latency · Round trip through the existing SSH connection, including helper response time."
        if let date { text += " Last measured \(date.formatted(date: .abbreviated, time: .standard))." }
        switch state {
        case .loading: text += " Measuring…"
        case .ready: break
        case .stale: text += " Stale: the last reading is not current."
        case .unavailable: text += " Unavailable. Requires a connected Stats or All features helper with latency support."
        }
        return text
    }

    func configure(provider: (any SSHStatisticsSampling)?, foreground: Bool, sleeping: Bool) {
        let provider = provider?.supportsLatency == true ? provider : nil
        guard self.provider !== provider || self.foreground != foreground || self.sleeping != sleeping else { return }
        let immediate = self.provider !== provider || (!self.foreground && foreground) || (self.sleeping && !sleeping)
        let changedConnection = self.provider !== provider
        self.provider = provider; self.foreground = foreground; self.sleeping = sleeping
        generation = UUID()
        let generation = generation, previous = task
        previous?.cancel()
        if provider == nil || sleeping || changedConnection {
            state = milliseconds == nil ? (provider != nil && !sleeping ? .loading : .unavailable) : .stale
        }
        guard let provider, !sleeping else { return }
        let interval = foreground ? interval : backgroundInterval
        task = Task { [weak self, weak provider] in
            // Drain cancellation before replacing a probe, including rapid
            // popup toggles and reconnects. Old replies cannot update this generation.
            await previous?.value
            if !immediate {
                do { try await Task.sleep(for: interval) } catch { return }
            }
            while !Task.isCancelled {
                do {
                    guard let provider else { return }
                    let start = ContinuousClock.now
                    try await provider.ping()
                    let elapsed = start.duration(to: .now).components
                    let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.milliseconds = max(0, milliseconds)
                    self?.date = Date()
                    self?.state = .ready
                } catch {
                    guard !Task.isCancelled, self?.generation == generation else { return }
                    self?.state = self?.milliseconds == nil ? .unavailable : .stale
                }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }
}

/// A provider borrows a terminal-owned connection. The statistics store cannot
/// create SSH sessions or keep an otherwise unused connection alive.
@MainActor
protocol SSHStatisticsSampling: AnyObject {
    var id: SSHConnectionID { get }
    var scope: SSHIntegrationScope { get }
    var host: String { get }
    var hostname: String? { get }
    var uid: UInt32 { get }
    var supportsStatistics: Bool { get }
    var supportsProcesses: Bool { get }
    var supportsLatency: Bool { get }
    func ping() async throws
    func processes() async throws -> SSHProcessCounters
    func sample() async throws -> SSHStatisticsCounters
    func disks() async throws -> [SSHStatisticsDisk]
    /// Helpers that measure rates themselves (helper4) return finished values; nil = raw counters.
    func measuredSample() async throws -> SSHStatisticsSample?
    func measuredProcesses() async throws -> (processes: [HostProcess], partial: Bool)?
}

extension SSHStatisticsSampling {
    var supportsLatency: Bool { false }
    func ping() async throws { throw HerdrFailure("SSH latency unavailable.") }
    var hostname: String? { nil }
    var supportsProcesses: Bool { false }
    func processes() async throws -> SSHProcessCounters { throw HerdrFailure("Process statistics unavailable.") }
    func measuredSample() async throws -> SSHStatisticsSample? { nil }
    func measuredProcesses() async throws -> (processes: [HostProcess], partial: Bool)? { nil }
}

@MainActor @Observable
final class SSHStatisticsStore {
    static let shared = SSHStatisticsStore(observesSystemSleep: true)
    enum State: Equatable { case loading, ready, stale, unavailable }
    struct Key: Hashable, Codable, Sendable {
        let authorization: String
        let host: String
        let uid: UInt32
    }
    struct Point {
        let date: Date
        var cpu: Double?
        var memoryPercent: Double?
        var receivedPerSecond: Double?
        var sentPerSecond: Double?
    }
    @MainActor @Observable
    final class Series {
        let scope: SSHIntegrationScope
        var latest: SSHStatisticsSample?
        var disks: [SSHStatisticsDisk]?
        var processes: [HostProcess]?
        var processesPartial = false
        var state = State.loading
        var disksStale = true
        var history: [Point] = []
        var hostIDs: Set<HostID> = []
        var hostname: String?
        let latency: SSHLatency
        @ObservationIgnored var latencySubscriptions: [UUID: SSHConnectionID?] = [:]
        @ObservationIgnored var providers: [SSHConnectionID: any SSHStatisticsSampling] = [:]
        @ObservationIgnored var subscriptions: [UUID: SSHConnectionID?] = [:]
        @ObservationIgnored var metricsTask: Task<Void, Never>?
        @ObservationIgnored var disksTask: Task<Void, Never>?
        @ObservationIgnored var processesTask: Task<Void, Never>?
        @ObservationIgnored var retiredProcesses: Task<Void, Never>?
        @ObservationIgnored var processRates = SSHProcessRates()
        @ObservationIgnored var retiredMetrics: Task<Void, Never>?
        @ObservationIgnored var retiredDisks: Task<Void, Never>?
        @ObservationIgnored var generation = UUID()
        @ObservationIgnored var rates = SSHStatisticsRates()
        @ObservationIgnored var failed: Set<SSHConnectionID> = []
        @ObservationIgnored private let historyExpiry = StatisticsHistoryExpiry()
        @ObservationIgnored private let historyRetention: TimeInterval
        init(scope: SSHIntegrationScope, historyRetention: TimeInterval = 3600,
             latencyInterval: Duration = .seconds(2), backgroundLatencyInterval: Duration = .seconds(60)) {
            self.scope = scope
            latency = SSHLatency(interval: latencyInterval, backgroundInterval: backgroundLatencyInterval)
            self.historyRetention = historyRetention.isFinite ? min(3600, max(0.001, historyRetention)) : 3600
        }

        func provider() -> (any SSHStatisticsSampling)? {
            let available = providers.filter { !failed.contains($0.key) }
            for preferred in (Array(latencySubscriptions.values) + Array(subscriptions.values)).compactMap({ $0 }) {
                if let provider = available[preferred] { return provider }
            }
            return available.sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }.first?.value
        }
        func append(_ point: Point) {
            history.append(point)
            trimHistory()
        }
        private func trimHistory() {
            let cutoff = Date().addingTimeInterval(-historyRetention)
            history.removeAll { $0.date <= cutoff }
            if history.isEmpty { history = [] }
            if history.count > 1801 { history.removeFirst(history.count - 1801) }
            historyExpiry.schedule(at: history.lazy.map(\.date).min()?.addingTimeInterval(historyRetention)) { [weak self] in self?.trimHistory() }
        }
        func stop() {
            stopTasks(preservingRates: false)
            trimHistory()
        }
        func changeSamplingCadence() {
            stopTasks(preservingRates: true)
        }
        private func stopTasks(preservingRates: Bool) {
            generation = UUID()
            metricsTask?.cancel(); retiredMetrics = metricsTask ?? retiredMetrics; metricsTask = nil
            disksTask?.cancel(); retiredDisks = disksTask ?? retiredDisks; disksTask = nil
            processesTask?.cancel(); retiredProcesses = processesTask ?? retiredProcesses; processesTask = nil
            processRates.reset()
            if !preservingRates { rates.reset() }
        }
    }
    private(set) var series: [Key: Series] = [:]

    func reset() {
        for value in series.values {
            value.stop()
            value.providers.removeAll(); value.subscriptions.removeAll(); value.latencySubscriptions.removeAll()
            value.latency.reset()
            value.latest = nil; value.disks = nil; value.processes = nil; value.history.removeAll()
            value.hostIDs.removeAll(); value.hostname = nil; value.state = .unavailable
        }
        series.removeAll()
    }

    func reset(_ host: HostID) {
        for key in keys(for: host) {
            guard let entry = series[key] else { continue }
            entry.hostIDs.remove(host)
            guard entry.hostIDs.isEmpty else { continue }
            entry.stop()
            entry.latency.reset()
            series[key] = nil
        }
    }
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private let backgroundInterval: Duration
    @ObservationIgnored private let diskInterval: Duration
    @ObservationIgnored private let historyRetention: TimeInterval
    @ObservationIgnored private let latencyInterval: Duration
    @ObservationIgnored private let backgroundLatencyInterval: Duration
    @ObservationIgnored private var sleeping = false

    init(interval: Duration = .seconds(2), backgroundInterval: Duration = .seconds(15),
         diskInterval: Duration = .seconds(15), historyRetention: TimeInterval = 3600,
         latencyInterval: Duration = .seconds(2), backgroundLatencyInterval: Duration = .seconds(60),
         observesSystemSleep: Bool = false) {
        self.interval = interval; self.backgroundInterval = backgroundInterval
        self.diskInterval = diskInterval; self.historyRetention = historyRetention
        self.latencyInterval = latencyInterval; self.backgroundLatencyInterval = backgroundLatencyInterval
        // Only the process-lifetime shared store installs workspace observers.
        if observesSystemSleep {
            for (name, sleeping) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
                _ = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.setSleeping(sleeping) }
                }
            }
        }
    }

    @discardableResult
    func register(_ provider: any SSHStatisticsSampling, grant: SSHIntegrationGrant, hostID: HostID? = nil) -> Key? {
        guard grant.isCurrent, grant.capabilities.contains("stats.sample"), provider.supportsStatistics else { return nil }
        let key = Key(authorization: provider.scope.key, host: provider.host, uid: provider.uid)
        let entry = series[key] ?? Series(scope: provider.scope, historyRetention: historyRetention,
                                          latencyInterval: latencyInterval, backgroundLatencyInterval: backgroundLatencyInterval)
        series[key] = entry
        if let hostID { entry.hostIDs.insert(hostID) }
        if let hostname = provider.hostname { entry.hostname = hostname }
        entry.providers[provider.id] = provider
        entry.failed.remove(provider.id)
        start(entry, metricsImmediately: true)
        updateLatency(entry)
        return key
    }

    func keys(for host: HostID) -> [Key] {
        series.keys.filter { series[$0]?.hostIDs.contains(host) == true }.sorted {
            let a = series[$0]!.scope, b = series[$1]!.scope
            return (a.account, a.destination, $0.authorization) < (b.account, b.destination, $1.authorization)
        }
    }

    func key(for connection: SSHConnectionID) -> Key? {
        series.first { $0.value.providers[connection] != nil }?.key
    }

    func remove(_ connection: SSHConnectionID) {
        for entry in series.values where entry.providers.removeValue(forKey: connection) != nil {
            entry.stop()
            entry.failed.remove(connection)
            entry.state = entry.latest == nil ? .unavailable : .stale
            entry.disksStale = true
            entry.append(Point(date: Date()))
            if !entry.providers.isEmpty { start(entry, metricsImmediately: true) }
            updateLatency(entry)
        }
    }

    func subscribe(_ key: Key, preferred: SSHConnectionID? = nil) -> UUID? {
        guard let entry = series[key] else { return nil }
        let startsForegroundSampling = entry.subscriptions.isEmpty
        let token = UUID()
        entry.subscriptions.updateValue(preferred, forKey: token)
        if startsForegroundSampling { entry.changeSamplingCadence() }
        start(entry, metricsImmediately: startsForegroundSampling)
        updateLatency(entry)
        return token
    }

    func unsubscribe(_ token: UUID, from key: Key) {
        guard let entry = series[key] else { return }
        entry.subscriptions.removeValue(forKey: token)
        if entry.subscriptions.isEmpty {
            // Aggregate counters keep the chart current in the background.
            // Process and disk collection remain foreground-only.
            entry.changeSamplingCadence()
            entry.disksStale = true
            start(entry, metricsImmediately: false)
        }
        updateLatency(entry)
    }

    func subscribeLatency(_ key: Key, preferred: SSHConnectionID? = nil) -> UUID? {
        guard let entry = series[key] else { return nil }
        let token = UUID()
        entry.latencySubscriptions.updateValue(preferred, forKey: token)
        updateLatency(entry)
        return token
    }

    func unsubscribeLatency(_ token: UUID, from key: Key) {
        guard let entry = series[key] else { return }
        entry.latencySubscriptions.removeValue(forKey: token)
        updateLatency(entry)
    }

    func setSleeping(_ sleeping: Bool) {
        self.sleeping = sleeping
        for entry in series.values { updateLatency(entry) }
    }

    private func updateLatency(_ entry: Series) {
        let provider = entry.provider() ?? entry.providers.sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }.first?.value
        entry.latency.configure(provider: provider, foreground: !entry.latencySubscriptions.isEmpty, sleeping: sleeping)
    }

    private func start(_ entry: Series, metricsImmediately: Bool) {
        guard !entry.providers.isEmpty else { return }
        let generation = entry.generation
        let samplingInterval = entry.subscriptions.isEmpty ? backgroundInterval : interval
        let diskInterval = diskInterval
        if entry.metricsTask == nil {
            let retired = entry.retiredMetrics
            entry.retiredMetrics = nil
            entry.metricsTask = Task { [weak self, weak entry] in
                defer { if entry?.generation == generation { entry?.metricsTask = nil } }
                await retired?.value
                if !metricsImmediately {
                    do { try await Task.sleep(for: samplingInterval) } catch { return }
                }
                while !Task.isCancelled {
                    guard let entry, entry.generation == generation, let provider = entry.provider() else { return }
                    do {
                        let measured = try await provider.measuredSample()
                        let counters: SSHStatisticsCounters
                        if let measured { counters = measured.counters } else { counters = try await provider.sample() }
                        guard !Task.isCancelled, entry.generation == generation, entry.providers[provider.id] === provider else { return }
                        let sample = measured ?? entry.rates.sample(counters, connection: provider.id)
                        var latest = sample
                        // A cadence switch can query twice within one remote
                        // counter tick. Keep the last same-boot CPU rate on
                        // screen, but leave the raw history point missing.
                        if latest.cpu == nil, counters.cpu != nil, let previous = entry.latest,
                           previous.counters.boot == counters.boot {
                            latest.cpu = previous.cpu; latest.cores = previous.cores
                        }
                        entry.latest = latest
                        var point = Point(date: sample.date, cpu: sample.cpu, receivedPerSecond: sample.receivedPerSecond, sentPerSecond: sample.sentPerSecond)
                        if let used = counters.memoryUsed, let total = counters.memoryTotal, total > 0, used <= total {
                            point.memoryPercent = Double(used) / Double(total) * 100
                        }
                        entry.append(point)
                        entry.state = .ready
                    } catch {
                        guard !Task.isCancelled, entry.generation == generation else { return }
                        entry.failed.insert(provider.id)
                        self?.updateLatency(entry)
                        entry.rates.reset()
                        entry.state = entry.latest == nil ? .unavailable : .stale
                        entry.append(Point(date: Date()))
                        // Only another already registered, authorized connection
                        // may take over. Failed connections are never reopened.
                        if entry.provider() == nil { return }
                    }
                    do { try await Task.sleep(for: samplingInterval) } catch { return }
                }
            }
        }
        guard !entry.subscriptions.isEmpty else { return }
        if entry.processesTask == nil {
            let retired = entry.retiredProcesses
            entry.retiredProcesses = nil
            entry.processesTask = Task { [weak entry] in
                defer { if entry?.generation == generation { entry?.processesTask = nil } }
                await retired?.value
                while !Task.isCancelled {
                    guard let entry, entry.generation == generation, let provider = entry.provider() else { return }
                    if provider.supportsProcesses {
                        do {
                            if let measured = try await provider.measuredProcesses() {
                                guard !Task.isCancelled, entry.generation == generation, entry.providers[provider.id] === provider else { return }
                                entry.processes = measured.processes
                                entry.processesPartial = measured.partial
                            } else {
                                let counters = try await provider.processes()
                                guard !Task.isCancelled, entry.generation == generation, entry.providers[provider.id] === provider else { return }
                                entry.processes = try entry.processRates.sample(counters, connection: provider.id)
                                entry.processesPartial = counters.truncated
                            }
                        } catch {
                            guard !Task.isCancelled, entry.generation == generation else { return }
                            entry.processes = nil; entry.processesPartial = false; entry.processRates.reset()
                        }
                    } else {
                        entry.processes = nil; entry.processesPartial = false; entry.processRates.reset()
                    }
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }
        if entry.disksTask == nil {
            let retired = entry.retiredDisks
            entry.retiredDisks = nil
            entry.disksTask = Task { [weak entry] in
                defer { if entry?.generation == generation { entry?.disksTask = nil } }
                await retired?.value
                while !Task.isCancelled {
                    guard let entry, entry.generation == generation, let provider = entry.provider() else { return }
                    do {
                        let disks = try await provider.disks()
                        guard !Task.isCancelled, entry.generation == generation, entry.providers[provider.id] === provider else { return }
                        entry.disks = disks; entry.disksStale = false
                    } catch {
                        guard !Task.isCancelled, entry.generation == generation else { return }
                        entry.disksStale = true
                    }
                    do { try await Task.sleep(for: diskInterval) } catch { return }
                }
            }
        }
    }
}
