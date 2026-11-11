import Foundation

/// A Markdown file as Files' rendered preview reads it (`FileMarkdownView`): chat's blocks (`ChatMarkdownBlock`), set
/// as a document rather than a message. A message keeps its line breaks, which an agent means; a file is
/// hard-wrapped by whoever wrote it (this repository's docs at 120 columns), so here:
///
/// - a paragraph's lines flow into one (two spaces or a backslash at a line's end still break it);
/// - an indented line after a list item continues the item;
/// - a quote's lines are one quote, its paragraphs kept apart;
/// - lines indented four spaces are code, and a line of `=` under a paragraph makes it a heading;
/// - YAML front matter is a `yaml` block, not a rule and a paragraph.
///
/// The parser drops blank lines, so an item's second paragraph joins its first, and a line continuing an item without
/// its indent stays a paragraph. The headings are the outline, and what folds.
struct FileMarkdownDocument: Equatable {
    struct Heading: Equatable, Identifiable {
        /// Its level, title and which of the headings alike it is: a fold stays with its section while the file
        /// changes elsewhere.
        let id: String
        /// Index into `blocks`.
        let block: Int
        let level: Int
        /// The title without its inline markup.
        let title: String
        /// How many headings' sections it is in: the outline's indent.
        let depth: Int
        /// One past its section's last block: the next heading of its level or above, or the end.
        let end: Int
        /// It has a section to fold.
        var foldable: Bool { end > block + 1 }
    }

    let blocks: [ChatMarkdownBlock]
    let headings: [Heading]
    /// The file is longer than what renders (`TextRendering.rich`): its source shows all of it.
    let truncated: Bool

    init(_ text: String) {
        let rich = TextRendering.rich(text)
        let parts = Self.frontMatter(rich.text)
        var blocks = parts.yaml.map { [ChatMarkdownBlock(kind: .code("yaml"), text: $0)] } ?? []
        blocks += Self.flowed(ChatMarkdownBlock.parse(parts.body))
        self.blocks = blocks
        headings = Self.headings(blocks)
        truncated = rich.truncated
    }

    // MARK: Folding

    /// The blocks inside folded sections: a folded heading shows, its section does not.
    func hidden(folded: Set<String>) -> IndexSet {
        var hidden = IndexSet()
        for heading in headings where heading.foldable && folded.contains(heading.id) {
            hidden.insert(integersIn: (heading.block + 1)..<heading.end)
        }
        return hidden
    }

    /// The blocks that show, in order. A search reads the whole file: what it finds in a folded section shows.
    func shown(folded: Set<String>, searching: Bool) -> [Int] {
        guard !searching else { return Array(blocks.indices) }
        let hidden = hidden(folded: folded)
        return blocks.indices.filter { !hidden.contains($0) }
    }

    /// The headings whose sections `heading` is in, outermost first.
    func ancestors(of heading: Heading) -> [Heading] {
        headings.filter { $0.block < heading.block && $0.end > heading.block }
    }

    /// `folded` with the sections around `heading` open, so it shows.
    func revealing(_ heading: Heading, in folded: Set<String>) -> Set<String> {
        folded.subtracting(ancestors(of: heading).map(\.id))
    }

    /// Fold All: every section folded but a heading that is alone at its level (a file's title, over everything),
    /// which stays open so the headings under it show. Unfolding one then shows its own, still folded.
    var allFolded: Set<String> {
        var open: Set<String> = []
        var siblings = headings.filter { $0.depth == 0 }
        while siblings.count == 1, let only = siblings.first {
            let children = headings.filter { $0.depth == only.depth + 1 && $0.block > only.block && $0.block < only.end }
            guard !children.isEmpty else { break }
            open.insert(only.id)
            siblings = children
        }
        return Set(headings.filter { $0.foldable && !open.contains($0.id) }.map(\.id))
    }

    /// The sections of `folded` this file has: ids of headings since renamed or removed fold nothing.
    func folds(in folded: Set<String>) -> Set<String> {
        Set(headings.filter { $0.foldable && folded.contains($0.id) }.map(\.id))
    }

    // MARK: Reading the file

