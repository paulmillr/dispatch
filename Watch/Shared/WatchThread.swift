import Foundation

/// A thread page (the `thread` reply): the recent turns of one conversation, what it asks of the user, its queue, and
/// what the composer may do. Built by the phone's bridge from `MobileChatSession` (`transcript.rows`, `approvals`,
/// `questions`, `queueRows`) right after the request was served; the watch caches it per conversation and asks again
/// when the snapshot says the conversation moved.
struct WatchThread: Codable, Equatable, Sendable {
    var key: WatchConversationKey
    /// When the phone built it.
    var generated: Date
    /// The row's name (`WatchConversation.name`).
    var title: String
    /// "Claude Code", "Codex" (`MobileChatSession.agentName`).
    var agent: String?
    /// The model as the phone names it ("opus-5.5", `MobileChatSession.modelLabel`).
    var model: String?
    var phase: WatchPhase
    /// Why input is paused (`MobileChatSession.Phase.paused`), or the host's problem while offline.
    var reason: String?
    /// The agent is working (`MobileChatSession.working`): the thinking row, Stop and steer show.
    var working: Bool
    /// What it is doing ("thinking", "Reading files", `MobileChatSession.activity`).
    var activity: String?
    /// Since when it works (`MobileChatSession.workingSince`), for "thinking 48s".
    var workingSince: Date?
    /// Oldest first, newest last; at most the request's `limit`.
    var items: [WatchItem]
    /// Older items exist than the page holds (on the phone or beyond the limit): "Earlier messages are on your iPhone".
    var earlier: Bool
    /// Pending approvals (`MobileChatSession.approvals` still `pending`), oldest first. Decided ones are receipts on the
    /// phone; the watch only shows what still waits.
    var approvals: [WatchApproval]
    /// Pending questions: question forms (an approval with `ClaudeQuestions`) and side questions (`ChatSideQuestion`).
    var questions: [WatchQuestion]
    /// The queue as the phone shows it (`MobileChatSession.queueRows`).
    var queue: [WatchQueued]
    /// The queue is paused after Stop (`MobileChatSession.queueStopped`): Resume shows.
    var queueStopped: Bool
    /// Stop is offered (`phase == .live && working`, as the phone's composer offers it).
    var canStop: Bool
    /// Where a message typed now goes (`MobileChatSession.route`): sent, queued, or kept on the phone until the
    /// conversation is live (`outbox`), for the composer's placeholder.
    var route: WatchRoute
    /// The thread's notes the phone shows (Codex's hook trust, the terminal attaching, a command's result), one per line;
    /// why input is paused is `reason`.
    var notes: [String]
    /// The last send, answer or queue change's failure (`MobileChatSession.failure`).
    var failure: String?

    init(key: WatchConversationKey, generated: Date, title: String, agent: String? = nil, model: String? = nil,
         phase: WatchPhase = .live, reason: String? = nil, working: Bool = false, activity: String? = nil,
         workingSince: Date? = nil, items: [WatchItem] = [], earlier: Bool = false, approvals: [WatchApproval] = [],
         questions: [WatchQuestion] = [], queue: [WatchQueued] = [], queueStopped: Bool = false, canStop: Bool = false,
         route: WatchRoute = .send, notes: [String] = [], failure: String? = nil) {
        self.key = key
        self.generated = generated
        self.title = title
        self.agent = agent
        self.model = model
        self.phase = phase
        self.reason = reason
        self.working = working
        self.activity = activity
        self.workingSince = workingSince
        self.items = items
        self.earlier = earlier
        self.approvals = approvals
        self.questions = questions
        self.queue = queue
        self.queueStopped = queueStopped
        self.canStop = canStop
        self.route = route
        self.notes = notes
        self.failure = failure
    }

    private enum CodingKeys: String, CodingKey {
        case key, generated, title, agent, model, phase, reason, working, activity, workingSince, items, earlier
        case approvals, questions, queue, queueStopped, canStop, route, notes, failure
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(WatchConversationKey.self, forKey: .key)
        generated = try values.decode(Date.self, forKey: .generated)
        title = try values.decode(String.self, forKey: .title)
        agent = try? values.decodeIfPresent(String.self, forKey: .agent)
        model = try? values.decodeIfPresent(String.self, forKey: .model)
        phase = (try? values.decodeIfPresent(WatchPhase.self, forKey: .phase)) ?? .unknown
        reason = try? values.decodeIfPresent(String.self, forKey: .reason)
        working = (try? values.decodeIfPresent(Bool.self, forKey: .working)) ?? false
        activity = try? values.decodeIfPresent(String.self, forKey: .activity)
        workingSince = try? values.decodeIfPresent(Date.self, forKey: .workingSince)
        items = values.watchList(WatchItem.self, forKey: .items)
        earlier = (try? values.decodeIfPresent(Bool.self, forKey: .earlier)) ?? false
        approvals = values.watchList(WatchApproval.self, forKey: .approvals)
        questions = values.watchList(WatchQuestion.self, forKey: .questions)
        queue = values.watchList(WatchQueued.self, forKey: .queue)
        queueStopped = (try? values.decodeIfPresent(Bool.self, forKey: .queueStopped)) ?? false
        canStop = (try? values.decodeIfPresent(Bool.self, forKey: .canStop)) ?? false
        route = (try? values.decodeIfPresent(WatchRoute.self, forKey: .route)) ?? .unknown
        notes = (try? values.decodeIfPresent([String].self, forKey: .notes)) ?? []
        failure = try? values.decodeIfPresent(String.self, forKey: .failure)
    }

