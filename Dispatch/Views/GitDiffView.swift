import AppKit
import SwiftUI

/// One file's diff in the chat tool cards' style: Diff / Source, two line-number gutters, blue hunk headers, folds
/// for unmodified runs, syntax colour over the add and remove tints (F3a). The Changes and Commits tabs share it.
///
/// Source shows the whole file when the caller can read it (`source`: the Changes tab reads the working tree through
/// `FilesSource.read`); without a reader it shows the new side as far as the diff holds it, numbered as in the file,
/// with a row for each stretch the diff leaves out (a commit's version of a file is not readable through `files.git`).
/// The same reader fills the lines git leaves out between hunks when one of those rows is opened.
struct GitDiffView: View {
    let diff: GitDiff
    @Binding var mode: GitDiffMode
    /// The status letter beside the path; nil draws none.
    var kind: GitChangeKind?
    /// The meta line's first words: "unstaged", "staged", "untracked", a commit's short hash.
    var label: String?
    /// Reads the file Source shows, as text; nil shows the diff's new side.
    var source: (@Sendable () async throws -> String)?
    /// Bumped to give the diff the keyboard (⏎ in the Changes list).
    var focusRequest: UUID?
    /// esc while the diff has the keyboard: the caller's list takes it back.
    var onEscape: (() -> Void)?

    @Environment(\.chatTheme) private var theme
    @State private var model = GitDiffLines()
    @State private var opened: Set<Int> = []
    /// The `Gap.hunk` of every gap between hunks the user opened; its lines show once the file is read.
    @State private var openedGaps: Set<Int> = []
    @State private var allOpen = false
    @State private var loaded: GitSourceText?
    @State private var cursor: Int?
    @FocusState private var focused: Bool

    private struct SourceKey: Equatable {
        let reading: Bool
        let path: String
        /// The diff changes when the file does: the text is read again.
        let text: String
    }

