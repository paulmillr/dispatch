import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The Commits mode (docs/ios.md, Files): the Mac's git commands through `files.git`, the log page by page with its
/// filters, the graph's lanes and indents, a commit's files, signature and diffs, and the list and detail views. The
/// repository is `CommitsFixture`, which prints what git prints for the commands asked.
@MainActor
final class CommitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func log(_ fixture: CommitsFixture, host: String = "mba2") -> CommitsLog {
        let log = CommitsLog()
        log.attach(CommitsQueries(git: fixture, root: "/Users/alex/src/web", host: host))
        return log
    }

    private func logCalls(_ fixture: CommitsFixture) -> [[String]] {
        fixture.calls.filter { $0.first == "log" && $0.contains(GitCommands.format) }
    }

    // MARK: Commands

    /// The phone asks exactly what the Mac asks (`GitCommands`, shared): a page's log and the same range raw.
    func testTheLogArgumentsAreTheMacs() {
        let page = GitCommands.log(scope: .branch, match: .message("router"), skip: 200, count: 200, tip: "abc1234")
        XCTAssertEqual(page, ["log", "-n", "200", "--skip=200", GitCommands.format, "--date=unix",
                              "--grep=router", "--regexp-ignore-case", "--fixed-strings", "abc1234"])
        XCTAssertEqual(GitCommands.raw(page), ["log", "-n", "200", "--skip=200", "--pretty=raw",
                                               "--grep=router", "--regexp-ignore-case", "--fixed-strings", "abc1234"])
        XCTAssertEqual(GitCommands.log(scope: .all, match: .author("Sam"), skip: 0, count: 5, tip: "abc1234"),
                       ["log", "-n", "5", "--skip=0", GitCommands.format, "--date=unix", "--all",
                        "--author=Sam", "--regexp-ignore-case", "--fixed-strings"], "every ref, from no tip")
        XCTAssertEqual(GitCommands.fileDiff("c81a2f4", mergeParent: nil, paths: GitCommands.paths("a[1].ts", old: nil)).diff,
                       ["show", "--format=", "-U3", "c81a2f4", "--", ":(literal)a[1].ts"])
        XCTAssertEqual(GitCommands.fileDiff("9b7ac11", mergeParent: "41f0d9a", paths: ["a.ts"]).stat,
                       ["diff", "--stat", "41f0d9a", "9b7ac11", "--", "a.ts"])
        XCTAssertNil(GitCommands.checked("--all"), "only a hash reaches git where a commit is asked")
        XCTAssertNil(GitCommands.checked("HEAD~1"))
        XCTAssertEqual(GitCommands.checked("c81a2f4"), "c81a2f4")
    }

    // MARK: The log

    func testTheLogLoadsPageByPageToTheEnd() async throws {
        let fixture = CommitsFixture.linear(450)
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.phase, .loaded)
        XCTAssertEqual(log.commits.count, 200)
        XCTAssertFalse(log.exhausted)
        XCTAssertEqual(log.commits.first?.subject, "Change 450")
        XCTAssertEqual(log.head, fixture.head)
        XCTAssertFalse(log.uncommitted)
        log.more()
        try await TestSupport.eventually { log.commits.count == 400 && !log.loadingMore }
        log.more()
        try await TestSupport.eventually { log.commits.count == 450 && log.exhausted }
        XCTAssertEqual(logCalls(fixture).compactMap { $0.first { $0.hasPrefix("--skip=") } }, ["--skip=0", "--skip=200", "--skip=400"])
        XCTAssertTrue(logCalls(fixture).allSatisfy { $0.last == fixture.head }, "every page from the tip read first")
        log.more()
        XCTAssertFalse(log.loadingMore, "nothing follows the last page")
        XCTAssertEqual(log.commits.filter { $0.signature == .ssh }.count, 150, "the raw headers name the signed ones")
    }

    /// A refresh with the same refs and HEAD keeps the pages; a moved ref starts them over.
    func testARefreshReadsThePagesAgainOnlyWhenTheRefsMoved() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.commits.count, 12)
        XCTAssertTrue(log.exhausted)
        try await TestSupport.eventually { log.uncommitted }
        await log.refresh()
        XCTAssertEqual(logCalls(fixture).count, 1, "the refs and HEAD stayed: no page read again")
        XCTAssertEqual(fixture.calls.filter { $0.first == "for-each-ref" }.count, 2)
        let head = log.commits.first
        XCTAssertEqual(head?.refs.first, GitRef(name: "dark-mode", kind: .branch, current: true))
        XCTAssertTrue(log.commits.contains { $0.refs.contains(GitRef(name: "origin/main", kind: .remote, current: false)) },
                      "for-each-ref tells a remote branch from a local one")
        XCTAssertTrue(log.commits.contains { $0.refs.contains(GitRef(name: "v1.4.0", kind: .tag, current: false)) })
    }

    func testSearchAsksMessagesAndAuthorsAndMergesThem() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        await log.refresh()
        log.apply("router")
        try await TestSupport.eventually { log.search == "router" && log.commits.count == 2 }
        XCTAssertEqual(log.shown.map(\.subject), ["Merge branch 'router-upgrade'", "Upgrade react-router to v7"])
        XCTAssertTrue(log.filtered)
        XCTAssertTrue(fixture.calls.contains { $0.contains("--grep=router") })
        XCTAssertTrue(fixture.calls.contains { $0.contains("--author=router") })
        log.apply("priya")
        try await TestSupport.eventually { log.commits.count == 2 && log.commits.allSatisfy { $0.author == "Priya Example" } }
        XCTAssertEqual(CommitsText.count(shown: log.shown.count, exhausted: log.exhausted, filtered: log.filtered), "2 matching")
        log.endSearch()
        try await TestSupport.eventually { log.commits.count == 12 }
        XCTAssertFalse(log.filtered)
    }

    func testTheFilterMenuNarrowsByScopeAuthorAndSignature() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.authors(), ["Alex Rivera", "Sam Example", "Priya Example"], "most commits first")
        log.author = "Sam Example"
        try await TestSupport.eventually { log.commits.count == 3 }
        XCTAssertTrue(fixture.calls.contains { $0.contains("--author=Sam Example") && !$0.contains { $0.hasPrefix("--grep=") } })
        log.author = nil
        try await TestSupport.eventually { log.commits.count == 12 }
        log.signedOnly = true
        XCTAssertEqual(log.shown.count, 5)
        XCTAssertTrue(log.shown.allSatisfy { $0.signature == .ssh })
        XCTAssertEqual(log.graph(maxLanes: 4).rows.map(\.lane), Array(repeating: 0, count: 5), "a filtered log is drawn unlinked")
        XCTAssertNil(log.graph(maxLanes: 4).top, "no uncommitted row under a filter")
        log.signedOnly = false
        log.scope = .all
        try await TestSupport.eventually { self.logCalls(fixture).last?.contains("--all") == true && log.phase == .loaded }
    }

    func testAFailedReadSaysWhyAndKeepsWhatShows() async {
        let fixture = CommitsFixture.sample(now: now)
        fixture.failures["for-each-ref"] = "throw:permission_denied"
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.phase, .failed("Git isn’t allowed on mba2: turn on Files & git for this host"))
        fixture.failures = [:]
        await log.refresh()
        XCTAssertEqual(log.phase, .loaded)
        fixture.failures["for-each-ref"] = "throw:connection_closed"
        await log.refresh()
        XCTAssertEqual(log.phase, .loaded, "the rows stay")
        XCTAssertEqual(log.stale, "mba2 is not connected")
        XCTAssertEqual(log.commits.count, 12)
    }

    func testAnEmptyRepositoryHasAnEmptyLog() async throws {
        let fixture = CommitsFixture(commits: [], refs: [], head: nil, dirty: true)
        fixture.failures["log"] = "fatal: your current branch 'main' does not have any commits yet"
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.phase, .loaded)
        XCTAssertTrue(log.commits.isEmpty)
        XCTAssertTrue(log.exhausted)
        try await TestSupport.eventually { log.uncommitted }
        let graph = log.graph(maxLanes: 4)
        XCTAssertNotNil(graph.top, "the uncommitted changes still show")
        XCTAssertTrue(graph.top?.lines.isEmpty == true, "with no line down to a HEAD")
    }

    /// The log shows as soon as it answers; the uncommitted row joins it when `status` does.
    func testTheLogDoesNotWaitForTheWorkTree() async throws {
        let fixture = CommitsFixture.sample(now: now)
        fixture.hold("status")
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.phase, .loaded)
        XCTAssertEqual(log.commits.count, 12)
        XCTAssertFalse(log.uncommitted, "status has not answered")
        XCTAssertNil(log.graph(maxLanes: 4).top)
        fixture.release("status")
        try await TestSupport.eventually { log.uncommitted }
        XCTAssertNotNil(log.graph(maxLanes: 4).top)
    }

    /// Signed only over pages without a signed commit: the list keeps asking by itself for `automaticPages`, then
    /// waits for Load more, which asks again; nothing claims "no match" while pages remain.
    func testAFilterAppliedHereStopsAfterItsAutomaticPages() async throws {
        let fixture = CommitsFixture.linear(3000, signedEvery: nil)
        let log = log(fixture)
        await log.refresh()
        log.signedOnly = true
        XCTAssertTrue(log.filteredHere)
        XCTAssertTrue(log.shown.isEmpty)
        XCTAssertFalse(log.exhausted)
        for page in 1...CommitsLog.automaticPages {
            log.more()
            try await TestSupport.eventually { log.commits.count == 200 * (page + 1) && !log.loadingMore }
        }
        XCTAssertTrue(log.paused)
        log.more()
        XCTAssertFalse(log.loadingMore, "no further page by itself")
        log.more(automatic: false)
        XCTAssertTrue(log.loadingMore, "Load more asks")
        try await TestSupport.eventually { log.commits.count == 1400 && !log.loadingMore }
        XCTAssertFalse(log.paused, "and starts the count again")
        log.signedOnly = false
        log.more()
        XCTAssertTrue(log.loadingMore, "without a filter applied here the end always asks")
    }

    /// While pages remain, an empty filtered list is still the list: its end says "Looking further…" (or Load more), not
    /// "No matching commits".
    func testAnEmptyFilteredListKeepsLooking() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let fixture = CommitsFixture.linear(3000, signedEvery: nil)
        let log = log(fixture)
        await log.refresh()
        log.signedOnly = true
        let context = try context()
        let (window, host) = try show(CommitsListView(log: log, context: context, queries: log.queries),
                                      size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        try await TestSupport.eventually(timeout: .seconds(10)) {
            accessibilityElements(host.view).contains { $0.accessibilityLabel == "Load more" }
        }
        let labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains("No matching commits"), "\(labels)")
        XCTAssertEqual(log.commits.count, 200 * (CommitsLog.automaticPages + 1), "it read its automatic pages and stopped")
        XCTAssertTrue(labels.contains { $0.hasPrefix("No matches in the 1") && $0.hasSuffix("200 commits read so far") }, "\(labels)")
    }

    func testACancelledReadChangesNothing() async {
        let fixture = CommitsFixture.sample(now: now)
        fixture.failures["for-each-ref"] = "throw:cancelled"
        let log = log(fixture)
        await log.refresh()
        XCTAssertEqual(log.phase, .idle, "not a failure")
        fixture.failures = [:]
        await log.refresh()
        fixture.failures["for-each-ref"] = "throw:cancelled"
        await log.refresh()
        XCTAssertEqual(log.phase, .loaded)
        XCTAssertNil(log.stale)
    }

    // MARK: The graph

    /// H3: the current branch's first-parent chain is green and keeps lane 0, the merged branch runs amber in lane 1 from
    /// the merge down to where it forked, and every row it passes is indented one lane.
    func testTheGraphIndentsTheMergedSpan() async {
        let log = log(CommitsFixture.sample(now: now))
        await log.refresh()
        let graph = log.graph(maxLanes: CommitGraphCell.maxLanes(width: 402))
        XCTAssertEqual(CommitGraphCell.maxLanes(width: 402), 4)
        XCTAssertEqual(graph.top?.lines, [GitGraph.Line(kind: .out, from: 0, to: 0, current: true)])
        XCTAssertEqual(graph.rows.map(\.lane), [0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(graph.rows.map(\.current), [true, true, true, true, false, false, true, true, true, true, true, true])
        XCTAssertTrue(graph.rows[3].lines.contains(GitGraph.Line(kind: .out, from: 0, to: 1, current: false)), "the merge forks amber")
        XCTAssertTrue(graph.rows[7].lines.contains(GitGraph.Line(kind: .into, from: 1, to: 0, current: false)), "and joins at the base")
        let starts = graph.rows.map { CommitGraphCell.width($0, lanes: graph.lanes) }
        XCTAssertEqual(starts, [48, 48, 48, 68, 68, 68, 68, 68, 48, 48, 48, 48])
        XCTAssertEqual(CommitGraphCell.width(graph.top, lanes: graph.lanes), 48)
    }

    /// A history rewritten in the middle (a force-push) with the same ends lays the graph out again.
    func testTheGraphFollowsAChangeInTheMiddle() {
        let fixture = CommitsFixture.linear(5)
        var commits = (0..<5).map { index in
            GitCommit(hash: fixture.commits[index].hash, parents: fixture.commits[index].parents, subject: "", body: "",
                      author: "Alex Rivera", email: "alex@example.com", date: now, refs: [])
        }
        let cache = CommitsGraphCache()
        let before = cache.graph(commits, head: commits[0].hash, uncommitted: false, linked: true, maxLanes: 4)
        // The middle commit now also merges a side commit loaded further down.
        commits[2].parents.append(commits[4].hash)
        let after = cache.graph(commits, head: commits[0].hash, uncommitted: false, linked: true, maxLanes: 4)
        XCTAssertNotEqual(before, after)
        XCTAssertNotEqual(CommitsGraphCache.fingerprint(commits), CommitsGraphCache.fingerprint(Array(commits.reversed())))
    }

    func testDeepLanesFoldIntoACount() {
        // Five branches merged at once: lanes past the room are counted.
        let base = String(format: "%040x", 99)
        let sides = (1...5).map { String(format: "%040x", $0) }
        let merge = GitCommit(hash: String(format: "%040x", 100), parents: [base] + sides, subject: "Octopus", body: "",
                              author: "Sam Example", email: "sam@example.com", date: now, refs: [])
        let commits = [merge] + sides.enumerated().map { index, hash in
            GitCommit(hash: hash, parents: [base], subject: "Side \(index)", body: "", author: "Sam Example",
                      email: "sam@example.com", date: now.addingTimeInterval(Double(-index - 1) * 60), refs: [])
        }
        let graph = GitGraph.layout(commits, head: merge.hash, maxLanes: 3)
        XCTAssertEqual(graph.lanes, 3)
        XCTAssertGreaterThan(graph.rows[0].hidden, 0)
        XCTAssertEqual(CommitGraphCell.width(graph.rows[0], lanes: graph.lanes), CommitGraphCell.x(2) + CommitGraphCell.gap)
    }

    // MARK: A commit

    func testACommitReadsItsFilesRefsAndSignature() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        await log.refresh()
        let hash = CommitsFixture.hash("c81a2f4")
        await log.open(hash)
        guard case .loaded(let detail)? = log.detail(hash) else { return XCTFail("no detail") }
        XCTAssertEqual(detail.files.map(\.path), ["src/components/Sidebar.tsx", "src/components/ThemeToggle.tsx",
                                                  "src/styles/tokens.css", "src/main.tsx"])
        XCTAssertEqual(detail.files.map(\.kind), [.modified, .added, .modified, .modified])
        XCTAssertEqual(detail.files.map(\.additions), [14, 32, 12, 3])
        XCTAssertEqual(detail.files.map(\.deletions), [6, 0, 3, 0])
        XCTAssertEqual(detail.commit.signature, .ssh, "the raw headers read beside the files")
        XCTAssertEqual(detail.commit.body.components(separatedBy: "\n\n").count, 2)
        try await TestSupport.eventually { log.checks[hash] != nil }
        let check = try XCTUnwrap(log.checks[hash])
        XCTAssertEqual(check.verdict, .good(certified: true))
        XCTAssertEqual(CommitSignatureText.look(kind: .ssh, check: check),
                       CommitSignatureText.Look(symbol: "checkmark.seal.fill", text: "Signed · SSH key", tone: .good))
        XCTAssertTrue(fixture.calls.contains(["verify-commit", "--raw", hash]))
        let commit = try XCTUnwrap(log.commit("c81a2f4"))
        XCTAssertEqual(commit.refs, [GitRef(name: "dark-mode", kind: .branch, current: true)])
        // The check is started (or not) before `open` returns.
        await log.open(CommitsFixture.hash("b0c7e26"))
        XCTAssertFalse(fixture.calls.contains(["verify-commit", "--raw", CommitsFixture.hash("b0c7e26")]), "an unsigned commit is not checked")
    }

    /// A check that gets no answer is shown as unchecked (no endless spinner) and can be asked again.
    func testASignatureCheckWithoutAnAnswerCanBeAskedAgain() async throws {
        let fixture = CommitsFixture.sample(now: now)
        fixture.failures["verify-commit"] = "throw:connection_closed"
        let log = log(fixture)
        await log.refresh()
        let hash = CommitsFixture.hash("c81a2f4")
        await log.open(hash)
        try await TestSupport.eventually { log.checks[hash] != nil }
        XCTAssertEqual(log.checks[hash]?.verdict, .unchecked("mba2 did not answer"))
        XCTAssertTrue(log.unanswered.contains(hash))
        XCTAssertEqual(CommitSignatureText.look(kind: .ssh, check: log.checks[hash]).text, "Unverified · SSH key")
        fixture.failures = [:]
        log.checkAgain(hash)
        try await TestSupport.eventually { log.checks[hash]?.verdict == .good(certified: true) }
        XCTAssertFalse(log.unanswered.contains(hash))
    }

    /// Copy patch: a merge's against its first parent, as its files; a cut patch and a failure say so.
    func testCopyPatch() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        await log.refresh()
        var copied: [String] = []
        let merge = CommitsFixture.hash("9b7ac11")
        let result = await log.copyPatch(merge) { copied.append($0) }
        XCTAssertEqual(result, .copied)
        XCTAssertTrue(fixture.calls.contains(["diff", "-U3", CommitsFixture.hash("41f0d9a"), merge]))
        let one = CommitsFixture.hash("c81a2f4")
        _ = await log.copyPatch(one) { copied.append($0) }
        XCTAssertTrue(fixture.calls.contains(["show", "--format=", "-U3", one]))
        XCTAssertTrue(copied.last?.hasPrefix("diff --git a/src/components/Sidebar.tsx") == true)
        fixture.failures["show"] = "fatal: bad object"
        let failed = await log.copyPatch(one) { copied.append($0) }
        XCTAssertEqual(failed, .failed("fatal: bad object"))
        XCTAssertEqual(copied.count, 2, "nothing copied on a failure")
        XCTAssertEqual(CommitDetailScreen.title(.cut(bytes: 8 << 20)), "Patch copied in part")
    }

    /// The tabs' logs are bounded, and one let go while a pushed screen holds it comes back to its tab.
    func testLogsAreBoundedAndAHeldOneComesBack() {
        let commits = MobileCommits(limit: 2)
        let host = UUID()
        let first = TabRef(host: host, key: "a")
        let held = commits.log(first)
        _ = commits.log(TabRef(host: host, key: "b"))
        _ = commits.log(TabRef(host: host, key: "c"))
        XCTAssertTrue(commits.log(first) === held, "the screen still holding it gets the same log")
        var dropped: CommitsLog? = commits.log(TabRef(host: host, key: "d"))
        weak var weakDropped = dropped
        _ = commits.log(TabRef(host: host, key: "e"))
        _ = commits.log(TabRef(host: host, key: "f"))
        dropped = nil
        XCTAssertNil(weakDropped, "nobody holds it: it goes")
    }

    /// A merge's letters come from its first parent, as its counts do; an unsigned commit is not checked.
    func testAMergeIsReadAgainstItsFirstParent() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        let merge = CommitsFixture.hash("9b7ac11"), parent = CommitsFixture.hash("41f0d9a")
        await log.open(merge)
        guard case .loaded(let detail)? = log.detail(merge) else { return XCTFail("no detail") }
        XCTAssertEqual(detail.commit.parents.count, 2)
        XCTAssertTrue(fixture.calls.contains(["diff", "--name-status", "-z", parent, merge]))
        XCTAssertFalse(fixture.calls.contains { $0.first == "verify-commit" })
        await log.read(detail.commit, path: "src/router.tsx", oldPath: nil, source: false)
        XCTAssertTrue(fixture.calls.contains(["diff", "-U3", parent, merge, "--", "src/router.tsx"]))
        let rows = CommitFacts.rows(detail.commit, now: now)
        XCTAssertEqual(rows.map(\.label), ["Author", "Date", "First parent", "Merged"])
        XCTAssertEqual(rows.last?.commit, CommitsFixture.hash("2c9d8e0"))
    }

    func testAFileShowsItsDiffAndTheFileAsTheCommitLeftIt() async throws {
        let fixture = CommitsFixture.sample(now: now)
        let log = log(fixture)
        await log.refresh()
        let commit = try XCTUnwrap(log.commit("c81a2f4"))
        await log.read(commit, path: "src/components/Sidebar.tsx", oldPath: nil, source: false)
        guard case .diff(let diff)? = log.text(commit.hash, path: "src/components/Sidebar.tsx", source: false) else {
            return XCTFail("no diff")
        }
        let rows = CommitFileRows.diff(diff, path: "src/components/Sidebar.tsx")
        guard case .hunk(let header)? = rows.first else { return XCTFail("starts at its hunk: \(rows.prefix(2))") }
        XCTAssertTrue(header.hasPrefix("@@ -1,20 +1,28 @@"))
        func kinds(_ rows: [CommitFileRows.Row]) -> [DiffLine.Kind] {
            rows.compactMap { if case .line(let kind, _, _) = $0 { kind } else { nil } }
        }
        XCTAssertEqual(kinds(rows).count { $0 == .added }, 14)
        XCTAssertEqual(kinds(rows).count { $0 == .removed }, 6)
        await log.read(commit, path: "src/components/Sidebar.tsx", oldPath: nil, source: true)
        guard case .source(let text)? = log.text(commit.hash, path: "src/components/Sidebar.tsx", source: true) else {
            return XCTFail("no source")
        }
        XCTAssertTrue(fixture.calls.contains(["show", "--format=", "-U2000000", commit.hash, "--", "src/components/Sidebar.tsx"]))
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count - 1, 28, "the new side, whole")
        let source = CommitFileRows.source(text, diff: diff, path: "src/components/Sidebar.tsx")
        XCTAssertEqual(kinds(source).count { $0 == .added }, 14, "the commit's additions marked in the file")
        XCTAssertEqual(kinds(source).count { $0 == .removed }, 6, "its removals where they were")
        XCTAssertEqual(kinds(source).count, 34)
        XCTAssertEqual(CommitFileRows.diff(GitDiff(path: "logo.png", text: "", binary: true, oldSize: 2048, newSize: 4096),
                                           path: "logo.png"), [.note("Binary file · 2 KB → 4 KB")])
    }

    // MARK: Texts

    func testTexts() throws {
        XCTAssertEqual(CommitsText.age(now.addingTimeInterval(-25 * 60), now: now), "25m")
        XCTAssertEqual(CommitsText.age(now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(CommitsText.age(now.addingTimeInterval(-8 * 86_400), now: now), "1w")
        XCTAssertEqual(CommitsText.age(now.addingTimeInterval(-60 * 86_400), now: now), "2mo")
        XCTAssertEqual(CommitsText.ago(now.addingTimeInterval(-25 * 60), now: now), "25m ago")
        XCTAssertEqual(CommitsText.count(shown: 148, exhausted: true, filtered: false), "148 commits")
        XCTAssertEqual(CommitsText.count(shown: 200, exhausted: false, filtered: false), "200+ commits")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        // The formatter puts a narrow no-break space before AM.
        func date(_ seconds: TimeInterval, _ now: Date) -> String {
            CommitsText.date(now.addingTimeInterval(seconds), now: now, calendar: calendar, locale: locale)
                .replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 9, minute: 30)))
        XCTAssertEqual(date(-47 * 60, today), "Today, 8:43 AM")
        XCTAssertEqual(date(-86_400, today), "Yesterday, 9:30 AM")
        XCTAssertEqual(date(-5 * 86_400, today), "Oct 18, 2026, 9:30 AM")
        // Every verdict in the chip's grammar.
        func look(_ verdict: GitSignatureCheck.Verdict, kind: GitSignatureKind = .gpg) -> CommitSignatureText.Look {
            CommitSignatureText.look(kind: kind, check: GitSignatureCheck(verdict: verdict, kind: kind))
        }
        XCTAssertEqual(look(.good(certified: false)).text, "Signed · GPG key, not certified")
        XCTAssertEqual(look(.bad).tone, .bad)
        XCTAssertEqual(look(.unknownKey, kind: .ssh).text, "Unknown key · SSH")
        XCTAssertEqual(look(.expiredKey).tone, .warning)
        XCTAssertEqual(look(.unchecked("gpg: not found")).text, "Unverified · GPG key")
        XCTAssertEqual(CommitSignatureText.look(kind: nil, check: nil).text, "Not signed")
        XCTAssertEqual(CommitSignatureText.look(kind: .ssh, check: nil).tone, .plain, "while it is checked")
        XCTAssertEqual(CommitSignatureText.detail(GitSignatureCheck(verdict: .unknownKey, kind: .ssh, key: "SHA256:abc"), kind: .ssh),
                       "SSH signature from a key not in your allowed signers · SSH key: SHA256:abc")
        // Someone else committed it, later: both rows.
        var commit = GitCommit(hash: CommitsFixture.hash("c81a2f4"), parents: [], subject: "s", body: "", author: "Alex Rivera",
                               email: "alex@example.com", date: today, refs: [])
        commit.committer = GitPerson(name: "Sam Example", email: "sam@example.com", date: today.addingTimeInterval(3600), zone: "+0000")
        XCTAssertEqual(CommitFacts.rows(commit, now: today).map(\.label), ["Author", "Committer", "Date", "Committed", "Parent"])
        XCTAssertEqual(CommitFacts.rows(commit, now: today).last?.value, "None, the first commit")
        XCTAssertEqual(CommitRow.spoken(commit, now: today.addingTimeInterval(3600)), "s, Alex Rivera, 1 hour ago")
    }

    // MARK: Views

    private func context(select: @escaping (FilesMode) -> Void = { _ in }, push: @escaping (FilesRoute) -> Void = { _ in })
        throws -> FilesModeContext {
        let workspace = TabsFixtures.workspace()
        workspace.apply(TabsFixtures.app().topology)
        let tab = try XCTUnwrap(workspace.tab("herdr:app:1"))
        return FilesModeContext(tab: tab, host: workspace.host, mode: .commits, directory: "/Users/alex/src/web",
                                git: SpaceGitFacts.Facts(directory: "/Users/alex/src/web", root: "/Users/alex/src/web", branch: "dark-mode"),
                                availability: .available, push: push, select: select)
    }

    /// H3 as VoiceOver reads it: the uncommitted row (Review), the commits by subject, author and age; the bar names the
    /// branch and the count, Search and the filter.
    func testTheListReadsAndOpens() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let fixture = CommitsFixture.sample(now: Date())
        let queries = CommitsQueries(git: fixture, root: "/Users/alex/src/web", host: "mba2")
        let log = CommitsLog()
        var selected: [FilesMode] = [], pushed: [FilesRoute] = []
        let context = try context(select: { selected.append($0) }, push: { pushed.append($0) })
        let view = VStack(spacing: 0) {
            CommitsBar(log: log, context: context)
            CommitsListView(log: log, context: context, queries: queries)
        }
        let (window, host) = try show(view, size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        try await TestSupport.eventually {
            let labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
            // The uncommitted row comes when `status` answers, after the log.
            return labels.contains { $0.hasPrefix("Sidebar theme toggle and unread rows") } && labels.contains("Uncommitted changes")
        }
        let labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains("Uncommitted changes"), "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Merge branch 'router-upgrade', Sam Example, ") && $0.hasSuffix("merge, main, origin/main") },
                      "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("dark-mode") && $0.hasSuffix("12 commits") }, "\(labels)")
        XCTAssertTrue(labels.contains("Search commits"))
        XCTAssertTrue(labels.contains("Filter commits"))
        try tap("Uncommitted changes", in: host.view)
        XCTAssertEqual(selected, [.review])
        let row = try XCTUnwrap(accessibilityElements(host.view).first { $0.accessibilityLabel?.hasPrefix("Upgrade react-router to v7") == true })
        XCTAssertTrue(row.accessibilityActivate())
        XCTAssertEqual(pushed, [FilesRoute(mode: .commits, revision: CommitsFixture.hash("2c9d8e0"))])
    }

    /// C2 as VoiceOver reads it: the subject, the refs and the verdict, the facts, the files with their counts.
    func testTheDetailReadsItsCommit() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let fixture = CommitsFixture.sample(now: Date())
        let log = CommitsLog()
        log.attach(CommitsQueries(git: fixture, root: "/Users/alex/src/web", host: "mba2"))
        await log.refresh()
        let tab = TabRef(host: TabsFixtures.host.id, key: "herdr:app:1")
        let hash = CommitsFixture.hash("c81a2f4")
        let view = NavigationStack {
            CommitDetailScreen(log: log, tab: tab, hash: hash, queries: nil)
        }
        let (window, host) = try show(view, size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        try await TestSupport.eventually {
            accessibilityElements(host.view).contains { $0.accessibilityLabel?.hasPrefix("src/main.tsx") == true }
                && log.checks[hash] != nil
        }
        var labels: [String] = []
        try await TestSupport.eventually {
            labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
            return labels.contains { $0.hasPrefix("alex@example.com · SSH key: SHA256:") }
        }
        for expected in ["Sidebar theme toggle and unread rows", "Branch dark-mode, checked out", "Back to Commits", "More",
                         "src/components/Sidebar.tsx, Modified, 14 added, 6 deleted",
                         "src/components/ThemeToggle.tsx, Added, 32 added"] {
            XCTAssertTrue(labels.contains(expected), "\(expected) in \(labels)")
        }
        XCTAssertTrue(labels.contains { $0.hasPrefix("alex@example.com · SSH key: SHA256:") }, "the signature's signer: \(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("Parent") && $0.contains("7d04e9b") }, "\(labels)")
    }

    private func show(_ view: some View, size: CGSize) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (window, host)
    }

    private func accessibilityElements(_ view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ element: NSObject) {
            if element.isAccessibilityElement { found.append(element) }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        return found
    }

    private func tap(_ label: String, in view: UIView) throws {
        let element = try XCTUnwrap(accessibilityElements(view).first { $0.accessibilityLabel == label }, "no \(label)")
        XCTAssertTrue(element.accessibilityActivate(), "\(label) did not activate")
    }
}
