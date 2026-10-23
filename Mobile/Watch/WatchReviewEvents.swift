import Foundation
import Observation

/// Reviews the phone just sent to an agent, mirrored on the watch with Undo until their deadline (docs/watch.md, Review
/// sent; mockups K8). The Review tab (another change) calls `post` when its Send goes out with an undo window, handing
/// over how to take it back, and `finished` when the window closed or the phone's own Undo took it; the bridge's
/// snapshot carries the open ones (`WatchSnapshot.reviews`) and its server answers the watch's `review.undo` with
/// `undo`. Observable: a post or a finish pushes a snapshot.
@MainActor @Observable
final class WatchReviewEvents {
    struct Event: Identifiable {
        let id: String
        let key: ChatConversationKey
        /// "claude", "codex", "pi".
        let agent: String?
        /// The conversation's name as its Agents row says it.
        let title: String
        let comments: Int
        let files: Int
        let sent: Date
        let undoUntil: Date
        /// Takes the review back, waiting for the helper's answer; false when it could not (the agent has it already).
        let undo: @MainActor () async -> Bool
    }

    /// Why the watch's Undo did nothing.
    enum UndoFailure: Error, Equatable {
        /// The window closed: the agent has it.
        case tooLate
        /// No such review (finished, or another device's).
        case unknown
    }

    private(set) var events: [Event] = []
    @ObservationIgnored private let clock: () -> Date
    /// Events kept at most (older ones go).
    private static let kept = 8

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// A review went out with `window` to take it back; returns the event's id.
    @discardableResult
    func post(key: ChatConversationKey, agent: String?, title: String, comments: Int, files: Int, window: TimeInterval,
              undo: @escaping @MainActor () async -> Bool) -> String {
        let now = clock()
        let event = Event(id: UUID().uuidString, key: key, agent: agent, title: title, comments: comments, files: files, sent: now,
                          undoUntil: now.addingTimeInterval(window), undo: undo)
        events.append(event)
        if events.count > Self.kept { events.removeFirst(events.count - Self.kept) }
        return event.id
    }

    /// The window closed or the phone took it back itself: the watch stops offering Undo.
    func finished(_ id: String) {
        events.removeAll { $0.id == id }
    }

    /// The watch's Undo.
    func undo(_ id: String) async -> Result<Void, UndoFailure> {
        guard let event = events.first(where: { $0.id == id }) else { return .failure(.unknown) }
        guard clock() < event.undoUntil else { return .failure(.tooLate) }
        guard await event.undo() else { return .failure(.tooLate) }
        finished(id)
        return .success(())
    }

    /// The events whose Undo is still open at `date`, oldest first, as the snapshot carries them.
    func open(at date: Date) -> [WatchReviewSent] {
        events.filter { date < $0.undoUntil }.map { event in
            WatchReviewSent(id: event.id, host: event.key.host.uuidString, node: event.key.node, agent: event.agent, title: event.title,
                            comments: event.comments, files: event.files, sent: event.sent, undoUntil: event.undoUntil)
        }
    }
}