    var body: some View {
        model.prepare(diff, theme: theme)
        let rows = displayRows
        // Source reads the file; so does Diff once a gap between hunks is opened (its lines are the file's).
        let wantsGaps = !model.presentation.gaps.isEmpty && (allOpen || !openedGaps.isEmpty)
        let key = SourceKey(reading: (mode == .source || wantsGaps) && source != nil && !isBinary, path: diff.path,
                            text: diff.text)
        return VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border).frame(height: 1)
            content(rows)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.terminal)
        .task(id: key) {
            guard key.reading, let source else { return }
            if loaded?.path != diff.path { loaded = GitSourceText(path: diff.path, state: .loading) }
            let state: GitSourceText.State
            do { state = .text(try await source()) } catch is CancellationError { return } catch {
                state = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            loaded = GitSourceText(path: diff.path, state: state)
        }
        .onChange(of: diff.path) {
            opened = []
            openedGaps = []
            allOpen = false
            cursor = nil
        }
        .onChange(of: mode) { cursor = nil }
        .onChange(of: focusRequest) { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-diff")
    }

    private var isBinary: Bool { diff.binary || model.presentation.binary }

    /// The read file, when it is this diff's.
    private var sourceText: String? {
        guard let loaded, loaded.path == diff.path, case .text(let text) = loaded.state else { return nil }
        return text
    }

    // MARK: Header

    private var header: some View {
        let presentation = model.presentation
        let title = diff.oldPath.map { $0 == diff.path ? diff.path : "\($0) → \(diff.path)" } ?? diff.path
        let meta = isBinary ? [label, GitChangesText.binary(old: diff.oldSize, new: diff.newSize, kind: kind)]
            .compactMap { $0 }.joined(separator: " · ")
            : GitChangesText.meta(label: label, additions: presentation.additions, deletions: presentation.deletions,
                                  hunks: presentation.hunks.count)
        return HStack(spacing: 10) {
            if let kind { GitChangeBadge(kind: kind, side: 18, corner: 4) }
            Text(verbatim: title)
                .font(theme.typography.font())
                .foregroundStyle(theme.ink)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
                .accessibilityIdentifier("git-diff-path")
            Text(verbatim: meta)
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("git-diff-meta")
            GitDiffModePicker(mode: $mode)
            Button(action: copy) {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(FilePreviewIconButtonStyle(on: false))
            .help(mode == .diff ? "Copy diff" : "Copy source")
            .accessibilityLabel(mode == .diff ? "Copy diff" : "Copy source")
            .accessibilityIdentifier("git-diff-copy")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-diff-header")
    }

    private func copy() {
        GitPasteboard.copy(mode == .diff ? diff.text : sourceText ?? model.newSide.joined(separator: "\n"))
    }

    // MARK: Body

    /// What the scroll view lists, by mode: the diff's rows, the read file's lines, or the diff's new side.
    private var displayRows: [GitDiffDisplayRow] {
        guard !isBinary else { return [] }
        if mode == .diff {
            let lines = sourceText.map { model.sourceLineCount($0, theme: theme) }
            return model.diffRows(opened: opened, allOpen: allOpen, openedGaps: openedGaps, sourceLines: lines,
                                  truncated: diff.truncated)
        }
        if source == nil { return model.newSideRows(truncated: diff.truncated) }
        if let sourceText { return model.sourceRows(sourceText, theme: theme) }
        return []
    }

    @ViewBuilder private func content(_ rows: [GitDiffDisplayRow]) -> some View {
        if isBinary {
            notice(GitChangesText.binary(old: diff.oldSize, new: diff.newSize, kind: kind), identifier: "git-diff-binary")
        } else if mode == .source, source != nil, loaded?.path != diff.path || loaded?.isLoading == true {
            GitDelayedSpinner()
        } else if mode == .source, source != nil, let loaded, case .failed(let message) = loaded.state {
            notice(message, identifier: "git-diff-source-error")
        } else if rows.isEmpty || (mode == .diff && model.presentation.hunks.isEmpty) {
            if mode == .source {
                notice(GitChangesText.emptySource(model.presentation, kind: kind, read: source != nil),
                       identifier: "git-diff-empty")
            } else {
                notice(model.presentation.notes.isEmpty ? "No changes to the file’s text"
                       : model.presentation.notes.joined(separator: "\n"), identifier: "git-diff-empty")
            }
        } else {
            rowsView(rows)
        }
    }

    private func notice(_ text: String, identifier: String) -> some View {
        Text(verbatim: text)
            .font(theme.typography.font(offset: -1))
            .foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(identifier)
    }

    private func rowsView(_ rows: [GitDiffDisplayRow]) -> some View {
        let metrics = FilePreviewMetrics.metrics(theme.typography)
        let whole = mode == .source && sourceText != nil
        let single = mode == .source
        let gutter = Self.gutterWidth(digits: model.digits(source: whole),
                                      digitWidth: metrics.digitWidth * (theme.typography.size - 1.5) / theme.typography.size)
        let codeLeading = single ? 14 + gutter + 10 + 14 : gutter * 2 + 14
        // Opened gaps draw the read file's lines among the diff's: the widest of either sets the width.
        let gapLines = !single && rows.contains { if case .diff(.gapLine) = $0 { return true }; return false }
        let widest = gapLines ? max(model.widest(source: false), model.widest(source: true)) : model.widest(source: whole)
        let contentWidth = codeLeading + CGFloat(widest) * metrics.digitWidth + 14
        return GeometryReader { geometry in
            // Every row as wide as the widest line, so the tints run the whole width when scrolled sideways (the code
            // font is monospaced: characters times the digit's advance).
            let width = max(geometry.size.width, contentWidth.rounded(.up))
            let page = max(1, Int(geometry.size.height / metrics.rowHeight) - 2)
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.self) { row in
                            self.row(row, gutter: gutter, width: width, metrics: metrics)
                                .background(focused && cursorRow(rows) == row ? theme.ink.opacity(0.06) : .clear)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    // At least the pane's height, from the top: a two-axis scroll view centres smaller content.
                    .frame(minWidth: width, minHeight: geometry.size.height, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        if single {
                            Rectangle().fill(theme.border).frame(width: 1).padding(.leading, 14 + gutter + 10)
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.downArrow) { move(1, rows, proxy) }
                .onKeyPress(.upArrow) { move(-1, rows, proxy) }
                .onKeyPress(.pageDown) { move(page, rows, proxy) }
                .onKeyPress(.pageUp) { move(-page, rows, proxy) }
                .onKeyPress(.home) { move(-rows.count, rows, proxy) }
                .onKeyPress(.end) { move(rows.count, rows, proxy) }
                .onKeyPress(.return) { openFold(at: cursorRow(rows)) }
                .onKeyPress(.space) { openFold(at: cursorRow(rows)) }
                .onKeyPress(.escape) {
                    guard let onEscape else { return .ignored }
                    onEscape()
                    return .handled
                }
            }
        }
        .font(theme.typography.codeFont())
        .accessibilityIdentifier("git-diff-rows")
    }

    /// A gutter at 11 pt: the design's 34 pt, wider only for line numbers past four digits.
    static func gutterWidth(digits: Int, digitWidth: CGFloat) -> CGFloat {
        max(34, (CGFloat(digits) * digitWidth + 12).rounded(.up))
    }

    private func cursorRow(_ rows: [GitDiffDisplayRow]) -> GitDiffDisplayRow? {
        guard let cursor, rows.indices.contains(cursor) else { return nil }
        return rows[cursor]
    }

    /// The keyboard's row in the focused diff: ↑↓, page up and down, home and end move it and scroll it into view.
    private func move(_ delta: Int, _ rows: [GitDiffDisplayRow], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let next = min(max((cursor ?? (delta > 0 ? -1 : rows.count)) + delta, 0), rows.count - 1)
        cursor = next
        proxy.scrollTo(rows[next])
        return .handled
    }

    private func openFold(at row: GitDiffDisplayRow?) -> KeyPress.Result {
        switch row {
        case .diff(.fold(let start, _))?:
            open(start, all: NSEvent.modifierFlags.contains(.option))
        case .diff(.gap(let hunk, _))? where source != nil:
            openGap(hunk, all: NSEvent.modifierFlags.contains(.option))
        default:
            return .ignored
        }
        return .handled
    }

    private func open(_ start: Int, all: Bool) {
        if all { allOpen = true } else { opened.insert(start) }
    }

    /// Opening a gap asks for the file when it is not read yet (the source task runs once a gap is open); its lines
    /// replace the row when the text arrives.
    private func openGap(_ hunk: Int, all: Bool) {
        if all { allOpen = true } else { openedGaps.insert(hunk) }
    }

    /// The gap's row: a button that fills it from the file when there is a reader, else a line saying what git left
    /// out (a commit's file is not readable here).
    @ViewBuilder private func gapRow(_ hunk: Int, count: Int, width: CGFloat) -> some View {
        let label = HStack(spacing: 8) {
            if source != nil { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
            Text(verbatim: GitChangesText.unmodified(count))
            if source != nil, allOpen || openedGaps.contains(hunk), let loaded, loaded.path == diff.path,
               case .failed(let message) = loaded.state {
                Text(verbatim: "· \(message)").foregroundStyle(theme.yellow)
            }
        }
        .font(theme.typography.font(offset: -1.5))
        .foregroundStyle(theme.muted)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(minWidth: width, minHeight: 22, maxHeight: 22, alignment: .leading)
        .background(Chrome.window)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .contentShape(Rectangle())
        if source != nil {
            Button { openGap(hunk, all: NSEvent.modifierFlags.contains(.option)) } label: { label }
                .buttonStyle(.plain)
                .help("Show the \(FilesFormatting.count(count)) lines from the file · ⌥-click shows every fold")
                .accessibilityIdentifier("git-diff-gap-\(hunk)")
        } else {
            label
                .help("Lines git left out of the diff")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("git-diff-gap-\(hunk)")
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ row: GitDiffDisplayRow, gutter: CGFloat, width: CGFloat,
                                  metrics: FilePreviewMetrics.Metrics) -> some View {
        switch row {
        case .diff(.hunk(let index)):
            let hunk = model.presentation.hunks[index]
            HStack(spacing: 10) {
                Text(verbatim: hunk.range).foregroundStyle(theme.blue)
                if !hunk.section.isEmpty { Text(verbatim: hunk.section).foregroundStyle(theme.muted) }
            }
            .font(theme.typography.codeFont(offset: -1))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .frame(minWidth: width, minHeight: 22, maxHeight: 22, alignment: .leading)
            .background(theme.blue.opacity(0.07))
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("git-diff-hunk-\(index)")
        case .diff(.line(let index)):
            diffLine(index, gutter: gutter, width: width, metrics: metrics)
        case .diff(.fold(let start, let count)):
            Button {
                open(start, all: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    Text(verbatim: GitChangesText.unmodified(count))
                }
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 14)
                .frame(minWidth: width, minHeight: 22, maxHeight: 22, alignment: .leading)
                .background(Chrome.window)
                .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the \(FilesFormatting.count(count)) lines · ⌥-click shows every fold")
            .accessibilityIdentifier("git-diff-fold-\(start)")
        case .diff(.gap(let hunk, let count)):
            gapRow(hunk, count: count, width: width)
        case .diff(.gapLine(let old, let new)):
            gapLine(old: old, new: new, gutter: gutter, width: width, metrics: metrics)
        case .diff(.noNewline(let index)):
            Text("No newline at end of file")
                .font(theme.typography.font(offset: -2))
                .foregroundStyle(theme.muted)
                .padding(.leading, mode == .diff ? gutter * 2 + 14 : 14 + gutter + 10 + 14)
                .frame(minWidth: width, minHeight: 18, alignment: .leading)
                .accessibilityIdentifier("git-diff-no-newline-\(index)")
        case .diff(.omitted(let after, let count)):
            Text("\(FilesFormatting.count(count)) \(count == 1 ? "line" : "lines") not in the diff")
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 14)
                .frame(minWidth: width, minHeight: 22, maxHeight: 22, alignment: .leading)
                .background(Chrome.window)
                .accessibilityIdentifier("git-diff-omitted-\(after)")
        case .source(let index):
            sourceLine(index, gutter: gutter, width: width, metrics: metrics)
        case .truncated:
            Text("Output cut at the helper’s bound")
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(theme.yellow)
                .padding(.horizontal, 14)
                .frame(minWidth: width, minHeight: 26, alignment: .leading)
                .accessibilityIdentifier("git-diff-truncated")
        }
    }

    private func diffLine(_ index: Int, gutter: CGFloat, width: CGFloat, metrics: FilePreviewMetrics.Metrics) -> some View {
        let line = model.presentation.lines[index]
        let single = mode == .source
        let tint: Color = switch line.kind {
        case .added where !single: theme.green.opacity(0.10)
        case .removed: theme.red.opacity(0.10)
        default: .clear
        }
        let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : ""
        let code = model.attributed(index, theme: theme)
        // The 11 pt numbers sit on the 12.5 pt code's baseline.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if single {
                number(line.new, width: gutter).padding(.leading, 14).padding(.trailing, 10 + 14)
            } else {
                number(line.old, width: gutter)
                number(line.new, width: gutter)
                Text(verbatim: sign)
                    .foregroundStyle(line.kind == .added ? theme.green : theme.red)
                    .frame(width: 14)
            }
            Text(code)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
            Spacer(minLength: 0)
        }
        // Exactly the text preview's 20 pt row, the line centred in it: rows never wrap, and the baseline alignment
        // of 11 pt numbers with 12.5 pt code would otherwise make the row taller than its text.
        .frame(minWidth: width, minHeight: metrics.rowHeight, maxHeight: metrics.rowHeight, alignment: .leading)
        .background(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(single ? [line.new] : [line.old, line.new], sign: single ? "" : sign, code))
        .accessibilityIdentifier("git-diff-line-\(index)")
    }

    /// An unmodified line of an opened gap, from the read file, numbered on both sides like the diff's own.
    private func gapLine(old: Int, new: Int, gutter: CGFloat, width: CGFloat,
                         metrics: FilePreviewMetrics.Metrics) -> some View {
        let code = model.sourceAttributed(new - 1, theme: theme)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(old, width: gutter)
            number(new, width: gutter)
            Color.clear.frame(width: 14, height: 1)
            Text(code)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minWidth: width, minHeight: metrics.rowHeight, maxHeight: metrics.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken([old, new], code))
        .accessibilityIdentifier("git-diff-gap-line-\(new)")
    }

    private func sourceLine(_ index: Int, gutter: CGFloat, width: CGFloat, metrics: FilePreviewMetrics.Metrics) -> some View {
        let code = model.sourceAttributed(index, theme: theme)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(index + 1, width: gutter).padding(.leading, 14).padding(.trailing, 10 + 14)
            Text(code)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minWidth: width, minHeight: metrics.rowHeight, maxHeight: metrics.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken([index + 1], code))
        .accessibilityIdentifier("git-diff-source-line-\(index + 1)")
    }

    /// A row as VoiceOver reads it: its numbers, its sign and its code. On macOS 27 a selectable Text stays an element
    /// of its own, so `.combine` alone would read the numbers only.
    static func spoken(_ numbers: [Int?], sign: String = "", _ code: AttributedString) -> String {
        (numbers.compactMap { $0.map(String.init) } + [sign, String(code.characters)])
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
    }

    private func number(_ value: Int?, width: CGFloat) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .font(theme.typography.codeFont(offset: -1.5))
            .foregroundStyle(theme.muted)
            .frame(width: width - 8, alignment: .trailing)
            .padding(.trailing, 8)
    }
}

