import Foundation

/// The shared parsing boundary for agent text. A client must explicitly opt in to any non-web link route.
enum ChatMarkdownPolicy {
    static func isWebLink(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
            && url.user == nil && url.password == nil
    }

    static func inline(_ text: String, allowingAdditionalLink: ((URL) -> Bool)? = nil) -> AttributedString {
        let visible = TextRendering.visible(text)
        var value = (try? AttributedString(markdown: visible,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(visible)
        let unsafe = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return isWebLink(url) || allowingAdditionalLink?(url) == true ? nil : run.range
        }
        for range in unsafe { value[range].link = nil }
        return value
    }
}

/// Whole-cache eviction keeps streamed revisions from accumulating. Oversized sources are rendered without retention.
struct ChatTextCache<Key: Hashable, Value> {
    struct Limit {
        let count: Int
        let bytes: Int
    }
    let limit: Limit
    private var values: [Key: Value] = [:]
    init(limit: Limit) { self.limit = limit }
    var count: Int { values.count }
    subscript(key: Key) -> Value? { values[key] }

    mutating func insert(_ value: Value, for key: Key, source: String) {
        guard source.utf8.count <= limit.bytes else { return }
        if values[key] == nil, values.count >= limit.count { values.removeAll(keepingCapacity: true) }
        values[key] = value
    }
}

enum ChatMarkdownCacheBounds {
    static let document = (count: 128, bytes: 64 * 1024)
    static let inline = (count: 1024, bytes: 8 * 1024)
}
