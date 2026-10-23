import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Review's changes list (docs/ios.md, Review): the helper reader's git commands (the Mac's `GitQueries`), the status
/// with its counts folded in, untracked diffs and errors; `ReviewChanges`' one read at a time, kept status and cadence;
/// H2's rows, bar and accessory (S4).
@MainActor
final class ReviewChangesTests: XCTestCase {
    nonisolated private static let root = "/Users/alex/src/app"
    nonisolated private static let hash = String(repeating: "a", count: 40)

    /// The status git prints for the fixture: a staged add, an unstaged edit, a staged rename, an unstaged binary, a
    /// conflict, two untracked files (text and binary), an ignored folder.
    nonisolated private static var porcelain: String {
        let h = hash, z = String(repeating: "0", count: 40)
        return [
            "# branch.oid 3f2c1a0e9b8d7c6f5a4b3c2d1e0f9a8b7c6d5e4f",
            "# branch.head dark-mode",
            "# branch.upstream origin/dark-mode",
            "# branch.ab +2 -1",
            "1 A. N... 000000 100644 100644 \(z) \(h) src/theme.ts",
            "1 .M N... 100644 100644 100644 \(h) \(h) src/components/Sidebar.tsx",
            "2 R. N... 100644 100644 100644 \(h) \(h) R100 src/layout.ts",
            "src/frame.ts",
            "1 .M N... 100644 100644 100644 \(h) \(h) assets/logo.png",
            "u UU N... 100644 100644 100644 100644 \(h) \(h) \(h) src/merge.ts",
            "? docs/theming.md",
            "? assets/icon.bin",
            "! node_modules/",
        ].map { $0 + "\0" }.joined()
    }

    /// A helper answering the fixture's git commands, `files.read` for the untracked files and `files.text`.
    nonisolated private static func gitHelper(status: Int64 = 0, words: String? = nil, refuse: String? = nil) -> ScriptedHelper {
        // Sendable: the script answers on the transport's queue.
        ScriptedHelper.scripted { request in
            if let refuse { return .failure(code: refuse, message: "") }
            switch request.method {
            case "files.git":
                let args = request.params["args"] as? [String] ?? []
                func git(_ output: String) -> ScriptedHelper.Reply {
                    .result(["status": Int(status), "output": words ?? output, "truncated": false])
                }
                switch args {
                case ["status", "--porcelain=v2", "--branch", "-z", "--ignored", "--untracked-files=normal"]: return git(porcelain)
                // Sidebar.tsx's counts; the binary's dashes; a stat-dirty file the status does not list.
                case ["diff", "--numstat", "-z"]:
                    return git("14\t6\tsrc/components/Sidebar.tsx\0-\t-\tassets/logo.png\0" + "3\t1\tsrc/stale.ts\0")
                case ["diff", "--cached", "--numstat", "-z"]:
                    return git("31\t0\tsrc/theme.ts\0" + "2\t1\t\0src/frame.ts\0src/layout.ts\0")
                case ["diff", "--stat", "--", "assets/logo.png"]:
                    return git(" assets/logo.png | Bin 49152 -> 52224 bytes\n 1 file changed\n")
                case ["diff", "-U3", "--", "src/components/Sidebar.tsx"]:
                    return git("diff --git a/src/components/Sidebar.tsx b/src/components/Sidebar.tsx\n--- a/src/components/Sidebar.tsx\n"
                               + "+++ b/src/components/Sidebar.tsx\n@@ -1 +1 @@\n-old\n+new\n")
                default: return git("")
                }
            case "files.read":
                let path = request.params["path"] as? String ?? ""
                let data: Data = path.hasSuffix("theming.md") ? Data("# Theming\n\nTokens.\nLast line".utf8)
                    : Data([0x89, 0x50, 0x00, 0x01, 0x02])
                return .bytes(.object(["kind": .string("file"), "size": .unsigned(UInt64(data.count))]), data)
            case "files.text":
                let path = request.params["path"] as? String ?? ""
                return path.hasSuffix(".bin") ? .failure(code: "unsupported", message: "") : .result("one\ntwo\n")
            default:
                return .failure(code: "unsupported", message: "")
            }
        }
    }

    // MARK: The helper reader

    /// The status is the Mac's three commands at the repository's root with the 8 MiB bound; the counts fold in where
    /// the status lists the file; untracked files are counted from a bounded `files.read`, a binary's sizes come from
    /// `diff --stat`.
    func testTheHelperReaderFoldsTheMacsStatusCommands() async throws {
        let helper = Self.gitHelper()
        try await helper.configureChunks()
        let reader = ReviewGitReader.helper(helper.client)
        let status = try await reader.status(Self.root)

        let git = helper.requests("files.git")
        XCTAssertEqual(Set(git.prefix(3).compactMap { $0.params["args"] as? [String] }), [
            ["status", "--porcelain=v2", "--branch", "-z", "--ignored", "--untracked-files=normal"],
            ["diff", "--numstat", "-z"], ["diff", "--cached", "--numstat", "-z"]])
        for request in git.prefix(3) {
            XCTAssertEqual(request.params["path"] as? String, Self.root)
            XCTAssertEqual(request.params["limit"] as? UInt64 ?? UInt64(request.params["limit"] as? Int ?? 0), 8 << 20)
            XCTAssertNil(request.params["plugin"], "as SpaceGitFacts sends files.git")
        }
        XCTAssertEqual(git.last?.params["args"] as? [String], ["diff", "--stat", "--", "assets/logo.png"])
        let reads = helper.requests("files.read")
        XCTAssertEqual(Set(reads.compactMap { $0.params["path"] as? String }),
                       [Self.root + "/docs/theming.md", Self.root + "/assets/icon.bin"])
        XCTAssertEqual(reads.first?.params["length"] as? UInt64 ?? UInt64(reads.first?.params["length"] as? Int ?? 0), 256 << 10)

        XCTAssertEqual(status.branch, "dark-mode")
        XCTAssertEqual(status.head, "3f2c1a0")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        func change(_ path: String, _ area: GitChangeArea) -> GitChange? { status.changes.first { $0.path == path && $0.area == area } }
        XCTAssertEqual(change("src/theme.ts", .staged)?.additions, 31)
        XCTAssertEqual(change("src/components/Sidebar.tsx", .unstaged)?.deletions, 6)
        let renamed = try XCTUnwrap(change("src/layout.ts", .staged))
        XCTAssertEqual(renamed.kind, .renamed)
        XCTAssertEqual(renamed.oldPath, "src/frame.ts")
        XCTAssertEqual(renamed.additions, 2)
        let binary = try XCTUnwrap(change("assets/logo.png", .unstaged))
        XCTAssertTrue(binary.binary)
        XCTAssertEqual(binary.oldSize, 49152)
        XCTAssertEqual(binary.newSize, 52224)
        XCTAssertEqual(change("src/merge.ts", .unstaged)?.kind, .conflicted)
        XCTAssertEqual(change("docs/theming.md", .untracked)?.additions, 4, "the last line has no newline")
        XCTAssertEqual(change("docs/theming.md", .untracked)?.deletions, 0)
        let icon = try XCTUnwrap(change("assets/icon.bin", .untracked))
        XCTAssertTrue(icon.binary)
        XCTAssertNil(icon.additions)
        XCTAssertEqual(icon.newSize, 5)
        XCTAssertFalse(status.changes.contains { $0.path == "src/stale.ts" }, "only what the status lists takes counts")
        XCTAssertFalse(status.changes.contains { $0.path.hasPrefix("node_modules") }, "ignored files are not changes")

        // The next status keeps the counts and sizes; a forget (an explicit refresh) reads them again.
        _ = try await reader.status(Self.root)
        XCTAssertEqual(helper.requests("files.read").count, 2)
        XCTAssertEqual(helper.requests("files.git").count, 7)
        reader.forget(Self.root)
        _ = try await reader.status(Self.root)
        XCTAssertEqual(helper.requests("files.read").count, 4)
        XCTAssertEqual(helper.requests("files.git").count, 11)

        // The rows' grammar for a rename and a binary.
        XCTAssertEqual(ReviewChangeRow.lead(renamed), "src/frame.ts → src/")
        XCTAssertEqual(ReviewChangeRow.binary(binary), "binary · 49 KB → 52 KB")
        XCTAssertEqual(ReviewChangeRow.letter(.conflicted), "U")
        XCTAssertEqual(ReviewChangeRow.letter(.untracked), "?")
        XCTAssertEqual(ReviewChangeRow.accessibilityLabel(renamed, comments: 1),
                       "src/layout.ts, Renamed, renamed from src/frame.ts, 2 added, 1 deleted, 1 comment")
    }

    /// A tracked change's diff is git's (`--cached` for a staged one, both paths for a rename); an untracked file is its
    /// text as one added hunk, a binary one its size; `text` is `files.text` and nil for what it refuses.
    func testDiffsAndText() async throws {
        let helper = Self.gitHelper()
        try await helper.configureChunks()
        let reader = ReviewGitReader.helper(helper.client)

        let sidebar = try await reader.diff(Self.root, GitChange(path: "src/components/Sidebar.tsx", kind: .modified, area: .unstaged))
        XCTAssertTrue(sidebar.text.contains("+new"))
        _ = try await reader.diff(Self.root, GitChange(path: "src/layout.ts", oldPath: "src/frame.ts", kind: .renamed, area: .staged))
        XCTAssertEqual(helper.requests("files.git").last?.params["args"] as? [String],
                       ["diff", "--cached", "-U3", "--", "src/frame.ts", "src/layout.ts"])
        _ = try await reader.diff(Self.root, GitChange(path: "src/[id].ts", kind: .modified, area: .unstaged))
        XCTAssertEqual(helper.requests("files.git").last?.params["args"] as? [String], ["diff", "-U3", "--", ":(literal)src/[id].ts"])

        let notes = try await reader.diff(Self.root, GitChange(path: "docs/theming.md", kind: .untracked, area: .untracked))
        XCTAssertEqual(notes.text, """
            diff --git a/docs/theming.md b/docs/theming.md
            new file mode 100644
            --- /dev/null
            +++ b/docs/theming.md
            @@ -0,0 +1,4 @@
            +# Theming
            +
            +Tokens.
            +Last line
            \\ No newline at end of file

            """)
        XCTAssertEqual(helper.requests("files.read").last?.params["length"] as? UInt64
                       ?? UInt64(helper.requests("files.read").last?.params["length"] as? Int ?? 0), 2 << 20)
        let icon = try await reader.diff(Self.root, GitChange(path: "assets/icon.bin", kind: .untracked, area: .untracked))
        XCTAssertTrue(icon.binary)
        XCTAssertEqual(icon.newSize, 5)

        let text = try await reader.text(Self.root + "/src/theme.ts")
        XCTAssertEqual(text, "one\ntwo\n")
        XCTAssertEqual(helper.requests("files.text").first?.params["plugin"] as? String, "files")
        XCTAssertEqual(helper.requests("files.text").first?.params["path"] as? String, Self.root + "/src/theme.ts")
        let refused = try await reader.text(Self.root + "/assets/icon.bin")
        XCTAssertNil(refused, "binary or too large: nothing to show")
    }

    /// git's failures in the Mac's words: outside a repository, the helper's deadline, git's own message, and the
    /// helper's refusals as unavailable.
    func testErrorsAreWordedAsTheMacs() async throws {
        func failure(_ helper: ScriptedHelper) async -> ReviewGitError? {
            do {
                _ = try await ReviewGitReader.helper(helper.client).status(Self.root)
                return nil
            } catch {
                return error as? ReviewGitError
            }
        }
        let outside = await failure(Self.gitHelper(status: 128, words: "fatal: not a git repository (or any of the parent directories): .git"))
        XCTAssertEqual(outside, .notRepository)
        let deadline = await failure(Self.gitHelper(status: -1, words: "git took longer than 20 s"))
        XCTAssertEqual(deadline, .source("git took longer than 20 s"))
        XCTAssertEqual(deadline?.transient, true)
        let broken = await failure(Self.gitHelper(status: 128, words: "fatal: bad object HEAD\n"))
        XCTAssertEqual(broken, .failed("fatal: bad object HEAD"))
        let denied = await failure(Self.gitHelper(refuse: "permission_denied"))
        XCTAssertEqual(denied, .unavailable("Git isn’t allowed on this host: turn on Files & git for it"))
        let missing = await failure(Self.gitHelper(refuse: "unsupported"))
        XCTAssertEqual(missing, .unavailable("The helper can’t run git on this host"))
        XCTAssertEqual(missing?.transient, false)
    }

    // MARK: ReviewChanges

    private static let place = ReviewPlace(host: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!, root: root)

    private func review(_ script: ScriptedStatus?) -> MobileReview {
        let review = MobileReview(repository: ReviewRepository(store: ReviewMemoryStore()), clock: { Date(timeIntervalSince1970: 0) })
        review.reader = { _ in script?.reader }
        return review
    }

    /// One read at a time: refreshes asked during a read make one more read after it; an explicit refresh forgets the
    /// reader's counts first.
    func testOneReadAtATime() async throws {
        let script = ScriptedStatus()
        let review = review(script)
        let changes = review.changes(Self.place)
        script.hold = true
        let first = Task { await changes.refresh() }
        try await TestSupport.eventually { script.pending == 1 }
        XCTAssertTrue(changes.loading)
        let second = Task { await changes.refresh() }
        let third = Task { await changes.refresh(fresh: true) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(script.reads, 1)
        script.release()
        try await TestSupport.eventually { script.pending == 1 }
        XCTAssertEqual(script.reads, 2, "the two asked meanwhile run once, after it")
        XCTAssertEqual(script.forgot, 1)
        script.hold = false
        script.release()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(script.reads, 2)
        XCTAssertFalse(changes.loading)
        XCTAssertEqual(changes.status?.changes.count, ReviewSample.changes.count)
    }

    /// A failed read keeps the last status and says why; the next answer clears it. Without a reader (offline, no
    /// grant) nothing is read.
    func testAFailedReadKeepsTheLastStatus() async throws {
        let script = ScriptedStatus()
        let review = review(script)
        let changes = review.changes(Self.place)
        await changes.refresh()
        let shown = try XCTUnwrap(changes.status)
        XCTAssertNil(changes.failure)
        script.fail = .source("The host is offline")
        await changes.refresh()
        XCTAssertEqual(changes.status, shown, "the last list stays")
        XCTAssertEqual(changes.error, "The host is offline")
        script.fail = nil
        await changes.refresh()
        XCTAssertNil(changes.failure)
        XCTAssertEqual(changes.status, shown, "the same status is not written again")

        let none = self.review(nil)
        let offline = none.changes(Self.place)
        await offline.refresh()
        XCTAssertNil(offline.status)
        XCTAssertFalse(offline.loading)
    }

    /// The watch reads on appear and after every interval; `MobileReview.changed(host:)` refreshes the host's shown
    /// lists (recounting) and no others; an ended watch reads no more.
    func testTheWatchCadence() async throws {
        let script = ScriptedStatus()
        let review = review(script)
        let changes = review.changes(Self.place)
        let steps = Steps()
        changes.sleep = { _ in await steps.sleep() }
        let other = review.changes(ReviewPlace(host: UUID(), root: Self.root))

        let watch = Task { await changes.watch() }
        try await TestSupport.eventually { script.reads == 1 && steps.pending == 1 }
        XCTAssertEqual(changes.shown, 1)
        steps.step()
        try await TestSupport.eventually { script.reads == 2 && steps.pending == 1 }
        steps.step()
        try await TestSupport.eventually { script.reads == 3 && steps.pending == 1 }

        review.changed(host: Self.place.host)
        try await TestSupport.eventually { script.reads == 4 }
        XCTAssertEqual(script.forgot, 1, "an agent's turn recounts")
        review.changed(host: other.place.host)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(script.reads, 4, "a list not shown reads when it shows")
        XCTAssertNil(other.status)

        watch.cancel()
        steps.step()
        try await TestSupport.eventually { changes.shown == 0 }
        review.changed(host: Self.place.host)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(script.reads, 4)
    }

    // MARK: Views

    private func context(_ review: MobileReview, offline: Bool = false, pushed: @escaping (FilesRoute) -> Void = { _ in }) -> ReviewContext {
        ReviewContext(review: review, place: Self.place, tab: TabRef(host: Self.place.host, key: "herdr:app:1"), host: "mba2",
                      branch: "dark-mode", offline: offline, push: pushed)
    }

    private func sampleReview(comments: Bool = true) -> MobileReview {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ReviewMemoryStore(comments ? [Self.place.scope: Review(comments: ReviewSample.comments(now: now), modified: now)] : [:])
        let review = MobileReview(repository: ReviewRepository(store: store), clock: { now })
        review.reader = { _ in ReviewSample.reader }
        return review
    }

    /// H2: the sample's sections and rows, each row one element with its status, counts and comments in this area; a
    /// tap pushes the change's diff.
    func testTheListShowsTheSectionsRowsAndBadges() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let review = sampleReview()
        var pushed: [FilesRoute] = []
        let (window, host) = try show(ReviewChangesScreen(context: context(review, pushed: { pushed.append($0) })))
        defer { window.isHidden = true }
        var labels: [String] = []
        try await TestSupport.eventually {
            labels = AccessibilityLabelTests.elements(in: host.view).compactMap(\.accessibilityLabel)
            return labels.contains { $0.hasPrefix("docs/theming.md") }
        }
        for row in ["src/theme.ts, Added, 31 added",
                    "src/components/ThemeToggle.tsx, Added, 48 added, 1 comment",
                    "src/components/Sidebar.tsx, Modified, 14 added, 6 deleted, 2 comments",
                    "src/main.tsx, Modified, 3 added, 1 deleted",
                    "tests/theme.test.ts, Untracked, 27 added",
                    "docs/theming.md, Untracked, 40 added"] {
            XCTAssertTrue(labels.contains(row), "\(row) in \(labels)")
        }
        for header in ["Staged", "Unstaged", "Untracked"] {
            XCTAssertTrue(labels.contains { $0.lowercased().hasPrefix(header.lowercased()) }, "\(header) in \(labels)")
        }
        let sidebar = try XCTUnwrap(AccessibilityLabelTests.elements(in: host.view).first { $0.accessibilityLabel?.hasPrefix("src/components/Sidebar.tsx") == true })
        XCTAssertTrue(sidebar.accessibilityActivate())
        try await TestSupport.eventually { !pushed.isEmpty }
        XCTAssertEqual(pushed.first, .review(GitChange(path: "src/components/Sidebar.tsx", kind: .modified, area: .unstaged)))
    }

    /// The bar: branch, files and counts, and search, which filters the list by path.
    func testTheBarSearchesByPath() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let review = sampleReview()
        let changes = review.changes(Self.place)
        await changes.refresh()
        let (window, host) = try show(ReviewBar(context: context(review)).padding(.horizontal, 16), height: 80)
        defer { window.isHidden = true }
        var elements: [NSObject] = []
        try await TestSupport.eventually {
            elements = AccessibilityLabelTests.elements(in: host.view)
            return elements.contains { $0.accessibilityLabel == "Search changes" }
        }
        let summary = elements.compactMap(\.accessibilityLabel).first { $0.contains("dark-mode") } ?? ""
        XCTAssertTrue(summary.contains("8 files"), summary)
        XCTAssertTrue(summary.contains("190 added, 18 deleted"), summary)
        XCTAssertTrue(try XCTUnwrap(elements.first { $0.accessibilityLabel == "Search changes" }).accessibilityActivate())
        try await TestSupport.eventually { changes.searching }
        changes.query = "theme"
        let matched = try XCTUnwrap(changes.status).matching(changes.query).changes.map(\.path)
        XCTAssertEqual(matched, ["src/theme.ts", "src/components/ThemeToggle.tsx", "tests/theme.test.ts"])
        try await TestSupport.eventually {
            AccessibilityLabelTests.elements(in: host.view).contains { $0.accessibilityLabel == "Close search" }
        }
    }

    /// The accessory: Create review with the comments and files (opens the sheet for the tab); after Send, "Sent to
    /// claude · 3 comments · Undo" (S4), or "Copied" when the review went to the clipboard.
    func testTheAccessoryCreatesAndShowsTheSentReview() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let review = sampleReview()
        let context = context(review)
        XCTAssertTrue(ReviewAccessory.shows(context))
        XCTAssertFalse(ReviewAccessory.shows(self.context(sampleReview(comments: false))))
        var (window, host) = try show(ReviewAccessory(context: context), height: 60)
        var elements: [NSObject] = []
        try await TestSupport.eventually {
            elements = AccessibilityLabelTests.elements(in: host.view)
            return elements.contains { $0.accessibilityLabel == "Create review" }
        }
        let create = try XCTUnwrap(elements.first { $0.accessibilityLabel == "Create review" })
        XCTAssertEqual(create.accessibilityValue, "3 comments on 2 files")
        XCTAssertTrue(create.accessibilityActivate())
        try await TestSupport.eventually { review.sheet == context.tab }
        window.isHidden = true

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for agent in ["claude", nil] as [String?] {
            review.sent[Self.place] = ReviewSent(id: UUID(), place: Self.place, agent: agent, comments: 3, files: 2, sent: now,
                                                 until: now.addingTimeInterval(60))
            (window, host) = try show(ReviewAccessory(context: context), height: 60)
            let title = agent.map { "Sent to \($0)" } ?? "Copied"
            try await TestSupport.eventually {
                let labels = AccessibilityLabelTests.elements(in: host.view).compactMap(\.accessibilityLabel)
                return labels.contains(title) && labels.contains("3 comments") && labels.contains("Undo")
            }
            window.isHidden = true
        }
    }

    private func show(_ view: some View, height: CGFloat = 900) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        let host = UIHostingController(rootView: view.background(Color.canvas))
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }
}

/// A status reader whose reads can be held, failed, and counted.
private final class ScriptedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var forgets = 0
    private var held = false
    private var failure: ReviewGitError?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var reads: Int { lock.withLock { count } }
    var forgot: Int { lock.withLock { forgets } }
    var pending: Int { lock.withLock { waiting.count } }
    var hold: Bool {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
    var fail: ReviewGitError? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var reader: ReviewGitReader {
        ReviewGitReader(status: { _ in try await self.read() }, diff: { _, change in ReviewSample.diff(change) },
                        text: { _ in nil }, forget: { _ in self.lock.withLock { self.forgets += 1 } })
    }

    func release() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }

    private func read() async throws -> GitStatus {
        let hold = lock.withLock { count += 1; return held }
        if hold { await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } } }
        if let failure = fail { throw failure }
        return ReviewSample.status(now: Date(timeIntervalSince1970: 0))
    }
}

/// A sleep that ends when the test steps it.
private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var pending: Int { lock.withLock { waiting.count } }

    func sleep() async {
        await withCheckedContinuation { continuation in lock.withLock { waiting.append(continuation) } }
    }

    func step() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }
}
