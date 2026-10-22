import Foundation
import Observation

@MainActor protocol ReviewPersistence {
    func load() throws -> [String: Review]
    func save(_ reviews: [String: Review]) throws
}

/// `reviews.json` beside the drafts: the comments quote the user's code, so it is owner-only and excluded from backups.
@MainActor final class ReviewFileStore: ReviewPersistence {
    struct Document: Codable { var version = 1; var reviews: [String: Review] }
    let url: URL
    init(url: URL = Home.support.appendingPathComponent("reviews.json")) { self.url = url }

    func load() throws -> [String: Review] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw CocoaError(.fileReadUnknown) }
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
        let repository = ReviewRepository(store: ReviewFileStore())
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
    /// The agent the last Create review went to, per scope (nil: the clipboard).
    private(set) var sentTo: [String: String] = [:]
    private(set) var error: String?
    @ObservationIgnored private let store: any ReviewPersistence
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    /// How long a review nobody touches is kept: past it, the code it is about has likely moved on.
    static let expiry: TimeInterval = 60 * 24 * 3600

    init(store: any ReviewPersistence) {
        self.store = store
        do {
            reviews = try store.load()
            loaded = true
        } catch {
            self.error = "Reviews could not be read: \(error.localizedDescription)"
        }
        // The clock is read only when there is something to expire.
        guard !reviews.isEmpty else { return }
        let cutoff = System.date().addingTimeInterval(-Self.expiry)
        let kept = reviews.filter { Self.lastChange($0.value) > cutoff }
        if kept.count != reviews.count {
            reviews = kept
            flush()
        }
    }

    /// When the review last changed; one stored before reviews kept the time goes by its newest comment.
    private static func lastChange(_ review: Review) -> Date {
        review.modified ?? review.comments.map(\.created).max() ?? .distantPast
    }

    private func touch(_ scope: String) {
        if reviews[scope] != nil { reviews[scope]?.modified = System.date() }
    }

    /// A repository's working tree on a host: this Mac's, or a remote host's by its name.
    static func scope(local: Bool, host: String?, root: String) -> String {
        (local ? "local" : "remote:" + (host ?? "")) + "|" + root
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
        flush()
        return review
    }

    /// Undo after Create review: the taken comments come back beside any written since.
    func restore(_ scope: String) {
        guard let taken = copied.removeValue(forKey: scope) else { return }
        sentTo[scope] = nil
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
