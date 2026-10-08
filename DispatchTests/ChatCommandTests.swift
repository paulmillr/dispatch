import AppKit
import XCTest
@testable import DispatchApp

@MainActor
final class ChatCommandTests: XCTestCase {
    /// A command-looking first line is a command only in a one-line draft; the harness fences a literal
    /// message (ChatQueueTests and ClaudeChatIntegrationTests check the delivered text).
    func testMultilinePrefixesAreMessagesAndNativeDeliveryQuotesThem() throws {
        for source in ["/new", "/terminal\nquoted text", "!echo example", "  /model\n", "!λ😀\n```\n~~~\n~~~~\n"] {
            XCTAssertTrue(AgentInput.isCommand(source))
            XCTAssertFalse(AgentInput.isCommand(source, multiline: true))
        }
        for source in ["ordinary message", "prose\n/terminal", "```sh\n!echo example\n```"] {
            XCTAssertFalse(AgentInput.isCommand(source))
        }
    }

    func testExactCommandFormsAndArguments() {
        XCTAssertEqual(ChatCommand(" /fast \n"), .fast)
        XCTAssertNil(ChatCommand("/fast on"))
        XCTAssertNil(ChatCommand("/model custom"))
        XCTAssertNil(ChatCommand("/status anything"))
        XCTAssertEqual(ChatCommand("/review inspect changes"), .review("inspect changes"))
        XCTAssertEqual(ChatCommand("/plan explain first"), .plan("explain first"))
        XCTAssertEqual(ChatCommand("/goal pause"), .goal("pause"))
        XCTAssertEqual(ChatCommand("/clear new topic"), .clear("new topic"))
        XCTAssertEqual(ChatCommand("/new"), .clear(""))
        XCTAssertNil(ChatCommand("/new topic"))
        XCTAssertNil(ChatCommand("/fork now"))
        XCTAssertTrue(ChatCommand.fork.replacesConversation)
        // Only the bare form opens the session picker; an argument names the conversation (Claude).
        XCTAssertEqual(ChatCommand("/resume"), .resume)
        XCTAssertNil(ChatCommand("/resume 0b6f2a1e"))
        XCTAssertTrue(ChatCommand.resume.opensTerminal)
        XCTAssertFalse(ChatCommand.resume.startsTurn)
        XCTAssertFalse(ChatCommand.resume.allowsBusy)
        XCTAssertFalse(ChatCommand.status.opensTerminal)
        XCTAssertFalse(ChatCommand.fast.startsTurn)
        XCTAssertTrue(ChatCommand.compact.startsTurn)
        XCTAssertFalse(ChatCommand.clear("").allowsBusy)
        XCTAssertTrue(ChatCommand.goal("pause").allowsBusy)
    }

