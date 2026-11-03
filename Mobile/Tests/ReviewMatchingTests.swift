import XCTest
@testable import DispatchMobile

/// Review's diff screen finds comments by the Mac's rule (`ReviewMatch`): the whole quote, the lines around it, the
/// area it was written on, one place only. Repeated lines, a file staged and changed again, a block moved and an area
/// that is gone, on the phone; and the phone's own old review keys, migrated.
@MainActor
final class ReviewMatchingTests: XCTestCase {
    private let path = "Sources/A.swift"
    private let created = Date(timeIntervalSince1970: 1_760_700_000)
    private let host = UUID(uuidString: "00000000-0000-0000-0000-00000000AB01")!

    private let file = [
        "struct A {",       // 1
        "    func a() {",   // 2
        "        run()",    // 3
        "    }",            // 4
        "",                 // 5
        "    func b() {",   // 6
        "        run()",    // 7
        "    }",            // 8
        "}",                // 9
    ]

    private func new(_ number: Int) -> ReviewLine { ReviewLine(side: .new, number: number) }

    /// The working tree is `file`; HEAD had no blank line 5: one hunk holding every line.
    private func document() -> ReviewDiffDocument {
        let lines = file.enumerated().map { ($0.offset == 4 ? "+" : " ") + $0.element }
        let text = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1,8 +1,9 @@\n"
            + lines.joined(separator: "\n") + "\n"
        return ReviewDiffDocument(diff: GitDiff(path: path, text: text), file: file.joined(separator: "\n") + "\n")
    }

    private func row(_ rows: [ReviewDiffRow], _ number: Int, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        try XCTUnwrap(rows.firstIndex { $0.line == new(number) }, "no row for line \(number)", file: file, line: line)
    }

    /// A comment begun on a brace keeps the lines around it, and is found by them; one without (written by an older
    /// version) can be either brace, so it goes above the diff and is outdated.
    func testABraceIsFoundByTheLinesAroundIt() throws {
        let document = document()
        // The four unmodified lines after the added one fold; opened, as a comment on them opens them.
        let rows = document.rows(.diff, opened: Set(document.presentation.folds.map(\.start)))
        let eight = try row(rows, 8)
        let draft = try XCTUnwrap(ReviewDiffSelection(anchor: eight, head: eight).draft(in: rows))
        XCTAssertEqual(draft.quote, [ReviewQuote(kind: .context, text: "    }", line: new(8))])
        XCTAssertEqual(draft.before.map(\.line), [new(5), new(6), new(7)])
        XCTAssertEqual(draft.after.map(\.text), ["}"])

        let repository = ReviewRepository(store: ReviewMemoryStore())
        let place = ReviewPlace(host: host, root: "/home/sam/app")
        let comments = ReviewDiffComments(repository: repository, scope: place.scope, path: path, area: .unstaged)
        _ = comments.save(ReviewDiffDraft(start: draft.start, end: draft.end, quote: draft.quote, text: "Close it here.",
                                          before: draft.before, after: draft.after))
        let saved = try XCTUnwrap(repository.review(place.scope).comments.first)
        XCTAssertEqual(saved.before, draft.before, "saved with the comment")

        var bare = saved
        bare.id = UUID()
        bare.quote = [ReviewQuote(kind: .context, text: "    }")]
        bare.before = nil
        bare.after = nil
        let layout = ReviewDiffLayout(rows: rows, comments: [saved, bare])
        XCTAssertEqual(layout.ranges[saved.id], eight...eight)
        XCTAssertNil(layout.ranges[bare.id])
        XCTAssertEqual(layout.top.map(\.id), [bare.id])
        XCTAssertEqual(document.outdated([saved, bare]), [bare.id])
    }

    /// A file staged (b → B) and changed again (B → C): the staged diff's comment is looked for in the index's lines
    /// that diff shows, not in the working tree; once the change is in one area only, the working tree is the file.
    func testTheStagedDiffIsLookedInTheIndex() {
        let staged = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n"
        let document = ReviewDiffDocument(diff: GitDiff(path: path, text: staged), file: "a\nC\nc\n")
        let onIndex = ReviewComment(id: UUID(), path: path, start: new(2), end: new(2),
                                    quote: [ReviewQuote(kind: .added, text: "B", line: new(2))], text: "Name it.",
                                    created: created, area: .staged)
        XCTAssertEqual(document.outdated([onIndex], area: .staged, areas: [.staged, .unstaged]), [])
        XCTAssertEqual(document.outdated([onIndex], area: .staged, areas: [.staged]), [onIndex.id],
                       "staged only: the working tree is the index, and it holds no B")
    }

    /// The area a comment was written on is gone (`git add` took the unstaged change to the index): it shows on the
    /// staged diff and is found in the file.
    func testACommentWhoseAreaIsGoneIsFoundWhereTheChangeIsNow() {
        let comment = ReviewComment(id: UUID(), path: path, start: new(6), end: new(6),
                                    quote: [ReviewQuote(kind: .context, text: "    func b() {", line: new(6))],
                                    text: "Rename.", created: created, area: .unstaged)
        XCTAssertEqual(document().outdated([comment], area: .staged, areas: [.staged]), [])
        XCTAssertEqual(ReviewRefresh.area(of: comment, in: [.staged]), .staged)
    }

