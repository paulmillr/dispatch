import Foundation
import XCTest
@testable import DispatchApp

@MainActor
final class PiBridgeTests: XCTestCase {
    func testNativeDialogBlocksInputEvenWithoutATitleOrActiveModelTurn() throws {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()))
        defer { chat.stop() }
        let session = chat.session(for: UUID())
        session.sessionID = UUID().uuidString; session.helper = HelperChat(terminal: 0)
        session.active = true; session.busy = false
        let question = HelperChat.Question(id: "custom", header: "", text: "", secret: false, options: [], multiple: false, custom: true, blocks: nil)
        let dialog = HelperChat.Interaction(id: "dialog", key: nil, approval: false, blocking: true, questions: [question], turn: nil, record: nil)
        chat.receiveHelper(.interaction(dialog), session: session)
        XCTAssertTrue(session.waitingForAnswer)
        XCTAssertEqual(session.questions.map(\.id), [dialog.id])
        XCTAssertFalse(session.busy)
        XCTAssertNil(session.activeTurnID)
        chat.receiveHelper(.interaction(.init(id: dialog.id, key: nil, approval: false, blocking: true, questions: [], turn: nil, record: nil)), session: session)
        XCTAssertFalse(session.waitingForAnswer)
        XCTAssertEqual(session.questions.count, 0)
    }
}
