import Foundation

struct ToolDocument: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    var diff: String
    var workingDirectory: String?
    /// Shorten labels without changing the path used to load source (including on SSH hosts).
    func displayPath(in directory: String) -> String {
        guard path.hasPrefix("/"), directory.hasPrefix("/") else { return path }
        let target = URL(fileURLWithPath: path).standardized.pathComponents
        let base = URL(fileURLWithPath: directory).standardized.pathComponents
        let shared = zip(target, base).prefix { $0 == $1 }.count
        let relative = Array(repeating: "..", count: base.count - shared) + target.dropFirst(shared)
        return relative.isEmpty ? "." : relative.joined(separator: "/")
    }

    func stepLabel(in directory: String) -> String {
        let relative = displayPath(in: directory)
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return relative }
        var components: [String] = []
        for part in relative.split(separator: "/").map(String.init) where part != "." {
            if part == "..", let last = components.last, last != ".." { components.removeLast() }
            else { components.append(part) }
        }
        guard components.first != ".." else { return relative }
        return components.last ?? relative
    }

    static func parse(_ item: ChatItem) -> [ToolDocument] {
        var input = item.text
        var file: String?
        var workingDirectory: String?
        if let data = input.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if ["Edit", "MultiEdit", "Write"].contains(item.title) {
                guard let path = object["file_path"] as? String, !path.isEmpty else { return [] }
                let edits: [[String: Any]]
                if item.title == "MultiEdit" {
                    guard let values = object["edits"] as? [[String: Any]], !values.isEmpty else { return [] }
                    edits = values
                } else { edits = [object] }
                var hunks: [String] = []
                for edit in edits {
                    let old: String, new: String, heading: String
                    if item.title == "Write" {
                        guard let content = edit["content"] as? String else { return [] }
                        old = ""; new = content
                        heading = content.isEmpty ? "Written content (empty)" : "Written content"
                    } else {
                        guard let before = edit["old_string"] as? String, let after = edit["new_string"] as? String else { return [] }
                        old = before; new = after
                        heading = edit["replace_all"] as? Bool == true ? "Replace all occurrences" : "Replacement"
                    }
                    var lines = ["@@ \(heading) @@"]
                    for (prefix, content) in [("-", old), ("+", new)] where !content.isEmpty {
                        var parts = content.components(separatedBy: "\n")
                        if content.hasSuffix("\n") { parts.removeLast() }
                        lines += parts.map { prefix + $0 }
                    }
                    hunks.append(lines.joined(separator: "\n"))
                }
                return [ToolDocument(path: path, diff: hunks.joined(separator: "\n"))]
            }
            input = (object["patch"] as? String) ?? (object["input"] as? String) ?? (object["cmd"] as? String) ?? (object["command"] as? String) ?? input
            file = (object["file_path"] as? String) ?? (object["path"] as? String) ?? (object["file_name"] as? String)
            workingDirectory = object["workdir"] as? String
        }
        var documents: [ToolDocument] = []
        var oldPath: String?
        var patchEnded = false
        var customPatch = false
        var oldRemaining = 0, newRemaining = 0
        for line in input.components(separatedBy: "\n") {
            if line == "*** End Patch" { patchEnded = true; continue }
            if patchEnded { continue }
            // Header-like text inside a hunk is file content. For example,
            // removing "-- option" produces "--- option", not a file header.
            if !documents.isEmpty && ((customPatch && !line.hasPrefix("*** ")) || oldRemaining > 0 || newRemaining > 0) {
                documents[documents.count - 1].diff += line + "\n"
                if line.hasPrefix("-") { oldRemaining = max(0, oldRemaining - 1) }
                else if line.hasPrefix("+") { newRemaining = max(0, newRemaining - 1) }
                else if line.hasPrefix(" ") {
                    oldRemaining = max(0, oldRemaining - 1); newRemaining = max(0, newRemaining - 1)
                }
                continue
            }
            if line.hasPrefix("@@ "), !documents.isEmpty {
                let fields = line.split(separator: " ")
                func count(_ field: Substring) -> Int {
                    let parts = field.dropFirst().split(separator: ",")
                    return parts.count == 2 ? (Int(parts[1]) ?? 0) : 1
                }
                if fields.count >= 4, fields[1].hasPrefix("-"), fields[2].hasPrefix("+") {
                    oldRemaining = count(fields[1]); newRemaining = count(fields[2])
                }
            }
            if line.hasPrefix("--- ") {
                let name = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
                oldPath = name.hasPrefix("a/") ? String(name.dropFirst(2)) : name
            } else if let prefix = ["*** Update File: ", "*** Add File: ", "*** Delete File: "].first(where: { line.hasPrefix($0) }) {
                customPatch = true
                documents.append(ToolDocument(path: String(line.dropFirst(prefix.count)), diff: ""))
            } else if line.hasPrefix("*** Move to: "), !documents.isEmpty {
                let previous = documents.removeLast()
                documents.append(ToolDocument(path: String(line.dropFirst("*** Move to: ".count)), diff: previous.diff))
            } else if line.hasPrefix("+++ ") {
                let name = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
                if name != "/dev/null" { documents.append(ToolDocument(path: name.hasPrefix("b/") ? String(name.dropFirst(2)) : name, diff: "")) }
                else if let oldPath, oldPath != "/dev/null" { documents.append(ToolDocument(path: oldPath, diff: "")) }
            } else if !documents.isEmpty && !line.hasPrefix("*** ") && !line.hasPrefix("--- ") && !line.hasPrefix("diff --git") {
                documents[documents.count - 1].diff += line + "\n"
            }
        }
        if documents.isEmpty && (item.output.contains("+++ ") || item.output.contains("*** Update File: ")) {
            var outputItem = item; outputItem.text = item.output; outputItem.output = ""
            documents = parse(outputItem)
        }
        if documents.isEmpty, let file { documents = [ToolDocument(path: file, diff: "")] }
        // A single operation can update the same file more than once.
        var merged: [ToolDocument] = []
        for var document in documents {
            document.workingDirectory = workingDirectory
            if let index = merged.firstIndex(where: { $0.path == document.path }) { merged[index].diff += document.diff }
            else { merged.append(document) }
        }
        return merged
    }
    /// New-file line numbers (old-file numbers for deletions). Unknown positions
    /// in partial/custom patches remain blank until a numbered hunk arrives.
    static func lineNumbers(_ lines: [String]) -> [Int?] {
        var old: Int?, new: Int?
        return lines.map { line in
            if line.hasPrefix("@@ ") {
                let fields = line.split(separator: " ")
                if fields.count >= 3 {
                    old = fields[1].dropFirst().split(separator: ",").first.flatMap { Int($0) }
                    new = fields[2].dropFirst().split(separator: ",").first.flatMap { Int($0) }
                }
                return nil
            }
            if line.hasPrefix("-") { defer { old = old.map { $0 + 1 } }; return old }
            if line.hasPrefix("+") { defer { new = new.map { $0 + 1 } }; return new }
            if line.hasPrefix(" ") {
                defer { old = old.map { $0 + 1 }; new = new.map { $0 + 1 } }; return new
            }
            return nil
        }
    }
    func source(in directory: String, endpoint: HelperWorkspace.Endpoint = .local) async throws -> String {
        let base = workingDirectory.map {
            $0.hasPrefix("/") ? $0 : URL(fileURLWithPath: directory).appendingPathComponent($0).path
        } ?? directory
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: base).appendingPathComponent(path)
        // The helper reads it on the directory's machine (UTF-8 text up to its preview limit).
        let connection = try await HelperApp.shared.connection(endpoint)
        do {
            return try await connection.request("files.text", params: ["path": url.path])
        } catch let failure as HelperFailure where failure.code == "unsupported" {
            throw SourceError.unsupported
        }
    }
    enum SourceError: LocalizedError {
        case unsupported
        var errorDescription: String? { "Source preview supports UTF-8 text files up to 2 MB." }
    }
}
