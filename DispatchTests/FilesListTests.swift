import Foundation
import XCTest
@testable import DispatchApp

/// The list's pure logic: rows from listings, expansion, the filter, hidden
/// files, sorting, crumbs, the open and parent keys, the texts and selection across refreshes.
@MainActor
final class FilesListTests: XCTestCase {
    private let home = "/Users/ivan"
    private let root = "/Users/ivan/src/api"
    /// The mockup's "now": the fake tree's ages are relative to it.
    private let now = Date(timeIntervalSince1970: 1_760_700_000)

    /// What the loading code does for one folder: list it and keep the result (or the failure) in the session.
    private func load(_ source: FakeFilesSource, _ session: FilesSession, _ path: String, at date: Date? = nil) async {
        do {
            let listing = try await source.list(path, hidden: true)
            session.listings[path] = FileListingState(listing: listing, loadedAt: date ?? now, error: nil, loading: false)
        } catch {
            session.listings[path] = FileListingState(listing: nil, loadedAt: date ?? now,
                                                      error: error as? FilesSourceError ?? .other(code: "test", message: "\(error)"))
        }
    }

    private func session(_ source: FakeFilesSource) async -> FilesSession {
        let session = FilesSession(id: System.uuid())
        session.home = source.home
        session.availability = .available(source)
        await load(source, session, root)
        return session
    }

    private func titles(_ rows: [FilesRow]) -> [String] { rows.map(\.title) }

    private func row(_ title: String, in rows: [FilesRow], file: StaticString = #filePath, line: UInt = #line) throws -> FilesRow {
        try XCTUnwrap(rows.first { $0.title == title }, "no row \(title) in \(titles(rows))", file: file, line: line)
    }

