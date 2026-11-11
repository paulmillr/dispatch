import Foundation
import Observation

@MainActor protocol ReviewPersistence {
    func load() throws -> [String: Review]
    func save(_ reviews: [String: Review]) throws
}

/// Whose review a key names: a repository's working tree on this Mac, or on a host by the app's own UUID for it (the
/// Mac's `HostRegistry.key(for:)`, the phone's host UUID), never by its name, which two hosts can share and a rename
/// changes, nor by what its helper reports.
struct ReviewScope: Hashable, Sendable {
    enum Kind: String, Sendable { case local, remote }
    var kind: Kind
    /// Empty on this Mac.
    var host: String
    var root: String

    /// What every key of this form starts with; keys without it were written before (`ReviewRepository.migrate`).
    static let prefix = "v2|"

    /// "v2|remote|5F0C…|/home/sam/api": versioned, each part with `%` and `|` percent-escaped, so no host or
    /// root can spell another's key.
    var key: String { Self.prefix + kind.rawValue + "|" + Self.escape(host) + "|" + Self.escape(root) }

    init(kind: Kind, host: String, root: String) {
        self.kind = kind
        self.host = kind == .local ? "" : host
        self.root = root
    }

    init?(key: String) {
        guard key.hasPrefix(Self.prefix) else { return nil }
        let parts = key.dropFirst(Self.prefix.count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[0])),
              let host = String(parts[1]).removingPercentEncoding, let root = String(parts[2]).removingPercentEncoding,
              kind == .remote || host.isEmpty else { return nil }
        self.init(kind: kind, host: host, root: root)
    }

    private static func escape(_ part: String) -> String {
        part.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "|", with: "%7C")
    }
}

/// `reviews.json` beside the drafts: the comments quote the user's code, so it is owner-only and excluded from backups.
/// Version 2 keys reviews by `ReviewScope.key`; a version 1 file is read and migrated (`ReviewRepository.migrate`).
@MainActor final class ReviewFileStore: ReviewPersistence {
    struct Document: Codable { var version = 2; var reviews: [String: Review] }
    let url: URL
    init(url: URL = Home.support.appendingPathComponent("reviews.json")) { self.url = url }

    func load() throws -> [String: Review] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 || document.version == 2 else { throw CocoaError(.fileReadUnknown) }
        return document.reviews
    }

    func save(_ reviews: [String: Review]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if reviews.isEmpty, !FileManager.default.fileExists(atPath: url.path) { return }
        try PrivateFile.write(encoder.encode(Document(reviews: reviews)), to: url, excludedFromBackup: true)
    }
}

/// The Review tab's comments, per repository working tree and host (`scope`), kept across launches. Every tab showing
/// that repository shows the same review. A comment saved, edited or deleted is written at once; the overall comment
/// 300 ms after typing stops. Read on first use, so a launch that never reviews never reads the file; a review left
/// alone for `expiry` is dropped then.
@MainActor @Observable final class ReviewRepository {
    private static var instance: ReviewRepository?
    static var shared: ReviewRepository {
        if let instance { return instance }
        let repository = ReviewRepository(store: ReviewFileStore(), identify: legacyHosts)
        instance = repository
        return repository
    }
    /// Tests put a repository over a store of their own.
    static func use(_ repository: ReviewRepository?) { instance = repository }
    /// Quit writes what is pending, if reviews were ever read.
    static func flushShared() { instance?.flush() }

    private(set) var reviews: [String: Review] = [:]
    /// What the last Create review took, per scope, for its Undo; memory only, gone once a comment is added.
    private(set) var copied: [String: Review] = [:]
    /// The agent the last Create review went to, per scope (nil: the clipboard, or cleared).
    private(set) var sentTo: [String: String] = [:]
    /// When the last Create review took the scope's review: its note goes by the clock, not by when it is seen.
    private(set) var takenAt: [String: Date] = [:]
    private(set) var error: String?
    @ObservationIgnored private let store: any ReviewPersistence
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    /// How long a review nobody touches is kept: past it, the code it is about has likely moved on.
    static let expiry: TimeInterval = 30 * 24 * 3600

