import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class SpaceBranchTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-branch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func branch(at directory: URL) async -> String? {
        await SpaceBranchReader().branch(.init(key: .init(directory: directory.path, connection: nil)))
    }

    func testNestedDirectoryAndUnbornBranch() async throws {
        let root = try fixture()
        try write("ref: refs/heads/feature/sidebar\n", to: root.appendingPathComponent(".git/HEAD"))
        let child = root.appendingPathComponent("Sources/Nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let result = await branch(at: child)
        XCTAssertEqual(result, "feature/sidebar")
    }

    func testRelativeWorktreeAndDetachedOrInvalidHeadStayEmpty() async throws {
        let root = try fixture(), checkout = root.appendingPathComponent("checkout")
        try write("ref: refs/heads/parent\n", to: root.appendingPathComponent(".git/HEAD"))
        try write("gitdir: ../metadata/worktrees/topic\n", to: checkout.appendingPathComponent(".git"))
        let head = root.appendingPathComponent("metadata/worktrees/topic/HEAD")
        try write("ref: refs/heads/topic\n", to: head)
        let attached = await branch(at: checkout)
        XCTAssertEqual(attached, "topic")
        try write(String(repeating: "a", count: 40) + "\n", to: head)
        let detached = await branch(at: checkout)
        XCTAssertNil(detached, "A detached nested worktree must not inherit the parent branch")
        try write("gitdir: \n", to: checkout.appendingPathComponent(".git"))
        let malformed = await branch(at: checkout)
        XCTAssertNil(malformed)
    }

    func testMissingOversizedAndNonRegularMetadataStayEmpty() async throws {
        let root = try fixture()
        let missing = await branch(at: root)
        XCTAssertNil(missing)
        try write("ref: refs/heads/" + String(repeating: "x", count: 5000), to: root.appendingPathComponent(".git/HEAD"))
        let oversized = await branch(at: root)
        XCTAssertNil(oversized)
        // An empty branch, a second line and a non-branch ref are not branch names.
        for (index, head) in ["ref: refs/heads/\n", "ref: refs/heads/main\nforged", "ref: refs/tags/release\n"].enumerated() {
            let directory = root.appendingPathComponent("head-\(index)")
            try write(head, to: directory.appendingPathComponent(".git/HEAD"))
            let name = await branch(at: directory)
            XCTAssertNil(name, head)
        }
    }

    func testFirstTabIgnoresSelectionAndFollowsReorderingAndDirectoryChanges() throws {
        var space = Space(name: "Work", directory: "/first")
        let next = TerminalTab(directory: "/second")
        space.panes[0].tabs.append(next)
        space.panes[0].selected = next.id
        let runtime = TerminalRuntime()
        XCTAssertEqual(SpaceBranchSource.firstTab(in: space, runtime: runtime)?.key.directory, "/first")
        space.panes[0].tabs.reverse()
        XCTAssertEqual(SpaceBranchSource.firstTab(in: space, runtime: runtime)?.key.directory, "/second")
        space.panes[0].tabs[0].directory = "/changed"
        XCTAssertEqual(SpaceBranchSource.firstTab(in: space, runtime: runtime)?.key.directory, "/changed")
        space.panes[0].tabs[0].machine = .ssh(SSHShell(destination: "remote"))
        XCTAssertNil(SpaceBranchSource.firstTab(in: space, runtime: runtime), "Remote cwd must never be read on this Mac")
    }

    func testFirstTmuxWindowDoesNotFollowSelectedWindow() {
        var space = Space(name: "tmux", directory: "/unused")
        space.structure([TerminalTab(directory: "/first"), TerminalTab(directory: "/second")], selected: 1)
        XCTAssertEqual(SpaceBranchSource.firstTab(in: space, runtime: TerminalRuntime())?.key.directory, "/first")
    }

    func testConcurrentSpacesAllReceiveBranches() async throws {
        let root = try fixture(), reader = SpaceBranchReader()
        var sources: [SpaceBranchSource] = []
        for index in 0..<12 {
            let directory = root.appendingPathComponent(String(index))
            try write("ref: refs/heads/topic-\(index)\n", to: directory.appendingPathComponent(".git/HEAD"))
            sources.append(.init(key: .init(directory: directory.path, connection: nil)))
        }
        let results = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for source in sources { group.addTask { await reader.branch(source) } }
            var values: [String] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        XCTAssertEqual(Set(results), Set((0..<12).map { "topic-\($0)" }))
    }

    func testSidebarModesRefreshAndClearUnavailableBranches() async throws {
        try DesktopTestSupport.requireUnlocked()
        let root = try fixture(), head = root.appendingPathComponent(".git/HEAD")
        try write("ref: refs/heads/feature/sidebar\n", to: head)
        let controller = AppDelegate(), workspace = controller.workspace
        controller.settings.values = Preferences()
        controller.settings.values.largeSidebarItems = false
        controller.settings.values.showGitBranches = true
        workspace.defaultDirectory = root.path
        workspace.newLocalSpace()
        workspace.renameSpace(workspace.spaces[0].id, to: "nightly")
        workspace.newTab()
        let second = try XCTUnwrap(workspace.activeTab)
        workspace.updateTab(second.id, directory: "/")
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SpaceSidebar(workspace: workspace,
            settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func tooltip() -> SpaceHoverDetails? {
            guard let root = window.contentView else { return nil }
            return PresentationTestSupport.views(of: ReorderTrackingView.self, in: root)
                .first { $0.configuration.item == .space(workspace.spaces[0].id) }?.configuration.spaceHover
        }
        func hasBranch(_ name: String) async -> Bool {
            (try? await PresentationTestSupport.capture(window).text().contains(name)) == true
        }
        try await TestSupport.eventually { await hasBranch("feature/sidebar") }
        try await TestSupport.eventually {
            tooltip()?.directory == root.path && tooltip()?.tabCount == "2 tabs"
        }
        _ = try await PresentationTestSupport.capture(window, named: "space-branch-inline-small")
        try write("ref: refs/heads/switched\n", to: head)
        try await TestSupport.eventually {
            guard await hasBranch("switched") else { return false }
            return await !hasBranch("feature/sidebar")
        }
        controller.settings.values.showGitBranches = false
        try await TestSupport.eventually { await !hasBranch("switched") }
        XCTAssertEqual(tooltip()?.summary.contains("switched"), false, "The hover leaves branches to the sidebar")
        _ = try await PresentationTestSupport.capture(window, named: "space-branch-hidden-small")
        controller.settings.values.showGitBranches = true
        try await TestSupport.eventually { await hasBranch("switched") }
        // Large flat tiles: the branch follows the name.
        controller.settings.values.largeSidebarItems = true
        try await TestSupport.eventually { await hasBranch("switched") }
        _ = try await PresentationTestSupport.capture(window, named: "space-tile-large")
        // Large Tree tiles: status, name and branch, with the shortcut on the right.
        controller.settings.values.spaceOrder = .tree
        try await TestSupport.eventually { await hasBranch("switched") }
        _ = try await PresentationTestSupport.capture(window, named: "space-tile-tree-large")
        controller.settings.values.spaceOrder = .flat
        controller.settings.values.largeSidebarItems = false
        try await TestSupport.eventually { await hasBranch("switched") }
        func nameFrame() async throws -> CGRect {
            let labels = try await PresentationTestSupport.capture(window).recognizedText()
            return try XCTUnwrap(labels.first { $0.topCandidates(1).first?.string.contains("nightly") == true }).boundingBox
        }
        var positions: [Bool: CGRect] = [:]
        for large in [false, true] {
            controller.settings.values.largeSidebarItems = large
            try await Task.sleep(for: .milliseconds(100))
            positions[large] = try await nameFrame()
        }
        try write(String(repeating: "a", count: 40), to: head)
        try await TestSupport.eventually { await !hasBranch("switched") }
        for large in [false, true] {
            controller.settings.values.largeSidebarItems = large
            try await Task.sleep(for: .milliseconds(100))
            let frame = try await nameFrame()
            XCTAssertEqual(frame.midY, try XCTUnwrap(positions[large]).midY,
                           accuracy: 1.5 / 360, "The first row must stay put when the branch disappears")
            _ = try await PresentationTestSupport.capture(window, named: large ? "space-no-branch-large" : "space-no-branch")
        }
    }

    func testSidebarSizeSetsRowHeightAndPersists() throws {
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).largeSidebarItems)
        let file = try fixture().appendingPathComponent("settings.json")
        let store = SettingsStore(file: file)
        for large in [false, true] {
            let data = Data("{\"largeSidebarItems\":\(large),\"fontSize\":16}".utf8)
            let preferences = try JSONDecoder().decode(Preferences.self, from: data)
            XCTAssertEqual(preferences.fontSize, 16)
            XCTAssertEqual(preferences.sidebarRowHeight, large ? 36 : 24, "On takes the default, the icons rows; off stays compact")
            try store.save(preferences)
            XCTAssertEqual(SettingsStore(file: file).values.largeSidebarItems, large)
        }
    }
}
