import Foundation

/// The phone's frugal mode (docs/ios.md, Frugal mode): one phone-wide switch that every periodic sender reads, on while
/// the phone is in Low Power Mode or its network path is constrained (Low Data Mode, `NWPath.isConstrained`): the two
/// ways the user asks for less. Cellular alone (`NWPath.isExpensive`) does not count. Each knob decides for itself how much stricter it
/// is: host stats every 30 s (`HostStatistics.cadence`), Agents' `chat.list` poll every fourth tick of the shared clock
/// only (`AgentsPoll`), Review's and the branches' polls every other tick (`HostTraffic.cadence`). Nothing visible
/// changes beyond those cadences.
///
/// The API for other areas: read `active` (or `reason`, for words) when deciding, and observe `changed` (posted on the
/// main queue, object nil) to re-decide something already scheduled. Low Power Mode is watched from the first read;
/// the network path is fed by the composition's `NetworkPathWatcher` (`path(constrained:)`).
@MainActor
enum Frugal {
    /// Why the phone is frugal, the strongest reason first.
    enum Reason: String, Equatable, Sendable {
        case lowPower, lowData

        /// How the stats sheet names it ("Low Power Mode · sampling every 30 s").
        var label: String {
            switch self {
            case .lowPower: "Low Power Mode"
            case .lowData: "Low Data Mode"
            }
        }
    }

    /// Posted on the main queue whenever `active` or `reason` changes.
    static let changed = Notification.Name("yachts.dispatch.mobile.frugal-changed")

    /// Whether the phone is frugal now.
    static var active: Bool { reason != nil }

    /// Why the phone is frugal now; nil when it is not.
    static var reason: Reason? {
        observe()
        if let pinned { return pinned }
        return current
    }

    /// A reading of the network path (`NetworkPathWatcher.observed`): whether it is constrained (Low Data Mode).
    static func path(constrained: Bool) {
        observe()
        guard constrained != self.constrained else { return }
        let before = reason
        self.constrained = constrained
        if reason != before { post() }
    }

    /// Starts watching Low Power Mode now rather than at the first read (the app's launch).
    static func start() { observe() }

    /// Tests: frugal for `reason` (nil: not frugal) whatever the phone says, until `unpin()`.
    static func pin(_ reason: Reason?) {
        observe()
        let before = self.reason
        pinned = .some(reason)
        if self.reason != before { post() }
    }

    /// Tests: the phone's own state again.
    static func unpin() {
        let before = reason
        pinned = nil
        if reason != before { post() }
    }

    private static var observing = false
    private static var lowPower = false
    private static var constrained = false
    private static var pinned: Reason??

    private static var current: Reason? {
        lowPower ? .lowPower : constrained ? .lowData : nil
    }

    private static func observe() {
        guard !observing else { return }
        observing = true
        lowPower = System.lowPowerMode
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { powerStateChanged() }
        }
    }

    private static func powerStateChanged() {
        let now = System.lowPowerMode
        guard now != lowPower else { return }
        let before = reason
        lowPower = now
        if reason != before { post() }
    }

    private static func post() {
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