    /// `identify`: the stable identities a host name in a key from before version 2 can mean (`migrate`).
    init(store: any ReviewPersistence, identify: @MainActor (String) -> Set<String> = { _ in [] }) {
        self.store = store
        do {
            reviews = try store.load()
            loaded = true
        } catch {
            self.error = "Reviews could not be read: \(error.localizedDescription)"
        }
        // The clock is read only when there is something to expire.
        guard !reviews.isEmpty else { return }
        let (found, moved) = Self.migrate(reviews, identify: identify)
        var migrated = found
        let now = System.date()
        let cutoff = now.addingTimeInterval(-Self.expiry)
        // A review that just moved to its key gets its 30 days from now: one kept while its host was unknown is not
        // dropped the moment it is found.
        for key in moved where Self.lastChange(migrated[key] ?? Review()) <= cutoff { migrated[key]?.modified = now }
        // One still under an old key is kept until it can move: it waits for its host, not for the clock.
        let kept = migrated.filter { !$0.key.hasPrefix(ReviewScope.prefix) || Self.lastChange($0.value) > cutoff }
        if kept != reviews {
            reviews = kept
            flush()
        }
    }

    /// Keys written before version 2 (`local|<root>`, `remote:<host name>|<root>`) under their `ReviewScope` key: this
    /// Mac's always, a remote one's when `identify` names exactly one host for the name (whatever `|` in the name or
    /// the root). Old keys that land on the same new key (a host renamed, a review already under it) are merged into
    /// one review, nothing lost (`merged`). A key whose host is not known, or could be more than one, stays as it was:
    /// kept, shown in no tab (no scope asks for it), tried again at the next launch. Also returns the new keys written.
    static func migrate(_ reviews: [String: Review], identify: (String) -> Set<String>)
        -> (reviews: [String: Review], moved: Set<String>) {
        var result = reviews.filter { $0.key.hasPrefix(ReviewScope.prefix) }
        var moved: Set<String> = []
        for (key, review) in reviews.filter({ !$0.key.hasPrefix(ReviewScope.prefix) }).sorted(by: { $0.key < $1.key }) {
            guard let scope = legacyScope(key, identify: identify) else {
                result[key] = review
                continue
            }
            result[scope.key] = result[scope.key].map { merged($0, review) } ?? review
            moved.insert(scope.key)
        }
        return (result, moved)
    }

    /// Two reviews of the same working tree as one: every comment of both (each once), the overall comments the newer
    /// first (one, when they say the same), changed when the newer was.
    static func merged(_ first: Review, _ second: Review) -> Review {
        let (newer, older) = lastChange(first) >= lastChange(second) ? (first, second) : (second, first)
        var result = newer
        result.comments += older.comments.filter { comment in !newer.comments.contains { $0.id == comment.id } }
        let summaries = [newer.summary, older.summary].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        result.summary = summaries.count == 2 && summaries[0] != summaries[1]
            ? summaries.joined(separator: "\n\n") : summaries.first ?? newer.summary
        result.modified = max(lastChange(newer), lastChange(older))
        return result
    }

    /// The scope a key from before version 2 names, nil when that is not one host's (or not a key of that form).
    static func legacyScope(_ key: String, identify: (String) -> Set<String>) -> ReviewScope? {
        if key.hasPrefix("local|") { return ReviewScope(kind: .local, host: "", root: String(key.dropFirst(6))) }
        guard key.hasPrefix("remote:") else { return nil }
        let rest = key.dropFirst(7)
        var found: Set<ReviewScope> = []
        // The old key did not escape `|`: every split that leaves an absolute root is a reading.
        for index in rest.indices where rest[index] == "|" {
            let root = String(rest[rest.index(after: index)...])
            guard root.hasPrefix("/") else { continue }
            for host in identify(String(rest[..<index])) { found.insert(ReviewScope(kind: .remote, host: host, root: root)) }
        }
        return found.count == 1 ? found.first : nil
    }

    /// The hosts a name in an old key can mean, by the identity reviews are keyed by now. The Mac wrote the host's
    /// shown name: the remembered hosts with that name, hostname or SSH destination, by their own UUID
    /// (`HostRegistry.key(for:)`). The phone wrote its host's UUID.
    static func legacyHosts(_ name: String) -> Set<String> {
        #if canImport(AppKit)
        guard let hosts = TerminalRuntime.shared.workspace?.hosts else { return [] }
        return Set(Self.hosts(named: name, in: Array(hosts.records.values)).compactMap {
            hosts.key(for: HostID(rawValue: $0))?.uuidString
        })
        #else
        UUID(uuidString: name).map { Set([$0.uuidString]) } ?? []
        #endif
    }

