import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// Files mode's listing (H1, docs/ios.md Files): the tab's folder through the helper's `files.list`, sorting, hidden
/// files, git's letters from `files.git status`, following the tab's folder, the breadcrumb's root, item counts, the
/// name search, and the rows as VoiceOver reads them.
@MainActor
final class FilesListingTests: XCTestCase {
    nonisolated static let root = "/Users/sam/src/web"
    static let ref = TabRef(host: UUID(uuidString: "00000000-0000-0000-0000-00000000F11E")!, key: "herdr:web:1")
    /// Nanoseconds since the epoch, `minutes` before the fixed now.
    nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    nonisolated static func stamp(_ minutes: Double) -> String { String(Int64((now.timeIntervalSince1970 - minutes * 60) * 1_000_000_000)) }

    /// A fictional tree: the web app's root, its `src`, `src/components` and a `node_modules` the search never enters.
    nonisolated(unsafe) static let tree: [String: [[String: Any]]] = [
        root: [
            entry(".env", kind: "file", size: 12, minutes: 600),
            entry("README.md", kind: "file", size: 2_200, minutes: 120),
            entry("node_modules", kind: "directory", minutes: 3_000),
            entry("src", kind: "directory", minutes: 4),
            entry("docs", kind: "directory", minutes: 60),
        ],
        root + "/src": [
            entry("theme.ts", kind: "file", size: 1_800, minutes: 25),
            entry("app.tsx", kind: "file", size: 2_400, minutes: 2_880),
            entry("components", kind: "directory", minutes: 4),
            entry("main.tsx", kind: "file", size: 912, minutes: 2_880),
        ],
        root + "/src/components": [
            entry("ThemeToggle.tsx", kind: "file", size: 1_500, minutes: 4),
            entry("Sidebar.tsx", kind: "file", size: 3_400, minutes: 4),
        ],
        root + "/docs": [entry("theming.md", kind: "file", size: 1_400, minutes: 60)],
        root + "/node_modules": [entry("theme-lib", kind: "directory", minutes: 3_000)],
    ]

    nonisolated static func entry(_ name: String, kind: String, size: Int = 0, minutes: Double) -> [String: Any] {
        ["name": name, "kind": kind, "size": size, "modified_ns": stamp(minutes), "target": NSNull()]
    }

    /// The helper answering `files.list` from `tree` (hidden names only when asked) and `files.git` with `status`.
    nonisolated static func helper(status: String = "", lists: (@Sendable (String) -> Void)? = nil) -> ScriptedHelper {
        ScriptedHelper.scripted { @Sendable request in
            switch request.method {
            case "files.list":
                let path = request.params["path"] as? String ?? ""
                lists?(path)
                guard let entries = tree[path] else { return .error(code: "not_found", message: "") }
                let hidden = request.params["hidden"] as? Bool ?? false
                return .result(["path": path, "entries": entries.filter { hidden || !(($0["name"] as? String) ?? "").hasPrefix(".") },
                                "truncated": false])
            case "files.git":
                return .result(["status": 0, "output": status, "truncated": false])
            default:
                return .error(code: "unsupported", message: "")
            }
        }
    }

    private func browser(_ helper: ScriptedHelper?, preferences: FilesPreferences = FilesPreferences(),
                         clock: @escaping @MainActor () -> Date = { FilesListingTests.now }) -> FilesBrowser {
        let source = helper.map { HelperMobileFilesSource(client: $0.client, host: "mba2") }
        return FilesBrowser(tab: Self.ref, host: "mba2", preferences: preferences, pause: { _ in }, clock: clock) { source }
    }

    /// Every folder holds `children` folders (d0, d1, …) and nothing else; paths under `slow` are never answered, those
    /// under `bad` fail.
    nonisolated static func folders(_ children: Int, slow: String = "/slow", bad: String = "/bad",
                                    named: [String: [String]] = [:]) -> ScriptedHelper {
        ScriptedHelper.scripted { @Sendable request in
            guard request.method == "files.list" else { return .result(["status": 0, "output": "", "truncated": false]) }
            let path = request.params["path"] as? String ?? ""
            if path.hasPrefix(slow) { return nil }
            if path.hasPrefix(bad) { return .error(code: "permission_denied", message: "") }
            let names = named[path] ?? (0..<children).map { "d\($0)" }
            return .result(["path": path, "entries": names.map { entry($0, kind: "directory", minutes: 1) }, "truncated": false])
        }
    }

