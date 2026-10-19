import SwiftUI

/// The removal question's copy.
struct HostRemovalConfirmation: Equatable {
    let title: String
    let message: String
    let button: String
}

/// What Hosts offers the Spaces tab (docs/ios.md, Areas and seams): removing a host after the user confirms
/// (M1e), reordering over `HostStore`, and the host screens Spaces embeds through `SpacesHostViews` (M1f pushed, M8a as
/// a sheet).
extension HostSessions: SpacesHostActions {
    static let removalMessage = "Its spaces and tabs close on this iPhone, and Dispatch forgets its password and host key. Nothing changes on the host: its tmux or herdr sessions and agents keep running."

    func removalConfirmation(for host: UUID) -> HostRemovalConfirmation? {
        store.record(host).map {
            HostRemovalConfirmation(title: "Remove \($0.name)?", message: Self.removalMessage, button: "Remove host")
        }
    }

    func removeHost(_ host: UUID) { remove(host) }

    /// One line per store whose last save failed, naming what stays unsaved (kept in memory until a save succeeds).
    var saveFailure: String? {
        var lines: [String] = []
        if let error = store.saveError {
            let names = store.hosts.filter { store.unsaved.contains($0.id) }.map(\.name)
            lines.append("\(Self.list(names, or: "Your hosts")) \(names.count == 1 ? "isn't" : "aren't") saved on this iPhone: \(error)")
        }
        if let error = keys.saveError {
            let names = keys.keys.filter { keys.unsaved.contains($0.id) }.map { "the key “\($0.label)”" }
            lines.append("\(Self.list(names, or: "Your keys").capitalizedFirst) \(names.count == 1 ? "isn't" : "aren't") saved on this iPhone: \(error)")
        }
        if let error = knownHosts.saveError {
            lines.append("Trusted host keys aren't saved on this iPhone: \(error)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func retrySave() {
        if store.saveError != nil { store.retrySave() }
        if keys.saveError != nil { keys.retrySave() }
        if knownHosts.saveError != nil { knownHosts.retrySave() }
    }

    var knownHostsUnreadable: Bool { knownHosts.unreadable }

    private static func list(_ names: [String], or fallback: String) -> String {
        switch names.count {
        case 0: fallback
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// Drag reordering in M1e: the store takes the new order.
    func reorderHosts(_ order: [UUID]) {
        let current = store.hosts.map(\.id)
        guard order != current else { return }
        for (target, id) in order.enumerated() {
            guard let from = store.hosts.firstIndex(where: { $0.id == id }), from != target else { continue }
            move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
        }
    }

    /// Host detail (M1f) to push, with Tabs' rows for its Spaces section.
    func hostDetail<Rows: View>(_ host: UUID, @ViewBuilder spaces: @escaping (HostSession) -> Rows) -> AnyView {
        AnyView(HostDetail(hostID: host, spaces: spaces).environment(self))
    }

    /// New host (M8a) to present as a sheet; `created` gets the saved host (M7a selects it).
    func newHostSheet(created: @escaping (UUID) -> Void) -> AnyView {
        AnyView(NewHostSheet(created: created).environment(self).tint(.dispatchPink))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
