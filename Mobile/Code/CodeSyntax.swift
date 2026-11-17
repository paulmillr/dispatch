import SwiftUI
import UIKit

/// The desktop syntax palette on the phone (M5d, M5e): keywords pink, calls blue, strings green, types purple, numbers
/// and constants amber, comments grey, the rest light grey. The shared scanner's mobile profile keeps the mockup's
/// finer roles (types and constants apart from keywords) and keyword sets per language.
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

    /// The colour of each role: the app's (`standard`), or a scheme's (`ChatPalette`); `id` keys caches of coloured text.
    struct Colors: Equatable {
        let id: String
        let colors: [Role: Color]
        subscript(role: Role) -> Color { colors[role] ?? role.color }
        static let standard = Colors(id: "app", colors: [:])
        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    struct Token: Equatable, Sendable {
        let range: NSRange
        let role: Role
    }

    /// Larger code is shown plain, as on the Mac.
    static let limit = SyntaxScanner.limit

    /// The language for a fence tag or a path ("ts", "src/lib/idempotent.ts", "Swift"), as the Mac names them.
    static func language(_ hint: String) -> String {
        SyntaxScanner.language(hint, profile: .mobile)
    }

    /// The tokens of `code`, in order and never overlapping; text between them is `.plain`.
    static func tokens(_ code: String, language hint: String) -> [Token] {
        SyntaxScanner.tokens(code, language: hint, profile: .mobile).map { token in
            // The mobile profile emits only code roles; diff and Markdown keep their dedicated renderers.
            Token(range: token.range, role: Role(rawValue: token.role.rawValue)!)
        }
    }

    /// `code` as attributed text in the palette (no font).
    static func attributed(_ code: String, language: String) -> NSAttributedString {
        let code = TextRendering.visible(code)
        let result = NSMutableAttributedString(string: code, attributes: [.foregroundColor: CodePalette.ink])
        for token in tokens(code, language: language) {
            result.addAttribute(.foregroundColor, value: token.role.uiColor, range: token.range)
        }
        return result
    }

    /// `code` cut into lines, each as attributed text in the palette (SwiftUI colours): one pass over the whole text, so
    /// a string or comment that spans lines keeps its colour on every line.
    static func lines(_ code: String, language: String, colors: Colors = .standard) -> [AttributedString] {
        let code = TextRendering.visible(code)
        let source = code as NSString
        var lines: [AttributedString] = []
        var starts: [Int] = []
        var start = 0
        while true {
            starts.append(start)
            let next = source.range(of: "\n", range: NSRange(location: start, length: source.length - start))
            let end = next.location == NSNotFound ? source.length : next.location
            var line = AttributedString(source.substring(with: NSRange(location: start, length: end - start)))
            line.foregroundColor = colors[.plain]
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
                    if let range = Self.range(lower..<upper, in: lines[line]) { lines[line][range].foregroundColor = colors[token.role] }
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
    /// Diff rows and counts, in colorblind mode that vision's (`UIColor.change`).
    static let added = UIColor.change("Added", added: true)
    static let removed = UIColor.change("Destructive", added: false)
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
