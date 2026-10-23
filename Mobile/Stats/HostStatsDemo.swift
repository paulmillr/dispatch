#if DEBUG
import SwiftUI

/// The simulator demo's host stats (`DemoScenario`, `DemoHelper`): what each demo host's helper answers to `stats.*`,
/// and the 15 minutes before launch, so the sheet's chart is full from the first frame. Fictional numbers.
enum HostStatsDemo {
    struct Machine {
        let cpu: Double
        let load: Double
        let memoryUsed: Double
        let memoryTotal: Double
        let diskFree: Double
        let diskTotal: Double
        /// Name, CPU percent, resident GiB.
        let processes: [(String, Double, Double)]
        let seed: UInt64
    }

    static let gib: Double = 1_073_741_824

    static func machine(_ name: String) -> Machine {
        switch name {
        case "studio":
            Machine(cpu: 12, load: 1.04, memoryUsed: 18, memoryTotal: 64, diskFree: 610, diskTotal: 1000,
                    processes: [("codex", 9, 0.6), ("cargo", 6, 1.1), ("tmux", 1, 0.1), ("postgres", 0.5, 1.2)], seed: 5)
        case "ai":
            Machine(cpu: 71, load: 6.2, memoryUsed: 52, memoryTotal: 128, diskFree: 210, diskTotal: 1800,
                    processes: [("python", 88, 24), ("codex", 7, 0.7), ("nvtop", 2, 0.1)], seed: 23)
        default:
            Machine(cpu: 34, load: 2.71, memoryUsed: 11, memoryTotal: 32, diskFree: 48, diskTotal: 480,
                    processes: [("node", 50, 0.9), ("cargo", 41, 0.6), ("rust-analyzer", 32, 1.4), ("fixture-helper", 3, 2.3),
                                ("postgres", 2, 1.9)], seed: 11)
        }
    }

    /// `stats.sample`, `stats.processes` and `stats.disks` of a demo host, as the helper encodes them.
    static func answer(_ method: String, host: String, home: String) -> Any? {
        let machine = machine(host)
        switch method {
        case "stats.sample":
            return ["boot": "demo", "cpu_present": true, "cpu": machine.cpu, "cores": [Double](), "load": [machine.load, machine.load * 0.9, machine.load * 0.8],
                    "memory": [UInt64(machine.memoryTotal * gib), UInt64(machine.memoryUsed * gib)], "swap": NSNull(),
                    "received_per_second": NSNull(), "sent_per_second": NSNull(), "uptime": 86_400.0 * 3] as [String: Any]
        case "stats.processes":
            let rows: [[String: Any]] = machine.processes.enumerated().map { index, row in
                ["pid": UInt32(400 + index), "start": NSNull(), "name": row.0, "cpu": row.1, "rss": UInt64(row.2 * gib)]
            }
            return [rows, false] as [Any]
        case "stats.disks":
            return [["identity": UInt64(1), "paths": [home], "total": UInt64(machine.diskTotal * gib),
                     "available": UInt64(machine.diskFree * gib)] as [String: Any]]
        default:
            return nil
        }
    }

    /// The 15 minutes before `now`, one sample every 15 s (the mockups' `MockStats`): a sleep gap a quarter of the way
    /// in, a burst two thirds in, ending at the host's CPU.
    @MainActor static func seed(_ stats: HostStatistics, host: String, home: String, now: Date = Date()) {
        let machine = machine(host)
        var state = machine.seed
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        var value = machine.cpu * 0.8
        var points: [HostStatistics.Point] = []
        let count = HostStatistics.barCount
        for index in 0..<count {
            value = max(4, min(96, value + (random() - 0.5) * 18))
            if (12...15).contains(index) { continue }
            let cpu = (38...41).contains(index) ? min(100, value + 45) : index == count - 1 ? machine.cpu : value
            let memory = machine.memoryUsed / machine.memoryTotal * 100 + (random() - 0.5) * 4
            let date = now.addingTimeInterval(-Double(count - 1 - index) * HostStatistics.barSpan - 3)
            points.append(HostStatistics.Point(date: date, cpu: cpu, memory: memory))
        }
        let sample = HostStatistics.Sample(date: points.last?.date ?? now, cpu: machine.cpu, load: machine.load,
                                           memoryUsed: UInt64(machine.memoryUsed * gib), memoryTotal: UInt64(machine.memoryTotal * gib))
        let processes = machine.processes.enumerated().map { index, row in
            HostStatistics.Process(id: UInt32(400 + index), name: row.0, cpu: row.1, memory: UInt64(row.2 * gib))
        }
        stats.seed(sample: sample, history: points, processes: processes,
                   disk: HostStatistics.Disk(total: UInt64(machine.diskTotal * gib), free: UInt64(machine.diskFree * gib)))
    }

