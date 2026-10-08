import AppKit
import Term
import XCTest
@testable import DispatchApp

@MainActor
final class TmuxChatIntegrationTests: XCTestCase {
    func testChatDiscoversInactiveWindowsRoutesPromptsAndSurvivesMovesAndReconnect() async throws {
        let endpoint = try CodexEndpointFixture(prefix: "dispatch-tmux-chat-", delay: 0.05, hooks: false)
        var passed = false
        defer { endpoint.stop(removeState: passed) }
        try await endpoint.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previousChat }
        let app = try TmuxWalkthrough()
        defer { app.close() }
        let workspace = app.workspace, chat = runtime.chat
        let command = CodexTestSupport.command(state: endpoint.state, binary: endpoint.binary)
        _ = try app.server(["send-keys", "-t", "%0", command, "Enter"])
        // Let the first CLI finish migrating the shared, fresh fixture database
        // before launching another CLI against it. Both still precede attach.
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "First fixture CLI did not finish startup") {
            try app.server(["capture-pane", "-p", "-t", "%0"]).contains("dispatch-fixture default")
        }
        _ = try app.server(["new-window", "-t", "edge", "/bin/sh"])
        _ = try app.server(["send-keys", "-t", "%1", command, "Enter"])
        try await app.attach()
        func tab(_ pane: Int) throws -> TerminalTab {
            try XCTUnwrap(workspace.spaces.flatMap(\.tabs).first { app.target($0) == "%\(pane)" })
        }
        let first = try tab(0), second = try tab(1)
        let a = chat.session(for: first.id), b = chat.session(for: second.id)
        do { try await wait { a.active && b.active } }
        catch {
            for (pane, session) in [(0, a), (1, b)] {
                print("PANE", pane, session.binding as Any, session.process as Any,
                      session.status as Any, session.active, session.discoveryBlocked, session.version as Any)
                print(try app.server(["capture-pane", "-p", "-t", "%\(pane)"]))
            }
            throw error
        }
        XCTAssertNil(runtime.views[first.id], "Discover an agent in a window that has never been displayed")
        XCTAssertNotEqual(a.process, b.process)
        XCTAssertFalse(chat.session(for: app.origin!.id).active, "The gateway never owns a pane's conversation")

        workspace.selectTab(first.id)
        try await app.ready()
        let terminal = try XCTUnwrap(runtime.views[first.id]), surface = terminal.surface
        chat.chooseChat(true, session: a)
        a.draft = "first pane\nsecond line"; chat.submit(a)
        XCTAssertTrue(a.busy, a.status ?? "Prompt was not sent")
        try await wait { !a.busy && a.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: first pane\nsecond line" } }
        XCTAssertNil(b.sessionID)
        let firstConversation = try XCTUnwrap(a.sessionID)
        workspace.selectTab(second.id)
        try await app.ready()
        chat.chooseChat(true, session: b)
        b.draft = "second pane"; chat.submit(b)
        try await wait { !b.busy && b.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: second pane" } }
        XCTAssertNotEqual(a.sessionID, b.sessionID)
        let crossed = try await XCTUnwrap(b.helper).refuses("wrong recipient", conversation: firstConversation)
        XCTAssertTrue(crossed, "Another pane's chat never sends into this conversation")
        a.draft = "retained draft"

        let firstWindow = try XCTUnwrap(workspace.spaces.flatMap(\.windows).first { $0.terminals.contains { $0.id == first.id } })
        workspace.moveWindowToNewSpace(firstWindow.id)
        try await wait { workspace.spaces.filter { $0.structured }.count == 2 && workspace.activeTab?.id == first.id }
        XCTAssertTrue(chat.session(for: first.id) === a)
        XCTAssertEqual(a.draft, "retained draft")
        XCTAssertTrue(terminal.surface === surface)
        let destination = try XCTUnwrap(workspace.spaces.flatMap(\.windows).first { $0.terminals.contains { $0.id == second.id } }?.arrangement.focusedPane)
        let destinationSpace = try XCTUnwrap(workspace.spaces.first { $0.tabs.contains { $0.id == second.id } })
        let target = try XCTUnwrap(destinationSpace.windows.first?.id)
        XCTAssertTrue(workspace.moveWindow(firstWindow.id, beside: target))
        try await wait { workspace.current?.windows.count == 2 }
        XCTAssertTrue(workspace.splitTab(first.id, beside: destination, edge: .bottom))
        try await wait { workspace.current?.panes.count == 2 }
        XCTAssertEqual(workspace.current?.windows.count, 2, "Native tiling keeps the server windows separate")
        workspace.selectTab(first.id)
        try await app.ready()
        XCTAssertTrue(a.showChat); XCTAssertTrue(b.showChat)
        XCTAssertTrue(terminal.surface === surface)
        try await wait { app.window.firstResponder is ChatComposer.ComposerTextView }
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.05))
        let composerA = try XCTUnwrap(app.window.firstResponder as? ChatComposer.ComposerTextView)
        XCTAssertEqual(composerA.string, "retained draft")
        let composerB = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: app.window.contentView!).first { $0.accessibilityIdentifier() == "chat-composer-\(second.id)" })
        let point = composerB.convert(NSPoint(x: 20, y: 10), to: nil)
        try await TestSupport.eventually(diagnostic: "Test window activation: key=\(app.window.isKeyWindow), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), visible=\(app.window.isVisible), onSpace=\(app.window.isOnActiveSpace), canKey=\(app.window.canBecomeKey)") {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); app.window.makeKeyAndOrderFront(nil)
            return app.window.isKeyWindow && NSApp.isActive
        }
        try PresentationTestSupport.click(app.window, at: point)
        try await TestSupport.eventually(diagnostic: "Composer focus: active \(workspace.activeTab?.id.uuidString ?? "nil"), expected \(second.id), responder \(String(describing: app.window.firstResponder)), visible \(composerB.visibleRect), canFocus \(composerB.canAcceptFocus())") {
            workspace.activeTab?.id == second.id && app.window.firstResponder === composerB
        }
        let focused = try await app.query("#{pane_id}")
        XCTAssertEqual(focused, "%1", "Clicking a chat composer must select its tmux pane")
        workspace.selectTab(first.id)
        XCTAssertTrue(workspace.applyLayout(.single))
        XCTAssertTrue(workspace.applyLayout(.single))
        try await wait { workspace.current?.layout.paneIDs.count == 1 }
        XCTAssertTrue(workspace.applyLayout(.rows))
        try await wait { workspace.current?.layout.paneIDs.count == 2 }
        try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration + 0.05))
        _ = try await PresentationTestSupport.capture(app.window, named: "tmux-chat-split")

        let processA = try XCTUnwrap(a.process), processB = try XCTUnwrap(b.process)
        app.detachSession()
        try await wait { !app.attached }
        XCTAssertTrue(processA.alive); XCTAssertTrue(processB.alive)
        try await app.attach()
        let restoredA = chat.session(for: try tab(0).id), restoredB = chat.session(for: try tab(1).id)
        try await wait { restoredA.sessionID == firstConversation && restoredB.sessionID == b.sessionID && !restoredA.loadingHistory && !restoredB.loadingHistory }
        XCTAssertTrue(restoredA.showChat); XCTAssertTrue(restoredB.showChat)
        XCTAssertEqual(restoredA.process, processA); XCTAssertEqual(restoredB.process, processB)
        XCTAssertTrue(restoredA.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: first pane\nsecond line" })
        workspace.selectTab(restoredA.id)
        try await app.ready()
        restoredA.draft = "/quit"; chat.submit(restoredA)
        try await wait { !processA.alive && !restoredA.active }
        let exited = try await XCTUnwrap(restoredA.helper).refuses("must not reach shell", conversation: firstConversation)
        XCTAssertTrue(exited)
        XCTAssertTrue(chat.canEnterChat(restoredA))
        chat.chooseChat(true, session: restoredA)
        XCTAssertTrue(restoredA.showChat, "The conversation remains available read-only after exit")
        XCTAssertTrue(processB.alive)
        XCTAssertNil(runtime.helpers[.local]?.error)
        passed = testRun?.failureCount == 0
    }

    func testLayoutsRearrangeFourExistingWindowsWithoutCreatingShells() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        for index in 1..<4 { _ = try app.server(["new-window", "-d", "-n", "tab-\(index)", "/bin/sh"]) }
        try await app.attach(); try await app.ready()
        let workspace = app.workspace
        let original = try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"])
        let windows = try XCTUnwrap(workspace.current).windows
        let originalIDs = Set(workspace.current!.tabs.map(\.id))
        var surfaces: [UUID: UInt] = [:]
        for preset in [LayoutPreset.grid, .single, .columns, .rows, .twoAbove, .grid, .grid] {
            XCTAssertTrue(workspace.applyLayout(preset))
            try await app.wait {
                workspace.current?.layout.paneIDs.count == preset.count &&
                workspace.current?.panes.allSatisfy { pane in
                    pane.activeTab.map { app.runtime.views[$0.id]?.window === app.window && app.runtime.views[$0.id]?.surface != nil } == true
                } == true
            }
            try await Task.sleep(for: .milliseconds(400))
            for tab in workspace.current!.tabs {
                if let surface = app.runtime.views[tab.id]?.surface {
                    let pointer = UInt(bitPattern: Unmanaged.passUnretained(surface as AnyObject).toOpaque())
                    if let previous = surfaces[tab.id] { XCTAssertEqual(pointer, previous) }
                    surfaces[tab.id] = pointer
                }
            }
            XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"]), original)
            XCTAssertEqual(workspace.spaces.filter { $0.structured }.count, 1)
            XCTAssertEqual(Set(workspace.current!.tabs.map(\.id)), originalIDs)
            XCTAssertEqual(workspace.current?.windows.map(\.id), windows.map(\.id))
            XCTAssertEqual(workspace.current?.preset, preset)
        }
        for tab in windows {
            workspace.selectWindow(tab.id)
            try await app.ready()
            let selectedWindow = try await app.query("#{window_id}")
            XCTAssertEqual(selectedWindow, app.target(tab))
            XCTAssertEqual(workspace.current?.layout.paneIDs.count, 4, "Focus must not hide the other tiles")
        }
        _ = try await PresentationTestSupport.capture(app.window, named: "four-existing-tmux-tabs", in: "tmux-layout-validation")
        let oldSelection = try XCTUnwrap(workspace.current?.activeWindow?.id)
        let group = try XCTUnwrap(workspace.current?.windowPresentation?.groups.first { $0.windows.contains(oldSelection) }).id
        workspace.newTab()
        try await app.wait {
            workspace.current?.windows.count == 5 && workspace.current?.activeWindow?.id != oldSelection &&
                workspace.activeTab?.isConnecting == false
        }
        let added = try XCTUnwrap(workspace.current?.activeWindow)
        XCTAssertEqual(workspace.current?.windowPresentation?.groups.first { $0.windows.contains(added.id) }?.id, group)
        XCTAssertEqual(workspace.current?.layout.paneIDs.count, 4)
        app.controller.closeWindow(added.id)
        try await app.wait { workspace.current?.windows.count == 4 && workspace.helper(workspace.current)?.operations == 0 }
        XCTAssertEqual(workspace.current?.layout.paneIDs.count, 4)
        XCTAssertTrue(workspace.applyLayout(.single))
        XCTAssertTrue(workspace.canSplit)
        workspace.split(.columns)
        XCTAssertEqual(workspace.current?.layout.paneIDs.count, 2)
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"]), original)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    func testExistingServerSplitRemainsInsideItsWindow() async throws {
        let app = try TmuxWalkthrough()
        defer { app.close() }
        _ = try app.server(["split-window", "-h", "-t", "%0", "/bin/sh"])
        for _ in 1..<4 { _ = try app.server(["new-window", "-d", "/bin/sh"]) }
        try await app.attach(); try await app.ready()
        let workspace = app.workspace
        let original = try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"])
        let splitWindow = try XCTUnwrap(workspace.current?.windows.first { app.target($0) == "@0" })
        XCTAssertEqual(workspace.current?.layout.paneIDs.count, 2)
        XCTAssertTrue(workspace.applyLayout(.grid))
        try await app.wait { workspace.current?.layout.paneIDs.count == 5 }
        workspace.selectWindow(splitWindow.id)
        XCTAssertTrue(workspace.applyLayout(.single))
        try await app.wait { workspace.current?.layout.paneIDs.count == 2 }
        let zoom = try await app.query("#{window_zoomed_flag}")
        XCTAssertEqual(zoom, "0", "Single changes native tab placement, not server zoom")
        let first = try XCTUnwrap(splitWindow.terminals.first)
        workspace.moveTabToNewSpace(first.id)
        try await app.wait { workspace.spaces.filter { $0.structured }.count == 2 }
        XCTAssertEqual(workspace.current?.windows.first?.terminals.count, 2, "Move the whole window, preserving its existing split")
        XCTAssertFalse(workspace.canApplyLayout(.columns), "One server window cannot supply two native tabs")
        workspace.split(.columns)
        XCTAssertEqual(try app.server(["list-panes", "-s", "-F", "#{window_id}:#{pane_id}:#{pane_pid}"]), original)
        XCTAssertNil(app.runtime.helpers[.local]?.error)
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        try await TestSupport.eventually(timeout: .seconds(15), file: file, line: line,
                                         diagnostic: "tmux chat: \(TerminalRuntime.shared.helpers[.local]?.error ?? "No protocol error")", condition)
    }
}
