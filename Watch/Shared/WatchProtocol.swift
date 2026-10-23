import Foundation

/// The phone↔watch protocol (docs/watch.md, Architecture and data flow). Compiled into both apps: the iPhone app's
/// `WatchBridge` (Mobile/Watch) answers it, the watch app's `WatchLink` asks it. Foundation only.
///
/// - The phone pushes a `WatchSnapshot` (WatchSnapshot.swift) as its WatchConnectivity application context: the lists,
///   small, latest wins.
/// - The watch sends a `WatchRequest` with `sendMessage`; the phone answers one `WatchReply` with the same `id`.
///
/// Compatibility: every message names its `kind` as a string and every new field is optional, so an older peer reads a
/// newer one's messages (an unknown request kind is answered `unsupported`, an unknown reply kind or enum value decodes
/// as `unknown`). `version` changes only for a change an older peer would misread, never for an added field or kind: a
/// later `terminal.screen` request (a text snapshot of a tab's screen, answered by a `screen` reply) is such an addition.
enum WatchProtocol {
    /// The protocol both sides speak. 1: snapshot, thread, answer, send, queue, stop/resume, seen; later additions
    /// (no new version): `open`, `review.undo`, and the snapshot's rows, hosts' stats and review events.
    static let version = 1
}

/// Identity of a conversation, exactly as the phone keys it (`ChatConversationKey`, Mobile/Chat/MobileChatOutbox.swift):
/// the host (`HostRecord.id`) and the terminal's topology `key` (tmux `…:%<pane>`, herdr `term_…`). Never a node id:
/// those belong to one helper connection and change with every reconnect (docs/ios.md, Identity).
struct WatchConversationKey: Hashable, Codable, Sendable {
    /// `HostRecord.id.uuidString`.
    var host: String
    /// The terminal's topology key (`HelperTopology.Node.key`).
    var node: String
}

/// A request from the watch. `id` pairs it with its reply (and lets the phone ignore a retried duplicate).
struct WatchRequest: Codable, Equatable, Sendable {
    var id: String
    /// The sender's `WatchProtocol.version`.
    var version: Int
    var action: WatchAction

    init(_ action: WatchAction, id: String = UUID().uuidString, version: Int = WatchProtocol.version) {
        self.id = id
        self.version = version
        self.action = action
    }

    private enum CodingKeys: String, CodingKey { case id, version }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? WatchProtocol.version
        // The action's fields sit beside the envelope's (one flat object, `kind` naming the action).
        action = try WatchAction(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
        try action.encode(to: encoder)
    }
}

/// What the watch asks of the phone. Each maps to one iPhone call (docs/watch.md, "What the bridge calls").
enum WatchAction: Equatable, Sendable {
    /// The watch app started or came forward: the phone answers with a fresh `snapshot` (the application context may be
    /// minutes old or missing on a first launch).
    case hello
    /// Pull to refresh: the phone retries its hosts (`HostSession.retryNow`) and re-reads their conversations, then
    /// answers with a `snapshot`. `host` nil: every host.
    case refresh(host: String?)
    /// A thread page (`WatchThread`) of at most `limit` items, newest last. Opens the conversation on the phone
    /// (`ChatConversations.session(for:)`), connecting its host when the phone is in the background.
    case thread(WatchConversationKey, limit: Int)
    /// Answers an approval (`WatchApproval.id`) or a question (`WatchQuestion.id`) of the conversation. Answered with the
    /// thread page after the phone applied it.
    case answer(WatchConversationKey, request: String, WatchAnswer)
    /// A message typed or dictated on the watch, routed as the phone's composer routes its own
    /// (`MobileChatSession.route(steer:command:)`: at once when the agent is idle, else queued). `steer`: into the running
    /// turn, the phone's long-press send.
    case send(WatchConversationKey, text: String, steer: Bool)
    /// Stop (`MobileChatSession.stop`): interrupts the turn and pauses the queue until `resume`.
    case stop(WatchConversationKey)
    /// Resume (`MobileChatSession.resumeQueue`).
    case resume(WatchConversationKey)
    /// Removes a queued message (`WatchQueued.id`, `MobileChatSession.removeQueued`).
    case removeQueued(WatchConversationKey, item: String)
    /// Sends a queued message now (`MobileChatSession.sendQueuedNow`), steering while the agent works.
    case sendQueuedNow(WatchConversationKey, item: String)
    /// The watch showed the thread up to `through` (its newest item's time): the phone's seen marker moves there
    /// (`ChatMarkers.markSeen`), never past what the phone itself holds. Answered `done`.
    case markSeen(WatchConversationKey, through: Date)
    /// "Open on iPhone": the phone shows the conversation (its thread) when it is in the foreground, else posts a
    /// local notification that opens it. Answered `opened` with what it did.
    case openOnPhone(WatchConversationKey)
    /// Undo of a review the phone just sent (`WatchReviewSent.id`), before its deadline. Answered `done`, or
    /// `requestEnded` once the agent has it.
    case undoReview(id: String)
    /// A kind this build does not know (a newer peer's). The phone answers `unsupported`.
    case unknown(String)

