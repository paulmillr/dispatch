import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The Changes tab as its mockup draws it, hosted in `FilesView` (its header line shares the
/// files header's row) with a fake source and the status and diff the git data layer would leave in the session, read
/// back by OCR and accessibility. Desktop cases: they open windows.
@MainActor
final class GitChangesPresentationTests: XCTestCase {
    private let root = "/Users/ivan/src/api"
    private let billingID = "unstaged:src/routes/billing.ts"

    /// `git diff -- src/routes/billing.ts` (-U3, recorded from real git) in the mockup's spirit: +8 −5 over three
    /// hunks with unmodified lines left out between them (3, then 4), the second hunk holding a run of five
    /// unmodified lines between its changes (three of them fold).
    static let billingDiff = """
        diff --git a/src/routes/billing.ts b/src/routes/billing.ts
        index 38a20787..02dde1d4 100644
        --- a/src/routes/billing.ts
        +++ b/src/routes/billing.ts
        @@ -1,4 +1,5 @@
         import { stripe } from '../lib/stripe'
        +import { db } from '../lib/db'
         import type { WebhookEvent } from '../types'
         
         const RETRIES = 3
        @@ -8,14 +9,16 @@ const REGION = 'eu'
         // Stripe calls this for every event on the account.
         export async function handleWebhook(raw: string, signature: string) {
           const event = stripe.webhooks.constructEvent(raw, signature, process.env.STRIPE_SECRET!)
        -  const attempt = Number(event.request?.idempotency_key ?? 0)
        -  if (attempt > 0) return { status: 200, body: 'retry' }
        +  // Stripe retries with a new attempt counter; key on the event id instead.
        +  const seen = await db.find('webhook_seen', event.id)
        +  if (seen) return { status: 200, body: 'duplicate' }
        +  await db.put('webhook_seen', event.id, { at: Date.now() })
           switch (event.type) {
             case 'invoice.paid':
               await markPaid(event.data.object as WebhookEvent['invoice'])
               break
             case 'invoice.failed':
        -      await markFailed(event.data.object as WebhookEvent['invoice'])
        +      await markFailed(event.data.object as WebhookEvent['invoice'], { retry: false })
               break
             case 'customer.created':
               await welcome(event.data.object as WebhookEvent['customer'])
        @@ -26,6 +29,6 @@ export async function handleWebhook(raw: string, signature: string) {
             default:
               break
           }
        -  metrics.increment('webhook')
        -  return { status: 200 }
        +  metrics.increment('webhook.ok')
        +  return { status: 200, body: 'ok' }
         }

        """

    /// The F3a status: chat.ts staged, billing.ts and db.ts unstaged, the idempotency test untracked.
    static func mockupStatus() -> GitStatus {
        GitStatus(branch: "main", head: "3f2c1a0", upstream: "origin/main", changes: [
            GitChange(path: "src/routes/chat.ts", kind: .modified, area: .staged, additions: 3, deletions: 0),
            GitChange(path: "src/routes/billing.ts", kind: .modified, area: .unstaged, additions: 8, deletions: 5),
            GitChange(path: "src/lib/db.ts", kind: .modified, area: .unstaged, additions: 1, deletions: 0),
            GitChange(path: "tests/idempotency.test.ts", kind: .untracked, area: .untracked, additions: 14, deletions: 0),
        ], loadedAt: Date(timeIntervalSince1970: 1_760_700_000))
    }

    private func mockupSession() -> FilesSession {
        let source = FakeFilesSource.mockupAPI()
        let session = FilesSession(id: System.uuid())
        session.home = source.home
        session.availability = .available(source)
        session.pinnedRoot = root
        session.tab = .changes
        session.git = .repository(GitRepository(root: root))
        session.status = Self.mockupStatus()
        session.changesSelection = billingID
        session.changesDiff = GitDiffState(key: billingID, diff: GitDiff(path: "src/routes/billing.ts", text: Self.billingDiff))
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

    /// Waits until OCR reads each text (or one of its variants), then returns the snapshot that did.
    @discardableResult
    private func read(_ texts: [[String]], in window: NSWindow, named name: String,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> PresentationTestSupport.Snapshot {
        var snapshot: PresentationTestSupport.Snapshot?
        var missing: [String] = []
        try await TestSupport.eventually(timeout: .seconds(20), file: file, line: line,
                                         diagnostic: "OCR did not read \(missing): \((try? snapshot?.text()) ?? "")") {
            let capture = try await PresentationTestSupport.capture(window, named: name, in: "files-audit",
                                                                     published: snapshot != nil)
            snapshot = capture
            missing = try texts.filter { try !capture.reads($0) }.map { $0[0] }
            return missing.isEmpty
        }
        return try XCTUnwrap(snapshot, file: file, line: line)
    }

    private func frame(_ identifier: String, in window: NSWindow, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> NSRect {
        var found: NSRect?
        try await TestSupport.eventually(file: file, line: line, diagnostic: "No \(identifier) on screen") {
            found = PresentationTestSupport.accessibilityFrames(identifier, in: window).first
            return found != nil
        }
        return try XCTUnwrap(found, file: file, line: line)
    }

    /// Clicks `identifier` until `done` holds. The test VM's desktop sometimes drops a synthesized click on a SwiftUI
    /// button in a window that is not frontmost; every click here is idempotent, so another is safe.
    private func click(_ identifier: String, in window: NSWindow, until done: @escaping @MainActor () -> Bool,
                       diagnostic: @escaping @MainActor () -> String = { "" },
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(timeout: .seconds(10), file: file, line: line,
                                         diagnostic: "\(identifier) clicked without effect. \(diagnostic())") {
            if done() { return true }
            guard let frame = PresentationTestSupport.accessibilityFrames(identifier, in: window).first else { return false }
            try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: frame.midX, y: frame.midY))
            return done()
        }
    }

    /// The colour at `point`, moved inside the window and clear of its scrollers: rows run as wide as the widest line.
    private func color(at point: NSPoint, in snapshot: PresentationTestSupport.Snapshot, window: NSWindow) throws -> NSColor {
        let bounds = try XCTUnwrap(window.contentView).bounds
        let point = NSPoint(x: min(point.x, bounds.maxX - 30), y: point.y)
        let scale = CGFloat(snapshot.bitmap.pixelsHigh) / bounds.height
        return try XCTUnwrap(snapshot.bitmap.colorAt(x: Int(point.x * scale), y: Int((bounds.height - point.y) * scale))?
            .usingColorSpace(.sRGB))
    }

    // MARK: Cases

    func testMockupShowsHeaderGroupsDiffAndFooter() async throws {
        let session = mockupSession()
        let window = try window(session)
        // OCR reads the middle dot as "•", "-" or nothing, "−" as "-", and "handleWebhook" now and then lowercase.
        let snapshot = try await read([
            ["main"], ["1 staged"], ["2 unstaged"], ["1 untracked"], ["~/src/api"], ["+26"],
            ["Staged"], ["Unstaged"], ["Untracked"],
            ["chat.ts"], ["billing.ts"], ["db.ts"], ["idempotency.test.ts"], ["src/routes"], ["+14"],
            ["src/routes/billing.ts"], ["unstaged · +8 −5 · 3 hunks", "unstaged • +8 -5 • 3 hunks", "+8 -5", "+8 −5"],
            ["Diff"], ["Source"],
            ["@@ -8,14 +9,16 @@", "-8,14 +9,16"], ["export async function handleWebhook", "handleWebhook", "handlewebhook"],
            // F3a's rows between hunks, from the hunks' numbers, and the fold inside the second hunk.
            ["3 unmodified lines"], ["4 unmodified lines"],
            ["Read-only · stage and commit in the shell", "Read-only • stage and commit in the shell",
             "stage and commit in the shell"],
            ["git add -p"],
        ], in: window, named: "git-changes-mockup")

        // The line shares the files header's 34 pt row, after the segments; the list starts right under it.
        let header = try await frame("files-header", in: window)
        let line = try await frame("git-changes-header-line", in: window)
        let commits = try await frame("files-segment-commits", in: window)
        let list = try await frame("git-changes-list", in: window)
        XCTAssertEqual(header.height, 34, accuracy: 0.5)
        XCTAssertEqual(line.midY, header.midY, accuracy: 1)
        XCTAssertGreaterThan(line.minX, commits.maxX)
        XCTAssertEqual(list.maxY, header.minY, accuracy: 1.5, "no second bar between the header and the list")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-filter", in: window).isEmpty,
                      "the list's filter is the Files tab's")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).isEmpty,
                      "the preview toggle is the Files tab's")

        // The badges: amber M on the modified rows, green U on the untracked one.
        let labels = PresentationTestSupport.accessibilityLabels("git-change-untracked-tests/idempotency.test.ts", in: window)
        XCTAssertTrue(labels.contains { $0.contains("Untracked") && $0.contains("idempotency.test.ts") }, "\(labels)")
        XCTAssertTrue(PresentationTestSupport.accessibilityLabels("git-change-unstaged-src/routes/billing.ts", in: window)
            .contains { $0.contains("Modified") })

        // The hunk header's wash is blue, an added line's green, a removed line's red.
        let hunk = try await frame("git-diff-hunk-1", in: window)
        let wash = try color(at: NSPoint(x: hunk.maxX - 4, y: hunk.midY), in: snapshot, window: window)
        XCTAssertGreaterThan(wash.blueComponent, wash.redComponent + 0.02, "Hunk header wash \(wash)")
        let added = try await frame("git-diff-line-1", in: window)
        let green = try color(at: NSPoint(x: added.maxX - 4, y: added.midY), in: snapshot, window: window)
        XCTAssertGreaterThan(green.greenComponent, green.redComponent + 0.02, "Added line tint \(green)")
        let removed = try await frame("git-diff-line-8", in: window)
        let red = try color(at: NSPoint(x: removed.maxX - 4, y: removed.midY), in: snapshot, window: window)
        XCTAssertGreaterThan(red.redComponent, red.greenComponent + 0.02, "Removed line tint \(red)")

        // 12.5 pt code on 20 pt rows, two gutters numbering both sides. Two unmodified rows: a combined element's frame
        // is its children's union, and an added row's empty old number draws no frame of its own.
        let first = try await frame("git-diff-line-2", in: window), second = try await frame("git-diff-line-3", in: window)
        XCTAssertEqual(first.minY - second.minY, 20, accuracy: 0.5)
        XCTAssertTrue(PresentationTestSupport.accessibilityLabels("git-diff-line-8", in: window)
            .contains { $0.contains("11") && $0.contains("const attempt") }, "The removed line carries its old number")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("git-diff-gap-1", in: window).isEmpty)
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("git-diff-gap-2", in: window).isEmpty)
    }

    func testNarrowHeaderKeepsTheLineBesideGlyphSegments() async throws {
        let session = mockupSession()
        let inset: CGFloat = 70
        let window = try window(session, inset: inset)
        try await read([["~/src/api"], ["+26"]], in: window, named: "git-changes-header-wide")
        let wide = try await frame("files-segment-changes", in: window)
        for width: CGFloat in [600, 480, 360] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await TestSupport.eventually(diagnostic: "the header did not settle at \(width) pt") {
                window.contentView?.layoutSubtreeIfNeeded()
                let commits = PresentationTestSupport.accessibilityFrames("files-segment-commits", in: window).first
                let totals = PresentationTestSupport.accessibilityFrames("git-changes-totals", in: window).first
                return commits.flatMap { commits in totals.map { commits.maxX < $0.minX } } ?? false
            }
            if width == 360 {
                // At last the segments drop their names (the line has clipped all it can).
                let narrow = try await frame("files-segment-changes", in: window)
                XCTAssertLessThan(narrow.width, wide.width - 20, "the segments kept their names at \(width) pt")
            }
            let files = try await frame("files-segment-files", in: window)
            let commits = try await frame("files-segment-commits", in: window)
            let totals = try await frame("git-changes-totals", in: window)
            XCTAssertGreaterThanOrEqual(files.minX, 11.5, "nothing spills past the leading edge at \(width) pt")
            XCTAssertLessThan(commits.maxX, totals.minX, "at \(width) pt")
            XCTAssertLessThanOrEqual(totals.maxX, width - 12 - inset + 0.5, "the totals stay out of the switch's room at \(width) pt")
            // Narrowed to glyphs, the segment keeps its name for VoiceOver and its count in sight.
            XCTAssertTrue(PresentationTestSupport.accessibilityLabels("files-segment-changes", in: window).contains("Changes 4"))
        }
        try await read([["+26"]], in: window, named: "git-changes-header-narrow")
    }

    func testClickingARowSelectsItAndArrowsMoveTheSelection() async throws {
        let session = mockupSession()
        let window = try window(session)
        try await click("git-change-staged-src/routes/chat.ts", in: window,
                        until: { session.changesSelection == "staged:src/routes/chat.ts" },
                        diagnostic: { "Selected \(String(describing: session.changesSelection))" })
        // No data layer here: the old diff is not shown for the new selection.
        try await TestSupport.eventually {
            PresentationTestSupport.accessibilityFrames("git-diff-path", in: window).isEmpty
        }

        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil,
                                                  characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                  isARepeat: false, keyCode: 125))
        window.sendEvent(down)
        try await TestSupport.eventually(diagnostic: "After ↓: \(String(describing: session.changesSelection))") {
            session.changesSelection == self.billingID
        }
    }

    func testFoldOpensOnClick() async throws {
        let session = mockupSession()
        let window = try window(session)
        // Five unmodified lines between the second hunk's changes: one stays beside each change, three fold.
        let presentation = GitDiffPresentation.parse(Self.billingDiff)
        let fold = try XCTUnwrap(presentation.folds.first)
        XCTAssertEqual(fold.count, 3)
        _ = try await frame("git-diff-fold-\(fold.start)", in: window)
        try await click("git-diff-fold-\(fold.start)", in: window, until: {
            PresentationTestSupport.accessibilityFrames("git-diff-fold-\(fold.start)", in: window).isEmpty
                && !PresentationTestSupport.accessibilityFrames("git-diff-line-\(fold.start + 2)", in: window).isEmpty
        })
        try await read([["markPaid"]], in: window, named: "git-changes-fold-open")
    }

    func testGapBetweenHunksFillsFromTheWorkingTree() async throws {
        let session = mockupSession()
        let window = try window(session)
        // New lines 6–8 lie between the first two hunks; opening the row reads the file through the tab's source.
        try await read([["3 unmodified lines"]], in: window, named: "git-changes-gap")
        try await click("git-diff-gap-1", in: window, until: {
            !PresentationTestSupport.accessibilityFrames("git-diff-gap-line-6", in: window).isEmpty
        })
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-diff-gap-1", in: window).isEmpty)
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("git-diff-gap-line-8", in: window).isEmpty)
        // The fake tree's billing.ts is one export repeated: its lines fill the gap, numbered 5–7 on the old side.
        let gapLine = PresentationTestSupport.accessibilityLabels("git-diff-gap-line-6", in: window)
        XCTAssertTrue(gapLine.contains { $0.contains("5") && $0.contains("export const billing") }, "\(gapLine)")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("git-diff-gap-2", in: window).isEmpty,
                       "the other gap stays closed")
        XCTAssertEqual(session.diffMode, .diff, "filling a gap stays in Diff")
    }

    func testResolvingAnotherFolderShowsASpinnerNotTheLastStatus() async throws {
        let session = mockupSession()
        let window = try window(session)
        _ = try await frame("git-changes-list", in: window)
        session.gitResolving = true
        try await TestSupport.eventually(diagnostic: "the last status still shows") {
            PresentationTestSupport.accessibilityFrames("git-changes-list", in: window).isEmpty
                && PresentationTestSupport.accessibilityFrames("git-diff", in: window).isEmpty
        }
        let snapshot = try await read([["Changes"]], in: window, named: "git-changes-resolving")
        XCTAssertFalse(try snapshot.reads(["idempotency.test.ts"]), "no stale rows while the repository resolves")
        session.gitResolving = false
        _ = try await frame("git-changes-list", in: window)
    }

    func testSourceShowsTheWorkingTreeFile() async throws {
        let session = mockupSession()
        let window = try window(session)
        try await click("git-diff-mode-source", in: window, until: { session.diffMode == .source })
        // The fake tree's billing.ts: 150 lines of one export, numbered in a single gutter.
        try await TestSupport.eventually(diagnostic: "No source line 1") {
            !PresentationTestSupport.accessibilityFrames("git-diff-source-line-1", in: window).isEmpty
        }
        try await read([["export const billing = 1"]], in: window, named: "git-changes-source")
    }

    func testEmptyStatusSaysTheTreeMatchesHEAD() async throws {
        let session = mockupSession()
        // What the git loader leaves after an empty status: nothing selected, no diff (`GitChangesText.reconciled`).
        session.status = GitStatus(branch: "main", head: "3f2c1a0", changes: [], loadedAt: Date(timeIntervalSince1970: 0))
        session.changesSelection = nil
        session.changesDiff = nil
        let window = try window(session)
        // OCR reads the UI font's dotted zero as "O".
        try await read([["No changes"], ["the working tree matches HEAD"], ["0 staged", "O staged"]], in: window,
                       named: "git-changes-empty")
        XCTAssertTrue(PresentationTestSupport.accessibilityLabels("git-changes-count-staged", in: window).contains("0 staged"))
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("git-diff", in: window).isEmpty, "No diff for no change")
    }

    func testAddPatchWithoutATerminalSaysSo() async throws {
        let session = mockupSession()
        let window = try window(session)
        try await click("git-add-patch", in: window, until: {
            PresentationTestSupport.accessibilityLabels("git-changes-notice", in: window).contains("The terminal isn’t running")
        }, diagnostic: {
            "Notice \(PresentationTestSupport.accessibilityLabels("git-changes-notice", in: window)), "
                + "posted \(String(describing: FilesEditorNotices.shared.notice(for: session.id)))"
        })
        XCTAssertTrue(session.tab == .changes, "Nothing was typed, so the tab stays")
        FilesEditorNotices.shared.clear(session.id)
    }

    func testBinaryAndTruncatedDiffs() async throws {
        let session = mockupSession()
        session.status?.changes.append(GitChange(path: "assets/logo.png", kind: .modified, area: .unstaged, binary: true,
                                                 oldSize: 48_000, newSize: 51_000))
        session.status?.truncated = true
        let window = try window(session)
        // The row says its sizes before it is selected, and the header says the status was cut.
        try await TestSupport.eventually(diagnostic: "\(PresentationTestSupport.accessibilityLabels("git-change-unstaged-assets/logo.png", in: window))") {
            PresentationTestSupport.accessibilityLabels("git-change-unstaged-assets/logo.png", in: window)
                .contains { $0.contains("48 KB → 51 KB") }
        }
        try await read([["showing the first 5"]], in: window, named: "git-changes-status-truncated")

        session.changesSelection = "unstaged:assets/logo.png"
        session.changesDiff = GitDiffState(key: "unstaged:assets/logo.png", diff: GitDiff(
            path: "assets/logo.png", text: "Binary files a/assets/logo.png and b/assets/logo.png differ\n", binary: true,
            oldSize: 48_000, newSize: 51_000))
        try await read([["binary · 48 KB → 51 KB", "binary • 48 KB → 51 KB", "48 KB → 51 KB", "48 KB - 51 KB"]],
                       in: window, named: "git-changes-binary")

        session.changesSelection = billingID
        // Cut at a line end inside the second hunk, as the helper's bound cuts it.
        let cut = Self.billingDiff.components(separatedBy: "\n").prefix(14).joined(separator: "\n") + "\n"
        session.changesDiff = GitDiffState(key: billingID, diff: GitDiff(path: "src/routes/billing.ts", text: cut,
                                                                         truncated: true))
        try await read([["Output cut at the helper’s bound", "Output cut at the helper's bound", "Output cut at the helper"]],
                       in: window, named: "git-changes-truncated")
    }
}
