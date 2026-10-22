import Foundation

/// Create review's last look at the files before the review goes out: each comment's line found again where it is now,
/// so the review's numbers are the file's as it is, not as it was when the comment was written; a comment whose line is
/// gone says so. Lines on the new side are found in the working-tree file, removed lines in the file's diffs.
enum ReviewRefresh {
    /// The working-tree file, as read: its lines, gone (deleted, or not a file now), or unknown (unreadable, too large,
    /// binary, the host unreachable: the comments keep their numbers).
    enum File: Equatable, Sendable {
        case lines([String])
        case gone
        case unknown
    }

    /// One file's comments against its working-tree lines and its diffs (every area it is changed in).
    static func relocate(_ comments: [ReviewComment], file: File, diffs: [GitDiffPresentation]) -> [ReviewComment] {
        let newSide: [ReviewPlacement.Candidate]?
        switch file {
        case .lines(let lines):
            newSide = lines.enumerated().map { .init(line: ReviewLine(side: .new, number: $0.offset + 1), text: $0.element) }
        case .gone:
            newSide = []
        case .unknown:
            newSide = nil
        }
        let removed = diffs.flatMap { diff in
            diff.lines.compactMap { line -> ReviewPlacement.Candidate? in
                guard line.kind == .removed, let old = line.old else { return nil }
                return .init(line: ReviewLine(side: .old, number: old), text: line.text)
            }
        }
        return comments.map { comment in
            guard let end = comment.end else { return comment }
            let candidates: [ReviewPlacement.Candidate]
            switch end.side {
            case .new:
                guard let newSide else { return comment }
                candidates = newSide
            case .old:
                // Without the diffs (git could not be asked) nothing is known of the old side.
                guard !diffs.isEmpty || file == .gone else { return comment }
                candidates = removed
            }
            guard let index = ReviewPlacement.place([comment], among: candidates)[comment.id] else {
                var outdated = comment
                outdated.outdated = true
                return outdated
            }
            return comment.moved(to: candidates[index].line)
        }
    }

    /// The review with every commented file read again. Never throws: what cannot be read keeps its numbers.
    static func refresh(_ review: Review, status: GitStatus, queries: GitQueries) async -> Review {
        var refreshed = review
        var comments: [UUID: ReviewComment] = [:]
        for (path, fileComments) in review.files where fileComments.contains(where: { !$0.onFile }) {
            let file = await read(path, queries: queries)
            var diffs: [GitDiffPresentation] = []
            if fileComments.contains(where: { $0.end?.side == .old }) {
                for change in status.changes where change.path == path && change.area != .untracked {
                    if let diff = try? await queries.diff(change), !diff.binary {
                        diffs.append(GitDiffPresentation.parse(diff.text))
                    }
                }
            }
            for comment in relocate(fileComments, file: file, diffs: diffs) { comments[comment.id] = comment }
        }
        refreshed.comments = review.comments.map { comments[$0.id] ?? $0 }
        return refreshed
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

    /// A file's lines as the diff numbers them: split at newlines, a final newline ending the last line.
    static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }
}