    var kind: String {
        switch self {
        case .hello: "hello"
        case .refresh: "refresh"
        case .thread: "thread"
        case .answer: "answer"
        case .send: "send"
        case .stop: "stop"
        case .resume: "resume"
        case .removeQueued: "queue.remove"
        case .sendQueuedNow: "queue.sendNow"
        case .markSeen: "seen"
        case .openOnPhone: "open"
        case .undoReview: "review.undo"
        case .unknown(let kind): kind
        }
    }

    /// The conversation it acts on, if any.
    var conversation: WatchConversationKey? {
        switch self {
        case .thread(let key, _), .answer(let key, _, _), .send(let key, _, _), .stop(let key), .resume(let key),
             .removeQueued(let key, _), .sendQueuedNow(let key, _), .markSeen(let key, _), .openOnPhone(let key): key
        case .hello, .refresh, .undoReview, .unknown: nil
        }
    }
}

extension WatchAction: Codable {
    /// Every action's fields in one flat object: no nesting to version, and unknown fields are ignored.
    private enum CodingKeys: String, CodingKey { case kind, host, node, limit, request, answer, text, steer, item, through, review }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        func key() throws -> WatchConversationKey {
            WatchConversationKey(host: try values.decode(String.self, forKey: .host), node: try values.decode(String.self, forKey: .node))
        }
        switch kind {
        case "hello": self = .hello
        case "refresh": self = .refresh(host: try values.decodeIfPresent(String.self, forKey: .host))
        case "thread": self = .thread(try key(), limit: try values.decodeIfPresent(Int.self, forKey: .limit) ?? WatchLimits.threadItems)
        case "answer":
            self = .answer(try key(), request: try values.decode(String.self, forKey: .request),
                           try values.decode(WatchAnswer.self, forKey: .answer))
        case "send":
            self = .send(try key(), text: try values.decode(String.self, forKey: .text),
                         steer: try values.decodeIfPresent(Bool.self, forKey: .steer) ?? false)
        case "stop": self = .stop(try key())
        case "resume": self = .resume(try key())
        case "queue.remove": self = .removeQueued(try key(), item: try values.decode(String.self, forKey: .item))
        case "queue.sendNow": self = .sendQueuedNow(try key(), item: try values.decode(String.self, forKey: .item))
        case "seen": self = .markSeen(try key(), through: try values.decode(Date.self, forKey: .through))
        case "open": self = .openOnPhone(try key())
        case "review.undo": self = .undoReview(id: try values.decode(String.self, forKey: .review))
        default: self = .unknown(kind)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        if let key = conversation {
            try values.encode(key.host, forKey: .host)
            try values.encode(key.node, forKey: .node)
        }
        switch self {
        case .refresh(let host): try values.encodeIfPresent(host, forKey: .host)
        case .thread(_, let limit): try values.encode(limit, forKey: .limit)
        case .answer(_, let request, let answer):
            try values.encode(request, forKey: .request)
            try values.encode(answer, forKey: .answer)
        case .send(_, let text, let steer):
            try values.encode(text, forKey: .text)
            if steer { try values.encode(true, forKey: .steer) }
        case .removeQueued(_, let item), .sendQueuedNow(_, let item): try values.encode(item, forKey: .item)
        case .markSeen(_, let through): try values.encode(through, forKey: .through)
        case .undoReview(let id): try values.encode(id, forKey: .review)
        case .hello, .stop, .resume, .openOnPhone, .unknown: break
        }
    }
}

