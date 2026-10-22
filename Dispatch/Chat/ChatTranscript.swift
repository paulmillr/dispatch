import Foundation

/// One conversation's transcript: agent records merged into turns and items in transcript order. The merge rules live
/// here once, for the Mac's `ChatSession` (which adds its view state around them: arrivals, unread, row caches) and the
/// iPhone's `MobileTranscript`. A session that keeps `turns` itself (observed, as the Mac's does) passes it in with its
/// `Index`; the value type holds both.
struct ChatTranscript {
    struct ItemIdentity: Hashable {
        let turn: String
        let item: String
    }

    /// The ordering keys and delivery state beside the turns.
    struct Index {
        var itemDates: [ItemIdentity: Date] = [:]
        var itemOffsets: [ItemIdentity: UInt64] = [:]
        /// Record content keys already applied: a repeated record is a no-op.
        var seen: Set<String> = []
        /// Positions given to helper records so far: they arrive in transcript order, so an earlier page goes before
        /// everything shown and the rest after; equal times then order by position, as file offsets did.
        var positions: ClosedRange<UInt64>?

        /// Helper records as positioned chat records (`HelperChat.Record.display`); a page's records read without
        /// times (`historical`) date to the epoch.
        mutating func decode(_ records: [HelperChat.Record], historical: Bool, earlier: Bool, now: Date) -> [ChatRecord] {
            let count = UInt64(records.count), span = positions ?? (1 << 62)...(1 << 62)
            let start = earlier ? span.lowerBound - count : span.upperBound + 1
            positions = min(start, span.lowerBound)...max(start + count, span.upperBound)
            return records.enumerated().compactMap { index, record in
                record.display(at: historical ? Date(timeIntervalSince1970: 0) : now).map {
                    var shown = $0
                    shown.fileOffset = start + UInt64(index)
                    return shown
                }
            }
        }
    }

    /// What an insert did to the turn's rows.
    struct Insertion {
        /// A new row (no existing item continued).
        let added: Bool
        /// The rows differ from before.
        let changed: Bool
    }

    var turns: [ChatTurn] = []
    var index = Index()

    var isEmpty: Bool { turns.allSatisfy { $0.items.isEmpty } }

    /// How long a turn ran, as both apps print it: 52s, 1m 26s, 2h 5m.
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    @discardableResult
    mutating func turn(_ id: String, at date: Date = Date(), fileOffset: UInt64? = nil) -> Int {
        Self.turn(id, at: date, fileOffset: fileOffset, in: &turns)
    }

    @discardableResult
    mutating func insert(_ item: ChatItem, turnID: String, at date: Date = Date(), historical: Bool = false,
                         fileOffset: UInt64? = nil) -> Insertion {
        Self.insert(item, turnID: turnID, at: date, historical: historical, fileOffset: fileOffset, turns: &turns, index: &index)
    }

    mutating func mergeHistorical(_ records: [ChatRecord]) {
        Self.mergeHistorical(records, turns: &turns, index: &index)
    }

