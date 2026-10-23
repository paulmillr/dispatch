import Foundation
import Observation
import SwiftUI

// The diff screen's model (R2–R4, S5), apart from its views so the rows, the comments' places, the selection and the
// saving are tested without a window: the change's diff as rows (Diff, or the whole file as Source), each review
// comment placed on its rows the way the Mac's diff places it (`ReviewPlacement`), the comments whose quoted lines left
// the file (`ReviewRefresh.relocate`), and the lines selected for a new comment.

/// What the diff screen shows: the change's unified diff, or the whole file with the diff's added lines tinted.
enum ReviewDiffMode: String, CaseIterable, Hashable, Sendable {
    case diff, source

    var title: String { self == .diff ? "Diff" : "Source" }
}

/// One row of the diff screen.
struct ReviewDiffRow: Identifiable, Equatable, Sendable {
    /// Stable across opening a fold or a gap, so the other rows keep their identity (and the scroll position).
    enum ID: Hashable, Sendable {
        case diff(GitDiffPresentation.Row)
        /// Source's line, zero-based.
        case source(Int)
        /// The diff was cut at the helper's bound here.
        case truncated
    }

    enum Content: Equatable, Sendable {
        /// "@@ -38,12 +41,17 @@ export function Sidebar() {".
        case hunk(String)
        /// A line of code: its kind and its numbers on each side (Source: the new side's only).
        case code(GitDiffPresentation.Kind, old: Int?, new: Int?)
        /// Unmodified lines inside a hunk, folded until opened.
        case fold(count: Int)
        /// Unmodified lines git left out between hunks, read from the file when opened.
        case gap(count: Int)
        /// git's "\ No newline at end of file".
        case noNewline
        /// Source without the file: new-side lines the diff does not hold.
        case omitted(count: Int)
        case truncated
    }

    let id: ID
    let content: Content
    /// A code row's text (without its marker).
    var text = ""
    /// Where a comment on this row goes and how it quotes the row; nil: no comment goes on it.
    var line: ReviewLine?
    var quote: ReviewQuote?

    var commentable: Bool { line != nil }
    /// The taller rows: a fold's and a gap's.
    var tall: Bool {
        switch content {
        case .fold, .gap: true
        default: false
        }
    }
}

/// The change's diff and the file as read, coloured once: what the rows are made of.
struct ReviewDiffDocument: Equatable {
    let diff: GitDiff
    let presentation: GitDiffPresentation
    /// The working-tree file: its lines, gone (deleted), or unknown (binary, too large, unreadable).
    private(set) var file: ReviewRefresh.File
    /// The diff's lines in the file's colours (by `presentation.lines` index), and the file's.
    private(set) var colored: [AttributedString]
    private(set) var coloredSource: [AttributedString] = []
    /// The new side's numbers of the diff's added lines: Source tints them.
    let addedLines: Set<Int>

    /// Longer lines are cut before they are drawn (the row truncates them anyway).
    static let lineLimit = 400

    /// The same diff and file (the colours follow from them); cheap while both share their storage.
    static func == (lhs: ReviewDiffDocument, rhs: ReviewDiffDocument) -> Bool {
        lhs.diff == rhs.diff && lhs.file == rhs.file
    }

    init(diff: GitDiff, file text: String?, gone: Bool = false) {
        self.diff = diff
        let presentation = GitDiffPresentation.parse(diff.text)
        self.presentation = presentation
        colored = Self.color(presentation, path: diff.path)
        addedLines = Set(presentation.lines.compactMap { $0.kind == .added ? $0.new : nil })
        file = .unknown
        setFile(text, gone: gone)
    }

    mutating func setFile(_ text: String?, gone: Bool = false) {
        if let text {
            let lines = ReviewRefresh.lines(text)
            file = .lines(lines)
            coloredSource = Self.color(lines: lines, path: diff.path)
        } else {
            file = gone ? .gone : .unknown
            coloredSource = []
        }
    }

    var fileLines: [String]? {
        if case .lines(let lines) = file { return lines }
        return nil
    }

    var path: String { diff.path }
    var binary: Bool { diff.binary || presentation.binary }
    /// Nothing to draw as lines: a binary file, or a diff of no hunks (a mode change, an empty file).
    var empty: Bool { presentation.hunks.isEmpty }

    // MARK: Rows

