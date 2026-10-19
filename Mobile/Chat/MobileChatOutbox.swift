import Foundation
import Observation

/// Where a conversation lives on the device: its host (the Hosts stream's `HostRecord.id`) and its terminal's
/// topology key (tmux `…:%<pane>`, herdr `term_…`). Node ids are the helper process's own and change with every
/// reconnect; the key does not (docs/ios.md, Helper contract: "Reattach by key").
struct ChatConversationKey: Hashable, Codable, Sendable {
    let host: UUID
    let node: String
}

/// A queued message, kept on the device until it is delivered (M4c, M5c). The helper's queue dies with the helper
/// (only Codex's own queue survives a drop), so this is the durable queue: while connected each message is mirrored
/// into `queue.*`; after a reconnect the device re-adds what the new helper lost. It never sends a message twice: when
/// the device cannot tell whether a message went out, it pauses it for the user (docs/architecture.md, Delivery).
struct ChatOutboxItem: Identifiable, Codable, Equatable, Sendable {
    enum State: Codable, Equatable, Sendable {
        /// On the device only: waits for the link and a verified conversation.
        case waiting
        /// `queue.add` sent; its reply is outstanding.
        case adding
        /// In the queue of the helper process `helper` (a session's client token) as `id` at `revision`.
        case queued(id: String, revision: UInt64, helper: UUID)
        /// The helper may or may not have delivered it: the user checks the thread, then sends or discards it.
        case uncertain(String)
        /// Refused, stopped, or typed for another conversation: edit, send or discard.
        case paused(String)
    }
    var id = UUID()
    let key: ChatConversationKey
    /// The conversation it was typed in (the binding's session); nil before the agent named one.
    let conversation: String?
    var text: String
    var created = Date()
    var state = State.waiting

    var pauseReason: String? {
        switch state {
        case .uncertain(let reason), .paused(let reason): reason
        case .waiting, .adding, .queued: nil
        }
    }
    var helperID: String? {
        if case .queued(let id, _, _) = state { return id }
        return nil
    }
}

@MainActor protocol ChatOutboxPersistence {
    func load() throws -> [ChatOutboxItem]
    func save(_ items: [ChatOutboxItem]) throws
}

@MainActor final class ChatOutboxFileStore: ChatOutboxPersistence {
    private struct Document: Codable { var version = 2; var items: [ChatOutboxItem] }
    let url: URL
    init(url: URL = Home.support.appendingPathComponent("chat-queue.json")) { self.url = url }
    func load() throws -> [ChatOutboxItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 2 else { throw CocoaError(.fileReadUnknown) }
        return document.items
    }
    func save(_ items: [ChatOutboxItem]) throws {
        try PrivateFile.write(JSONEncoder().encode(Document(items: items)), to: url, excludedFromBackup: true)
    }
}

@MainActor final class ChatOutboxMemoryStore: ChatOutboxPersistence {
    var items: [ChatOutboxItem] = []
    init(_ items: [ChatOutboxItem] = []) { self.items = items }
    func load() throws -> [ChatOutboxItem] { items }
    func save(_ items: [ChatOutboxItem]) throws { self.items = items }
}

/// Every conversation's queued messages in order, saved on each change (private file, excluded from backups). An add
/// interrupted by the app ending (no reply seen) comes back uncertain, never waiting. A file that cannot be read is
/// never written over (as `ChatDraftRepository` does): nothing more is queued until Remove all data, and the composer
/// says why.
@MainActor @Observable final class ChatOutbox {
    static let shared = ChatOutbox(store: ChatOutboxFileStore())
    private(set) var items: [ChatOutboxItem] = []
    private(set) var error: String?
    @ObservationIgnored private let store: any ChatOutboxPersistence
    /// The saved items were read (or there were none): only then may a save replace the file.
    @ObservationIgnored private var loaded = false

    init(store: any ChatOutboxPersistence) {
        self.store = store
        do {
            items = try store.load().map { item in
                var item = item
                if item.state == .adding { item.state = .uncertain(Self.interrupted) }
                return item
            }
            loaded = true
        } catch { self.error = "Queued messages could not be read: \(error.localizedDescription)" }
    }

    static let interrupted = "Dispatch closed before the host confirmed this message. Check the thread, then send or discard it."

    func items(for key: ChatConversationKey) -> [ChatOutboxItem] { items.filter { $0.key == key } }

    /// Saves before accepting: a message that cannot be kept is not taken from the composer.
    func add(_ item: ChatOutboxItem) -> Bool {
        items.append(item)
        guard persist() else { items.removeAll { $0.id == item.id }; return false }
        return true
    }

    func update(_ id: UUID, _ change: (inout ChatOutboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let before = items[index]
        change(&items[index])
        if items[index] != before { persist() }
    }

    func remove(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    /// One conversation's items in a new order (the others keep their places).
    func reorder(_ key: ChatConversationKey, _ order: [UUID]) {
        let mine = items.filter { $0.key == key }
        guard Set(order) == Set(mine.map(\.id)) else { return }
        var queue = order.compactMap { id in mine.first { $0.id == id } }
        items = items.map { $0.key == key ? queue.removeFirst() : $0 }
        persist()
    }

    /// Settings' Remove all data: every item, and the file even when it could not be read.
    func removeAll() {
        items = []
        loaded = true
        persist()
    }

    @discardableResult private func persist() -> Bool {
        guard loaded else { return false }
        do { try store.save(items); error = nil; return true }
        catch { self.error = "Queued messages could not be saved: \(error.localizedDescription)"; return false }
    }
}
