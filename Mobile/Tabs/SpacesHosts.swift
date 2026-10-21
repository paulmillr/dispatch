import SwiftUI

/// What the Spaces tab shows of a host's connection (the host session's `HostLink`, mapped by the integration).
enum SpacesHostState: Equatable, Sendable {
    case connected
    /// Connecting, authenticating, bootstrapping or reconnecting.
    case connecting
    /// Disconnected or failed; the last-known spaces stay listed.
    case offline
}

/// The host management the Spaces tab drives (M1e) and the Hosts area implements over `HostStore` and `HostSessions`.
/// The Spaces tab asks before removing (it closes every space and tab on the host); `removeHost` acts.
@MainActor
protocol SpacesHostActions: AnyObject {
    /// The question Spaces asks before `removeHost` (title, message, the destructive button).
    func removalConfirmation(for host: UUID) -> HostRemovalConfirmation?
    /// Removes the host from the phone after the user confirmed.
    func removeHost(_ id: UUID)
    /// The hosts in their new order (drag handles in M1e).
    func reorderHosts(_ order: [UUID])
    /// What the phone failed to save (hosts, keys, trusted host keys), for the notice Spaces shows; nil: all saved.
    var saveFailure: String? { get }
    /// The notice's Retry: writes what is unsaved again.
    func retrySave()
    /// The trusted host keys cannot be read: no host connects until the user chooses Retry or Reset.
    var knownHostsUnreadable: Bool { get }
    func retryKnownHosts()
    func resetKnownHosts()
}

extension SpacesHostActions {
    var saveFailure: String? { nil }
    func retrySave() {}
    var knownHostsUnreadable: Bool { false }
    func retryKnownHosts() {}
    func resetKnownHosts() {}
}

/// Hosts' views the Spaces tab embeds: New host (M8a; `done` gets the new host's id, or nil when cancelled) and host
/// detail (M1f, pushed from the Info button).
struct SpacesHostViews {
    var newHost: @MainActor (_ done: @escaping (UUID?) -> Void) -> AnyView
    var detail: @MainActor (UUID) -> AnyView
}

/// Records what the Spaces tab asked and applies it to the model only (previews and tests; the app's are
/// `HostSessions`); reordering reorders the model's hosts, as the store would through the next sync.
@MainActor
final class FakeSpacesHostActions: SpacesHostActions {
    private(set) var removed: [UUID] = []
    private(set) var orders: [[UUID]] = []
    weak var model: MobileTabs?

    init(model: MobileTabs? = nil) { self.model = model }

    func removalConfirmation(for host: UUID) -> HostRemovalConfirmation? {
        guard let name = model?.workspace(host)?.host.name else { return nil }
        return HostRemovalConfirmation(title: "Remove \(name)?", message: HostSessions.removalMessage, button: "Remove host")
    }

    func removeHost(_ id: UUID) {
        removed.append(id)
        model?.dropHost(id)
    }

    func reorderHosts(_ order: [UUID]) {
        orders.append(order)
        model?.applyHostOrder(order)
    }
}

/// One host section of the tree (M2b): the host, its spaces in the phone's order, what is unread inside (the count a
/// collapsed section shows), and whether it is collapsed.
struct SpacesSection: Identifiable {
    let host: TabsHost
    let spaces: [SpacesSpaceRow]
    let unread: Int
    let collapsed: Bool
    var id: UUID { host.id }

    /// Whether the section shows New space below the host: a connected host whose spaces are known to be none (live:
    /// not the cache's, not a multiplexer switch still on its way), expanded, unfiltered and outside edit mode.
    func offersNewSpace(editing: Bool, filter: TabsQuery.Filter) -> Bool {
        spaces.isEmpty && !host.stale && !collapsed && !editing && filter == .all && host.sameMachine == nil
    }
}

/// One space row of the tree: the tabs that need you (Mail's unread count) and the amber dot when something works.
struct SpacesSpaceRow: Identifiable {
    let space: MobileSpace
    let unread: Int
    let working: Bool
    let id: SpaceRef
}