    // MARK: Listing

    /// The tab's folder lists through `files.list` (hidden names left out), folders first, then by name.
    func testTheTabsFolderListsFoldersFirst() async throws {
        let helper = Self.helper()
        let browser = browser(helper)
        browser.follow(directory: Self.root + "/src", repository: Self.root, home: "/Users/sam")
        await browser.load()
        let list = try XCTUnwrap(helper.requests("files.list").first)
        XCTAssertEqual(list.params["path"] as? String, Self.root + "/src")
        XCTAssertEqual(list.params["hidden"] as? Bool, false)
        XCTAssertEqual(browser.rows.map(\.name), ["components", "app.tsx", "main.tsx", "theme.ts"])
        XCTAssertEqual(browser.rows.last?.size, 1_800)
        XCTAssertEqual(browser.crumbs.map(\.title), ["web", "src"], "The repository's root is the first crumb")
    }

    /// Sort by name, date (newest first) or size (largest first), folders first in each.
    func testSortByNameDateAndSize() {
        func file(_ name: String, _ size: UInt64, _ minutes: Double) -> FileEntry {
            FileEntry(name: name, kind: .file, size: size, modified: Self.now.addingTimeInterval(-minutes * 60), targetKind: nil)
        }
        let folder = FileEntry(name: "zeta", kind: .directory, size: 0, modified: Self.now.addingTimeInterval(-99_999), targetKind: nil)
        let entries = [file("b.ts", 10, 5), file("A.ts", 300, 60), folder, file("c10.ts", 20, 1), file("c9.ts", 20, 2)]
        XCTAssertEqual(FilesBrowser.sorted(entries, by: .name).map(\.name), ["zeta", "A.ts", "b.ts", "c9.ts", "c10.ts"])
        XCTAssertEqual(FilesBrowser.sorted(entries, by: .modified).map(\.name), ["zeta", "c10.ts", "c9.ts", "b.ts", "A.ts"])
        XCTAssertEqual(FilesBrowser.sorted(entries, by: .size).map(\.name), ["zeta", "A.ts", "c9.ts", "c10.ts", "b.ts"],
                       "Equal sizes by name, numbers as numbers")
    }

    /// Show hidden files lists again with `hidden`, kept apart from the listing without; the choice is every tab's.
    func testHiddenFilesListAgainForEveryTab() async throws {
        let helper = Self.helper()
        let preferences = FilesPreferences()
        let browser = browser(helper, preferences: preferences)
        browser.follow(directory: Self.root, repository: Self.root, home: "/Users/sam")
        await browser.load()
        XCTAssertFalse(browser.rows.contains { $0.name == ".env" })
        browser.showsHidden = true
        await browser.load()
        XCTAssertEqual(helper.requests("files.list").last?.params["hidden"] as? Bool, true)
        XCTAssertTrue(browser.rows.contains { $0.name == ".env" })
        let other = FilesBrowser(tab: TabRef(host: Self.ref.host, key: "herdr:web:2"), host: "mba2", preferences: preferences) { nil }
        XCTAssertTrue(other.showsHidden, "One choice for every tab")
        browser.showsHidden = false
        XCTAssertFalse(browser.rows.contains { $0.name == ".env" }, "The listing without hidden names is kept")
    }

    // MARK: Git

