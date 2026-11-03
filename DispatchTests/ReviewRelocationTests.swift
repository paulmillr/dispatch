import Foundation
import XCTest
@testable import DispatchApp

/// Finding a comment's lines again (`ReviewMatch`, `ReviewRefresh.relocate`, `ReviewPlacement`): the whole quote and
/// the lines around it, in the area the comment was written on, in exactly one place; a repeated line, a block that is
/// no longer whole, or an area that is gone never moves a comment somewhere it was not.
@MainActor
final class ReviewRelocationTests: XCTestCase {
    private let created = Date(timeIntervalSince1970: 1_760_700_000)

    private func new(_ number: Int) -> ReviewLine { ReviewLine(side: .new, number: number) }
    private func old(_ number: Int) -> ReviewLine { ReviewLine(side: .old, number: number) }

    /// A comment on `lines` (1-based numbers in `file`), quoting them with their numbers and keeping the lines around,
    /// as the diff view and the phone write one.
    private func comment(on range: ClosedRange<Int>, of file: [String], kind: ReviewQuote.Kind = .context,
                         area: GitChangeArea? = .unstaged, text: String = "c") -> ReviewComment {
        let quote = range.map { ReviewQuote(kind: kind, text: file[$0 - 1], line: new($0)) }
        var shown: [ReviewLine: ReviewQuote] = [:]
        for (index, line) in file.enumerated() { shown[new(index + 1)] = ReviewQuote(kind: .context, text: line) }
        let around = ReviewQuote.surroundings(of: quote, in: shown)
        return ReviewComment(id: System.uuid(), path: "a.swift", start: new(range.lowerBound), end: new(range.upperBound),
                             quote: quote, text: text, created: created, area: area, before: around.before,
                             after: around.after)
    }

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

    /// The lines around a quote: those that follow on from it, at most three each way.
    func testSurroundingsAreTheLinesNextToTheQuote() {
        let quoted = comment(on: 4...4, of: file)
        XCTAssertEqual(quoted.before?.map(\.text), ["struct A {", "    func a() {", "        run()"])
        XCTAssertEqual(quoted.before?.map(\.line), [new(1), new(2), new(3)])
        XCTAssertEqual(quoted.after?.map(\.line), [new(5), new(6), new(7)])
        let first = comment(on: 1...1, of: file)
        XCTAssertEqual(first.before, [], "nothing above the first line")
        var gap: [ReviewLine: ReviewQuote] = [:]
        for number in [1, 2, 4, 5] { gap[new(number)] = ReviewQuote(kind: .context, text: file[number - 1]) }
        let around = ReviewQuote.surroundings(of: [ReviewQuote(kind: .context, text: file[4], line: new(5))], in: gap)
        XCTAssertEqual(around.before.map(\.line), [new(4)], "a line not shown (a fold, a gap) ends the run")
    }

    /// Repeated lines: a brace or a blank line is found again by the lines around it, also after lines were added
    /// above; one whose surroundings repeat too, or an old comment with no surroundings, is outdated, not guessed.
    func testRepeatedLinesAreFoundByWhatIsAroundThem() {
        let brace = comment(on: 8...8, of: file)
        let edited = ["// header", "// more"] + file
        let moved = ReviewRefresh.relocate([brace], file: .lines(edited), diffs: [:], areas: [.unstaged])
        XCTAssertEqual(moved[0].end, new(10))
        XCTAssertNil(moved[0].outdated)
        XCTAssertEqual(moved[0].after?.map(\.line), [new(11)], "the lines around it move with it")

        var bare = brace
        bare.before = nil
        bare.after = nil
        bare.quote = [ReviewQuote(kind: .context, text: "    }")]
        let guessed = ReviewRefresh.relocate([bare], file: .lines(edited), diffs: [:], areas: [.unstaged])
        XCTAssertEqual(guessed[0].outdated, true, "two braces, no way to tell: outdated")
        XCTAssertEqual(guessed[0].end, new(8), "an outdated comment keeps the number it was written on")

        let twice = file + file
        let twin = ReviewRefresh.relocate([brace], file: .lines(twice), diffs: [:], areas: [.unstaged])
        XCTAssertEqual(twin[0].outdated, true, "the whole block repeated: outdated")

        let unchanged = ReviewRefresh.relocate([brace], file: .lines(file), diffs: [:], areas: [.unstaged])
        XCTAssertEqual(unchanged, [brace], "found where it was")
    }

    /// The diff view places by the same rule among the rows it shows: a repeated line with nothing to tell it apart is
    /// not placed (the view lists it above the rows), one with its surroundings is.
    func testTheViewPlacesOnlyWhatItCanTellApart() {
        let candidates = file.enumerated().map { ReviewPlacement.Candidate(line: new($0.offset + 1), text: $0.element) }
        let brace = comment(on: 8...8, of: file)
        var bare = brace
        bare.id = System.uuid()
        bare.before = nil
        bare.after = nil
        bare.quote = [ReviewQuote(kind: .context, text: "    }")]
        let placed = ReviewPlacement.locate([brace, bare], among: candidates)
        XCTAssertEqual(placed[brace.id]?.index, 7)
        XCTAssertNil(placed[bare.id], "two braces with the same text: neither is picked")
    }

