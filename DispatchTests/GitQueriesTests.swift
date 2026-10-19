import Foundation
import XCTest
@testable import DispatchApp

/// The git commands as `files.git` receives them (the exact argument lists the helper allows) and what their answers
/// become, against the in-memory host's scripted git.
final class GitQueriesTests: XCTestCase {
    private let api = "/Users/ivan/src/api"
    private typealias Recorded = GitParsersTests.Recorded

    private func ok(_ output: String, truncated: Bool = false) -> GitOutput { GitOutput(status: 0, output: output, truncated: truncated) }

    func testRepositoryOfAFolder() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.gitAnswers[api + "/src rev-parse --show-toplevel"] = ok(api + "\n")
        let repository = try await GitQueries.repository(of: api + "/src", source: source)
        XCTAssertEqual(repository, GitRepository(root: api))
        XCTAssertEqual(source.gitCalls, [api + "/src rev-parse --show-toplevel"])

        let outside = try await GitQueries.repository(of: "/Users/ivan/docs", source: source)
        XCTAssertNil(outside, "git's \"not a git repository\" is no repository, not an error")
        source.gitAnswers["/Users/ivan/src/api/.git rev-parse --show-toplevel"] =
            GitOutput(status: 128, output: "fatal: this operation must be run in a work tree\n", truncated: false)
        let inside = try await GitQueries.repository(of: api + "/.git", source: source)
        XCTAssertNil(inside)

        // git names the resolved path; the root keeps the spelling of the folder shown.
        source.gitAnswers["/tmp/x/repo/src rev-parse --show-toplevel"] = ok("/private/tmp/x/repo\n")
        let linked = try await GitQueries.repository(of: "/tmp/x/repo/src", source: source)
        XCTAssertEqual(linked?.root, "/tmp/x/repo")

        // A link named otherwise (~/proj → /Volumes/data/api): the highest folder, as spelled, git places in the same
        // repository. Its parent is outside it, or in another one (a dotfiles repository at home).
        source.gitAnswers["/Users/ivan/proj rev-parse --show-toplevel"] = ok("/Volumes/data/api\n")
        source.gitAnswers["/Users/ivan/proj/src rev-parse --show-toplevel"] = ok("/Volumes/data/api\n")
        let before = source.gitCalls.count
        let link = try await GitQueries.repository(of: "/Users/ivan/proj", source: source)
        XCTAssertEqual(link?.root, "/Users/ivan/proj")
        XCTAssertEqual(Array(source.gitCalls.dropFirst(before)), ["/Users/ivan/proj rev-parse --show-toplevel",
                                                                  "/Users/ivan rev-parse --show-toplevel"])
        source.gitAnswers["/Users/ivan rev-parse --show-toplevel"] = ok("/Users/ivan\n")
        let below = try await GitQueries.repository(of: "/Users/ivan/proj/src", source: source)
        XCTAssertEqual(below?.root, "/Users/ivan/proj")

