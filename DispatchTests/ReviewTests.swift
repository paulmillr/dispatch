import Foundation
import XCTest
@testable import DispatchApp

/// The Review tab's pure side: where comments land among a diff's rows (and find their line again once the file
/// changed), the words of a comment's place, the review Create review copies, and the repository that keeps them.
@MainActor
final class ReviewTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_760_700_000)

    private func comment(_ path: String, _ start: ReviewLine?, _ end: ReviewLine?, _ quote: [ReviewQuote], _ text: String,
                         at offset: TimeInterval = 0) -> ReviewComment {
        ReviewComment(id: System.uuid(), path: path, start: start, end: end, quote: quote, text: text,
                      created: created.addingTimeInterval(offset))
    }

    private func new(_ number: Int) -> ReviewLine { ReviewLine(side: .new, number: number) }
    private func old(_ number: Int) -> ReviewLine { ReviewLine(side: .old, number: number) }

    func testLocationWords() {
        XCTAssertEqual(ReviewText.location(start: new(12), end: new(12)), "Line 12")
        XCTAssertEqual(ReviewText.location(start: new(10), end: new(12)), "Lines 10–12")
        XCTAssertEqual(ReviewText.location(start: old(9), end: old(9)), "Removed line 9")
        XCTAssertEqual(ReviewText.location(start: old(9), end: old(10)), "Removed lines 9–10")
        XCTAssertEqual(ReviewText.location(start: old(9), end: new(12)), "Old line 9 to new line 12")
        XCTAssertEqual(ReviewText.location(start: nil, end: nil), "File")
        XCTAssertEqual(ReviewText.target(start: new(10), end: new(12)), "lines 10–12")
        XCTAssertEqual(ReviewText.target(start: nil, end: nil), "the file")
        XCTAssertEqual(ReviewText.count(1), "1 comment")
        XCTAssertEqual(ReviewText.count(1_200), "1,200 comments")
    }

    /// The review for the agent: what it is of, how to read it, the overall comment, then each file in path order with
    /// its own comment first and the rest by line, each quoting its lines as a diff.
    func testReviewGroupsCommentsByFileWithTheirLines() {
        let review = Review(comments: [
            comment("src/routes/billing.ts", new(12), new(12), [ReviewQuote(kind: .added, text: "  const seen = await db.find('webhook_seen', event.id)")],
                    "Wrap the find and the put in one transaction.", at: 1),
            comment("src/lib/db.ts", nil, nil, [], "Rename this to store.ts.", at: 2),
            comment("src/routes/billing.ts", old(9), old(10), [
                ReviewQuote(kind: .removed, text: "  const attempt = Number(event.request?.idempotency_key ?? 0)"),
                ReviewQuote(kind: .removed, text: "  if (attempt > 0) return { status: 200, body: 'retry' }"),
            ], "  Keep the retry log line.  \n", at: 3),
        ], summary: "\nLooks close; fix these and run the tests.\n")
        let text = ReviewText.render(review, context: .init(root: "/Users/sam/src/api", host: "homelab", branch: "main",
                                                           head: "3f2c1a0d9e"))
        XCTAssertEqual(text, """
            Code review of the uncommitted changes in /Users/sam/src/api on homelab (main at 3f2c1a0): 3 comments on 2 files.

            Address each comment below. Paths are relative to the repository root. Line numbers are the file's as it is now (removed lines as numbered in the old version); the quoted lines show what each comment is about, marked + added, - removed.

            Looks close; fix these and run the tests.

            ## src/lib/db.ts

            File:
            Rename this to store.ts.

            ## src/routes/billing.ts

            Removed lines 9–10:
            ```diff
            -  const attempt = Number(event.request?.idempotency_key ?? 0)
            -  if (attempt > 0) return { status: 200, body: 'retry' }
            ```
            Keep the retry log line.

            Line 12:
            ```diff
            +  const seen = await db.find('webhook_seen', event.id)
            ```
            Wrap the find and the put in one transaction.

            """)
    }

    func testReviewOfOnlyASummaryOnThisMac() {
        let text = ReviewText.render(Review(summary: "Split the commit in two."),
                                     context: .init(root: "/Users/sam/src/api", host: nil, branch: nil, head: "3f2c1a0"))
        XCTAssertEqual(text, "Code review of the uncommitted changes in /Users/sam/src/api (detached at 3f2c1a0).\n\nSplit the commit in two.\n")
    }

    /// A quote holding backticks gets a longer fence; a long one keeps its first and last lines.
    func testQuotesFenceAroundBackticksAndFoldWhenLong() {
        XCTAssertEqual(ReviewText.fenced([ReviewQuote(kind: .context, text: "let s = ```code```")]),
                       "````diff\n let s = ```code```\n````")
        let long = (1...30).map { ReviewQuote(kind: .added, text: "line \($0)") }
        let lines = ReviewText.fenced(long).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2 + 24 + 1)
        XCTAssertEqual(lines[1], "+line 1")
        XCTAssertEqual(lines[13], " … 6 more lines …")
        XCTAssertEqual(lines[25], "+line 30")
    }

    /// A comment lands on the row with its number and text; once lines above it moved, on the nearest row of its side
    /// with that text; once its text is gone, nowhere (the view lists it above the rows).
    func testPlacementFindsTheLineAgainAfterItMoved() {
        let candidates: [ReviewPlacement.Candidate] = [
            .init(line: new(1), text: "import { db } from '../lib/db'"),
            .init(line: old(4), text: "  return { status: 200 }"),
            .init(line: new(4), text: "  return { status: 200, body: 'ok' }"),
            .init(line: new(9), text: "  break"),
            .init(line: new(20), text: "  break"),
        ]
        let exact = comment("a.ts", new(4), new(4), [ReviewQuote(kind: .added, text: "  return { status: 200, body: 'ok' }")], "x")
        let moved = comment("a.ts", new(18), new(18), [ReviewQuote(kind: .context, text: "  break")], "y")
        let removed = comment("a.ts", old(3), old(3), [ReviewQuote(kind: .removed, text: "  return { status: 200 }")], "z")
        let gone = comment("a.ts", new(4), new(4), [ReviewQuote(kind: .added, text: "  return null")], "w")
        let onFile = comment("a.ts", nil, nil, [], "v")
        let placed = ReviewPlacement.place([exact, moved, removed, gone, onFile], among: candidates)
        XCTAssertEqual(placed[exact.id], 2)
        XCTAssertEqual(placed[moved.id], 4, "the nearest of the two breaks")
        XCTAssertEqual(placed[removed.id], 1, "a removed line stays on the old side")
        XCTAssertNil(placed[gone.id])
        XCTAssertNil(placed[onFile.id])
    }

    /// Among the diff's rows: a comment under its line, one whose line is gone and one on the file above the rows,
    /// the draft under its last line with its lines tinted, and a fold holding a commented line open.
    func testDiffRowsPlaceCommentsTheComposerAndOpenTheirFolds() throws {
        let model = GitDiffLines()
        let theme = ChatThemeStore.shared.current
        model.prepare(GitDiff(path: "src/routes/billing.ts", text: GitChangesPresentationTests.billingDiff), theme: theme)
        let presentation = model.presentation
        let fold = try XCTUnwrap(presentation.folds.first)
        let folded = presentation.lines[fold.start + 1]
        let inFold = comment("src/routes/billing.ts", new(folded.new!), new(folded.new!),
                             [ReviewQuote(kind: .context, text: folded.text)], "In the fold")
        XCTAssertEqual(model.commentFolds([inFold], draft: nil), [fold.start])

        let added = try XCTUnwrap(presentation.lines.firstIndex { $0.text.contains("const seen = await db.find") })
        let line = presentation.lines[added]
        let onLine = comment("src/routes/billing.ts", new(line.new!), new(line.new!),
                             [ReviewQuote(kind: .added, text: line.text)], "On the line")
        let gone = comment("src/routes/billing.ts", new(3), new(3), [ReviewQuote(kind: .added, text: "gone")], "Gone", at: 1)
        let onFile = comment("src/routes/billing.ts", nil, nil, [], "On the file", at: 2)
        let previous = presentation.lines[added - 1]
        let draft = ReviewDraft(id: System.uuid(), focus: System.uuid(), scope: "local|/r", path: "src/routes/billing.ts",
                                start: new(previous.new!), end: new(line.new!),
                                quote: [ReviewQuote(kind: .added, text: previous.text), ReviewQuote(kind: .added, text: line.text)],
                                editing: nil)
        let rows = model.diffRows(opened: [], allOpen: false, openedGaps: [], sourceLines: nil, truncated: false)
        let layout = model.reviewLayout(rows, comments: [onLine, gone, onFile], draft: draft, reviewing: true)
        XCTAssertEqual(Array(layout.rows.prefix(2)), [.comment(onFile.id), .comment(gone.id)], "the file's own comment first")
        XCTAssertEqual(layout.detached, [gone.id])
        let at = try XCTUnwrap(layout.rows.firstIndex(of: .diff(.line(added))))
        XCTAssertEqual(Array(layout.rows[(at + 1)...(at + 2)]), [.comment(onLine.id), .composer])
        XCTAssertEqual(layout.highlighted, [.diff(.line(added - 1)), .diff(.line(added))])
        XCTAssertEqual(layout.lines[.diff(.line(added))]?.quote, ReviewQuote(kind: .added, text: line.text))

        let plain = model.reviewLayout(rows, comments: [onLine], draft: nil, reviewing: false)
        XCTAssertEqual(plain.rows, rows, "Commits' diffs take no comments")
        XCTAssertTrue(plain.lines.isEmpty)
    }

    /// Create review's last look: a line found again where the file has it now (a range moving with it), a removed line
    /// in the diff, a line gone marked so (and said so in the review), a file that cannot be read left alone.
    func testRelocateFindsEachLineWhereTheFileHasItNow() {
        let seen = "  const seen = await db.find('webhook_seen', event.id)"
        let moved = comment("a.ts", new(11), new(12), [ReviewQuote(kind: .added, text: "  // key on the event id"),
                                                       ReviewQuote(kind: .added, text: seen)], "Moved")
        let gone = comment("a.ts", new(20), new(20), [ReviewQuote(kind: .added, text: "  retry()")], "Gone", at: 1)
        let removed = comment("a.ts", old(9), old(9), [ReviewQuote(kind: .removed, text: "  legacy()")], "Removed", at: 2)
        let onFile = comment("a.ts", nil, nil, [], "File", at: 3)
        let lines = (1...30).map { "line \($0)" }.enumerated().map { $0.offset == 14 ? seen : $0.element }
        let diff = GitDiffPresentation.parse("@@ -10,2 +10,1 @@\n-  legacy()\n line 10\n")
        let result = ReviewRefresh.relocate([moved, gone, removed, onFile], file: .lines(lines), diffs: [diff])
        XCTAssertEqual(result[0].start, new(14), "the range moves with its last line")
        XCTAssertEqual(result[0].end, new(15))
        XCTAssertNil(result[0].outdated)
        XCTAssertEqual(result[1].outdated, true)
        XCTAssertEqual(result[1].end, new(20), "an outdated comment keeps the number it was written on")
        XCTAssertEqual(result[2].end, old(10))
        XCTAssertEqual(result[3], onFile)

        let unknown = ReviewRefresh.relocate([moved, removed], file: .unknown, diffs: [])
        XCTAssertEqual(unknown, [moved, removed], "unreadable: nothing is known, nothing changes")
        let deleted = ReviewRefresh.relocate([moved], file: .gone, diffs: [])
        XCTAssertEqual(deleted.first?.outdated, true)

        var outdated = result[1]
        outdated.path = "a.ts"
        let text = ReviewText.render(Review(comments: [outdated]), context: .init(root: "/r", host: nil, branch: "main", head: nil))
        XCTAssertTrue(text.contains("Line 20 (the line has changed since; the quote is what it said):\n```diff\n+  retry()"), text)
        XCTAssertEqual(ReviewRefresh.lines("a\r\nb\n"), ["a", "b"])
        XCTAssertEqual(ReviewRefresh.lines("a\n\nb"), ["a", "", "b"])
    }

    /// While a file is both staged and changed again, a comment shows on the diff it was written on; in one area,
    /// there whatever it was written on (`git add` moved it).
    func testACommentShowsOnTheDiffItWasWrittenOn() {
        var staged = comment("a.ts", new(1), new(1), [], "x")
        staged.area = .staged
        XCTAssertTrue(staged.shows(in: .staged, areas: [.staged, .unstaged]))
        XCTAssertFalse(staged.shows(in: .unstaged, areas: [.staged, .unstaged]))
        XCTAssertTrue(staged.shows(in: .unstaged, areas: [.unstaged]))
        XCTAssertTrue(comment("a.ts", nil, nil, [], "y").shows(in: .unstaged, areas: [.staged, .unstaged]))
    }

    /// ⌥↓ / ⌥↑ go through the comments of listed files in the review's order, from the selected file when none was
    /// reached yet, and stop at the ends; each goes to the diff of its own area.
    func testNavigationStepsThroughTheListedFilesComments() throws {
        var first = comment("src/a.ts", new(3), new(3), [], "1")
        first.area = .staged
        let second = comment("src/a.ts", new(9), new(9), [], "2", at: 1)
        let third = comment("src/b.ts", nil, nil, [], "3", at: 2)
        let elsewhere = comment("src/gone.ts", nil, nil, [], "4", at: 3)
        let status = GitStatus(branch: "main", head: nil, changes: [
            GitChange(path: "src/a.ts", kind: .modified, area: .staged),
            GitChange(path: "src/a.ts", kind: .modified, area: .unstaged),
            GitChange(path: "src/b.ts", kind: .modified, area: .unstaged),
        ], loadedAt: created)
        let ordered = ReviewNavigation.ordered(Review(comments: [third, second, elsewhere, first]), status: status)
        XCTAssertEqual(ordered.map(\.text), ["1", "2", "3"], "a file with no changes is not stepped to")
        XCTAssertEqual(ReviewNavigation.step(from: nil, by: 1, in: ordered, selectedPath: "src/b.ts")?.text, "3")
        XCTAssertEqual(ReviewNavigation.step(from: nil, by: -1, in: ordered, selectedPath: nil)?.text, "3")
        XCTAssertEqual(ReviewNavigation.step(from: first.id, by: 1, in: ordered, selectedPath: nil)?.text, "2")
        XCTAssertNil(ReviewNavigation.step(from: third.id, by: 1, in: ordered, selectedPath: nil))
        XCTAssertEqual(ReviewNavigation.change(for: first, in: status)?.id, "staged:src/a.ts")
        XCTAssertEqual(ReviewNavigation.change(for: second, in: status)?.id, "staged:src/a.ts", "no area: the list's first")
    }

    /// A review nobody touched for 60 days is gone at the next read, and the file is written without it.
    func testUntouchedReviewsExpire() {
        let store = MemoryReviewStore()
        let now = System.date()
        store.stored = [
            "local|/old": Review(comments: [comment("a.ts", nil, nil, [], "old")], modified: now.addingTimeInterval(-61 * 24 * 3600)),
            "local|/new": Review(comments: [comment("a.ts", nil, nil, [], "new")], modified: now.addingTimeInterval(-3600)),
        ]
        let repository = ReviewRepository(store: store)
        XCTAssertEqual(Set(repository.reviews.keys), ["local|/new"])
        XCTAssertEqual(store.saved.last.map { Set($0.keys) }, ["local|/new"])
        repository.add(comment("b.ts", nil, nil, [], "b"), to: "local|/new")
        XCTAssertNotNil(repository.review("local|/new").modified)
    }

    func testScopeNamesTheHostAndTheRepository() {
        XCTAssertEqual(ReviewRepository.scope(local: true, host: nil, root: "/Users/sam/src/api"), "local|/Users/sam/src/api")
        XCTAssertEqual(ReviewRepository.scope(local: false, host: "homelab", root: "/home/sam/api"), "remote:homelab|/home/sam/api")
    }

    /// Saved, edited and deleted comments are written at once; Create review takes the review (its Undo brings it
    /// back beside comments written since); a file that could not be read is never overwritten.
    func testRepositoryKeepsTakesAndRestoresReviews() throws {
        let store = MemoryReviewStore()
        let repository = ReviewRepository(store: store)
        let scope = "local|/Users/sam/src/api"
        let first = comment("a.ts", new(1), new(1), [ReviewQuote(kind: .added, text: "x")], "First")
        repository.add(first, to: scope)
        XCTAssertEqual(store.saved.last?[scope]?.comments.map(\.text), ["First"])
        repository.update(first.id, text: "First, edited", in: scope)
        XCTAssertEqual(store.saved.last?[scope]?.comments.map(\.text), ["First, edited"])

        let taken = try XCTUnwrap(repository.take(scope))
        XCTAssertEqual(taken.comments.map(\.id), [first.id])
        XCTAssertTrue(repository.review(scope).isEmpty)
        XCTAssertNil(store.saved.last?[scope], "the copied review leaves the file")
        XCTAssertNotNil(repository.copied[scope])
        repository.restore(scope)
        XCTAssertEqual(repository.review(scope).comments.map(\.id), [first.id])
        XCTAssertNil(repository.copied[scope])

        repository.take(scope, sentTo: "Claude Code")
        XCTAssertEqual(repository.sentTo[scope], "Claude Code", "the bar names where the review went")
        let second = comment("b.ts", nil, nil, [], "Second")
        repository.add(second, to: scope)
        XCTAssertNil(repository.copied[scope], "a new comment ends the Undo")
        XCTAssertNil(repository.sentTo[scope])
        repository.remove(second.id, from: scope)
        XCTAssertNil(repository.reviews[scope], "an empty review is dropped")
        XCTAssertNil(repository.take(scope), "nothing to take")

        let broken = MemoryReviewStore()
        broken.failLoad = true
        let unread = ReviewRepository(store: broken)
        XCTAssertNotNil(unread.error)
        unread.add(first, to: scope)
        XCTAssertTrue(broken.saved.isEmpty)
    }

    /// The file round-trips, is owner-only, and is not written while nothing was ever reviewed.
    func testFileStoreWritesAPrivateFile() throws {
        let directory = System.temporary.appendingPathComponent("review-\(System.uuid().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewFileStore(url: directory.appendingPathComponent("reviews.json"))
        try store.save([:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let reviews = ["local|/r": Review(comments: [comment("a.ts", new(2), new(3), [ReviewQuote(kind: .context, text: "y")], "Z")],
                                          summary: "S")]
        try store.save(reviews)
        XCTAssertEqual(try store.load(), reviews)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
}

@MainActor final class MemoryReviewStore: ReviewPersistence {
    var stored: [String: Review] = [:]
    var saved: [[String: Review]] = []
    var failLoad = false

    func load() throws -> [String: Review] {
        if failLoad { throw CocoaError(.fileReadCorruptFile) }
        return stored
    }

    func save(_ reviews: [String: Review]) throws {
        stored = reviews
        saved.append(reviews)
    }
}