    /// The chat shows the conversation's model, effort and goal from the helper's State
    /// (which thread a transcript event belongs to is the codex harness's history reader).
    func testSettingsAndGoalEventsAreBoundToTheirConversation() throws {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.helper = HelperChat(terminal: 0)
        func state(_ fields: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: ["busy": false, "pending": false, "compacting": false].merging(fields) { $1 })
            coordinator.receiveHelper(.state(try JSONDecoder().decode(HelperChat.State.self, from: data)), session: session)
        }
        let goal = #"{"objective":"Finish tests","status":"paused","tokensUsed":15,"timeUsedSeconds":0}"#
        try state(["model": "test-model", "effort": "high", "goal": goal])
        XCTAssertEqual(session.model, "test-model"); XCTAssertEqual(session.effort, "high")
        XCTAssertEqual(session.goal?.objective, "Finish tests")
        XCTAssertEqual(session.goal?.status, "paused")
        try state(["model": "test-model", "effort": "high"])
        XCTAssertNil(session.goal); XCTAssertEqual(session.goalRevision, 2)
    }

    /// A terminal surface the helper cannot drive (State.attention) keeps the chat shown and the draft
    /// editable, but blocks sending until the terminal is handled.
    func testUnrecognizedConfirmationKeepsChatAndEditableDraft() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.helper = HelperChat(terminal: 0)
        session.active = true
        chat.chooseChat(true, session: session)
        session.draft = "unfinished thought"
        let state = #"{"busy":false,"pending":false,"compacting":false,"attention":"Codex is waiting in the terminal."}"#
        chat.receiveHelper(.state(try JSONDecoder().decode(HelperChat.State.self, from: Data(state.utf8))), session: session)
        XCTAssertTrue(session.showChat)
        XCTAssertTrue(session.manualViewChoice)
        XCTAssertTrue(session.inputBlocked)
        XCTAssertNotNil(session.terminalAttention)
        session.draft += " with more text"
        XCTAssertEqual(session.draft, "unfinished thought with more text")
        XCTAssertEqual(session.viewTransitions.count, 1)
    }

    func testTransientDialogPreservesPendingCommandOutput() throws {
        let chat = ChatCoordinator(enabled: true)
        let session = chat.session(for: UUID())
        defer { chat.close(session.id) }
        session.observedCommand = (title: "/mcp", output: nil)
        session.awaitingPromptAck = true
        // full023: Claude publishes a transient dialog, idle, then the command's output.
        for state in [#"{"busy":true,"pending":false,"compacting":false,"dialog":"dialog open"}"#,
                      #"{"busy":false,"pending":false,"compacting":false}"#] {
            chat.receiveHelper(.state(try JSONDecoder().decode(HelperChat.State.self, from: Data(state.utf8))), session: session)
        }
        chat.receiveHelper(.records([.init(id: "output", turn: "command", kind: "output", text: "No MCP servers configured.",
            title: "", output: "", blocks: [], completed: true, exit_code: nil, patch: nil, time_ms: nil,
            documents: [], tool: nil, inline_reasoning: false)]), session: session)
        XCTAssertEqual([session.observedCommand?.title, session.commandResult?.title,
                        session.commandResult?.text, session.terminalAttention],
                       [nil, "/mcp", "No MCP servers configured.", nil])
        XCTAssertFalse(session.awaitingPromptAck)
    }

    /// The helper reports a new conversation on the same agent (/clear): the old conversation's draft is
    /// kept for it, the new one starts empty, and messages queued for the old one wait for review.
    func testClearPreservesTargetAndPreviousConversationDraftButPausesOldQueue() throws {
        let coordinator = ChatCoordinator(enabled: true)
        let session = coordinator.session(for: UUID())
        session.helper = HelperChat(terminal: 0)
        let process = try XCTUnwrap(AgentProcess.capture(getpid()))
        session.process = process
        session.active = true; session.sessionID = UUID().uuidString
        session.draft = "next draft"; session.showChat = true
        let previousScope = session.drafts.scope
        session.queuedMessages = [.init(text: "old queued message", process: process)]
        session.insert(.init(id: "old", kind: .assistant, text: "Old response"), turnID: "old")
        let newID = UUID().uuidString
        let binding: [String: Any] = ["session": newID, "transcript": NSNull(), "pid": process.pid,
                                      "start": [process.startedSeconds, process.startedMicroseconds], "executable": process.executable]
        let history: [String: Any] = ["terminal": 0, "binding": binding, "session": newID, "key": "codex", "label": "Codex",
                                      "commands": [String](), "native_queue": false, "records": [Any](), "history_pending": false, "capabilities": [String]()]
        let page = try JSONDecoder().decode(HelperChat.History.self, from: JSONSerialization.data(withJSONObject: history))
        coordinator.receiveHelper(.history(page), session: session)
        XCTAssertEqual(session.sessionID, newID); XCTAssertEqual(session.process, process)
        XCTAssertEqual(session.draft, ""); XCTAssertTrue(session.showChat)
        XCTAssertEqual(session.drafts.repository.buckets[previousScope]?.working.text, "next draft")
        XCTAssertTrue(session.turns.isEmpty); XCTAssertNil(session.transcriptPath)
        XCTAssertNotNil(session.queuePaused); XCTAssertEqual(session.queuedMessages.count, 1)
        XCTAssertFalse(session.busy); XCTAssertFalse(session.awaitingPromptAck)
    }
    func testReviewChildActivityCompletesWithTheParent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("review.jsonl")
        let helper = HelperChat(archive: .init(key: "codex", path: path.path, session: "session"))
        let coordinator = ChatCoordinator(enabled: false)
        let session = coordinator.session(for: UUID())
        defer { coordinator.close(session.id) }
        session.active = true
        let payloads: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "session"]],
            ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "review", "item": ["type": "EnteredReviewMode"]]],
            ["type": "event_msg", "payload": ["type": "task_started", "turn_id": "child"]],
            ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "review", "item": ["type": "ExitedReviewMode"]]],
            ["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "review"]]
        ]
        var data = Data()
        for (index, value) in payloads.enumerated() {
            data.append(try JSONSerialization.data(withJSONObject: value)); data.append(10)
            try data.write(to: path)
            let page = try await helper.page(earlier: nil)
            coordinator.receiveHelper(.records(page.records), session: session)
            if index == 2 {
                XCTAssertTrue(session.busy)
                XCTAssertEqual(session.activeTurnID, "review")
            }
        }
        XCTAssertFalse(session.busy)
        XCTAssertEqual(session.turns.map(\.id), ["review"])
    }

}