/// The phone's answer to one request.
struct WatchReply: Codable, Equatable, Sendable {
    /// The request's `id`.
    var id: String
    /// The phone's `WatchProtocol.version`: the watch can say "Update Dispatch on your iPhone" for a newer kind.
    var version: Int
    var result: WatchResult

    init(id: String, _ result: WatchResult, version: Int = WatchProtocol.version) {
        self.id = id
        self.version = version
        self.result = result
    }

    private enum CodingKeys: String, CodingKey { case id, version }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? WatchProtocol.version
        result = try WatchResult(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(version, forKey: .version)
        try result.encode(to: encoder)
    }
}

enum WatchResult: Equatable, Sendable {
    /// `hello` and `refresh`: the lists as the phone has them now.
    case snapshot(WatchSnapshot)
    /// `thread` and every conversation action: the page after the phone applied the action.
    case thread(WatchThread)
    /// Done, nothing to show (`markSeen`, `review.undo`).
    case done
    /// `open`: what the phone did.
    case opened(WatchOpenOutcome)
    /// Refused or failed, with what to tell the user.
    case failure(WatchFailure)
    /// A reply kind this build does not know.
    case unknown(String)

    var kind: String {
        switch self {
        case .snapshot: "snapshot"
        case .thread: "thread"
        case .done: "done"
        case .opened: "opened"
        case .failure: "failure"
        case .unknown(let kind): kind
        }
    }
}

extension WatchResult: Codable {
    private enum CodingKeys: String, CodingKey { case kind, snapshot, thread, failure, opened }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "snapshot": self = .snapshot(try values.decode(WatchSnapshot.self, forKey: .snapshot))
        case "thread": self = .thread(try values.decode(WatchThread.self, forKey: .thread))
        case "done": self = .done
        case "opened": self = .opened((try? values.decode(WatchOpenOutcome.self, forKey: .opened)) ?? .unknown)
        case "failure": self = .failure(try values.decode(WatchFailure.self, forKey: .failure))
        default: self = .unknown(kind)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case .snapshot(let snapshot): try values.encode(snapshot, forKey: .snapshot)
        case .thread(let thread): try values.encode(thread, forKey: .thread)
        case .failure(let failure): try values.encode(failure, forKey: .failure)
        case .opened(let outcome): try values.encode(outcome, forKey: .opened)
        case .done, .unknown: break
        }
    }
}

/// What "Open on iPhone" did on the phone.
enum WatchOpenOutcome: String, WatchTolerantValue {
    /// The phone app was in the foreground: the thread is on its screen.
    case shown
    /// In the background: a local notification that opens the thread was posted.
    case notified
    /// In the background with notifications not allowed: nothing could bring it forward.
    case unavailable
    case unknown
}

