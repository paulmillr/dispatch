import CryptoKit
import Foundation

/// Chat history on this iPhone (Settings › Chat › Keep history on this iPhone, on by default): what a thread showed,
/// saved so the chat opens on it while its host is offline, also after a relaunch. The same shape as the Mac's saved
/// chats (`SavedChat`): the transcript's turns and merge state, so the host's history merges into them when it is back
/// (`MobileChatSession.seed`). Only what the phone read (the pages it was sent, the earlier ones scrolled to, the full
/// outputs opened), never fetched for the save; never the agent's state, requests or queue.
///
/// One file per chat (`<host>/<sha256 of the node key>.chat`, compressed JSON), written when a thread is let go and as
/// the app goes to the background, only when it changed; at most `chatLimit` compressed (its oldest turns go first),
/// `totalLimit` across chats (the least recently used chat first). Private (0600), out of backups, in protection class
/// B: written whenever, readable only while the phone is unlocked. A host's go with the host, all of them on Remove all
/// data or when the setting is turned off. Reads and writes run in order on one queue, off the main thread.
@MainActor final class ChatHistoryArchive {
    struct Saved: Codable, @unchecked Sendable {
        struct Position: Codable {
            var row: String
            var into: Double
            var last: String?
        }

        var version = 1
        var node: String
        var conversation: String
        var reachedStart: Bool
        var saved: Date
        var turns: [ChatTurn]
        var index: ChatTranscript.Index
        var position: Position?
    }

    /// 32 MiB compressed per chat.
    static let chatLimit = 32 << 20
    /// 512 MiB compressed across chats.
    static let totalLimit = 512 << 20

    let directory: URL
    let chatLimit: Int
    let totalLimit: Int
    /// The setting (`MobileSettings.chatKeepHistory`): off, nothing is written or read.
    var enabled: @MainActor () -> Bool = { true }
    private let queue = DispatchQueue(label: "chat-history", qos: .utility)
    /// What each chat's file holds now, so an unchanged transcript is not written again.
    private var written: [ChatConversationKey: Signature] = [:]

    private struct Signature: Equatable {
        let conversation: String
        let revision: Int
        let bytes: Int
        let reachedStart: Bool
    }

    init(directory: URL = Home.support.appendingPathComponent("chat-history", isDirectory: true),
         chatLimit: Int = ChatHistoryArchive.chatLimit, totalLimit: Int = ChatHistoryArchive.totalLimit) {
        self.directory = directory
        self.chatLimit = chatLimit
        self.totalLimit = totalLimit
    }

    func file(_ key: ChatConversationKey) -> URL {
        let name = SHA256.hash(data: Data(key.node.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key.host.uuidString, isDirectory: true).appendingPathComponent(name + ".chat")
    }

    /// Saves what a thread showed (unless the file already holds it).
    func save(_ kept: MobileChatSession.Kept, for key: ChatConversationKey) {
        guard enabled() else { return }
        let signature = Signature(conversation: kept.conversation, revision: kept.transcript.revision, bytes: kept.bytes,
                                  reachedStart: kept.earlier == nil)
        guard written[key] != signature else { return }
        written[key] = signature
        let transcript = kept.transcript.saved
        let saved = Saved(node: key.node, conversation: kept.conversation, reachedStart: kept.earlier == nil, saved: kept.saved,
                          turns: transcript.turns, index: transcript.index,
                          position: kept.readingPosition.map { .init(row: $0.row, into: Double($0.into), last: $0.last) })
        let url = file(key), root = directory, chatLimit = chatLimit, totalLimit = totalLimit
        queue.async {
            guard let data = Self.encode(saved, limit: chatLimit) else { return }
            try? PrivateFile.write(data, to: url, excludedFromBackup: true, unreadableWhileLocked: true)
            Self.trim(root, limit: totalLimit, keeping: url)
        }
    }

    /// The chat's saved copy, as a kept transcript; nil without one (or one for another node, or unreadable).
    func load(_ key: ChatConversationKey) async -> MobileChatSession.Kept? {
        guard enabled() else { return nil }
        let url = file(key)
        let saved: Saved? = await withCheckedContinuation { done in
            queue.async { done.resume(returning: Self.read(url)) }
        }
        guard let saved, saved.node == key.node, enabled() else { return nil }
        var transcript = ChatTranscript()
        transcript.turns = saved.turns
        transcript.index = saved.index
        let restored = MobileTranscript(saved: transcript)
        guard !restored.isEmpty else { return nil }
        written[key] = Signature(conversation: saved.conversation, revision: restored.revision, bytes: restored.estimatedBytes,
                                 reachedStart: saved.reachedStart)
        return MobileChatSession.Kept(
            transcript: restored, conversation: saved.conversation, earlier: saved.reachedStart ? nil : "",
            readingPosition: saved.position.map { ChatReadingPosition(row: $0.row, into: CGFloat($0.into), last: $0.last) },
            bytes: restored.estimatedBytes, saved: saved.saved)
    }

    /// A host's chats go (the host was removed).
    func remove(host: UUID) {
        written = written.filter { $0.key.host != host }
        let folder = directory.appendingPathComponent(host.uuidString, isDirectory: true)
        queue.async { try? FileManager.default.removeItem(at: folder) }
    }

    /// Every chat goes (Remove all data, the setting turned off).
    func removeAll() {
        written = [:]
        let root = directory
        queue.async { try? FileManager.default.removeItem(at: root) }
    }

    /// Calls `done` on the main queue once every save asked for so far is written.
    func flush(_ done: @escaping @MainActor @Sendable () -> Void) {
        queue.async { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
    }

    /// Compressed JSON at most `limit` bytes: a larger chat loses its oldest half of turns until it fits (their records
    /// unseen again, so the host's history brings them back), as the Mac's saved chats do; nil when even one turn is
    /// too large.
    nonisolated static func encode(_ saved: Saved, limit: Int) -> Data? {
        var saved = saved
        let encoder = JSONEncoder()
        while true {
            guard let json = try? encoder.encode(saved),
                  let data = try? (json as NSData).compressed(using: .lzfse) as Data else { return nil }
            if data.count <= limit { return data }
            guard saved.turns.count > 1 else { return nil }
            let dropped = saved.turns.prefix(saved.turns.count / 2)
            saved.turns.removeFirst(dropped.count)
            let items = dropped.flatMap(\.items)
            saved.index.forget(turns: Set(dropped.map(\.id)), records: Set(items.map(\.id) + items.compactMap { $0.source?.id }))
            saved.reachedStart = false
        }
    }

    nonisolated static func decode(_ data: Data) -> Saved? {
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let saved = try? JSONDecoder().decode(Saved.self, from: json), saved.version == 1 else { return nil }
        return saved
    }

    /// Reads a chat's file; a read counts as a use (its time moves up, `trim`).
    private nonisolated static func read(_ url: URL) -> Saved? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return decode(data)
    }

    /// Removes the least recently used chats until the rest fit `limit` (never `keeping`, the one just written), and
    /// what a killed write left (temporary files start with a dot; no write runs meanwhile, this queue is serial).
    private nonisolated static func trim(_ root: URL, limit: Int, keeping: URL) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: keys) else { return }
        var files: [(url: URL, size: Int, used: Date)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if url.lastPathComponent.hasPrefix(".") { try? manager.removeItem(at: url); continue }
            files.append((url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.size }
        let kept = keeping.resolvingSymlinksInPath().path
        for file in files.sorted(by: { $0.used < $1.used }) where total > limit && file.url.resolvingSymlinksInPath().path != kept {
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