/// A row of the diff's scroll view; hashable, so it is also the row's identity.
enum GitDiffDisplayRow: Hashable, Sendable {
    case diff(GitDiffPresentation.Row)
    /// A line of the file Source read.
    case source(Int)
    /// "Output cut at the helper’s bound" under a diff the helper cut.
    case truncated
}

/// Source's read of the file, per path.
struct GitSourceText: Equatable {
    enum State: Equatable {
        case loading
        case text(String)
        case failed(String)
    }

    let path: String
    let state: State

    var isLoading: Bool { state == .loading }
}

/// The parsed diff, its colour and its widths, computed once per diff and theme (as `FileTextLines` does for the
/// preview), never per frame. A hunk is coloured when one of its rows first draws, so a 2 MB diff costs only the
/// hunks scrolled to.
@MainActor final class GitDiffLines {
    private struct Key: Equatable {
        let diff: GitDiff
        let theme: ChatTheme
    }

    private struct RowsKey: Equatable {
        let newSide: Bool
        let opened: Set<Int>
        let allOpen: Bool
        let openedGaps: Set<Int>
        let sourceLines: Int?
        let truncated: Bool
    }

    private var key: Key?
    private(set) var presentation = GitDiffPresentation()
    /// The hunk each line belongs to.
    private var hunkOf: [Int] = []
    private var colored: [Int: [AttributedString]] = [:]
    private var widestDiff = 0
    private var digitsDiff = 1
    private var rowsKey: RowsKey?
    private var rows: [GitDiffDisplayRow] = []
    private var source = FileTextLines()
    private var sourceText: String?
    private var sourceRows: [GitDiffDisplayRow] = []
    private var widestSource = 0

