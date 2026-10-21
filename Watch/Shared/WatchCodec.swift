import Foundation

/// How protocol values travel. WatchConnectivity carries property-list dictionaries; every value here goes as one
/// `Data` blob under `WatchCodec.key`, so the dictionary never needs plist-compatible types (no optionals, enums with
/// payloads or nested Codable), and the same bytes serve the application context, a message and its reply.
///
/// The blob is a binary property list (`PropertyListEncoder`), not JSON: the snapshot repeats the same strings in every
/// row (host ids, keys, space names, folders, field names), which a binary plist stores once. Measured on the 5 hosts ×
/// 6 conversations sample (`WatchFixtures.crowded`, every text at its longest): 15.0 KB as a binary plist, 28.5 KB as
/// JSON. Dates stay native. `plutil -p` reads a captured blob.
enum WatchCodec {
    /// The one key of every WatchConnectivity dictionary (application context, message, reply).
    static let key = "dispatch.watch"

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }

    /// The WatchConnectivity dictionary carrying `value`.
    static func message<T: Encodable>(_ value: T) throws -> [String: Any] { [key: try encode(value)] }

    /// The value a WatchConnectivity dictionary carries; nil when it carries none (another sender's, an empty context).
    static func value<T: Decodable>(_ type: T.Type, in message: [String: Any]) throws -> T? {
        guard let data = message[key] as? Data else { return nil }
        return try decode(type, from: data)
    }

    // MARK: Fitting under the limits

    /// The snapshot as the phone sends it: texts clipped (`WatchLimits`), then, while the encoding exceeds `budget`, rows
    /// left out a tenth at a time, least useful on a wrist first: terminal tabs, then idle conversations and their tabs,
    /// then anything that does not need the user, oldest first in each; `truncated` set.
    static func fit(_ snapshot: WatchSnapshot, budget: Int = WatchLimits.snapshotBytes) -> WatchSnapshot {
        var fitted = snapshot
        for index in fitted.hosts.indices {
            fitted.hosts[index].problem = fitted.hosts[index].problem.map { WatchText.clip($0, to: WatchLimits.line) }
        }
        for index in fitted.conversations.indices {
            fitted.conversations[index].preview = fitted.conversations[index].preview.map(WatchText.preview)
            fitted.conversations[index].attention = fitted.conversations[index].attention.map { WatchText.clip($0, to: WatchLimits.preview) }
            fitted.conversations[index].name = WatchText.clip(fitted.conversations[index].name, to: WatchLimits.line)
        }
        for index in fitted.tabs.indices {
            fitted.tabs[index].status = fitted.tabs[index].status.map { WatchText.clip($0, to: WatchLimits.line) }
            fitted.tabs[index].name = WatchText.clip(fitted.tabs[index].name, to: WatchLimits.line)
        }
        while size(fitted) > budget {
            let kept = Set(fitted.conversations.map(\.key))
            // The tiers, least useful first; each round drops from the first that has any.
            let tabs: [(WatchTab) -> Bool] = [
                { !$0.chat && $0.urgency == nil },
                { $0.urgency == nil && !($0.conversationKey.map(kept.contains) ?? false) },
                { $0.urgency != .needsYou },
                { _ in true },
            ]
            let conversations: [(WatchConversation) -> Bool] = [
                { _ in false },
                { $0.dot == nil && !$0.needsYou },
                { !$0.needsYou },
                { _ in true },
            ]
            var dropped = false
            for tier in tabs.indices {
                let tabCandidates = fitted.tabs.indices.filter { tabs[tier](fitted.tabs[$0]) }
                let conversationCandidates = fitted.conversations.indices.filter { conversations[tier](fitted.conversations[$0]) }
                if !conversationCandidates.isEmpty {
                    drop(&fitted.conversations, among: conversationCandidates) { $0.lastActivity }
                    dropped = true
                }
                if !tabCandidates.isEmpty {
                    drop(&fitted.tabs, among: tabCandidates) { $0.activity }
                    dropped = true
                }
                if dropped { break }
            }
            if !dropped {
                guard !fitted.spaces.isEmpty else { break }
                fitted.spaces.removeLast(max(1, fitted.spaces.count / 10))
            }
            fitted.truncated = true
        }
        return fitted
    }

    /// The page as the phone replies it: texts clipped, then the oldest items left out while the encoding exceeds
    /// `budget` (`earlier` set).
    static func fit(_ thread: WatchThread, budget: Int = WatchLimits.replyBytes) -> WatchThread {
        var fitted = thread
        for index in fitted.items.indices {
            let item = fitted.items[index]
            fitted.items[index].text = WatchText.clip(item.text, to: item.kind == .tool ? WatchLimits.line : WatchLimits.itemText)
            fitted.items[index].detail = item.detail.map { WatchText.clip($0, to: WatchLimits.line) }
        }
        for index in fitted.approvals.indices {
            fitted.approvals[index].detail = fitted.approvals[index].detail.map { WatchText.clip($0, to: WatchLimits.detail) }
        }
        for index in fitted.queue.indices {
            fitted.queue[index].text = WatchText.clip(fitted.queue[index].text, to: WatchLimits.line)
        }
        while size(fitted) > budget, !fitted.items.isEmpty {
            fitted.items.removeFirst(max(1, fitted.items.count / 10))
            fitted.earlier = true
        }
        return fitted
    }

    /// Encoded bytes (0 when it does not encode).
    static func size<T: Encodable>(_ value: T) -> Int { (try? encode(value).count) ?? 0 }

    /// Leaves out the oldest tenth (at least one) of `list`'s entries at `candidates`.
    private static func drop<T>(_ list: inout [T], among candidates: [Int], time: (T) -> Date?) {
        let oldest = candidates.sorted { (time(list[$0]) ?? .distantPast) < (time(list[$1]) ?? .distantPast) }
        let gone = Set(oldest.prefix(max(1, list.count / 10)))
        list = list.enumerated().filter { !gone.contains($0.offset) }.map(\.element)
    }
}