    /// YAML front matter: a first line of `---`, a `key:` (or a comment) right under it, up to the next line of `---`
    /// or `...`. A file that only opens with a rule keeps its rule.
    static func frontMatter(_ text: String) -> (yaml: String?, body: String) {
        guard text.hasPrefix("---\n") else { return (nil, text) }
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 2, lines[1].range(of: #"^(?:[A-Za-z_][A-Za-z0-9_. -]*:|#)"#, options: .regularExpression) != nil,
              let close = lines.indices.dropFirst().first(where: {
                  let line = lines[$0].trimmingCharacters(in: .whitespaces)
                  return line == "---" || line == "..."
              }) else { return (nil, text) }
        return (lines[1..<close].joined(separator: "\n"), lines[(close + 1)...].joined(separator: "\n"))
    }

    /// The parsed blocks as a document flows them (see the type).
    static func flowed(_ parsed: [ChatMarkdownBlock]) -> [ChatMarkdownBlock] {
        var blocks: [ChatMarkdownBlock] = []
        /// The lines of the quote being gathered.
        var quoted: [String]?
        func endQuote() {
            guard let lines = quoted else { return }
            quoted = nil
            blocks.append(.init(kind: .quote, text: quote(lines)))
        }
        for block in parsed {
            if block.kind == .quote {
                quoted = (quoted ?? []) + [block.text]
                continue
            }
            endQuote()
            switch block.kind {
            case .heading(let level):
                blocks.append(.init(kind: .heading(level), text: unclosed(block.text)))
            case .paragraph:
                let lines = block.text.components(separatedBy: "\n")
                if let last = blocks.last, case .list = last.kind, indented(lines[0], by: 2) {
                    blocks[blocks.count - 1] = .init(kind: last.kind, text: flow([last.text] + lines))
                } else if lines.allSatisfy({ indented($0, by: 4) }) {
                    blocks.append(.init(kind: .code("text"), text: lines.map(outdented).joined(separator: "\n")))
                } else if lines.count > 1, let under = lines.last?.trimmingCharacters(in: .whitespaces), !under.isEmpty,
                          under.allSatisfy({ $0 == "=" }) {
                    blocks.append(.init(kind: .heading(1), text: flow(Array(lines.dropLast()))))
                } else {
                    blocks.append(.init(kind: .paragraph, text: flow(lines)))
                }
            default:
                blocks.append(block)
            }
        }
        endQuote()
        return blocks
    }

    /// A heading without the `#`s some files close it with (`## Title ##`).
    private static func unclosed(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(closing) }
        return text
    }

    /// One paragraph's lines as one flowing text: a line break in the source is a space, and a line ending in two
    /// spaces or a backslash breaks there (Markdown's hard break).
    static func flow(_ lines: [String]) -> String {
        var text = "", breaks = false
        for (index, source) in lines.enumerated() {
            var line = String(source.drop { $0 == " " || $0 == "\t" })
            let hard = line.hasSuffix("  ") || (line.hasSuffix("\\") && !line.hasSuffix("\\\\"))
            if hard, line.hasSuffix("\\") { line.removeLast() }
            while let last = line.last, last == " " || last == "\t" { line.removeLast() }
            if index > 0 { text += breaks ? "\n" : " " }
            text += line
            breaks = hard
        }
        return text
    }

