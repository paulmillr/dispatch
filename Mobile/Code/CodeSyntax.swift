import SwiftUI
import UIKit

/// The desktop syntax palette on the phone (M5d, M5e): keywords pink, calls blue, strings green, types purple, numbers
/// and constants amber, comments grey, the rest light grey. A port of the Mac's `SyntaxHighlight` lexer (which needs the
/// Mac's `ChatTheme`): the same language names, the same bounded, non-overlapping regular expression where strings
/// and comments are consumed whole so keywords cannot repaint them, with the mockup's finer roles (types and constants
/// apart from keywords) and keyword sets per language.
enum CodeSyntax {
    enum Role: String, CaseIterable, Sendable {
        case plain, keyword, call, string, type, number, comment

        var uiColor: UIColor {
            switch self {
            case .plain: CodePalette.ink
            case .keyword: CodePalette.keyword
            case .call: CodePalette.call
            case .string: CodePalette.string
            case .type: CodePalette.type
            case .number: CodePalette.number
            case .comment: CodePalette.comment
            }
        }
        var color: Color { Self.colors[self]! }
        private static let colors: [Role: Color] = Dictionary(uniqueKeysWithValues: allCases.map { ($0, Color(uiColor: $0.uiColor)) })
    }

    struct Token: Equatable, Sendable {
        let range: NSRange
        let role: Role
    }

    /// Larger code is shown plain, as on the Mac.
    static let limit = 65_536

    /// The language for a fence tag or a path ("ts", "src/lib/idempotent.ts", "Swift"), as the Mac names them.
    static func language(_ hint: String) -> String {
        let name = hint.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "text"
        let ext = (name as NSString).pathExtension
        let key = ext.isEmpty ? (name as NSString).lastPathComponent : ext
        switch key {
        case "sh", "bash", "zsh", "fish", "shell", "console": return "shell"
        case "js", "jsx", "javascript", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "typescript", "mts", "cts": return "typescript"
        case "py", "python": return "python"
        case "swift": return "swift"
        case "json", "jsonl": return "json"
        case "yml", "yaml": return "yaml"
        case "c", "h", "cpp", "hpp", "cc", "rust", "rs", "go", "java", "kotlin", "kt", "cs", "m", "mm": return "code"
        case "css", "scss": return "css"
        case "html", "xml", "svg": return "html"
        case "sql": return "sql"
        case "diff", "patch": return "diff"
        default: return "text"
        }
    }

    /// The tokens of `code`, in order and never overlapping; text between them is `.plain`.
    static func tokens(_ code: String, language hint: String) -> [Token] {
        let language = language(hint)
        guard language != "text", language != "diff", code.utf16.count <= limit,
              let expression = expressions[language] else { return [] }
        var result: [Token] = []
        for match in expression.matches(in: code, range: NSRange(location: 0, length: code.utf16.count)) {
            for (group, role) in groups.enumerated() where match.range(at: group + 1).location != NSNotFound {
                result.append(Token(range: match.range, role: role))
                break
            }
        }
        return result
    }

