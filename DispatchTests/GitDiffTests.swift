import Foundation
import XCTest
@testable import DispatchApp

/// The diff view's pure side: unified diffs as git prints them parsed into hunks and
/// numbered lines, the fold rule, the Source fallback, and the Changes tab's words. Fixtures are real `git diff` output.
@MainActor
final class GitDiffTests: XCTestCase {
    private typealias Row = GitDiffPresentation.Row

    /// `git diff -- src/routes/billing.ts` with two hunks, the second named by its function.
    private let billing = """
        diff --git a/src/routes/billing.ts b/src/routes/billing.ts
        index 3f2c1a0..9b8e7d2 100644
        --- a/src/routes/billing.ts
        +++ b/src/routes/billing.ts
        @@ -1,4 +1,5 @@
         import { stripe } from '../lib/stripe'
        +import { db } from '../lib/db'
         import type { WebhookEvent } from '../types'
         
         export const SEEN = 1
        @@ -6,8 +7,9 @@ export async function handleWebhook
           const event = stripe.webhooks.constructEvent(raw, signature, secret)
        -  const attempt = Number(event.request?.idempotency_key ?? 0)
        +  const seen = await db.find('webhook_seen', event.id)
        +  if (seen) return { status: 200, body: 'duplicate' }
           switch (event.type) {
             case 'invoice.paid':
               await markPaid(event.data.object)
               break
             default:
        -  return { status: 200 }
        +  return { status: 200, body: 'ok' }

        """

    func testHunksNumberBothSides() throws {
        let diff = GitDiffPresentation.parse(billing)
        XCTAssertFalse(diff.binary)
        XCTAssertTrue(diff.notes.isEmpty, "a plain change has no header lines worth showing")
        XCTAssertEqual(diff.hunks.count, 2)
        let first = diff.hunks[0], second = diff.hunks[1]
        XCTAssertEqual(first.range, "@@ -1,4 +1,5 @@")
        XCTAssertEqual(first.section, "")
        XCTAssertEqual(second.range, "@@ -6,8 +7,9 @@")
        XCTAssertEqual(second.section, "export async function handleWebhook")
        XCTAssertEqual([first.oldStart, first.oldCount, first.newStart, first.newCount], [1, 4, 1, 5])
        XCTAssertEqual(first.lines, 0..<5)
        XCTAssertEqual(second.lines, 5..<16)
        XCTAssertEqual(diff.additions, 4)
        XCTAssertEqual(diff.deletions, 2)

        let added = diff.lines[1]
        XCTAssertEqual(added.kind, .added)
        XCTAssertNil(added.old)
        XCTAssertEqual(added.new, 2)
        XCTAssertEqual(added.text, "import { db } from '../lib/db'", "The marker is not part of the text")
        let blank = diff.lines[3]
        XCTAssertEqual(blank.kind, .context)
        XCTAssertEqual(blank.text, "", "A context line holding only its space marker is an empty line")
        XCTAssertEqual([blank.old, blank.new], [3, 4])
        let removed = diff.lines[6]
        XCTAssertEqual(removed.kind, .removed)
        XCTAssertEqual(removed.old, 7)
        XCTAssertNil(removed.new)
        XCTAssertEqual(diff.lines[15].kind, .added)
        XCTAssertEqual(diff.lines[15].new, 15)
        XCTAssertEqual(diff.lines[14].old, 13, "The second hunk's old side runs 6 through 13")
    }

    func testDiffWithoutTrailingNewlineParsesTheSame() {
        let trimmed = String(billing.dropLast())
        XCTAssertFalse(trimmed.hasSuffix("\n"))
        XCTAssertEqual(GitDiffPresentation.parse(trimmed), GitDiffPresentation.parse(billing))
        let crlf = billing.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(GitDiffPresentation.parse(crlf), GitDiffPresentation.parse(billing), "CRLF output reads as LF")
    }

