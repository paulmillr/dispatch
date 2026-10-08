import Foundation
import Observation
import CryptoKit
import OSLog

enum ChatPromptBoundary: Sendable {
    case local(Date)
    case preparingRemote
    case firstRemoteTurn

    func accepts(_ record: ChatRecord) -> Bool {
        switch self {
        case .local(let date): return record.date >= date
        case .preparingRemote: return false
        case .firstRemoteTurn: return true
        }
    }
}

struct ChatItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case user, assistant, reasoning, tool, notice }
    var id: String
    var kind: Kind
    var rowID: String?
    var text: String { didSet { presentationID = UUID() } }
    var title: String = "" { didSet { presentationID = UUID() } }
    var output: String = "" { didSet { presentationID = UUID() } }
    var completed = false { didSet { presentationID = UUID() } }
    var exitCode: Int? { didSet { presentationID = UUID() } }
    var patch: ChatPatch? { didSet { presentationID = UUID() } }
    var processID: String? { didSet { presentationID = UUID() } }
    var shellCommand: String? { didSet { presentationID = UUID() } }
    var commandSource: String? { didSet { presentationID = UUID() } }
    var source: HelperChat.Record? { didSet { presentationID = UUID() } }
    /// The directory the agent recorded for this tool call, when its input omits one.
    var directory: String? { didSet { presentationID = UUID() } }
    var hiddenPatchRequests: Set<String> = [] { didSet { presentationID = UUID() } }
    private(set) var presentationID = UUID()
    /// Claude's summarized thinking reads as short progress notes, so it is
    /// shown inline like a message instead of behind a disclosure.
    var isNarration: Bool { kind == .reasoning && (source?.inline_reasoning ?? id.hasPrefix("claude-")) }

    static func == (lhs: ChatItem, rhs: ChatItem) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.title == rhs.title &&
        lhs.output == rhs.output && lhs.completed == rhs.completed && lhs.exitCode == rhs.exitCode && lhs.patch == rhs.patch && lhs.processID == rhs.processID &&
        lhs.shellCommand == rhs.shellCommand && lhs.commandSource == rhs.commandSource && lhs.directory == rhs.directory && lhs.hiddenPatchRequests == rhs.hiddenPatchRequests && lhs.source == rhs.source
    }
    static func contentID(_ text: String) -> String {
        ChatRecord.contentKey(Data(text.utf8))
    }

    fileprivate func matches(_ previous: Self) -> Bool {
        if id == previous.id { return true }
        // Pi's native message/block identities already match live and saved
        // records. Repeated text in another message is a distinct item.
        if id.hasPrefix("pi-") || previous.id.hasPrefix("pi-") { return false }
        return [.user, .assistant, .reasoning].contains(kind) && kind == previous.kind && text == previous.text
    }

    fileprivate func merging(_ previous: Self, historical: Bool = false) -> Self {
        if let source, let previousSource = previous.source, previous.completed, !completed, kind == previous.kind {
            guard historical else {
                var kept = previous
                kept.source = previousSource.filled(from: source)
                return kept
            }
            var updated = previous.merging(self)
            updated.id = previous.id
            updated.rowID = previous.rowID ?? rowID
            return updated
        }
        var updated = self
        updated.source = previous.source.flatMap { source?.filled(from: $0) } ?? source ?? previous.source
        // Hooks and transcript records can arrive in either order. Preserve the
        // first row identity and any fields missing from the later record.
        updated.id = previous.id
        updated.rowID = previous.rowID ?? rowID
        if updated.text.isEmpty { updated.text = previous.text }
        // A live snapshot can predate a completed transcript read even when
        // it arrives afterward. Completion must preserve the final text too.
        if previous.completed, !completed, kind == previous.kind,
           kind == .assistant || kind == .reasoning { updated.text = previous.text }
        if updated.title.isEmpty { updated.title = previous.title }
        if updated.output.isEmpty { updated.output = previous.output }
        updated.completed = updated.completed || previous.completed
        updated.exitCode = updated.exitCode ?? previous.exitCode
        updated.processID = updated.processID ?? previous.processID
        updated.shellCommand = updated.shellCommand ?? previous.shellCommand
        updated.commandSource = updated.commandSource ?? previous.commandSource
        updated.directory = updated.directory ?? previous.directory
        if updated.patch == nil { updated.patch = previous.patch }
        // Delayed history or a repeated partial snapshot must not roll back a final patch.
        let incomingPreview = updated.patch.map { $0.state == .generating || $0.state == .applying } ?? false
        if let patch = previous.patch, (previous.completed && incomingPreview) || (patch.state == .applying && updated.patch?.state == .generating) { updated.patch = patch }
        if previous.completed, previous.patch == nil, incomingPreview {
            updated.patch?.state = previous.exitCode == nil || previous.exitCode == 0 ? .completed : .failed
        }
        if previous.patch != nil { updated.title = "apply_patch" }
        return updated
    }
}

struct ChatTurn: Identifiable, Sendable {
    var id: String { didSet { invalidatePresentation() } }
    var started = Date() { didSet { invalidatePresentation() } }
    var ended: Date? { didSet { invalidatePresentation() } }
    var fileOffset: UInt64? { didSet { invalidatePresentation() } }
    var items: [ChatItem] = [] { didSet { itemsRevision = UUID(); invalidatePresentation() } }
    private(set) var itemsRevision = UUID()
    private(set) var presentationRevision = UUID()

    mutating func invalidatePresentation() { presentationRevision = UUID() }
}

@MainActor @Observable
/// A helper interaction (permission or questions): the producer owns expiry; `complete` receives the
/// decision and any answers.
final class PendingApproval: Identifiable {
    enum Decision: String { case allow, deny, terminal, expired }
    let id = UUID()
    let key: String
    let interaction: String?
    let operation: String
    /// The tool record and turn the approval belongs to, when the producer names them.
    let item: ChatItem?
    let turnID: String?
    /// The transcript item of the tool call this request is about, when the hook named one.
    let toolItemID: String?
    let questions: ClaudeQuestions?
    let questionDraft: ClaudeQuestionDraft?
    private(set) var answers: [String: String]?
    private(set) var decision: Decision?
    @ObservationIgnored private let complete: (PendingApproval) -> Void
    init(key: String, interaction: String? = nil, operation: String, item: ChatItem? = nil, turnID: String? = nil, toolItemID: String? = nil, questions: ClaudeQuestions? = nil,
         complete: @escaping (PendingApproval) -> Void) {
        self.key = key
        self.interaction = interaction
        self.operation = operation
        self.item = item
        self.turnID = turnID
        self.toolItemID = toolItemID
        self.complete = complete
        self.questions = questions
        questionDraft = questions.map(ClaudeQuestionDraft.init)
    }
    var pending: Bool { decision == nil }
    func retire() { decision = .expired }
    func resolve(_ value: Decision) {
        guard decision == nil else { return }
        // Questions require the explicit, complete answer payload below.
        guard questions == nil || value != .allow else { return }
        decision = value
        complete(self)
    }
    func answer(_ answers: [String: String]) {
        guard decision == nil, questions?.accepts(answers) == true else { return }
        self.answers = answers; decision = .allow
        complete(self)
    }
}