    /// `code` as attributed text in the palette (no font).
    static func attributed(_ code: String, language: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code, attributes: [.foregroundColor: CodePalette.ink])
        for token in tokens(code, language: language) {
            result.addAttribute(.foregroundColor, value: token.role.uiColor, range: token.range)
        }
        return result
    }

    /// `code` cut into lines, each as attributed text in the palette (SwiftUI colours): one pass over the whole text, so
    /// a string or comment that spans lines keeps its colour on every line.
    static func lines(_ code: String, language: String) -> [AttributedString] {
        let source = code as NSString
        var lines: [AttributedString] = []
        var starts: [Int] = []
        var start = 0
        while true {
            starts.append(start)
            let next = source.range(of: "\n", range: NSRange(location: start, length: source.length - start))
            let end = next.location == NSNotFound ? source.length : next.location
            var line = AttributedString(source.substring(with: NSRange(location: start, length: end - start)))
            line.foregroundColor = Role.plain.color
            lines.append(line)
            guard next.location != NSNotFound else { break }
            start = end + 1
        }
        var index = 0
        for token in tokens(code, language: language) {
            // Paint the token on every line it touches.
            while index + 1 < starts.count, starts[index + 1] <= token.range.location { index += 1 }
            var line = index
            while line < lines.count, starts[line] < NSMaxRange(token.range) {
                let lineStart = starts[line]
                let lineLength = (line + 1 < starts.count ? starts[line + 1] - 1 : source.length) - lineStart
                let lower = max(token.range.location, lineStart) - lineStart
                let upper = min(NSMaxRange(token.range), lineStart + lineLength) - lineStart
                if upper > lower {
                    if let range = Self.range(lower..<upper, in: lines[line]) { lines[line][range].foregroundColor = token.role.color }
                }
                line += 1
            }
        }
        return lines
    }

    /// A UTF-16 range of `text` as its own indices.
    private static func range(_ offsets: Range<Int>, in text: AttributedString) -> Range<AttributedString.Index>? {
        let string = String(text.characters)
        let utf16 = string.utf16
        guard let lower = utf16.index(utf16.startIndex, offsetBy: offsets.lowerBound, limitedBy: utf16.endIndex),
              let upper = utf16.index(utf16.startIndex, offsetBy: offsets.upperBound, limitedBy: utf16.endIndex),
              let from = String.Index(lower, within: string), let to = String.Index(upper, within: string),
              let start = AttributedString.Index(from, within: text), let end = AttributedString.Index(to, within: text)
        else { return nil }
        return start..<end
    }

    /// The capture groups in precedence order.
    private static let groups: [Role] = [.comment, .string, .number, .number, .keyword, .type, .number, .type, .call, .call]

    private static let expressions: [String: NSRegularExpression] = {
        ["shell", "python", "yaml", "javascript", "typescript", "swift", "json", "code", "css", "html", "sql"]
            .reduce(into: [:]) { result, language in result[language] = try? NSRegularExpression(pattern: pattern(language)) }
    }()

    private static func words(_ list: String) -> String {
        list.isEmpty ? #"(?!)"# : #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static func keywords(_ language: String) -> String {
        switch language {
        case "swift":
            "let var func return if else guard for while in do switch case break continue default import class struct enum protocol extension public private internal fileprivate open static final override async await throws throw try catch defer self Self super init deinit where as is some any inout mutating nonisolated actor typealias associatedtype get set willSet didSet lazy weak unowned rethrows subscript repeat fallthrough consuming borrowing"
        case "javascript", "typescript":
            "const let var function return if else for while do switch case break continue default import from export class extends implements new this super async await throw try catch finally typeof instanceof in of yield delete void interface type enum namespace declare readonly public private protected static abstract as is keyof satisfies"
        case "python":
            "def class return if elif else for while in not and or is import from as with try except finally raise lambda pass yield global nonlocal async await break continue del assert match case self"
        case "shell":
            "if then else elif fi for do done while until case esac function in return export local readonly set unset source"
        case "json":
            ""
        case "sql":
            "select SELECT from FROM where WHERE join JOIN left LEFT inner INNER on ON insert INSERT into INTO values VALUES update UPDATE set SET delete DELETE create CREATE table TABLE limit LIMIT order ORDER by BY group GROUP and AND or OR not NOT as AS"
        default:
            "let var const func function fn return if else guard for while in of do switch case match break continue default import from export use class struct enum protocol extension impl trait interface type public private protected internal pub static final override async await throws throw try catch defer self super new mut ref package void this goto"
        }
    }

    private static func constants(_ language: String) -> String {
        switch language {
        case "swift": "true false nil"
        case "javascript", "typescript": "true false null undefined NaN Infinity"
        case "python": "True False None"
        case "shell", "css", "html", "yaml": ""
        default: "true false null nil None"
        }
    }

    private static func types(_ language: String) -> String {
        switch language {
        case "typescript", "javascript": "string number boolean any unknown never object symbol bigint"
        case "python": "int str float bool list dict set tuple bytes object"
        case "code": "int long short char float double bool void usize isize u8 u16 u32 u64 i8 i16 i32 i64 f32 f64 str"
        default: ""
        }
    }

    private static func pattern(_ language: String) -> String {
        let hash = ["shell", "python", "yaml"].contains(language)
        let comments = language == "json" ? #"(?!)"#
            : hash ? #"(?m)(?<!\S)#[^\n]*"#
            : language == "sql" ? #"--[^\n]*|/\*[\s\S]*?(?:\*/|$)"#
            : #"//[^\n]*|/\*[\s\S]*?(?:\*/|$)|<!--[\s\S]*?(?:-->|$)"#
        let strings = #""""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\[\s\S]|[^"\\\n])*(?:"|$)|'(?:\\[\s\S]|[^'\\\n])*(?:'|$)|`(?:\\[\s\S]|[^`\\])*(?:`|$)"#
        let numbers = #"\b(?:0x[\da-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
        // Upper-case names that are not object keys (`TTL`, not `NX:`) read as constants.
        let shouting = #"\b[A-Z][A-Z0-9_]+\b(?!\s*:(?!:))"#
        // Type names: capitalised with a lower-case letter (`String`, `Promise`), or one capital (`T`).
        let capitalized = language == "shell" ? #"(?!)"# : #"\b[A-Z](?:[A-Z0-9_]*[a-z][a-zA-Z0-9_]*)?\b"#
        // Calls, and the receivers of a member access (`redis.incr(…)`); in the shell, variables and flags.
        let calls = language == "shell" ? #"\$\{[^}\n]*\}|\$[a-zA-Z_][a-zA-Z_0-9]*|(?<!\S)--?[a-zA-Z][a-zA-Z0-9-]*"#
            : #"\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*\()"#
        let receivers = language == "shell" || language == "json" ? #"(?!)"# : #"\b[a-z_][a-zA-Z0-9_]*(?=\??\.[a-zA-Z_])"#
        return [comments, strings, numbers, words(constants(language)), words(keywords(language)), words(types(language)),
                shouting, capitalized, calls, receivers].map { "(" + $0 + ")" }.joined(separator: "|")
    }
}

