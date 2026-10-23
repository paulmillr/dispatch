import SwiftUI

/// A host's last update, as Spaces and Agents show it under pull to refresh: its connection and when its helper last
/// answered (`HostSession.updated`).
struct HostFreshness: Identifiable, Equatable {
    let id: UUID
    var name: String
    var tint: Color
    var state: SpacesHostState
    var updated: Date?

    /// "Updated just now", "Updated 12m ago"; a host that is not connected says so first ("Offline · updated 2h ago").
    static func label(state: SpacesHostState, updated: Date?, now: Date) -> String {
        let when = TabsTime.ago(updated, now: now).map { $0 == "now" ? "just now" : $0 == "Yesterday" ? "yesterday" : $0 }
        switch state {
        case .connected: return when.map { "Updated \($0)" } ?? "Connected"
        case .connecting: return when.map { "Connecting · updated \($0)" } ?? "Connecting"
        case .offline: return when.map { "Offline · updated \($0)" } ?? "Offline"
        }
    }

    /// One line for every host: "Updated just now" for those that answered within the minute, then the others, two by
    /// name ("Updated just now · vps offline", "vps offline · studio updated 12m ago", "+2 more"). Nil without hosts.
    static func summary(_ hosts: [HostFreshness], now: Date) -> String? {
        guard !hosts.isEmpty else { return nil }
        let behind = hosts.compactMap { host -> String? in
            switch host.state {
            case .offline: return host.name + " offline"
            case .connecting: return host.name + " connecting"
            case .connected:
                guard let updated = host.updated, now.timeIntervalSince(updated) >= 60 else { return nil }
                return TabsTime.ago(updated, now: now).map { host.name + " updated " + ($0 == "Yesterday" ? "yesterday" : $0) }
            }
        }
        let fresh = behind.count < hosts.count ? ["Updated just now"] : []
        let named = fresh + behind.prefix(2) + (behind.count > 2 ? ["+\(behind.count - 2) more"] : [])
        return named.joined(separator: " · ")
    }
}

/// The shared stack's subtitle under Spaces' flat list and Agents (Mail's "Updated just now"): every host's last
/// update in one line. `hosts` is read in this modifier's body, not the root's, so a host's ping re-evaluates only it;
/// the times move on with the minute. Nil `hosts` shows none (an empty subtitle, so the stack keeps its identity).
struct HostsSubtitle: ViewModifier {
    let hosts: (@MainActor () -> [HostFreshness])?

    func body(content: Content) -> some View {
        TimelineView(.everyMinute) { context in
            content.navigationSubtitle(hosts.flatMap { HostFreshness.summary($0(), now: context.date) } ?? "")
        }
    }
}

extension View {
    /// Pull to refresh when there is something to refresh: `action` nil (the Debug samples) leaves the list as it is.
    @ViewBuilder func hostsRefreshable(_ action: (@MainActor () async -> Void)?) -> some View {
        if let action { refreshable { await action() } } else { self }
    }
}