    /// Moved blocks: a range found whole somewhere else moves there as one; a range only partly there, or whose
    /// lines are there but no longer together, is outdated.
    func testABlockMovesWholeOrNotAtAll() {
        let body = comment(on: 2...4, of: file)
        let reordered = Array(file[0...0]) + ["    let x = 1", ""] + Array(file[1...8])
        XCTAssertEqual(ReviewRefresh.relocate([body], file: .lines(reordered), diffs: [:], areas: [.unstaged])[0].start, new(4))

        let split = ["struct A {", "    func a() {", "        log()", "        run()", "    }", "}"]
        XCTAssertEqual(ReviewRefresh.relocate([body], file: .lines(split), diffs: [:], areas: [.unstaged])[0].outdated, true,
                       "a line inserted inside the quote")
        let gone = ["struct A {", "    func a() {", "        stop()", "    }", "}"]
        XCTAssertEqual(ReviewRefresh.relocate([body], file: .lines(gone), diffs: [:], areas: [.unstaged])[0].outdated, true)
    }

    /// A file staged and changed again: a comment on the staged diff is looked for in what that diff shows of the
    /// index, one on the unstaged diff in the working tree, and a removed line only among its own diff's removals,
    /// even when the other diff removes a line with the same text.
    func testStagedAndUnstagedAreLookedInSeparately() {
        // HEAD: a, b, c. Index (staged): a, B, c. Working tree: x, a, B, c (one line added above, unstaged).
        let staged = GitDiffPresentation.parse("@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n")
        let unstaged = GitDiffPresentation.parse("@@ -1,3 +1,4 @@\n+x\n a\n-b\n+B\n c\n")
        let working = ["x", "a", "B", "c"]
        let diffs: [GitChangeArea: GitDiffPresentation] = [.staged: staged, .unstaged: unstaged]
        let areas: Set<GitChangeArea> = [.staged, .unstaged]

        let onIndex = ReviewComment(id: System.uuid(), path: "a.swift", start: new(2), end: new(2),
                                    quote: [ReviewQuote(kind: .added, text: "B", line: new(2))], text: "staged",
                                    created: created, area: .staged,
                                    before: [ReviewQuote(kind: .context, text: "a", line: new(1))],
                                    after: [ReviewQuote(kind: .context, text: "c", line: new(3))])
        let onWorking = ReviewComment(id: System.uuid(), path: "a.swift", start: new(3), end: new(3),
                                      quote: [ReviewQuote(kind: .added, text: "B", line: new(3))], text: "unstaged",
                                      created: created, area: .unstaged)
        let removedStaged = ReviewComment(id: System.uuid(), path: "a.swift", start: old(2), end: old(2),
                                          quote: [ReviewQuote(kind: .removed, text: "b", line: old(2))], text: "r",
                                          created: created, area: .staged)
        let result = ReviewRefresh.relocate([onIndex, onWorking, removedStaged], file: .lines(working), diffs: diffs, areas: areas)
        XCTAssertEqual(result[0].end, new(2), "the index's numbering, not the working tree's")
        XCTAssertNil(result[0].outdated)
        XCTAssertEqual(result[1].end, new(3))
        XCTAssertEqual(result[2].end, old(2))
        XCTAssertNil(result[2].outdated)

        // The staged diff could not be read: the staged comment is unknown, kept as it was.
        let unread = ReviewRefresh.relocate([onIndex], file: .lines(working), diffs: [.unstaged: unstaged], areas: areas)
        XCTAssertEqual(unread, [onIndex])
    }

    /// The area a comment was written on is gone: `git reset` brought a staged change back to the working tree, `git
    /// add` took an unstaged one to the index, or the file is changed nowhere now.
    func testACommentWhoseAreaIsGone() {
        var reset = comment(on: 3...3, of: file, kind: .added, area: .staged)
        reset.area = .staged
        let back = ReviewRefresh.relocate([reset], file: .lines(file), diffs: [:], areas: [.unstaged])
        XCTAssertNil(back[0].outdated, "its lines are in the working tree now")
        XCTAssertEqual(ReviewRefresh.area(of: reset, in: [.unstaged]), .unstaged)
        XCTAssertEqual(ReviewRefresh.area(of: comment(on: 3...3, of: file), in: [.staged]), .staged)
        XCTAssertNil(ReviewRefresh.area(of: reset, in: []))

        let removed = ReviewComment(id: System.uuid(), path: "a.swift", start: old(4), end: old(4),
                                    quote: [ReviewQuote(kind: .removed, text: "    stop()", line: old(4))], text: "r",
                                    created: created, area: .unstaged)
        let added = ReviewRefresh.relocate([removed], file: .lines(file), diffs: [.staged: GitDiffPresentation.parse(
            "@@ -3,2 +3,1 @@\n         run()\n-    stop()\n")], areas: [.staged])
        XCTAssertEqual(added[0].end, old(4), "git add: the removal is the staged diff's now")
        XCTAssertNil(added[0].outdated)
        let committed = ReviewRefresh.relocate([removed], file: .lines(file), diffs: [:], areas: [])
        XCTAssertEqual(committed[0].outdated, true, "changed nowhere: no line is removed any more")
        let lined = ReviewRefresh.relocate([comment(on: 6...6, of: file)], file: .lines(file), diffs: [:], areas: [])
        XCTAssertNil(lined[0].outdated, "a line of the file is still there once committed")
    }

