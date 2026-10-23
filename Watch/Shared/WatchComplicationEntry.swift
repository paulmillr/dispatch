import Foundation

/// What the complications show (K7, docs/watch.md, Complications): how many conversations need you, and the first of
/// them (what it asks, its host), with the thread a tap opens. The watch app writes it to the App Group container on
/// every snapshot and every entry the phone transfers for the complication (`WatchComplicationWriter`); the widget
/// extension (`DispatchWatchWidgets`) reads it. In `Watch/Shared`: the phone builds the same entry from its snapshot
/// for `transferCurrentComplicationUserInfo`.
struct WatchComplicationEntry: Codable, Equatable, Sendable {
    /// Conversations waiting for the user (the Agents badge's count).
    var needsYou: Int
    /// The first needs-you row's line ("Allow cargo test --workspace?", at most `WatchLimits.preview` characters), else its
    /// title.
    var text: String?
    /// Its host's name.
    var host: String?
    /// Its agent ("claude"), for the glyph.
    var agent: String?
    /// Its conversation: what a tap opens.
    var key: WatchConversationKey?
    /// The snapshot's time: the rectangular face says how old it is once that is more than a few minutes.
    var updated: Date

    init(needsYou: Int, text: String? = nil, host: String? = nil, agent: String? = nil, key: WatchConversationKey? = nil,
         updated: Date) {
        self.needsYou = needsYou
        self.text = text
        self.host = host
        self.agent = agent
        self.key = key
        self.updated = updated
    }

    /// The gallery's and the placeholder's entry (fictional).
    static let sample = WatchComplicationEntry(needsYou: 2, text: "Allow cargo test --workspace?", host: "mba2", agent: "codex",
                                               updated: .distantPast)

    /// An entry older than this is shown with its time ("As of 2:02 PM"): the phone has not been heard from since.
    static let staleAfter: TimeInterval = 5 * 60

    /// Nothing waits (the grey "Nothing waiting").
    static func empty(at date: Date) -> WatchComplicationEntry { WatchComplicationEntry(needsYou: 0, updated: date) }

    /// The entry a snapshot gives: its rows that need you, newest first as Agents sorts them; the count is the phone's
    /// when it says more (muted rows count there too).
    init(_ snapshot: WatchSnapshot) {
        let names = Dictionary(snapshot.hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let waiting = snapshot.conversations.filter(\.needsYou).sorted { a, b in
            (a.lastActivity ?? .distantPast, names[a.host] ?? "", a.node) > (b.lastActivity ?? .distantPast, names[b.host] ?? "", b.node)
        }
        let first = waiting.first
        func text(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
        self.init(needsYou: max(snapshot.phone.needsYou, waiting.count),
                  text: first.map { WatchText.preview(text($0.waitingText) ?? text($0.attention) ?? $0.displayTitle) },
                  host: first.flatMap { names[$0.host] }, agent: first?.agent, key: first?.key, updated: snapshot.generated)
    }

    /// The same faces as `other`, whatever the times: what the phone transfers and the app writes only on a change.
    func shows(_ other: WatchComplicationEntry?) -> Bool {
        guard var other else { return false }
        other.updated = updated
        return other == self
    }

    /// The WatchConnectivity user info carrying it (`transferCurrentComplicationUserInfo`).
    static let key = "dispatch.watch.complication"

    func userInfo() throws -> [String: Any] { [Self.key: try WatchCodec.encode(self)] }

    static func value(in userInfo: [String: Any]) -> WatchComplicationEntry? {
        (userInfo[key] as? Data).flatMap { try? WatchCodec.decode(WatchComplicationEntry.self, from: $0) }
    }

    /// The rectangular widget's second line: "Allow cargo test? · mba2".
    var line: String? {
        guard needsYou > 0 else { return nil }
        let parts = [text, host].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var title: String { needsYou > 0 ? "Needs you · \(needsYou)" : "Nothing waiting" }

    // MARK: Taps

    static let scheme = "dispatch-watch"

    /// `dispatch-watch://open?host=<id>&node=<key>`, or `dispatch-watch://agents` when nothing waits.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        if let key {
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "host", value: key.host), URLQueryItem(name: "node", value: key.node)]
        } else {
            components.host = "agents"
        }
        return components.url!
    }

    /// The conversation a complication's URL names.
    static func key(_ url: URL) -> WatchConversationKey? {
        guard url.scheme == scheme, url.host == "open",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, UUID(uuidString: host) != nil,
              let node = items.first(where: { $0.name == "node" })?.value, !node.isEmpty else { return nil }
        return WatchConversationKey(host: host, node: node)
    }
}
