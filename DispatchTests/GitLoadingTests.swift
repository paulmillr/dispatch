import Foundation
import Observation
import XCTest
@testable import DispatchApp

/// The git data layer against the in-memory host's scripted git: the repository resolved per folder and connection, the
/// status on the files loader's tick only while Files or Changes shows, the marks it puts on every loaded folder, the
/// log's pages and filter, the selections' loads, and no rewrite of a value that did not change.
@MainActor
final class GitLoadingTests: XCTestCase {
    typealias Sleeper = FilesLoadingTests.Sleeper
    typealias Tab = FilesLoadingTests.Tab
    typealias Clock = FilesLoadingTests.Clock
    typealias Redraws = FilesLoadingTests.Redraws

    @MainActor final class Current {
        var source: any FilesSource
        init(_ source: any FilesSource) { self.source = source }
    }

    @MainActor struct Fixture {
        let coordinator: FilesCoordinator
        let session: FilesSession
        let tab: Tab
        let sleeper: Sleeper
        /// The wait before a slow diff shows as loading.
        let delay: Sleeper
        let clock: Clock
        var git: GitLoader { coordinator.git }

        /// Waits until git has nothing in flight and the files loader waits again.
        func idle(file: StaticString = #filePath, line: UInt = #line) async throws {
            try await TestSupport.eventually(file: file, line: line) {
                !git.busy(session.id) && coordinator.loader.waiting(session.id) != nil
            }
        }

        /// The 2 s tick, then quiet.
        func tick(file: StaticString = #filePath, line: UInt = #line) async throws {
            try await TestSupport.eventually(file: file, line: line) { sleeper.pending == 1 }
            clock.now += 2
            sleeper.fire()
            try await TestSupport.eventually(file: file, line: line) { sleeper.pending == 1 }
            try await idle(file: file, line: line)
        }
    }

    private let api = "/Users/ivan/src/api"
    private static let hash = "c28855c0a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private static let parent = "4b1d2a0f9e8d7c6b5a4938271605f4e3d2c1b0a9"
    private static let format = GitQueries.format

    /// The F3a working tree: CHANGELOG.md staged, billing.ts and db.ts changed, tests/ new, node_modules/ ignored.
    private static let porcelain = [
        "# branch.oid \(hash)", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -0",
        "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb CHANGELOG.md",
        "1 .M N... 100644 100644 100644 ccccccc ccccccc src/lib/db.ts",
        "1 .M N... 100644 100644 100644 ddddddd ddddddd src/routes/billing.ts",
        "? tests/", "! node_modules/",
    ].joined(separator: "\0") + "\0"

    private static func record(_ hash: String, parents: [String], subject: String, at: Int, refs: String = "") -> String {
        [hash, parents.joined(separator: " "), "Sam Example", "sam@example.com", String(at), refs, subject, ""]
            .joined(separator: "\u{1F}") + "\0\n"
    }

    private func ok(_ output: String, truncated: Bool = false) -> GitOutput { GitOutput(status: 0, output: output, truncated: truncated) }

    private static let refs = "for-each-ref \(GitQueries.refsFormat) refs/heads refs/remotes refs/tags"
    private static let status = "status --porcelain=v2 --branch -z --ignored --untracked-files=normal"

    private static func diff(_ path: String) -> String {
        "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n@@ -1 +1,2 @@\n x\n+y\n"
    }

