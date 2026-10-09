import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class CodexMainThreadTests: XCTestCase {
    // Native questions.rs::read normalizes the old async item titles/options to this app form.
    private func interaction(_ id: String, _ values: [(String, [String])]) -> HelperChat.Interaction {
        .init(id: id, key: nil, approval: false, blocking: false, questions: values.enumerated().map { index, value in
            .init(id: String(index), header: "Question \(index + 1)", text: value.0, secret: false,
                  options: value.1.map { .init(id: $0, label: $0, detail: "") },
                  multiple: false, custom: true, blocks: nil)
        }, turn: "turn", record: id)
    }

    func testAsyncQuestionsUseUserMessagesAndSurviveTurnCompletion() throws {
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.sessionID = "main"; session.active = true
        session.helper = HelperChat(terminal: 0)
        session.draft = "unfinished draft"
        let request = interaction("async", [("What should I do?", ["Small", "Large"]), ("Any details?", [])])
        chat.receiveHelper(.interaction(request), session: session)
        chat.receiveHelper(.interaction(request), session: session)
        let question = try XCTUnwrap(session.questions.first)
        XCTAssertEqual(session.questions.count, 1)
        XCTAssertNil(question.answers, "A suggested option is never an automatic answer")
        question.select("Small"); question.index = 1; question.type("Custom detail")
        XCTAssertEqual(question.answers, ["0": .options([0]), "1": .text("Custom detail")])
        XCTAssertEqual(question.summary(skip: false), "What should I do?\nSmall\n\nAny details?\nCustom detail")
        let ended = HelperChat.Record(id: "done", turn: "turn", kind: "turn_ended", text: "", title: "", output: "", blocks: [],
                                      completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        chat.receiveHelper(.records([ended]), session: session)
        XCTAssertEqual(session.questions.count, 1)
        XCTAssertFalse(session.waitingForAnswer)
        session.resetConversation()
        XCTAssertTrue(session.questions.isEmpty)
        XCTAssertTrue(question.custom.isEmpty)
        XCTAssertEqual(session.draft, "unfinished draft")
    }

    func testTranscriptRecoversMissedAsyncQuestionAndRecognizesTerminalAnswer() throws {
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.sessionID = "main"; session.active = true
        session.helper = HelperChat(terminal: 0)
        session.draft = "unfinished draft"
        let request = interaction("question", [("Which behavior?", ["Styling only", "Behavior too"])])
        let recovered = HelperChat.Record(id: "question", turn: "turn", kind: "assistant", text: "Which behavior?", title: "", output: "", blocks: [],
                                          completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        chat.receiveHelper(.page(.init(records: [recovered], earlier: nil, state: nil, snapshot: nil)), session: session)
        chat.receiveHelper(.interaction(request), session: session)
        let question = try XCTUnwrap(session.questions.first)
        XCTAssertEqual(question.questions.first?.question, "Which behavior?")
        XCTAssertFalse(session.waitingForAnswer, "Optional questions must not block ongoing work")
        let ended = HelperChat.Record(id: "done", turn: "turn", kind: "turn_ended", text: "", title: "", output: "", blocks: [],
                                      completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        chat.receiveHelper(.records([ended]), session: session)
        XCTAssertEqual(session.questions.count, 1)
        let unrelated = HelperChat.Record(id: "follow-up", turn: "turn", kind: "user", text: "An unrelated follow-up", title: "", output: "", blocks: [],
                                          completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        chat.receiveHelper(.records([unrelated]), session: session)
        XCTAssertEqual(session.questions.count, 1)
        let answered = HelperChat.Record(id: "answer", turn: "turn", kind: "user", text: "> Which behavior?\n\nStyling only", title: "", output: "", blocks: [],
                                         completed: true, exit_code: nil, patch: nil, time_ms: nil, documents: [], tool: nil, inline_reasoning: false)
        chat.receiveHelper(.records([answered]), session: session)
        // The actual helper clears this interaction when it reads that answer; its whole native port
        // also verifies that a late duplicate transcript event cannot publish another interaction.
        chat.receiveHelper(.interaction(interaction("question", [])), session: session)
        XCTAssertTrue(session.questions.isEmpty)
        chat.receiveHelper(.records([recovered]), session: session)
        XCTAssertTrue(session.questions.isEmpty, "A late transcript event must not reopen an answered question")
        XCTAssertEqual(session.draft, "unfinished draft")
        session.resetConversation()
        chat.receiveHelper(.page(.init(records: [recovered], earlier: nil, state: nil, snapshot: nil)), session: session)
        XCTAssertTrue(session.questions.isEmpty, "Scrolling into history must not reopen old questions")
    }

    func testNativeLaunchUsesVersionCompatibleIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-codex-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { CodexTestSupport.removeFixture(root) }
        let binary = root.appendingPathComponent("codex")
        let probes: [(String, Bool)] = [
            ("printf '%s\\n' '--no-daemon'", true),
            ("printf '%s\\n' '--no-alt-screen'", false), // A successfully probed legacy CLI.
            ("exit 23", true),
            ("exit 0", true),
            ("printf ' \\t\\n'", true),
            ("/bin/sleep 3", true), // Exceeds the capability probe's deadline.
        ]
        let invocations: [([String], Bool)] = [
            ([], true),
            (["--profile", "a profile", "literal $ value"], true),
            (["--future-option", "exec", "resume", "--last"], true),
            (["resume", "--future-flag"], true),
            (["--model", "exec", "question"], true),
            (["--worktree"], true),
            (["exec", "hello"], false),
            (["--config", "model=\"a model\"", "app-server"], false),
            (["agents"], false),
            (["--strict-config", "agents"], false),
            (["--dangerously-bypass-hook-trust", "exec", "hello"], false),
            (["--remote", "unix:///tmp/external.sock"], false),
            (["--future-flag", "--remote=unix:///tmp/external.sock"], false),
            (["--no-daemon"], false),
            (["--future-flag", "--help"], false),
        ]
        for (probe, supportsIsolation) in probes {
            try "#!/bin/sh\nif [ \"$1\" = --help ]; then \(probe); exit; fi\nif [ \"$#\" -gt 0 ]; then printf '<%s>\\n' \"$@\"; fi\nexit 17\n".write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            for (arguments, isolates) in invocations {
                // One delayed TUI launch covers the timeout without delaying the whole matrix.
                if probe == "/bin/sleep 3" && !arguments.isEmpty { continue }
                let process = Process(), output = Pipe()
                // What typing `codex` in a Dispatch terminal runs: the helper's typed launch.
                process.executableURL = try XCTUnwrap(HelperApp.executable)
                process.arguments = ["launch", "codex"] + arguments
                process.environment = ["PATH": root.path, "HOME": root.path]
                process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run(); process.waitUntilExit()
                let flag = supportsIsolation && isolates ? ["--no-daemon"] : []
                XCTAssertEqual(process.terminationStatus, 17, "probe: \(probe), arguments: \(arguments)")
                XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                               (flag + arguments).map { "<\($0)>\n" }.joined(), "probe: \(probe), arguments: \(arguments)")
            }
        }
    }

    private func launch(_ arguments: [String]) throws -> (arguments: [String], server: [String]?, directory: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-arguments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { CodexTestSupport.removeFixture(root) }
        let binary = root.appendingPathComponent("codex")
        let script = """
        #!/usr/bin/python3
        import json, os, signal, socket, sys
        args = sys.argv[1:]
        root = os.path.dirname(os.path.realpath(__file__))
        saved = os.path.join(root, 'server.json')
        if args == ['--help']:
            print(json.dumps({'arguments': args, 'server': None, 'help': '--remote unix://'}))
        elif args[:2] == ['app-server', '--listen']:
            with open(saved, 'w') as file: json.dump(args, file)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(args[2].removeprefix('unix://'))
            listener.listen()
            signal.pause()
        else:
            server = None
            if os.path.exists(saved):
                with open(saved) as file: server = json.load(file)
            print(json.dumps({'arguments': args, 'server': server}))
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let process = Process(), output = Pipe()
        process.executableURL = try XCTUnwrap(HelperApp.executable)
        process.arguments = ["launch", "codex"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = root.path + ":/usr/bin:/bin"
        environment["HOME"] = root.path
        environment["DISPATCH_TEST_ROOT"] = environment["TEST_RUNNER_TMPDIR"] ?? environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        let project = root.appendingPathComponent("project with spaces")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = try XCTUnwrap(project.path.withCString { realpath($0, nil) })
        defer { free(path) }
        let directory = String(cString: path)
        process.environment = environment; process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        struct Result: Decodable { let arguments: [String]; let server: [String]? }
        let result = try JSONDecoder().decode(Result.self, from: bytes)
        return (result.arguments, result.server, directory)
    }

    func testLaunchPreservesCommandsAndConfiguration() throws {
        for arguments in [[], ["resume", "--last"], ["fork", "a-session"], ["--model", "exec", "question"]] {
            let result = try launch(arguments)
            XCTAssertNotNil(result.server, "arguments: \(arguments)")
            XCTAssertEqual(Array(result.arguments.suffix(arguments.count)), arguments)
        }
        let arguments = ["-c", "model=\"a model\"", "--enable", "a_feature", "--sandbox", "read-only", "question with spaces"]
        let result = try launch(arguments), server = try XCTUnwrap(result.server, "arguments: \(arguments)")
        XCTAssertEqual(Array(server.dropFirst(3)), ["-c", "model=\"a model\"", "--enable", "a_feature"])
        XCTAssertEqual(Array(result.arguments.dropFirst(2)), arguments)
        for arguments in [["exec", "hello"], ["app-server"], ["--help"], ["--version"], ["--remote", "unix://"], ["--profile", "work"], ["--unknown-option"], ["-c"]] {
            let result = try launch(arguments)
            XCTAssertNil(result.server)
            XCTAssertEqual(result.arguments, arguments)
        }
    }

    func testRemoteLaunchPreservesDirectoryFilteringAndExplicitOverrides() throws {
        for arguments in [["resume"], ["resume", "--last"], ["fork"], ["fork", "--last"], [],
                          ["resume", "--all"], ["resume", "--all", "--last"], ["resume", "session-id"],
                          ["fork", "session-id"], ["resume", "--", "session-id"], ["--", "--cd=prompt"],
                          ["-C", "/tmp/other", "resume"], ["resume", "--cd", "../other"], ["resume", "--cd=../other"],
                          ["--model", "--cd=not-a-directory", "resume"]] {
            let result = try launch(arguments), server = try XCTUnwrap(result.server, "arguments: \(arguments)")
            let endpoint = try XCTUnwrap(server.dropFirst(2).first)
            let directory = arguments == ["resume"] || arguments == ["resume", "--last"] || arguments == ["fork"] || arguments == ["fork", "--last"] || arguments == ["--model", "--cd=not-a-directory", "resume"]
            let prefix = directory ? ["--remote", endpoint, "--cd", result.directory] : ["--remote", endpoint]
            XCTAssertEqual(result.arguments, prefix + arguments)
        }
    }

    func testStopThinkingInterruptsOnlyTheCurrentCodexTurnAndKeepsTheCLIUsable() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-stop-thinking-", delay: 0.04, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[id])
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary) + " --dispatch", to: terminal)
        let session = runtime.chat.session(for: id)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.active && AgentModelMenu.containsModel(TerminalTestSupport.screen(terminal: terminal), slug: "dispatch-fixture", name: "Dispatch fixture") }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "DISPATCH_THINKING_ANIMATION commit"; runtime.chat.submit(session)
        var eligibility: Set<String> = []
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Codex Stop states: \(eligibility.sorted()); screen: \(TerminalTestSupport.screen(terminal: terminal))") {
            eligibility.insert("active=\(session.active) shown=\(session.showChat) busy=\(session.busy) thread=\(session.sessionID != nil) turn=\(session.activeTurnID != nil) ack=\(session.awaitingPromptAck) submitting=\(session.submissionID != nil) loading=\(session.loadingHistory) blocked=\(session.inputBlocked)")
            return runtime.chat.canInterrupt(session) && session.activeTurnID != nil
        }
        let turn = try XCTUnwrap(session.activeTurnID), process = session.process
        XCTAssertTrue(runtime.chat.interrupt(session))
        XCTAssertFalse(runtime.chat.interrupt(session), "A second click cannot duplicate the request")
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.submissionFailure ?? "Codex did not confirm Stop") { !session.busy && session.interruptionID == nil }
        XCTAssertEqual(session.process, process)
        XCTAssertTrue(session.active)
        XCTAssertFalse(runtime.chat.canInterrupt(session))
        session.draft = "Reply after stopping"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.activeTurnID != turn && session.turns.contains { $0.id != turn && $0.items.contains { $0.kind == .assistant } }
        }
        passed = testRun?.failureCount == 0
    }

    func testStopWithoutTurnIdentityUsesTerminalAndKeepsCLIUsable() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-stop-unidentified-", delay: 0.04, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeTab?.id)
        try await app.wait { runtime.views[id].map { $0.surface != nil && !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary) + " --dispatch", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && AgentModelMenu.containsModel(terminal.agentMenuScreen, slug: "dispatch-fixture", name: "Dispatch fixture")
        }
        runtime.chat.chooseChat(true, session: session)
        session.draft = "DISPATCH_THINKING_ANIMATION commit"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.busy && session.activeTurnID != nil && runtime.chat.canInterrupt(session)
        }
        let process = try XCTUnwrap(session.process), conversation = session.sessionID
        let turn = try XCTUnwrap(session.activeTurnID)
        // Withhold identity until Stop has selected its terminal fallback. Deliver
        // it afterward so the real completion still matches the interrupted turn.
        session.activeTurnID = nil
        XCTAssertTrue(runtime.chat.canInterrupt(session))
        XCTAssertTrue(runtime.chat.interrupt(session))
        XCTAssertFalse(runtime.chat.interrupt(session))
        session.activeTurnID = turn
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: session.submissionFailure ?? "Stop did not finish") {
            !session.busy && session.interruptionID == nil
        }
        XCTAssertEqual(session.process, process); XCTAssertEqual(session.sessionID, conversation)
        XCTAssertTrue(process.alive); XCTAssertTrue(session.active)
        session.draft = "Reply after unidentified Stop"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: Reply after unidentified Stop" }
        }
        passed = testRun?.failureCount == 0
    }

    func testFirstMainQuestionAttachesWithoutStatusAndTracksNewConversation() async throws {
        try await walkthrough(asynchronous: false)
    }
    func testAsyncMainQuestionRemainsAfterTurnAndRepliesWithoutConsumingDraft() async throws {
        for _ in 0..<3 { try await walkthrough(asynchronous: true) }
    }
    func testMainQuestionsInNativeTmux() async throws {
        try await walkthrough(asynchronous: false, tmux: true)
    }
    func testMainConversationAttachesThroughPackageLauncher() async throws {
        try await walkthrough(asynchronous: false, packageLauncher: true)
    }
    /// A conversation from an earlier run is not loaded in this run's private server. Chat switches to Terminal
    /// for Codex's picker, then follows the conversation picked there and sends to it.
    func testResumePicksAConversationFromAnEarlierRunInTerminal() async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-resume-", delay: 0.025, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { if !passed { print("Resume Codex: \(session.sessionID ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") } }
        func reply(_ text: String) -> Bool {
            session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text == "Local fixture reply: " + text }
        }
        // As the user's typing does, sending follows the composer's focus (and Codex's focus-out report).
        func send(_ text: String) async throws {
            runtime.chat.chooseChat(true, session: session)
            try await TestSupport.eventually { app.window.firstResponder is ChatComposer.ComposerTextView }
            session.draft = text; runtime.chat.sendFromComposer(session)
        }
        func run(_ message: String) async throws -> (process: AgentProcess, conversation: String) {
            TerminalTestSupport.send(CodexTestSupport.command(state: fixture.state, binary: fixture.binary) + " --dispatch", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) {
                session.active && session.sessionID != nil && terminal.agentMenuScreen.contains("› Ask Codex to do anything")
            }
            try await send(message)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: terminal.agentMenuScreen) { !session.busy && reply(message) }
            return (try XCTUnwrap(session.process), try XCTUnwrap(session.sessionID))
        }
        try await TestSupport.eventually(diagnostic: "Test window activation: key=\(app.window.isKeyWindow), active=\(NSApp.isActive)") {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); app.window.makeKeyAndOrderFront(nil)
            return app.window.isKeyWindow && NSApp.isActive
        }
        let earlier = try await run("earlier run")
        try await send("/quit")
        try await TestSupport.eventually(timeout: .seconds(10)) { !earlier.process.alive && !session.active }
        let current = try await run("current run")
        XCTAssertNotEqual(current.conversation, earlier.conversation)
        try await send("/resume")
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Resume: \(session.submissionFailure ?? "pending")") {
            !session.showChat && session.submissionID == nil
        }
        XCTAssertNil(session.submissionFailure)
        try await TestSupport.eventually(diagnostic: terminal.agentMenuScreen) {
            terminal.agentMenuScreen.contains("Resume a previous session") && app.window.firstResponder === terminal
        }
        // The current run's conversation is listed first.
        TerminalTestSupport.key(125, "\u{F701}", terminal)
        try await TestSupport.eventually(diagnostic: terminal.agentMenuScreen) { resumeRows(terminal.agentMenuScreen) == (2, 1) }
        TerminalTestSupport.key(36, "\r", terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Resumed \(session.sessionID ?? "none")\n\(terminal.agentMenuScreen)") {
            session.sessionID == earlier.conversation && !session.loadingHistory && reply("earlier run") && !reply("current run")
        }
        XCTAssertFalse(session.showChat)
        try await TestSupport.eventually(diagnostic: terminal.agentMenuScreen) { terminal.agentMenuScreen.contains("› Ask Codex to do anything") }
        // Chat now sends to the resumed conversation.
        try await send("after resume")
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Sent: \(session.submissionFailure ?? "pending")\n\(terminal.agentMenuScreen)") {
            !session.busy && reply("after resume")
        }
        XCTAssertEqual(session.sessionID, earlier.conversation)
        try await send("/quit")
        try await TestSupport.eventually(timeout: .seconds(10)) { !current.process.alive }
        passed = testRun?.failureCount == 0
    }
    /// Codex's resume picker: how many conversations it lists, and which one is selected.
    private func resumeRows(_ screen: String) -> (count: Int, selected: Int?) {
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let search = lines.lastIndex(of: "Type to search") else { return (0, nil) }
        let rows = lines[(search + 1)...].prefix { !$0.hasPrefix("─") }.filter { !$0.isEmpty }
        return (rows.count, rows.firstIndex { $0.hasPrefix("›") })
    }
    private func walkthrough(asynchronous: Bool, tmux: Bool = false, packageLauncher: Bool = false) async throws {
        let fixture = try CodexEndpointFixture(prefix: "dispatch-main-", delay: 0.025, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed) }
        try await fixture.start(timeout: .seconds(15))
        let config = fixture.state.appendingPathComponent("codex-home/config.toml")
        let contents = try String(contentsOf: config, encoding: .utf8)
        try contents.replacingOccurrences(of: "[features]\n", with: "[features]\ndefault_mode_request_user_input = true\n")
            .write(to: config, atomically: true, encoding: .utf8)
        if asynchronous {
            let catalog = fixture.state.appendingPathComponent("models.json")
            let model: [String: Any] = ["slug": "dispatch-fixture", "tool_mode": "code_mode_only", "base_instructions": "You are an offline test fixture.",
                "display_name": "Dispatch fixture", "supported_reasoning_levels": [["effort": "medium", "description": "Fixture"]],
                "shell_type": "unified_exec", "visibility": "list", "supported_in_api": true, "priority": 1,
                "support_verbosity": false, "truncation_policy": ["mode": "bytes", "limit": 10000], "experimental_supported_tools": ["send_user_message_async"]]
            try JSONSerialization.data(withJSONObject: ["models": [model]]).write(to: catalog)
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            let setting = String(decoding: try encoder.encode(catalog.path), as: UTF8.self)
            try ("model_catalog_json = " + setting + "\n" + String(contentsOf: config, encoding: .utf8)).write(to: config, atomically: true, encoding: .utf8)
        }
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true)
        defer { app.close() }
        if tmux { try await app.attach(); try await app.ready() }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { if !passed { print("Main Codex: \(session.sessionID ?? "none") / \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") } }
        // This fixture's tmux server starts outside Dispatch. Supply the same
        // local launch context that newly managed native panes receive.
        let launchContext = tmux ? "env DISPATCH_HELPER_EXECUTABLE=" + HerdrLaunch.quote(try XCTUnwrap(HelperApp.executable).path) + " " : ""
        var binary = fixture.binary
        if packageLauncher {
            // Like npm's codex.js, keep a package launcher alive between
            // Dispatch and the native binary, forwarding the same arguments.
            let wrapper = fixture.state.appendingPathComponent("codex")
            let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
            let native = String(decoding: try encoder.encode(fixture.binary), as: UTF8.self)
            try """
            #!/usr/bin/python3
            import signal, subprocess, sys
            child = subprocess.Popen([\(native)] + sys.argv[1:])
            for number in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
                signal.signal(number, lambda number, frame: child.send_signal(number))
            sys.exit(child.wait())

            """.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            binary = wrapper.path
        }
        TerminalTestSupport.send(launchContext + CodexTestSupport.command(state: fixture.state, binary: binary) + " --dispatch", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.active && AgentModelMenu.containsModel(terminal.agentMenuScreen, slug: "dispatch-fixture", name: "Dispatch fixture")
        }
        let process = try XCTUnwrap(session.process)
        XCTAssertTrue(process.arguments?.contains("--remote") == true, "The helper's typed launch runs Codex against its control socket")
        if packageLauncher {
            let parentID = try XCTUnwrap(AgentProcess.info(process.pid)?.pbi_ppid)
            let parent = try XCTUnwrap(AgentProcess.capture(pid_t(parentID)))
            XCTAssertNotEqual(parent.executable, HelperApp.executable?.resolvingSymlinksInPath().path)
        }
        try await TestSupport.eventually(timeout: .seconds(15)) { session.sessionID != nil }
        // A new conversation has no rollout to resume yet; it still shows its configured model before a turn.
        try await TestSupport.eventually(timeout: .seconds(15)) { session.model == "dispatch-fixture" }
        XCTAssertNil(session.effort, "The fixture leaves the effort at the model's default")
        let arguments = try XCTUnwrap(process.arguments)
        let endpoint = try XCTUnwrap(arguments.firstIndex(of: "--remote")).advanced(by: 1)
        let socket = String(arguments[endpoint].dropFirst("unix://".count))
        runtime.chat.chooseChat(true, session: session)
        if asynchronous {
            session.draft = "DISPATCH_ASYNC_QUESTION main"
            runtime.chat.sendFromComposer(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { session.questions.contains { !$0.blocking } }
            let question = try XCTUnwrap(session.questions.first { !$0.blocking })
            XCTAssertFalse(session.waitingForAnswer)
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy }
            XCTAssertEqual(session.questions.count, 1, "Optional questions remain answerable after Codex finishes its turn: \(session.questions.map(\.id))")
            question.type("Async custom answer")
            session.draft = "preserve this draft too"
            runtime.chat.answerQuestion(question, skip: false, session: session)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                session.questions.isEmpty && !session.busy && session.turns.flatMap(\.items).contains { $0.text.contains("Async custom answer") }
            }
            XCTAssertEqual(session.draft, "preserve this draft too")
            session.draft = "DISPATCH_ASYNC_QUESTION ongoing"
            runtime.chat.sendFromComposer(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { session.questions.contains { !$0.blocking } && session.busy }
            let ongoing = try XCTUnwrap(session.questions.first { !$0.blocking })
            runtime.chat.answerQuestion(ongoing, skip: true, session: session)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                session.questions.isEmpty && session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text.contains("Skipped") }
            }
            app.close()
            try await TestSupport.eventually(timeout: .seconds(10)) { !process.alive && !FileManager.default.fileExists(atPath: socket) }
            passed = testRun?.failureCount == 0
            return
        }
        session.draft = "DISPATCH_SIDE_QUESTION main first turn"
        runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { !session.questions.isEmpty }
        let first = try XCTUnwrap(session.questions.first), conversation = try XCTUnwrap(session.sessionID)
        first.select("Small change (Recommended)"); first.index = 1; first.type("Main answer from Chat")
        session.draft = "preserved next draft"
        runtime.chat.answerQuestion(first, skip: false, session: session)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            session.questions.isEmpty && !session.busy && session.turns.flatMap(\.items).contains { $0.output.contains("Main answer from Chat") }
        }
        XCTAssertEqual(session.draft, "preserved next draft")
        session.draft = "/new"; runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.sessionID != conversation && session.sessionID != nil && session.command == nil }
        session.draft = "DISPATCH_PLAN_QUESTION answer in Terminal"
        runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { !session.questions.isEmpty }
        let second = try XCTUnwrap(session.questions.first)
        XCTAssertEqual(second.threadID, session.sessionID)
        // Answer the second option in Terminal (Codex's own menu), not in Chat.
        TerminalTestSupport.key(125, "\u{F701}", terminal); TerminalTestSupport.key(36, "\r", terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { session.questions.isEmpty && !session.busy }
        runtime.chat.answerQuestion(second, skip: false, session: session)
        XCTAssertFalse(second.submitted)
        // A bare /resume opens Codex's own session picker: Chat switches to Terminal, which takes the keys.
        let replacement = try XCTUnwrap(session.sessionID)
        try await TestSupport.eventually(diagnostic: "Test window activation: key=\(app.window.isKeyWindow), active=\(NSApp.isActive)") {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true); app.window.makeKeyAndOrderFront(nil)
            return app.window.isKeyWindow && NSApp.isActive
        }
        session.draft = "/resume"; runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Resume: \(session.submissionFailure ?? "pending")\n\(terminal.agentMenuScreen)") {
            !session.showChat && session.submissionID == nil
        }
        XCTAssertTrue(session.manualViewChoice)
        XCTAssertEqual(session.draft, "")
        XCTAssertNil(session.command); XCTAssertNil(session.observedCommand); XCTAssertNil(session.commandResult)
        XCTAssertFalse(session.awaitingPromptAck); XCTAssertNil(session.submissionFailure); XCTAssertNil(session.terminalAttention)
        try await TestSupport.eventually(diagnostic: terminal.agentMenuScreen) {
            terminal.agentMenuScreen.contains("Resume a previous session") && app.window.firstResponder === terminal
        }
        // Pick the first conversation: the picker lists the most recently updated first.
        TerminalTestSupport.key(125, "\u{F701}", terminal)
        try await TestSupport.eventually(diagnostic: terminal.agentMenuScreen) { resumeRows(terminal.agentMenuScreen) == (2, 1) }
        TerminalTestSupport.key(36, "\r", terminal)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Resumed \(session.sessionID ?? "none") from \(replacement)\n\(terminal.agentMenuScreen)") {
            session.sessionID == conversation && !session.loadingHistory
                && session.turns.flatMap(\.items).contains { $0.output.contains("Main answer from Chat") }
        }
        XCTAssertFalse(session.showChat, "Chat follows the resumed conversation without leaving Terminal")
        // Codex drops keys while it leaves the picker; the user returns once its composer is back.
        try await TestSupport.eventually(diagnostic: terminal.agentMenuScreen) {
            let screen = terminal.agentMenuScreen
            return screen.contains("DISPATCH_SIDE_QUESTION main first turn") && screen.contains("› Ask Codex to do anything")
        }
        // As the user's typing does, sending follows the composer's focus (and Codex's focus-out report).
        runtime.chat.chooseChat(true, session: session)
        try await TestSupport.eventually { app.window.firstResponder is ChatComposer.ComposerTextView }
        session.draft = "/quit"; runtime.chat.sendFromComposer(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { !process.alive && !FileManager.default.fileExists(atPath: socket) }
        passed = true
    }
}