    func testMockupRootRowsTextsAndCount() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(titles(rows), [".github", "node_modules", "src", "tests",
                                      ".gitignore", "CHANGELOG.md", "package.json", "pnpm-lock.yaml", "README.md", "tsconfig.json"])
        XCTAssertTrue(rows.allSatisfy { $0.depth == 0 && $0.parent == root && $0.isEntry && !$0.expanded })
        XCTAssertEqual(try row("src", in: rows).id, root + "/src")
        XCTAssertEqual(try row("src", in: rows).modified, "6m")
        XCTAssertEqual(try row("src", in: rows).size, "—")
        XCTAssertEqual(try row("tests", in: rows).modified, "35m")
        XCTAssertEqual(try row("node_modules", in: rows).modified, "15h")
        XCTAssertEqual(try row(".github", in: rows).modified, "2d")
        XCTAssertEqual(try row(".gitignore", in: rows).modified, "13d")
        XCTAssertEqual(try row(".gitignore", in: rows).size, "13 B")
        XCTAssertEqual(try row("pnpm-lock.yaml", in: rows).size, "190 KB")
        XCTAssertEqual(try row("CHANGELOG.md", in: rows).modified, "12m")
        let result = FilesRowBuilder().rows(for: session, root: root, hidden: true)
        XCTAssertEqual(result.itemCount, 10)
        XCTAssertEqual(result.ids, Set(rows.map(\.id)))
        XCTAssertEqual(FilesFooter.summary(items: result.itemCount, selected: 1), "10 items · 1 selected")
        XCTAssertEqual(FilesFooter.summary(items: 1, selected: 0), "1 item")
        XCTAssertEqual(FilesFooter.summary(items: 5_120, selected: 1_024), "5,120 items · 1,024 selected",
                       "grouped as the preview groups, whatever the locale")
        XCTAssertEqual(FilesFooter.summary(items: 16, selected: 0), "16 items")
    }

    func testExpansionShowsLoadingThenRowsOneLevelAtATime() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        session.expanded.insert(root + "/src")
        var rows = session.rows(root: root, settingHidden: true)
        let src = try XCTUnwrap(rows.firstIndex { $0.title == "src" })
        XCTAssertTrue(rows[src].expanded)
        XCTAssertEqual(rows[src + 1].kind, .loading)
        XCTAssertEqual(rows[src + 1].title, "…")
        XCTAssertEqual(rows[src + 1].depth, 1)
        XCTAssertFalse(rows[src + 1].isEntry)
        XCTAssertEqual(rows[src + 2].title, "tests", "the loading row is the folder’s only row")

        await load(source, session, root + "/src")
        rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(Array(titles(rows)[src...(src + 3)]), ["src", "lib", "routes", "index.ts"])
        XCTAssertEqual(rows[(src + 1)...(src + 3)].map(\.depth), [1, 1, 1])
        XCTAssertEqual(rows[src + 1].parent, root + "/src")
        XCTAssertFalse(rows[src + 2].expanded, "routes stays closed: one level at a time")

        session.expanded.insert(root + "/src/routes")
        await load(source, session, root + "/src/routes")
        rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(Array(titles(rows)[src...(src + 5)]), ["src", "lib", "routes", "billing.ts", "health.ts", "index.ts"])
        XCTAssertEqual(rows[(src + 3)...(src + 4)].map(\.depth), [2, 2])
        XCTAssertEqual(rows[src + 3].id, root + "/src/routes/billing.ts")
        XCTAssertEqual(rows[src + 3].modified, "6m")

        // Closing src hides routes' rows even though routes is still marked expanded.
        session.expanded.remove(root + "/src")
        rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(rows.count, 10)
    }

    func testFolderErrorsEmptyFoldersAndTheTruncationBound() async throws {
        let source = FakeFilesSource.mockupAPI()
        source.directory(root + "/empty")
        for index in 0..<5 { source.file(root + "/many/file\(index).txt", "x") }
        let session = await session(source)
        source.failures["list \(root)/tests"] = .permissionDenied(root + "/tests")
        await load(source, session, root + "/tests")
        await load(source, session, root + "/empty")
        source.listLimit = 3
        await load(source, session, root + "/many")
        session.expanded = [root + "/tests", root + "/empty", root + "/many"]
        let rows = session.rows(root: root, settingHidden: true)

        let tests = try XCTUnwrap(rows.firstIndex { $0.title == "tests" })
        XCTAssertEqual(rows[tests + 1].kind, .error)
        XCTAssertEqual(rows[tests + 1].title, "No permission to read \(root)/tests")
        let empty = try XCTUnwrap(rows.firstIndex { $0.title == "empty" })
        XCTAssertEqual(rows[empty + 1].kind, .empty)
        XCTAssertEqual(rows[empty + 1].title, "Empty folder")
        let many = try XCTUnwrap(rows.firstIndex { $0.title == "many" })
        XCTAssertEqual(Array(titles(rows)[(many + 1)...(many + 4)]),
                       ["file0.txt", "file1.txt", "file2.txt", "showing the first 10,000"])
        XCTAssertEqual(rows[many + 4].kind, .truncated)
        XCTAssertNil(session.openAction(for: rows[many + 4]))

        // An empty root shows no rows; the view says so in the middle of the list.
        let bare = FilesSession(id: System.uuid())
        await load(source, bare, root + "/empty")
        XCTAssertEqual(bare.rows(root: root + "/empty", settingHidden: true), [])
    }

    func testFilterIsCaseInsensitiveAndKeepsAncestors() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        for folder in ["/src", "/src/routes", "/src/lib"] {
            session.expanded.insert(root + folder)
            await load(source, session, root + folder)
        }
        session.filter = "BILL"
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)), ["src", "routes", "billing.ts"])
        session.filter = "lib"
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)), ["src", "lib"],
                       "a matching folder shows; its rows only if they match too")
        session.filter = "  json "
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)), ["package.json", "tsconfig.json"])
        session.filter = "nothing-matches"
        XCTAssertEqual(session.rows(root: root, settingHidden: true), [])
        // No placeholders while filtering: a loading folder that matches shows without its "…".
        session.expanded.insert(root + "/tests")
        session.filter = "tests"
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)), ["tests"])
    }

    func testHiddenFilesFollowTheSettingUntilToggled() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        XCTAssertFalse(titles(session.rows(root: root, settingHidden: false)).contains { $0.hasPrefix(".") })
        XCTAssertTrue(titles(session.rows(root: root, settingHidden: true)).contains(".github"))
        session.toggleHidden(settingHidden: false)
        XCTAssertEqual(session.showHidden, true)
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: false)).filter { $0.hasPrefix(".") }, [".github", ".gitignore"])
        session.toggleHidden(settingHidden: false)
        XCTAssertEqual(session.showHidden, false)
        XCTAssertFalse(titles(session.rows(root: root, settingHidden: true)).contains(".github"),
                       "the tab’s choice overrides the setting")
        XCTAssertEqual(FilesRowBuilder().rows(for: session, root: root, hidden: false).itemCount, 8)
    }

    func testEachSortKeepsFoldersFirst() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let folders = [".github", "node_modules", "src", "tests"]
        session.sort = .name; session.sortDescending = true
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)),
                       folders.reversed() + ["tsconfig.json", "README.md", "pnpm-lock.yaml", "package.json", "CHANGELOG.md", ".gitignore"])
        session.sort = .modified; session.sortDescending = true
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)),
                       ["src", "tests", "node_modules", ".github",
                        "CHANGELOG.md", "package.json", "pnpm-lock.yaml", "README.md", ".gitignore", "tsconfig.json"],
                       "newest first; equal times by name")
        session.sortDescending = false
        XCTAssertEqual(Array(titles(session.rows(root: root, settingHidden: true)).prefix(4)), [".github", "node_modules", "tests", "src"])
        session.sort = .size; session.sortDescending = true
        XCTAssertEqual(titles(session.rows(root: root, settingHidden: true)),
                       folders + ["pnpm-lock.yaml", "README.md", "CHANGELOG.md", "tsconfig.json", "package.json", ".gitignore"])
        session.sortDescending = false
        XCTAssertEqual(Array(titles(session.rows(root: root, settingHidden: true)).suffix(2)), ["README.md", "pnpm-lock.yaml"])

        // A new key starts in its natural direction; the same key again flips it.
        session.chooseSort(.name)
        XCTAssertEqual(session.sort, .name); XCTAssertFalse(session.sortDescending)
        session.chooseSort(.modified)
        XCTAssertEqual(session.sort, .modified); XCTAssertTrue(session.sortDescending)
        session.chooseSort(.modified)
        XCTAssertFalse(session.sortDescending)
        session.chooseSort(.size)
        XCTAssertTrue(session.sortDescending)

        // Numbers by value, case ignored, bytes decide the rest.
        let names = ["file10", "File2", "file1", "a", "A"]
        let entries = names.map { FileEntry(name: $0, kind: .file, size: 0, modified: nil, targetKind: nil, mark: nil) }
        XCTAssertEqual(FilesRowBuilder.sorted(entries, by: .name, descending: false).map(\.name), ["A", "a", "file1", "File2", "file10"])
    }

    func testCrumbsUseHomeAndTheHostPrefix() {
        XCTAssertEqual(FilesPath.crumbs(root: root, home: home),
                       [FilesCrumb(title: "~", path: home), FilesCrumb(title: "src", path: home + "/src"),
                        FilesCrumb(title: "api", path: root)])
        XCTAssertEqual(FilesPath.crumbs(root: home + "/", home: home), [FilesCrumb(title: "~", path: home)])
        XCTAssertEqual(FilesPath.crumbs(root: "/etc/nginx", home: home),
                       [FilesCrumb(title: "/", path: "/"), FilesCrumb(title: "etc", path: "/etc"),
                        FilesCrumb(title: "nginx", path: "/etc/nginx")])
        XCTAssertEqual(FilesPath.crumbs(root: "/", home: home), [FilesCrumb(title: "/", path: "/")])
        XCTAssertEqual(FilesPath.crumbs(root: "/Users/ivanka", home: home).map(\.title), ["/", "Users", "ivanka"],
                       "a sibling sharing the home’s prefix is not under it")
        XCTAssertEqual(FilesPath.crumbs(root: "/home/ivan/nightly", home: nil).map(\.title), ["/", "home", "ivan", "nightly"])
        XCTAssertEqual(FilesPath.crumbLine(root: "/home/ivan/nightly", home: "/home/ivan", host: "homelab"), "homelab: ~ / nightly")
        XCTAssertEqual(FilesPath.crumbLine(root: root, home: home, host: nil), "~ / src / api")
        XCTAssertEqual(FilesPath.crumbLine(root: "/etc/nginx", home: home, host: nil), "/ etc / nginx")

        let session = FilesSession(id: System.uuid())
        session.home = "/home/ivan"
        session.hostLabel = "homelab"
        XCTAssertEqual(session.crumbs(root: "/home/ivan/nightly").map(\.title), ["~", "nightly"])
    }

    func testOpenAndParentKeys() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        XCTAssertEqual(session.root(tabDirectory: root), root)
        XCTAssertTrue(session.followsShell)
        var rows = session.rows(root: root, settingHidden: true)

        // ⏎ on a file previews it; the root stays.
        let readme = try row("README.md", in: rows)
        XCTAssertEqual(session.openAction(for: readme), .preview(root + "/README.md"))
        session.open(readme)
        XCTAssertEqual(session.preview?.path, root + "/README.md")
        XCTAssertEqual(session.preview?.entry?.name, "README.md")
        XCTAssertTrue(session.followsShell)

        // ⏎ on a folder pins it, clears the filter and the selection.
        session.filter = "s"
        session.selection = [root + "/src"]
        let src = try row("src", in: rows)
        XCTAssertEqual(session.openAction(for: src), .pin(root + "/src"))
        session.open(src)
        XCTAssertEqual(session.pinnedRoot, root + "/src")
        XCTAssertEqual(session.root(tabDirectory: root), root + "/src")
        XCTAssertEqual(session.filter, "")
        XCTAssertEqual(session.selection, [])
        XCTAssertNil(session.preview)

        // ⌘↑ pins the enclosing folder with the folder it came from selected.
        XCTAssertTrue(session.showEnclosingFolder(of: root + "/src"))
        XCTAssertEqual(session.pinnedRoot, root)
        XCTAssertEqual(session.selection, [root + "/src"])
        XCTAssertEqual(session.anchor, root + "/src")
        rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(session.selectionIndexes(in: rows), IndexSet(integer: 2))
        XCTAssertTrue(session.showEnclosingFolder(of: "/Users"))
        XCTAssertEqual(session.pinnedRoot, "/")
        XCTAssertFalse(session.showEnclosingFolder(of: "/"), "nothing encloses /")
        XCTAssertEqual(session.pinnedRoot, "/")

        // ↩ follows the shell again.
        session.followShell()
        XCTAssertNil(session.pinnedRoot)
        XCTAssertEqual(session.root(tabDirectory: ""), home, "an unknown shell directory falls back to home")
        XCTAssertEqual(FilesPath.parent("/Users/ivan/"), "/Users")
        XCTAssertEqual(FilesPath.parent("/Users"), "/")
        XCTAssertNil(FilesPath.parent("/"))
        // The header's right-click menu, as Finder's title menu: the shown folder down to the disk.
        XCTAssertEqual(FilesPath.ancestors("/Users/ivan/src/api/"), ["/Users/ivan/src/api", "/Users/ivan/src", "/Users/ivan", "/Users", "/"])
        XCTAssertEqual(FilesPath.ancestors("/"), ["/"])
        XCTAssertEqual(FilesHeader.menuTitle("/Users/ivan", local: false, host: "homelab"), "ivan")
        XCTAssertEqual(FilesHeader.menuTitle("/", local: false, host: "homelab"), "homelab")
        XCTAssertEqual(FilesPath.join("/", "etc"), "/etc")
        XCTAssertEqual(FilesPath.join("/etc/", "nginx"), "/etc/nginx")
        XCTAssertTrue(FilesPath.isWithin("/a/b", "/a"))
        XCTAssertTrue(FilesPath.isWithin("/a", "/"))
        XCTAssertFalse(FilesPath.isWithin("/ab", "/a"))
    }

    func testPreviewWidthRule() {
        func columns(_ width: CGFloat, _ preference: CGFloat? = nil, hidden: Bool = false) -> FilesSplitColumns {
            FilesView.layout(width: width, preference: preference, hidden: hidden)
        }
        // The default: 560 pt from 1,000 pt, half below, the list never under 320 pt, nothing under 600 pt.
        XCTAssertEqual(columns(1_200), FilesSplitColumns(list: 640, preview: 560))
        XCTAssertEqual(columns(1_000), FilesSplitColumns(list: 440, preview: 560))
        XCTAssertEqual(columns(999), FilesSplitColumns(list: 499, preview: 500))
        XCTAssertEqual(columns(800), FilesSplitColumns(list: 400, preview: 400))
        XCTAssertEqual(columns(600), FilesSplitColumns(list: 320, preview: 280), "half would leave the list 300 pt")
        XCTAssertEqual(columns(599), FilesSplitColumns(list: 599, preview: nil))
        XCTAssertEqual(columns(500), FilesSplitColumns(list: 500, preview: nil))

        // A chosen width holds where it fits and is clamped to the minima where it does not.
        XCTAssertEqual(columns(1_000, 300), FilesSplitColumns(list: 700, preview: 300))
        XCTAssertEqual(columns(800, 300), FilesSplitColumns(list: 500, preview: 300))
        XCTAssertEqual(columns(1_000, 900), FilesSplitColumns(list: 320, preview: 680), "the list keeps 320 pt")
        XCTAssertEqual(columns(1_000, 100), FilesSplitColumns(list: 760, preview: 240), "the preview keeps 240 pt")
        XCTAssertEqual(columns(600, 500), FilesSplitColumns(list: 320, preview: 280))
        XCTAssertEqual(columns(1_000, 333.4), FilesSplitColumns(list: 667, preview: 333), "on whole points")
        XCTAssertEqual(columns(500, 300), FilesSplitColumns(list: 500, preview: nil), "too narrow for both: no preview")

        // Hidden: the list takes the view at every width.
        XCTAssertEqual(columns(1_200, hidden: true), FilesSplitColumns(list: 1_200, preview: nil))
        XCTAssertEqual(columns(1_200, 300, hidden: true), FilesSplitColumns(list: 1_200, preview: nil))

        // What a drag proposes is clamped the same way.
        XCTAssertEqual(FilesView.clampedPreview(10, width: 1_180), 240)
        XCTAssertEqual(FilesView.clampedPreview(2_000, width: 1_180), 860)
        XCTAssertEqual(FilesView.clampedPreview(456.6, width: 1_180), 457)
    }

    func testHidingThePreviewKeepsItsWidthAndOpeningAFileShowsIt() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let rows = session.rows(root: root, settingHidden: true)
        let readme = try row("README.md", in: rows), package = try row("package.json", in: rows)
        let src = try row("src", in: rows)
        XCTAssertTrue(session.previewOff, "Files starts without the pane; a double click brings it")
        XCTAssertFalse(session.previewHidden)
        session.tab = .changes
        XCTAssertFalse(session.previewOff, "the git tabs' diffs show from the start")
        session.tab = .files
        XCTAssertNil(session.previewWidth)
        session.togglePreview()
        XCTAssertFalse(session.previewOff, "⌥⌘P asks for it")

        session.previewWidth = 420
        session.togglePreview()
        XCTAssertTrue(session.previewHidden)
        XCTAssertEqual(session.previewWidth, 420, "hiding keeps the width")
        XCTAssertEqual(FilesView.layout(width: 1_180, preference: session.previewWidth, hidden: session.previewHidden),
                       FilesSplitColumns(list: 1_180, preview: nil))

        // A selection while hidden still sets the preview, so the pane loads it once shown; it does not show the pane.
        session.selectionChanged(to: [package], anchor: package)
        XCTAssertEqual(session.preview?.path, package.id)
        XCTAssertTrue(session.previewHidden)

        // ⏎ on a folder pins it and leaves the pane hidden; on a file it shows the pane with that file.
        session.open(src)
        XCTAssertTrue(session.previewHidden)
        session.followShell()
        session.open(readme)
        XCTAssertFalse(session.previewHidden)
        XCTAssertEqual(session.preview?.path, readme.id)
        XCTAssertEqual(session.previewWidth, 420)
        XCTAssertEqual(FilesView.layout(width: 1_180, preference: session.previewWidth, hidden: session.previewHidden),
                       FilesSplitColumns(list: 760, preview: 420))

        // Hiding a preview that has the keyboard hands it to the list; hiding one that has not leaves focus alone.
        session.previewFocused = true
        let request = session.focusRequest
        session.setPreviewHidden(true)
        XCTAssertFalse(session.previewFocused)
        XCTAssertNotEqual(session.focusRequest, request)
        let hiddenRequest = session.focusRequest
        session.setPreviewHidden(true)
        session.togglePreview()
        XCTAssertFalse(session.previewHidden)
        session.togglePreview()
        XCTAssertTrue(session.previewHidden)
        XCTAssertEqual(session.focusRequest, hiddenRequest)
    }

    func testSelectionPreviewsAndSurvivesARefresh() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        var rows = session.rows(root: root, settingHidden: true)
        let package = try row("package.json", in: rows), readme = try row("README.md", in: rows)

        // One entry previews; several keep what shows; none clears it.
        session.selectionChanged(to: [package], anchor: package)
        XCTAssertEqual(session.selection, [package.id])
        XCTAssertEqual(session.anchor, package.id)
        XCTAssertEqual(session.preview?.path, package.id)
        let preview = session.preview
        session.selectionChanged(to: [package], anchor: package)
        XCTAssertTrue(session.preview === preview, "the same row does not reload its preview")
        session.selectionChanged(to: [package, readme], anchor: readme)
        XCTAssertEqual(session.selection, [package.id, readme.id])
        XCTAssertEqual(session.anchor, readme.id)
        XCTAssertTrue(session.preview === preview)
        XCTAssertEqual(session.pathsText(in: rows), "\(package.id)\n\(readme.id)", "paths in row order, one per line")
        XCTAssertEqual(session.selectionIndexes(in: rows), IndexSet([6, 8]))

        // A refresh removes README and adds a file before package.json: selection follows the paths.
        source.remove(readme.id)
        source.file(root + "/AGENTS.md", "# agents\n", modified: now)
        await load(source, session, root, at: now.addingTimeInterval(2))
        rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(Array(titles(rows).suffix(6)),
                       [".gitignore", "AGENTS.md", "CHANGELOG.md", "package.json", "pnpm-lock.yaml", "tsconfig.json"])
        XCTAssertEqual(rows.firstIndex { $0.id == package.id }, 7)
        XCTAssertEqual(session.selectionIndexes(in: rows), IndexSet(integer: 7))
        XCTAssertEqual(session.selection, [package.id, readme.id], "a path that went away stays chosen")
        XCTAssertEqual(session.pathsText(in: rows), package.id, "only the selected rows that show are copied")
        // It comes back (an editor's atomic save): selected again.
        source.file(readme.id, "# api\n", modified: now)
        await load(source, session, root, at: now.addingTimeInterval(4))
        rows = session.rows(root: root, settingHidden: true)
        XCTAssertEqual(session.selectionIndexes(in: rows), IndexSet([7, 9]))

        session.selectionChanged(to: [], anchor: nil)
        XCTAssertEqual(session.selection, [])
        XCTAssertNil(session.anchor)
        XCTAssertNil(session.preview)
    }

    func testBuilderKeepsTheOrderAcrossRefreshesAndRedoesTheTexts() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let builder = FilesRowBuilder()
        let first = builder.rows(for: session, root: root, hidden: true)
        await load(source, session, root, at: now.addingTimeInterval(1))
        XCTAssertEqual(builder.rows(for: session, root: root, hidden: true), first,
                       "an identical listing a second later gives identical rows, so the outline changes nothing")
        await load(source, session, root, at: now.addingTimeInterval(3_600))
        let later = builder.rows(for: session, root: root, hidden: true)
        XCTAssertEqual(later.rows.map(\.id), first.rows.map(\.id))
        XCTAssertEqual(try row("src", in: later.rows).modified, "1h")
        XCTAssertEqual(try row("README.md", in: later.rows).modified, "9d")
        session.sortDescending = true
        XCTAssertEqual(builder.rows(for: session, root: root, hidden: true).rows.first?.title, "tests")

        // A refresh where a few entries changed places them where a full sort would.
        session.sort = .size
        _ = builder.rows(for: session, root: root, hidden: true)
        source.file(root + "/README.md", String(repeating: "x", count: 500_000), modified: now)
        source.file(root + "/a.txt", "a", modified: now)
        source.remove(root + "/package.json")
        await load(source, session, root, at: now.addingTimeInterval(3_602))
        let merged = builder.rows(for: session, root: root, hidden: true).rows.map(\.title)
        XCTAssertEqual(merged, FilesRowBuilder().rows(for: session, root: root, hidden: true).rows.map(\.title))
        XCTAssertEqual(Array(merged.dropFirst(4).prefix(2)), ["README.md", "pnpm-lock.yaml"])
        XCTAssertEqual(merged.last, "a.txt")
    }

    func testAFailedRootRefreshKeepsTheRowsAndSaysSo() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let builder = FilesRowBuilder()
        XCTAssertNil(builder.rows(for: session, root: root, hidden: true).rootError)
        session.listings[root]?.error = .other(code: "EACCES", message: "Permission denied")
        let failed = builder.rows(for: session, root: root, hidden: true)
        XCTAssertEqual(failed.rows.count, 10, "the last good rows stay")
        XCTAssertEqual(failed.rootError, "Permission denied", "and the view says they are not live (F2e)")
        XCTAssertFalse(failed.rows.contains { $0.kind == .error }, "the root's reason is the view's line, not a row")
        session.listings[root] = FileListingState(listing: nil, loadedAt: now, error: .other(code: "EACCES", message: "Permission denied"))
        XCTAssertNil(builder.rows(for: session, root: root, hidden: true).rootError, "without rows the view centres the reason instead")
    }

    private func outline(_ session: FilesSession, builder: FilesRowBuilder) -> (FilesOutlineController, FilesOutlineView, () -> Void) {
        let controller = FilesOutlineController()
        let container = FilesOutlineContainer(controller: controller)
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.layoutSubtreeIfNeeded()
        let root = root
        func update() {
            let rows = builder.rows(for: session, root: root, hidden: true).rows
            controller.update(.init(session: session, rows: rows, root: root, settingHidden: true, focusRequest: nil, drag: nil,
                                    style: FilesOutlineStyle.cached(typography: AppTypography()),
                                    rebuild: { builder.rows(for: session, root: root, hidden: true).rows }))
        }
        addTeardownBlock { @MainActor in controller.dismantle() }
        return (controller, container.outline, update)
    }

    func testARefreshWithTheSameEntriesChangesNoRow() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let (_, outline, update) = outline(session, builder: FilesRowBuilder())
        update()
        let before = (0..<outline.numberOfRows).map { outline.item(atRow: $0) as AnyObject }
        XCTAssertEqual(before.count, 10)
        await load(source, session, root, at: now)
        update()
        let after = (0..<outline.numberOfRows).map { outline.item(atRow: $0) as AnyObject }
        XCTAssertEqual(after.count, before.count)
        XCTAssertTrue(zip(before, after).allSatisfy { $0 === $1 }, "every row keeps its item: nothing reloads")
        source.file(root + "/AGENTS.md", "# agents\n", modified: now)
        await load(source, session, root, at: now)
        update()
        XCTAssertEqual(outline.numberOfRows, 11, "a new file is inserted in place")
        let kept = (0..<outline.numberOfRows).filter { row in before.contains { $0 === outline.item(atRow: row) as AnyObject } }
        XCTAssertEqual(kept.count, 10, "the others keep their items")
    }

    func testAgesMoveOnByTheMinuteWithoutANewListing() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let builder = FilesRowBuilder()
        func ages(_ now: Date?) throws -> [String] {
            let rows = builder.rows(for: session, root: root, hidden: true, now: now).rows
            return try ["src", "tests", "node_modules"].map { try row($0, in: rows).modified }
        }
        XCTAssertEqual(try ages(nil), ["6m", "35m", "15h"], "measured from when the listing was taken")
        XCTAssertEqual(FilesRowBuilder.minute(now.addingTimeInterval(3 * 60 + 59)), now.addingTimeInterval(3 * 60))
        // The listing is unchanged (the loader keeps it, and its time); the shown minute moves the ages on.
        XCTAssertEqual(try ages(FilesRowBuilder.minute(now.addingTimeInterval(3 * 60 + 10))), ["9m", "38m", "15h"])
        XCTAssertEqual(try ages(FilesRowBuilder.minute(now.addingTimeInterval(25 * 60))), ["31m", "1h", "15h"])
        XCTAssertEqual(try ages(now.addingTimeInterval(-10 * 60)), ["6m", "35m", "15h"],
                       "a minute before the listing was taken never makes it younger")

        // In the outline the tick changes texts only: every row keeps its item, and the selection stays.
        let controller = FilesOutlineController()
        let container = FilesOutlineContainer(controller: controller)
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in controller.dismantle() }
        let outline = container.outline
        let folder = root
        func update(_ now: Date) {
            controller.update(.init(session: session, rows: builder.rows(for: session, root: folder, hidden: true, now: now).rows,
                                    root: folder, settingHidden: true, focusRequest: nil, drag: nil,
                                    style: FilesOutlineStyle.cached(typography: AppTypography()),
                                    rebuild: { builder.rows(for: session, root: folder, hidden: true, now: now).rows }))
        }
        update(now)
        session.selection = [root + "/tests"]
        update(now)
        let before = (0..<outline.numberOfRows).map { outline.item(atRow: $0) as AnyObject }
        let selected = outline.selectedRowIndexes
        XCTAssertEqual(selected.count, 1)
        update(FilesRowBuilder.minute(now.addingTimeInterval(25 * 60)))
        let after = (0..<outline.numberOfRows).map { outline.item(atRow: $0) as AnyObject }
        XCTAssertTrue(zip(before, after).allSatisfy { $0 === $1 } && before.count == after.count, "no row was rebuilt")
        XCTAssertEqual(outline.selectedRowIndexes, selected)
        let tests = try XCTUnwrap(after.first { ($0 as? FilesOutlineController.Node)?.row.title == "tests" }
            as? FilesOutlineController.Node)
        XCTAssertEqual(tests.row.modified, "1h")
    }

    func testDataSourceAnswersAnIndexOutOfRangeWithAStandIn() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let (controller, outline, update) = outline(session, builder: FilesRowBuilder())
        update()
        let missing = controller.outlineView(outline, child: 99, ofItem: nil) as? FilesOutlineController.Node
        XCTAssertEqual(missing?.row.kind, .loading, "a blank row, not a trap")
        let file = try XCTUnwrap(outline.item(atRow: 4))
        XCTAssertEqual(controller.outlineView(outline, numberOfChildrenOfItem: file), 0)
        XCTAssertNotNil(controller.outlineView(outline, child: 0, ofItem: file) as? FilesOutlineController.Node)
    }

    func testCopyPathsCopiesTheSelectedRowsThatShow() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let rows = session.rows(root: root, settingHidden: true)
        session.selection = [root + "/README.md", root + "/package.json", root + "/src/gone.ts"]
        XCTAssertEqual(session.pathsText(in: rows), "\(root)/package.json\n\(root)/README.md")
    }

    /// The outline without a window: rows arrive by path, folders open and close with the session, a refresh changes
    /// only what changed, the selection follows its paths, and a folder the user opens loads before it is drawn.
    func testOutlineFollowsTheRowsByPath() async throws {
        let source = FakeFilesSource.mockupAPI()
        let session = await session(source)
        let builder = FilesRowBuilder()
        let controller = FilesOutlineController()
        let container = FilesOutlineContainer(controller: controller)
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.layoutSubtreeIfNeeded()
        let outline = container.outline
        func update() {
            let rows = builder.rows(for: session, root: root, hidden: true).rows
            controller.update(.init(session: session, rows: rows, root: root, settingHidden: true, focusRequest: nil, drag: nil,
                                    style: FilesOutlineStyle(typography: AppTypography()),
                                    rebuild: { builder.rows(for: session, root: self.root, hidden: true).rows }))
        }
        func shown() -> [String] {
            (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FilesOutlineController.Node)?.row.title }
        }
        update()
        XCTAssertEqual(shown(), titles(session.rows(root: root, settingHidden: true)))
        XCTAssertEqual(outline.rowHeight, 24)

        // Opened by the session: the loading row, then the folder's rows in place.
        session.expanded.insert(root + "/src")
        update()
        XCTAssertEqual(Array(shown()[2...4]), ["src", "…", "tests"])
        await load(source, session, root + "/src")
        update()
        XCTAssertEqual(Array(shown()[2...6]), ["src", "lib", "routes", "index.ts", "tests"])
        XCTAssertEqual(outline.level(forRow: 3), 1)

        // Opened by the user: the session learns it and the rows are there at once.
        await load(source, session, root + "/src/routes")
        let routes = try XCTUnwrap(outline.item(atRow: 4))
        outline.expandItem(routes)
        XCTAssertTrue(session.expanded.contains(root + "/src/routes"))
        XCTAssertEqual(Array(shown()[4...6]), ["routes", "billing.ts", "health.ts"])
        update()
        XCTAssertEqual(Array(shown()[4...7]), ["routes", "billing.ts", "health.ts", "index.ts"])

        // The selection is by path: a refresh that adds a row above it keeps the same file selected.
        session.selection = [root + "/src/routes/health.ts"]
        update()
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 6))
        let health = try XCTUnwrap(outline.item(atRow: 6) as? FilesOutlineController.Node)
        source.file(root + "/src/routes/auth.ts", "export {}\n", modified: now)
        await load(source, session, root + "/src/routes", at: now.addingTimeInterval(2))
        update()
        XCTAssertEqual(Array(shown()[4...8]), ["routes", "auth.ts", "billing.ts", "health.ts", "index.ts"])
        XCTAssertEqual(outline.selectedRowIndexes, IndexSet(integer: 7))
        XCTAssertTrue(outline.item(atRow: 7) as? FilesOutlineController.Node === health,
                      "rows that stay keep their item: nothing reloads")

        // Closed by the user: its folders inside close with it.
        outline.collapseItem(outline.item(atRow: 2))
        XCTAssertFalse(session.expanded.contains(root + "/src"))
        XCTAssertFalse(session.expanded.contains(root + "/src/routes"))
        update()
        XCTAssertEqual(shown(), titles(session.rows(root: root, settingHidden: true)))

        // A new order rebuilds the list; a filter removes rows around those that stay.
        session.sortDescending = true
        update()
        XCTAssertEqual(shown().first, "tests")
        session.filter = "json"
        update()
        XCTAssertEqual(shown(), ["tsconfig.json", "package.json"])

        // The user's selection reaches the session and previews a file.
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertEqual(session.selection, [root + "/package.json"])
        XCTAssertEqual(session.preview?.path, root + "/package.json")

        // A new root starts over.
        session.sortDescending = false
        session.pin(root + "/src")
        await load(source, session, root + "/src")
        let rows = builder.rows(for: session, root: root + "/src", hidden: true).rows
        controller.update(.init(session: session, rows: rows, root: root + "/src", settingHidden: true, focusRequest: nil,
                                drag: nil, style: FilesOutlineStyle(typography: AppTypography()), rebuild: { rows }))
        XCTAssertEqual(shown(), ["lib", "routes", "index.ts"])
        controller.dismantle()
    }

    /// The mockup's working tree (F3a): one staged, two unstaged, one untracked; billing.ts staged and changed again, and
    /// an ignored folder, neither of which adds a file.
    private func mockupStatus(branch: String? = "main") -> GitStatus {
        func change(_ path: String, _ kind: GitChangeKind, _ area: GitChangeArea) -> GitChange {
            GitChange(path: path, kind: kind, area: area)
        }
        return GitStatus(branch: branch, head: "4f1c2e9", upstream: "origin/main", changes: [
            change("src/routes/chat.ts", .modified, .staged),
            change("src/routes/billing.ts", .modified, .staged),
            change("src/routes/billing.ts", .modified, .unstaged),
            change("src/lib/db.ts", .modified, .unstaged),
            change("tests/idempotency.test.ts", .untracked, .untracked),
            change("node_modules", .ignored, .untracked),
        ], loadedAt: now)
    }

    func testFooterSaysWhyGitHasNothingToShow() {
        // Inside a repository the header's branch and the Changes count say it; still resolving, nothing to guess.
        XCTAssertNil(FilesFooter.gitSummary(.repository(GitRepository(root: root))))
        XCTAssertNil(FilesFooter.gitSummary(.loading))
        XCTAssertEqual(FilesFooter.gitSummary(.none), "not a repository")
        // Where git cannot run the segments do not show: the footer is where the tab says why.
        XCTAssertEqual(FilesFooter.gitSummary(.unavailable("git is not installed on homelab")), "git is not installed on homelab")
    }

    func testSegmentsShowTheGitTabsInsideARepository() {
        let session = FilesSession(id: System.uuid())
        func ids() -> [FilesTab] { FilesHeader.segments(for: session).map(\.id) }
        session.git = .none
        XCTAssertEqual(ids(), [.files], "outside a repository: Files alone")
        let files = FilesHeader.segments(for: session)[0]
        XCTAssertEqual(files.help, "Files · ⌃⌘1")
        XCTAssertEqual(files.accessibilityID, "files-segment-files")
        XCTAssertNil(files.count)

        session.git = .repository(GitRepository(root: root))
        XCTAssertEqual(ids(), [.files, .changes, .commits])
        XCTAssertNil(FilesHeader.segments(for: session)[1].count, "no count until the status is in")
        session.status = mockupStatus()
        let segments = FilesHeader.segments(for: session)
        XCTAssertEqual(segments.map(\.title), ["Files", "Changes", "Commits"])
        XCTAssertEqual(segments.map(\.count), [nil, 4, nil], "Changes 4, as the mockup's pill")
        XCTAssertEqual(segments.map(\.help), ["Files · ⌃⌘1", "Changes · ⌃⌘2", "Commits · ⌃⌘3"])
        XCTAssertEqual(segments.map(\.accessibilityID), ["files-segment-files", "files-segment-changes", "files-segment-commits"])
        session.status?.changes = []
        XCTAssertNil(FilesHeader.segments(for: session)[1].count, "a clean tree has no pill")

        // Still resolving: Files alone on the Files tab; a git tab asked for keeps its segments while it waits.
        session.git = .loading
        XCTAssertEqual(ids(), [.files])
        session.select(.commits)
        XCTAssertEqual(ids(), [.files, .changes, .commits])
        XCTAssertNil(FilesHeader.segments(for: session)[1].count)
    }

    func testFormatting() {
        XCTAssertEqual(FilesFormatting.size(0), "0 B")
        XCTAssertEqual(FilesFormatting.size(612), "612 B")
        XCTAssertEqual(FilesFormatting.size(999), "999 B")
        XCTAssertEqual(FilesFormatting.size(1_000), "1.0 KB")
        XCTAssertEqual(FilesFormatting.size(4_100), "4.1 KB")
        XCTAssertEqual(FilesFormatting.size(9_940), "9.9 KB")
        XCTAssertEqual(FilesFormatting.size(9_960), "10 KB", "rounding up past 10 drops the decimal")
        XCTAssertEqual(FilesFormatting.size(188_000), "188 KB")
        XCTAssertEqual(FilesFormatting.size(999_400), "999 KB")
        XCTAssertEqual(FilesFormatting.size(999_600), "1.0 MB", "1,000 KB reads as the next unit")
        XCTAssertEqual(FilesFormatting.size(2_200_000), "2.2 MB")
        XCTAssertEqual(FilesFormatting.size(9_600_000), "9.6 MB")
        XCTAssertEqual(FilesFormatting.size(24_000_000), "24 MB")
        XCTAssertEqual(FilesFormatting.size(1_500_000_000), "1.5 GB")
        XCTAssertEqual(FilesFormatting.size(UInt64.max), "18 EB")
        let folder = FileEntry(name: "src", kind: .directory, size: 4_096, modified: nil, targetKind: nil, mark: nil)
        let link = FileEntry(name: "lib", kind: .symlink, size: 12, modified: nil, targetKind: .directory, mark: nil)
        XCTAssertEqual(FilesFormatting.size(of: folder), "—")
        XCTAssertEqual(FilesFormatting.size(of: link), "—", "a link to a folder reads as a folder")

        func age(_ seconds: TimeInterval) -> String { FilesFormatting.age(now.addingTimeInterval(-seconds), at: now) }
        XCTAssertEqual(FilesFormatting.age(nil, at: now), "—")
        XCTAssertEqual(age(0), "now")
        XCTAssertEqual(age(59), "now")
        XCTAssertEqual(age(-300), "now", "a clock ahead of this Mac’s is not negative")
        XCTAssertEqual(age(60), "1m")
        XCTAssertEqual(age(35 * 60), "35m")
        XCTAssertEqual(age(3_599), "59m")
        XCTAssertEqual(age(2 * 3_600 + 59), "2h")
        XCTAssertEqual(age(23 * 3_600 + 3_599), "23h")
        XCTAssertEqual(age(6 * 86_400), "6d")
        XCTAssertEqual(age(13 * 86_400), "13d")
        XCTAssertEqual(age(400 * 86_400), "1y")

        XCTAssertEqual(FilesFormatting.staleness(since: now.addingTimeInterval(-20), at: now), "list is less than a minute old")
        XCTAssertEqual(FilesFormatting.staleness(since: now.addingTimeInterval(-125), at: now), "list is 2 min old")
        XCTAssertEqual(FilesFormatting.staleness(since: now.addingTimeInterval(-3_700), at: now), "list is 1 hour old")
        XCTAssertEqual(FilesFormatting.staleness(since: now.addingTimeInterval(-3 * 86_400), at: now), "list is 3 days old")
    }
}
