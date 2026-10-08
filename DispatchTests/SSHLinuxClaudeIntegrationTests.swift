import AppKit
import XCTest
@testable import DispatchApp

/// Real Linux CLI/PTY, rendered by the macOS app through authenticated SSH.
@MainActor
final class SSHLinuxClaudeIntegrationTests: XCTestCase {
    func testLinuxPlainClaudeChat() async throws { try await walkthrough("plain") }
    func testLinuxTmuxClaudeChat() async throws { try await walkthrough("tmux") }
    func testLinuxHerdrClaudeChat() async throws { try await walkthrough("herdr") }
    func testLinuxPlainTransportModelQueueAndExit() async throws { try await walkthrough("plain", transportOnly: true) }
    func testLinuxTmuxTransportModelQueueAndExit() async throws { try await walkthrough("tmux", transportOnly: true) }
    func testLinuxHerdrTransportModelQueueAndExit() async throws { try await walkthrough("herdr", transportOnly: true) }
    func testLinuxPlainClaudeApprovalsAndQuestions() async throws { try await walkthrough("plain", hooks: true) }
    func testLinuxTmuxClaudeApprovalsAndQuestions() async throws { try await walkthrough("tmux", hooks: true) }
    func testLinuxHerdrClaudeApprovalsAndQuestions() async throws { try await walkthrough("herdr", hooks: true) }

