import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The Review tab's comments as the user writes them, hosted in `FilesView` over the Changes mockup (a fake source, the
/// status and diff the git data layer would leave in the session) with the comments in memory: the gutter's + opens
/// the composer, ⏎ saves, Create review copies the review and clears it, Undo brings it back. Desktop cases.
@MainActor
final class ReviewPresentationTests: XCTestCase {
    private let root = "/Users/ivan/src/api"
    private let billingID = "unstaged:src/routes/billing.ts"
    private var repository: ReviewRepository!

    override func setUp() async throws {
        repository = ReviewRepository(store: MemoryReviewStore())
        ReviewRepository.use(repository)
        addTeardownBlock { @MainActor in ReviewRepository.use(nil) }
    }

    private func mockupSession() -> FilesSession {
        let source = FakeFilesSource.mockupAPI()
        let session = FilesSession(id: System.uuid())
        session.home = source.home
        session.availability = .available(source)
        session.pinnedRoot = root
        session.tab = .changes
        session.git = .repository(GitRepository(root: root))
        session.status = GitChangesPresentationTests.mockupStatus()
        session.changesSelection = billingID
        session.changesDiff = GitDiffState(key: billingID, diff: GitDiff(path: "src/routes/billing.ts",
                                                                          text: GitChangesPresentationTests.billingDiff))
        return session
    }