    /// Screenshot launches of the demo: `-DispatchHostStats <host>[:small|drag|large][:cpu|memory|scrub]` opens that
    /// host's stats sheet; `-DispatchHostStatsState offline` disconnects the host first (W1c, W5), `plain` starts it
    /// with its Helper switch off (W6); `-DispatchHostDetail <host>` pushes its host detail (W4).
    static var target: String? {
        UserDefaults.standard.string(forKey: "DispatchHostStats")?.split(separator: ":").first.map(String.init)
            ?? UserDefaults.standard.string(forKey: "DispatchHostDetail")
            ?? UserDefaults.standard.string(forKey: "DispatchHostStatsPopover")
    }

    static var plainHost: String? {
        UserDefaults.standard.string(forKey: "DispatchHostStatsState") == "plain" ? target : nil
    }

    static var launch: HostStatsLaunch {
        var launch = HostStatsLaunch()
        let parts = (UserDefaults.standard.string(forKey: "DispatchHostStats") ?? "").split(separator: ":").map(String.init)
        for part in parts.dropFirst() {
            switch part {
            case "large": launch.detent = .large
            case "drag": launch.detent = HostStatsSheet.dragging
            case "memory": launch.metric = .memory
            case "scrub": launch.scrub = 40
            default: break
            }
        }
        return launch
    }
}

/// Applies the screenshot launch arguments (`HostStatsDemo`) once the demo's hosts are up.
struct HostStatsDebugLaunch: ViewModifier {
    let composition: MobileComposition
    @State private var host: UUID?
    @State private var popover: UUID?
    @State private var applied = false

    func body(content: Content) -> some View {
        content
            // I5's content as the iPad stream will present it: a popover from a host glyph, here from the top right.
            .overlay(alignment: .topTrailing) {
                Color.clear.frame(width: 44, height: 44).padding(.top, 60).padding(.trailing, 20)
                    .popover(isPresented: Binding(get: { popover != nil }, set: { if !$0 { popover = nil } })) {
                        if let popover { HostStatsPopoverContent(hostID: popover).presentationCompactAdaptation(.popover) }
                    }
                    .allowsHitTesting(false)
            }
            .sheet(item: Binding(get: { host.map(HostStatsDebugItem.init) }, set: { host = $0?.id })) { item in
                HostStatsSheet(hostID: item.id, launch: HostStatsDemo.launch)
            }
            .task {
                guard !applied, let name = HostStatsDemo.target else { return }
                applied = true
                guard let session = composition.hosts.ordered.first(where: { $0.host.name == name }) else { return }
                // The demo's hosts connect in about 200 ms.
                for _ in 0..<40 where !session.link.isConnected { try? await Task.sleep(for: .milliseconds(50)) }
                if UserDefaults.standard.string(forKey: "DispatchHostStatsState") == "offline" { session.park() }
                if UserDefaults.standard.string(forKey: "DispatchHostDetail") != nil {
                    composition.navigator.path = [.host(session.id)]
                }
                if UserDefaults.standard.string(forKey: "DispatchHostStats") != nil { host = session.id }
                if UserDefaults.standard.string(forKey: "DispatchHostStatsPopover") != nil { popover = session.id }
            }
    }
}

private struct HostStatsDebugItem: Identifiable {
    let id: UUID
}
#endif