    /// The rows of `mode`. Diff: each hunk's header and lines, the folds not in `opened` as one row each, the gaps
    /// between hunks one row each unless in `openedGaps` and the file is read. Source: the file's lines, else the new
    /// side's lines the diff holds with a row for each stretch it leaves out.
    func rows(_ mode: ReviewDiffMode, opened: Set<Int> = [], openedGaps: Set<Int> = []) -> [ReviewDiffRow] {
        var result: [ReviewDiffRow]
        switch mode {
        case .diff:
            let lines = fileLines
            result = presentation.rows(opened: opened, openedGaps: openedGaps, sourceLines: lines?.count).map(row)
        case .source:
            if let lines = fileLines {
                result = lines.enumerated().map { index, text in
                    let number = index + 1
                    let kind: GitDiffPresentation.Kind = addedLines.contains(number) ? .added : .context
                    return ReviewDiffRow(id: .source(index), content: .code(kind, old: nil, new: number), text: text,
                                         line: ReviewLine(side: .new, number: number),
                                         quote: ReviewQuote(kind: kind == .added ? .added : .context, text: text))
                }
            } else {
                result = presentation.newSideRows().map(row)
            }
        }
        if diff.truncated, mode == .diff { result.append(ReviewDiffRow(id: .truncated, content: .truncated)) }
        return result
    }

    private func row(_ row: GitDiffPresentation.Row) -> ReviewDiffRow {
        switch row {
        case .hunk(let index):
            let hunk = presentation.hunks[index]
            return ReviewDiffRow(id: .diff(row), content: .hunk(hunk.section.isEmpty ? hunk.range : hunk.range + " " + hunk.section))
        case .line(let index):
            let line = presentation.lines[index]
            let found: (ReviewLine, ReviewQuote)? = switch line.kind {
            case .removed: line.old.map { (ReviewLine(side: .old, number: $0), ReviewQuote(kind: .removed, text: line.text)) }
            case .added: line.new.map { (ReviewLine(side: .new, number: $0), ReviewQuote(kind: .added, text: line.text)) }
            case .context: line.new.map { (ReviewLine(side: .new, number: $0), ReviewQuote(kind: .context, text: line.text)) }
            }
            return ReviewDiffRow(id: .diff(row), content: .code(line.kind, old: line.old, new: line.new), text: line.text,
                                 line: found?.0, quote: found?.1)
        case .fold(_, let count):
            return ReviewDiffRow(id: .diff(row), content: .fold(count: count))
        case .gap(_, let count):
            return ReviewDiffRow(id: .diff(row), content: .gap(count: count))
        case .gapLine(let old, let new):
            let text = fileLines.flatMap { $0.indices.contains(new - 1) ? $0[new - 1] : nil } ?? ""
            return ReviewDiffRow(id: .diff(row), content: .code(.context, old: old, new: new), text: text,
                                 line: ReviewLine(side: .new, number: new), quote: ReviewQuote(kind: .context, text: text))
        case .noNewline:
            return ReviewDiffRow(id: .diff(row), content: .noNewline)
        case .omitted(_, let count):
            return ReviewDiffRow(id: .diff(row), content: .omitted(count: count))
        }
    }

    /// A code row's text in the file's colours.
    func attributed(_ row: ReviewDiffRow) -> AttributedString {
        switch row.id {
        case .diff(.line(let index)) where colored.indices.contains(index): return colored[index]
        case .diff(.gapLine(_, let new)) where coloredSource.indices.contains(new - 1): return coloredSource[new - 1]
        case .source(let index) where coloredSource.indices.contains(index): return coloredSource[index]
        default: return Self.plain(row.text)
        }
    }

    private static func plain(_ text: String) -> AttributedString {
        var result = AttributedString(TextRendering.visible(bounded(text)))
        result.foregroundColor = CodeSyntax.Role.plain.color
        return result
    }

    private static func bounded(_ text: String) -> String {
        text.count > lineLimit ? String(text.prefix(lineLimit)) + "…" : text
    }

