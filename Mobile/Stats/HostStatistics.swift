import Foundation
import Observation

/// One host's stats (docs/ios.md, Host stats): CPU, load, memory, the home volume's disk and the top processes from its
/// helper, and the last 15 minutes of CPU and memory as 60 bars of 15 s. Owned by the `HostSession`, which hands it
/// each helper connection's client (`attach`); it samples only while `active` (the app in the foreground) and a helper
/// client is attached: every 2 s while a stats sheet or popover shows it (`beginViewing`), else on the shared clock's
/// 15 s ticks (`HostTraffic`), 30 s under Low Power Mode. Only a viewer's samples ask for the process list (about
/// 100 KB from a busy Mac, which only the sheet shows); the disks are asked at most every 15 s while viewed, every
/// minute otherwise; a sample's requests go out together. A sample on a tick stands in for the connection's liveness
/// ping (`HostPulse`) and its round trip is the host's latency (`roundTrip`). A plain SSH connection, the background
/// and a dropped link sample nothing; the last sample stays (`stale`, with its time) and so does the history, whose
/// missing bars are gaps.
///
/// The API other areas read (the watch's snapshot, the stats views): `sample`, `disk`, `processes`, `bars(_:at:)`,
/// `peak(_:at:)`, `average(_:at:)`, `live`, `stale`, `summary(at:)`.
@MainActor @Observable
final class HostStatistics {
    struct Sample: Equatable, Sendable {
        var date: Date
        /// Percent of all cores; nil when the helper could not measure it yet (the first sample of a connection).
        var cpu: Double?
        /// The 1-minute load average.
        var load: Double?
        var memoryUsed: UInt64?
        var memoryTotal: UInt64?

        var memoryPercent: Double? {
            guard let used = memoryUsed, let total = memoryTotal, total > 0, used <= total else { return nil }
            return Double(used) / Double(total) * 100
        }
    }

    struct Process: Identifiable, Equatable, Sendable {
        let id: UInt32
        let name: String
        let cpu: Double?
        let memory: UInt64
    }

    /// The home folder's volume (the helper lists it first).
    struct Disk: Equatable, Sendable {
        let total: UInt64
        let free: UInt64
        var used: UInt64 { total - min(free, total) }
        var usedPercent: Double? { total > 0 ? Double(used) / Double(total) * 100 : nil }
    }

    /// A sample in the history: CPU and memory percent.
    struct Point: Equatable, Sendable {
        let date: Date
        let cpu: Double?
        let memory: Double?
    }

    enum Metric: String, CaseIterable, Sendable {
        case cpu, memory
        var title: String { self == .cpu ? "CPU" : "Memory" }
    }

    nonisolated static let window: TimeInterval = 15 * 60
    nonisolated static let barCount = 60
    nonisolated static var barSpan: TimeInterval { window / Double(barCount) }
    /// How often the disks are asked: with a sample at most every 15 s while a sheet shows them, every minute otherwise
    /// (the watch's and the host rows' free space changes slowly).
    nonisolated static func diskInterval(viewing: Bool) -> TimeInterval { viewing ? 15 : 60 }

    /// How often to sample: 2 s while a sheet or popover shows the stats, 15 s otherwise, 30 s under Low Power Mode
    /// (the phone samples only in the foreground; the Mac's `StatisticsCadence` keeps 15 s while shown, 60 s otherwise).
    /// Each sample is a helper request, a frame that wakes the link and the radio. Every 15 s bar gets a sample, or
    /// under Low Power Mode every other one and the bar between takes the later sample (`barHold`). Without a viewer the
    /// samples land on the shared clock's ticks (`HostTraffic`), with the liveness ping's and every other host's.
    nonisolated static func cadence(viewing: Bool, lowPower: Bool) -> Duration {
        lowPower ? .seconds(30) : viewing ? .seconds(2) : HostTraffic.interval
    }

    /// The longest gap between two samples whose empty bars take the later one (`bars`): Low Power Mode's 30 s cadence
    /// leaves every other bar without a sample of its own, plus the requests' own time.
    nonisolated static let barHold: TimeInterval = 35

    private(set) var sample: Sample?
    private(set) var processes: [Process] = []
    /// The helper cut the process list short.
    private(set) var processesPartial = false
    private(set) var disk: Disk?
    /// Oldest first, the last 15 minutes and a little more.
    private(set) var history: [Point] = []
    /// The current connection has sampled (a helper client is attached, the app is in the foreground and a sample of
    /// this connection is in): the numbers are current. Until a new connection's first sample they stay stale.
    private(set) var live = false
    /// Low Power Mode as last read (the W7 banner).
    private(set) var lowPower = false
    /// How many stats sheets or popovers show this host now.
    private(set) var viewers: Set<UUID> = []