struct ChatToolGroup: Identifiable {
    let id: String
    let children: [ChatTranscriptRow]
    // Separate from the stable disclosure identity. A rebuilt cached group
    // refreshes its summary without hashing every child's revision during draw.
    let presentationID = UUID()
}

struct ChatTranscriptRow: Identifiable {
    let id: String
    let item: ChatItem?
    let approval: PendingApproval?
    var group: ChatToolGroup? = nil
    var toolGroupID: String? = nil
    var turnID: String? = nil
    var bubbleStart = true
    var bubbleEnd = true
    var workedFor: TimeInterval? = nil
    var replyTime: Date? = nil
}

struct ChatQueuedMessage: Identifiable {
    let id = UUID()
    var text: String
    var process: AgentProcess?
    var binding: HelperTopology.Binding? = nil
    var host: String? = nil
    var delivery: ChatDraftDelivery? = nil
    var isCommand = false
    var conversation: String? = nil
    var generation: UUID? = nil
    var pause: ChatQueuePause? = nil
    var native: HelperChat.Queued? = nil
    /// Being added to the native queue.
    var pending = false
    /// Not yet accepted by a native queue; the app delivers or uploads it.
    var held: Bool { native == nil }
    var editable: Bool { native?.editable ?? true }

    @MainActor func matches(_ session: ChatSession) -> Bool {
        process == session.process && host == session.host
            && (binding == nil || (binding?.pid == session.binding?.pid
                                  && binding?.start == session.binding?.start
                                  && binding?.executable == session.binding?.executable))
            && (generation == nil || generation == session.queueGeneration)
            && (conversation == nil || conversation == session.sessionID)
    }
}

enum ChatQueuePause: Equatable {
    case uncertain, destinationChanged, stopped, needsEdit(String)
    var description: String {
        switch self {
        case .uncertain: "Queue paused: delivery could not be confirmed. Check the terminal, then edit or discard this message."
        case .destinationChanged: "Queue paused: this message belongs to another conversation or agent. Edit it to send here, or discard it."
        case .stopped: "Queue paused after Stop. Resume when ready."
        case .needsEdit(let reason): reason
        }
    }
}

/// Only transport failures proven to precede any input may retry automatically.
struct ChatInputNotSent: LocalizedError {
    let errorDescription: String?
    init(_ error: Error) { errorDescription = error.localizedDescription }

    static func deliveryUncertain(_ error: Error, started: Bool) -> Bool {
        guard started, !(error is ChatInputNotSent) else { return false }
        if let delivery = error as? HelperChat.Delivery { return delivery.uncertain }
        // A helper's refusal typed nothing unless it says `uncertain` (core api.rs Multiplexer.keys);
        // a connection that ended after the request may have lost the reply to a send that ran.
        if let failure = error as? HelperFailure {
            return ["uncertain", "connection_closed", "limit", "invalid_response"].contains(failure.code)
        }
        return true
    }
}

/// Short-lived presentation receipts distinguish live insertions from history,
/// streaming revisions, and lazy rows being mounted again while scrolling.
@MainActor final class ChatTranscriptArrivals {
    final class Receipt {
        let time: TimeInterval
        private(set) var consumed = false
        init(time: TimeInterval) { self.time = time }
        func eligible(since opened: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
            !consumed && time >= opened && now - time < 0.5
        }
        func consume(since opened: TimeInterval) -> Bool {
            guard eligible(since: opened) else { return false }
            consumed = true
            return true
        }
    }
    private var receipts: [String: Receipt] = [:]
    /// Each entrance glides and fades the transcript for a few frames, and every frame re-lays it out. In a burst
    /// of live rows only the first in this interval moves; the rest appear in place, joining a glide still running.
    var burstInterval: TimeInterval = 1
    private var lastMotion = -Double.infinity
    /// Whether a live row arriving now gets an entrance; one that does starts a new interval.
    func admitsMotion(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard now - lastMotion >= burstInterval else { return false }
        lastMotion = now
        return true
    }
    /// The user's own prompt always enters, and starts an interval like any entrance.
    func noteMotion(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastMotion = now }
    func record(_ id: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        receipts = receipts.filter { now - $0.value.time < 0.5 }
        if receipts[id] == nil { receipts[id] = Receipt(time: now) }
    }
    func receipt(for id: String) -> Receipt? { receipts[id] }
    /// A group header that a live row just created enters with it instead of popping in above it.
    func recordGroup(_ id: String, forming children: [String], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard children.contains(where: { receipts[$0].map { !$0.consumed && now - $0.time < 0.5 } == true }) else { return }
        record(id, now: now)
    }
    func reset() { receipts.removeAll(); lastMotion = -Double.infinity }
}

