import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Review's diff screen (R2–R4, S5; docs/ios.md, Review): the rows from a change's diff and file, the comments placed
/// on them as the Mac places them, the outdated ones, the selection, and saving into the shared review model.
@MainActor
final class ReviewDiffTests: XCTestCase {
    private let path = "src/components/Sidebar.tsx"
    private var sidebar: GitChange { ReviewSample.changes.first { $0.path == path }! }
    private let place = ReviewPlace(host: UUID(uuidString: "00000000-0000-0000-0000-00000000AB01")!, root: "/Users/alex/src/app")

    private func document(file: Bool = true) -> ReviewDiffDocument {
        ReviewDiffDocument(diff: ReviewSample.diff(sidebar), file: file ? ReviewSample.text(path) : nil)
    }

    private func comments() -> [ReviewComment] { ReviewSample.comments().filter { $0.path == path } }

    private func index(_ rows: [ReviewDiffRow], new number: Int) -> Int {
        rows.firstIndex { $0.line == ReviewLine(side: .new, number: number) }!
    }

    // MARK: Rows

    func testTheSampleDiffBecomesHunksLinesAndAGap() {
        let rows = document().rows(.diff)
        XCTAssertEqual(rows.first?.content, .hunk("@@ -1,6 +1,9 @@"))
        XCTAssertEqual(rows[1].content, .code(.context, old: 1, new: 1))
        XCTAssertEqual(rows[1].text, ReviewSample.sidebar[0])
        XCTAssertEqual(rows[3].content, .code(.added, old: nil, new: 3))
        XCTAssertEqual(rows[10].content, .gap(count: 31), "the 31 lines between the hunks")
        XCTAssertEqual(rows[11].content, .hunk("@@ -38,12 +41,17 @@ export function Sidebar() {"))
        let removed = rows.first { $0.content == .code(.removed, old: 39, new: nil) }
        XCTAssertEqual(removed?.line, ReviewLine(side: .old, number: 39))
        XCTAssertEqual(removed?.quote, ReviewQuote(kind: .removed, text: "    <nav className=\"sidebar\">"))
        let added = rows[index(rows, new: 42)]
        XCTAssertEqual(added.quote, ReviewQuote(kind: .added, text: ReviewSample.sidebar[41]))
        XCTAssertNil(rows[0].line, "a hunk header takes no comment")
        XCTAssertEqual(rows.filter { if case .code = $0.content { true } else { false } }.count, 9 + 20)
    }

    func testAGapOpensWithTheFilesLines() throws {
        let document = document()
        let closed = document.rows(.diff)
        let opened = document.rows(.diff, openedGaps: [1])
        XCTAssertEqual(opened.count, closed.count + 30)
        let tenth = opened[index(opened, new: 10)]
        XCTAssertEqual(tenth.content, .code(.context, old: 7, new: 10))
        XCTAssertEqual(tenth.text, ReviewSample.sidebar[9])
        XCTAssertEqual(tenth.quote, ReviewQuote(kind: .context, text: ReviewSample.sidebar[9]))
        // Without the file the gap stays one row.
        let unread = self.document(file: false)
        XCTAssertEqual(unread.rows(.diff, openedGaps: [1]).count, closed.count)
    }

    func testSourceIsTheFileWithTheAddedLinesMarked() {
        let rows = document().rows(.source)
        XCTAssertEqual(rows.count, ReviewSample.sidebar.count)
        XCTAssertEqual(rows[41].content, .code(.added, old: nil, new: 42))
        XCTAssertEqual(rows[0].content, .code(.context, old: nil, new: 1))
        XCTAssertEqual(rows[20].line, ReviewLine(side: .new, number: 21))
        // Without the file: the diff's new side and what it leaves out.
        let partial = document(file: false).rows(.source)
        XCTAssertTrue(partial.contains { $0.content == .omitted(count: 31) })
        XCTAssertFalse(partial.contains { if case .code(.removed, _, _) = $0.content { true } else { false } })
    }

    // MARK: Placement

