import Foundation

// The Review tab: the uncommitted changes, where every line can take a comment, and Create review turns the comments
// into one text for a coding agent (copied to the clipboard). The model, where comments land among a diff's rows, and
// the text are here, pure; `ReviewRepository` keeps the comments, `GitDiffView` and `ReviewViews` draw them.

/// A line a comment is on: its number in the old file (a removed line) or in the new one (an added or unmodified line,
/// or a line of Source).
struct ReviewLine: Codable, Hashable, Sendable {
    enum Side: String, Codable, Hashable, Sendable { case old, new }
    var side: Side
    var number: Int
}

/// A commented line as it read when the comment was written, and how the diff marked it.
struct ReviewQuote: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case context, added, removed }
    var kind: Kind
    var text: String
}

/// One comment: on a run of lines (`start` to `end` as the diff lists them, the same line for one), or on the file
/// as a whole (both nil).
struct ReviewComment: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// Repository-relative.
    var path: String
    var start: ReviewLine?
    var end: ReviewLine?
    /// The lines from `start` to `end`; its last line is what finds the comment's place again once the file changes.
    var quote: [ReviewQuote]
    var text: String
    var created: Date
    /// The diff it was written on. While the file is both staged and changed again it shows on that diff only (the two
    /// number the new side differently); once the file is in one area, there.
    var area: GitChangeArea?
    /// Set by Create review's last look at the file (`ReviewRefresh`): its line is no longer there. Never stored.
    var outdated: Bool?

    var onFile: Bool { end == nil }

    /// The comment on the line found at `end`: a start on the same side moves with it.
    func moved(to end: ReviewLine) -> ReviewComment {
        guard let old = self.end, old != end else { return self }
        var moved = self
        moved.end = end
        if let start, start.side == end.side, old.side == end.side {
            moved.start = ReviewLine(side: start.side, number: max(1, start.number + end.number - old.number))
        }
        return moved
    }

    /// Whether the diff of `path` in `area` shows it, the file's changes being in `areas`.
    func shows(in area: GitChangeArea, areas: Set<GitChangeArea>) -> Bool {
        guard let own = self.area, areas.contains(own) else { return true }
        return own == area
    }
}

extension GitChangeArea: Codable {}

/// The comments on one repository's working tree (on one host) and the overall comment Create review asks for.
struct Review: Codable, Hashable, Sendable {
    var comments: [ReviewComment] = []
    var summary = ""
    /// When it last changed: a review left alone for `ReviewRepository.expiry` is dropped.
    var modified: Date?

    var isEmpty: Bool { comments.isEmpty && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func comments(on path: String) -> [ReviewComment] { comments.filter { $0.path == path } }

    /// The commented files in path order, and each file's comments: the file's own first, then by line.
    var files: [(path: String, comments: [ReviewComment])] {
        Dictionary(grouping: comments, by: \.path)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value.sorted(by: Self.order)) }
    }

    private static func order(_ a: ReviewComment, _ b: ReviewComment) -> Bool {
        switch (a.end, b.end) {
        case (nil, nil): return a.created < b.created
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x.number != y.number ? x.number < y.number : a.created < b.created
        }
    }
}

/// The comment being written in a tab (`FilesSession.reviewDraft`): where it goes, or which comment it edits. Its
/// text is kept apart (`FilesSession.reviewDraftText`), so typing re-renders nothing.
struct ReviewDraft: Equatable, Sendable {
    /// The draft's identity: it moves with a new comment that moves to another line.
    var id: UUID
    /// Bumped to give its editor the keyboard.
    var focus: UUID
    var scope: String
    var path: String
    var start: ReviewLine?
    var end: ReviewLine?
    var quote: [ReviewQuote]
    /// The saved comment this draft edits; nil for a new one.
    var editing: UUID?
    /// The diff it is written on.
    var area: GitChangeArea?
}

/// ⌥↓ / ⌥↑ or a click in Create review's list: the diff shows this comment (`FilesSession.reviewReveal`).
struct ReviewReveal: Equatable, Sendable {
    var comment: UUID
    /// A new request for the same comment scrolls to it again.
    var request: UUID
}

/// The order ⌥↓ and ⌥↑ step through the comments in: the files the status lists, by path, each file's own comment first
/// and then by line, as the review lists them.
enum ReviewNavigation {
    static func ordered(_ review: Review, status: GitStatus) -> [ReviewComment] {
        let paths = Set(status.changes.map(\.path))
        return review.files.filter { paths.contains($0.path) }.flatMap(\.comments)
    }

    /// The comment after (`delta` 1) or before (-1) `current`; from none, the first (last) on the selected file, else
    /// the first (last) of all. Nil at either end.
    static func step(from current: UUID?, by delta: Int, in ordered: [ReviewComment], selectedPath: String?) -> ReviewComment? {
        guard !ordered.isEmpty else { return nil }
        if let current, let index = ordered.firstIndex(where: { $0.id == current }) {
            let next = index + delta
            return ordered.indices.contains(next) ? ordered[next] : nil
        }
        let onFile = ordered.filter { $0.path == selectedPath }
        return delta > 0 ? onFile.first ?? ordered.first : onFile.last ?? ordered.last
    }

    /// The change whose diff shows `comment`: the one of its area, else the first of its path in list order.
    static func change(for comment: ReviewComment, in status: GitStatus) -> GitChange? {
        let changes = GitChangesText.ordered(status).filter { $0.path == comment.path }
        return changes.first { $0.area == comment.area } ?? changes.first
    }
}

// MARK: Placement

