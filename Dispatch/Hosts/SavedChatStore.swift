import Foundation

/// A tab's chat as it stood when the app quit (Settings › General › On launch: Reopen spaces and history): what it had
/// loaded, never fetched for the save. It comes back read-only, as a retained conversation (`ChatSession.agentExited`
/// for a tab whose agent ended with the app), until its agent binds again and the live read merges into it.
struct SavedChat: Codable, Sendable {
    var conversation: String?
    var agent: String
    var agentTitle: String?
    var host: String?
    var title: String?
    var transcriptTitle: String?
    var model: String?
    var effort: String?
    /// The tab showed this chat.
    var shown: Bool
    /// Its tab is in a tmux or herdr space: the agent outlives the app, and the chat shows again until it binds.
    var multiplexed: Bool
    var turns: [ChatTurn]
    /// The merge state beside the turns, so a live read of the same conversation adds only what they lack.
    var index: ChatTranscript.Index
}

/// Saved chats, written only as the app quits with history on, beside the terminal output (`TerminalHistoryStore`)
/// and on the same terms: private, excluded from backups, read once at the next launch and then deleted, ignored after
/// a week. The file: a header as one JSON line, then each chat's JSON in its order. Chats encode and decode in
/// parallel, one per core, so quitting with many long chats stays quick.
struct SavedChatStore {
    let url: URL

    struct Header: Codable {
        struct Chat: Codable { var id: UUID; var bytes: Int }
        var version = 1
        var saved: Date
        var chats: [Chat]
    }

    /// Replaces the saved chats; nothing to save removes them. `limits`: a chat larger than a tab's share drops its
    /// oldest turns; past the total, the rest are left out.
    func save(_ chats: [(id: UUID, chat: SavedChat)], limits: TerminalHistoryStore.Limits = TerminalHistoryStore.limits) throws {
        let encoded = Self.encode(chats.map(\.chat), limit: limits.tab)
        var entries: [(id: UUID, data: Data)] = [], total = 0
        for (index, data) in encoded.enumerated() {
            guard let data, total + data.count <= limits.total else { continue }
            entries.append((chats[index].id, data)); total += data.count
        }
        guard !entries.isEmpty else { return try remove() }
        let header = Header(saved: Date(), chats: entries.map { .init(id: $0.id, bytes: $0.data.count) })
        try PrivateFile.write(to: url, excludedFromBackup: true) { file in
            try file.write(contentsOf: JSONEncoder().encode(header) + [0x0A])
            for entry in entries { try file.write(contentsOf: entry.data) }
        }
    }

    /// The saved chats, removed from the disk first: none when missing, unreadable, too large, too old or from
    /// another version; a chat that does not decode is left out.
    func take(limits: TerminalHistoryStore.Limits = TerminalHistoryStore.limits) -> [UUID: SavedChat] {
        let data = try? Data(contentsOf: url, options: .alwaysMapped)
        try? remove()
        guard let data, data.count <= limits.total + 1024 * 1024, let newline = data.firstIndex(of: 0x0A),
              let header = try? JSONDecoder().decode(Header.self, from: data[..<newline]), header.version == 1,
              abs(header.saved.timeIntervalSinceNow) <= TerminalHistoryStore.maxAge,
              header.chats.allSatisfy({ (0...data.count).contains($0.bytes) }),
              header.chats.reduce(0, { $0 + $1.bytes }) == data.count - newline - 1 else { return [:] }
        var ranges: [Range<Int>] = [], offset = newline + 1
        for chat in header.chats {
            ranges.append(offset..<offset + chat.bytes); offset += chat.bytes
        }
        let decoded = Results<SavedChat>(count: ranges.count)
        DispatchQueue.concurrentPerform(iterations: ranges.count) { index in
            decoded[index] = try? JSONDecoder().decode(SavedChat.self, from: data[ranges[index]])
        }
        var chats: [UUID: SavedChat] = [:]
        for (index, chat) in header.chats.enumerated() { chats[chat.id] = decoded[index] }
        return chats
    }

    func remove() throws {
        PrivateFile.removeStale(for: url)
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }

    /// Each chat as JSON, in parallel; one over `limit` bytes keeps its newest turns (halving until it fits), and one
    /// that cannot be encoded is nil.
    static func encode(_ chats: [SavedChat], limit: Int) -> [Data?] {
        let results = Results<Data>(count: chats.count)
        DispatchQueue.concurrentPerform(iterations: chats.count) { index in
            let encoder = JSONEncoder()
            var chat = chats[index]
            while true {
                guard let data = try? encoder.encode(chat) else { return }
                if data.count <= limit { results[index] = data; return }
                guard chat.turns.count > 1 else { return }
                let dropped = chat.turns.prefix(chat.turns.count / 2)
                chat.turns.removeFirst(dropped.count)
                // Their records are no longer seen: a live read of the conversation brings them back.
                let items = dropped.flatMap(\.items)
                chat.index.forget(turns: Set(dropped.map(\.id)),
                                  records: Set(items.map(\.id) + items.compactMap { $0.source?.id }))
            }
        }
        return results.values
    }

    /// Slots that parallel work fills, one per index.
    private final class Results<Value>: @unchecked Sendable {
        private var storage: [Value?]
        private let lock = NSLock()
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        subscript(index: Int) -> Value? {
            get { lock.withLock { storage[index] } }
            set { lock.withLock { storage[index] = newValue } }
        }
        var values: [Value?] { lock.withLock { storage } }
    }
}

extension ChatSession {
    /// What the quit saves of this chat: its loaded turns and their merge state, the conversation they belong to and
    /// what names it; nil with nothing to show. `multiplexed`: its tab is in a tmux or herdr space, whose agent outlives
    /// the app.
    func saved(multiplexed: Bool) -> SavedChat? {
        guard turns.contains(where: { !$0.items.isEmpty }) else { return nil }
        return SavedChat(conversation: sessionID, agent: agentID, agentTitle: helperTitle, host: host, title: title,
                         transcriptTitle: transcriptTitle, model: reportsModel ? model : nil, effort: effort,
                         shown: showChat, multiplexed: multiplexed, turns: turns, index: transcriptIndex)
    }

    /// A saved chat back in this session, before anything bound it. Sending stays paused (no agent until one binds);
    /// a tab whose agent ended with the app keeps it as a retained conversation (`agentExited`: the tab is its terminal,
    /// the transcript in the mode switch's menu), and a multiplexer's tab shows it again if it showed it. When its agent
    /// binds, a read of the same conversation merges into it, and another conversation replaces it.
    func restore(_ saved: SavedChat) {
        guard sessionID == nil, turns.isEmpty, helper == nil else { return }
        host = saved.host
        agentID = saved.agent
        helperTitle = saved.agentTitle
        sessionID = saved.conversation
        title = saved.title
        transcriptTitle = saved.transcriptTitle
        if let model = saved.model { self.model = model }
        effort = saved.effort
        transcriptIndex = saved.index
        turns = saved.turns
        agentExited = !saved.multiplexed
        if saved.shown && saved.multiplexed { setView(true, reason: "restore") }
    }
}
