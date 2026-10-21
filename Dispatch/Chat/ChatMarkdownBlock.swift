import Foundation

/// Markdown blocks of an agent message, line by line (the Mac's `ChatMarkdown` and the iPhone's thread draw them).
struct ChatMarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph, heading(Int), list(String, Int), quote, code(String), rule, table([[String]])
    }
    let kind: Kind
    let text: String

    /// Line-based fences keep inline backticks and incomplete streaming fences intact.
    static func parse(_ text: String) -> [ChatMarkdownBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ChatMarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.init(kind: .paragraph, text: paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if let marker = trimmed.first, marker == "`" || marker == "~", trimmed.prefix(while: { $0 == marker }).count >= 3 {
                flush()
                let length = trimmed.prefix(while: { $0 == marker }).count
                let language = String(trimmed.dropFirst(length)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                var closed = false
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if next.prefix(while: { $0 == marker }).count >= length && next.allSatisfy({ $0 == marker }) { closed = true; break }
                    code.append(lines[index - 1])
                }
                // A streaming fence's last line is still arriving: empty, or the closing fence's first backticks, it
                // would show as a line that the next delta takes away again.
                if !closed, let last = code.last?.trimmingCharacters(in: .whitespaces), last.allSatisfy({ $0 == marker }) {
                    code.removeLast()
                }
                blocks.append(.init(kind: .code(language.isEmpty ? "text" : language), text: code.joined(separator: "\n")))
            } else if trimmed.isEmpty { flush() }
            else if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 || trimmed == "***" || trimmed == "___" {
                flush(); blocks.append(.init(kind: .rule, text: ""))
            } else if index < lines.count, line.contains("|"), isTableDivider(lines[index]) {
                flush(); index += 1
                var rows = [cells(line)]
                while index < lines.count && lines[index].contains("|") && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[index])); index += 1
                }
                blocks.append(.init(kind: .table(rows), text: ""))
            } else if trimmed.hasPrefix("#"), (1...6).contains(trimmed.prefix(while: { $0 == "#" }).count), trimmed.drop(while: { $0 == "#" }).first == " " {
                flush()
                let count = trimmed.prefix(while: { $0 == "#" }).count
                blocks.append(.init(kind: .heading(count), text: String(trimmed.dropFirst(count + 1))))
            } else if trimmed.hasPrefix("> ") || trimmed == ">" {
                flush(); blocks.append(.init(kind: .quote, text: String(trimmed.dropFirst(min(2, trimmed.count)))))
            } else if let match = trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush()
                let marker = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
                var content = String(trimmed[match.upperBound...])
                var bullet = ["-", "*", "+"].contains(marker) ? "•" : marker
                if content.hasPrefix("[ ] ") { bullet = "☐"; content = String(content.dropFirst(4)) }
                else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") { bullet = "☑"; content = String(content.dropFirst(4)) }
                blocks.append(.init(kind: .list(bullet, min(6, (line.count - trimmed.count) / 2)), text: content))
            } else { paragraph.append(line) }
        }
        flush(); return blocks
    }
    private static func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        // Escaped pipes and pipes inside inline code are content, not separators.
        var cells: [String] = [], cell = "", escaped = false, inCode = false
        for char in value {
            if escaped { cell.append(char); escaped = false; continue }
            if char == "\\" { cell.append(char); escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|" && !inCode { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(char) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces)); return cells
    }
    private static func isTableDivider(_ line: String) -> Bool {
        let row = cells(line)
        return !row.isEmpty && row.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
}
