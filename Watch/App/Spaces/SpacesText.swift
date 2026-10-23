import SwiftUI

/// A tab's own screen in Spaces (`TabDetailScreen`): host plus the tab's topology key, as the phone's `TabRef`.
struct WatchTabRoute: Hashable, Sendable {
    let host: String
    let tab: String
}

/// A host's screen (`HostScreen`, K6): its `WatchHost.id`.
struct WatchHostRoute: Hashable, Sendable {
    let host: String
}

/// A space's screen (`SpaceScreen`): host plus the space's key (`SpaceRef`).
struct WatchSpaceRoute: Hashable, Sendable {
    let host: String
    let space: String
}

/// The words of Spaces' rows and headers, pure so the tests read them without a view.
@MainActor
enum SpacesText {
    /// The header's state: nil when connected (the green dot says it), "Connecting…", "Offline".
    static func state(_ host: WatchHost) -> String? {
        switch host.state {
        case .connected: nil
        case .connecting: "Connecting…"
        case .offline, .unknown: "Offline"
        }
    }

    static func stateColor(_ host: WatchHost) -> Color {
        switch host.state {
        case .connected: WatchDots.connected
        case .connecting: WatchDots.working
        case .offline, .unknown: .gray
        }
    }

    /// What a host says in place of (or above) its spaces, most pressing first: the phone's screen is needed
    /// (`WatchModel.blockedMessage`), then its problem while not connected, with when the phone last reached it. Under
    /// the "Unlock your iPhone" notice, a host blocked only by the lock says nothing more (every host would repeat it).
    static func problem(_ host: WatchHost, now: Date, notice: WatchNotice? = nil) -> (symbol: String, text: String, detail: String?)? {
        if notice == .phoneLocked, host.blocked == .phoneLocked { return nil }
        let last = host.state == .connected ? nil : host.lastConnected.map { "Last connected \(WatchTime.ago($0, now: now))" }
        if let blocked = WatchModel.blockedMessage(host) {
            return (host.blocked == .phoneLocked ? "lock.fill" : "iphone", blocked, last)
        }
        guard host.state != .connected, let problem = host.problem, !problem.isEmpty else { return nil }
        return ("exclamationmark.triangle.fill", problem, last)
    }

    /// The phone's line for a second host on the same machine (SpacesTree).
    static func sameMachine(_ other: String) -> String { "Same machine as \(other): its spaces show there." }

    static let noSpaces = "No spaces"
    static let noTabs = "No tabs"
    static let truncated = "Some rows are on your iPhone"

    /// A space's gutter dot: blue when a tab needs you or holds an unseen result, else amber while one works.
    static func dot(_ space: WatchSpace) -> WatchDot? {
        space.unread > 0 ? .unread : space.working ? .working : nil
    }

    /// A tab's gutter dot (`WatchUrgency.dot`).
    static func dot(_ tab: WatchTab) -> WatchDot? {
        switch tab.urgency {
        case nil, .unknown?: nil
        case let urgency?: urgency.dot
        }
    }

    /// The tab's line two, as the phone's row (`SpacesTabRow.line`): what its agent is doing, else the program when the
    /// name is not already it; a bare shell has none.
    static func line(_ tab: WatchTab) -> String? {
        if let status = tab.status, !status.isEmpty { return status }
        if let program = tab.program, program != tab.name { return program }
        return nil
    }

    /// The row's glyph: a speech bubble for a chat tab, the terminal for any other (`TabsKindGlyph`).
    static func symbol(_ tab: WatchTab) -> String { tab.chat ? "bubble.left.fill" : "apple.terminal" }

    /// Where a tab row leads: an agent's thread when it is bound to one, else the tab's screen.
    enum Destination: Equatable {
        case thread(WatchConversationKey)
        case tab(WatchTabRoute)
    }

    static func destination(_ tab: WatchTab) -> Destination {
        if tab.chat, let key = tab.conversationKey { return .thread(key) }
        return .tab(WatchTabRoute(host: tab.host, tab: tab.key))
    }

    /// The folder for a narrow row: "~/src/dispatch" as is; a deeper one keeps its last two components after "…/",
    /// where the name of the project is.
    static func folder(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count > 3 else { return path }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// VoiceOver's value for a space: "2 unread, Working".
    static func value(_ space: WatchSpace) -> String {
        [space.unread > 0 ? "\(space.unread) unread" : nil, space.working ? "Working" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}
