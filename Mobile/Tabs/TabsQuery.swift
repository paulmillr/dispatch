import Foundation
import SwiftUI

/// The Spaces tree's filter row (P1): All, Needs you (the hosts and spaces with an agent waiting for the user) and
/// Agents (the spaces running one). The Agents section of the tab bar is the same set by conversation; the chip is the
/// tree's view of it. No sort: hosts keep their order and spaces the phone's (`MobileTabs.orderedSpaces`).
struct TabsQuery: Equatable, Codable {
    enum Filter: String, CaseIterable, Codable, Identifiable {
        case all, needsYou, agents
        var id: Self { self }
        var title: String {
            switch self { case .all: "All"; case .needsYou: "Needs you"; case .agents: "Agents" }
        }
        /// The chip's glyph (P1).
        var symbol: String {
            switch self { case .all: "square.on.square"; case .needsYou: "exclamationmark.bubble"; case .agents: "text.bubble" }
        }
    }

    var filter = Filter.all

    init(filter: Filter = .all) {
        self.filter = filter
    }

    /// An older build's menu ("chats" is Agents now; its Terminals and sort are gone) or a newer build's unknown value
    /// takes the nearest filter, else All.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = values.lenient(String.self, forKey: .filter, default: "")
        filter = raw == "chats" ? .agents : Filter(rawValue: raw) ?? .all
    }

    private enum CodingKeys: String, CodingKey { case filter }

    /// A filter other than All is on: the chip is tinted, hosts without a match leave the tree.
    var filtering: Bool { filter != .all }
}

/// What a chat tab's agent is doing, for line two of its row (P2, P3) and the watch's tab rows: its words (the current
/// step, the approval or question it waits on, its last message) and, while it works, when its turn started, which the
/// rows count from ("Editing Sidebar.tsx · 48s", ticking) and the words never carry, so they change only with the step.
struct TabsStatus: Equatable, Sendable {
    var text: String
    /// The running turn's start, while the agent works; nil otherwise.
    var since: Date? = nil
}

/// How much a tab wants attention, from Chat's per-conversation state (`PaneUrgency`'s precedence: waiting, then
/// running, then unread). The rows draw it as Mail does: blue unread for needs you or an unseen result, amber working.
enum TabUrgency: Int, Comparable, Sendable {
    case unseen, working, needsYou
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    /// Counted as unread (the tree's counts, the back pill's number when needs you).
    var unread: Bool { self != .working }
    /// The row's gutter dot: blue unread for needs you and an unseen result, amber working.
    var rowDot: MobileRow<HostGlyph>.Dot { self == .working ? .working : .unread }
}

/// A tab with what the list needs to order and filter it, read once per row.
struct TabsEntry: Identifiable {
    let tab: MobileTab
    let space: MobileSpace?
    let host: TabsHost
    let urgency: TabUrgency?
    /// Its time (`MobileTabs.activity(of:)`); nil: the tab's own.
    let activity: Date?
    /// The name it shows (`MobileTabs.label(of:)`).
    let label: String
    let id: TabRef

    @MainActor init(tab: MobileTab, space: MobileSpace?, host: TabsHost, urgency: TabUrgency?, activity: Date? = nil,
                    label: String? = nil) {
        self.tab = tab
        self.label = label ?? tab.name
        self.space = space
        self.host = host
        self.urgency = urgency
        self.activity = activity ?? tab.activity
        id = tab.ref
    }

    @MainActor func matches(_ filter: TabsQuery.Filter) -> Bool {
        switch filter {
        case .all: true
        case .agents: tab.isChat
        // Live rows only, as the Needs you count and the app's badge count them: a host not reached now says nothing.
        case .needsYou: urgency == .needsYou && !host.stale
        }
    }
}

extension TabsTime {
    /// M7a's folder times: "now", "12m ago", "2h ago" within the day, then as the rows ("Yesterday", "Mon", a date).
    static func ago(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h ago" }
        return label(date, now: now, calendar: calendar, locale: locale)
    }
}

extension TabsTime {
    /// "48s", "3m", "1h 5m": how long a turn has run.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h \(total % 3600 / 60)m"
    }
}

/// A row's time in Spaces and Agents, as Messages writes it (M2a, M3a): "now" within a minute, the time today,
/// "Yesterday", the weekday within a week, else the short date.
enum TabsTime {
    static func label(_ date: Date?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let date else { return nil }
        if now.timeIntervalSince(date) < 60 { return "now" }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))
        }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}
