import Foundation

/// A complete snapshot of one patch, including snapshots received before execution.
/// Item identity is shared with hooks and durable Codex history.
struct ChatPatch: Equatable, Sendable {
    enum State: String, Sendable { case generating, applying, completed, failed, declined, interrupted }
    var documents: [ToolDocument]
    var state: State

    private static func contentDiff(_ content: String, adding: Bool) -> String {
        var lines = content.components(separatedBy: "\n")
        if content.isEmpty { lines = [] }
        else if content.hasSuffix("\n") { lines.removeLast() }
        let range = adding ? "-0,0 +1,\(lines.count)" : "-1,\(lines.count) +0,0"
        return "@@ \(range) @@\n" + lines.map { (adding ? "+" : "-") + $0 }.joined(separator: "\n")
    }
    static func item(id: String, changes: Any?, state: State, output: String = "") -> ChatItem? {
        var documents: [ToolDocument] = []
        if let changes = changes as? [[String: Any]] {
            for change in changes {
                guard let path = change["path"] as? String, let diff = change["diff"] as? String else { return nil }
                let kind = change["kind"] as? [String: Any]
                let type = kind?["type"] as? String
                let rendered = type == "add" || type == "delete" ? contentDiff(diff, adding: type == "add") : diff
                documents.append(ToolDocument(path: kind?["movePath"] as? String ?? path, diff: rendered))
            }
        } else if let changes = changes as? [String: [String: Any]] {
            for path in changes.keys.sorted() {
                guard let change = changes[path], let type = change["type"] as? String else { return nil }
                let diff: String
                switch type {
                case "update":
                    guard let value = change["unified_diff"] as? String else { return nil }; diff = value
                case "add", "delete":
                    guard let content = change["content"] as? String else { return nil }
                    diff = contentDiff(content, adding: type == "add")
                default: return nil
                }
                documents.append(ToolDocument(path: change["move_path"] as? String ?? path, diff: diff))
            }
        } else { return nil }
        var item = ChatItem(id: "tool-" + id, kind: .tool, text: "", title: "apply_patch", output: output,
                            completed: [.completed, .failed, .declined].contains(state),
                            exitCode: [.failed, .declined].contains(state) ? 1 : nil)
        item.patch = ChatPatch(documents: documents, state: state)
        return item
    }
}

extension ChatPatch {
    /// Collapse a literal patch-only wrapper and its adjacent execution snapshot
    /// for display. Keep both underlying records for later updates/history replay.
    static func isPatchOperation(_ item: ChatItem) -> Bool {
        item.kind == .tool && (item.patch != nil || ["Edit", "MultiEdit", "Write"].contains(item.title)
            || ["apply_patch", "patch"].contains(ToolOrchestration.normalizedName(item.title)))
    }
    static func duplicates(wrapper: ChatItem, patch: ChatItem) -> Bool {
        guard wrapper.kind == .tool, wrapper.patch == nil, isPatchOperation(patch),
              ["exec", "js", "javascript"].contains(ToolOrchestration.normalizedName(wrapper.title)),
              wrapper.text.utf8.count <= 131_072 else { return false }
        let object = ToolPresentation.json(wrapper.text) as? [String: Any]
        let code = object?["code"] as? String ?? wrapper.text
        // Only a single literal call, optionally awaited and printed. A wrapper
        // with other commands or computed arguments retains its own Tools row.
        let pattern = #"^\s*(?:text\s*\(\s*)?(?:await\s+)?tools\.apply_patch\s*\(\s*("(?:[^"\\]|\\.)*")\s*\)\s*\)?\s*;?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let range = Range(match.range(at: 1), in: code),
              let input = ToolPresentation.json(String(code[range])) as? String else { return false }
        return sameEdits(request: ChatItem(id: "request", kind: .tool, text: input, title: "apply_patch"), patch: patch)
    }

    static func duplicatedRequests(wrapper: ChatItem, patch: ChatItem) -> Set<String> {
        guard wrapper.kind == .tool, wrapper.patch == nil, isPatchOperation(patch),
              ["exec", "js", "javascript"].contains(ToolOrchestration.normalizedName(wrapper.title)) else { return [] }
        let object = ToolPresentation.json(wrapper.text) as? [String: Any]
        let requests = ToolOrchestration.requests(in: object?["code"] as? String ?? wrapper.text)
        // Multiple identical requests can represent distinct executions. Keep
        // those visible rather than guessing which execution this patch belongs to.
        let matches = requests.filter { isPatchOperation($0) && sameEdits(request: $0, patch: patch) }
        return matches.count == 1 ? Set(matches.map(\.id)) : []
    }

    static func sameEdits(request: ChatItem, patch: ChatItem) -> Bool {
        let requested = ToolDocument.parse(request)
        let actual = patch.patch?.documents ?? ToolDocument.parse(patch)
        guard !requested.isEmpty, requested.count == actual.count else { return false }
        func edits(_ document: ToolDocument) -> [String] {
            document.diff.components(separatedBy: "\n").filter { $0.hasPrefix("+") || $0.hasPrefix("-") }
        }
        return zip(requested.sorted { $0.path < $1.path }, actual.sorted { $0.path < $1.path }).allSatisfy {
            $0.path == $1.path && !edits($0).isEmpty && edits($0) == edits($1)
        }
    }
}
