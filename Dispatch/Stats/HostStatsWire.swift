import Foundation

/// Foundation-only responses from the helper's stats plugin (helper/PROTOCOL.md). Platform adapters select the
/// fields they consume: the phone can decode a partial sample, while the Mac requires the complete response.
enum HostStatsWire {
    struct Sample: Decodable, Sendable {
        let cpu: Double?
        let load: [Double]
        /// `[total, used]` bytes.
        let memory: [UInt64]?

        init(from decoder: any Decoder) throws {
            try self.init(from: decoder, requiresLoad: false)
        }

        /// The phone tolerates a missing load; the Mac's complete sample requires it.
        fileprivate init(from decoder: any Decoder, requiresLoad: Bool) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            cpu = try fields.decodeIfPresent(Double.self, forKey: .cpu)
            load = try requiresLoad ? fields.decode([Double].self, forKey: .load)
                                    : fields.decodeIfPresent([Double].self, forKey: .load) ?? []
            memory = try fields.decodeIfPresent([UInt64].self, forKey: .memory)
        }

        private enum CodingKeys: String, CodingKey { case cpu, load, memory }
    }

    /// The Mac uses the complete response. Required fields stay required rather than inventing uptime or cores.
    struct CompleteSample: Decodable, Sendable {
        private let values: Sample
        let boot: String?
        let cores: [Double]
        let swap: [UInt64]?
        let received: Double?
        let sent: Double?
        let uptime: Double

        var cpu: Double? { values.cpu }
        var load: [Double] { values.load }
        var memory: [UInt64]? { values.memory }

        init(from decoder: any Decoder) throws {
            values = try Sample(from: decoder, requiresLoad: true)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            boot = try fields.decodeIfPresent(String.self, forKey: .boot)
            cores = try fields.decode([Double].self, forKey: .cores)
            swap = try fields.decodeIfPresent([UInt64].self, forKey: .swap)
            received = try fields.decodeIfPresent(Double.self, forKey: .received)
            sent = try fields.decodeIfPresent(Double.self, forKey: .sent)
            uptime = try fields.decode(Double.self, forKey: .uptime)
        }

        private enum CodingKeys: String, CodingKey {
            case boot, cores, swap, uptime
            case received = "received_per_second"
            case sent = "sent_per_second"
        }
    }

    struct Row: Decodable, Sendable {
        let pid: UInt32
        let name: String
        let cpu: Double?
        let rss: UInt64?
    }

    /// `(rows, truncated)`.
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
        let paths: [String]
        let total: UInt64
        let available: UInt64
    }

    /// The Mac also uses the volume's stable identity; the phone ignores that field.
    struct IdentifiedDisk: Decodable, Sendable {
        private let volume: Disk
        let identity: UInt64

        var paths: [String] { volume.paths }
        var total: UInt64 { volume.total }
        var available: UInt64 { volume.available }

        init(from decoder: any Decoder) throws {
            volume = try Disk(from: decoder)
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            identity = try fields.decode(UInt64.self, forKey: .identity)
        }

        private enum CodingKeys: String, CodingKey { case identity }
    }
}