    /// `files.git status` in the repository's root gives the rows their letters: modified, added, untracked as ?, a
    /// conflict as U; clean and ignored files none.
    func testGitStatusMarksTheRows() async throws {
        let records = [
            "1 .M N... 100644 100644 100644 1111111111111111111111111111111111111111 1111111111111111111111111111111111111111 src/main.tsx",
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 2222222222222222222222222222222222222222 src/theme.ts",
            "u UU N... 100644 100644 100644 100644 3333333333333333333333333333333333333333 3333333333333333333333333333333333333333 3333333333333333333333333333333333333333 src/app.tsx",
            "? src/components/",
        ]
        let helper = Self.helper(status: records.joined(separator: "\0") + "\0")
        let browser = browser(helper)
        browser.follow(directory: Self.root + "/src", repository: Self.root, home: "/Users/sam")
        await browser.load()
        try await TestSupport.eventually { browser.marks != nil }
        let git = try XCTUnwrap(helper.requests("files.git").first)
        XCTAssertEqual(git.params["path"] as? String, Self.root)
        XCTAssertEqual(git.params["args"] as? [String], FilesBrowser.statusArguments)
        let marks = Dictionary(uniqueKeysWithValues: browser.rows.map { ($0.name, browser.mark($0) ?? "") })
        XCTAssertEqual(marks, ["main.tsx": "M", "theme.ts": "A", "app.tsx": "U", "components": "?"])
        browser.follow(directory: "/Users/sam/notes", repository: nil, home: "/Users/sam")
        XCTAssertNil(browser.marks, "Outside a repository no letters")
    }

    // MARK: Following the tab

    /// A cd in the tab moves the listing; the user's own navigation stays until the tab's folder changes; the root is the
    /// repository's, else the home folder (`~`), else "/".
    func testTheListingFollowsTheTabsFolder() async throws {
        let browser = browser(Self.helper())
        browser.follow(directory: Self.root, repository: nil, home: "/Users/sam")
        XCTAssertEqual(browser.crumbs.map(\.title), ["~", "src", "web"], "Before the repository is known: from home")
        browser.follow(directory: Self.root, repository: Self.root, home: "/Users/sam")
        XCTAssertEqual(browser.crumbs.map(\.title), ["web"], "The root arrives: the breadcrumb starts at the repository")
        browser.open(Self.root + "/src/components")
        XCTAssertEqual(browser.crumbs.map(\.title), ["web", "src", "components"])
        browser.follow(directory: Self.root, repository: Self.root, home: "/Users/sam")
        XCTAssertEqual(browser.folder, Self.root + "/src/components", "The same folder again: the user's stays")
        browser.open(Self.root + "/src")
        XCTAssertEqual(browser.folder, Self.root + "/src", "A crumb opens its folder")
        browser.follow(directory: Self.root + "/docs", repository: Self.root, home: "/Users/sam")
        XCTAssertEqual(browser.folder, Self.root + "/docs", "A cd moves the listing")
        browser.follow(directory: "/etc/nginx", repository: nil, home: "/Users/sam")
        XCTAssertEqual(browser.crumbs.map(\.title), ["/", "etc", "nginx"])
        XCTAssertEqual(FilesBrowser.crumbs(folder: Self.root + "/src", repository: Self.root, home: "/Users/sam").map(\.path),
                       [Self.root, Self.root + "/src"], "The bar's first frame has the same crumbs")
    }

    // MARK: Counts and search

    /// A folder row's count is its own listing, read when the row shows and kept for when it opens.
    func testFolderCountsListTheFolderOnce() async throws {
        let helper = Self.helper()
        let browser = browser(helper)
        browser.follow(directory: Self.root + "/src", repository: Self.root, home: "/Users/sam")
        await browser.load()
        XCTAssertNil(browser.count(Self.root + "/src/components"))
        browser.needCount(Self.root + "/src/components")
        browser.needCount(Self.root + "/src/components")
        try await TestSupport.eventually { browser.count(Self.root + "/src/components") != nil }
        XCTAssertEqual(browser.count(Self.root + "/src/components")?.count, 2)
        XCTAssertEqual(helper.requests("files.list").filter { $0.params["path"] as? String == Self.root + "/src/components" }.count, 1)
        browser.open(Self.root + "/src/components")
        XCTAssertEqual(browser.rows.map(\.name), ["Sidebar.tsx", "ThemeToggle.tsx"], "Opening shows the counted listing at once")
        XCTAssertEqual(FilesText.items(1), "1 item")
        XCTAssertEqual(FilesText.items(10_000, truncated: true), "10,000+ items")
    }

