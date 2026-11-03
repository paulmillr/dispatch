import Foundation

/// Display-only lexical spans shared by the Mac and iPhone. Profiles retain each UI's language support and
/// precedence; rendering, palettes and visible-text conversion belong to the platform wrappers.
enum SyntaxScanner {
    enum Profile: CaseIterable, Sendable {
        case desktop, mobile
    }

    enum Role: String, CaseIterable, Sendable {
        case plain, keyword, call, string, type, number, comment
        case added, removed, hunk
    }

    struct Token: Equatable, Sendable {
        let range: NSRange
        let role: Role
    }

    /// Measured in UTF-16 code units to match NSRange and both platform text systems.
    static let limit = 65_536

    static func language(_ hint: String, profile: Profile) -> String {
        let name = hint.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? "text"
        let ext = (name as NSString).pathExtension
        let key = ext.isEmpty ? (profile == .mobile ? (name as NSString).lastPathComponent : name) : ext
        switch key {
        case "sh", "bash", "zsh", "fish", "shell", "console": return "shell"
        case "js", "jsx", "javascript", "mjs", "cjs": return "javascript"
        case "ts", "tsx", "typescript": return "typescript"
        case "mts", "cts": return profile == .mobile ? "typescript" : "text"
        case "py", "python": return "python"
        case "swift": return "swift"
        case "json", "jsonl": return "json"
        case "yml", "yaml": return "yaml"
        case "c", "h", "cpp", "hpp", "cc", "rust", "rs", "go", "java", "kotlin", "kt", "cs": return "code"
        case "m", "mm": return profile == .mobile ? "code" : "text"
        case "css", "scss": return "css"
        case "html", "xml", "svg": return "html"
        case "sql": return "sql"
        case "diff", "patch": return "diff"
        case "md", "markdown", "mdx": return profile == .desktop ? "markdown" : "text"
        default: return "text"
        }
    }

    /// Ordered, non-overlapping spans. Untokenized text stays plain, including unsupported and oversized input.
    static func tokens(_ code: String, language hint: String, profile: Profile) -> [Token] {
        let language = language(hint, profile: profile)
        let length = code.utf16.count
        guard language != "text", length <= limit else { return [] }
        if language == "diff" { return profile == .desktop ? diffTokens(code) : [] }
        guard let expression = expressions[profile]?[language] else { return [] }
        var result: [Token] = []
        for match in expression.regex.matches(in: code, range: NSRange(location: 0, length: length)) {
            for (group, role) in expression.roles.enumerated() where match.range(at: group + 1).location != NSNotFound {
                result.append(Token(range: match.range, role: role))
                break
            }
        }
        return result
    }

    private static func diffTokens(_ code: String) -> [Token] {
        var offset = 0
        var result: [Token] = []
        for line in code.components(separatedBy: "\n") {
            let role: Role? = line.hasPrefix("+") ? .added : line.hasPrefix("-") ? .removed : line.hasPrefix("@@") ? .hunk : nil
            let length = line.utf16.count
            if let role { result.append(Token(range: NSRange(location: offset, length: length), role: role)) }
            offset += length + 1
        }
        return result
    }

    private struct Expression {
        let regex: NSRegularExpression
        let roles: [Role]
    }

    /// Only supported normalized languages and the two profiles enter this immutable cache.
    private static let expressions: [Profile: [String: Expression]] = {
        let languages = ["shell", "python", "yaml", "javascript", "typescript", "swift", "json", "code", "css", "html", "sql"]
        return Dictionary(uniqueKeysWithValues: Profile.allCases.map { profile in
            let supported = languages + (profile == .desktop ? ["markdown"] : [])
            let entries = supported.reduce(into: [String: Expression]()) { result, language in
                let definition = pattern(language, profile: profile)
                if let regex = try? NSRegularExpression(pattern: definition.pattern) {
                    result[language] = Expression(regex: regex, roles: definition.roles)
                }
            }
            return (profile, entries)
        })
    }()

    private static func words(_ list: String) -> String {
        list.isEmpty ? #"(?!)"# : #"\b(?:"# + list.split(separator: " ").joined(separator: "|") + #")\b"#
    }