    /// Each side of a hunk coloured as one text (as the Mac does), so a string or comment spanning lines colours
    /// through and a removed line never changes how an added one lexes; unmodified lines take the new side's colours.
    static func color(_ presentation: GitDiffPresentation, path: String) -> [AttributedString] {
        var result = presentation.lines.map { plain($0.text) }
        guard CodeSyntax.language(path) != "text" else { return result }
        for hunk in presentation.hunks {
            let lines = Array(hunk.lines)
            for side in [GitDiffPresentation.Kind.removed, .added] {
                let members = lines.filter { presentation.lines[$0].kind == .context || presentation.lines[$0].kind == side }
                let joined = members.map { bounded(presentation.lines[$0].text) }.joined(separator: "\n")
                guard !members.isEmpty, joined.utf16.count <= CodeSyntax.limit else { continue }
                let colored = CodeSyntax.lines(joined, language: path)
                guard colored.count == members.count else { continue }
                for (position, member) in members.enumerated() where presentation.lines[member].kind == side || side == .added {
                    result[member] = colored[position]
                }
            }
        }
        return result
    }

    static func color(lines: [String], path: String) -> [AttributedString] {
        let joined = lines.map(bounded).joined(separator: "\n")
        guard CodeSyntax.language(path) != "text", joined.utf16.count <= CodeSyntax.limit else { return lines.map(plain) }
        let colored = CodeSyntax.lines(joined, language: path)
        return colored.count == lines.count ? colored : lines.map(plain)
    }

    // MARK: Comments

    /// The comments whose quoted lines are no longer in the file (S5), once the file is read: found again neither in
    /// the file (the new side) nor among the diff's removed lines (the old side). Unknown when the file is.
    func outdated(_ comments: [ReviewComment]) -> Set<UUID> {
        if case .unknown = file { return [] }
        let relocated = ReviewRefresh.relocate(comments, file: file, diffs: [presentation])
        return Set(relocated.filter { $0.outdated == true }.map(\.id))
    }

    /// The folds and gaps holding a line a comment is on, so they show open (the Mac opens such folds too): placed
    /// among the rows with everything open.
    func holding(_ comments: [ReviewComment]) -> (folds: Set<Int>, gaps: Set<Int>) {
        let lined = comments.filter { !$0.onFile }
        guard !lined.isEmpty, !presentation.folds.isEmpty || !presentation.gaps.isEmpty else { return ([], []) }
        let all = rows(.diff, opened: Set(presentation.folds.map(\.start)), openedGaps: Set(presentation.gaps.map(\.hunk)))
        let layout = ReviewDiffLayout(rows: all, comments: lined)
        var folds: Set<Int> = [], gaps: Set<Int> = []
        for range in layout.ranges.values {
            for index in range {
                switch all[index].id {
                case .diff(.line(let line)):
                    if let fold = presentation.folds.first(where: { $0.range.contains(line) }) { folds.insert(fold.start) }
                case .diff(.gapLine(_, let new)):
                    if let gap = presentation.gaps.first(where: { ($0.new..<($0.new + $0.count)).contains(new) }) {
                        gaps.insert(gap.hunk)
                    }
                default: break
                }
            }
        }
        return (folds, gaps)
    }
}

/// The comments among the rows: each placed comment's rows (tinted, its chip on the first, its card under the last),
/// and the ones that show as cards above the diff (on the file, or not among the rows).
struct ReviewDiffLayout: Equatable {
    var rows: [ReviewDiffRow]
    /// Each placed comment's rows, first to last, as indices in `rows`.
    var ranges: [UUID: ClosedRange<Int>] = [:]
    /// The comments as placed: one found on another line names the line it is on now.
    var comments: [UUID: ReviewComment] = [:]
    /// Cards above the diff, in the review's order: comments on the file, then those not among the rows.
    var top: [ReviewComment] = []
    /// Per row, the comments whose range starts there: its chip and count.
    var chips: [Int: [UUID]] = [:]
    /// The file's comments in the order the stepper goes through them: the file's own first, then by line.
    var order: [UUID] = []

    init(rows: [ReviewDiffRow], comments: [ReviewComment]) {
        self.rows = rows
        var candidates: [ReviewPlacement.Candidate] = []
        var candidateRows: [Int] = []
        for (index, row) in rows.enumerated() {
            guard let line = row.line, let quote = row.quote else { continue }
            candidates.append(.init(line: line, text: quote.text))
            candidateRows.append(index)
        }
        let placed = ReviewPlacement.place(comments, among: candidates)
        var unplaced: [ReviewComment] = []
        for comment in comments {
            guard let found = placed[comment.id] else {
                self.comments[comment.id] = comment
                unplaced.append(comment)
                continue
            }
            let moved = comment.moved(to: candidates[found].line)
            self.comments[comment.id] = moved
            let last = candidateRows[found]
            // From its first line (the nearest row above the last with that line) to where it lands.
            let first = moved.start.flatMap { start in
                candidateRows.prefix(found + 1).last { rows[$0].line == start }
            } ?? last
            ranges[comment.id] = first...last
            chips[first, default: []].append(comment.id)
        }
        top = Review(comments: unplaced).files.flatMap(\.comments)
        let ordered = Review(comments: comments.map { self.comments[$0.id] ?? $0 }).files.flatMap(\.comments)
        order = ordered.map(\.id)
        for (row, ids) in chips { chips[row] = ids.sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) } }
    }

    /// The rows a comment tints: placed comments' ranges.
    func commented(_ row: Int) -> Bool { ranges.values.contains { $0.contains(row) } }
}

