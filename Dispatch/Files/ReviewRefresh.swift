import Foundation

/// Create review's last look at the files before the review goes out: each comment's line found again where it is now,
/// so the review's numbers are the file's as it is, not as it was when the comment was written; a comment whose lines are
/// gone, or could be in more than one place, says so (`ReviewMatch`). Lines on the new side are found in the
/// working-tree file, removed lines in the diff of the area the comment was written on. A comment on a commit's diff is
/// found in the working-tree file too; its removed lines keep their numbers.
enum ReviewRefresh {
    /// The working-tree file, as read: its lines, gone (deleted, or not a file now), or unknown (unreadable, too large,
    /// binary, the host unreachable: the comments keep their numbers).
    enum File: Equatable, Sendable {
        case lines([String])
        case gone
        case unknown
    }

    /// One file's comments against the file as it is now: its working-tree lines, the areas it is changed in
    /// (`areas`; nil when the status could not be read) and the diffs read of them (an area missing from `diffs` could
    /// not be read). Each comment is looked
    /// for in the area it was written on (`area(of:in:)`): the new side in the working-tree file, or, while the file is
    /// staged and changed again, in what the staged diff shows of the index; the old side among that diff's removed
    /// lines. Found once, it takes the numbers it has now; found nowhere or in several places, it is outdated.
    static func relocate(_ comments: [ReviewComment], file: File, diffs: [GitChangeArea: GitDiffPresentation],
                         areas: Set<GitChangeArea>?) -> [ReviewComment] {
        let working: ReviewMatch.Side? = switch file {
        case .lines(let lines): .file(lines)
        case .gone: ReviewMatch.Side([], complete: true)
        case .unknown: nil
        }
        return comments.map { comment in
            guard !comment.onFile else { return comment }
            // A commit's comment: its lines are looked for in the file as it is now (found, they take today's numbers);
            // removed lines were the commit's parent's, which no working-tree diff holds, so they keep theirs.
            if comment.commit != nil { return result(comment, ReviewMatch.locate(comment, new: working, old: nil)) }
            // Without the status nothing is known of the areas: the working tree is the file, no diff is known.
            guard let areas else {
                return result(comment, ReviewMatch.locate(comment, new: working, old: nil))
            }
            let area = area(of: comment, in: areas)
            let new: ReviewMatch.Side?
            if area == .staged, areas.contains(.unstaged) {
                new = diffs[.staged].map { diff in
                    ReviewMatch.Side(diff.lines.compactMap { line in
                        line.kind == .removed ? nil : line.new.map { ($0, line.text) }
                    }, complete: false)
                }
            } else {
                new = working
            }
            let old: ReviewMatch.Side?
            if let area, area != .untracked {
                old = diffs[area].map { diff in
                    ReviewMatch.Side(diff.lines.compactMap { line in
                        line.kind == .removed ? line.old.map { ($0, line.text) } : nil
                    }, complete: true)
                }
            } else {
                // Unchanged, or new to git: nothing is removed.
                old = ReviewMatch.Side([], complete: true)
            }
            return result(comment, ReviewMatch.locate(comment, new: new, old: old))
        }
    }

    private static func result(_ comment: ReviewComment, _ match: ReviewMatch.Result) -> ReviewComment {
        switch match {
        case .found(let found):
            return found
        case .outdated:
            var outdated = comment
            outdated.outdated = true
            return outdated
        case .unknown:
            return comment
        }
    }

    /// The area whose diff a comment's lines are in now: the one it was written on while the file is still changed
    /// there; else (`git add` or `git reset` moved the change, or the comment predates areas) the one the file is
    /// changed in, the working tree's first; nil once the file is changed nowhere.
    static func area(of comment: ReviewComment, in areas: Set<GitChangeArea>) -> GitChangeArea? {
        if let own = comment.area, areas.contains(own) { return own }
        return [GitChangeArea.unstaged, .untracked, .staged].first(where: areas.contains)
    }

    /// The review with every commented file read again through `read` (the working-tree file) and `diff` (a change's
    /// diff; nil when git could not say), `status` nil when it could not be read (removed lines keep their numbers then).
    /// Never throws: what cannot be read keeps its numbers. Both apps run it: the Mac through `GitQueries`, the phone
    /// through its helper's `files.git` and `files.text`.
    static func refresh(_ review: Review, status: GitStatus?, read: (String) async -> File,
                        diff: (GitChange) async -> GitDiff?) async -> Review {
        var refreshed = review
        var comments: [UUID: ReviewComment] = [:]
        for (path, fileComments) in review.files where fileComments.contains(where: { !$0.onFile }) {
            let changes = status?.changes.filter { $0.path == path && $0.kind != .ignored } ?? []
            let areas = status.map { _ in Set(changes.map(\.area)) }
            // The diffs the comments need: their area's removed lines, and the index's lines while the file is staged
            // and changed again.
            var needed: Set<GitChangeArea> = []
            for comment in fileComments where !comment.onFile && comment.commit == nil {
                guard let areas, let area = area(of: comment, in: areas), area != .untracked else { continue }
                if (area == .staged && areas.contains(.unstaged)) || ReviewMatch.anchors(comment)[.old] != nil {
                    needed.insert(area)
                }
            }
            let file = await read(path)
            var diffs: [GitChangeArea: GitDiffPresentation] = [:]
            for change in changes where needed.contains(change.area) && diffs[change.area] == nil {
                if let diff = await diff(change), !diff.binary {
                    diffs[change.area] = GitDiffPresentation.parse(diff.text)
                }
            }
            for comment in relocate(fileComments, file: file, diffs: diffs, areas: areas) { comments[comment.id] = comment }
        }
        refreshed.comments = review.comments.map { comments[$0.id] ?? $0 }
        return refreshed
    }

    #if canImport(AppKit)
    /// The review with every commented file read again. Never throws: what cannot be read keeps its numbers.
    static func refresh(_ review: Review, status: GitStatus, queries: GitQueries) async -> Review {
        await refresh(review, status: status, read: { await read($0, queries: queries) },
                      diff: { try? await queries.diff($0) })
    }

    private static func read(_ path: String, queries: GitQueries) async -> File {
        guard GitChange.representable(path) else { return .unknown }
        do {
            let (data, _) = try await queries.source.read(FilesPath.join(queries.root, path), offset: 0,
                                                          length: GitChangesText.sourceLimit + 1, revision: nil)
            guard UInt64(data.count) <= GitChangesText.sourceLimit, !data.contains(0) else { return .unknown }
            return .lines(lines(String(decoding: data, as: UTF8.self)))
        } catch FilesSourceError.notFound, FilesSourceError.notDirectory {
            return .gone
        } catch {
            return .unknown
        }
    }
    #endif

    /// A file's lines as the diff numbers them: split at newlines, a final newline ending the last line.
    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
