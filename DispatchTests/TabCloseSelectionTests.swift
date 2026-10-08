import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class TabCloseSelectionTests: XCTestCase {
    func testNativeCloseSelection() async throws { try await exercise(.native) }
    func testSSHCloseSelection() async throws {
        try await exercise(.native, remote: true)
    }
    func testTmuxCloseSelection() async throws { try await exercise(.tmux) }
    func testRemoteTmuxCloseSelection() async throws {
        try await exercise(.tmux, remote: true)
    }
    func testHerdrCloseSelection() async throws {
        try await exercise(.herdr)
    }
    func testRemoteHerdrCloseSelection() async throws {
        try await exercise(.herdr, remote: true)
    }

    func testCloseConfirmationTracksLiveCommandsAndIdleShells() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(app.runtime.views[id])
        TerminalTestSupport.send("printf 'CLOSE_%s\\n' READY", to: terminal)
        try await app.wait { TerminalTestSupport.screen(terminal: terminal).contains("CLOSE_READY") }
        try await app.wait { !app.controller.needsCloseConfirmation([id]) }
        TerminalTestSupport.send("sleep 60", to: terminal)
        try await app.wait { app.controller.needsCloseConfirmation([id]) }
        XCTAssertTrue(app.controller.needsCloseConfirmation([id], detaching: true), "Window close and Quit still protect local commands")
        TerminalTestSupport.key(8, "c", terminal, modifiers: .control)
        try await app.wait { !app.controller.needsCloseConfirmation([id]) }
        app.controller.closeTab(id)
        XCTAssertFalse(app.workspace.allTabIDs.contains(id))
    }

    func testTmuxDetachDoesNotRequireConfirmation() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let before = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        XCTAssertFalse(app.controller.needsCloseConfirmation([tab.id], detaching: true))
        app.controller.detachTab(tab.id)
        try await app.wait { !app.workspace.allTabIDs.contains(tab.id) }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), before)
    }

    func testDetachPendingTmuxTabKeepsItDetachedAfterCreationAndRestoresSameProcess() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        try await app.attach(); try await app.ready()
        app.workspace.newTab()
        let pending = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertEqual(app.workspace.activeTab?.isConnecting, true, "The window is still being created")
        let shown = Set(app.visiblePanes)
        app.controller.closeWindow(pending.id)
        XCTAssertFalse(app.workspace.current?.windows.contains { $0.id == pending.id } ?? true)
        try await app.wait { !app.workspace.detached.isEmpty }
        let detached = try XCTUnwrap(app.workspace.detached.first?.id)
        // The server created its window anyway; it stays detached, not shown.
        try await TestSupport.eventually(diagnostic: "panes=\((try? app.server(["list-panes", "-a", "-F", "#{session_name}:#{window_id}:#{pane_id}"])) ?? "-") shown=\(shown) detached=\(app.workspace.detached.map(\.name))") {
            (try? app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").count) == shown.count + 1
        }
        XCTAssertEqual(Set(app.visiblePanes), shown)
        let processes = try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"])
        app.workspace.restoreDetached([detached])
        try await app.wait { app.workspace.detached.allSatisfy { $0.id != detached } && app.visiblePanes.count == shown.count + 1 }
        XCTAssertEqual(try app.server(["list-panes", "-a", "-F", "#{pane_id}:#{pane_pid}"]), processes)
        XCTAssertTrue(shown.isStrictSubset(of: Set(app.visiblePanes)))
    }

    private enum Backend { case native, tmux, herdr }
    private func exercise(_ backend: Backend, remote: Bool = false) async throws {
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        app.window.delegate = app.controller
        try await TestSupport.eventually(diagnostic: "Test window activation: key=\(app.window.isKeyWindow), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), visible=\(app.window.isVisible), onSpace=\(app.window.isOnActiveSpace)") {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            app.window.makeKeyAndOrderFront(nil)
            return app.window.isKeyWindow && NSApp.isActive
        }
        let server = remote ? try await SSHTestServer() : nil
        defer { server?.stop() }
        let root = URL(fileURLWithPath: "/tmp/hc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock").path
        defer {
            if backend == .herdr { _ = try? HerdrSocket(path: socket).request("server.stop") }
            try? FileManager.default.removeItem(at: root)
        }
        let gateway = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { app.runtime.views[gateway].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(app.runtime.views[gateway])
        if let server {
            TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                app.runtime.ssh.links.values.contains { $0.launch.tabID == gateway && $0.shellPID != nil }
            }
        }
        if backend == .tmux { try await app.attach(); try await app.ready() }
        if backend == .herdr {
            let launch = "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); herdr"
            TerminalTestSupport.send(launch, to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        }
        let space = try XCTUnwrap(app.workspace.current?.id)
        func tabs() -> [UUID] { app.workspace.currentTabs.map(\.id) }
        func close(_ id: UUID) throws {
            // A multiplexer window (structured space) closes as a window, a native tab as a tab.
            if app.workspace.current?.structured == true {
                let window = try XCTUnwrap(app.workspace.spaces.flatMap(\.windows).first { $0.terminals.contains { $0.id == id } })
                app.controller.closeWindow(window.id)
            } else { app.controller.closeTab(id) }
        }
        var check = 0
        func settled(on id: UUID) async throws {
            check += 1
            try await TestSupport.eventually(diagnostic: "Close-selection stage \(check): expected \(id), selected \(String(describing: app.workspace.activeTab?.id)), tabs \(tabs()), spaces \(app.workspace.spaces.map { ($0.name, $0.tabs.map(\.id)) })") {
                app.workspace.activeTab?.id == id
            }
            let tab = try XCTUnwrap(app.workspace.activeTab)
            if backend == .tmux, app.workspace.current?.shows("tmux") == true {
                try await TestSupport.eventually { app.workspace.current?.activeWindow.flatMap(app.target) != nil }
                let window = try XCTUnwrap(app.workspace.current?.activeWindow.flatMap(app.target))
                let actual = try await app.query("#{window_id}").trimmingCharacters(in: .whitespacesAndNewlines)
                XCTAssertEqual(actual, window, "The server must agree with native selection")
            } else if backend == .herdr, app.workspace.current?.shows("herdr") == true {
                struct Result: Decodable { let snapshot: HerdrSnapshot }
                try await TestSupport.eventually {
                    guard let window = app.workspace.activeWindowKey, !window.hasPrefix("pending:") else { return false }
                    return try JSONDecoder().decode(Result.self, from: HerdrSocket(path: socket).request("session.snapshot")).snapshot.focused_tab_id == window
                }
            }
            try await TestSupport.eventually(diagnostic: "Stage \(check), selected \(String(describing: app.workspace.activeTab?.id)), expected \(id), window \(String(describing: app.workspace.current?.selectedContainer)), refs \(app.workspace.currentTabs.map { String(describing: app.target($0)) + ":connecting=\($0.isConnecting)" }), tabs \(tabs()), target \(String(describing: app.runtime.views[tab.focusedSurfaceID])), mounted \(app.runtime.views[tab.focusedSurfaceID]?.window === app.window), presented \(String(describing: app.runtime.views[tab.focusedSurfaceID]?.isPresented)), first responder \(String(describing: app.window.firstResponder))") {
                guard let current = app.workspace.activeTab, current.id == id,
                      let view = app.runtime.views[current.focusedSurfaceID] else { return false }
                return app.window.firstResponder === view && view.window === app.window
            }
        }
        for count in 2...4 {
            app.workspace.newTab()
            try await app.wait { tabs().count == count }
        }
        let original = tabs()
        // Visit a non-neighbor last to reproduce tmux's history-based fallback.
        app.workspace.selectTab(original[2]); app.workspace.selectTab(original[0])
        try await settled(on: original[0])
        app.controller.closeCurrentTab()
        try await app.wait { tabs().count == 3 }
        try await settled(on: original[1])

        if backend == .tmux {
            let windows = try XCTUnwrap(app.workspace.current?.windows)
            guard windows.count >= 3 else { return XCTFail("Expected 3 windows, the app shows \(windows.count)") }
            let moved = try XCTUnwrap(windows.first { $0.terminals.contains { $0.id == original[3] } })
            let target = try XCTUnwrap(windows.first { $0.terminals.contains { $0.id == original[2] } })
            XCTAssertTrue(app.workspace.moveWindow(moved.id, beside: target.id))
        } else {
            XCTAssertTrue(app.workspace.moveTab(original[3], to: try XCTUnwrap(app.workspace.current?.focusedPane), relativeTo: original[1], after: true))
        }
        try await app.wait { tabs() == [original[1], original[3], original[2]] }
        app.workspace.selectTab(original[1])
        try await settled(on: original[1])
        try close(original[1])
        try await app.wait { tabs().count == 2 }
        try await settled(on: original[3])
        try close(original[2])
        try await app.wait { tabs() == [original[3]] }
        try await settled(on: original[3])

        for count in 2...4 {
            app.workspace.newTab()
            try await app.wait { tabs().count == count }
        }
        let final = tabs()
        app.workspace.selectTab(final[3]); app.controller.closeCurrentTab()
        try await app.wait { tabs().count == 3 }
        try await settled(on: final[2])
        app.workspace.selectTab(final[0])
        app.controller.closeCurrentTab()
        try await app.wait { tabs().count == 2 }
        try await settled(on: final[1])
        app.controller.closeCurrentTab()
        try await app.wait { tabs() == [final[2]] }
        try await settled(on: final[2])

        // Closing a selected tab in another space must not steal native focus.
        app.workspace.newTab()
        try await app.wait { tabs().count == 2 }
        let background = try XCTUnwrap(tabs().last)
        // A remote snapshot can list a new tab before its focus reply arrives.
        try await settled(on: background)
        app.workspace.newLocalSpace()
        let local = try XCTUnwrap(app.workspace.activeTab?.id)
        try await settled(on: local)
        try close(background)
        try await app.wait { app.workspace.spaces.first { $0.id == space }?.tabs.count == 1 }
        XCTAssertEqual(app.workspace.activeTab?.id, local)
        app.workspace.selectSpace(space)
        try await settled(on: final[2])
        XCTAssertTrue(app.runtime.helpers.values.allSatisfy { $0.error == nil })
    }
}
