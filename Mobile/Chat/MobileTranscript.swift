import Foundation

/// One conversation's transcript on the phone: the helper's records merged with the Mac's rules (`ChatTranscript`, shared
/// with `ChatSession`), in the Mac's record loop (`ChatCoordinator.receiveHelper` and `apply`): a page merges as one
/// historical batch, live records one by one.
struct MobileTranscript {
    private(set) var transcript = ChatTranscript()
    var turns: [ChatTurn] { transcript.turns }
    /// The turn the latest live start opened (a later prompt may steer it without another start).
    private(set) var activeTurnID: String?
    private(set) var revision = 0

    var isEmpty: Bool { transcript.isEmpty }

    /// Applies helper records. `historical`: a page (no live delivery state); `earlier`: an older page, prepended.
    /// `prepare` sees every item that is not from an earlier page before it is merged. Returns what was applied.
    @discardableResult
    mutating func apply(_ records: [HelperChat.Record], historical: Bool, earlier: Bool = false,
                        now: Date = Date(), prepare: (ChatItem, String) -> ChatItem = { item, _ in item }) -> [Applied] {
        var applied: [Applied] = []
        var batch: [ChatRecord] = []
        func merge(_ item: ChatItem, from record: ChatRecord) {
            if historical {
                batch.append(ChatRecord(key: record.key, turnID: record.turnID, date: record.date, action: .item(item),
                                        fileOffset: record.fileOffset))
            } else {
                transcript.insert(item, turnID: record.turnID, at: record.date, fileOffset: record.fileOffset)
            }
        }
        for record in transcript.index.decode(records, historical: historical, earlier: earlier, now: now)
        where transcript.index.seen.insert(record.key).inserted {
            switch record.action {
            case .started:
                if historical { batch.append(record) } else { transcript.turn(record.turnID, at: record.date, fileOffset: record.fileOffset) }
                if !earlier { activeTurnID = record.turnID }
                applied.append(.started(record.turnID))
            case .ended:
                if historical { batch.append(record) } else {
                    let index = transcript.turn(record.turnID, at: record.date, fileOffset: record.fileOffset)
                    transcript.turns[index].ended = record.date
                }
                applied.append(.ended(record.turnID))
            case .compacted:
                merge(ChatItem(id: record.key, kind: .notice, text: "Conversation compacted"), from: record)
            case .item(let item):
                // A live user record can confirm the prompt shown while it was sent (ChatCoordinator.apply).
                let item = earlier ? item : prepare(item, record.turnID)
                merge(item, from: record)
                applied.append(.item(item, turn: record.turnID))
            case .commandOutput(let text) where !historical && !earlier:
                applied.append(.output(text))
            default: break
            }
        }
        if historical { transcript.mergeHistorical(batch) }
        revision += 1
        return applied
    }

    enum Applied {
        case started(String)
        case ended(String)
        case item(ChatItem, turn: String)
        /// What a native command printed (`output` records, Claude's shell mode): the command's result, not a row.
        case output(String)
    }

    /// A transcript replaced in place (a Pi tree switch, `replace` records): the history goes, identity stays.
    mutating func clear() { self = MobileTranscript() }

    /// A tool whose full output `chat.tools` returned: the same id merges into its row.
    mutating func replaceTool(_ record: HelperChat.Record) {
        guard case .item(let item)? = record.display?.action else { return }
        for index in transcript.turns.indices {
            if let row = transcript.turns[index].items.firstIndex(where: { $0.id == item.id || $0.source?.id == item.id }) {
                var updated = transcript.turns[index].items[row]
                updated.output = item.output
                updated.source = record
                transcript.turns[index].items[row] = updated
                revision += 1
                return
            }
        }
    }
}

// MARK: What the thread shows

/// A turn's steps and duration: the caption under its last agent bubble ("5 steps · 1m 26s", M4a) and the steps of
/// message details (M5b). Steps are the turn's tool rows as the Mac groups them (ToolOrchestration.coalesced, a patch
/// wrapper folded into its patch), so the count is what the Mac's tool groups hold; the duration is the turn's
/// `ended - started`, unknown for a turn read without times.
struct ChatTurnSummary: Equatable {
    var steps: [ChatItem]
    var duration: TimeInterval?

