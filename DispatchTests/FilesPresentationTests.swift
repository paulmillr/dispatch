import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// The files view as the mockups draw it, hosted in a window and read back by
/// OCR: the header and its tabs, rows, the footer and each unavailable state.
@MainActor
final class FilesPresentationTests: XCTestCase {
    private let root = "/Users/ivan/src/api"
    /// The clock's now when the case starts (XCTest makes every case's instance before the run): the list measures its
    /// ages from the clock, so the mockup's tree is dated from it.
    private lazy var now = System.date()

    private func load(_ source: FakeFilesSource, _ session: FilesSession, _ path: String) async throws {
        let listing = try await source.list(path, hidden: true)
        session.listings[path] = FileListingState(listing: listing, loadedAt: now, error: nil, loading: false)
    }

    /// The F2a state: ~/src/api pinned, src, lib and routes open, billing.ts selected. `session` is the runtime's for a
    /// test that reaches it through the app's menus.
    private func mockupSession(_ given: FilesSession? = nil) async throws -> (FilesSession, FakeFilesSource) {
        let source = FakeFilesSource.mockupAPI(now: now)
        let session = given ?? FilesSession(id: System.uuid())
        session.home = source.home
        session.availability = .available(source)
        session.pinnedRoot = root
        session.showHidden = true
        // The mockup shows the preview, which a tab otherwise opens on a double click.
        session.previewRequested = true
        for path in [root, root + "/src", root + "/src/lib", root + "/src/routes"] { try await load(source, session, path) }
        session.expanded = [root + "/src", root + "/src/lib", root + "/src/routes"]
        session.selection = [root + "/src/routes/billing.ts"]
        session.anchor = root + "/src/routes/billing.ts"
        return (session, source)
    }