    func prepare(_ diff: GitDiff, theme: ChatTheme) {
        let key = Key(diff: diff, theme: theme)
        guard key != self.key else { return }
        let reparse = self.key?.diff != diff
        self.key = key
        colored = [:]
        sourceText = nil
        guard reparse else { return }
        presentation = diff.binary ? GitDiffPresentation() : GitDiffPresentation.parse(diff.text)
        hunkOf = Array(repeating: 0, count: presentation.lines.count)
        for (number, hunk) in presentation.hunks.enumerated() { for index in hunk.lines { hunkOf[index] = number } }
        widestDiff = presentation.lines.reduce(0) { max($0, min($1.text.count, FileTextLines.lineLimit + 2)) }
        digitsDiff = String(presentation.lines.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }).count
        rowsKey = nil
    }

    var newSide: [String] { presentation.lines.filter { $0.kind != .removed }.map(\.text) }

    /// Digits of the largest line number shown: the read file's line count, else the diff's numbers.
    func digits(source: Bool) -> Int { source && sourceText != nil ? String(self.source.lines.count).count : digitsDiff }

    func widest(source: Bool) -> Int { source && sourceText != nil ? widestSource : widestDiff }

    func diffRows(opened: Set<Int>, allOpen: Bool, openedGaps: Set<Int>, sourceLines: Int?,
                  truncated: Bool) -> [GitDiffDisplayRow] {
        let key = RowsKey(newSide: false, opened: opened, allOpen: allOpen, openedGaps: openedGaps,
                          sourceLines: sourceLines, truncated: truncated)
        return cachedRows(key) {
            presentation.rows(opened: opened, allOpen: allOpen, openedGaps: openedGaps, sourceLines: sourceLines)
        }
    }

    func newSideRows(truncated: Bool) -> [GitDiffDisplayRow] {
        let key = RowsKey(newSide: true, opened: [], allOpen: false, openedGaps: [], sourceLines: nil, truncated: truncated)
        return cachedRows(key) { presentation.newSideRows() }
    }

    private func cachedRows(_ key: RowsKey, _ make: () -> [GitDiffPresentation.Row]) -> [GitDiffDisplayRow] {
        guard key != rowsKey else { return rows }
        rowsKey = key
        rows = make().map(GitDiffDisplayRow.diff)
        if key.truncated { rows.append(.truncated) }
        return rows
    }

    /// The read file's line count, preparing its lines (and colour) for Source and for opened gaps.
    func sourceLineCount(_ text: String, theme: ChatTheme) -> Int { sourceRows(text, theme: theme).count }

    func sourceRows(_ text: String, theme: ChatTheme) -> [GitDiffDisplayRow] {
        if sourceText != text {
            sourceText = text
            source = FileTextLines()
            source.prepare(.init(owner: ObjectIdentifier(source), count: text.utf8.count, language: key?.diff.path ?? "",
                                 theme: theme)) { text }
            sourceRows = source.lines.indices.map(GitDiffDisplayRow.source)
            widestSource = source.lines.reduce(0) { max($0, min($1.count, FileTextLines.lineLimit + 2)) }
        }
        return sourceRows
    }

    func sourceAttributed(_ index: Int, theme: ChatTheme) -> AttributedString {
        guard source.lines.indices.contains(index) else { return AttributedString(" ") }
        return source.attributed(index, theme: theme)
    }

    /// A diff line's text in the file's colours. Each side of its hunk is highlighted as one text, so a string or
    /// comment that spans lines colours through, and a removed line never changes how an added one lexes.
    func attributed(_ index: Int, theme: ChatTheme) -> AttributedString {
        let line = presentation.lines[index]
        if line.text.isEmpty { return AttributedString(" ") }
        if line.text.count > FileTextLines.lineLimit {
            var text = AttributedString(String(line.text.prefix(FileTextLines.lineLimit)) + " …")
            text.foregroundColor = theme.ink
            return text
        }
        let number = hunkOf[index]
        let lines = colored[number] ?? color(presentation.hunks[number], theme: theme)
        colored[number] = lines
        let offset = index - presentation.hunks[number].lines.lowerBound
        return lines.indices.contains(offset) ? lines[offset] : AttributedString(line.text)
    }

    private func color(_ hunk: GitDiffPresentation.Hunk, theme: ChatTheme) -> [AttributedString] {
        let path = key?.diff.path ?? ""
        let lines = Array(presentation.lines[hunk.lines])
        var result = lines.map { line -> AttributedString in
            var text = AttributedString(line.text)
            text.foregroundColor = theme.ink
            return text
        }
        guard SyntaxHighlight.language(path) != "text" else { return result }
        for side in [GitDiffPresentation.Kind.removed, .added] {
            // The old side is the unmodified and removed lines, the new side the unmodified and added ones; unmodified
            // lines keep the new side's colours.
            let members = lines.indices.filter { lines[$0].kind == .context || lines[$0].kind == side }
            let joined = members.map { lines[$0].text.count > FileTextLines.lineLimit ? "" : lines[$0].text }
                .joined(separator: "\n")
            guard !members.isEmpty, joined.utf16.count <= 65_536 else { continue }
            let colored = SyntaxHighlight.lines(joined, language: path, theme: theme)
            guard colored.count == members.count else { continue }
            for (position, member) in members.enumerated() where lines[member].kind == side || side == .added {
                result[member] = colored[position]
            }
        }
        return result
    }
}

/// The Diff / Source switch in the diff's header (`.seg` at 20 pt).
struct GitDiffModePicker: View {
    @Binding var mode: GitDiffMode
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(spacing: 1) {
            segment("Diff", .diff, help: "Show the changes")
            segment("Source", .source, help: "Show the whole file")
        }
        .glassSegmentTrack(fallback: Chrome.palette.control, corner: 5, inset: 1)
        .fixedSize()
    }

    private func segment(_ title: String, _ value: GitDiffMode, help: String) -> some View {
        let palette = Chrome.palette
        let on = mode == value
        return Button { mode = value } label: {
            Text(title)
                .font(theme.typography.font(offset: -1.5))
                .foregroundStyle(on ? palette.ink : palette.muted)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .glassSegmentPill(on, fallback: palette.selectedControl)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier("git-diff-mode-\(value.rawValue)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
