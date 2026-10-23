import Foundation
import Observation

/// A tab's repository on a host: where its review comments live and whose changes Review lists. Its
/// `ReviewRepository` scope is `remote:<host UUID>|<root>` (the Mac's format for a remote working tree, with the phone's
/// host id where the Mac puts the host's name). Every tab in the same repository on the same host shares one review.
struct ReviewPlace: Hashable, Sendable {
    let host: UUID
    /// The repository's root on the host (`SpaceGitFacts`).
    let root: String

    @MainActor var scope: String { ReviewRepository.scope(local: false, host: host.uuidString, root: root) }
}

/// What Review's views see of their tab: the place, the tab, the host's name, the branch, whether the host is offline
/// (S3: the list dims, the accessory is the foundation's), and how to push a screen.
struct ReviewContext {
    let review: MobileReview
    let place: ReviewPlace
    let tab: TabRef
    let host: String
    let branch: String?
    let offline: Bool
    let push: (FilesRoute) -> Void
}

/// An agent a review can go to: a conversation in a tab of the review's space, the review's own tab first.
struct ReviewTarget: Identifiable, Hashable, Sendable {
    let key: ChatConversationKey
    /// "claude", "codex", "pi" (as `AgentGlyph` names them).
    let agent: String
    /// The tab's shown name and its space's ("web").
    let tab: String
    let space: String
    /// "fable-5.1"; nil before the agent said.
    let model: String?
    /// The review's own tab.
    let here: Bool

    var id: ChatConversationKey { key }
}

/// Why Send did not send.
struct ReviewSendError: Error, Equatable {
    let message: String
}

/// A review that went to a conversation: whether the agent has it already, and how to take it back while it does not.
struct ReviewDelivery {
    /// An idle agent got it at once (`chat.send` confirmed): there is nothing to take back.
    var delivered: Bool
    /// Takes the queued message back (from the device's or the helper's queue), waiting for the helper's answer; false
    /// once the agent has it or the helper refused.
    let withdraw: @MainActor () async -> Bool
}

/// How a review leaves the phone: to a conversation as its composer would send it (`MobileChatSession.sendConfirmed`:
/// at once when the agent is idle, confirmed by `chat.send`, else queued), or to the clipboard; a send that failed puts
/// the text into the conversation's draft. The composition fills it; tests script it.
struct ReviewOutlet {
    var send: @MainActor (_ text: String, _ target: ReviewTarget) async -> Result<ReviewDelivery, ReviewSendError> = { _, _ in
        .failure(ReviewSendError(message: "No agent to send to."))
    }
    var copy: @MainActor (String) -> Void = { _ in }
    /// The review's text into `target`'s chat draft, after a send that failed: nothing is lost.
    var draft: @MainActor (_ text: String, _ target: ReviewTarget) -> Void = { _, _ in }
}

/// A review that just went out (S4): "Sent to claude · 3 comments · Undo" (or "Copied") in Review's accessory until
/// `until`; Undo brings the comments back and takes the message back if the agent does not have it yet.
struct ReviewSent: Identifiable, Equatable {
    let id: UUID
    let place: ReviewPlace
    /// The agent it went to; nil: copied.
    let agent: String?
    let comments: Int
    let files: Int
    let sent: Date
    let until: Date
}

/// Review's state for the whole app (one per composition): the comments (`ReviewRepository`, `reviews.json`), each
/// repository's changes as last read (`ReviewChanges`), the reviews just sent with their Undo, the agents a tab's
/// review can go to and how it gets there. Debug's demo state for the screenshots (`ReviewDemo`) rides along.
@MainActor @Observable
final class MobileReview {
    /// The comments, read on first use (a badge, the list): a launch that never shows Review never reads `reviews.json`.
    /// A file that cannot be read is never written over; comments then live in memory and the list says so
    /// (`ReviewRepository.error`).
    var repository: ReviewRepository {
        if let loaded { return loaded }
        let repository = makeRepository()
        loaded = repository
        return repository
    }
    @ObservationIgnored private var loaded: ReviewRepository?
    /// The repository's file (`reviews.json`), which Remove all data deletes; nil for a store in memory.
    @ObservationIgnored var file: URL?
    @ObservationIgnored private let makeRepository: @MainActor () -> ReviewRepository
    /// The host's git through its helper, when it is connected with the Files & git grant; nil otherwise.
    @ObservationIgnored var reader: @MainActor (UUID) -> ReviewGitReader? = { _ in nil }
    /// The agents a tab's review can go to (its space's conversations, the tab's own first).
    @ObservationIgnored var targets: @MainActor (TabRef) -> [ReviewTarget] = { _ in [] }
    @ObservationIgnored var outlet = ReviewOutlet()
    /// The watch's mirror of a sent review's Undo (docs/watch.md, Review sent); nil without a watch link.
    @ObservationIgnored var watch: WatchReviewEvents?
    @ObservationIgnored let clock: () -> Date
    /// How long Undo stays after Send or Copy.
    static let undoWindow: TimeInterval = 60