    /// Anything waits for the user.
    var needsYou: Bool { !approvals.isEmpty || questions.contains { $0.blocking } }

    /// When its newest item was written: what `markSeen` sends.
    var lastActivity: Date? { items.compactMap(\.time).max() }
}

/// The conversation's state on the phone (`MobileChatSession.Phase`).
enum WatchPhase: String, WatchTolerantValue {
    /// Verified: input goes to the agent.
    case live
    /// `chat.open` sent, the helper has not named the conversation yet.
    case opening
    /// Input paused; `reason` says why (the agent exited, another agent took the terminal).
    case paused
    /// No live subscription: the host is not connected. The transcript the phone holds is still shown.
    case offline
    case unknown
}

/// Where the composer's text goes now (`MobileChatSession.Route`).
enum WatchRoute: String, WatchTolerantValue {
    /// The agent is idle: sent at once ("Message").
    case send
    /// It works or messages wait: queued after this turn ("Queue a message…").
    case queue
    /// Not live: kept on the phone and queued once the conversation is ("Queued on your iPhone").
    case outbox
    case unknown
}

/// What a thread row is (`ChatThreadRow.Kind`, plus the tool steps the phone folds into captions).
enum WatchItemKind: String, WatchTolerantValue {
    /// The user's message.
    case user
    /// The agent's message, Markdown flattened to text (`WatchText.plain`).
    case agent
    /// Claude's inline thinking (`ChatItem.isNarration`): drawn muted.
    case thinking
    /// One tool call as one line (`ChatStep`: the kind, what it acted on, a short result).
    case tool
    /// "Conversation compacted" and other notices.
    case notice
    case unknown
}

/// One row of a thread page.
struct WatchItem: Codable, Equatable, Sendable, Identifiable {
    /// The phone's row id (`ChatThreadRow.id`, or the tool item's id): stable across pages of one conversation.
    var id: String
    var kind: WatchItemKind
    /// The message, clipped to `WatchLimits.itemText`; for a tool, what it acted on (`ChatStep.title`).
    var text: String
    /// When it was written (`ChatThreadRow.time`).
    var time: Date?
    /// The turn it belongs to (`ChatThreadRow.turnID`): the watch groups by it.
    var turn: String?
    /// For a tool: "Read", "Patch", "Run", "Search", "Web", "Tool" (`ChatStep.Kind.label`).
    var tool: String?
    /// For a tool: "+4 −1", the last output line, "exit 1" (`ChatStep.detail`).
    var detail: String?
    /// For a tool: it failed (`ChatStep.failed`).
    var failed: Bool
    /// For a tool: still running (`ChatStep.running`).
    var running: Bool
    /// Under the last agent message of an ended turn: "5 steps · 1m 26s" (`ChatTurnSummary.caption`).
    var caption: String?

    init(id: String, kind: WatchItemKind, text: String, time: Date? = nil, turn: String? = nil, tool: String? = nil,
         detail: String? = nil, failed: Bool = false, running: Bool = false, caption: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.time = time
        self.turn = turn
        self.tool = tool
        self.detail = detail
        self.failed = failed
        self.running = running
        self.caption = caption
    }
}

/// What a choice does (`ApprovalChoice.Role`).
enum WatchChoiceRole: String, WatchTolerantValue {
    case allow, deny
    /// "This session": allow, and the agent's suggested rules for the rest of its session (Claude only).
    case session
    case unknown
}

/// One approval chip: which option of the helper's question it answers (`ApprovalChoice.index`; option 0 allows,
/// 1 denies, helper/PROTOCOL.md).
struct WatchChoice: Codable, Equatable, Sendable, Identifiable {
    var index: Int
    /// "Allow", "Deny", "This session" (`ApprovalChoice.label`).
    var label: String
    var role: WatchChoiceRole

    init(index: Int, label: String, role: WatchChoiceRole) {
        self.index = index
        self.label = label
        self.role = role
    }

    var id: Int { index }
}

/// A pending approval (`MobileChatSession.Approval` whose `PendingApproval` has no questions).
struct WatchApproval: Codable, Equatable, Sendable, Identifiable {
    /// The helper's interaction id (`HelperChat.Interaction.id`): what `answer` names. Stable for the request's life,
    /// unlike the phone's card id.
    var id: String
    /// What the approval bubble says (`HelperChat.Interaction.approvalPresentation.text`: "Allow Bash?", the tool's
    /// description).
    var title: String
    /// Its code block (the command, file or pattern), clipped to `WatchLimits.detail`.
    var detail: String?
    /// When it arrived (`Approval.arrived`): "Waiting · 2m".
    var arrived: Date
    /// In the phone's order (`MobileChatSession.choices(for:)`): Deny, This session when offered, Allow.
    var choices: [WatchChoice]

