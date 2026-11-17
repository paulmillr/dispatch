import AppKit
import SwiftUI

/// One file's diff in the chat tool cards' style: Diff / Source, two line-number gutters, blue hunk headers, folds
/// for unmodified runs, syntax colour over the add and remove tints (F3a). The Changes and Commits tabs share it.
///
/// Source shows the whole file when the caller can read it (`source`: the Review tab reads the working tree through
/// `FilesSource.read`); without a reader it shows the new side as far as the diff holds it, numbered as in the file,
/// with a row for each stretch the diff leaves out (a commit's version of a file is not readable through `files.git`).
/// The same reader fills the lines git leaves out between hunks when one of those rows is opened.
struct GitDiffView: View {
    let diff: GitDiff
    /// `diff`'s lines as the data layer parsed them off the main thread; nil parses them here.
    var parsed: GitDiffParsed?
    @Binding var mode: GitDiffMode
    /// Long lines wrap to the pane rather than scroll sideways; nil wraps in a compact split (`wraps`).
    @Binding var wrap: Bool?
    /// The status letter beside the path; nil draws none.
    var kind: GitChangeKind?
    /// Reads the file Source shows, as text; nil shows the diff's new side.
    var source: (@Sendable () async throws -> String)?
    /// Bumped to give the diff the keyboard (⏎ in the Changes list).
    var focusRequest: UUID?
    /// esc while the diff has the keyboard: the caller's list takes it back.
    var onEscape: (() -> Void)?
    /// The Review tab's comments on this file: each line takes one (the gutter's + on hover, or ⏎ on the keyboard's
    /// row), and they show under their lines. Nil (Commits) draws none.
    var review: GitDiffReview?
    /// The files tab showing the diff: ⌘F finds in the diff while it has the keyboard (`FilesSession.diffFocused`), as
    /// the preview's find does on Files.
    var session: FilesSession?
    /// The diff takes the keyboard when it appears (a commit's file opened with ⏎ while its diff was loading).
    var focusOnAppear = false

    @Environment(\.chatTheme) private var theme
    @Environment(\.appTypography) private var typography
    @MotionReduced private var reduceMotion
    /// Narrower than `FilesView.columnsWidth`: one gutter in Diff, lines wrapped unless the wrap button said otherwise,
    /// Diff | Source as glyphs.
    @Environment(\.filesCompact) private var compact
    @State private var model = GitDiffLines()
    /// Bumped when a hunk coloured in the background is ready: its rows draw again, in colour.
    @State private var coloredHunks = 0
    @State private var opened: Set<Int> = []
    /// The `Gap.hunk` of every gap between hunks the user opened; its lines show once the file is read.
    @State private var openedGaps: Set<Int> = []
    @State private var allOpen = false
    @State private var loaded: GitSourceText?
    @State private var cursor: Int?
    @FocusState private var focused: Bool
    /// ⌘F's find in the diff's lines: "n of m", ⏎ and ⇧⏎ step, esc closes.
    @State private var find = FilePreviewFind()
    @FocusState private var findFocused: Bool

    private struct SourceKey: Equatable {
        let reading: Bool
        let path: String
        /// The diff changes when the file does: the text is read again.
        let text: String
    }