    private func walkthrough(_ backend: String, hooks: Bool = false, transportOnly: Bool = false) async throws {
        let phaseTimings = WalkthroughTimings(test: name, agent: "claude", transport: "linux-" + backend)
        phaseTimings.begin("SSH_setup")
        var passed = false
        defer { phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        let profile = try JSONDecoder().decode(SSHLinuxTestProfile.self,
            from: Data(contentsOf: SSHLinuxTestProfile.configurationURL()))
        let claude = try XCTUnwrap(profile.claude, "Pair the Linux runner with --agent claude --claude PATH")
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true); defer { app.close() }
        let origin = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
        let terminal = try XCTUnwrap(runtime.views[origin])
        try await SSHTestServer.authorize(arguments: profile.options + [profile.destination], grant: .init(profile: .full, hooks: hooks))
        TerminalTestSupport.send("ssh " + (profile.options + [profile.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25), diagnostic: "Linux SSH bootstrap: " + TerminalTestSupport.screen(terminal: terminal)) {
            runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
        }
        let ssh = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
        let root = "/tmp/dispatch-claude-linux-" + UUID().uuidString
        let script = root + "/claude_fixture.py", state = root + "/state"
        let socket = root + "/" + backend + ".sock"
        @discardableResult
        func remote(_ argv: [String], input: Data = Data()) async throws -> Data {
            let result = try await SSHTestCommand.run(master: ssh.launch.master, argv: argv, input: input)
            guard result.status == 0 else { throw HerdrFailure("Linux fixture command failed: " + String(decoding: result.output, as: UTF8.self)) }
            return result.output
        }
        phaseTimings.begin("endpoint_startup")
        try await remote(["/bin/mkdir", "-m", "700", root])
        try await remote(["/usr/bin/tee", script], input: Data(contentsOf: CodexTestSupport.root.appendingPathComponent("scripts/claude_fixture.py")))
        try await remote(["/usr/bin/tee", root + "/fixture_barriers.py"],
            input: Data(contentsOf: CodexTestSupport.root.appendingPathComponent("scripts/fixture_barriers.py")))
        let fixture = try SSHTestDaemon(master: ssh.launch.master,
            argv: ["/usr/bin/python3", script, "serve", "--state", state, "--delay", (transportOnly || hooks) ? "0" : "0.025"], pidFile: root + "/fixture.pid")
        func cleanup() async {
            // Ending tmux control mode closes this SSH session: stop the fixture first.
            await fixture.stop()
            if backend == "herdr" {
                do { try await SSHTestCommand.stopHerdr(master: ssh.launch.master, socket: socket) }
                catch { XCTFail("Cannot stop isolated Linux herdr fixture: " + error.localizedDescription) }
            }
            if backend == "tmux" { _ = try? await remote([profile.supportedTmuxPath, "-S", socket, "kill-server"]) }
            print("Linux Claude \(backend) fixture retained at " + root)
        }
        do {
            try await fixture.waitUntilReady(marker: "Local Claude endpoint:")
            if backend == "tmux" {
                TerminalTestSupport.send(HerdrLaunch.quote(profile.supportedTmuxPath) + " -u -S " + HerdrLaunch.quote(socket) + " -f /dev/null -CC new-session -s claude /bin/bash", to: terminal)
                try await app.wait { app.workspace.current?.structured == true }
            } else if backend == "herdr" {
                TerminalTestSupport.send("export PATH=" + HerdrLaunch.quote(profile.path) + "; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(root)
                    + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: terminal)
                try await TestSupport.eventually(timeout: .seconds(15), diagnostic: TerminalTestSupport.screen(terminal: terminal)) { app.workspace.current?.shows("herdr") == true }
            }
            let launch = ["/usr/bin/env", "TZ=Asia/Kathmandu", "python3", script, "launch", "--state", state, "--claude", claude, "--integration"]
                .map(HerdrLaunch.quote).joined(separator: " ")
            phaseTimings.begin("agent_readiness")
            if hooks {
                // Login with hook routing disabled, then install only for the
                // registered CLI's private fixture profile during discovery.
                runtime.chat.stop()
                runtime.chat = ChatCoordinator(enabled: true)
                runtime.chat.start()
                try await TestSupport.integrations(["claude"], enabled: true, chat: runtime.chat)
                try await exerciseHooks(app: app, launch: launch, state: state, config: state + "/claude-home", master: ssh.launch.master)
            } else { try await SSHClaudeIntegrationTests.exercise(backend, app: app, launch: launch, transportOnly: transportOnly, timings: phaseTimings, settings: {
                let result = try await SSHTestCommand.run(master: ssh.launch.master, argv: ["/bin/cat", state + "/claude-home/settings.json"])
                return result.status == 0 ? result.output : nil
            }, requests: { try await remote(["/bin/cat", state + "/requests.jsonl"]) }) }
            phaseTimings.begin("teardown")
            await cleanup()
            await app.close().value
            passed = testRun?.failureCount == 0
        } catch {
            phaseTimings.begin("teardown")
            await cleanup(); await app.close().value
            throw error
        }
    }

    private func exerciseHooks(app: TmuxWalkthrough, launch: String, state: String, config: String, master: SSHMaster) async throws {
        let runtime = TerminalRuntime.shared
        let id = try XCTUnwrap(app.workspace.activeSurfaceID)
        try await app.wait {
            runtime.views[id].map { $0.surface != nil && !$0.agentMenuScreen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == true
        }
        let terminal = try XCTUnwrap(runtime.views[id]), session = runtime.chat.session(for: id)
        defer { print("Linux Claude hooks: \(session.status ?? "none") / \(runtime.chat.error ?? "none")\n\(terminal.agentMenuScreen)") }
        session.manualViewChoice = true
        TerminalTestSupport.send(launch, to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            session.active && session.agentID == "claude" && terminal.agentMenuScreen.contains("for shortcuts")
        }
        let settings = config + "/settings.json"
        var installed = Data()
        var lastRead = "Settings have not been read."
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let read = try await SSHTestCommand.run(master: master, argv: ["/bin/cat", settings])
            lastRead = "status=\(read.status) " + String(decoding: read.output, as: UTF8.self)
            if read.status == 0, String(decoding: read.output, as: UTF8.self).contains("AskUserQuestion") { installed = read.output; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !installed.isEmpty else {
            let metadata = try await SSHTestCommand.run(master: master, argv: ["/usr/bin/stat", "-c", "%a %n", settings])
            throw HerdrFailure("Discovery must install hooks in the isolated Claude profile: "
                + (runtime.chat.error ?? "no setup error") + "; " + lastRead + "; "
                + String(decoding: metadata.output, as: UTF8.self))
        }
        TerminalTestSupport.send("/exit", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(15)) { !session.active }
        TerminalTestSupport.send(launch + " --hooks", to: terminal)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            session.active && session.agentID == "claude" && !session.loadingHistory && !session.busy && terminal.agentMenuScreen.contains("for shortcuts")
        }
        runtime.chat.chooseChat(true, session: session)
        let marker = state + "/work/dispatch-approval-marker"
        for decision in [PendingApproval.Decision.deny, .allow] {
            session.draft = "permission tool " + decision.rawValue; runtime.chat.submit(session)
            try await TestSupport.eventually(timeout: .seconds(25), diagnostic: "Claude permission submit: \(session.status ?? "none") / \(session.submissionFailure ?? "none"), blocked=\(session.inputBlocked), draft=\(session.draft), sending=\(session.submissionID != nil)") { session.approvals.contains(where: \.pending) }
            let request = try XCTUnwrap(session.approvals.last(where: \.pending))
            XCTAssertNil(request.questions)
            request.resolve(decision)
            try await TestSupport.eventually(timeout: .seconds(25)) {
                !session.busy && session.turns.last?.items.contains { $0.kind == .assistant && $0.text.contains("Tool result received:") } == true
            }
            let read = try await SSHTestCommand.run(master: master, argv: ["/bin/cat", marker])
            XCTAssertEqual(read.status == 0, decision == .allow)
            if decision == .allow { XCTAssertEqual(String(decoding: read.output, as: UTF8.self), "approved") }
        }
        session.draft = "multiple questions please"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(25)) { session.approvals.contains { $0.pending && $0.questions != nil } }
        let request = try XCTUnwrap(session.approvals.last(where: \.pending))
        XCTAssertEqual(request.questions?.questions.count, 3)
        let answers = ["How much detail should the reply include?": "Detailed", "Which checks should be included?": "Tests, Documentation",
                       "Which language should the example use?": "Python λ\n" + String(repeating: "complete example ", count: 100)]
        request.answer(answers)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            !session.busy && session.turns.last?.items.contains { $0.kind == .assistant && $0.text.contains("Answers received:") && $0.text.contains("Python λ") } == true
        }
        XCTAssertEqual(request.answers, answers)
        session.draft = "question skip"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(25)) { session.approvals.contains { $0.pending && $0.questions != nil } }
        let skipped = try XCTUnwrap(session.approvals.last(where: \.pending))
        skipped.resolve(.deny)
        try await TestSupport.eventually(timeout: .seconds(25)) {
            !session.busy && session.turns.last?.items.contains { $0.kind == .assistant && $0.text.contains("denied or failed.") } == true
        }
        session.draft = "question revoke"; runtime.chat.submit(session)
        try await TestSupport.eventually(timeout: .seconds(25)) { session.approvals.contains { $0.pending && $0.questions != nil } }
        let revoked = try XCTUnwrap(session.approvals.last(where: \.pending))
        // Turning the integration off returns its pending questions to the terminal at once.
        runtime.chat.setHelperIntegration("claude", enabled: false)
        XCTAssertFalse(revoked.pending)
        revoked.answer(["How much detail should the reply include?": "Compact"])
        XCTAssertNil(revoked.answers)
        try await TestSupport.eventually(timeout: .seconds(15)) { ClaudeScreen.question(terminal.agentMenuScreen) }
        let read = try await SSHTestCommand.run(master: master, argv: ["/bin/cat", settings])
        XCTAssertEqual(read.status, 0); XCTAssertEqual(read.output, installed)
        _ = try await PresentationTestSupport.capture(app.window, named: "linux-claude-questions", in: "claude-chat-audit")
    }
}
