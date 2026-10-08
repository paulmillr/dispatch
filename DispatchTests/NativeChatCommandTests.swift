import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class NativeChatCommandTests: XCTestCase {
    func testShellCompletionRequiresMatchingResultAndRestoredComposer() {
        // The completed command's output comes from the harness (chat.command outcome); shellCommandAndExit checks it end to end.
        XCTAssertEqual(ChatCommand("!ls"), .shell("ls"))
        XCTAssertNil(ChatCommand("!!ls"))
    }

    func testStructuredShellCompletionPreservesOutputAndMatchesPendingCommand() throws {
        let output = "first  \n  second\n"
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.observedCommand = (title: "!ls", output: nil)
        let record = HelperChat.Record(id: "execution", turn: "turn", kind: "output", text: output,
            title: "", output: "", blocks: [], completed: true, exit_code: 0, patch: nil,
            time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        chat.receiveHelper(.records([record]), session: session)
        XCTAssertEqual(session.commandResult?.title, "!ls")
        XCTAssertEqual(session.commandResult?.text, output)
        XCTAssertNil(session.observedCommand)
        XCTAssertTrue(session.turns.isEmpty, "A native shell command must not create a chat turn")
        chat.receiveHelper(.records([record]), session: session)
        XCTAssertEqual(session.commandResult?.text, output)
    }

    func testTranscriptUserShellCommandUsesStructuredIdentity() throws {
        let command = "printf 'ok\\n'", output = "ok\n"
        let outcome = HelperChat.Outcome(kind: "shell", sent: nil, command: command, output: output, title: nil, text: nil)
        let result = try XCTUnwrap(outcome.result(agent: "Codex"))
        XCTAssertEqual(result.title, "!" + command)
        XCTAssertEqual(result.text, output)
        // Native user-shell classification is performed before this common result reaches the app.
        let ordinary = HelperChat.Outcome(kind: "sent", sent: nil, command: command, output: output, title: nil, text: nil)
        XCTAssertNil(ordinary.result(agent: "Codex"))
    }

    func testShellCommandsAreNativeAndCannotBeQueued() throws {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        session.active = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        defer { chat.close(session.id) }
        for text in ["!echo hello", "!!pwd", "  !pwd"] {
            XCTAssertTrue(AgentInput.isCommand(text))
            session.draft = text
            chat.queue(session)
            XCTAssertTrue(session.queuedMessages.isEmpty)
            XCTAssertEqual(session.draft, text)
        }
        for text in ["Explain !command", "Hello!", "How does /status work?"] {
            XCTAssertFalse(AgentInput.isCommand(text))
        }
    }

    func testShellCommandInTmuxDoesNotWaitForModelAcknowledgement() async throws {
        try await shellCommandAndExit()
    }

    func testRemoteTmuxExitLatency() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-exit-timing-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(); defer { app.close() }
        let server = try await SSHTestServer(grant: .init(profile: .full, hooks: false)); defer { server.stop() }
        let origin = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let original = try XCTUnwrap(runtime.views[origin])
        TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
        }
        try await app.attach(command: "\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge")
        try await app.ready()
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        try await TestSupport.eventually {
            !terminal.agentMenuScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var timings: [[String: Any]] = []
        for trial in 0..<6 {
            let chat = trial % 2 == 0
            let marker = "DISPATCH_EXIT_READY_\(trial)"
            TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
                + "; printf 'DISPATCH_EXIT_READY_%s\\n' \(trial)", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
                session.active && session.remoteAgent != nil && !session.loadingHistory && session.activityCheck == nil
                    && terminal.agentMenuScreen.contains("dispatch-fixture default")
            }
            runtime.chat.chooseChat(true, session: session)
            session.draft = "warm exit benchmark \(trial)"; runtime.chat.sendFromComposer(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.submissionFailure ?? terminal.agentMenuScreen) {
                !session.busy && !session.awaitingPromptAck && session.turns.flatMap(\.items).contains {
                    $0.text == "Local fixture reply: warm exit benchmark \(trial)"
                }
            }
            runtime.chat.chooseChat(chat, session: session)
            try await TestSupport.eventually { chat ? session.showChat : terminal.isPresented }
            if !chat {
                // Measure Return on an already typed command, as a user would.
                // Sending a synthetic burst plus Return can trigger Codex's
                // paste detection instead of its normal command submission.
                terminal.insertText("/exit", replacementRange: NSRange(location: NSNotFound, length: 0))
                try await Task.sleep(for: .milliseconds(250))
            }
            let start = ProcessInfo.processInfo.systemUptime
            var delivery: Double?, shell: Double?, ended: Double?, presented: Double?
            if chat { session.draft = "/exit"; runtime.chat.sendFromComposer(session) }
            else { TerminalTestSupport.key(36, "\r", terminal) }
            while ProcessInfo.processInfo.systemUptime - start < 8 {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if delivery == nil, !session.showChat, session.submissionID == nil { delivery = elapsed }
                if shell == nil, terminal.agentMenuScreen.contains(marker) { shell = elapsed }
                if ended == nil, !session.active { ended = elapsed }
                if presented == nil, terminal.isPresented { presented = elapsed }
                if delivery != nil, shell != nil, ended != nil, presented != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(session.submissionFailure)
            let sample: [String: Any] = ["path": chat ? "chat" : "terminal", "trial": trial,
                "deliverySeconds": try XCTUnwrap(delivery), "shellReadySeconds": try XCTUnwrap(shell, terminal.agentMenuScreen),
                "discoveryEndedSeconds": try XCTUnwrap(ended, "Remote exit detection"), "terminalVisibleSeconds": try XCTUnwrap(presented)]
            timings.append(sample)
            print("EXIT_TIMING " + String(decoding: try JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]), as: UTF8.self))
        }
        let directory = CodexTestSupport.root.appendingPathComponent("build/exit-latency")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("ssh-tmux.json"))
        passed = true
    }

    private func shellCommandAndExit() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-bang-command-", delay: 0.01, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        try await app.attach()
        try await app.ready()
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        let terminal = try XCTUnwrap(runtime.views[id])
        let session = runtime.chat.session(for: id)
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && !session.loadingHistory && session.activityCheck == nil
                && terminal.agentMenuScreen.contains("dispatch-fixture default")
        }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "!printf 'DISPATCH_%s\\n' BANG_OK"
        runtime.chat.submit(session)
        XCTAssertFalse(session.awaitingPromptAck)
        XCTAssertNil(session.optimisticPrompt)
        XCTAssertFalse(session.busy)
        XCTAssertTrue(session.showChat, "Native commands must not change the selected view")
        XCTAssertNil(session.terminalAttention)
        XCTAssertNotNil(session.command)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
            terminal.agentMenuScreen.contains("DISPATCH_BANG_OK")
        }
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: session.status ?? "Waiting for shell completion") {
            session.command == nil && session.commandResult?.text.contains("DISPATCH_BANG_OK") == true
        }
        XCTAssertEqual(session.commandResult?.text, "DISPATCH_BANG_OK\n", "Chat must use Codex's exact command output, not its terminal rendering")
        XCTAssertNil(session.terminalAttention)
        XCTAssertFalse(session.inputBlocked)
        XCTAssertEqual(session.draft, "")
        session.draft = "hello after shell command"
        runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.submissionFailure ?? session.status ?? "Waiting for next chat reply") {
            !session.busy && !session.awaitingPromptAck && session.turns.flatMap(\.items).contains { $0.text.contains("Local fixture reply: hello after shell command") }
        }
        let process = try XCTUnwrap(session.process)
        session.draft = "/exit"
        runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(diagnostic: session.submissionFailure ?? terminal.agentMenuScreen) {
            !process.alive && !session.active
        }
        XCTAssertFalse(session.showChat)
        XCTAssertNil(session.terminalAttention)
        XCTAssertTrue(session.draft.isEmpty)
        XCTAssertTrue(runtime.chat.canEnterChat(session))
        try await TestSupport.eventually { terminal.isPresented && app.window.firstResponder === terminal }
        TerminalTestSupport.send("printf 'CODEX_EXIT_%s\\n' OK", to: terminal)
        try await TestSupport.eventually { terminal.agentMenuScreen.contains("CODEX_EXIT_OK") }
        passed = true
    }
}