actor ChatSearch {
    struct Document: Equatable, Sendable {
        let id: String
        let row: String
        let label: String
        let text: String
    }
    struct Match: Equatable, Sendable {
        let document: Document
        let range: NSRange
        var id: String { "\(document.id):\(range.location)" }
        var excerpt: (text: String, range: NSRange) {
            let text = document.text
            guard let match = Range(range, in: text) else { return ("", NSRange(location: 0, length: 0)) }
            // Keep the matched text complete, with one short line of context on either side.
            let start = text.index(match.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(match.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
            let context = String(text[start..<end])
            let offset = text[start..<match.lowerBound].utf16.count
            return (context, NSRange(location: offset, length: range.length))
        }
    }
    private var query = ""
    private var cache: [String: (Document, [Match])] = [:]
    func matches(_ documents: [Document], query: String) throws -> [Match] {
        if self.query != query { cache = [:]; self.query = query }
        guard !query.isEmpty else { return [] }
        var result: [Match] = [], retained: Set<String> = []
        for document in documents {
            try Task.checkCancellation()
            retained.insert(document.id)
            if cache[document.id]?.0 != document {
                var matches: [Match] = [], start = document.text.startIndex
                while start < document.text.endIndex,
                      let range = document.text.range(of: query, options: .caseInsensitive, range: start..<document.text.endIndex) {
                    try Task.checkCancellation()
                    matches.append(.init(document: document, range: NSRange(range, in: document.text)))
                    start = range.upperBound
                }
                cache[document.id] = (document, matches)
            }
            result.append(contentsOf: cache[document.id]!.1)
        }
        cache = cache.filter { retained.contains($0.key) }
        return result
    }
}

@MainActor @Observable
final class ChatSession: Identifiable {
    struct Presentation {
        let draft: String
        let showChat: Bool
        let manualViewChoice: Bool
        let expanded: Set<String>
        let expandedToolGroups: Set<String>
        var toolGroupIdentities: [String: String] = [:]
        var collapsedToolGroups: Set<String> = []
        var collapsedLiveTools: Set<String> = []
        let scrollAnchor: String?
        let scrollPosition: ChatScrollPosition.Anchor?
        let atBottom: Bool
    }
    let id: UUID // stable terminal tab ID
    let terminalSearch = ContentSearch()
    let search = ContentSearch()
    @ObservationIgnored var searchIndex = ChatSearch()
    var searchMatches: [ChatSearch.Match] = []
    var searchMatch: ChatSearch.Match? {
        guard search.visible, let index = search.selected, searchMatches.indices.contains(index) else { return nil }
        return searchMatches[index]
    }
    var searchDocuments: [ChatSearch.Document] {
        transcriptRows.flatMap { [$0] + ($0.group?.children ?? []) }.flatMap { row in
            guard let item = row.item ?? row.approval?.item else {
                return row.approval.map { [ChatSearch.Document(id: row.id, row: row.id, label: "Permission", text: $0.operation)] } ?? []
            }
            var fields = [("title", "Tool", item.title), ("text", item.kind == .tool ? "Tool input" : "Message", item.text),
                          ("output", "Tool output", item.output)]
            if let patch = item.patch, !patch.documents.isEmpty {
                fields.removeAll { $0.0 == "text" }
                fields += patch.documents.enumerated().map { ("patch-\($0.offset)", $0.element.path, $0.element.diff) }
            }
            return fields.filter { !$0.2.isEmpty }.map { .init(id: row.id + ":" + $0.0, row: row.id, label: $0.1, text: $0.2) }
        }
    }
    let token = UUID().uuidString
    var sessionID: String? {
        didSet { if sessionID == nil, oldValue != nil { draftCollection.beginProvisional() } }
    }
    /// The bound agent on this Mac (nil for an agent on an SSH host).
    var process: AgentProcess?
    /// The helper's binding: the agent's process identity on whichever host runs it.
    var binding: HelperTopology.Binding?
    @ObservationIgnored var helper: HelperChat?
    @ObservationIgnored var helperTask: Task<Void, Never>?
    var helperTitle: String?
    var helperEarlier: String?
    /// The SSH host a remote agent runs on (its helper's link); nil on this Mac.
    var host: String?
    /// Positions given to helper records so far (they arrive in transcript order); see receiveHelper.
    @ObservationIgnored var helperPositions: ClosedRange<UInt64>?
    var helperCommands: [String] = []
    var agentTitle: String { helperTitle ?? "Agent" }
    var supportsQueue: Bool { helper != nil }
    var agentID = "codex"
    /// A conversation belongs to its host: the same id on another SSH host is another conversation.
    var ownershipKey: String? { sessionID.map { (host.map { "ssh:" + $0 + ":" } ?? "") + agentID + ":" + $0 } }
    var discoveryBlocked = false
    var loadingHistory = false
    var hasEarlier = false
    var loadingEarlier = false
    var earlierError: String?
    var historyGeneration: UUID?
    var historyRevision = 0
    var hasNewMessages = false
    /// The composer's ⌘/ sheet; here so the Help menu can open it.
    var shortcutsPresented = false
    /// Chat shows a transcript and composer rather than the setup placeholder.
    var hasConversation: Bool { hasOpenedChat || sessionID != nil || active || !draft.isEmpty }
    @ObservationIgnored let scrollPosition = ChatScrollPosition()
    @ObservationIgnored private var toolGroupIdentities: [String: String] = [:]
    var promptBoundary: ChatPromptBoundary? {
        didSet {
            if let promptBoundary, optimisticPrompt != nil { optimisticPromptBoundary = promptBoundary }
        }
    }
    var optimisticPrompt: ChatItem? {
        didSet {
            cachedRows = nil; cachedVisibleRows = nil
            if let optimisticPrompt, oldValue?.id != optimisticPrompt.id, showChat, atBottom {
                transcriptArrivals.noteMotion()
                transcriptArrivals.record(optimisticPrompt.id)
                scrollPosition.expectArrival()
            }
            if optimisticPrompt == nil {
                optimisticPromptBoundary = nil; optimisticPromptDelivered = false; optimisticPromptRetained = false
            }
        }
    }
    @ObservationIgnored var optimisticPromptBoundary: ChatPromptBoundary?
    @ObservationIgnored var optimisticPromptRetained = false
    @ObservationIgnored var optimisticPromptDelivered = false
    var turns: [ChatTurn] = [] { didSet { cachedRows = nil; cachedVisibleRows = nil } }
    var approvals: [PendingApproval] = [] { didSet { cachedRows = nil; cachedVisibleRows = nil } }
    private struct PatchPair: Hashable { let wrapper: UUID; let patch: UUID }
    @ObservationIgnored private var patchPairs: [PatchPair: (collapse: Bool, hidden: Set<String>)] = [:]
    private struct TurnRows {
        let revision: UUID
        let itemsRevision: UUID
        let displayedItems: [ChatItem]
        let rows: [ChatTranscriptRow]
        let groupIDs: Set<String>
        let toolRevisions: Set<UUID>
    }
    /// Keep prepared rows with the retained turns, rather than evicting all
    /// transforms once a conversation crosses a fixed number of turns.
    private struct TurnRowsCache: ExpressibleByDictionaryLiteral {
        private var entries: [String: TurnRows] = [:]
        private var toolReferences: [UUID: Int] = [:]
        private(set) var toolRevisions: Set<UUID> = []
        var count: Int { entries.count }

        init(dictionaryLiteral elements: (String, TurnRows)...) {
            for (id, rows) in elements { self[id] = rows }
        }

        subscript(id: String) -> TurnRows? {
            get { entries[id] }
            set {
                if let old = entries[id] {
                    for revision in old.toolRevisions {
                        if toolReferences[revision] == 1 {
                            toolReferences.removeValue(forKey: revision)
                            toolRevisions.remove(revision)
                        } else { toolReferences[revision, default: 0] -= 1 }
                    }
                }
                if let newValue {
                    for revision in newValue.toolRevisions {
                        toolReferences[revision, default: 0] += 1
                        toolRevisions.insert(revision)
                    }
                }
                entries[id] = newValue
            }
        }

        mutating func retain(_ turnIDs: Set<String>) {
            for id in entries.keys.filter({ !turnIDs.contains($0) }) { self[id] = nil }
        }
    }
    @ObservationIgnored private var displayedTurns: TurnRowsCache = [:]
    private func displayedItems(_ items: [ChatItem], turnID: String) -> [ChatItem] {
        patchDisplayedItems(ToolOrchestration.coalesced(items, turnID: turnID), turnID: turnID)
    }
    private func patchDisplayedItems(_ items: [ChatItem], turnID: String) -> [ChatItem] {
        var result: [ChatItem] = []
        for item in items {
            if let previous = result.last, !ChatPatch.isPatchOperation(previous), ChatPatch.isPatchOperation(item) {
                let patch = item
                let wrapper = previous
                let key = PatchPair(wrapper: wrapper.presentationID, patch: patch.presentationID)
                let match: (collapse: Bool, hidden: Set<String>)
                if let cached = patchPairs[key] { match = cached }
                else {
                    match = (ChatPatch.duplicates(wrapper: wrapper, patch: patch), ChatPatch.duplicatedRequests(wrapper: wrapper, patch: patch))
                    if patchPairs.count >= 4096 { patchPairs.removeAll(keepingCapacity: true) }
                    patchPairs[key] = match
                }
                if match.collapse {
                    var merged = patch
                    merged.rowID = previous.rowID ?? "\(turnID.utf8.count):\(turnID):\(previous.id)"
                    result[result.count - 1] = merged
                    continue
                }
                if !match.hidden.isEmpty {
                    result[result.count - 1].hiddenPatchRequests.formUnion(match.hidden)
                }
            }
            result.append(item)
        }
        return result
    }
    @ObservationIgnored private var cachedRows: [ChatTranscriptRow]?
    @ObservationIgnored private var cachedVisibleRows: [ChatTranscriptRow]?
    @ObservationIgnored let toolLayouts = ChatToolLayoutCache()
    @ObservationIgnored let transcriptArrivals = ChatTranscriptArrivals()
    var expandedToolGroups: Set<String> = [] { didSet { cachedVisibleRows = nil } }
    var collapsedToolGroups: Set<String> = [] { didSet { cachedVisibleRows = nil } }
    var collapsedLiveTools: Set<String> = []

    func toolIsExpanded(_ row: ChatTranscriptRow) -> Bool {
        guard let item = row.item, item.kind == .tool else { return false }
        let newestPatch = busy && row.turnID == activeTurnID &&
            turns.last(where: { $0.id == activeTurnID })?.items.last(where: {
                $0.kind == .tool && ChatToolGroupHeader.category($0) == "Patch"
            })?.id == item.id
        return expanded.contains(row.id) || (newestPatch && !collapsedLiveTools.contains(row.id))
    }

    func groupIsExpanded(_ group: ChatToolGroup, turnID: String?) -> Bool {
        expandedToolGroups.contains(group.id) || (busy && turnID == activeTurnID && transcriptRows.last(where: { $0.group != nil && $0.turnID == activeTurnID })?.group?.id == group.id && !collapsedToolGroups.contains(group.id))
    }
    func setGroupExpanded(_ group: ChatToolGroup, _ value: Bool) {
        atBottom = false; followRevision = nil
        if value { expandedToolGroups.insert(group.id); collapsedToolGroups.remove(group.id) }
        else { expandedToolGroups.remove(group.id); collapsedToolGroups.insert(group.id) }
    }

    /// Expanded children remain peers in the outer lazy stack, so even one huge
    /// group never mounts thousands of tool cards inside an eager container.
    var visibleTranscriptRows: [ChatTranscriptRow] {
        let rows = transcriptRows
        _ = busy; _ = activeTurnID; _ = expandedToolGroups; _ = collapsedToolGroups
        if let cachedVisibleRows { return cachedVisibleRows }
        var visible: [ChatTranscriptRow] = []
        for row in rows {
            if let group = row.group, groupIsExpanded(group, turnID: row.turnID) {
                var head = row; head.bubbleEnd = false
                visible.append(head)
                for (index, child) in group.children.enumerated() {
                    var child = child
                    child.bubbleStart = false
                    child.bubbleEnd = index == group.children.count - 1
                    visible.append(child)
                }
            } else { visible.append(row) }
        }
        cachedVisibleRows = visible
        return visible
    }
    var transcriptRows: [ChatTranscriptRow] {
        // Register dependencies, but flatten only when the conversation changes.
        let turns = turns, approvals = approvals, optimisticPrompt = optimisticPrompt
        if let cachedRows { return cachedRows }
        var grouped = Dictionary(grouping: approvals, by: \.turnID)
        // A request can arrive before its tool call is read (Claude writes the call only after the reply). Once the
        // call is in a turn, show the card there instead of after every later turn, where its receipt would sit
        // above the composer for good. Without a call ID (Claude's PermissionRequest hook may omit it), a resolved
        // request's call is the latest tool item with its tool and arguments; a pending one stays last, since an
        // earlier identical call is not the one it is asking about.
        if let unplaced = grouped[nil], !unplaced.isEmpty {
            let ids = Set(unplaced.compactMap(\.toolItemID))
            let matched = unplaced.filter { !$0.pending }.compactMap(\.item)
            let tools = Set(matched.map(\.title))
            var owners: [String: String] = [:], calls: [String: String] = [:]
            for turn in turns {
                for item in turn.items where item.kind == .tool {
                    if ids.contains(item.id) { owners[item.id] = turn.id }
                    if tools.contains(item.title) { calls[item.title + "\n" + item.text] = turn.id }
                }
            }
            if !owners.isEmpty || !calls.isEmpty {
                grouped[nil] = nil
                for approval in unplaced {
                    let owner = approval.toolItemID.flatMap { owners[$0] }
                        ?? (approval.pending ? nil : approval.item.flatMap { calls[$0.title + "\n" + $0.text] })
                    grouped[owner, default: []].append(approval)
                }
            }
        }
        var rows: [ChatTranscriptRow] = []
        var usedGroupIDs: Set<String> = []
        for turn in turns {
            let prepared: TurnRows
            if let cached = displayedTurns[turn.id], cached.revision == turn.presentationRevision,
               cached.groupIDs.isDisjoint(with: usedGroupIDs) {
                prepared = cached
                usedGroupIDs.formUnion(cached.groupIDs)
            } else {
                prepared = preparedRows(for: turn, usedGroupIDs: &usedGroupIDs)
                displayedTurns[turn.id] = prepared
            }
            rows.append(contentsOf: prepared.rows)
            for approval in grouped[turn.id] ?? [] {
                rows.append(ChatTranscriptRow(id: "approval-\(approval.id)", item: nil, approval: approval))
            }
        }
        if displayedTurns.count > turns.count { displayedTurns.retain(Set(turns.map(\.id))) }
        if let prompt = optimisticPrompt {
            rows.append(ChatTranscriptRow(id: prompt.id, item: prompt, approval: nil))
        }
        for approval in grouped[nil] ?? [] {
            rows.append(ChatTranscriptRow(id: "approval-\(approval.id)", item: nil, approval: approval))
        }
        if toolLayouts.count > 0 { toolLayouts.retain(displayedTurns.toolRevisions) }
        cachedRows = rows
        return rows
    }

    private func preparedRows(for turn: ChatTurn, usedGroupIDs: inout Set<String>) -> TurnRows {
        // Ending or reordering a turn can change its rows without changing the
        // projected tool items. Keep their formatting identities stable when
        // only timing metadata changed.
        let items: [ChatItem]
        if let cached = displayedTurns[turn.id], cached.itemsRevision == turn.itemsRevision {
            items = cached.displayedItems
        } else { items = displayedItems(turn.items, turnID: turn.id) }
        var rows: [ChatTranscriptRow] = [], tools: [ChatTranscriptRow] = []
        var groupIDs: Set<String> = [], toolRevisions: Set<UUID> = []
        func flushTools() {
            guard !tools.isEmpty else { return }
            let hasMessage = rows.last?.item.map { $0.kind == .assistant || $0.isNarration } == true && rows.last?.group == nil
            guard tools.count >= 2 || hasMessage else {
                rows.append(contentsOf: tools); tools.removeAll(keepingCapacity: true); return
            }
            // A split may reuse an old disclosure only once. A merge prefers
            // an opened disclosure, then a manually collapsed one, then any
            // prior identity. Inspect the candidates once in their row order.
            var first: String?, expanded: String?, collapsed: String?
            for tool in tools {
                guard let id = toolGroupIdentities[tool.id], !usedGroupIDs.contains(id) else { continue }
                if first == nil { first = id }
                if expandedToolGroups.contains(id) { expanded = id; break }
                if collapsed == nil, collapsedToolGroups.contains(id) { collapsed = id }
            }
            let proposed = expanded ?? collapsed ?? first ?? ("tool-group:" + tools[0].id)
            let id = usedGroupIDs.contains(proposed) ? "tool-group:" + UUID().uuidString : proposed
            usedGroupIDs.insert(id); groupIDs.insert(id)
            // A message row already shows its group; a new header row is new presentation.
            if first == nil, !hasMessage { transcriptArrivals.recordGroup(id, forming: tools.map(\.id)) }
            for tool in tools { toolGroupIdentities[tool.id] = id }
            let children = tools.map { row in var row = row; row.toolGroupID = id; return row }
            let group = ChatToolGroup(id: id, children: children)
            if hasMessage { rows[rows.count - 1].group = group }
            else { rows.append(ChatTranscriptRow(id: id, item: nil, approval: nil, group: group, turnID: turn.id)) }
            tools.removeAll(keepingCapacity: true)
        }
        for item in items {
            let row = ChatTranscriptRow(id: item.rowID ?? "\(turn.id.utf8.count):\(turn.id):\(item.id)", item: item, approval: nil,
                                        turnID: turn.id, replyTime: item.kind == .assistant ? itemDates[ItemIdentity(turn: turn.id, item: item.id)] : nil)
            if item.kind == .tool { tools.append(row); toolRevisions.insert(item.presentationID) }
            else { flushTools(); rows.append(row) }
        }
        flushTools()
        // A turn read without times starts and ends at the epoch; its duration is unknown.
        if let ended = turn.ended, turn.started.timeIntervalSince1970 > 0, ended.timeIntervalSince(turn.started) >= 120 {
            rows.append(ChatTranscriptRow(id: "worked-for:" + turn.id, item: nil, approval: nil,
                                          turnID: turn.id, workedFor: ended.timeIntervalSince(turn.started)))
        }
        return TurnRows(revision: turn.presentationRevision, itemsRevision: turn.itemsRevision, displayedItems: items,
                        rows: rows, groupIDs: groupIDs, toolRevisions: toolRevisions)
    }
    var showChat = false { didSet { acknowledgeVisibleOutput() } }
    // A moved pane may mount its new view before the outgoing view disappears.
    // Removing the old presentation must not hide the new one.
    private var presentations: Set<UUID> = []
    var isPresented: Bool { !presentations.isEmpty }
    private var latestOutputIsVisible: Bool { isPresented && (!showChat || atBottom) }
    // Presentation outlives agent processes, transcript readers and connections.
    struct ViewTransition {
        let date: Date
        let chat: Bool
        let reason: String
    }
    private static let viewLog = Logger(subsystem: "com.dispatch.app", category: "ChatPresentation")
    private(set) var viewTransitions: [ViewTransition] = []
    private(set) var hasOpenedChat = false
    func setView(_ chat: Bool, reason: String) {
        if chat { hasOpenedChat = true }
        focusRequest = UUID()
        guard showChat != chat else { return }
        Self.viewLog.info("Chat view changed: chat=\(chat) reason=\(reason, privacy: .public) surface=\(self.id.uuidString, privacy: .public)")
        viewTransitions.append(.init(date: .now, chat: chat, reason: reason))
        if viewTransitions.count > 32 { viewTransitions.removeFirst() }
        showChat = chat
    }
    var terminalAttention: String?
    var inputBlocked: Bool { discoveryBlocked || terminalAttention != nil }
    var manualViewChoice = false
    var active = false
    var busy = false { didSet {
        cachedVisibleRows = nil
        if !busy { submittedThinkingAt = nil }
    } }
    // Keep a locally submitted turn on one clock across remote acknowledgement.
    var submittedThinkingAt: Date?
    var nativeActivity: String?
    var submissionID: UUID?
    var interruptionID: UUID?
    var activityCheck: UUID?
    var activityNeedsRefresh = false
    var activityRetryAfter: Date?
    var activeTurnID: String? { didSet { cachedVisibleRows = nil } }
    /// An unresolved interaction from a disconnected helper cannot regain authority as a native card.
    var retiredInteraction = false
    var awaitingPromptAck = false
    /// A Claude or Pi slash command awaiting its turn, output, or menu.
    /// A native command sent to the agent whose printed output has not arrived yet (its result's title).
    @ObservationIgnored var observedCommand: (title: String, output: String?)?
    var lastInputAt: Date?
    private let draftCollection: ChatDraftCollection
    private var draftHost = "local"
    var drafts: ChatDraftCollection {
        // A remote agent's drafts belong to its host (`host`, set from its helper's link).
        if let host { draftHost = "ssh:" + host } else if process != nil { draftHost = "local" }
        if let sessionID { draftCollection.bind(host: draftHost, agent: agentID, conversation: sessionID) }
        return draftCollection
    }
    var draft: String {
        get { drafts.current.text }
        set { drafts.edit(text: newValue) }
    }
    var draftIsCommand: Bool { drafts.shape.command }
    var composerHeight: CGFloat = 28
    var directDraftDelivery: ChatDraftDelivery?
    func clearDraft() { drafts.discard() }
    func finishDirectDraft(success: Bool) {
        guard let delivery = directDraftDelivery else { return }
        drafts.finish(delivery, success: success); directDraftDelivery = nil
    }
    var queuedMessages: [ChatQueuedMessage] = []
    /// A queue operation (add, edit, move, send) is in flight; its snapshot waits in helperQueueSnapshot.
    var queueBusy = false
    var queueError: String?
    var helperQueueSnapshot: [HelperChat.Queued]?
    /// The producer's own queue (chat.open native_queue); otherwise core holds and drains it.
    var helperNativeQueue = false
    var queueGeneration = UUID()
    var queueWaiting: String?
    var queueRetryAfter: Date?
    var queuePaused: String? { queuedMessages.first?.pause?.description }
    func pauseQueued(_ id: UUID, reason: ChatQueuePause) {
        guard let index = queuedMessages.firstIndex(where: { $0.id == id }) else { return }
        queuedMessages[index].pause = reason
    }
    func stopQueue() {
        for index in queuedMessages.indices where queuedMessages[index].pause == nil { queuedMessages[index].pause = .stopped }
    }
    func invalidateQueuedDestination(replacing: Bool = false) {
        // Native entries stay with their Codex thread; never retarget them to a
        // replacement conversation. Revoked access keeps them visible until an
        // authenticated snapshot arrives. Unsynchronized drafts remain recoverable.
        if replacing { queuedMessages.removeAll { !$0.held } }
        queueBusy = false; queueError = nil; helperQueueSnapshot = nil
        queueGeneration = UUID(); queueWaiting = nil; queueRetryAfter = nil
        for index in queuedMessages.indices where queuedMessages[index].pause != .uncertain {
            queuedMessages[index].pause = .destinationChanged
        }
    }
    var queuedSubmissionID: UUID?
    var editingQueuedID: UUID?
    var editingQueuedDraftID: UUID?
    var selectedQueuedID: UUID?
    var hoveredQueuedID: UUID?
    var commandSelection = 0
    var sideConversation: ChatSideConversation?
    var reviewing = false
    var matchingCommands: [String] {
        guard let prefix = drafts.shape.commandPrefix else { return [] }
        let commands = ["/terminal"] + (active ? helperCommands.filter { $0 != "/terminal" } : [])
        return commands.filter { $0.hasPrefix(prefix) }
    }
    func completeCommand() {
        guard !matchingCommands.isEmpty else { return }
        draft = matchingCommands[min(commandSelection, matchingCommands.count - 1)] + " "
        commandSelection = 0; focusRequest = UUID()
    }
    // Transcript polling and activity hooks may replace their own status, but
    // a failed send must remain visible until the user acts or identity ends.
    var submissionFailure: String?
    private var activityStatus: String?
    var status: String? {
        get { terminalAttention ?? submissionFailure ?? activityStatus }
        set { activityStatus = newValue }
    }
    /// Until the agent reports a model, its title: a fresh agent reports none before its first reply.
    var model: String {
        get { reportedModel ?? agentTitle }
        set { reportedModel = newValue }
    }
    private var reportedModel: String?
    var title: String?
    var transcriptTitle: String?
    var conversationTitle: String? { title ?? transcriptTitle }
    var effort: String?
    var modelPicker: ChatModelPicker?
    var command: ChatCommandRequest?
    var commandResult: ChatCommandResult?
    var commandEditor: String?
    var commandEditorText = ""
    var questions: [ChatSideQuestion] = []
    var waitingForAnswer: Bool {
        questions.contains { $0.blocking && !$0.submitted } || (questions.isEmpty && nativePrompt?.title.hasPrefix("Question ") == true)
            || approvals.contains { $0.pending && $0.questions != nil }
    }
    func clearQuestions() {
        questions.forEach { $0.clearAnswers() }
        if !questions.isEmpty { focusRequest = UUID() }
        questions = []
    }
    var nativePrompt: ChatNativePrompt?
    @ObservationIgnored var claudePromptObservedAt: ContinuousClock.Instant?
    var nativeInputs: Set<UUID> = []
    var nativeInputInFlight: Bool { !nativeInputs.isEmpty }
    var serviceTier: String?
    var collaborationMode: String?
    var threadName: String?
    var confirmedConversation: String?
    var confirmedConversationInput: Date?
    var goal: ChatGoal?
    var goalUpdatedAt = Date()
    var usage: ChatUsage?
    var settingsRevision = 0
    var goalRevision = 0
    @ObservationIgnored var modelChoices = ChatModelChoicesCache()
    @ObservationIgnored var configurationRequest: UUID?
    @ObservationIgnored private(set) var configurationRevision = UUID()
    var version: String?
    var expanded: Set<String> = []
    var scrollAnchor: String?
    var atBottom = true { didSet { acknowledgeVisibleOutput() } }
    var scrollToLatestRequest = UUID()
    var focusRequest = UUID()
    var revision = 0
    @ObservationIgnored var followRevision: Int?
    var transcriptAvailable = false
    var stoppedTurnID: String?
    var transcriptPath: String?
    struct ItemIdentity: Hashable {
        let turn: String
        let item: String
    }
    @ObservationIgnored var itemDates: [ItemIdentity: Date] = [:]
    @ObservationIgnored var itemOffsets: [ItemIdentity: UInt64] = [:]
    @ObservationIgnored var seen: Set<String> = []
    init(id: UUID, draftRepository: ChatDraftRepository = .shared) {
        self.id = id; draftCollection = ChatDraftCollection(repository: draftRepository)
    }

    var presentation: Presentation {
        Presentation(draft: draft, showChat: showChat, manualViewChoice: manualViewChoice, expanded: expanded,
            expandedToolGroups: expandedToolGroups, toolGroupIdentities: toolGroupIdentities,
            collapsedToolGroups: collapsedToolGroups, collapsedLiveTools: collapsedLiveTools, scrollAnchor: scrollAnchor,
            scrollPosition: scrollPosition.visibleAnchor() ?? scrollPosition.saved, atBottom: atBottom)
    }

    func restorePresentation(_ saved: Presentation) {
        // Drafts restore from their conversation collection, independently of presentation.
        setView(saved.showChat, reason: "conversation-restored"); manualViewChoice = saved.manualViewChoice
        expanded = saved.expanded; expandedToolGroups = saved.expandedToolGroups
        // Reconciled groups may use an identity from a later child. Retain
        // that mapping with disclosure choices when SSH recreates the session.
        toolGroupIdentities = saved.toolGroupIdentities
        displayedTurns = [:]
        cachedRows = nil; cachedVisibleRows = nil
        collapsedToolGroups = saved.collapsedToolGroups; collapsedLiveTools = saved.collapsedLiveTools
        scrollAnchor = saved.scrollAnchor; atBottom = saved.atBottom
        scrollPosition.restore(saved.scrollPosition)
    }

    func setPresented(_ visible: Bool, by view: UUID) {
        if visible { presentations.insert(view) } else { presentations.remove(view) }
        acknowledgeVisibleOutput()
    }

    private func acknowledgeVisibleOutput() {
        if latestOutputIsVisible { hasNewMessages = false }
    }

    func revealLatestMessages() {
        atBottom = true
        followRevision = revision
        scrollPosition.jumpToLatest()
        scrollToLatestRequest = UUID()
    }

    func finishPatches(in turnID: String) {
        guard let turn = turns.first(where: { $0.id == turnID }) else { return }
        for var item in turn.items where item.patch != nil && !item.completed {
            item.patch?.state = .interrupted; item.completed = true
            insert(item, turnID: turnID)
        }
    }
    /// A conversation replaced inside the same agent process (/clear, /new) keeps
    /// that process's model and effort; the agent does not report them again
    /// until its next reply.
    func resetConversation(keepingConfiguration: Bool = false) {
        search.close(); search.query = ""; searchMatches = []; searchIndex = ChatSearch()
        transcriptArrivals.reset()
        sideConversation?.close(); sideConversation = nil
        reviewing = false
        draftCollection.persist(flush: true)
        command?.cancel(); command = nil; commandResult = nil; commandEditor = nil
        clearQuestions()
        nativePrompt = nil; nativeInputs.removeAll(); claudePromptObservedAt = nil
        serviceTier = nil; collaborationMode = nil; threadName = nil; goal = nil; confirmedConversation = nil
        settingsRevision = 0; goalRevision = 0; usage = nil
        invalidateQueuedDestination(replacing: true)
        queuedSubmissionID = nil
        editingQueuedID = nil; editingQueuedDraftID = nil; selectedQueuedID = nil; hoveredQueuedID = nil
        modelPicker?.abandon(); modelPicker = nil
        modelChoices = ChatModelChoicesCache()
        relinquish()
        retiredInteraction = false
        optimisticPrompt = nil
        approvals = []; turns = []; seen = []; itemDates = [:]; itemOffsets = [:]; toolLayouts.removeAll(); helperPositions = nil
        transcriptPath = nil; transcriptAvailable = false; version = nil
        loadingHistory = false; promptBoundary = nil
        hasEarlier = false; loadingEarlier = false; earlierError = nil; historyGeneration = nil
        hasNewMessages = false; scrollPosition.clear(); toolGroupIdentities = [:]; patchPairs = [:]; displayedTurns = [:]
        busy = false; nativeActivity = nil; submissionID = nil; interruptionID = nil; activityCheck = nil; activeTurnID = nil; awaitingPromptAck = false; observedCommand = nil; stoppedTurnID = nil
        activityNeedsRefresh = false; activityRetryAfter = nil
        submissionFailure = nil; status = nil; title = nil; transcriptTitle = nil; configurationRequest = nil
        if !keepingConfiguration { reportedModel = nil; effort = nil }
        configurationRevision = UUID()
        terminalAttention = nil
        expanded = []; expandedToolGroups = []; collapsedToolGroups = []; collapsedLiveTools = []; scrollAnchor = nil; atBottom = true
        followRevision = nil
        revision += 1
    }

    func confirmConfiguration(model: String, effort: String?) {
        configurationRevision = UUID()
        applyConfiguration(model: model, effort: effort)
    }

    func applyConfiguration(model: String, effort: String?, revision: UUID? = nil) {
        guard revision == nil || revision == configurationRevision else { return }
        configurationRequest = nil
        self.model = model; self.effort = effort
    }

    /// A Pi tree switch replaces visible history while retaining the terminal
    /// binding and the user's presentation choices and draft. A prompt still
    /// being sent is not history either: the first read of the transcript it
    /// created is a replacement, and confirms its bubble in place. A bubble
    /// whose send ended unconfirmed leaves with the replaced history.
    func clearBranchHistory() {
        transcriptArrivals.reset()
        if approvals.contains(where: \.pending) {
            print("Chat transcript replacement preserves pending approvals: session=\(sessionID ?? "nil"), pending=\(approvals.filter(\.pending).count)")
        }
        if optimisticPrompt == nil || optimisticPromptRetained { optimisticPrompt = nil; submittedThinkingAt = nil }
        turns = []; seen = []; itemDates = [:]; itemOffsets = [:]; toolLayouts.removeAll(); helperPositions = nil
        toolGroupIdentities = [:]; patchPairs = [:]; displayedTurns = [:]
        activeTurnID = nil; hasEarlier = false; loadingEarlier = false; earlierError = nil
        scrollPosition.clear(); scrollAnchor = nil; atBottom = true
        expanded = []; expandedToolGroups = []; collapsedToolGroups = []; collapsedLiveTools = []
        revision += 1
    }

    func turn(_ id: String, at date: Date = Date(), fileOffset: UInt64? = nil) -> Int {
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
    func insert(_ item: ChatItem, turnID: String, at date: Date = Date(), historical: Bool = false, fileOffset: UInt64? = nil) {
        let index = turn(turnID, at: date, fileOffset: fileOffset)
        let date = item.source == nil ? date : Date(timeIntervalSince1970: 0)
        var turn = turns[index]
        var identity = item.id
        let changed: Bool
        let existing = turn.items.firstIndex(where: item.matches)
        if let existing {
            let updated = item.merging(turn.items[existing], historical: historical)
            changed = updated != turn.items[existing]
            identity = updated.id
            if changed { turn.items[existing] = updated }
        } else {
            turn.items.append(item); changed = true
            // An acknowledged optimistic prompt already animated under its rowID.
            if !historical, showChat, atBottom, !loadingHistory, item.rowID == nil {
                if transcriptArrivals.admitsMotion() {
                    transcriptArrivals.record("\(turnID.utf8.count):\(turnID):\(item.id)")
                    scrollPosition.expectArrival()
                } else {
                    scrollPosition.expectRow()
                }
            }
        }
        let key = ItemIdentity(turn: turnID, item: identity)
        let previousDate = itemDates[key], previousOffset = itemOffsets[key]
        itemDates[key] = min(itemDates[key] ?? date, date)
        if let fileOffset { itemOffsets[key] = min(itemOffsets[key] ?? fileOffset, fileOffset) }
        func precedes(_ lhs: ChatItem, _ rhs: ChatItem) -> Bool {
            let a = ItemIdentity(turn: turnID, item: lhs.id), b = ItemIdentity(turn: turnID, item: rhs.id)
            let ad = itemDates[a] ?? date, bd = itemDates[b] ?? date
            return ad == bd ? (itemOffsets[a] ?? .max) < (itemOffsets[b] ?? .max) : ad < bd
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
            // Earlier history can supply an older timestamp/offset for an
            // existing live item. Preserve the stable tie order in that case.
            turn.items.sort(by: precedes)
        }
        if previousDate != itemDates[key] { turn.invalidatePresentation() }
        turns[index] = turn
        if !historical {
            if changed && !latestOutputIsVisible { hasNewMessages = true }
            followRevision = atBottom ? revision + 1 : nil
            revision += 1
        }
    }

    /// Historical publication shares the live merge rules, but copies each
    /// affected item array once and publishes the conversation once per batch.
    /// Activity, configuration and prompt acknowledgement stay in the
    /// coordinator's ordered event loop.
    func mergeHistorical(_ records: [ChatRecord]) {
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
                    if !identities.insert(item.id).inserted || itemDates[ItemIdentity(turn: turn.id, item: item.id)] == nil {
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
                    insert(item, turnID: record.turnID, at: record.date, historical: true, fileOffset: record.fileOffset)
                case .started:
                    _ = turn(record.turnID, at: record.date, fileOffset: record.fileOffset)
                case .ended:
                    let index = turn(record.turnID, at: record.date, fileOffset: record.fileOffset)
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
            mergeHistoricalItems(items, into: &updatedTurns[index])
        }
        let order = updatedTurns.indices.sorted(by: turnPrecedes)
        turns = order.map { updatedTurns[$0] }
    }

    private struct HistoricalTextIdentity: Hashable {
        let kind: ChatItem.Kind
        let text: String
        init?(_ item: ChatItem) {
            guard !item.id.hasPrefix("pi-"), [.user, .assistant, .reasoning].contains(item.kind) else { return nil }
            kind = item.kind; text = item.text
        }
    }

    private func mergeHistoricalItems(_ records: [ChatRecord], into turn: inout ChatTurn) {
        var items = turn.items
        var identities = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        var textIdentities: [HistoricalTextIdentity: Set<Int>] = [:]
        var dates = items.map { itemDates[ItemIdentity(turn: turn.id, item: $0.id)] }
        var offsets = items.map { itemOffsets[ItemIdentity(turn: turn.id, item: $0.id)] }
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
            if let key = HistoricalTextIdentity(item), let candidates = textIdentities[key] {
                // The live path takes the first displayed match, which can be
                // an equal-text item before the item with the exact native ID.
                for candidate in candidates where item.matches(items[candidate]) {
                    if existing == nil || precedes(candidate, existing!, fallback: record.date) { existing = candidate }
                }
            }
            let index: Int
            if let existing {
                index = existing
                let previous = items[index], updated = item.merging(previous, historical: true)
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
                items.append(item); identities[item.id] = index
                if let key = HistoricalTextIdentity(item) { textIdentities[key, default: []].insert(index) }
                let key = ItemIdentity(turn: turn.id, item: item.id)
                ranks.append(index)
                dates.append(min(itemDates[key] ?? date, date))
                offsets.append(record.fileOffset.map { min(itemOffsets[key] ?? $0, $0) } ?? itemOffsets[key])
            }
            if let source = items[index].source { identities[source.id] = index }
            let key = ItemIdentity(turn: turn.id, item: items[index].id)
            itemDates[key] = dates[index]
            itemOffsets[key] = offsets[index]
        }
        let fallback = records.last?.date ?? turn.started
        let order = items.indices.sorted { precedes($0, $1, fallback: fallback) }
        turn.items = order.map { items[$0] }
    }

    func showOptimisticPrompt(_ text: String, at date: Date = .now) {
        optimisticPromptDelivered = false
        optimisticPromptRetained = false
        submittedThinkingAt = date
        optimisticPrompt = ChatItem(id: "pending-" + UUID().uuidString, kind: .user, text: text)
        optimisticPromptBoundary = .local(date)
        followRevision = atBottom ? revision + 1 : nil
        revision += 1
    }

    func matchesPrompt(_ item: ChatItem) -> Bool {
        guard item.kind == .user, let pending = optimisticPrompt else { return false }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return [pending.text, AgentInput.fenced(pending.text)].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
    }

    func reconcilePrompt(_ item: ChatItem) -> ChatItem {
        guard matchesPrompt(item), let pending = optimisticPrompt else { return item }
        var confirmed = item
        confirmed.rowID = pending.id
        optimisticPrompt = nil
        return confirmed
    }

    func failOptimisticPrompt(restoreDraft: Bool) {
        submittedThinkingAt = nil
        // Confirmed input remains part of the read-only conversation even if
        // its transcript record has not arrived. Reconcile it when that record
        // becomes available instead of hiding it or recreating a draft.
        guard let pending = optimisticPrompt else { return }
        if optimisticPromptDelivered { optimisticPromptRetained = true; return }
        if restoreDraft {
            if directDraftDelivery != nil { finishDirectDraft(success: false) }
            else { drafts.restore(ChatDraft(text: pending.text, multiline: pending.text.contains("\n"))) }
        }
        optimisticPrompt = nil
        followRevision = atBottom ? revision + 1 : nil
        revision += 1
    }

    func expireApprovals() {
        for approval in approvals where approval.decision == nil && !approval.pending { approval.resolve(.expired) }
    }
    func relinquish() {
        // Subscription failure can precede process exit and presentation retention. Keep the
        // old request's retirement even after its card no longer reports itself as pending.
        if approvals.contains(where: \.pending) || !questions.isEmpty { retiredInteraction = true }
        approvals.forEach { $0.resolve(.terminal) }
    }
}

/// Cumulative agent-reported usage. Missing counters remain unknown.
struct ChatUsage: Sendable, Equatable {
    var input: Int?
    var output: Int?
    var contextTokens: Int?
    var contextWindow: Int?
    var costUSD: Double?

    init?(_ payload: [String: Any]) {
        guard let info = payload["info"] as? [String: Any] else { return nil }
        let total = info["total_token_usage"] as? [String: Any] ?? [:]
        let last = info["last_token_usage"] as? [String: Any] ?? [:]
        func counter(_ value: Any?) -> Int? {
            guard let value = value as? Int, value >= 0 else { return nil }
            return value
        }
        input = counter(total["input_tokens"])
        output = counter(total["output_tokens"])
        contextTokens = counter(last["total_tokens"])
        contextWindow = counter(info["model_context_window"])
        if let cost = info["total_cost_usd"] as? Double, cost.isFinite, cost >= 0 { costUSD = cost }
        guard input != nil || output != nil || contextTokens != nil || contextWindow != nil || costUSD != nil else { return nil }
    }
    var contextRemaining: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, max(0, 1 - Double(contextTokens) / Double(contextWindow)))
    }
}