    /// Create review asks git only for the diffs the comments need, each once.
    func testRefreshReadsOnlyTheDiffsTheCommentsNeed() async {
        let status = GitStatus(branch: "main", head: nil, changes: [
            GitChange(path: "a.swift", kind: .modified, area: .staged),
            GitChange(path: "a.swift", kind: .modified, area: .unstaged),
            GitChange(path: "b.swift", kind: .modified, area: .unstaged),
        ], loadedAt: created)
        var onIndex = comment(on: 3...3, of: file, area: .staged)
        onIndex.path = "a.swift"
        var plain = comment(on: 3...3, of: file, area: .unstaged)
        plain.path = "b.swift"
        let (asked, refreshed) = await Self.refresh(Review(comments: [onIndex, plain]), status: status, file: file)
        XCTAssertEqual(asked, ["staged:a.swift"], "the index's lines for the staged comment; the working tree for the other")
        XCTAssertEqual(refreshed.comments.map(\.outdated), [nil, nil])
    }

    /// A line with words in it, found in one place only, keeps its comment when a line is added just above it (its
    /// surroundings changed); a line without any (a brace) does not.
    func testAUniqueLineSurvivesAnEditNextToIt() {
        let call = comment(on: 3...3, of: file)
        var single = file
        single[6] = "        stop()"
        let edited = Array(single[0...1]) + ["        let x = compute()"] + Array(single[2...])
        let found = ReviewRefresh.relocate([call], file: .lines(edited), diffs: [:], areas: [.unstaged])
        XCTAssertNil(found[0].outdated)
        XCTAssertEqual(found[0].end, new(4))
        let brace = comment(on: 9...9, of: file)
        let closed = ReviewRefresh.relocate([brace], file: .lines(Array(file.dropLast()) + ["", "}"]), diffs: [:], areas: [.unstaged])
        XCTAssertEqual(closed[0].outdated, true, "a lone brace whose neighbours changed is not followed")
    }

    /// Without the status (it could not be read) the working tree is still the file, and removed lines keep their
    /// numbers instead of all going outdated.
    func testWithoutTheStatusRemovedLinesAreUnknown() {
        let removed = ReviewComment(id: System.uuid(), path: "a.swift", start: old(4), end: old(4),
                                    quote: [ReviewQuote(kind: .removed, text: "    stop()", line: old(4))], text: "r",
                                    created: created, area: .unstaged)
        let lined = comment(on: 6...6, of: file)
        let result = ReviewRefresh.relocate([removed, lined], file: .lines(["// new"] + file), diffs: [:], areas: nil)
        XCTAssertEqual(result[0], removed)
        XCTAssertEqual(result[1].end, new(7))
    }

    /// The review refreshed against `file` (every diff all of it as context), and the changes whose diffs it asked.
    private nonisolated static func refresh(_ review: Review, status: GitStatus, file: [String]) async -> ([String], Review) {
        var asked: [String] = []
        let refreshed = await ReviewRefresh.refresh(review, status: status, read: { _ in .lines(file) }, diff: { change in
            asked.append(change.id)
            return GitDiff(path: change.path, text: "@@ -1,9 +1,9 @@\n" + file.map { " " + $0 }.joined(separator: "\n") + "\n")
        })
        return (asked, refreshed)
    }

    /// A comment written before quotes kept their numbers: its run is numbered from its first line when it fits
    /// between its first and last, else only those two lines are looked for.
    func testOldCommentsAreNumberedFromTheirEnds() {
        let run = ReviewComment(id: System.uuid(), path: "a.swift", start: new(2), end: new(4),
                                quote: file[1...3].map { ReviewQuote(kind: .context, text: $0) }, text: "x", created: created)
        let anchors = ReviewMatch.anchors(run)
        XCTAssertEqual(anchors[.new]?.map(\.number), [2, 3, 4])
        let mixed = ReviewComment(id: System.uuid(), path: "a.swift", start: old(7), end: new(9),
                                  quote: [ReviewQuote(kind: .removed, text: "gone"), ReviewQuote(kind: .added, text: "x"),
                                          ReviewQuote(kind: .added, text: "y")], text: "x", created: created)
        let ends = ReviewMatch.anchors(mixed)
        XCTAssertEqual(ends[.old]?.map(\.number), [7])
        XCTAssertEqual(ends[.new]?.map(\.number), [9])
        XCTAssertEqual(ends[.new]?.map(\.text), ["y"])
    }
}