    func testNoNewlineAtEndOfFileMarksTheLineBeforeIt() {
        // A file that lost its missing final newline: the old "y" had none, the new one does.
        let diff = GitDiffPresentation.parse("""
            diff --git a/nonl.txt b/nonl.txt
            index 1b322989..04ec35a6 100644
            --- a/nonl.txt
            +++ b/nonl.txt
            @@ -1,2 +1,3 @@
             x
            -y
            \\ No newline at end of file
            +y
            +z

            """)
        XCTAssertEqual(diff.lines.map(\.text), ["x", "y", "y", "z"])
        XCTAssertEqual(diff.lines.map(\.noNewline), [false, true, false, false])
        XCTAssertEqual(diff.rows(), [.hunk(0), .line(0), .line(1), .noNewline(1), .line(2), .line(3)])
        XCTAssertEqual(diff.lines[3].new, 3)

        // A marker at the very end, after an addition: the new file ends without a newline.
        let added = GitDiffPresentation.parse("@@ -1 +1,2 @@\n x\n+y\n\\ No newline at end of file\n")
        XCTAssertEqual(added.lines.map(\.noNewline), [false, true])
        XCTAssertEqual(added.hunks.first?.oldCount, 1, "A count left out is 1")
    }

    func testRenameKeepsItsHeaderLines() {
        let diff = GitDiffPresentation.parse("""
            diff --git a/src/old.ts b/src/new.ts
            similarity index 90%
            rename from src/old.ts
            rename to src/new.ts
            index 92dfa216..ba004504 100644
            --- a/src/old.ts
            +++ b/src/new.ts
            @@ -1,6 +1,6 @@
             a
             b
            -c
            +C
             d
             e
             f

            """)
        XCTAssertEqual(diff.notes, ["similarity index 90%", "rename from src/old.ts", "rename to src/new.ts"])
        XCTAssertEqual(diff.hunks.count, 1)
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)