    /// The search filters the folder's rows by name, then walks below it (never into node_modules) for more.
    func testSearchFiltersThenWalksBelow() async throws {
        let helper = Self.helper()
        let browser = browser(helper)
        browser.follow(directory: Self.root, repository: Self.root, home: "/Users/sam")
        await browser.load()
        browser.searching = true
        browser.query = "them"
        XCTAssertTrue(browser.rows.isEmpty, "Nothing named so in the root itself")
        try await TestSupport.eventually { !browser.walking }
        XCTAssertEqual(Set(browser.hits.map(\.path)), [Self.root + "/src/theme.ts", Self.root + "/src/components/ThemeToggle.tsx",
                                                       Self.root + "/docs/theming.md"])
        XCTAssertEqual(browser.hits.first { $0.entry.name == "ThemeToggle.tsx" }?.folder, "src/components")
        XCTAssertFalse(helper.requests("files.list").contains { ($0.params["path"] as? String)?.contains("node_modules") == true })
        browser.query = "READ"
        XCTAssertEqual(browser.rows.map(\.name), ["README.md"], "Any case")
        browser.endSearch()
        XCTAssertTrue(browser.hits.isEmpty)
        XCTAssertEqual(browser.rows.count, 4)
    }

    /// Counts wait at most `countQueueLimit` deep, a row that goes cancels its read, leaving the screen cancels them
    /// all, and a failed count is not asked again this session.
    func testCountsAreBoundedCancelledAndRememberFailures() async throws {
        let helper = Self.folders(0)
        let browser = browser(helper)
        for index in 0..<40 { browser.needCount("/slow/d\(index)") }
        XCTAssertEqual(browser.countsPending, FilesBrowser.countConcurrency + FilesBrowser.countQueueLimit)
        _ = try await helper.wait(for: "files.list", count: FilesBrowser.countConcurrency)
        let first = try XCTUnwrap(helper.requests("files.list").first)
        browser.dropCount(first.params["path"] as? String ?? "")
        try await TestSupport.eventually { helper.cancellations.contains(first.id) }
        browser.cancelCounts()
        XCTAssertEqual(browser.countsPending, 0)
        browser.needCount("/bad/x")
        try await TestSupport.eventually { helper.requests("files.list").contains { $0.params["path"] as? String == "/bad/x" } }
        try await TestSupport.eventually { browser.countsPending == 0 }
        browser.needCount("/bad/x")
        XCTAssertEqual(browser.countsPending, 0, "A failed count is remembered")
        XCTAssertEqual(helper.requests("files.list").filter { $0.params["path"] as? String == "/bad/x" }.count, 1)
    }

    /// A tab keeps at most `listingLimit` listings, the shown folder's always.
    func testListingsAreBounded() async throws {
        let helper = Self.folders(1)
        let browser = browser(helper)
        for index in 0..<(FilesBrowser.listingLimit + 12) {
            browser.open("/f/\(index)")
            await browser.load()
        }
        XCTAssertLessThanOrEqual(browser.listings.count, FilesBrowser.listingLimit)
        XCTAssertNotNil(browser.current?.listing, "The shown folder's stays")
        withExtendedLifetime(helper) {}
    }

    /// The search waits out its debounce, then stops after `walkLimit` folders however many there are.
    func testSearchIsDebouncedAndStopsAfterItsFolders() async throws {
        let helper = Self.folders(3)
        final class Pauses: @unchecked Sendable { var asked: [Duration] = [] }
        let pauses = Pauses()
        let browser = FilesBrowser(tab: Self.ref, host: "mba2", pause: { pauses.asked.append($0) }, clock: { Self.now }) {
            HelperMobileFilesSource(client: helper.client, host: "mba2")
        }
        browser.follow(directory: "/deep", repository: nil, home: nil)
        browser.searching = true
        browser.query = "nothing-matches"
        try await TestSupport.eventually(timeout: .seconds(20)) { !browser.walking }
        XCTAssertEqual(pauses.asked, [FilesBrowser.debounce])
        XCTAssertEqual(browser.walkBound, .folders(FilesBrowser.walkLimit))
        XCTAssertLessThanOrEqual(helper.requests("files.list").count, FilesBrowser.walkLimit)
        XCTAssertEqual(FilesListingView.bound(.folders(400)), "Stopped after 400 folders.")
    }