    private func window(_ session: FilesSession) throws -> NSWindow {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FilesView(session: session)
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

    private func frame(_ identifier: String, in window: NSWindow, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> NSRect {
        var found: NSRect?
        try await TestSupport.eventually(file: file, line: line, diagnostic: "No \(identifier) on screen") {
            found = PresentationTestSupport.accessibilityFrames(identifier, in: window).first
            return found != nil
        }
        return try XCTUnwrap(found, file: file, line: line)
    }

    /// Clicks `point` (hovering first, so a + shown on hover is there) until `done` holds; every click here is
    /// idempotent.
    private func click(at point: @escaping @MainActor () -> NSPoint?, in window: NSWindow, until done: @escaping @MainActor () -> Bool,
                       diagnostic: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(timeout: .seconds(10), file: file, line: line, diagnostic: diagnostic) {
            if done() { return true }
            guard let point = point() else { return false }
            try await PresentationTestSupport.hoverAndClick(window, at: point)
            return done()
        }
    }

    private func click(_ identifier: String, in window: NSWindow, until done: @escaping @MainActor () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        try await click(at: {
            PresentationTestSupport.accessibilityFrames(identifier, in: window).first.map { NSPoint(x: $0.midX, y: $0.midY) }
        }, in: window, until: done, diagnostic: "\(identifier) clicked without effect", file: file, line: line)
    }

    /// Types `text` into the review editor that has the keyboard in `window`, then presses ⏎.
    private func type(_ text: String, in window: NSWindow) throws {
        let editor = try XCTUnwrap(window.firstResponder as? ReviewTextEditor.EditorView)
        editor.insertText(text, replacementRange: editor.selectedRange())
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(enter)
    }

    func testCommentOnALineThenCreateReviewCopiesItAndUndoBringsItBack() async throws {
        let session = mockupSession()
        let window = try window(session)
        let scope = try XCTUnwrap(session.reviewScope)
        let presentation = GitDiffPresentation.parse(GitChangesPresentationTests.billingDiff)
        let index = try XCTUnwrap(presentation.lines.firstIndex { $0.text.contains("const seen = await db.find") })
        let number = try XCTUnwrap(presentation.lines[index].new)

        // The + over the line's gutter shows on hover; a click opens the composer under the line.
        _ = try await frame("git-diff-line-\(index)", in: window)
        try await click(at: {
            PresentationTestSupport.accessibilityFrames("git-diff-line-\(index)", in: window).first
                .map { NSPoint(x: $0.minX + 11, y: $0.midY) }
        }, in: window, until: { session.reviewDraft != nil }, diagnostic: "no composer after the line's +")
        XCTAssertEqual(session.reviewDraft?.end, ReviewLine(side: .new, number: number))
        XCTAssertEqual(session.reviewDraft?.quote, [ReviewQuote(kind: .added, text: presentation.lines[index].text)])
        let composer = try await frame("review-composer", in: window)
        let line = try await frame("git-diff-line-\(index)", in: window)
        XCTAssertLessThan(composer.maxY, line.minY + 1, "the composer sits under its line")
        try await TestSupport.eventually(diagnostic: "the composer's editor has no keyboard: \(String(describing: window.firstResponder))") {
            window.firstResponder is ReviewTextEditor.EditorView
        }

        // ⏎ saves: the card under the line, the file's count in the list.
        try type("Wrap the find and the put in one transaction.", in: window)
        try await TestSupport.eventually { self.repository.review(scope).comments.count == 1 }
        XCTAssertNil(session.reviewDraft)
        _ = try await frame("review-comment", in: window)
        XCTAssertTrue(PresentationTestSupport.accessibilityLabels("review-comment-text", in: window)
            .contains { $0.contains("one transaction") })
        try await TestSupport.eventually {
            // The row's count; macOS 26 reads it out only as part of the row's button.
            PresentationTestSupport.accessibilityLabels("git-change-comments", in: window).contains("1 comment")
                || PresentationTestSupport.accessibilityLabels("git-change-unstaged-src/routes/billing.ts", in: window)
                    .contains { $0.contains("1 comment") }
        }

        // Create review: the overall comment, ⏎ copies it, and the comments are gone with an Undo.
        let pasteboard = NSPasteboard.general.string(forType: .string)
        addTeardownBlock { @MainActor in
            NSPasteboard.general.clearContents()
            if let pasteboard { NSPasteboard.general.setString(pasteboard, forType: .string) }
        }
        var popover: NSWindow?
        try await click("review-create", in: window, until: {
            popover = NSApp.windows.first { $0 !== window && $0.isVisible && $0.firstResponder is ReviewTextEditor.EditorView }
            return popover != nil
        })
        try type("Looks close; run the tests after.", in: try XCTUnwrap(popover))
        try await TestSupport.eventually { self.repository.review(scope).isEmpty }
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        XCTAssertTrue(copied.hasPrefix("Code review of the uncommitted changes in \(root) (main at 3f2c1a0): 1 comment on 1 file."),
                      copied)
        XCTAssertTrue(copied.contains("Looks close; run the tests after."), copied)
        // Create review read the file again: the fake tree's billing.ts is one export repeated, so the line is gone.
        XCTAssertTrue(copied.contains("## src/routes/billing.ts\n\nLine \(number) (the line has changed since; the quote is what it "
                                      + "said):\n```diff\n+\(presentation.lines[index].text)\n```\n"
                                      + "Wrap the find and the put in one transaction."), copied)
        _ = try await frame("review-copied", in: window)
        try await TestSupport.eventually { PresentationTestSupport.accessibilityFrames("review-comment", in: window).isEmpty }

        try await click("review-undo", in: window, until: { self.repository.review(scope).comments.count == 1 })
        _ = try await frame("review-comment", in: window)
        XCTAssertEqual(repository.review(scope).summary, "Looks close; run the tests after.")
    }

    /// A comment on the file sits above the rows; Edit opens it in the composer and ⏎ saves the new text; Delete
    /// removes it.
    func testFileCommentEditsAndDeletes() async throws {
        let session = mockupSession()
        let window = try window(session)
        let scope = try XCTUnwrap(session.reviewScope)
        try await click("git-diff-comment-file", in: window, until: { session.reviewDraft != nil })
        XCTAssertNil(session.reviewDraft?.end)
        try await TestSupport.eventually { window.firstResponder is ReviewTextEditor.EditorView }
        try type("Split this file.", in: window)
        try await TestSupport.eventually { self.repository.review(scope).comments.map(\.text) == ["Split this file."] }
        var card = NSRect.zero, hunk = NSRect.zero // The comment's row comes in with the next layout: read both once it is placed.
        try await TestSupport.eventually(diagnostic: "the file's comment sits above the rows: card \(card), hunk \(hunk)") { card = PresentationTestSupport.accessibilityFrames("review-comment", in: window).first ?? .zero; hunk = PresentationTestSupport.accessibilityFrames("git-diff-hunk-0", in: window).first ?? .zero; return card != .zero && hunk != .zero && card.minY > hunk.maxY - 1 }
        XCTAssertGreaterThan(card.minY, hunk.maxY - 1, "the file's comment sits above the rows")

        try await click("review-comment-edit", in: window, until: { session.reviewDraft?.editing != nil })
        try await TestSupport.eventually { window.firstResponder is ReviewTextEditor.EditorView }
        try type(" Into two.", in: window)
        try await TestSupport.eventually { self.repository.review(scope).comments.map(\.text) == ["Split this file. Into two."] }

        try await click("review-comment-delete", in: window, until: { self.repository.review(scope).comments.isEmpty })
        try await TestSupport.eventually { PresentationTestSupport.accessibilityFrames("review-comment", in: window).isEmpty }
    }
}
