import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class ChatModelPickerTests: XCTestCase {
    func testNativeModelNameMatchesSlugAndCatalogDisplayName() {
        for (text, expected) in [("model: dispatch-fixture", true), ("model: Dispatch fixture", true),
                                 ("Model changed to Dispatch fixture high", true), ("model: another", false),
                                 ("model: dispatch-fixture-extra", false)] {
            XCTAssertEqual(AgentModelMenu.containsModel(text, slug: "dispatch-fixture", name: "Dispatch fixture"), expected)
        }
    }

    func testModelLabelsDropVendorPrefixes() {
        for (model, expected) in [
            ("claude-opus-5-5", "opus-5.5"), ("claude-opus-5.5", "opus-5.5"), ("claude-sonnet-5", "sonnet-5"),
            ("claude-opus-5-5[1m]", "opus-5.5[1m]"), ("claude-haiku-4-5-20251001", "haiku-4.5"),
            ("claude-3-5-sonnet-20241022", "sonnet-3.5"), ("claude-sonnet-4-5-latest", "sonnet-4.5"),
            ("us.anthropic.claude-opus-4-1-20250805-v1:0", "opus-4.1"), ("claude-opus-4-1@20250805", "opus-4.1"),
            ("anthropic/claude-fable-5-1", "fable-5.1"), ("opus", "opus"), ("default", "default"),
            ("gpt-5.6-sol", "sol-5.6"), ("gpt-6-astra-latest", "astra-6"), ("openai/gpt-6.1-sol", "sol-6.1"),
            ("gpt-5.5", "gpt-5.5"), ("gpt-4o", "gpt-4o"), ("google/gemini-2.5-pro", "gemini-2.5-pro"),
            ("dispatch-fixture", "dispatch-fixture"),
        ] {
            XCTAssertEqual(ChatModelControls.label(for: model), expected, model)
        }
    }

    func testClaudeMenuDetailsNameModelsAndEffortsSortStrongestFirst() {
        for (detail, expected) in [("Opus 5.5 · Best for everyday, complex tasks", "claude-opus-5-5"),
                                   ("Fable 5.1 · Most capable", "claude-fable-5-1"), ("Sonnet 5 · Efficient", "claude-sonnet-5"),
                                   ("Haiku 4.5", "claude-haiku-4-5"), ("Description", nil), ("", nil)] as [(String, String?)] {
            XCTAssertEqual(ClaudeModelMenu.modelID(detail: detail), expected, detail)
        }
        XCTAssertEqual(ClaudeModelMenu.sortedEfforts(["xhigh", "max", "ultracode", "low", "future", "medium", "high"]),
                       ["ultracode", "max", "xhigh", "high", "medium", "low", "future"])
    }

    func testLiveMenuParsingAndMalformedScreens() throws {
        let screen = """
        Select Model and Effort
        Access legacy models by running codex -m <model_name>
        › 1. gpt-6-astra (default)  A capable model
          2. gpt-5.6-sol (current)  A fast model
        Press enter to confirm or esc to go back
        """
        let menu = try XCTUnwrap(AgentModelMenu(screen))
        // Codex 0.157.0: tui/src/chatwidget/snapshots/{custom_model_display_name_all_models,
        // custom_model_display_name_reasoning,model_advanced_reasoning_selection_popup}.snap
        // (each filename has the codex_tui__chatwidget__tests__ prefix).
        for footer in ["enter select · esc back", "enter default · s session · esc back", "enter apply · s session · esc back"] {
            XCTAssertEqual(AgentModelMenu(screen.replacingOccurrences(of: "Press enter to confirm or esc to go back", with: footer)), menu)
        }
        XCTAssertEqual(menu.kind, .models)
        XCTAssertEqual(menu.selected, "gpt-6-astra")
        XCTAssertEqual(menu.choices.map(\.name), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertTrue(menu.choices[0].isDefault)
        XCTAssertTrue(menu.choices[1].current)
        XCTAssertEqual(menu.choices[1].detail, "A fast model")
        XCTAssertNil(AgentModelMenu(screen.replacingOccurrences(of: "›", with: " ")))
        XCTAssertNil(AgentModelMenu(screen.replacingOccurrences(of: "esc to go back", with: "")))
        XCTAssertNil(AgentModelMenu(screen.replacingOccurrences(of: "gpt-5.6-sol", with: "gpt-6-astra")))
        XCTAssertNil(AgentModelMenu(String(repeating: "x", count: 65_537) + screen))
        let effort = try XCTUnwrap(AgentModelMenu("""
        Select Reasoning Level for gpt-5.6-sol
          1. Low (default)  Fast responses
        › 2. Extra high (current)  More reasoning
          3. More reasoning…  Max and Ultra consume usage limits faster
        Press enter to confirm or esc to go back
        """))
        XCTAssertEqual(effort.kind, .effort("gpt-5.6-sol"))
        XCTAssertEqual(effort.choices.map(\.effort), ["low", "xhigh", nil])
    }

    func testCatalogStopsWhenWrapProvesEveryNumberedModelIsKnown() async throws {
        for width in [2, 7] {
            for current in [0, 3, 5] {
                var selected = current, keys: [AgentMenuKey?] = []
                let picker = ChatModelPicker(model: "model-\(current)", effort: nil, column: .model, screen: {
                    let start = min(selected, 7 - width)
                    let rows = (start..<(start + width)).map { index in
                        "\(selected == index ? "›" : " ") \(index + 1). model-\(index)\(current == index ? " (current)" : "")  Description \(index)"
                    }
                    return (["Select Model and Effort"] + rows + ["Press enter to confirm or esc to go back"]).joined(separator: "\n")
                }, send: { key in
                    keys.append(key)
                    if key == .down { selected = (selected + 1) % 7 }
                    else { XCTAssertNil(key) }
                }, confirmed: { _, _ in XCTFail("Reading choices must not apply a model") }, finished: { _ in })
                picker.start()
                try await TestSupport.eventually { !picker.loading }
                XCTAssertNil(picker.error)
                XCTAssertEqual(picker.models, (0..<7).map {
                    AgentModelMenu.Choice(number: $0 + 1, name: "model-\($0)", detail: "Description \($0)",
                                         current: $0 == current, isDefault: false)
                })
                let moves = max(7 - current, 7 - width)
                XCTAssertEqual(keys, [nil] + Array(repeating: .down, count: moves))
                XCTAssertEqual(picker.highlightedModel, "model-\(current)")
                picker.abandon()
            }
        }
    }

    func testCancellationDoesNotReplayOpeningCommandOrConfirm() async throws {
        for agent in ["codex", "claude"] {
            var commands: [AgentMenuKey?] = [], finished = 0, confirmations = 0
            let picker = ChatModelPicker(agentID: agent, model: "unknown", effort: nil, column: .model, screen: { "ordinary prompt" },
                send: { commands.append($0) }, confirmed: { _, _ in confirmations += 1 }, finished: { terminal in
                    XCTAssertTrue(terminal, "Interrupted menu input must remain visible in Terminal")
                    finished += 1
                })
            picker.start()
            try await TestSupport.eventually { commands.count == 1 }
            picker.close(); picker.close()
            try await TestSupport.eventually { finished == 1 }
            XCTAssertEqual(commands.count, 1)
            XCTAssertNil(commands[0])
            XCTAssertEqual(confirmations, 0)
        }
    }

    func testPickerAvailabilityRequiresIdleAttachedSession() {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        // Attached: a helper chat (terminal 0 stands in; no request is made while the picker is refused).
        session.helper = HelperChat(terminal: 0)
        session.active = true
        for version in ["0.153.4", "99.0.0-dev", nil] as [String?] {
            session.version = version
            XCTAssertTrue(coordinator.canPickModel(session))
        }
        let blocked: [(ChatSession) -> Void] = [
            { $0.active = false }, { $0.busy = true },
            { $0.discoveryBlocked = true }, { $0.loadingHistory = true },
            { $0.activityCheck = UUID() }, { $0.submissionID = UUID() }
        ]
        for block in blocked {
            session.active = true; session.busy = false; session.version = "0.153.4"
            session.discoveryBlocked = false; session.loadingHistory = false
            session.activityCheck = nil; session.submissionID = nil
            block(session)
            XCTAssertFalse(coordinator.canPickModel(session))
            coordinator.openModelPicker(session, column: .model)
            XCTAssertNil(session.modelPicker)
        }
    }

    func testUnverifiedAgentFailurePreservesSelectionAndDoesNotRetry() async throws {
        var calls = 0, confirmations = 0
        let picker = ChatModelPicker(model: "old", effort: "high", column: .effort, screen: { "" },
            send: { _ in calls += 1; throw HerdrFailure("Agent identity changed") },
            confirmed: { _, _ in confirmations += 1 }, finished: { _ in })
        picker.start()
        try await TestSupport.eventually { !picker.loading }
        XCTAssertEqual(calls, 1); XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(picker.selectedModel, "old")
        XCTAssertEqual(picker.error, "Agent identity changed")
        picker.close()
    }

    func testQuickModelsRemainAvailableAfterBrowsingFullList() async throws {
        var page = "", row = 0, openings = 0, selections = 0
        func screen() -> String {
            let choices = page == "Select Model" ? ["codex-auto-fast", "All models"] : ["gpt-6-astra", "gpt-5.6-sol"]
            guard page.hasPrefix("Select Model") else { return page }
            return page + "\n" + choices.enumerated().map { index, name in
                "\(index == row ? "›" : " ") \(index + 1). \(name)  Agent description"
            }.joined(separator: "\n") + "\nPress enter to confirm or esc to go back"
        }
        let picker = ChatModelPicker(model: "unlisted", effort: nil, column: .model, screen: screen, send: { key in
            switch key {
            case .end, .clearLine, .interrupt, .left, .right, .thisSession: XCTFail("Unexpected key from the Codex model picker")
            case nil: openings += 1; page = "Select Model"; row = 0
            case .down, .up: row = 1 - row
            case .escape: page = ""
            case .enter:
                if page == "Select Model", row == 1 { page = "Select Model and Effort"; row = 0 }
                else { selections += 1; page = "• Model changed to codex-auto-fast low" }
            }
        }, confirmed: { model, effort in
            XCTAssertEqual(model, "codex-auto-fast"); XCTAssertEqual(effort, "low")
        }, finished: { XCTAssertFalse($0) })
        picker.start()
        try await TestSupport.eventually { !picker.loading }
        XCTAssertNil(picker.error)
        XCTAssertEqual(picker.models.map(\.name), ["codex-auto-fast", "gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(selections, 0)
        picker.selectModel("codex-auto-fast")
        try await TestSupport.eventually { !picker.loading }
        XCTAssertNil(picker.error)
        XCTAssertFalse(picker.presented)
        XCTAssertEqual(openings, 2); XCTAssertEqual(selections, 1)
    }

    func testEffortsAreReadOnlyWhenRequested() async throws {
        // Claude 2.1.285's effort ring wraps; a clamped ring needs both directions.
        for (agent, wraps) in [("codex", false), ("claude", false), ("claude", true)] {
            var page = "", level = 1, keys: [AgentMenuKey?] = []
            let levels = ["Low", "High"]
            func screen() -> String {
                guard !page.isEmpty else { return "" }
                if agent == "claude" {
                    return "Select model\n❯ 1. Custom ✔  Description\n● \(levels[level]) effort ←/→ to adjust\nEnter to set as default · s to use this session only · Esc to cancel"
                }
                return page == "model"
                    ? "Select Model and Effort\n› 1. Custom (current)  Description\nPress enter to confirm or esc to go back"
                    : "Select Reasoning Level for Custom\n  1. Low  Fast\n› 2. High (current)  Thorough\nPress enter to confirm or esc to go back"
            }
            let picker = ChatModelPicker(agentID: agent, model: "Custom", effort: "high", column: .model, screen: screen,
                send: { key in
                    keys.append(key)
                    switch key {
                    case nil: page = "model"
                    case .left: level = wraps ? (level + levels.count - 1) % levels.count : max(0, level - 1)
                    case .right: level = wraps ? (level + 1) % levels.count : min(levels.count - 1, level + 1)
                    case .enter: XCTAssertEqual(agent, "codex"); XCTAssertEqual(page, "model"); page = "effort"
                    case .escape: page = ""
                    default: XCTFail("Unexpected navigation for a single-model catalog")
                    }
                }, confirmed: { _, _ in XCTFail("Reading choices must not apply them") }, finished: { _ in })
            picker.start()
            try await TestSupport.eventually { !picker.loading }
            XCTAssertNil(picker.error)
            XCTAssertEqual(keys.map { $0?.rawValue }, [nil])
            XCTAssertEqual(picker.models.map(\.name), ["Custom"])
            XCTAssertEqual(picker.efforts, [])
            picker.showColumn(.effort)
            try await TestSupport.eventually(timeout: .seconds(6)) { !picker.loading }
            XCTAssertNil(picker.error)
            // Claude lists stronger efforts first; Codex keeps its menu order.
            XCTAssertEqual(picker.efforts.map(\.effort), agent == "claude" ? ["high", "low"] : ["low", "high"])
            XCTAssertEqual(picker.efforts.filter(\.current).map(\.effort), ["high"])
            XCTAssertEqual(level, 1)
            // One lap of a wrapping ring already visited every level.
            if wraps { XCTAssertEqual(keys.map { $0?.rawValue }, [nil, AgentMenuKey.left.rawValue, AgentMenuKey.left.rawValue]) }
            picker.close()
            try await TestSupport.eventually { page.isEmpty }
        }
    }

    func testRealLocalModelAndEffortPicker() async throws { try await walkthrough("local") }
    func testRealLocalTmuxModelAndEffortPicker() async throws { try await walkthrough("local-tmux") }
    func testRealLocalHerdrModelAndEffortPicker() async throws { try await walkthrough("local-herdr") }
    func testRealSSHModelAndEffortPicker() async throws { try await walkthrough("ssh") }
    func testRealSSHTmuxModelAndEffortPicker() async throws { try await walkthrough("ssh-tmux") }
    func testRealSSHHerdrModelAndEffortPicker() async throws { try await walkthrough("ssh-herdr") }
    func testLocalTransportModelQueueAndExit() async throws { try await walkthrough("local", transportOnly: true) }
    func testLocalTmuxTransportModelQueueAndExit() async throws { try await walkthrough("local-tmux", transportOnly: true) }
    func testLocalHerdrTransportModelQueueAndExit() async throws { try await walkthrough("local-herdr", transportOnly: true) }
    func testSSHTransportModelQueueAndExit() async throws { try await walkthrough("ssh", transportOnly: true) }
    func testSSHTmuxTransportModelQueueAndExit() async throws { try await walkthrough("ssh-tmux", transportOnly: true) }
    func testSSHHerdrTransportModelQueueAndExit() async throws { try await walkthrough("ssh-herdr", transportOnly: true) }
    func testRealLocalChatCommands() async throws { try await walkthrough("local", commandsOnly: true) }
    func testRealHerdrChatCommands() async throws { try await walkthrough("local-herdr", commandsOnly: true) }
    func testRealSSHChatCommands() async throws { try await walkthrough("ssh", commandsOnly: true) }
    func testRealLocalTmuxChatCommands() async throws { try await walkthrough("local-tmux", commandsOnly: true) }
    func testRealSSHTmuxChatCommands() async throws { try await walkthrough("ssh-tmux", commandsOnly: true) }
    func testRealSSHHerdrChatCommands() async throws { try await walkthrough("ssh-herdr", commandsOnly: true) }

    func testRealQueuedMessagesCancelledByPermissionRevocation() async throws {
        for backend in ["ssh", "ssh-tmux", "ssh-herdr"] {
            try await walkthrough(backend, revokeQueued: true)
        }
    }

    func testRealQueuedMessagesStayPausedAfterAcceptedTurnIsRevoked() async throws {
        for backend in ["ssh", "ssh-tmux", "ssh-herdr"] {
            try await walkthrough(backend, revokeQueued: true, afterAccepted: true)
        }
    }

    private func walkthrough(_ backend: String, commandsOnly: Bool = false, revokeQueued: Bool = false, afterAccepted: Bool = false, transportOnly: Bool = false) async throws {
        let phaseTimings = WalkthroughTimings(test: name, agent: "codex", transport: backend)
        phaseTimings.begin("endpoint_startup")
        let fixture = try CodexEndpointFixture(prefix: "dispatch-model-picker-", delay: 0, hooks: false)
        var passed = false
        defer { fixture.stop(removeState: passed); phaseTimings.save(passed: passed && testRun?.failureCount == 0) }
        try await fixture.start(timeout: .seconds(15))
        if commandsOnly || transportOnly {
            let catalog = transportOnly ? fixture.state.appendingPathComponent("transport-models.json")
                : CodexTestSupport.root.appendingPathComponent("DispatchTests/Fixtures/codex-command-models.json")
            if transportOnly { try CodexTestSupport.transportModelCatalog().write(to: catalog, options: .atomic) }
            let config = fixture.state.appendingPathComponent("codex-home/config.toml")
            let contents = try String(contentsOf: config, encoding: .utf8)
            try ("model_catalog_json = \"\(catalog.path)\"\n" + contents).write(to: config, atomically: true, encoding: .utf8)
        }
        phaseTimings.begin("SSH_setup")
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator(enabled: true)
        if !backend.hasPrefix("ssh") { runtime.chat.disabledIntegrations.insert("codex") }
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(liquidGlass: false); defer { app.close() }
        do {
            let server: SSHTestServer?
            if backend.hasPrefix("ssh") { server = try await SSHTestServer() } else { server = nil }
            defer { server?.stop() }
            // Keep Unix-domain socket paths below sockaddr_un's path limit.
            let backendRoot = server?.root ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("dmp-" + String(UUID().uuidString.prefix(8)))
            try FileManager.default.createDirectory(at: backendRoot, withIntermediateDirectories: true)
            defer { if server == nil { CodexTestSupport.removeFixture(backendRoot) } }
            let socket = backendRoot.appendingPathComponent("herdr.sock").path
            defer { _ = try? HerdrSocket(path: socket).request("server.stop") }
            let origin = try XCTUnwrap(app.workspace.activeTab?.id)
            try await app.wait { runtime.views[origin].map { !TerminalTestSupport.screen(terminal: $0).isEmpty } == true }
            let original = try XCTUnwrap(runtime.views[origin])
            if backend.hasPrefix("ssh") {
                let server = try XCTUnwrap(server)
                TerminalTestSupport.send("ssh " + (server.options + [server.destination]).map(HerdrLaunch.quote).joined(separator: " "), to: original)
                try await TestSupport.eventually(timeout: .seconds(20)) {
                    runtime.ssh.links.values.contains { $0.launch.tabID == origin && $0.shellPID != nil }
                }
            }
            if backend.hasSuffix("tmux") {
                TerminalTestSupport.send("\(HerdrLaunch.quote(TestSupport.tool("tmux"))) -u -L \(app.socket) -CC attach -t edge", to: original)
                try await app.wait { app.workspace.current?.structured == true }
            } else if backend.hasSuffix("herdr") {
                TerminalTestSupport.send("export PATH=\(TestSupport.path):$PATH; export XDG_CONFIG_HOME=" + HerdrLaunch.quote(backendRoot.path)
                    + "; export HERDR_SOCKET_PATH=" + HerdrLaunch.quote(socket) + "; herdr", to: original)
                try await TestSupport.eventually(timeout: .seconds(15)) { app.workspace.current?.shows("herdr") == true }
            }
            let id = try XCTUnwrap(app.workspace.activeSurfaceID)
            try await app.wait { runtime.views[id]?.surface != nil }
            let terminal = try XCTUnwrap(runtime.views[id])
            phaseTimings.begin("agent_readiness")
            let command = CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
            TerminalTestSupport.send(command, to: terminal)
            let session = runtime.chat.session(for: id)
            func wait(_ condition: () -> Bool) async throws {
                try await TestSupport.eventually(timeout: .seconds(20), diagnostic:
                    "\(backend): \(session.modelPicker?.error ?? session.status ?? "no error"), busy=\(session.busy), active=\(session.active), tab=\(session.id)\n\(terminal.agentMenuScreen)", condition)
            }
            func model(_ picker: ChatModelPicker, _ slug: String) throws -> String {
                let names = ["dispatch-fixture": "Dispatch fixture", "gpt-5.6-sol": transportOnly ? "GPT-5.6 Sol" : "GPT-5.6-Sol"]
                return try XCTUnwrap(picker.models.first {
                    AgentModelMenu.containsModel($0.name, slug: slug, name: names[slug])
                }).name
            }
            if backend.hasPrefix("ssh") {
                try await SSHChatTestSupport.trustHooks(state: fixture.state, command: command, session: session, terminal: terminal)
            }
            try await wait { session.active && AgentModelMenu.containsModel(terminal.agentMenuScreen, slug: "dispatch-fixture", name: "Dispatch fixture") }
            runtime.chat.chooseChat(true, session: session)
            session.draft = "initial picker turn"; runtime.chat.submit(session)
            try await wait { runtime.chat.canPickModel(session) && session.model == "dispatch-fixture"
                && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: initial picker turn" } }
            phaseTimings.begin("scenario")
            if transportOnly {
                // Exercise the real transport contract once. Detailed browsing,
                // cancellation, caching and command behavior remain in their
                // original walkthroughs and the plain-local full cases.
                runtime.chat.openModelPicker(session, column: .model)
                let picker = try XCTUnwrap(session.modelPicker)
                try await wait { !picker.loading }
                XCTAssertNil(picker.error)
                XCTAssertEqual(Set(picker.models.map(\.name)), [try model(picker, "dispatch-fixture"), try model(picker, "gpt-5.6-sol")],
                               "Focused transport must read the native fixture catalog")
                picker.selectModel(try model(picker, "gpt-5.6-sol"))
                try await wait { !picker.loading }
                XCTAssertNil(picker.error)
                XCTAssertEqual(Set(picker.efforts.compactMap(\.effort)), ["low", "medium"])
                picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
                try await wait { session.modelPicker == nil || picker.error != nil }
                XCTAssertNil(picker.error)
                XCTAssertEqual(session.model, "gpt-5.6-sol")
                XCTAssertEqual(session.effort, "low")
                let before = try requests(fixture.state).count
                let messages = ["transport first via \(backend)", "transport second via \(backend)\nwith λ"]
                for message in messages { session.draft = message; runtime.chat.queue(session) }
                session.draft = "keep transport draft"
                try await wait {
                    !session.busy && session.queuedMessages.isEmpty && session.submissionID == nil
                        && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: " + messages[1] }
                }
                XCTAssertEqual(session.draft, "keep transport draft")
                XCTAssertNil(session.queuePaused)
                XCTAssertEqual(Array(session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text).suffix(2)), messages)
                let delivered = Array(try requests(fixture.state).dropFirst(before))
                XCTAssertEqual(delivered.count, 2, "Queued input must reach \(backend) exactly once")
                for request in delivered {
                    let body = try XCTUnwrap(request["body"] as? [String: Any])
                    XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
                    XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
                }
                try await wait { runtime.chat.canPickModel(session) && !session.awaitingPromptAck }
                session.drafts.edit(text: "/exit", multiline: false); runtime.chat.submit(session)
                try await wait { !session.active && !session.showChat }
                XCTAssertTrue(session.draft.isEmpty)
                TerminalTestSupport.send("printf 'TRANSPORT_SHELL_%s\\n' READY", to: terminal)
                try await wait { terminal.agentMenuScreen.contains("TRANSPORT_SHELL_READY") }
                passed = testRun?.failureCount == 0
                phaseTimings.begin("teardown")
                await app.close().value
                return
            }
            if revokeQueued {
                let login = try XCTUnwrap(runtime.ssh.links.values.first { $0.launch.tabID == origin })
                let before = try requests(fixture.state).count
                let barrier = ModelFixtureBarrier(state: fixture.state)
                defer { barrier.cancel() }
                let first = afterAccepted ? barrier.prompt + " accepted via \(backend)" : "cancel first queued via \(backend)"
                let messages = [first, "cancel second queued via \(backend)"]
                for message in messages { session.draft = message; runtime.chat.queue(session) }
                XCTAssertNotNil(session.submissionID ?? session.queuedSubmissionID, "First queued delivery must have started")
                XCTAssertEqual(session.queuedMessages.count, 2)
                session.draft = "Keep typing after cancellation"
                if afterAccepted {
                    try await barrier.accepted()
                    try await wait {
                        (try? requests(fixture.state).count) == before + 1 && session.submissionID == nil && session.busy
                            && !session.awaitingPromptAck && session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text == first }
                    }
                    XCTAssertEqual(session.queuedMessages.map(\.text), [messages[1]])
                }
                let turn = session.activeTurnID, transcript = session.transcriptPath
                let feature: SSHIntegrationFeature = backend == "ssh" ? .chat : (backend == "ssh-tmux" ? .tmux : .herdr)
                runtime.ssh.permissions.save(.init(helperEnabled: true,
                    features: Set(SSHIntegrationFeature.allCases).subtracting([feature])), for: login.scope)
                XCTAssertFalse(session.active)
                XCTAssertNil(session.submissionID)
                XCTAssertNotNil(session.queuePaused)
                if afterAccepted {
                    try barrier.release()
                    try await barrier.completed()
                    try await fixture.waitForTurnCompletion(path: XCTUnwrap(transcript), sessionID: XCTUnwrap(session.sessionID), turn: XCTUnwrap(turn))
                }
                // A delivered HTTP response alone says nothing about app actor
                // callbacks. Cancelled submissions and in-flight discovery/reads
                // remain tracked until their main-actor processing has returned.
                try await wait { runtime.chat.operations.pending(for: session.id) == 0 }
                await runtime.chat.operations.wait(for: session.id)
                XCTAssertFalse(session.active)
                XCTAssertNil(session.submissionID)
                XCTAssertEqual(try requests(fixture.state).count, before + (afterAccepted ? 1 : 0), "Revoked queued messages reached the agent via \(backend)")
                XCTAssertEqual(session.queuedMessages.map(\.text), afterAccepted ? [messages[1]] : messages)
                XCTAssertEqual(session.draft, "Keep typing after cancellation")
                XCTAssertFalse(session.drafts.saved.contains { $0.text == first }, "An accepted message must not become an unsent draft")
                if afterAccepted {
                    XCTAssertEqual(session.transcriptRows.filter { $0.item?.kind == .user && $0.item?.text == first }.count, 1,
                        "Accepted input must remain visible exactly once in the read-only transcript")
                }
                XCTAssertNotNil(session.queuePaused)
                passed = testRun?.failureCount == 0
                phaseTimings.begin("teardown")
                await app.close().value
                return
            }
            if commandsOnly {
                try await exerciseCommands(session, terminal: terminal, coordinator: runtime.chat, state: fixture.state, backend: backend)
                passed = testRun?.failureCount == 0
                phaseTimings.begin("teardown")
                await app.close().value
                return
            }
            let oldEffort = session.effort
            let initialRequests = try requests(fixture.state).count
            session.draft = "Draft survives browsing · λ"
            // First open and cancel without choosing; neither a request nor a draft
            // mutation may result from browsing the live agent's menu.
            let coldStarted = ContinuousClock.now
            runtime.chat.openModelPicker(session, column: .model)
            let cancelled = try XCTUnwrap(session.modelPicker)
            try await wait { !cancelled.loading }
            let coldDuration = coldStarted.duration(to: .now)
            XCTAssertNil(cancelled.error)
            XCTAssertFalse(cancelled.models.isEmpty)
            runtime.chat.closeModelPicker(session)
            try await wait { session.modelPicker == nil }
            XCTAssertEqual(session.model, "dispatch-fixture"); XCTAssertEqual(session.effort, oldEffort)
            XCTAssertEqual(session.draft, "Draft survives browsing · λ")
            XCTAssertEqual(try requests(fixture.state).count, initialRequests)
            if backend == "local" {
                app.window.makeKeyAndOrderFront(nil)
                session.focusRequest = UUID()
                try await Task.sleep(for: .milliseconds(350))
                NSApp.sendEvent(TerminalTestSupport.keyEvent(46, "M", in: app.window, modifiers: [.command, .shift]))
            } else { runtime.chat.openModelPicker(session, column: .model) }
            try await wait { session.modelPicker != nil }
            let picker = try XCTUnwrap(session.modelPicker)
            try await wait { !picker.loading }
            XCTAssertNil(picker.error)
            let target = try model(picker, "gpt-5.6-sol")
            if backend == "local" {
                try await Task.sleep(for: .milliseconds(250))
                for _ in picker.models.indices where picker.highlightedModel != target {
                    NSApp.sendEvent(TerminalTestSupport.keyEvent(125, "\u{f701}", in: NSApp.keyWindow))
                }
                XCTAssertEqual(picker.highlightedModel, target)
                NSApp.sendEvent(TerminalTestSupport.keyEvent(36, "\r", in: NSApp.keyWindow))
            } else { picker.selectModel(target) }
            try await wait { !picker.loading }
            XCTAssertNil(picker.error)
            XCTAssertEqual(session.model, "dispatch-fixture", "Browsing a model must not publish unconfirmed settings")
            XCTAssertTrue(picker.efforts.contains { $0.effort == "ultra" })
            if backend == "local" {
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(picker.column, .effort)
                NSApp.sendEvent(TerminalTestSupport.keyEvent(48, "\t", in: NSApp.keyWindow))
                XCTAssertEqual(picker.column, .model)
                NSApp.sendEvent(TerminalTestSupport.keyEvent(48, "\t", in: NSApp.keyWindow))
                XCTAssertEqual(picker.column, .effort)
                var captured = false
                for popup in NSApp.windows where popup.isVisible && popup !== app.window && popup.contentView != nil {
                    let snapshot = try await PresentationTestSupport.capture(popup)
                    if try snapshot.text().contains("EFFORT") {
                        try PresentationTestSupport.save(snapshot.bitmap, named: "model-effort-picker", in: "chat-model-validation")
                        captured = true
                    }
                }
                XCTAssertTrue(captured, "The real two-column popover must be visible")
            }
            picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
            try await wait { session.modelPicker == nil || picker.error != nil }
            XCTAssertNil(picker.error)
            XCTAssertEqual(session.model, "gpt-5.6-sol"); XCTAssertEqual(session.effort, "low")
            XCTAssertEqual(session.draft, "Draft survives browsing · λ")
            XCTAssertTrue(session.showChat)
            XCTAssertEqual(try requests(fixture.state).count, initialRequests)
            var cachedDurations: [Double] = []
            for column in [ChatModelPicker.Column.model, .effort, .model, .effort] {
                let started = ContinuousClock.now
                runtime.chat.openModelPicker(session, column: column)
                let cached = try XCTUnwrap(session.modelPicker)
                let duration = started.duration(to: .now).components
                cachedDurations.append(Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                XCTAssertFalse(cached.loading, "Cached \(column) choices are available synchronously on \(backend)")
                XCTAssertFalse(cached.models.isEmpty); XCTAssertFalse(cached.efforts.isEmpty)
                XCTAssertEqual(cached.models.filter(\.current).map(\.name), [try model(cached, "gpt-5.6-sol")])
                XCTAssertEqual(cached.efforts.filter(\.current).compactMap(\.effort), ["low"])
                try await Task.sleep(for: .milliseconds(80))
                XCTAssertNil(AgentModelMenu(terminal.agentMenuScreen), "Browsing cached choices must leave the live terminal alone")
                runtime.chat.closeModelPicker(session)
                XCTAssertNil(session.modelPicker, "Cached dismissal is immediate")
            }
            let timings: [String: Any] = ["backend": backend,
                "cold_choices_seconds": Double(coldDuration.components.seconds) + Double(coldDuration.components.attoseconds) / 1e18,
                "cached_choices_seconds": cachedDurations,
                "measurement": "Options available to the native picker; excludes popover animation"]
            let timingDirectory = CodexTestSupport.root.appendingPathComponent("build/chat-model-cache-validation")
            try FileManager.default.createDirectory(at: timingDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: timings, options: [.prettyPrinted, .sortedKeys])
                .write(to: timingDirectory.appendingPathComponent("\(backend).json"))
            if backend == "local" {
                // Native /model changes do not always append a turn context. The
                // live picker must supersede an absent or older footer baseline.
                session.model = "older-model"; session.effort = "high"
            }
            runtime.chat.openModelPicker(session, column: .effort, cycle: true)
            let cycle = try XCTUnwrap(session.modelPicker)
            try await wait { session.modelPicker == nil || cycle.error != nil }
            XCTAssertNil(cycle.error)
            XCTAssertEqual(session.effort, "medium")
            session.draft = "model selection reaches the endpoint"; runtime.chat.sendFromComposer(session)
            try await wait {
                !session.busy && !session.awaitingPromptAck && session.activityCheck == nil && session.submissionID == nil
                    && session.draft.isEmpty && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: model selection reaches the endpoint" }
            }
            let body = try XCTUnwrap(try requests(fixture.state).last?["body"] as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "gpt-5.6-sol")
            XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
            XCTAssertEqual(session.model, "gpt-5.6-sol"); XCTAssertEqual(session.effort, "medium")
            if backend == "ssh-tmux" {
                // Reopen without waiting for the outgoing popover animation, and
                // resize the terminal while its native menu is being populated.
                for (index, effort) in ["high", "xhigh", "low", "medium"].enumerated() {
                    runtime.chat.openModelPicker(session, column: .effort)
                    let repeated = try XCTUnwrap(session.modelPicker)
                    app.window.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 1140 : 1120, height: 740))
                    try await wait { !repeated.loading }
                    XCTAssertNil(repeated.error)
                    repeated.selectEffort(try XCTUnwrap(repeated.efforts.first { $0.effort == effort }))
                    try await wait { session.modelPicker == nil || repeated.error != nil }
                    XCTAssertNil(repeated.error)
                    XCTAssertEqual(session.effort, effort)
                }
            }
            if backend == "local" {
                // The advanced list uses a conversation-only confirmation for
                // Ultra. No model request is needed to apply or inspect it.
                runtime.chat.openModelPicker(session, column: .effort)
                let advanced = try XCTUnwrap(session.modelPicker)
                try await wait { !advanced.loading }
                advanced.selectEffort(try XCTUnwrap(advanced.efforts.first { $0.effort == "ultra" }))
                try await wait { session.modelPicker == nil || advanced.error != nil }
                XCTAssertNil(advanced.error)
                XCTAssertEqual(session.effort, "ultra")
                TerminalTestSupport.key(48, "\t", terminal, modifiers: .shift)
                try await wait { terminal.agentMenuScreen.contains("Plan mode") }
                runtime.chat.openModelPicker(session, column: .effort)
                let plan = try XCTUnwrap(session.modelPicker)
                try await wait { !plan.loading }
                plan.selectEffort(try XCTUnwrap(plan.efforts.first { $0.effort == "low" }))
                try await wait { !plan.loading }
                XCTAssertNil(plan.error)
                XCTAssertFalse(plan.scope.isEmpty)
                XCTAssertEqual(session.effort, "ultra", "Scope must be chosen explicitly")
                plan.selectScope(try XCTUnwrap(plan.scope.first))
                try await wait { session.modelPicker == nil || plan.error != nil }
                XCTAssertNil(plan.error)
                XCTAssertEqual(session.effort, "low")
            }
            passed = testRun?.failureCount == 0
            phaseTimings.begin("teardown")
            await app.close().value
        } catch {
            phaseTimings.begin("teardown")
            await app.close().value
            throw error
        }
    }

    private func requests(_ state: URL) throws -> [[String: Any]] {
        try CodexTestSupport.conversationRequests(in: state)
    }
}