    /// The app is in the foreground (`HostSessions.setActive`): nothing samples in the background.
    var active = false {
        didSet { if active != oldValue { reschedule() } }
    }

    var viewing: Bool { !viewers.isEmpty }
    var cadence: Duration { Self.cadence(viewing: viewing, lowPower: lowPower) }
    /// The last sample is not current: the link dropped, the app went to the background or the connection is plain.
    var stale: Bool { !live && sample != nil }

    @ObservationIgnored var now: @MainActor () -> Date = { System.date() }
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var readLowPower: @MainActor () -> Bool = { System.lowPowerMode }
    /// How long a request may take (the Mac's 3 s); the disks get twice as long.
    @ObservationIgnored var timeout: Duration = .seconds(3)
    /// The connection's liveness ping, told which ticks a sample covers (`HostSession` shares it with the driver).
    @ObservationIgnored var pulse: HostPulse?
    /// A tick's `stats.sample` round trip, the host's latency while the ping skips (`HostSession.latency`).
    @ObservationIgnored var roundTrip: (@MainActor (Duration) -> Void)?

    @ObservationIgnored private var client: HelperClient?
    /// This connection's last process list and disks reading.
    @ObservationIgnored private var processesRead: Date?
    @ObservationIgnored private var disksRead: Date?
    /// The shared clock's tick the next sample is for; nil for a viewer's (off the clock).
    @ObservationIgnored private var dueTick: Date?
    @ObservationIgnored private var samples = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init() {}

    /// Each connection's helper client, nil when it goes (a drop, a disconnect, a plain SSH connection).
    func attach(_ client: HelperClient?) {
        guard client !== self.client else { return }
        self.client = client
        processesRead = nil
        disksRead = nil
        samples = 0
        // A new connection's numbers are not in yet.
        if live { live = false }
        reschedule()
    }

    /// A stats view appeared; end it with `endViewing`. The first viewer samples now, with the process list (unless a
    /// sample with one is under 2 s old), and every 2 s from then.
    func beginViewing() -> UUID {
        let token = System.uuid()
        viewers.insert(token)
        if viewers.count == 1 { reschedule() }
        return token
    }

    func endViewing(_ token: UUID) {
        guard viewers.remove(token) != nil, viewers.isEmpty else { return }
        reschedule()
    }

    /// Low Power Mode changed (`NSProcessInfoPowerStateDidChange`).
    func powerStateChanged() {
        guard readLowPower() != lowPower else { return }
        reschedule()
    }

    /// What an edit that replaced the session keeps: the samples and history.
    func adopt(_ other: HostStatistics) {
        sample = other.sample
        processes = other.processes
        processesPartial = other.processesPartial
        disk = other.disk
        history = other.history
    }

    // MARK: Sampling

