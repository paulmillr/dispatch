import AppKit
import SwiftUI
import XCTest
@testable import DispatchApp

@MainActor
final class ChatQueueTests: XCTestCase {

    func testMenuKeysUseCheckedSubmissionAndPreserveRejectedAndUncertainOutcomes() {
        let replies = [(true, true), (false, false), (false, true)]
        let outcomes: [Bool?] = replies.map { written, uncertain in
            let reply = HelperChat.Sent(written: written, may_have_sent: uncertain, reason: "fixture rejection")
            do { try reply.confirmed(); return nil }
            catch { return ChatInputNotSent.deliveryUncertain(error, started: true) }
        }
        XCTAssertEqual(outcomes, [nil, false, true])
    }

    func testDeliveryUncertaintyRequiresStartedInputAndNoProofOfRejection() throws {
        let error = NSError(domain: "delivery", code: 1)
        var cases: [(Error, Bool)] = [(error, true), (ChatInputNotSent(error), false)]
        // A helper's refusal typed nothing unless it says so; a lost connection may have lost the reply.
        for (code, uncertain) in [("input", false), ("deadline", false), ("uncertain", true), ("connection_closed", true)] {
            cases.append((HelperFailure(code: code, message: "fixture"), uncertain))
        }
        for uncertain in [false, true] {
            let result = HelperChat.Sent(written: false, may_have_sent: uncertain, reason: "failed")
            do {
                try result.confirmed()
                XCTFail("A refused or unconfirmed delivery must report its outcome")
            } catch {
                cases.append((error, uncertain))
                cases.append((ChatInputNotSent(error), false))
            }
        }
        let actual = cases.map { error, _ in
            [false, true].map { ChatInputNotSent.deliveryUncertain(error, started: $0) }
        }
        XCTAssertEqual(actual, cases.map { [false, $0.1] })
    }

    func testQueueUsesStableSSHIdentityButRejectsProcessReplacement() throws {
        let (chat, session) = try queuedFixture()
        session.queuedMessages = []; session.process = nil; session.host = "host"
        session.helperNativeQueue = true // This test keeps held rows in the app; no stand-in requests.
        session.binding = .init(session: "original", transcript: "first", pid: 42, start: [1, 0], executable: "/bin/agent")
        session.queueBusy = true; session.draft = "remote message"; chat.queue(session)
        session.binding = .init(session: "original", transcript: "rotated", pid: 42, start: [1, 0], executable: "/bin/agent")
        XCTAssertTrue(session.queuedMessages[0].matches(session), "Transcript replacement does not replace its owner")
        session.binding = .init(session: "original", transcript: "rotated", pid: 42, start: [2, 0], executable: "/bin/agent")
        chat.drainQueue(session)
        XCTAssertFalse(session.queuedMessages[0].matches(session), "A reused remote PID is another owner")
        XCTAssertEqual(session.queuedMessages[0].pause, .destinationChanged)
    }

    func testDisconnectKeepsBindingButPermissionRevocationRequiresReview() throws {
        let (chat, session) = try queuedFixture()
        let endpoint = HelperWorkspace.Endpoint.remote(SSHConnectionID())
        session.helper = HelperChat(terminal: 0, endpoint: endpoint)
        session.process = nil; session.host = "host"
        session.helperNativeQueue = true
        session.binding = .init(session: "original", transcript: nil, pid: 42, start: [1, 0], executable: "/bin/agent")
        session.queuedMessages = []; session.queueBusy = true
        session.draft = "survives reconnect"; chat.queue(session)
        chat.helperExited(endpoint)
        XCTAssertFalse(session.active)
        XCTAssertTrue(session.queuedMessages[0].matches(session))
        XCTAssertNil(session.queuePaused, "Untouched replies may resume after the same destination is verified")
        session.active = true
        chat.helperExited(endpoint, disabled: true)
        XCTAssertFalse(session.queuedMessages[0].matches(session))
        XCTAssertEqual(session.queuedMessages[0].pause, .destinationChanged)
    }