    /// The turn `id`, made where its start time and position put it, or moved there when a record gives it an
    /// earlier one.
    static func turn(_ id: String, at date: Date, fileOffset: UInt64?, in turns: inout [ChatTurn]) -> Int {
        func precedes(_ a: ChatTurn, _ b: ChatTurn) -> Bool {
            a.started == b.started ? (a.fileOffset ?? .max) < (b.fileOffset ?? .max) : a.started < b.started
        }
        if let index = turns.firstIndex(where: { $0.id == id }) {
            let started = date.timeIntervalSince1970 > 0 ? min(turns[index].started, date) : turns[index].started
            let offset = fileOffset.map { min(turns[index].fileOffset ?? $0, $0) } ?? turns[index].fileOffset
            // Almost every tool/reply updates an existing turn without changing
            // its ordering. Avoid sorting the entire conversation per record.
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

    /// An item merged into its turn: it continues an existing row (the same tool call, a streamed message) or takes
    /// its place by time and position.
    @discardableResult
    static func insert(_ item: ChatItem, turnID: String, at date: Date, historical: Bool, fileOffset: UInt64?,
                       turns: inout [ChatTurn], index state: inout Index) -> Insertion {
        let index = turn(turnID, at: date, fileOffset: fileOffset, in: &turns)
        let date = item.source == nil ? date : Date(timeIntervalSince1970: 0)
        var turn = turns[index]
        var identity = item.id
        let changed: Bool
        let existing = turn.items.firstIndex(where: item.continues)
        if let existing {
            let updated = item.merged(over: turn.items[existing], historical: historical)
            changed = updated != turn.items[existing]
            identity = updated.id
            if changed { turn.items[existing] = updated }
        } else {
            let added = unique(item) { id in turn.items.contains { $0.id == id } }
            identity = added.id
            turn.items.append(added); changed = true
        }
        let key = ItemIdentity(turn: turnID, item: identity)
        let previousDate = state.itemDates[key], previousOffset = state.itemOffsets[key]
        state.itemDates[key] = min(state.itemDates[key] ?? date, date)
        if let fileOffset { state.itemOffsets[key] = min(state.itemOffsets[key] ?? fileOffset, fileOffset) }
        let dates = state.itemDates, offsets = state.itemOffsets
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
        } else if previousDate != state.itemDates[key] || previousOffset != state.itemOffsets[key] {
            // Earlier history can supply an older timestamp/offset for an
            // existing live item. Preserve the stable tie order in that case.
            turn.items.sort(by: precedes)
        }
        if previousDate != state.itemDates[key] { turn.invalidatePresentation() }
        turns[index] = turn
        return Insertion(added: existing == nil, changed: changed)
    }

    /// Historical publication shares the live merge rules, but copies each
    /// affected item array once and publishes the conversation once per batch.
    /// Activity, configuration and prompt acknowledgement stay in the
    /// caller's ordered event loop.
    static func mergeHistorical(_ records: [ChatRecord], turns: inout [ChatTurn], index state: inout Index) {
        guard !records.isEmpty else { return }
        var updatedTurns = turns
        var turnIndices: [String: Int] = [:]
        var requiresIncrementalMerge = false
        let affectedTurns = Set(records.map(\.turnID))
        for (index, turn) in updatedTurns.enumerated() {
            if turnIndices[turn.id] != nil { requiresIncrementalMerge = true }
            else { turnIndices[turn.id] = index }
            if affectedTurns.contains(turn.id) {
                var identities: Set<String> = []
                for item in turn.items {
                    if !identities.insert(item.id).inserted || state.itemDates[ItemIdentity(turn: turn.id, item: item.id)] == nil {
                        requiresIncrementalMerge = true
                        break
                    }
                }
            }
        }
        // Directly restored snapshots may not have item ordering metadata, or
        // may contain repeated native IDs. Preserve the original first-match
        // and per-record fallback-date behavior for these exceptional inputs.
        if requiresIncrementalMerge {
            for record in records {
                switch record.action {
                case .item(let item):
                    insert(item, turnID: record.turnID, at: record.date, historical: true, fileOffset: record.fileOffset,
                           turns: &turns, index: &state)
                case .started:
                    _ = turn(record.turnID, at: record.date, fileOffset: record.fileOffset, in: &turns)
                case .ended:
                    let index = turn(record.turnID, at: record.date, fileOffset: record.fileOffset, in: &turns)
                    turns[index].ended = record.date
                default: break
                }
            }
            return
        }
        var turnRanks = Array(updatedTurns.indices)
        var itemsByTurn: [Int: [ChatRecord]] = [:]
        func turnPrecedes(_ a: Int, _ b: Int) -> Bool {
            let lhs = updatedTurns[a], rhs = updatedTurns[b]
            if lhs.started != rhs.started { return lhs.started < rhs.started }
            let leftOffset = lhs.fileOffset ?? .max, rightOffset = rhs.fileOffset ?? .max
            if leftOffset != rightOffset { return leftOffset < rightOffset }
            return turnRanks[a] < turnRanks[b]
        }
        for record in records {
            let index: Int
            if let existing = turnIndices[record.turnID] {
                index = existing
                let previous = updatedTurns[index]
                let started = record.date.timeIntervalSince1970 > 0 ? min(previous.started, record.date) : previous.started
                let offset = record.fileOffset.map { min(previous.fileOffset ?? $0, $0) } ?? previous.fileOffset
                if started != previous.started || offset != previous.fileOffset {
                    // A stable sort after a timestamp correction retains the
                    // order immediately before that correction, including prior
                    // corrections in this batch. Remember it before changing keys.
                    for (rank, position) in updatedTurns.indices.sorted(by: turnPrecedes).enumerated() {
                        turnRanks[position] = rank
                    }
                    updatedTurns[index].started = started
                    updatedTurns[index].fileOffset = offset
                }
            } else {
                index = updatedTurns.count
                turnIndices[record.turnID] = index
                updatedTurns.append(ChatTurn(id: record.turnID, started: record.date, fileOffset: record.fileOffset))
                turnRanks.append(index)
            }
            switch record.action {
            case .item: itemsByTurn[index, default: []].append(record)
            case .ended: updatedTurns[index].ended = record.date
            default: break
            }
        }
        for (index, items) in itemsByTurn {
            mergeHistoricalItems(items, into: &updatedTurns[index], index: &state)
        }
        let order = updatedTurns.indices.sorted(by: turnPrecedes)
        turns = order.map { updatedTurns[$0] }
    }

    /// `item` under an id no item of its turn has: another message under an id the agent reuses (Codex keys a prompt
    /// by its text, which attachment-only prompts share) gets one derived from its attachments.
    static func unique(_ item: ChatItem, taken: (String) -> Bool) -> ChatItem {
        guard taken(item.id) else { return item }
        var item = item
        let base = item.id + "#" + ChatItem.contentID(item.attachments.map { $0.path ?? $0.name }.joined(separator: "\n")).prefix(16)
        var id = base, count = 1
        while taken(id) { count += 1; id = base + "-\(count)" }
        item.id = id
        return item
    }

    private struct HistoricalTextIdentity: Hashable {
        let kind: ChatItem.Kind
        let text: String
        init?(_ item: ChatItem) {
            guard !item.id.hasPrefix("pi-"), [.user, .assistant, .reasoning].contains(item.kind) else { return nil }
            kind = item.kind; text = item.text
        }
    }

    private static func mergeHistoricalItems(_ records: [ChatRecord], into turn: inout ChatTurn, index state: inout Index) {
        var items = turn.items
        var identities = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        var textIdentities: [HistoricalTextIdentity: Set<Int>] = [:]
        var dates = items.map { state.itemDates[ItemIdentity(turn: turn.id, item: $0.id)] }
        var offsets = items.map { state.itemOffsets[ItemIdentity(turn: turn.id, item: $0.id)] }
        var ranks = Array(items.indices)
        for (index, item) in items.enumerated() {
            if let source = item.source { identities[source.id] = index }
            if let key = HistoricalTextIdentity(item) { textIdentities[key, default: []].insert(index) }
        }
        func precedes(_ a: Int, _ b: Int, fallback: Date) -> Bool {
            let leftDate = dates[a] ?? fallback, rightDate = dates[b] ?? fallback
            if leftDate != rightDate { return leftDate < rightDate }
            let leftOffset = offsets[a] ?? .max, rightOffset = offsets[b] ?? .max
            if leftOffset != rightOffset { return leftOffset < rightOffset }
            return ranks[a] < ranks[b]
        }
        for record in records {
            guard case .item(let item) = record.action else { continue }
            let date = item.source == nil ? record.date : Date(timeIntervalSince1970: 0)
            var existing = identities[item.source?.id ?? item.id]
            if let found = existing, item.carriesOtherAttachments(than: items[found]) { existing = nil }
            if let key = HistoricalTextIdentity(item), let candidates = textIdentities[key] {
                // The live path takes the first displayed match, which can be
                // an equal-text item before the item with the exact native ID.
                for candidate in candidates where item.continues(items[candidate]) {
                    if existing == nil || precedes(candidate, existing!, fallback: record.date) { existing = candidate }
                }
            }
            let index: Int
            if let existing {
                index = existing
                let previous = items[index], updated = item.merged(over: previous, historical: true)
                if updated != previous {
                    if let key = HistoricalTextIdentity(previous) { textIdentities[key]?.remove(index) }
                    items[index] = updated
                    if let key = HistoricalTextIdentity(updated) { textIdentities[key, default: []].insert(index) }
                }
                let date = min(dates[index] ?? date, date)
                let offset = record.fileOffset.map { min(offsets[index] ?? $0, $0) } ?? offsets[index]
                if date != dates[index] || offset != offsets[index] {
                    // Most pages add records without correcting existing keys.
                    // Only corrections need the current stable order captured;
                    // the item array itself is reordered once after the batch.
                    for (rank, position) in items.indices.sorted(by: { precedes($0, $1, fallback: record.date) }).enumerated() {
                        ranks[position] = rank
                    }
                    dates[index] = date; offsets[index] = offset
                }
            } else {
                index = items.count
                let item = unique(item) { identities[$0] != nil }
                items.append(item); identities[item.id] = index
                if let key = HistoricalTextIdentity(item) { textIdentities[key, default: []].insert(index) }
                let key = ItemIdentity(turn: turn.id, item: item.id)
                ranks.append(index)
                dates.append(min(state.itemDates[key] ?? date, date))
                offsets.append(record.fileOffset.map { min(state.itemOffsets[key] ?? $0, $0) } ?? state.itemOffsets[key])
            }
            if let source = items[index].source { identities[source.id] = index }
            let key = ItemIdentity(turn: turn.id, item: items[index].id)
            state.itemDates[key] = dates[index]
            state.itemOffsets[key] = offsets[index]
        }
        let fallback = records.last?.date ?? turn.started
        let order = items.indices.sorted { precedes($0, $1, fallback: fallback) }
        turn.items = order.map { items[$0] }
    }
}
