import AppKit
import SwiftUI
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
            ("gpt-daybreak-blue-latest", "daybreak-blue"),
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
        let session = coordinator.session(for: System.uuid())
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
            { $0.activityCheck = System.uuid() }, { $0.submissionID = System.uuid() }
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

    // MARK: The tracks

    private func row(_ name: String, _ detail: String = "", isDefault: Bool = false) -> AgentModelMenu.Choice {
        .init(number: 1, name: name, detail: detail, current: false, isDefault: isDefault)
    }

    func testLadderIsOnlyOneKnownFamily() throws {
        let claude = try XCTUnwrap(ChatModelLadder(["claude-fable-5-2", "claude-mythos-5-2", "claude-haiku-5-5", "claude-opus-5-5", "claude-sonnet-5-5"].map { row($0) }))
        XCTAssertEqual(claude.rungs.map(\.family), ["haiku", "sonnet", "opus", "fable"])
        XCTAssertEqual(claude.rungs.map(\.label), ["haiku-5.5", "sonnet-5.5", "opus-5.5", "fable-5.2"])
        XCTAssertEqual(claude.security?.label, "mythos-5.2")
        let codex = try XCTUnwrap(ChatModelLadder(["gpt-6-astra", "gpt-6-luna", "daybreak-blue"].map { row($0) }))
        XCTAssertEqual(codex.rungs.map(\.family), ["luna", "astra"], "Rungs the agent does not list are not drawn")
        XCTAssertEqual(codex.security?.family, "daybreak-blue")

        // Claude's own rows: the default names its model only in its description.
        let rows = [row("Default", "Opus 5.5 · Most capable", isDefault: true), row("Fable 5.1", "Fable 5.1 · Best"), row("Sonnet 5.5", "Fastest")]
        let live = try XCTUnwrap(ChatModelLadder(rows))
        XCTAssertEqual(live.rungs.map(\.choice.name), ["Sonnet 5.5", "Default", "Fable 5.1"])
        XCTAssertEqual(live.rungs[1].description, "Most capable")
        XCTAssertEqual(live.rung(reported: "claude-opus-5-5")?.family, "opus")

        let folded = try XCTUnwrap(ChatModelLadder([row("Default", "Opus 5.5 · Most capable", isDefault: true), row("Opus", "Opus 5.5 · Most capable"), row("Sonnet 5.5")]))
        XCTAssertEqual(folded.rungs.map(\.choice.name), ["Sonnet 5.5", "Opus"])
        XCTAssertEqual(folded.rungs[1].rows, ["Default", "Opus"])
        XCTAssertTrue(folded.rungs[1].isDefault)

        for (name, names) in [
            ("unknown model", ["claude-opus-5-5", "claude-sonnet-5-5", "dispatch-fixture"]),
            ("custom provider", ["claude-opus-5-5", "provider/model-a"]),
            ("two families", ["claude-opus-5-5", "gpt-6-astra"]),
            ("two versions", ["claude-opus-5-5", "claude-opus-5-1", "claude-sonnet-5-5"]),
            ("a [1m] variant", ["claude-opus-5-5", "claude-opus-5-5[1m]", "claude-sonnet-5-5"]),
            ("one rung", ["claude-opus-5-5"]),
            ("one rung and security", ["claude-opus-5-5", "claude-mythos-5-2"]),
            ("two security models", ["claude-opus-5-5", "claude-sonnet-5-5", "claude-mythos-5-2", "claude-mythos-5-1"]),
            ("the other family's security model", ["claude-opus-5-5", "claude-sonnet-5-5", "daybreak-blue"]),
            ("nothing", []),
        ] as [(String, [String])] {
            XCTAssertNil(ChatModelLadder(names.map { row($0) }), name)
        }
        XCTAssertNil(ChatModelLadder.provisional(model: "dispatch-fixture"))
        XCTAssertEqual(ChatModelLadder.provisional(model: "claude-opus-5-5")?.rungs.map(\.label), ["opus-5.5"])
        XCTAssertEqual(ChatModelLadder.provisional(model: "claude-mythos-5-2")?.security?.family, "mythos")
        XCTAssertTrue(ChatModelLadder.isSecurity(model: "claude-mythos-5-2"))
        XCTAssertFalse(ChatModelLadder.isSecurity(model: "claude-opus-5-5"))
    }

    /// Codex's list as it arrives: three generations of some models, and Daybreak by its catalog name.
    private static let codexRows = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna",
                                    "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-daybreak-blue-latest"]

    func testCodexLadderKeepsEachModelsNewestGeneration() throws {
        let ladder = try XCTUnwrap(ChatModelLadder(Self.codexRows.map { row($0) }))
        XCTAssertEqual(ladder.rungs.map(\.family), ["luna", "terra", "sol", "astra"])
        XCTAssertEqual(ladder.rungs.map(\.choice.name), ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra"])
        XCTAssertEqual(ladder.security?.choice.name, "gpt-daybreak-blue-latest")
        XCTAssertEqual(ladder.security?.label, "daybreak-blue")
        XCTAssertEqual(ladder.securityCommand?.text, "/daybreak")
        XCTAssertEqual(ladder.rung(reported: "gpt-6.1-sol")?.family, "sol")
        XCTAssertNil(ladder.rung(reported: "gpt-6-sol"), "An older generation is off the ladder")
        XCTAssertTrue(ChatModelLadder.isSecurity(model: "gpt-daybreak-blue-latest"))
        XCTAssertNil(ChatModelLadder(["gpt-6-sol", "gpt-6-sol[x]", "gpt-6-luna"].map { row($0) }), "No newest of two alike")
        XCTAssertNil(ChatModelLadder(Self.codexRows.map { row($0) } + [row("gpt-6-nova")]), "Unknown model")
        XCTAssertNil(try XCTUnwrap(ChatModelLadder(["claude-opus-5-5", "claude-sonnet-5-5"].map { row($0) })).securityCommand)
    }

    func testDaybreakButtonSendsOnlyWhenPressed() async throws {
        let agent = TrackAgent()
        let ids = Self.codexRows
        agent.cache.store(models: ids.map { .init(number: 1, name: $0, detail: "", current: false, isDefault: false) }, quickModels: [])
        for id in ids { agent.cache.store(efforts: TrackAgent.five.map { .init(number: 1, name: $0, detail: "", current: false, isDefault: false, effortValue: $0) }, for: id) }
        let picker = agent.picker(model: "gpt-6.1-terra")
        XCTAssertTrue(picker.showsTracks)
        XCTAssertEqual(stops(picker, .model), ["luna", "terra", "sol", "astra"])

        picker.toggleSecurity()
        XCTAssertEqual(agent.selects, [])
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["gpt-daybreak-blue-latest high"] }
        agent.replies.append(.success(("gpt-daybreak-blue-latest", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertTrue(picker.securityOn)
        XCTAssertEqual(agent.commands, [], "Choosing the model never sends it")

        picker.runSecurityCommand()
        XCTAssertEqual(picker.trackStatus, "Sending /daybreak…")
        XCTAssertFalse(picker.canRunSecurityCommand)
        picker.runSecurityCommand()
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(agent.commands, ["/daybreak"], "One press, one toggle")
        XCTAssertEqual(picker.securityLine, "Sent. See Terminal.")
        XCTAssertEqual(agent.selects.count, 1, "The model stays as it is")

        agent.commandFailure = HerdrFailure("The terminal is busy")
        picker.runSecurityCommand()
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(picker.trackState(.model).caption, .failure("The terminal is busy"))
        picker.close()

        // An older generation is the lists' to show.
        let older = agent.picker(model: "gpt-5.6-sol")
        XCTAssertFalse(older.showsTracks); XCTAssertNil(older.ladder)
        older.close()
    }

    func testEffortOrderAndBringingDown() {
        XCTAssertEqual(ChatModelLadder.union([["max", "low", "future"], ["high", "low", "other", "none"]]),
                       ["none", "low", "high", "max", "future", "other"])
        XCTAssertEqual(ChatModelLadder.broughtDown("high", to: ["low", "high"]), "high")
        XCTAssertEqual(ChatModelLadder.broughtDown("xhigh", to: ["low", "medium", "high"]), "high")
        XCTAssertEqual(ChatModelLadder.broughtDown("medium", to: ["low", "high"]), "low")
        XCTAssertEqual(ChatModelLadder.broughtDown("none", to: ["low", "high"]), "low", "Nothing below it: the lowest")
        XCTAssertNil(ChatModelLadder.broughtDown("high", to: []))
        XCTAssertEqual(ChatModelLadder.levels([.init(number: 1, name: "Default", detail: "", current: true, isDefault: true, effortValue: "default")]), [])
    }

    /// An agent whose replies and level reads the test steps.
    @MainActor private final class TrackAgent {
        typealias Observed = (model: String, effort: String?)
        var selects: [String] = []
        var replies: [Result<Observed, Error>] = []
        var reads: [String] = []
        var catalogHeld = false
        var confirmed: [String] = []
        var finished: [Bool] = []
        var remembered: [String] = []
        var commands: [String] = []
        var commandFailure: Error?
        let cache = ChatModelChoicesCache()
        static let ids = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-mythos-5-2"]
        static let five = ["low", "medium", "high", "xhigh", "max"]
        var levels = ["claude-haiku-5-5": ["low", "medium", "high"], "claude-sonnet-5-5": five, "claude-opus-5-5": five,
                      "claude-fable-5-2": five, "claude-mythos-5-2": five]

        func menu(_ names: [String], current: String?) -> HelperChat.Menu {
            .init(choices: names.map { .init(id: $0, label: $0, detail: "About \($0)") }, current: current)
        }

        func cacheCatalog(levelsFor models: [String] = ids) {
            cache.store(models: Self.ids.map { .init(number: 1, name: $0, detail: "About \($0)", current: false, isDefault: false) }, quickModels: [])
            for model in models {
                cache.store(efforts: (levels[model] ?? []).map { .init(number: 1, name: $0, detail: "Level \($0)", current: false, isDefault: false, effortValue: $0) }, for: model)
            }
        }

        func picker(model: String = "claude-fable-5-2", effort: String? = "high", column: ChatModelPicker.Column = .model, lastRung: String? = nil, tracks: Bool = true) -> ChatModelPicker {
            let picker = ChatModelPicker(model: model, effort: effort, column: column, cache: cache, transport: .init(
                catalog: {
                    while self.catalogHeld { try await Task.sleep(for: .milliseconds(5)) }
                    return self.menu(Self.ids, current: model)
                }, efforts: { name in
                    self.reads.append(name)
                    return self.menu(self.levels[name] ?? [], current: name == model ? effort : nil)
                }, select: { name, level in
                    self.selects.append("\(name) \(level ?? "nil")")
                    while self.replies.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
                    return try self.replies.removeFirst().get()
                }, command: { text in
                    if let failure = self.commandFailure { throw failure }
                    self.commands.append(text)
                }), tracks: tracks, lastRung: lastRung, chatOnly: true, rememberRung: { self.remembered.append($0) },
                confirmed: { self.confirmed.append("\($0) \($1 ?? "nil")") }, finished: { self.finished.append($0) })
            picker.start()
            return picker
        }
    }

    private func stops(_ picker: ChatModelPicker, _ row: ChatModelPicker.TrackRow) -> [String] { picker.trackState(row).stops.map(\.id) }

    func testTrackChangeWaitsForReadbackAndStaysOpen() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        XCTAssertTrue(picker.showsTracks); XCTAssertFalse(picker.loading)
        XCTAssertEqual(stops(picker, .model), ["haiku", "sonnet", "opus", "fable"])
        XCTAssertEqual(stops(picker, .effort), TrackAgent.five)
        XCTAssertEqual(picker.trackState(.model).current, 3)
        XCTAssertEqual(picker.trackState(.model).value, "fable-5.2")

        picker.chooseTrackStop(.model, at: 3)
        XCTAssertNil(picker.trackTarget, "Clicking the chosen stop does nothing")
        picker.chooseTrackStop(.model, at: 2)
        let pending = picker.trackState(.model)
        XCTAssertEqual(pending.current, 2); XCTAssertEqual(pending.ghost, 3); XCTAssertTrue(pending.unconfirmed)
        XCTAssertEqual(pending.value, "opus-5.5"); XCTAssertEqual(picker.trackStatus, "Applies when closed")
        XCTAssertEqual(agent.selects, [], "Nothing is sent while the popover is open")
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-opus-5-5 high"] }
        XCTAssertTrue(agent.confirmed.isEmpty, "Only the agent's state confirms a choice")

        agent.replies.append(.success(("claude-opus-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(agent.confirmed, ["claude-opus-5-5 high"])
        XCTAssertNil(picker.trackTarget); XCTAssertNil(picker.error)
        XCTAssertFalse(picker.trackState(.model).unconfirmed); XCTAssertNil(picker.trackState(.model).ghost)
        XCTAssertTrue(picker.presented, "The popover stays open so the other track can be set")
        XCTAssertEqual(agent.finished, [])
        XCTAssertEqual(picker.trackReturnRung, "opus"); XCTAssertEqual(agent.remembered.last, "opus")
        picker.close()
        XCTAssertEqual(agent.finished, [false]); XCTAssertFalse(picker.presented)
    }

    func testTrackQueueSendsOneAtATimeAndLatestWins() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.chooseTrackStop(.model, at: 2)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 1 }
        picker.chooseTrackStop(.model, at: 1)
        picker.chooseTrackStop(.model, at: 0)
        picker.chooseTrackStop(.effort, at: 0)
        XCTAssertEqual(agent.selects.count, 1, "A change made in flight waits for the readback")
        agent.replies.append(.success(("claude-opus-5-5", "high")))
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 2 }
        XCTAssertEqual(agent.selects.last, "claude-haiku-5-5 low")
        agent.replies.append(.success(("claude-haiku-5-5", "low")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(agent.selects.count, 2)
        XCTAssertEqual(picker.trackConfirmed, .init(rung: "haiku", effort: "low"))
        picker.close()
    }

    func testTrackKeysWaitForTheClose() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.stepTrack(1)
        XCTAssertNil(picker.trackTarget, "No wrapping past the last stop")
        picker.stepTrack(-1); picker.stepTrack(-1); picker.stepTrack(-1)
        XCTAssertTrue(picker.keyboardFocus)
        XCTAssertEqual(picker.trackState(.model).current, 0, "The thumb moves at once")
        XCTAssertEqual(picker.trackState(.effort).current, 2)
        XCTAssertEqual(agent.selects, [])

        picker.escapeTrack()
        XCTAssertNil(picker.trackTarget); XCTAssertTrue(picker.presented, "Esc puts the thumb back")
        XCTAssertEqual(picker.trackState(.model).current, 3)

        picker.moveTrackRow(1)
        XCTAssertEqual(picker.trackRow, .effort)
        picker.moveTrackRow(1)
        XCTAssertEqual(picker.trackRow, .security)
        picker.moveTrackRow(1)
        XCTAssertEqual(picker.trackRow, .security, "↑ ↓ stop at the ends")
        picker.moveTrackRow(1, wrapping: true)
        XCTAssertEqual(picker.trackRow, .model, "Tab goes round")

        picker.stepTrack(-1); picker.stepTrack(-1)
        picker.stepTrack(1)
        XCTAssertEqual(agent.selects, [])
        picker.close()
        try await TestSupport.eventually { agent.selects.count == 1 }
        XCTAssertEqual(agent.selects, ["claude-opus-5-5 high"], "← ← → is one switch")
        agent.replies.append(.success(("claude-opus-5-5", "high")))
        try await TestSupport.eventually { agent.finished == [false] }
    }

    func testTrackFailureReturnsTheThumbAndSaysSo() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.chooseTrackStop(.model, at: 2)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 1 }
        agent.replies.append(.success(("claude-sonnet-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(picker.error, "Couldn't switch to opus-5.5.")
        XCTAssertEqual(picker.trackState(.model).current, 1, "The thumb goes where the readback says")
        XCTAssertEqual(picker.trackState(.model).caption, .failure("Couldn't switch to opus-5.5."))
        XCTAssertEqual(picker.trackState(.effort).caption, .ends("quicker", "more thorough"))
        XCTAssertEqual(agent.confirmed, ["claude-sonnet-5-5 high"])
        XCTAssertTrue(picker.presented)

        picker.chooseTrackStop(.effort, at: 0)
        XCTAssertNil(picker.error, "A new change clears it")
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 2 }
        agent.replies.append(.failure(HerdrFailure("The agent is gone")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(picker.trackState(.effort).caption, .failure("The agent is gone"))
        XCTAssertEqual(picker.trackState(.effort).current, 2)
        XCTAssertNil(picker.trackTarget)
        XCTAssertEqual(agent.confirmed.count, 1)
        picker.close()
    }

    func testTrackBringsTheEffortDownAndHatchesMissingLevels() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker(effort: "xhigh")
        picker.chooseTrackStop(.model, at: 0)
        let effort = picker.trackState(.effort)
        XCTAssertEqual(effort.value, "high"); XCTAssertEqual(effort.note, "was xhigh"); XCTAssertEqual(effort.ghost, 3)
        XCTAssertEqual(effort.stops.map(\.available), [true, true, true, false, false])
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-haiku-5-5 high"] }
        agent.replies.append(.success(("claude-haiku-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(picker.trackState(.effort).note, "was xhigh", "Until the popover closes")

        let hatched = picker.trackState(.effort, hover: 3)
        XCTAssertEqual(hatched.caption, .detail("haiku-5.5 stops at high."))
        XCTAssertEqual(hatched.value, "high", "Pointing at a hatched stop changes nothing")
        picker.chooseTrackStop(.effort, at: 4)
        XCTAssertNil(picker.trackTarget, "A hatched stop is inert")
        picker.trackRow = .effort
        picker.stepTrack(1)
        XCTAssertNil(picker.trackTarget, "Arrows stop at the last level the model has")
        let pointing = picker.trackState(.effort, hover: 0)
        XCTAssertEqual(pointing.value, "low"); XCTAssertTrue(pointing.valueMuted); XCTAssertEqual(pointing.caption, .detail("Level low"))
        picker.close()
    }

    func testTrackKeysDoNotForgetTheEffortOnTheWayPastAWeakerModel() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker(model: "claude-sonnet-5-5", effort: "xhigh")
        picker.stepTrack(-1)
        XCTAssertEqual(picker.trackState(.effort).value, "high")
        picker.stepTrack(1); picker.stepTrack(1)
        XCTAssertEqual(picker.trackState(.effort).value, "xhigh")
        XCTAssertNil(picker.trackState(.effort).note)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-opus-5-5 xhigh"] }
        agent.replies.append(.success(("claude-opus-5-5", "xhigh")))
        try await TestSupport.eventually { !picker.trackSending }
        picker.close()
    }

    func testTrackReadsUncachedLevelsBeforeSending() async throws {
        let agent = TrackAgent(); agent.cacheCatalog(levelsFor: ["claude-fable-5-2"])
        let picker = agent.picker(effort: "xhigh")
        XCTAssertEqual(agent.reads, [], "The current model's levels are cached")
        picker.chooseTrackStop(.model, at: 0)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 1 }
        XCTAssertEqual(agent.reads, ["claude-haiku-5-5"])
        XCTAssertEqual(agent.selects, ["claude-haiku-5-5 high"])
        agent.replies.append(.success(("claude-haiku-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertEqual(picker.trackState(.effort).note, "was xhigh")
        picker.close()
    }

    func testTrackModelWithoutLevelsSendsNoEffort() async throws {
        let agent = TrackAgent(); agent.levels["claude-haiku-5-5"] = ["default"]; agent.cacheCatalog()
        let picker = agent.picker()
        picker.chooseTrackStop(.model, at: 0)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-haiku-5-5 nil"] }
        agent.replies.append(.success(("claude-haiku-5-5", nil)))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertTrue(picker.trackState(.effort).disabled)
        picker.close()
    }

    func testSecurityModelIsASwitchOffTheLadder() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker(model: "claude-opus-5-5")
        XCTAssertEqual(stops(picker, .model), ["haiku", "sonnet", "opus", "fable"], "The security model is no stop")
        XCTAssertEqual(picker.securityLine, "For security work. This chat only.")
        picker.toggleSecurity()
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-mythos-5-2 high"] }
        agent.replies.append(.success(("claude-mythos-5-2", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertTrue(picker.securityOn)
        let track = picker.trackState(.model)
        XCTAssertNil(track.current); XCTAssertTrue(track.dimmed); XCTAssertTrue(track.shield)
        XCTAssertEqual(track.ghost, 2); XCTAssertEqual(track.value, "mythos-5.2")
        XCTAssertEqual(track.caption, .detail("Off the ladder. A stop here turns it off."))
        XCTAssertEqual(picker.securityLine, "Off returns to opus-5.5.")
        XCTAssertFalse(picker.trackState(.effort).dimmed, "Effort stays live")

        picker.stepTrack(-1)
        XCTAssertNil(picker.trackTarget, "Arrow keys never reach it")
        picker.pressTrack(.model, at: 1)
        XCTAssertNil(picker.trackHeld, "Dragging never reaches it")

        picker.toggleSecurity()
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.last == "claude-opus-5-5 high" }
        agent.replies.append(.success(("claude-opus-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertFalse(picker.securityOn)

        picker.toggleSecurity()
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 3 }
        agent.replies.append(.success(("claude-mythos-5-2", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        picker.releaseTrack(.model, at: 1, moved: false)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 4 }
        XCTAssertEqual(agent.selects.last, "claude-sonnet-5-5 high", "A stop on the dimmed track turns it off in one request")
        agent.replies.append(.success(("claude-sonnet-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        XCTAssertFalse(picker.securityOn)
        picker.close()
    }

    func testSecurityModelReturnsToTheLastRungOrTheDefault() {
        let agent = TrackAgent(); agent.cacheCatalog()
        let known = agent.picker(model: "claude-mythos-5-2", lastRung: "sonnet")
        XCTAssertTrue(known.securityOn); XCTAssertEqual(known.trackReturnRung, "sonnet")
        known.close()
        let strongest = agent.picker(model: "claude-mythos-5-2")
        XCTAssertEqual(strongest.trackReturnRung, "fable", "No default among the rungs: the strongest")
        strongest.close()
        agent.cache.store(models: TrackAgent.ids.map { .init(number: 1, name: $0, detail: "", current: false, isDefault: $0 == "claude-sonnet-5-5") }, quickModels: [])
        let fallback = agent.picker(model: "claude-mythos-5-2")
        XCTAssertEqual(fallback.trackReturnRung, "sonnet", "The agent's default, when it is a rung")
        fallback.close()
    }

    func testTrackDragAppliesOnlyOnRelease() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.pressTrack(.model, at: 3)
        picker.dragTrack(to: 1.25)
        XCTAssertEqual(picker.trackState(.model).value, "sonnet-5.5", "The header names the nearest stop")
        XCTAssertEqual(picker.trackState(.model).caption, .detail("About claude-sonnet-5-5"))
        XCTAssertNil(picker.trackTarget); XCTAssertEqual(agent.selects, [], "Never sent mid-drag")

        picker.escapeTrack()
        XCTAssertNil(picker.trackHeld); XCTAssertTrue(picker.presented)
        picker.releaseTrack(.model, at: 1.25, moved: true)
        XCTAssertNil(picker.trackTarget, "Esc while held puts the thumb back; its release does nothing")

        picker.pressTrack(.model, at: 3)
        picker.dragTrack(to: 1.25)
        picker.releaseTrack(.model, at: 1.25, moved: true)
        XCTAssertNil(picker.trackHeld)
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-sonnet-5-5 high"] }
        agent.replies.append(.success(("claude-sonnet-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }

        // Haiku's missing levels: a drag ends on the nearest level it has.
        agent.levels["claude-sonnet-5-5"] = ["low", "medium"]
        picker.close()
        let limited = TrackAgent(); limited.cacheCatalog()
        let haiku = limited.picker(model: "claude-haiku-5-5")
        haiku.pressTrack(.effort, at: 2)
        haiku.dragTrack(to: 4)
        XCTAssertEqual(haiku.trackState(.effort).value, "high")
        haiku.releaseTrack(.effort, at: 4, moved: true)
        XCTAssertNil(haiku.trackTarget, "Its nearest level is the chosen one")
        haiku.close()
    }

    func testClosingSendsAWaitingChangeAndFinishesWithItsReadback() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.stepTrack(-1)
        XCTAssertEqual(agent.selects, [])
        picker.close()
        XCTAssertFalse(picker.presented)
        XCTAssertEqual(agent.finished, [], "The picker finishes with the readback")
        try await TestSupport.eventually { agent.selects == ["claude-opus-5-5 high"] }
        agent.replies.append(.success(("claude-opus-5-5", "high")))
        try await TestSupport.eventually { agent.finished == [false] }
        XCTAssertEqual(agent.confirmed, ["claude-opus-5-5 high"])

        let failing = TrackAgent(); failing.cacheCatalog()
        let declined = failing.picker()
        declined.chooseTrackStop(.model, at: 0)
        declined.close()
        try await TestSupport.eventually { failing.selects.count == 1 }
        failing.replies.append(.failure(HerdrFailure("No")))
        try await TestSupport.eventually { failing.finished == [true] }
    }

    func testAQuestionAfterClosingIsTheChatsAndANoIsNoFailure() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.chooseTrackStop(.model, at: 2)
        picker.close()
        try await TestSupport.eventually { agent.selects.count == 1 }
        let question = HelperChat.Interaction(id: "menu:session", key: nil, approval: false, blocking: true,
            questions: [.init(id: "confirmation", header: "Switch model?", text: "Your next response will use more tokens", secret: false,
                options: [.init(id: "1", label: "Yes", detail: nil), .init(id: "2", label: "No", detail: nil)],
                multiple: false, custom: false, blocks: nil)], turn: nil, record: nil)
        XCTAssertFalse(picker.ask(question), "The popover is gone: the chat shows the question")
        agent.replies.append(.success(("claude-fable-5-2", "high")))
        try await TestSupport.eventually { agent.finished == [false] }
        XCTAssertNil(picker.error)
    }

    func testTracksStayOffUnlessTheSettingIsOn() {
        XCTAssertFalse(ChatModelPicker.tracksEnabled, "Experimental: off by default")
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker(tracks: false)
        XCTAssertFalse(picker.showsTracks); XCTAssertNil(picker.ladder)
        XCTAssertEqual(picker.models.map(\.name), TrackAgent.ids, "A list the tracks could draw is still the lists")
        picker.close()
    }

    /// A catalog of `count` models the lists draw, every one with its levels known.
    private func longList(_ agent: TrackAgent, count: Int) -> [String] {
        let names = (1...count).map { "provider/model-\($0)" }
        agent.cache.store(models: names.map { .init(number: 1, name: $0, detail: $0.hasSuffix("-\(count)") ? "Fast one" : "", current: false, isDefault: false) }, quickModels: [])
        for name in names { agent.cache.store(efforts: [.init(number: 1, name: "low", detail: "", current: false, isDefault: false, effortValue: "low")], for: name) }
        return names
    }

    func testALongModelListIsSearchable() {
        let agent = TrackAgent(), names = longList(agent, count: 16)
        let picker = agent.picker(model: names[0], effort: "low", tracks: false)
        XCTAssertTrue(picker.showsModelSearch)
        XCTAssertEqual(picker.shownModels.count, 16)
        picker.modelQuery = "model-1 PROVIDER"
        XCTAssertEqual(picker.shownModels.map(\.name), [names[0]] + names[9...], "Every word, in any order, any case")
        XCTAssertEqual(picker.highlightedModel, names[0], "A highlight the search keeps stays")

        picker.modelQuery = "fast"
        XCTAssertEqual(picker.shownModels.map(\.name), [names[15]], "The description counts")
        XCTAssertEqual(picker.highlightedModel, names[15], "A highlight the search hides moves to the first left")
        picker.move(1)
        XCTAssertEqual(picker.highlightedModel, names[15], "Keys stay inside what the search left")
        picker.chooseHighlighted()
        XCTAssertEqual(picker.selectedModel, names[15]); XCTAssertEqual(picker.column, .effort)

        picker.modelQuery = "nothing like this"
        XCTAssertEqual(picker.column, .model, "Typing is about models")
        XCTAssertEqual(picker.shownModels, [])
        picker.chooseHighlighted()
        XCTAssertEqual(picker.selectedModel, names[15], "Return chooses nothing the search hid")
        picker.close()

        let short = TrackAgent(), fifteen = longList(short, count: 15)
        let few = short.picker(model: fifteen[0], effort: "low", tracks: false)
        XCTAssertFalse(few.showsModelSearch)
        few.modelQuery = "fast"
        XCTAssertEqual(few.shownModels.count, 15)
        few.close()
    }

    func testTheSearchFieldTakesTypingAndTheListsKeys() async throws {
        let agent = TrackAgent(), names = longList(agent, count: 20)
        let picker = agent.picker(model: names[0], effort: "low", tracks: false)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatModelPickerView(picker: picker, close: { picker.close() }, terminal: {}))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        func key(_ code: UInt16, _ text: String) { NSApp.sendEvent(TerminalTestSupport.keyEvent(code, text, in: window)) }
        let rest = try await PresentationTestSupport.capture(window, named: "lists-search", in: "chat-model-validation").text().lowercased()
        XCTAssertTrue(rest.contains("search models"), rest)

        for (code, text) in [(UInt16(46), "m"), (31, "o"), (2, "d"), (14, "e"), (37, "l"), (27, "-"), (19, "2")] { key(code, text) }
        try await TestSupport.eventually { picker.modelQuery == "model-2" }
        XCTAssertEqual(picker.shownModels.map(\.name), [names[1], names[19]])
        key(125, "\u{f701}")
        XCTAssertEqual(picker.highlightedModel, names[19], "↓ moves the list from the field")
        _ = try await PresentationTestSupport.capture(window, named: "lists-search-typed", in: "chat-model-validation")
        key(36, "\r")
        try await TestSupport.eventually { picker.selectedModel == names[19] }
        XCTAssertEqual(picker.column, .effort, "Return chooses from the field")

        key(53, "\u{1b}")
        try await TestSupport.eventually { picker.modelQuery.isEmpty }
        XCTAssertTrue(picker.presented, "Esc clears the search first")
        picker.close()
    }

    func testTracksFollowChangesMadeElsewhere() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker()
        picker.followSession(model: "claude-sonnet-5-5", effort: "low")
        XCTAssertEqual(picker.trackState(.model).current, 1)
        XCTAssertEqual(picker.trackState(.effort).value, "low")
        XCTAssertEqual(agent.selects, [])
        picker.followSession(model: "dispatch-fixture", effort: "max")
        XCTAssertEqual(picker.trackState(.model).current, 1, "A model off the ladder moves nothing")
        picker.chooseTrackStop(.model, at: 2)
        picker.followSession(model: "claude-haiku-5-5", effort: "low")
        XCTAssertEqual(picker.trackState(.model).current, 2, "A change on its way is not overtaken")
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.count == 1 }
        agent.replies.append(.success(("claude-opus-5-5", "low")))
        try await TestSupport.eventually { !picker.trackSending }
        picker.close()
    }

    func testTracksBeforeTheChoicesAreKnownThenTheLists() async throws {
        let agent = TrackAgent(); agent.catalogHeld = true
        let picker = agent.picker()
        XCTAssertTrue(picker.showsTracks, "A current model of a known family opens at the tracks")
        XCTAssertFalse(picker.ladderKnown); XCTAssertEqual(stops(picker, .model), ["fable"]); XCTAssertEqual(stops(picker, .effort), ["high"])
        XCTAssertEqual(picker.trackStatus, "Reading agent choices…")
        picker.chooseTrackStop(.effort, at: 0); picker.stepTrack(-1); picker.toggleSecurity()
        XCTAssertNil(picker.trackTarget, "Inert until the agent's list is known")
        agent.catalogHeld = false
        try await TestSupport.eventually { !picker.loading }
        XCTAssertTrue(picker.ladderKnown)
        XCTAssertEqual(stops(picker, .model), ["haiku", "sonnet", "opus", "fable"])
        XCTAssertEqual(agent.reads, ["claude-fable-5-2"])
        XCTAssertEqual(stops(picker, .effort), TrackAgent.five)
        picker.close()

        // Any other list keeps today's lists, and a choice there closes the popover.
        let other = TrackAgent()
        other.cache.store(models: ["claude-opus-5-5", "dispatch-fixture"].map { .init(number: 1, name: $0, detail: "", current: false, isDefault: false) }, quickModels: [])
        other.cache.store(efforts: [.init(number: 1, name: "low", detail: "", current: false, isDefault: false, effortValue: "low")], for: "claude-opus-5-5")
        let lists = other.picker(model: "claude-opus-5-5", effort: "low")
        XCTAssertFalse(lists.showsTracks); XCTAssertNil(lists.ladder); XCTAssertFalse(lists.efforts.isEmpty)
        lists.selectEffort(try XCTUnwrap(lists.efforts.first))
        try await TestSupport.eventually { other.selects.count == 1 }
        other.replies.append(.success(("claude-opus-5-5", "low")))
        try await TestSupport.eventually { !lists.presented }
        XCTAssertEqual(other.finished, [false])
    }

    func testTracksDrawAndTakeKeysAndThePointer() async throws {
        let agent = TrackAgent(); agent.cacheCatalog()
        let picker = agent.picker(effort: "xhigh")
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatModelPickerView(picker: picker, close: { picker.close() }, terminal: {}))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        func shot(_ name: String) async throws -> String {
            try await Task.sleep(for: .milliseconds(500))
            return try await PresentationTestSupport.capture(window, named: "tracks-" + name, in: "chat-model-validation").text().lowercased()
        }
        func key(_ code: UInt16, _ text: String) { NSApp.sendEvent(TerminalTestSupport.keyEvent(code, text, in: window)) }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        let rest = try await shot("rest")
        for word in ["model", "effort", "haiku", "sonnet", "opus", "fable", "fable-5.2", "mythos-5.2", "faster", "smarter", "done"] {
            XCTAssertTrue(rest.contains(word), "\(word) in: \(rest)")
        }

        // Keys reach the popover: down to EFFORT, up back, a step, Esc puts it back and leaves it open.
        key(125, "\u{f701}")
        XCTAssertEqual(picker.trackRow, .effort)
        key(126, "\u{f700}")
        XCTAssertEqual(picker.trackRow, .model)
        key(123, "\u{f702}")
        XCTAssertEqual(picker.trackTarget?.rung, "opus")
        _ = try await shot("waiting")
        key(53, "\u{1b}")
        XCTAssertNil(picker.trackTarget); XCTAssertTrue(picker.presented)

        // The pointer: a click on a stop chooses it; a drag follows and chooses on release.
        let track = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("chat-model-track", in: window).first)
        func stop(_ place: CGFloat) -> NSPoint { NSPoint(x: track.minX + (place + 0.5) * track.width / 4, y: track.midY) }
        try mouse(.leftMouseDown, stop(0))
        try mouse(.leftMouseUp, stop(0))
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects == ["claude-haiku-5-5 high"] }
        let hatched = try await shot("brought-down")
        XCTAssertTrue(hatched.contains("was xhigh"), hatched)
        agent.replies.append(.success(("claude-haiku-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }

        try mouse(.leftMouseDown, stop(0))
        XCTAssertNotNil(picker.trackHeld)
        try mouse(.leftMouseDragged, stop(1.1))
        XCTAssertEqual(agent.selects.count, 1, "Never sent mid-drag")
        _ = try await shot("held")
        try mouse(.leftMouseDragged, stop(2.2))
        try mouse(.leftMouseUp, stop(2.2))
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.last == "claude-opus-5-5 high" }
        agent.replies.append(.success(("claude-opus-5-5", "high")))
        try await TestSupport.eventually { !picker.trackSending }

        // The switch and a failure, then Space on the security row.
        key(48, "\t"); key(48, "\t")
        XCTAssertEqual(picker.trackRow, .security)
        key(49, " ")
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.last == "claude-mythos-5-2 high" }
        agent.replies.append(.success(("claude-mythos-5-2", "high")))
        try await TestSupport.eventually { !picker.trackSending }
        let security = try await shot("security")
        XCTAssertTrue(security.contains("off the ladder"), security)
        key(49, " ")
        picker.sendWaitingChange()
        try await TestSupport.eventually { agent.selects.last == "claude-opus-5-5 high" }
        agent.replies.append(.failure(HerdrFailure("Couldn't switch to opus-5.5.")))
        try await TestSupport.eventually { !picker.trackSending }
        let failed = try await shot("failed")
        XCTAssertTrue(failed.contains("open in terminal"), failed)

        key(53, "\u{1b}")
        XCTAssertFalse(picker.presented, "Esc with nothing waiting closes")
    }

    func testDaybreakButtonDrawsAndTakesAClick() async throws {
        let agent = TrackAgent()
        let ids = Self.codexRows
        agent.cache.store(models: ids.map { .init(number: 1, name: $0, detail: "", current: false, isDefault: false) }, quickModels: [])
        for id in ids { agent.cache.store(efforts: TrackAgent.five.map { .init(number: 1, name: $0, detail: "", current: false, isDefault: false, effortValue: $0) }, for: id) }
        let picker = agent.picker(model: "gpt-6.1-terra")
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close(); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatModelPickerView(picker: picker, close: { picker.close() }, terminal: {}))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(900))
        let text = try await PresentationTestSupport.capture(window, named: "tracks-codex", in: "chat-model-validation").text().lowercased()
        for word in ["luna", "terra", "sol", "astra", "terra-6.1", "daybreak-blue", "daybreak"] { XCTAssertTrue(text.contains(word), "\(word) in: \(text)") }

        let frame = try XCTUnwrap(PresentationTestSupport.accessibilityFrames("chat-security-command", in: window).first)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY), modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
        try await TestSupport.eventually { agent.commands == ["/daybreak"] }
        XCTAssertEqual(agent.selects, [])
        try await Task.sleep(for: .milliseconds(500))
        _ = try await PresentationTestSupport.capture(window, named: "tracks-codex-sent", in: "chat-model-validation")
        picker.close()
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
            if transportOnly { try System.write(CodexTestSupport.transportModelCatalog(), to: catalog) }
            let config = fixture.state.appendingPathComponent("codex-home/config.toml")
            let contents = try String(decoding: try System.read(config), as: UTF8.self)
            try System.write(Data(("model_catalog_json = \"\(catalog.path)\"\n" + contents).utf8), to: config)
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
            let backendRoot = server?.root ?? System.temporary
                .appendingPathComponent("dmp-" + String(System.uuid().uuidString.prefix(8)))
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
            // Over SSH to this Mac the login shell's TMPDIR is the account's /var/folders path: codex lists it in its
            // instructions, which the compaction record's id hashes (a scrub cannot follow a hash). The fixture's own.
            let command = (commandsOnly && backend.hasPrefix("ssh") ? "TMPDIR=" + HerdrLaunch.quote(fixture.state.path) + " " : "")
                + CodexTestSupport.command(state: fixture.state, binary: fixture.binary)
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
            // Its chat history (the binding) arrived too: a prompt sent before it names no conversation, by timing.
            try await wait { session.active && session.binding != nil && !session.loadingHistory
                && AgentModelMenu.containsModel(terminal.agentMenuScreen, slug: "dispatch-fixture", name: "Dispatch fixture") }
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
                session.focusRequest = System.uuid()
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
                if !runtime.helpers.values.contains(where: { $0.holding(id) }) { XCTAssertNil(AgentModelMenu(terminal.agentMenuScreen), "Browsing cached choices must leave the live terminal alone") } // A held terminal (terminals.follow) still shows the last walk.
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