    func testCommandWaitsForTerminalQuestionToFinishClosing() throws {
        let (chat, session) = try queuedFixture()
        session.queuedMessages = []; session.busy = false; session.queueBusy = true
        let question = HelperChat.Interaction(id: "question", key: nil, approval: false, blocking: true,
            questions: [.init(id: "size", header: "Size", text: "Choose an option", secret: false,
                options: [.init(id: "small", label: "Small", detail: nil), .init(id: "large", label: "Large", detail: nil)],
                multiple: false, custom: false, blocks: nil)], turn: nil, record: nil)
        chat.receiveHelper(.interaction(question), session: session)
        session.draft = "/new"; chat.sendFromComposer(session)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["/new"])
        XCTAssertTrue(session.queuedMessages[0].isCommand)
        XCTAssertNil(session.command)
        chat.receiveHelper(.interaction(.init(id: "question", key: nil, approval: false, blocking: true,
            questions: [], turn: nil, record: nil)), session: session)
        XCTAssertFalse(session.waitingForAnswer)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["/new"])
    }

    func testSteeringKeepsTurnIdentityWhenItsStartPredatesThePrompt() {
        func record(_ kind: String, _ id: String, _ time: Int64, text: String = "") -> HelperChat.Record {
            .init(id: id, turn: "running", kind: kind, text: text, title: "", output: "", blocks: [],
                completed: true, exit_code: nil, patch: nil, time_ms: time, documents: [], tool: nil, inline_reasoning: false)
        }
        for previous in [nil, "previous"] as [String?] {
            let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
            let session = chat.session(for: UUID())
            session.helper = HelperChat(terminal: 0)
            session.active = true; session.busy = true; session.activeTurnID = previous
            session.showOptimisticPrompt("steer this turn", at: Date(timeIntervalSince1970: 100))
            session.awaitingPromptAck = true; session.promptBoundary = .local(Date(timeIntervalSince1970: 100))
            chat.receiveHelper(.records([record("turn_started", "started", 99_000)]), session: session)
            XCTAssertTrue(session.awaitingPromptAck, "A prior start cannot acknowledge this input")
            XCTAssertEqual(session.activeTurnID, "running")
            chat.receiveHelper(.records([record("user", "steered", 100_000, text: "steer this turn"),
                record("turn_ended", "ended", 101_000)]), session: session)
            chat.receiveHelper(.state(.init(busy: false, activity: nil, model: nil, model_label: nil,
                effort: nil, usage: nil, goal: nil, draft: nil, attention: nil, title: nil,
                compacting: false, service_tier: nil)), session: session)
            XCTAssertNil(session.optimisticPrompt)
            XCTAssertFalse(session.awaitingPromptAck)
            XCTAssertFalse(session.busy)
        }
    }

    func testQueueWaitsForBothIdleStateAndTurnCompletion() throws {
        for recordsFirst in [false, true] {
            let (chat, session) = try queuedFixture()
            session.binding = .init(session: "original", transcript: nil, pid: 42, start: [1, 0], executable: "/bin/agent")
            session.showOptimisticPrompt("previous", at: Date(timeIntervalSince1970: 100))
            session.awaitingPromptAck = true
            session.promptBoundary = .local(Date(timeIntervalSince1970: 100))
            session.activeTurnID = "previous-turn"
            let records = HelperChat.Event.records([.init(id: "started", turn: "running", kind: "turn_started",
                text: "", title: "", output: "", blocks: [], completed: true, exit_code: nil,
                patch: nil, time_ms: 100_000, documents: [], tool: nil, inline_reasoning: false),
                .init(id: "previous", turn: "running", kind: "user",
                text: "previous", title: "", output: "", blocks: [], completed: true, exit_code: nil,
                patch: nil, time_ms: 100_000, documents: [], tool: nil, inline_reasoning: false),
                .init(id: "ended", turn: "running", kind: "turn_ended", text: "", title: "", output: "", blocks: [],
                    completed: true, exit_code: nil, patch: nil, time_ms: 101_000, documents: [], tool: nil, inline_reasoning: false)])
            let idle = HelperChat.Event.state(.init(busy: false, activity: nil, model: nil, model_label: nil,
                effort: nil, usage: nil, goal: nil, draft: nil, attention: nil, title: nil,
                compacting: false, service_tier: nil))
            chat.receiveHelper(recordsFirst ? records : idle, session: session)
            XCTAssertNil(session.queuedSubmissionID, "Neither acknowledgement while busy nor idle before acknowledgement permits delivery")
            chat.receiveHelper(recordsFirst ? idle : records, session: session)
            XCTAssertEqual(session.queuedSubmissionID, session.queuedMessages.first?.id)
            XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second"], "Rows remain until checked delivery completes")
            session.helperTask?.cancel()
        }
    }

    func testQueueDoesNotTreatStartAcknowledgementAsTurnCompletion() throws {
        let (chat, session) = try queuedFixture()
        session.binding = .init(session: "original", transcript: nil, pid: 42, start: [1, 0], executable: "/bin/agent")
        session.awaitingPromptAck = true; session.promptBoundary = .firstRemoteTurn
        // Real full047 app journal: old idle, new turn start, then busy in the same read.
        for event in [HelperChat.Event.state(.init(busy: false, activity: nil, model: nil, model_label: nil,
                        effort: nil, usage: nil, goal: nil, draft: nil, attention: nil, title: nil,
                        compacting: false, service_tier: nil)),
                      .records([.init(id: "started", turn: "running", kind: "turn_started", text: "", title: "",
                        output: "", blocks: [], completed: true, exit_code: nil, patch: nil,
                        time_ms: 100_000, documents: [], tool: nil, inline_reasoning: false)]),
                      .state(.init(busy: true, activity: "working", model: nil, model_label: nil,
                        effort: nil, usage: nil, goal: nil, draft: nil, attention: nil, title: nil,
                        compacting: false, service_tier: nil))] {
            chat.receiveHelper(event, session: session)
            XCTAssertNil(session.queuedSubmissionID)
            XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second"])
        }
        XCTAssertFalse(session.awaitingPromptAck)
        XCTAssertTrue(session.busy)
    }

    private func queuedFixture() throws -> (ChatCoordinator, ChatSession) {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.showChat = true; session.busy = true; session.sessionID = "original"
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        // Held while queueing: the app's queue state only, nothing uploaded to the stand-in.
        session.queueBusy = true
        for text in ["first", "second"] { session.draft = text; chat.queue(session) }
        session.queueBusy = false
        return (chat, session)
    }

    func testAttentionAndRetryDoNotPauseUntouchedMessages() throws {
        let (chat, session) = try queuedFixture()
        chat.requireTerminalAttention(session, status: "Answer in Terminal")
        XCTAssertNil(session.queuePaused)
        session.busy = false
        chat.retryChat(session)
        XCTAssertNil(session.terminalAttention)
        XCTAssertNil(session.queuePaused)
        XCTAssertNotNil(session.queueWaiting, "This fixture has no terminal, so it waits for one")
        XCTAssertEqual(session.queuedMessages.count, 2)
    }

    func testFailedSendNowExplainsAndKeepsMessageQueued() throws {
        let (chat, session) = try queuedFixture()
        let first = session.queuedMessages[0].id
        // This fixture has no terminal, so the agent cannot take input mid-turn.
        chat.sendNow(session, queuedID: first)
        XCTAssertTrue(session.submissionFailure?.hasPrefix("Could not send now:") == true, session.submissionFailure ?? "no failure shown")
        XCTAssertEqual(session.queuedMessages.map(\.id).first, first)
        XCTAssertNil(session.queuedMessages[0].pause)
        XCTAssertNil(session.queuePaused)
    }

    func testUncertainHeadSurvivesUnrelatedEditAndRetryButDiscardReleasesQueue() throws {
        let (chat, session) = try queuedFixture()
        let first = session.queuedMessages[0].id, second = session.queuedMessages[1].id
        session.pauseQueued(first, reason: .uncertain)
        chat.editQueued(second, in: session); session.draft = "edited second"; chat.queue(session)
        chat.requireTerminalAttention(session, status: "Inspect delivery")
        chat.retryChat(session); chat.resumeQueue(session)
        XCTAssertEqual(session.queuedMessages[0].pause, .uncertain)
        session.busy = false
        chat.sendNow(session, queuedID: first)
        XCTAssertNil(session.submissionID)
        chat.removeQueued(first, from: session)
        XCTAssertNil(session.queuePaused)
        XCTAssertNotNil(session.queueWaiting, "Removing the failed head immediately attempts the next message")
        XCTAssertEqual(session.queuedMessages.map(\.text), ["edited second"])
    }

    func testRequeueRetargetsOnlyEditedMessageAfterConversationChange() throws {
        let (chat, session) = try queuedFixture()
        session.resetConversation(); session.sessionID = "replacement"; session.busy = true
        let first = session.queuedMessages[0].id, second = session.queuedMessages[1].id
        chat.editQueued(second, in: session); session.draft = "new conversation input"; chat.queue(session)
        XCTAssertFalse(session.queuedMessages[0].matches(session))
        XCTAssertEqual(session.queuedMessages[0].pause, .destinationChanged)
        XCTAssertTrue(session.queuedMessages[1].matches(session))
        XCTAssertNil(session.queuedMessages[1].pause)
        chat.resumeQueue(session)
        XCTAssertNotNil(session.queuePaused)
        chat.sendNow(session, queuedID: first)
        XCTAssertNil(session.submissionID)
        chat.removeQueued(first, from: session)
        XCTAssertNil(session.queuePaused)
    }

    func testConversationBindingDetectsChangeWithoutResetAndAllowsInitialAdoption() throws {
        let (chat, session) = try queuedFixture()
        session.sessionID = "different"; session.busy = false
        chat.drainQueue(session)
        XCTAssertEqual(session.queuedMessages[0].pause, .destinationChanged)
        session.queuedMessages = []; session.sessionID = nil; session.busy = true
        session.draft = "first conversation"; chat.queue(session)
        session.sessionID = "initial"
        XCTAssertTrue(session.queuedMessages[0].matches(session))
        session.resetConversation()
        XCTAssertFalse(session.queuedMessages[0].matches(session))
    }

    func testResumeAfterStopPreservesUncertainMessages() throws {
        let (chat, session) = try queuedFixture()
        session.pauseQueued(session.queuedMessages[1].id, reason: .uncertain)
        session.stopQueue()
        XCTAssertEqual(session.queuedMessages[0].pause, .stopped)
        chat.resumeQueue(session)
        XCTAssertNil(session.queuedMessages[0].pause)
        XCTAssertEqual(session.queuedMessages[1].pause, .uncertain)
    }

    func testIdleComposerSubmissionSkipsQueueUI() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.showChat = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        session.draft = "send directly"

        // This fixture deliberately has no terminal target. Direct delivery
        // therefore preserves the draft with an error; the old queue-first
        // path left the same message visible as a queued card instead.
        chat.sendFromComposer(session)

        XCTAssertTrue(session.queuedMessages.isEmpty)
        XCTAssertNil(session.queuePaused)
        XCTAssertEqual(session.draft, "send directly")
        XCTAssertNotNil(session.submissionFailure)
    }

    func testEditingKeepsOrderAndCancelRestoresOriginal() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.busy = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        for text in ["first", "second", "/status"] { session.draft = text; chat.queue(session) }
        let ids = session.queuedMessages.map(\.id)
        XCTAssertTrue(session.queuedMessages[2].isCommand)
        chat.editQueued(ids[1], in: session)
        session.draft = "changed second"
        chat.sendFromComposer(session)
        XCTAssertEqual(session.queuedMessages.map(\.id), ids)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "changed second", "/status"])
        XCTAssertNil(session.editingQueuedID)
        chat.editQueued(ids[0], in: session)
        session.draft = "cancelled change"
        chat.cancelQueuedEdit(session)
        XCTAssertEqual(session.queuedMessages.first?.text, "first")
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.queuedMessages.map(\.id), ids)
    }

    func testCommandCompletionAndQueueNavigationDoNotSubmit() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.busy = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        // The commands the helper's Codex harness reports (chat.history commands).
        session.helperCommands = ["/btw", "/side", "/fast", "/compact", "/rename", "/init", "/review", "/stop", "/copy", "/model",
                                  "/plan", "/goal", "/clear", "/status", "/terminal", "/hooks", "/permissions", "/resume", "/exit", "/quit"]
        session.draft = "queued"; chat.queue(session)
        let editor = ChatComposer.ComposerTextView()
        editor.session = session
        let window = NSWindow()
        defer { window.orderOut(nil) }
        editor.keyDown(with: TerminalTestSupport.keyEvent(126, "", in: window))
        XCTAssertEqual(session.selectedQueuedID, session.queuedMessages[0].id)
        editor.keyDown(with: TerminalTestSupport.keyEvent(125, "", in: window))
        XCTAssertNil(session.selectedQueuedID)
        session.draft = "/bt"; editor.string = "/bt"
        var sends = 0; editor.submit = { sends += 1 }
        editor.keyDown(with: TerminalTestSupport.keyEvent(48, "\t", in: window))
        XCTAssertEqual(session.draft, "/btw ")
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(session.matchingCommands.isEmpty)
    }
    func testMultilineControlReturnUsesSubmissionRoutingThroughAppKit() async throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.showChat = true; session.busy = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await TestSupport.eventually { window.firstResponder is ChatComposer.ComposerTextView }
        let editor = try XCTUnwrap(window.firstResponder as? ChatComposer.ComposerTextView)
        // Control-Return can carry LF and keypad Enter ETX instead of CR.
        for (code, characters): (UInt16, String) in [(36, "\n"), (76, "\u{3}")] {
            let message = "message \(code)\nsecond line"
            session.draft = message
            try await TestSupport.eventually { editor.string == message }
            NSApp.sendEvent(TerminalTestSupport.keyEvent(code, characters, in: window, modifiers: .control, ignoringModifiers: "\r"))
            XCTAssertEqual(session.draft, "")
            XCTAssertFalse(session.drafts.current.multiline)
            XCTAssertEqual(session.queuedMessages.last?.text, message)
        }
        XCTAssertEqual(session.queuedMessages.count, 2)
        session.draft = "/terminal"; session.drafts.edit(multiline: true)
        try await TestSupport.eventually { editor.string == "/terminal" }
        XCTAssertTrue(editor.performKeyEquivalent(with: TerminalTestSupport.keyEvent(36, "\n", in: window, modifiers: .control)))
        XCTAssertTrue(session.showChat, "A multiline /terminal is literal text")
        XCTAssertEqual(session.queuedMessages.last?.text, "/terminal")
        XCTAssertEqual(session.queuedMessages.count, 3)
        XCTAssertTrue(session.queuedMessages.last?.delivery?.draft.multiline == true)
        session.draft = "/terminal"
        chat.sendFromComposer(session)
        XCTAssertFalse(session.showChat, "A fresh compact buffer still supports commands")
        XCTAssertEqual(session.queuedMessages.count, 3)
    }

    func testMultilineSlashAndBangStayLiteralAcrossQueueEditingAndDelivery() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        session.active = true; session.showChat = true; session.busy = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        for text in ["/new", "/terminal\nquoted text", "/model", "!echo example"] {
            session.draft = text
            session.drafts.edit(multiline: true)
            XCTAssertFalse(session.draftIsCommand)
            chat.sendFromComposer(session)
            XCTAssertEqual(session.queuedMessages.last?.text, text)
            XCTAssertTrue(session.showChat)
            XCTAssertNil(session.command)
            XCTAssertNil(session.commandResult)
        }
        let first = try XCTUnwrap(session.queuedMessages.first)
        chat.editQueued(first.id, in: session)
        XCTAssertEqual(session.draft, "/new")
        XCTAssertTrue(session.drafts.current.multiline)
        XCTAssertFalse(session.draftIsCommand)
        chat.queue(session)
        session.busy = false
        session.draft = "trigger draining"; chat.queue(session)
        // No terminal exists: wait without executing /terminal or requiring an edit.
        XCTAssertNil(session.queuePaused)
        XCTAssertNotNil(session.queueWaiting)
        XCTAssertTrue(session.showChat)
        XCTAssertEqual(session.queuedMessages.first?.text, "/new")
        XCTAssertNil(session.command)
        session.showOptimisticPrompt("/new")
        XCTAssertEqual(session.optimisticPrompt?.text, "/new")
    }

    func testQueueTipKeepsTheContainingWindowSize() async throws {
        let previous = ChatThemeStore.shared.current
        defer { ChatThemeStore.shared.current = previous }
        var configured = ChatTheme.standard
        configured.typography = ChatTypography(preferences: Preferences())
        for theme in [ChatTheme.standard, configured] {
            ChatThemeStore.shared.current = theme
            let chat = ChatCoordinator(enabled: true)
            let session = chat.session(for: UUID())
            session.active = true; session.showChat = true; session.busy = true
            session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
            window.contentView = content; window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await TestSupport.eventually { !PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: content).isEmpty }
            let size = content.bounds.size
            for text in ["first", "second", "third"] { session.draft = text; chat.queue(session) }
            try await TestSupport.eventually { chat.queueTipShown }
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second", "third"])
            XCTAssertEqual(content.bounds.size, size)
            XCTAssertLessThanOrEqual(window.contentMinSize.height, size.height)
        }
    }

    func testDraggingQueueHandleReordersWithoutPasteboard() async throws {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        session.active = true; session.showChat = true; session.busy = true
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
        window.contentView = content; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await TestSupport.eventually { !PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: content).isEmpty }
        for text in ["first", "second", "third"] { session.draft = text; chat.queue(session) }
        let ids = session.queuedMessages.map(\.id)
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(chat.canReorderQueue(session))
        func handle(_ id: UUID) -> ReorderTrackingView? {
            PresentationTestSupport.views(of: ReorderTrackingView.self, in: content).first { $0.configuration.item == .queued(id) }
        }
        try await TestSupport.eventually { content.layoutSubtreeIfNeeded(); return ids.allSatisfy { handle($0) != nil } }
        let source = try XCTUnwrap(handle(ids[0])), target = try XCTUnwrap(handle(ids[2]))
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let end = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.maxY - 1), to: nil)
        var events = [mouse(.leftMouseDragged, end), mouse(.leftMouseUp, end)]
        source.trackMouse(with: mouse(.leftMouseDown, start)) { events.isEmpty ? nil : events.removeFirst() }
        XCTAssertEqual(session.queuedMessages.map(\.text), ["second", "third", "first"])
    }

    func testReturnAndKeypadEnterQueueWhileBusyAndCheckingActivity() async throws {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        session.active = true; session.showChat = true; session.busy = true
        session.version = "0.153.4"; session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // A helper chat whose agent the helper has not bound: rows stay here, sends are refused (draft kept).
        session.helper = HelperChat(terminal: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChatView(session: session, coordinator: chat, focused: true, floatingSwitch: false))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: try XCTUnwrap(window.contentView)).first)
        for (code, text) in [(UInt16(36), "first"), (UInt16(76), "second")] {
            session.draft = text
            editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)))
            XCTAssertEqual(session.draft, "")
        }
        XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second"])
        XCTAssertTrue(session.busy)
        XCTAssertNil(session.submissionID)
        session.draft = "from Send"
        try await Task.sleep(for: .milliseconds(150))
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        func clickReply(_ title: String, in snapshot: PresentationTestSupport.Snapshot) throws {
            let content = try XCTUnwrap(window.contentView)
            let box = try XCTUnwrap(try snapshot.recognizedText().filter {
                $0.topCandidates(1).first?.string.hasPrefix(title) == true
            }.max { $0.boundingBox.minX < $1.boundingBox.minX }).boundingBox
            let point = NSPoint(x: box.midX * content.bounds.width,
                y: (content.isFlipped ? 1 - box.midY : box.midY) * content.bounds.height)
            try PresentationTestSupport.click(window, at: content.convert(point, to: nil))
        }
        try clickReply("Queue", in: await PresentationTestSupport.capture(window))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.draft, "")
        XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second", "from Send"])
        session.draft = "send immediately"
        func option(_ pressed: Bool) throws {
            NSApp.postEvent(try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
                modifierFlags: pressed ? .option : [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)), atStart: false)
        }
        try option(true)
        try await Task.sleep(for: .milliseconds(150))
        let held = try await PresentationTestSupport.capture(window, named: "option-held", in: "chat-queue-validation")
        XCTAssertTrue(try held.text().contains("Steer"))
        try clickReply("Steer", in: held)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.queuedMessages.count, 3, "Option-click must bypass the queue")
        XCTAssertEqual(session.draft, "send immediately", "This fixture has no terminal, so immediate delivery preserves the draft")
        XCTAssertNotNil(session.submissionFailure, "The button must attempt immediate delivery")
        try option(false)
        try await Task.sleep(for: .milliseconds(150))
        let released = try await PresentationTestSupport.capture(window, named: "option-released", in: "chat-queue-validation")
        XCTAssertTrue(try released.text().contains("Queue"))
        XCTAssertFalse(try released.text().contains("Steer"))
        session.busy = false; session.loadingHistory = true
        session.draft = "third"; chat.sendFromComposer(session)
        XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second", "from Send", "third"])
        editor.string = "line"; editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))
        XCTAssertEqual(editor.string, "line\n")
        XCTAssertEqual(session.queuedMessages.count, 4)
    }

    func testQueueEditingValidationAndConversationReplacement() throws {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        session.draft = "preserved"
        chat.queue(session)
        XCTAssertEqual(session.draft, "preserved"); XCTAssertTrue(session.queuedMessages.isEmpty)
        session.active = true; session.busy = true; session.version = "0.153.4"
        session.process = try XCTUnwrap(AgentProcess.capture(getpid()))
        // Queueing belongs to a helper chat; terminal 0 is no helper terminal (only the app's queue state).
        session.helper = HelperChat(terminal: 0)
        for text in ["first", "second\nline"] { session.draft = text; chat.queue(session) }
        XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second\nline"])
        XCTAssertEqual(session.draft, "")
        let first = session.queuedMessages[0].id
        session.draft = "unfinished draft"
        chat.editQueued(first, in: session)
        XCTAssertEqual(session.draft, "unfinished draft"); XCTAssertEqual(session.queuedMessages.count, 2)
        session.draft = ""; chat.editQueued(first, in: session)
        XCTAssertEqual(session.draft, "first"); XCTAssertEqual(session.queuedMessages.map(\.text), ["first", "second\nline"])
        XCTAssertEqual(session.editingQueuedID, first)
        session.resetConversation()
        XCTAssertNotNil(session.queuePaused); XCTAssertEqual(session.queuedMessages.count, 2)
        chat.removeQueued(session.queuedMessages[0].id, from: session)
        chat.removeQueued(session.queuedMessages[0].id, from: session)
        XCTAssertNil(session.queuePaused)
        for text in ["!echo hello", "bad\u{1b}input", "  \n"] {
            session.version = "0.153.4"; session.draft = text; chat.queue(session)
            XCTAssertEqual(session.draft, text); XCTAssertTrue(session.queuedMessages.isEmpty)
        }
    }

    func testExistingDirectCodexAttachShowsSwitchAndControlReturnQueuesInOrder() async throws {
        let endpoint = try CodexEndpointFixture(prefix: "dispatch-queue-", delay: 0.25, hooks: false)
        var passed = false
        defer { endpoint.stop(removeState: passed) }
        try await endpoint.start(timeout: .seconds(15))
        let runtime = TerminalRuntime.shared, previous = runtime.chat
        runtime.chat = ChatCoordinator()
        defer { runtime.chat = previous }
        let app = try TmuxWalkthrough(autoClose: true, liquidGlass: false) // Reads the queue through offscreen captures.
        defer { app.close() }
        runtime.chat.setHelperIntegration("codex", enabled: false)
        await runtime.chat.integrationChanges?.value
        let command = CodexTestSupport.command(state: endpoint.state, binary: endpoint.binary)
        // Codex itself is the pane's initial process, already running before
        // Dispatch attaches; no inherited app environment or hooks are required.
        _ = try app.server(["respawn-pane", "-k", "-t", "%0", "exec " + command])
        try await TestSupport.eventually(timeout: .seconds(15)) {
            try app.server(["capture-pane", "-p", "-t", "%0"]).contains("dispatch-fixture default")
        }
        _ = try app.server(["send-keys", "-l", "-t", "%0", "existing conversation"])
        try await Task.sleep(for: .milliseconds(250))
        _ = try app.server(["send-keys", "-t", "%0", "Enter"])
        try await TestSupport.eventually(timeout: .seconds(15)) {
            try app.server(["capture-pane", "-p", "-t", "%0"]).contains("Local fixture reply: existing conversation")
        }
        try await app.attach(); try await app.ready()
        let chat = runtime.chat, session = chat.session(for: try XCTUnwrap(app.workspace.activeSurfaceID))
        try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Existing Codex must be discoverable without hooks") {
            session.active && session.sessionID != nil && !session.loadingHistory && !session.busy
        }
        XCTAssertTrue(chat.canEnterChat(session))
        XCTAssertEqual(chat.hookStatus("codex"), .off, "Discovered without the codex integration")
        XCTAssertFalse(app.workspace.allTabIDs.contains(try XCTUnwrap(app.origin?.id)))
        chat.chooseChat(false, session: session)
        try await Task.sleep(for: .milliseconds(350))
        _ = try await PresentationTestSupport.capture(app.window, named: "existing-tmux-codex", in: "chat-queue-validation")
        XCTAssertEqual(PresentationTestSupport.accessibilityFrames("chat-mode-switch", label: "Show Chat", in: app.window).filter { !$0.isEmpty }.count, 1,
                       "The mode switch must render on an already-running Codex terminal")
        chat.chooseChat(true, session: session)
        try await TestSupport.eventually { app.window.firstResponder is ChatComposer.ComposerTextView }
        session.draft = "wait while I queue"; chat.submit(session)
        XCTAssertEqual(session.visibleTranscriptRows.last?.item?.text, "wait while I queue")
        XCTAssertNotNil(session.optimisticPrompt, "The bubble must appear before any asynchronous transcript response")
        try await TestSupport.eventually { session.busy && !session.awaitingPromptAck }
        for text in ["queued first", "remove this", "queued second\nwith newline"] {
            session.draft = text
            try await TestSupport.eventually { (app.window.firstResponder as? NSTextView)?.string == text }
            NSApp.sendEvent(TerminalTestSupport.keyEvent(36, "\r", in: app.window, modifiers: .control))
            XCTAssertEqual(session.draft, "")
        }
        XCTAssertEqual(session.queuedMessages.count, 3)
        // A history refresh before input starts is retryable. Finishing it and
        // clearing attention must deliver each queued prompt exactly once.
        session.loadingHistory = true
        chat.sendNow(session, queuedID: session.queuedMessages[0].id)
        session.loadingHistory = false
        XCTAssertNil(session.queuePaused)
        XCTAssertNotNil(session.queueWaiting)
        chat.requireTerminalAttention(session, status: "Temporary readiness check")
        XCTAssertNil(session.queuePaused)
        chat.retryChat(session)
        chat.removeQueued(session.queuedMessages[1].id, from: session)
        session.draft = "draft survives queue delivery"
        let queued = try await PresentationTestSupport.capture(app.window, named: "queued-messages", in: "chat-queue-validation")
        XCTAssertTrue(try queued.text().contains("queued"))
        try await TestSupport.eventually(timeout: .seconds(25)) {
            session.queuedMessages.isEmpty && !session.busy && session.turns.flatMap(\.items).contains {
                $0.text == "Local fixture reply: queued second\nwith newline"
            }
        }
        let prompts = session.turns.flatMap(\.items).filter { $0.kind == .user }.map(\.text)
        XCTAssertEqual(prompts, ["existing conversation", "wait while I queue", "queued first", "queued second\nwith newline"])
        XCTAssertEqual(session.draft, "draft survives queue delivery")
        XCTAssertNil(session.queuePaused)
        let conversation = session.sessionID
        for source in ["/terminal\nλ😀", "!printf LITERAL_PREFIX_SAMPLE\n```\n~~~"] {
            session.draft = source
            let delivered = AgentInput.fenced(source)
            chat.sendFromComposer(session)
            XCTAssertTrue(session.showChat)
            try await TestSupport.eventually(timeout: .seconds(15), diagnostic: "Literal delivery: \(session.queuePaused ?? session.submissionFailure ?? "pending")") {
                !session.busy && session.queuedMessages.isEmpty && session.turns.flatMap(\.items).contains {
                    $0.kind == .assistant && $0.text == "Local fixture reply: " + delivered
                }
            }
            XCTAssertEqual(session.sessionID, conversation)
            XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.kind == .user && $0.text == delivered })
            XCTAssertNil(session.optimisticPrompt)
            XCTAssertNil(session.queuePaused)
        }
        passed = true
    }

    func testExplicitChatOptOutIsPreservedWithoutHooks() throws {
        let domain = "dispatch-chat-opt-out-" + UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: "agentChatEnabled")
        XCTAssertFalse(ChatCoordinator(defaults: defaults).enabled)
        defaults.removeObject(forKey: "agentChatEnabled")
        XCTAssertTrue(ChatCoordinator(defaults: defaults).enabled)
    }

    func testChatSwitchUsesShiftCommandC() throws {
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        let controller = AppDelegate(); controller.buildMenus()
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        let item = try XCTUnwrap(view.items.first { $0.title == "Switch Terminal / Chat" })
        XCTAssertEqual(item.keyEquivalent, "C"); XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        // ⇧⌘C must not shadow another menu command.
        let others = (NSApp.mainMenu?.items ?? []).compactMap(\.submenu).flatMap(\.items).filter { $0 !== item && !$0.isHidden }
        XCTAssertFalse(others.contains { $0.keyEquivalent.lowercased() == "c" && $0.keyEquivalentModifierMask == [.command, .shift] })
    }

}
