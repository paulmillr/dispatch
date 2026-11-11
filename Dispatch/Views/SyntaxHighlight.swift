import SwiftUI

/// A bounded, non-overlapping lexer for display, with plain-text fallback.
/// Tokens in strings/comments are consumed together so keywords cannot repaint them.
enum SyntaxHighlight {
    static func language(_ hint: String) -> String {
        SyntaxScanner.language(hint, profile: .desktop)
    }
    static let keyword = Color(red: 0.79, green: 0.62, blue: 0.91)
    static let string = Color(red: 0.64, green: 0.81, blue: 0.57)
    static let number = Color(red: 0.89, green: 0.70, blue: 0.46)
    static let function = Color(red: 0.49, green: 0.72, blue: 0.89)
    static let comment = Color(red: 0.49, green: 0.51, blue: 0.55)

    struct Token { let range: NSRange; let color: Color }
    static func text(_ code: String, language hint: String, theme: ChatTheme = .standard) -> AttributedString {
        let code = TextRendering.visible(code)
        var result = AttributedString(code)
        result.foregroundColor = theme.ink
        for token in tokens(code, language: hint, theme: theme) {
            guard let range = Range(token.range, in: code),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].foregroundColor = token.color
        }
        return result
    }
    static func tokens(_ code: String, language hint: String, theme: ChatTheme = .standard) -> [Token] {
        SyntaxScanner.tokens(code, language: hint, profile: .desktop).map { token in
            let color: Color = switch token.role {
            case .plain: theme.ink
            case .keyword: theme.keyword
            case .call, .type, .hunk: theme.blue
            case .string: theme.string
            case .number: theme.number
            case .comment: theme.comment
            case .added: theme.green
            case .removed: theme.red
            }
            return Token(range: token.range, color: color)
        }
    }

    static func lines(_ code: String, language: String, theme: ChatTheme = .standard) -> [AttributedString] {
        let highlighted = text(code, language: language, theme: theme)
        var lines: [AttributedString] = []
        var start = highlighted.startIndex
        for index in highlighted.characters.indices where highlighted.characters[index] == "\n" {
            lines.append(AttributedString(highlighted[start..<index]))
            start = highlighted.characters.index(after: index)
        }
        lines.append(AttributedString(highlighted[start...]))
        return lines
    }

    static func diffLines(_ diff: String, path: String, theme: ChatTheme = .standard) -> [AttributedString] {
        guard language(path) != "text", language(path) != "diff", diff.utf16.count <= SyntaxScanner.limit else {
            return lines(diff, language: "diff", theme: theme)
        }
        let raw = diff.components(separatedBy: "\n")
        var result = lines(diff, language: "diff", theme: theme)
        var old: [(index: Int, body: String)] = [], new: [(index: Int, body: String)] = []
        func flush() {
            // Parse both versions independently: a removed comment/string must
            // not change the lexical state of added lines, or the next hunk.
            for version in [old, new] where !version.isEmpty {
                let colored = lines(version.map(\.body).joined(separator: "\n"), language: path, theme: theme)
                for (offset, row) in version.enumerated() {
                    var prefix = AttributedString(raw[row.index].isEmpty ? "" : String(raw[row.index].prefix(1)))
                    prefix.foregroundColor = raw[row.index].hasPrefix("+") ? theme.green : raw[row.index].hasPrefix("-") ? theme.red : theme.muted
                    prefix.append(colored[offset])
                    result[row.index] = prefix
                }
            }
            old.removeAll(keepingCapacity: true); new.removeAll(keepingCapacity: true)
        }
        for (index, line) in raw.enumerated() {
            if line.hasPrefix("@@") || line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                flush()
            } else if line.hasPrefix("+") {
                new.append((index, String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                old.append((index, String(line.dropFirst())))
            } else if line.hasPrefix(" ") || line.isEmpty {
                let body = line.isEmpty ? "" : String(line.dropFirst())
                old.append((index, body)); new.append((index, body))
            } else { flush() }
        }
        flush()
        return result
    }
}

struct ChatCodeBlock: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatSearchQuery) private var query
    let code: String
    var language = "text"
    var title: String?
    var firstLine: Int?
    /// A tall block shows its first 320 pt until Show All: never a vertical scroll area of its own, which would take
    /// the wheel from the transcript scrolling past it.
    @State private var expanded = false
    var body: some View {
        let preview = TextRendering.prefix(code, scalars: 32_768)
        let shown = firstLine != nil && preview.text.hasSuffix("\n") ? String(preview.text.dropLast()) : preview.text
        let rawLabel = title ?? (language == "text" ? "Text" : language)
        let label = TextRendering.visible(TextRendering.prefix(rawLabel, scalars: 128).text)
        // Formatting depends on the content, not the viewport. Capture it outside
        // GeometryReader so resizing only lays out the existing attributed text.
        let highlighted = SyntaxHighlight.text(shown.isEmpty ? " " : shown, language: language, theme: theme)
        let natural = CGFloat(shown.components(separatedBy: "\n").count) * theme.typography.codeDetailLineHeight + 24
        // Every block scrolls sideways only, so vertical scrolling always reaches the transcript.
        let tall = natural > 320
        let lines = shown.components(separatedBy: "\n").count
        let scroller = NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).foregroundStyle(theme.muted)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).help("Copy \(label)").accessibilityLabel("Copy \(label)")
            }.font(theme.typography.detail).padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.window)
            GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    if let firstLine {
                        Text((0..<shown.components(separatedBy: "\n").count).map { String(firstLine + $0) }.joined(separator: "\n"))
                            .foregroundStyle(theme.muted).fixedSize(horizontal: true, vertical: true)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("code-line-numbers")
                    }
                    Text(ChatSearchHighlight.text(highlighted, query: query, theme: theme)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }.font(theme.typography.codeDetail)
                    .frame(minWidth: max(0, geometry.size.width - 24), alignment: .leading).padding(12)
            }
            }.frame(height: tall && !expanded ? 320 : max(44, natural) + scroller, alignment: .top).clipped()
            if tall {
                Button(expanded ? "Show Less" : "Show All \(lines) Lines") { expanded.toggle() }
                    .buttonStyle(.plain).font(theme.typography.detail).foregroundStyle(theme.blue)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .accessibilityIdentifier("code-block-show-all")
            }
            if preview.truncated {
                Text(TextRendering.shortenedNote)
                    .font(theme.typography.detail).foregroundStyle(theme.muted).padding(8)
            }
        }.background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
    }
}
