import SwiftUI

/// A bounded, non-overlapping lexer for display, with plain-text fallback.
/// Tokens in strings/comments are consumed together so keywords cannot repaint them.
enum SyntaxHighlight {
    static func language(_ hint: String) -> String {
        let name = hint.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "text"
        let ext = (name as NSString).pathExtension
        let key = ext.isEmpty ? name : ext
        switch key {
        case "sh", "bash", "zsh", "fish", "shell", "console": return "shell"
        case "js", "jsx", "javascript", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "typescript": return "typescript"
        case "py", "python": return "python"
        case "swift": return "swift"
        case "json", "jsonl": return "json"
        case "yml", "yaml": return "yaml"
        case "c", "h", "cpp", "hpp", "cc", "rust", "rs", "go", "java", "kotlin", "kt", "cs": return "code"
        case "css", "scss": return "css"
        case "html", "xml", "svg": return "html"
        case "sql": return "sql"
        case "diff", "patch": return "diff"
        case "md", "markdown", "mdx": return "markdown"
        default: return "text"
        }
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
        let lang = language(hint)
        guard lang != "text", code.utf16.count <= 65_536 else { return [] }
        var result: [Token] = []
        if lang == "diff" {
            var offset = 0
            for line in code.components(separatedBy: "\n") {
                let color: Color? = line.hasPrefix("+") ? theme.green : line.hasPrefix("-") ? theme.red : line.hasPrefix("@@") ? theme.blue : nil
                if let color { result.append(Token(range: NSRange(location: offset, length: line.utf16.count), color: color)) }
                offset += line.utf16.count + 1
            }
            return result
        }
        guard let regex = expressions[lang] else { return result }
        let colors: [Color] = lang == "markdown"
            // Code, comments and rules, headings, links, emphasis, then list and quote markers.
            ? [theme.string, theme.comment, theme.keyword, theme.blue, theme.number, theme.number]
            : [theme.comment, theme.string, theme.number, theme.keyword, theme.blue, theme.blue]
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            for group in 1...colors.count where match.range(at: group).location != NSNotFound {
                result.append(Token(range: match.range, color: colors[group - 1]))
                break
            }
        }
        return result
    }

    /// Immutable, bounded cache: only normalized supported languages become
    /// keys. Themes remain per-call values and never affect lexical precedence.
    private static let expressions: [String: NSRegularExpression] = {
        let languages = ["shell", "python", "yaml", "javascript", "typescript", "swift", "json", "code", "css", "html", "sql",
                         "markdown"]
        return languages.reduce(into: [:]) { result, language in
            result[language] = try? NSRegularExpression(pattern: pattern(language))
        }
    }()

    private static func pattern(_ lang: String) -> String {
        if lang == "markdown" { return markdownPattern }
        let hashComments = ["shell", "python", "yaml"].contains(lang)
        let comments = lang == "json" ? #"(?!)"# : (hashComments ? #"(?m)(?<!\S)#[^\n]*"# : (lang == "sql" ? #"--[^\n]*|/\*[\s\S]*?(?:\*/|$)"# : #"//[^\n]*|/\*[\s\S]*?(?:\*/|$)|<!--[\s\S]*?(?:-->|$)"#))
        // A quote's string ends with its line (as the iPhone's CodeSyntax): one apostrophe ("it's", Rust's 'static)
        // never colours the rest of the file.
        let strings = #""""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\[\s\S]|[^"\\\n])*(?:"|$)|'(?:\\[\s\S]|[^'\\\n])*(?:'|$)|`(?:\\[\s\S]|[^`\\])*(?:`|$)"#
        let words = lang == "json" ? "true false null" : "let var const func function return if else guard for while in of do switch case break continue default import from export class struct enum protocol extension public private internal static final override async await throws throw try catch defer self super new nil null true false None True False def with as lambda pass yield raise except finally and or not is select SELECT FROM WHERE JOIN INSERT INTO VALUES UPDATE SET CREATE TABLE LIMIT ORDER BY fn mut impl use pub package interface type void int string bool this"
        let keywords = #"\b(?:"# + words.split(separator: " ").joined(separator: "|") + #")\b"#
        let variables = lang == "shell" ? #"\$\{[^}\n]*\}|\$[a-zA-Z_][a-zA-Z_0-9]*|(?<!\S)--?[a-zA-Z][a-zA-Z0-9-]*"# : #"\b[A-Z][a-zA-Z0-9_]*\b"#
        return "(" + comments + ")|(" + strings + ")|(" + #"\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"# + ")|(" + keywords + ")|(" + variables + ")|(" + #"\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*\()"# + ")"
    }

    /// Block-level spans first, so a fence or an inline code span keeps its text from being read as headings or
    /// emphasis; one group per color in `tokens`.
    private static let markdownPattern: String = {
        let code = #"(?m)^[ \t]{0,3}(?:```[\s\S]*?(?:^[ \t]{0,3}```[^\n]*|(?![\s\S]))|~~~[\s\S]*?(?:^[ \t]{0,3}~~~[^\n]*|(?![\s\S])))|`+[^`\n]+`+"#
        let quiet = #"<!--[\s\S]*?(?:-->|$)|(?m)^[ \t]{0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#
        let headings = #"(?m)^[ \t]{0,3}#{1,6}(?:[ \t][^\n]*)?$|(?m)^[ \t]{0,3}=+[ \t]*$"#
        let links = #"!?\[[^\]\n]*\]\([^)\n]*\)|!?\[[^\]\n]*\]\[[^\]\n]*\]|<(?:https?|mailto):[^>\s]+>|(?m)^[ \t]{0,3}\[[^\]\n]+\]:[^\n]*"#
        let emphasis = #"\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~|\*[^*\s][^*\n]*\*|(?<![\w_])_[^_\s][^_\n]*_(?![\w_])"#
        let markers = #"(?m)^[ \t]*(?:[-*+]|\d{1,9}[.)])(?=[ \t])(?:[ \t]+\[[ xX]\])?|(?m)^[ \t]{0,3}>[> \t]*"#
        return [code, quiet, headings, links, emphasis, markers].map { "(" + $0 + ")" }.joined(separator: "|")
    }()

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
        guard language(path) != "text", language(path) != "diff", diff.utf16.count <= 65_536 else {
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
    var body: some View {
        let preview = TextRendering.prefix(code, scalars: 32_768)
        let shown = firstLine != nil && preview.text.hasSuffix("\n") ? String(preview.text.dropLast()) : preview.text
        let rawLabel = title ?? (language == "text" ? "Text" : language)
        let label = TextRendering.visible(TextRendering.prefix(rawLabel, scalars: 128).text)
        // Formatting depends on the content, not the viewport. Capture it outside
        // GeometryReader so resizing only lays out the existing attributed text.
        let highlighted = SyntaxHighlight.text(shown.isEmpty ? " " : shown, language: language, theme: theme)
        let natural = CGFloat(shown.components(separatedBy: "\n").count) * theme.typography.codeDetailLineHeight + 24
        // A block that fits its 320 pt scrolls sideways only: with both axes, a horizontal scroller shown always
        // (no trackpad) takes its one line's height and a vertical scroller appears for it.
        let tall = natural > 320
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
            ScrollView(tall ? [.horizontal, .vertical] : .horizontal) {
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
            }.frame(height: tall ? 320 : max(44, natural) + scroller)
            if preview.truncated {
                Text("Preview truncated · Copy includes the full text")
                    .font(theme.typography.detail).foregroundStyle(theme.muted).padding(8)
            }
        }.background(theme.terminal, in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
    }
}