    /// The search goes `depthLimit` folders deep, and stops after `walkSeconds`.
    func testSearchStopsAtItsDepthAndTime() async throws {
        let chain = Self.folders(1), wide = Self.folders(2)
        defer { withExtendedLifetime((chain, wide)) {} }
        let deep = browser(chain)
        deep.follow(directory: "/chain", repository: nil, home: nil)
        deep.searching = true
        deep.query = "zzz"
        try await TestSupport.eventually { !deep.walking }
        XCTAssertEqual(deep.walkBound, .folders(FilesBrowser.depthLimit + 1))
        final class Clock { var now = FilesListingTests.now }
        let clock = Clock()
        let slow = browser(wide) {
            clock.now = clock.now.addingTimeInterval(1)
            return clock.now
        }
        slow.follow(directory: "/wide", repository: nil, home: nil)
        slow.searching = true
        slow.query = "zzz"
        try await TestSupport.eventually { !slow.walking }
        guard case .folders(let looked)? = slow.walkBound else { return XCTFail("\(String(describing: slow.walkBound))") }
        XCTAssertLessThan(looked, 12, "About ten seconds of a clock moving a second a look")
    }

    /// From "/" the search never walks into the kernel's and devices' pseudo-filesystems; Show hidden files restarts it.
    func testSearchSkipsPseudoFilesystemsAndRestartsOnHidden() async throws {
        let helper = Self.folders(0, named: ["/": ["proc", "sys", "dev", "home", "Volumes"], "/home": ["notes"]])
        let browser = browser(helper)
        browser.follow(directory: "/", repository: nil, home: nil)
        browser.searching = true
        browser.query = "note"
        try await TestSupport.eventually { !browser.walking }
        let listed = Set(helper.requests("files.list").compactMap { $0.params["path"] as? String })
        XCTAssertTrue(listed.isDisjoint(with: ["/proc", "/sys", "/dev", "/Volumes"]), "\(listed)")
        XCTAssertEqual(browser.hits.map(\.path), ["/home/notes"])
        browser.showsHidden = true
        try await TestSupport.eventually { helper.requests("files.list").contains { $0.params["hidden"] as? Bool == true } }
        try await TestSupport.eventually { !browser.walking }
        browser.showsHidden = false
    }

    /// git's letters are asked once there is a connection, even for a root first followed offline, and a status cut at
    /// its bound says so.
    func testGitIsAskedWhenTheConnectionComesAndSaysWhenCut() async throws {
        let helper = ScriptedHelper.scripted { @Sendable request in
            request.method == "files.git" ? .result(["status": 0, "output": "? a.txt\0", "truncated": true])
                : .result(["path": FilesListingTests.root, "entries": [Any](), "truncated": false])
        }
        var connected = false
        let source = HelperMobileFilesSource(client: helper.client, host: "mba2")
        let browser = FilesBrowser(tab: Self.ref, host: "mba2", pause: { _ in }) { connected ? source : nil }
        browser.follow(directory: Self.root, repository: Self.root, home: "/Users/sam")
        XCTAssertTrue(helper.requests("files.git").isEmpty)
        connected = true
        browser.follow(directory: Self.root, repository: Self.root, home: "/Users/sam")
        try await TestSupport.eventually { browser.marks != nil }
        XCTAssertEqual(helper.requests("files.git").count, 1)
        XCTAssertTrue(browser.marksTruncated)
    }