// MARK: Selection

/// R3: the lines picked for a new comment, from where the selection started (`anchor`) to where it was extended
/// (`head`), as row indices. Both ends are always rows a comment can go on.
struct ReviewDiffSelection: Equatable, Sendable {
    var anchor: Int
    var head: Int

    var rows: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }

    /// A tap on `row`: selects it; with a selection, extends (or shrinks) it to the row; tapping the only selected
    /// row clears it. Rows that take no comment do nothing.
    static func tap(_ selection: ReviewDiffSelection?, row: Int, in rows: [ReviewDiffRow]) -> ReviewDiffSelection? {
        guard rows.indices.contains(row), rows[row].commentable else { return selection }
        guard var selection else { return ReviewDiffSelection(anchor: row, head: row) }
        if selection.anchor == row, selection.head == row { return nil }
        selection.head = row
        return selection
    }

    /// A handle dragged to `row`: the top handle (`top`) moves the first line, the bottom one the last; the other end
    /// stays. The row is clamped to the rows and to the nearest commentable row towards the end that stays.
    func moving(top: Bool, to row: Int, in rows: [ReviewDiffRow]) -> ReviewDiffSelection {
        let fixed = top ? self.rows.upperBound : self.rows.lowerBound
        return ReviewDiffSelection(anchor: fixed, head: Self.clamp(row, towards: fixed, in: rows))
    }

    /// `row` within the rows, stepped towards `anchor` until a comment can go on it.
    static func clamp(_ row: Int, towards anchor: Int, in rows: [ReviewDiffRow]) -> Int {
        guard !rows.isEmpty else { return anchor }
        var row = min(max(row, 0), rows.count - 1)
        while row != anchor, !rows[row].commentable { row += row < anchor ? 1 : -1 }
        return row
    }

    /// The comment's first and last lines and its quote: the commentable rows in the range.
    func draft(in rows: [ReviewDiffRow]) -> (start: ReviewLine, end: ReviewLine, quote: [ReviewQuote])? {
        let picked = self.rows.clamped(to: 0...max(0, rows.count - 1)).filter { rows.indices.contains($0) && rows[$0].commentable }
        guard let first = picked.first, let last = picked.last, let start = rows[first].line, let end = rows[last].line
        else { return nil }
        return (start, end, picked.compactMap { rows[$0].quote })
    }
}

// MARK: Words

enum ReviewDiffText {
    /// The selection pill's "Comment on 45–48", "Comment on line 42", "Comment on removed line 39".
    static func pill(start: ReviewLine, end: ReviewLine) -> String {
        if start.side != end.side { return "Comment on these lines" }
        let removed = end.side == .old ? "removed " : ""
        if start == end { return "Comment on \(removed)line \(end.number)" }
        return "Comment on \(removed)\(start.number)–\(end.number)"
    }

    /// S5's "was lines 12–14", "was line 12".
    static func was(_ comment: ReviewComment) -> String {
        let location = ReviewText.location(comment)
        guard let first = location.first else { return location }
        return "was " + first.lowercased() + location.dropFirst()
    }

    /// The card's "Line 42 · 2m".
    static func header(_ comment: ReviewComment, now: Date) -> (location: String, age: String) {
        (ReviewText.location(comment), FilesFormatting.age(comment.created, at: now))
    }

    /// The status letter as `GitStatusBadge` draws it: untracked "?", conflicted "U".
    static func letter(_ kind: GitChangeKind) -> String {
        switch kind {
        case .untracked: "?"
        case .conflicted: "U"
        default: kind.rawValue
        }
    }