@MainActor
extension ChatModelPickerTests {
    func exerciseCommands(_ session: ChatSession, terminal: TerminalView, coordinator: ChatCoordinator, state: URL, backend: String) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        var phase = "initial", timings: [[String: Any]] = []
        defer {
            let output = CodexTestSupport.root.appendingPathComponent("build/chat-command-timing-validation")
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ["backend": backend, "waits": timings,
                    "totalSeconds": ProcessInfo.processInfo.systemUptime - started], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(backend + ".json"))
            } catch { XCTFail("Cannot preserve command timing: \(error)") }
        }
        // Native menus (review presets, plan questions, goal prompts) reach the chat as the helper's blocking
        // choice questions; native text editors (/rename, /goal edit) as typed questions.
        func menu() -> PendingApproval? { session.approvals.last { $0.pending && $0.questions != nil } }
        func wait(_ condition: () -> Bool) async throws {
            let started = ProcessInfo.processInfo.systemUptime
            func record(_ passed: Bool) {
                timings.append(["phase": phase, "passed": passed,
                    "seconds": ProcessInfo.processInfo.systemUptime - started, "index": timings.count])
            }
            do {
                try await TestSupport.eventually(timeout: .seconds(12), diagnostic:
                    "phase=\(phase) goal=\(String(describing: session.goal)) session=\(session.sessionID ?? "nil") route=\(session.helper?.route.session ?? "nil") loading=\(session.loadingHistory) binding=\(String(describing: session.binding)) command=\(String(describing: session.command?.command)) result=\(String(describing: session.commandResult)) busy=\(session.busy) ack=\(session.awaitingPromptAck) observed=\(String(describing: session.observedCommand)) failure=\(session.submissionFailure ?? "nil") native=\(session.nativeInputInFlight) turn=\(session.activeTurnID ?? "nil") boundary=\(String(describing: session.promptBoundary)) chat=\(session.showChat) menu=\(menu()?.operation ?? "none") questions=\(session.questions.map(\.question.question))\n\(terminal.agentMenuScreen)", condition)
                record(true)
            } catch {
                record(false)
                throw error
            }
        }
        func showing(_ title: String) -> Bool {
            menu()?.questions?.questions.contains { $0.text.contains(title) || $0.header.contains(title) } == true
        }
        func choose(_ number: Int) {
            guard let menu = menu(), let question = menu.questions?.questions.first, question.options.indices.contains(number - 1) else {
                return XCTFail("No native menu with option \(number) (\(phase))")
            }
            menu.answer([question.text: question.options[number - 1].label])
        }
        var idle: Bool { menu() == nil && session.questions.isEmpty }
        func edit(_ text: String) async throws {
            try await wait { session.questions.contains { $0.question.allowsCustom } }
            let question = try XCTUnwrap(session.questions.first { $0.question.allowsCustom })
            question.type(text); coordinator.answerQuestion(question, skip: false, session: session)
        }
        func command(_ text: String) async throws {
            phase = text
            try await wait {
                session.activityCheck == nil && !session.loadingHistory && session.submissionID == nil
                    && (!session.busy || ChatCommand(text)?.allowsBusy == true)
                    && !session.nativeInputInFlight && idle
            }
            session.draft = text; coordinator.submit(session)
            coordinator.submit(session) // Repeated Send must not toggle or deliver twice.
            try await wait { session.command == nil }
            XCTAssertTrue(session.showChat, text)
            XCTAssertEqual(session.draft, "", text)
            XCTAssertFalse(session.awaitingPromptAck, "\(text) command=\(String(describing: session.command?.command)) observed=\(String(describing: session.observedCommand)) questions=\(session.questions.count) approvals=\(session.approvals.filter(\.pending).count) failure=\(session.submissionFailure ?? "nil")")
        }
        // A setter with arguments it does not take keeps the draft and starts no work.
        phase = "unsupported setter arguments"
        session.submissionFailure = "An earlier failed send"
        session.draft = "/fast on"; coordinator.submit(session)
        XCTAssertNil(session.submissionFailure, "A new explicit command replaces prior send feedback")
        try await wait { session.command == nil && session.submissionID == nil && session.commandResult != nil }
        XCTAssertEqual(session.draft, "/fast on")
        XCTAssertEqual(session.commandResult?.title, "Command arguments")
        XCTAssertFalse(session.busy)
        session.draft = ""
        try await command("/fast")
        XCTAssertEqual(session.serviceTier, "priority")
        try await command("/fast")
        XCTAssertNotEqual(session.serviceTier, "priority")
        try await command("/status")
        XCTAssertEqual(session.commandResult?.title, "Session status")
        XCTAssertTrue(session.commandResult?.text.contains(session.sessionID!) == true)
        try await command("/rename Command fixture")
        XCTAssertEqual(session.threadName, "Command fixture")
        phase = "rename editor"
        session.draft = "/rename"; coordinator.submit(session)
        try await edit("Renamed from chat")
        try await wait { session.command == nil && session.threadName == "Renamed from chat" }
        try await command("/copy")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Local fixture reply: initial picker turn")
        try await command("/compact")
        try await wait { !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Conversation compacted" } }
        XCTAssertTrue(session.turns.flatMap(\.items).contains { $0.text == "Conversation compacted" })
        try await command("/review Inspect the fixture changes")
        try await wait { !session.busy }
        try await command("/review")
        try await wait { showing("Select a review preset") }
        phase = "review selection"
        choose(2)
        try await wait { idle && !session.nativeInputInFlight && !session.busy }
        try await command("/init")
        try await wait { !session.busy }
        try await command("/pwd")
        XCTAssertEqual(session.commandResult?.title, "Working directory")
        XCTAssertTrue(session.commandResult?.text.hasSuffix("/" + state.lastPathComponent + "/work") == true)
        try await command("/mcp")
        XCTAssertEqual(session.commandResult?.text, "• No MCP servers configured.\nSee the MCP docs to configure them.")
        try await command("/recap")
        XCTAssertEqual(session.commandResult?.text, "Fixture recap: the conversation is ready for its next turn.\n\nNext: Send the next fixture prompt.")
        phase = "background tool prompt"
        session.draft = "DISPATCH_BACKGROUND_TOOL"; coordinator.sendFromComposer(session)
        try await wait { !session.busy && session.turns.flatMap(\.items).contains { $0.text.contains("Local fixture reply: DISPATCH_BACKGROUND_TOOL") } }
        let pidFile = state.appendingPathComponent("work/dispatch-background.pid")
        let backgroundPID = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertTrue(AgentProcess.capture(backgroundPID)?.alive == true)
        try await command("/ps")
        XCTAssertEqual(session.commandResult?.title, "Background terminals")
        XCTAssertFalse(session.commandResult?.text.contains("No background terminals running") ?? true)
        try await command("/stop")
        try await wait { AgentProcess.capture(backgroundPID)?.alive != true }
        try await command("/ps")
        XCTAssertEqual(session.commandResult?.text, "• No background terminals running.")
        try await command("/plan")
        XCTAssertEqual(session.collaborationMode, "plan")
        try await command("/plan DISPATCH_PLAN_QUESTION")
        try await wait { menu() != nil }
        XCTAssertTrue(showing("Which approach"))
        phase = "plan question selection"
        choose(2)
        try await wait { !session.busy && idle && !session.nativeInputInFlight }
        try await command("/goal Complete the fixture")
        try await wait { session.goal?.objective == "Complete the fixture" }
        phase = "pause goal button"
        session.draft = "preserved while pausing"
        let window = try XCTUnwrap(terminal.window), content = try XCTUnwrap(window.contentView)
        // Draft changes resize the SwiftUI composer asynchronously. Wait until
        // AppKit has received that revision before taking hit-test coordinates.
        // Otherwise an OCR point from the previous layout may hit the terminal.
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        phase = "pause goal composer readiness"
        try await wait {
            session.command == nil && idle && session.submissionID == nil
                && session.modelPicker == nil && session.active && !session.inputBlocked && !session.loadingHistory
                && session.activityCheck == nil && !session.nativeInputInFlight && !session.approvals.contains(where: \.pending)
                && PresentationTestSupport.views(of: ChatComposer.ComposerTextView.self, in: content)
                    .contains { $0.string == session.draft }
        }
        let previousPointer = CGEvent(source: nil)?.location
        defer { if let previousPointer { CGWarpMouseCursorPosition(previousPointer) } }
        try await PresentationTestSupport.clickGoalAction("Pause", in: window)
        phase = "pause goal button"
        try await wait { session.command == nil && session.goal?.status == "paused" }
        XCTAssertEqual(session.draft, "preserved while pausing")
        session.draft = ""
        try await wait { session.goal?.status == "paused" && !session.busy }
        try await command("/goal")
        XCTAssertTrue(session.commandResult?.text.contains("Complete the fixture") == true)
        phase = "goal editor"
        session.draft = "/goal edit"; coordinator.submit(session)
        try await edit("Finish the edited fixture")
        try await wait { session.command == nil && session.goal?.objective == "Finish the edited fixture" }
        XCTAssertEqual(session.goal?.status, "paused", "Editing must not restart a paused goal")
        if menu() != nil { choose(2) }
        try await wait { session.goal?.objective == "Finish the edited fixture" && idle && !session.nativeInputInFlight }
        phase = "resume goal button"
        try await PresentationTestSupport.clickGoalAction("Resume", in: window)
        try await wait { session.command == nil }
        if menu() != nil { choose(1) }
        try await wait { session.goal?.status == "active" && idle && !session.nativeInputInFlight }
        try await command("/goal pause")
        try await wait { session.goal?.status == "paused" && !session.busy }
        phase = "stop goal button"
        session.draft = "preserved while stopping"
        try await PresentationTestSupport.clickGoalAction("Stop", in: window)
        try await wait { session.command == nil && session.goal == nil }
        XCTAssertEqual(session.draft, "preserved while stopping")
        session.draft = ""
        XCTAssertNil(session.goal)
        try await command("/goal")
        XCTAssertEqual(session.commandResult?.text, "No goal is currently set.")
        try await command("/plan DISPATCH_PROPOSED_PLAN")
        try await wait { showing("Implement this plan?") }
        phase = "implement plan selection"
        choose(1)
        try await wait { idle && !session.nativeInputInFlight && !session.busy && session.collaborationMode == "default" }
        // A fork's rollout refers to its parent; Chat follows the new thread.
        let parentID = session.sessionID
        try await command("/fork")
        XCTAssertNotEqual(session.sessionID, parentID)
        XCTAssertEqual(session.commandResult?.title, "Conversation forked")
        phase = "prompt after forking"
        session.draft = "after forking"; coordinator.sendFromComposer(session)
        try await wait { !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: after forking" } }
        let oldID = session.sessionID
        try await command("/clear")
        XCTAssertNotEqual(session.sessionID, oldID)
        XCTAssertTrue(session.turns.isEmpty)
        phase = "prompt after clearing"
        session.draft = "after clearing"; coordinator.sendFromComposer(session)
        try await wait { !session.busy && session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: after clearing" } }
        XCTAssertNotEqual(session.sessionID, oldID)
        XCTAssertFalse(session.turns.flatMap(\.items).contains { $0.text == "Local fixture reply: initial picker turn" })
        let clearedID = session.sessionID
        try await command("/new")
        XCTAssertNotEqual(session.sessionID, clearedID)
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertEqual(session.commandResult?.title, "New conversation")
        phase = "open model picker"
        session.draft = "/model"; coordinator.submit(session)
        try await wait { session.modelPicker != nil && session.modelPicker?.loading == false }
        XCTAssertNil(session.modelPicker?.error)
        phase = "close model picker"
        coordinator.closeModelPicker(session)
        try await wait { session.modelPicker == nil }
        XCTAssertTrue(session.showChat)
    }
}