/// Why a request did not do what it asked, in the words the watch shows. The phone fills `message` with its own text
/// where it has one (`MobileChatSession.failure`, `HostSession.problem`); the watch never composes host-specific text.
struct WatchFailure: Error, Codable, Equatable, Sendable {
    enum Code: String, WatchTolerantValue {
        /// Watch side: the iPhone is not reachable (`WCSession.isReachable` false, or `sendMessage` failed).
        case unreachable
        /// Watch side: no reply in time (`WatchLimits.replyTimeout`).
        case timedOut
        /// Reserved: phone builds before passwords read after first unlock (docs/security.md) answered it while locked;
        /// current ones never do (a Face ID key host answers `openPhone`).
        case phoneLocked
        /// The host needs something only the phone's screen can do: Face ID for its key, a host key to trust, a changed
        /// host key, a keyboard-interactive login (`WatchHostBlock`).
        case openPhone
        /// The host is not connected and could not be reached (`HostSession.problem` in `message`).
        case hostOffline
        /// The conversation's terminal is gone or no longer runs an agent.
        case noConversation
        /// The approval or question was answered elsewhere or expired (`PendingApproval.retire`).
        case requestEnded
        /// The phone refused the input; nothing was sent (`ChatInputNotSent`, an outbox that cannot be saved).
        case notSent
        /// The request kind or version is one the phone does not know: update the older app.
        case unsupported
        /// A message that does not decode.
        case invalid
        /// Anything else; `message` says what.
        case failed
        /// A code from a newer peer.
        case unknown
    }

    var code: Code
    /// One or two sentences for the watch's screen.
    var message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    static let unreachable = WatchFailure(.unreachable, "Your iPhone isn't reachable. Bring it closer or turn on Bluetooth.")
    static let timedOut = WatchFailure(.timedOut, "Your iPhone didn't answer in time.")
    static let phoneLocked = WatchFailure(.phoneLocked, "Unlock your iPhone: Dispatch can't reach your hosts while it's locked.")
    static let unsupported = WatchFailure(.unsupported, "Update Dispatch on your iPhone and Apple Watch.")
    static let invalid = WatchFailure(.invalid, "Your iPhone sent something this watch app can't read.")

    static func openPhone(host: String) -> WatchFailure {
        WatchFailure(.openPhone, "Open Dispatch on your iPhone to connect \(host).")
    }
}

/// A string-backed enum that decodes a value it does not know (a newer peer's) as `unknown` instead of failing the
/// whole message.
protocol WatchTolerantValue: RawRepresentable, CaseIterable, Codable, Hashable, Sendable where RawValue == String {
    static var unknown: Self { get }
}

extension WatchTolerantValue {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

/// Sizes both sides keep to (docs/watch.md, Limits).
enum WatchLimits {
    /// The encoded snapshot's ceiling. WatchConnectivity refuses an application context or message over its payload
    /// limit (`WCErrorCodePayloadTooLarge`, about 64 KiB); half of that leaves room and keeps the radio short.
    static let snapshotBytes = 32 * 1024
    /// A reply's ceiling (a thread page), under the same limit.
    static let replyBytes = 48 * 1024
    /// An Agents row's preview, as the watch shows two or three lines of it.
    static let preview = 120
    /// A thread item's text; longer messages end with "…" (the whole message is on the phone).
    static let itemText = 1_000
    /// What the WatchConnectivity dictionary adds around the encoded snapshot (its key, the plist's frame): the snapshot
    /// is fitted to `snapshotBytes` less this, so the context itself stays under `snapshotBytes`.
    static let envelope = 256
    /// A row's step and what it asks when the snapshot is over its budget: one short line.
    static let short = 40
    /// A tool one-liner, an approval's code block, a queued message.
    static let line = 200
    static let detail = 600
    /// Items a thread page holds by default.
    static let threadItems = 40
    /// How long the watch waits for a reply. The phone may have to connect a host first (SSH, the helper, the history:
    /// a few seconds), and answers within `WatchLimits.phoneBudget`.
    static let replyTimeout: Duration = .seconds(20)
    /// The phone's own budget for one request, connecting included; it answers `hostOffline` or `timedOut` after it.
    static let phoneBudget: Duration = .seconds(15)
}
