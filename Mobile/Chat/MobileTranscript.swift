import Foundation

/// One conversation's transcript on the phone: the helper's records merged into turns and items with the Mac's rules
/// (`ChatSession.turn`, `insert` and `ChatCoordinator.apply`; ChatModels.swift). It duplicates that part of the Mac's
/// `ChatSession` until the planned split into shared transcript state and Mac view state lands (docs/ios.md).
struct MobileTranscript {
    private(set) var turns: [ChatTurn] = []
    /// The turn the latest live start opened (a later prompt may steer it without another start).
    private(set) var activeTurnID: String?
    private struct ItemIdentity: Hashable {
        let turn: String
        let item: String
    }
    private var itemDates: [ItemIdentity: Date] = [:]
    private var itemOffsets: [ItemIdentity: UInt64] = [:]
    /// Record content keys already applied (a repeated record is a no-op).
    private var seen: Set<String> = []
    /// Positions given to records so far: they arrive in transcript order (ChatCoordinator.receiveHelper).
    private var positions: ClosedRange<UInt64>?
    /// The newest record id of any kind the transcript holds, and of the newest agent message.
    private(set) var latestRecordID: String?
    private(set) var revision = 0

    var isEmpty: Bool { turns.allSatisfy { $0.items.isEmpty } }

    /// Applies helper records. `historical`: a page (no live delivery state); `earlier`: an older page, prepended.
    /// `prepare` sees every item that is not from an earlier page before it is merged. Returns what was applied.
    @discardableResult
    mutating func apply(_ records: [HelperChat.Record], historical: Bool, earlier: Bool = false,
                        now: Date = Date(), prepare: (ChatItem, String) -> ChatItem = { item, _ in item }) -> [Applied] {
        let count = UInt64(records.count), span = positions ?? (1 << 62)...(1 << 62)
        let start = earlier ? span.lowerBound - count : span.upperBound + 1
        positions = min(start, span.lowerBound)...max(start + count, span.upperBound)
        var applied: [Applied] = []
        for (index, record) in records.enumerated() {
            guard var shown = record.display(at: historical ? Date(timeIntervalSince1970: 0) : now) else { continue }
            shown.fileOffset = start + UInt64(index)
            guard seen.insert(shown.key).inserted else { continue }
            switch shown.action {
            case .started:
                _ = turn(shown.turnID, at: shown.date, fileOffset: shown.fileOffset)
                if !earlier { activeTurnID = shown.turnID }
                applied.append(.started(shown.turnID))
            case .ended:
                let index = turn(shown.turnID, at: shown.date, fileOffset: shown.fileOffset)
                turns[index].ended = shown.date
                applied.append(.ended(shown.turnID))
            case .item(let item):
                // A live user record can confirm the prompt shown while it was sent (ChatCoordinator.apply).
                let item = earlier ? item : prepare(item, shown.turnID)
                insert(item, turnID: shown.turnID, at: shown.date, fileOffset: shown.fileOffset)
                applied.append(.item(item, turn: shown.turnID))
            default: break
            }
            if !earlier { latestRecordID = record.id }
        }
        if latestRecordID == nil, let last = records.last { latestRecordID = last.id }
        revision += 1
        return applied
    }

    enum Applied {
        case started(String)
        case ended(String)
        case item(ChatItem, turn: String)
    }

    /// A transcript replaced in place (a Pi tree switch, `replace` records): the history goes, identity stays.
    mutating func clear() { self = MobileTranscript() }

    /// A tool whose full output `chat.tools` returned: the same id merges into its row.
    mutating func replaceTool(_ record: HelperChat.Record) {
        guard case .item(let item)? = record.display?.action else { return }
        for index in turns.indices {
            if let row = turns[index].items.firstIndex(where: { $0.id == item.id || $0.source?.id == item.id }) {
                var updated = turns[index].items[row]
                updated.output = item.output
                updated.source = record
                turns[index].items[row] = updated
                revision += 1
                return
            }
        }
    }