    func testTheSampleCommentsLandOnTheirRows() throws {
        let rows = document().rows(.diff)
        let comments = comments()
        let layout = ReviewDiffLayout(rows: rows, comments: comments)
        let line42 = index(rows, new: 42), line45 = index(rows, new: 45), line48 = index(rows, new: 48)
        XCTAssertEqual(layout.ranges[comments[0].id], line42...line42)
        XCTAssertEqual(layout.ranges[comments[1].id], line45...line48)
        XCTAssertEqual(layout.chips[line42], [comments[0].id])
        XCTAssertEqual(layout.chips[line45], [comments[1].id])
        XCTAssertNil(layout.chips[line48], "the chip is on the range's first row")
        XCTAssertTrue(layout.commented(line45 + 2))
        XCTAssertFalse(layout.commented(line42 + 1))
        XCTAssertEqual(layout.order, comments.map(\.id))
        XCTAssertTrue(layout.top.isEmpty)
    }

    func testAMovedCommentNamesItsLineAndAnUnfoundOneGoesOnTop() throws {
        let rows = document().rows(.diff)
        var moved = comments()[0]
        moved.start = ReviewLine(side: .new, number: 40)
        moved.end = ReviewLine(side: .new, number: 40)
        let file = ReviewComment(id: UUID(), path: path, start: nil, end: nil, quote: [], text: "The whole file.",
                                 created: Date(), area: .unstaged)
        var lost = comments()[1]
        lost.id = UUID()
        lost.quote = [ReviewQuote(kind: .added, text: "nowhere()")]
        let layout = ReviewDiffLayout(rows: rows, comments: [moved, file, lost])
        XCTAssertEqual(layout.comments[moved.id]?.end, ReviewLine(side: .new, number: 42))
        XCTAssertEqual(ReviewText.location(try XCTUnwrap(layout.comments[moved.id])), "Line 42")
        XCTAssertEqual(layout.top.map(\.id), [file.id, lost.id], "the file's own first")
        XCTAssertEqual(layout.order.first, file.id)
    }

    func testOutdatedCommentsAreTheOnesWhoseLinesLeftTheFile() {
        let outdated = ReviewSample.outdated()
        let all = [outdated] + comments()
        XCTAssertEqual(document().outdated(all), [outdated.id])
        XCTAssertEqual(document(file: false).outdated(all), [], "unknown without the file")
        XCTAssertEqual(ReviewDiffText.was(outdated), "was lines 12–14")
    }

    func testACommentBetweenTheHunksOpensItsGap() throws {
        let document = document()
        let comment = ReviewComment(id: UUID(), path: path, start: ReviewLine(side: .new, number: 20),
                                    end: ReviewLine(side: .new, number: 20),
                                    quote: [ReviewQuote(kind: .context, text: ReviewSample.sidebar[19])],
                                    text: "Early return.", created: Date(), area: .unstaged)
        XCTAssertEqual(document.holding([comment]).gaps, [1])
        let model = ReviewDiffModel(path: path, area: .unstaged)
        // The rows a model draws with that comment hold its line.
        let rows = document.rows(.diff, openedGaps: document.holding([comment]).gaps)
        XCTAssertNotNil(ReviewDiffLayout(rows: rows, comments: [comment]).ranges[comment.id])
        XCTAssertNil(model.layout([comment]), "nothing before the diff is read")
    }

    // MARK: Selection

    func testTappingSelectsExtendsAndClears() throws {
        let rows = document().rows(.diff)
        let line45 = index(rows, new: 45), line48 = index(rows, new: 48)
        var selection = ReviewDiffSelection.tap(nil, row: line45, in: rows)
        XCTAssertEqual(selection?.rows, line45...line45)
        selection = ReviewDiffSelection.tap(selection, row: line48, in: rows)
        XCTAssertEqual(selection?.rows, line45...line48)
        let draft = try XCTUnwrap(selection?.draft(in: rows))
        XCTAssertEqual(draft.start, ReviewLine(side: .new, number: 45))
        XCTAssertEqual(draft.end, ReviewLine(side: .new, number: 48))
        XCTAssertEqual(draft.quote, ReviewSample.sidebar[44...47].map { ReviewQuote(kind: .added, text: $0) })
        XCTAssertEqual(ReviewDiffText.pill(start: draft.start, end: draft.end), "Comment on 45–48")
        XCTAssertEqual(ReviewText.location(start: draft.start, end: draft.end), "Lines 45–48")
        XCTAssertEqual(ReviewDiffSelection.tap(selection, row: 0, in: rows), selection, "a hunk header does nothing")
        let one = ReviewDiffSelection.tap(nil, row: line45, in: rows)
        XCTAssertNil(ReviewDiffSelection.tap(one, row: line45, in: rows), "the only selected row clears")
    }