    private func reschedule() {
        task?.cancel()
        task = nil
        generation += 1
        dueTick = nil
        pulse?.expect(nil)
        let reading = readLowPower()
        if lowPower != reading { lowPower = reading }
        guard active, let client else {
            if live { live = false }
            return
        }
        let generation = generation
        let sleep = sleep
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.delay(generation) else { return }
                if delay > .zero {
                    do { try await sleep(delay) } catch { return }
                }
                guard let self, self.generation == generation else { return }
                await self.tick(client, generation: generation)
            }
        }
    }

    /// Until the next sample. A viewer's: a cadence after this connection's last sample with the process list, without
    /// one now. Otherwise the shared clock's next tick of the cadence at least half of one away (`HostTraffic`; no sample
    /// is needed before anything shows it), told to the liveness ping, which skips that tick.
    private func delay(_ generation: Int) -> Duration? {
        guard self.generation == generation else { return nil }
        let now = now()
        guard !viewing else {
            dueTick = nil
            pulse?.expect(nil)
            guard let start = processesRead else { return .zero }
            let seconds = cadence.seconds - now.timeIntervalSince(start)
            return seconds > 0 ? .milliseconds(Int((seconds * 1000).rounded(.up))) : .zero
        }
        let wait = HostTraffic.wait(every: cadence, from: now)
        dueTick = wait.tick
        pulse?.expect(wait.tick)
        return wait.delay
    }

    private func tick(_ client: HelperClient, generation: Int) async {
        let started = now()
        let viewed = viewing
        let tick = dueTick
        if let tick { pulse?.sampled(tick) }
        let readsDisks = disksRead.map { started.timeIntervalSince($0) >= Self.diskInterval(viewing: viewed) - 0.5 } ?? true
        // The requests go out together, each bounded as the Mac's (3 s, the disks 6 s), so a stuck one cannot stall
        // sampling (the helper runs each kind in its own slot); a cancelled loop (another connection, the background, a
        // new cadence) cancels them. The process list only for a viewer.
        let timeout = timeout
        async let timed = Self.timedRequest(client, "stats.sample", timeout: timeout) as (HostStatsWire.Sample, Duration)?
        async let listed: HostStatsWire.Processes? = viewed ? Self.request(client, "stats.processes", timeout: timeout) : nil
        async let volumes: [HostStatsWire.Disk]? = readsDisks ? Self.request(client, "stats.disks", timeout: timeout * 2) : nil
        let (sampledWire, rows, disks) = await (timed, listed, volumes)
        // The ping skipped this tick for the sample: without its answer (refused before it left, as a connection whose
        // profile lacks `stats.sample` does, or lost) the tick's `echo` goes now, so the helper still hears the phone.
        var echoed: Duration?
        if sampledWire == nil, tick != nil, !Task.isCancelled {
            let reply: ([String: String], Duration)? = await Self.timedRequest(client, "echo", timeout: timeout)
            echoed = reply?.1
        }
        // Another connection, a disconnect or the background since: not this connection's any more.
        guard !Task.isCancelled, self.generation == generation, self.client === client else { return }
        let date = now()
        if viewed { processesRead = date }
        if readsDisks { disksRead = date }
        if let sampledWire {
            apply(sampledWire.0, at: date)
            // On a tick the sample is the ping (which skipped it); a viewer's 2 s samples leave the latency to the ping.
            if !viewed { roundTrip?(sampledWire.1) }
        } else if let echoed {
            roundTrip?(echoed)
        }
        if let rows {
            let next = rows.rows.map { Process(id: $0.pid, name: $0.name, cpu: $0.cpu, memory: $0.rss ?? 0) }
            if processes != next { processes = next }
            if processesPartial != rows.partial { processesPartial = rows.partial }
        }
        if let home = disks?.first {
            let next = Disk(total: home.total, free: home.available)
            if disk != next { disk = next }
        }
    }

    /// `request`, with its round trip.
    private static func timedRequest<Value: Decodable & Sendable>(_ client: HelperClient, _ method: String,
                                                                 timeout: Duration) async -> (Value, Duration)? {
        let started = ContinuousClock.now
        let value: Value? = await request(client, method, timeout: timeout)
        return value.map { ($0, ContinuousClock.now - started) }
    }

    /// `method` on `client`, nil after `timeout` (the request is cancelled) or on any failure.
    private static func request<Value: Decodable & Sendable>(_ client: HelperClient, _ method: String, timeout: Duration) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { try? await client.connection.request(method, params: [String: String]()) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func apply(_ wire: HostStatsWire.Sample, at date: Date) {
        let cpu = wire.cpu.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let next = Sample(date: date, cpu: cpu, load: wire.load.first, memoryUsed: wire.memory?.last,
                          memoryTotal: wire.memory?.first)
        history.append(Point(date: date, cpu: cpu, memory: next.memoryPercent))
        defer {
            let cutoff = date.addingTimeInterval(-Self.window - 60)
            if let first = history.firstIndex(where: { $0.date >= cutoff }), first > 0 { history.removeFirst(first) }
        }
        samples += 1
        // A connection's first CPU has no interval to measure over: until the next sample the last one stays, stale,
        // rather than a current line without CPU (or an earlier connection's CPU shown as current).
        if cpu == nil, samples == 1, sample?.cpu != nil { return }
        sample = next
        if !live { live = true }
    }

    // MARK: Reading

    /// The chart's bars, oldest first: one per 15 s on a fixed wall-clock grid, so only the newest bar changes as samples
    /// land and the chart steps one bar left every 15 s (the Mac's `HostStatisticsSnapshot.historyBars`). A bar is the
    /// peak of its own samples; one without, between two samples at most `hold` apart, takes the later one (the 15 s
    /// cadence drifts past a bar now and then, Low Power Mode's 30 s skips every other one). Nil is a gap: no sample
    /// (offline, the background).
    func bars(_ metric: Metric, at now: Date, count: Int = HostStatistics.barCount, hold: TimeInterval = HostStatistics.barHold) -> [Double?] {
        Self.bars(history, metric: metric, at: now, count: count, hold: hold)
    }

    nonisolated static func bars(_ history: [Point], metric: Metric, at now: Date, count: Int = barCount,
                                 hold: TimeInterval = barHold) -> [Double?] {
        StatisticsHistory.bars(history, at: now, window: window, count: count, hold: hold,
                               date: { $0.date }, value: { metric == .cpu ? $0.cpu : $0.memory })
    }

    /// When bar `index` of `bars(_:at:)` starts.
    nonisolated static func barStart(_ index: Int, at now: Date, count: Int = barCount) -> Date {
        let span = window / Double(count)
        let slot = Int((now.timeIntervalSinceReferenceDate / span).rounded(.down)) - (count - 1) + index
        return Date(timeIntervalSinceReferenceDate: Double(slot) * span)
    }

    /// The highest sample of the last 15 minutes (percent).
    func peak(_ metric: Metric, at now: Date) -> Double? { values(metric, at: now).max() }

    /// The mean of the last 15 minutes' samples (percent).
    func average(_ metric: Metric, at now: Date) -> Double? {
        let values = values(metric, at: now)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func values(_ metric: Metric, at now: Date) -> [Double] {
        history.filter { $0.date > now.addingTimeInterval(-Self.window) && $0.date <= now }
            .compactMap { metric == .cpu ? $0.cpu : $0.memory }.filter(\.isFinite)
    }

    /// The top processes by CPU or by memory.
    func top(_ metric: Metric, count: Int = 3) -> [Process] {
        switch metric {
        case .cpu:
            Array(processes.filter { $0.cpu?.isFinite == true }
                .sorted { ($0.cpu ?? 0, -Int64($0.id)) > ($1.cpu ?? 0, -Int64($1.id)) }.prefix(count))
        case .memory:
            Array(processes.sorted { ($0.memory, -Int64($0.id)) > ($1.memory, -Int64($1.id)) }.prefix(count))
        }
    }

    /// Everything a compact surface shows at once (the watch's host screen): nil before the first sample.
    func summary(at now: Date) -> HostStatsSummary? {
        guard let sample else { return nil }
        return HostStatsSummary(date: sample.date, stale: stale, cpu: sample.cpu, load: sample.load,
                                memoryUsed: sample.memoryUsed, memoryTotal: sample.memoryTotal,
                                diskFree: disk?.free, diskTotal: disk?.total, bars: bars(.cpu, at: now),
                                peak: peak(.cpu, at: now), average: average(.cpu, at: now))
    }

    #if DEBUG
    /// The simulator demo's earlier 15 minutes (`DemoScenario`): a host that has been connected a while.
    func seed(sample: Sample, history: [Point], processes: [Process], disk: Disk?) {
        self.sample = sample
        self.history = history
        self.processes = processes
        self.disk = disk
    }
    #endif
}

/// A host's stats at a glance, from `HostStatistics.summary(at:)`: what the watch's host screen and other compact
/// surfaces draw. Values are bytes and percent; `bars` are the 60 × 15 s CPU bars, nil for a gap.
struct HostStatsSummary: Equatable, Sendable {
    let date: Date
    let stale: Bool
    let cpu: Double?
    let load: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let diskFree: UInt64?
    let diskTotal: UInt64?
    let bars: [Double?]
    let peak: Double?
    let average: Double?

    var cpuHigh: Bool { HostStatsFormat.cpuHigh(cpu) }
    var memoryHigh: Bool {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return false }
        return HostStatsFormat.memoryHigh(Double(used) / Double(total) * 100)
    }
    var diskHigh: Bool {
        guard let free = diskFree, let total = diskTotal, total > 0 else { return false }
        return HostStatsFormat.diskHigh(Double(total - min(free, total)) / Double(total) * 100)
    }
}