    /// A listing first asked offline is read when the connection comes back.
    func testReconnectingReadsAListingFirstAskedOffline() async throws {
        let helper = Self.helper()
        var connected = false
        let source = HelperMobileFilesSource(client: helper.client, host: "mba2")
        let browser = FilesBrowser(tab: Self.ref, host: "mba2", pause: { _ in }) { connected ? source : nil }
        browser.follow(directory: Self.root + "/src", repository: Self.root, home: "/Users/sam")
        await browser.load()
        XCTAssertEqual(browser.current?.error, .offline("mba2"))
        connected = true
        await browser.reconnected()
        XCTAssertEqual(browser.rows.count, 4)
        try await TestSupport.eventually { !helper.requests("files.git").isEmpty }
    }

    /// A folder deleted on the host shows as gone on the next read, not with its last contents.
    func testAFolderDeletedShowsGone() async throws {
        final class Gone: @unchecked Sendable { var gone = false }
        let state = Gone()
        let helper = ScriptedHelper.scripted { @Sendable request in
            state.gone ? .error(code: "not_found", message: "") : .result(["path": "/w", "entries": [FilesListingTests.entry("a", kind: "file", minutes: 1)], "truncated": false])
        }
        let browser = browser(helper)
        browser.follow(directory: "/w", repository: nil, home: nil)
        await browser.load()
        XCTAssertEqual(browser.rows.count, 1)
        state.gone = true
        await browser.load(force: true)
        XCTAssertNil(browser.current?.listing)
        XCTAssertEqual(browser.current?.error, .notFound("/w"))
    }

    // MARK: Failures

    /// Without a connection nothing is asked: a folder never listed says the host is offline, one listed before stays.
    func testOfflineKeepsTheLastListing() async throws {
        let helper = Self.helper()
        var connected = true
        let source = HelperMobileFilesSource(client: helper.client, host: "mba2")
        let browser = FilesBrowser(tab: Self.ref, host: "mba2") { connected ? source : nil }
        browser.follow(directory: Self.root + "/src", repository: nil, home: "/Users/sam")
        await browser.load()
        connected = false
        await browser.load(force: true)
        XCTAssertEqual(browser.rows.count, 4, "The last listing stays")
        browser.open(Self.root + "/docs")
        await browser.load()
        XCTAssertEqual(browser.current?.error, .offline("mba2"))
        XCTAssertEqual(helper.requests("files.list").count, 1)
    }

    /// The helper's codes as Files words them.
    func testHelperErrorsMap() async throws {
        let helper = Self.helper()
        let browser = browser(helper)
        browser.follow(directory: Self.root + "/gone", repository: nil, home: "/Users/sam")
        await browser.load()
        XCTAssertEqual(browser.current?.error, .notFound(Self.root + "/gone"))
        XCTAssertEqual(HelperMobileFilesSource.map(HelperFailure(code: "permission_denied", message: ""), path: "/x", host: "mba2"),
                       .permissionDenied("/x"))
        XCTAssertEqual(HelperMobileFilesSource.map(HelperWire.Failure.truncated, path: "/x", host: "mba2"), .offline("mba2"))
        XCTAssertEqual(HelperMobileFilesSource.map(HelperFailure(code: "unsupported", message: "No"), path: "/x", host: "mba2"),
                       .unsupported("No"))
    }

    // MARK: Words and view

    func testAgesAndDetails() {
        XCTAssertEqual(FilesText.age(Self.now.addingTimeInterval(-30), now: Self.now), "now")
        XCTAssertEqual(FilesText.age(Self.now.addingTimeInterval(-25 * 60), now: Self.now), "25m")
        XCTAssertEqual(FilesText.age(Self.now.addingTimeInterval(-2 * 86_400), now: Self.now), "2d")
        XCTAssertEqual(FilesText.age(Self.now.addingTimeInterval(-21 * 86_400), now: Self.now), "3w")
        XCTAssertEqual(FilesText.age(Self.now.addingTimeInterval(-400 * 86_400), now: Self.now), "1y")
        XCTAssertEqual(FilesText.ago(Self.now.addingTimeInterval(-25 * 60), now: Self.now), "25m ago")
        let file = FileEntry(name: "theme.ts", kind: .file, size: 1_800, modified: Self.now.addingTimeInterval(-25 * 60), targetKind: nil)
        XCTAssertEqual(FilesText.detail(file, count: nil, now: Self.now), "1.8 KB · 25m")
        let folder = FileEntry(name: "hooks", kind: .directory, size: 0, modified: Self.now.addingTimeInterval(-25 * 60), targetKind: nil)
        XCTAssertEqual(FilesText.detail(folder, count: (2, false), now: Self.now), "2 items · 25m")
        XCTAssertEqual(FilesText.detail(folder, count: nil, now: Self.now), "25m", "The age alone until the count is read")
        XCTAssertEqual(FilesText.symbol(file), "doc.text")
        XCTAssertEqual(FilesText.symbol(folder), "folder.fill")
        XCTAssertEqual(FilesText.symbol(name: "README.md"), "doc.richtext")
    }

