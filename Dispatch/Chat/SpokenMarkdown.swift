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

    static func bounded(_ text: String, _ limit: Int, more: String = "…") -> String {
        let prefix = TextRendering.prefix(text, scalars: limit)
        return prefix.text + (prefix.truncated ? more : "")
    }
}
