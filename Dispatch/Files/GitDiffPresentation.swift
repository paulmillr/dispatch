import Foundation

/// One file's unified diff as the diff view draws it (F3a, F4a): its hunks, each line with its old and new numbers,
/// the runs of unmodified lines that fold, and the unmodified lines git left out between hunks. Pure, so the parsing and the fold rule are tested without a window;
/// `GitDiffView` adds colour and layout.
struct GitDiffPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case context, added, removed
    }

    struct Line: Equatable, Sendable {
        var kind: Kind
        /// The line's number in the old file (nil for an addition) and in the new one (nil for a removal).
        var old: Int?
        var new: Int?
        /// The line without its +, − or space marker.
        var text: String
        /// git printed "\ No newline at end of file" after it: this side of the file ends without one.
        var noNewline = false
    }

    struct Hunk: Equatable, Sendable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        /// "@@ -6,8 +8,12 @@", drawn in blue.
        var range: String
        /// What git names the hunk by after the range ("export async function handleWebhook"), muted; may be empty.
        var section: String
        /// The hunk's lines in `lines`.
        var lines: Range<Int>
    }

    /// A run of unmodified lines drawn as one "N unmodified lines" row until it is opened.
    struct Fold: Equatable, Sendable {
        /// The run's first line in `lines`, which also names the fold.
        var start: Int
        var count: Int
        var range: Range<Int> { start..<(start + count) }
    }

    /// The unmodified lines git left out before a hunk, from the numbers of the hunks on either side: `count` lines
    /// starting at `new` in the new file, which are `old`… in the old one.
    struct Gap: Equatable, Sendable {
        /// The hunk the gap precedes (never the first).
        var hunk: Int
        var old: Int
        var new: Int
        var count: Int
    }

    /// What the view draws, top to bottom. Hashable values double as stable row identities, so opening a fold
    /// keeps every other row's identity (and the scroll position).
    enum Row: Hashable, Sendable {
        case hunk(Int)
        case line(Int)
        case fold(start: Int, count: Int)
        /// The lines between two hunks as one "N unmodified lines" row (`Gap`), named by the hunk after it.
        case gap(hunk: Int, count: Int)
        /// One of those lines once its gap is opened, read from the file Source shows: its numbers on each side.
        case gapLine(old: Int, new: Int)
        /// git's "\ No newline at end of file" under the line it follows.
        case noNewline(Int)
        /// Source without the file: the new side's lines that the diff leaves out ("12 lines not in the diff").
        case omitted(after: Int, count: Int)
    }

    var lines: [Line] = []
    var hunks: [Hunk] = []
    var folds: [Fold] = []
    var gaps: [Gap] = []
    /// git said "Binary files … differ" (or printed a GIT binary patch) instead of lines.
    var binary = false
    /// The header lines worth showing when there are no hunks: "rename from …", "new file mode 100644", "old mode …".
    var notes: [String] = []

    var additions: Int { lines.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) } }
    var deletions: Int { lines.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) } }

    /// Runs of unmodified lines longer than this fold.
    static let foldThreshold = 3
    /// Unmodified lines kept beside a change when the run between it and the next folds, so every change keeps a line
    /// of context on each side.
    static let foldContext = 1

    // MARK: Parsing

    /// Parses `git diff` / `git show` output for one path. Lenient: a truncated diff parses up to its cut, a hunk ends
    /// at the first line that is not a hunk line once its counts run out (or earlier, at a header), and a combined
    /// diff of a merge (`@@@`) reads its first parent as the old side.
    static func parse(_ text: String) -> GitDiffPresentation {
        var result = GitDiffPresentation()
        var raw = text.contains("\r\n") ? text.replacingOccurrences(of: "\r\n", with: "\n") : text
        if raw.hasSuffix("\n") { raw.removeLast() }
        guard !raw.isEmpty else { return result }

        // The hunk being read: the next numbers and how many lines of each side it still holds.
        var inHunk = false
        var markers = 1
        var old = 0, new = 0
        var oldLeft = 0, newLeft = 0
        var hunkStart = 0

        func closeHunk() {
            guard inHunk else { return }
            result.hunks[result.hunks.count - 1].lines = hunkStart..<result.lines.count
            inHunk = false
        }

        for piece in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(piece)
            if line.hasPrefix("@@"), let header = Self.hunkHeader(line) {
                closeHunk()
                result.hunks.append(Hunk(oldStart: header.oldStart, oldCount: header.oldCount, newStart: header.newStart,
                                         newCount: header.newCount, range: header.range, section: header.section,
                                         lines: result.lines.count..<result.lines.count))
                inHunk = true
                markers = header.markers
                old = header.oldStart
                new = header.newStart
                oldLeft = header.oldCount
                newLeft = header.newCount
                hunkStart = result.lines.count
                continue
            }
            if inHunk {
                if line.hasPrefix("\\") {
                    // "\ No newline at end of file" (in the user's language when git is localised): it belongs to the
                    // line before it.
                    if result.lines.count > hunkStart { result.lines[result.lines.count - 1].noNewline = true }
                    continue
                }
                let exhausted = oldLeft <= 0 && newLeft <= 0
                if let parsed = Self.hunkLine(line, markers: markers), !(exhausted && !line.isEmpty) {
                    // An empty line inside a hunk is a context line whose space an editor or mailer stripped.
                    if exhausted && line.isEmpty { continue }
                    switch parsed.kind {
                    case .context:
                        result.lines.append(Line(kind: .context, old: old, new: new, text: parsed.text))
                        old += 1; new += 1; oldLeft -= 1; newLeft -= 1
                    case .added:
                        result.lines.append(Line(kind: .added, old: nil, new: new, text: parsed.text))
                        new += 1; newLeft -= 1
                    case .removed:
                        result.lines.append(Line(kind: .removed, old: old, new: nil, text: parsed.text))
                        old += 1; oldLeft -= 1
                    }
                    continue
                }
                closeHunk()
            }
            result.header(line)
        }
        closeHunk()
        result.folds = Self.folds(result.lines, hunks: result.hunks)
        result.gaps = Self.gaps(result.hunks)
        return result
    }

    /// One header line before (or between) hunks: whether the file is binary, and the lines worth showing when there
    /// are no hunks. The paths are the model's (`GitDiff.path`, `oldPath`), not read here.
    private mutating func header(_ line: String) {
        if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
            binary = true
        } else if ["rename from ", "rename to ", "copy from ", "copy to ", "new file mode ", "deleted file mode ",
                   "old mode ", "new mode ", "similarity index "].contains(where: line.hasPrefix) {
            notes.append(line)
        }
    }

    struct HunkHeader: Equatable {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var range: String
        var section: String
        /// Marker columns on each line: 1, or a combined diff's parent count.
        var markers: Int
    }

    /// "@@ -6,8 +8,12 @@ section" (a missing count is 1), or a combined diff's "@@@ -1,2 -1,3 +1,4 @@@".
    static func hunkHeader(_ line: String) -> HunkHeader? {
        let ats = line.prefix { $0 == "@" }.count
        guard ats >= 2 else { return nil }
        let fence = String(repeating: "@", count: ats)
        let body = line.dropFirst(ats)
        guard let close = body.range(of: " " + fence) else { return nil }
        let ranges = body[body.startIndex..<close.lowerBound].split(separator: " ")
        guard ranges.count == ats, let last = ranges.last, last.hasPrefix("+"), let first = ranges.first, first.hasPrefix("-"),
              let oldSide = side(first.dropFirst()), let newSide = side(last.dropFirst()) else { return nil }
        let after = body[close.upperBound...]
        let section = after.hasPrefix(" ") ? String(after.dropFirst()) : String(after)
        return HunkHeader(oldStart: oldSide.start, oldCount: oldSide.count, newStart: newSide.start, newCount: newSide.count,
                          range: String(line[..<close.upperBound]),
                          section: section.trimmingCharacters(in: .whitespaces), markers: ats - 1)

        func side(_ value: Substring) -> (start: Int, count: Int)? {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            guard parts.count > 1 else { return (start, 1) }
            guard parts.count == 2, let count = Int(parts[1]) else { return nil }
            return (start, count)
        }
    }

    /// A hunk line's kind and text, or nil when the line is not one (a header that ends the hunk).
    private static func hunkLine(_ line: String, markers: Int) -> (kind: Kind, text: String)? {
        if line.isEmpty { return (.context, "") }
        let prefix = line.prefix(markers)
        guard prefix.count == markers, prefix.allSatisfy({ $0 == " " || $0 == "+" || $0 == "-" }) else { return nil }
        let text = String(line.dropFirst(markers))
        // A combined diff marks a line per parent: a + anywhere is in the result, a − anywhere only in a parent.
        if prefix.contains("+") { return (.added, text) }
        if prefix.contains("-") { return (.removed, text) }
        return (.context, text)
    }

    /// The runs of unmodified lines longer than `foldThreshold`, keeping `foldContext` lines next to each change.
    static func folds(_ lines: [Line], hunks: [Hunk]) -> [Fold] {
        var result: [Fold] = []
        for hunk in hunks {
            var index = hunk.lines.lowerBound
            while index < hunk.lines.upperBound {
                guard lines[index].kind == .context else { index += 1; continue }
                let start = index
                while index < hunk.lines.upperBound, lines[index].kind == .context { index += 1 }
                let end = index
                guard end - start > foldThreshold else { continue }
                // The run's ends that touch a change keep their context; a hunk's own edges need none.
                let low = start == hunk.lines.lowerBound ? start : start + foldContext
                let high = end == hunk.lines.upperBound ? end : end - foldContext
                // A run of four or more keeps at most one line at each end: two or more always fold.
                result.append(Fold(start: low, count: high - low))
            }
        }
        return result
    }

    /// The stretches between consecutive hunks. A side of a hunk with no lines names the line before it (`-5,0`), so
    /// its next line is the start plus one rather than the start plus the count.
    static func gaps(_ hunks: [Hunk]) -> [Gap] {
        guard hunks.count > 1 else { return [] }
        func after(start: Int, count: Int) -> Int { count == 0 ? start + 1 : start + count }
        func first(start: Int, count: Int) -> Int { count == 0 ? start + 1 : start }
        var result: [Gap] = []
        for index in 1..<hunks.count {
            let previous = hunks[index - 1], next = hunks[index]
            let new = after(start: previous.newStart, count: previous.newCount)
            let count = first(start: next.newStart, count: next.newCount) - new
            guard count > 0 else { continue }
            result.append(Gap(hunk: index, old: after(start: previous.oldStart, count: previous.oldCount), new: new,
                              count: count))
        }
        return result
    }

    // MARK: Rows

    /// The Diff rows: each hunk's header and lines, closed folds as one row, and before every hunk but the first the
    /// lines git left out (F3a's "2 unmodified lines"). `opened` holds the `Fold.start` of every fold the user opened,
    /// `openedGaps` the `Gap.hunk` of every gap; `allOpen` opens them all (⌥-click). An opened gap shows its lines only
    /// once the file is read (`sourceLines`, its line count) and holds them; until then it stays one row.
    func rows(opened: Set<Int> = [], allOpen: Bool = false, openedGaps: Set<Int> = [], sourceLines: Int? = nil) -> [Row] {
        var result: [Row] = []
        result.reserveCapacity(lines.count + hunks.count)
        var closed: [Int: Int] = [:]
        if !allOpen { for fold in folds where !opened.contains(fold.start) { closed[fold.start] = fold.count } }
        var gapBefore: [Int: Gap] = [:]
        for gap in gaps { gapBefore[gap.hunk] = gap }
        for (number, hunk) in hunks.enumerated() {
            if let gap = gapBefore[number] {
                if allOpen || openedGaps.contains(number), let sourceLines, gap.new + gap.count - 1 <= sourceLines {
                    for offset in 0..<gap.count { result.append(.gapLine(old: gap.old + offset, new: gap.new + offset)) }
                } else {
                    result.append(.gap(hunk: number, count: gap.count))
                }
            }
            result.append(.hunk(number))
            var index = hunk.lines.lowerBound
            while index < hunk.lines.upperBound {
                if let count = closed[index] {
                    result.append(.fold(start: index, count: count))
                    index += count
                    continue
                }
                result.append(.line(index))
                if lines[index].noNewline { result.append(.noNewline(index)) }
                index += 1
            }
        }
        return result
    }

    /// Source when the file itself is not to hand: the new side's lines the diff holds (unmodified and added) with
    /// their numbers, and a row for each stretch it leaves out.
    func newSideRows() -> [Row] {
        var result: [Row] = []
        var next = 1
        for hunk in hunks {
            let shown = hunk.lines.filter { lines[$0].kind != .removed }
            guard let first = shown.first, let start = lines[first].new else { continue }
            if start > next { result.append(.omitted(after: next - 1, count: start - next)) }
            for index in shown {
                result.append(.line(index))
                if lines[index].noNewline { result.append(.noNewline(index)) }
            }
            // An unmodified or added line always has a new number.
            next = (shown.last.flatMap { lines[$0].new } ?? start) + 1
        }
        return result
    }
}