    // MARK: The Mac's merge (ChatSession.turn and insert, ChatModels.swift)

    private mutating func turn(_ id: String, at date: Date, fileOffset: UInt64?) -> Int {
        func precedes(_ a: ChatTurn, _ b: ChatTurn) -> Bool {
            a.started == b.started ? (a.fileOffset ?? .max) < (b.fileOffset ?? .max) : a.started < b.started
        }
        if let index = turns.firstIndex(where: { $0.id == id }) {
            let started = date.timeIntervalSince1970 > 0 ? min(turns[index].started, date) : turns[index].started
            let offset = fileOffset.map { min(turns[index].fileOffset ?? $0, $0) } ?? turns[index].fileOffset
            guard started != turns[index].started || offset != turns[index].fileOffset else { return index }
            turns[index].started = started; turns[index].fileOffset = offset
            turns.sort(by: precedes)
            return turns.firstIndex(where: { $0.id == id })!
        }
        let value = ChatTurn(id: id, started: date, fileOffset: fileOffset)
        var low = 0, high = turns.count
        while low < high {
            let middle = (low + high) / 2
            if precedes(value, turns[middle]) { high = middle } else { low = middle + 1 }
        }
        turns.insert(value, at: low)
        return low
    }

    private mutating func insert(_ item: ChatItem, turnID: String, at date: Date, fileOffset: UInt64?) {
        let index = turn(turnID, at: date, fileOffset: fileOffset)
        let date = item.source == nil ? date : Date(timeIntervalSince1970: 0)
        var turn = turns[index]
        var identity = item.id
        let existing = turn.items.firstIndex(where: item.continues)
        if let existing {
            let updated = item.merged(over: turn.items[existing], historical: false)
            identity = updated.id
            if updated != turn.items[existing] { turn.items[existing] = updated }
        } else {
            turn.items.append(item)
        }
        let key = ItemIdentity(turn: turnID, item: identity)
        let previousDate = itemDates[key], previousOffset = itemOffsets[key]
        itemDates[key] = min(itemDates[key] ?? date, date)
        if let fileOffset { itemOffsets[key] = min(itemOffsets[key] ?? fileOffset, fileOffset) }
        let dates = itemDates, offsets = itemOffsets
        func precedes(_ lhs: ChatItem, _ rhs: ChatItem) -> Bool {
            let a = ItemIdentity(turn: turnID, item: lhs.id), b = ItemIdentity(turn: turnID, item: rhs.id)
            let ad = dates[a] ?? date, bd = dates[b] ?? date
            return ad == bd ? (offsets[a] ?? .max) < (offsets[b] ?? .max) : ad < bd
        }
        if existing == nil {
            let added = turn.items.removeLast()
            var low = 0, high = turn.items.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(added, turn.items[middle]) { high = middle } else { low = middle + 1 }
            }
            turn.items.insert(added, at: low)
        } else if previousDate != itemDates[key] || previousOffset != itemOffsets[key] {
            turn.items.sort(by: precedes)
        }
        turns[index] = turn
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

    /// The Mac's elapsed text (AgentWorkingAnimation.elapsedText): 52s, 1m 26s, 2h 5m.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    /// The Mac's displayed items (ChatSession.displayedItems): orchestration coalesced, a wrapper that only repeats
    /// its patch folded into the patch.
    static func displayed(_ items: [ChatItem], turnID: String) -> [ChatItem] {
        var result: [ChatItem] = []
        for item in ToolOrchestration.coalesced(items, turnID: turnID) {
            if let previous = result.last, !ChatPatch.isPatchOperation(previous), ChatPatch.isPatchOperation(item),
               ChatPatch.duplicates(wrapper: previous, patch: item) {
                result[result.count - 1] = item
                continue
            }
            result.append(item)
        }
        return result
    }
}

/// One row of the thread (M4a): bubbles are text only; tools, reasoning and turn markers become captions and steps.
struct ChatThreadRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        /// An agent message; `summary` is set on the last one of an ended turn.
        case agent(summary: ChatTurnSummary?)
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
