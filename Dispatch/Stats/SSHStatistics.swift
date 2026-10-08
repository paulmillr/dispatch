import Foundation

/// Wire counters carry remote monotonic time. Local wall-clock time is used
/// only to place an observation in history, never as a rate denominator.
struct SSHStatisticsCounters: Codable, Sendable {
    struct CPU: Codable, Equatable, Sendable { let name: String; let busy: UInt64; let total: UInt64 }
    struct Network: Codable, Equatable, Sendable { let name: String; let received: UInt64; let sent: UInt64 }
    let boot: String
    let monotonic: Double
    var cpu: [CPU]?
    var network: [Network]?
    var memoryTotal: UInt64?
    var memoryUsed: UInt64?
    var swapTotal: UInt64?
    var swapUsed: UInt64?
    var load: [Double]?
    var uptime: Double?
}

struct SSHStatisticsDisk: Codable, Sendable {
    let paths: [String]
    let identity: String
    let total: UInt64
    let free: UInt64
}

struct SSHStatisticsSample: Sendable {
    let date: Date
    let counters: SSHStatisticsCounters
    var cpu: Double?
    var cores: [Double]?
    var receivedPerSecond: Double?
    var sentPerSecond: Double?
}

struct SSHStatisticsRates {
    private var previous: SSHStatisticsCounters?
    private var generation: SSHConnectionID?

    mutating func reset() { previous = nil; generation = nil }

    mutating func sample(_ counters: SSHStatisticsCounters, connection: SSHConnectionID, date: Date = Date()) -> SSHStatisticsSample {
        var sample = SSHStatisticsSample(date: date, counters: counters)
        defer { previous = counters; generation = connection }
        guard counters.monotonic.isFinite, let old = previous, generation == connection,
              !counters.boot.isEmpty, old.boot == counters.boot,
              old.monotonic.isFinite, counters.monotonic > old.monotonic else { return sample }
        let elapsed = counters.monotonic - old.monotonic
        guard elapsed.isFinite, elapsed > 0 else { return sample }
        if let current = counters.cpu, let before = old.cpu, current.count <= 8193,
           current.count == before.count, !current.isEmpty, current[0].name == "cpu",
           Set(current.map(\.name)).count == current.count,
           zip(current, before).allSatisfy({ $0.name == $1.name && $0.total > $1.total && $0.busy >= $1.busy && $0.busy <= $0.total && $1.busy <= $1.total && $0.busy - $1.busy <= $0.total - $1.total }) {
            let values = zip(current, before).map { Double($0.busy - $1.busy) / Double($0.total - $1.total) * 100 }
            sample.cpu = values.first
            sample.cores = Array(values.dropFirst())
        }
        if let current = counters.network, let before = old.network, current.count <= 4096,
           current.count == before.count, Set(current.map(\.name)).count == current.count {
            let sorted = current.sorted { $0.name < $1.name }, prior = before.sorted { $0.name < $1.name }
            if zip(sorted, prior).allSatisfy({ $0.name == $1.name && $0.received >= $1.received && $0.sent >= $1.sent }) {
                let received = zip(sorted, prior).reduce(0.0) { $0 + Double($1.0.received - $1.1.received) / elapsed }
                let sent = zip(sorted, prior).reduce(0.0) { $0 + Double($1.0.sent - $1.1.sent) / elapsed }
                if received.isFinite && sent.isFinite { sample.receivedPerSecond = received; sample.sentPerSecond = sent }
            }
        }
        return sample
    }
}

/// Process tables never enter chart history. Identity includes the remote boot,
/// connection generation, PID and start time; names are display-only.
struct SSHProcessCounters: Codable, Sendable {
    struct Process: Codable, Sendable {
        let pid: Int32
        let start: String
        let name: String
        let cpuNanos: UInt64
        let rss: UInt64
    }
    let boot: String
    let monotonic: Double
    let truncated: Bool
    let processes: [Process]

    func validate() throws {
        func safe(_ text: String, limit: Int) -> Bool {
            !text.isEmpty && text.utf8.count <= limit && !text.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
            }
        }
        guard safe(boot, limit: 256), monotonic.isFinite, monotonic >= 0, processes.count <= 4096,
              Set(processes.map(\.pid)).count == processes.count,
              processes.allSatisfy({ process in
                  let start = process.start.split(separator: ":", omittingEmptySubsequences: false)
                  return process.pid > 0 && safe(process.name, limit: 128) && safe(process.start, limit: 64)
                      && (1...2).contains(start.count)
                      && start.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && UInt64($0) != nil }
                      && (start.count == 1 || (UInt64(start[1]) ?? .max) < 1_000_000)
                      && process.rss <= UInt64(Int64.max)
              }) else { throw HerdrFailure("Invalid remote process statistics.") }
    }
}

struct SSHProcessRates {
    private var previous: SSHProcessCounters?
    private var generation: SSHConnectionID?
    mutating func reset() { previous = nil; generation = nil }
    mutating func sample(_ counters: SSHProcessCounters, connection: SSHConnectionID) throws -> [HostProcess] {
        do { try counters.validate() } catch { reset(); throw error }
        var before: [Int32: SSHProcessCounters.Process] = [:]
        var elapsed: Double?
        if let old = previous, generation == connection, old.boot == counters.boot,
           counters.monotonic > old.monotonic, (counters.monotonic - old.monotonic).isFinite {
            before = Dictionary(uniqueKeysWithValues: old.processes.map { ($0.pid, $0) })
            elapsed = counters.monotonic - old.monotonic
        }
        defer { previous = counters; generation = connection }
        return counters.processes.map { process in
            var cpu: Double?
            if let old = before[process.pid], old.start == process.start,
               process.cpuNanos >= old.cpuNanos, let elapsed {
                let rate = Double(process.cpuNanos - old.cpuNanos) / 1_000_000_000 / elapsed * 100
                if rate.isFinite && rate >= 0 { cpu = rate }
            }
            return HostProcess(id: Int(process.pid), name: process.name, cpu: cpu, memory: process.rss)
        }
    }
}
