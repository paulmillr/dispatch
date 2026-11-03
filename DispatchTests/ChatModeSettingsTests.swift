import XCTest
@testable import DispatchApp

/// Settings › Features › Chat mode's options: Open agents in, Esc stops the agent, Tool steps, Double ⌃D.
@MainActor final class ChatModeSettingsTests: XCTestCase {
    func testOlderSettingsKeepTodaysBehaviourAndChoicesRoundTrip() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.chatAgentStart, .chat)
        XCTAssertEqual(old.chatEscapeStop, .once)
        XCTAssertEqual(old.chatToolSteps, .current)
        XCTAssertTrue(old.chatControlDExits)
        var changed = Preferences()
        changed.chatAgentStart = .terminal
        changed.chatEscapeStop = .twice
        changed.chatToolSteps = .all
        changed.chatControlDExits = false
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed)), changed)
    }

    func testTerminalStartKeepsTheLaunchCoverAway() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        let session = chat.session(for: System.uuid())
        chat.agentStart = .terminal
        chat.terminalSubmitted("codex", tab: session.id)
        XCTAssertNil(session.launchingAgent, "the terminal stays in front: nothing covers it for Chat")
        chat.agentStart = .chat
        chat.terminalSubmitted("codex", tab: session.id)
        XCTAssertEqual(session.launchingAgent, "codex")
    }

    func testEscapeTwiceArmsTheStopFirst() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        let session = chat.session(for: System.uuid())
        session.active = true; session.showChat = true; session.busy = true
        session.helper = HelperChat(terminal: 0)
        chat.escapeStop = .twice
        XCTAssertTrue(chat.escapeStop(session, at: 10))
        XCTAssertEqual(session.stopArmedAt, 10)
        XCTAssertNil(session.interruptionID, "the first Esc stops nothing")
        XCTAssertTrue(chat.escapeStop(session, at: 11.5))
        XCTAssertEqual(session.stopArmedAt, 11.5, "a late second press arms again")
        XCTAssertNil(session.interruptionID)
        session.busy = false
        XCTAssertFalse(chat.escapeStop(session, at: 12), "nothing to stop: Esc goes on as usual")
        XCTAssertNil(session.stopArmedAt)
    }

    func testToolStepsSetHowGroupsStartUntilTheUserChooses() {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        let session = chat.session(for: System.uuid())
        let group = ChatToolGroup(id: "g", children: [])
        XCTAssertEqual(session.groupDisclosure(group, turnID: nil), .collapsed, "a finished group starts collapsed")
        chat.toolSteps = .all
        XCTAssertEqual(session.toolSteps, .all, "every chat takes the setting")
        XCTAssertEqual(session.groupDisclosure(group, turnID: nil), .all)
        session.setGroupExpanded(group, false)
        XCTAssertEqual(session.groupDisclosure(group, turnID: nil), .collapsed, "the user's choice wins")
        XCTAssertEqual(chat.session(for: System.uuid()).toolSteps, .all, "and new chats start with it")
    }
}