/// The words and numbers of the stats views, in one place for the views and the tests.
enum HostStatsFormat {
    /// A value in red: CPU at 90 % or more, memory over 90 % used, a disk over 80 % used (the Mac's disk warning).
    static func cpuHigh(_ percent: Double?) -> Bool { (percent ?? 0) >= 90 }
    static func memoryHigh(_ percent: Double?) -> Bool { (percent ?? 0) > 90 }
    static func diskHigh(_ percent: Double?) -> Bool { (percent ?? 0) > 80 }

    /// "34" (whole percent), "—" without one.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(Int(value.rounded()))
    }

    /// Bytes as a number and its unit (binary, as the Mac's stats): "11" "GB", "7.4" "GB", "1.2" "TB", "512" "MB".
    static func size(_ bytes: UInt64?) -> (value: String, unit: String) {
        guard let bytes else { return ("—", "GB") }
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 1000 { return (one(gib / 1024), "TB") }
        if gib < 1 { return (String(Int((gib * 1024).rounded())), "MB") }
        return (gib < 10 ? one(gib) : String(Int(gib.rounded())), "GB")
    }

    /// "2.3 GB".
    static func sizeText(_ bytes: UInt64?) -> String {
        let size = size(bytes)
        return "\(size.value) \(size.unit)"
    }

    /// "2.71 load".
    static func load(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "no load" }
        return String(format: "%.2f load", value)
    }

    /// "peak 82% · avg 31%".
    static func peakLine(peak: Double?, average: Double?) -> String? {
        guard let peak, let average else { return nil }
        return "peak \(percent(peak))% · avg \(percent(average))%"
    }

    /// "2:02 PM".
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    private static func one(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
