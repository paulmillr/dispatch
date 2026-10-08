import Foundation

/// The app schedules samples and renders normalized values from its common connection.
enum HelperStatistics {
  struct Sample: Decodable, Sendable {
    let boot: String?
    let cpu: Double?
    let cores: [Double]
    let load: [Double]
    let memory: [UInt64]?
    let swap: [UInt64]?
    let received: Double?
    let sent: Double?
    let uptime: Double

    enum CodingKeys: String, CodingKey {
      case boot, cpu, cores, load, memory, swap, uptime
      case received = "received_per_second"
      case sent = "sent_per_second"
    }

    var host: HostSample {
      var result = HostSample()
      result.cpuAvailable = cpu != nil
      result.cpu = cpu ?? 0
      result.cores = cores
      result.load = load
      result.memoryAvailable = memory != nil
      result.memoryTotal = memory?.first ?? 0
      result.memoryUsed = memory?.last ?? 0
      result.swapAvailable = swap != nil
      result.swapUsed = swap?.last ?? 0
      result.networkAvailable = received != nil && sent != nil
      result.receivedPerSecond = received ?? 0
      result.sentPerSecond = sent ?? 0
      result.uptime = uptime
      return result
    }
  }

  struct Row: Decodable, Sendable {
    let pid: UInt32
    let name: String
    let cpu: Double?
    let rss: UInt64?

    var host: HostProcess {
      HostProcess(id: Int(pid), name: name, cpu: cpu, memory: rss ?? 0)
    }
  }

  struct Processes: Decodable, Sendable {
    let rows: [Row]
    let partial: Bool

    init(from decoder: any Decoder) throws {
      var values = try decoder.unkeyedContainer()
      rows = try values.decode([Row].self)
      partial = try values.decode(Bool.self)
    }
  }

  struct Disk: Decodable, Sendable {
    let identity: UInt64
    let paths: [String]
    let total: UInt64
    let available: UInt64
  }

  struct Reset: Encodable {
    let plugin = "stats"
    let topics: [String]
  }

  static func reset() async throws {
    let connection = try await HelperApp.shared.connection()
    let _: HelperClient.Empty = try await connection.request(
      "plugins.reset", params: Reset(topics: ["sample", "processes"]))
  }

  static func sample(includeStorage: Bool, includeProcesses: Bool) async throws -> HostSample {
    let connection = try await HelperApp.shared.connection()
    let sample: Sample = try await connection.request("stats.sample", params: [String: String]())
    var result = sample.host
    if includeProcesses {
      let processes: Processes = try await connection.request(
        "stats.processes", params: [String: String]())
      result.processes = processes.rows.map(\.host)
    }
    if includeStorage {
      let disks = try await storage()
      result.diskTotal = disks.diskTotal
      result.diskFree = disks.diskFree
      result.volumes = disks.volumes
    }
    return result
  }

  static func storage() async throws -> HostSample {
    let connection = try await HelperApp.shared.connection()
    let disks: [Disk] = try await connection.request("stats.disks", params: [String: String]())
    var result = HostSample()
    if let home = disks.first {
      result.diskTotal = home.total
      result.diskFree = home.available
    }
    result.volumes = disks.dropFirst().map {
      HostVolume(path: $0.paths.joined(separator: " · "), total: $0.total, free: $0.available)
    }
    return result
  }
}

/// Statistics from a server's helper4, which measures rates itself.
@MainActor
final class HelperStatisticsProvider: SSHStatisticsSampling {
  let id: SSHConnectionID
  let scope: SSHIntegrationScope
  let host: String
  let hostname: String?
  let uid: UInt32
  let supportsStatistics: Bool
  let supportsProcesses: Bool
  let supportsLatency = true

  init(id: SSHConnectionID, scope: SSHIntegrationScope, greeting: SSHGreeting) {
    self.id = id; self.scope = scope; host = greeting.host; hostname = greeting.hostname; uid = greeting.uid
    supportsStatistics = greeting.capabilities.contains("stats.sample")
    supportsProcesses = greeting.capabilities.contains("stats.processes")
  }

  private func request<Value: Decodable & Sendable>(_ method: String, seconds: Int = 3) async throws -> Value {
    let endpoint = HelperWorkspace.Endpoint.remote(id)
    return try await SSHTimeout.run(.seconds(seconds)) {
      try await HelperApp.shared.connection(endpoint).request(method, params: [String: String]())
    }
  }

  func ping() async throws {
    let _: [String: String] = try await request("echo")
  }

  func sample() async throws -> SSHStatisticsCounters { throw HerdrFailure("Raw counters are unavailable.") }

  func measuredSample() async throws -> SSHStatisticsSample? {
    let sample: HelperStatistics.Sample = try await request("stats.sample")
    let counters = SSHStatisticsCounters(
      boot: sample.boot ?? "", monotonic: sample.uptime, memoryTotal: sample.memory?.first,
      memoryUsed: sample.memory?.last, swapTotal: sample.swap?.first, swapUsed: sample.swap?.last,
      load: sample.load, uptime: sample.uptime)
    return SSHStatisticsSample(
      date: Date(), counters: counters, cpu: sample.cpu, cores: sample.cores,
      receivedPerSecond: sample.received, sentPerSecond: sample.sent)
  }

  func measuredProcesses() async throws -> (processes: [HostProcess], partial: Bool)? {
    let processes: HelperStatistics.Processes = try await request("stats.processes")
    return (processes.rows.map(\.host), processes.partial)
  }

  func disks() async throws -> [SSHStatisticsDisk] {
    let disks: [HelperStatistics.Disk] = try await request("stats.disks", seconds: 6)
    return disks.map {
      SSHStatisticsDisk(paths: $0.paths, identity: String($0.identity), total: $0.total, free: $0.available)
    }
  }
}