    func testHandlesClampToCommentableRows() {
        let rows = document().rows(.diff)
        let line42 = index(rows, new: 42), line45 = index(rows, new: 45), line48 = index(rows, new: 48)
        let selection = ReviewDiffSelection(anchor: line45, head: line48)
        XCTAssertEqual(selection.moving(top: true, to: line42, in: rows).rows, line42...line48)
        // Past the first hunk's header: the first line after it.
        XCTAssertEqual(selection.moving(top: true, to: -5, in: rows).rows, 1...line48)
        XCTAssertEqual(selection.moving(top: false, to: rows.count + 9, in: rows).rows.upperBound, rows.count - 1)
        // The gap row is stepped over towards the end that stays.
        let gap = rows.firstIndex { $0.content == .gap(count: 31) }!
        XCTAssertEqual(selection.moving(top: true, to: gap, in: rows).rows.lowerBound, gap + 2)
        XCTAssertEqual(ReviewDiffMetrics.row(at: 25, offsets: ReviewDiffMetrics().offsets(rows)), 1)
        XCTAssertEqual(ReviewDiffMetrics.row(at: 10 * 20 + 27, offsets: ReviewDiffMetrics().offsets(rows)), 11, "past the 26 point gap")
    }

    func testASelectionAcrossBothSidesNamesBoth() throws {
        let rows = document().rows(.diff)
        let removed = rows.firstIndex { $0.line == ReviewLine(side: .old, number: 39) }!
        let draft = try XCTUnwrap(ReviewDiffSelection(anchor: removed, head: index(rows, new: 42)).draft(in: rows))
        XCTAssertEqual(ReviewText.location(start: draft.start, end: draft.end), "Old line 39 to new line 42")
        XCTAssertEqual(ReviewDiffText.pill(start: draft.start, end: draft.end), "Comment on these lines")
        XCTAssertEqual(draft.quote.map(\.kind), [.removed, .added])
    }

    // MARK: Saving

    func testSavingEditingAndDeletingWriteTheMacsFields() throws {
        let repository = ReviewRepository(store: ReviewMemoryStore())
        let scope = place.scope
        let comments = ReviewDiffComments(repository: repository, scope: scope, path: path, area: .unstaged)
        let quote = ReviewSample.sidebar[44...47].map { ReviewQuote(kind: .added, text: $0) }
        XCTAssertNil(comments.save(ReviewDiffDraft(start: nil, end: nil, quote: [], text: "  \n")), "nothing to save")
        let before = Date()
        let id = try XCTUnwrap(comments.save(ReviewDiffDraft(start: ReviewLine(side: .new, number: 45),
                                                            end: ReviewLine(side: .new, number: 48), quote: quote,
                                                            text: " Keep the old markup. ")))
        let saved = try XCTUnwrap(repository.review(scope).comments.first)
        XCTAssertEqual(saved, ReviewComment(id: id, path: path, start: ReviewLine(side: .new, number: 45),
                                            end: ReviewLine(side: .new, number: 48), quote: quote,
                                            text: "Keep the old markup.", created: saved.created, area: .unstaged))
        XCTAssertGreaterThanOrEqual(saved.created, before.addingTimeInterval(-1))
        // The Mac's Create review renders it as its own.
        let text = ReviewText.render(repository.review(scope), context: .init(root: place.root, host: "mba2", branch: "dark-mode"))
        XCTAssertTrue(text.contains("## \(path)\n\nLines 45–48:\n```diff\n+" + ReviewSample.sidebar[44] + "\n"), text)
        XCTAssertTrue(text.contains("\nKeep the old markup.\n"), text)

        XCTAssertEqual(comments.save(ReviewDiffDraft(start: saved.start, end: saved.end, quote: quote, editing: id,
                                                     text: "Edited.")), id)
        XCTAssertEqual(repository.review(scope).comments.map(\.text), ["Edited."])
        XCTAssertEqual(repository.review(scope).comments.first?.created, saved.created)
        comments.delete(id)
        XCTAssertTrue(repository.review(scope).comments.isEmpty)
    }

    func testKeepForTheFileMakesAnOutdatedCommentAFileComment() throws {
        let outdated = ReviewSample.outdated()
        let repository = ReviewRepository(store: ReviewMemoryStore([place.scope: Review(comments: [outdated])]))
        let comments = ReviewDiffComments(repository: repository, scope: place.scope, path: path, area: .unstaged)
        comments.keepForFile(outdated.id)
        let kept = try XCTUnwrap(repository.review(place.scope).comments.first)
        XCTAssertEqual(kept.id, outdated.id)
        XCTAssertTrue(kept.onFile)
        XCTAssertNil(kept.start)
        XCTAssertEqual(kept.quote, outdated.quote)
        XCTAssertEqual(kept.text, outdated.text)
        XCTAssertEqual(ReviewText.location(kept), "File")
        // Not outdated any more: on the file, it goes above the diff as a plain card.
        XCTAssertEqual(document().outdated([kept]), [])
    }

