import Foundation

/// Text for voice conversation announcements, shared by the Mac and phone.
enum SpokenMarkdown {
    /// A reply as words to say: Markdown's marks gone, code blocks named rather than read, long ones cut short.
    static func text(_ markdown: String) -> String {
        let blocks = ChatMarkdownBlock.parse(TextRendering.visible(markdown))
        let parts = blocks.compactMap { block -> String? in
            let source: String
            switch block.kind {
            case .rule: return nil
            case .code: return "There's a code block on screen."
            case .table: return "There's a table on screen."
            default: source = block.text
            }
            let value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return value.map { String($0.characters) } ?? source
        }
        return bounded(parts.joined(separator: "\n"), 1_500, more: " The rest is on screen.")
    }

    /// One message read on request (the phone's Read Aloud): all of it, Markdown's marks gone, each code block and
    /// table said in a few words instead of read ("Swift code, 12 lines."), a pause between blocks; only a very long
    /// message is cut short.
    static func message(_ markdown: String) -> String {
        let blocks = ChatMarkdownBlock.parse(TextRendering.visible(markdown))
        let parts = blocks.compactMap { block -> String? in
            switch block.kind {
            case .rule: return nil
            case .code(let language): return code(language: language, lines: block.text)
            case .table(let rows): return rows.count > 1 ? "A table, \(rows.count - 1) rows." : "A table."
            default:
                let value = try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                let words = (value.map { String($0.characters) } ?? block.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !words.isEmpty else { return nil }
                // A heading or list item without its own stop would run into the next block.
                return words.last.map { ".!?:;".contains($0) } == true ? words : words + "."
            }
        }
        return bounded(parts.joined(separator: "\n"), 20_000, more: " The rest is on screen.")
    }

    /// "Swift code, 12 lines.", "Shell command." (one line of shell), "A diff, 30 lines.", "Code, 3 lines."
    static func code(language: String, lines text: String) -> String {
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let key = language.lowercased().trimmingCharacters(in: .whitespaces)
        let shell = ["sh", "bash", "zsh", "fish", "shell", "console", "shell-session"].contains(key)
        if shell && count == 1 { return "Shell command." }
        let lines = count == 1 ? "1 line" : "\(count) lines"
        if key == "diff" || key == "patch" { return "A diff, \(lines)." }
        let names = ["js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
                     "tsx": "TypeScript", "jsx": "JavaScript", "py": "Python", "python": "Python", "rb": "Ruby",
                     "rs": "Rust", "rust": "Rust", "go": "Go", "swift": "Swift", "kt": "Kotlin", "java": "Java",
                     "c": "C", "cpp": "C++", "c++": "C++", "cs": "C#", "json": "JSON", "yaml": "YAML", "yml": "YAML",
                     "toml": "TOML", "sql": "SQL", "html": "HTML", "css": "CSS", "md": "Markdown", "markdown": "Markdown",
                     "xml": "XML"]
        // An unlabelled fence parses as "text".
        let plain = key.isEmpty || key.count > 20 || ["text", "txt", "plaintext", "plain"].contains(key)
        let name = shell ? "Shell" : names[key] ?? (plain ? nil : key.prefix(1).uppercased() + key.dropFirst())
        return name.map { "\($0) code, \(lines)." } ?? "Code, \(lines)."
    }

    static func bounded(_ text: String, _ limit: Int, more: String = "…") -> String {
        let prefix = TextRendering.prefix(text, scalars: limit)
        return prefix.text + (prefix.truncated ? more : "")
    }
}