/// The words of the Review tab and the diff header (F3a), kept apart from the views so they are tested as text.
enum GitChangesText {
    /// "main", or "detached at 3f2c1a0" on a detached HEAD: the Changes and Commits headers and the Files footer all
    /// name the checkout this way.
    static func branch(_ status: GitStatus) -> String {
        if let branch = status.branch { return branch }
        return status.head.map { "detached at \(String($0.prefix(7)))" } ?? "detached HEAD"
    }

    /// "showing the first 2,000" after the counts of a status cut at the helper's bound.
    static func truncated(_ status: GitStatus) -> String {
        "showing the first \(FilesFormatting.count(status.changes.count))"
    }


    /// "Staged", "Unstaged", "Untracked".
    static func title(_ area: GitChangeArea) -> String {
        switch area {
        case .staged: "Staged"
        case .unstaged: "Unstaged"
        case .untracked: "Untracked"
        }
    }

    /// The folder line under a change's name: its folder, or for a rename or copy "src/old.ts → src/new.ts".
    static func folder(_ change: GitChange) -> String {
        if let oldPath = change.oldPath, change.kind == .renamed || change.kind == .copied {
            return "\(oldPath) → \(change.path)"
        }
        return change.folder
    }

    /// A fold's or a gap's "1 unmodified line", "6 unmodified lines".
    static func unmodified(_ count: Int) -> String {
        "\(FilesFormatting.count(count)) unmodified \(count == 1 ? "line" : "lines")"
    }