    /// Each repository's changes, made on first use.
    @ObservationIgnored private var lists: [ReviewPlace: ReviewChanges] = [:]
    /// The review just sent per repository (S4), until its Undo window closes.
    var sent: [ReviewPlace: ReviewSent] = [:]
    /// A comment the diff screen should open on (Create review's rows): per repository, the comment's id.
    var reveal: [ReviewPlace: UUID] = [:]
    /// The Create review sheet showing, per tab.
    var sheet: TabRef?
    /// Debug: the state the screenshots start in.
    let demo: ReviewDemo?
    /// Create review reading the commented files again before the review goes out ("Checking the lines…").
    var checking: Set<ReviewPlace> = []
    /// Create review waiting for the agent's conversation to confirm the review ("Sending…"): the comments stay until it
    /// does.
    var sending: Set<ReviewPlace> = []
    /// A short note in Review's accessory after an Undo that could not take the message back, or a Send that failed
    /// ("Comments restored · claude already has the review"); it goes after `noticeDuration`.
    var notices: [ReviewPlace: String] = [:]
    static let noticeDuration: Duration = .seconds(5)
    /// Why the last Send did not go, per repository; Create review says it until the next try.
    var failures: [ReviewPlace: String] = [:]
    /// The reviews just sent with how to take them back and the end of their Undo window (`ReviewSending.swift`).
    @ObservationIgnored var outgoing: [ReviewPlace: ReviewOutgoing] = [:]
    /// Waits out the Undo window; tests pass their own.
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    init(repository: @autoclosure @escaping @MainActor () -> ReviewRepository = .shared, clock: @escaping () -> Date = { System.date() },
         demo: ReviewDemo? = nil) {
        makeRepository = repository
        self.clock = clock
        self.demo = demo
    }

    /// A repository's changes (one object per place, kept for the run).
    func changes(_ place: ReviewPlace) -> ReviewChanges {
        if let list = lists[place] { return list }
        let list = ReviewChanges(place: place, review: self)
        lists[place] = list
        return list
    }

    /// Something changed the host's working trees (an agent's turn ended): the host's lists that show read their status
    /// again, recounting the untracked files; the others read when they next show.
    /// Per host, bumped when an agent's turn ends there (`changed(host:)`): a shown diff reads its change again.
    private(set) var turns: [UUID: Int] = [:]

    func changed(host: UUID) {
        turns[host, default: 0] += 1
        for (place, list) in lists where place.host == host && list.shown > 0 {
            Task { await list.refresh(fresh: true) }
        }
    }

    /// The comments on a repository: Review's badge and the capsule's Files badge.
    func count(_ place: ReviewPlace) -> Int { repository.review(place.scope).comments.count }
}

/// Debug launch arguments that put Review in a mockup's state (docs/ios.md, Debug hooks), on the Spaces sample:
/// `-DispatchReviewDiff <path>[:select|compose|outdated]` pushes that change's diff (R2, R3, R4, S5),
/// `-DispatchReviewSheet agent|swipe|noagent` opens Create review (R5, R5b, R5c), `-DispatchReviewSent YES` shows the
/// sent accessory (S4).
struct ReviewDemo: Equatable, Sendable {
    var diff: String?
    var diffState: String?
    var sheet: String?
    var sent = false

    static func launch(_ defaults: UserDefaults = .standard) -> ReviewDemo? {
        #if DEBUG
        let diff = defaults.string(forKey: "DispatchReviewDiff")
        let sheet = defaults.string(forKey: "DispatchReviewSheet")
        let sent = defaults.bool(forKey: "DispatchReviewSent")
        guard diff != nil || sheet != nil || sent else { return nil }
        let parts = diff?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
        return ReviewDemo(diff: parts.first, diffState: parts.count > 1 ? parts[1] : nil, sheet: sheet, sent: sent)
        #else
        return nil
        #endif
    }
}

extension FilesRoute {
    /// A change's diff in Review: its path and its area (staged, unstaged, untracked).
    static func review(_ change: GitChange) -> FilesRoute {
        FilesRoute(mode: .review, path: change.path, detail: change.area.rawValue)
    }

    /// The area of a Review route's change.
    var reviewArea: GitChangeArea? { detail.flatMap(GitChangeArea.init(rawValue:)) }
}

/// Reviews kept in memory: the Spaces sample, previews and tests.
@MainActor final class ReviewMemoryStore: ReviewPersistence {
    var reviews: [String: Review]
    init(_ reviews: [String: Review] = [:]) { self.reviews = reviews }
    func load() throws -> [String: Review] { reviews }
    func save(_ reviews: [String: Review]) throws { self.reviews = reviews }
}

#if DEBUG
extension MobileReview {
    /// The Spaces sample's Review: the mockup's repository on every host (`ReviewSample`), its three comments on mba2's
    /// app repository (H2's badge), S5's outdated comment with `-DispatchReviewDiff …:outdated`.
    static func sample(now: Date = Date(), demo: ReviewDemo? = ReviewDemo.launch()) -> MobileReview {
        let place = ReviewPlace(host: TabsSample.mba2.id, root: "/Users/alex/src/app")
        var comments = ReviewSample.comments(now: now)
        if demo?.diffState == "outdated" { comments.insert(ReviewSample.outdated(now: now), at: 0) }
        // S4: the review just went to claude, its Undo open.
        let sent = demo?.sent == true
        let store = ReviewMemoryStore(sent ? [:] : [place.scope: Review(comments: comments, modified: now)])
        let review = MobileReview(repository: ReviewRepository(store: store), demo: demo)
        review.reader = { _ in ReviewSample.reader }
        if sent {
            review.sent[place] = ReviewSent(id: UUID(), place: place, agent: "claude", comments: comments.count,
                                            files: Set(comments.map(\.path)).count, sent: now, until: now.addingTimeInterval(3600))
        }
        return review
    }
}
#endif
