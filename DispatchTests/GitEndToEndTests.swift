import Foundation
import XCTest
@testable import DispatchApp

/// The git data layer against this Mac's helper (`files.git`) on a repository made with the real git in a temporary
/// folder: the argument lists pass the helper's allowlist, and what git prints there parses into the models. A helper
/// without `files.git` answers `unsupported`; these cases check that mapping and stop, so they need no change once it
/// does.
final class GitEndToEndTests: XCTestCase {
    private var session: HelperSession!
    private var root: URL!
    private var source: HelperFilesSource!

    override func setUp() async throws {
        root = URL(fileURLWithPath: try XCTUnwrap(System.environment("TMPDIR")))
            .appendingPathComponent("g" + System.uuid().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        // The helper's git reads the home's ~/.gitconfig (and the system's): an empty home of its own, so the
        // developer's settings (log.decorate, diff.renames, status.showUntrackedFiles…) cannot change what git prints.
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        let process = Process()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["--stdio"]
        process.environment = System.inherited.merging(["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"]) { _, new in new }
        process.standardError = FileHandle.nullDevice
        session = try await HelperSession(process: process)
        // Closed in a teardown block, not tearDown(): those run first, so the helper ends inside the case's app
        // journal (TestSupport's block finishes it), as a `defer { session.close() }` would.
        addTeardownBlock { [session] in session?.close() }
        source = HelperFilesSource(endpoint: .local, connection: session.connection, home: root.path, hostLabel: nil)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: A repository made with git

    private var repo: URL { root.appendingPathComponent("api") }

    @discardableResult
    private func git(_ args: String..., date: Int = 1_760_000_000) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Ivan", "-c", "user.email=ivan@example.com", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-C", repo.path] + args
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                               "GIT_AUTHOR_DATE": "\(date) +0000", "GIT_COMMITTER_DATE": "\(date) +0000"]
        process.standardError = FileHandle.nullDevice
        let exit = try TestSupport.live(process)
        XCTAssertEqual(exit.status, 0, "git " + args.joined(separator: " "))
        return String(decoding: exit.output, as: UTF8.self)
    }

    private func write(_ path: String, _ text: String) throws { try write(path, Data(text.utf8)) }

    private func write(_ path: String, _ data: Data) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written live, as the folders are: git runs live in replay too (TestSupport.live) and commits these files.
        try data.write(to: url, options: .atomic)
    }

    /// Two commits (a tag, a second branch), then a staged change, an unstaged one, a staged rename, a binary change, an
    /// untracked file, an untracked folder and an ignored folder.
    private func makeRepository() throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
        try git("init", "-q")
        try write(".gitignore", "node_modules\n")
        try write("src/routes/billing.ts", "a\nb\nc\n")
        try write("src/lib/db.ts", "x\n")
        try write("old.txt", "old\n")
        try write("logo.png", Data([0, 1, 2, 3, 4, 5]))
        try git("add", "-A")
        try git("commit", "-q", "-m", "Initial billing route")
        try write("src/routes/billing.ts", "a\nb\nc\nd\n")
        try git("commit", "-q", "-a", "-m", "Keep the retry queue bounded", "-m", "Bounded at a hundred.", date: 1_760_003_600)
        try git("tag", "v1")
        try git("tag", "-a", "v2", "-m", "Release two")
        try git("branch", "feat/webhook")
        try write("src/routes/billing.ts", "a\nB\nc\nd\n")
        try git("add", "src/routes/billing.ts")
        try write("src/lib/db.ts", "x\ny\n")
        try git("mv", "old.txt", "new.txt")
        try write("logo.png", Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        try write("notes.md", "one\ntwo\n")
        try write("tests/idempotency.test.ts", "test()\n")
        try write("node_modules/left-pad/index.js", "module.exports = 1\n")
    }

    /// A commit on each of two branches off a first one: `feat/webhook` adds a file, deletes one and changes one;
    /// `main` changes billing.ts again. Then on main a staged change, an unstaged one, a staged rename, a binary
    /// change, an untracked file and an ignored folder.
    private func makeBranchedRepository() throws {
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
        try git("init", "-q")
        try write(".gitignore", "node_modules\n")
        try write("src/routes/billing.ts", "a\nb\nc\n")
        try write("src/lib/db.ts", "x\n")
        try write("old.txt", "old\n")
        try write("CHANGELOG.md", "# Changelog\n")
        try write("logo.png", Data([0, 1, 2, 3, 4, 5]))
        try git("add", "-A")
        try git("commit", "-q", "-m", "Initial billing route")
        try git("checkout", "-q", "-b", "feat/webhook")
        try write("src/routes/webhook.ts", "export const verify = true\n")
        try git("rm", "-q", "CHANGELOG.md")
        try write("src/routes/billing.ts", "a\nb\nc\nverify\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "Verify webhook signatures", date: 1_760_001_800)
        try git("checkout", "-q", "main")
        try write("src/routes/billing.ts", "a\nb\nc\nd\n")
        try git("commit", "-q", "-a", "-m", "Keep the retry queue bounded", date: 1_760_003_600)
        try write("src/routes/billing.ts", "a\nB\nc\nd\n")
        try git("add", "src/routes/billing.ts")
        try write("src/lib/db.ts", "x\ny\n")
        try git("mv", "old.txt", "new.txt")
        try write("logo.png", Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        try write("notes.md", "one\ntwo\n")
        try write("node_modules/left-pad/index.js", "module.exports = 1\n")
    }

    /// The query's answer, or nil after checking that the helper does not run git yet.
    private func once<T>(file: StaticString = #filePath, line: UInt = #line, _ body: () async throws(GitError) -> T) async throws -> T? {
        do throws(GitError) {
            return try await body()
        } catch .unavailable(let message) {
            XCTAssertEqual(message, "This Mac’s helper can’t do this yet", file: file, line: line)
            return nil
        }
    }

    // MARK: Cases

    func testQueriesReadARealRepository() async throws {
        try makeRepository()
        let folder = repo.appendingPathComponent("src").path
        guard let found = try await once({ () async throws(GitError) -> GitRepository? in
            try await GitQueries.repository(of: folder, source: source)
        }) else { return }
        // git answers /private/var/…; the root keeps the spelling of the folder shown.
        let repository = try XCTUnwrap(found)
        XCTAssertEqual(repository.root, repo.path)
        let queries = GitQueries(source: source, root: repository.root)

        let status = try await queries.status()
        XCTAssertEqual(status.branch, "main")
        XCTAssertNotNil(status.head)
        XCTAssertEqual(Set(status.changes.map { "\($0.area.rawValue) \($0.kind.rawValue) \($0.path)" }), [
            "staged M src/routes/billing.ts", "staged R new.txt", "unstaged M src/lib/db.ts", "unstaged M logo.png",
            "untracked U notes.md", "untracked U tests/",
        ])
        XCTAssertEqual(status.changes.first { $0.path == "new.txt" }?.oldPath, "old.txt")
        XCTAssertEqual(status.ignored, ["node_modules/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git/index.lock").path))

        let unstaged = try await queries.numstat(cached: false), staged = try await queries.numstat(cached: true)
        XCTAssertEqual(unstaged.first { $0.path == "src/lib/db.ts" }, GitNumstat(path: "src/lib/db.ts", additions: 1, deletions: 0))
        XCTAssertTrue(unstaged.first { $0.path == "logo.png" }?.binary == true)
        XCTAssertEqual(staged.first { $0.path == "new.txt" }?.oldPath, "old.txt")
        XCTAssertEqual(staged.first { $0.path == "src/routes/billing.ts" }, GitNumstat(path: "src/routes/billing.ts", additions: 1, deletions: 1))

        let billing = try await queries.diff(GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged))
        XCTAssertTrue(billing.text.contains("\n-b\n+B\n"), billing.text)
        let renamed = try await queries.diff(GitChange(path: "new.txt", oldPath: "old.txt", kind: .renamed, area: .staged))
        XCTAssertEqual(renamed.oldPath, "old.txt")
        XCTAssertTrue(renamed.text.contains("rename to new.txt"))
        let binary = try await queries.diff(GitChange(path: "logo.png", kind: .modified, area: .unstaged))
        XCTAssertTrue(binary.binary)
        XCTAssertEqual(binary.oldSize, 6)
        XCTAssertEqual(binary.newSize, 11)
        let notes = try await queries.diff(GitChange(path: "notes.md", kind: .untracked, area: .untracked))
        XCTAssertTrue(notes.text.hasSuffix("@@ -0,0 +1,2 @@\n+one\n+two\n"), notes.text)

        let log = try await queries.log(scope: .all, skip: 0, count: 200)
        XCTAssertTrue(log.exhausted)
        XCTAssertEqual(log.commits.map(\.subject), ["Keep the retry queue bounded", "Initial billing route"])
        XCTAssertEqual(log.commits[0].body, "Bounded at a hundred.")
        XCTAssertEqual(log.commits[0].date, Date(timeIntervalSince1970: 1_760_003_600))
        let refs = try await queries.refs()
        let merged = GitRefs.merge(log.commits, refs: refs)
        XCTAssertEqual(Set(merged[0].refs.map(\.name)), ["main", "feat/webhook", "v1", "v2"])
        XCTAssertEqual(merged[0].refs.first { $0.current }?.name, "main")
        XCTAssertEqual(refs.first { $0.refname == "refs/tags/v2" }?.hash, log.commits[0].hash,
                       "The annotated tag peels to its commit")
        let head = try await queries.head()
        XCTAssertEqual(head, log.commits[0].hash)
        let pinned = try await queries.log(scope: .branch, skip: 1, count: 200, from: log.commits[0].hash)
        XCTAssertEqual(pinned.commits.map(\.subject), ["Initial billing route"], "Paged from a pinned commit")
        let filtered = try await queries.log(scope: .branch, match: .message("RETRY"), skip: 0, count: 200)
        XCTAssertEqual(filtered.commits.map(\.subject), ["Keep the retry queue bounded"], "Literal, ignoring case")
        let second = try await queries.log(scope: .branch, skip: 1, count: 1)
        XCTAssertEqual(second.commits.map(\.subject), ["Initial billing route"])

        // A link to the repository named otherwise: its root is the link, so the Files list's paths match.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        let linked = try await GitQueries.repository(of: link.path, source: source)
        XCTAssertEqual(linked?.root, link.path)
        let linkedSource = try await GitQueries.repository(of: link.appendingPathComponent("src").path, source: source)
        XCTAssertEqual(linkedSource?.root, link.path)

        let detail = try await queries.commit(log.commits[0].hash)
        XCTAssertEqual(detail.files, [GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged, additions: 1, deletions: 0)])
        let change = try await queries.commitDiff(detail.commit, path: "src/routes/billing.ts", oldPath: nil)
        XCTAssertTrue(change.text.contains("\n+d\n"), change.text)
        let added = try await queries.commitDiff(log.commits[1], path: "logo.png", oldPath: nil)
        XCTAssertTrue(added.binary)
        XCTAssertEqual(added.newSize, 6)
    }

    func testOutsideARepositoryAndRefusedCommands() async throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        guard let found = try await once({ () async throws(GitError) -> GitRepository? in
            try await GitQueries.repository(of: plain.path, source: source)
        }) else { return }
        if let found {
            XCTAssertFalse(FilesLoader.path(found.root, isInside: root.path), "Only a repository around the temporary folder")
        }
        do {
            _ = try await GitQueries(source: source, root: plain.path).run(["push"])
            XCTFail("The helper ran git push")
        } catch {
            guard case .source(.other(let code, _)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "invalid_request")
        }
    }

    /// The loader end to end: the repository, the status with its counts, the marks on the listing and the log.
    @MainActor
    func testTheLoaderShowsTheRepositoryItsMarksAndLog() async throws {
        try makeRepository()
        let coordinator = FilesCoordinator { nil }
        let session = coordinator.session(for: System.uuid())
        session.visible = true
        session.presented = true
        let source = try XCTUnwrap(self.source), path = repo.path
        coordinator.loader.environment = FilesLoader.Environment(
            resolve: { _, _ in .available(source) }, directory: { _ in path }, track: { _ in }, preferences: { .init() },
            sleep: { try await System.sleep(for: $0, "files.refresh") }, now: { System.date() })
        coordinator.observe(session)
        defer { coordinator.forget(session.id) }
        try await TestSupport.eventually(timeout: .seconds(20)) { session.git != .loading }
        if case .unavailable(let message) = session.git {
            XCTAssertEqual(message, "This Mac’s helper can’t do this yet")
            return
        }
        XCTAssertEqual(session.git, .repository(GitRepository(root: path)))
        try await TestSupport.eventually(timeout: .seconds(20)) {
            session.listings[path]?.entries.contains { $0.name == "notes.md" && $0.mark == "U" } == true
        }
        let marks = Dictionary(uniqueKeysWithValues: (session.listings[path]?.entries ?? []).compactMap { entry in
            entry.mark.map { (entry.name, $0) }
        })
        XCTAssertEqual(marks, ["logo.png": "M", "new.txt": "R", "node_modules": "!", "notes.md": "U", "tests": "U"])
        let status = try XCTUnwrap(session.status)
        XCTAssertEqual(status.changes.first { $0.path == "notes.md" }?.additions, 2, "Untracked lines count as additions")
        XCTAssertEqual(status.changes.first { $0.area == .staged && $0.path == "src/routes/billing.ts" }?.additions, 1)

        session.tab = .commits
        try await TestSupport.eventually(timeout: .seconds(20)) { session.log?.commits.count == 2 }
        XCTAssertEqual(session.log?.exhausted, true)
        session.selectedCommit = session.log?.commits.first?.hash
        try await TestSupport.eventually(timeout: .seconds(20)) { session.commitDetail != nil }
        XCTAssertEqual(session.commitDetail?.files.map(\.path), ["src/routes/billing.ts"])
    }

    /// The three tabs end to end on this Mac's helper: a visible, presented session's loader fills the Files listing's
    /// marks, the Changes tab's status, counts and diffs, and the Commits tab's log, refs, a commit's files with their
    /// letters and a file's diff, as the tab switches.
    @MainActor
    func testTheThreeTabsShowARealRepository() async throws {
        try makeBranchedRepository()
        let coordinator = FilesCoordinator { nil }
        let session = coordinator.session(for: System.uuid())
        session.visible = true
        session.presented = true
        let source = try XCTUnwrap(self.source), path = repo.path
        coordinator.loader.environment = FilesLoader.Environment(
            resolve: { _, _ in .available(source) }, directory: { _ in path }, track: { _ in }, preferences: { .init() },
            sleep: { try await System.sleep(for: $0, "files.refresh") }, now: { System.date() })
        coordinator.observe(session)
        defer { coordinator.forget(session.id) }

        // Files: the repository resolved, the segments shown, the marks on the listing.
        XCTAssertEqual(session.tab, .files)
        try await TestSupport.eventually(timeout: .seconds(20)) { session.git != .loading }
        XCTAssertEqual(session.git, .repository(GitRepository(root: path)))
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "marks \(self.marks(session, path))") {
            self.marks(session, path) == ["logo.png": "M", "new.txt": "R", "node_modules": "!", "notes.md": "U"]
        }
        XCTAssertEqual(FilesHeader.segments(for: session).map(\.id), [.files, .changes, .commits])
        try await TestSupport.eventually(timeout: .seconds(20)) { session.changedCount == 5 }
        XCTAssertEqual(FilesHeader.segments(for: session)[1].count, 5)

        // Changes: the status with every file's counts, then a text diff and a binary one.
        session.select(.changes)
        XCTAssertEqual(session.tab, .changes)
        let status = try XCTUnwrap(session.status)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(Set(status.changes.map { "\($0.area.rawValue) \($0.kind.rawValue) \($0.path)" }), [
            "staged M src/routes/billing.ts", "staged R new.txt", "unstaged M src/lib/db.ts", "unstaged M logo.png",
            "untracked U notes.md",
        ])
        func change(_ id: String) -> GitChange? { session.status?.changes.first { $0.id == id } }
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "counts \(session.status?.changes ?? [])") {
            change("staged:src/routes/billing.ts")?.additions == 1 && change("unstaged:src/lib/db.ts")?.additions == 1
                && change("untracked:notes.md")?.additions == 2 && change("unstaged:logo.png")?.binary == true
        }
        XCTAssertEqual(change("staged:src/routes/billing.ts")?.deletions, 1)
        try await TestSupport.eventually(timeout: .seconds(20)) { change("unstaged:logo.png")?.newSize != nil }
        XCTAssertEqual(change("unstaged:logo.png")?.oldSize, 6, "A binary's sizes come with the status")
        XCTAssertEqual(change("unstaged:logo.png")?.newSize, 11)
        XCTAssertEqual(change("staged:new.txt")?.oldPath, "old.txt")
        XCTAssertEqual(session.status?.additions, 4)
        XCTAssertEqual(session.status?.deletions, 1)

        session.changesSelection = "staged:src/routes/billing.ts"
        try await TestSupport.eventually(timeout: .seconds(20)) {
            session.changesDiff?.key == "staged:src/routes/billing.ts" && session.changesDiff?.diff != nil
        }
        let staged = try XCTUnwrap(session.changesDiff?.diff)
        XCTAssertEqual(staged.path, "src/routes/billing.ts")
        XCTAssertTrue(staged.text.contains("\n-b\n+B\n"), staged.text)
        session.changesSelection = "unstaged:logo.png"
        try await TestSupport.eventually(timeout: .seconds(20)) {
            session.changesDiff?.key == "unstaged:logo.png" && session.changesDiff?.diff != nil
        }
        let binary = try XCTUnwrap(session.changesDiff?.diff)
        XCTAssertTrue(binary.binary)
        XCTAssertEqual(binary.oldSize, 6)
        XCTAssertEqual(binary.newSize, 11)

        // Commits: this branch's log, then every branch's with the refs on its commits.
        session.select(.commits)
        XCTAssertEqual(session.tab, .commits)
        try await TestSupport.eventually(timeout: .seconds(20)) { session.log?.commits.count == 2 }
        XCTAssertEqual(session.log?.commits.map(\.subject), ["Keep the retry queue bounded", "Initial billing route"])
        session.logScope = .all
        try await TestSupport.eventually(timeout: .seconds(20)) { session.log?.scope == .all && session.log?.commits.count == 3 }
        let log = try XCTUnwrap(session.log)
        XCTAssertTrue(log.exhausted)
        XCTAssertEqual(log.commits.map(\.subject), ["Keep the retry queue bounded", "Verify webhook signatures",
                                                    "Initial billing route"])
        XCTAssertEqual(log.commits[0].refs.filter(\.current).map(\.name), ["main"])
        XCTAssertTrue(log.commits[1].refs.contains(GitRef(name: "feat/webhook", kind: .branch, current: false)),
                      "\(log.commits[1].refs)")
        XCTAssertEqual(log.commits[0].parents, [log.commits[2].hash])
        XCTAssertEqual(log.commits[1].parents, [log.commits[2].hash])

        // The side branch's commit: its files with their letters, and one file's diff.
        let side = log.commits[1]
        session.selectedCommit = side.hash
        try await TestSupport.eventually(timeout: .seconds(20)) { session.commitDetail?.commit.hash == side.hash }
        let detail = try XCTUnwrap(session.commitDetail)
        XCTAssertEqual(detail.files, [
            GitChange(path: "CHANGELOG.md", kind: .deleted, area: .staged, additions: 0, deletions: 1),
            GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged, additions: 1, deletions: 0),
            GitChange(path: "src/routes/webhook.ts", kind: .added, area: .staged, additions: 1, deletions: 0),
        ])
        XCTAssertTrue(detail.commit.refs.contains { $0.name == "feat/webhook" })
        session.commitFile = "src/routes/webhook.ts"
        try await TestSupport.eventually(timeout: .seconds(20)) {
            session.commitDiff?.diff?.path == "src/routes/webhook.ts"
        }
        let added = try XCTUnwrap(session.commitDiff?.diff)
        XCTAssertTrue(added.text.contains("new file mode"), added.text)
        XCTAssertTrue(added.text.contains("\n+export const verify = true\n"), added.text)

        // Back on Files, the marks still stand.
        session.select(.files)
        XCTAssertEqual(marks(session, path)["new.txt"], "R")
    }

    @MainActor
    private func marks(_ session: FilesSession, _ path: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (session.listings[path]?.entries ?? []).compactMap { entry in
            entry.mark.map { (entry.name, $0) }
        })
    }
}