    private static func pattern(_ language: String, profile: Profile) -> (pattern: String, roles: [Role]) {
        if language == "markdown" {
            return (markdownPattern, [.string, .comment, .keyword, .call, .number, .number])
        }
        let hashComments = ["shell", "python", "yaml"].contains(language)
        let comments = language == "json" ? #"(?!)"#
            : hashComments ? #"(?m)(?<!\S)#[^\n]*"#
            : language == "sql" ? #"--[^\n]*|/\*[\s\S]*?(?:\*/|$)"#
            : #"//[^\n]*|/\*[\s\S]*?(?:\*/|$)|<!--[\s\S]*?(?:-->|$)"#
        // Single quotes stop at a line; triple quotes and backticks may span lines. Consume the whole span
        // before considering keywords or calls, including an unfinished string at the end of the input.
        let strings = #""""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\[\s\S]|[^"\\\n])*(?:"|$)|'(?:\\[\s\S]|[^'\\\n])*(?:'|$)|`(?:\\[\s\S]|[^`\\])*(?:`|$)"#
        let shellVariables = #"\$\{[^}\n]*\}|\$[a-zA-Z_][a-zA-Z_0-9]*|(?<!\S)--?[a-zA-Z][a-zA-Z0-9-]*"#
        let calls = #"\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*\()"#
        let patterns: [String]
        let roles: [Role]
        switch profile {
        case .desktop:
            let numbers = #"\b(?:0x[\da-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
            let list = language == "json" ? "true false null" : "let var const func function return if else guard for while in of do switch case break continue default import from export class struct enum protocol extension public private internal static final override async await throws throw try catch defer self super new nil null true false None True False def with as lambda pass yield raise except finally and or not is select SELECT FROM WHERE JOIN INSERT INTO VALUES UPDATE SET CREATE TABLE LIMIT ORDER BY fn mut impl use pub package interface type void int string bool this"
            let variables = language == "shell" ? shellVariables : #"\b[A-Z][a-zA-Z0-9_]*\b"#
            patterns = [comments, strings, numbers, words(list), variables, calls]
            roles = [.comment, .string, .number, .keyword, .call, .call]
        case .mobile:
            let numbers = #"\b(?:0x[\da-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#
            // Upper-case names that are not object keys (`TTL`, not `NX:`) read as constants.
            let shouting = #"\b[A-Z][A-Z0-9_]+\b(?!\s*:(?!:))"#
            let capitalized = language == "shell" ? #"(?!)"# : #"\b[A-Z](?:[A-Z0-9_]*[a-z][a-zA-Z0-9_]*)?\b"#
            let receivers = language == "shell" || language == "json" ? #"(?!)"# : #"\b[a-z_][a-zA-Z0-9_]*(?=\??\.[a-zA-Z_])"#
            patterns = [comments, strings, numbers, words(constants(language)), words(keywords(language)), words(types(language)),
                        shouting, capitalized, language == "shell" ? shellVariables : calls, receivers]
            roles = [.comment, .string, .number, .number, .keyword, .type, .number, .type, .call, .call]
        }
        return (patterns.map { "(" + $0 + ")" }.joined(separator: "|"), roles)
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

    /// Block spans precede inline styling so code fences consume headings and emphasis inside them.
    private static let markdownPattern: String = {
        let code = #"(?m)^[ \t]{0,3}(?:```[\s\S]*?(?:^[ \t]{0,3}```[^\n]*|(?![\s\S]))|~~~[\s\S]*?(?:^[ \t]{0,3}~~~[^\n]*|(?![\s\S])))|`+[^`\n]+`+"#
        let quiet = #"<!--[\s\S]*?(?:-->|$)|(?m)^[ \t]{0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#
        let headings = #"(?m)^[ \t]{0,3}#{1,6}(?:[ \t][^\n]*)?$|(?m)^[ \t]{0,3}=+[ \t]*$"#
        let links = #"!?\[[^\]\n]*\]\([^)\n]*\)|!?\[[^\]\n]*\]\[[^\]\n]*\]|<(?:https?|mailto):[^>\s]+>|(?m)^[ \t]{0,3}\[[^\]\n]+\]:[^\n]*"#
        let emphasis = #"\*\*[^*\n]+\*\*|__[^_\n]+__|~~[^~\n]+~~|\*[^*\s][^*\n]*\*|(?<![\w_])_[^_\s][^_\n]*_(?![\w_])"#
        let markers = #"(?m)^[ \t]*(?:[-*+]|\d{1,9}[.)])(?=[ \t])(?:[ \t]+\[[ xX]\])?|(?m)^[ \t]{0,3}>[> \t]*"#
        return [code, quiet, headings, links, emphasis, markers].map { "(" + $0 + ")" }.joined(separator: "|")
    }()
}