    var body: some View {
        model.prepare(diff, parsed: parsed, theme: theme)
        _ = coloredHunks
        let comments = review?.comments ?? []
        let draft = review?.draft
        let layout = model.reviewLayout(displayRows(comments: comments, draft: draft), comments: comments, draft: draft,
                                        reviewing: review != nil)
        // Source reads the file; so does Diff once a gap between hunks is opened (its lines are the file's).
        let wantsGaps = !model.presentation.gaps.isEmpty && (allOpen || !openedGaps.isEmpty)
        let key = SourceKey(reading: (mode == .source || wantsGaps) && source != nil && !isBinary, path: diff.path,
                            text: diff.text)
        return VStack(spacing: 0) {
            header
            Rectangle().fill(theme.border).frame(height: 1)
            // Until the review holds a comment, one line says the lines take them and where they go.
            if let review, review.showsHint, !isBinary {
                Text(verbatim: review.commit == nil
                     ? "Click + beside a line (or press ⏎ on it) to comment for the agent · Create Review sends the comments"
                     : "Click + beside a line of this commit (or press ⏎ on it) to comment for the agent · Create Review sends the comments")
                    .font(typography, .caption)
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .background(theme.blue.opacity(0.06))
                    .accessibilityIdentifier("git-diff-review-hint")
            }
            content(layout)
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
        .onChange(of: focused || findFocused) { _, has in session?.diffFocused = has }
        .onChange(of: session?.findRequest) { if session?.diffFocused == true { openFind() } }
        .onDisappear { if focused || findFocused { session?.diffFocused = false } }
        .onAppear { if focusOnAppear { DispatchQueue.main.async { focused = true } } }
        // A comment saved or cancelled gives the keyboard back to the diff.
        .onChange(of: review?.draft?.id) { old, new in if old != nil, new == nil { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-diff")
    }

    private var isBinary: Bool { diff.binary || model.presentation.binary }

    /// The lines wrap: as the wrap button set them, else in a compact split.
    private var wraps: Bool { wrap ?? compact }

    /// Diff numbers its lines in one gutter in a compact split: the new side's number, a removed line's old one faint.
    private var oneGutter: Bool { compact && mode == .diff }

    /// Reviewing, every line starts with a column for its + (`ReviewLineAction`), so it covers no number or sign.
    private var inset: CGFloat { review == nil ? 0 : 20 }

    /// The read file, when it is this diff's.
    private var sourceText: String? {
        guard let loaded, loaded.path == diff.path, case .text(let text) = loaded.state else { return nil }
        return text
    }

    // MARK: Header

    private var header: some View {
        let presentation = model.presentation
        let title = TextRendering.visible(diff.oldPath.map { $0 == diff.path ? diff.path : "\($0) → \(diff.path)" } ?? diff.path)
        return HStack(spacing: 10) {
            if let kind { GitChangeBadge(kind: kind, side: 18, plain: true) }
            Text(verbatim: title)
                .font(typography, .content)
                .foregroundStyle(theme.ink)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
                .accessibilityIdentifier("git-diff-path")
            // The file's counts as the Review list draws them.
            GitCounts(additions: isBinary ? nil : presentation.additions, deletions: isBinary ? nil : presentation.deletions,
                      binary: isBinary ? GitChangesText.binary(old: diff.oldSize, new: diff.newSize, kind: kind) : nil)
                .font(typography, .body)
                .accessibilityIdentifier("git-diff-meta")
            Spacer(minLength: 0)
            if find.open { findField }
            if !isBinary {
                // The file's whole diff as git prints it: a line's selection takes one line at a time.
                Button { GitPasteboard.copy(diff.text) } label: {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 11)).frame(width: 14, height: 14)
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: false))
                .help("Copy the diff")
                .accessibilityLabel("Copy diff")
                .accessibilityIdentifier("git-diff-copy")
            }
            Button { wrap = !wraps } label: {
                FileWrapGlyph().frame(width: 14, height: 14)
            }
            .buttonStyle(FilePreviewIconButtonStyle(on: wraps))
            .help(wraps ? "Don’t wrap lines" : "Wrap lines")
            .accessibilityLabel("Wrap lines")
            .accessibilityValue(wraps ? "on" : "off")
            .accessibilityIdentifier("git-diff-wrap")
            if let review {
                Button { review.beginOnFile() } label: {
                    Image(systemName: "text.bubble").font(.system(size: 11, weight: .medium)).frame(width: 14, height: 14)
                }
                .buttonStyle(FilePreviewIconButtonStyle(on: false))
                .help("Comment on the file")
                .accessibilityLabel("Comment on the file")
                .accessibilityIdentifier("git-diff-comment-file")
            }
            GitDiffModePicker(mode: $mode, glyphs: compact)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background {
            // ⌘F while the diff has the keyboard, wherever the menu routes Edit › Find; opening twice is harmless.
            Button(action: openFind) { Color.clear.frame(width: 0, height: 0) }
                .buttonStyle(.plain).opacity(0).allowsHitTesting(false)
                .keyboardShortcut(focused && !isBinary ? KeyboardShortcut("f", modifiers: .command) : nil)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-diff-header")
    }

    private var findField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(theme.muted)
            TextField("Find in diff", text: $find.query)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .onSubmit { if NSEvent.modifierFlags.contains(.shift) { find.previous() } else { find.next() } }
                .onKeyPress(.escape) { closeFind(); return .handled }
                .onExitCommand { closeFind() }
                .onChange(of: find.query) { find.current = 0; find.step += 1 }
                .accessibilityIdentifier("git-diff-find")
            if !find.query.isEmpty {
                Text(find.total == 0 ? "none" : "\(min(find.current + 1, find.total)) of \(find.total)")
                    .foregroundStyle(theme.muted)
                    .fixedSize()
                    .accessibilityIdentifier("git-diff-find-count")
            }
        }
        .font(typography, .label)
        .padding(.horizontal, 8)
        .frame(width: 190, height: 22)
        .background(theme.window, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border))
    }

    private func openFind() {
        guard !isBinary else { return }
        find.open = true
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        find.open = false
        find.query = ""
        focused = true
    }

    /// The query's matches among the rows shown, in reading order (the row each is on): only while the find is open.
    private func findMatches(_ rows: [GitDiffDisplayRow]) -> [TextOccurrences.Match] {
        guard find.open, !find.query.isEmpty else { return [] }
        return TextOccurrences.scan(of: find.query, in: rows.lazy.map { model.text(of: $0) ?? "" }, limit: 10_000)
    }

    /// The find's query marked in a line's code.
    private func marked(_ code: AttributedString) -> AttributedString {
        find.open ? ChatSearchHighlight.text(code, query: find.query, theme: theme) : code
    }

    // MARK: Body

    /// What the scroll view lists, by mode: the diff's rows, the read file's lines, or the diff's new side. A fold
    /// holding a commented line shows open.
    private func displayRows(comments: [ReviewComment], draft: ReviewDraft?) -> [GitDiffDisplayRow] {
        guard !isBinary else { return [] }
        if mode == .diff {
            let lines = sourceText.map { model.sourceLineCount($0, theme: theme) }
            let commented = review == nil ? [] : model.commentFolds(comments, draft: draft)
            return model.diffRows(opened: opened.union(commented), allOpen: allOpen, openedGaps: openedGaps,
                                  sourceLines: lines, truncated: diff.truncated)
        }
        if source == nil { return model.newSideRows(truncated: diff.truncated) }
        if let sourceText { return model.sourceRows(sourceText, theme: theme) }
        return []
    }

    @ViewBuilder private func content(_ layout: GitDiffReviewLayout) -> some View {
        if isBinary {
            notice(GitChangesText.binary(old: diff.oldSize, new: diff.newSize, kind: kind), identifier: "git-diff-binary",
                   layout: layout)
        } else if mode == .source, source != nil, loaded?.path != diff.path || loaded?.isLoading == true {
            GitDelayedSpinner()
        } else if mode == .source, source != nil, let loaded, case .failed(let message) = loaded.state {
            notice(message, identifier: "git-diff-source-error", layout: layout)
        } else if layout.empty || (mode == .diff && model.presentation.hunks.isEmpty) {
            if mode == .source {
                notice(GitChangesText.emptySource(model.presentation, kind: kind, read: source != nil),
                       identifier: "git-diff-empty", layout: layout)
            } else {
                notice(model.presentation.notes.isEmpty ? "No changes to the file’s text"
                       : model.presentation.notes.joined(separator: "\n"), identifier: "git-diff-empty", layout: layout)
            }
        } else {
            rowsView(layout)
        }
    }

    /// A notice where there are no lines; the file's comments (and one being written) above it.
    @ViewBuilder private func notice(_ text: String, identifier: String, layout: GitDiffReviewLayout) -> some View {
        let top = layout.rows.prefix { if case .comment = $0 { return true }; return $0 == .composer }
        if let review, !top.isEmpty {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(top), id: \.self) { row in
                            reviewRow(row, review: review, layout: layout, leading: 14, pane: geometry.size.width)
                        }
                        notice(text, identifier: identifier).frame(minHeight: 160)
                    }
                    .animation(reviewMotion, value: Self.reviewRows(layout.rows))
                    .padding(.vertical, 8)
                }
            }
        } else {
            notice(text, identifier: identifier)
        }
    }

    private func notice(_ text: String, identifier: String) -> some View {
        Text(verbatim: text)
            .font(typography, .label)
            .foregroundStyle(theme.muted)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier(identifier)
    }

    private func rowsView(_ layout: GitDiffReviewLayout) -> some View {
        let rows = layout.rows
        let metrics = FilePreviewMetrics.metrics(theme.typography)
        let whole = mode == .source && sourceText != nil
        let single = mode == .source
        let gutter = Self.gutterWidth(digits: model.digits(source: whole),
                                      digitWidth: metrics.digitWidth * (theme.typography.size - 1.5) / theme.typography.size)
        let codeLeading = inset + (single ? 14 + gutter + 10 + 14 : oneGutter ? gutter + 14 : gutter * 2 + 14)
        // Opened gaps draw the read file's lines among the diff's: the widest of either sets the width.
        let gapLines = !single && rows.contains { if case .diff(.gapLine) = $0 { return true }; return false }
        let widest = gapLines ? max(model.widest(source: false), model.widest(source: true)) : model.widest(source: whole)
        let contentWidth = codeLeading + CGFloat(widest) * metrics.digitWidth + 14
        let matches = findMatches(rows)
        let found = matches.indices.contains(find.current) ? matches[find.current].line : nil
        return GeometryReader { geometry in
            // Every row as wide as the widest line, so the tints run the whole width when scrolled sideways (the code
            // font is monospaced: characters times the digit's advance); wrapped, as wide as the pane.
            let width = wraps ? geometry.size.width : max(geometry.size.width, contentWidth.rounded(.up))
            let page = max(1, Int(geometry.size.height / metrics.rowHeight) - 2)
            ScrollViewReader { proxy in
                ScrollView(wraps ? [.vertical] : [.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.self) { row in
                            self.row(row, gutter: gutter, width: width, metrics: metrics, layout: layout,
                                     leading: codeLeading, pane: geometry.size.width,
                                     cursor: focused && cursorRow(rows) == row)
                                .background(found.map { rows[$0] == row } == true ? theme.yellow.opacity(0.18)
                                            : focused && cursorRow(rows) == row ? theme.ink.opacity(0.06) : .clear)
                        }
                    }
                    // A comment or the composer coming or going opens or closes its place: the lines below slide
                    // rather than jump. Only those rows key it, so a diff's own updates stay instant.
                    .animation(reviewMotion, value: Self.reviewRows(rows))
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    // At least the pane's height, from the top: a two-axis scroll view centres smaller content.
                    .frame(minWidth: width, minHeight: geometry.size.height, alignment: .topLeading)
                    .background(alignment: .topLeading) {
                        if single {
                            Rectangle().fill(theme.border).frame(width: 1).padding(.leading, inset + 14 + gutter + 10)
                        }
                    }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.downArrow) { step(1, rows, proxy) }
                .onKeyPress(.upArrow) { step(-1, rows, proxy) }
                .onKeyPress(.pageDown) { move(page, rows, proxy) }
                .onKeyPress(.pageUp) { move(-page, rows, proxy) }
                .onKeyPress(.home) { move(-rows.count, rows, proxy) }
                .onKeyPress(.end) { move(rows.count, rows, proxy) }
                .onKeyPress(.return) { openFold(at: cursorRow(rows), layout: layout) }
                .onKeyPress(.space) { openFold(at: cursorRow(rows), layout: nil) }
                .onKeyPress(.escape) {
                    guard let onEscape else { return .ignored }
                    onEscape()
                    return .handled
                }
                .onChange(of: find.step) { if let found { proxy.scrollTo(rows[found], anchor: .center) } }
                .onChange(of: matches.count, initial: true) {
                    if find.total != matches.count { find.total = matches.count }
                    if find.current >= matches.count, find.current != 0 { find.current = 0 }
                }
                .onAppear { reveal(review?.session.reviewReveal, rows, proxy) }
                .onChange(of: review?.session.reviewReveal) { _, request in reveal(request, rows, proxy) }
            }
        }
        .font(theme.typography.codeFont())
        .accessibilityIdentifier("git-diff-rows")
    }

    /// One hunk as git prints it: its header, then each line with its mark (`+`, `-`, a space).
    static func hunkText(_ presentation: GitDiffPresentation, _ index: Int) -> String {
        guard presentation.hunks.indices.contains(index) else { return "" }
        let hunk = presentation.hunks[index]
        var lines = [hunk.section.isEmpty ? hunk.range : hunk.range + " " + hunk.section]
        for line in presentation.lines[hunk.lines] {
            let mark = switch line.kind { case .added: "+"; case .removed: "-"; case .context: " " }
            lines.append(mark + line.text)
            if line.noNewline { lines.append("\\ No newline at end of file") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A gutter at 11 pt: the design's 34 pt, wider only for line numbers past four digits.
    static func gutterWidth(digits: Int, digitWidth: CGFloat) -> CGFloat {
        max(34, (CGFloat(digits) * digitWidth + 12).rounded(.up))
    }

    private func cursorRow(_ rows: [GitDiffDisplayRow]) -> GitDiffDisplayRow? {
        guard let cursor, rows.indices.contains(cursor) else { return nil }
        return rows[cursor]
    }

    /// ↑↓ move the keyboard's row; with ⌥ (reviewing) they go to the next or previous comment, on whichever file.
    private func step(_ delta: Int, _ rows: [GitDiffDisplayRow], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard NSEvent.modifierFlags.contains(.option), let review else { return move(delta, rows, proxy) }
        return review.step(by: delta) ? .handled : .ignored
    }

    /// A comment asked for (⌥↓, Create review's list) that this diff holds: the keyboard's row on it, scrolled to the
    /// middle, the diff given the keyboard, and the request done.
    private func reveal(_ request: ReviewReveal?, _ rows: [GitDiffDisplayRow], _ proxy: ScrollViewProxy) {
        guard let request, let review, let index = rows.firstIndex(of: .comment(request.comment)) else { return }
        cursor = index
        focused = true
        review.session.reviewReveal = nil
        DispatchQueue.main.async { proxy.scrollTo(rows[index], anchor: .center) }
    }

    /// The keyboard's row in the focused diff: ↑↓, page up and down, home and end move it and scroll it into view.
    private func move(_ delta: Int, _ rows: [GitDiffDisplayRow], _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let next = min(max((cursor ?? (delta > 0 ? -1 : rows.count)) + delta, 0), rows.count - 1)
        cursor = next
        proxy.scrollTo(rows[next])
        return .handled
    }

    /// ⏎ or space on the keyboard's row: a fold or gap opens; ⏎ on a line (`layout` given) comments on it.
    private func openFold(at row: GitDiffDisplayRow?, layout: GitDiffReviewLayout?) -> KeyPress.Result {
        switch row {
        case .diff(.fold(let start, _))?:
            open(start, all: NSEvent.modifierFlags.contains(.option))
        case .diff(.gap(let hunk, _))? where source != nil:
            openGap(hunk, all: NSEvent.modifierFlags.contains(.option))
        case let row? where review != nil && layout?.lines[row] != nil:
            guard let layout else { return .ignored }
            comment(on: row, layout: layout, extend: NSEvent.modifierFlags.contains(.shift))
        default:
            return .ignored
        }
        return .handled
    }

    /// The + of a line, or ⏎ on it: a new comment there, or with ⇧ the one being written stretched to it.
    private func comment(on row: GitDiffDisplayRow, layout: GitDiffReviewLayout, extend: Bool) {
        guard let review, let target = layout.lines[row] else { return }
        var lines = [target]
        if extend, let draft = review.draft, draft.editing == nil, let start = draft.start,
           let anchor = layout.lines.values.filter({ $0.line == start }).min(by: { abs($0.index - target.index) < abs($1.index - target.index) }) {
            let range = min(anchor.index, target.index)...max(anchor.index, target.index)
            let spanned = layout.lines.values.filter { range.contains($0.index) }.sorted { $0.index < $1.index }
            if !spanned.isEmpty { lines = spanned }
        }
        guard let first = lines.first, let last = lines.last else { return }
        // Each quoted line keeps its number, and the lines around them are kept too: what finds the comment again.
        let quote = lines.map { ReviewQuote(kind: $0.quote.kind, text: $0.quote.text, line: $0.line) }
        var shown: [ReviewLine: ReviewQuote] = [:]
        for line in layout.lines.values where shown[line.line] == nil { shown[line.line] = line.quote }
        let around = ReviewQuote.surroundings(of: quote, in: shown)
        review.begin(start: first.line, end: last.line, quote: quote, before: around.before, after: around.after)
    }

    /// The review's rows among a diff's, in order: what the rows' motion follows.
    static func reviewRows(_ rows: [GitDiffDisplayRow]) -> [GitDiffDisplayRow] {
        rows.filter { if case .comment = $0 { return true }; return $0 == .composer }
    }
    private var reviewMotion: Animation? { InterfaceMotion.animation(reduce: reduceMotion, duration: 0.22) }

    /// A saved comment, or the composer, at its place among the rows: in line with the code, no wider than the pane.
    @ViewBuilder private func reviewRow(_ row: GitDiffDisplayRow, review: GitDiffReview, layout: GitDiffReviewLayout,
                                        leading: CGFloat, pane: CGFloat) -> some View {
        let width = max(260, min(pane - leading - 14, 720))
        Group {
            switch row {
            case .comment(let id):
                if let comment = layout.comments[id] {
                    if let draft = review.draft, draft.editing == id {
                        ReviewComposer(review: review, draft: draft)
                    } else {
                        ReviewCommentCard(review: review, comment: comment, detached: layout.detached.contains(id),
                                          revealed: review.session.reviewPosition == id)
                    }
                }
            case .composer:
                if let draft = review.draft { ReviewComposer(review: review, draft: draft) }
            default:
                EmptyView()
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, leading)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A line that takes a comment: its + on hover, its tint while the comment being written spans it.
    @ViewBuilder private func commentable<Line: View>(_ line: Line, _ row: GitDiffDisplayRow,
                                                      layout: GitDiffReviewLayout, cursor: Bool = false) -> some View {
        if review != nil, let target = layout.lines[row] {
            line.modifier(ReviewLineAction(highlighted: layout.highlighted.contains(row), cursor: cursor,
                                           identifier: "git-diff-comment-\(target.line.side.rawValue)-\(target.line.number)") { extend in
                comment(on: row, layout: layout, extend: extend)
            })
        } else {
            line
        }
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
        .font(typography, .body)
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
                                  metrics: FilePreviewMetrics.Metrics, layout: GitDiffReviewLayout, leading: CGFloat,
                                  pane: CGFloat, cursor: Bool = false) -> some View {
        switch row {
        case .diff(.hunk(let index)):
            let hunk = model.presentation.hunks[index]
            HStack(spacing: 10) {
                Text(verbatim: hunk.range).foregroundStyle(theme.blue)
                if !hunk.section.isEmpty { Text(verbatim: hunk.section).foregroundStyle(theme.muted) }
            }
            .font(theme.typography.codeFont(offset: -1))
            .lineLimit(1)
            .fixedSize(horizontal: !wraps, vertical: false)
            .padding(.horizontal, 14)
            .frame(minWidth: width, minHeight: 22, maxHeight: 22, alignment: .leading)
            .background(theme.blue.opacity(0.07))
            .contentShape(Rectangle())
            .contextMenu {
                Button("Copy Hunk") { GitPasteboard.copy(Self.hunkText(model.presentation, index)) }
                Button("Copy Diff") { GitPasteboard.copy(diff.text) }
            }
            .help("Right-click to copy the hunk")
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Copy Hunk") { GitPasteboard.copy(Self.hunkText(model.presentation, index)) }
            .accessibilityIdentifier("git-diff-hunk-\(index)")
        case .diff(.line(let index)):
            commentable(diffLine(index, gutter: gutter, width: width, metrics: metrics), row, layout: layout, cursor: cursor)
        case .diff(.fold(let start, let count)):
            Button {
                open(start, all: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    Text(verbatim: GitChangesText.unmodified(count))
                }
                .font(typography, .body)
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
            commentable(gapLine(old: old, new: new, gutter: gutter, width: width, metrics: metrics), row, layout: layout,
                        cursor: cursor)
        case .diff(.noNewline(let index)):
            Text("No newline at end of file")
                .font(typography, .caption)
                .foregroundStyle(theme.muted)
                .padding(.leading, inset + (mode == .diff ? gutter * (oneGutter ? 1 : 2) + 14 : 14 + gutter + 10 + 14))
                .frame(minWidth: width, minHeight: 18, alignment: .leading)
                .accessibilityIdentifier("git-diff-no-newline-\(index)")
        case .diff(.omitted(let after, let count)):
            Text("\(FilesFormatting.count(count)) \(count == 1 ? "line" : "lines") not in the diff")
                .font(typography, .body)
                .foregroundStyle(theme.muted)
                .padding(.horizontal, 14)
                .frame(minWidth: width, minHeight: 22, maxHeight: 22, alignment: .leading)
                .background(Chrome.window)
                .accessibilityIdentifier("git-diff-omitted-\(after)")
        case .source(let index):
            commentable(sourceLine(index, gutter: gutter, width: width, metrics: metrics), row, layout: layout, cursor: cursor)
        case .comment, .composer:
            if let review { reviewRow(row, review: review, layout: layout, leading: leading, pane: pane) }
        case .truncated:
            Text("Output cut at the helper’s bound")
                .font(typography, .body)
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
        let code = marked(model.attributed(index, theme: theme) { coloredHunks &+= 1 })
        // The 11 pt numbers sit on the 12.5 pt code's baseline.
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if inset > 0 { Color.clear.frame(width: inset, height: 1) }
            if single {
                number(line.new, width: gutter).padding(.leading, 14).padding(.trailing, 10 + 14)
            } else {
                if oneGutter {
                    number(line.new ?? line.old, width: gutter, faint: line.new == nil)
                } else {
                    number(line.old, width: gutter)
                    number(line.new, width: gutter)
                }
                Text(verbatim: sign)
                    .foregroundStyle(line.kind == .added ? theme.green : theme.red)
                    .frame(width: 14)
            }
            Text(code)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wraps, vertical: true)
            Spacer(minLength: 0)
        }
        // Exactly the text preview's 20 pt row, the line centred in it: unwrapped rows never wrap, and the baseline
        // alignment of 11 pt numbers with 12.5 pt code would otherwise make the row taller than its text.
        .frame(minWidth: width, maxWidth: wraps ? width : nil, minHeight: metrics.rowHeight,
               maxHeight: wraps ? nil : metrics.rowHeight, alignment: .leading)
        .background(tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken(single ? [line.new] : [line.old, line.new], sign: single ? "" : sign, code))
        .accessibilityIdentifier("git-diff-line-\(index)")
    }

    /// An unmodified line of an opened gap, from the read file, numbered on both sides like the diff's own.
    private func gapLine(old: Int, new: Int, gutter: CGFloat, width: CGFloat,
                         metrics: FilePreviewMetrics.Metrics) -> some View {
        let code = marked(model.sourceAttributed(new - 1, theme: theme))
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if inset > 0 { Color.clear.frame(width: inset, height: 1) }
            if !oneGutter { number(old, width: gutter) }
            number(new, width: gutter)
            Color.clear.frame(width: 14, height: 1)
            Text(code)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wraps, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minWidth: width, maxWidth: wraps ? width : nil, minHeight: metrics.rowHeight,
               maxHeight: wraps ? nil : metrics.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.spoken([old, new], code))
        .accessibilityIdentifier("git-diff-gap-line-\(new)")
    }

    private func sourceLine(_ index: Int, gutter: CGFloat, width: CGFloat, metrics: FilePreviewMetrics.Metrics) -> some View {
        let code = marked(model.sourceAttributed(index, theme: theme))
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            if inset > 0 { Color.clear.frame(width: inset, height: 1) }
            number(index + 1, width: gutter).padding(.leading, 14).padding(.trailing, 10 + 14)
            Text(code)
                .foregroundStyle(theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: !wraps, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minWidth: width, maxWidth: wraps ? width : nil, minHeight: metrics.rowHeight,
               maxHeight: wraps ? nil : metrics.rowHeight, alignment: .leading)
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

    private func number(_ value: Int?, width: CGFloat, faint: Bool = false) -> some View {
        Text(verbatim: value.map(String.init) ?? "")
            .font(theme.typography.codeFont(offset: -1.5))
            .foregroundStyle(faint ? theme.muted.opacity(0.5) : theme.muted)
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
    /// A saved review comment: under its last line, or above the rows when it is on the file or its line is not shown.
    case comment(UUID)
    /// The review comment being written, placed as a saved one is.
    case composer
}

/// The rows `GitDiffView` draws with the review's comments among them, built once per change of rows or comments.
struct GitDiffReviewLayout: Equatable {
    /// A commentable row: its place among the rows without comments, its line, and how a comment quotes it.
    struct Line: Equatable {
        var index: Int
        var line: ReviewLine
        var quote: ReviewQuote
    }

    var rows: [GitDiffDisplayRow]
    /// No rows before the comments: the view shows its notice instead.
    var empty = false
    var comments: [UUID: ReviewComment] = [:]
    /// Comments on lines not among the rows, listed above them with the line they were written on.
    var detached: Set<UUID> = []
    /// The lines the comment being written spans.
    var highlighted: Set<GitDiffDisplayRow> = []
    var lines: [GitDiffDisplayRow: Line] = [:]
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
/// hunks scrolled to; a long one is coloured off the main thread, its rows in plain ink until then.
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
    /// Each hunk's text in UTF-8 bytes, which decides where it is coloured.
    private var hunkBytes: [Int] = []
    private var colored: [Int: [AttributedString]] = [:]
    /// The hunks being coloured off the main thread, and the colouring they belong to: a new diff or theme starts
    /// another, and what the last one finishes is dropped.
    private var coloring: Set<Int> = []
    private var coloringGeneration = 0
    /// A hunk longer than this is coloured off the main thread: lexing 64 KB took about 30 ms, a few frames.
    static let inlineColoring = 8 * 1024
    private var widestDiff = 0
    private var digitsDiff = 1
    private var rowsKey: RowsKey?
    private var rows: [GitDiffDisplayRow] = []
    private var source = FileTextLines()
    private var sourceText: String?
    private var sourceRows: [GitDiffDisplayRow] = []
    private var widestSource = 0

    /// `parsed`: the diff's lines as the data layer parsed them off the main thread, else parsed here.
    func prepare(_ diff: GitDiff, parsed: GitDiffParsed? = nil, theme: ChatTheme) {
        let key = Key(diff: diff, theme: theme)
        guard key != self.key else { return }
        let reparse = self.key?.diff != diff
        self.key = key
        colored = [:]
        coloring = []
        coloringGeneration &+= 1
        sourceText = nil
        guard reparse else { return }
        reviewKey = nil
        foldsKey = nil
        presentation = diff.binary ? GitDiffPresentation()
            : parsed?.presentation ?? GitDiffPresentation.parse(diff.text)
        hunkOf = Array(repeating: 0, count: presentation.lines.count)
        hunkBytes = presentation.hunks.map { hunk in
            presentation.lines[hunk.lines].reduce(0) { $0 + $1.text.utf8.count + 1 }
        }
        for (number, hunk) in presentation.hunks.enumerated() { for index in hunk.lines { hunkOf[index] = number } }
        widestDiff = presentation.lines.reduce(0) { max($0, min($1.text.count, FileTextLines.lineLimit + 2)) }
        digitsDiff = String(presentation.lines.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }).count
        rowsKey = nil
    }

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
            sourceGeneration &+= 1
            source = FileTextLines()
            source.prepare(.init(owner: ObjectIdentifier(source), count: text.utf8.count, language: key?.diff.path ?? "",
                                 theme: theme)) { text }
            sourceRows = source.lines.indices.map(GitDiffDisplayRow.source)
            widestSource = source.lines.reduce(0) { max($0, min($1.count, FileTextLines.lineLimit + 2)) }
        }
        return sourceRows
    }

    // MARK: Review

    private struct ReviewKey: Equatable {
        let rows: [GitDiffDisplayRow]
        let comments: [ReviewComment]
        let draft: ReviewDraft?
        let reviewing: Bool
        let source: Int
    }

    private var reviewKey: ReviewKey?
    /// Bumped when the read file changes: a gap's or Source's lines quote it.
    private var sourceGeneration = 0
    private var review = GitDiffReviewLayout(rows: [])
    private var foldsKey: [ReviewComment]?
    private var folds: Set<Int> = []

    /// A commentable row's line and how a comment quotes it: a diff line on its side, a line of an opened gap or of
    /// Source on the new side.
    private func reviewLine(_ row: GitDiffDisplayRow) -> (line: ReviewLine, quote: ReviewQuote)? {
        switch row {
        case .diff(.line(let index)):
            return ReviewPlacement.anchor(presentation.lines[index])
        case .diff(.gapLine(_, let new)):
            return sourceLine(new - 1).map { (ReviewLine(side: .new, number: new), ReviewQuote(kind: .context, text: $0)) }
        case .source(let index):
            return sourceLine(index).map { (ReviewLine(side: .new, number: index + 1), ReviewQuote(kind: .context, text: $0)) }
        default:
            return nil
        }
    }

    private func sourceLine(_ index: Int) -> String? { source.lines.indices.contains(index) ? source.lines[index] : nil }

    /// A row's line of code, as the find reads it; nil for a row with none (a hunk's header, a fold, a comment).
    func text(of row: GitDiffDisplayRow) -> String? { reviewLine(row)?.quote.text }

    /// The draft as a comment to place: a new one on lines (one on the file, or an edit, has its place already).
    private static func pending(_ draft: ReviewDraft?) -> ReviewComment? {
        guard let draft, draft.editing == nil, draft.end != nil else { return nil }
        return ReviewComment(id: draft.id, path: draft.path, start: draft.start, end: draft.end, quote: draft.quote,
                             text: "", created: .distantFuture, before: draft.before, after: draft.after)
    }

    /// The `Fold.start` of every fold holding a line a comment (or the draft) lands on, so it shows open.
    func commentFolds(_ comments: [ReviewComment], draft: ReviewDraft?) -> Set<Int> {
        let all = comments + [Self.pending(draft)].compactMap { $0 }
        guard !all.isEmpty, !presentation.folds.isEmpty else { return [] }
        if foldsKey == all { return folds }
        let lines = presentation.lines.indices.map { reviewLine(.diff(.line($0))) }
        var indices: [Int] = []
        var candidates: [ReviewPlacement.Candidate] = []
        for (index, line) in lines.enumerated() {
            guard let line else { continue }
            indices.append(index)
            candidates.append(.init(line: line.line, text: line.quote.text))
        }
        // Every line a comment spans opens its fold, from its first line (the nearest above its last) to its last.
        var placed: Set<Int> = []
        for found in ReviewPlacement.locate(all, among: candidates).values {
            let start = found.comment.start.flatMap { start in candidates.prefix(found.index + 1).lastIndex { $0.line == start } }
            for index in (start ?? found.index)...found.index { placed.insert(indices[index]) }
        }
        folds = Set(presentation.folds.filter { fold in placed.contains { fold.range.contains($0) } }.map(\.start))
        foldsKey = all
        return folds
    }

    /// The rows with the review's comments among them (`GitDiffReviewLayout`); the rows alone when not reviewing.
    func reviewLayout(_ rows: [GitDiffDisplayRow], comments: [ReviewComment], draft: ReviewDraft?,
                      reviewing: Bool) -> GitDiffReviewLayout {
        let key = ReviewKey(rows: rows, comments: comments, draft: draft, reviewing: reviewing, source: sourceGeneration)
        if key == reviewKey { return review }
        reviewKey = key
        review = Self.layout(rows, comments: comments, draft: draft, reviewing: reviewing, line: reviewLine)
        return review
    }

    private static func layout(_ base: [GitDiffDisplayRow], comments: [ReviewComment], draft: ReviewDraft?,
                               reviewing: Bool,
                               line: (GitDiffDisplayRow) -> (line: ReviewLine, quote: ReviewQuote)?) -> GitDiffReviewLayout {
        var layout = GitDiffReviewLayout(rows: base)
        layout.empty = base.isEmpty
        guard reviewing else { return layout }
        var candidates: [ReviewPlacement.Candidate] = []
        var candidateRows: [Int] = []
        for (index, row) in base.enumerated() {
            guard let found = line(row) else { continue }
            layout.lines[row] = .init(index: index, line: found.line, quote: found.quote)
            candidates.append(.init(line: found.line, text: found.quote.text))
            candidateRows.append(index)
        }
        let pending = Self.pending(draft)
        let found = ReviewPlacement.locate(comments + [pending].compactMap { $0 }, among: candidates)
        var placed = found.mapValues(\.index)
        // A comment being written that is not found again (its line repeats) stays under the line it was begun on.
        if let pending, placed[pending.id] == nil, let end = pending.end,
           let at = candidates.firstIndex(where: { $0.line == end }) {
            placed[pending.id] = at
        }
        var under: [Int: [GitDiffDisplayRow]] = [:]
        var top: [ReviewComment] = []
        for comment in comments.sorted(by: { $0.created < $1.created }) {
            layout.comments[comment.id] = comment
            if let found = found[comment.id] {
                // Found again on another line (lines added or removed above it): its card names the line it is on now.
                layout.comments[comment.id] = found.comment
                under[candidateRows[found.index], default: []].append(.comment(comment.id))
            } else {
                top.append(comment)
                if !comment.onFile { layout.detached.insert(comment.id) }
            }
        }
        var rows = Review(comments: top).files.flatMap { $0.comments.map { GitDiffDisplayRow.comment($0.id) } }
        if let draft, draft.editing == nil {
            if let pending, let placed = placed[pending.id] { under[candidateRows[placed], default: []].append(.composer) }
            else { rows.append(.composer) }
        }
        for (index, row) in base.enumerated() {
            rows.append(row)
            if let extra = under[index] { rows += extra }
        }
        layout.rows = rows
        // The draft's lines tint: from its first line to where it (or the comment it edits) lands.
        if let draft, let start = draft.start, let end = placed[draft.editing ?? draft.id].map({ candidateRows[$0] }) {
            let first = layout.lines.values.filter { $0.line == start && $0.index <= end }.map(\.index).max() ?? end
            layout.highlighted = Set(base[first...end].filter { layout.lines[$0] != nil })
        }
        return layout
    }

    func sourceAttributed(_ index: Int, theme: ChatTheme) -> AttributedString {
        guard source.lines.indices.contains(index) else { return AttributedString(" ") }
        return source.attributed(index, theme: theme)
    }

    /// A diff line's text in the file's colours. Each side of its hunk is highlighted as one text, so a string or
    /// comment that spans lines colours through, and a removed line never changes how an added one lexes. A hunk over
    /// `inlineColoring` is coloured off the main thread: its lines come back in plain ink, and `colored` is called on
    /// the main thread once its colours are ready.
    func attributed(_ index: Int, theme: ChatTheme,
                    colored ready: @escaping @MainActor () -> Void = {}) -> AttributedString {
        let line = presentation.lines[index]
        if line.text.isEmpty { return AttributedString(" ") }
        if line.text.utf8.count > FileTextLines.lineLimit {
            let bounded = TextRendering.prefix(line.text, scalars: FileTextLines.lineLimit)
            if bounded.truncated {
                var text = AttributedString(TextRendering.visible(bounded.text) + " …")
                text.foregroundColor = theme.ink
                return text
            }
        }
        let number = hunkOf[index]
        let hunk = presentation.hunks[number]
        let offset = index - hunk.lines.lowerBound
        if let lines = colored[number] {
            return lines.indices.contains(offset) ? lines[offset] : AttributedString(TextRendering.visible(line.text))
        }
        let path = key?.diff.path ?? ""
        let members = Array(presentation.lines[hunk.lines])
        guard hunkBytes[number] > Self.inlineColoring else {
            let lines = Self.color(members, path: path, theme: theme)
            colored[number] = lines
            return lines.indices.contains(offset) ? lines[offset] : AttributedString(TextRendering.visible(line.text))
        }
        if coloring.insert(number).inserted {
            let generation = coloringGeneration
            Task { [weak self] in
                let lines = await Self.colorAway(members, path: path, theme: theme)
                guard let self, self.coloringGeneration == generation else { return }
                self.coloring.remove(number)
                self.colored[number] = lines
                ready()
            }
        }
        var plain = AttributedString(TextRendering.visible(line.text))
        plain.foregroundColor = theme.ink
        return plain
    }

    @concurrent nonisolated private static func colorAway(_ lines: [GitDiffPresentation.Line], path: String,
                                                          theme: ChatTheme) async -> [AttributedString] {
        color(lines, path: path, theme: theme)
    }

    nonisolated private static func color(_ lines: [GitDiffPresentation.Line], path: String,
                                          theme: ChatTheme) -> [AttributedString] {
        var result = lines.map { line -> AttributedString in
            var text = AttributedString(TextRendering.visible(line.text))
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
    @Environment(\.appTypography) private var typography
    @Binding var mode: GitDiffMode
    /// A compact split's header: each mode as a glyph, its name in the help and for VoiceOver.
    var glyphs = false
    @Environment(\.chatTheme) private var theme

    var body: some View {
        HStack(spacing: 1) {
            segment("Diff", .diff, symbol: "plus.forwardslash.minus", help: "Show the changes")
            segment("Source", .source, symbol: "doc.plaintext", help: "Show the whole file")
        }
        .glassSegmentTrack(fallback: Chrome.palette.control, corner: 5, inset: 1)
        .fixedSize()
    }

    private func segment(_ title: String, _ value: GitDiffMode, symbol: String, help: String) -> some View {
        let palette = Chrome.palette
        let on = mode == value
        return Button { mode = value } label: {
            Group {
                if glyphs {
                    Image(systemName: symbol).font(.system(size: typography.size(offset: -2.5), weight: .medium))
                        .frame(width: typography.expanded(16))
                } else {
                    Text(title).font(typography, .body)
                }
            }
                .foregroundStyle(on ? palette.ink : palette.muted)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .glassSegmentPill(on, fallback: palette.selectedControl)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier("git-diff-mode-\(value.rawValue)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
