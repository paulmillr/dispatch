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

/// Hosts' sheets the Spaces tab presents: New host (M8a; `done` gets the new host's id, or nil when cancelled) and Edit
/// host (Files' Change integration…). A host's own screen is the stats sheet (`hostStatsSheet`).
struct SpacesHostViews {
    var newHost: @MainActor (_ done: @escaping (UUID?) -> Void) -> AnyView
    /// Edit host (`HostSessions.editHostSheet`).
    var edit: @MainActor (UUID) -> AnyView
    /// The switcher's host row (P3): "34% cpu · 34% mem · 18 ms" from the host's stats, nil before any.
    var statsLine: @MainActor (UUID) -> String? = { _ in nil }
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

/// One host section of the tree (P1): the host, its spaces in the phone's order, what is unread inside (the count a
/// folded section shows), whether it is folded, and how much of its work is detached (the Detached row).
struct SpacesSection: Identifiable {
    let host: TabsHost
    let spaces: [SpacesSpaceRow]
    let unread: Int
    let collapsed: Bool
    var detached = 0
    var id: UUID { host.id }

    /// Not connected nor on its way: the OFFLINE group's (W0).
    var offline: Bool { host.state == .offline }

    /// A folded host's note: "2 spaces · 1" (the spaces, then what is unread in them).
    var foldedNote: String {
        let count = spaces.count == 1 ? "1 space" : "\(spaces.count) spaces"
        return unread > 0 ? "\(count) · \(unread)" : count
    }

    /// Whether the section shows New space below the host: a connected host whose spaces are known to be none (live:
    /// not the cache's, not a multiplexer switch still on its way), expanded, unfiltered and outside edit mode.
    func offersNewSpace(editing: Bool, filter: TabsQuery.Filter) -> Bool {
        spaces.isEmpty && !host.stale && !collapsed && !editing && filter == .all && host.sameMachine == nil
    }
}

/// Edit's list (M1e): every host's header and then its spaces, one list so a handle can be dropped anywhere. A list
/// moves rows only within one `ForEach`, so with a section per host a drop past a host's last space (the gap under it
/// is the next host's) went back; here a space dropped outside its host goes to that host's nearer end, and a host's
/// header, the list's handle too, takes its spaces to where it is dropped.
enum SpacesEditRow: Identifiable {
    case host(SpacesSection)
    /// `first` and `last` in its host: the card's rounded ends.
    case space(SpacesSpaceRow, host: UUID, first: Bool, last: Bool)

    var id: String {
        switch self {
        case .host(let section): "host:" + section.id.uuidString
        case .space(let row, let host, _, _): "space:" + host.uuidString + ":" + row.id.key
        }
    }

    /// The rows for `sections`: each header, then its spaces unless folded.
    static func rows(_ sections: [SpacesSection]) -> [SpacesEditRow] {
        sections.flatMap { section -> [SpacesEditRow] in
            let spaces = section.collapsed ? [] : section.spaces
            return [.host(section)] + spaces.enumerated().map { index, row in
                .space(row, host: section.host.id, first: index == 0, last: index == spaces.count - 1)
            }
        }
    }

    enum Move: Equatable {
        /// `MobileTabs.moveSpaces`: the space's host, its shown spaces' keys, and the offsets among them.
        case spaces(host: UUID, visible: [String], from: Int, to: Int)
        /// `MobileTabs.moveHost`: the host before the one it now precedes, nil for last.
        case host(UUID, before: UUID?)
    }

    /// The move `onMove` reports (offsets into `rows`): a space's within its host, a destination outside the host
    /// clamped to its nearer end; a header's among the hosts, where it lands among the other headers. Nil for several
    /// rows or no change of order.
    static func move(_ rows: [SpacesEditRow], from source: IndexSet, to destination: Int) -> Move? {
        guard source.count == 1, let index = source.first, rows.indices.contains(index) else { return nil }
        if case .host(let section) = rows[index] {
            var moved = rows
            moved.move(fromOffsets: source, toOffset: destination)
            let hosts = moved.compactMap { if case .host(let section) = $0 { section.id } else { nil } }
            guard hosts != rows.compactMap({ if case .host(let section) = $0 { section.id } else { nil } }),
                  let at = hosts.firstIndex(of: section.id) else { return nil }
            return .host(section.id, before: at + 1 < hosts.count ? hosts[at + 1] : nil)
        }
        guard case .space(_, let host, _, _) = rows[index] else { return nil }
        let block = rows.indices.filter { if case .space(_, host, _, _) = rows[$0] { true } else { false } }
        guard let start = block.first, let end = block.last else { return nil }
        let keys = block.compactMap { if case .space(let row, _, _, _) = rows[$0] { row.id.key } else { nil } }
        let to = min(max(destination, start), end + 1) - start
        return .spaces(host: host, visible: keys, from: index - start, to: to)
    }
}

/// One space row of the tree: the tabs that need you (Mail's unread count) and the amber dot when something works.
struct SpacesSpaceRow: Identifiable {
    let space: MobileSpace
    let unread: Int
    let working: Bool
    let id: SpaceRef
}
