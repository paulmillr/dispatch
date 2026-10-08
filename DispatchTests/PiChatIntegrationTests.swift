import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class PiChatIntegrationTests: XCTestCase {
    func testTmuxPiChatTransport() async throws { try await transport("tmux") }
    func testHerdrPiChatTransport() async throws { try await transport("herdr") }

    func testManagedExtensionReloadNativeDialogAndRevocation() async throws {
        try DesktopTestSupport.requireUnlocked()
        let fm = FileManager.default
        let pi = try XCTUnwrap([TestSupport.tool("pi")].first { fm.isExecutableFile(atPath: $0) })
        let state = URL(fileURLWithPath: "/tmp/dispatch-pi-setup-" + UUID().uuidString)
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                             "serve", "--state", state.path, "--delay", "0.025"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("Pi local managed extension fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        // The helper installs into its own Pi agent directory (the test home's); the fixture's Pi uses it too.
        let home = Home.url.appendingPathComponent(".pi/agent"), script = home.appendingPathComponent("extensions/dispatch-chat.js")
        let extensions = home.appendingPathComponent("extensions")
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let other = extensions.appendingPathComponent("unrelated.js")
        let otherBytes = try Data(contentsOf: CodexTestSupport.root.appendingPathComponent("scripts/fixtures/pi-navigation.js"))
        try otherBytes.write(to: other)
        let settings = home.appendingPathComponent("settings.json")
        try Data("{\"quietStartup\":true,\"editorPaddingX\":2}\n".utf8).write(to: settings)
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let chat = runtime.chat
        defer { chat.setHelperIntegration("pi", enabled: false) }
        try await TestSupport.integrations(["pi"], enabled: false, chat: chat)
        let app = try TmuxWalkthrough(); defer { app.close() }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("Pi setup final: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        TerminalTestSupport.send(["python3", CodexTestSupport.root.appendingPathComponent("scripts/pi_fixture.py").path,
            "--state", state.path, "--pi", pi, "--integration", "--home", home.path].map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        // pi_fixture execs Pi: the terminal's foreground process is the native Pi.
        func nativeProcess() -> AgentProcess? {
            guard terminal.foregroundPID > 1, terminal.foregroundPID <= UInt64(Int32.max) else { return nil }
            return AgentProcess.capture(pid_t(terminal.foregroundPID))
        }
        try await TestSupport.eventually(timeout: .seconds(20)) { nativeProcess() != nil && terminal.agentMenuScreen.contains("dispatch-fixture") }
        let process = try XCTUnwrap(nativeProcess())
        XCTAssertFalse(session.active)
        XCTAssertFalse(fm.fileExists(atPath: script.path))
        let models = home.appendingPathComponent("models.json")
        let savedModels = try Data(contentsOf: models), savedSettings = try Data(contentsOf: settings)
        try await TestSupport.integrations(["pi"], enabled: true, chat: runtime.chat)
        XCTAssertNil(runtime.chat.error); XCTAssertTrue(fm.fileExists(atPath: script.path))
        XCTAssertFalse(session.active, "Installing on disk must wait for the native process to reload")
        TerminalTestSupport.send("/reload", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Pi reload: \(session.status ?? "none")\n\(terminal.agentMenuScreen)") {
            session.active && session.agentID == "pi" && session.sessionID != nil && !session.loadingHistory && !session.busy
        }
        XCTAssertEqual(session.process, process, "Reload must attach to the original process birth and PID")
        let conversation = try XCTUnwrap(session.sessionID)
        runtime.chat.chooseChat(true, session: session)
        session.draft = "managed local Pi ready"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.completed && $0.text == "Local Claude fixture reply: managed local Pi ready" }
        }
        let turns = session.turns.map(\.id)
        let requests = try Data(contentsOf: state.appendingPathComponent("requests.jsonl"))
        session.draft = "preserve native dialog draft λ"
        TerminalTestSupport.send("/dispatch-test-question", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(10)) {
            session.busy && session.showChat && session.inputBlocked && session.status?.contains("needs an answer in Terminal") == true
        }
        XCTAssertEqual(session.draft, "preserve native dialog draft λ")
        let dialog = try await XCTUnwrap(session.helper).native()
        XCTAssertNotNil(dialog.dialog, "The native confirm dialog is the harness's state")
        let blocked = try await XCTUnwrap(session.helper).refuses("must not replace native permission", conversation: conversation)
        XCTAssertTrue(blocked, "A pending native dialog cannot accept Chat input")
        TerminalTestSupport.key(53, "\u{1b}", terminal)
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.busy }
        XCTAssertEqual(session.draft, "preserve native dialog draft λ")
        XCTAssertEqual(session.turns.map(\.id), turns)
        runtime.chat.chooseChat(true, session: session)
        session.draft = "preserve disabled Pi draft 🥧"
        runtime.chat.setHelperIntegration("pi", enabled: false)
        XCTAssertFalse(session.active)
        try await TestSupport.eventually { runtime.chat.hookStatus("pi") == .off && !fm.fileExists(atPath: script.path) }
        runtime.chat.submit(session)
        XCTAssertEqual(session.draft, "preserve disabled Pi draft 🥧")
        XCTAssertNotNil(session.submissionFailure)
        XCTAssertTrue(process.alive)
        let registration = home.appendingPathComponent("dispatch/sessions/\(process.pid).json")
        TerminalTestSupport.send("/reload", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(10)) { !fm.fileExists(atPath: registration.path) }
        XCTAssertFalse(session.active)
        XCTAssertEqual(nativeProcess(), process)
        XCTAssertEqual(session.turns.map(\.id), turns)
        XCTAssertEqual(try Data(contentsOf: models), savedModels)
        XCTAssertEqual(try Data(contentsOf: settings), savedSettings)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), requests)
        TerminalTestSupport.send("/quit", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(10)) { !process.alive }
    }

    func testNativeDiscoveryStreamingQueueStopModelAndSessionLifecycle() async throws {
        let restoreRuntime = TestSupport.preserveRuntime()
        defer { restoreRuntime() }
        let phaseTimings = WalkthroughTimings(test: name, agent: "pi", transport: "local")
        phaseTimings.begin("endpoint_startup")
        var passed = false
        defer { phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        try DesktopTestSupport.requireUnlocked()
        let fm = FileManager.default
        let pi = try XCTUnwrap([TestSupport.tool("pi")].first { fm.isExecutableFile(atPath: $0) },
                               "Run ./run.sh --test to prepare Pi")
        let state = URL(fileURLWithPath: "/tmp/dispatch-pi-chat-" + UUID().uuidString)
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                             "serve", "--state", state.path, "--delay", "0.04"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("Pi Chat fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        phaseTimings.begin("runtime_setup")
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
        func finish() async {
            phaseTimings.begin("teardown")
            window.close(); window.contentView = nil
            await runtime.stop().value
        }

        do {
            func launch(resume: String? = nil) async throws -> (TerminalView, ChatSession) {
                let id = try XCTUnwrap(workspace.activeSurfaceID)
                try await TestSupport.eventually { runtime.views[id]?.surface != nil }
                let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
                session.manualViewChoice = true
                var args = ["python3", CodexTestSupport.root.appendingPathComponent("scripts/pi_fixture.py").path,
                            "--state", state.path, "--pi", pi,
                            "--extension", CodexTestSupport.root.appendingPathComponent("helper/harnesses/pi/resources/bridge.js").path]
                if let resume { args += ["--session", resume] }
                TerminalTestSupport.send(args.map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Pi discovery: \(session.status ?? "none")\n\(terminal.agentMenuScreen)") {
                    session.active && session.agentID == "pi" && session.sessionID != nil && !session.loadingHistory && !session.busy
                }
                return (terminal, session)
            }
            phaseTimings.begin("agent_readiness")
            let (terminal, session) = try await launch()
            phaseTimings.begin("scenario")
            defer { print("Pi final: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
            let originalSurface = terminal.surface
            let process = try XCTUnwrap(session.process), originalID = try XCTUnwrap(session.sessionID)
            let originalPath = try XCTUnwrap(session.transcriptPath)
            XCTAssertEqual(session.agentID, "pi")
            XCTAssertTrue(session.turns.isEmpty)
            XCTAssertFalse(fm.fileExists(atPath: originalPath), "Pi must attach before its first assistant turn creates the transcript")
            runtime.chat.chooseChat(true, session: session)

            terminal.insertText("native draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            try await TestSupport.eventually { terminal.agentMenuScreen.contains("native draft") }
            session.draft = "must preserve native draft"; runtime.chat.submit(session)
            try await TestSupport.eventually { session.submissionFailure != nil && session.submissionID == nil }
            XCTAssertEqual(session.draft, "must preserve native draft")
            let nativeDraft = try await XCTUnwrap(session.helper).native()
            XCTAssertEqual(nativeDraft.editor, "native draft")
            TerminalTestSupport.key(32, "u", terminal, modifiers: .control)
            try await TestSupport.eventually { !terminal.agentMenuScreen.contains("native draft") }
            session.draft = "thinking Pi chat\nsecond line 🥧"; runtime.chat.submit(session)
            XCTAssertNotNil(session.optimisticPrompt)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Pi streaming: \(session.submissionFailure ?? "none")") {
                session.busy && session.turns.flatMap(\.items).contains { [.assistant, .reasoning].contains($0.kind) && !$0.text.isEmpty && !$0.completed }
            }
            func reply(_ text: String, in session: ChatSession) -> Bool {
                session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.text.contains(text) && $0.completed }
            }
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && reply("Local Claude fixture reply: thinking Pi chat\nsecond line 🥧", in: session) }
            XCTAssertNil(session.optimisticPrompt)
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .assistant }.count, 1, "The final JSONL entry replaces its streaming snapshot")
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .reasoning && $0.text.contains("Synthetic fixture trace") })

            session.draft = "tool Pi check"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && reply("Tool result received: completed.", in: session) }
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.completed && $0.output.contains("DISPATCH_CLAUDE_TOOL_OK") })
            session.draft = "thinking queue first"; runtime.chat.submit(session)
            session.draft = "queue second"; runtime.chat.queue(session)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                !session.busy && session.queuedMessages.isEmpty && reply("Local Claude fixture reply: queue second", in: session)
            }
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 4)

            runtime.chat.openModelPicker(session, column: .effort)
            let picker = try XCTUnwrap(session.modelPicker)
            try await TestSupport.eventually(timeout: .seconds(10)) { !picker.loading && !picker.models.isEmpty && !picker.efforts.isEmpty }
            XCTAssertNil(picker.error)
            XCTAssertTrue(picker.models.contains { $0.name == "dispatch-local/dispatch-fixture" })
            picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "high" }))
            try await TestSupport.eventually(timeout: .seconds(10)) { session.modelPicker == nil }
            XCTAssertEqual(session.model, "dispatch-local/dispatch-fixture"); XCTAssertEqual(session.effort, "high")
            let configured = try await XCTUnwrap(session.helper).native()
            XCTAssertEqual(configured.effort, "high")

            session.draft = "long cancellation"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                runtime.chat.canInterrupt(session) && session.turns.flatMap(\.items).contains { $0.kind == .assistant && !$0.completed && !$0.text.isEmpty }
            }
            XCTAssertTrue(runtime.chat.interrupt(session))
            try await TestSupport.eventually(timeout: .seconds(10)) { !session.busy && session.interruptionID == nil }
            session.draft = "after cancellation"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && reply("Local Claude fixture reply: after cancellation", in: session) }
            _ = try await PresentationTestSupport.capture(window, named: "pi-chat", in: "pi-chat-audit")

            // Pi prints a command's result above its editor or opens a selector in it.
            func command(_ text: String, until done: () -> Bool) async throws {
                session.draft = text; runtime.chat.submit(session)
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "\(text) attention=\(session.terminalAttention ?? "none") result=\(session.commandResult?.text ?? "none")\n\(terminal.agentMenuScreen)") {
                    session.observedCommand == nil && !session.awaitingPromptAck && done()
                }
            }
            try await command("/name Chat probe") { session.commandResult?.title == "/name Chat probe" }
            XCTAssertEqual(session.commandResult?.text, "Session name set: Chat probe")
            XCTAssertTrue(session.showChat); XCTAssertNil(session.terminalAttention)
            try await command("/thinking") { session.terminalAttention != nil }
            XCTAssertTrue(terminal.agentMenuScreen.contains("Thinking Level"), terminal.agentMenuScreen)
            TerminalTestSupport.key(53, "\u{1b}", terminal)
            try await TestSupport.eventually { !terminal.agentMenuScreen.contains("Thinking Level") }
            runtime.chat.chooseChat(true, session: session)

            session.draft = "/new"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) {
                session.active && session.sessionID != originalID && !session.loadingHistory && !session.busy
            }
            XCTAssertNil(session.terminalAttention, "Chat follows the new Pi session")
            XCTAssertTrue(session.turns.isEmpty)
            let stale = try await XCTUnwrap(session.helper).refuses("stale conversation must not run", conversation: originalID)
            XCTAssertTrue(stale, "The old session cannot authorize input after /new")
            runtime.chat.chooseChat(true, session: session)
            session.draft = "replacement session"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && reply("Local Claude fixture reply: replacement session", in: session) }
            let replacementID = session.sessionID
            workspace.newTab()
            let (_, resumed) = try await launch(resume: originalPath)
            XCTAssertEqual(resumed.sessionID, originalID)
            XCTAssertNotEqual(resumed.process, process)
            XCTAssertEqual(session.sessionID, replacementID, "A resumed same-directory session must not rebind another live Pi process")
            try await TestSupport.eventually { !resumed.loadingHistory && reply("Local Claude fixture reply: after cancellation", in: resumed) }
            XCTAssertEqual(resumed.turns.flatMap(\.items).filter { $0.kind == .user }.count, 6)
            runtime.chat.chooseChat(true, session: resumed)
            resumed.draft = "/quit"; runtime.chat.submit(resumed)
            try await TestSupport.eventually { !resumed.active }
            workspace.selectTab(session.id)
            session.draft = "/quit"; runtime.chat.submit(session)
            try await TestSupport.eventually { !process.alive && !session.active }
            XCTAssertTrue(terminal.surface === originalSurface)
            XCTAssertTrue(runtime.chat.canEnterChat(session))
            let exited = try await XCTUnwrap(session.helper).refuses("must not reach shell", conversation: try XCTUnwrap(replacementID))
            XCTAssertTrue(exited, "An exited Pi process must not take input")
            await finish()
            passed = testRun?.failureCount == 0
        } catch { await finish(); throw error }
    }

    private func transport(_ backend: String) async throws {
        let fm = FileManager.default
        let pi = try XCTUnwrap([TestSupport.tool("pi")].first { fm.isExecutableFile(atPath: $0) })
        let state = URL(fileURLWithPath: "/tmp/dispatch-pi-" + backend + "-" + UUID().uuidString)
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                             "serve", "--state", state.path, "--delay", "0.025"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("Pi \(backend) fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(); defer { app.close() }
        let socket = state.appendingPathComponent("herdr.sock").path
        defer { if backend == "herdr" { _ = try? HerdrSocket(path: socket).request("server.stop") } }
        if backend == "tmux" {
            try await app.attach(); try await app.ready()
        } else {
            let id = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[id]?.surface != nil }
            let terminal = try XCTUnwrap(runtime.views[id])
            TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(state.path)
                + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: terminal)
            try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
        }
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("Pi \(backend) final: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        TerminalTestSupport.send(["python3", CodexTestSupport.root.appendingPathComponent("scripts/pi_fixture.py").path,
            "--state", state.path, "--pi", pi, "--extension", CodexTestSupport.root.appendingPathComponent("helper/harnesses/pi/resources/bridge.js").path]
            .map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            session.active && session.agentID == "pi" && !session.loadingHistory && !session.busy && session.sessionID != nil
        }
        let process = try XCTUnwrap(session.process), conversation = try XCTUnwrap(session.sessionID)
        runtime.chat.chooseChat(true, session: session)
        session.draft = "thinking Pi through " + backend; runtime.chat.submit(session)
        session.draft = "tool Pi through " + backend; runtime.chat.queue(session)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            !session.busy && session.queuedMessages.isEmpty && session.turns.flatMap(\.items).contains {
                $0.kind == .tool && $0.completed && $0.output.contains("DISPATCH_CLAUDE_TOOL_OK")
            }
        }
        XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 2)
        runtime.chat.openModelPicker(session, column: .effort)
        let picker = try XCTUnwrap(session.modelPicker)
        try await TestSupport.eventually(timeout: .seconds(10)) { !picker.loading && !picker.efforts.isEmpty }
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "high" }))
        try await TestSupport.eventually(timeout: .seconds(10)) { session.modelPicker == nil }
        XCTAssertEqual(session.effort, "high")
        session.draft = "long stop via " + backend; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) { runtime.chat.canInterrupt(session) }
        XCTAssertTrue(runtime.chat.interrupt(session))
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.busy && session.interruptionID == nil }
        session.draft = "recovered via " + backend; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.busy && session.turns.flatMap(\.items).contains {
                $0.kind == .assistant && $0.completed && $0.text == "Local Claude fixture reply: recovered via " + backend
            }
        }
        XCTAssertEqual(session.sessionID, conversation)
        session.draft = "/quit"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { !session.active && !process.alive }
        XCTAssertFalse(session.showChat)
        XCTAssertNil(session.terminalAttention)
        XCTAssertTrue(session.draft.isEmpty)
        XCTAssertTrue(runtime.chat.canEnterChat(session))
    }
}