    /// `inset`: room the floating mode switch takes at the header's trailing end, as `TerminalContentView` leaves it.
    private func window(_ session: FilesSession, width: CGFloat = 1180, inset: CGFloat = 0) -> NSWindow {
        AppFont.register()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FilesView(session: session)
            .environment(\.filesHeaderTrailingInset, inset)
            .environment(\.appTypography, AppTypography())
            .preferredColorScheme(.dark))
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.orderOut(nil)
            window.contentView = nil
        }
        return window
    }

    /// Waits until OCR reads every text, then returns the snapshot that did.
    @discardableResult
    private func read(_ texts: [String], in window: NSWindow, named name: String,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> PresentationTestSupport.Snapshot {
        var snapshot: PresentationTestSupport.Snapshot?
        try await TestSupport.eventually(timeout: .seconds(20), file: file, line: line,
                                         diagnostic: "OCR did not read \(texts): \((try? snapshot?.text()) ?? "")") {
            let capture = try await PresentationTestSupport.capture(window, named: name, in: "files-audit")
            snapshot = capture
            return try texts.allSatisfy { try capture.reads([$0]) }
        }
        return try XCTUnwrap(snapshot, file: file, line: line)
    }

    /// Waits until the element with `identifier` says `label`. Its accessibility label is the text as drawn: OCR reads
    /// the UI font's dotted zero as "•" and a trailing ellipsis as "..".
    private func says(_ label: String, _ identifier: String, in window: NSWindow,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic:
            "\(identifier) said \(PresentationTestSupport.accessibilityLabels(identifier, in: window)), not \(label)") {
            PresentationTestSupport.accessibilityLabels(identifier, in: window).contains(label)
        }
    }

    /// The outline once SwiftUI has made the representable's views (the first layout, after the window shows).
    private func frame(_ identifier: String, in window: NSWindow, file: StaticString = #filePath,
                       line: UInt = #line) async throws -> NSRect {
        var found: NSRect?
        try await TestSupport.eventually(file: file, line: line, diagnostic: "No \(identifier) on screen") {
            found = PresentationTestSupport.accessibilityFrames(identifier, in: window).first
            return found != nil
        }
        return try XCTUnwrap(found, file: file, line: line)
    }

    private func outlineView(in window: NSWindow) async throws -> FilesOutlineView {
        let root = try XCTUnwrap(window.contentView)
        try await TestSupport.eventually(diagnostic: "No FilesOutlineView under the hosting view") {
            root.layoutSubtreeIfNeeded()
            return PresentationTestSupport.views(of: FilesOutlineView.self, in: root).first != nil
        }
        return try XCTUnwrap(PresentationTestSupport.views(of: FilesOutlineView.self, in: root).first)
    }

    func testListHeaderRowsAndFooter() async throws {
        let (session, _) = try await mockupSession()
        let window = window(session)
        let outline = try await outlineView(in: window)
        try await TestSupport.eventually { outline.numberOfRows == 17 }
        // .github, node_modules, src, lib, db.ts, stripe.ts, routes, billing.ts…
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 7))
        XCTAssertEqual(outline.level(forRow: 7), 2)
        XCTAssertEqual(outline.rowHeight, 24)
        try await read(["Files", "src", "api", "Name", "Modified", "Size"], in: window, named: "files-header")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("files-search", in: window).isEmpty, "search shows as its glyph")
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-hidden-toggle", in: window).isEmpty,
                      "hidden files have no button: ⇧⌘. and Settings")
        try await read(["billing.ts", "health.ts", "pnpm-lock.yaml", "35m"], in: window, named: "files-rows")
        // Sizes hold zeros, which OCR misreads in the UI font: the size column's cell says what it draws.
        let lock = try XCTUnwrap((0..<outline.numberOfRows).first {
            (outline.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue == "pnpm-lock.yaml"
        })
        XCTAssertEqual((outline.view(atColumn: 2, row: lock, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue,
                       "190 KB")
        try await read(["items", "selected"], in: window, named: "files-footer")
        try await says("10 items · 1 selected", "files-footer-summary", in: window)

        // A refresh with the same entries changing no row is FilesListTests' (the controller without a window).
        session.filter = "bill"
        try await TestSupport.eventually { outline.numberOfRows == 3 }
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 2), "the selection follows its path through the filter")
    }

    /// With Liquid Glass the bar is the app's other glass chrome: the tabs on a glass track with the shown one's pill,
    /// the search and pane toggle on one glass pill; the same places as flat.
    func testHeaderIsGlassOnEveryTab() async throws {
        try XCTSkipUnless(LiquidGlassStore.supported, "Liquid Glass needs macOS 26")
        let original = LiquidGlassStore.shared.enabled
        LiquidGlassStore.shared.enabled = true
        defer { LiquidGlassStore.shared.enabled = original }
        let (session, _) = try await mockupSession()
        repository(session)
        let window = window(session)
        _ = try await outlineView(in: window)
        for tab in [FilesTab.files, .changes, .commits] {
            session.tab = tab
            try await TestSupport.eventually(diagnostic: "the glass header did not settle on \(tab)") {
                let commits = PresentationTestSupport.accessibilityFrames("files-segment-commits", in: window).first
                let crumbs = PresentationTestSupport.accessibilityFrames("files-crumbs", in: window).first
                let search = PresentationTestSupport.accessibilityFrames("files-search", in: window).first
                let pane = PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first
                guard let commits, let crumbs, let search, let pane else { return false }
                return commits.maxX < crumbs.minX && search.maxX <= pane.minX && pane.maxX <= 1_180 - 12 + 0.5
            }
            _ = try await PresentationTestSupport.capture(window, named: "files-header-glass-\(tab)", in: "files-audit")
        }
    }

    /// The link button: lit while the view follows the shell; a click stays in the folder shown, another follows again.
    func testFollowShellButtonPinsAndFollowsAgain() async throws {
        let (session, _) = try await mockupSession()
        session.pinnedRoot = nil
        let window = window(session)
        _ = try await outlineView(in: window)
        func click() async throws {
            let button = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-follow-shell", in: window).first)
            try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: button.midX, y: button.midY))
        }
        try await click()
        try await TestSupport.eventually(diagnostic: "the click did not pin the folder") { !session.followsShell }
        try await click()
        try await TestSupport.eventually(diagnostic: "the click did not follow the shell again") { session.followsShell }
    }

    /// The search glyph opens the field with the keyboard in it; esc clears and folds it back to the glyph.
    func testSearchOpensFromItsGlyphAndFoldsBackWhenCleared() async throws {
        let (session, _) = try await mockupSession()
        let window = window(session)
        _ = try await outlineView(in: window)
        let glyph = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-search", in: window).first)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-filter", in: window).isEmpty)
        try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: glyph.midX, y: glyph.midY))
        try await TestSupport.eventually(diagnostic: "the field did not open with the keyboard") {
            !PresentationTestSupport.accessibilityFrames("files-filter", in: window).isEmpty
                && window.firstResponder is NSTextView
        }
        try await read(["Search"], in: window, named: "files-search-open")
        session.filter = "bill"
        session.focusRequest = System.uuid()
        try await TestSupport.eventually(diagnostic: "a search with text stays open") {
            !(window.firstResponder is NSTextView) && !PresentationTestSupport.accessibilityFrames("files-filter", in: window).isEmpty
        }
        session.filter = ""
        try await TestSupport.eventually(diagnostic: "an empty search without the keyboard folds back") {
            PresentationTestSupport.accessibilityFrames("files-filter", in: window).isEmpty
                && !PresentationTestSupport.accessibilityFrames("files-search", in: window).isEmpty
        }
    }

    /// F2a's repository: four changed files (one staged and changed again, an ignored folder that counts for nothing).
    private func repository(_ session: FilesSession) {
        func change(_ path: String, _ kind: GitChangeKind, _ area: GitChangeArea) -> GitChange {
            GitChange(path: path, kind: kind, area: area)
        }
        session.git = .repository(GitRepository(root: root))
        session.status = GitStatus(branch: "main", head: "4f1c2e9", upstream: "origin/main", changes: [
            change("src/routes/chat.ts", .modified, .staged), change("src/routes/billing.ts", .modified, .staged),
            change("src/routes/billing.ts", .modified, .unstaged), change("src/lib/db.ts", .modified, .unstaged),
            change("tests/idempotency.test.ts", .untracked, .untracked), change("node_modules", .ignored, .untracked),
        ], loadedAt: now)
    }

    func testGitSegmentsAndFooterInsideAndOutsideARepository() async throws {
        let (session, _) = try await mockupSession()
        repository(session)
        let window = window(session)
        // The second segment is the branch, which opens Commits, with the uncommitted files' count; the Files tab's own
        // line shows nothing of git.
        try await read(["Files", "main", "src"], in: window, named: "files-header-repository")
        try await says("main · up to date with origin/main · 4 files uncommitted · Commits ⌃⌘3", "files-segment-commits",
                       in: window)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-branch", in: window).isEmpty)
        try await says("10 items · 1 selected", "files-footer-summary", in: window)
        // The segments sit left of the crumbs, in the mockup's order.
        let files = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-segment-files", in: window).first)
        let commits = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-segment-commits", in: window).first)
        let crumbs = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-crumbs", in: window).first)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-segment-changes", in: window).isEmpty,
                      "the changes are Commits' uncommitted row")
        XCTAssertLessThan(files.maxX, commits.minX)
        XCTAssertLessThan(commits.maxX, crumbs.minX)
        // The link follows the folder it belongs to: right after the crumbs, apart from the trailing controls.
        let follow = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-follow-shell", in: window).first)
        let search = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-search", in: window).first)
        XCTAssertLessThan(crumbs.maxX, follow.minX)
        XCTAssertLessThan(follow.maxX, crumbs.maxX + 40, "the link sits beside the path")
        XCTAssertLessThan(follow.maxX, search.minX - 40, "the link is not among the trailing controls")
        // The same place on every tab: the controls keep their order at the trailing end.
        for tab in [FilesTab.files, .changes, .commits] {
            session.tab = tab
            try await TestSupport.eventually(diagnostic: "the header did not settle on \(tab)") {
                let search = PresentationTestSupport.accessibilityFrames("files-search", in: window).first
                let pane = PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first
                guard let search, let pane else { return false }
                return search.maxX <= pane.minX && pane.maxX <= 1_180 - 12 + 0.5
            }
        }
        session.tab = .files

        session.status?.branch = nil
        try await says("detached at 4f1c2e9 · up to date with origin/main · 4 files uncommitted · Commits ⌃⌘3",
                       "files-segment-commits", in: window)

        // git missing on the host: no git segments, and the Files tab says nothing of it.
        session.git = .unavailable("git is not installed on homelab")
        try await TestSupport.eventually(diagnostic: "the git segments still show") {
            PresentationTestSupport.accessibilityFrames("files-segment-commits", in: window).isEmpty
        }
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-footer-git", in: window).isEmpty)
        session.git = .repository(GitRepository(root: root))

        // Outside a repository (the shell cd'd out of it): Files alone.
        session.git = .none
        try await TestSupport.eventually(diagnostic: "the git segments still show") {
            PresentationTestSupport.accessibilityFrames("files-segment-commits", in: window).isEmpty
        }
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("files-segment-files", in: window).isEmpty)
        let snapshot = try await read(["Files", "items"], in: window, named: "files-header-none")
        XCTAssertFalse(try snapshot.reads(["main"]), "no git segment outside a repository")
        XCTAssertFalse(try snapshot.reads(["not a repository"]), "the Files tab says nothing of git")
    }

    /// Under 600 pt the preview has no column: opening a file (⏎, a double click) shows it in the list's place under a
    /// bar back to the list, as the pane toggle does; the narrow list gives up Size, then Modified.
    func testANarrowViewShowsTheOpenedFileInTheListsPlace() async throws {
        let (session, _) = try await mockupSession()
        session.previewRequested = false
        let window = window(session, width: 360)
        let outline = try await outlineView(in: window)
        try await TestSupport.eventually { session.splitNarrow }
        func columns() -> [String] { outline.tableColumns.filter { !$0.isHidden }.map(\.title) }
        try await TestSupport.eventually(diagnostic: "columns \(columns())") { columns() == ["Name", "Modified"] }
        window.setContentSize(NSSize(width: 300, height: 740))
        try await TestSupport.eventually(diagnostic: "columns \(columns())") { columns() == ["Name"] }
        window.setContentSize(NSSize(width: 360, height: 740))

        let path = root + "/src/routes/billing.ts"
        let entry = try XCTUnwrap(session.listings[root + "/src/routes"]?.entries.first { $0.name == "billing.ts" })
        session.open(FilesRow(id: path, parent: root + "/src/routes", depth: 2, kind: .entry, entry: entry, title: entry.name,
                              modified: "", size: ""))
        XCTAssertTrue(session.narrowDetail)
        let back = try await frame("files-split-back", in: window)
        let preview = try await frame("file-preview", in: window)
        XCTAssertGreaterThan(back.minY, preview.maxY - 1, "the bar back sits over the preview")
        XCTAssertLessThan(preview.minX, 2, "the preview takes the list's place")
        try await says("Hide preview", "files-preview-toggle", in: window)
        // The test VM's desktop sometimes drops a synthesized click; another is harmless.
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "the bar back did not take the click") {
            if !session.narrowDetail { return true }
            try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: back.midX, y: back.midY))
            return !session.narrowDetail
        }
        try await TestSupport.eventually { PresentationTestSupport.accessibilityFrames("file-preview", in: window).isEmpty }
        try await says("Show preview", "files-preview-toggle", in: window)
        session.togglePreview()
        _ = try await frame("files-split-back", in: window)
    }

    func testNarrowHeaderFitsTheGitSegments() async throws {
        let (session, _) = try await mockupSession()
        repository(session)
        let inset: CGFloat = 70
        let window = window(session, width: 1180, inset: inset)
        try await says("main · up to date with origin/main · 4 files uncommitted · Commits ⌃⌘3", "files-segment-commits", in: window)
        for width: CGFloat in [600, 480] {
            window.setContentSize(NSSize(width: width, height: 740))
            try await TestSupport.eventually(diagnostic: "the header did not settle at \(width) pt") {
                window.contentView?.layoutSubtreeIfNeeded()
                return PresentationTestSupport.accessibilityFrames("files-segment-commits", in: window).first.map {
                    $0.maxX <= (PresentationTestSupport.accessibilityFrames("files-search", in: window).first?.minX ?? 0)
                } ?? false
            }
            let segment = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-segment-files", in: window).first)
            let toggle = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first)
            XCTAssertGreaterThanOrEqual(segment.minX, 11.5, "nothing spills past the leading edge at \(width) pt")
            XCTAssertLessThanOrEqual(toggle.maxX, width - 12 - inset + 0.5, "the toggle stays out of the switch's room at \(width) pt")
            // Narrowed to glyphs, the segments keep their names for VoiceOver and the count in sight.
            try await says("main · up to date with origin/main · 4 files uncommitted · Commits ⌃⌘3", "files-segment-commits", in: window)
        }
        _ = try await PresentationTestSupport.capture(window, named: "files-header-repository-narrow", in: "files-audit")
    }

    func testControlCommandDigitsAndShiftCommandLettersSwitchTheTabs() async throws {
        try DesktopTestSupport.requireUnlocked()
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        let controller = AppDelegate(), workspace = controller.workspace
        let tab = TerminalTab(directory: root)
        workspace.spaces = [Space(name: "api", tab: tab)]
        workspace.selectedSpace = workspace.spaces.first?.id
        runtime.workspace = workspace
        let menus = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu)
        defer {
            runtime.files.forget(tab.id); runtime.chat.close(tab.id); runtime.workspace = previous
            NSApp.mainMenu = menus.0; NSApp.windowsMenu = menus.1; NSApp.helpMenu = menus.2
        }
        // The runtime's session, as the menus reach it. Its loader idles: no TerminalContentView presents it.
        let (session, _) = try await mockupSession(runtime.files.session(for: tab.id))
        repository(session)
        runtime.files.switchMode(tab.id, to: .files)
        let window = window(session)
        controller.window = window
        controller.buildMenus()
        try await TestSupport.eventually(diagnostic: "the test window did not become key") {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            return NSApp.keyWindow === window
        }
        _ = try await outlineView(in: window)
        func press(_ code: UInt16, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            NSApp.mainMenu?.performKeyEquivalent(with: TerminalTestSupport.keyEvent(code, key, in: window, modifiers: modifiers)) == true
        }
        func outlineShows() -> Bool {
            window.contentView.map { !PresentationTestSupport.views(of: FilesOutlineView.self, in: $0).isEmpty } ?? false
        }

        // ⌃⌘2: Commits on its uncommitted row, the list and its footer gone with the Files tab.
        XCTAssertTrue(press(19, "2", [.control, .command]))
        XCTAssertEqual(session.tab, .changes)
        try await TestSupport.eventually(diagnostic: "the Files tab's list stayed") {
            !outlineShows() && PresentationTestSupport.accessibilityFrames("files-footer", in: window).isEmpty
        }
        try await says("main · up to date with origin/main · 4 files uncommitted · Commits ⌃⌘3", "files-segment-commits", in: window)
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-follow-shell", in: window).isEmpty,
                      "following the shell is the Files tab's")
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("files-search", in: window).isEmpty,
                       "every tab searches from the same place")
        _ = try await PresentationTestSupport.capture(window, named: "files-tab-changes", in: "files-audit")
        // ⌃⌘3: Commits; ⌃⌘1: Files again, the list back.
        XCTAssertTrue(press(20, "3", [.control, .command]))
        XCTAssertEqual(session.tab, .commits)
        XCTAssertTrue(press(18, "1", [.control, .command]))
        XCTAssertEqual(session.tab, .files)
        try await TestSupport.eventually(diagnostic: "the list did not come back") { outlineShows() }
        XCTAssertTrue(PresentationTestSupport.accessibilityFrames("files-branch", in: window).isEmpty, "no git on Files")

        // ⇧⌘U and ⇧⌘L open files on their tab from the terminal.
        runtime.files.switchMode(tab.id, to: .terminal)
        XCTAssertTrue(press(32, "U", [.command, .shift]))
        XCTAssertEqual(runtime.files.mode(for: tab.id), .files)
        XCTAssertEqual(session.tab, .changes)
        runtime.files.switchMode(tab.id, to: .terminal)
        XCTAssertTrue(press(37, "L", [.command, .shift]))
        XCTAssertEqual(runtime.files.mode(for: tab.id), .files)
        XCTAssertEqual(session.tab, .commits)

        // The shell left the repository: back on Files, and the git keys do nothing.
        session.git = .none
        XCTAssertEqual(session.tab, .files)
        _ = press(19, "2", [.control, .command]); _ = press(32, "U", [.command, .shift])
        XCTAssertEqual(session.tab, .files)
        try await TestSupport.eventually(diagnostic: "the list did not come back") { outlineShows() }
    }

    func testEmptyFolderAndLoading() async throws {
        let (session, source) = try await mockupSession()
        source.directory(root + "/empty")
        try await load(source, session, root + "/empty")
        session.pinnedRoot = root + "/empty"
        let window = window(session)
        try await read(["Empty folder", "items"], in: window, named: "files-empty")
        try await says("0 items", "files-footer-summary", in: window)
        session.availability = .loading
        try await read(["Loading"], in: window, named: "files-loading")
    }

    func testUnavailableStates() async throws {
        let (session, _) = try await mockupSession()
        session.hostLabel = "homelab"
        session.availability = .plainSSH(host: "homelab")
        let window = window(session)
        // OCR reads a trailing ellipsis as ".." or drops it: the buttons' labels say the exact words.
        try await read(["Files need dispatch-helper on homelab", "plain SSH", "Install helper", "Not now"],
                       in: window, named: "files-plain-ssh")
        try await says("Install helper…", "files-install-helper", in: window)
        session.availability = .notGranted(host: "homelab", scope: nil)
        try await read(["Files are off for homelab", "Change integration"], in: window, named: "files-not-granted")
        try await says("Change integration…", "files-change-integration", in: window)
        session.availability = .unavailable(message: "The helper on homelab stopped")
        try await read(["Files are unavailable", "The helper on homelab stopped"], in: window, named: "files-unavailable")
        session.availability = .offline(host: "homelab", since: System.date().addingTimeInterval(-125))
        try await read(["homelab offline", "list is 2 min old", "Reconnect", "billing.ts"], in: window, named: "files-offline")
    }

    // MARK: Divider and hidden preview

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1,
                       file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1), file: file, line: line)
    }

    /// The divider's strip once laid out, and the centre of its 1 pt line in window coordinates.
    private func divider(in window: NSWindow) -> (view: FilesPreviewDividerView, x: CGFloat)? {
        guard let root = window.contentView else { return nil }
        root.layoutSubtreeIfNeeded()
        return PresentationTestSupport.views(of: FilesPreviewDividerView.self, in: root).first.map {
            ($0, $0.convert($0.bounds, to: nil).midX)
        }
    }

    private func dividerSits(at x: CGFloat, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await TestSupport.eventually(file: file, line: line, diagnostic:
            "The divider sits at \(divider(in: window).map { "\($0.x)" } ?? "nothing"), not \(x)") {
            guard let found = divider(in: window) else { return false }
            return abs(found.x - x) < 0.5
        }
    }

    /// The outline column's width, which spans from the view's leading edge to the divider.
    private func listWidth(_ outline: FilesOutlineView) -> CGFloat {
        outline.enclosingScrollView.map { $0.convert($0.bounds, to: nil).width } ?? 0
    }

    func testPreviewDividerFollowsTheWidthAndADrag() async throws {
        let (session, _) = try await mockupSession()
        let files = TerminalRuntime.shared.files
        let remembered = files.lastPreviewWidth
        addTeardownBlock { @MainActor in files.lastPreviewWidth = remembered }
        let window = window(session)
        let outline = try await outlineView(in: window)
        // 1,180 pt: the default 560 pt preview, its line at the list's trailing edge.
        try await dividerSits(at: 620.5, in: window)
        XCTAssertEqual(listWidth(outline), 620, accuracy: 1)
        let strip = try XCTUnwrap(divider(in: window)).view
        XCTAssertEqual(strip.bounds.width, FilesPreviewDividerView.hitWidth)
        // Counted once the window has settled (its first frames and key status update the outline).
        try await read(["billing.ts", "Modified"], in: window, named: "files-divider-default")
        let controller = try XCTUnwrap(outline.delegate as? FilesOutlineController)
        let updates = controller.updates

        // A width set from outside moves the line.
        session.previewWidth = 400
        try await dividerSits(at: 780.5, in: window)
        XCTAssertEqual(listWidth(outline), 780, accuracy: 1)
        session.previewWidth = 410
        try await dividerSits(at: 770.5, in: window)
        session.previewWidth = 400
        try await dividerSits(at: 780.5, in: window)

        // A drag from the line: the strip takes the click over the list's and the preview's views, and the line
        // follows the pointer. The chosen width carries to new tabs.
        let y = window.contentLayoutRect.midY
        let start = NSPoint(x: 780.5, y: y)
        XCTAssertTrue(window.contentView?.hitTest(window.contentView!.convert(start, from: nil)) === strip,
                      "the divider's strip is on top where it overlaps the columns")
        XCTAssertTrue(window.contentView?.hitTest(window.contentView!.convert(NSPoint(x: 777.5, y: y), from: nil)) === strip,
                      "the strip reaches past the line into the list")
        window.sendEvent(try mouse(.leftMouseDown, at: start, in: window))
        window.sendEvent(try mouse(.leftMouseDragged, at: NSPoint(x: 730.5, y: y), in: window))
        try await dividerSits(at: 730.5, in: window)
        window.sendEvent(try mouse(.leftMouseDragged, at: NSPoint(x: 680.5, y: y), in: window))
        window.sendEvent(try mouse(.leftMouseUp, at: NSPoint(x: 680.5, y: y), in: window))
        XCTAssertEqual(session.previewWidth, 500)
        XCTAssertEqual(files.lastPreviewWidth, 500)
        try await dividerSits(at: 680.5, in: window)
        XCTAssertEqual(listWidth(outline), 680, accuracy: 1)
        XCTAssertEqual(controller.updates, updates, "moving the divider resizes the outline without updating it")
        try await read(["billing.ts", "Modified"], in: window, named: "files-divider-dragged")

        // Dragged past either minimum it stops: the preview keeps 240 pt, the list 320 pt.
        window.sendEvent(try mouse(.leftMouseDown, at: NSPoint(x: 680.5, y: y), in: window))
        window.sendEvent(try mouse(.leftMouseDragged, at: NSPoint(x: 1_170, y: y), in: window))
        window.sendEvent(try mouse(.leftMouseUp, at: NSPoint(x: 1_170, y: y), in: window))
        XCTAssertEqual(session.previewWidth, 240)
        try await dividerSits(at: 940.5, in: window)
        let narrow = try XCTUnwrap(divider(in: window)).x
        window.sendEvent(try mouse(.leftMouseDown, at: NSPoint(x: narrow, y: y), in: window))
        window.sendEvent(try mouse(.leftMouseDragged, at: NSPoint(x: 20, y: y), in: window))
        window.sendEvent(try mouse(.leftMouseUp, at: NSPoint(x: 20, y: y), in: window))
        XCTAssertEqual(session.previewWidth, 860)
        try await dividerSits(at: 320.5, in: window)

        // A click that does not move leaves the width alone; a double-click puts the default back.
        session.previewWidth = 500
        try await dividerSits(at: 680.5, in: window)
        let line = NSPoint(x: 680.5, y: y)
        window.sendEvent(try mouse(.leftMouseDown, at: line, in: window))
        window.sendEvent(try mouse(.leftMouseUp, at: line, in: window))
        XCTAssertEqual(session.previewWidth, 500)
        window.sendEvent(try mouse(.leftMouseDown, at: line, in: window, clicks: 2))
        window.sendEvent(try mouse(.leftMouseUp, at: line, in: window, clicks: 2))
        XCTAssertNil(session.previewWidth)
        XCTAssertNil(files.lastPreviewWidth)
        try await dividerSits(at: 620.5, in: window)
    }

    func testHiddenPreviewLeavesTheListTheViewAndLoadsNothing() async throws {
        let (session, source) = try await mockupSession()
        let billing = root + "/src/routes/billing.ts", health = root + "/src/routes/health.ts"
        session.showPreview(billing, entry: nil)
        let window = window(session)
        let outline = try await outlineView(in: window)
        try await dividerSits(at: 620.5, in: window)
        try await says("Hide preview", "files-preview-toggle", in: window)
        try await TestSupport.eventually { source.calls.contains("read \(billing)") }
        XCTAssertFalse(PresentationTestSupport.accessibilityFrames("file-preview", in: window).isEmpty)

        // The header's button hides the pane: no divider, no preview, the list spans the view.
        let toggle = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first)
        try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: toggle.midX, y: toggle.midY))
        try await TestSupport.eventually { session.previewHidden }
        try await says("Show preview", "files-preview-toggle", in: window)
        try await TestSupport.eventually(diagnostic: "the divider or the preview is still mounted") {
            self.divider(in: window) == nil && PresentationTestSupport.accessibilityFrames("file-preview", in: window).isEmpty
        }
        XCTAssertEqual(listWidth(outline), 1_180, accuracy: 1)
        // The header keeps the toggle clear of the search and inside the view.
        let shown = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first)
        let search = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-search", in: window).first)
        XCTAssertLessThanOrEqual(search.maxX, shown.minX)
        XCTAssertLessThanOrEqual(shown.maxX, 1_180 - 12 + 0.5)

        // A selection while hidden sets the preview and reads nothing until the pane shows.
        let rows = session.rows(root: root, settingHidden: true)
        let row = try XCTUnwrap(rows.first { $0.id == health })
        session.selectionChanged(to: [row], anchor: row)
        XCTAssertEqual(session.preview?.path, health)
        try await read(["billing.ts", "health.ts", "Size"], in: window, named: "files-preview-hidden")
        XCTAssertFalse(source.calls.contains("read \(health)"), "a hidden preview loads nothing: \(source.calls)")

        let again = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first)
        try await PresentationTestSupport.hoverAndClick(window, at: NSPoint(x: again.midX, y: again.midY))
        try await TestSupport.eventually { !session.previewHidden }
        try await says("Hide preview", "files-preview-toggle", in: window)
        try await dividerSits(at: 620.5, in: window)
        try await TestSupport.eventually { source.calls.contains("read \(health)") }
        try await read(["health", "ok"], in: window, named: "files-preview-shown-again")
    }

    func testNarrowHeaderKeepsThePreviewToggleClearOfTheSwitch() async throws {
        let (session, _) = try await mockupSession()
        // 600 pt is the narrowest view with a preview; the switch's room is about what a floating switch takes.
        let inset: CGFloat = 70
        let window = window(session, width: 600, inset: inset)
        try await dividerSits(at: 320.5, in: window)
        try await says("Hide preview", "files-preview-toggle", in: window)
        let toggle = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first)
        let follow = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-follow-shell", in: window).first)
        let search = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-search", in: window).first)
        XCTAssertLessThan(follow.maxX, search.minX)
        XCTAssertLessThanOrEqual(search.maxX, toggle.minX)
        XCTAssertLessThanOrEqual(toggle.maxX, 600 - 12 - inset + 0.5, "the toggle stays out of the switch's room")
        try await read(["Files", "Name"], in: window, named: "files-header-narrow")
        // Under 600 pt the preview gives way and the crumbs, then the filter, give the buttons their room.
        for width: CGFloat in [560, 480] {
            window.setContentSize(NSSize(width: width, height: 740))
            try await TestSupport.eventually { self.divider(in: window) == nil }
            let toggle = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-preview-toggle", in: window).first)
            let search = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-search", in: window).first)
            let segment = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("files-segment-files", in: window).first)
            XCTAssertLessThanOrEqual(search.maxX, toggle.minX, "at \(width) pt")
            XCTAssertLessThanOrEqual(toggle.maxX, width - 12 - inset + 0.5, "at \(width) pt")
            XCTAssertGreaterThanOrEqual(segment.minX, 11.5, "nothing spills past the leading edge at \(width) pt")
        }
        try await read(["Files"], in: window, named: "files-header-narrowest")
        XCTAssertFalse(session.previewHidden, "a collapsed preview is not a hidden one")
    }
}
