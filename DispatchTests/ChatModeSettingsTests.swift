import XCTest
@testable import DispatchApp

/// Settings › Features › Chat mode's options and the fixed double-Escape stop shortcut.
@MainActor final class ChatModeSettingsTests: XCTestCase {
    func testRemovedKeyboardSettingsAreIgnoredAndCurrentChoicesRoundTrip() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.chatAgentStart, .chat)
        XCTAssertEqual(old.chatToolSteps, .current)
        var changed = Preferences()
        changed.chatAgentStart = .terminal
        changed.chatToolSteps = .all
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed)), changed)
        let removed = try JSONDecoder().decode(Preferences.self, from: Data(#"{"chatEscapeStop":"once","chatControlDExits":false}"#.utf8))
        XCTAssertEqual(removed, old)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(removed)) as? [String: Any])
        XCTAssertNil(encoded["chatEscapeStop"])
        XCTAssertNil(encoded["chatControlDExits"])
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
        defer { chat.stop() }
        let session = chat.session(for: System.uuid())
        session.active = true; session.showChat = true; session.busy = true
        session.helper = HelperChat(terminal: 0)
        session.draft = "Keep this draft"
        XCTAssertTrue(chat.escapeStop(session, at: 10))
        XCTAssertEqual(session.stopArmedAt, 10)
        XCTAssertNil(session.interruptionID, "the first Esc stops nothing")
        XCTAssertTrue(chat.escapeStop(session, at: 11.5))
        XCTAssertEqual(session.stopArmedAt, 11.5, "a late second press arms again")
        XCTAssertNil(session.interruptionID)
        session.busy = false
        XCTAssertFalse(chat.escapeStop(session, at: 12), "nothing to stop: Esc goes on as usual")
        XCTAssertNil(session.stopArmedAt)
        session.busy = true
        XCTAssertTrue(chat.escapeStop(session, at: 13))
        XCTAssertTrue(chat.escapeStop(session, at: 13.5))
        XCTAssertNotNil(session.interruptionID, "A second press within a second stops the turn")
        XCTAssertNil(session.stopArmedAt)
        XCTAssertEqual(session.draft, "Keep this draft")
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
