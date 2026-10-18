import Foundation
import XCTest
@testable import DispatchApp

/// The Commits tab's lanes and its texts: where each commit's dot sits, which lines
/// cross each row, which are the current branch's, and how deep lanes collapse.
@MainActor
final class GitGraphTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_700_000)

    /// Commits from "hash: parent parent" lines, newest first, as `git log` lists them.
    private func log(_ lines: [String]) -> [GitCommit] {
        lines.enumerated().map { index, line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let parents = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
            return GitCommit(hash: parts[0], parents: parents, subject: "Commit \(parts[0])", body: "", author: "Ivan",
                             email: "ivan@example.com", date: now.addingTimeInterval(Double(-index) * 3_600), refs: [])
        }
    }

    private typealias Line = GitGraph.Line

    private func pass(_ lane: Int, current: Bool = true) -> Line { Line(kind: .pass, from: lane, to: lane, current: current) }
    private func into(_ from: Int, _ to: Int, current: Bool = true) -> Line { Line(kind: .into, from: from, to: to, current: current) }
    private func out(_ from: Int, _ to: Int, current: Bool = true) -> Line { Line(kind: .out, from: from, to: to, current: current) }

    func testAnEmptyLogDrawsNothing() {
        XCTAssertEqual(GitGraph.layout([], head: nil), GitGraph.empty)
        let top = GitGraph.layout([], head: nil, uncommitted: true)
        XCTAssertEqual(top.rows, [])
        XCTAssertEqual(top.top, GitGraph.Row(lane: 0, current: true, lines: [], hidden: 0), "the hollow dot stands alone")
        XCTAssertEqual(top.lanes, 1)
    }

    func testLinearHistoryIsOneGreenLane() {
        let graph = GitGraph.layout(log(["c: b", "b: a", "a"]), head: "c", uncommitted: true)
        XCTAssertEqual(graph.lanes, 1)
        XCTAssertEqual(graph.top?.lines, [out(0, 0)])
        XCTAssertEqual(graph.rows.map(\.lane), [0, 0, 0])
        XCTAssertTrue(graph.rows.allSatisfy(\.current))
        XCTAssertEqual(graph.rows[0].lines, [into(0, 0), out(0, 0)], "the uncommitted dot runs into HEAD")
        XCTAssertEqual(graph.rows[1].lines, [into(0, 0), out(0, 0)])
        XCTAssertEqual(graph.rows[2].lines, [into(0, 0)], "the root commit ends the lane")
        XCTAssertEqual(GitGraph.layout(log(["c: b", "b: a", "a"]), head: "c").rows[0].lines, [out(0, 0)],
                       "without uncommitted changes the tip has no line above")
    }

    /// The mockup's graph: a merge of a two-commit branch that forked from "r".
    func testAMergeOpensASecondLaneAndTheForkClosesIt() {
        let commits = log(["m: k f", "k: r", "f: g", "g: r", "r: s", "s"])
        let graph = GitGraph.layout(commits, head: "m")
        XCTAssertEqual(graph.lanes, 2)
        XCTAssertEqual(graph.rows.map(\.lane), [0, 0, 1, 1, 0, 0])
        XCTAssertEqual(graph.rows.map(\.current), [true, true, false, false, true, true])
        XCTAssertEqual(graph.rows[0].lines, [out(0, 0), out(0, 1, current: false)], "the merge's second parent curves right")
        XCTAssertEqual(graph.rows[1].lines, [into(0, 0), pass(1, current: false), out(0, 0)])
        XCTAssertEqual(graph.rows[2].lines, [pass(0), into(1, 1, current: false), out(1, 1, current: false)])
        XCTAssertEqual(graph.rows[3].lines, [pass(0), into(1, 1, current: false), out(1, 0, current: false)],
                       "the branch joins the lane already waiting for its parent")
        XCTAssertEqual(graph.rows[4].lines, [into(0, 0), out(0, 0)])
    }

    func testTwoTipsForkingFromOneCommitMeetAtIt() {
        // "x" (another branch, listed first) and "h" (HEAD) both come from "b": the current branch keeps lane 1, where
        // it started, and the other line meets it at "b".
        let commits = log(["x: b", "h: b", "b: a", "a"])
        let graph = GitGraph.layout(commits, head: "h")
        XCTAssertEqual(graph.rows.map(\.lane), [0, 1, 1, 1])
        XCTAssertEqual(graph.rows.map(\.current), [false, true, true, true])
        XCTAssertEqual(graph.rows[1].lines, [pass(0, current: false), out(1, 1)],
                       "the current branch does not merge into the other branch's lane")
        XCTAssertEqual(graph.rows[2].lines, [into(0, 1, current: false), into(1, 1), out(1, 1)])
        XCTAssertEqual(graph.lanes, 2)
    }

    func testABranchThatEndsGivesItsLaneBack() {
        // "o" is an orphan branch's only commit; later tips reuse its lane.
        let commits = log(["h: g", "o", "g: f", "t: f", "f"])
        let graph = GitGraph.layout(commits, head: "h")
        XCTAssertEqual(graph.rows[1].lane, 1)
        XCTAssertEqual(graph.rows[1].lines, [pass(0)], "a commit without parents draws no line below")
        XCTAssertEqual(graph.rows[3].lane, 1, "the next tip takes the freed lane")
        XCTAssertEqual(graph.rows[3].lines, [pass(0), out(1, 0, current: false)])
        XCTAssertEqual(graph.lanes, 2)
    }

    func testLanesBeyondEightCollapseIntoACount() {
        // Ten branches of two commits each over one root: every tip opens a lane, kept until its second commit joins
        // the root's lane.
        let tips = (0..<10).map { "t\($0): p\($0)" }, seconds = (0..<10).map { "p\($0): r" }
        let graph = GitGraph.layout(log(tips + seconds + ["r"]), head: "t0")
        XCTAssertEqual(graph.rows.prefix(10).map(\.lane), Array(0..<10))
        XCTAssertEqual(graph.lanes, GitGraph.maxLanes)
        XCTAssertEqual(graph.rows[7].hidden, 0)
        XCTAssertEqual(graph.rows[8].hidden, 1, "the ninth tip's own lane is hidden")
        XCTAssertEqual(graph.rows[9].hidden, 2, "two hidden lanes pass the tenth tip")
        XCTAssertEqual(graph.rows[9].lines, (0..<8).map { pass($0, current: $0 == 0) },
                       "only the drawn lanes' lines are kept")
        XCTAssertEqual(graph.rows[10].hidden, 2)
        XCTAssertEqual(graph.rows[19].lane, 9)
        XCTAssertEqual(graph.rows[19].hidden, 1)
        XCTAssertEqual(graph.rows[19].lines, [pass(0)], "a hidden lane's line into a drawn one is dropped, not drawn across")
        XCTAssertEqual(graph.rows[20].lines, [into(0, 0)])
        XCTAssertEqual(graph.rows[20].hidden, 0)
    }

    func testAFilteredLogDrawsDotsOnly() {
        let graph = GitGraph.layout(log(["c: b", "a: z"]), head: "c", uncommitted: true, linked: false)
        XCTAssertEqual(graph.rows.map(\.lane), [0, 0])
        XCTAssertTrue(graph.rows.allSatisfy { $0.lines.isEmpty })
        XCTAssertEqual(graph.lanes, 1)
    }

    func testHeadComesFromTheRefsThenTheStatus() {
        var commits = log(["x: h", "h: a", "a"])
        XCTAssertEqual(GitGraph.head(in: commits, status: nil, scope: .branch), "x", "a branch's log starts at HEAD")
        XCTAssertNil(GitGraph.head(in: commits, status: nil, scope: .all))
        let status = GitStatus(branch: "main", head: "h", changes: [], loadedAt: now)
        XCTAssertEqual(GitGraph.head(in: commits, status: status, scope: .all), "h")
        commits[1].refs = [GitRef(name: "main", kind: .branch, current: true)]
        XCTAssertEqual(GitGraph.head(in: commits, status: nil, scope: .all), "h")
        let graph = GitGraph.layout(commits, head: "h")
        XCTAssertEqual(graph.rows.map(\.current), [false, true, true])
    }

    // MARK: Texts

    func testHeaderFooterAndAgeTexts() {
        let status = GitStatus(branch: "main", head: "c28855c", upstream: "origin/main", ahead: 2, changes: [
            GitChange(path: "a.ts", kind: .modified, area: .staged),
            GitChange(path: "a.ts", kind: .modified, area: .unstaged),
            GitChange(path: "b.ts", kind: .untracked, area: .untracked),
        ], loadedAt: now)
        // One wording for the checkout in the Changes and Commits headers and the Files footer.
        XCTAssertEqual(GitChangesText.branch(status), "main")
        let detached = GitStatus(head: "c28855c", changes: [], loadedAt: now)
        XCTAssertEqual(GitChangesText.branch(detached), "detached at c28855c")
        XCTAssertEqual(FilesFooter.gitSummary(.repository(GitRepository(root: "/r")), status: detached), "detached at c28855c · 0 changed")
        XCTAssertEqual(status.changedFiles, 2, "the uncommitted row counts a file staged and unstaged once")
        XCTAssertEqual(GitCommitsText.files(1), "1 file")
        let page = GitLog(commits: log(["b: a", "a"]), exhausted: false, scope: .all, filter: "", loadedAt: now)
        XCTAssertEqual(GitCommitsText.commits(page, scope: .all), "2+ commits · all branches", "more pages follow")
        XCTAssertEqual(GitCommitsText.commits(nil, scope: .branch), "this branch")
        XCTAssertEqual(GitCommitsText.footer(page), "2 loaded · scroll for more")
        var all = page
        all.exhausted = true
        XCTAssertEqual(GitCommitsText.commits(all, scope: .branch), "2 commits · this branch")
        all.commits.removeLast()
        XCTAssertEqual(GitCommitsText.commits(all, scope: .branch), "1 commit · this branch")
        XCTAssertEqual(GitCommitsText.footer(all), "1 loaded · all")
        XCTAssertEqual(GitCommitsText.ago(now.addingTimeInterval(-35 * 60), at: now), "35 min ago")
        XCTAssertEqual(GitCommitsText.ago(now.addingTimeInterval(-3_600), at: now), "1 hour ago")
        XCTAssertEqual(GitCommitsText.ago(now.addingTimeInterval(-3 * 86_400), at: now), "3 days ago")
        XCTAssertEqual(GitCommitsText.ago(now.addingTimeInterval(30), at: now), "just now", "clock skew reads now")
    }

    func testAgesMoveWithTheClock() {
        // The rows and the detail read the clock on every minute's tick: the same commit reads older as time passes.
        let date = now.addingTimeInterval(-59 * 60)
        XCTAssertEqual([0, 60, 3 * 3_600].map { FilesFormatting.age(date, at: now.addingTimeInterval(Double($0))) },
                       ["59m", "1h", "3h"])
        XCTAssertEqual([0, 60, 23 * 3_600 + 60].map { GitCommitsText.ago(date, at: now.addingTimeInterval(Double($0))) },
                       ["59 min ago", "1 hour ago", "1 day ago"])
    }

    func testTheFilterDraftKeepsWhatIsTypedAndAppliesItTrimmed() {
        // "fix " typed: the pause applies "fix", and the field keeps the space for the next word.
        XCTAssertEqual(GitCommitsFilter.applied("fix ", filter: ""), "fix")
        XCTAssertNil(GitCommitsFilter.applied("fix ", filter: "fix"), "nothing new to apply after the trailing space")
        XCTAssertFalse(GitCommitsFilter.settled("fix ", filter: "fix", editing: true), "the draft stays while typing")
        XCTAssertEqual(GitCommitsFilter.applied("fix bug", filter: "fix"), "fix bug")
        // Once the field is left, a draft that says what the filter does gives way to it; a pending one does not.
        XCTAssertTrue(GitCommitsFilter.settled("fix ", filter: "fix", editing: false))
        XCTAssertFalse(GitCommitsFilter.settled("fix bug", filter: "fix", editing: false))
        XCTAssertFalse(GitCommitsFilter.settled(nil, filter: "fix", editing: false))
        XCTAssertEqual(GitCommitsFilter.applied("  ", filter: "fix"), "", "spaces alone clear the filter")
        XCTAssertNil(GitCommitsFilter.applied(nil, filter: "fix"))
    }

    func testChipsPutTheCheckedOutBranchFirst() {
        let refs = [GitRef(name: "v2.4.0", kind: .tag, current: false), GitRef(name: "origin/main", kind: .remote, current: false),
                    GitRef(name: "main", kind: .branch, current: true), GitRef(name: "dev", kind: .branch, current: false)]
        XCTAssertEqual(GitRefChip.ordered(refs).map(\.name), ["main", "dev", "origin/main", "v2.4.0"])
        XCTAssertTrue(GitRefChip.filled(refs[2]))
        XCTAssertFalse(GitRefChip.filled(refs[3]))
    }
}
