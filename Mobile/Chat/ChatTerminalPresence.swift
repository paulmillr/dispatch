import Foundation

/// What chat input needs from the terminal side: the conversation's terminal attached (`terminals.attach`) and its
/// screen published (`terminals.publish`), even while only the Chat segment shows. The helper verifies `chat.send`,
/// `queue.start` and typed answers against the screen the client publishes; without one they fail with
/// `terminal_unavailable` (docs/ios.md, Helper contract: "Publish screens"). The Terminal stream's `TerminalPresences`
/// satisfies it at integration (one `TerminalPresence` per host and topology key, `open(_:feed:terminal:)` with a
/// `HelperTerminalFeed`, `attached`); Chat only retains, releases and reads whether the terminal is attached.
@MainActor protocol ChatTerminalPresence: AnyObject {
    /// Attach the conversation's terminal (`terminal` on `client`, the current helper's id) and keep publishing its
    /// screens; a new id after a reconnect reattaches. Balanced by `release`.
    func retain(_ key: ChatConversationKey, terminal: UInt64, client: HelperClient)
    func release(_ key: ChatConversationKey)
    /// The terminal is attached and its screen is being published.
    func attached(_ key: ChatConversationKey) -> Bool
}

/// For previews, the demo and tests: a terminal counts as attached once retained (unless `publishes` is off).
@MainActor @Observable final class ChatTerminalPresenceStub: ChatTerminalPresence {
    private(set) var retained: [ChatConversationKey: UInt64] = [:]
    var publishes = true
    func retain(_ key: ChatConversationKey, terminal: UInt64, client: HelperClient) { retained[key] = terminal }
    func release(_ key: ChatConversationKey) { retained[key] = nil }
    func attached(_ key: ChatConversationKey) -> Bool { publishes && retained[key] != nil }
}
