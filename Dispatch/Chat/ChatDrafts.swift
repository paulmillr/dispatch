import Foundation
import Observation

struct ChatDraft: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String?
    var text = ""
    var multiline = false
    var selection = NSRange(location: 0, length: 0)
    var modified = Date()
    // A restored copy may need a new UI identity, but retains this version ID.
    var revision = UUID()
    var label: String {
        title ?? String(text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.prefix(36) ?? "Draft")
    }
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct ChatDraftBucket: Codable {
    var working = ChatDraft()
    var saved: [ChatDraft] = []
    var selected: UUID?
    var recovery: [UUID: ChatDraft] = [:]
}

@MainActor protocol ChatDraftPersistence {
    func load() throws -> [String: ChatDraftBucket]
    func save(_ buckets: [String: ChatDraftBucket]) throws
}

@MainActor final class ChatDraftFileStore: ChatDraftPersistence {
    struct Document: Codable { var version = 1; var buckets: [String: ChatDraftBucket] }
    let url: URL
    init(url: URL = Home.support.appendingPathComponent("drafts.json")) { self.url = url }
    func load() throws -> [String: ChatDraftBucket] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
        return document.buckets
    }
    func save(_ buckets: [String: ChatDraftBucket]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Document(buckets: buckets)).write(to: url, options: .atomic)
    }
}

/// One repository serializes all conversations, including completions for a departed conversation.
@MainActor @Observable final class ChatDraftRepository {
    static let shared = ChatDraftRepository(store: ChatDraftFileStore())
    private(set) var buckets: [String: ChatDraftBucket] = [:]
    private(set) var error: String?
    var activeScopes: Set<String> = []
    @ObservationIgnored private let store: any ChatDraftPersistence
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var maximumWait: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var migratedScopes: [String: String] = [:]
    func migrate(_ source: String, to destination: String) { migratedScopes[source] = destination }
    func resolvedScope(_ key: String) -> String {
        var key = key
        while let next = migratedScopes[key] { key = next }
        return key
    }
    init(store: any ChatDraftPersistence) {
        self.store = store
        reload()
    }
    private func reload() {
        do {
            var restored = try store.load()
            for key in Array(restored.keys) {
                guard var bucket = restored[key] else { continue }
                for var draft in bucket.recovery.values.sorted(by: { $0.modified < $1.modified }) {
                    if bucket.saved.contains(where: { $0.revision == draft.revision }) || bucket.working.revision == draft.revision { continue }
                    if bucket.saved.contains(where: { $0.id == draft.id }) || bucket.working.id == draft.id { draft.id = UUID() }
                    bucket.saved.append(draft)
                }
                bucket.recovery = [:]; restored[key] = bucket
            }
            for (key, bucket) in restored {
                if buckets[key] == nil { buckets[key] = bucket }
                else if !bucket.saved.isEmpty || !bucket.working.isEmpty {
                    // A failed initial read may leave a live editor with its
                    // own bucket for this conversation. Keep recovered disk
                    // drafts separately so its next save cannot erase them.
                    buckets["recovered:" + UUID().uuidString] = bucket
                }
            }
            loaded = true; error = nil
        } catch { self.error = "Draft recovery could not be read: \(error.localizedDescription)" }
    }
    func put(_ bucket: ChatDraftBucket, at key: String, flush: Bool = false) {
        buckets[key] = bucket
        pending?.cancel()
        if flush { _ = self.flush() }
        else {
            // Continuous typing must not postpone durable storage indefinitely.
            if maximumWait == nil {
                maximumWait = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    _ = self?.flush()
                }
            }
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                _ = self?.flush()
            }
        }
    }
    @discardableResult func flush() -> Bool {
        pending?.cancel(); pending = nil
        maximumWait?.cancel(); maximumWait = nil
        if !loaded { reload() }
        guard loaded else { return false }
        do { try store.save(buckets); error = nil; return true }
        catch { self.error = "Drafts could not be saved: \(error.localizedDescription)"; return false }
    }
    func remove(_ key: String) { buckets[key] = nil }
}

struct ChatDraftDelivery {
    let scope: String
    let id: UUID
    let draft: ChatDraft
}

