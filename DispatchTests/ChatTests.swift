import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class ChatTests: XCTestCase {
    func testDisabledOptionalIntegrationReportsUnsentDraftBeforeInstallationFinishes() {
        for optional in [false, true] {
            let chat = ChatCoordinator(enabled: true)
            let session = chat.session(for: UUID())
            defer { chat.close(session.id) }
            session.agentID = "fixture"
            session.draft = "Preserve this draft λ"
            chat.helperInstalls["fixture"] = .init(edits: [], restart: false, installed: true,
                optional: optional, reload: nil, trust: nil, status: "ready")
            chat.disabledIntegrations.insert("fixture")
            XCTAssertEqual(chat.hookStatus("fixture"), .off)
            chat.submitHelper(session, queued: nil, immediately: false)
            XCTAssertEqual(session.draft, "Preserve this draft λ")
            XCTAssertEqual(session.submissionFailure != nil, optional)
            XCTAssertNil(session.submissionID)
        }
    }

    func testInstallationFailuresRetireWithTheirOwner() {
        let chat = ChatCoordinator(enabled: false)
        let endpoint = HelperWorkspace.Endpoint.remote(SSHConnectionID())
        let local = ChatCoordinator.InstallationTarget(key: "codex", endpoint: .local, terminal: nil)
        let account = ChatCoordinator.InstallationTarget(key: "codex", endpoint: endpoint, terminal: nil)
        let terminal = ChatCoordinator.InstallationTarget(key: "codex", endpoint: endpoint, terminal: 7)
        chat.installationFailures = [local: "Local", account: "Account", terminal: "Terminal"]
        chat.helperExited(endpoint, terminal: 7)
        XCTAssertEqual(chat.installationFailures, [local: "Local", account: "Account"])
        XCTAssertEqual(chat.error, "Account\nLocal")
        chat.helperExited(endpoint)
        XCTAssertEqual(chat.installationFailures, [local: "Local"])
        XCTAssertEqual(chat.error, "Local")
        chat.helperExited(.local)
        XCTAssertEqual(chat.installationFailures, [:])
        XCTAssertNil(chat.error)
    }

    func testTranscriptReplacementPreservesLiveApproval() {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        var decisions: [PendingApproval.Decision] = []
        let approval = PendingApproval(key: "permission", operation: "Run command") { decisions.append($0.decision!) }
        session.approvals = [approval]
        chat.receiveHelper(.replacement(.init(records: [], earlier: nil, state: nil, snapshot: nil)), session: session)
        XCTAssertEqual(session.approvals.map(\.id), [approval.id])
        XCTAssertTrue(approval.pending)
        XCTAssertEqual(decisions, [])
    }

    func testPiPollCannotReplacePickerConfirmationWithOlderConfiguration() async throws {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.agentID = "pi"
        session.model = "custom/fixture"; session.effort = "medium"
        let revision = session.configurationRevision
        var release: CheckedContinuation<Void, Never>?
        let poll = Task { @MainActor in
            await withCheckedContinuation { release = $0 }
            chat.apply([
                ChatRecord(key: "old-configuration", turnID: "turn", date: .now,
                           action: .configuration(model: "custom/fixture", effort: "medium")),
                ChatRecord(key: "reply", turnID: "turn", date: .now,
                           action: .item(ChatItem(id: "reply", kind: .assistant, text: "Keep this reply")))
            ], to: session, earlier: false, historical: false, configurationRevision: revision)
            session.applyConfiguration(model: "custom/fixture", effort: "medium", revision: revision)
        }
        try await TestSupport.eventually { release != nil }
        session.confirmConfiguration(model: "custom/fixture", effort: "high")
        release?.resume()
        await poll.value
        XCTAssertEqual(session.effort, "high")
        XCTAssertEqual(session.turns.flatMap(\.items).map(\.text), ["Keep this reply"])
        session.applyConfiguration(model: "custom/native", effort: "low", revision: session.configurationRevision)
        XCTAssertEqual(session.model, "custom/native"); XCTAssertEqual(session.effort, "low")
        let previous = session.configurationRevision
        session.resetConversation()
        let resetModel = session.model
        session.applyConfiguration(model: "custom/native", effort: "high", revision: previous)
        XCTAssertEqual(session.model, resetModel); XCTAssertNil(session.effort)
    }

    func testBranchSwitchClearsAcceptedBubbleWithoutRestoringItAsDraft() {
        let session = ChatSession(id: UUID(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        session.draft = "Draft for later"
        session.showOptimisticPrompt("Accepted on old branch")
        session.optimisticPromptDelivered = true
        session.failOptimisticPrompt(restoreDraft: true)
        session.clearBranchHistory()
        XCTAssertNil(session.optimisticPrompt)
        XCTAssertNil(session.optimisticPromptBoundary)
        XCTAssertFalse(session.optimisticPromptDelivered)
        XCTAssertEqual(session.draft, "Draft for later")
        XCTAssertTrue(session.drafts.saved.isEmpty)
        XCTAssertTrue(session.transcriptRows.isEmpty)
    }

    func testAcceptedOptimisticPromptDoesNotRestoreButNextUnsentPromptDoes() {
        let session = ChatSession(id: UUID(), draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        session.showOptimisticPrompt("Accepted message")
        session.optimisticPromptDelivered = true
        session.failOptimisticPrompt(restoreDraft: true)
        XCTAssertTrue(session.draft.isEmpty)
        XCTAssertTrue(session.drafts.saved.isEmpty)
        XCTAssertEqual(session.optimisticPrompt?.text, "Accepted message", "Accepted input must stay visible until the transcript confirms it")
        let rowID = session.optimisticPrompt?.id
        let confirmed = session.reconcilePrompt(ChatItem(id: "confirmed", kind: .user, text: "Accepted message"))
        XCTAssertEqual(confirmed.rowID, rowID)
        XCTAssertNil(session.optimisticPrompt)
        session.showOptimisticPrompt("Unsent next message")
        session.failOptimisticPrompt(restoreDraft: true)
        XCTAssertEqual(session.draft, "Unsent next message")
    }

    func testChatFontMigrationAndPersistence() throws {
        let defaults = Preferences()
        XCTAssertEqual(defaults.fontFamily, "Source Code Pro")
        XCTAssertEqual(defaults.chatFont, .system)
        XCTAssertEqual(defaults.fontSize, 12.5)
        let typography = ChatTypography(preferences: defaults)
        XCTAssertEqual(typography.codeFontName, "SourceCodePro-Regular")
        XCTAssertEqual(typography.sizeScale, 1)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)), defaults)
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"fontFamily":"0xProto"}"#.utf8))
        XCTAssertEqual(old.chatFont, .system)
        let removed = try JSONDecoder().decode(Preferences.self, from: Data(#"{"chatFont":"Removed Font","fontFamily":"0xProto"}"#.utf8))
        XCTAssertEqual(removed.chatFont, .system)
        XCTAssertEqual(removed.fontFamily, "0xProto")
        for choice in ChatFont.allCases {
            var preferences = old
            preferences.chatFont = choice
            let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(decoded, preferences)
        }
    }

    func testChatSwitchInstallsAgentHooksAndReportsRestartForOlderAgents() async throws {
        let restore = TestSupport.preserveRuntime()
        defer { restore() }
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        TerminalRuntime.shared.chat = chat
        let app = try TmuxWalkthrough()
        defer { app.close(); chat.setEnabled(false) }
        try await TestSupport.integrations(["codex", "claude", "pi"], enabled: false, chat: chat)
        XCTAssertEqual(chat.hookStatus("codex"), .off)
        XCTAssertEqual(chat.hookStatus("pi"), .off)
        // Disabling leaves installed hooks in the file, so an earlier case's install would make
        // this one a no-op (ready). Start from a Codex home without them.
        try? FileManager.default.removeItem(at: Home.url.appendingPathComponent(".codex/hooks.json"))
        let base = ProcessInfo.processInfo.environment["TEST_RUNNER_TMPDIR"] ?? ProcessInfo.processInfo.environment["TMPDIR"] ?? FileManager.default.temporaryDirectory.path
        let state = URL(fileURLWithPath: base).appendingPathComponent("h" + UUID().uuidString.prefix(8))
        let fixture = try CodexEndpointFixture(prefix: "hooks", delay: 0.05, hooks: false, state: state)
        try await fixture.start(timeout: .seconds(10))
        defer { fixture.stop(removeState: true) }
        let tab = try XCTUnwrap(app.workspace.activeTab)
        try await TestSupport.eventually { app.runtime.views[tab.id]?.surface != nil }
        let view = try XCTUnwrap(app.runtime.views[tab.id])
        // Start the native agent before enabling hooks; its real binding is owned by the helper.
        TerminalTestSupport.send("env -u DISPATCH_EXECUTABLE " + CodexTestSupport.command(state: fixture.state, binary: fixture.binary), to: view)
        let terminal = try XCTUnwrap(app.workspace.activeTab?.terminal)
        let helper = HelperChat(terminal: terminal)
        struct Reply: Decodable { let binding: HelperTopology.Binding }
        var binding: HelperTopology.Binding?
        for _ in 0..<80 {
            if let reply: Reply = try? await helper.call("chat.state", input: HelperChat.Input(helper.route)), (reply.binding.pid ?? 0) > 1 {
                binding = reply.binding
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let captured = try XCTUnwrap(binding)
        let pid = try XCTUnwrap(captured.pid)
        let process = try XCTUnwrap(AgentProcess.capture(pid_t(pid)))
        XCTAssertEqual(captured.pid, UInt64(process.pid))
        XCTAssertEqual(captured.executable, process.executable)
        XCTAssertEqual(captured.start, [process.startedSeconds, process.startedMicroseconds])
        defer { if process.alive { kill(process.pid, SIGTERM) } }
        chat.setEnabled(true)
        await chat.integrationChanges?.value
        XCTAssertNil(chat.error)
        XCTAssertEqual(chat.hookStatus("codex"), .restart)
        XCTAssertEqual(chat.hookStatus("pi"), .off, "Pi's extension stays opt-in")
        XCTAssertEqual(chat.hookStatus("claude"), .ready, "No Claude process predates its hooks")
        XCTAssertEqual(kill(process.pid, SIGTERM), 0)
        try await TestSupport.eventually(timeout: .seconds(10)) { !process.alive }
        var retired = false
        for _ in 0..<80 {
            do {
                let reply: Reply = try await helper.call("chat.state", input: HelperChat.Input(helper.route))
                retired = reply.binding.pid != captured.pid
            } catch let error as HelperFailure where error.code == "unavailable" {
                retired = true
            }
            if retired { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(retired, "The helper must retire the exited native binding")
        let install = try await HelperChat.setup(.local, key: "codex", enabled: nil, terminal: nil)
        chat.helperInstalls["codex"] = try XCTUnwrap(install)
        XCTAssertEqual(chat.hookStatus("codex"), .ready)
        chat.setEnabled(false)
        await chat.integrationChanges?.value
        XCTAssertEqual(chat.hookStatus("codex"), .off)
        XCTAssertEqual(chat.hookStatus("claude"), .off)
    }

    func testChatFontSelectionKeepsCodeFontIndependent() {
        var preferences = Preferences()
        preferences.chatFont = .sameAsCode
        preferences.fontFamily = "0xProto"
        let code = ChatTypography(preferences: preferences)
        XCTAssertEqual(code.fontName, code.codeFontName)
        var changedDefault = preferences
        changedDefault.fontFamily = "Source Code Pro"
        let followingCode = ChatTypography(preferences: changedDefault)
        XCTAssertEqual(followingCode.fontName, followingCode.codeFontName)
        XCTAssertNotEqual(followingCode.fontName, code.fontName)
        for choice in ChatFont.allCases where choice != .sameAsCode {
            preferences.chatFont = choice
            let chat = ChatTypography(preferences: preferences)
            if choice == .system {
                XCTAssertEqual(chat.reply, NSFont.systemFont(ofSize: preferences.fontSize + 1))
                XCTAssertEqual(chat.body, .system(size: preferences.fontSize, weight: .regular))
            } else {
                XCTAssertEqual(chat.fontName, choice.postScriptName)
                XCTAssertEqual(chat.reply.fontName, choice.postScriptName)
            }
            XCTAssertEqual(chat.codeFontName, code.codeFontName)
            XCTAssertEqual(chat.codeDetailLineHeight, code.codeDetailLineHeight)
            XCTAssertEqual(chat.codeReply.pointSize, code.reply.pointSize)
            if choice == .system { XCTAssertEqual(chat.reply.pointSize, code.reply.pointSize) }
            else { XCTAssertNotEqual(chat.reply.pointSize, code.reply.pointSize) }
            XCTAssertEqual(chat.size, preferences.fontSize)
            preferences.fontFamily = "Source Code Pro"
            let changedCode = ChatTypography(preferences: preferences)
            XCTAssertEqual(changedCode.fontName, chat.fontName)
            XCTAssertEqual(changedCode.reply.pointSize, chat.reply.pointSize)
            XCTAssertNotEqual(changedCode.codeFontName, chat.codeFontName)
            preferences.fontFamily = "0xProto"
        }
    }

    func testUnavailableCodeFontKeepsChatTypographyUsableAtSizeLimits() throws {
        for size in [8.0, 32.0] {
            for choice in ChatFont.allCases {
                var preferences = Preferences()
                preferences.fontFamily = "DispatchMissingFont-\(UUID().uuidString)"
                preferences.fontSize = size
                preferences.chatFont = choice
                let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
                let typography = ChatTypography(preferences: decoded)
                XCTAssertEqual(typography.codeReply.fontName, NSFont.monospacedSystemFont(ofSize: size + 1, weight: .regular).fontName)
                XCTAssertEqual(typography.codeReply.pointSize, size + 1)
                XCTAssertEqual(typography.fontName, choice == .system ? NSFont.systemFont(ofSize: size).fontName : choice.postScriptName ?? typography.codeFontName)
                for metric in [typography.characterWidth, typography.replyLineHeight, typography.detailLineHeight,
                               typography.codeDetailLineHeight, typography.detailSize] {
                    XCTAssertTrue(metric.isFinite && metric > 0, "Unavailable fonts must not produce unusable text metrics")
                }
            }
        }
    }

    func testOptimisticPromptReconcilesWithoutDuplicateOrRowIdentityChange() {
        let session = ChatSession(id: UUID()), chat = ChatCoordinator(enabled: true)
        let now = Date()
        session.showOptimisticPrompt("repeat me")
        let rowID = session.visibleTranscriptRows.last?.id
        XCTAssertEqual(session.visibleTranscriptRows.last?.item?.text, "repeat me")
        XCTAssertEqual(session.followRevision, session.revision)
        session.awaitingPromptAck = true; session.promptBoundary = .local(now)
        chat.apply([ChatRecord(key: "old", turnID: "old", date: now.addingTimeInterval(-10), action: .item(ChatItem(id: "old-user", kind: .user, text: "repeat me")))], to: session, earlier: false, historical: true)
        XCTAssertNotNil(session.optimisticPrompt, "Old identical messages cannot acknowledge the new send")
        chat.apply([ChatRecord(key: "start", turnID: "new", date: now, action: .started),
                    ChatRecord(key: "user", turnID: "new", date: now, action: .item(ChatItem(id: "real", kind: .user, text: "repeat me")))], to: session, earlier: false, historical: false)
        XCTAssertNil(session.optimisticPrompt)
        XCTAssertEqual(session.visibleTranscriptRows.last?.id, rowID)
        session.insert(ChatItem(id: "hook", kind: .user, text: "repeat me"), turnID: "new", at: now)
        XCTAssertEqual(session.visibleTranscriptRows.count, 2)
        XCTAssertEqual(session.visibleTranscriptRows.last?.id, rowID)
    }

    /// Live helper records take the same acknowledgement path as transcript records, in either order of
    /// the turn start and the prompt's own user record.
    func testLiveHelperRecordsAcknowledgeTheOptimisticPromptInPlace() throws {
        func record(_ kind: String, _ text: String = "") throws -> HelperChat.Record {
            try JSONDecoder().decode(HelperChat.Record.self, from: JSONSerialization.data(withJSONObject: [
                "id": kind, "turn": "t1", "kind": kind, "text": text, "title": "", "output": "", "blocks": [],
                "completed": true, "documents": [], "inline_reasoning": false]))
        }
        for records in [[try record("turn_started"), try record("user", "hello")], [try record("user", "hello"), try record("turn_started")]] {
            let session = ChatSession(id: UUID()), chat = ChatCoordinator(enabled: true)
            session.showOptimisticPrompt("hello")
            let row = session.visibleTranscriptRows.last?.id
            session.awaitingPromptAck = true; session.promptBoundary = .firstRemoteTurn
            chat.receiveHelper(.records(records), session: session)
            XCTAssertNil(session.optimisticPrompt)
            XCTAssertFalse(session.awaitingPromptAck)
            XCTAssertEqual(session.visibleTranscriptRows.map(\.id), [row].compactMap { $0 })
        }
    }

    /// A new agent's first prompt creates its transcript, so the helper's first read of it arrives as a history
    /// replacement, before or after the send's reply, holding the prompt or not yet. The bubble keeps its row
    /// throughout instead of leaving and coming back with the record's identity.
    func testFirstTranscriptReadAcknowledgesTheOptimisticPromptInPlace() throws {
        func record(_ kind: String, _ text: String = "") throws -> HelperChat.Record {
            try JSONDecoder().decode(HelperChat.Record.self, from: JSONSerialization.data(withJSONObject: [
                "id": kind, "turn": "t1", "kind": kind, "text": text, "title": "", "output": "", "blocks": [],
                "completed": true, "documents": [], "inline_reasoning": false]))
        }
        let prompt = [try record("turn_started"), try record("user", "hello")]
        for delivered in [false, true] {
            for (first, later) in [(prompt, []), ([], prompt)] {
                let session = ChatSession(id: UUID()), chat = ChatCoordinator(enabled: true)
                session.active = true
                session.showOptimisticPrompt("hello")
                session.busy = true; session.optimisticPromptDelivered = delivered
                session.awaitingPromptAck = true; session.promptBoundary = .firstRemoteTurn
                let row = try XCTUnwrap(session.visibleTranscriptRows.last?.id), clock = session.submittedThinkingAt
                chat.receiveHelper(.replacement(.init(records: first, earlier: nil, state: nil, snapshot: nil)), session: session)
                XCTAssertEqual(session.visibleTranscriptRows.map(\.id), [row])
                XCTAssertEqual(session.submittedThinkingAt, clock, "The send keeps one clock")
                if !later.isEmpty { chat.receiveHelper(.records(later), session: session) }
                XCTAssertNil(session.optimisticPrompt)
                XCTAssertFalse(session.awaitingPromptAck)
                XCTAssertEqual(session.visibleTranscriptRows.map(\.id), [row])
            }
        }
    }

    /// A question form's submitted answers reach the helper as chosen option indices or typed text, whatever
    /// state the form was edited in (the test API and the form both submit the answers).
    func testSubmittedQuestionAnswersBecomeHelperOptionsOrText() throws {
        let interaction = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: [
            "id": "q", "approval": false, "blocking": true, "questions": [
                ["Detail?", ["Compact", "Detailed"], false], ["Checks?", ["Tests", "Lint", "Documentation"], true],
                ["Language?", ["Swift", "Rust"], false]].map { item -> [String: Any] in
                let (text, labels, multiple) = (item[0] as! String, item[1] as! [String], item[2] as! Bool)
                return ["id": text, "header": text, "text": text, "secret": false, "multiple": multiple, "custom": true,
                        "options": labels.map { ["id": $0, "label": $0] }]
            }]))
        let answers = interaction.answers(["Detail?": "Detailed", "Checks?": "Tests, Documentation", "Language?": "Python λ, typed"])
        XCTAssertEqual(answers, ["Detail?": .options([1]), "Checks?": .options([0, 2]), "Language?": .text("Python λ, typed")])
    }

    func testSubmittedThinkingClockSurvivesRemoteAcknowledgement() throws {
        let session = ChatSession(id: UUID()), chat = ChatCoordinator(enabled: true)
        session.active = true
        session.showOptimisticPrompt("hello")
        session.busy = true; session.awaitingPromptAck = true
        session.promptBoundary = .firstRemoteTurn
        let pending = AgentWorkingState(session)
        let started = try XCTUnwrap(pending.started, "Pending sends need a stable local clock")
        let receivedAt = started.addingTimeInterval(5)
        for skew in [-15.0, 15.0] {
            session.awaitingPromptAck = true; session.promptBoundary = .firstRemoteTurn
            let turn = "remote-\(skew)"
            chat.apply([.init(key: turn, turnID: turn, date: started.addingTimeInterval(skew), action: .started)],
                       to: session, earlier: false, historical: false)
            let acknowledged = AgentWorkingState(session)
            XCTAssertEqual(acknowledged.started, pending.started)
            XCTAssertEqual(AgentWorkingAnimation.timeText(acknowledged, now: receivedAt, appeared: started), "5s")
        }
        let finished = AgentWorkingState(session).finished(at: started.addingTimeInterval(-10), label: "Finished", receivedAt: receivedAt)
        XCTAssertEqual(AgentWorkingAnimation.timeText(finished, now: receivedAt, appeared: started), "5s")
        session.busy = false
        session.resetConversation()
        session.active = true; session.busy = true
        let date = Date().addingTimeInterval(-30)
        session.turns = [.init(id: "other", started: date)]
        XCTAssertEqual(AgentWorkingState(session).started, date, "A restored turn must not inherit the prior submission clock")
    }

    func testOptimisticFailureResetAndCommands() {
        let session = ChatSession(id: UUID())
        session.showOptimisticPrompt("hello")
        session.failOptimisticPrompt(restoreDraft: true)
        XCTAssertEqual(session.draft, "hello"); XCTAssertTrue(session.visibleTranscriptRows.isEmpty)
        session.showOptimisticPrompt("hello"); session.draft = "next draft"
        session.failOptimisticPrompt(restoreDraft: true)
        XCTAssertEqual(session.draft, "next draft")
        session.showOptimisticPrompt("/model")
        XCTAssertEqual(session.optimisticPrompt?.text, "/model", "Literal messages can contain command-looking text; the coordinator routes commands")
        session.showOptimisticPrompt("hello"); session.resetConversation()
        XCTAssertTrue(session.visibleTranscriptRows.isEmpty)
    }

    func testFailedSendRemainsVisibleAcrossBackgroundStatusRefreshUntilExplicitAction() throws {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.active = true; session.draft = "Keep my unsent message"
        coordinator.submit(session) // No verified process or terminal: refuse input.
        let failure = try XCTUnwrap(session.status)
        XCTAssertTrue(failure.contains("your draft is preserved"))
        XCTAssertEqual(session.draft, "Keep my unsent message")
        XCTAssertNil(session.submissionID)

        session.status = nil // A successful background transcript read.
        XCTAssertEqual(session.status, failure)
        session.status = "Codex is compacting the conversation…"
        XCTAssertEqual(session.status, failure, "Activity cannot hide failed delivery")
        session.status = nil
        coordinator.chooseChat(false, session: session)
        XCTAssertNil(session.status, "Opening the terminal explicitly acknowledges the failure")
        // A new explicit command replacing prior send feedback needs a real agent: exerciseCommands.
    }

    func testSubmissionFailureDoesNotFollowAClosedOrReplacementConversation() {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.submissionFailure = "Old failed send"
        coordinator.close(session.id)
        XCTAssertNil(session.submissionFailure)
        session.submissionFailure = "Another failed send"
        session.status = "Old activity"
        session.resetConversation()
        XCTAssertNil(session.status)
        XCTAssertNil(session.submissionFailure)
    }

    func testUnreadOutputTracksPresentationAcrossTerminalAndChatModes() {
        let session = ChatSession(id: UUID()), view = UUID()
        session.showChat = true
        session.insert(ChatItem(id: "background", kind: .assistant, text: "Finished in a hidden tab"), turnID: "turn")
        XCTAssertTrue(session.hasNewMessages, "A hidden tab needs an unread icon even when its saved chat position is at the bottom")
        session.atBottom = true
        XCTAssertTrue(session.hasNewMessages, "A hidden transcript geometry update cannot acknowledge unseen output")
        session.setPresented(true, by: view)
        XCTAssertFalse(session.hasNewMessages)

        session.atBottom = false
        session.insert(ChatItem(id: "later", kind: .assistant, text: "New output while reading history"), turnID: "turn")
        XCTAssertTrue(session.hasNewMessages)
        session.setPresented(false, by: view)
        session.setPresented(true, by: view)
        XCTAssertTrue(session.hasNewMessages, "Returning to a scrolled chat must preserve unread output")
        session.showChat = false
        XCTAssertFalse(session.hasNewMessages, "The visible live terminal also shows the agent's output")
        session.insert(ChatItem(id: "terminal", kind: .assistant, text: "Visible terminal output"), turnID: "turn")
        XCTAssertFalse(session.hasNewMessages)
        session.setPresented(false, by: view)
        session.insert(ChatItem(id: "hidden-terminal", kind: .assistant, text: "Hidden terminal output"), turnID: "turn")
        XCTAssertTrue(session.hasNewMessages)
    }

    func testMovedPresentationDoesNotLetOutgoingViewHideTheNewOwner() {
        let session = ChatSession(id: UUID()), outgoing = UUID(), incoming = UUID()
        session.showChat = true
        session.setPresented(true, by: outgoing)
        session.setPresented(true, by: incoming)
        session.setPresented(false, by: outgoing)
        XCTAssertTrue(session.isPresented)
        session.insert(ChatItem(id: "moved", kind: .assistant, text: "Output in the new pane"), turnID: "turn")
        XCTAssertFalse(session.hasNewMessages)
        session.setPresented(false, by: incoming)
        XCTAssertFalse(session.isPresented)
    }

    func testHistoricalAndDuplicateOutputDoesNotCreateUnreadActivity() {
        let session = ChatSession(id: UUID()), view = UUID()
        session.showChat = true
        session.insert(ChatItem(id: "old", kind: .assistant, text: "Restored history"), turnID: "old", historical: true)
        XCTAssertFalse(session.hasNewMessages)
        session.setPresented(true, by: view)
        session.insert(ChatItem(id: "hook", kind: .assistant, text: "Done"), turnID: "live")
        session.insert(ChatItem(id: "tool", kind: .tool, text: "swift build", title: "Shell"), turnID: "live")
        let toolPresentation = session.turns.flatMap(\.items).first { $0.id == "tool" }?.presentationID
        session.setPresented(false, by: view)
        session.insert(ChatItem(id: "transcript", kind: .assistant, text: "Done"), turnID: "live")
        session.insert(ChatItem(id: "tool", kind: .tool, text: "swift build", title: "Shell"), turnID: "live")
        XCTAssertFalse(session.hasNewMessages, "Replaying already-seen hook output from a transcript must not notify twice")
        XCTAssertEqual(session.turns.flatMap(\.items).first { $0.id == "tool" }?.presentationID, toolPresentation,
                       "Duplicate records must preserve cached tool formatting")
        session.insert(ChatItem(id: "tool", kind: .tool, text: "", output: "Build complete", completed: true), turnID: "live")
        XCTAssertTrue(session.hasNewMessages, "New output for an existing tool still needs attention")
    }

    func testNewConversationPreservesSelectedViewWhileReadinessChanges() {
        let session = ChatSession(id: UUID()), view = UUID()
        session.showChat = true; session.manualViewChoice = true
        session.draft = "Unsent draft"
        session.setPresented(true, by: view)
        session.resetConversation()
        XCTAssertTrue(session.showChat, "A replacement process must preserve the selected view")
        XCTAssertTrue(session.manualViewChoice)
        XCTAssertTrue(session.isPresented, "The terminal still owns its mounted pane")
        XCTAssertEqual(session.draft, "Unsent draft")
    }

    /// /exit from Chat returns to Terminal whether the command's reply or the agent's exit comes
    /// first; a state between them must not bring the chat back as a read-only transcript.
    func testRequestedExitReturnsToTerminalWhicheverSignalArrivesFirst() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        let idle = HelperChat.State(busy: false, activity: nil, model: nil, model_label: nil, effort: nil, usage: nil,
                                    goal: nil, draft: nil, attention: nil, title: nil, compacting: false, service_tier: nil)
        session.helper = HelperChat(terminal: 1, session: "conversation", endpoint: .local)
        session.agentID = "claude"; session.sessionID = "conversation"
        chat.receiveHelper(.state(idle), session: session)
        XCTAssertTrue(session.showChat, "Discovery shows the chat")
        XCTAssertFalse(session.manualViewChoice)
        // Reply first: the agent still reports state before it exits.
        session.exitRequested = true
        chat.setChatVisible(false, session: session, reason: "exit")
        chat.receiveHelper(.state(idle), session: session)
        XCTAssertFalse(session.showChat, "A late state must not reopen an exiting agent's chat")
        chat.helperExited(.local, terminal: 1)
        XCTAssertFalse(session.showChat)
        XCTAssertFalse(session.exitRequested)
        // The next agent is shown again; this time its exit arrives before the reply.
        chat.receiveHelper(.state(idle), session: session)
        XCTAssertTrue(session.showChat)
        session.exitRequested = true
        chat.helperExited(.local, terminal: 1)
        XCTAssertFalse(session.showChat, "The exit itself returns to Terminal")
        XCTAssertEqual(session.viewTransitions.last?.reason, "exit")
        XCTAssertFalse(session.manualViewChoice, "A later agent in this terminal still opens in chat")
    }

    func testRetainedHistoryRemainsReadableAfterProcessLookupFails() {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.sessionID = UUID().uuidString
        session.discoveryBlocked = true
        session.status = "Herdr connection closed."
        XCTAssertTrue(coordinator.canEnterChat(session))
        XCTAssertTrue(coordinator.chatAvailabilityHint(session).contains("sending paused"))
        session.active = true
        XCTAssertTrue(coordinator.canEnterChat(session), "Unverified live agents must retain access to history and drafts")
    }

    private var fixture: Data {
        get throws { try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/codex-0.153.2.jsonl")) }
    }
    /// Chat on installs both approval integrations; an opt-out stays (the next start reads the installed
    /// state instead of reinstalling); a broken Codex config fails without hiding Claude or being rewritten.
    func testApprovalHooksDefaultToBothAndRememberOptOuts() async throws {
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        try await TestSupport.integrations(["codex", "claude"], enabled: false, chat: chat)
        let hooks = Home.url.appendingPathComponent(".codex/hooks.json")
        defer { try? FileManager.default.removeItem(at: hooks); chat.setEnabled(false) }
        func later() async throws -> ChatCoordinator {
            let next = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
            next.loadLaunches()
            try await TestSupport.eventually(timeout: .seconds(10)) { ["codex", "claude"].allSatisfy { next.helperInstalls[$0] != nil } }
            return next
        }
        chat.setEnabled(true)
        try await TestSupport.eventually(timeout: .seconds(10), diagnostic: chat.error ?? "no error") {
            chat.hookStatus("codex") != .off && chat.hookStatus("claude") != .off
        }
        XCTAssertNil(chat.error)
        chat.setHelperIntegration("codex", enabled: false)
        try await TestSupport.eventually(timeout: .seconds(10)) { chat.hookStatus("codex") == .off }
        let claudeOnly = try await later()
        XCTAssertEqual(claudeOnly.hookStatus("codex"), .off)
        XCTAssertNotEqual(claudeOnly.hookStatus("claude"), .off)
        chat.setHelperIntegration("claude", enabled: false)
        try await TestSupport.eventually(timeout: .seconds(10)) { chat.hookStatus("claude") == .off }
        let off = try await later()
        XCTAssertEqual([off.hookStatus("codex"), off.hookStatus("claude")], [.off, .off])
        for key in ["codex", "claude"] { chat.setHelperIntegration(key, enabled: true) }
        try await TestSupport.eventually(timeout: .seconds(10)) { chat.hookStatus("codex") != .off && chat.hookStatus("claude") != .off }
        let restored = try await later()
        XCTAssertTrue(restored.hookStatus("codex") != .off && restored.hookStatus("claude") != .off)

        for key in ["codex", "claude"] { chat.setHelperIntegration(key, enabled: false) }
        try await TestSupport.eventually(timeout: .seconds(10)) { chat.hookStatus("codex") == .off && chat.hookStatus("claude") == .off }
        let invalid = Data("invalid JSON".utf8)
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try invalid.write(to: hooks)
        chat.error = nil
        for key in ["codex", "claude"] { chat.setHelperIntegration(key, enabled: true) }
        try await TestSupport.eventually(timeout: .seconds(10)) { chat.hookStatus("claude") != .off && chat.error != nil }
        XCTAssertEqual(chat.hookStatus("codex"), .off)
        XCTAssertNotNil(chat.error, "Successful Claude setup must not hide a Codex setup failure")
        XCTAssertEqual(try Data(contentsOf: hooks), invalid)
    }

    func testHistoricalTurnsArrivingAfterHooksRemainChronological() {
        let session = ChatSession(id: UUID())
        session.insert(ChatItem(id: "final", kind: .assistant, text: "Last"), turnID: "new", at: Date(timeIntervalSince1970: 40))
        session.insert(ChatItem(id: "old", kind: .user, text: "Earlier"), turnID: "old", at: Date(timeIntervalSince1970: 10))
        session.insert(ChatItem(id: "user", kind: .user, text: "Question"), turnID: "new", at: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(session.turns.map(\.id), ["old", "new"])
        XCTAssertEqual(session.turns[1].items.map(\.text), ["Question", "Last"])
    }
    /// A Codex transcript's tool call shows its input and output once (hook/live overlap is the helper's).
    /// The helper's Codex integration in the test home's hooks.json (what the app's Chat switch installs).
    private var codexHooks: URL { Home.url.appendingPathComponent(".codex/hooks.json") }
    private func codex(_ enabled: Bool?) async throws -> HelperChat.Installation {
        let installation = try await HelperChat.setup(.local, key: "codex", enabled: enabled, terminal: nil)
        return try XCTUnwrap(installation)
    }

    /// Pi's managed extension through installation.install (helper route of the old PiChatSetup cases):
    /// a file the user changed or replaced is never overwritten (the install fails, its bytes stay),
    /// linked files or directories are refused, and unrelated extensions are left alone.
    func testPiExtensionNeverOverwritesForeignOrLinkedFiles() async throws {
        let fm = FileManager.default
        let extensions = Home.url.appendingPathComponent(".pi/agent/extensions")
        let script = extensions.appendingPathComponent("dispatch-chat.js")
        func pi(_ enabled: Bool) async throws -> HelperChat.Installation {
            let installation = try await HelperChat.setup(.local, key: "pi", enabled: enabled, terminal: nil)
            return try XCTUnwrap(installation)
        }
        defer { try? fm.removeItem(at: extensions) }
        _ = try await pi(true)
        XCTAssertTrue(fm.fileExists(atPath: script.path), "Installing writes the managed extension")
        let unrelated = extensions.appendingPathComponent("unrelated.js")
        let foreign = Data("// Dispatch's opt-in bridge for an existing interactive Pi session.\n// user modifications must survive\n".utf8)
        try foreign.write(to: unrelated)
        try foreign.write(to: script)
        let refused = await Task { try await pi(true) }.result
        XCTAssertThrowsError(try refused.get(), "A modified extension is not overwritten")
        XCTAssertEqual(try Data(contentsOf: script), foreign)
        XCTAssertEqual(try Data(contentsOf: unrelated), foreign, "Unrelated extensions stay")
        // A linked extension file (even one pointing at the user's copy) is foreign too.
        let target = Home.url.appendingPathComponent("preserved-\(UUID()).js")
        defer { try? fm.removeItem(at: target) }
        try fm.moveItem(at: script, to: target)
        try fm.createSymbolicLink(at: script, withDestinationURL: target)
        let linked = await Task { try await pi(true) }.result
        XCTAssertThrowsError(try linked.get(), "A symlinked extension is refused")
        XCTAssertEqual(try Data(contentsOf: target), foreign)
        try fm.removeItem(at: script)
        // A linked extensions directory is refused and stays empty.
        let directory = Home.url.appendingPathComponent("linked-\(UUID())")
        defer { try? fm.removeItem(at: directory) }
        try fm.removeItem(at: extensions)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: extensions, withDestinationURL: directory)
        let linkedDirectory = await Task { try await pi(true) }.result
        XCTAssertThrowsError(try linkedDirectory.get(), "A symlinked extensions directory is refused")
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
        try fm.removeItem(at: extensions)
        _ = try await pi(false)
    }

    /// Installing merges into the user's hooks.json: their handlers and keys stay, a second install
    /// changes nothing. Turning it off is helper state: the file is not touched again (append-only)
    /// and the audit reports off.
    func testHookMergePreservesExistingHandlersAndIsIdempotent() async throws {
        _ = try await codex(false)
        defer { try? FileManager.default.removeItem(at: codexHooks) }
        try FileManager.default.createDirectory(at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"description":"Mine","future":true,"hooks":{"Stop":[{"matcher":".*","hooks":[{"type":"command","command":"echo mine","timeout":7}]}]}}"#.utf8)
            .write(to: codexHooks)
        _ = try await codex(true)
        let first = try Data(contentsOf: codexHooks)
        _ = try await codex(true)
        XCTAssertEqual(try Data(contentsOf: codexHooks), first, "A second install changes nothing")
        _ = try await codex(false)
        XCTAssertEqual(try Data(contentsOf: codexHooks), first, "Turning the integration off leaves the file as installed")
        let audit = try await codex(nil)
        XCTAssertEqual(audit.status, "off")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: codexHooks)) as? [String: Any])
        XCTAssertEqual(root["description"] as? String, "Mine")
        XCTAssertEqual(root["future"] as? Bool, true)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        let handlers = try XCTUnwrap(hooks["Stop"]?.flatMap { $0["hooks"] as? [[String: Any]] ?? [] })
        XCTAssertEqual(handlers.filter { $0["command"] as? String == "echo mine" }.map { $0["timeout"] as? Int }, [7])
    }

    /// A hooks.json the integration cannot read as hooks is never rewritten: the install fails instead.
    func testInvalidConfigurationRemainsUntouched() async throws {
        _ = try await codex(false)
        defer { try? FileManager.default.removeItem(at: codexHooks) }
        try FileManager.default.createDirectory(at: codexHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        for value in [#"{"hooks": ["#, #"{"hooks":[]}"#, #"{"hooks":{"Stop":[{}]}}"#, #"{"hooks":{"Stop":[{"hooks":[42]}]}}"#] {
            let invalid = Data(value.utf8)
            try invalid.write(to: codexHooks)
            let result = await Task { try await codex(true) }.result
            XCTAssertThrowsError(try result.get(), value)
            XCTAssertEqual(try Data(contentsOf: codexHooks), invalid, value)
        }
    }

    /// Install, audit and remove in the test home: the status follows each step.
    func testInstallAndDisableInTemporaryHome() async throws {
        _ = try await codex(false)
        defer { try? FileManager.default.removeItem(at: codexHooks) }
        var statuses: [String?] = []
        for enabled in [false, true, false] {
            _ = try await codex(enabled)
            statuses.append(try await codex(nil).status)
        }
        XCTAssertEqual(statuses.map { $0 == "off" }, [true, false, true])
    }

    /// A Codex transcript opened from a file: the conversation's own records in their turn, hidden
    /// and unknown records never shown.
    private func archive(_ data: Data, opens: Bool = true) async throws -> ChatSession {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try data.write(to: url)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        return try await chat.archived(url, agent: "codex", session: "11111111-1111-4111-8111-111111111111", opens: opens)
    }

    func testPartialTranscriptAndUnknownRecords() async throws {
        let session = try await archive(try fixture)
        let items = session.turns.flatMap(\.items)
        XCTAssertTrue(items.contains { $0.kind == .user && $0.text == "Check the build" })
        XCTAssertTrue(items.contains { $0.kind == .reasoning && $0.text == "I will check the build." })
        XCTAssertFalse(items.contains { $0.text.contains("DO_NOT_DISPLAY") || $0.text.contains("IGNORE") })
        XCTAssertEqual(session.turns.map(\.id), ["turn-1"])
    }

    /// Any version string, or none, opens the transcript; the metadata decides, not the version.
    func testTranscriptCompatibilityDependsOnMetadataNotVersion() async throws {
        let bytes = try fixture
        let body = Data(bytes[(try XCTUnwrap(bytes.firstIndex(of: 10)) + 1)...])
        for version in ["0.1.0", "99.0.0", "0.154.0-beta.1", "custom-build", nil] as [String?] {
            var metadata: [String: Any] = ["id": "11111111-1111-4111-8111-111111111111"]
            if let version { metadata["cli_version"] = version }
            let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": metadata]) + Data([10])
            let items = try await archive(header + body).turns.flatMap(\.items)
            XCTAssertTrue(items.contains { $0.kind == .user && $0.text == "Check the build" }, version ?? "none")
            XCTAssertTrue(items.contains { $0.kind == .assistant && $0.text == "The build passed." }, version ?? "none")
            XCTAssertFalse(items.contains { $0.text.contains("DO_NOT_DISPLAY") || $0.text.contains("IGNORE") })
        }
    }

    /// Without its conversation's metadata a transcript shows nothing.
    func testMissingOrMalformedMetadataDoesNotAuthorizeTranscriptRecords() async throws {
        let bytes = try fixture
        let body = Data(bytes[(try XCTUnwrap(bytes.firstIndex(of: 10)) + 1)...])
        var headers = [Data()]
        for metadata in [[:], ["cli_version": "0.154.0"], ["id": 42], ["id": ""], ["id": " \t"]] as [[String: Any]] {
            headers.append(try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": metadata]) + Data([10]))
        }
        for header in headers {
            let session = try await archive(header + body, opens: false)
            XCTAssertTrue(session.turns.isEmpty, String(decoding: header, as: UTF8.self))
        }
    }

    func testHookAndTranscriptOverlapPreservesToolInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try fixture.write(to: url)
        let helper = HelperChat(archive: .init(key: "codex", path: url.path, session: "11111111-1111-4111-8111-111111111111"))
        let page = try await helper.page(earlier: nil)
        let chat = ChatCoordinator(enabled: false, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = chat.session(for: UUID())
        session.insert(ChatItem(id: "hook-final", kind: .assistant, text: "The build passed."), turnID: "turn-1")
        chat.receiveHelper(.page(page), session: session)
        let items = try XCTUnwrap(session.turns.first).items
        XCTAssertEqual(items.filter { $0.kind == .assistant }.count, 1)
        let tool = try XCTUnwrap(items.first { $0.id == "tool-call-1" })
        XCTAssertEqual(tool.title, "exec_command")
        XCTAssertTrue(tool.text.contains("swift build"))
        XCTAssertEqual(tool.output, "Build complete")
    }

    func testToolUpdatesMergeInEitherOrderAndKeepSeparateCalls() throws {
        let input = ChatItem(id: "tool-1", kind: .tool, text: "swift build", title: "Shell")
        let output = ChatItem(id: "tool-1", kind: .tool, text: "", output: "Build failed", completed: true, exitCode: 7)
        for updates in [[input, output], [output, input]] {
            let session = ChatSession(id: UUID())
            for item in updates { session.insert(item, turnID: "turn") }
            let merged = try XCTUnwrap(session.turns.first?.items.first)
            XCTAssertEqual(merged.id, "tool-1")
            XCTAssertEqual(merged.text, input.text)
            XCTAssertEqual(merged.title, input.title)
            XCTAssertEqual(merged.output, output.output)
            XCTAssertEqual(merged.exitCode, 7)
            XCTAssertTrue(merged.completed)

            var repeated = input
            repeated.id = "tool-2"
            session.insert(repeated, turnID: "turn")
            XCTAssertEqual(session.turns.first?.items.count, 2, "Separate calls with identical input must stay separate")
        }
    }
    func testDuplicateMessagesKeepIdentityAndEarliestTranscriptPosition() throws {
        let session = ChatSession(id: UUID())
        let date = Date(timeIntervalSince1970: 20)
        session.insert(ChatItem(id: "hook", kind: .assistant, text: "Done"), turnID: "turn", at: date.addingTimeInterval(10))
        let rowID = try XCTUnwrap(session.transcriptRows.first?.id)
        session.insert(ChatItem(id: "next", kind: .assistant, text: "Next"), turnID: "turn", at: date, fileOffset: 200)
        session.insert(ChatItem(id: "transcript", kind: .assistant, text: "Done"), turnID: "turn", at: date, historical: true, fileOffset: 100)
        XCTAssertEqual(session.turns.first?.items.map(\.id), ["hook", "next"])
        XCTAssertEqual(session.transcriptRows.first?.id, rowID)
        XCTAssertEqual(session.turns.first?.started, date)
        XCTAssertEqual(session.turns.first?.fileOffset, 100)
    }
    /// A transcript opens only for its own conversation; incremental rereads after replacement or
    /// truncation are the helper's reader.
    func testReaderHandlesReplacementTruncationAndWrongSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rollout.jsonl")
        try fixture.write(to: url)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let first = try await chat.archived(url, agent: "codex", session: "11111111-1111-4111-8111-111111111111")
        XCTAssertFalse(first.turns.isEmpty)
        let mismatch = try await chat.archived(url, agent: "codex", session: "other", opens: false)
        XCTAssertTrue(mismatch.turns.isEmpty)
    }

    /// An oversized or malformed line hides only itself: the records after it still show.
    func testOversizedAndMalformedRecordsRecoverAtNewline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try fixture
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        let clean = directory.appendingPathComponent("clean.jsonl"), damaged = directory.appendingPathComponent("damaged.jsonl")
        try data.write(to: clean)
        try (Data(lines[0]) + Data([10]) + Data(repeating: 120, count: 4_194_305) + Data("\ninvalid\n".utf8)
             + Data(lines.dropFirst().joined(separator: [10]))).write(to: damaged)
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let id = "11111111-1111-4111-8111-111111111111"
        let expected = try await chat.archived(clean, agent: "codex", session: id).turns.flatMap(\.items).map(\.text)
        let shown = try await chat.archived(damaged, agent: "codex", session: id).turns.flatMap(\.items).map(\.text)
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(shown, expected)
    }

    /// A card decides once: later clicks change nothing; terminal/expired leave the native prompt to the terminal.
    func testApprovalDecisionsAreOneShotAndFailOpenToNativeUI() throws {
        for decision in [PendingApproval.Decision.allow, .deny, .terminal, .expired] {
            var completed: [PendingApproval.Decision?] = []
            let card = PendingApproval(key: "request", operation: "swift build") { completed.append($0.decision) }
            XCTAssertTrue(card.pending)
            card.resolve(decision)
            card.resolve(.allow)
            XCTAssertFalse(card.pending)
            XCTAssertEqual(completed, [decision])
        }
        var completed = 0
        let card = PendingApproval(key: "stale", operation: "operation") { _ in completed += 1 }
        card.retire()
        card.resolve(.allow)
        XCTAssertEqual(card.decision, .expired)
        XCTAssertEqual(completed, 0, "A withdrawn request sends nothing")
    }

    func testTabStateAndManualChoiceSurviveRepeatedAccess() {
        let coordinator = ChatCoordinator()
        let id = UUID(), other = UUID()
        let first = coordinator.session(for: id)
        let second = coordinator.session(for: other)
        XCTAssertNotEqual(first.token, second.token)
        first.draft = "line one\nline two"; first.expanded.insert("tool"); first.scrollAnchor = "turn"
        coordinator.chooseChat(true, session: first)
        coordinator.chooseChat(false, session: first)
        XCTAssertTrue(coordinator.session(for: id) === first)
        XCTAssertEqual(first.draft, "line one\nline two")
        XCTAssertEqual(first.scrollAnchor, "turn")
        XCTAssertTrue(first.expanded.contains("tool"))
        XCTAssertTrue(first.manualViewChoice)
        coordinator.close(id)
        XCTAssertNil(coordinator.sessions[id])
        XCTAssertTrue(coordinator.session(for: other) === second)
    }
    /// The chat shows the harness's usage report (helper State.usage, the documented ChatUsage JSON) without inventing a cost.
    func testSessionUsageParsesReportedCountersWithoutInventingCost() throws {
        let report = #"{"info":{"total_token_usage":{"input_tokens":142000,"output_tokens":6940},"last_token_usage":{"total_tokens":19000},"model_context_window":100000}}"#
        let coordinator = ChatCoordinator(enabled: false)
        defer { coordinator.stop() }
        let session = coordinator.session(for: UUID())
        session.helper = HelperChat(terminal: 0)
        let state = try JSONSerialization.data(withJSONObject: ["busy": false, "pending": false, "compacting": false, "usage": report])
        coordinator.receiveHelper(.state(try JSONDecoder().decode(HelperChat.State.self, from: state)), session: session)
        let usage = try XCTUnwrap(session.usage)
        XCTAssertEqual(usage.input, 142000)
        XCTAssertEqual(usage.output, 6940)
        XCTAssertEqual(try XCTUnwrap(usage.contextRemaining), 0.81, accuracy: 0.001)
        XCTAssertNil(usage.costUSD)
        session.resetConversation()
        XCTAssertNil(session.usage)
        XCTAssertNil(ChatUsage(["info": ["total_token_usage": ["input_tokens": -1]]]))
    }

}