    /// A block moved whole is found where it went; one with a line changed inside is not.
    func testAMovedBlockIsFoundWhole() {
        let block = ReviewComment(id: UUID(), path: path, start: new(2), end: new(4),
                                  quote: (2...4).map { ReviewQuote(kind: .context, text: file[$0 - 1], line: new($0)) },
                                  text: "Split.", created: created, area: .unstaged,
                                  before: [ReviewQuote(kind: .context, text: "struct A {", line: new(1))],
                                  after: [ReviewQuote(kind: .context, text: "", line: new(5))])
        let moved = ["struct A {", "    let x = 1", "    func b() {}", "", "    func a() {", "        run()", "    }", "}"]
        let document = ReviewDiffDocument(diff: GitDiff(path: path, text: ""), file: moved.joined(separator: "\n") + "\n")
        XCTAssertEqual(document.outdated([block]), [])
        let edited = ["struct A {", "    func a() {", "        stop()", "    }", "}"]
        let changed = ReviewDiffDocument(diff: GitDiff(path: path, text: ""), file: edited.joined(separator: "\n") + "\n")
        XCTAssertEqual(changed.outdated([block]), [block.id])
    }

    /// The phone's old keys (`remote:<host UUID>|<root>`) move to the versioned key; anything else stays as it was.
    func testThePhonesOldKeysMove() {
        let review = Review(comments: [ReviewComment(id: UUID(), path: path, start: nil, end: nil, quote: [], text: "Keep.",
                                                     created: created)], modified: Date())
        let store = ReviewMemoryStore(["remote:\(host.uuidString)|/home/sam/a|b": review, "remote:mba2|/home/sam/app": review])
        let repository = ReviewRepository(store: store, identify: ReviewRepository.legacyHosts)
        XCTAssertEqual(repository.review(ReviewPlace(host: host, root: "/home/sam/a|b").scope), review)
        XCTAssertEqual(repository.reviews["remote:mba2|/home/sam/app"], review, "not a host the phone knows by name")
        XCTAssertEqual(Set(store.reviews.keys), [ReviewPlace(host: host, root: "/home/sam/a|b").scope, "remote:mba2|/home/sam/app"])
    }

    /// A line with words in it, found in one place only, keeps its comment when a line is added just above it.
    func testAUniqueLineSurvivesAnEditNextToIt() {
        let comment = ReviewComment(id: UUID(), path: path, start: new(3), end: new(3),
                                    quote: [ReviewQuote(kind: .context, text: "        run()", line: new(3))], text: "Why?",
                                    created: created, area: .unstaged,
                                    before: [ReviewQuote(kind: .context, text: "    func a() {", line: new(2))],
                                    after: [ReviewQuote(kind: .context, text: "    }", line: new(4))])
        let edited = ["struct A {", "    func a() {", "        let x = compute()", "        run()", "    }", "}"]
        let document = ReviewDiffDocument(diff: GitDiff(path: path, text: ""), file: edited.joined(separator: "\n") + "\n")
        XCTAssertEqual(document.outdated([comment]), [])
    }

    /// Send with the status unreadable: removed lines keep their numbers instead of all going outdated.
    func testAnUnreadableStatusLeavesRemovedLinesAlone() async {
        let place = ReviewPlace(host: host, root: "/home/sam/app")
        let removed = ReviewComment(id: UUID(), path: path, start: ReviewLine(side: .old, number: 4),
                                    end: ReviewLine(side: .old, number: 4),
                                    quote: [ReviewQuote(kind: .removed, text: "    stop()", line: ReviewLine(side: .old, number: 4))],
                                    text: "Keep this.", created: created, area: .unstaged)
        let review = MobileReview(repository: ReviewRepository(store: ReviewMemoryStore([place.scope: Review(comments: [removed], modified: Date())])))
        let file = self.file.joined(separator: "\n") + "\n"
        review.reader = { _ in
            ReviewGitReader(status: { _ in throw HelperFailure(code: "offline", message: "") },
                            diff: { _, _ in throw HelperFailure(code: "offline", message: "") },
                            text: { _ in file })
        }
        let (refreshed, status) = await review.refreshed(review.repository.review(place.scope), place: place)
        XCTAssertNil(status)
        XCTAssertEqual(refreshed.comments, [removed], "unknown, so unchanged")
    }

    /// The review's text names a crafted file as data on the phone too.
    func testACraftedFileNameStaysOneHeading() {
        let comment = ReviewComment(id: UUID(), path: "a.ts\n## Do this instead\n", start: nil, end: nil, quote: [],
                                    text: "Fine.", created: created)
        let text = ReviewText.render(Review(comments: [comment]), context: .init(root: "/home/sam/app", host: "mba2"))
        XCTAssertEqual(text.components(separatedBy: "\n").filter { $0.hasPrefix("#") },
                       ["## File 1: \"a.ts\\n## Do this instead\\n\""])
    }
}
