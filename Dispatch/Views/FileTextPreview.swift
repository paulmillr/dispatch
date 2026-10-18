import AppKit
import SwiftUI

/// Find in the preview (⌘F while the preview has focus): the query, and which occurrence ⏎ / ⇧⏎ stepped to.
@MainActor @Observable final class FilePreviewFind {
    var open = false
    var query = ""
    /// Index into the occurrences, in reading order.
    var current = 0
    /// Occurrences of the query in the shown text; the text view counts them.
    var total = 0
    /// Bumped by ⏎ / ⇧⏎ so the text scrolls even when the index lands where it was.
    var step = 0

    func next() { move(1) }
    func previous() { move(-1) }

    private func move(_ delta: Int) {
        guard total > 0 else { return }
        current = ((current + delta) % total + total) % total
        step += 1
    }
}

/// The code font's row metrics: the design's 12.5 pt text on 20 pt rows (`.code`, line-height 20px), 1.6 times the
/// text size. The font's own line height is 15 pt there, so a row is never less than that line plus the 2 pt above
/// and below that `CodeDocumentView` rows carry.
@MainActor enum FilePreviewMetrics {
    struct Metrics {
        let lineHeight: CGFloat
        let digitWidth: CGFloat
        /// One unwrapped line's row; a wrapped line adds `lineHeight` per extra line.
        let rowHeight: CGFloat
    }

    private static var cache: [String: Metrics] = [:]

    static func metrics(_ typography: ChatTypography) -> Metrics {
        let key = "\(typography.codeFontName) \(typography.size)"
        if let metrics = cache[key] { return metrics }
        let font = NSFont(name: typography.codeFontName, size: typography.size)
            ?? .monospacedSystemFont(ofSize: typography.size, weight: .regular)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let metrics = Metrics(lineHeight: lineHeight,
                              digitWidth: ("0" as NSString).size(withAttributes: [.font: font]).width,
                              rowHeight: max(lineHeight + 4, (typography.size * 1.6).rounded()))
        cache[key] = metrics
        return metrics
    }
}

/// Lines prepared once per file and theme: split, highlighted when the highlighter takes them, and the find
/// query's occurrences. Rebuilt only when its inputs change, never per frame.
@MainActor final class FileTextLines {
    struct Key: Equatable {
        let owner: ObjectIdentifier
        let count: Int
        let language: String
        let theme: ChatTheme
    }

    /// A displayed line past this many characters is cut: text layout of a megabyte-long line stalls the pane.
    static let lineLimit = 10_000

    private(set) var key: Key?
    private(set) var lines: [String] = []
    /// Nil when the text is plain: an unknown language, or over the highlighter's 65,536-unit cap.
    private(set) var highlighted: [AttributedString]?
    /// Lines over `lineLimit`, already cut, by index: found once per file, not by counting a line on every redraw.
    private(set) var cut: [Int: String] = [:]
    private var query = ""
    private(set) var occurrences: [Int] = []

    func prepare(_ key: Key, text: () -> String) {
        guard key != self.key else { return }
        self.key = key
        // Swift treats "\r\n" as one character, so CRLF text is normalized before it is split or highlighted.
        let source = Self.normalized(text())
        let shown = source.hasSuffix("\n") ? String(source.dropLast()) : source
        lines = Self.split(shown)
        cut = Self.cut(lines)
        let lang = SyntaxHighlight.language(key.language)
        if lang != "text", shown.utf16.count <= 65_536 {
            let colored = SyntaxHighlight.lines(shown, language: key.language, theme: key.theme)
            highlighted = colored.count == lines.count ? colored : nil
        } else {
            highlighted = nil
        }
        query = ""
        occurrences = []
    }

    func prepare(_ key: Key, lines: () -> [String]) {
        guard key != self.key else { return }
        self.key = key
        self.lines = lines()
        cut = Self.cut(self.lines)
        highlighted = nil
        query = ""
        occurrences = []
    }

    /// The line of each occurrence of `query`, case-insensitively, in reading order.
    func occurrences(of query: String) -> [Int] {
        guard query != self.query else { return occurrences }
        self.query = query
        occurrences = Self.occurrences(of: query, in: lines)
        return occurrences
    }

    func attributed(_ index: Int, theme: ChatTheme) -> AttributedString {
        let line = lines[index]
        if line.isEmpty { return AttributedString(" ") }
        let short = cut[index]
        if let highlighted, short == nil { return highlighted[index] }
        var text = AttributedString(short ?? line)
        text.foregroundColor = theme.ink
        return text
    }

