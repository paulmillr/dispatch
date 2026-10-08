import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class HerdrChatIntegrationTests: XCTestCase {
    func testChatFollowsRealHerdrTerminalsAcrossTabsSplitsMovesAndReattach() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        guard FileManager.default.isExecutableFile(atPath: TestSupport.tool("herdr")) else { throw XCTSkip("Install herdr for integration tests") }
        let fixture = try CodexEndpointFixture(prefix: "dispatch-herdr-chat-", delay: 0.05, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let root = URL(fileURLWithPath: "/tmp/hc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let socket = root.appendingPathComponent("herdr.sock").path
        let runtime = TerminalRuntime.shared, controller = AppDelegate(), previousChat = runtime.chat
        let workspace = controller.workspace
        runtime.chat = ChatCoordinator(enabled: true); runtime.workspace = workspace
        runtime.start(preferences: Preferences())
        workspace.onCloseTabs = { runtime.close($0) }
        workspace.defaultDirectory = fixture.state.appendingPathComponent("work").path
        workspace.newLocalSpace()
        let window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; runtime.stop(); runtime.chat = previousChat
            _ = try? HerdrSocket(path: socket).request("server.stop")
            CodexTestSupport.removeFixture(root)
        }
        func terminal(_ id: UUID) async throws -> TerminalView {
            try await TestSupport.eventually { runtime.views[id]?.surface != nil }
            return runtime.views[id]!
        }
        let launch = "export PATH=\(TestSupport.path):/usr/bin:/bin:$PATH; export XDG_CONFIG_HOME=\(HerdrLaunch.quote(root.path)); export XDG_STATE_HOME=\(HerdrLaunch.quote(root.path)); export HERDR_SOCKET_PATH=\(HerdrLaunch.quote(socket)); herdr"
        let source = try await terminal(workspace.activeTab!.id)
        TerminalTestSupport.send(launch, to: source)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: source)) { workspace.current?.shows("herdr") == true }
        let tabA = try XCTUnwrap(workspace.current?.activeWindow).id, surfaceA = try XCTUnwrap(HerdrTestSupport.panes(workspace, socket: socket).first)
        func start(_ id: UUID) async throws -> (TerminalView, ChatSession) {
            let view = try await terminal(id)
            TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary, hookDriver: true), to: view)
            let session = runtime.chat.session(for: id)
            // Process discovery can precede the CLI's first input frame.
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: view)) {
                session.active && !session.loadingHistory && AgentModelMenu.containsModel(view.agentMenuScreen, slug: "dispatch-fixture", name: "Dispatch fixture") &&
                    view.agentMenuScreen.components(separatedBy: .newlines).contains {
                        $0.trimmingCharacters(in: .whitespaces).hasPrefix("›")
                    }
            }
            return (view, session)
        }
        func reply(_ session: ChatSession, _ prompt: String, repeatedSubmit: Bool = false) async throws {
            // Moving a pane can finish visually before discovery verifies its
            // new location. Match the composer's readiness before direct input.
            try await TestSupport.eventually(timeout: .seconds(15)) {
                session.active && !session.inputBlocked && !session.loadingHistory
                    && session.activityCheck == nil && !session.busy && session.submissionID == nil
            }
            session.draft = prompt; runtime.chat.submit(session)
            if repeatedSubmit { runtime.chat.submit(session) }
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(session.status ?? "No chat reply") busy=\(session.busy) sending=\(session.submissionID != nil) draft=\(session.draft)\n\(runtime.views[session.id].map { TerminalTestSupport.screen(terminal: $0) } ?? "missing terminal")") {
                !session.busy && session.submissionID == nil && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + prompt }
            }
            XCTAssertEqual(session.draft, "")
        }
        let (first, a) = try await start(surfaceA.id)
        let firstPTY = first.surface
        XCTAssertNotEqual(a.id, tabA, "The chat belongs to the inner terminal, not its container tab")
        // Launching the real server/agent can change the key window during a
        // desktop test run. Menu shortcuts deliberately require our window.
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { window.isKeyWindow }
        let menu = NSMenuItem(title: "Chat", action: #selector(AppDelegate.toggleChat), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(menu))
        controller.toggleChat()
        try await TestSupport.eventually(diagnostic: "chat=\(a.showChat), active=\(a.active), selected=\(String(describing: workspace.activeSurfaceID)), expected=\(a.id), responder=\(String(describing: window.firstResponder)), key=\(window.isKeyWindow), editors=\(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: window.contentView!).count)") { a.showChat && window.firstResponder is ChatComposer.ComposerTextView }
        XCTAssertFalse(first.isPresented, "Chat hides the bridge without destroying its PTY")
        a.draft = "/status"; runtime.chat.submit(a)
        XCTAssertFalse(a.awaitingPromptAck, "Native commands do not acknowledge a model prompt")
        XCTAssertNil(a.optimisticPrompt)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "\(String(describing: a.commandResult))\n\(first.agentMenuScreen)") {
            a.command == nil && a.commandResult?.title == "Session status"
        }
        XCTAssertTrue(a.showChat)
        XCTAssertEqual(a.draft, "")
        runtime.chat.chooseChat(true, session: a)
        XCTAssertFalse(a.busy, "Returning from /status must not show thinking")
        XCTAssertFalse(a.awaitingPromptAck)
        XCTAssertNil(a.promptBoundary)
        try await reply(a, "first line\nsecond line · caffè 漢字", repeatedSubmit: true)
        XCTAssertEqual(a.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
        a.draft = "saved first draft"
        let conversationA = a.sessionID

        workspace.newTab()
        try await TestSupport.eventually { workspace.current?.activeWindow?.id != tabA && workspace.activeTab?.isConnecting == false }
        let tabB = try XCTUnwrap(workspace.current?.activeWindow).id, surfaceB = try XCTUnwrap(HerdrTestSupport.panes(workspace, socket: socket).first)
        let (_, b) = try await start(surfaceB.id)
        runtime.chat.chooseChat(true, session: b)
        try await reply(b, "second terminal only")
        XCTAssertNotEqual(a.process, b.process); XCTAssertNotEqual(a.sessionID, b.sessionID)
        b.draft = "saved second draft"
        // Each terminal's binding authorizes only its own conversation.
        let crossed = try await XCTUnwrap(b.helper).refuses("must not cross terminals", conversation: try XCTUnwrap(conversationA))
        XCTAssertTrue(crossed, "Another pane's agent must never take this conversation's input")

        workspace.selectWindow(tabA)
        try await TestSupport.eventually { workspace.activeSurfaceID == a.id && window.firstResponder is ChatComposer.ComposerTextView }
        XCTAssertEqual(a.draft, "saved first draft"); XCTAssertTrue(first.surface === firstPTY)
        _ = try api(socket, "pane.split", ["target_pane_id": surfaceA.pane, "direction": "right", "cwd": root.path, "focus": true])
        try await TestSupport.eventually { try HerdrTestSupport.panes(workspace, socket: socket).count == 2 }
        let split = try XCTUnwrap(HerdrTestSupport.panes(workspace, socket: socket).first { $0.id != a.id })
        XCTAssertEqual(workspace.directory(forSurface: split.id).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, root.resolvingSymlinksInPath().path)
        let (splitView, c) = try await start(split.id)
        let splitPTY = splitView.surface
        runtime.chat.chooseChat(true, session: c)
        try await reply(c, "split terminal only")
        try await TestSupport.eventually {
            !c.busy && !c.awaitingPromptAck && !c.loadingHistory && c.activityCheck == nil && c.submissionID == nil
        }
        c.draft = "sending while editing"; runtime.chat.submit(c)
        c.draft = "next draft while send is pending"
        try await TestSupport.eventually(timeout: .seconds(10)) {
            c.submissionID == nil && !c.busy && c.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: sending while editing" }
        }
        XCTAssertEqual(c.draft, "next draft while send is pending")
        c.draft = "saved split draft"
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { window.isKeyWindow }
        workspace.cyclePane(-1)
        try await TestSupport.eventually { workspace.activeSurfaceID == a.id }
        controller.toggleChat()
        try await TestSupport.eventually(diagnostic: "chat=\(a.showChat), key=\(window.isKeyWindow), focused=\(String(describing: workspace.activeSurfaceID)), responder=\(String(describing: window.firstResponder))") { !a.showChat && window.firstResponder === first }
        XCTAssertTrue(c.showChat, "The shortcut affects only the focused inner pane")
        controller.toggleChat()
        try await TestSupport.eventually { a.showChat && window.firstResponder is ChatComposer.ComposerTextView }
        let composers = PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: window.contentView!)
        let splitComposer = try XCTUnwrap(composers.first { $0.string == c.draft })
        window.makeFirstResponder(splitComposer)
        try await TestSupport.eventually { workspace.activeSurfaceID == c.id }
        XCTAssertEqual(a.draft, "saved first draft")
        try await Task.sleep(for: .milliseconds(350))
        _ = try await PresentationTestSupport.capture(window, named: "herdr-split-chat", in: "herdr-chat")

        workspace.newTab()
        try await TestSupport.eventually {
            workspace.current?.windowCount == 3 && workspace.current?.tabs.allSatisfy { !$0.isConnecting } == true
        }
        workspace.selectSurface(c.id)
        for preset in [LayoutPreset.rows, .twoAbove, .columns] {
            XCTAssertTrue(workspace.applyLayout(preset))
            try await TestSupport.eventually(timeout: .seconds(10), diagnostic: "\(runtime.helpers[.local]?.error.map { String(describing: $0) } ?? "none")") {
                workspace.current?.preset == preset && workspace.current?.numberedPaneIDs.count == preset.count
            }
            XCTAssertTrue(runtime.chat.session(for: a.id) === a)
            XCTAssertTrue(runtime.chat.session(for: c.id) === c)
            XCTAssertTrue(first.surface === firstPTY); XCTAssertTrue(splitView.surface === splitPTY)
            XCTAssertEqual(a.draft, "saved first draft"); XCTAssertEqual(c.draft, "saved split draft")
            XCTAssertEqual(workspace.activeSurfaceID, c.id)
        }
        try await reply(c, "after changing layouts")
        c.draft = "saved split draft"

        // Server-side movement changes pane/tab/space IDs while the terminal and
        // its conversation, draft, and native PTY must retain their identity.
        let movedName = workspace.nextSpaceName
        controller.movePaneToNewSpace(c.id)
        try await TestSupport.eventually { workspace.current?.name == movedName && workspace.activeSurfaceID == c.id }
        XCTAssertTrue(runtime.chat.session(for: c.id) === c)
        XCTAssertTrue(runtime.views[c.id] === splitView)
        XCTAssertTrue(splitView.surface === splitPTY)
        XCTAssertEqual(c.draft, "saved split draft")
        try await reply(c, "after moving spaces")
        workspace.newLocalSpace()
        let local = workspace.activeTab!.id
        _ = try await terminal(local)
        XCTAssertFalse(controller.validateMenuItem(menu), "A local shell must not inherit the herdr agent")
        workspace.selectWindow(tabB)
        try await TestSupport.eventually { workspace.activeSurfaceID == b.id }
        XCTAssertEqual(b.draft, "saved second draft")

        // The old synthetic hook uses the shipping transport: a sibling's actual
        // descendant cannot claim A's session, even with the same inherited route.
        let event = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PermissionRequest", "session_id": a.sessionID!,
            "tool_name": "Bash", "tool_input": ["command": "synthetic fixture approval"], "turn_id": "approval", "tool_use_id": "herdr-tool"])
        let wrong = try await fixture.hook(pid: XCTUnwrap(b.process).pid, payload: event)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: wrong) as? [String: String], [:])
        XCTAssertTrue(a.approvals.isEmpty)
        let owner = try XCTUnwrap(a.process).pid
        let request = Task { try await fixture.hook(pid: owner, payload: event) }
        defer { request.cancel() }
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: a.status ?? "No pending approval") { a.approvals.contains(where: \.pending) }
        let approval = try XCTUnwrap(a.approvals.first(where: \.pending))
        XCTAssertTrue(b.approvals.isEmpty)
        XCTAssertEqual(workspace.activeSurfaceID, b.id, "An approval in another tab must not steal focus")
        try await Task.sleep(for: .milliseconds(350))
        let attention = try await PresentationTestSupport.capture(window, named: "herdr-chat-approval", in: "herdr-chat").text()
        XCTAssertTrue(attention.contains("waiting for input"), attention)

        workspace.selectWindow(tabA)
        let container = try XCTUnwrap(workspace.current?.containers.first { $0.id == tabA })
        workspace.helper(workspace.current)?.close(container.node, policy: .detach)
        XCTAssertFalse(approval.pending, "Detaching releases a pending approval back to the terminal")
        let released = try await request.value
        XCTAssertEqual(try JSONSerialization.jsonObject(with: released) as? [String: String], [:])
        XCTAssertNil(runtime.chat.sessions[a.id])
        XCTAssertTrue(a.process!.alive, "Detaching must leave the server-owned agent running")
        a.draft = "must not send after detach"; runtime.chat.submit(a)
        XCTAssertEqual(a.draft, "must not send after detach")
        workspace.selectTab(local)
        TerminalTestSupport.send(launch, to: runtime.views[local]!)
        try await TestSupport.eventually(timeout: .seconds(15)) { workspace.spaces.flatMap(\.tabs).contains { $0.surfaceIDs.contains(a.id) } }
        workspace.selectSurface(a.id)
        let attached = runtime.chat.session(for: a.id)
        try await TestSupport.eventually(timeout: .seconds(15)) { attached.active && attached.sessionID == conversationA && !attached.loadingHistory }
        XCTAssertFalse(attached === a)
        try await reply(attached, "after reattach")
        let activeProcess = try XCTUnwrap(attached.process)
        attached.draft = "/quit"; runtime.chat.sendFromComposer(attached)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: attached.status ?? "Waiting for /quit") {
            !activeProcess.alive && !attached.active
        }
        XCTAssertTrue(runtime.chat.canEnterChat(attached), "Exited herdr agents retain readable history")
        attached.draft = "must not reach shell"; runtime.chat.submit(attached)
        XCTAssertEqual(attached.draft, "must not reach shell")

        // A transport failure must preserve a draft even if the cached process
        // association has not yet observed the server shutdown.
        workspace.selectSurface(b.id)
        _ = try api(socket, "server.stop")
        b.draft = "preserve on disconnect"; runtime.chat.submit(b)
        try await TestSupport.eventually { b.submissionID == nil }
        XCTAssertEqual(b.draft, "preserve on disconnect")
        try await TestSupport.eventually(diagnostic: "Stopped Herdr chat: retained=\(runtime.chat.sessions[b.id] === b), active=\(b.active), current=\(String(describing: runtime.chat.sessions[b.id]?.active)), process=\(String(describing: b.process?.alive)), helper=\(String(describing: b.helper?.route)), status=\(String(describing: b.status))") { !b.active }
        XCTAssertTrue(runtime.chat.canEnterChat(b), "A stopped server must not hide retained history")
        passed = true
    }

    private func api(_ path: String, _ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let data = try HerdrSocket(path: path).request(method, params: JSONSerialization.data(withJSONObject: params))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
