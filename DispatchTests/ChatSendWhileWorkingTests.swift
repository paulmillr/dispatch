import XCTest
@testable import DispatchApp

/// Settings › Features › Chat mode › While the agent works: Return queues (⌥⏎ steers) or steers (⌥⏎ queues).
@MainActor final class ChatSendWhileWorkingTests: XCTestCase {
    func testTheChoiceRoundTripsAndOlderSettingsQueue() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(old.chatSendWhileWorking, .queue, "settings saved before the option queue, as before")
        var changed = Preferences()
        changed.chatSendWhileWorking = .steer
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(decoded.chatSendWhileWorking, .steer)
        let unknown = try JSONDecoder().decode(Preferences.self, from: Data(#"{"chatSendWhileWorking":"later"}"#.utf8))
        XCTAssertEqual(unknown.chatSendWhileWorking, .queue)
    }

    func testReturnSteersOnlyAMessageWhileTheAgentWorks() {
        let coordinator = ChatCoordinator(enabled: true, defaults: nil)
        let session = ChatSession(id: System.uuid())
        session.draft = "look at the tests first"
        session.busy = true
        XCTAssertFalse(coordinator.returnSteers(session), "Queue is the default")

        coordinator.sendWhileWorking = .steer
        XCTAssertTrue(coordinator.returnSteers(session))
        session.busy = false
        XCTAssertFalse(coordinator.returnSteers(session), "an idle agent takes a new turn")
        session.busy = true
        session.draft = "/compact"
        XCTAssertFalse(coordinator.returnSteers(session), "a command never steers")
        session.draft = "look at the tests first"
        session.editingQueuedID = System.uuid()
        XCTAssertFalse(coordinator.returnSteers(session), "Return requeues an edited queued message")
    }
}