    // MARK: Model

    private func context(_ review: MobileReview) -> ReviewContext {
        ReviewContext(review: review, place: place, tab: TabRef(host: place.host, key: "herdr:app:1"), host: "mba2",
                      branch: "dark-mode", offline: false, push: { _ in })
    }

    private func sampleReview(_ comments: [ReviewComment]? = nil) -> MobileReview {
        let store = ReviewMemoryStore([place.scope: Review(comments: comments ?? ReviewSample.comments())])
        let review = MobileReview(repository: ReviewRepository(store: store), demo: nil)
        review.reader = { _ in ReviewSample.reader }
        return review
    }

    func testTheModelReadsTheChangeAndWritesANewComment() async throws {
        let review = sampleReview()
        let model = ReviewDiffModel(path: path, area: .unstaged)
        await model.reload(context(review))
        XCTAssertNotNil(model.document)
        XCTAssertEqual(model.change.additions, 14)
        XCTAssertEqual(model.change.deletions, 6)
        let shown = model.comments(review.repository.review(place.scope), status: review.changes(place).status)
        XCTAssertEqual(shown.count, 2, "ThemeToggle.tsx's comment is not on this diff")
        let layout = try XCTUnwrap(model.layout(shown)).layout
        model.step(1, order: layout.order)
        XCTAssertEqual(model.open, shown[0].id)
        model.step(-1, order: layout.order)
        XCTAssertEqual(model.open, shown[1].id, "the stepper wraps around")

        let rows = layout.rows
        model.tap(index(rows, new: 52), rows: rows)
        XCTAssertNil(model.open, "selecting closes the card")
        model.tap(index(rows, new: 54), rows: rows)
        model.compose(rows: rows)
        XCTAssertEqual(model.draft?.location, "Lines 52–54")
        model.draft?.text = "Move the footer out."
        model.send(ReviewDiffComments(repository: review.repository, scope: place.scope, path: path, area: .unstaged))
        XCTAssertNil(model.draft)
        XCTAssertNil(model.selection)
        let added = try XCTUnwrap(review.repository.review(place.scope).comments.last)
        XCTAssertEqual(model.open, added.id, "the new comment's card opens")
        XCTAssertEqual(added.quote.count, 3)
        XCTAssertEqual(review.count(place), 4)
    }

    func testWithoutAReaderTheScreenSaysSo() async {
        let review = MobileReview(repository: ReviewRepository(store: ReviewMemoryStore()), demo: nil)
        let model = ReviewDiffModel(path: path, area: .unstaged)
        await model.reload(context(review))
        XCTAssertEqual(model.load, .unavailable("mba2 can’t be read now."))
    }

    // MARK: View

    func testTheDiffScreenDrawsTheSampleWithLabels() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let review = sampleReview()
        let screen = NavigationStack { ReviewDiffScreen(context: context(review), path: path, area: .unstaged) }
        let found = await TestSupport.windowScene()
        let scene = try XCTUnwrap(found)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: screen)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        var labels: [String] = []
        try await TestSupport.eventually(timeout: .seconds(5)) {
            labels = Self.labels(host.view)
            return labels.contains { $0.hasPrefix("Line 42, added:") }
        }
        XCTAssertTrue(labels.contains("Line 42, added: <nav className={`sidebar sidebar--${theme}`}>"), "\(labels)")
        XCTAssertTrue(labels.contains("Removed line 39: <nav className=\"sidebar\">"), "\(labels)")
        XCTAssertTrue(labels.contains("1 comment on line 42"), "\(labels)")
        XCTAssertTrue(labels.contains("1 comment on lines 45–48"), "\(labels)")
        XCTAssertTrue(labels.contains("Show 31 unmodified lines"), "\(labels)")
        XCTAssertTrue(labels.contains("Comment"), "\(labels)")
    }

    private static func labels(_ view: UIView) -> [String] {
        var found: [String] = []
        func walk(_ element: NSObject) {
            if element.isAccessibilityElement, let label = element.accessibilityLabel { found.append(label) }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        return found
    }
}
