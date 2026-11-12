import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class NativeTabCloseTests: XCTestCase {
    /// As the phone's Close: a tab whose every pane runs an agent with its turn over closes without asking; a pane
    /// without one, an agent working or waiting, or one that exited leaves it to the helper's check. A busy server
    /// tab's question names the agent and its state, else nothing.
    func testFinishedAgentsCloseWithoutAskingAndTheQuestionNamesWhatRuns() {
        let chat = TerminalRuntime.shared.chat
        let first = System.uuid(), second = System.uuid()
        defer { chat.close(first); chat.close(second) }
        XCTAssertFalse(AppDelegate.agentsFinished([]))
        XCTAssertFalse(AppDelegate.agentsFinished([first]), "No agent")
        let agent = chat.session(for: first)
        agent.active = true
        XCTAssertTrue(AppDelegate.agentsFinished([first]))
        agent.busy = true
        XCTAssertFalse(AppDelegate.agentsFinished([first]), "Working")
        agent.busy = false
        XCTAssertFalse(AppDelegate.agentsFinished([first, second]), "Every pane")
        let other = chat.session(for: second)
        other.active = true
        XCTAssertTrue(AppDelegate.agentsFinished([first, second]))
        other.agentExited = true
        XCTAssertFalse(AppDelegate.agentsFinished([first, second]), "Exited")

        let tail = " Terminating ends it; Detach keeps it running on the server."
        XCTAssertEqual(AppDelegate.closeQuestion(agent: "Codex", working: true, waiting: false), "Codex is still working." + tail)
        XCTAssertEqual(AppDelegate.closeQuestion(agent: "Claude Code", working: false, waiting: true), "Claude Code is waiting for you." + tail)
        XCTAssertEqual(AppDelegate.closeQuestion(agent: "Pi", working: false, waiting: false), "Pi is still running." + tail)
        XCTAssertEqual(AppDelegate.closeQuestion(agent: nil, working: false, waiting: false), "Something is still running in it." + tail)
    }

    func testPreparedNativeCloseRestoresOnDisconnect() async throws {
        let app = try TmuxWalkthrough(server: false); defer { app.close() }
        try await app.wait { app.workspace.activeTab?.terminal != nil }
        app.workspace.newTab()
        try await app.wait { app.workspace.currentTabs.count == 2 && app.workspace.currentTabs.allSatisfy { $0.terminal != nil } }
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let helper = try XCTUnwrap(app.workspace.helper(containing: tab.id))
        var finish: CheckedContinuation<Void, Never>?
        let task = helper.close(try XCTUnwrap(tab.terminal), policy: .prompt) {
            await withCheckedContinuation { finish = $0 }
        }
        let neighbor = app.workspace.activeSurfaceID
        XCTAssertFalse(app.workspace.allTabIDs.contains(tab.id))
        XCTAssertTrue(ScreenPublication.targets(of: tab.id, workspace: app.workspace, helpers: [helper])
            .contains { $0.terminal == tab.terminal }, "A hidden native chat still publishes the screen its quit checks")
        try await TestSupport.eventually { finish != nil }
        helper.stop(retaining: true)
        XCTAssertTrue(app.workspace.allTabIDs.contains(tab.id), "An unconfirmed quit must remain recoverable offline")
        XCTAssertEqual(app.workspace.activeSurfaceID, neighbor)
        XCTAssertNil(helper.closingSpace(containing: tab.id))
        finish?.resume()
        await task.value
        XCTAssertTrue(app.workspace.allTabIDs.contains(tab.id))
    }

    func testPreparedCloseHidesImmediatelyAndRestoresAfterFailure() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let helper = try XCTUnwrap(app.workspace.helper(containing: tab.id))
        let node = try XCTUnwrap(tab.terminal)
        var finish: CheckedContinuation<Void, any Error>?
        let task = helper.close(node, policy: .prompt) {
            try await withCheckedThrowingContinuation { finish = $0 }
        }
        XCTAssertFalse(app.workspace.allTabIDs.contains(tab.id), "The close publishes before any async work")
        let neighbor = try XCTUnwrap(app.workspace.activeTab?.id)
        XCTAssertNotEqual(neighbor, tab.id)
        XCTAssertNotNil(app.runtime.views[tab.id], "The quitting agent must keep its terminal")
        XCTAssertEqual(app.workspace.space(containingTab: tab.id)?.tabs.first { $0.id == tab.id }?.terminal, node)
        try await TestSupport.eventually { finish != nil }
        // Another topology must not flash the closing tab back into the strip.
        _ = try app.server(["new-window", "-d", "-n", "topology-during-quit", "/bin/sh"])
        try await app.wait { app.workspace.current?.windows.contains { $0.name == "topology-during-quit" } == true }
        XCTAssertFalse(app.workspace.allTabIDs.contains(tab.id))
        finish?.resume(throwing: HerdrFailure("Quit refused"))
        await task.value
        XCTAssertTrue(app.workspace.allTabIDs.contains(tab.id))
        XCTAssertEqual(app.workspace.activeTab?.id, neighbor, "Recovery must not steal focus")
        XCTAssertEqual(helper.error, "Quit refused")
        XCTAssertNil(helper.closingSpace(containing: tab.id))
        XCTAssertNotNil(app.runtime.views[tab.id])
    }

    func testPreparedCloseWaitsBeforeEndingTerminalAndReleasesItAfterward() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let pane = try XCTUnwrap(app.target(tab))
        let helper = try XCTUnwrap(app.workspace.helper(containing: tab.id))
        var finish: CheckedContinuation<Void, Never>?
        let task = helper.close(try XCTUnwrap(tab.terminal), policy: .prompt) {
            await withCheckedContinuation { finish = $0 }
        }
        XCTAssertFalse(app.workspace.allTabIDs.contains(tab.id))
        try await TestSupport.eventually { finish != nil }
        XCTAssertTrue(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").contains(Substring(pane)))
        finish?.resume()
        await task.value
        XCTAssertNil(app.runtime.views[tab.id])
        XCTAssertFalse(try app.server(["list-panes", "-a", "-F", "#{pane_id}"]).split(separator: "\n").contains(Substring(pane)))
        XCTAssertNil(helper.error)
    }

    func testPreparedCloseReleasesAnExitedTerminalWhenItsDeliveryReplyFails() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.activeTab)
        let pane = try XCTUnwrap(app.target(tab))
        let helper = try XCTUnwrap(app.workspace.helper(containing: tab.id))
        var finish: CheckedContinuation<Void, any Error>?
        let task = helper.close(try XCTUnwrap(tab.terminal), policy: .prompt) {
            try await withCheckedThrowingContinuation { finish = $0 }
        }
        try await TestSupport.eventually { finish != nil }
        _ = try app.server(["kill-pane", "-t", pane])
        _ = try app.server(["rename-window", "-t", "edge:keeper", "after-exit"])
        try await app.wait { app.workspace.current?.windows.contains { $0.name == "after-exit" } == true }
        finish?.resume(throwing: HerdrFailure("The quit reply arrived after the terminal exited"))
        await task.value
        XCTAssertFalse(app.workspace.allTabIDs.contains(tab.id))
        XCTAssertNil(app.runtime.views[tab.id], "An exited terminal must not retain a view waiting for another topology")
        XCTAssertNil(helper.closingSpace(containing: tab.id))
        XCTAssertNil(helper.error, "A terminal already confirmed absent needs no failed-close recovery")
    }

    func testCommandWTerminatesIdleTmuxWindowAndAllItsPanes() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertEqual(tab.terminals.count, 2)
        let window = try XCTUnwrap(app.target(tab))
        app.controller.closeCurrentTab()
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
        try await app.wait { (try? app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window))) == false }
        XCTAssertTrue(app.workspace.detached.isEmpty)
    }

    /// ⌘W on a busy tmux window asks, as the phone's Close; Detach keeps every kind of job running.
    func testCommandWPreservesForegroundBackgroundAndStoppedTmuxJobs() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let answerer = CloseConfirmationAnswerer(server: CloseConfirmationAnswerer.detach); defer { answerer.stop() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        try await app.attach(); try await app.ready()
        for command in ["sleep 120", "sleep 120 &", "sleep 120 & kill -STOP $!"] {
            let pane = try app.server(["new-window", "-P", "-F", "#{pane_id}", "/bin/sh"]).trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try app.server(["split-window", "-d", "-t", pane, "/bin/sh"])
            _ = try app.server(["send-keys", "-t", pane, command, "Enter"])
            try await app.wait { app.workspace.spaces.flatMap(\.windows).contains { $0.terminals.count == 2 && $0.terminals.contains { app.target($0) == pane } } }
            let tab = try XCTUnwrap(app.workspace.spaces.flatMap(\.windows).first { $0.terminals.contains { app.target($0) == pane } })
            let window = try XCTUnwrap(app.target(tab))
            let original = try app.server(["list-panes", "-t", window, "-F", "#{pane_id}:#{pane_pid}"])
            app.workspace.selectWindow(tab.id)
            let asked = answerer.serverAnswered
            app.controller.closeCurrentTab()
            // Gone at once; the question comes with the helper's answer.
            try await app.wait { answerer.serverAnswered == asked + 1 }
            try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
            XCTAssertEqual(try app.server(["list-panes", "-t", window, "-F", "#{pane_id}:#{pane_pid}"]), original)
        }
        XCTAssertTrue(answerer.questions.allSatisfy { $0.contains("Detach keeps it running") }, "\(answerer.questions)")
    }

    /// The same question's other answers: Cancel shows the tab again with its work; Terminate ends the window.
    func testCommandWOnABusyTmuxWindowCancelsOrTerminates() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let pane = try app.server(["new-window", "-P", "-F", "#{pane_id}", "/bin/sh"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try app.server(["send-keys", "-t", pane, "sleep 120", "Enter"])
        try await app.wait { (try? app.server(["display-message", "-p", "-t", pane, "#{pane_current_command}"]))?.hasPrefix("sleep") == true }
        try await app.wait { app.workspace.spaces.flatMap(\.windows).contains { $0.terminals.contains { app.target($0) == pane } } }
        let tab = try XCTUnwrap(app.workspace.spaces.flatMap(\.windows).first { $0.terminals.contains { app.target($0) == pane } })
        let window = try XCTUnwrap(app.target(tab))
        app.workspace.selectWindow(tab.id)
        let cancel = CloseConfirmationAnswerer(server: CloseConfirmationAnswerer.cancel)
        app.controller.closeCurrentTab()
        try await app.wait { cancel.serverAnswered == 1 }
        cancel.stop()
        try await app.wait { app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
        XCTAssertTrue(app.workspace.detached.isEmpty, "Cancel neither detaches nor ends it")
        XCTAssertTrue(try app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window)))
        let terminate = CloseConfirmationAnswerer(server: CloseConfirmationAnswerer.terminate); defer { terminate.stop() }
        app.workspace.selectWindow(tab.id)
        app.controller.closeCurrentTab()
        try await app.wait { (try? app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window))) == false }
        XCTAssertEqual(terminate.serverAnswered, 1)
        XCTAssertTrue(app.workspace.detached.isEmpty)
    }

    func testLocalHerdrCloseTerminatesIdleButDetachesBackgroundJob() async throws {
        try await checkHerdr(remote: false)
    }

    func testClosingIdlePanePreservesHiddenSiblingWork() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        _ = try app.server(["split-window", "-d", "-t", "edge:0", "/bin/sh"])
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow)
        XCTAssertEqual(tab.terminals.count, 3)
        let hidden = tab.terminals[0], idle = tab.terminals[1]
        let pane = try XCTUnwrap(app.target(hidden)), window = try XCTUnwrap(app.target(tab))
        _ = try app.server(["send-keys", "-t", pane, "sleep 120 &", "Enter"])
        app.controller.detachTab(hidden.id)
        app.controller.closeTab(idle.id)
        try await app.wait { (try? app.server(["list-panes", "-t", window, "-F", "#{pane_id}"]).split(separator: "\n").count) == 2 }
        // The window with the hidden pane's job asks; Detach keeps that work.
        let answerer = CloseConfirmationAnswerer(); defer { answerer.stop() }
        app.controller.closeWindow(tab.id)
        try await app.wait { answerer.serverAnswered == 1 }
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == tab.id } }
        XCTAssertEqual(try app.server(["list-panes", "-t", window, "-F", "#{pane_id}"]).split(separator: "\n").count, 2)
    }

    func testRemoteTmuxCloseTerminatesIdleAndPreservesBackgroundJob() async throws {
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(); defer { server.stop() }
        _ = try app.server(["new-window", "-d", "-n", "keeper", "/bin/sh"])
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
        }
        try await app.attach(); try await app.ready()
        let tab = try XCTUnwrap(app.workspace.current?.activeWindow), window = try XCTUnwrap(app.target(tab))
        app.controller.closeCurrentTab()
        try await app.wait { (try? app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(window))) == false }
        let busy = try XCTUnwrap(app.workspace.current?.activeWindow), busyWindow = try XCTUnwrap(app.target(busy))
        let pane = try XCTUnwrap(busy.terminals.first.flatMap { app.target($0) })
        _ = try app.server(["send-keys", "-t", pane, "sleep 120 & printf 'JOB_%s\\n' STARTED", "Enter"])
        try await app.wait { (try? app.server(["capture-pane", "-p", "-t", pane]).contains("JOB_STARTED")) == true }
        let answerer = CloseConfirmationAnswerer(server: CloseConfirmationAnswerer.detach); defer { answerer.stop() }
        app.controller.closeCurrentTab()
        try await app.wait { answerer.serverAnswered == 1 }
        try await app.wait { !app.workspace.spaces.flatMap(\.windows).contains { $0.id == busy.id } }
        XCTAssertTrue(try app.server(["list-windows", "-F", "#{window_id}"]).split(separator: "\n").contains(Substring(busyWindow)))
    }

    func testRemoteHerdrCloseTerminatesIdleButDetachesBackgroundJob() async throws {
        try await checkHerdr(remote: true)
    }

    private func checkHerdr(remote: Bool) async throws {
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let server = remote ? try await SSHTestServer() : nil
        defer { server?.stop() }
        let root = server?.root ?? URL(fileURLWithPath: "/tmp/close-herdr-\(System.uuid().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("herdr.sock").path
        defer {
            _ = try? HerdrSocket(path: socket).request("server.stop")
            if server == nil { try? FileManager.default.removeItem(at: root) }
        }
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { app.runtime.views[source]?.surface != nil }
        let origin = try XCTUnwrap(app.runtime.views[source])
        if let server {
            TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: origin)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                app.runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil }
            }
        }
        TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(root.path)
            + "; export XDG_STATE_HOME=" + HerdrLaunch.quote(root.path) + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: origin)
        try await app.wait { app.workspace.current?.shows("herdr") == true }
        let busy = try XCTUnwrap(app.workspace.activeTab), busyTab = try XCTUnwrap(app.workspace.activeWindowKey)
        let surface = try XCTUnwrap(HerdrTestSupport.panes(app.workspace, socket: socket).first)
        try await app.wait { app.runtime.views[surface.id]?.surface != nil }
        let view = try XCTUnwrap(app.runtime.views[surface.id])
        TerminalTestSupport.send("sleep 120 & printf 'JOB_%s\\n' STARTED", to: view)
        try await app.wait { TerminalTestSupport.screen(terminal: view).contains("JOB_STARTED") }
        app.workspace.newTab()
        try await app.wait {
            app.workspace.activeWindowKey != busyTab && app.workspace.activeTab?.isConnecting == false
                && (try? HerdrTestSupport.panes(app.workspace, socket: socket))?.isEmpty == false
        }
        let idle = try XCTUnwrap(app.workspace.activeTab), idleTab = try XCTUnwrap(app.workspace.activeWindowKey)
        let idleSurface = try XCTUnwrap(HerdrTestSupport.panes(app.workspace, socket: socket).first)
        try await app.wait { app.runtime.views[idleSurface.id]?.surface != nil }
        let idleView = try XCTUnwrap(app.runtime.views[idleSurface.id])
        TerminalTestSupport.send("printf 'IDLE_%s\\n' READY", to: idleView)
        try await app.wait { TerminalTestSupport.screen(terminal: idleView).contains("IDLE_READY") }
        app.controller.closeCurrentTab()
        try await app.wait { !app.workspace.allTabIDs.contains(idle.id) }
        // Remote controls update the sidebar optimistically before the server replies.
        try await app.wait {
            guard let data = try? HerdrSocket(path: socket).request("session.snapshot"),
                  let snapshot = try? HerdrRPC.snapshot(from: data) else { return false }
            return !snapshot.tabs.contains { $0.tab_id == idleTab }
        }
        app.workspace.selectTab(busy.id)
        let answerer = CloseConfirmationAnswerer(server: CloseConfirmationAnswerer.detach); defer { answerer.stop() }
        app.controller.closeCurrentTab()
        try await app.wait { answerer.serverAnswered == 1 }
        try await app.wait { !app.workspace.allTabIDs.contains(busy.id) }
        let retained = try HerdrRPC.snapshot(from: HerdrSocket(path: socket).request("session.snapshot"))
        XCTAssertTrue(retained.tabs.contains { $0.tab_id == busyTab })
    }
}