/// Text as the watch shows it. The phone flattens and clips before sending (`WatchCodec.fit`), so the watch never parses
/// Markdown or holds more than its screen can show.
enum WatchText {
    /// At most `limit` characters, ending with "…" when cut.
    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 0 else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// An Agents preview: flattened, on one line (whitespace collapsed, as `ChatConversationSummary.preview`), clipped to
    /// `WatchLimits.preview`.
    static func preview(_ text: String) -> String {
        clip(plain(text).split(whereSeparator: \.isWhitespace).joined(separator: " "), to: WatchLimits.preview)
    }

    /// Markdown as plain text for a small screen: fences, heading and quote marks, emphasis and inline code marks go;
    /// links keep their text; list items get a bullet; a table's rows become "a · b" lines. Paragraph breaks stay.
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            // Table rules ("|---|:--:|") and thematic breaks ("---", "***").
            if !line.isEmpty, line.allSatisfy({ "|-:+ *_".contains($0) }), line.contains(where: { "-*_".contains($0) }) { continue }
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let match = line.firstMatch(of: #/^#{1,6}\s+/#) { line = String(line[match.range.upperBound...]) }
            if let match = line.firstMatch(of: #/^[-*+]\s+(\[[ xX]\]\s+)?/#) { line = "• " + line[match.range.upperBound...] }
            if line.hasPrefix("|"), line.hasSuffix("|") {
                line = line.dropFirst().dropLast().split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
            }
            line = line.replacing(#/!?\[([^\]]*)\]\([^)]*\)/#) { String($0.output.1) }
            line = line.replacing("**", with: "").replacing("__", with: "").replacing("`", with: "")
            // Single-star emphasis ("*word*"), not a multiplication or a glob ("a * b", "*.swift").
            line = line.replacing(#/(^|[^\w*])\*([^*\s](?:[^*]*[^*\s])?)\*(?![\w*])/#) { $0.output.1 + $0.output.2 }
            lines.append(line)
        }
        // At most one empty line between paragraphs, none at the ends.
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }
}

/// The phone's agent notifications (`RefreshNotification`, Mobile/Resilience/BackgroundRefresh.swift), which iOS shows on
/// the watch when the phone is locked and the watch is worn. Their `userInfo` names the conversation with these keys
/// (`RefreshNotification.hostKey`, `nodeKey`), so a tap on the watch opens the same thread the phone would.
enum WatchNotification {
    static let hostKey = "host"
    static let nodeKey = "node"
    /// `RefreshNotification.categoryIdentifier`: the watch's notification scene registers for it.
    static let category = "agent"

    static func key(_ userInfo: [AnyHashable: Any]) -> WatchConversationKey? {
        guard let host = userInfo[hostKey] as? String, UUID(uuidString: host) != nil,
              let node = userInfo[nodeKey] as? String, !node.isEmpty else { return nil }
        return WatchConversationKey(host: host, node: node)
    }
}

/// `WatchHost.tint`'s `#RRGGBB` both ways.
enum WatchTint {
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Components in 0...1; nil for anything but `#RRGGBB`.
    static func components(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
}