    /// A quote's lines: its paragraphs (an empty `>` line between them) each flowed, a blank line apart. A line that
    /// starts a block of its own (a list item, a heading, a quote inside, a fence, a table's row) keeps its line, and
    /// so does a callout's `[!NOTE]`.
    private static func quote(_ lines: [String]) -> String {
        var paragraphs: [String] = [], current: [String] = []
        func end() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")); current = [] }
        }
        var open: [String] = []
        func close() {
            if !open.isEmpty { current.append(flow(open)); open = [] }
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                close(); end()
            } else if trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] |#{1,6} |>|```|~~~|\|)"#, options: .regularExpression) != nil {
                close(); current.append(trimmed)
            } else if trimmed.range(of: #"^\[![A-Za-z]+\]"#, options: .regularExpression) != nil {
                close(); current.append(trimmed)
            } else {
                open.append(line)
            }
        }
        close(); end()
        return paragraphs.joined(separator: "\n\n")
    }

    private static func indented(_ line: String, by spaces: Int) -> Bool {
        line.hasPrefix("\t") || line.hasPrefix(String(repeating: " ", count: spaces))
    }

    /// An indented code line without its four spaces (or tab).
    private static func outdented(_ line: String) -> String {
        line.hasPrefix("\t") ? String(line.dropFirst()) : String(line.dropFirst(4))
    }

    private static func headings(_ blocks: [ChatMarkdownBlock]) -> [Heading] {
        let found: [(block: Int, level: Int, title: String)] = blocks.enumerated().compactMap { index, block in
            guard case .heading(let level) = block.kind else { return nil }
            return (index, level, title(block.text))
        }
        var seen: [String: Int] = [:]
        /// The levels of the headings around the one being read.
        var open: [Int] = []
        return found.enumerated().map { index, heading in
            let key = "\(heading.level) \(heading.title)"
            let earlier = seen[key, default: 0]
            seen[key] = earlier + 1
            while let last = open.last, last >= heading.level { open.removeLast() }
            let depth = open.count
            open.append(heading.level)
            let end = found[(index + 1)...].first { $0.level <= heading.level }?.block ?? blocks.count
            return Heading(id: earlier == 0 ? key : "\(key) #\(earlier + 1)", block: heading.block, level: heading.level,
                           title: heading.title, depth: depth, end: end)
        }
    }

    /// A heading's words, without its inline markup.
    static func title(_ text: String) -> String {
        let value = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return value.map { String($0.characters) } ?? text
    }
}

/// How a rendered Markdown file is set on the Mac (`FileMarkdownStyle`) and the phone (`FileMarkdownReader`) alike: the
/// column's measure, the six heading sizes and the space between blocks, all in shares of the prose's size.
enum FileMarkdownLayout {
    /// The column's widest, in ems of the prose: about 80 characters a line.
    static let ems: CGFloat = 36
    /// Each level's size as a share of the prose's: six sizes, the sixth also muted.
    static let headingScale: [CGFloat] = [1.75, 1.45, 1.22, 1.1, 1, 0.92]

    /// A heading's share of the prose's size, for `level` (clamped to the six).
    static func headingShare(_ level: Int) -> CGFloat { headingScale[min(max(level, 1), headingScale.count) - 1] }

    /// The space above a block, after the one shown before it: most above a heading, less under it than above it, a
    /// list's items close together. A heading right under another is its subtitle and sits close; under a folded one
    /// (`afterFolded`) it is the next section, a line away.
    static func gap(before kind: ChatMarkdownBlock.Kind, after previous: ChatMarkdownBlock.Kind?, afterFolded: Bool = false,
                    size: CGFloat) -> CGFloat {
        guard let previous else { return 0 }
        let ems: CGFloat
        switch (previous, kind) {
        case _ where afterFolded: ems = 1.1
        case (.heading, .heading): ems = 0.7
        case (_, .heading(let level)): ems = level == 1 ? 2 : level == 2 ? 1.8 : level == 3 ? 1.5 : 1.3
        case (.heading(let level), _): ems = level <= 2 ? 0.65 : 0.5
        case (.list, .list): ems = 0.3
        default: ems = 0.8
        }
        return (size * ems).rounded()
    }
}

/// The documents of the files shown, by their text: the header's outline and the body read the same one, and a hover
/// or a fold does not parse the file again. A few, for the panes showing Markdown side by side.
@MainActor enum FileMarkdownDocuments {
    private static var recent: [(text: String, document: FileMarkdownDocument)] = []
    static let limit = 4
    /// Files parsed, for tests.
    private(set) static var parses = 0

    static func document(_ text: String) -> FileMarkdownDocument {
        if let index = recent.firstIndex(where: { $0.text == text }) { return recent[index].document }
        parses += 1
        let document = FileMarkdownDocument(text)
        if recent.count >= limit { recent.removeFirst() }
        recent.append((text, document))
        return document
    }
}