    /// "src/components", nil at the repository's root.
    static func folder(_ path: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

// MARK: Comments

/// A comment being written (R4): on lines, on the file (no lines), or an edit of a saved comment.
struct ReviewDiffDraft: Equatable, Sendable {
    var start: ReviewLine?
    var end: ReviewLine?
    var quote: [ReviewQuote]
    /// The saved comment it edits; nil for a new one.
    var editing: UUID?
    var text = ""

    var location: String { ReviewText.location(start: start, end: end) }
}

/// Saving, editing and deleting a file's comments in the review (`ReviewRepository`, the Mac's `reviews.json` model):
/// fields as the Mac writes them, so either app's Create review renders them the same (`ReviewText`).
@MainActor
struct ReviewDiffComments {
    let repository: ReviewRepository
    let scope: String
    /// Repository-relative.
    let path: String
    /// The diff the comments are written on.
    let area: GitChangeArea?

    /// Saves the draft: a new comment (its id and date from `System`), or the edited comment's text. Nil for an empty
    /// text.
    @discardableResult func save(_ draft: ReviewDiffDraft) -> UUID? {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = draft.editing {
            repository.update(id, text: text, in: scope)
            return id
        }
        let comment = ReviewComment(id: System.uuid(), path: path, start: draft.start, end: draft.end, quote: draft.quote,
                                    text: text, created: System.date(), area: area)
        repository.add(comment, to: scope)
        return comment.id
    }

    func delete(_ id: UUID) { repository.remove(id, from: scope) }

    /// S5's Keep for the file: the outdated comment stays, on the file as a whole (no lines), its quote kept so the
    /// agent still sees what it was about.
    func keepForFile(_ id: UUID) {
        guard var comment = repository.review(scope).comments.first(where: { $0.id == id }) else { return }
        comment.start = nil
        comment.end = nil
        comment.outdated = nil
        repository.remove(id, from: scope)
        repository.add(comment, to: scope)
    }
}

// MARK: Model

/// The diff screen's state: what was read, the mode, the opened folds and gaps, the open comment card, the selection
/// and the composer. One per screen (an iPad pane keeps its own).
@MainActor @Observable
final class ReviewDiffModel {
    enum Load: Equatable {
        case loading
        case loaded(ReviewDiffDocument)
        case failed(String)
        /// No reader: the host is offline or does not grant git.
        case unavailable(String)
    }

    let path: String
    let area: GitChangeArea?
    private(set) var load: Load = .loading
    /// The change as the status lists it (counts, kind); a stand-in until the status is read.
    private(set) var change: GitChange
    var mode: ReviewDiffMode = .diff
    var openedFolds: Set<Int> = []
    var openedGaps: Set<Int> = []
    /// The comment whose card shows under its lines.
    var open: UUID?
    /// Cards above the diff closed with × for this visit.
    var dismissed: Set<UUID> = []
    var selection: ReviewDiffSelection?
    /// The Comment button with nothing selected: the bar says to tap the lines.
    var hinting = false
    var draft: ReviewDiffDraft?
    /// The composer raises the keyboard when it opens (not for the Debug demo's still).
    var focusDraft = true
    /// A row or card to scroll to; the view clears it.
    var scroll: ReviewDiffScroll?

    init(path: String, area: GitChangeArea?) {
        self.path = path
        self.area = area
        change = GitChange(path: path, kind: area == .untracked ? .untracked : .modified, area: area ?? .unstaged)
    }

    var document: ReviewDiffDocument? {
        if case .loaded(let document) = load { return document }
        return nil
    }

    /// Reads the change's diff and the file through the repository's reader (the status first, when Review has not
    /// read it yet). Both before the first draw, so outdated cards never pop in.
    /// `refresh`: an agent's turn ended or the app came back: the status is read again too, and a diff that did not
    /// change leaves the screen as it is (scroll position, open card, selection and composer stay either way).
    func reload(_ context: ReviewContext, refresh: Bool = false) async {
        let changes = context.review.changes(context.place)
        if changes.status == nil || refresh { await changes.refresh() }
        if let found = Self.change(path: path, area: area, in: changes.status) { change = found }
        guard let reader = changes.reader else {
            load = .unavailable("\(context.host.isEmpty ? "The host" : context.host) can’t be read now.")
            return
        }
        let root = context.place.root, change = change
        let deleted = change.kind == .deleted
        do {
            async let diff = reader.diff(root, change)
            async let text: String? = deleted ? nil : (try? await reader.text(FilesPath.join(root, change.path)))
            let read = try await diff
            let document = ReviewDiffDocument(diff: read, file: await text, gone: deleted)
            if document != self.document { load = .loaded(document) }
        } catch {
            if document == nil { load = .failed(error.localizedDescription) }
        }
    }

    /// The change at `path` in `area`, else the path's first.
    static func change(path: String, area: GitChangeArea?, in status: GitStatus?) -> GitChange? {
        let changes = status?.changes.filter { $0.path == path } ?? []
        return changes.first { $0.area == area } ?? changes.first
    }

    /// The comments this diff shows: the file's, those written on another area's diff left out while the file is
    /// changed in both (`ReviewComment.shows`).
    func comments(_ review: Review, status: GitStatus?) -> [ReviewComment] {
        let own = area ?? change.area
        var areas = Set(status?.changes.filter { $0.path == path }.map(\.area) ?? [])
        areas.insert(own)
        return review.comments(on: path).filter { $0.shows(in: own, areas: areas) }
    }

    // MARK: Layout (cached per input)

    private struct LayoutKey: Equatable {
        var mode: ReviewDiffMode
        var folds: Set<Int>
        var gaps: Set<Int>
        var comments: [ReviewComment]
        var document: ReviewDiffDocument
    }

    @ObservationIgnored private var layoutKey: LayoutKey?
    @ObservationIgnored private var cached: (layout: ReviewDiffLayout, outdated: Set<UUID>)?

    /// The rows with the comments placed, and the outdated comments (S5's cards).
    func layout(_ comments: [ReviewComment]) -> (layout: ReviewDiffLayout, outdated: Set<UUID>)? {
        guard let document else { return nil }
        let key = LayoutKey(mode: mode, folds: openedFolds, gaps: openedGaps, comments: comments, document: document)
        if key == layoutKey, let cached { return cached }
        let held = mode == .diff ? document.holding(comments) : (folds: [], gaps: [])
        let rows = document.rows(mode, opened: openedFolds.union(held.folds), openedGaps: openedGaps.union(held.gaps))
        let result = (ReviewDiffLayout(rows: rows, comments: comments), document.outdated(comments))
        layoutKey = key
        cached = result
        return result
    }

    // MARK: Actions

    func tap(_ row: Int, rows: [ReviewDiffRow]) {
        guard draft == nil else { return }
        let next = ReviewDiffSelection.tap(selection, row: row, in: rows)
        guard next != selection else { return }
        if next != nil { open = nil; hinting = false }
        selection = next
    }

    func clearSelection() {
        selection = nil
        hinting = false
    }

    /// The selection pill's tap: the composer on the selected lines.
    func compose(rows: [ReviewDiffRow]) {
        guard let picked = selection?.draft(in: rows) else { return }
        draft = ReviewDiffDraft(start: picked.start, end: picked.end, quote: picked.quote)
    }

    func composeOnFile() {
        selection = nil
        hinting = false
        open = nil
        draft = ReviewDiffDraft(start: nil, end: nil, quote: [])
    }

    func edit(_ comment: ReviewComment) {
        selection = nil
        hinting = false
        draft = ReviewDiffDraft(start: comment.start, end: comment.end, quote: comment.quote, editing: comment.id,
                                text: comment.text)
    }

    func cancelDraft() {
        draft = nil
        focusDraft = true
        selection = nil
    }

    /// Send: saves the draft; a new comment on lines opens its card.
    func send(_ comments: ReviewDiffComments) {
        guard let draft, let id = comments.save(draft) else { return }
        self.draft = nil
        focusDraft = true
        selection = nil
        if draft.end != nil { open = id }
    }

    func toggle(_ id: UUID) {
        open = open == id ? nil : id
        if open != nil { scroll = .comment(id) }
    }

    /// The card's stepper: the previous (-1) or next (1) of the file's comments, wrapping around.
    func step(_ delta: Int, order: [UUID]) {
        guard !order.isEmpty else { return }
        let index = open.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : order.count)
        let next = order[(index + delta + order.count) % order.count]
        open = next
        dismissed.remove(next)
        scroll = .comment(next)
    }

    /// Opens a fold or a gap row.
    func expand(_ row: ReviewDiffRow) {
        guard case .diff(let id) = row.id else { return }
        switch id {
        case .fold(let start, _): openedFolds.insert(start)
        case .gap(let hunk, _): openedGaps.insert(hunk)
        default: break
        }
    }
}

/// Where the diff screen scrolls next.
enum ReviewDiffScroll: Equatable {
    case comment(UUID)
    case row(ReviewDiffRow.ID)
}