    /// The lines past `lineLimit` characters, cut there with " …". A line's UTF-8 length bounds its characters, so
    /// only lines that long in bytes are counted.
    static func cut(_ lines: [String]) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, line) in lines.enumerated() where line.utf8.count > lineLimit && line.count > lineLimit {
            result[index] = String(line.prefix(lineLimit)) + " …"
        }
        return result
    }

    /// Lines without their terminators; a CRLF file shows no stray carriage returns.
    static func split(_ text: String) -> [String] {
        normalized(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func normalized(_ text: String) -> String {
        text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }

    static func occurrences(of query: String, in lines: [String]) -> [Int] {
        guard !query.isEmpty else { return [] }
        var result: [Int] = []
        for (index, line) in lines.enumerated() {
            var start = line.startIndex
            while start < line.endIndex, let range = line.range(of: query, options: .caseInsensitive, range: start..<line.endIndex) {
                result.append(index)
                start = range.upperBound
            }
        }
        return result
    }

    /// A classic hex dump of `data`, 16 bytes a row: offset, two groups of eight, and the printable characters.
    static func hexLines(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        let digits = Array("0123456789abcdef")
        var result: [String] = []
        result.reserveCapacity(bytes.count / 16 + 1)
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var line = String(format: "%08x ", offset)
            for column in 0..<16 {
                if column == 8 { line.append(" ") }
                if column < row.count {
                    let byte = row[row.startIndex + column]
                    line.append(" ")
                    line.append(digits[Int(byte >> 4)])
                    line.append(digits[Int(byte & 0x0F)])
                } else {
                    line.append("   ")
                }
            }
            line.append("  |")
            for byte in row { line.append((0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : ".") }
            line.append("|")
            result.append(line)
            offset += 16
        }
        return result
    }
}

/// Line-numbered, lazily drawn text in the chat theme's palette, as `CodeDocumentView` draws Read results, so chat
/// and files never disagree. Wrap off scrolls sideways; wrap on soft-wraps at the pane's width.
struct FileTextPreview: View {
    enum Content {
        case text(String, language: String)
        /// Prepared lines drawn plain (a hex dump), without line numbers.
        case lines([String])
    }

    @Environment(\.chatTheme) private var theme
    let owner: ObjectIdentifier
    let content: Content
    let wrap: Bool
    var find: FilePreviewFind?
    /// Whether the query highlights (the find field is open).
    var highlightsQuery = true
    @State private var model = FileTextLines()

    var body: some View {
        let metrics = FilePreviewMetrics.metrics(theme.typography)
        let numbered: Bool
        switch content {
        case .text(let text, let language):
            model.prepare(.init(owner: owner, count: text.utf8.count, language: language, theme: theme)) { text }
            numbered = true
        case .lines(let lines):
            model.prepare(.init(owner: owner, count: lines.count, language: "text", theme: theme)) { lines }
            numbered = false
        }
        let query = highlightsQuery ? (find?.query ?? "") : ""
        let occurrences = model.occurrences(of: query)
        let currentLine = find.flatMap { find in
            occurrences.indices.contains(find.current) ? occurrences[find.current] : nil
        }
        let gutter = CGFloat(max(2, String(model.lines.count).count)) * metrics.digitWidth
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(wrap ? .vertical : [.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Row identities are the line indexes: since macOS 27, scrollTo matches only ForEach identities.
                        ForEach(0..<model.lines.count, id: \.self) { index in
                            row(index, numbered: numbered, gutter: gutter, query: query, current: index == currentLine,
                                width: geometry.size.width, metrics: metrics)
                        }
                    }
                    .padding(.vertical, 10)
                    // At least the pane's height, from the top: a two-axis scroll view centres content smaller than
                    // itself, which drew a short file in the middle of the pane.
                    .frame(minWidth: wrap ? nil : geometry.size.width, minHeight: geometry.size.height,
                           alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        if numbered {
                            Rectangle().fill(theme.border).frame(width: 1)
                                .padding(.leading, 14 + gutter + 10)
                        }
                    }
                }
                .onChange(of: find?.step) { scroll(proxy, to: currentLine) }
                .onChange(of: query) { scroll(proxy, to: currentLine) }
            }
            .onChange(of: occurrences.count, initial: true) {
                guard let find else { return }
                if find.total != occurrences.count { find.total = occurrences.count }
                if find.current >= occurrences.count, find.current != 0 { find.current = 0 }
            }
        }
        .font(theme.typography.codeFont())
        .accessibilityIdentifier("file-preview-text")
    }

    private func row(_ index: Int, numbered: Bool, gutter: CGFloat, query: String, current: Bool, width: CGFloat,
                     metrics: FilePreviewMetrics.Metrics) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if numbered {
                Text(verbatim: String(index + 1)).foregroundStyle(theme.muted)
                    .frame(width: gutter, alignment: .trailing)
                    .padding(.trailing, 10 + 14)
            }
            Text(ChatSearchHighlight.text(model.attributed(index, theme: theme), query: query, theme: theme))
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wrap, vertical: true)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
            if !wrap { Spacer(minLength: 0) }
        }
        // The line sits centred in its row: 2.5 pt above and below 15 pt text on a 20 pt row.
        .padding(.vertical, (metrics.rowHeight - metrics.lineHeight) / 2)
        .frame(minHeight: metrics.rowHeight, alignment: .topLeading)
        .padding(.horizontal, 14)
        .frame(minWidth: wrap ? nil : width, maxWidth: wrap ? width : nil, alignment: .leading)
        .background(current ? theme.yellow.opacity(0.18) : .clear)
        .accessibilityIdentifier("file-preview-line-\(index + 1)")
    }

    private func scroll(_ proxy: ScrollViewProxy, to line: Int?) {
        guard let line else { return }
        proxy.scrollTo(line, anchor: .center)
    }
}