/// The mockup's code colours (M5d, M5e), shared by the diff viewer and the composer: the dark palette in dark, a
/// deeper one with the same roles in light (asset catalog, `Code…` colours). Dynamic: TextKit and SwiftUI resolve them
/// per trait collection when they draw.
enum CodePalette {
    static let ink = UIColor.dispatch("CodeInk")
    static let keyword = UIColor.dispatch("CodeKeyword")
    static let call = UIColor.dispatch("StepRead")
    static let string = UIColor.dispatch("CodeString")
    static let type = UIColor.dispatch("CodeType")
    static let number = UIColor.dispatch("CodeNumber")
    static let comment = UIColor.dispatch("CodeComment")
    /// Diff rows and counts.
    static let added = UIColor.dispatch("Added")
    static let removed = UIColor.dispatch("Destructive")
    static let addedRow = added.dynamic(alpha: 0.12)
    static let removedRow = removed.dynamic(alpha: 0.12)
    static let hunk = call
    static let hunkRow = call.dynamic(alpha: 0.08)
    /// Line numbers, disclosure triangles and fence tags: the tertiary label.
    static let gutter = UIColor.tertiaryLabel
    static let hairline = UIColor.dispatch("Hairline")
    /// The composer's fenced panel and inline chip.
    static let panel = UIColor.dispatch("CodePanel")
    static let panelBorder = UIColor.dispatch("CodePanelBorder")
    static let panelRule = UIColor.dispatch("CodePanelRule")
    static let chip = UIColor.dispatch("CodeChip")
}
