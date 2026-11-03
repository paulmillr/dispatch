import AppKit
import XCTest
@testable import DispatchApp

/// Side conversations of agents with custom configurations: they run on the parent's own provider,
/// model and credentials (docs/security.md, Side conversations), and a Codex profile says why it
/// stays in the terminal.
@MainActor
final class ChatSideCustomConfigTests: XCTestCase {
    /// The parent runs on a provider, model and effort given only as `-c` options, authenticated by a
    /// variable only its environment holds; the configuration file's default provider reaches nothing.
    func testCodexSideRunsOnTheParentsOverriddenProviderModelAndCredential() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-side-config-", delay: 0.01, hooks: false,
            state: URL(fileURLWithPath: "/tmp/dispatch-q-" + System.uuid().uuidString.prefix(8)))
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let endpoint = try XCTUnwrap(JSONSerialization.jsonObject(with: try System.read(fixture.state.appendingPathComponent("endpoint.json"))) as? [String: Any])
        let url = "http://127.0.0.1:\(try XCTUnwrap(endpoint["port"] as? Int))/v1"
        let configURL = fixture.state.appendingPathComponent("codex-home/config.toml")
        let config = String(decoding: try System.read(configURL), as: UTF8.self)
        XCTAssertTrue(config.contains(url))
        try System.write(Data(config.replacingOccurrences(of: url, with: "http://127.0.0.1:1/v1").utf8), to: configURL)
        let provider = "model_providers.dispatch_custom={name=\"Dispatch custom endpoint\", base_url=\"\(url)\", wire_api=\"responses\", "
            + "env_key=\"FIXTURE_PROVIDER_KEY\", requires_openai_auth=false, supports_websockets=false, request_max_retries=0, stream_max_retries=0}"
        let options = ["-c", "model=\"dispatch-custom-model\"", "-c", "model_provider=\"dispatch_custom\"", "-c", provider,
                       "-c", "model_reasoning_effort=\"high\""]
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        // A local Dispatch terminal: typing `codex` there runs the managed launch (--dispatch).
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[id])
        let session = runtime.chat.session(for: id)
        // The synthetic key the fixture accepts, in the parent's environment only.
        TerminalTestSupport.send("FIXTURE_PROVIDER_KEY=dispatch-fixture " + CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
            + " --dispatch " + options.map { HerdrLaunch.quote("--codex-arg=" + $0) }.joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
            session.active && terminal.agentMenuScreen.contains("dispatch-custom-model")
        }
        terminal.surface?.text("main conversation seed"); TerminalTestSupport.key(36, "\r", terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
            terminal.agentMenuScreen.contains("Local fixture reply: main conversation seed")
        }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "/status"; runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "session=\(session.sessionID ?? "none") helper=\(session.helper != nil)\n\(terminal.agentMenuScreen)") {
            session.sessionID != nil && session.command == nil && session.helper != nil
        }
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.text.contains("Local fixture reply: main conversation seed") }
        }
        for mode in [ChatSideMode.btw, .side] {
            // Opens once the chat is idle (Chat refuses while the TUI shows a prompt or history loads).
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "blocked=\(session.inputBlocked) command=\(session.command != nil) "
                + "submission=\(session.submissionID != nil) prompt=\(session.nativePrompt != nil) loading=\(session.loadingHistory) "
                + "native=\(session.nativeInputInFlight) approvals=\(session.approvals.count) active=\(session.active) "
                + "session=\(session.sessionID ?? "none") helper=\(session.helper != nil) reviewing=\(session.reviewing) "
                + "picker=\(session.modelPicker != nil) editor=\(session.commandEditor != nil) side=\(session.sideConversation != nil)\n"
                + TerminalTestSupport.screen(terminal: terminal)) {
                session.sideConversation != nil
                    || runtime.chat.openSideConversation(mode, question: "side note on the parent's provider", session: session, consumeDraft: false)
            }
            let side = try XCTUnwrap(session.sideConversation)
            try await TestSupport.eventually(timeout: .seconds(30), diagnostic: side.failure ?? "Waiting for the \(mode.rawValue) fork") {
                side.failure != nil || (!side.busy && side.messages.contains { !$0.user })
            }
            XCTAssertNil(side.failure)
            XCTAssertTrue(side.messages.contains { !$0.user && $0.text.contains("side note on the parent's provider") })
            runtime.chat.closeSideConversation(session)
        }
        // Every model request, the parent's and both sides', reached the parent's provider with its model and effort.
        let requests = try CodexTestSupport.conversationRequests(in: fixture.state).compactMap { $0["body"] as? [String: Any] }
        let sides = try requests.filter {
            String(decoding: try JSONSerialization.data(withJSONObject: $0["input"] ?? []), as: UTF8.self).contains("side note on the parent")
        }
        XCTAssertGreaterThanOrEqual(sides.count, 2)
        for body in requests {
            XCTAssertEqual(body["model"] as? String, "dispatch-custom-model")
            XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        }
        passed = testRun?.failureCount == 0
    }

    /// The parent authenticates only through an apiKeyHelper reading a variable of its own environment.
    func testClaudeSideApiKeyHelperReadsTheParentsVariable() async throws {
        let claude = try XCTUnwrap([TestSupport.tool("claude")].first { FileManager.default.isExecutableFile(atPath: $0) })
        let state = URL(fileURLWithPath: "/tmp/dispatch-claude-side-" + System.uuid().uuidString)
        let script = CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path
        let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script, "serve", "--state", state.path, "--delay", "0.025"]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        let child = try System.Child(server)
        defer { child.stop(); print("Claude side fixture: " + state.path) }
        try await TestSupport.eventually { System.exists(state.appendingPathComponent("endpoint.json")) }
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        session.manualViewChoice = true
        TerminalTestSupport.send(["python3", script, "launch", "--state", state.path, "--claude", claude, "--integration", "--api-key-helper"]
            .map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
            session.active && session.agentID == "claude" && !session.loadingHistory && !session.busy
                && terminal.agentMenuScreen.contains("for shortcuts")
        }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "hello through the key helper"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.submissionFailure ?? terminal.agentMenuScreen) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains("Local Claude fixture reply: hello through the key helper") }
        }
        for mode in [ChatSideMode.btw, .side] {
            session.draft = "/\(mode.rawValue) side note through the key helper"
            runtime.chat.sendFromComposer(session)
            let side = try XCTUnwrap(session.sideConversation)
            try await TestSupport.eventually(timeout: .seconds(20), diagnostic: side.failure ?? "Waiting for the \(mode.rawValue) fork") {
                side.failure != nil || (!side.busy && side.messages.contains { !$0.user })
            }
            XCTAssertNil(side.failure)
            XCTAssertTrue(side.messages.contains { !$0.user && $0.text.contains("side note through the key helper") })
            runtime.chat.closeSideConversation(session)
        }
        // Every request, the parent's and both sides', carried the key the helper printed.
        let requests = String(decoding: try System.read(state.appendingPathComponent("requests.jsonl")), as: UTF8.self)
        let records = try requests.split(separator: "\n").map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertTrue(records.contains { String(describing: $0["body"] ?? "").contains("side note through the key helper") })
        XCTAssertEqual(Set(records.map { $0["auth"] as? String ?? "none" }), ["helper"])
    }

    /// A TUI with a profile falls back from the private server and says what that costs.
    func testCodexProfileLaunchSaysWhyChatStaysInTheTerminal() throws {
        let root = System.temporary.appendingPathComponent("codex-profile-" + System.uuid().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { CodexTestSupport.removeFixture(root) }
        let binary = root.appendingPathComponent("codex")
        try "#!/bin/sh\nif [ \"$1\" = --help ]; then printf '%s\\n' '--remote unix://' '--no-daemon'; exit; fi\nprintf '<%s>' \"$@\"\n"
            .write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let helper = try XCTUnwrap(HelperApp.executable)
        for (arguments, says) in [(["--profile", "work"], true), (["-p", "work", "resume"], true),
                                  (["exec", "--profile", "work", "hello"], false), (["--future-option"], false)] {
            let process = Process()
            // What typing `codex` in a Dispatch terminal runs; its stderr is the terminal's.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exec \"$0\" launch codex \"$@\" 2>&1 >/dev/null", helper.path] + arguments
            process.environment = ["PATH": root.path + ":/usr/bin:/bin", "HOME": root.path]
            process.standardInput = FileHandle.nullDevice
            let said = String(decoding: try System.run(process).output, as: UTF8.self)
            XCTAssertEqual(said.contains("dispatch: codex --profile runs without Dispatch's private app server"), says, "arguments: \(arguments): \(said)")
        }
    }
}