    init(steps: [ChatItem], duration: TimeInterval?) {
        self.steps = steps
        self.duration = duration
    }

    init(_ turn: ChatTurn) {
        steps = Self.displayed(turn.items, turnID: turn.id).filter { $0.kind == .tool }
        if let ended = turn.ended, turn.started.timeIntervalSince1970 > 0, ended >= turn.started {
            duration = ended.timeIntervalSince(turn.started)
        } else { duration = nil }
    }

    /// "5 steps · 1m 26s"; nil when there is neither.
    var caption: String? {
        var parts: [String] = []
        if !steps.isEmpty { parts.append("\(steps.count) \(steps.count == 1 ? "step" : "steps")") }
        if let duration { parts.append(Self.elapsed(duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Mac's elapsed text (`ChatTranscript.elapsed`, shared).
    static func elapsed(_ interval: TimeInterval) -> String { ChatTranscript.elapsed(interval) }

    /// The Mac's displayed items (`ChatPatch.displayedItems`, shared).
    static func displayed(_ items: [ChatItem], turnID: String) -> [ChatItem] {
        ChatPatch.displayedItems(items, turnID: turnID)
    }
}

/// One row of the thread (M4a): bubbles are text only; tools, reasoning and turn markers become captions and steps.
struct ChatThreadRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        /// An agent message; `summary` is set on the last one of an ended turn.
        case agent(summary: ChatTurnSummary?)
        /// Claude's thinking (`inline_reasoning`, `ChatItem.isNarration`): shown inline, as on the Mac.
        case thinking
        case notice
    }
    let id: String
    let kind: Kind
    let item: ChatItem
    let turnID: String
    /// When the record says it was written (nil for records read without times).
    let time: Date?
}

extension MobileTranscript {
    /// The thread's rows in order. A turn's caption goes under its last agent message once the turn has ended.
    var rows: [ChatThreadRow] {
        var rows: [ChatThreadRow] = []
        for turn in turns {
            let items = turn.items
            let lastAgent = items.lastIndex { $0.kind == .assistant }
            for (index, item) in items.enumerated() {
                let time = item.source?.time_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                let id = item.rowID ?? "\(turn.id.utf8.count):\(turn.id):\(item.id)"
                switch item.kind {
                case .user:
                    rows.append(.init(id: id, kind: .user, item: item, turnID: turn.id, time: time))
                case .assistant:
                    let summary = index == lastAgent && turn.ended != nil ? ChatTurnSummary(turn) : nil
                    rows.append(.init(id: id, kind: .agent(summary: summary), item: item, turnID: turn.id, time: time))
                case .notice:
                    rows.append(.init(id: id, kind: .notice, item: item, turnID: turn.id, time: time))
                case .reasoning where item.isNarration && !item.text.isEmpty:
                    rows.append(.init(id: id, kind: .thinking, item: item, turnID: turn.id, time: time))
                case .tool, .reasoning: break
                }
            }
        }
        return rows
    }

    /// The live turn: the active one while it has not ended.
    var openTurn: ChatTurn? {
        guard let id = activeTurnID, let turn = turns.last(where: { $0.id == id }), turn.ended == nil else { return nil }
        return turn
    }

    /// The newest agent message (the Agents preview, M3a).
    var lastAgentItem: ChatItem? {
        turns.reversed().lazy.compactMap { $0.items.last { $0.kind == .assistant } }.first
    }

    /// When the newest record was written.
    var lastActivity: Date? {
        turns.reversed().lazy.compactMap { turn in
            turn.items.compactMap { $0.source?.time_ms }.max().map { Date(timeIntervalSince1970: Double($0) / 1000) }
                ?? (turn.started.timeIntervalSince1970 > 0 ? turn.ended ?? turn.started : nil)
        }.first
    }

    /// The turn holding `item` (message details).
    func turn(containing rowID: String) -> ChatTurn? {
        turns.first { turn in turn.items.contains { ($0.rowID ?? "\(turn.id.utf8.count):\(turn.id):\($0.id)") == rowID } }
    }
}

extension ChatThreadRow: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
