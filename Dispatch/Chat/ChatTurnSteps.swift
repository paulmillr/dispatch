import Foundation

/// One step of a turn as message details list it (the phone's M5f live log and M5b step list, the Mac's message
/// info): a kind, what it acted on (a path relative to the conversation's directory, or the command) and a short
/// result. Built from the shared tool presentation (ToolPresentation), never from tool-specific parsing of its own.
struct ChatStep: Identifiable, Equatable {
    enum Kind: Equatable {
        case read, patch, run, search, think, web, tool

        /// M5b's word and M5f's badge (upper-cased there).
        var label: String {
            switch self {
            case .read: "Read"; case .patch: "Patch"; case .run: "Run"; case .search: "Search"
            case .think: "Think"; case .web: "Web"; case .tool: "Tool"
            }
        }
    }

    let item: ChatItem
    let kind: Kind
    let title: String
    /// "+4 −1", "1 failed · exit 1", the last line of a command's output; nil when there is nothing short to say.
    let detail: String?
    let additions: Int
    let deletions: Int
    let failed: Bool
    let running: Bool
    var id: String { item.id }

    init(_ item: ChatItem, directory: String?) {
        self.item = item
        let directory = directory ?? item.directory ?? ""
        if item.kind == .reasoning {
            kind = .think
            let rawTitle = item.isNarration ? ChatThinkingFold.headline(item.text)
                : item.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Thinking"
            title = TextRendering.visible(TextRendering.prefix(rawTitle, scalars: 512).text)
            detail = nil; additions = 0; deletions = 0; failed = false; running = !item.completed
            return
        }
        let tool = ToolPresentation(item)
        let category = item.source?.tool?.kind
        if tool.isPatch || ChatPatch.isPatchOperation(item) || category == "patch" {
            kind = .patch
        } else if tool.readCommand != nil || category == "read" || tool.title == "Read" {
            kind = .read
        } else if category == "search" || tool.title == "Search" || item.source?.tool?.search != nil {
            // Before shell: an `rg` or `grep` run is a search, as the Mac's tool cards title it.
            kind = .search
        } else if tool.commandPresentation != nil || category == "shell" || item.source?.tool?.shell != nil {
            kind = .run
        } else if WebToolPresentation.matches(item.title) {
            kind = .web
        } else { kind = .tool }
        // A patch that did not apply (declined, failed, interrupted) changed nothing: its state shows, not its counts
        // (ChatToolCard's "Patch declined").
        let unapplied = item.patch.flatMap { [.interrupted, .failed, .declined].contains($0.state) ? $0.state : nil }
        additions = unapplied == nil ? tool.additions : 0
        deletions = unapplied == nil ? tool.deletions : 0
        failed = tool.failed || unapplied != nil
        running = !item.completed
        // Relative to the conversation's directory, else to the directory the agent recorded for the call.
        let bases = [directory, item.directory ?? "", item.source?.tool?.directory ?? ""].filter { !$0.isEmpty }
        func relative(_ path: String) -> String {
            for directory in bases {
                let base = directory.hasSuffix("/") ? directory : directory + "/"
                if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
            }
            return path
        }
        switch kind {
        case .patch where !tool.documents.isEmpty:
            title = TextRendering.visible(TextRendering.prefix(
                tool.documents.map { relative($0.path) }.joined(separator: ", "), scalars: 512).text)
        case .read where tool.readCommand != nil:
            title = TextRendering.visible(TextRendering.prefix(relative(tool.readCommand!.path), scalars: 512).text)
        case .read:
            let path = (ToolPresentation.json(item.text) as? [String: Any])?["file_path"] as? String
            title = TextRendering.visible(TextRendering.prefix(
                path.map(relative) ?? tool.displaySummary(in: directory), scalars: 512).text)
        case .run:
            let command = item.source?.tool?.shell?.command ?? tool.input
            let rawTitle = command.split(whereSeparator: \.isNewline).first.map(String.init) ?? tool.displaySummary(in: directory)
            title = TextRendering.visible(TextRendering.prefix(rawTitle, scalars: 512).text)
        default:
            let summary = tool.displaySummary(in: directory)
            title = TextRendering.visible(TextRendering.prefix(
                summary.isEmpty ? tool.displayTitle : summary, scalars: 512).text)
        }
        switch kind {
        case .patch:
            detail = unapplied.map { "Patch " + $0.rawValue } ?? (additions + deletions > 0 ? "+\(additions) −\(deletions)" : nil)
        case .run:
            let last = tool.output.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
            let exit = tool.exitCode.flatMap { $0 == 0 ? nil : "exit \($0)" }
            detail = [last.map { TextRendering.visible(TextRendering.prefix($0, scalars: 80).text) }, exit]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        default:
            detail = nil
        }
    }

    /// A turn's steps, in order: its tools as the caption counts them, and its reasoning summaries in the live log
    /// (Claude's thinking is a row of the thread itself until its turn folds: `thinking` lists it then).
    static func steps(_ turn: ChatTurn, directory: String?, reasoning: Bool, thinking: Bool = false) -> [ChatStep] {
        ChatTurnSummary.displayed(turn.items, turnID: turn.id)
            .filter { $0.kind == .tool || reasoning && $0.kind == .reasoning && !$0.isNarration && !$0.text.isEmpty
                || thinking && $0.isNarration && !$0.text.isEmpty }
            .map { ChatStep($0, directory: directory) }
    }

