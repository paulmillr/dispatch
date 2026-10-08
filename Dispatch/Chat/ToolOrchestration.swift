import Foundation

/// Extracts literal requests for display. This is deliberately not a JavaScript
/// interpreter: expressions, computed arguments, templates, and regexes fall back
/// to raw details. It never evaluates code or claims a nested request completed.
enum ToolOrchestration {
    private struct Request { let item: ChatItem; let range: Range<Int> }
    static func requests(in source: String) -> [ChatItem] { extract(source).map(\.item) }

    /// Only standalone awaited/printed literal calls can replace a wrapper.
    /// Computed code and control flow retain the original Tools presentation.
    static func sequentialRequests(in source: String) -> [ChatItem]? {
        let parsed = extract(source)
        guard !parsed.isEmpty else { return nil }
        var chars = Array(source)
        for request in parsed.reversed() { chars.replaceSubrange(request.range, with: Array("REQUEST")) }
        let remainder = String(chars).replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\r\n]*"#, with: "", options: .regularExpression)
        let pattern = #"\A(?:\s*(?:text\s*\(\s*)?await\s+REQUEST\s*\)?\s*;?\s*)+\z"#
        guard remainder.range(of: pattern, options: .regularExpression) != nil || isPrintedBatch(remainder) else { return nil }
        return parsed.map(\.item)
    }

    private static func isPrintedBatch(_ source: String) -> Bool {
        let code = source.filter { !$0.isWhitespace }
        if let tail = code.range(of: #"(?:text\(awaitREQUEST\);?)+\z"#, options: .regularExpression), tail.lowerBound != code.startIndex,
           isPrintedBatch(String(code[..<tail.lowerBound])) { return true }
        let names = #"[A-Za-z_$][A-Za-z0-9_$]*"#
        let batch = #"awaitPromise\.(?:allSettled|all)\(\[(?:REQUEST,?)+\]\)"#
        func matches(_ pattern: String, _ value: String) -> Bool { value.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"\Atext\("# + batch + #"\);?\z"#, code) { return true }
        if matches(#"\Afor\((?:const|let)("# + names + #")of"# + batch + #"\)\{?text\(\1\);?\}?\z"#, code) { return true }
        let prefix = #"\A(?:const|let)("# + names + #")="# + batch + #";?(.*)\z"#
        guard let regex = try? NSRegularExpression(pattern: prefix),
              let match = regex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
              let nameRange = Range(match.range(at: 1), in: code), let tailRange = Range(match.range(at: 2), in: code) else { return false }
        let name = NSRegularExpression.escapedPattern(for: String(code[nameRange])), tail = String(code[tailRange])
        return matches(#"\A"# + name + #"\.forEach\(text\);?\z"#, tail)
            || matches(#"\Afor\((?:const|let)("# + names + #")of"# + name + #"\)\{?text\(\1\);?\}?\z"#, tail)
            || matches(#"\Afor\(let("# + names + #")=0;\1<"# + name + #"\.length;\1\+\+\)\{?text\(\{\1,\.\.\."# + name + #"\[\1\]\}\);?\}?\z"#, tail)
    }

    private static func extract(_ source: String) -> [Request] {
        guard source.utf8.count <= 131_072 else { return [] }
        let chars = Array(source)
        var index = 0
        var requests: [Request] = []
        func identifier(_ char: Character) -> Bool { char.isLetter || char.isNumber || char == "_" || char == "$" }
        func whitespace() { while index < chars.count && chars[index].isWhitespace { index += 1 } }
        func quoted() -> Bool {
            let quote = chars[index]; index += 1
            while index < chars.count {
                if chars[index] == "\\" { index += 2; continue }
                if chars[index] == quote { index += 1; return true }
                index += 1
            }
            return false
        }
        while index < chars.count {
            let char = chars[index]
            if char == "`" { return [] } // Dynamic templates cannot be summarized safely.
            if char == "\"" || char == "'" { guard quoted() else { return [] }; continue }
            if char == "/" {
                if index + 1 < chars.count && chars[index + 1] == "/" {
                    while index < chars.count && chars[index] != "\n" { index += 1 }
                    continue
                }
                if index + 1 < chars.count && chars[index + 1] == "*" {
                    index += 2
                    while index + 1 < chars.count && !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                    guard index + 1 < chars.count else { return [] }
                    index += 2; continue
                }
                return [] // Do not mistake the contents of a regex literal for a call.
            }
            guard identifier(char) else { index += 1; continue }
            let start = index
            while index < chars.count && identifier(chars[index]) { index += 1 }
            guard String(chars[start..<index]) == "tools" else { continue }
            // Reject other.tools and other?.tools.
            var previous = start
            while previous > 0 && chars[previous - 1].isWhitespace { previous -= 1 }
            guard previous == 0 || chars[previous - 1] != "." else { continue }
            whitespace()
            guard index < chars.count && chars[index] == "." else { continue }
            index += 1; whitespace()
            let nameStart = index
            while index < chars.count && identifier(chars[index]) { index += 1 }
            let name = String(chars[nameStart..<index])
            guard !name.isEmpty else { continue }
            whitespace()
            guard index < chars.count && chars[index] == "(" else { continue }
            index += 1; whitespace()
            guard index < chars.count else { return [] }
            let argumentStart = index
            if chars[index] == "{" {
                var depth = 0
                repeat {
                    if chars[index] == "\"" || chars[index] == "'" { guard quoted() else { return [] }; continue }
                    if chars[index] == "{" { depth += 1 }
                    if chars[index] == "}" { depth -= 1 }
                    index += 1
                } while index < chars.count && depth > 0
                guard depth == 0 else { return [] }
            } else if chars[index] == "\"" || chars[index] == "'" {
                guard quoted() else { return [] }
            } else { continue }
            let argument = String(chars[argumentStart..<index])
            whitespace()
            guard index < chars.count && chars[index] == ")", let value = try? JSONSerialization.jsonObject(with: Data(argument.utf8), options: [.fragmentsAllowed, .json5Allowed]) else { continue }
            if name == "apply_patch", let patch = value as? String {
                requests.append(Request(item: ChatItem(id: "request-\(start)", kind: .tool, text: patch, title: name), range: start..<(index + 1)))
            } else if let object = value as? [String: Any] {
                requests.append(Request(item: ChatItem(id: "request-\(start)", kind: .tool, text: TranscriptParser.printable(object), title: name), range: start..<(index + 1)))
            }
            if requests.count >= 32 { break }
        }
        return requests
    }
}

extension ToolOrchestration {
    static func normalizedName(_ title: String) -> String {
        // Only the final namespace component is used. Foundation's components
        // path allocates and scans every component on each classification.
        let start = title.lastIndex(of: ".").map { title.index(after: $0) } ?? title.startIndex
        return title[start...].lowercased()
    }

    static func isWrapper(_ item: ChatItem) -> Bool {
        item.kind == .tool && ["exec", "js", "javascript"].contains(normalizedName(item.title))
    }

    /// Canonicalize only within one wrapper's forward execution window. The
    /// same command in another call or turn remains a distinct operation.
    static func coalesced(_ items: [ChatItem], turnID: String) -> [ChatItem] {
        var result: [ChatItem] = []
        var consumed: Set<Int> = []
        for index in items.indices {
            guard !consumed.contains(index) else { continue }
            let wrapper = items[index]
            let object = isWrapper(wrapper) ? ToolPresentation.json(wrapper.text) as? [String: Any] : nil
            guard isWrapper(wrapper), let requests = sequentialRequests(in: object?["code"] as? String ?? wrapper.text) else {
                result.append(wrapper); continue
            }
            var end = index + 1
            while end < items.count, items[end].kind == .tool, !isWrapper(items[end]) { end += 1 }
            let outputs = results(wrapper.output, count: requests.count)
            var matched: Set<Int> = []
            let executions = requests.enumerated().map { ordinal, request -> Int? in
                let envelope = outputs.flatMap { ordinal < $0.count ? ToolPresentation.json($0[ordinal]) as? [String: Any] : nil }
                let processID = envelope?["session_id"].map(TranscriptParser.printable)
                // Long-running commands can finish after later wrappers. Their
                // returned process handle gives an exact link to that event.
                let limit = processID == nil ? end : items.count
                let match = ((index + 1)..<limit).first {
                    !consumed.contains($0) && !matched.contains($0) && matches(request, items[$0])
                        && (processID == nil || items[$0].processID == processID)
                }
                if let match { matched.insert(match) }
                return match
            }
            // A transport can truncate the entire batch into invalid JSON. If
            // every operation has its own execution record, use those complete
            // results without retaining the damaged wrapper copy.
            guard outputs != nil || executions.allSatisfy({ $0 != nil }) else { result.append(wrapper); continue }
            for (ordinal, request) in requests.enumerated() {
                let match = executions[ordinal]
                if request.title == "write_stdin", let input = ToolPresentation.json(request.text) as? [String: Any],
                   (input["chars"] as? String ?? "").isEmpty,
                   let processID = input["session_id"].map(TranscriptParser.printable),
                   let outputs, ordinal < outputs.count,
                   let envelope = ToolPresentation.json(outputs[ordinal]) as? [String: Any], envelope["output"] is String,
                   envelope["session_id"] != nil || envelope["exit_code"] is Int,
                   items.contains(where: { $0.processID == processID && $0.completed && (envelope["exit_code"] as? Int ?? $0.exitCode) == $0.exitCode }) {
                    // Empty polling only repeats chunks of the command's final
                    // aggregated output. The original polling records remain.
                    continue
                }
                var item: ChatItem
                if let match {
                    item = items[match]; consumed.insert(match)
                } else {
                    item = request
                    item.id = wrapper.id + ":" + request.id
                    if let outputs, ordinal < outputs.count {
                        item.output = outputs[ordinal]
                        let envelope = ToolPresentation.json(item.output) as? [String: Any]
                        let output = ToolOutput.decode(item.output)
                        item.exitCode = output.code
                        item.completed = envelope?["session_id"] == nil || envelope?["exit_code"] is Int
                    }
                }
                // Preserve the mounted wrapper row while its execution arrives.
                item.rowID = ordinal == 0 ? (wrapper.rowID ?? "\(turnID.utf8.count):\(turnID):\(wrapper.id)")
                    : "\(turnID.utf8.count):\(turnID):\(wrapper.id):\(request.id)"
                result.append(item)
            }
        }
        return result
    }

    private static func matches(_ request: ChatItem, _ execution: ChatItem) -> Bool {
        if ChatPatch.isPatchOperation(request) {
            return ChatPatch.isPatchOperation(execution) && ChatPatch.sameEdits(request: request, patch: execution)
        }
        let name = normalizedName(execution.title)
        guard ["exec_command", "shell_command"].contains(request.title),
              ["shell", "bash", "exec_command", "shell_command"].contains(name) else { return false }
        let input = ToolPresentation.json(request.text) as? [String: Any]
        let value = ToolPresentation.json(execution.text)
        let object = value as? [String: Any]
        let command = ToolPresentation.command(object?["cmd"] ?? object?["command"] ?? value) ?? execution.text
        guard ToolPresentation.command(input?["cmd"] ?? input?["command"]) == command else { return false }
        if let directory = input?["workdir"] as? String ?? input?["cwd"] as? String,
           let actual = object?["workdir"] as? String ?? object?["cwd"] as? String { return directory == actual }
        return true
    }

    /// Code Mode prints one content item per text(...) call, preceded by a
    /// status header. Keep those results separate instead of duplicating the
    /// concatenated wrapper output on every underlying operation.
    private static func results(_ raw: String, count: Int) -> [String]? {
        if raw.isEmpty { return [] }
        if let content = ToolPresentation.json(raw) as? [[String: Any]] {
            var results: [String] = []
            for item in content {
                guard ["input_text", "output_text", "text"].contains(item["type"] as? String ?? ""),
                      let text = item["text"] as? String else { return nil }
                if text.range(of: #"\AScript completed\nWall time [0-9]+(?:\.[0-9]+)? seconds\nOutput:\n\z"#, options: .regularExpression) != nil { continue }
                results.append(text)
            }
            if results.count == 1, count > 1, let batch = ToolPresentation.json(results[0]) as? [Any], batch.count == count {
                results = batch.map(TranscriptParser.printable)
            }
            guard results.count == count else { return nil }
            return results.map { value in
                guard let settled = ToolPresentation.json(value) as? [String: Any] else { return value }
                if settled["status"] as? String == "fulfilled", let result = settled["value"] { return TranscriptParser.printable(result) }
                if settled["status"] as? String == "rejected", let reason = settled["reason"] {
                    return TranscriptParser.printable(["output": "Request failed: " + TranscriptParser.printable(reason), "exit_code": 1])
                }
                return value
            }
        }
        return count == 1 ? [raw] : nil
    }
}