/// Where a file's comments show among the diff view's rows. A comment goes under the row of its last line: the row with
/// its number and text, else the nearest row on its side with that text (lines added or removed above it moved it),
/// else nowhere, and the view lists it above the rows with the line it was written on.
enum ReviewPlacement {
    /// A commentable row's line and text.
    struct Candidate: Hashable, Sendable {
        var line: ReviewLine
        var text: String
    }

    /// For each placed comment, the index in `candidates` it goes under.
    static func place(_ comments: [ReviewComment], among candidates: [Candidate]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        guard !comments.isEmpty, !candidates.isEmpty else { return result }
        var byText: [String: [Int]] = [:]
        for comment in comments { if let text = comment.quote.last?.text { byText[text] = [] } }
        for (index, candidate) in candidates.enumerated() where byText[candidate.text] != nil {
            byText[candidate.text, default: []].append(index)
        }
        for comment in comments {
            guard let end = comment.end, let text = comment.quote.last?.text, let indices = byText[text] else { continue }
            let sameSide = indices.filter { candidates[$0].line.side == end.side }
            if let exact = sameSide.first(where: { candidates[$0].line.number == end.number }) {
                result[comment.id] = exact
            } else if let nearest = sameSide.min(by: { abs(candidates[$0].line.number - end.number)
                                                     < abs(candidates[$1].line.number - end.number) }) {
                result[comment.id] = nearest
            }
        }
        return result
    }
}

// MARK: Text

/// The words of comments and the review Create review copies, kept apart from the views so they are tested as text.
enum ReviewText {
    /// What the review is of: the repository, the host it is on (nil: this Mac), and its checkout.
    struct Context: Equatable, Sendable {
        var root: String
        var host: String?
        var branch: String?
        var head: String?
    }

    /// A comment's place: "Line 12", "Lines 10–12", "Removed line 9", "Old line 9 to new line 12", "File".
    static func location(_ comment: ReviewComment) -> String { location(start: comment.start, end: comment.end) }

    static func location(start: ReviewLine?, end: ReviewLine?) -> String {
        guard let end else { return "File" }
        let start = start ?? end
        let old = end.side == .old
        if start == end { return old ? "Removed line \(end.number)" : "Line \(end.number)" }
        if start.side == end.side {
            return "\(old ? "Removed lines" : "Lines") \(start.number)–\(end.number)"
        }
        return "\(start.side == .old ? "Old" : "New") line \(start.number) to \(old ? "old" : "new") line \(end.number)"
    }

    /// "3 comments", "1 comment".
    static func count(_ comments: Int) -> String {
        "\(FilesFormatting.count(comments)) \(comments == 1 ? "comment" : "comments")"
    }

    /// A quote longer than this shows its first and last lines.
    static let quoteLines = 24
    /// Quoted lines longer than this end in "…".
    static let quoteWidth = 400

    /// The review for the agent: what it is of and how to read it, the overall comment, then each file's comments with
    /// the lines they are on.
    static func render(_ review: Review, context: Context) -> String {
        let files = review.files
        var head = "Code review of the uncommitted changes in \(context.root)"
        if let host = context.host { head += " on \(host)" }
        if let checkout = checkout(context) { head += " (\(checkout))" }
        if !review.comments.isEmpty {
            head += ": \(count(review.comments.count)) on \(FilesFormatting.count(files.count)) "
                + (files.count == 1 ? "file" : "files")
        }
        var parts = [head + "."]
        if !review.comments.isEmpty {
            parts.append("Address each comment below. Paths are relative to the repository root. Line numbers are the "
                         + "file's as it is now (removed lines as numbered in the old version); the quoted lines show "
                         + "what each comment is about, marked + added, - removed.")
        }
        let summary = review.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { parts.append(summary) }
        for file in files {
            parts.append("## \(file.path)")
            for comment in file.comments {
                var block = location(comment)
                    + (comment.outdated == true ? " (the line has changed since; the quote is what it said)" : "") + ":"
                if !comment.quote.isEmpty { block += "\n" + fenced(comment.quote) }
                block += "\n" + comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                parts.append(block)
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// "main at 3f2c1a0", "detached at 3f2c1a0", nil when neither is known.
    private static func checkout(_ context: Context) -> String? {
        let head = context.head.map { String($0.prefix(7)) }
        switch (context.branch, head) {
        case let (branch?, head?): return "\(branch) at \(head)"
        case let (branch?, nil): return branch
        case let (nil, head?): return "detached at \(head)"
        case (nil, nil): return nil
        }
    }

    /// The quoted lines as a `diff` block, fenced longer than any backtick run they hold.
    static func fenced(_ quote: [ReviewQuote]) -> String {
        var lines = quote.map { line -> String in
            let marker = switch line.kind { case .added: "+"; case .removed: "-"; case .context: " " }
            let text = line.text.count > quoteWidth ? String(line.text.prefix(quoteWidth)) + "…" : line.text
            return marker + text
        }
        if lines.count > quoteLines {
            let kept = quoteLines / 2
            let left = lines.count - kept * 2
            lines = Array(lines.prefix(kept)) + [" … \(FilesFormatting.count(left)) more lines …"] + Array(lines.suffix(kept))
        }
        let longest = quote.map { longestRun(of: "`", in: $0.text) }.max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return ([fence + "diff"] + lines + [fence]).joined(separator: "\n")
    }

    private static func longestRun(of character: Character, in text: String) -> Int {
        var longest = 0, run = 0
        for scalar in text {
            if scalar == character { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        return longest
    }
}
