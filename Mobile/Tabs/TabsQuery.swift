import Foundation
import SwiftUI

/// M2a's sort/filter menu: Sort by (Activity, Name, Host) and Show (All, Chats, Terminals, Needs you). The same menu
/// applies to the spaces level of the tree (M2b) and to a space's tabs (M2c).
struct TabsQuery: Equatable, Codable {
    enum Sort: String, CaseIterable, Codable, Identifiable {
        case activity, name, host
        var id: Self { self }
        var title: String {
            switch self { case .activity: "Activity"; case .name: "Name"; case .host: "Host" }
        }
    }

    enum Filter: String, CaseIterable, Codable, Identifiable {
        case all, chats, terminals, needsYou
        var id: Self { self }
        var title: String {
            switch self { case .all: "All"; case .chats: "Chats"; case .terminals: "Terminals"; case .needsYou: "Needs you" }
        }
    }

    var sort = Sort.activity
    var filter = Filter.all

    init(sort: Sort = .activity, filter: Filter = .all) {
        self.sort = sort
        self.filter = filter
    }

    /// A missing or unknown value (an older or newer build's) takes its default; the other stays.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sort = values.lenient(Sort.self, forKey: .sort, default: .activity)
        filter = values.lenient(Filter.self, forKey: .filter, default: .all)
    }

    /// The pill tints when a filter is active (M2a); a sort alone does not count.
    var filtering: Bool { filter != .all }
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
    let id: TabRef

    @MainActor init(tab: MobileTab, space: MobileSpace?, host: TabsHost, urgency: TabUrgency?, activity: Date? = nil) {
        self.tab = tab
        self.space = space
        self.host = host
        self.urgency = urgency
        self.activity = activity ?? tab.activity
        id = tab.ref
    }

    @MainActor func matches(_ filter: TabsQuery.Filter) -> Bool {
        switch filter {
        case .all: true
        case .chats: tab.isChat
        case .terminals: !tab.isChat
        case .needsYou: urgency == .needsYou
        }
    }
}

@MainActor
enum TabsOrdering {
    /// Most recent first; tabs with no change seen yet go last, by name. Name and Host sort with Finder's comparison;
    /// ties fall back to activity, then the tab key, so the order never flickers between snapshots.
    static func sorted(_ entries: [TabsEntry], by sort: TabsQuery.Sort) -> [TabsEntry] {
        entries.sorted { a, b in
            switch sort {
            case .activity:
                if let order = activity(a.activity, b.activity) { return order }
                if let order = text(a.tab.name, b.tab.name) { return order }
            case .name:
                if let order = text(a.tab.name, b.tab.name) { return order }
                if let order = text(a.space?.name ?? "", b.space?.name ?? "") { return order }
                if let order = activity(a.activity, b.activity) { return order }
            case .host:
                if let order = text(a.host.name, b.host.name) { return order }
                if a.host.id != b.host.id { return a.host.id.uuidString < b.host.id.uuidString }
                if let order = activity(a.activity, b.activity) { return order }
                if let order = text(a.tab.name, b.tab.name) { return order }
            }
            if a.host.id != b.host.id { return a.host.id.uuidString < b.host.id.uuidString }
            return a.tab.ref.key < b.tab.ref.key
        }
    }

    static func query(_ entries: [TabsEntry], _ query: TabsQuery) -> [TabsEntry] {
        sorted(entries.filter { $0.matches(query.filter) }, by: query.sort)
    }

    /// Spaces (M2b) by the same sort: a space's activity is its latest tab's.
    static func sorted(spaces: [(space: MobileSpace, host: TabsHost)], by sort: TabsQuery.Sort,
                       activity time: (MobileSpace) -> Date? = { $0.activity }) -> [(space: MobileSpace, host: TabsHost)] {
        spaces.sorted { a, b in
            switch sort {
            case .activity:
                if let order = activity(time(a.space), time(b.space)) { return order }
                if let order = text(a.space.name, b.space.name) { return order }
            case .name:
                if let order = text(a.space.name, b.space.name) { return order }
                if let order = text(a.host.name, b.host.name) { return order }
            case .host:
                if let order = text(a.host.name, b.host.name) { return order }
                if a.host.id != b.host.id { return a.host.id.uuidString < b.host.id.uuidString }
                if let order = activity(time(a.space), time(b.space)) { return order }
            }
            if a.host.id != b.host.id { return a.host.id.uuidString < b.host.id.uuidString }
            return a.space.ref.key < b.space.ref.key
        }
    }

    private static func activity(_ a: Date?, _ b: Date?) -> Bool? {
        switch (a, b) {
        case let (a?, b?): a == b ? nil : a > b
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): nil
        }
    }

    private static func text(_ a: String, _ b: String) -> Bool? {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: nil
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
