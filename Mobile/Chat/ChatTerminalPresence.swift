import Foundation

/// What chat input needs from the terminal side: the conversation's terminal attached (`terminals.attach`), even while
/// only the Chat segment shows. The helper verifies `chat.send`, `queue.start` and typed answers against the terminal's
/// screen, which it reads only while a client attaches it: from tmux or herdr itself when the hello accepted
/// `screens.host`, else from the screen the client publishes (`terminals.publish`); without either they fail with
/// `terminal_unavailable` (docs/ios.md, Helper contract: "Host screens"). The Terminal stream's `TerminalPresences`
/// satisfies it at integration (one `TerminalPresence` per host and topology key, `open(_:feed:terminal:)` with a
/// `HelperTerminalFeed`, `attached`); Chat only retains, releases and reads whether the terminal is attached.
@MainActor protocol ChatTerminalPresence: AnyObject {
    /// Attach the conversation's terminal (`terminal` on `client`, the current helper's id, whose hello accepted
    /// `features`) and keep it attached, its screen published unless the helper reads it itself; a new id after a
    /// reconnect reattaches. Balanced by `release`.
    func retain(_ key: ChatConversationKey, terminal: UInt64, client: HelperClient, features: Set<String>)
    func release(_ key: ChatConversationKey)
    /// The terminal is attached, so the helper can read its screen (its own reads or the phone's publications).
    func attached(_ key: ChatConversationKey) -> Bool
    /// The conversation is sending (a send, a queue start or an answer the helper verifies against the terminal's
    /// screen) or has finished: the terminal holds off what would end its attachment meanwhile (Reset terminal).
    func sending(_ key: ChatConversationKey, _ busy: Bool)
}

extension ChatTerminalPresence {
    func sending(_ key: ChatConversationKey, _ busy: Bool) {}
}

/// For previews, the demo and tests: a terminal counts as attached once retained (unless `publishes` is off).
@MainActor @Observable final class ChatTerminalPresenceStub: ChatTerminalPresence {
    private(set) var retained: [ChatConversationKey: UInt64] = [:]
    var publishes = true
    private(set) var features: [ChatConversationKey: Set<String>] = [:]
    func retain(_ key: ChatConversationKey, terminal: UInt64, client: HelperClient, features: Set<String>) {
        retained[key] = terminal
        self.features[key] = features
    }
    func release(_ key: ChatConversationKey) { retained[key] = nil }
    func attached(_ key: ChatConversationKey) -> Bool { publishes && retained[key] != nil }
}