@MainActor @Observable final class ChatDraftCollection {
    let repository: ChatDraftRepository
    private(set) var scope: String
    private(set) var bucket: ChatDraftBucket
    private(set) var editorGeneration = UUID()
    private var deleted: [(Int, ChatDraft)] = []
    var canUndoDelete: Bool { !deleted.isEmpty }
    init(repository: ChatDraftRepository, provisional: String = UUID().uuidString) {
        self.repository = repository
        let initialScope = "provisional:" + provisional
        scope = initialScope
        bucket = repository.buckets[initialScope] ?? ChatDraftBucket()
        repository.activeScopes.insert(scope)
    }
    var current: ChatDraft { bucket.saved.first { $0.id == bucket.selected } ?? bucket.working }
    var saved: [ChatDraft] { bucket.saved }
    var selected: UUID? { bucket.selected }
    /// Drafts left by conversations no chat shows, most recently edited first.
    var recoverable: [String] {
        repository.buckets.keys.filter { $0 != scope && !repository.activeScopes.contains($0) && !Self.records(repository.buckets[$0]).isEmpty }
            .sorted { (Self.records(repository.buckets[$0]).map(\.modified).max() ?? .distantPast, $0) > (Self.records(repository.buckets[$1]).map(\.modified).max() ?? .distantPast, $1) }
    }
    /// The drafts `recover` would bring in, newest first.
    func recoverableDrafts(_ key: String) -> [ChatDraft] { Self.records(repository.buckets[key]).sorted { $0.modified > $1.modified } }
    private static func records(_ bucket: ChatDraftBucket?) -> [ChatDraft] {
        guard let bucket else { return [] }
        var seen = Set<UUID>()
        // A pending delivery's recovery copy can repeat a saved version.
        return (bucket.saved + (bucket.working.isEmpty ? [] : [bucket.working]) + bucket.recovery.values).filter { seen.insert($0.revision).inserted }
    }
    func beginProvisional() {
        persist(flush: true); repository.activeScopes.remove(scope)
        scope = "provisional:" + UUID().uuidString; bucket = ChatDraftBucket()
        repository.activeScopes.insert(scope); deleted = []; editorGeneration = UUID()
    }
    /// Reattach an unidentified conversation only after discovery has verified
    /// the same remote process. Keep any text typed on the replacement surface.
    func resumeProvisional(_ key: String) {
        guard scope.hasPrefix("provisional:"), key.hasPrefix("provisional:"), key != scope,
              !repository.activeScopes.contains(key), var restored = repository.buckets[key] else { return }
        persist(flush: true)
        restored.saved += bucket.saved
        restored.recovery.merge(bucket.recovery) { existing, _ in existing }
        // A selected saved draft can be the replacement editor's visible text
        // even when its separate working buffer is empty.
        if let selected = bucket.selected { restored.selected = selected }
        if !bucket.working.isEmpty {
            if !restored.working.isEmpty { restored.saved.append(restored.working) }
            restored.working = bucket.working
            restored.selected = bucket.selected
        }
        repository.migrate(scope, to: key)
        repository.remove(scope); repository.activeScopes.remove(scope)
        scope = key; bucket = restored; repository.activeScopes.insert(key)
        deleted = []; editorGeneration = UUID(); persist(flush: true)
    }

