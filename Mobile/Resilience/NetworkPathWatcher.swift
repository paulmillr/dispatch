import Foundation
import Network

/// One reading of the device's network path: whether it is usable, and the interfaces it goes through in the
/// system's order of preference ("wifi:en0", "cellular:pdp_ip0").
struct NetworkPath: Equatable, Sendable {
    var satisfied: Bool
    var interfaces: [String]
}

/// Where readings come from: `NWPathMonitor` in the app, a test's own pushes in tests.
protocol NetworkPathSource: AnyObject, Sendable {
    func start(_ update: @escaping @Sendable (NetworkPath) -> Void)
    func cancel()
}

/// The system's path monitor.
final class SystemNetworkPathSource: NetworkPathSource, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "yachts.dispatch.mobile.network-path")

    func start(_ update: @escaping @Sendable (NetworkPath) -> Void) {
        monitor.pathUpdateHandler = { path in
            update(NetworkPath(satisfied: path.status == .satisfied,
                               interfaces: path.availableInterfaces.map { "\(Self.name($0.type)):\($0.name)" }))
        }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }

    private static func name(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "wired"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "unknown"
        }
    }
}

/// Calls `changed` when the network path becomes usable again or, while usable, moves to other interfaces (Wi-Fi to
/// cellular, a VPN coming up): the moments a waiting reconnect should try at once and a connected link may have died
/// without a word (plan 3.2). The first reading is the baseline; losing the path calls nothing (the links notice).
@MainActor
final class NetworkPathWatcher {
    private let source: any NetworkPathSource
    private let changed: @MainActor () -> Void
    private(set) var last: NetworkPath?
    /// Every reading, the first included (whether the iPhone is offline, for what the hosts say).
    var observed: (@MainActor (NetworkPath) -> Void)?

    init(source: any NetworkPathSource = SystemNetworkPathSource(), changed: @escaping @MainActor () -> Void) {
        self.source = source
        self.changed = changed
    }

    func start() {
        source.start { [weak self] path in
            Task { @MainActor in self?.receive(path) }
        }
    }

    func stop() { source.cancel() }

    func receive(_ path: NetworkPath) {
        defer { last = path }
        observed?(path)
        guard let last, path.satisfied else { return }
        if !last.satisfied || path.interfaces != last.interfaces { changed() }
    }
}
