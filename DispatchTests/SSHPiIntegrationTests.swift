import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class SSHPiIntegrationTests: XCTestCase {
    func testRemotePlainPiChat() async throws { try await walkthrough("plain") }
    func testRemoteTmuxPiChatAndBranchReconnect() async throws { try await walkthrough("tmux") }
    func testRemoteHerdrPiChatAndBranchReconnect() async throws { try await walkthrough("herdr") }

    func testRemotePlainTransportAndSessionLifecycle() async throws { try await walkthrough("plain", transportOnly: true) }
    func testRemoteTmuxTransportAndSessionLifecycle() async throws { try await walkthrough("tmux", transportOnly: true) }
    func testRemoteHerdrTransportAndSessionLifecycle() async throws { try await walkthrough("herdr", transportOnly: true) }

    func testRemoteManagedPiExtensionInstallReloadAndRevocation() async throws {
        try DesktopTestSupport.requireUnlocked()
        let fm = FileManager.default
        let pi = try XCTUnwrap([TestSupport.tool("pi")].first { fm.isExecutableFile(atPath: $0) })
        let state = URL(fileURLWithPath: "/tmp/dispatch-ssh-pi-setup-" + UUID().uuidString)
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                             "serve", "--state", state.path, "--delay", "0.015"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("SSH Pi managed extension fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        // The remote helper installs into its sessions' Pi directory (the server's own); the fixture's Pi uses it.
        let ssh = try await SSHTestServer(grant: .init(profile: .full, hooks: true)); defer { ssh.stop() }
        let home = ssh.agents.appendingPathComponent("pi"), extensions = home.appendingPathComponent("extensions")
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let other = extensions.appendingPathComponent("unrelated.js")
        let otherBytes = Data("export default function unrelated() {}\n".utf8)
        try otherBytes.write(to: other)
        let settings = home.appendingPathComponent("settings.json")
        try Data("{\"quietStartup\":true,\"editorPaddingX\":2,\"theme\":\"dark\"}\n".utf8).write(to: settings)
        let managed = extensions.appendingPathComponent("dispatch-chat.js")
        let source = try Data(contentsOf: CodexTestSupport.root.appendingPathComponent("helper/harnesses/pi/resources/bridge.js"))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let chat = runtime.chat
        defer { chat.setHelperIntegration("pi", enabled: false) }
        try await TestSupport.integrations(["pi"], enabled: false, chat: chat)
        let app = try TmuxWalkthrough(); defer { app.close() }
        let scope = try await ssh.authorize()
        runtime.ssh.permissions.saveHooks(false, for: scope, agent: .pi)
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("SSH Pi managed: \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        TerminalTestSupport.send("ssh " + (ssh.options + [ssh.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20)) {
            runtime.ssh.links.values.contains { $0.launch.tabID == id && $0.shellPID != nil }
        }
        session.manualViewChoice = true
        TerminalTestSupport.send(["python3", CodexTestSupport.root.appendingPathComponent("scripts/pi_fixture.py").path,
            "--state", state.path, "--pi", pi, "--integration", "--home", home.path].map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Pi setup discovery: \(session.status ?? "none")\n\(terminal.agentMenuScreen)") {
            let saved = (try? Data(contentsOf: settings)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return session.discoveryBlocked && session.status == "Pi Chat hooks are not enabled for this SSH configuration."
                && terminal.agentMenuScreen.contains("dispatch-fixture")
                && (saved?["lastChangelogVersion"] as? String)?.isEmpty == false
        }
        XCTAssertFalse(fm.fileExists(atPath: managed.path), "Remote discovery must respect this SSH configuration's Pi opt-out")
        // Seed the theme to avoid asynchronous terminal-theme detection, then
        // wait for Pi's changelog receipt before saving its startup baseline.
        let models = home.appendingPathComponent("models.json")
        let savedModels = try Data(contentsOf: models), savedSettings = try Data(contentsOf: settings)
        try await TestSupport.integrations(["pi"], enabled: true, chat: runtime.chat)
        try await TestSupport.eventually(timeout: .seconds(20), diagnostic: "Pi setup: \(runtime.chat.error ?? "none") / \(session.status ?? "none")") {
            (try? Data(contentsOf: managed)) == source && session.status?.contains("/reload") == true
        }
        XCTAssertFalse(session.active, "Installing on disk must wait for Pi's native reload")
        XCTAssertEqual(try Data(contentsOf: models), savedModels)
        XCTAssertEqual(try Data(contentsOf: settings), savedSettings)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        TerminalTestSupport.send("/reload", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25), diagnostic: "Pi reload: \(session.status ?? "none")\n\(terminal.agentMenuScreen)") {
            session.active && session.agentID == "pi" && session.remoteAgent != nil && session.sessionID != nil && !session.loadingHistory && !session.busy
        }
        let identity = try XCTUnwrap(session.remoteAgent), helper = try XCTUnwrap(session.helper)
        let conversation = try XCTUnwrap(session.sessionID)
        let process = try XCTUnwrap(AgentProcess.capture(identity.pid))
        let registration = home.appendingPathComponent("dispatch/sessions/\(identity.pid).json")
        XCTAssertTrue(fm.fileExists(atPath: registration.path))
        runtime.chat.chooseChat(true, session: session)
        session.draft = "managed SSH Pi ready"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && Self.reply("Local Claude fixture reply: managed SSH Pi ready", in: session) }
        let requests = try Data(contentsOf: state.appendingPathComponent("requests.jsonl"))
        session.draft = "preserve disabled remote Pi draft λ"
        runtime.chat.setHelperIntegration("pi", enabled: false)
        XCTAssertFalse(session.active); XCTAssertEqual(runtime.chat.hookStatus("pi"), .off)
        runtime.chat.submit(session)
        XCTAssertEqual(session.draft, "preserve disabled remote Pi draft λ")
        XCTAssertNotNil(session.submissionFailure)
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Pi disable: \(runtime.chat.error ?? "none")") {
            !fm.fileExists(atPath: managed.path)
        }
        let revoked = await helper.refuses("revoked Pi input must not run", conversation: conversation)
        XCTAssertTrue(revoked, "Remote Pi disable must revoke the loaded bridge before native reload")
        XCTAssertTrue(process.alive, "Disabling Chat must preserve the native Pi process")
        runtime.chat.chooseChat(false, session: session)
        TerminalTestSupport.send("/reload", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { !fm.fileExists(atPath: registration.path) }
        XCTAssertEqual(try Data(contentsOf: models), savedModels)
        XCTAssertEqual(try Data(contentsOf: settings), savedSettings)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), requests, "Disable and reload must not send or replay prompts")
        TerminalTestSupport.send("/quit", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { !process.alive }
    }

    private func walkthrough(_ backend: String, transportOnly: Bool = false) async throws {
        let phaseTimings = WalkthroughTimings(test: name, agent: "pi", transport: "ssh-" + backend)
        phaseTimings.begin("endpoint_startup")
        var passed = false
        defer { phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        let fm = FileManager.default
        let pi = try XCTUnwrap([TestSupport.tool("pi")].first { fm.isExecutableFile(atPath: $0) })
        let state = URL(fileURLWithPath: "/tmp/dispatch-ssh-pi-" + UUID().uuidString)
        let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py").path,
                             "serve", "--state", state.path, "--delay", transportOnly ? "0" : "0.035"]
        fixture.standardOutput = FileHandle.nullDevice; fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate(); fixture.waitUntilExit() }
            print("SSH Pi \(backend) fixture: " + state.path)
        }
        try await TestSupport.eventually { fm.fileExists(atPath: state.appendingPathComponent("endpoint.json").path) }
        phaseTimings.begin("SSH_setup")
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(server: backend != "tmux"); defer { app.close() }
        do {
            let ssh = try await SSHTestServer(grant: .init(profile: .full, hooks: true)); defer { ssh.stop() }
            let socket = state.appendingPathComponent("herdr.sock").path
            defer { if backend == "herdr" { _ = try? HerdrSocket(path: socket).request("server.stop") } }
            let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let original = try XCTUnwrap(runtime.views[origin])
            TerminalTestSupport.send("ssh " + (ssh.options + [ssh.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
            }
            let attach = backend == "tmux" ? app.attachCommand() :
                "export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(state.path) +
                "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr"
            if backend != "plain" {
                // Only the initial login starts a server with this SSH environment.
                // Reconnect must keep its existing panes and agent processes alive.
                TerminalTestSupport.send(backend == "tmux" ? app.attachCommand(login: true) : attach, to: original)
                try await TestSupport.eventually(timeout: .seconds(15)) {
                    backend == "tmux" ? app.workspace.current?.structured == true : app.workspace.current?.shows("herdr") == true
                }
            }
            let launch = ["/usr/bin/env", "TZ=Asia/Kathmandu", "python3", CodexTestSupport.root.appendingPathComponent("scripts/pi_fixture.py").path,
                "--state", state.path, "--pi", pi, "--extension", CodexTestSupport.root.appendingPathComponent("helper/harnesses/pi/resources/bridge.js").path,
                "--extension", CodexTestSupport.root.appendingPathComponent("scripts/fixtures/pi-navigation.js").path].map(HerdrLaunch.quote).joined(separator: " ")
            phaseTimings.begin("agent_readiness")
            let exercised = try await Self.exercise(backend, app: app, launch: launch, transportOnly: transportOnly, timings: phaseTimings)
            let session: ChatSession
            if backend == "plain" { session = exercised.session }
            else {
                session = try await reconnectBranch(exercised, app: app, ssh: ssh, origin: origin, attach: attach, state: state)
            }
            let helper = try XCTUnwrap(session.helper), conversation = try XCTUnwrap(session.sessionID)
            runtime.chat.chooseChat(true, session: session)
            try await Self.waitForInputReady(session)
            session.drafts.edit(text: "/new", multiline: false)
            XCTAssertTrue(session.draftIsCommand, "Leave the restored multiline draft mode before invoking /new")
            runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Pi /new: \(session.status ?? "none") / \(session.submissionFailure ?? "none"), attention=\(String(describing: session.terminalAttention)), draft=\(session.draft)\n\(runtime.views[session.id]?.agentMenuScreen ?? "missing terminal")") {
                session.active && session.sessionID != conversation && !session.loadingHistory && !session.busy
            }
            XCTAssertTrue(session.turns.isEmpty)
            let stale = await helper.refuses("stale conversation must not run", conversation: conversation)
            XCTAssertTrue(stale, "A prior conversation must not authorize remote Pi input")
            runtime.chat.chooseChat(true, session: session)
            session.draft = "new SSH Pi session"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && Self.reply("Local Claude fixture reply: new SSH Pi session", in: session) }
            session.draft = "/quit"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.active }
            XCTAssertTrue(runtime.chat.canEnterChat(session))
            let exited = await helper.refuses("must not reach shell", conversation: conversation)
            XCTAssertTrue(exited, "An exited Pi process must not authorize input")
            phaseTimings.begin("teardown")
            await app.close().value
            passed = testRun?.failureCount == 0
        } catch {
            phaseTimings.begin("teardown")
            await app.close().value
            throw error
        }
    }

    struct Exercised {
        let session: ChatSession
        let firstLeaf: String
    }

    static func exercise(_ backend: String, app: TmuxWalkthrough, launch: String, transportOnly: Bool = false, timings: WalkthroughTimings? = nil) async throws -> Exercised {
        let runtime = TerminalRuntime.shared
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[id]?.surface != nil }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("SSH Pi \(backend): \(session.status ?? "none") / \(session.submissionFailure ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        TerminalTestSupport.send(launch, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            session.active && session.agentID == "pi" && session.remoteAgent != nil && !session.loadingHistory && !session.busy
        }
        XCTAssertNil(session.process)
        let conversation = try XCTUnwrap(session.sessionID)
        func diagnose(_ stage: String) async {
            print("SSH Pi \(backend) \(stage): active=\(session.active) busy=\(session.busy) ack=\(session.awaitingPromptAck) blocked=\(session.discoveryBlocked) loading=\(session.loadingHistory) submission=\(session.submissionID?.uuidString ?? "none") status=\(session.status ?? "none") failure=\(session.submissionFailure ?? "none")")
            for turn in session.turns {
                print("Pi turn \(turn.id): " + turn.items.map { "\($0.id) \($0.kind) completed=\($0.completed) " + String($0.text.prefix(220)) }.joined(separator: " | "))
            }
            do {
                let state = try await XCTUnwrap(session.helper).native()
                print("Native Pi \(stage): busy=\(state.busy) leaf=\(state.leafID ?? "root") editor=\(state.editor.debugDescription)")
            } catch { print("Native Pi diagnostic: " + error.localizedDescription) }
        }
        timings?.begin("scenario")
        runtime.chat.chooseChat(true, session: session)
        terminal.insertText("unsent native Pi draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = try await waitForState(session) { $0.editor == "unsent native Pi draft" }
        session.draft = "preserve both drafts"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(10)) { session.submissionFailure != nil && session.submissionID == nil }
        XCTAssertEqual(session.draft, "preserve both drafts")
        let nativeDraft = try await XCTUnwrap(session.helper).native()
        XCTAssertEqual(nativeDraft.editor, "unsent native Pi draft")
        TerminalTestSupport.key(32, "u", terminal, modifiers: .control)
        _ = try await waitForState(session) { $0.editor.isEmpty }
        if transportOnly {
            session.draft = "SSH Pi " + backend + "\nUnicode λ"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(20)) {
                !session.busy && reply("Local Claude fixture reply: SSH Pi " + backend, in: session)
            }
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
        } else {
            // Keep a live window long enough for a remote poll and transcript read.
            session.draft = "thinking SSH Pi \(backend)\nUnicode λ\nlong streaming response"; runtime.chat.submit(session)
            do {
                try await TestSupport.eventually(timeout: .seconds(20)) {
                    session.busy && session.turns.flatMap(\.items).contains { [.assistant, .reasoning].contains($0.kind) && !$0.text.isEmpty && !$0.completed }
                }
            } catch { await diagnose("first stream"); throw error }
            try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && reply("Local Claude fixture reply: thinking SSH Pi " + backend, in: session) }
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
            XCTAssertEqual(session.turns.flatMap(\.items).filter { $0.kind == .assistant }.count, 1)
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .reasoning && $0.text.contains("Synthetic fixture trace") })
        }
        let first = try await XCTUnwrap(session.helper).native()
        let firstLeaf = try XCTUnwrap(first.leafID)
        if !transportOnly {
            session.draft = "thinking SSH Pi queue first"; runtime.chat.submit(session)
            session.draft = "SSH Pi queue second"; runtime.chat.queue(session)
            try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && session.queuedMessages.isEmpty && reply("Local Claude fixture reply: SSH Pi queue second", in: session) }
            session.draft = "tool SSH Pi check"; runtime.chat.submit(session)
            do {
                try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && reply("Tool result received: completed.", in: session) }
            } catch { await diagnose("tool completion"); throw error }
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .tool && $0.completed && $0.output.contains("DISPATCH_CLAUDE_TOOL_OK") })
        }
        runtime.chat.openModelPicker(session, column: .effort)
        let picker = try XCTUnwrap(session.modelPicker)
        try await TestSupport.eventually(timeout: .seconds(15)) { !picker.loading && !picker.efforts.isEmpty }
        XCTAssertNil(picker.error)
        XCTAssertTrue(picker.models.contains { $0.name == "dispatch-local/dispatch-fixture" })
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "high" }))
        try await TestSupport.eventually(timeout: .seconds(15)) { session.modelPicker == nil }
        XCTAssertEqual(session.effort, "high")
        if transportOnly {
            let messages = ["SSH Pi transport first", "SSH Pi transport second\nwith λ"]
            for message in messages { session.draft = message; runtime.chat.queue(session) }
            session.draft = "preserved Pi transport draft"
            try await TestSupport.eventually(timeout: .seconds(20)) {
                !session.busy && session.queuedMessages.isEmpty && session.submissionID == nil
                    && reply("Local Claude fixture reply: " + messages[1], in: session)
            }
            XCTAssertNil(session.queuePaused)
            XCTAssertEqual(session.draft, "preserved Pi transport draft")
            XCTAssertEqual(Array(session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text).suffix(2)), messages)
            XCTAssertEqual(session.effort, "high")
        } else {
            session.draft = "long SSH Pi stop"; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(20)) { runtime.chat.canInterrupt(session) }
            session.draft = "do not send after stop"; runtime.chat.queue(session)
            session.draft = "keep the SSH Pi draft λ\nsecond line"
            XCTAssertTrue(runtime.chat.interrupt(session))
            XCTAssertFalse(runtime.chat.interrupt(session))
            try await TestSupport.eventually(timeout: .seconds(15)) { !session.busy && session.interruptionID == nil }
            XCTAssertEqual(session.draft, "keep the SSH Pi draft λ\nsecond line")
            XCTAssertNotNil(session.queuePaused); XCTAssertEqual(session.queuedMessages.count, 1)
            runtime.chat.removeQueued(try XCTUnwrap(session.queuedMessages.first?.id), from: session)
        }
        session.draft = "recovered SSH Pi"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(20)) { !session.busy && reply("Local Claude fixture reply: recovered SSH Pi", in: session) }
        XCTAssertEqual(session.sessionID, conversation)
        return Exercised(session: session, firstLeaf: firstLeaf)
    }

    static func reply(_ text: String, in session: ChatSession) -> Bool {
        session.turns.flatMap(\.items).contains { $0.kind == .assistant && $0.completed && $0.text.contains(text) }
    }

    static func waitForState(_ session: ChatSession, matching predicate: (HelperChat.Native) -> Bool) async throws -> HelperChat.Native {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            let state = try await XCTUnwrap(session.helper).native()
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HerdrFailure("Remote Pi state did not become ready")
    }

    static func waitForInputReady(_ session: ChatSession) async throws {
        // Restored history and the bridge's idle state can arrive before Chat's
        // activity check finishes. Wait for the same gates used by submission.
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic:
            "Pi input: active=\(session.active) busy=\(session.busy) history=\(session.loadingHistory) activity=\(session.activityCheck != nil) ack=\(session.awaitingPromptAck)") {
            TerminalRuntime.shared.chat.canPickModel(session) && !session.awaitingPromptAck
                && TerminalRuntime.shared.views[session.id] != nil
        }
    }

    private func reconnectBranch(_ exercised: Exercised, app: TmuxWalkthrough, ssh: SSHTestServer,
                                 origin: UUID, attach: String, state: URL) async throws -> ChatSession {
        let runtime = TerminalRuntime.shared, session = exercised.session
        let identity = try XCTUnwrap(session.remoteAgent), conversation = try XCTUnwrap(session.sessionID)
        let process = try XCTUnwrap(AgentProcess.capture(identity.pid))
        let terminal = try XCTUnwrap(runtime.views[session.id])
        runtime.chat.chooseChat(false, session: session)
        TerminalTestSupport.send("/dispatch-test-branch " + exercised.firstLeaf, to: terminal)
        _ = try await Self.waitForState(session) { $0.leafID == exercised.firstLeaf && !$0.busy }
        try await TestSupport.eventually(timeout: .seconds(15)) {
            !session.loadingHistory && session.turns.flatMap(\.items).filter { $0.kind == .user }.count == 1
        }
        XCTAssertFalse(Self.reply("recovered SSH Pi", in: session), "The selected earlier branch must omit later transcript entries")
        let turns = session.turns.map(\.id)
        let draft = "Keep the branch reconnect draft λ\nsecond line"; session.draft = draft
        let requests = try Data(contentsOf: state.appendingPathComponent("requests.jsonl"))
        let connection = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
        let closed = try await SSHCommand.run(executable: connection.launch.master.executable,
                                              arguments: connection.launch.master.controlArguments("exit"))
        XCTAssertEqual(closed.status, 0)
        try await TestSupport.eventually(timeout: .seconds(20)) { runtime.ssh.links[connection.launch.connectionID] == nil && !session.active }
        XCTAssertTrue(process.alive)
        XCTAssertEqual(session.draft, draft)
        app.workspace.newLocalSpace()
        let source = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[source].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let shell = try XCTUnwrap(runtime.views[source])
        TerminalTestSupport.send("ssh " + (ssh.options + [ssh.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: shell)
        try await TestSupport.eventually(timeout: .seconds(20)) { runtime.ssh.links.values.contains { $0.launch.tabID == source && $0.shellPID != nil } }
        TerminalTestSupport.send(attach, to: shell)
        func restoredSession() -> ChatSession? {
            app.workspace.current?.tabs.flatMap(\.surfaceIDs).compactMap { id in
                let candidate = runtime.chat.session(for: id)
                return candidate.active && candidate.remoteAgent == identity && candidate.sessionID == conversation && !candidate.loadingHistory ? candidate : nil
            }.first
        }
        try await TestSupport.eventually(timeout: .seconds(25)) { restoredSession() != nil }
        let restored = try XCTUnwrap(restoredSession())
        app.workspace.selectSurface(restored.id)
        _ = try await Self.waitForState(restored) { $0.leafID == exercised.firstLeaf && !$0.busy }
        XCTAssertEqual(restored.sessionID, conversation)
        XCTAssertEqual(restored.draft, draft); XCTAssertEqual(restored.turns.map(\.id), turns)
        XCTAssertEqual(restored.turns.flatMap(\.items).filter { $0.kind == .user }.count, 1)
        XCTAssertFalse(Self.reply("recovered SSH Pi", in: restored))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("requests.jsonl")), requests, "Reconnect must not send or replay input")
        return restored
    }
}