    init(id: String, title: String, detail: String? = nil, arrived: Date, choices: [WatchChoice]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.arrived = arrived
        self.choices = choices
    }
}

/// One option of a question (`HelperChat.Choice`, `ClaudeQuestions.Option`).
struct WatchOption: Codable, Equatable, Sendable, Identifiable {
    /// Its index in the helper's question: what an answer names.
    var index: Int
    var label: String
    /// Its description, clipped to `WatchLimits.line`.
    var detail: String?

    init(index: Int, label: String, detail: String? = nil) {
        self.index = index
        self.label = label
        self.detail = detail
    }

    var id: Int { index }
}

/// A pending question: a question form (an approval with questions, `ClaudeQuestions`) or a side question
/// (`ChatSideQuestion`). One interaction can hold several questions, answered together.
struct WatchQuestion: Codable, Equatable, Sendable, Identifiable {
    struct Part: Codable, Equatable, Sendable, Identifiable {
        /// The helper's question id (`HelperChat.Question.id`): `WatchAnswer.options` and `texts` are keyed by it.
        var id: String
        var header: String
        var text: String
        var options: [WatchOption]
        /// Several options may be chosen.
        var multiple: Bool
        /// A typed answer is allowed (`ChatSideQuestion.Question.allowsCustom`): the watch offers dictation.
        var custom: Bool
        /// A secret answer: the watch says "Answer on your iPhone" (no secure field worth typing a secret into).
        var secret: Bool

        init(id: String, header: String = "", text: String, options: [WatchOption] = [], multiple: Bool = false,
             custom: Bool = false, secret: Bool = false) {
            self.id = id
            self.header = header
            self.text = text
            self.options = options
            self.multiple = multiple
            self.custom = custom
            self.secret = secret
        }
    }

    /// The helper's interaction id: what `answer` names.
    var id: String
    /// The agent waits for it (`HelperChat.Interaction.blocking`); a non-blocking one can be skipped without harm.
    var blocking: Bool
    var arrived: Date?
    var parts: [Part]

    init(id: String, blocking: Bool = true, arrived: Date? = nil, parts: [Part]) {
        self.id = id
        self.blocking = blocking
        self.arrived = arrived
        self.parts = parts
    }

    /// Every part can be answered on the watch (none is secret).
    var answerable: Bool { !parts.isEmpty && !parts.contains(where: \.secret) }
}

/// One queued message (`MobileChatSession.QueueRow`).
struct WatchQueued: Codable, Equatable, Sendable, Identifiable {
    /// `QueueRow.id`: a device item's UUID, or "helper:<id>" for one only the host's queue holds. Both survive a
    /// reconnect (the outbox is saved, the host's queue store ids are the same for every helper).
    var id: String
    /// Clipped to `WatchLimits.line`.
    var text: String
    /// Why it does not send by itself (paused, uncertain, stopped; `QueueRow.status`).
    var status: String?
    /// "Send now" is offered (`MobileChatSession.canSendNow`).
    var canSendNow: Bool

    init(id: String, text: String, status: String? = nil, canSendNow: Bool = false) {
        self.id = id
        self.text = text
        self.status = status
        self.canSendNow = canSendNow
    }
}

/// An answer to an approval or a question. Flat: exactly one of `choice`, `options`/`texts` or `skip` is meant.
struct WatchAnswer: Codable, Equatable, Sendable {
    /// An approval's chip (`WatchChoice.index`).
    var choice: Int?
    /// Per question part id: the chosen options' indices.
    var options: [String: [Int]]
    /// Per question part id: a typed or dictated answer (a part with `custom`).
    var texts: [String: String]
    /// Skip the question form (the phone's Skip: denies a question form, answers a side question `skip`).
    var skip: Bool

    init(choice: Int? = nil, options: [String: [Int]] = [:], texts: [String: String] = [:], skip: Bool = false) {
        self.choice = choice
        self.options = options
        self.texts = texts
        self.skip = skip
    }

    static func choice(_ choice: WatchChoice) -> WatchAnswer { WatchAnswer(choice: choice.index) }
    static let skipped = WatchAnswer(skip: true)

    private enum CodingKeys: String, CodingKey { case choice, options, texts, skip }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        choice = try values.decodeIfPresent(Int.self, forKey: .choice)
        options = try values.decodeIfPresent([String: [Int]].self, forKey: .options) ?? [:]
        texts = try values.decodeIfPresent([String: String].self, forKey: .texts) ?? [:]
        skip = try values.decodeIfPresent(Bool.self, forKey: .skip) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(choice, forKey: .choice)
        if !options.isEmpty { try values.encode(options, forKey: .options) }
        if !texts.isEmpty { try values.encode(texts, forKey: .texts) }
        if skip { try values.encode(true, forKey: .skip) }
    }

    /// Whether it answers every part of `question` (or skips it).
    func completes(_ question: WatchQuestion) -> Bool {
        skip || question.parts.allSatisfy { part in
            !(options[part.id] ?? []).isEmpty || !(texts[part.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
