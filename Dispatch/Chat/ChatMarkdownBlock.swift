import Foundation

/// Markdown blocks of an agent message, line by line (the Mac's `ChatMarkdown` and the iPhone's thread draw them).
struct ChatMarkdownBlock: Equatable {
    /// A rendered table is a view per cell. Bound adversarial rows before they can create tens of thousands of views.
    static let tableColumnsLimit = 64
    static let fenceInfoLimit = 128

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
                let language = TextRendering.prefix(String(trimmed.dropFirst(length)), scalars: fenceInfoLimit).text
                    .trimmingCharacters(in: .whitespaces)
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
    private static func cells(_ line: String, markTruncated: Bool = true) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        // Escaped pipes and pipes inside inline code are content, not separators.
        var cells: [String] = [], cell = "", escaped = false, inCode = false
        for char in value {
            if escaped { cell.append(char); escaped = false; continue }
            if char == "\\" { cell.append(char); escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|" && !inCode {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""
                if cells.count == tableColumnsLimit {
                    if markTruncated { cells[cells.count - 1] = "…" }
                    return cells
                }
            }
            else { cell.append(char) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces)); return cells
    }
    /// The text a reader sees, without its Markdown: for one-line previews (the iPhone's Agents rows and Spaces lines),
    /// which showed `**bold**`, backticks and a table's pipes as typed. Headings, quotes and list items keep their
    /// words, a table's rows their cells (" · " between them, no divider), inline markup its text (links their
    /// titles); code blocks are left out unless nothing else is said.
    static func plainText(_ text: String) -> String {
        let blocks = parse(TextRendering.rich(text).text)
        func inline(_ text: String) -> String {
            let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return value.map { String($0.characters) } ?? text
        }
        let prose: [String] = blocks.compactMap { block in
            switch block.kind {
            case .paragraph, .heading, .quote, .list: inline(block.text)
            case .table(let rows): rows.map { $0.map(inline).joined(separator: " · ") }.joined(separator: "\n")
            case .code, .rule: nil
            }
        }
        let said = prose.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !said.isEmpty { return said.joined(separator: "\n") }
        return blocks.compactMap { if case .code = $0.kind { $0.text } else { nil } }.joined(separator: "\n")
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let row = cells(line, markTruncated: false)
        return !row.isEmpty && row.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
}

/// Bounds rich-text work and makes controls that can visually reorder or conceal source explicit. The underlying
/// file/message stays unchanged for copying and actions; this is only the string handed to text layout and Markdown.
enum TextRendering {
    static let richScalarLimit = 131_072
    static let richLineLimit = 2_000

    struct RichText: Equatable {
        let text: String
        let truncated: Bool
    }

    /// A scalar bound cannot be bypassed by one pathological extended grapheme made from thousands of scalars.
    /// The returned text is otherwise unchanged; callers that draw it must still use `visible` or a renderer that does.
    static func prefix(_ text: String, scalars limit: Int) -> RichText {
        guard limit > 0 else { return RichText(text: "", truncated: !text.isEmpty) }
        var bounded = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count == limit { return RichText(text: String(bounded), truncated: true) }
            bounded.append(scalar)
            count += 1
        }
        return RichText(text: String(bounded), truncated: false)
    }

    static func rich(_ text: String) -> RichText {
        var bounded = String.UnicodeScalarView()
        var scalars = 0, lines = 1
        var truncated = false
        for scalar in text.unicodeScalars {
            if scalars == richScalarLimit || (scalar == "\n" && lines == richLineLimit) {
                truncated = true
                break
            }
            bounded.append(scalar)
            scalars += 1
            if scalar == "\n" { lines += 1 }
        }
        return RichText(text: visible(String(bounded)), truncated: truncated)
    }

    static func visible(_ text: String) -> String {
        let normalized = text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        guard normalized.unicodeScalars.contains(where: unsafe) else { return normalized }
        var result = ""
        result.reserveCapacity(normalized.utf8.count)
        let scalars = Array(normalized.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar.value == 0x200D, index > 0, index + 1 < scalars.count,
               joinsEmoji(scalars[index - 1], scalars[index + 1]) { result.unicodeScalars.append(scalar) }
            else if let label = label(for: scalar) { result += "⟦\(label)⟧" }
            else { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    /// A joiner between two emoji (👩🏽‍💻) is how the emoji is spelled, not a hidden control.
    private static func joinsEmoji(_ previous: Unicode.Scalar, _ next: Unicode.Scalar) -> Bool {
        func emoji(_ scalar: Unicode.Scalar) -> Bool { scalar.value > 0x7F && scalar.properties.isEmoji }
        return (emoji(previous) || previous.value == 0xFE0F) && emoji(next)
    }

    private static func unsafe(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (value < 0x20 && value != 0x09 && value != 0x0A)
            || (0x7F...0x9F).contains(value)
            || scalar.properties.generalCategory == .format
            || value == 0x2028 || value == 0x2029
    }

    private static func label(for scalar: Unicode.Scalar) -> String? {
        guard unsafe(scalar) else { return nil }
        switch scalar.value {
        case 0x00: return "NUL"
        case 0x08: return "BS"
        case 0x0D: return "CR"
        case 0x1B: return "ESC"
        case 0x061C: return "ALM"
        case 0x200B: return "ZWSP"
        case 0x200C: return "ZWNJ"
        case 0x200D: return "ZWJ"
        case 0x200E: return "LRM"
        case 0x200F: return "RLM"
        case 0x2028: return "LS"
        case 0x2029: return "PS"
        case 0x202A: return "LRE"
        case 0x202B: return "RLE"
        case 0x202C: return "PDF"
        case 0x202D: return "LRO"
        case 0x202E: return "RLO"
        case 0x2060: return "WJ"
        case 0x2066: return "LRI"
        case 0x2067: return "RLI"
        case 0x2068: return "FSI"
        case 0x2069: return "PDI"
        case 0xFEFF: return "BOM"
        default: return "U+" + String(scalar.value, radix: 16, uppercase: true)
        }
    }
}
