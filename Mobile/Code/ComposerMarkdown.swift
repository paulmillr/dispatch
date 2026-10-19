import Foundation

/// What the code composer (M5e) renders in a plain Markdown draft: fenced blocks (the Mac composer's
/// `ComposerFence.scan`, shared by path) and inline code spans outside them. Offsets are UTF-16, as UITextView's.
struct ComposerMarkdown: Equatable {
    /// An inline code span: `range` includes its backticks, `code` is between them.
    struct Chip: Equatable {
        let range: NSRange
        let code: NSRange
        var ticks: Int { code.location - range.location }
    }

    let fences: [ComposerFence]
    let chips: [Chip]

    init(_ text: String) {
        fences = ComposerFence.scan(text)
        chips = Self.chips(text, outside: fences)
    }

    /// Inline spans in each line outside the fences: a run of backticks opens, the next run of the same length on the
    /// same line closes; an unclosed run is literal text (CommonMark, restricted to one line).
    static func chips(_ text: String, outside fences: [ComposerFence]) -> [Chip] {
        let source = text as NSString
        var result: [Chip] = []
        var lineStart = 0
        while lineStart <= source.length {
            let newline = source.range(of: "\n", range: NSRange(location: lineStart, length: source.length - lineStart))
            let lineEnd = newline.location == NSNotFound ? source.length : newline.location
            if !fences.contains(where: { NSLocationInRange(lineStart, $0.range) }) {
                result += lineChips(source, from: lineStart, to: lineEnd)
            }
            guard newline.location != NSNotFound else { break }
            lineStart = lineEnd + 1
        }
        return result
    }

    private static let backtick = unichar(UInt8(ascii: "`"))

    private static func lineChips(_ source: NSString, from start: Int, to end: Int) -> [Chip] {
        // Runs of backticks on the line: (location, length).
        var runs: [(location: Int, length: Int)] = []
        var index = start
        while index < end {
            if source.character(at: index) == backtick {
                var length = 0
                while index + length < end, source.character(at: index + length) == backtick { length += 1 }
                runs.append((index, length))
                index += length
            } else { index += 1 }
        }
        var result: [Chip] = []
        var open = 0
        while open < runs.count {
            let opener = runs[open]
            guard let close = runs[(open + 1)...].firstIndex(where: { $0.length == opener.length }) else { open += 1; continue }
            let closer = runs[close]
            let code = NSRange(location: opener.location + opener.length, length: closer.location - opener.location - opener.length)
            if code.length > 0 {
                result.append(Chip(range: NSRange(location: opener.location, length: closer.location + closer.length - opener.location), code: code))
                open = close + 1
            } else { open += 1 }
        }
        return result
    }

    /// The fence whose body or opening line holds `location` (a caret there types code).
    func fence(at location: Int) -> ComposerFence? {
        fences.first { fence in
            location >= fence.opening.location && (fence.closing.map { location <= $0.location } ?? (location <= NSMaxRange(fence.range)))
        }
    }

    /// A caret at `location` types code: inside a fence, inside an inline span, or after a backtick run that is not
    /// closed yet on its line (so autocorrection never rewrites code being typed).
    func isCode(at location: Int, in text: String) -> Bool {
        if fence(at: location) != nil { return true }
        if chips.contains(where: { location > $0.range.location && location < NSMaxRange($0.range) }) { return true }
        let source = text as NSString
        guard location <= source.length else { return false }
        let line = source.lineRange(for: NSRange(location: location, length: 0))
        // Backticks before the caret on its line that no closed span accounts for.
        var index = line.location, open = false
        while index < location {
            if let chip = chips.first(where: { $0.range.location == index }) {
                index = NSMaxRange(chip.range); continue
            }
            if source.character(at: index) == Self.backtick { open = true }
            index += 1
        }
        return open
    }

    /// One edit: replace `range` with `text`, then select `selection`.
    struct Edit: Equatable {
        let range: NSRange
        let text: String
        let selection: NSRange
    }

    /// `pasted` (at `range` of `text`) as a fenced block on lines of its own ("Paste as code").
    static func fenced(_ pasted: String, replacing range: NSRange, in text: String, language: String = "") -> Edit {
        let source = text as NSString
        var body = pasted
        while body.hasSuffix("\n") { body.removeLast() }
        let before = range.location > 0 && source.character(at: range.location - 1) != unichar(10) ? "\n" : ""
        let afterIndex = NSMaxRange(range)
        let after = afterIndex < source.length && source.character(at: afterIndex) != unichar(10) ? "\n" : ""
        let value = before + "```" + language + "\n" + body + "\n```" + after
        let end = range.location + (before + "```" + language + "\n" + body + "\n```").utf16.count
        return Edit(range: range, text: value, selection: NSRange(location: end, length: 0))
    }

    /// Whether pasting `string` offers "Paste as code": several lines, outside code.
    static func offersCode(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n")
    }
}

/// The key row above the keyboard (M5e): the backtick, the fence, braces, parentheses, the arrow and tab.
enum ComposerKey: String, CaseIterable, Identifiable {
    case backtick, fence, braces, parentheses, arrow, tab
    var id: String { rawValue }

    var label: String {
        switch self {
        case .backtick: "`"; case .fence: "```"; case .braces: "{ }"; case .parentheses: "( )"; case .arrow: "=>"; case .tab: "tab"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .backtick: "Backtick"; case .fence: "Code block"; case .braces: "Braces"; case .parentheses: "Parentheses"
        case .arrow: "Arrow"; case .tab: "Indent"
        }
    }

    /// The edit this key makes at `selection` of `text`: pairs wrap a selection and leave the caret inside; the fence
    /// opens a block on lines of its own with the caret on its empty body line (or around the selection).
    func edit(_ text: String, selection: NSRange) -> ComposerMarkdown.Edit {
        let source = text as NSString
        let selected = source.substring(with: selection)
        func wrap(_ open: String, _ close: String) -> ComposerMarkdown.Edit {
            let start = selection.location + open.utf16.count
            return .init(range: selection, text: open + selected + close,
                         selection: NSRange(location: start, length: selection.length))
        }
        switch self {
        case .backtick: return selection.length > 0 ? wrap("`", "`") : wrap("`", "")
        case .braces: return wrap("{", "}")
        case .parentheses: return wrap("(", ")")
        case .arrow: return .init(range: selection, text: "=>", selection: NSRange(location: selection.location + 2, length: 0))
        case .tab: return .init(range: selection, text: "    ", selection: NSRange(location: selection.location + 4, length: 0))
        case .fence:
            let before = selection.location > 0 && source.character(at: selection.location - 1) != unichar(10) ? "\n" : ""
            let afterIndex = NSMaxRange(selection)
            let after = afterIndex < source.length && source.character(at: afterIndex) != unichar(10) ? "\n" : ""
            var body = selected
            while body.hasSuffix("\n") { body.removeLast() }
            let start = selection.location + (before + "```\n").utf16.count
            return .init(range: selection, text: before + "```\n" + body + "\n```" + after,
                         selection: NSRange(location: start, length: body.utf16.count))
        }
    }
}
