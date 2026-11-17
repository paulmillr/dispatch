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
    nonisolated static let lineLimit = 10_000
    /// A small, newline-heavy file can otherwise create millions of Swift strings and view rows.
    static let linesLimit = 100_000
    /// Find stores one row index per match. Bound that independent of the file byte limit.
    static let occurrencesLimit = 100_000
    static let truncatedLine = "… preview truncated after 100,000 lines …"

    private(set) var key: Key?
    private(set) var lines: [String] = []
    /// Nil when the text is plain: an unknown language, or over the highlighter's 65,536-unit cap.
    private(set) var highlighted: [AttributedString]?
    /// Lines over `lineLimit`, already cut, by index: found once per file, not by counting a line on every redraw.
    private(set) var cut: [Int: String] = [:]
    private var query = ""
    private(set) var occurrences: [Int] = []

    /// The whole text as the view shows it, one attributed string, and where each line starts in it (UTF-16).
    final class Document {
        let text: NSAttributedString
        let lineStarts: [Int]
        init(text: NSAttributedString, lineStarts: [Int]) { self.text = text; self.lineStarts = lineStarts }
    }
    private var built: Document?

    /// The code font as AppKit draws it, ligatures as Settings has them.
    static func font(_ typography: ChatTypography) -> NSFont {
        typography.unligated(typography.codeFontName, typography.size)
            ?? NSFont(name: typography.codeFontName, size: typography.size)
            ?? .monospacedSystemFont(ofSize: typography.size, weight: .regular)
    }

    /// The prepared lines joined into one text, each line in its row (the preview's metrics) and its syntax colours;
    /// built once per file and theme. Cut lines keep their " …", and nothing hidden is in it (`prepare`).
    func document(theme: ChatTheme, metrics: FilePreviewMetrics.Metrics) -> Document {
        if let built { return built }
        let font = Self.font(theme.typography)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = metrics.rowHeight
        paragraph.maximumLineHeight = metrics.rowHeight
        let ink = NSColor(theme.ink)
        // The row's spare height above the text as below it, as the rows centred their line.
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph,
                                                   .baselineOffset: (metrics.rowHeight - metrics.lineHeight) / 2]
        let result = NSMutableAttributedString()
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        result.beginEditing()
        for index in lines.indices {
            starts.append(result.length)
            if let highlighted, cut[index] == nil {
                for run in highlighted[index].runs {
                    var attributes = base
                    if let color = run.swiftUI.foregroundColor { attributes[.foregroundColor] = NSColor(color) }
                    result.append(NSAttributedString(string: String(highlighted[index][run.range].characters), attributes: attributes))
                }
            } else {
                result.append(NSAttributedString(string: cut[index] ?? lines[index], attributes: base))
            }
            if index < lines.count - 1 { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }
        result.endEditing()
        let document = Document(text: result, lineStarts: starts.isEmpty ? [0] : starts)
        built = document
        return document
    }

    /// Where `query` occurs in `text`, case-insensitively, in reading order; at most `occurrencesLimit`.
    static func matches(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let string = text as NSString
        var result: [NSRange] = []
        var start = 0
        while start < string.length, result.count < occurrencesLimit {
            let found = string.range(of: query, options: .caseInsensitive, range: NSRange(location: start, length: string.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            start = NSMaxRange(found)
        }
        return result
    }

    func prepare(_ key: Key, text: () -> String) {
        guard key != self.key else { return }
        self.key = key
        built = nil
        // Swift treats "\r\n" as one character, so CRLF text is normalized before it is split or highlighted.
        let source = TextRendering.visible(Self.normalized(text()))
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

    /// The lines past `lineLimit` scalars, cut there with " …". Scalar iteration also bounds a single extended
    /// grapheme made from an adversarial number of combining marks.
    static func cut(_ lines: [String]) -> [Int: String] {
        var result: [Int: String] = [:]
        for (index, line) in lines.enumerated() where line.utf8.count > lineLimit {
            let bounded = TextRendering.prefix(line, scalars: lineLimit)
            if bounded.truncated { result[index] = bounded.text + " …" }
        }
        return result
    }

    /// Lines without their terminators; a CRLF file shows no stray carriage returns.
    static func split(_ text: String) -> [String] {
        let text = normalized(text)
        var result: [String] = []
        result.reserveCapacity(min(linesLimit, 1_024))
        var start = text.startIndex
        while let newline = text[start...].firstIndex(of: "\n") {
            result.append(String(text[start..<newline]))
            start = text.index(after: newline)
            if result.count == linesLimit {
                result[result.index(before: result.endIndex)] = truncatedLine
                return result
            }
        }
        result.append(String(text[start...]))
        return result
    }

    static func normalized(_ text: String) -> String {
        text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
    }

    static func occurrences(of query: String, in lines: [String]) -> [Int] {
        TextOccurrences.scan(of: query, in: lines, limit: occurrencesLimit).map(\.line)
    }
}

/// Line-numbered, lazily drawn text in the chat theme's palette, as `CodeDocumentView` draws Read results, so chat
/// and files never disagree. Wrap off scrolls sideways; wrap on soft-wraps at the pane's width.
struct FileTextPreview: View {
    enum Content {
        case text(String, language: String)
    }

    @Environment(\.chatTheme) private var theme
    let owner: ObjectIdentifier
    let content: Content
    let wrap: Bool
    /// Text's line numbers (Settings › Files).
    var lineNumbers = true
    var find: FilePreviewFind?
    /// Whether the query highlights (the find field is open).
    var highlightsQuery = true
    /// Keeps the scroll while the view goes and comes back.
    var keeper: FilePreviewScrollKeeper?
    /// The text has the keyboard, or gave it up (the pane's focus follows).
    var focusChanged: (Bool) -> Void = { _ in }
    /// The pane asks the text for the keyboard.
    var wantsFocus = false
    /// Esc in the text: true when the pane took it.
    var escape: () -> Bool = { false }
    @State private var model = FileTextLines()

    var body: some View {
        let metrics = FilePreviewMetrics.metrics(theme.typography)
        switch content {
        case .text(let text, let language):
            model.prepare(.init(owner: owner, count: text.utf8.count, language: language, theme: theme)) { text }
        }
        let query = highlightsQuery ? (find?.query ?? "") : ""
        return FileTextDocument(document: model.document(theme: theme, metrics: metrics), theme: theme, metrics: metrics,
                                wrap: wrap, lineNumbers: lineNumbers, query: query, current: find?.current ?? 0,
                                step: find?.step ?? 0, keeper: keeper, focusChanged: focusChanged, wantsFocus: wantsFocus,
                                escape: escape) { count in
            guard let find else { return }
            // After this update: find's count is SwiftUI state.
            DispatchQueue.main.async {
                if find.total != count { find.total = count }
                if find.current >= count, find.current != 0 { find.current = 0 }
            }
        }
        .accessibilityIdentifier("file-preview-text")
    }
}

/// Keeps a preview's scroll while its view goes and comes back (the split showing another tab, the pane hiding or
/// collapsing): the clip's origin, by view, on the file's state (`FilePreviewState.scroll`), so the file shows where
/// the reader left it. Set in the scroll view's content, whose enclosing `NSScrollView` it watches. The origin goes
/// back once the document is tall (and wide) enough to hold it, at most a second after the view returns; a scroll by
/// the reader first wins.
struct FilePreviewScrollKeeper: NSViewRepresentable {
    enum Key: Hashable {
        /// The text with line numbers, Markdown's source included.
        case text
        /// Rendered Markdown.
        case rendered
        /// The first 64 KB of text too large to show.
        case head
    }

    let preview: FilePreviewState
    let key: Key

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.preview = preview
        probe.key = key
    }

    final class Probe: NSView {
        weak var preview: FilePreviewState?
        var key = Key.text
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        /// The origin to go back to, until the document holds it or the reader scrolls.
        private var pending: CGPoint?
        private var deadline: TimeInterval = 0

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // Before the view goes: the teardown's own clip moves are not the reader's.
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let scroll = enclosingScrollView, scroll !== self.scroll else { return }
            stop()
            self.scroll = scroll
            if let saved = preview?.scroll[key], saved != .zero {
                pending = saved
                deadline = ProcessInfo.processInfo.systemUptime + 1
            }
            let center = NotificationCenter.default
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipMoved() }
            })
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pending = nil }
            })
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document,
                                                    queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.restore() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.restore() }
        }

        private func clipMoved() {
            guard let scroll else { return }
            if pending != nil {
                restore()
                return
            }
            preview?.scroll[key] = scroll.contentView.bounds.origin
        }

        /// Puts the saved origin back once the document can hold it; gives up after the deadline.
        private func restore() {
            guard let target = pending, let scroll, let document = scroll.documentView else { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                pending = nil
                return
            }
            let clip = scroll.contentView.bounds.size
            guard document.frame.height - clip.height >= target.y - 0.5,
                  document.frame.width - clip.width >= target.x - 0.5 else { return }
            pending = nil
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
            preview?.scroll[key] = target
        }

        private func stop() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            scroll = nil
            pending = nil
        }
    }
}