    private func repository(_ source: FakeFilesSource) {
        source.gitAnswers["rev-parse --show-toplevel"] = ok(api + "\n")
        source.gitAnswers["rev-parse --verify HEAD"] = ok(Self.hash + "\n")
        source.gitAnswers[Self.status] = ok(Self.porcelain)
        source.gitAnswers["diff --numstat -z"] = ok("1\t0\tsrc/lib/db.ts\08\t5\tsrc/routes/billing.ts\0")
        source.gitAnswers["diff --cached --numstat -z"] = ok("1\t0\tCHANGELOG.md\0")
        source.gitAnswers[Self.refs] = ok("refs/heads/main\t\(Self.hash)\t*\t\nrefs/remotes/origin/main\t\(Self.parent)\t \t\n")
        source.gitAnswers["log -n 200 --skip=0 \(Self.format) --date=unix \(Self.hash)"] =
            ok(Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000))
        // The Changes tab selects its first change when it opens.
        source.gitAnswers["diff --cached -U3 -- CHANGELOG.md"] = ok(Self.diff("CHANGELOG.md"))
        // Above the repository git finds none.
        source.gitAnswers["/Users/ivan rev-parse --show-toplevel"] =
            GitOutput(status: 128, output: "fatal: not a git repository (or any of the parent directories): .git\n", truncated: false)
    }

    private func fixture(_ source: FakeFilesSource, directory: String?, visible: Bool = true,
                         preferences: @escaping @MainActor () -> FilesLoader.Preferences = { .init() },
                         resolve: (@MainActor (UUID, Date?) -> FilesAvailability)? = nil) -> Fixture {
        let coordinator = FilesCoordinator { nil }
        let tab = Tab(directory), sleeper = Sleeper(), delay = Sleeper(), clock = Clock()
        let session = coordinator.session(for: System.uuid())
        session.visible = visible
        session.presented = true
        coordinator.loader.environment = FilesLoader.Environment(
            resolve: resolve ?? { _, _ in .available(source) },
            directory: { _ in tab.directory },
            track: { _ in },
            preferences: preferences,
            sleep: { try await sleeper.sleep($0) },
            now: { clock.now })
        coordinator.git.environment = GitLoader.Environment(sleep: { try await delay.sleep($0) }, now: { clock.now })
        coordinator.observe(session)
        return Fixture(coordinator: coordinator, session: session, tab: tab, sleeper: sleeper, delay: delay, clock: clock)
    }

    private func calls(_ source: FakeFilesSource, _ command: String) -> [String] {
        source.gitCalls.filter { $0.contains(" " + command + " ") || $0.hasSuffix(" " + command) }
    }

    // MARK: Repository

    func testRepositoryResolvesPerFolderAndConnectionAndIsCached() async throws {
        let first = FakeFilesSource.mockupAPI(), again = FakeFilesSource.mockupAPI()
        for source in [first, again] {
            repository(source)
            source.hostLabel = "homelab"
        }
        let current = Current(first)
        let f = fixture(first, directory: api, resolve: { _, _ in .available(current.source) })
        try await TestSupport.eventually { f.session.git == .repository(GitRepository(root: api)) }
        try await f.idle()
        XCTAssertEqual(calls(first, "rev-parse"), [api + " rev-parse --show-toplevel"])
        XCTAssertEqual(f.git.cached(first, api), .repository(GitRepository(root: api)))

        // A folder inside the repository resolves again without the state ever leaving `.repository`.
        let changes = Redraws()
        withObservationTracking { _ = f.session.git } onChange: { changes.mark() }
        f.tab.directory = api + "/src"
        try await TestSupport.eventually { calls(first, "rev-parse").count == 2 }
        try await f.idle()
        f.tab.directory = api
        try await f.idle()
        XCTAssertEqual(calls(first, "rev-parse").count, 2, "Each folder is asked once")
        XCTAssertFalse(changes.marked, "Moving inside the repository never rewrites the git state")

        // Outside any repository: no segments, no status, no marks.
        f.tab.directory = "/Users/ivan"
        try await TestSupport.eventually { f.session.git == GitState.none }
        XCTAssertNil(f.session.status)
        try await f.idle()

        // The same host's new connection is another source: what the old one knew is not reused.
        f.tab.directory = api
        current.source = again
        try await f.tick()
        try await TestSupport.eventually { calls(again, "rev-parse").count == 1 && f.session.git.repository != nil }
        XCTAssertNil(f.git.cached(again, "/Users/ivan"))
    }

    func testANewRepositoryIsFoundAfterAPromptAndAHiddenTabResolvesNothing() async throws {
        let source = FakeFilesSource.mockupAPI()
        let f = fixture(source, directory: api, visible: false)
        try await TestSupport.eventually { f.coordinator.loader.waiting(f.session.id) == .change }
        XCTAssertEqual(source.gitCalls, [], "A tab that never showed files runs no git")
        XCTAssertEqual(f.session.git, .loading)

        f.session.visible = true
        try await TestSupport.eventually { f.session.git == GitState.none }
        try await f.tick()
        XCTAssertEqual(calls(source, "rev-parse").count, 1, "Outside a repository the tick asks nothing")

        // `git init` in the shell: its prompt asks again.
        repository(source)
        f.clock.now += 1
        f.coordinator.shellPromptedNow(f.session.id)
        try await TestSupport.eventually { f.session.git.repository != nil && f.session.status != nil }
    }

    func testUnavailableGitStopsAsking() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.failures["git"] = .unsupported("git is not installed on this Mac")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.git == .unavailable("git is not installed on this Mac") }
        try await f.idle()
        let asked = source.gitCalls.count
        try await f.tick()
        try await f.tick()
        XCTAssertEqual(source.gitCalls.count, asked, "Nothing runs git on a tab whose git is unavailable")
    }

    // MARK: Status and marks

    /// With Settings › Features › Git › Separate Changes tab: the Changes tab is its own and reads only the status.
    func testStatusRefreshesOnTheTickWhileFilesOrChangesShows() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let f = fixture(source, directory: api, preferences: { .init(changesTab: true) })
        try await TestSupport.eventually { f.session.status != nil }
        try await f.idle()
        let status = try XCTUnwrap(f.session.status)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.head, "c28855c")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.changes(in: .staged).map(\.path), ["CHANGELOG.md"])
        XCTAssertEqual(status.changes(in: .unstaged).map { "\($0.path) +\($0.additions ?? -1) -\($0.deletions ?? -1)" },
                       ["src/lib/db.ts +1 -0", "src/routes/billing.ts +8 -5"])
        XCTAssertEqual(status.changes(in: .untracked).map(\.path), ["tests/"])
        XCTAssertEqual(status.additions, 10)
        XCTAssertEqual(status.deletions, 5)
        XCTAssertEqual(calls(source, "status").count, 1)

        try await f.tick()
        XCTAssertEqual(calls(source, "status").count, 2, "The Files tab reads the status every 2 s")
        f.session.tab = .changes
        try await f.tick()
        XCTAssertEqual(calls(source, "status").count, 3, "So does the Changes tab")

        // Commits reads it on entry and on the tick: its uncommitted row and the branch's ahead and behind show it.
        f.session.tab = .commits
        try await TestSupport.eventually { calls(source, "status").count == 4 }
        try await f.idle()
        XCTAssertEqual(calls(source, "status").count, 4)
        try await f.tick()
        XCTAssertEqual(calls(source, "status").count, 5, "Commits reads the status on the tick too")
        let before = calls(source, "status").count
        f.session.tab = .files
        try await TestSupport.eventually { calls(source, "status").count == before + 1 }
        try await f.idle()

        f.session.visible = false
        try await TestSupport.eventually { f.coordinator.loader.waiting(f.session.id) == .change }
        f.coordinator.shellPromptedNow(f.session.id)
        f.coordinator.refreshNow(f.session.id)
        try await f.idle()
        XCTAssertEqual(calls(source, "status").count, before + 1, "Hidden, nothing runs")

        f.session.visible = true
        try await TestSupport.eventually { calls(source, "status").count == before + 2 }
        try await f.idle()
        f.clock.now += 1
        f.coordinator.shellPromptedNow(f.session.id)
        try await TestSupport.eventually { calls(source, "status").count == before + 3 }
    }

    /// By default the changes are Commits' uncommitted row: selecting it is entering Commits (the status and the log are
    /// read at once), and moving between its rows reads nothing new.
    func testTheUncommittedRowReadsWhatCommitsReads() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        try await f.idle()
        XCTAssertFalse(f.session.changesTab)
        XCTAssertEqual(calls(source, "status").count, 1)
        XCTAssertTrue(calls(source, "log").isEmpty, "Files reads no log")

        f.session.tab = .changes
        try await TestSupport.eventually { calls(source, "status").count == 2 && f.session.log != nil }
        try await f.idle()
        XCTAssertEqual(calls(source, "status").count, 2)
        let logs = calls(source, "log").count
        XCTAssertGreaterThan(logs, 0, "the uncommitted row shows above the log")

        f.session.tab = .commits
        try await f.idle()
        XCTAssertEqual(calls(source, "status").count, 2, "a commit row reads nothing new")
        XCTAssertEqual(calls(source, "log").count, logs)
        f.session.tab = .changes
        try await f.idle()
        XCTAssertEqual(calls(source, "status").count, 2, "nor does the uncommitted row again")
        try await f.tick()
        XCTAssertEqual(calls(source, "status").count, 3, "the tick reads the status")
    }

    func testStatusChangesLeaveTheFilesListingsAlone() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let f = fixture(source, directory: api)
        f.session.expanded = [api + "/src", api + "/src/routes"]
        try await TestSupport.eventually { f.session.status != nil && f.session.listings[api + "/src/routes"]?.listing != nil }
        try await f.idle()
        let listings = f.session.listings.mapValues(\.listing)
        let redraws = Redraws()
        withObservationTracking { _ = f.session.listings } onChange: { redraws.mark() }

        // billing.ts is committed: the Changes tab hears of it, the Files tab shows nothing of git.
        source.gitAnswers[Self.status] =
            ok(Self.porcelain.replacingOccurrences(of: "1 .M N... 100644 100644 100644 ddddddd ddddddd src/routes/billing.ts\0", with: ""))
        try await f.tick()
        XCTAssertFalse(f.session.status?.changes.contains { $0.path == "src/routes/billing.ts" } ?? true)
        XCTAssertFalse(redraws.marked, "a new status rewrites no listing")
        XCTAssertEqual(f.session.listings.mapValues(\.listing), listings)
    }

    func testUnchangedStatusIsNotRewritten() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil && f.session.listings[api]?.listing != nil }
        try await f.idle()
        let loadedAt = f.session.status?.loadedAt
        let redraws = Redraws()
        withObservationTracking {
            _ = f.session.status
            _ = f.session.listings
            _ = f.session.git
        } onChange: { redraws.mark() }
        try await f.tick()
        try await f.tick()
        XCTAssertEqual(calls(source, "status").count, 3)
        XCTAssertFalse(redraws.marked, "An identical status and the listings are left alone")
        XCTAssertEqual(f.session.status?.loadedAt, loadedAt)
    }

    func testUntrackedFilesCountTheirLines() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.file(api + "/notes.md", "one\ntwo\nthree\n")
        source.gitAnswers[Self.status] = ok(Self.porcelain + "? notes.md\0")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status?.changes.contains { $0.path == "notes.md" } == true }
        try await f.idle()
        let notes = try XCTUnwrap(f.session.status?.changes.first { $0.path == "notes.md" })
        XCTAssertEqual(notes.additions, 3)
        XCTAssertEqual(notes.deletions, 0)
        try await f.tick()
        XCTAssertEqual(source.calls.filter { $0 == "read " + api + "/notes.md" }.count, 1, "An unchanged file is counted once")

        source.file(api + "/notes.md", "one\ntwo\nthree\nfour\n", modified: Date(timeIntervalSince1970: 1_760_800_000))
        try await f.tick()
        try await f.tick()
        XCTAssertEqual(f.session.status?.changes.first { $0.path == "notes.md" }?.additions, 4,
                       "Its listing shows it changed: counted again")
    }

    // MARK: Log

    func testLogLoadsByPageWithRefsAndMergesTheFilter() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let format = Self.format
        let page = (0..<200).map { index in
            Self.record(String(format: "%040x", 1_000 + index), parents: [String(format: "%040x", 1_001 + index)],
                        subject: "Commit \(index)", at: 1_760_000_000 - index * 60,
                        refs: index == 0 ? "HEAD -> main" : index == 1 ? "origin/main" : "")
        }.joined()
        let tip = String(format: "%040x", 1_000)
        source.gitAnswers["rev-parse --verify HEAD"] = ok(tip + "\n")
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix \(tip)"] = ok(page)
        source.gitAnswers["log -n 200 --skip=200 \(format) --date=unix \(tip)"] =
            ok(Self.record(String(format: "%040x", 1_200), parents: [], subject: "Initial billing route", at: 1_759_000_000))
        source.gitAnswers[Self.refs] =
            ok("refs/heads/main\t\(tip)\t*\t\nrefs/remotes/origin/main\t\(String(format: "%040x", 1_001))\t \t\n")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.git.repository != nil }
        XCTAssertNil(f.session.log, "The log waits for the Commits tab")
        f.session.tab = .commits
        try await TestSupport.eventually { f.session.log?.commits.count == 200 }
        try await f.idle()
        let log = try XCTUnwrap(f.session.log)
        XCTAssertFalse(log.exhausted)
        XCTAssertEqual(log.scope, .branch)
        XCTAssertEqual(log.commits[0].refs, [GitRef(name: "main", kind: .branch, current: true)])
        XCTAssertEqual(log.commits[1].refs, [GitRef(name: "origin/main", kind: .remote, current: false)], "for-each-ref says it is remote")

        // The view asks for more near the end.
        f.session.logWanted = 400
        try await TestSupport.eventually { f.session.log?.exhausted == true }
        XCTAssertEqual(f.session.log?.commits.count, 201)
        XCTAssertEqual(f.session.log?.commits.last?.subject, "Initial billing route")

        // The refs did not move: the tick reads them and nothing else, and the log is not rewritten.
        try await f.idle()
        let logs = calls(source, "log").count
        let redraws = Redraws()
        withObservationTracking { _ = f.session.log } onChange: { redraws.mark() }
        try await f.tick()
        XCTAssertEqual(calls(source, "log").count, logs)
        XCTAssertEqual(calls(source, "for-each-ref").count, 2)
        XCTAssertFalse(redraws.marked)

        // A filter runs against messages and authors and merges them by hash, newest first.
        let first = Self.record(String(format: "%040x", 1_000), parents: [], subject: "Commit 0", at: 1_760_000_000)
        let third = Self.record(String(format: "%040x", 1_002), parents: [], subject: "Commit 2", at: 1_759_999_880)
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix --all --grep=sam --regexp-ignore-case --fixed-strings"] = ok(third)
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix --all --author=sam --regexp-ignore-case --fixed-strings"] = ok(first + third)
        f.session.logScope = .all
        f.session.logFilter = "sam"
        try await TestSupport.eventually { f.session.log?.filter == "sam" }
        XCTAssertEqual(f.session.log?.commits.map(\.subject), ["Commit 0", "Commit 2"])
        XCTAssertEqual(f.session.log?.scope, .all)
        XCTAssertEqual(f.session.log?.exhausted, true)
    }

    /// Coming to Commits, the log's reads go ahead of the status read the tab also wants: the helper runs a host's git
    /// two at a time, and a status of a large tree would hold the log back for seconds.
    func testCommitsReadsTheLogBeforeTheStatus() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        try await f.idle()
        let before = source.gitCalls.count
        f.session.tab = .commits
        try await TestSupport.eventually { f.session.log != nil }
        try await f.idle()
        let after = Array(source.gitCalls[before...])
        let log = try XCTUnwrap(after.firstIndex { $0.contains(" log -n ") }, "\(after)")
        let status = try XCTUnwrap(after.firstIndex { $0.contains(" status ") }, "the status follows: \(after)")
        XCTAssertLessThan(log, status, "\(after)")
        XCTAssertLessThan(after.firstIndex { $0.contains(" for-each-ref ") } ?? .max, log)
    }

    /// The log marks signed commits from their raw headers; selecting one checks it once, with the verdict kept by hash.
    func testSignedCommitsAreMarkedAndTheSelectedOneChecked() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.gitAnswers["log -n 200 --skip=0 --pretty=raw \(Self.hash)"] = ok(
            "commit \(Self.hash)\ntree 1111111111111111111111111111111111111111\nparent \(Self.parent)\n"
            + "gpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEz\n -----END PGP SIGNATURE-----\n\n    Make webhook retries idempotent\n")
        source.gitAnswers["show --numstat -z \(Self.format) \(Self.hash)"] = ok(
            Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000)
                .dropLast() + "\0\n1\t0\tCHANGELOG.md\0")
        source.gitAnswers["show --name-status -z \(Self.format) \(Self.hash)"] = ok(
            Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000)
                .dropLast() + "\0\nM\0CHANGELOG.md\0")
        source.gitAnswers["show --format= -U3 \(Self.hash) -- CHANGELOG.md"] = ok(Self.diff("CHANGELOG.md"))
        source.gitAnswers["verify-commit --raw \(Self.hash)"] = ok(
            "[GNUPG:] GOODSIG 0123456789ABCDEF Sam Example <sam@example.com>\n[GNUPG:] TRUST_ULTIMATE 0 pgp\n")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        f.session.tab = .commits
        try await TestSupport.eventually { f.session.log != nil }
        XCTAssertEqual(f.session.log?.commits.first?.signature, .gpg)
        XCTAssertTrue(calls(source, "verify-commit").isEmpty, "nothing is checked until a commit is selected")
        f.session.selectedCommit = Self.hash
        try await TestSupport.eventually { f.session.signatureChecks[Self.hash] != nil }
        XCTAssertEqual(f.session.signatureChecks[Self.hash]?.verdict, .good(certified: true))
        try await f.idle()
        try await f.tick()
        XCTAssertEqual(calls(source, "verify-commit").count, 1, "a verdict is kept, not asked again")
    }

    /// Settings › Features › Git off: the git tabs and marks go and nothing more is asked of git until it is on again.
    @MainActor final class Switch { var on = true }

    func testGitTurnedOffAsksNothingAndLeavesFilesOnly() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let git = Switch()
        let f = fixture(source, directory: api, preferences: { FilesLoader.Preferences(git: git.on) })
        try await TestSupport.eventually { f.session.status != nil }
        f.session.tab = .commits
        try await TestSupport.eventually { f.session.log != nil }
        try await f.idle()

        git.on = false
        try await f.tick()
        XCTAssertEqual(f.session.git, .off)
        XCTAssertEqual(f.session.tab, .files, "the git tabs go with git")
        XCTAssertFalse(f.session.showsGitTabs)
        XCTAssertNil(f.session.status)
        XCTAssertNil(f.session.log)
        let asked = source.gitCalls.count
        try await f.tick()
        XCTAssertEqual(source.gitCalls.count, asked, "nothing is asked while git is off")

        git.on = true
        try await f.tick()
        try await TestSupport.eventually { f.session.git == .repository(GitRepository(root: api)) && f.session.status != nil }
    }

    // MARK: Selections

    func testSelectionsLoadTheirDiffsAndDetail() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.gitAnswers["diff -U3 -- src/routes/billing.ts"] = ok(GitParsersTests.Recorded.unstagedDiff)
        source.gitAnswers["show --numstat -z \(Self.format) \(Self.hash)"] = ok(
            Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000,
                        refs: "HEAD -> main").dropLast() + "\0\n8\t5\tsrc/routes/billing.ts\01\t0\tCHANGELOG.md\0")
        source.gitAnswers["show --name-status -z \(Self.format) \(Self.hash)"] = ok(
            Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000,
                        refs: "HEAD -> main").dropLast() + "\0\nM\0src/routes/billing.ts\0A\0CHANGELOG.md\0")
        source.gitAnswers["show --format= -U3 \(Self.hash) -- src/routes/billing.ts"] = ok(GitParsersTests.Recorded.unstagedDiff)
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        f.session.tab = .changes
        f.session.changesSelection = "unstaged:src/routes/billing.ts"
        try await TestSupport.eventually { f.session.changesDiff?.diff != nil }
        XCTAssertEqual(f.session.changesDiff?.key, "unstaged:src/routes/billing.ts")
        XCTAssertEqual(f.session.changesDiff?.diff?.path, "src/routes/billing.ts")
        XCTAssertFalse(f.session.changesDiff?.loading ?? true)
        try await f.idle()

        // The same counts on the next tick: the diff is not read again.
        try await f.tick()
        XCTAssertEqual(calls(source, "diff -U3").count, 1)

        // A selection the status does not list falls to the first change, as the list shows it.
        f.session.changesSelection = "staged:gone.ts"
        try await TestSupport.eventually {
            f.session.changesSelection == "staged:CHANGELOG.md" && f.session.changesDiff?.key == "staged:CHANGELOG.md"
        }

        f.session.tab = .commits
        f.session.selectedCommit = Self.hash
        try await TestSupport.eventually { f.session.commitDetail != nil }
        let detail = try XCTUnwrap(f.session.commitDetail)
        XCTAssertEqual(detail.commit.subject, "Make webhook retries idempotent")
        XCTAssertEqual(detail.files.map(\.path), ["src/routes/billing.ts", "CHANGELOG.md"])
        XCTAssertEqual(detail.files.map(\.kind), [.modified, .added])
        XCTAssertEqual(detail.commit.refs, [GitRef(name: "main", kind: .branch, current: true)])
        f.session.commitFile = "src/routes/billing.ts"
        try await TestSupport.eventually { f.session.commitDiff?.diff != nil }
        XCTAssertEqual(f.session.commitDiff?.key, Self.hash + ":src/routes/billing.ts")

        // Source shows the file as the commit left it: the commit's patch with the whole file as context.
        source.gitAnswers["show --format= -U\(GitChangesText.sourceLimit) \(Self.hash) -- src/routes/billing.ts"] = ok(
            "diff --git a/src/routes/billing.ts b/src/routes/billing.ts\nindex 1111111..2222222 100644\n"
            + "--- a/src/routes/billing.ts\n+++ b/src/routes/billing.ts\n@@ -1,3 +1,3 @@\n import a\n-old()\n+retry()\n done\n")
        let queries = GitQueries(source: source, root: api)
        let commit = detail.commit
        let text = try await queries.commitSource(commit, path: "src/routes/billing.ts", oldPath: nil)
        XCTAssertEqual(text, "import a\nretry()\ndone\n")

        f.session.selectedCommit = nil
        try await TestSupport.eventually { f.session.commitDetail == nil && f.session.commitDiff == nil }
    }

    func testASlowDiffShowsLoadingOnlyAfterTheDelay() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.file(api + "/notes.md", "one\n")
        source.file(api + "/todo.md", "two\n")
        source.gitAnswers[Self.status] = ok(Self.porcelain + "? notes.md\0? todo.md\0")
        let f = fixture(source, directory: api)
        f.session.tab = .changes
        try await TestSupport.eventually { f.session.status?.changes.count == 6 }
        try await f.idle()
        f.session.changesSelection = "untracked:notes.md"
        try await TestSupport.eventually { f.session.changesDiff?.diff?.path == "notes.md" }
        XCTAssertTrue(f.session.changesDiff?.diff?.text.hasSuffix("@@ -0,0 +1 @@\n+one\n") == true)

        source.hangs = ["read " + api + "/todo.md"]
        f.session.changesSelection = "untracked:todo.md"
        try await TestSupport.eventually { f.delay.pending == 1 }
        XCTAssertEqual(f.session.changesDiff?.key, "untracked:notes.md", "The last diff stays while the next one may still answer")
        f.delay.fire()
        try await TestSupport.eventually { f.session.changesDiff == GitDiffState(key: "untracked:todo.md", loading: true) }

        source.hangs = []
        f.session.changesSelection = "untracked:notes.md"
        try await TestSupport.eventually { f.session.changesDiff?.diff?.path == "notes.md" }
        XCTAssertFalse(f.session.changesDiff?.loading ?? true)
    }

    // MARK: Review fixes

    func testUntrackedCountsAreBoundedPerFileAndPerReadAndKeptAcrossPrompts() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        // Twenty files of 250,000 bytes (5 MB, over one read's 4 MiB), one of 300,000 (over the 256 KiB a count reads)
        // and one whose name git printed as U+FFFD.
        let parts = (0..<20).map { String(format: "part-%02d.txt", $0) }
        for part in parts { source.file(api + "/" + part, String(repeating: "x\n", count: 125_000)) }
        source.file(api + "/big.log", String(repeating: "y\n", count: 150_000))
        source.gitAnswers[Self.status] = ok(Self.porcelain + "? big.log\0" + parts.map { "? \($0)\0" }.joined() + "? caf\u{FFFD}.md\0")
        let f = fixture(source, directory: api)
        func change(_ path: String) -> GitChange? { f.session.status?.changes.first { $0.path == path } }
        func counted() -> Int { parts.filter { change($0)?.additions != nil }.count }
        func reads(_ path: String) -> Int { source.calls.filter { $0 == "read " + api + "/" + path }.count }
        try await TestSupport.eventually { f.session.status != nil }
        try await f.idle()
        XCTAssertGreaterThan(counted(), 0)
        XCTAssertLessThan(counted(), 20, "One status read counts at most 4 MiB")
        try await f.tick()
        try await f.tick()
        XCTAssertEqual(counted(), 20, "The files left over are counted on the next reads")
        XCTAssertEqual(change("part-00.txt")?.additions, 125_000)
        XCTAssertNil(change("big.log")?.additions, "Too big to count")
        XCTAssertLessThanOrEqual(reads("big.log"), 1, "Read at most once, before its listing gave its size")
        XCTAssertFalse(source.calls.contains { $0.contains("\u{FFFD}") }, "A name that is not UTF-8 is never read")
        XCTAssertEqual(parts.map(reads), Array(repeating: 1, count: 20), "Each file is read for its count once")

        // A prompt reads the status again, not the files whose stamps did not change.
        f.clock.now += 1
        let statuses = calls(source, "status").count
        f.coordinator.shellPromptedNow(f.session.id)
        try await TestSupport.eventually { calls(source, "status").count > statuses }
        try await f.idle()
        XCTAssertEqual(parts.map(reads), Array(repeating: 1, count: 20))
        XCTAssertEqual(counted(), 20)

        // Selecting the unrepresentable name says so instead of asking git or the disk.
        f.session.tab = .changes
        f.session.changesSelection = "untracked:caf\u{FFFD}.md"
        try await TestSupport.eventually { f.session.changesDiff?.error == GitChange.unrepresentable }
        XCTAssertFalse(source.calls.contains { $0.contains("\u{FFFD}") })
    }

    func testATruncatedStatusSaysSo() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.gitAnswers[Self.status] = ok(String(Self.porcelain.dropLast(8)), truncated: true)
        // A binary that is only stat-dirty: numstat lists it (`-\t-`) though the status does not. No change of its own.
        source.gitAnswers["diff --numstat -z"] = ok("1\t0\tsrc/lib/db.ts\08\t5\tsrc/routes/billing.ts\0-\t-\tlogo.png\0")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        XCTAssertEqual(f.session.status?.truncated, true)
        XCTAssertEqual(f.session.status?.changes.map(\.path), ["CHANGELOG.md", "src/lib/db.ts", "src/routes/billing.ts", "tests/"],
                       "The entries before the cut, and nothing numstat alone lists")
        XCTAssertEqual(f.session.status?.changes.contains { $0.binary }, false)
        let limits = zip(source.gitCalls, source.gitLimits).filter { $0.0.contains(" status ") || $0.0.contains("--numstat") }
        XCTAssertEqual(Set(limits.map(\.1)), [GitQueries.statusLimit])
    }

    func testBinariesShowTheirSizesWithoutASelection() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.file(api + "/logo.png", Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        source.file(api + "/icon.bin", Data([0x89, 0, 1]))
        source.gitAnswers[Self.status] = ok(Self.porcelain + "1 .M N... 100644 100644 100644 eeeeeee eeeeeee logo.png\0? icon.bin\0")
        source.gitAnswers["diff --numstat -z"] = ok("1\t0\tsrc/lib/db.ts\08\t5\tsrc/routes/billing.ts\0-\t-\tlogo.png\0")
        source.gitAnswers["diff --stat -- logo.png"] = ok(GitParsersTests.Recorded.binaryStat)
        let f = fixture(source, directory: api)
        func change(_ id: String) -> GitChange? { f.session.status?.changes.first { $0.id == id } }
        try await TestSupport.eventually { change("unstaged:logo.png")?.newSize != nil && change("untracked:icon.bin")?.binary == true }
        XCTAssertEqual(change("unstaged:logo.png")?.oldSize, 6)
        XCTAssertEqual(change("unstaged:logo.png")?.newSize, 11)
        XCTAssertEqual(change("untracked:icon.bin")?.newSize, 3, "An untracked binary's size is the file's")
        XCTAssertNil(change("untracked:icon.bin")?.oldSize)
        try await f.idle()
        try await f.tick()
        try await f.tick()
        XCTAssertEqual(calls(source, "diff --stat").count, 1, "Asked once while nothing changed")

        // A prompt may follow `git add`: asked again.
        f.clock.now += 1
        f.coordinator.shellPromptedNow(f.session.id)
        try await TestSupport.eventually { calls(source, "diff --stat").count == 2 }
        try await f.idle()
        XCTAssertEqual(change("unstaged:logo.png")?.newSize, 11)
    }

    func testTheLoaderKeepsTheChangesSelectionOnTheSameChange() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        for path in ["src/lib/db.ts", "src/routes/billing.ts"] {
            source.gitAnswers["diff -U3 -- \(path)"] = ok(Self.diff(path))
            source.gitAnswers["diff --cached -U3 -- \(path)"] = ok(Self.diff(path))
        }
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        try await f.idle()
        XCTAssertNil(f.session.changesSelection, "Off the Changes tab nothing is picked")
        f.session.tab = .changes
        try await TestSupport.eventually { f.session.changesSelection == "staged:CHANGELOG.md" }
        f.session.changesSelection = "unstaged:src/lib/db.ts"
        try await TestSupport.eventually { f.session.changesDiff?.key == "unstaged:src/lib/db.ts" }

        // `git add src/lib/db.ts`: the same path, now staged.
        let added = Self.porcelain.replacingOccurrences(of: "1 .M N... 100644 100644 100644 ccccccc ccccccc src/lib/db.ts",
                                                        with: "1 M. N... 100644 100644 100644 ccccccc ccccccc src/lib/db.ts")
        source.gitAnswers[Self.status] = ok(added)
        try await f.tick()
        XCTAssertEqual(f.session.changesSelection, "staged:src/lib/db.ts")
        try await TestSupport.eventually { f.session.changesDiff?.key == "staged:src/lib/db.ts" }

        // Committed: the change now where it was (second in the list) is picked.
        source.gitAnswers[Self.status] = ok(Self.porcelain.replacingOccurrences(
            of: "1 .M N... 100644 100644 100644 ccccccc ccccccc src/lib/db.ts\0", with: ""))
        try await f.tick()
        XCTAssertEqual(f.session.changesSelection, "unstaged:src/routes/billing.ts")

        // Everything committed: nothing to select.
        source.gitAnswers[Self.status] = ok("# branch.oid \(Self.hash)\0# branch.head main\0")
        try await f.tick()
        XCTAssertNil(f.session.changesSelection)
        XCTAssertNil(f.session.changesDiff)
    }

    func testAFailedDetailOrDiffShowsWhyAndIsAskedAgainOnTheTick() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let show = "show --numstat -z \(Self.format) \(Self.hash)", letters = "show --name-status -z \(Self.format) \(Self.hash)"
        let record = Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000)
        let bad = GitOutput(status: 128, output: "fatal: bad object \(Self.hash)\n", truncated: false)
        source.gitAnswers[show] = bad
        source.gitAnswers[letters] = bad
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.git.repository != nil }
        f.session.tab = .commits
        f.session.selectedCommit = Self.hash
        try await TestSupport.eventually { f.session.commitDetailError == "fatal: bad object \(Self.hash)" }
        try await f.idle()
        XCTAssertNil(f.session.commitDetail)
        XCTAssertEqual(calls(source, "show").count, 2, "Not asked again before the tick")

        // The detail pane's "Try again" is ⌘R: it asks again at once.
        source.gitAnswers[show] = ok(record.dropLast() + "\0\n8\t5\tsrc/routes/billing.ts\01\t0\tCHANGELOG.md\0")
        source.gitAnswers[letters] = ok(record.dropLast() + "\0\nM\0src/routes/billing.ts\0A\0CHANGELOG.md\0")
        f.coordinator.refreshNow(f.session.id)
        try await TestSupport.eventually { f.session.commitDetail != nil }
        XCTAssertNil(f.session.commitDetailError)

        // A cancelled file diff is read again on the next pass; a failed one shows its error until the tick reads it.
        let billing = "show --format= -U3 \(Self.hash) -- src/routes/billing.ts"
        source.gitAnswers[billing] = ok(Self.diff("src/routes/billing.ts"))
        source.fail("git", with: [.cancelled])
        f.session.commitFile = "src/routes/billing.ts"
        try await TestSupport.eventually { calls(source, "show --format=").count == 1 }
        try await f.idle()
        try await f.tick()
        try await TestSupport.eventually { f.session.commitDiff?.diff?.path == "src/routes/billing.ts" }

        let changelog = "show --format= -U3 \(Self.hash) -- CHANGELOG.md"
        let unreadable = GitOutput(status: 128, output: "fatal: unable to read 1111111\n", truncated: false)
        source.gitAnswers[changelog] = unreadable
        f.session.commitFile = "CHANGELOG.md"
        try await TestSupport.eventually { f.session.commitDiff == GitDiffState(key: Self.hash + ":CHANGELOG.md", error: "fatal: unable to read 1111111") }
        try await f.idle()
        source.gitAnswers[changelog] = ok(Self.diff("CHANGELOG.md"))
        try await f.tick()
        try await TestSupport.eventually { f.session.commitDiff?.diff?.path == "CHANGELOG.md" }
        XCTAssertNil(f.session.commitDiff?.error)

        // ⌘R asks again for a failed file diff too.
        source.gitAnswers[billing] = unreadable
        f.session.commitFile = "src/routes/billing.ts"
        try await TestSupport.eventually { f.session.commitDiff?.error == "fatal: unable to read 1111111" }
        try await f.idle()
        source.gitAnswers[billing] = ok(Self.diff("src/routes/billing.ts"))
        f.coordinator.refreshNow(f.session.id)
        try await TestSupport.eventually { f.session.commitDiff?.diff?.path == "src/routes/billing.ts" }

        // Another commit's error is not the next one's.
        source.gitAnswers[show] = bad
        f.session.commitFile = nil
        f.session.selectedCommit = nil
        try await TestSupport.eventually { f.session.commitDetail == nil }
        f.session.selectedCommit = Self.hash
        try await TestSupport.eventually { f.session.commitDetailError != nil }
        let root = Self.record(Self.parent, parents: [], subject: "Initial billing route", at: 1_759_000_000).dropLast()
        source.gitAnswers["show --numstat -z \(Self.format) \(Self.parent)"] = ok(root + "\0\n1\t0\tCHANGELOG.md\0")
        source.gitAnswers["show --name-status -z \(Self.format) \(Self.parent)"] = ok(root + "\0\nA\0CHANGELOG.md\0")
        f.session.selectedCommit = Self.parent
        try await TestSupport.eventually { f.session.commitDetail?.commit.hash == Self.parent }
        XCTAssertNil(f.session.commitDetailError)
    }

    func testTheLogStartsOverWhenADetachedHeadMoves() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        // Detached: no branch is checked out, so the refs say nothing when HEAD moves.
        source.gitAnswers[Self.refs] = ok("refs/heads/main\t\(Self.parent)\t \t\n")
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.git.repository != nil }
        f.session.tab = .commits
        try await TestSupport.eventually { f.session.log?.commits.first?.hash == Self.hash }
        try await f.idle()

        let moved = String(repeating: "e", count: 40)
        source.gitAnswers["rev-parse --verify HEAD"] = ok(moved + "\n")
        source.gitAnswers["log -n 200 --skip=0 \(Self.format) --date=unix \(moved)"] =
            ok(Self.record(moved, parents: [Self.hash], subject: "Try the retry queue", at: 1_760_000_600)
                + Self.record(Self.hash, parents: [Self.parent], subject: "Make webhook retries idempotent", at: 1_760_000_000))
        try await f.tick()
        try await TestSupport.eventually { f.session.log?.commits.map(\.hash) == [moved, Self.hash] }
    }

    func testATransientFailureLeavesANeverResolvedTabWaiting() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        source.fail("git", with: [.busy("The helper is busy")])
        let f = fixture(source, directory: api)
        f.session.tab = .changes
        try await TestSupport.eventually { calls(source, "rev-parse").count == 1 }
        try await f.idle()
        XCTAssertEqual(f.session.git, .loading, "No answer yet: ⇧⌘U's tab keeps waiting")
        XCTAssertEqual(f.session.tab, .changes)
        try await f.tick()
        try await TestSupport.eventually { f.session.git.repository != nil }
        XCTAssertEqual(f.session.tab, .changes)
    }

    func testGitResolvingWhileTheRootMovesToAFolderNotYetResolved() async throws {
        let source = FakeFilesSource.mockupAPI()
        repository(source)
        let f = fixture(source, directory: api)
        try await TestSupport.eventually { f.session.status != nil }
        try await f.idle()
        XCTAssertFalse(f.session.gitResolving)

        source.hangs = ["git " + api + "/src"]
        f.tab.directory = api + "/src"
        try await TestSupport.eventually { f.session.gitResolving }
        XCTAssertEqual(f.session.git, .repository(GitRepository(root: api)), "It may be the same repository: what shows stays")
        XCTAssertNotNil(f.session.status)
        f.tab.directory = api
        try await TestSupport.eventually { !f.session.gitResolving }

        source.hangs = []
        f.tab.directory = api + "/src"
        try await TestSupport.eventually { calls(source, "rev-parse --show-toplevel").count == 3 }
        try await f.idle()
        XCTAssertFalse(f.session.gitResolving)
        XCTAssertEqual(f.session.git, .repository(GitRepository(root: api)))

        // A prompt asks about the same folder again: nothing shown is stale, so no spinner.
        let redraws = Redraws()
        withObservationTracking { _ = f.session.gitResolving } onChange: { redraws.mark() }
        f.clock.now += 1
        f.coordinator.shellPromptedNow(f.session.id)
        try await TestSupport.eventually { calls(source, "rev-parse --show-toplevel").count == 4 }
        try await f.idle()
        XCTAssertFalse(redraws.marked)
    }
}