struct ChatRecord: Sendable {
    enum Action: Sendable {
        case item(ChatItem), started, ended, compacted, metadata(String, String), configuration(model: String, effort: String?)
        case settings(ChatAgentSettings), goal(ChatGoal?), usage(ChatUsage), title(String)
        /// Text a native slash command printed without starting a model turn.
        case commandOutput(String)
    }
    let key: String
    let turnID: String
    let date: Date
    let action: Action
    var fileOffset: UInt64? = nil
    var reviewing: Bool? = nil

    /// Stable, lowercase SHA-256 keys without 32 printf/NSString allocations.
    static func contentKey(_ bytes: Data) -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var result = [UInt8](); result.reserveCapacity(64)
        for byte in SHA256.hash(data: bytes) {
            result.append(digits[Int(byte >> 4)]); result.append(digits[Int(byte & 15)])
        }
        return String(decoding: result, as: UTF8.self)
    }
}

/// JSON values shown as text (tool inputs and outputs).
enum TranscriptParser {
    static func printable(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum AgentInput {
    /// What a harness sends for a command-looking chat message (c1654cc AgentDiscovery.literalMessage; codex
    /// and claude fence it, pi and nanocodex take it as is): a code fence longer than any inside it.
    static func fenced(_ text: String) -> String {
        guard isCommand(text) else { return text }
        var backticks = 0, tildes = 0, longestBackticks = 0, longestTildes = 0
        for scalar in text.unicodeScalars {
            backticks = scalar == "`" ? backticks + 1 : 0; tildes = scalar == "~" ? tildes + 1 : 0
            longestBackticks = max(longestBackticks, backticks); longestTildes = max(longestTildes, tildes)
        }
        let useBackticks = longestBackticks <= longestTildes
        let fence = String(repeating: useBackticks ? "`" : "~", count: max(3, (useBackticks ? longestBackticks : longestTildes) + 1))
        return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }

    /// Native editor commands need delivery confirmation, not a model-turn ack.
    static func isCommand(_ text: String, multiline: Bool = false) -> Bool {
        guard !multiline else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("!")
    }
}