    /// The rows read as name, kind, detail and git's letter; the footer counts them; a folder's tap opens it in place.
    func testTheListingReadsByRow() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let records = "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 2222222222222222222222222222222222222222 src/theme.ts\0"
        let helper = Self.helper(status: records)
        let browser = browser(helper)
        browser.follow(directory: Self.root + "/src", repository: Self.root, home: "/Users/sam")
        await browser.load()
        try await TestSupport.eventually { browser.marks != nil }
        var opened: [String] = []
        let (window, host) = try show(FilesListingView(browser: browser, tint: .blue) { path, _ in opened.append(path) })
        defer { window.isHidden = true }
        var labels: [String] = []
        try await TestSupport.eventually {
            labels = accessibilityElements(host.view).compactMap(\.accessibilityLabel)
            return labels.contains { $0.hasPrefix("theme.ts") }
        }
        XCTAssertTrue(labels.contains { $0.hasPrefix("theme.ts, 1.8 KB · ") && $0.hasSuffix(", Added") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.hasPrefix("components, folder") }, "\(labels)")
        XCTAssertTrue(labels.contains("4 items"), "\(labels)")
        try tap(labels.first { $0.hasPrefix("theme.ts") }!, in: host.view)
        XCTAssertEqual(opened, [Self.root + "/src/theme.ts"])
        try tap(labels.first { $0.hasPrefix("components") }!, in: host.view)
        XCTAssertEqual(browser.folder, Self.root + "/src/components")
    }

    /// An empty folder says so and offers the hidden files it may hold.
    func testAnEmptyFolderOffersHiddenFiles() async throws {
        AccessibilityLabelTests.enableAccessibility()
        let helper = ScriptedHelper.scripted { @Sendable request in
            request.method == "files.list" ? .result(["path": "/tmp/empty", "entries": [Any](), "truncated": false]) : .result(NSNull())
        }
        let browser = browser(helper)
        browser.follow(directory: "/tmp/empty", repository: nil, home: "/Users/sam")
        await browser.load()
        let (window, host) = try show(FilesListingView(browser: browser, tint: .blue) { _, _ in })
        defer { window.isHidden = true }
        try await TestSupport.eventually { accessibilityElements(host.view).contains { $0.accessibilityLabel == "This folder is empty" } }
        try tap("Show hidden files", in: host.view)
        XCTAssertTrue(browser.showsHidden)
        browser.showsHidden = false
    }

    // MARK: Helpers

    private func show(_ view: some View, size: CGSize = CGSize(width: 402, height: 700)) throws -> (UIWindow, UIViewController) {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }

    private func accessibilityElements(_ view: UIView) -> [NSObject] {
        var found: [NSObject] = []
        func walk(_ element: NSObject) {
            if element.isAccessibilityElement { found.append(element) }
            for child in (element.accessibilityElements as? [NSObject]) ?? [] { walk(child) }
            if let view = element as? UIView { for sub in view.subviews { walk(sub) } }
        }
        walk(view)
        return found
    }

    private func tap(_ label: String, in view: UIView) throws {
        let element = try XCTUnwrap(accessibilityElements(view).first { $0.accessibilityLabel == label }, "no \(label)")
        XCTAssertTrue(element.accessibilityActivate(), "\(label) did not activate")
    }
}