    #if canImport(AppKit)
    /// The identified hosts among `records` the Mac could have shown as `name`.
    static func hosts(named name: String, in records: [HostRecord]) -> Set<String> {
        Set(records.filter { record in
            record.id != .local && !record.id.isProvisional
                && (record.name == name || record.hostname == name || record.destinations.contains(name))
        }.map(\.id.rawValue))
    }
    #endif

    /// When the review last changed; one stored before reviews kept the time goes by its newest comment.
    private static func lastChange(_ review: Review) -> Date {
        review.modified ?? review.comments.map(\.created).max() ?? .distantPast
    }

    private func touch(_ scope: String) {
        if reviews[scope] != nil { reviews[scope]?.modified = System.date() }
    }

    /// A repository's working tree on a host: this Mac's, or a remote host's by its stable identity (`ReviewScope`).
    static func scope(local: Bool, host: String?, root: String) -> String {
        ReviewScope(kind: local ? .local : .remote, host: host ?? "", root: root).key
    }

    func review(_ scope: String) -> Review { reviews[scope] ?? Review() }

    func add(_ comment: ReviewComment, to scope: String) {
        forgetCopied(scope)
        reviews[scope, default: Review()].comments.append(comment)
        touch(scope)
        flush()
    }

    func update(_ id: UUID, text: String, in scope: String) {
        guard let index = reviews[scope]?.comments.firstIndex(where: { $0.id == id }) else { return }
        reviews[scope]?.comments[index].text = text
        touch(scope)
        flush()
    }

    func remove(_ id: UUID, from scope: String) {
        guard reviews[scope]?.comments.contains(where: { $0.id == id }) == true else { return }
        reviews[scope]?.comments.removeAll { $0.id == id }
        touch(scope)
        prune(scope)
        flush()
    }

    func setSummary(_ text: String, in scope: String) {
        guard review(scope).summary != text else { return }
        reviews[scope, default: Review()].summary = text
        touch(scope)
        prune(scope)
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.flush()
        }
    }

    /// Create review: the review leaves the repository (its Undo keeps it in memory) and is returned to be copied, or
    /// sent to the agent named `sentTo`.
    @discardableResult func take(_ scope: String, sentTo agent: String? = nil) -> Review? {
        guard let review = reviews.removeValue(forKey: scope), !review.isEmpty else { return nil }
        copied[scope] = review
        sentTo[scope] = agent
        takenAt[scope] = System.date()
        flush()
        return review
    }

    /// Undo after Create review: the taken comments come back beside any written since.
    func restore(_ scope: String) {
        guard let taken = copied.removeValue(forKey: scope) else { return }
        sentTo[scope] = nil
        takenAt[scope] = nil
        var review = reviews[scope] ?? Review()
        review.comments = taken.comments + review.comments.filter { comment in !taken.comments.contains { $0.id == comment.id } }
        if review.summary.isEmpty { review.summary = taken.summary }
        reviews[scope] = review
        touch(scope)
        flush()
    }

    /// The Undo note goes once the user moves on.
    func forgetCopied(_ scope: String) {
        if copied[scope] != nil { copied[scope] = nil }
        if sentTo[scope] != nil { sentTo[scope] = nil }
        if takenAt[scope] != nil { takenAt[scope] = nil }
    }

    /// Every review gone, as after removing its file (the phone's Remove all data): empty, writable again, no error.
    func reset() {
        pending?.cancel(); pending = nil
        reviews = [:]
        copied = [:]
        sentTo = [:]
        takenAt = [:]
        error = nil
        loaded = true
    }

    private func prune(_ scope: String) {
        if reviews[scope]?.isEmpty == true { reviews[scope] = nil }
    }

    func flush() {
        pending?.cancel(); pending = nil
        // A file that could not be read is never overwritten with what this launch added alone.
        guard loaded else { return }
        do { try store.save(reviews); error = nil }
        catch { self.error = "Reviews could not be saved: \(error.localizedDescription)" }
    }
}