    func bind(host: String, agent: String, conversation: String) {
        // Encode components so user/host/conversation punctuation cannot collide.
        let key = [host, agent, conversation].map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
        guard key != scope else { return }
        persist(flush: true)
        var next = repository.buckets[key] ?? ChatDraftBucket()
        if scope.hasPrefix("provisional:") {
            next.saved += bucket.saved
            if bucket.selected != nil { next.selected = bucket.selected }
            if !bucket.working.isEmpty {
                // Identity discovery must not replace text already being edited.
                if !next.working.isEmpty { next.saved.append(next.working) }
                next.working = bucket.working
                next.selected = bucket.selected
            }
            next.recovery.merge(bucket.recovery) { existing, _ in existing }
            repository.migrate(scope, to: key)
            repository.remove(scope)
        }
        repository.activeScopes.remove(scope); repository.activeScopes.insert(key)
        scope = key; bucket = next; deleted = []; editorGeneration = UUID(); persist(flush: true)
    }
    func edit(text: String? = nil, multiline: Bool? = nil, selection: NSRange? = nil) {
        var record = current
        if let text, record.text != text {
            record.text = text; record.multiline = record.multiline || text.contains("\n") || text.contains("\r")
            record.modified = Date(); record.revision = UUID()
        }
        if let multiline { record.multiline = multiline }
        if let selection { record.selection = selection }
        guard record != current else { return }
        if let index = bucket.saved.firstIndex(where: { $0.id == bucket.selected }) { bucket.saved[index] = record }
        else { bucket.working = record }
        persist()
    }
    func keep() {
        guard !current.isEmpty else { return }
        if bucket.selected == nil { bucket.saved.append(bucket.working); bucket.working = ChatDraft() }
        openFreshWorking()
        editorGeneration = UUID(); persist(flush: true)
    }
    private func openFreshWorking() {
        if !bucket.working.isEmpty { bucket.saved.append(bucket.working) }
        bucket.working = ChatDraft(); bucket.selected = nil
    }
    func select(_ id: UUID?) {
        guard id == nil || bucket.saved.contains(where: { $0.id == id }) else { return }
        bucket.selected = id; editorGeneration = UUID(); persist(flush: true)
    }
    func navigate(_ delta: Int) {
        let ids: [UUID?] = [nil] + bucket.saved.map { Optional($0.id) }
        let index = ids.firstIndex(of: bucket.selected) ?? 0
        select(ids[(index + delta + ids.count) % ids.count])
    }
    func rename(_ id: UUID, title: String) {
        guard let index = bucket.saved.firstIndex(where: { $0.id == id }) else { return }
        bucket.saved[index].title = title.isEmpty ? nil : title
        bucket.saved[index].modified = Date(); bucket.saved[index].revision = UUID(); persist(flush: true)
    }
    func delete(_ id: UUID) {
        guard let index = bucket.saved.firstIndex(where: { $0.id == id }) else { return }
        deleted.append((index, bucket.saved.remove(at: index)))
        if bucket.selected == id { openFreshWorking(); editorGeneration = UUID() }
        persist(flush: true)
    }
    func undoDelete() {
        guard let (index, record) = deleted.popLast() else { return }
        let records = bucket.saved + [bucket.working]
        // A delivery failure can restore this version before Undo is used.
        // Preserve any later edit under its own identity as well.
        if !records.contains(where: { $0.revision == record.revision }) {
            var restored = record
            if records.contains(where: { $0.id == record.id }) { restored.id = UUID() }
            bucket.saved.insert(restored, at: min(index, bucket.saved.count))
        }
        persist(flush: true)
    }
    func discard() {
        if let id = bucket.selected { delete(id) }
        else { bucket.working = ChatDraft(); editorGeneration = UUID(); persist(flush: true) }
    }
    func restore(_ record: ChatDraft) {
        if current.id == record.id && current.revision == record.revision { persist(flush: true); return }
        let records = bucket.saved + [bucket.working]
        if records.contains(where: { $0.revision == record.revision }) {
            persist(flush: true); return
        }
        var restored = record
        if records.contains(where: { $0.id == record.id }) { restored.id = UUID() }
        if current.isEmpty && selected == nil { bucket.working = restored; editorGeneration = UUID() }
        else { bucket.saved.append(restored) }
        persist(flush: true)
    }
    func recover(_ key: String) {
        guard key != scope, !repository.activeScopes.contains(key), let other = repository.buckets[key] else { return }
        var records = other.saved
        if !other.working.isEmpty { records.append(other.working) }
        records += other.recovery.values.sorted { $0.modified < $1.modified }
        for var record in records {
            if bucket.saved.contains(where: { $0.revision == record.revision }) || bucket.working.revision == record.revision { continue }
            if bucket.saved.contains(where: { $0.id == record.id }) || bucket.working.id == record.id { record.id = UUID() }
            bucket.saved.append(record)
        }
        repository.remove(key); persist(flush: true)
    }
    /// Persist before removing visible state. A failed write rejects acceptance.
    func prepareDelivery(consume: Bool) -> ChatDraftDelivery? {
        guard let delivery = prepareRecovery(current) else { return nil }
        if consume { consumeCurrent(delivery.draft) }
        persist(flush: true); return delivery
    }
    /// Native queue steering removes server-owned text before submitting it.
    /// Keep a durable recovery record without touching the composer's draft.
    func prepareRecovery(_ draft: ChatDraft) -> ChatDraftDelivery? {
        let delivery = ChatDraftDelivery(scope: scope, id: UUID(), draft: draft)
        bucket.recovery[delivery.id] = draft
        persist()
        guard repository.flush() else { bucket.recovery[delivery.id] = nil; persist(); return nil }
        return delivery
    }
    private func consumeCurrent(_ record: ChatDraft) {
        if let index = bucket.saved.firstIndex(where: { $0.id == record.id && $0.revision == record.revision }) {
            bucket.saved.remove(at: index)
            if selected == record.id { openFreshWorking(); editorGeneration = UUID() }
        } else if bucket.working.id == record.id && bucket.working.revision == record.revision {
            bucket.working = ChatDraft()
            if selected == nil { editorGeneration = UUID() }
        }
    }
    func forgetDelivery(_ delivery: ChatDraftDelivery) {
        let key = repository.resolvedScope(delivery.scope)
        if key == scope { bucket.recovery[delivery.id] = nil; persist(flush: true) }
        else if var old = repository.buckets[key] { old.recovery[delivery.id] = nil; repository.put(old, at: key, flush: true) }
    }
    func finish(_ delivery: ChatDraftDelivery, success: Bool) {
        let deliveryScope = repository.resolvedScope(delivery.scope)
        if scope == deliveryScope {
            guard bucket.recovery.removeValue(forKey: delivery.id) != nil else { return }
            if success { consumeCurrent(delivery.draft); persist(flush: true) }
            else { restore(delivery.draft) }
        } else if var old = repository.buckets[deliveryScope] {
            guard old.recovery.removeValue(forKey: delivery.id) != nil else { return }
            if !success {
                let records = old.saved + [old.working]
                if !records.contains(where: { $0.revision == delivery.draft.revision }) {
                    var restored = delivery.draft
                    if records.contains(where: { $0.id == restored.id }) { restored.id = UUID() }
                    old.saved.append(restored)
                }
            } else {
                old.saved.removeAll { $0.id == delivery.draft.id && $0.revision == delivery.draft.revision }
                if old.working.id == delivery.draft.id && old.working.revision == delivery.draft.revision { old.working = ChatDraft() }
                if old.selected == delivery.draft.id && !old.saved.contains(where: { $0.id == delivery.draft.id }) { old.selected = nil }
            }
            repository.put(old, at: deliveryScope, flush: true)
        }
    }
    func persist(flush: Bool = false) { repository.put(bucket, at: scope, flush: flush) }
}
