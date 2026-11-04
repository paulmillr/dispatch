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
    /// `prepare` sees every item that is not from an earlier page before it is merged; `arrived` hears the row id of
    /// each reply a live record added, and whether it is complete (the typed reveal). Returns what was applied.
    @discardableResult
    mutating func apply(_ records: [HelperChat.Record], historical: Bool, earlier: Bool = false,
                        now: Date = Date(), prepare: (ChatItem, String) -> ChatItem = { item, _ in item },
                        arrived: (String, _ completed: Bool) -> Void = { _, _ in }) -> [Applied] {
        var applied: [Applied] = []
        var batch: [ChatRecord] = []
        func merge(_ item: ChatItem, from record: ChatRecord) {
            if historical {
                batch.append(ChatRecord(key: record.key, turnID: record.turnID, date: record.date, action: .item(item),
                                        fileOffset: record.fileOffset))
            } else {
                let insertion = transcript.insert(item, turnID: record.turnID, at: record.date, fileOffset: record.fileOffset)
                if insertion.added, item.kind == .assistant {
                    arrived(item.rowID ?? "\(record.turnID.utf8.count):\(record.turnID):\(item.id)", item.completed)
                }
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

/// A turn's steps, duration and changes: the corner of its last agent bubble ("3 files +127 −22 · 10:17", S6d) and
/// the steps of message details (M5b). Steps are the turn's tool rows as the Mac groups them
/// (ToolOrchestration.coalesced, a patch wrapper folded into its patch), so the count is what the Mac's tool groups
/// hold; the duration is the turn's `ended - started`, unknown for a turn read without times; the files are the distinct
/// paths its applied patches touched, with their added and removed lines summed (a declined, failed or interrupted
/// patch changed nothing). The structured fields are what other surfaces (the watch, Spaces rows) show the same way.
struct ChatTurnSummary: Equatable {
    var steps: [ChatItem]
    var duration: TimeInterval?
    /// When the turn ended; nil for a turn read without times.
    var ended: Date?
    /// Distinct paths the turn's applied patches touched, in the order first touched.
    var files: [String] = []
    var additions = 0
    var deletions = 0
    /// Every step read a file (a read-only side question's turn): "Read 3 files".
    var reads: [String]? = nil

    init(steps: [ChatItem], duration: TimeInterval?, ended: Date? = nil) {
        self.steps = steps
        self.duration = duration
        self.ended = ended
        tally()
    }

    init(_ turn: ChatTurn) {
        steps = Self.displayed(turn.items, turnID: turn.id).filter { $0.kind == .tool }
        if let ended = turn.ended, turn.started.timeIntervalSince1970 > 0, ended >= turn.started {
            duration = ended.timeIntervalSince(turn.started)
        } else { duration = nil }
        // A turn read without times ends at the epoch (`ChatTranscript`'s historical date).
        ended = turn.ended.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        tally()
    }

    /// The whole seconds of `duration`.
    var seconds: Int? { duration.map { Int($0) } }

    private mutating func tally() {
        var seen = Set<String>(), files: [String] = [], reads: [String] = [], allRead = !steps.isEmpty
        for step in steps {
            if let change = Self.change(of: step) {
                additions += change.additions
                deletions += change.deletions
                for path in change.paths where seen.insert(path).inserted { files.append(path) }
            }
            if allRead, let path = Self.readPath(step) {
                if !reads.contains(path) { reads.append(path) }
            } else { allRead = false }
        }
        self.files = files
        self.reads = allRead ? reads : nil
    }

    /// What an applied patch step changed: its files and line counts (ChatStep's rule); nil for any other step.
    static func change(of item: ChatItem) -> (paths: [String], additions: Int, deletions: Int)? {
        guard item.kind == .tool else { return nil }
        let tool = ToolPresentation(item)
        guard tool.isPatch || ChatPatch.isPatchOperation(item) || item.source?.tool?.kind == "patch" else { return nil }
        if let state = item.patch?.state, [.interrupted, .failed, .declined].contains(state) { return nil }
        return (tool.documents.map(\.path), tool.additions, tool.deletions)
    }

    /// The file a read step read; nil for any other step.
    private static func readPath(_ item: ChatItem) -> String? {
        if let read = item.source?.tool?.read { return read.path }
        guard item.source?.tool?.kind == "read" || item.title == "Read" else { return nil }
        return ToolPresentation(item).readCommand?.path
            ?? (ToolPresentation.json(item.text) as? [String: Any])?["file_path"] as? String
    }

    /// "5 steps · 1m 26s"; nil when there is neither (message details' heading).
    var caption: String? {
        var parts: [String] = []
        if !steps.isEmpty { parts.append(Self.count(steps.count, "step")) }
        if let duration { parts.append(Self.elapsed(duration)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The corner of the turn's last bubble (S6d), where messengers put a message's time: what the turn changed and when
    /// it ended. "idempotent.ts +38 −4 · 10:14" for one file (its name), "3 files +127 −22 · 10:17" for more (grouped
    /// digits), "Read 12 files · 10:17" when nothing changed and each of three or more steps read a file, "40 steps ·
    /// 10:17" for three or more other steps; nil for a plain answer (two steps or fewer, nothing changed). Without an
    /// end time the same without "· time". The time is the locale's short time today, "Yesterday 10:17", the weekday
    /// within a week ("Thu 10:17"), else the date ("Oct 12", with the year when it is not `now`'s). `fits` says whether a
    /// text fits the bubble's line (`ChatCornerMetrics`): a file name too long for it is shortened in its middle
    /// ("PaymentWeb…test.ts"), the counts and time kept.
    func corner(now: Date, calendar: Calendar, fits: (String) -> Bool = { _ in true }) -> String? {
        guard let subject = corner(calendar: calendar) else { return nil }
        let time = ended.map { " · " + Self.time($0, now: now, calendar: calendar) } ?? ""
        let text = subject.text + time
        guard !fits(text), files.count == 1, let name = files.first.map({ ($0 as NSString).lastPathComponent }),
              let range = subject.text.range(of: name) else { return text }
        let rest = subject.text[range.upperBound...] + time
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.count > 6 ? "" : "." + ext
        let stem = Array(name.dropLast(suffix.count))
        for keep in stride(from: stem.count - 1, through: 2, by: -1) {
            let short = String(stem.prefix((keep + 1) / 2)) + "…" + String(stem.suffix(keep / 2)) + suffix
            if fits(short + rest) { return short + rest }
        }
        return "…" + suffix + rest
    }

    /// The corner for VoiceOver: "idempotent.ts, 38 added, 4 removed, 10:14".
    func spokenCorner(now: Date, calendar: Calendar) -> String? {
        corner(calendar: calendar).map { subject in
            ([subject.spoken] + (ended.map { [Self.time($0, now: now, calendar: calendar)] } ?? [])).joined(separator: ", ")
        }
    }

    /// The corner's subject, drawn and spoken; nil for a plain answer.
    private func corner(calendar: Calendar) -> (text: String, spoken: String)? {
        let locale = calendar.locale ?? .autoupdatingCurrent
        func number(_ value: Int) -> String { value.formatted(.number.locale(locale)) }
        if let first = files.first {
            let subject = files.count == 1 ? (first as NSString).lastPathComponent : "\(number(files.count)) files"
            return ("\(subject) +\(number(additions)) −\(number(deletions))",
                    "\(subject), \(number(additions)) added, \(number(deletions)) removed")
        }
        guard steps.count >= 3 else { return nil }
        let text = if let reads, !reads.isEmpty { "Read " + Self.count(reads.count, "file", number: number) }
            else { Self.count(steps.count, "step", number: number) }
        return (text, text)
    }

    /// When a turn ended, as the corner says it: the short time today, "Yesterday 10:17", "Thu 10:17" within a week,
    /// else "Oct 12" ("Oct 12, 2025" in another year).
    static func time(_ date: Date, now: Date, calendar: Calendar) -> String {
        let locale = calendar.locale ?? .autoupdatingCurrent
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let time = date.formatted(style.hour().minute())
        var days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        // A host's clock a little ahead of the phone's around midnight: a turn that just ended is today's.
        if days < 0, date.timeIntervalSince(now) < 15 * 60 { days = 0 }
        switch days {
        case 0: return time
        case 1: return yesterday(locale: locale, calendar: calendar) + " " + time
        case 2..<7: return date.formatted(style.weekday(.abbreviated)) + " " + time
        default:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return date.formatted(sameYear ? style.month(.abbreviated).day() : style.month(.abbreviated).day().year())
        }
    }

    /// The locale's word for yesterday ("Yesterday", "Gestern"), as relative date formatting says it.
    static func yesterday(locale: Locale, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        // Relative to the real day: the word is all that is taken.
        return formatter.string(from: calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date())
    }

    /// "1 step", "5 steps".
    static func count(_ count: Int, _ noun: String, number: (Int) -> String = { "\($0)" }) -> String {
        "\(number(count)) \(noun)\(count == 1 ? "" : "s")"
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
        /// Claude's thinking (`inline_reasoning`, `ChatItem.isNarration`): an agent bubble of its own.
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
