import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class PaneNavigationTests: XCTestCase {
    private func fixture(_ workspace: Workspace, chat: ChatCoordinator? = nil) -> [UUID: ChatSession] {
        workspace.newLocalSpace()
        let labels = ["zsh", "vitest --watch", "cargo bench", "pnpm build"]
        var sessions: [UUID: ChatSession] = [:]
        for (index, title) in labels.enumerated() {
            if index > 0 { workspace.newTab() }
            let id = workspace.activeTab!.id
            workspace.updateTab(id, customTitle: title)
            let session = chat?.session(for: id) ?? ChatSession(id: id)
            session.active = index > 0
            session.busy = index == 1
            session.hasNewMessages = index == 2
            if index == 3 { session.approvals = [PendingApproval(key: "overwrite", operation: "Overwrite dist/? [y/N]") { _ in }] }
            sessions[id] = session
        }
        workspace.renameSpace(workspace.selectedSpace!, to: "api-refactor")
        return sessions
    }

    func testRankingByUrgency() {
        let workspace = Workspace(), sessions = fixture(workspace)
        let all = AttentionEntry.entries(workspace: workspace, sessions: sessions)
        XCTAssertEqual(all.map(\.urgency), [.waiting, .unread, .running, .idle])
        XCTAssertEqual(all.map(\.title), ["pnpm build", "cargo bench", "vitest --watch", "zsh"])
    }

    func testListsHiddenTmuxPanesAndEveryHerdrSurfaceOnce() {
        let workspace = Workspace()
        // A tmux session as the helper presents it: one window shown, one hidden.
        var space = Space(name: "tmux", directory: "/tmp")
        space.structure([TerminalTab(directory: "/tmp"), TerminalTab(directory: "/tmp")], selected: 0)
        space.containers[0].name = "first"; space.containers[1].name = "hidden"
        let first = space.containers[0].terminals[0], second = space.containers[1].terminals[0]
        workspace.spaces = [space]
        let entries = AttentionEntry.entries(workspace: workspace, sessions: [:])
        XCTAssertEqual(Set(entries.map(\.id)), [first.id, second.id])
        XCTAssertTrue(entries.first { $0.id == second.id }!.path.contains("hidden"))
        // A herdr tab holding two panes.
        var herdr = Space(name: "herdr", directory: "/tmp")
        herdr.structure([TerminalTab(directory: "/tmp")], selected: 0, backend: 2)
        var other = TerminalTab(directory: "/tmp"); other.terminal = 2
        herdr.containers[0].arrangement.panes.append(Pane(tabs: [other]))
        let surfaces = herdr.containers[0].terminals
        workspace.spaces.append(herdr)
        let combined = AttentionEntry.entries(workspace: workspace, sessions: [:])
        XCTAssertEqual(Set(combined.map(\.id)), Set([first.id, second.id] + surfaces.map(\.id)))
        XCTAssertEqual(combined.count, 4)
    }

    func testSidebarFilteringWithoutPopup() async throws {
        try DesktopTestSupport.requireUnlocked()
        AppFont.register()
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        let workspace = controller.workspace
        let previousWorkspace = runtime.workspace, oldMenu = NSApp.mainMenu
        controller.settings.values = Preferences()
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        controller.settings.values.hideSingleSpace = false
        let sessions = fixture(workspace, chat: runtime.chat)
        runtime.workspace = workspace
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        controller.buildMenus()
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer {
            window.close(); window.contentView = nil
            runtime.close(Array(sessions.keys))
            runtime.workspace = previousWorkspace; NSApp.mainMenu = oldMenu
        }
        try await TestSupport.eventually {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            return NSApp.keyWindow === window
        }
        XCTAssertFalse(NSApp.mainMenu!.performKeyEquivalent(with: TerminalTestSupport.keyEvent(35, "P", in: window, modifiers: [.command, .shift])))
        let root = try XCTUnwrap(window.contentView)
        // Search stays closed until ⌘P opens it; leaving it empty closes it again.
        func spaceSearch() -> NSTextField? {
            PresentationTestSupport.views(of: NSTextField.self, in: root).first { PresentationTestSupport.placeholder(of: $0) == "Search spaces…" }
        }
        func terminal() -> TerminalView? { workspace.activeTab.flatMap { runtime.views[$0.id] }.flatMap { $0.window === window ? $0 : nil } }
        let selected = workspace.selectedSpace
        for hidden in [true, false] {
            controller.windowState.sidebarVisibilityOverride = !hidden
            // Leave the search as a user does, by clicking into the terminal. A programmatic
            // makeFirstResponder is not equivalent here: the search field takes focus back.
            // SwiftUI creates the terminal view in its first render, which has not run yet when the
            // window became key without waiting; the sidebar change above also moves it.
            try await TestSupport.eventually(diagnostic: "The active terminal is not in the window") { terminal() != nil }
            window.contentView?.layoutSubtreeIfNeeded()
            let view = try XCTUnwrap(terminal())
            try PresentationTestSupport.click(window, at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            try await TestSupport.eventually(diagnostic: "Space search stays open after clicking the terminal") { spaceSearch() == nil }
            XCTAssertTrue(NSApp.mainMenu!.performKeyEquivalent(with: TerminalTestSupport.keyEvent(35, "p", in: window, modifiers: [.command])))
            do {
                try await TestSupport.eventually(diagnostic: "Space search: controller=\(ObjectIdentifier(controller)) hidden=\(hidden) sidebar=\(controller.sidebarVisible) input=\(String(describing: spaceSearch())) editor=\(String(describing: spaceSearch()?.currentEditor())) responder=\(String(describing: window.firstResponder)) request=\(String(describing: controller.windowState.spaceSearchFocusRequest))") {
                    guard let input = spaceSearch() else { return false }
                    return controller.sidebarVisible && input.currentEditor() != nil && window.firstResponder === input.currentEditor()
                }
            } catch {
                _ = try? await PresentationTestSupport.capture(window, named: "search-failure", in: "sidebar-validation")
                print("Search view tree: windows=\(NSApp.windows.filter(\.isVisible).map { ($0.windowNumber, $0.frame) }), root=\(root), sidebar=\(controller.sidebarVisible)")
                throw error
            }
            // AppKit moves focus at once; SwiftUI records its focus state in its next update pass. Run that pass
            // now, so leaving the field below is not undone by a focus commit still pending.
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        let input = try XCTUnwrap(spaceSearch())
        workspace.hosts.begin(try XCTUnwrap(workspace.activeTab).id, generation: UUID(), destination: "alice@build-server")
        for mode in [SpaceOrder.flat, .tree] {
            controller.settings.values.spaceOrder = mode
            for (query, noMatches) in [("API", false), ("BUILD-SERVER", false), ("alice@", false), ("nonexistent-space", true), ("", false)] {
                input.stringValue = query
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: input)
                try await TestSupport.eventually {
                    let text = try await PresentationTestSupport.capture(window).text()
                    return text.contains("No matching spaces") == noMatches
                }
                XCTAssertEqual(workspace.selectedSpace, selected, "Filtering must not switch the active space")
            }
        }

    }

    func testRunningShellSurvivesMoveToNewSpace() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let controller = AppDelegate(), runtime = TerminalRuntime.shared
        let previousWorkspace = runtime.workspace
        runtime.workspace = controller.workspace
        runtime.start(preferences: Preferences())
        controller.workspace.newLocalSpace()
        let id = try XCTUnwrap(controller.workspace.activeSurfaceID)
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: controller.workspace, settings: controller.settings, controller: controller))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.contentView = nil; window.close()
            runtime.stop(); runtime.workspace = previousWorkspace
        }
        try await TestSupport.eventually { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id])
        let surface = try XCTUnwrap(terminal.surface)
        TerminalTestSupport.send("dispatch_switcher_probe=retained; printf 'SWITCHER_%s\\n' READY", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("SWITCHER_READY") }
        let originalSpace = controller.workspace.selectedSpace
        controller.movePaneToNewSpace(id)
        try await TestSupport.eventually { controller.workspace.selectedSpace != originalSpace && terminal.window === window && terminal.isPresented }
        XCTAssertEqual(controller.workspace.activeSurfaceID, id)
        TerminalTestSupport.send("printf 'MOVED_%s\\n' \"$dispatch_switcher_probe\"", to: terminal)
        try await TestSupport.eventually { TerminalTestSupport.screen(terminal: terminal).contains("MOVED_retained") }
        XCTAssertTrue(terminal.surface === surface)
    }
}
