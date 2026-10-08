import XCTest
@testable import DispatchApp

@MainActor
final class ChatModelChoicesCacheTests: XCTestCase {
    func testClaudeCanonicalModelAliasesReuseChoicesAndExpireWithCatalog() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let cache = ChatModelChoicesCache(now: { now }), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-a")
        cache.rememberAlias("provider/model-a", menuName: "model-a")
        let picker = ChatModelPicker(agentID: "claude", model: "provider/model-a", effort: "high", column: .effort, cache: cache,
            screen: { "ordinary terminal" }, send: { _ in XCTFail("Cached browsing must not send input") }, confirmed: { _, _ in XCTFail("Browsing must not change selection") }, finished: { _ in })
        picker.start()
        XCTAssertFalse(picker.loading); XCTAssertEqual(picker.selectedModel, "model-a")
        XCTAssertFalse(picker.efforts.isEmpty); picker.close()
        now += 86_400
        XCTAssertNil(cache.menuName(for: "provider/model-a"))
    }
    func testTTLIsOneDayWithoutSlidingAndClockReversalExpires() {
        let origin = Date(timeIntervalSince1970: 1_000_000)
        var now = origin
        let cache = ChatModelChoicesCache(now: { now }), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-a")
        now = origin.addingTimeInterval(86_399)
        XCTAssertNotNil(cache.catalog); XCTAssertNotNil(cache.efforts(for: "model-a"))
        now = origin.addingTimeInterval(86_400)
        XCTAssertNil(cache.catalog); XCTAssertNil(cache.efforts(for: "model-a"))
        cache.store(models: agent.models, quickModels: [])
        now = now.addingTimeInterval(-1)
        XCTAssertNil(cache.catalog)
    }

    func testEffortTTLIsIndependentOfModelListRefresh() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let cache = ChatModelChoicesCache(now: { now }), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-a")
        now += 43_200
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-b")
        now += 43_200
        XCTAssertNotNil(cache.catalog)
        XCTAssertNil(cache.efforts(for: "model-a"))
        XCTAssertNotNil(cache.efforts(for: "model-b"))
    }

    func testCacheBelongsToChatAndResetsWithAgentIdentity() {
        let session = ChatSession(id: UUID()), other = ChatSession(id: UUID()), agent = MenuFixture()
        let cache = session.modelChoices
        cache.prepare(for: session)
        cache.store(models: agent.models, quickModels: [])
        cache.prepare(for: session)
        XCTAssertNotNil(cache.catalog); XCTAssertNil(other.modelChoices.catalog)
        let changes: [(ChatSession) -> Void] = [
            { $0.sessionID = "another-conversation" },
            { $0.version = "new-agent-version" },
            { $0.agentID = "another-agent" },
            { $0.process = AgentProcess(executable: "/bin/codex", pid: 123, startedSeconds: 456, startedMicroseconds: 0) },
            { $0.process = AgentProcess(executable: "/bin/codex", pid: 123, startedSeconds: 789, startedMicroseconds: 0) }
        ]
        for change in changes {
            cache.store(models: agent.models, quickModels: [])
            change(session); cache.prepare(for: session)
            XCTAssertNil(cache.catalog)
        }
        cache.store(models: agent.models, quickModels: [])
        session.resetConversation()
        XCTAssertFalse(session.modelChoices === cache)
        XCTAssertNil(session.modelChoices.catalog)
    }

    func testCachedModelAndEffortBrowsingSendsNoInputAndUpdatesCheckmarks() {
        let cache = ChatModelChoicesCache(), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-b")
        for column in [ChatModelPicker.Column.model, .effort] {
            // The stored rows mark model-a/high current; the session now uses b/low.
            let picker = agent.picker(cache: cache, model: "model-b", effort: "low", column: column)
            picker.start()
            XCTAssertFalse(picker.loading); XCTAssertNil(picker.error)
            XCTAssertEqual(picker.models.filter(\.current).map(\.name), ["model-b"])
            XCTAssertEqual(picker.efforts.filter(\.current).map(\.effort), ["low"])
            picker.selectModel("model-b")
            XCTAssertFalse(picker.loading)
            picker.close()
        }
        XCTAssertEqual(agent.keys.count, 0)
        XCTAssertEqual(agent.confirmations, 0)
        XCTAssertEqual(agent.finishes, 2)
    }

    func testFreshChoicesAreReusedAndExpiredChoicesReload() async throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let cache = ChatModelChoicesCache(now: { now }), agent = MenuFixture()
        let first = agent.picker(cache: cache)
        first.start()
        try await settled(first)
        XCTAssertNotNil(cache.catalog); XCTAssertNil(cache.efforts(for: "model-a"))
        first.showColumn(.effort)
        try await settled(first)
        XCTAssertNotNil(cache.catalog); XCTAssertNotNil(cache.efforts(for: "model-a"))
        first.close()
        try await TestSupport.eventually { agent.finishes == 1 }
        let keys = agent.keys.count
        let cached = agent.picker(cache: cache)
        cached.start(); cached.close()
        XCTAssertEqual(agent.keys.count, keys)
        now += 86_400
        agent.modelNames.append("model-c")
        let refreshed = agent.picker(cache: cache)
        refreshed.start()
        try await settled(refreshed)
        XCTAssertEqual(refreshed.models.map(\.name), ["model-a", "model-b", "model-c"])
        XCTAssertEqual(agent.keys.filter { $0 == nil }.count, 2)
        refreshed.close()
        try await TestSupport.eventually { agent.finishes == 3 }
    }

    func testCachedEffortSelectionRevalidatesLiveRowsAndConfirmsOnce() async throws {
        let cache = ChatModelChoicesCache(), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-b")
        agent.modelNames = ["model-a", "new-model", "model-b"]
        agent.effortNames = ["High", "Low"]
        let picker = agent.picker(cache: cache, model: "model-b", column: .effort)
        picker.start()
        XCTAssertTrue(agent.keys.isEmpty)
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
        try await settled(picker)
        XCTAssertFalse(picker.presented)
        XCTAssertEqual(agent.currentModel, "model-b"); XCTAssertEqual(agent.currentEffort, "low")
        XCTAssertEqual(agent.keys.filter { $0 == nil }.count, 1)
        XCTAssertEqual(agent.confirmations, 1)
    }

    func testNativeModelIDsSurviveDisplayLabelsAndCachedBrowsing() async throws {
        // Codex 0.157: custom_model_display_name_all_models snapshot and
        // app/event_dispatch.rs PersistModelSelection retain IDs in confirmation.
        for names in [[:], ["model-a": "First model", "model-b": "Second model"]] {
            let cache = ChatModelChoicesCache(), agent = MenuFixture()
            agent.labels = names
            let picker = agent.picker(cache: cache)
            picker.start(); try await settled(picker)
            picker.selectModel(names["model-b"] ?? "model-b"); try await settled(picker)
            picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
            try await settled(picker)
            XCTAssertFalse(picker.presented)
            XCTAssertEqual(agent.confirmedModels, ["model-b"])
            let keys = agent.keys.count
            let cached = agent.picker(cache: cache, model: "model-b", effort: "low", column: .effort)
            cached.start()
            XCTAssertFalse(cached.loading)
            XCTAssertEqual(cached.models.filter(\.current).map(\.name), [names["model-b"] ?? "model-b"])
            XCTAssertEqual(cached.efforts.filter(\.current).compactMap(\.effort), ["low"])
            cached.close(); XCTAssertEqual(agent.keys.count, keys)
            agent.scoped = true
            agent.confirmation = "Model changed to model-b low"
            let plan = agent.picker(cache: cache, model: "model-b", effort: "low", column: .effort)
            plan.start()
            plan.selectEffort(try XCTUnwrap(plan.efforts.first { $0.effort == "high" }))
            try await settled(plan)
            XCTAssertFalse(plan.scope.isEmpty)
            XCTAssertEqual(agent.confirmedModels, ["model-b"])
            plan.selectScope(try XCTUnwrap(plan.scope.first))
            try await settled(plan)
            XCTAssertFalse(plan.presented)
            XCTAssertEqual(agent.confirmedModels, ["model-b", "model-b"])
            XCTAssertEqual(agent.currentEffort, "high")
        }
    }

    func testStaleModelConfirmationCannotEstablishADisplayAlias() async throws {
        let cache = ChatModelChoicesCache(), agent = MenuFixture()
        agent.labels = ["model-a": "First model", "model-b": "Second model"]
        agent.confirmation = "Model changed to model-a low"
        agent.page = agent.confirmation!
        let picker = agent.picker(cache: cache)
        picker.start(); try await settled(picker)
        picker.selectModel("Second model"); try await settled(picker)
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
        try await TestSupport.eventually { !picker.loading }
        XCTAssertNotNil(picker.error)
        XCTAssertTrue(agent.confirmedModels.isEmpty)
        XCTAssertNil(cache.catalog)
        picker.close()
    }

    func testEffortCycleWaitsForLiveChoicesAcrossIntermediateOldConfirmations() async throws {
        for names in [[:], ["model-a": "First model", "model-b": "Second model"]] {
            for cached in [false, true] {
                let agent = MenuFixture(), cache = ChatModelChoicesCache()
                agent.labels = names
                agent.page = "Model changed to model-a high"
                if cached {
                    cache.store(models: agent.models, quickModels: [])
                    cache.store(efforts: agent.efforts, for: names["model-a"] ?? "model-a")
                    cache.rememberAlias("model-a", menuName: names["model-a"] ?? "model-a")
                }
                var frames = 0, confirmations: [AgentModelMenu.Selection] = []
                let picker = ChatModelPicker(model: "model-a", effort: "high", column: .effort, cache: cache,
                    screen: {
                        if agent.page == "effort", frames < 2 {
                            frames += 1
                            return "Model changed to model-a high"
                        }
                        return agent.screen
                    }, send: { agent.send($0) },
                    confirmed: { confirmations.append(.init(model: $0, effort: $1)) }, finished: { _ in })
                picker.start(cycle: true)
                try await settled(picker)
                XCTAssertFalse(picker.presented)
                XCTAssertEqual(confirmations, [.init(model: "model-a", effort: "low")])
                XCTAssertEqual(agent.currentEffort, "low")
            }
        }
    }

    func testNativeModelConfirmationFormats() {
        // Codex 0.157 app/model_defaults.rs and chatwidget/tests/plan_mode.rs;
        // the unsuffixed and conversation-only records remain supported.
        for suffix in ["", " for this conversation", " for this session only", " for Plan mode.", " for Default mode."] {
            for effort in ["", " default", " low", " ultra"] {
                XCTAssertEqual(AgentModelMenu.selection("• Model changed to provider/model" + effort + suffix),
                    .init(model: "provider/model", effort: ["", " default"].contains(effort) ? nil : String(effort.dropFirst())))
            }
        }
        for text in ["", "Model changed to ", "Model changed to model unexpected", "Model changed to model low extra"] {
            XCTAssertNil(AgentModelMenu.selection(text))
        }
    }

    func testRemovedEffortInvalidatesCacheWithoutApplyingAnotherChoice() async throws {
        let cache = ChatModelChoicesCache(), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-a")
        agent.effortNames = ["High"]
        let picker = agent.picker(cache: cache, column: .effort)
        picker.start()
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
        try await TestSupport.eventually { !picker.loading }
        XCTAssertNotNil(picker.error); XCTAssertNil(cache.catalog)
        XCTAssertEqual(agent.confirmations, 0)
        XCTAssertEqual(agent.currentEffort, "high")
        XCTAssertEqual(agent.keys.filter { $0 == nil }.count, 1)
        XCTAssertEqual(agent.keys.filter { $0 == .enter }.count, 1, "Only the model menu was entered")
        picker.close()
        try await TestSupport.eventually { agent.finishes == 1 }
    }

    func testCachedChoicesDoNotBypassIdentityFailureOrRetry() async throws {
        let cache = ChatModelChoicesCache(), agent = MenuFixture()
        cache.store(models: agent.models, quickModels: [])
        cache.store(efforts: agent.efforts, for: "model-a")
        var calls = 0
        let picker = ChatModelPicker(model: "model-a", effort: "high", column: .effort, cache: cache,
            screen: { "ordinary prompt" }, send: { _ in calls += 1; throw HerdrFailure("Agent changed") },
            confirmed: { _, _ in XCTFail("Unverified selection") }, finished: { _ in })
        picker.start(); XCTAssertEqual(calls, 0)
        picker.selectEffort(try XCTUnwrap(picker.efforts.first { $0.effort == "low" }))
        try await TestSupport.eventually { !picker.loading }
        XCTAssertEqual(calls, 1); XCTAssertEqual(picker.error, "Agent changed")
        XCTAssertNil(cache.catalog)
        picker.close()
    }

    func testImmediateCancellationDoesNotStartLoadingAfterClose() async throws {
        let agent = MenuFixture()
        // Keep the transport owner observable after the cancelled task runs.
        let cancelled = agent.picker(cache: ChatModelChoicesCache())
        cancelled.start(); cancelled.close()
        await Task.yield()
        XCTAssertTrue(agent.keys.isEmpty)
        XCTAssertEqual(agent.finishes, 1)
    }

    private func settled(_ picker: ChatModelPicker) async throws {
        try await TestSupport.eventually { !picker.loading }
        XCTAssertNil(picker.error)
    }

    @MainActor private final class MenuFixture {
        var modelNames = ["model-a", "model-b"]
        var labels: [String: String] = [:]
        var confirmation: String?
        var scoped = false, pendingEffort = ""
        var effortNames = ["Low", "High"]
        var currentModel = "model-a", currentEffort = "high"
        var selectedModel = "model-a", page = "", row = 0
        var keys: [AgentMenuKey?] = []
        var confirmations = 0, finishes = 0
        var confirmedModels: [String] = []
        var models: [AgentModelMenu.Choice] {
            modelNames.enumerated().map { .init(number: $0.offset + 1, name: labels[$0.element] ?? $0.element, detail: "Model description",
                current: $0.element == currentModel, isDefault: $0.offset == 0) }
        }
        var efforts: [AgentModelMenu.Choice] {
            effortNames.enumerated().map { .init(number: $0.offset + 1, name: $0.element, detail: "Effort description",
                current: $0.element.lowercased() == currentEffort, isDefault: $0.offset == 0) }
        }
        var screen: String {
            if page == "scope" { return "Apply reasoning change\n› 1. Apply to Plan mode override\nenter select · esc back" }
            guard page == "models" || page == "effort" else { return page }
            let title = page == "models" ? "Select Model and Effort" : "Select Reasoning Level for \(labels[selectedModel] ?? selectedModel)"
            return title + "\n" + (page == "models" ? models : efforts).enumerated().map { index, choice in
                "\(index == row ? "›" : " ") \(choice.number). \(choice.name)\(choice.current ? " (current)" : "")  \(choice.detail)"
            }.joined(separator: "\n") + (labels.isEmpty ? "\nPress enter to confirm or esc to go back" : "\nenter select · esc back")
        }
        func send(_ key: AgentMenuKey?) {
            keys.append(key)
            switch key {
            case .end, .clearLine, .interrupt, .left, .right, .thisSession: XCTFail("Unexpected key from the Codex model picker")
            case nil: page = "models"; row = 0
            case .up, .down:
                let count = page == "models" ? models.count : efforts.count
                row = (row + (key == .down ? 1 : count - 1)) % count
            case .escape: page = page == "effort" ? "models" : ""; row = 0
            case .enter:
                if page == "models" { selectedModel = modelNames[row]; page = "effort"; row = 0 }
                else if page == "effort", scoped { pendingEffort = effortNames[row].lowercased(); page = "scope"; row = 0 }
                else {
                    currentModel = selectedModel; currentEffort = page == "scope" ? pendingEffort : effortNames[row].lowercased()
                    page = (confirmation ?? "Model changed to \(currentModel) \(currentEffort)")
                        + "\n\(labels[currentModel] ?? currentModel) \(currentEffort) · /work"
                }
            }
        }
        func picker(cache: ChatModelChoicesCache, model: String = "model-a", effort: String = "high",
                    column: ChatModelPicker.Column = .model) -> ChatModelPicker {
            ChatModelPicker(model: model, effort: effort, column: column, cache: cache,
                screen: { self.screen }, send: { self.send($0) },
                confirmed: { model, _ in self.confirmations += 1; self.confirmedModels.append(model) }, finished: { _ in self.finishes += 1 })
        }
    }
}
