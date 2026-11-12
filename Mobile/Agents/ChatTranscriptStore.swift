import Foundation

/// What released conversations read (`MobileChatSession.Kept`), so the next session of a conversation shows its rows in
/// its first frame while `chat.open` reconciles them (docs/ios.md, Chat). In memory only, never written: bounded by
/// `limit` bytes (`MobileTranscript.estimatedBytes`), the least recently kept going first; a host's entries go with
/// the host (`ChatConversations.remove`), all of them on Remove all data and when iOS warns of memory pressure.
@MainActor final class ChatTranscriptStore {
    /// 8 MiB: a few hundred long threads' pages, a small share of what the app may use, and gone with the app.
    static let defaultLimit = 8 << 20

    let limit: Int
    private var entries: [ChatConversationKey: MobileChatSession.Kept] = [:]
    /// Least recently kept first.
    private var order: [ChatConversationKey] = []
    private(set) var bytes = 0

    init(limit: Int = ChatTranscriptStore.defaultLimit) { self.limit = limit }

    var keys: Set<ChatConversationKey> { Set(entries.keys) }

    /// Keeps a released session's transcript as the conversation's newest, then lets the oldest go until the store
    /// fits. One larger than the whole store is not kept.
    func keep(_ kept: MobileChatSession.Kept, for key: ChatConversationKey) {
        drop(key)
        guard kept.bytes <= limit else { return }
        entries[key] = kept
        order.append(key)
        bytes += kept.bytes
        while bytes > limit, let oldest = order.first { drop(oldest) }
    }

    /// The conversation's kept transcript, taken out: the session it seeds keeps it from now on (and gives it back when
    /// released).
    func take(_ key: ChatConversationKey) -> MobileChatSession.Kept? {
        guard let kept = entries[key] else { return nil }
        drop(key)
        return kept
    }

    func remove(host: UUID) {
        for key in order where key.host == host { drop(key) }
    }

    func removeAll() {
        entries = [:]
        order = []
        bytes = 0
    }

    private func drop(_ key: ChatConversationKey) {
        guard let kept = entries.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        bytes -= kept.bytes
    }
}
