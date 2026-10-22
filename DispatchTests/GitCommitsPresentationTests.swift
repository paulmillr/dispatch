import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The Commits tab as its mockup draws it, hosted in `FilesView` (its header line shares the files
/// header's row) over a fake source with the mockup's log, status and detail set directly (the git data layer is not
/// under test): read back by OCR and accessibility, then clicked and scrolled.
@MainActor
final class GitCommitsPresentationTests: XCTestCase {
    /// The clock's now when the case starts (XCTest makes every case's instance before the run): the rows and the
    /// detail read their ages from the clock as they draw.
    private lazy var now = System.date()

    private func hash(_ short: String) -> String { short + String(repeating: "0", count: 40 - short.count) }

    private func commit(_ short: String, _ subject: String, parents: [String], ago: TimeInterval, refs: [GitRef] = [],
                        body: String = "") -> GitCommit {
        GitCommit(hash: hash(short), parents: parents.map(hash), subject: subject, body: body, author: "Sam Example",
                  email: "sam@example.com", date: now.addingTimeInterval(-ago), refs: refs)
    }

    /// F4a's log: main with a merged two-commit branch, origin/main two behind, a tag further down.
    private var mockupCommits: [GitCommit] {
        let minute: TimeInterval = 60, hour: TimeInterval = 3_600, day: TimeInterval = 86_400
        return [
            commit("c28855c", "Make webhook retries idempotent", parents: ["b17e2a4"], ago: 35 * minute,
                   refs: [GitRef(name: "main", kind: .branch, current: true)],
                   body: "Stripe retries the same event with a new attempt counter, so a counter-based guard double-processes. Key on the event id instead and remember it for a day."),
            commit("b17e2a4", "Keep the retry queue bounded", parents: ["a93f0d1"], ago: 50 * minute),
            commit("a93f0d1", "Merge branch 'feat/webhook-signatures'", parents: ["9d0c3b2", "8e21f47"], ago: 3 * hour,
                   refs: [GitRef(name: "origin/main", kind: .remote, current: false)]),
            commit("8e21f47", "Verify webhook signatures before parsing", parents: ["6b5a9e3"], ago: 4 * hour,
                   refs: [GitRef(name: "feat/webhook-signatures", kind: .branch, current: false)]),
            commit("9d0c3b2", "Bump stripe to 14.2", parents: ["5f4c2d8"], ago: 5 * hour),
            commit("6b5a9e3", "Add the raw-body middleware", parents: ["5f4c2d8"], ago: 7 * hour),
            commit("5f4c2d8", "Reorganize routes by domain", parents: ["4a3b1c7"], ago: day),
            commit("4a3b1c7", "Use pnpm 9 in CI", parents: ["3c2d9e6"], ago: 2 * day,
                   refs: [GitRef(name: "v2.4.0", kind: .tag, current: false)]),
            commit("3c2d9e6", "Show plan limits on the usage card", parents: ["2b1e8f5"], ago: 2 * day + hour),
            commit("2b1e8f5", "Note 2.4.0 changes in CHANGELOG", parents: ["1a9f7d4"], ago: 4 * day),
            commit("1a9f7d4", "Initial billing route", parents: [], ago: 6 * day),
        ]
    }

    private func mockupSession() -> FilesSession {
        let source = FakeFilesSource.mockupAPI()
        let session = FilesSession(id: System.uuid())
        session.home = source.home
        session.availability = .available(source)
        session.git = .repository(GitRepository(root: "/Users/ivan/src/api"))
        session.tab = .commits
        session.status = GitStatus(branch: "main", head: "c28855c", upstream: "origin/main", ahead: 2, changes: [
            GitChange(path: "src/routes/chat.ts", kind: .modified, area: .staged, additions: 3, deletions: 0),
            GitChange(path: "src/routes/billing.ts", kind: .modified, area: .unstaged, additions: 8, deletions: 5),
            GitChange(path: "src/lib/db.ts", kind: .modified, area: .unstaged, additions: 1, deletions: 0),
            GitChange(path: "tests/idempotency.test.ts", kind: .untracked, area: .untracked, additions: 14, deletions: 0),
        ], loadedAt: now)
        let commits = mockupCommits
        session.logScope = .all
        session.log = GitLog(commits: commits, exhausted: true, scope: .all, filter: "", loadedAt: now)
        session.selectedCommit = commits[0].hash
        session.commitDetail = GitCommitDetail(commit: commits[0], files: [
            GitChange(path: "src/routes/billing.ts", kind: .modified, area: .staged, additions: 8, deletions: 5),
            GitChange(path: "src/lib/db.ts", kind: .modified, area: .staged, additions: 3, deletions: 0),
            GitChange(path: "CHANGELOG.md", kind: .modified, area: .staged, additions: 1, deletions: 0),
        ])
        return session
    }

    /// `inset`: room the floating mode switch takes at the header's trailing end, as `TerminalContentView` leaves it.
    private func window(_ session: FilesSession, width: CGFloat = 1180, inset: CGFloat = 0) throws -> NSWindow {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FilesView(session: session)
            .environment(\.filesHeaderTrailingInset, inset)
            .environment(\.appTypography, AppTypography())
            .preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
        }
        return window
    }

    /// Waits until OCR reads every text.
    private func read(_ texts: [String], in window: NSWindow, named name: String,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        var snapshot: PresentationTestSupport.Snapshot?
        try await TestSupport.eventually(timeout: .seconds(20), file: file, line: line,
                                         diagnostic: "OCR did not read \(texts): \((try? snapshot?.text()) ?? "")") {
            let capture = try await PresentationTestSupport.capture(window, named: name, in: "files-audit")
            snapshot = capture
            return try texts.allSatisfy { try capture.reads([$0]) }
        }
    }

    /// Waits until the element with `identifier` says `label` (the text as drawn, which OCR may misread).
    private func says(_ label: String, _ identifier: String, in window: NSWindow,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic:
            "\(identifier) said \(PresentationTestSupport.accessibilityLabels(identifier, in: window)), not \(label)") {
            PresentationTestSupport.accessibilityLabels(identifier, in: window).contains { $0.contains(label) }
        }
    }

    private func frame(_ identifier: String, in window: NSWindow, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> NSRect {
        var frames: [NSRect] = []
        try await TestSupport.eventually(file: file, line: line, diagnostic: "No element \(identifier)") {
            frames = PresentationTestSupport.accessibilityFrames(identifier, in: window)
            return !frames.isEmpty
        }
        return try XCTUnwrap(frames.first, file: file, line: line)
    }

    private func centre(of identifier: String, in window: NSWindow, file: StaticString = #filePath,
                        line: UInt = #line) async throws -> NSPoint {
        let frame = try await frame(identifier, in: window, file: file, line: line)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    /// Clicks the element once as a user does (the pointer moved over it first), then waits for `done`.
    private func click(_ identifier: String, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line,
                       until done: @escaping @MainActor () -> Bool) async throws {
        let point = try await centre(of: identifier, in: window, file: file, line: line)
        try await PresentationTestSupport.hoverAndClick(window, at: point)
        try await TestSupport.eventually(file: file, line: line, diagnostic: "Clicking \(identifier) at \(point) did nothing") {
            done()
        }
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    func testMockupHeaderRowsAndDetail() async throws {
        let session = mockupSession()
        let window = try window(session)
        // OCR reads "↑2" as "12": the chip's label below says it.
        try await read(["api", "main", "All branches"], in: window, named: "git-commits-header")
        try await read(["Uncommitted changes", "4 files", "Keep the retry queue bounded", "Bump stripe to 14.2",
                        "Initial billing route", "feat/webhook-signatures", "v2.4.0"], in: window, named: "git-commits-rows")
        try await read(["CHANGED FILES", "src/routes/billing.ts", "CHANGELOG.md", "Sam Example", "35 min ago"],
                       in: window, named: "git-commit-detail")
        try await says("Make webhook retries idempotent", "git-commit-subject", in: window)
        try await says("c28855c", "git-commit-hash", in: window)
        try await says("api · main · 2 ahead of origin/main", "files-location", in: window)
        try await says("11 loaded · all", "git-commits-footer-summary", in: window)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-commit-show", in: window).isEmpty, "no git show")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-diff-copy", in: window).isEmpty, "no copy button")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-commit-committer", in: window).isEmpty,
                      "the author committed it")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("git-commit-file-src/lib/db.ts", in: window).isEmpty)
        // The commit opens on its first file, as the mockup shows it.
        XCTAssertEqual(session.commitFile, "src/routes/billing.ts")

        // The files header's 34 pt row as on every tab: the repository and its branch, the search and the details'
        // toggle, then the tabs at the trailing end; the list starts right under it, and the scope menu sits in its footer.
        let header = try await frame("files-header", in: window)
        let segment = try await frame("files-segment-commits", in: window)
        let crumbs = try await frame("files-location", in: window)
        let scope = try await frame("git-log-scope", in: window)
        let footer = try await frame("git-commits-footer", in: window)
        let search = try await frame("files-search", in: window)
        let toggle = try await frame("files-preview-toggle", in: window)
        let list = try await frame("git-commits-list", in: window)
        XCTAssertEqual(header.height, 34, accuracy: 0.5)
        XCTAssertLessThan(crumbs.maxX, search.minX)
        XCTAssertLessThanOrEqual(search.maxX, toggle.minX)
        XCTAssertEqual(scope.midY, footer.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(scope.maxX, footer.maxX)
        XCTAssertLessThanOrEqual(toggle.maxX, segment.minX)
        XCTAssertGreaterThan(segment.maxX, header.maxX - 12 - 40, "the tabs sit at the trailing end")
        XCTAssertEqual(list.maxY, header.minY, accuracy: 1.5, "no second bar between the header and the list")
        XCTAssertTrue(PresentationTestSupport.accessibilityLabels("files-preview-toggle", in: window).contains("Hide details"))

        // The search opens from its glyph.
        session.logFilter = "sam"
        _ = try await frame("git-commits-filter", in: window)
    }

    func testNarrowHeaderKeepsTheControlsBesideGlyphSegments() async throws {
        let session = mockupSession()
        let inset: CGFloat = 70
        let window = try window(session, inset: inset)
        try await read(["All branches"], in: window, named: "git-commits-header-wide")
        let wide = try await frame("files-segment-commits", in: window)
        for width: CGFloat in [600, 480, 360] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await TestSupport.eventually(diagnostic: "the header did not settle at \(width) pt") {
                window.contentView?.layoutSubtreeIfNeeded()
                let files = PresentationTestSupport.accessibilityFrames("files-segment-files", in: window).first
                let filter = PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first
                return files.flatMap { files in filter.map { $0.maxX < files.minX } } ?? false
            }
            if width == 360 {
                // At last the segments drop their names (the line has clipped all it can).
                let narrow = try await frame("files-segment-commits", in: window)
                XCTAssertLessThan(narrow.width, wide.width - 20, "the segments kept their names at \(width) pt")
            }
            let files = try await frame("files-segment-files", in: window)
            let commits = try await frame("files-segment-commits", in: window)
            let filter = try await frame("files-preview-toggle", in: window)
            let place = try await frame("files-location", in: window)
            XCTAssertGreaterThanOrEqual(place.minX, 11.5, "nothing spills past the leading edge at \(width) pt")
            XCTAssertLessThan(filter.maxX, files.minX, "at \(width) pt")
            XCTAssertLessThanOrEqual(commits.maxX, width - 12 - inset + 0.5, "the tabs stay out of the switch's room at \(width) pt")
        }
        _ = try await PresentationTestSupport.capture(window, named: "git-commits-header-narrow", in: "files-audit")
    }

    func testClickingARowSelectsItAndTheUncommittedRowOpensChanges() async throws {
        let session = mockupSession()
        let window = try window(session)
        let bump = mockupCommits[4]
        try await click("git-commit-\(bump.short)", in: window) { session.selectedCommit == bump.hash }
        XCTAssertNil(session.commitFile, "the old commit's file is dropped until the new detail arrives")
        // The detail shows the log's row at once; its files wait for the data layer.
        try await says("Bump stripe to 14.2", "git-commit-subject", in: window)
        try await read(["Loading files"], in: window, named: "git-commit-loading-files")
        session.commitDetail = GitCommitDetail(commit: bump, files: [
            GitChange(path: "package.json", kind: .modified, area: .staged, additions: 1, deletions: 1),
        ])
        try await TestSupport.eventually { session.commitFile == "package.json" }

        // The uncommitted row opens the Review tab; the commit stays picked for when Commits shows again.
        try await click("git-commits-uncommitted", in: window) { session.tab == .changes }
        XCTAssertEqual(session.selectedCommit, bump.hash)
    }

    /// Under 600 pt there is one column: a chosen commit's detail takes the log's place under a bar back to it.
    func testANarrowViewShowsAChosenRowsDetailInTheLogsPlace() async throws {
        let session = mockupSession()
        session.selectedCommit = nil
        session.commitDetail = nil
        let window = try window(session, width: 360)
        let bump = mockupCommits[4]
        try await click("git-commit-\(bump.short)", in: window) { session.selectedCommit == bump.hash }
        XCTAssertTrue(session.narrowDetail)
        try await says("Bump stripe to 14.2", "git-commit-subject", in: window)
        let back = try await frame("files-split-back", in: window)
        let subject = try await frame("git-commit-subject", in: window)
        XCTAssertGreaterThan(back.minY, subject.maxY, "the bar back sits over the detail")
        XCTAssertLessThan(subject.minX, 60, "the detail takes the whole width")
        try await click("files-split-back", in: window) { !session.narrowDetail }
        try await TestSupport.eventually { PresentationTestSupport.accessibilityFrames("files-split-back", in: window).isEmpty }
        _ = try await frame("git-commit-\(bump.short)", in: window)
    }

    func testADiffShowsOnlyUnderItsCommitAndPath() async throws {
        let session = mockupSession()
        let head = mockupCommits[0], other = mockupCommits[1]
        let text = "diff --git a/src/lib/db.ts b/src/lib/db.ts\n--- a/src/lib/db.ts\n+++ b/src/lib/db.ts\n@@ -1 +1 @@\n-a\n+b\n"
        // Another commit's diff of the same path is still in the slot: it is not shown as this one's.
        session.commitDiff = GitDiffState(key: GitCommitsText.diffKey(hash: other.hash, path: "src/routes/billing.ts"),
                                          diff: GitDiff(path: "src/routes/billing.ts", text: text))
        let window = try window(session)
        try await TestSupport.eventually { session.commitFile == "src/routes/billing.ts" }
        try await TestSupport.pause(for: .milliseconds(300))
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-diff", in: window).isEmpty,
                      "the other commit's diff showed")
        session.commitDiff = GitDiffState(key: GitCommitsText.diffKey(hash: head.hash, path: "src/routes/billing.ts"),
                                          diff: GitDiff(path: "src/routes/billing.ts", text: text))
        try await says("src/routes/billing.ts", "git-diff-path", in: window)
    }

    /// A signed commit's seal in the log, and its verdict under the selected commit's hash and author.
    func testSignedCommitsShowTheirSealAndTheSelectedVerdict() async throws {
        let session = mockupSession()
        let head = mockupCommits[0]
        session.log?.commits[0].signature = .gpg
        session.log?.commits[1].signature = .ssh
        let window = try window(session)
        try await says("Checking the GPG signature…", "git-commit-signature", in: window)
        session.signatureChecks[head.hash] = GitSignatureCheck(verdict: .good(certified: true), kind: .gpg,
                                                               signer: "Sam Example <sam@example.com>", key: "0123456789ABCDEF")
        try await says("Sam Example <sam@example.com> · GPG key ID: 0123456789ABCDEF", "git-commit-signature", in: window)
        try await read(["Sam Example", "Signed"], in: window, named: "git-commit-signature")
        // The seal sits beside the author, on the hash's line.
        let author = try await frame("git-commit-author", in: window)
        let seal = try await frame("git-commit-signature", in: window)
        XCTAssertEqual(seal.midY, author.midY, accuracy: 2)
        XCTAssertGreaterThan(seal.minX, author.maxX)
        // Each row reads as one element for VoiceOver, its seal's words among its own.
        let ssh = PresentationTestSupport.accessibilityLabels("git-commit-\(mockupCommits[1].short)", in: window)
        XCTAssertTrue(ssh.contains { $0.contains("Signed with SSH") }, "\(ssh)")
        let gpg = PresentationTestSupport.accessibilityLabels("git-commit-\(head.short)", in: window)
        XCTAssertTrue(gpg.contains { $0.contains("GPG key ID: 0123456789ABCDEF") }, "\(gpg)")
    }

    /// A commit someone else committed, or committed later than it was written, says so under the author.
    func testACommitterOtherThanTheAuthorShowsUnderTheAuthor() async throws {
        let session = mockupSession()
        let head = mockupCommits[0]
        session.log?.commits[0].committer = GitPerson(name: head.author, email: head.email, date: head.date, zone: "+0000")
        let window = try window(session)
        try await says("Make webhook retries idempotent", "git-commit-subject", in: window)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-commit-committer", in: window).isEmpty)
        session.log?.commits[0].committer = GitPerson(name: "Robin Example", email: "robin@example.com",
                                                      date: head.date.addingTimeInterval(20 * 60), zone: "+0200")
        try await says("Committed by Robin Example · 15 min ago", "git-commit-committer", in: window)
        try await read(["Committed by Robin Example"], in: window, named: "git-commit-committer")
    }

    /// Refs past their share of a narrow list fold into a count rather than crowding out the subject.
    func testManyRefsFoldIntoACount() async throws {
        let session = mockupSession()
        session.log?.commits[0].refs = [GitRef(name: "main", kind: .branch, current: true),
                                        GitRef(name: "origin/main", kind: .remote, current: false),
                                        GitRef(name: "origin/release-candidate-2026-10-18-main", kind: .remote, current: false),
                                        GitRef(name: "origin/feature-with-a-very-long-name", kind: .remote, current: false)]
        let window = try window(session)
        let head = "git-commit-\(mockupCommits[0].short)"
        try await TestSupport.eventually(diagnostic: "\(PresentationTestSupport.accessibilityLabels(head, in: window))") {
            PresentationTestSupport.accessibilityLabels(head, in: window).contains { $0.contains(" more: ") }
        }
        try await read(["Make webhook"], in: window, named: "git-commits-many-refs")
    }

    /// Source shows the whole file as the commit left it, not only the lines its diff holds: git's patch of the file
    /// with all of it as context.
    func testSourceShowsTheFileAsTheCommitLeftIt() async throws {
        let session = mockupSession()
        let source = try XCTUnwrap(session.source as? FakeFilesSource)
        let head = mockupCommits[0], path = "src/routes/billing.ts"
        let header = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n"
        let whole = (1...40).map { $0 == 30 ? "-old line\n+changed line 30\n" : " unchanged line \($0)\n" }.joined()
        source.gitAnswers["show --format= -U\(GitChangesText.sourceLimit) \(head.hash) -- \(path)"] =
            GitOutput(status: 0, output: header + "@@ -1,40 +1,40 @@\n" + whole, truncated: false)
        session.commitFile = path
        session.commitDiff = GitDiffState(key: GitCommitsText.diffKey(hash: head.hash, path: path), diff: GitDiff(
            path: path, text: header + "@@ -27,7 +27,7 @@\n unchanged line 27\n unchanged line 28\n unchanged line 29\n"
                + "-old line\n+changed line 30\n unchanged line 31\n unchanged line 32\n unchanged line 33\n"))
        let window = try window(session)
        try await click("git-diff-mode-source", in: window, until: { session.diffMode == .source })
        try await TestSupport.eventually(diagnostic: "Source shows only the diff's lines") {
            !PresentationTestSupport.accessibilityFrames("git-diff-source-line-1", in: window).isEmpty
        }
        try await read(["unchanged line 1", "unchanged line 2"], in: window, named: "git-commit-source")
    }

    func testDetailErrorOffersARetryInsteadOfLoading() async throws {
        let session = mockupSession()
        session.commitDetail = nil
        session.commitDetailError = "fatal: bad object c28855c"
        let window = try window(session)
        try await read(["fatal: bad object", "Try again"], in: window, named: "git-commit-detail-error")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-commit-files-loading", in: window).isEmpty)
        _ = try await frame("git-commit-files-retry", in: window)
        session.commitDetailError = nil
        try await read(["Loading files"], in: window, named: "git-commit-detail-loading")
    }

    func testResolvingAnotherFolderShowsASpinnerNotTheLastLog() async throws {
        let session = mockupSession()
        let window = try window(session)
        _ = try await frame("git-commits-list", in: window)
        session.gitResolving = true
        try await TestSupport.eventually(diagnostic: "the last log still shows") {
            PresentationTestSupport.accessibilityFrames("git-commits-list", in: window).isEmpty
                && PresentationTestSupport.accessibilityFrames("git-commit-detail", in: window).isEmpty
        }
        let snapshot = try await PresentationTestSupport.capture(window, named: "git-commits-resolving", in: "files-audit")
        XCTAssertFalse(try snapshot.reads(["Keep the retry queue bounded"]), "no stale rows while the repository resolves")
        session.gitResolving = false
        _ = try await frame("git-commits-list", in: window)
    }

    func testReturnUnderTheNarrowWidthKeepsTheKeyboardInTheList() async throws {
        let session = mockupSession()
        let window = try window(session, width: 560)
        _ = try await frame("git-commits-list", in: window)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-commit-detail", in: window).isEmpty,
                      "no detail under 600 pt")
        session.focusRequest = System.uuid()
        try await TestSupport.pause(for: .milliseconds(200))
        try key("\r", code: 36, in: window)
        try key("\u{F701}", code: 125, in: window)
        try await TestSupport.eventually(diagnostic: "↓ after ⏎ went nowhere: \(String(describing: session.selectedCommit))") {
            session.selectedCommit == self.mockupCommits[1].hash
        }
    }

    func testScrollingNearTheEndAsksForAnotherPage() async throws {
        let session = mockupSession()
        session.status = nil
        session.selectedCommit = nil
        session.commitDetail = nil
        func page(_ count: Int, exhausted: Bool) -> GitLog {
            var commits: [GitCommit] = []
            for index in 0..<count {
                let short = String(format: "%07x", index + 1), parent = String(format: "%07x", index + 2)
                let parents: [String] = index + 1 < count ? [parent] : []
                commits.append(commit(short, "Commit number \(index + 1)", parents: parents, ago: Double(index) * 600))
            }
            return GitLog(commits: commits, exhausted: exhausted, scope: .branch, filter: "", loadedAt: now)
        }
        session.logScope = .branch
        session.log = page(200, exhausted: false)
        session.logWanted = 200
        let window = try window(session)
        try await read(["Commit number 1", "scroll for more"], in: window, named: "git-commits-page")
        try await says("200 loaded · scroll for more", "git-commits-footer-summary", in: window)
        XCTAssertEqual(session.logWanted, 200, "the first rows ask for nothing")

        func scrollToEnd() throws {
            let root = try XCTUnwrap(window.contentView)
            root.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(PresentationTestSupport.views(of: NSScrollView.self, in: root).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            })
            let height = scroll.documentView?.frame.height ?? 0
            let bottom = max(0, height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.isFlipped ? bottom : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        try await TestSupport.eventually(diagnostic: "logWanted is \(session.logWanted)") {
            try scrollToEnd()
            return session.logWanted == 400
        }
        // Rows appearing again before the page arrives ask for nothing more.
        try scrollToEnd()
        try await TestSupport.pause(for: .milliseconds(300))
        XCTAssertEqual(session.logWanted, 400)

        session.log = page(400, exhausted: false)
        try await TestSupport.eventually(diagnostic: "logWanted is \(session.logWanted)") {
            try scrollToEnd()
            return session.logWanted == 600
        }
        session.log = page(450, exhausted: true)
        try await says("450 loaded · all", "git-commits-footer-summary", in: window)
        try scrollToEnd()
        try await TestSupport.pause(for: .milliseconds(300))
        XCTAssertEqual(session.logWanted, 600, "an exhausted log asks for nothing")
    }
}