    /// "+8 −5", "+3", "−2", "0": what the row and the totals show. Nil before the counts load.
    static func counts(additions: Int?, deletions: Int?) -> (plus: String?, minus: String?)? {
        guard additions != nil || deletions != nil else { return nil }
        let plus = additions.flatMap { $0 > 0 ? "+\(FilesFormatting.count($0))" : nil }
        let minus = deletions.flatMap { $0 > 0 ? "−\(FilesFormatting.count($0))" : nil }
        return (plus, minus)
    }

    /// "binary · 48 KB → 51 KB", "binary · 51 KB" (added), "binary · 48 KB → deleted", or "binary" without sizes.
    static func binary(old: UInt64?, new: UInt64?, kind: GitChangeKind? = nil) -> String {
        switch (old, new) {
        case let (old?, new?) where kind == .added && old == 0: return "binary · \(FilesFormatting.size(new))"
        case let (old?, new?) where kind == .deleted && new == 0: return "binary · \(FilesFormatting.size(old)) → deleted"
        case let (old?, new?): return "binary · \(FilesFormatting.size(old)) → \(FilesFormatting.size(new))"
        case let (nil, new?): return "binary · \(FilesFormatting.size(new))"
        case let (old?, nil): return "binary · \(FilesFormatting.size(old)) → deleted"
        case (nil, nil): return "binary"
        }
    }