    /// The open turn's steps since the agent last wrote (a message or Claude's thinking), with reasoning summaries: the
    /// Mac's live tool group, which its header counts. The working row's count and log.
    static func current(_ turn: ChatTurn, directory: String?) -> [ChatStep] {
        let items = ChatTurnSummary.displayed(turn.items, turnID: turn.id)
        let start = items.lastIndex { $0.kind == .assistant || $0.kind == .reasoning && $0.isNarration && !$0.text.isEmpty }
            .map { $0 + 1 } ?? 0
        return items[start...]
            .filter { $0.kind == .tool || $0.kind == .reasoning && !$0.isNarration && !$0.text.isEmpty }
            .map { ChatStep($0, directory: directory) }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// When a turn's Claude thinking leaves the thread, on every surface: the Mac folds it into the turn's step group, the
/// phone into message details' steps, and the watch leaves it out.
enum ChatThinkingFold {
    /// The turn ended on a reply and has thinking to fold. One stopped or failed mid-work keeps it: the only account of it.
    static func folds(_ items: [ChatItem], ended: Date?) -> Bool {
        guard ended != nil, items.contains(where: { $0.isNarration && !$0.text.isEmpty }) else { return false }
        return items.last { $0.kind == .assistant || $0.kind == .tool || $0.isNarration }?.kind == .assistant
    }

    /// A thought's one line in a step list: its first line, without Markdown's code and bold marks.
    static func headline(_ text: String) -> String {
        (text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Thinking")
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    }
}

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

/// What message details say of a turn (the phone's M5b, the Mac's message info).
extension ChatTurnSummary {
    /// "10:28 – 10:32 · 4m 12s" (the end with its day when the day changed, "Yesterday 23:58 – 00:03"); the start alone
    /// while working; nil for a turn read without times.
    static func span(_ turn: ChatTurn?, duration: TimeInterval?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let turn, turn.started.timeIntervalSince1970 > 0 else { return nil }
        let start = moment(turn.started, now: now, calendar: calendar)
        guard let ended = turn.ended, ended.timeIntervalSince1970 > 0, ended >= turn.started else { return start }
        let end = calendar.isDate(ended, inSameDayAs: turn.started)
            ? clock(ended, calendar: calendar) : moment(ended, now: now, calendar: calendar)
        return [start + " – " + end, duration.map(Self.elapsed)].compactMap { $0 }.joined(separator: " · ")
    }

    /// A time as the thread's corners say it ("10:32", "Yesterday 10:32", "Thu 10:32"), with its time of day past a
    /// week too ("Oct 12, 10:32"), where the corner says the date alone.
    static func moment(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day = Self.time(date, now: now, calendar: calendar)
        let clock = Self.clock(date, calendar: calendar)
        return day.contains(clock) ? day : day + ", " + clock
    }

    static func clock(_ date: Date, calendar: Calendar) -> String {
        date.formatted(Date.FormatStyle(locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
                                        timeZone: calendar.timeZone).hour().minute())
    }

    /// "48.2K in · 3.1K out".
    static func tokens(_ usage: ChatUsage) -> String? {
        [usage.input.map { compact($0) + " in" }, usage.output.map { compact($0) + " out" }].compactMap { $0 }
            .joined(separator: " · ").nilIfEmpty
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

/// Message details' step list, folded (M1): up to `threshold` steps show as they are; past it the patches, the failed
/// steps and the last step stay, and each run of two or more steps between them folds into one row that says what they
/// did ("Read 5 files, searched 3 times"). A run of one shows: a fold would hide no room.
enum ChatStepFold {
    static let threshold = 8

    enum Entry: Equatable, Identifiable {
        case step(Int)
        case fold(Range<Int>, String)

        var id: String {
            switch self {
            case .step(let index): "step-\(index)"
            case .fold(let range, _): "fold-\(range.lowerBound)"
            }
        }
    }

    static func entries(_ steps: [ChatStep]) -> [Entry] {
        guard steps.count > threshold else { return steps.indices.map(Entry.step) }
        var entries: [Entry] = [], run: [Int] = []
        func flush() {
            if run.count == 1 { entries.append(.step(run[0])) }
            else if let first = run.first, let last = run.last {
                entries.append(.fold(first..<last + 1, summary(steps[first...last])))
            }
            run = []
        }
        for index in steps.indices {
            let step = steps[index]
            if step.kind == .patch || step.failed || index == steps.count - 1 {
                flush()
                entries.append(.step(index))
            } else { run.append(index) }
        }
        flush()
        return entries
    }

    /// What a run of steps did, by kind in the order each first appears: "Read 5 files, searched 3 times, ran 2 commands".
    static func summary(_ steps: ArraySlice<ChatStep>) -> String {
        var order: [ChatStep.Kind] = [], counts: [ChatStep.Kind: Int] = [:]
        for step in steps {
            if counts[step.kind] == nil { order.append(step.kind) }
            counts[step.kind, default: 0] += 1
        }
        func times(_ count: Int) -> String { count == 1 ? "once" : count == 2 ? "twice" : "\(count) times" }
        let parts = order.map { kind -> String in
            let count = counts[kind] ?? 0
            switch kind {
            case .read: return "read " + ChatTurnSummary.count(count, "file")
            case .search: return "searched " + times(count)
            case .run: return "ran " + ChatTurnSummary.count(count, "command")
            case .patch: return "patched " + ChatTurnSummary.count(count, "file")
            case .think: return "thought " + times(count)
            case .web: return "used the web " + times(count)
            case .tool: return "used " + ChatTurnSummary.count(count, "tool")
            }
        }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension ChatStep.Kind {
    /// Message details' glyph for the kind (its word is the glyph's VoiceOver label).
    var symbol: String {
        switch self {
        case .read: "doc.text"
        case .patch: "pencil.line"
        case .run: "apple.terminal"
        case .search: "magnifyingglass"
        case .think: "brain"
        case .web: "globe"
        case .tool: "wrench.and.screwdriver"
        }
    }
}
