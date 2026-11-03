import Foundation
import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

/// Shared git reads run against a value executor, independent of transport, cache ownership and UI.
final class GitReadCoreTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Error, Equatable, Sendable {
        case failed(String)
        case cancelled
        case offline
    }

    private actor Script {
        var calls: [([String], UInt64)] = []
        let answers: [[String]: Result<GitOutput, Failure>]

        init(_ answers: [[String]: Result<GitOutput, Failure>]) { self.answers = answers }

        func run(_ args: [String], limit: UInt64) -> Result<GitOutput, Failure> {
            calls.append((args, limit))
            return answers[args] ?? .success(GitOutput(status: 0, output: "", truncated: false))
        }
    }

    private func reads(_ script: Script) -> GitCommitReads<Failure> {
        GitCommitReads(execute: { await script.run($0, limit: $1) }, failed: { .failed($0) }, failedMessage: {
            if case .failed(let message) = $0 { return message }
            return nil
        })
    }

    private func ok(_ text: String, truncated: Bool = false) -> Result<GitOutput, Failure> {
        .success(GitOutput(status: 0, output: text, truncated: truncated))
    }

    private let commitHash = String(repeating: "a", count: 40)
    private let parent = String(repeating: "b", count: 40)

    private func record(parents: [String] = []) -> String {
        [commitHash, parents.joined(separator: " "), "Sam Example", "sam@example.com", "1800000000", "", "Change", ""]
            .joined(separator: "\u{1f}") + "\0"
    }

    func testUntrackedContentKeepsWholeLinesAtItsBound() {
        let cut = GitContent.untracked(path: "a.txt", data: Data("one\npar".utf8), size: 20)
        XCTAssertTrue(cut.truncated)
        XCTAssertTrue(cut.text.hasSuffix("@@ -0,0 +1 @@\n+one\n"))
        XCTAssertFalse(cut.text.contains("No newline"))
        let whole = GitContent.untracked(path: "a.txt", data: Data("one\nlast".utf8), size: 8)
        XCTAssertFalse(whole.truncated)
        XCTAssertTrue(whole.text.hasSuffix("+last\n\\ No newline at end of file\n"))
        XCTAssertEqual(GitContent.lineCount(Data()), 0)
        XCTAssertEqual(GitContent.lineCount(Data("one\nlast".utf8)), 2)
        XCTAssertEqual(GitContent.lineCount(Data("one\nlast\n".utf8)), 2)
        XCTAssertTrue(GitContent.untracked(path: "empty", data: Data(), size: 0).text.hasSuffix("+++ b/empty\n"))
        XCTAssertFalse(GitContent.untracked(path: "long", data: Data("partial".utf8), size: 100).text.contains("@@"))
    }

    func testTheBinaryProbeUsesGitsFirstEightThousandBytes() {
        let binary = GitContent.untracked(path: "a.bin", data: Data([65, 0]), size: 100)
        XCTAssertTrue(binary.binary)
        XCTAssertEqual(binary.newSize, 100)
        XCTAssertTrue(binary.text.isEmpty)
        var data = Data(repeating: 65, count: 8_000)
        data.append(0)
        XCTAssertFalse(GitContent.isBinary(data))
        data[7_999] = 0
        XCTAssertTrue(GitContent.isBinary(data))
    }

    func testStatusCountsKeepAreasAndOnlyEnrichListedPaths() {
        let changes = [GitChange(path: "same", kind: .modified, area: .staged),
                       GitChange(path: "same", kind: .modified, area: .unstaged),
                       GitChange(path: "new", kind: .untracked, area: .untracked),
                       GitChange(path: "binary", kind: .untracked, area: .untracked)]
        let folded = GitStatusEnrichment.counts(changes, unstaged: GitParsers.numstat("3\t2\tsame\0"),
                                               staged: GitParsers.numstat("1\t0\tsame\0" + "9\t9\tstale\0")) { path in
            path == "new" ? .init(lines: 4, binary: false, size: 20) : .init(lines: nil, binary: true, size: 100)
        }
        XCTAssertEqual(folded.map(\.path), changes.map(\.path))
        XCTAssertEqual(folded.map(\.additions), [1, 3, 4, nil])
        XCTAssertEqual(folded.map(\.deletions), [0, 2, 0, nil])
        XCTAssertEqual(folded.last?.newSize, 100)
    }

    func testWorkingTreeSourceExcludesStagedFilesChangedAgainAndDeletions() {
        let staged = GitChange(path: "same", kind: .modified, area: .staged)
        let unstaged = GitChange(path: "same", kind: .modified, area: .unstaged)
        XCTAssertFalse(ReviewSourcePolicy.readsWorkingTree(staged, changes: [staged, unstaged]))
        XCTAssertTrue(ReviewSourcePolicy.readsWorkingTree(unstaged, changes: [staged, unstaged]))
        XCTAssertTrue(ReviewSourcePolicy.readsWorkingTree(staged, changes: [staged]))
        XCTAssertTrue(ReviewSourcePolicy.readsWorkingTree(staged, changes: [staged, .init(path: "other", kind: .modified, area: .unstaged)]))
        XCTAssertFalse(ReviewSourcePolicy.readsWorkingTree(.init(path: "gone", kind: .deleted, area: .unstaged), areas: []))
    }

    func testLogKeepsTruncatedPagesOpenAndRawReadsOptional() async throws {
        let args = GitCommands.log(scope: .branch, match: .message("literal.*"), skip: 200, count: 200, tip: commitHash)
        let script = Script([args: ok(record(), truncated: true), GitCommands.raw(args): .failure(.offline)])
        let page = try await reads(script).log(scope: .branch, match: .message("literal.*"), skip: 200, count: 200, tip: commitHash)
        XCTAssertEqual(page.commits.map(\.hash), [commitHash])
        XCTAssertFalse(page.exhausted)
        let calls = await script.calls
        XCTAssertEqual(Set(calls.map(\.0)), [args, GitCommands.raw(args)])
        XCTAssertTrue(calls.allSatisfy { $0.1 == 0 })
        let empty = Script([args: ok("", truncated: true)])
        let emptyPage = try await reads(empty).log(scope: .branch, match: .message("literal.*"), skip: 200, count: 200, tip: commitHash)
        XCTAssertTrue(emptyPage.exhausted, "a cut page with no complete record cannot advance")
    }

    func testUnbornHeadAndTypedCancellationStayDistinct() async throws {
        let empty = Script([GitCommands.head: .failure(.failed("Needed a single revision"))])
        let head = try await reads(empty).head()
        XCTAssertNil(head)
        let cancelled = Script([GitCommands.head: .failure(.cancelled)])
        do { _ = try await reads(cancelled).head(); XCTFail("cancellation became an unborn HEAD") }
        catch { XCTAssertEqual(error, .cancelled) }
        let args = GitCommands.log(scope: .branch, match: .everything, skip: 0, count: 200, tip: nil)
        let unborn = Script([args: .failure(.failed("fatal: bad default revision 'HEAD'"))])
        let page = try await reads(unborn).log(scope: .branch, match: .everything, skip: 0, count: 200, tip: nil)
        XCTAssertEqual(page, GitLogPage(commits: [], exhausted: true))
    }

    func testRawHeadersEnrichLogAndCommitWithoutCheckingSignatures() async throws {
        let args = GitCommands.log(scope: .all, match: .everything, skip: 0, count: 10, tip: nil)
        let raw = "commit \(commitHash)\nauthor Sam Example <sam@example.com> 1800000000 +0230\n"
            + "committer Pat Example <pat@example.com> 1800000001 -0100\ngpgsig -----BEGIN SSH SIGNATURE-----\n signature\n\n"
        let script = Script([args: ok(record()), GitCommands.raw(args): ok(raw),
                             GitCommands.show(commitHash, numstat: true): ok(record() + "\n1\t0\ta.txt\0"),
                             ["log", "-n", "1", "--pretty=raw", commitHash]: ok(raw)])
        let page = try await reads(script).log(scope: .all, match: .everything, skip: 0, count: 10, tip: "--ignored-for-all")
        XCTAssertEqual(page.commits.first?.signature, .ssh)
        XCTAssertEqual(page.commits.first?.zone, "+0230")
        let detail = try await reads(script).commit(commitHash, requireLetters: false, rawHeaders: true)
        XCTAssertEqual(detail.commit.signature, .ssh)
        XCTAssertEqual(detail.commit.committer?.name, "Pat Example")
        let calls = await script.calls
        XCTAssertFalse(calls.contains { $0.0.first == "verify-commit" })
    }

    func testCommentAnchorsKeepRemovedAndNewSidesDistinct() {
        let removed = ReviewPlacement.anchor(.init(kind: .removed, old: 7, new: nil, text: "old"))
        XCTAssertEqual(removed?.line, ReviewLine(side: .old, number: 7))
        XCTAssertEqual(removed?.quote, ReviewQuote(kind: .removed, text: "old"))
        let added = ReviewPlacement.anchor(.init(kind: .added, old: nil, new: 8, text: "new"))
        XCTAssertEqual(added?.line, ReviewLine(side: .new, number: 8))
        let context = ReviewPlacement.anchor(.init(kind: .context, old: 7, new: 8, text: "same"))
        XCTAssertEqual(context?.line, ReviewLine(side: .new, number: 8))
        XCTAssertEqual(context?.quote.kind, .context)
        XCTAssertNil(ReviewPlacement.anchor(.init(kind: .added, old: nil, new: nil, text: "partial")))
    }

    func testCommitLettersPoliciesAndFirstParentMergeReads() async throws {
        let counted = record() + "\n1\t0\ta.txt\0"
        let missing = Script([GitCommands.show(commitHash, numstat: true): ok(counted),
                              GitCommands.show(commitHash, numstat: false): .failure(.offline)])
        do { _ = try await reads(missing).commit(commitHash, requireLetters: true, rawHeaders: false); XCTFail("required letters vanished") }
        catch { XCTAssertEqual(error, .offline) }
        let tolerated = try await reads(missing).commit(commitHash, requireLetters: false, rawHeaders: true)
        XCTAssertEqual(tolerated.files.first?.path, "a.txt")
        let merge = Script([GitCommands.show(commitHash, numstat: true): ok(record(parents: [parent, commitHash]) + "\n1\t0\ta.txt\0"),
                            GitCommands.mergeLetters(parent: parent, hash: commitHash): ok("A\0a.txt\0")])
        let detail = try await reads(merge).commit(commitHash, requireLetters: true, rawHeaders: false)
        XCTAssertEqual(detail.files.first?.kind, .added)
        let calls = await merge.calls
        XCTAssertTrue(calls.contains { $0.0 == GitCommands.mergeLetters(parent: parent, hash: commitHash) })
        XCTAssertFalse(calls.contains { $0.0.contains("--pretty=raw") })
    }

    func testCommitSourceReadsTheRevisionWithLiteralPathsAndKeepsItsBound() async throws {
        let commit = try XCTUnwrap(GitParsers.log(record(parents: [parent, commitHash])).first)
        let args = GitCommands.fileSource(commitHash, mergeParent: parent, paths: [":(literal)a[1].txt"], limit: 2_000_000)
        let script = Script([args: ok("@@ -1 +1 @@\n-old\n+new\n")])
        let source = try await reads(script).source(commit, path: "a[1].txt", oldPath: nil, limit: 2_000_000, tooLarge: "Too large")
        XCTAssertEqual(source, "new\n")
        let calls = await script.calls
        XCTAssertEqual(calls.first?.0, args)
        XCTAssertEqual(calls.first?.1, 4_000_000)
        let cut = Script([args: ok("@@ -1 +1 @@\n-old\n+new\n", truncated: true)])
        do { _ = try await reads(cut).source(commit, path: "a[1].txt", oldPath: nil, limit: 2_000_000, tooLarge: "Too large"); XCTFail("cut source shown as whole") }
        catch { XCTAssertEqual(error, .failed("Too large")) }
    }
}