    /// What Source says when it has no lines: a deletion has no current file; a read file can be empty; without the
    /// file (`read` false) a diff of no hunks (a rename, a mode change) says what changed through its header lines, and
    /// one whose hunks only remove lines left the file empty.
    static func emptySource(_ presentation: GitDiffPresentation, kind: GitChangeKind?, read: Bool) -> String {
        if kind == .deleted || presentation.notes.contains(where: { $0.hasPrefix("deleted file mode ") }) {
            return "Deleted · there is no current file"
        }
        if !read, presentation.hunks.isEmpty {
            return presentation.notes.isEmpty ? "No lines in the diff" : presentation.notes.joined(separator: "\n")
        }
        return "The file is empty"
    }

    /// The changes in list order: staged, unstaged, untracked, each as the status lists them.
    static func ordered(_ status: GitStatus) -> [GitChange] {
        GitChangeArea.allCases.flatMap { status.changes(in: $0) }
    }

    /// The selection after ↑ (-1) or ↓ (+1), clamped at the ends; the first change when nothing is selected.
    static func moved(_ selection: String?, by delta: Int, in changes: [GitChange]) -> String? {
        guard !changes.isEmpty else { return nil }
        guard let selection, let index = changes.firstIndex(where: { $0.id == selection }) else {
            return delta < 0 ? changes.last?.id : changes.first?.id
        }
        return changes[min(max(index + delta, 0), changes.count - 1)].id
    }

    /// What stays selected when the status changes under the list: the same change; else the same path in another
    /// area (`git add` moved it from Unstaged to Staged); else the change now where it was; else the first.
    static func reconciled(_ selection: String?, previous: [GitChange], current: [GitChange]) -> String? {
        guard !current.isEmpty else { return nil }
        guard let selection else { return current.first?.id }
        if current.contains(where: { $0.id == selection }) { return selection }
        if let old = previous.first(where: { $0.id == selection }) {
            if let moved = current.first(where: { $0.path == old.path }) { return moved.id }
            if let index = previous.firstIndex(of: old) { return current[min(index, current.count - 1)].id }
        }
        return current.first?.id
    }
}