        source.gitAnswers["/srv/shared rev-parse --show-toplevel"] = GitOutput(
            status: 128, output: "fatal: detected dubious ownership in repository at '/srv/shared'\n", truncated: false)
        do {
            _ = try await GitQueries.repository(of: "/srv/shared", source: source)
            XCTFail("A refusal resolved")
        } catch {
            XCTAssertEqual(error, .failed("fatal: detected dubious ownership in repository at '/srv/shared'"), "git's own words")
        }
    }

    func testShownRootFollowsTheFoldersSpelling() {
        XCTAssertEqual(GitQueries.shownRoot("/Users/ivan/src/api", for: "/Users/ivan/src/api/src/lib"), "/Users/ivan/src/api")
        XCTAssertEqual(GitQueries.shownRoot("/private/var/folders/t/repo", for: "/var/folders/t/repo/a"), "/var/folders/t/repo")
        XCTAssertNil(GitQueries.shownRoot("/Volumes/data/api", for: "/Users/ivan/work"),
                     "No ancestor with the repository's name: git is asked about the parents (repository(of:))")
    }

    func testHelperRefusalsAreUnavailable() async throws {
        let local = FakeFilesSource.mockupAPI()
        local.failures["git"] = .unsupported("git is not installed on this Mac")
        do {
            _ = try await GitQueries.repository(of: api, source: local)
            XCTFail("A host without git resolved")
        } catch {
            XCTAssertEqual(error, .unavailable("git is not installed on this Mac"))
        }
        let remote = FakeFilesSource(endpoint: .remote(SSHConnectionID()), hostLabel: "homelab")
        remote.failures["git"] = .permissionDenied(api)
        do {
            _ = try await GitQueries.repository(of: api, source: remote)
            XCTFail("A connection without the git grant resolved")
        } catch {
            XCTAssertEqual(error, .unavailable("Git isn’t allowed on homelab: turn on Git metadata for this host"))
        }
        remote.failures["git"] = .offline("homelab")
        do {
            _ = try await GitQueries(source: remote, root: api).status()
            XCTFail("An offline host answered")
        } catch {
            XCTAssertEqual(error, .source(.offline("homelab")))
        }
        // A helper that does not know files.git yet answers unsupported in its own words.
        XCTAssertEqual(GitQueries.failure(HelperFailure(code: "unsupported", message: ""), source: local, path: api),
                       .unavailable("This Mac’s helper can’t do this yet"))
        XCTAssertEqual(GitQueries.failure(HelperFailure(code: "permission_denied", message: "git.read"), source: local, path: api),
                       .unavailable("Git isn’t allowed on this Mac’s helper"))
        XCTAssertEqual(HelperFilesSource.Bound.git(1).duration, .seconds(65), "Longer than the helper's three 20 s steps")
        XCTAssertEqual(HelperFilesSource.Bound.git(0).duration, .seconds(97), "The helper's 2 MiB: 1 s more per 64 KiB")
        XCTAssertEqual(HelperFilesSource.Bound.git(8 << 20).duration, .seconds(193))
        XCTAssertEqual(HelperFilesSource.Bound.git(.max).duration, .seconds(600))
        XCTAssertEqual(HelperFilesSource.Bound.git(8 << 20).name, "files.git")

        // The helper stopped git at its deadline: not git's answer about the repository.
        local.failures["git"] = nil
        local.gitAnswers["status --porcelain=v2 --branch -z --ignored --untracked-files=normal"] =
            GitOutput(status: -1, output: "git took longer than 20 s", truncated: false)
        do {
            _ = try await GitQueries(source: local, root: api).status()
            XCTFail("A stopped git answered")
        } catch {
            XCTAssertEqual(error, .source(.other(code: "deadline", message: "git took longer than 20 s")))
        }
    }

    func testStatusAndCountsSendTheAllowedArguments() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.gitAnswers["status --porcelain=v2 --branch -z --ignored --untracked-files=normal"] = ok(Recorded.status)
        source.gitAnswers["diff --numstat -z"] = ok(Recorded.unstagedNumstat)
        source.gitAnswers["diff --cached --numstat -z"] = ok(Recorded.stagedNumstat)
        let queries = GitQueries(source: source, root: api)
        let status = try await queries.status()
        XCTAssertEqual(status.branch, "main")
        let unstaged = try await queries.numstat(cached: false), staged = try await queries.numstat(cached: true)
        XCTAssertEqual(unstaged.count, 4)
        XCTAssertEqual(staged.first?.oldPath, "old.txt")
        XCTAssertEqual(source.gitCalls, [
            api + " status --porcelain=v2 --branch -z --ignored --untracked-files=normal",
            api + " diff --numstat -z",
            api + " diff --cached --numstat -z",
        ])
        XCTAssertEqual(source.gitLimits, [8 << 20, 8 << 20, 8 << 20], "The status and its counts ask for the helper's cap")
        XCTAssertFalse(status.truncated)
        source.gitAnswers["status --porcelain=v2 --branch -z --ignored --untracked-files=normal"] =
            ok(String(Recorded.status.prefix(Recorded.status.count - 6)), truncated: true)
        let cut = try await queries.status()
        XCTAssertTrue(cut.truncated, "A status the bound cut says so")
        XCTAssertEqual(cut.ignored, ["debug.log"])
        source.gitAnswers["diff --numstat -z"] = GitOutput(status: 129, output: "error: unknown option\n", truncated: false)
        do {
            _ = try await queries.numstat(cached: false)
            XCTFail("A failed command answered")
        } catch {
            XCTAssertEqual(error, .failed("error: unknown option"))
        }
    }

    func testDiffsOfStagedUnstagedRenamedAndBinaryChanges() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.gitAnswers["diff --cached -U3 -- src/routes/billing.ts"] = ok(Recorded.stagedDiff)
        source.gitAnswers["diff -U3 -- src/routes/billing.ts"] = ok(Recorded.unstagedDiff, truncated: true)
        source.gitAnswers["diff --cached -U3 -- old.txt new.txt"] = ok(Recorded.renameDiff)
        source.gitAnswers["diff -U3 -- logo.png"] = ok(Recorded.binaryDiff)
        source.gitAnswers["diff --stat -- logo.png"] = ok(Recorded.binaryStat)
        let queries = GitQueries(source: source, root: api)

        let staged = try await queries.diff(GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged))
        XCTAssertEqual(staged.text, Recorded.stagedDiff)
        XCTAssertFalse(staged.truncated)
        let unstaged = try await queries.diff(GitChange(path: "src/routes/billing.ts", kind: .modified, area: .unstaged))
        XCTAssertTrue(unstaged.truncated, "The helper's bound shows on the diff")
        let renamed = try await queries.diff(GitChange(path: "new.txt", oldPath: "old.txt", kind: .renamed, area: .staged))
        XCTAssertEqual(renamed.path, "new.txt")
        XCTAssertEqual(renamed.oldPath, "old.txt")
        let binary = try await queries.diff(GitChange(path: "logo.png", kind: .modified, area: .unstaged))
        XCTAssertTrue(binary.binary)
        XCTAssertEqual(binary.oldSize, 6)
        XCTAssertEqual(binary.newSize, 11)
        XCTAssertEqual(source.gitCalls.last, api + " diff --stat -- logo.png", "Sizes are asked only for a binary")

        // A name git would read as a pattern goes literally.
        XCTAssertEqual(GitQueries.paths("src/[id].ts", old: nil), [":(literal)src/[id].ts"])
        XCTAssertEqual(GitQueries.paths("b.ts", old: ":a.ts"), [":(literal):a.ts", "b.ts"])
    }

    func testUntrackedFilesReadAsAdditions() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.file(api + "/notes.md", "one\ntwo")
        source.file(api + "/logo.bin", Data([0x89, 0x50, 0x00, 0x01]))
        let queries = GitQueries(source: source, root: api)
        let test = try await queries.diff(GitChange(path: "tests/idempotency.test.ts", kind: .untracked, area: .untracked))
        XCTAssertEqual(test.text, """
            diff --git a/tests/idempotency.test.ts b/tests/idempotency.test.ts
            new file mode 100644
            --- /dev/null
            +++ b/tests/idempotency.test.ts
            @@ -0,0 +1 @@
            +test('idempotent', () => {})

            """)
        XCTAssertEqual(test.newSize, 29)
        XCTAssertTrue(source.calls.contains("read " + api + "/tests/idempotency.test.ts"))
        XCTAssertEqual(source.gitCalls, [], "git has nothing to diff an untracked file against")
        let notes = try await queries.diff(GitChange(path: "notes.md", kind: .untracked, area: .untracked))
        XCTAssertTrue(notes.text.hasSuffix("@@ -0,0 +1,2 @@\n+one\n+two\n\\ No newline at end of file\n"), notes.text)
        let binary = try await queries.diff(GitChange(path: "logo.bin", kind: .untracked, area: .untracked))
        XCTAssertTrue(binary.binary)
        XCTAssertEqual(binary.newSize, 4)
        XCTAssertNil(binary.oldSize)
        do {
            _ = try await queries.diff(GitChange(path: "tests/", kind: .untracked, area: .untracked))
            XCTFail("An untracked folder read as a file")
        } catch {
            guard case .failed = error else { return XCTFail("\(error)") }
        }

        let lines = try await queries.untrackedLines("notes.md", limit: 100)
        XCTAssertEqual(lines.lines, 2)
        XCTAssertFalse(lines.binary)
        XCTAssertEqual(lines.read, 7)
        XCTAssertEqual(lines.size, 7)
        let pixels = try await queries.untrackedLines("logo.bin", limit: 100)
        XCTAssertNil(pixels.lines)
        XCTAssertTrue(pixels.binary)
        let cut = try await queries.untrackedLines("notes.md", limit: 4)
        XCTAssertNil(cut.lines, "Longer than the limit: no count")
        XCTAssertEqual(cut.read, 4)
        XCTAssertEqual(cut.size, 7)

        // A name that arrived as U+FFFD (not UTF-8) is never named back to git or read.
        let reads = source.calls.count
        for change in [GitChange(path: "caf\u{FFFD}.txt", kind: .modified, area: .unstaged),
                       GitChange(path: "caf\u{FFFD}.txt", kind: .untracked, area: .untracked),
                       GitChange(path: "new.txt", oldPath: "caf\u{FFFD}.txt", kind: .renamed, area: .staged)] {
            XCTAssertFalse(change.representable)
            do {
                _ = try await queries.diff(change)
                XCTFail("\(change.path) was diffed")
            } catch {
                XCTAssertEqual(error, .failed(GitChange.unrepresentable))
            }
        }
        XCTAssertEqual(source.calls.count, reads)
        XCTAssertEqual(source.gitCalls, [])
        XCTAssertEqual(GitQueries.lineCount(Data("a\nb\n".utf8)), 2)
        XCTAssertEqual(GitQueries.lineCount(Data()), 0)
    }

    /// The page queries a run made, apart from the raw query each page reads beside it (the signatures), which must
    /// mirror its page: the same range in the raw format.
    private func pageCalls(_ source: FakeFilesSource, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        let calls = source.gitCalls.map { String($0.dropFirst(api.count + 1)) }
        let pages = calls.filter { !$0.contains("--pretty=raw") }
        let mirrored = pages.map { $0.replacingOccurrences(of: GitQueries.format, with: "--pretty=raw")
            .replacingOccurrences(of: " --date=unix", with: "") }
        XCTAssertEqual(calls.filter { $0.contains("--pretty=raw") }.sorted(), mirrored.sorted(),
                       "every page reads its signatures", file: file, line: line)
        return pages
    }

    func testLogPagesScopesAndFilters() async throws {
        let source = FakeFilesSource.mockupAPI()
        let format = GitQueries.format
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix"] = ok(Recorded.log)
        source.gitAnswers["log -n 1 --skip=0 \(format) --date=unix --all"] = ok(Recorded.log, truncated: true)
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix --grep=Retry --regexp-ignore-case --fixed-strings"] = ok("")
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix --all --author=ivan --regexp-ignore-case --fixed-strings"] = ok(Recorded.log)
        let queries = GitQueries(source: source, root: api)

        let branch = try await queries.log(scope: .branch, skip: 0, count: 200)
        XCTAssertEqual(branch.commits.count, 2)
        XCTAssertTrue(branch.exhausted, "A short page is the end")
        let cut = try await queries.log(scope: .all, skip: 0, count: 1)
        XCTAssertEqual(cut.commits.count, 2)
        XCTAssertFalse(cut.exhausted, "A page the bound cut is not the end")
        let message = try await queries.log(scope: .branch, match: .message("Retry"), skip: 0, count: 200)
        XCTAssertEqual(message.commits, [])
        XCTAssertTrue(message.exhausted)
        let author = try await queries.log(scope: .all, match: .author("ivan"), skip: 0, count: 200)
        XCTAssertEqual(author.commits.count, 2)
        // The branch scope pages from a pinned commit; every branch has none to pin.
        let tip = "8c55745e219a449f587bbd4ad476d0f376670a0d"
        source.gitAnswers["log -n 200 --skip=200 \(format) --date=unix --grep=Retry --regexp-ignore-case --fixed-strings \(tip)"] = ok("")
        _ = try await queries.log(scope: .branch, match: .message("Retry"), skip: 200, count: 200, from: tip)
        _ = try await queries.log(scope: .all, match: .author("ivan"), skip: 0, count: 200, from: tip)
        XCTAssertEqual(pageCalls(source), [
            "log -n 200 --skip=0 \(format) --date=unix",
            "log -n 1 --skip=0 \(format) --date=unix --all",
            "log -n 200 --skip=0 \(format) --date=unix --grep=Retry --regexp-ignore-case --fixed-strings",
            "log -n 200 --skip=0 \(format) --date=unix --all --author=ivan --regexp-ignore-case --fixed-strings",
            "log -n 200 --skip=200 \(format) --date=unix --grep=Retry --regexp-ignore-case --fixed-strings \(tip)",
            "log -n 200 --skip=0 \(format) --date=unix --all --author=ivan --regexp-ignore-case --fixed-strings",
        ])
        do {
            _ = try await queries.log(scope: .branch, skip: 0, count: 200, from: "--all")
            XCTFail("A tip that is not a hash reached git")
        } catch {
            guard case .failed = error else { return XCTFail("\(error)") }
        }

        // HEAD's commit, and none before the first commit.
        source.gitAnswers["rev-parse --verify HEAD"] = ok(tip + "\n")
        let head = try await queries.head()
        XCTAssertEqual(head, tip)
        source.gitAnswers["rev-parse --verify HEAD"] = GitOutput(status: 128, output: "fatal: Needed a single revision\n", truncated: false)
        let unborn = try await queries.head()
        XCTAssertNil(unborn)

        // A repository before its first commit has an empty log, not an error.
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix"] = GitOutput(
            status: 128, output: "fatal: your current branch 'main' does not have any commits yet\n", truncated: false)
        let empty = try await queries.log(scope: .branch, skip: 0, count: 200)
        XCTAssertEqual(empty, GitLogPage(commits: [], exhausted: true))
    }

    func testRefsCommitsAndCommitDiffs() async throws {
        let source = FakeFilesSource.mockupAPI()
        let hash = "8c55745e219a449f587bbd4ad476d0f376670a0d", parent = "7b984b71ab4bcb7cb46ccfa9ffde329d32f8d0b8"
        source.gitAnswers["for-each-ref \(GitQueries.refsFormat) refs/heads refs/remotes refs/tags"] = ok(Recorded.refs)
        source.gitAnswers["show --numstat -z \(GitQueries.format) \(hash)"] = ok(Recorded.show)
        source.gitAnswers["show --name-status -z \(GitQueries.format) \(hash)"] = ok(
            Recorded.show.components(separatedBy: "\0")[0] + "\0\0\nA\0src/routes/billing.ts\0")
        source.gitAnswers["show --format= -U3 \(hash) -- src/routes/billing.ts"] = ok(Recorded.unstagedDiff)
        source.gitAnswers["diff -U3 \(parent) \(hash) -- a.txt"] = ok(Recorded.ccDiff)
        let queries = GitQueries(source: source, root: api)

        let refs = try await queries.refs()
        XCTAssertEqual(refs.count, 5)
        let detail = try await queries.commit(hash)
        XCTAssertEqual(detail.commit.hash, hash)
        XCTAssertEqual(detail.files.map(\.path), ["src/routes/billing.ts"])
        XCTAssertEqual(detail.files.map(\.kind), [.added], "The letter comes from --name-status")
        let diff = try await queries.commitDiff(detail.commit, path: "src/routes/billing.ts", oldPath: nil)
        XCTAssertEqual(diff.path, "src/routes/billing.ts")
        var merge = detail.commit
        merge.parents = [parent, "5d0ea93f208fa20097b95902f7ea6a3c0f20be06"]
        let merged = try await queries.commitDiff(merge, path: "a.txt", oldPath: nil)
        XCTAssertEqual(merged.path, "a.txt", "A merge's file diffs against its first parent")

        let before = source.gitCalls.count
        for bad in ["--output=/tmp/x", "HEAD~1", "a..b", "12"] {
            do {
                _ = try await queries.commit(bad)
                XCTFail("\(bad) reached git")
            } catch {
                guard case .failed = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(source.gitCalls.count, before, "Only hashes reach git as revisions")
    }

    func testFilteredPagesMergeByHashNewestFirst() async throws {
        func commit(_ hash: String, _ time: TimeInterval) -> GitCommit {
            GitCommit(hash: hash, parents: [], subject: hash, body: "", author: "a", email: "e", date: Date(timeIntervalSince1970: time), refs: [])
        }
        var pages = GitLogPages(scope: .branch, filter: "  fix ")
        XCTAssertEqual(pages.queries.map(\.match), [.message("fix"), .author("fix")])
        pages.queries[0].commits = [commit("aaaa", 50), commit("bbbb", 40), commit("cccc", 10)]
        pages.queries[0].exhausted = true
        pages.queries[1].commits = [commit("dddd", 45), commit("bbbb", 40), commit("eeee", 20)]
        XCTAssertEqual(pages.commits.map(\.hash), ["aaaa", "dddd", "bbbb", "eeee"],
                       "Merged by date, each commit once, and nothing older than the unfinished query's last page")
        XCTAssertFalse(pages.exhausted)
        pages.queries[1].exhausted = true
        XCTAssertEqual(pages.commits.map(\.hash), ["aaaa", "dddd", "bbbb", "eeee", "cccc"])
        XCTAssertTrue(pages.exhausted)
        XCTAssertEqual(GitLogPages(scope: .all, filter: "").queries.map(\.match), [.everything])
    }

    func testFillLoadsPagesUntilWantedOrShort() async throws {
        let source = FakeFilesSource.mockupAPI()
        let format = GitQueries.format
        let one = Recorded.log.components(separatedBy: "\0\n")
        source.gitAnswers["log -n 3 --skip=0 \(format) --date=unix"] = ok(one[0] + "\0\n", truncated: true)
        source.gitAnswers["log -n 2 --skip=1 \(format) --date=unix"] = ok(one[1] + "\0\n")
        var pages = GitLogPages(scope: .branch, filter: "")
        try await pages.fill(3, with: GitQueries(source: source, root: api))
        XCTAssertEqual(pages.commits.count, 2)
        XCTAssertTrue(pages.exhausted, "The second page came back short")
        XCTAssertEqual(pageCalls(source).count, 2, "A page the bound cut is followed by the rest")
    }

    func testFillAsksAPageAtATimeFromItsTipAndKeepsEachCommitOnce() async throws {
        let source = FakeFilesSource.mockupAPI()
        let format = GitQueries.format, tip = String(format: "%040x", 1)
        func records(_ range: Range<Int>) -> String {
            range.map { index in
                [String(format: "%040x", index + 1), String(format: "%040x", index + 2), "Ivan", "ivan@example.com",
                 String(1_760_000_000 - index), "", "Commit \(index)", ""].joined(separator: "\u{1F}") + "\0\n"
            }.joined()
        }
        // The second page overlaps the first by ten (a ref moved between them, with --all): each commit once.
        source.gitAnswers["log -n 200 --skip=0 \(format) --date=unix \(tip)"] = ok(records(0..<200))
        source.gitAnswers["log -n 200 --skip=200 \(format) --date=unix \(tip)"] = ok(records(190..<390))
        source.gitAnswers["log -n 200 --skip=400 \(format) --date=unix \(tip)"] = ok(records(390..<590))
        source.gitAnswers["log -n 60 --skip=600 \(format) --date=unix \(tip)"] = ok(records(590..<650))
        var pages = GitLogPages(scope: .branch, filter: "", tip: tip)
        try await pages.fill(650, with: GitQueries(source: source, root: api))
        XCTAssertEqual(pageCalls(source), [
            "log -n 200 --skip=0 \(format) --date=unix \(tip)",
            "log -n 200 --skip=200 \(format) --date=unix \(tip)",
            "log -n 200 --skip=400 \(format) --date=unix \(tip)",
            "log -n 60 --skip=600 \(format) --date=unix \(tip)",
        ], "Never more than a page a call: the helper refuses more than 1,000")
        XCTAssertEqual(pages.commits.count, 650)
        XCTAssertEqual(Set(pages.commits.map(\.hash)).count, 650)
        XCTAssertEqual(pages.queries[0].fetched, 660)
        XCTAssertFalse(pages.exhausted)
    }
}
