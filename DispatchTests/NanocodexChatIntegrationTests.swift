import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

/// Drives a real nanocodex TUI against the loopback Responses fixture, locally
/// and through the SSH helper's control relay. The binary must include the
/// native control prompt admission fix.
@MainActor
final class NanocodexChatIntegrationTests: XCTestCase {
    func testNativePromptSteerQueueStopAndSettings() async throws { try await walkthrough(ssh: false) }
    func testRemotePromptSteerQueueStopAndSettings() async throws { try await walkthrough(ssh: true) }

    private func walkthrough(ssh useSSH: Bool) async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        try DesktopTestSupport.requireUnlocked()
        let fm = FileManager.default
        let nanocodex = TestSupport.tool("nanocodex")
        guard fm.isExecutableFile(atPath: nanocodex) else {
            throw XCTSkip("Link a nanocodex build that includes #681 (0.6.6+) at build/test-tools/bin/nanocodex")
        }
        let state = URL(fileURLWithPath: "/tmp/dispatch-nanocodex-chat-" + UUID().uuidString)
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/codex_fixture.py").path,
                             "serve", "--state", state.path, "--no-hooks", "--delay", "0.04"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("Nanocodex Chat fixture: " + state.path)
        }
        // The fixture writes a placeholder before binding its real port.
        let endpoint = state.appendingPathComponent("endpoint.json")
        func port() -> Int? {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: endpoint)) as? [String: Any])?["port"] as? Int
        }
        try await TestSupport.eventually { (port() ?? 1) > 1 }
        let fixturePort = try XCTUnwrap(port())
        let home = state.appendingPathComponent("home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let runtime = TerminalRuntime.shared, controller = AppDelegate(), previousChat = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        runtime.workspace = controller.workspace; runtime.start(preferences: Preferences())
        let workspace = controller.workspace
        workspace.defaultDirectory = state.appendingPathComponent("work").path
        workspace.onCloseTabs = { runtime.close($0) }; workspace.newSpace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; controller.window = window
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: controller.settings, controller: controller))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        defer { runtime.chat = previousChat }
        // Remote chat needs only Chat permissions: no hooks or installation.
        let ssh = useSSH ? try await SSHTestServer(grant: .init(profile: .full)) : nil
        defer { ssh?.stop() }
        if let ssh { _ = try await ssh.authorize() }
        do { try await scenario(runtime: runtime, workspace: workspace, state: state, nanocodex: nanocodex, home: home, port: fixturePort, ssh: ssh) }
        catch { window.close(); window.contentView = nil; await runtime.stop().value; throw error }
        window.close(); window.contentView = nil
        await runtime.stop().value
    }

    private func scenario(runtime: TerminalRuntime, workspace: Workspace, state: URL, nanocodex: String, home: URL, port fixturePort: Int,
                          ssh: SSHTestServer?) async throws {
        let codexHome = state.appendingPathComponent("codex-home")
        let id = try XCTUnwrap(workspace.activeSurfaceID)
        try await TestSupport.eventually { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        session.manualViewChoice = true
        if let ssh {
            TerminalTestSupport.send("ssh " + (ssh.options + [ssh.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                runtime.ssh.links.values.contains { $0.launch.tabID == id && $0.shellPID != nil }
            }
            TerminalTestSupport.send("cd " + HerdrLaunch.quote(state.appendingPathComponent("work").path), to: terminal)
        }
        let environment = ["HOME=" + home.path, "CODEX_HOME=" + codexHome.path, "OPENAI_API_BASE_URL=http://127.0.0.1:\(fixturePort)/v1",
                           "NANOCODEX_RESPONSES_TRANSPORT=https", "NANOCODEX_COMPUTER=off"]
        TerminalTestSupport.send((["env"] + environment + [nanocodex, "--api-key", "dispatch-fixture"]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        defer { print("Nanocodex final: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        try await TestSupport.eventually(timeout: .seconds(30), diagnostic: "Nanocodex discovery: \(session.status ?? "none")\n\(terminal.agentMenuScreen)") {
            session.active && session.agentID == "nanocodex" && session.sessionID != nil && !session.loadingHistory
                && (ssh == nil) == (session.remoteAgent == nil) && session.helper != nil
        }
        let conversation = try XCTUnwrap(session.sessionID)
        runtime.chat.chooseChat(true, session: session)
        func reply(_ text: String) -> Bool {
            session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text == "Local fixture reply: " + text }
        }
        func users() -> [String] { session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text) }

        // Structured prompts and commands never touch the terminal's own composer draft.
        terminal.insertText("native draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await TestSupport.eventually { terminal.agentMenuScreen.contains("native draft") }
        XCTAssertFalse(session.helperCommands.isEmpty, "The harness reports its native commands")
        let fast = terminal.agentMenuScreen.contains("· fast")
        session.draft = "/fast"; runtime.chat.submit(session)
        try await TestSupport.eventually { session.submissionID == nil && terminal.agentMenuScreen.contains("· fast") != fast }
        XCTAssertNil(session.submissionFailure); XCTAssertNil(session.terminalAttention)
        XCTAssertTrue(session.draft.isEmpty)
        session.draft = "/model unknown-model"; runtime.chat.submit(session)
        try await TestSupport.eventually { session.submissionFailure != nil && session.submissionID == nil }
        XCTAssertEqual(session.draft, "/model unknown-model", "A rejected command keeps its draft")
        session.draft = "first chat prompt"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && reply("first chat prompt") }
        XCTAssertNil(session.optimisticPrompt)
        XCTAssertTrue(terminal.agentMenuScreen.contains("native draft"))
        XCTAssertEqual(users(), ["first chat prompt"])

        // Steering joins the running turn; a queued message waits for it.
        session.draft = "SLOW_RESPONSE tool check"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { session.busy && session.nativeActivity == "working" }
        let running = try await XCTUnwrap(session.helper).native()
        XCTAssertTrue(running.busy, "The native turn is active")
        session.draft = "steer: keep it short"; runtime.chat.sendNow(session)
        session.draft = "queued after steer"; runtime.chat.queue(session)
        try await TestSupport.eventually(timeout: .seconds(30)) { !session.busy && session.queuedMessages.isEmpty && reply("queued after steer") }
        XCTAssertTrue(reply("steer: keep it short"))
        XCTAssertEqual(users(), ["first chat prompt", "SLOW_RESPONSE tool check", "steer: keep it short", "queued after steer"])
        XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.completed && $0.title == "shell_command" })

        // Stop cancels only the active turn and waits for its terminal event.
        session.draft = "SLOW_RESPONSE stop me"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { runtime.chat.canInterrupt(session) }
        XCTAssertTrue(runtime.chat.interrupt(session))
        try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && session.interruptionID == nil }
        XCTAssertNil(session.submissionFailure)
        XCTAssertFalse(reply("SLOW_RESPONSE stop me"))

        // After the first turn only effort can change.
        runtime.chat.openModelPicker(session, column: .effort)
        let picker = try XCTUnwrap(session.modelPicker)
        try await TestSupport.eventually(timeout: .seconds(10)) { !picker.loading && !picker.efforts.isEmpty }
        XCTAssertNil(picker.error)
        XCTAssertEqual(picker.models.map(\.name), [session.model])
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
        try await TestSupport.eventually(timeout: .seconds(10)) { session.modelPicker == nil }
        XCTAssertEqual(session.effort, "low")
        let configured = try await XCTUnwrap(session.helper).native()
        XCTAssertEqual(configured.effort, "low")

        session.draft = "after settings"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && reply("after settings") }
        XCTAssertEqual(session.sessionID, conversation)
        let requests = try String(contentsOf: state.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        XCTAssertTrue(requests.contains("\"effort\": \"low\"") || requests.contains("\"effort\":\"low\""))
    }
}
