import Foundation
import XCTest
#if canImport(AppKit)
@testable import DispatchApp
#else
@testable import DispatchMobile
#endif

// Test doubles the Mac and iPhone test bundles share (docs/ios.md): Foundation only.

@MainActor final class ChatDraftMemoryStore: ChatDraftPersistence {
    var buckets: [String: ChatDraftBucket] = [:]
    func load() throws -> [String: ChatDraftBucket] { buckets }
    func save(_ buckets: [String: ChatDraftBucket]) throws { self.buckets = buckets }
}

extension ChatSideQuestion {
    /// The form for a helper interaction (its chat.interaction JSON) in conversation `session`.
    static func helper(_ interaction: [String: Any], session: String) throws -> ChatSideQuestion {
        let value = try JSONDecoder().decode(HelperChat.Interaction.self, from: JSONSerialization.data(withJSONObject: interaction))
        return try XCTUnwrap(ChatSideQuestion(interaction: value, session: session))
    }
}