        // A pure rename has no hunks: its header lines are what the view shows.
        let pure = GitDiffPresentation.parse("""
            diff --git a/src/old.ts b/src/new.ts
            similarity index 100%
            rename from src/old.ts
            rename to src/new.ts

            """)
        XCTAssertTrue(pure.hunks.isEmpty)
        XCTAssertEqual(pure.notes, ["similarity index 100%", "rename from src/old.ts", "rename to src/new.ts"])
        XCTAssertTrue(pure.rows().isEmpty)
    }

    func testNewAndBinaryFiles() {
        let added = GitDiffPresentation.parse("""
            diff --git a/tests/idempotency.test.ts b/tests/idempotency.test.ts
            new file mode 100644
            index 0000000..e69de29
            --- /dev/null
            +++ b/tests/idempotency.test.ts
            @@ -0,0 +1,2 @@
            +test('idempotent', () => {
            +})

            """)
        XCTAssertEqual(added.notes, ["new file mode 100644"])
        XCTAssertEqual(added.lines.map(\.new), [1, 2])
        XCTAssertEqual(added.lines.map(\.old), [nil, nil])

        let binary = GitDiffPresentation.parse("""
            diff --git a/bin.dat b/bin.dat
            new file mode 100644
            index 00000000..bdc955b7
            Binary files /dev/null and b/bin.dat differ

            """)
        XCTAssertTrue(binary.binary)
        XCTAssertTrue(binary.lines.isEmpty)
    }

    func testEmptyDiff() {
        let diff = GitDiffPresentation.parse("")
        XCTAssertTrue(diff.hunks.isEmpty)
        XCTAssertTrue(diff.lines.isEmpty)
        XCTAssertTrue(diff.folds.isEmpty)
        XCTAssertEqual(diff.rows(), [])
        XCTAssertEqual(diff.newSideRows(), [])
        XCTAssertEqual(GitDiffPresentation.parse("\n"), diff)
    }

    func testTruncatedDiffKeepsWhatArrived() {
        // Cut at a line end by the helper's bound in the middle of the second hunk.
        let cut = billing.components(separatedBy: "\n").prefix(14).joined(separator: "\n") + "\n"
        let diff = GitDiffPresentation.parse(cut)
        XCTAssertEqual(diff.hunks.count, 2)
        XCTAssertEqual(diff.hunks[1].lines, 5..<8)
        XCTAssertEqual(diff.lines.last?.text, "  const seen = await db.find('webhook_seen', event.id)")
    }

    func testHunkEndsAtTheNextFilesHeader() {
        // Two files in one output (`git show` of a commit): the second header is not read as hunk lines.
        let diff = GitDiffPresentation.parse("""
            @@ -1 +1 @@
            -a
            +b
            diff --git a/z b/z
            --- a/z
            +++ b/z
            @@ -3,2 +3,2 @@
            -c
            +d
             e

            """)
        XCTAssertEqual(diff.hunks.map(\.lines), [0..<2, 2..<5])
        XCTAssertEqual(diff.lines.map(\.text), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(diff.lines[4].old, 4)
    }

    func testCombinedDiffReadsTheFirstParentAsOld() {
        let diff = GitDiffPresentation.parse("""
            diff --cc merged.txt
            @@@ -1,2 -1,2 +1,3 @@@ section
              a
            + b
             -c
            ++d

            """)
        XCTAssertEqual(diff.hunks.first?.range, "@@@ -1,2 -1,2 +1,3 @@@")
        XCTAssertEqual(diff.hunks.first?.section, "section")
        XCTAssertEqual(diff.lines.map(\.kind), [.context, .added, .removed, .added])
        XCTAssertEqual(diff.lines.map(\.text), ["a", "b", "c", "d"])
    }

    func testHunkHeaderForms() {
        XCTAssertEqual(GitDiffPresentation.hunkHeader("@@ -6,8 +8,12 @@ export async function handleWebhook")?.section,
                       "export async function handleWebhook")
        let bare = GitDiffPresentation.hunkHeader("@@ -1 +1 @@")
        XCTAssertEqual(bare?.oldCount, 1)
        XCTAssertEqual(bare?.newCount, 1)
        XCTAssertEqual(bare?.range, "@@ -1 +1 @@")
        XCTAssertNil(GitDiffPresentation.hunkHeader("@@ nonsense @@"))
        XCTAssertNil(GitDiffPresentation.hunkHeader("@ -1 +1 @"))
        XCTAssertNil(GitDiffPresentation.hunkHeader("@@ -1,x +1 @@"))
    }

    // MARK: Folds

    /// One hunk as `git diff` (-U3) prints it: up to three unmodified lines, a change, `middle` unmodified lines (at
    /// most six, or git splits the hunk), a change, up to three unmodified lines.
    private func hunk(leading: Int = 3, middle: Int, trailing: Int = 3) -> GitDiffPresentation {
        var lines: [String] = []
        var number = 0
        func context(_ count: Int) { for _ in 0..<count { number += 1; lines.append(" line \(number)") } }
        context(leading)
        lines.append("-old"); lines.append("+new"); number += 1
        context(middle)
        lines.append("+added")
        context(trailing)
        let old = leading + 1 + middle + trailing, new = old + 1
        return GitDiffPresentation.parse("@@ -1,\(old) +1,\(new) @@\n" + lines.joined(separator: "\n") + "\n")
    }

    func testFoldsRunsBetweenChangesLongerThanThreeKeepingALineBesideEachChange() {
        XCTAssertTrue(hunk(middle: 3).folds.isEmpty, "three unmodified lines never fold")
        XCTAssertTrue(hunk(leading: 3, middle: 1, trailing: 3).folds.isEmpty, "git's three lines at a hunk's edge stay")

        let long = hunk(middle: 6)
        // Lines: 0–2 leading, 3 removed, 4 added, 5–10 middle, 11 added, 12–14 trailing.
        XCTAssertEqual(long.folds, [.init(start: 6, count: 4)], "lines 5 and 10 stay beside the changes")
        let folded: [Row] = [.hunk(0)] + (0...5).map { Row.line($0) } + [.fold(start: 6, count: 4)]
        XCTAssertEqual(long.rows(), folded + (10...14).map { Row.line($0) })
        let open: [Row] = [.hunk(0)] + (0...14).map { Row.line($0) }
        XCTAssertEqual(long.rows(opened: [6]), open)
        XCTAssertEqual(long.rows(allOpen: true), open, "⌥-click opens every fold")
    }

    func testAFourLineRunBetweenChangesFoldsTwo() {
        XCTAssertEqual(hunk(leading: 1, middle: 4, trailing: 1).folds, [.init(start: 4, count: 2)])
        XCTAssertEqual(hunk(middle: 5).folds, [.init(start: 6, count: 3)])
    }

    /// `git diff -- f.txt` (-U3) on a 30-line file: line 2 changed; lines 10 and 15 changed, four unmodified lines
    /// apart, so one hunk; a line inserted after 27. Recorded from real git.
    private let spread = """
        diff --git a/f.txt b/f.txt
        index ac9837cd..ff43cf37 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,5 +1,5 @@
         line 1
        -line 2
        +line 2 changed
         line 3
         line 4
         line 5
        @@ -7,12 +7,12 @@ line 6
         line 7
         line 8
         line 9
        -line 10
        +line 10 changed
         line 11
         line 12
         line 13
         line 14
        -line 15
        +line 15 changed
         line 16
         line 17
         line 18
        @@ -25,6 +25,7 @@ line 24
         line 25
         line 26
         line 27
        +inserted after 27
         line 28
         line 29
         line 30

        """

    func testGapsBetweenHunksComeFromTheirNumbers() {
        let diff = GitDiffPresentation.parse(spread)
        XCTAssertEqual(diff.gaps, [.init(hunk: 1, old: 6, new: 6, count: 1), .init(hunk: 2, old: 19, new: 19, count: 6)])
        XCTAssertEqual(diff.folds, [.init(start: 12, count: 2)], "the inner run of four keeps its own fold")
        func lines(_ range: ClosedRange<Int>) -> [Row] { range.map { Row.line($0) } }
        var expected: [Row] = [.hunk(0)]
        expected += lines(0...5)
        expected += [.gap(hunk: 1, count: 1), .hunk(1)]
        expected += lines(6...11)
        expected += [.fold(start: 12, count: 2)]
        expected += lines(14...19)
        expected += [.gap(hunk: 2, count: 6), .hunk(2)]
        expected += lines(20...26)
        let rows = diff.rows()
        XCTAssertEqual(rows, expected)

        // Opened, a gap shows the file's lines once it is read, numbered on both sides.
        XCTAssertEqual(diff.rows(openedGaps: [2]), rows, "not read yet: still one row")
        let filled = diff.rows(openedGaps: [2], sourceLines: 31)
        XCTAssertFalse(filled.contains(.gap(hunk: 2, count: 6)))
        XCTAssertTrue(filled.contains(.gap(hunk: 1, count: 1)), "opening one gap leaves the others")
        XCTAssertEqual(filled.filter { if case .gapLine = $0 { return true }; return false },
                       (19...24).map { Row.gapLine(old: $0, new: $0) })
        XCTAssertEqual(filled.firstIndex(of: .gapLine(old: 24, new: 24)).map { filled[$0 + 1] }, .hunk(2))
        XCTAssertEqual(diff.rows(openedGaps: [2], sourceLines: 20), rows, "a file now shorter than the gap stays folded")

        let all = diff.rows(allOpen: true, sourceLines: 31)
        XCTAssertTrue(all.contains(.gapLine(old: 6, new: 6)))
        XCTAssertFalse(all.contains { if case .fold = $0 { return true }; if case .gap = $0 { return true }; return false })

        // A side with no lines names the line before it.
        let deletion = GitDiffPresentation.parse("@@ -3,2 +2,0 @@\n-a\n-b\n@@ -10 +8 @@\n-c\n+d\n")
        XCTAssertEqual(deletion.gaps, [.init(hunk: 1, old: 5, new: 3, count: 5)])
        XCTAssertTrue(GitDiffPresentation.parse(billing.replacingOccurrences(of: "@@ -6,8 +7,9 @@", with: "@@ -5,8 +6,9 @@"))
            .gaps.isEmpty, "hunks that touch leave no gap")
        XCTAssertEqual(GitChangesText.unmodified(1), "1 unmodified line")
        XCTAssertEqual(GitChangesText.unmodified(6), "6 unmodified lines")
    }

    func testNewSideRowsNumberTheFileAndMarkWhatIsLeftOut() {
        let diff = GitDiffPresentation.parse(billing)
        let rows = diff.newSideRows()
        // Hunk one covers new lines 1–5, hunk two 7–15: line 6 is not in the diff, and nothing precedes line 1.
        XCTAssertEqual(rows.first, .line(0))
        XCTAssertTrue(rows.contains(.omitted(after: 5, count: 1)))
        let numbers = rows.compactMap { row -> Int? in if case .line(let index) = row { return diff.lines[index].new }; return nil }
        XCTAssertEqual(numbers, [1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        XCTAssertFalse(rows.contains { if case .line(let index) = $0 { return diff.lines[index].kind == .removed }; return false })

        let later = GitDiffPresentation.parse("@@ -10,2 +12,2 @@\n a\n-b\n+c\n")
        XCTAssertEqual(later.newSideRows(), [.omitted(after: 0, count: 11), .line(0), .line(2)])
    }

    // MARK: Words

    private func status(_ changes: [GitChange], branch: String? = "main") -> GitStatus {
        GitStatus(branch: branch, head: "3f2c1a0d9e", changes: changes, loadedAt: Date(timeIntervalSince1970: 0))
    }

    private var mockup: [GitChange] {
        [GitChange(path: "src/routes/chat.ts", kind: .modified, area: .staged, additions: 3, deletions: 0),
         GitChange(path: "src/routes/billing.ts", kind: .modified, area: .unstaged, additions: 8, deletions: 5),
         GitChange(path: "src/lib/db.ts", kind: .modified, area: .unstaged, additions: 1, deletions: 0),
         GitChange(path: "tests/idempotency.test.ts", kind: .untracked, area: .untracked, additions: 14, deletions: 0)]
    }

    func testHeaderWords() {
        let status = status(mockup)
        XCTAssertEqual(GitChangesText.branch(status), "main")
        XCTAssertEqual(GitChangesText.branch(self.status([], branch: nil)), "detached at 3f2c1a0")
        XCTAssertEqual(status.additions, 26)
        XCTAssertEqual(status.deletions, 5)
        // The header's search on Changes: any case, by path or a rename's old path.
        XCTAssertEqual(status.matching("").changes, status.changes)
        XCTAssertEqual(status.matching(" ROUTES ").changes.map(\.path), status.changes.map(\.path).filter { $0.contains("routes") })
        var renamed = status
        renamed.changes = [GitChange(path: "new.ts", oldPath: "lib/old.ts", kind: .renamed, area: .staged)]
        XCTAssertEqual(renamed.matching("old").changes.count, 1)
        XCTAssertTrue(status.matching("nothing-like-this").changes.isEmpty)
    }

    func testRowWords() {
        let rename = GitChange(path: "src/new.ts", oldPath: "src/old.ts", kind: .renamed, area: .staged)
        XCTAssertEqual(GitChangesText.folder(rename), "src/old.ts → src/new.ts")
        XCTAssertEqual(GitChangesText.folder(mockup[1]), "src/routes")
        XCTAssertEqual(GitChangesText.counts(additions: 8, deletions: 5)?.plus, "+8")
        XCTAssertEqual(GitChangesText.counts(additions: 8, deletions: 5)?.minus, "−5")
        XCTAssertNil(GitChangesText.counts(additions: 3, deletions: 0)?.minus)
        XCTAssertEqual(GitChangesText.counts(additions: 1_200, deletions: nil)?.plus, "+1,200")
        XCTAssertNil(GitChangesText.counts(additions: nil, deletions: nil))
        XCTAssertEqual(GitChangesText.binary(old: 48_000, new: 51_000), "binary · 48 KB → 51 KB")
        XCTAssertEqual(GitChangesText.binary(old: nil, new: 51_000), "binary · 51 KB")
        XCTAssertEqual(GitChangesText.binary(old: 0, new: 51_000, kind: .added), "binary · 51 KB")
        XCTAssertEqual(GitChangesText.binary(old: 48_000, new: 0, kind: .deleted), "binary · 48 KB → deleted")
        XCTAssertEqual(GitChangesText.binary(old: nil, new: nil), "binary")
        XCTAssertEqual(GitChangesText.meta(label: "unstaged", additions: 8, deletions: 5, hunks: 2),
                       "unstaged · +8 −5 · 2 hunks")
        XCTAssertEqual(GitChangesText.meta(label: nil, additions: 1, deletions: 0, hunks: 1), "+1 −0 · 1 hunk")
    }

    func testKeyboardMovesThroughTheGroupsInOrder() {
        let ordered = GitChangesText.ordered(status(mockup.reversed()))
        XCTAssertEqual(ordered.map(\.area), [.staged, .unstaged, .unstaged, .untracked])
        let ids = ordered.map(\.id)
        XCTAssertEqual(GitChangesText.moved(nil, by: 1, in: ordered), ids.first)
        XCTAssertEqual(GitChangesText.moved(nil, by: -1, in: ordered), ids.last)
        XCTAssertEqual(GitChangesText.moved(ids[0], by: 1, in: ordered), ids[1])
        XCTAssertEqual(GitChangesText.moved(ids[0], by: -1, in: ordered), ids[0], "Clamped at the top")
        XCTAssertEqual(GitChangesText.moved(ids[3], by: 1, in: ordered), ids[3], "Clamped at the bottom")
        XCTAssertNil(GitChangesText.moved(nil, by: 1, in: []))
    }

    func testSelectionFollowsAChangeAcrossRefreshes() {
        let before = mockup
        let billing = before[1].id
        XCTAssertEqual(GitChangesText.reconciled(billing, previous: before, current: before), billing)
        XCTAssertEqual(GitChangesText.reconciled(nil, previous: [], current: before), before[0].id, "The first is picked")

        // `git add src/routes/billing.ts` in the shell: the change moves to Staged and the selection follows it.
        var staged = before
        staged[1].area = .staged
        XCTAssertEqual(GitChangesText.reconciled(billing, previous: before, current: staged), "staged:src/routes/billing.ts")

        // Committed away: the change now in its place is selected.
        let committed = before.filter { $0.id != billing }
        XCTAssertEqual(GitChangesText.reconciled(billing, previous: before, current: committed), committed[1].id)
        XCTAssertNil(GitChangesText.reconciled(billing, previous: before, current: []))
    }

    func testGitLinesTypeFromWhereverTheShellIs() {
        let repository = "/Users/ivan/src/api"
        XCTAssertEqual(FilesEditor.git("add -p", repository: repository, shellDirectory: "/Users/ivan/src/api/src"),
                       "git add -p")
        XCTAssertEqual(FilesEditor.git("add -p", repository: repository, shellDirectory: repository), "git add -p")
        XCTAssertEqual(FilesEditor.git("add -p", repository: repository, shellDirectory: "/Users/ivan"),
                       "git -C '/Users/ivan/src/api' add -p")
        XCTAssertEqual(FilesEditor.git("show c28855c", repository: repository, shellDirectory: "/Users/ivan/src/apiary"),
                       "git -C '/Users/ivan/src/api' show c28855c", "a sibling folder sharing the prefix is outside")
        XCTAssertEqual(FilesEditor.git("add -p", repository: "/Users/ivan/it's", shellDirectory: nil),
                       #"git -C '/Users/ivan/it'\''s' add -p"#)
    }

    func testGitLinesGoThroughTheTerminalsRefusals() {
        // What the Changes and Commits buttons call: a tab with no terminal types nothing and says why.
        let files = FilesCoordinator { nil }
        let tab = System.uuid()
        defer { FilesEditorNotices.shared.clear(tab) }
        XCTAssertEqual(FilesEditor.runGit("add -p", repository: "/Users/ivan/src/api", tab: tab, files: files), .noTerminal)
        XCTAssertEqual(FilesEditorNotices.shared.notice(for: tab), FilesEditor.Refusal.noTerminal.message)
        XCTAssertEqual(FilesEditor.runGit("show c28855c\nrm -rf ~", repository: "/Users/ivan/src/api", tab: tab,
                                          files: files), .unsafePath, "a newline would run the rest")
        XCTAssertEqual(FilesEditorNotices.shared.notice(for: tab), FilesEditor.Refusal.unsafePath.message)
        XCTAssertEqual(FilesEditor.refusal(path: "", action: .line("git add -p"), hasTerminal: true, busy: true), .busy)
        XCTAssertNil(FilesEditor.refusal(path: "", action: .line("git add -p"), hasTerminal: true, busy: false))
    }

    // MARK: Source

    func testSourceWithoutLinesSaysWhy() {
        let rename = GitDiffPresentation.parse("""
            diff --git a/src/old.ts b/src/new.ts
            similarity index 100%
            rename from src/old.ts
            rename to src/new.ts

            """)
        XCTAssertEqual(GitChangesText.emptySource(rename, kind: .renamed, read: false),
                       "similarity index 100%\nrename from src/old.ts\nrename to src/new.ts")
        let mode = GitDiffPresentation.parse("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n")
        XCTAssertEqual(GitChangesText.emptySource(mode, kind: nil, read: false), "old mode 100644\nnew mode 100755")
        XCTAssertEqual(GitChangesText.emptySource(GitDiffPresentation(), kind: nil, read: false), "No lines in the diff")
        let deleted = GitDiffPresentation.parse("diff --git a/x b/x\ndeleted file mode 100644\n@@ -1,2 +0,0 @@\n-a\n-b\n")
        XCTAssertEqual(GitChangesText.emptySource(deleted, kind: nil, read: false), "Deleted · there is no current file")
        let emptied = GitDiffPresentation.parse("@@ -1,2 +0,0 @@\n-a\n-b\n")
        XCTAssertEqual(GitChangesText.emptySource(emptied, kind: .modified, read: false), "The file is empty")
        XCTAssertEqual(GitChangesText.emptySource(rename, kind: .modified, read: true), "The file is empty",
                       "a file read and found empty")
    }
}
