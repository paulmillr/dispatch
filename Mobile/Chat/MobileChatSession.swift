import Foundation
import Observation

/// One agent conversation on the phone: a terminal whose topology node carries an agent `Binding`, read and driven
/// over the helper's `chat.*`, `interaction.*` and `queue.*` operations (helper/PROTOCOL.md). The phone's counterpart
/// of the Mac's `ChatSession` plus the helper half of `ChatCoordinator` (ChatCoordinator+Helper.swift), without the
/// Mac's view state. It keeps docs/architecture.md's agent-request and delivery invariants:
///
/// - It attaches (`chat.open`) only for a terminal the topology binds to an agent, and treats the conversation as
///   verified only when the helper's history names that same process.
/// - Approvals and question replies belong to the subscription that delivered them; a lost link retires them.
/// - Losing the link or the binding pauses input but keeps the transcript and the drafts.
/// - Queued messages live on the device (`ChatOutbox`) until delivered and are mirrored into the helper's queue while
///   connected; a message whose delivery the device cannot establish is paused for the user, never sent again.
///
/// Identity is the host plus the terminal's topology key: node ids belong to one helper process and change with every
/// reconnect (docs/ios.md, Helper contract).
@MainActor @Observable
final class MobileChatSession: Identifiable {
    enum Phase: Equatable {
        /// No live subscription: no client, no binding yet, or before the first open.
        case detached
        /// `chat.open` sent; the helper has not named the conversation yet.
        case opening
        /// The helper's history names the bound process: input goes to the agent.
        case verified
        /// Input is paused (the reason is shown); history and drafts stay.
        case paused(String)
    }

    /// An approval card (M4b): the request, when it arrived, and the subscription it belongs to.
    struct Approval: Identifiable {
        let pending: PendingApproval
        let interaction: HelperChat.Interaction
        let arrived: Date
        fileprivate let generation: UUID
        /// The turn of the thread's last row when it arrived: its card ends that turn when the producer names none
        /// (Claude's hooks), so a decided card never sinks below the turns after it.
        var anchor: String? = nil
        /// The chip the user chose (shown as their reply).
        var chosen: ApprovalChoice?
        var id: UUID { pending.id }
    }

    nonisolated let key: ChatConversationKey
    nonisolated var id: ChatConversationKey { key }
    /// The host's display name (banner, captions, facts).
    var hostName: String

    private(set) var link: HostLink = .disconnected
    /// Why the host is not connected yet (`HostSession.problem`), for the banner.
    private(set) var linkProblem: String?
    @ObservationIgnored private(set) var client: HelperClient?
    /// Names the helper process behind `client`: a new client is a new helper, whose queue starts empty.
    @ObservationIgnored private var helperToken = UUID()
    /// The terminal's node id in the current helper's topology.
    private(set) var terminal: UInt64?
    /// The agent the topology binds to this terminal (discovery).
    private(set) var binding: HelperTopology.Binding?
    private(set) var phase = Phase.detached
    @ObservationIgnored let presence: (any ChatTerminalPresence)?

    // The conversation, as the helper names it.
    private(set) var conversation: String?
    private(set) var agentKey: String?
    private(set) var agentLabel: String?
    private(set) var commands: [String] = []
    private(set) var nativeQueue = false
    private(set) var transcript = MobileTranscript()
    private(set) var loadingHistory = false
    private(set) var earlier: String?
    var hasEarlier: Bool { earlier != nil }
    private(set) var loadingEarlier = false
    private(set) var earlierError: String?
    private(set) var historyError: String?

    // The agent's reported state (chat.state).
    private(set) var busy = false
    private(set) var subagents: [String] = []
    private(set) var activity: String?
    private(set) var model: String?
    /// The model as the Mac's footer names it (opus-5.5), never the menu's alias or the raw ID (claude-opus-5-5).
    var modelLabel: String? { model.map(AgentModelMenu.label(for:)) }
    private(set) var effort: String?
    private(set) var attention: String?
    private(set) var title: String?
    private(set) var compacting = false
    private(set) var version: String?
    /// A prompt was sent and the agent has not acknowledged it (no turn start or state since).
    private(set) var awaitingAck = false
    /// The acknowledged turn started; the agent counts as working until its next state (ChatSession.starting).
    private(set) var starting = false
    /// When the agent last began working: the clock when no live turn has a start time.
    private(set) var workingSince: Date?
    /// When this phone sent the prompt the agent is working on.
    private(set) var submittedAt: Date?

    // Requests from the agent.
    private(set) var approvals: [Approval] = []
    private(set) var questions: [ChatSideQuestion] = []
    /// A helper approval arrived in this conversation (for Codex: its hooks are trusted).
    private(set) var receivedApproval = false

    /// The helper's queue snapshot (`chat.queue`, `queue.list`); what the phone shows is `queueRows`.
    private(set) var queue: [HelperChat.Queued] = []
    private(set) var queueBusy = false
    private(set) var queueError: String?

    // Sending.
    private(set) var optimisticPrompt: ChatItem?
    private(set) var sending = false
    private(set) var stopping = false
    /// Why the last send, answer or queue change failed; cleared by the next one.
    var failure: String?
    /// A command's own result (chat.command, or the output it printed), shown until the next send.
    var commandResult: ChatCommandResult?
    /// The last command this phone sent, which titles the output it prints.
    @ObservationIgnored private var lastCommand: String?

    // Attachments (docs/ios.md, Attachments).
    /// The opt-in features the connected helper's hello accepted (`HelperSession.Info.features`).
    private(set) var features: Set<String> = []
    /// Files on their way to the host (`attachments.put`), in the composer's strip until stored; never saved, so a quit
    /// mid-upload drops them. Each belongs to the draft it was started for, and lands there.
    private(set) var uploads: [ChatUpload] = []
    /// The uploads of the draft the composer shows.
    var draftUploads: [ChatUpload] {
        let draft = drafts.shape.id
        return uploads.filter { $0.draft == draft }
    }
    /// Why the last attach did nothing (too many, too large, unreadable, still uploading), shown above the composer
    /// until the next attach or send.
    var attachmentError: String?
    /// What each upload reads, kept for Retry.
    @ObservationIgnored private var uploadSources: [String: MobileAttachmentSource] = [:]

    // Model and effort (M3b): menus are choice metadata only, cached per agent and conversation.
    @ObservationIgnored let modelChoices = ChatModelChoicesCache()
    private(set) var modelsLoading = false
    /// Settings chosen before the conversation opened (New chat, M9a), applied once it is verified.
    var pendingSettings: (model: String, effort: String?)?

    let drafts: ChatDraftCollection
    let outbox: ChatOutbox

    @ObservationIgnored private var generation = UUID()
    /// The send `sending` stands for: one that ends after a reconnect started another still clears its own flag only.
    @ObservationIgnored private var sendTicket = 0
    @ObservationIgnored private var observation: (id: UInt64, client: HelperClient)?
    @ObservationIgnored private var retained = false
    @ObservationIgnored private var reconciling = false
    /// Device queue items with a helper operation in flight (a snapshot without them proves nothing yet).
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// A drain is running; another request runs it once more when it ends.
    @ObservationIgnored private var draining = false
    @ObservationIgnored private var drainAgain = false
    /// The live turn when the link dropped while the agent worked: if it is still running after the reconnect, the
    /// old helper cannot have started on its queue (drains wait for an idle agent).
    @ObservationIgnored private var dropTurn: String?
    /// Called with every applied change the conversation list cares about (state, records, approvals).
    @ObservationIgnored var changed: ((MobileChatSession) -> Void)?

    init(key: ChatConversationKey, hostName: String, presence: (any ChatTerminalPresence)? = nil,
         drafts: ChatDraftRepository = .shared, outbox: ChatOutbox = .shared) {
        self.key = key
        self.hostName = hostName
        self.presence = presence
        self.drafts = ChatDraftCollection(repository: drafts)
        self.outbox = outbox
    }

    /// The host's link and client changed (HostSession.link, .client), with the features its hello accepted.
    func update(link: HostLink, client: HelperClient?, problem: String? = nil, features: Set<String> = []) {
        let previous = self.client
        if linkProblem != problem { linkProblem = problem }
        if self.features != features { self.features = features }
        self.link = link
        self.client = link == .connected ? client : nil
        if self.client !== previous { helperToken = UUID() }
        if self.client == nil {
            if previous != nil || phase != .detached { suspend(reason: nil) }
        } else if previous !== self.client || phase == .detached {
            open()
        }
    }

    /// The topology's node for this conversation's key: its current id and binding (nil: no agent runs there now).
    func update(terminal: UInt64?, binding: HelperTopology.Binding?) {
        let previous = (self.terminal, self.binding)
        self.terminal = terminal
        self.binding = binding
        guard terminal != previous.0 || binding != previous.1 else { return }
        if binding == nil || terminal == nil {
            if previous.1 != nil {
                busy = false; subagents = []; awaitingAck = false; starting = false; updateWorkingSince()
                suspend(reason: "\(agentName) exited. This transcript is read-only.")
            }
            return
        }
        // A new process, a new node id, or the agent naming its conversation (Codex's thread id arrives with the first
        // prompt): reopen, and the history decides what changed.
        if client != nil { open() }
    }

    var agentName: String { agentLabel ?? agentKey ?? "The agent" }

    /// The agent is working: the thinking bubble (M5a) shows.
    var working: Bool { (turnRunning || !subagents.isEmpty) && attention == nil }
    /// A turn runs or is about to (the Mac's optimistic `busy`); what the conversation list counts as working.
    var turnRunning: Bool { (busy || awaitingAck || starting) && attention == nil }
    var waitingForUser: Bool {
        approvals.contains { $0.pending.pending } || questions.contains { $0.blocking && !$0.submitted }
    }
    /// The terminal is attached and publishes its screen: chat input can be verified (ChatTerminalPresence).
    var terminalAttached: Bool {
        guard let presence else { return true }
        return terminal != nil && client != nil && presence.attached(key)
    }
    /// Codex runs Dispatch's hooks only after "Trust all" in its own terminal; until an approval has come through,
    /// the thread says so (docs/ios.md, Helper contract: "Surface native trust steps").
    var needsHookTrust: Bool { agentKey == "codex" && !receivedApproval }

    private func open() {
        guard let client, let terminal, binding != nil else { return }
        closeObservation()
        let generation = UUID()
        self.generation = generation
        phase = .opening
        if transcript.isEmpty { loadingHistory = true }
        struct Open: Encodable { let terminal: UInt64 }
        let connection = client.connection
        Task { [weak self] in
            do {
                let id = try await connection.subscribe(
                    "chat.open", params: Open(terminal: terminal),
                    notify: { [weak self] method, value in
                        // One serial queue keeps the helper's order (a Task per notification would not).
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.notify(method, value, generation: generation) } }
                    },
                    ended: { [weak self] result in
                        DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(result, generation: generation) } }
                    })
                guard let self, self.generation == generation else { connection.cancel(id); return }
                self.observation = (id, client)
            } catch {
                guard let self, self.generation == generation else { return }
                self.fail(error)
            }
        }
    }

    private func closeObservation() {
        if let observation { observation.client.connection.cancel(observation.id) }
        observation = nil
        if retained { presence?.release(key) }
        retained = false
    }

    /// Input pauses; requests from the old subscription can no longer be answered.
    private func suspend(reason: String?) {
        dropTurn = working ? transcript.openTurn?.id : nil
        closeObservation()
        generation = UUID()
        retireRequests()
        loadingHistory = false
        reconciling = false
        phase = reason.map(Phase.paused) ?? .detached
    }

    private func retireRequests() {
        for approval in approvals where approval.pending.pending { approval.pending.retire() }
        questions.removeAll { !$0.submitted }
    }

    private func ended(_ result: Result<HelperBinary.Value, any Error>, generation: UUID) {
        guard self.generation == generation else { return }
        observation = nil
        if case .failure(let error) = result, !(error is CancellationError) { fail(error) }
    }

    private func fail(_ error: any Error) {
        loadingHistory = false
        let code = (error as? HelperFailure)?.code
        if code == "agent_exited" || code == "expired" {
            busy = false; subagents = []; awaitingAck = false; starting = false; updateWorkingSince()
            suspend(reason: "\(agentName) exited. This transcript is read-only.")
        } else if link == .connected {
            suspend(reason: error.localizedDescription)
        } else { suspend(reason: nil) }
    }

    private func notify(_ method: String, _ value: HelperBinary.Value, generation: UUID) {
        guard self.generation == generation else { return }
        do {
            switch method {
            case "chat.history": receive(history: try HelperBinary.decode(HelperChat.History.self, from: value))
            case "chat.records":
                let records = try HelperBinary.decode(Records.self, from: value)
                guard accepts(records.terminal, records.session) else { return }
                if records.replace == true {
                    transcript.clear()
                    transcript.apply(records.records, historical: true)
                    earlier = records.earlier
                } else { receive(live: records.records) }
            case "chat.state":
                let status = try HelperBinary.decode(Status.self, from: value)
                guard accepts(status.terminal, status.session) else { return }
                receive(state: status.state)
            case "chat.queue":
                let items = try HelperBinary.decode(Items.self, from: value)
                guard accepts(items.terminal, items.session) else { return }
                receive(queue: items.items)
                queueError = items.error?.localizedDescription
            case "interaction.opened":
                let opened = try HelperBinary.decode(Opened.self, from: value)
                guard accepts(opened.terminal, opened.session) else { return }
                receive(interaction: opened.interaction, generation: generation)
            case "terminal.exit":
                let exit = try HelperBinary.decode(HelperClient.Exit.self, from: value)
                guard exit.terminal == terminal else { return }
                busy = false; subagents = []; awaitingAck = false; starting = false; updateWorkingSince()
                suspend(reason: "\(agentName) exited. This transcript is read-only.")
            default: return
            }
        } catch {
            failure = error.localizedDescription
        }
        changed?(self)
    }

    /// Updates for this terminal's current conversation only.
    private func accepts(_ terminal: UInt64, _ session: String) -> Bool {
        terminal == self.terminal && phase == .verified && (conversation == nil || conversation == session || session.isEmpty)
    }

    private struct Records: Decodable {
        let terminal: UInt64
        let session: String
        let records: [HelperChat.Record]
        let replace: Bool?
        let earlier: String?
    }
    private struct Items: Decodable {
        let terminal: UInt64
        let session: String
        let items: [HelperChat.Queued]
        let error: HelperFailure?
    }
    private struct Status: Decodable {
        let terminal: UInt64
        let session: String
        let state: HelperChat.State
    }
    private struct Opened: Decodable {
        let terminal: UInt64
        let session: String
        let interaction: HelperChat.Interaction
    }

    private func receive(history: HelperChat.History) {
        guard history.terminal == terminal else { return }
        // Ownership: the helper must name the process discovery bound to this terminal.
        if let expected = binding, expected.pid != nil,
           expected.pid != history.binding.pid || expected.start != history.binding.start {
            suspend(reason: "The agent in this terminal changed. Reopen the conversation.")
            return
        }
        let named = history.session.isEmpty ? nil : history.session
        if let shown = conversation, let named, shown != named {
            // Another conversation in this terminal (/clear, /resume): its own transcript and requests.
            transcript = MobileTranscript()
            retireRequests()
            approvals = []
            queue = []
            optimisticPrompt = nil
            earlier = nil
            receivedApproval = false
        }
        if let named { conversation = named }
        agentKey = history.key
        agentLabel = history.label
        commands = history.commands
        nativeQueue = history.native_queue
        if let conversation {
            drafts.bind(host: "ios:" + key.host.uuidString, agent: history.key, conversation: conversation)
            modelChoices.prepare(agent: history.key, conversation: conversation, version: version)
        }
        let wasVerified = phase == .verified
        phase = .verified
        historyError = history.history_error?.localizedDescription
        if let error = history.state_error, error.code == "setup" {
            phase = .paused(error.localizedDescription)
        }
        if !wasVerified, phase == .verified, let client, let terminal, !retained {
            presence?.retain(key, terminal: terminal, client: client)
            retained = true
        }
        if history.history_pending {
            loadingHistory = transcript.isEmpty && named != nil
        } else {
            loadingHistory = false
            transcript.apply(history.records, historical: true, prepare: reconcile)
            earlier = history.earlier
        }
        if let state = history.state { receive(state: state) }
        if !wasVerified, phase == .verified { reconciling = true }
        if reconciling, !loadingHistory { Task { await self.reconcileQueue() } }
    }

    private func receive(live records: [HelperChat.Record]) {
        let applied = transcript.apply(records, historical: false, prepare: reconcile)
        for change in applied {
            switch change {
            case .started:
                if awaitingAck { starting = true }
                awaitingAck = false
            case .ended(let turn):
                if turn == transcript.activeTurnID {
                    starting = false; awaitingAck = false; submittedAt = nil
                }
            case .item(let item, _):
                if item.kind == .user, item.rowID != nil { awaitingAck = false }
            case .output(let text):
                // The pending command's result, as the Mac shows it (`receiveCommandExecution`).
                commandResult = ChatCommandResult(title: lastCommand ?? "Command",
                                                  text: text.isEmpty ? "Command completed with no output." : text)
            }
        }
        updateWorkingSince()
    }

    /// A live user record that repeats the prompt shown while it was sent takes its bubble's place
    /// (ChatSession.reconcilePrompt): the row keeps its identity and the thumbnails the composer made, nothing moves.
    private func reconcile(_ item: ChatItem, turn: String) -> ChatItem {
        guard let pending = optimisticPrompt,
              AgentInput.records(item, prompt: pending.text, attachments: pending.attachments) else { return item }
        var confirmed = item
        confirmed.rowID = pending.id
        confirmed.attachments = ChatAttachment.merge(item.attachments, keeping: pending.attachments)
        optimisticPrompt = nil
        return confirmed
    }

    private func receive(state: HelperChat.State) {
        if let version = state.version { self.version = version }
        subagents = state.agents ?? []
        busy = state.busy
        if state.busy { awaitingAck = false }
        starting = false
        activity = state.activity
        if let model = state.model {
            self.model = model
            effort = state.effort
        }
        attention = state.attention
        if let title = state.title { self.title = title }
        compacting = state.compacting
        if !working { submittedAt = nil }
        updateWorkingSince()
        applyPendingSettings()
        drainWhenIdle()
    }

    private func updateWorkingSince() {
        if !working { workingSince = nil } else if workingSince == nil { workingSince = Date() }
    }

    private func receive(interaction: HelperChat.Interaction, generation: UUID) {
        if interaction.questions.isEmpty {
            // The request closed (answered elsewhere, expired): undecided cards expire; decided ones stay as receipts.
            questions.removeAll { $0.id == interaction.id }
            for approval in approvals where approval.interaction.id == interaction.id && approval.pending.pending {
                approval.pending.retire()
            }
            return
        }
        // A native question acknowledges a prompt as a turn would.
        awaitingAck = false
        guard !approvals.contains(where: { $0.interaction.id == interaction.id && $0.pending.pending }),
              !questions.contains(where: { $0.id == interaction.id }) else { return }
        let choices = interaction.questions.allSatisfy { $0.options.count >= 2 && !$0.secret }
        if let permission = interaction.permission {
            receivedApproval = true
            let pending = PendingApproval(key: interaction.key ?? interaction.id, interaction: interaction.id,
                                          operation: permission.operation, item: interaction.tool(in: transcript.turns),
                                          turnID: interaction.turn, toolItemID: interaction.record) { [weak self] approval in
                self?.complete(approval)
            }
            approvals.append(Approval(pending: pending, interaction: interaction, arrived: Date(), generation: generation,
                                      anchor: transcript.rows.last?.turnID))
        } else if interaction.blocking, !interaction.approval, choices,
                  interaction.questions.count == 1 || interaction.record != nil {
            let form = ClaudeQuestions(interaction.questions.map { question in
                ClaudeQuestions.Question(text: question.text, header: question.header,
                                         options: question.options.map { .init(label: $0.label, description: $0.detail ?? "", preview: nil) },
                                         multiple: question.multiple)
            })
            let pending = PendingApproval(key: interaction.id, interaction: interaction.id,
                                          operation: interaction.questions.map(\.text).joined(separator: "\n"),
                                          turnID: interaction.turn, toolItemID: interaction.record, questions: form) { [weak self] approval in
                self?.complete(approval)
            }
            approvals.append(Approval(pending: pending, interaction: interaction, arrived: Date(), generation: generation,
                                      anchor: transcript.rows.last?.turnID))
        } else if let conversation, let question = ChatSideQuestion(interaction: interaction, session: conversation) {
            questions.append(question)
        }
    }

    /// The chips the helper's options allow: Deny and Allow, and This session only when the helper offers a
    /// session-scoped choice (today's hooks offer Allow / Deny / Terminal).
    static func choices(for interaction: HelperChat.Interaction) -> [ApprovalChoice] {
        guard interaction.approval, let question = interaction.questions.first, question.options.count >= 2 else { return [] }
        var choices = [ApprovalChoice(role: .deny, index: 1)]
        if let session = question.options.indices.dropFirst(2).first(where: { index in
            let option = question.options[index]
            return [option.id, option.label].contains { $0.range(of: "session", options: .caseInsensitive) != nil }
        }) {
            choices.append(ApprovalChoice(role: .session, index: session))
        }
        choices.append(ApprovalChoice(role: .allow, index: 0))
        return choices
    }

    func answer(_ approval: Approval, with choice: ApprovalChoice) {
        guard let index = approvals.firstIndex(where: { $0.id == approval.id }), approval.pending.pending else { return }
        approvals[index].chosen = choice
        approval.pending.resolve(choice.role == .deny ? .deny : .allow)
    }

    /// A question form's answers (ClaudeQuestions), or skip.
    func answer(_ approval: Approval, answers: [String: String]?) {
        if let answers { approval.pending.answer(answers) } else { approval.pending.resolve(.deny) }
    }

    private func complete(_ pending: PendingApproval) {
        guard let card = approvals.first(where: { $0.pending === pending }) else { return }
        // A request belongs to the subscription that delivered it.
        guard card.generation == generation, phase == .verified else {
            failure = "This request ended with its connection. Continue in Terminal."
            return
        }
        var input = route()
        input.interaction = card.interaction.id
        switch (pending.decision, pending.questionDraft) {
        case (.allow, _?):
            input.answers = card.interaction.answers(pending.answers ?? [:])
        case (.deny, _?):
            input.answers = Dictionary(uniqueKeysWithValues: card.interaction.questions.map { ($0.id, .skip) })
        case (.allow, nil), (.deny, nil):
            guard let question = card.interaction.questions.first else { return }
            input.answers = [question.id: .options([card.chosen?.index ?? (pending.decision == .allow ? 0 : 1)])]
        default: return
        }
        let generation = generation
        Task {
            do {
                let sent: HelperChat.Sent = try await call("interactions.answer", input, generation: generation)
                try sent.confirmed()
            } catch {
                guard self.generation == generation else { return }
                self.failure = self.explain(error)
            }
            self.changed?(self)
        }
    }

    func answer(_ question: ChatSideQuestion, skip: Bool) {
        guard phase == .verified, questions.contains(where: { $0 === question }), !question.submitted,
              skip || question.complete else { return }
        var input = route()
        input.interaction = question.id
        input.answers = skip ? Dictionary(uniqueKeysWithValues: question.questions.map { ($0.id, .skip) }) : question.answers
        question.submitted = true
        let generation = generation
        Task {
            do {
                let sent: HelperChat.Sent = try await call("interactions.answer", input, generation: generation)
                try sent.confirmed()
                question.clearAnswers()
            } catch {
                guard self.generation == generation else { return }
                question.submitted = false
                question.submissionUncertain = ChatInputNotSent.deliveryUncertain(error, started: true)
                question.submissionError = self.explain(error)
                self.failure = self.explain(error)
            }
        }
    }

    enum Route: Equatable {
        /// `chat.send` mode prompt: the agent is idle.
        case prompt
        /// `chat.send` mode steer: into the running turn (long-press send, M5a).
        case steer
        /// The device queue, mirrored into the helper's (`queue.add`): after this turn (M5a, M5c), or until the
        /// terminal publishes its screen.
        case queue
        /// The device queue only: the conversation is not verified (M4c); it is mirrored once it is.
        case outbox
    }

    /// Where the composer's text goes now. A command (`/…`, `!…`) goes at once whenever the agent can take input, even
    /// with messages queued, and is never steered (ChatCoordinator.sendFromComposer).
    func route(steer: Bool, command: Bool = false) -> Route {
        guard phase == .verified, client != nil, terminal != nil else { return .outbox }
        if command { return idle ? .prompt : .queue }
        if steer, working, terminalAttached { return .steer }
        if working || sending || !queueRows.isEmpty || waitingForUser || !terminalAttached { return .queue }
        return .prompt
    }

    /// Nothing runs and nothing waits for the user: a command can go now.
    private var idle: Bool { !working && !sending && !waitingForUser && terminalAttached && !loadingHistory }

    /// The composer's text and attachments, sent by `route(steer:)`. The draft leaves the composer only once its
    /// destination took it (for the queue, once it is saved on the device); a failure restores it, attachments too.
    func send(steer: Bool = false) {
        let draft = drafts.current
        if let upload = draftUploads.first {
            attachmentError = upload.error == nil ? "Wait until the attachments are uploaded."
                : "Retry or remove the attachment that did not upload."
            return
        }
        _ = submit(draft.text, attachments: draft.attachments, steer: steer) { self.drafts.prepareDelivery(consume: true) }
    }

    /// Text from elsewhere (the watch, docs/watch.md), routed exactly as the composer's but without its draft: the
    /// draft is neither read, taken nor restored. Returns where it went, or nil when nothing was sent (empty text, or a
    /// device queue that could not be saved: `failure` says why). A prompt's own delivery failure comes later, in
    /// `failure`.
    @discardableResult
    func send(text: String, steer: Bool) -> Route? {
        submit(text, attachments: [], steer: steer, delivery: nil)
    }

    /// `delivery` prepares the composer's draft for delivery (nil: not the composer's text); a nil result sends nothing.
    /// With attachments the text may be empty; a command takes none.
    private func submit(_ text: String, attachments: [ChatAttachment], steer: Bool,
                        delivery prepare: (() -> ChatDraftDelivery?)?) -> Route? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return nil }
        let isCommand = AgentInput.isCommand(text, multiline: text.contains("\n"))
        if isCommand, !attachments.isEmpty {
            attachmentError = "A command cannot carry attachments. Remove them to run it."
            return nil
        }
        failure = nil; commandResult = nil; attachmentError = nil
        let route = route(steer: steer, command: isCommand)
        var delivery: ChatDraftDelivery?
        if let prepare {
            guard let prepared = prepare() else { return nil }
            delivery = prepared
        }
        switch route {
        case .outbox, .queue:
            let item = ChatOutboxItem(key: key, conversation: conversation, text: text, command: isCommand,
                                      process: phase == .verified ? .init(binding) : nil, attachments: attachments)
            let accepted = outbox.add(item)
            finish(delivery, success: accepted)
            if !accepted { failure = outbox.error; return nil }
            if route == .queue { Task { await self.drainQueue() } }
        case .prompt where isCommand:
            command(text, delivery: delivery)
        case .prompt, .steer:
            prompt(text, attachments: attachments, steer: route == .steer, delivery: delivery)
        }
        return route
    }

    /// Settles the composer's draft after a delivery (nothing for text that was not the draft).
    private func finish(_ delivery: ChatDraftDelivery?, success: Bool) {
        if let delivery { drafts.finish(delivery, success: success) }
    }

    private func prompt(_ text: String, attachments: [ChatAttachment], steer: Bool, delivery: ChatDraftDelivery?) {
        var input = route()
        input.text = text
        input.mode = steer ? "steer" : "prompt"
        input.attachments = Self.paths(attachments)
        let generation = generation
        var pending = ChatItem(id: "pending-" + UUID().uuidString, kind: .user, text: text)
        pending.attachments = attachments
        if !steer {
            optimisticPrompt = pending
            submittedAt = Date()
            awaitingAck = true
            updateWorkingSince()
        }
        let ticket = beginSending()
        Task {
            defer { if self.sendTicket == ticket { self.sending = false } }
            do {
                try await self.deliver(input, generation: generation)
                self.finish(delivery, success: true)
            } catch {
                // Not retried: the draft comes back and the failure says whether it may have been sent.
                self.finish(delivery, success: false)
                if self.optimisticPrompt?.id == pending.id { self.optimisticPrompt = nil }
                if !steer { self.awaitingAck = false; self.submittedAt = nil }
                self.updateWorkingSince()
                self.failure = self.explain(error)
            }
            if self.generation != generation, self.optimisticPrompt?.id == pending.id { self.optimisticPrompt = nil }
            self.changed?(self)
        }
    }

    /// `chat.send`, sent once more after half a second when the agent refused it as still starting: `input` means
    /// nothing was typed (docs/ios.md, Helper contract: "Expect input refusals").
    private func deliver(_ input: HelperChat.Input, generation: UUID) async throws {
        do {
            let sent: HelperChat.Sent = try await call("chat.send", input, generation: generation)
            try sent.confirmed()
        } catch let error as HelperFailure where error.code == "input" {
            try await Task.sleep(for: .milliseconds(500))
            // The destination is checked again: after a reconnect the input's terminal id names another helper's node.
            let sent: HelperChat.Sent = try await call("chat.send", input, generation: generation)
            try sent.confirmed()
        }
    }

    private func beginSending() -> Int {
        sendTicket += 1
        sending = true
        return sendTicket
    }

    private func command(_ text: String, delivery: ChatDraftDelivery?) {
        var input = route()
        input.text = text
        lastCommand = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = generation
        let ticket = beginSending()
        Task {
            defer { if self.sendTicket == ticket { self.sending = false } }
            do {
                let outcome: HelperChat.Outcome = try await call("chat.command", input, generation: generation)
                try outcome.confirmed()
                self.finish(delivery, success: true)
                self.commandResult = outcome.result(agent: self.agentName)
            } catch {
                self.finish(delivery, success: false)
                self.failure = self.explain(error)
            }
        }
    }

    func stop() {
        guard phase == .verified, working, !stopping else { return }
        stopping = true
        // As the Mac's stopQueue: what the device still holds waits for Resume. Adds already sent reach the helper
        // before this stop, which pauses its own queue.
        for item in queueItems where item.state == .waiting { outbox.update(item.id) { $0.state = .paused(Self.stopped) } }
        Task {
            defer { self.stopping = false }
            do {
                let sent: HelperChat.Sent = try await call("chat.stop", route())
                try sent.confirmed()
            } catch { self.failure = self.explain(error) }
        }
    }

    /// Helper refusals in the thread's words.
    private func explain(_ error: any Error) -> String {
        switch (error as? HelperFailure)?.code {
        case "terminal_unavailable":
            "The terminal is not attached yet, so \(agentName) cannot take input. Your draft is preserved."
        case "input":
            "\(agentName) is not ready for input yet. Your draft is preserved."
        default: error.localizedDescription
        }
    }

    /// One row of the queue card (M5c) or one queued bubble (M4c).
    struct QueueRow: Identifiable, Equatable {
        enum Source: Equatable {
            /// Kept on this device.
            case device(UUID)
            /// Only in the helper's queue (added elsewhere, e.g. the Mac).
            case helper(String)
        }
        let source: Source
        var text: String
        /// Why it does not send by itself: paused, uncertain, stopped.
        var status: String?
        /// Its text can be changed in place: not a row with attachments (the helper's queue refuses that).
        var editable: Bool
        /// What the message carries.
        var attachments: [ChatAttachment] = []
        /// The agent can take it while it works ("send now" steers): what the helper says of its row, else true. A
        /// device row with attachments is not editable but steers like any other.
        var steerable = true
        var id: String {
            switch source { case .device(let id): id.uuidString; case .helper(let id): "helper:" + id }
        }
    }

    var queueItems: [ChatOutboxItem] { outbox.items(for: key) }

    var queueRows: [QueueRow] {
        let items = queueItems
        var rows = items.map { item -> QueueRow in
            let helper = item.helperID.flatMap { id in queue.first { $0.id == id } }
            let status = item.pauseReason ?? helper?.paused.map(Self.pauseText)
            return QueueRow(source: .device(item.id), text: item.text, status: status,
                            editable: (helper?.editable ?? true) && item.attachments.isEmpty, attachments: item.attachments,
                            steerable: helper?.editable ?? true)
        }
        let mirrored = Set(items.compactMap(\.helperID))
        rows += queue.filter { !mirrored.contains($0.id) }.map { queued in
            let attachments = queued.previewAttachments
            return QueueRow(source: .helper(queued.id), text: attachments.isEmpty ? queued.text : queued.typedText,
                            status: queued.paused.map(Self.pauseText), editable: queued.editable && attachments.isEmpty,
                            attachments: attachments, steerable: queued.editable)
        }
        return rows
    }

    private static func pauseText(_ pause: String) -> String {
        switch pause {
        case "stopped": "Paused after Stop."
        case "uncertain": "Delivery could not be confirmed. Check the thread, then send or discard it."
        case "destination_changed": "Belongs to another conversation or agent."
        default: "Edit this message before sending it."
        }
    }

    /// The helper stopped its queue, or the device paused its own items (Stop): Resume restores them.
    var queueStopped: Bool {
        queue.contains { $0.paused == "stopped" } || queueItems.contains { $0.state == .paused(Self.stopped) }
    }
    static let stopped = "Paused after Stop."
    static let otherProcess = "Typed for an earlier run of the agent in this terminal. Send it here or discard it."

    private func receive(queue items: [HelperChat.Queued]) {
        queue = items
        // A mirrored message the host no longer holds was sent (the helper removes an item only once it was typed, or
        // on a user's remove). Ids are the host's queue store's, the same for every helper of a stored conversation.
        for item in queueItems where !inFlight.contains(item.id) {
            guard case .queued(let id, _, let helper) = item.state, helper == helperToken || stored(item) else { continue }
            if let current = items.first(where: { $0.id == id }) {
                // The helper's preview names attachments by type; the device keeps what was typed.
                outbox.update(item.id) {
                    $0.state = .queued(id: id, revision: current.revision, helper: helper)
                    if $0.attachments.isEmpty { $0.text = current.text }
                }
            } else { outbox.remove(item.id) }
        }
        drainWhenIdle()
    }

    /// A shell command waits on the device for an idle agent and an empty helper queue: every change that can make
    /// that true looks again.
    private func drainWhenIdle() {
        guard phase == .verified, idle, queue.isEmpty,
              queueItems.contains(where: { $0.shell && $0.state == .waiting }) else { return }
        Task { await self.drainQueue() }
    }

    /// Puts a device item into the helper's queue (`queue.add`). A failure after the request went out pauses it.
    private func mirror(_ id: UUID) async -> Bool {
        guard let item = queueItems.first(where: { $0.id == id }), item.state == .waiting, !item.shell,
              phase == .verified else { return false }
        var input = route()
        input.text = item.text; input.mode = "prompt"; input.command = item.command
        input.attachments = Self.paths(item.attachments)
        let token = helperToken
        outbox.update(id) { $0.state = .adding }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        do {
            let queued: HelperChat.Queued = try await call("queue.add", input)
            outbox.update(id) { $0.state = .queued(id: queued.id, revision: queued.revision, helper: token) }
            if !queue.contains(where: { $0.id == queued.id }) { queue.append(queued) }
            return true
        } catch let error as ChatInputNotSent {
            outbox.update(id) { $0.state = .waiting }
            failure = error.localizedDescription
            return false
        } catch {
            let uncertain = ChatInputNotSent.deliveryUncertain(error, started: true)
            outbox.update(id) {
                $0.state = uncertain
                    ? .uncertain("The host may have taken this message. Check the thread, then send or discard it.")
                    : .paused(explain(error))
            }
            return false
        }
    }

    /// After (re)verification: settles what the device queue holds against the helper's queue and the transcript,
    /// then mirrors what waits, in order. A message the old helper held and may have been sending when it went away
    /// is paused for the user; the ones behind it were certainly not sent and go into the new helper's queue.
    private func reconcileQueue() async {
        guard reconciling, phase == .verified else { return }
        reconciling = false
        let generation = generation
        let snapshot: [HelperChat.Queued]
        do { snapshot = try await call("queue.list", route()) } catch {
            queueError = error.localizedDescription
            return
        }
        guard self.generation == generation else { return }
        queue = snapshot
        var claimed = Set<String>()
        var head = true
        let undrained = dropTurn != nil && dropTurn == transcript.openTurn?.id && working
        for item in queueItems {
            if let typed = item.conversation, let conversation, typed != conversation, item.pauseReason == nil {
                outbox.update(item.id) {
                    $0.state = .paused("Typed for an earlier conversation of \(self.agentName). Send it here or discard it.")
                }
                continue
            }
            if let process = item.process, !process.matches(binding), item.pauseReason == nil {
                outbox.update(item.id) { $0.state = .paused(Self.otherProcess) }
                continue
            }
            guard case .queued(let id, _, let helper) = item.state else { continue }
            // A stored conversation's queue outlives its helper: the id names the item for every helper, and an item the
            // host no longer holds was sent or removed there, never to be added again.
            let durable = stored(item)
            let match = snapshot.first { $0.id == id && !claimed.contains($0.id) && (helper == helperToken || nativeQueue || durable) }
                ?? (durable ? nil : snapshot.first { !claimed.contains($0.id) && $0.carries(item) })
            if let match {
                claimed.insert(match.id)
                outbox.update(item.id) { $0.state = .queued(id: match.id, revision: match.revision, helper: self.helperToken) }
            } else if durable || delivered(item) || helper == helperToken {
                outbox.remove(item.id)
            } else if head && !undrained {
                outbox.update(item.id) {
                    $0.state = .uncertain("The connection dropped while this message was next in line. Check the thread, then send or discard it.")
                }
            } else {
                outbox.update(item.id) { $0.state = .waiting }
            }
            head = false
        }
        dropTurn = nil
        await drainQueue()
    }

    /// The host's queue store keeps this item: a helper-held queue of a conversation the agent named when it was added.
    private func stored(_ item: ChatOutboxItem) -> Bool {
        !nativeQueue && !(item.conversation ?? "").isEmpty
    }

    /// The transcript shows the message as the user's, written after it was queued: its text and as many attachments
    /// (the same host copies where the record names them), so an attachment-only message is not taken for another.
    private func delivered(_ item: ChatOutboxItem) -> Bool {
        let since = item.created.addingTimeInterval(-300).timeIntervalSince1970 * 1000
        return transcript.turns.contains { turn in
            turn.items.contains {
                AgentInput.records($0, prompt: item.text, attachments: item.attachments) && Double($0.source?.time_ms ?? 0) >= since
            }
        }
    }

    /// Mirrors every waiting device item in order, up to a shell command, which runs by itself once the agent is idle
    /// and nothing is ahead of it. One drain at a time; a request made meanwhile runs it again. The core-held queue is
    /// held while it fills, so the agent starts on the first message only after all are in (Codex's own queue has no
    /// hold).
    private func drainQueue() async {
        guard !draining else { drainAgain = true; return }
        draining = true
        defer { draining = false }
        repeat {
            drainAgain = false
            await drainOnce()
        } while drainAgain && phase == .verified
        changed?(self)
    }

    private func drainOnce() async {
        guard phase == .verified, let client else { return }
        adoptProcess()
        // Stop paused the device's items: nothing new goes ahead of them until Resume.
        guard !queueItems.contains(where: { $0.state == .paused(Self.stopped) }) else { return }
        let items = queueItems
        let shell = items.firstIndex { $0.shell && $0.state == .waiting }
        let waiting = items[..<(shell ?? items.endIndex)].filter { $0.state == .waiting }
        let generation = generation, hold = !nativeQueue && waiting.count > 1
        // The hold is released on the helper that took it, with the route it was taken for, whatever happened meanwhile
        // (a reconnect must not release the next helper's hold halfway through its own drain).
        let route = route()
        if hold { try? await setHeld(true, client: client, route: route) }
        var mirrored = true
        for item in waiting {
            guard self.generation == generation, phase == .verified else { mirrored = false; break }
            guard await mirror(item.id) else { mirrored = false; break }
        }
        if hold {
            do { try await setHeld(false, client: client, route: route) } catch {
                // Still that helper: once more, then say so (a held queue never starts the agent).
                if self.client === client, (try? await setHeld(false, client: client, route: route)) == nil {
                    queueError = "The queue could not be released: \(error.localizedDescription)"
                    failure = queueError
                }
            }
        }
        guard mirrored, let shell, self.generation == generation, idle, queue.isEmpty,
              !queueItems.prefix(while: { $0.id != items[shell].id }).contains(where: { $0.state == .adding || $0.helperID != nil })
        else { return }
        await runShell(items[shell].id, generation: generation)
    }

    /// Items queued before the agent was bound belong to the process the verified conversation names; an item typed for
    /// another process is paused (ChatCoordinator.drainQueue, `matches`).
    private func adoptProcess() {
        guard let process = ChatOutboxItem.Process(binding) else { return }
        for item in queueItems where item.state == .waiting {
            if item.process == nil { outbox.update(item.id) { $0.process = process } }
            else if item.process != process { outbox.update(item.id) { $0.state = .paused(Self.otherProcess) } }
        }
    }

    /// A queued shell command at the head of an idle conversation: `chat.command`, as the composer sends one.
    private func runShell(_ id: UUID, generation: UUID) async {
        guard let item = queueItems.first(where: { $0.id == id }), item.state == .waiting else { return }
        var input = route()
        input.text = item.text
        lastCommand = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        outbox.update(id) { $0.state = .adding }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let ticket = beginSending()
        defer { if sendTicket == ticket { sending = false } }
        do {
            let outcome: HelperChat.Outcome = try await call("chat.command", input, generation: generation)
            try outcome.confirmed()
            outbox.remove(id)
            commandResult = outcome.result(agent: agentName)
            drainAgain = true
        } catch let error as ChatInputNotSent {
            outbox.update(id) { $0.state = .waiting }
            failure = error.localizedDescription
        } catch {
            let uncertain = ChatInputNotSent.deliveryUncertain(error, started: true)
            outbox.update(id) {
                $0.state = uncertain
                    ? .uncertain("The host may have run this command. Check the thread, then send or discard it.")
                    : .paused(explain(error))
            }
            failure = explain(error)
        }
    }

    private func setHeld(_ held: Bool, client: HelperClient, route: HelperChat.Input) async throws {
        var input = route
        input.held = held
        let _: HelperClient.Empty = try await client.connection.request("queue.hold", params: input)
    }

    func editQueued(_ row: QueueRow, text: String) {
        guard row.editable, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch row.source {
        case .device(let id):
            guard let item = queueItems.first(where: { $0.id == id }) else { return }
            let command = AgentInput.isCommand(text, multiline: text.contains("\n"))
            if case .queued(let helperID, let revision, _) = item.state {
                var input = route()
                input.item = helperID; input.revision = revision; input.text = text; input.command = command
                changeQueue("queue.update", input, item: id, succeeded: {
                    self.outbox.update(id) { $0.text = text; $0.command = command }
                })
            } else {
                outbox.update(id) { $0.text = text; $0.command = command }
                if item.state == .waiting { Task { await self.drainQueue() } }
            }
        case .helper(let helperID):
            guard let native = queue.first(where: { $0.id == helperID }) else { return }
            var input = route()
            input.item = native.id; input.revision = native.revision; input.text = text; input.command = false
            changeQueue("queue.update", input)
        }
    }

    func removeQueued(_ row: QueueRow) {
        switch row.source {
        case .device(let id):
            guard let item = queueItems.first(where: { $0.id == id }) else { return }
            if case .queued(let helperID, let revision, _) = item.state, phase == .verified {
                var input = route()
                input.item = helperID; input.revision = revision
                changeQueue("queue.remove", input, item: id, succeeded: { self.outbox.remove(id) })
            } else {
                outbox.remove(id)
                // What waited behind it (a shell command, Stop's paused items) may go now.
                if phase == .verified { Task { await self.drainQueue() } }
            }
        case .helper(let helperID):
            guard let native = queue.first(where: { $0.id == helperID }) else { return }
            var input = route()
            input.item = native.id; input.revision = native.revision
            changeQueue("queue.remove", input)
        }
    }

    /// Whether "send now" may deliver this row (ChatQueueView.steerDisabled): not a paused or uncertain one (it may
    /// already have gone out), not one being added, and not a row the agent cannot change while it works.
    func canSendNow(_ row: QueueRow) -> Bool {
        guard phase == .verified, !queueBusy, row.status == nil, row.steerable || !working else { return false }
        if case .device(let id) = row.source {
            guard let item = queueItems.first(where: { $0.id == id }), item.state != .adding else { return false }
            // A command does not steer: it waits for an idle agent like any typed command.
            return !item.command || idle
        }
        return true
    }

    /// Long-press "send now" (interrupts the turn: steer while working). A device-only message goes by `chat.send`, a
    /// device-only command by `chat.command`.
    func sendQueuedNow(_ row: QueueRow) {
        guard canSendNow(row) else { return }
        let mode = working ? "steer" : "prompt"
        failure = nil
        let device: UUID? = if case .device(let id) = row.source { id } else { nil }
        let item = device.flatMap { id in queueItems.first { $0.id == id } }
        let helperID: String? = if case .helper(let id) = row.source { id } else { item?.helperID }
        var input = route()
        let method: String
        if let helperID, let native = queue.first(where: { $0.id == helperID }) {
            method = "queue.start"
            input.item = native.id; input.revision = native.revision; input.mode = mode
        } else if let item, item.command {
            method = "chat.command"
            input.text = item.text
        } else if let item {
            method = "chat.send"
            input.text = item.text; input.mode = mode; input.attachments = Self.paths(item.attachments)
        } else { return }
        queueBusy = true
        if let device { inFlight.insert(device) }
        let generation = generation
        Task {
            defer { self.queueBusy = false; if let device { self.inFlight.remove(device) } }
            do {
                if method == "chat.command" {
                    let outcome: HelperChat.Outcome = try await call(method, input, generation: generation)
                    try outcome.confirmed()
                    self.commandResult = outcome.result(agent: self.agentName)
                } else {
                    let sent: HelperChat.Sent = try await call(method, input, generation: generation)
                    try sent.confirmed()
                }
                if let device { self.outbox.remove(device) }
            } catch {
                let uncertain = ChatInputNotSent.deliveryUncertain(error, started: true)
                if let device {
                    // A started item has left the helper's queue either way; the device keeps it for the user.
                    self.outbox.update(device) {
                        $0.state = uncertain ? .uncertain("Delivery could not be confirmed. Check the thread, then send or discard it.")
                            : .paused(self.explain(error))
                    }
                }
                self.failure = self.explain(error)
            }
        }
    }

    /// Moves a row; the device order and the helper's order follow.
    func moveQueued(from source: Int, to destination: Int) {
        var rows = queueRows
        guard rows.indices.contains(source), rows.indices.contains(destination), source != destination else { return }
        rows.insert(rows.remove(at: source), at: destination)
        let devices = rows.compactMap { row -> UUID? in if case .device(let id) = row.source { id } else { nil } }
        let previous = queueItems.map(\.id)
        outbox.reorder(key, devices)
        let helperOrder = rows.compactMap { row -> String? in
            switch row.source {
            case .device(let id): queueItems.first { $0.id == id }?.helperID
            case .helper(let id): id
            }
        }
        guard phase == .verified, helperOrder.count > 1, Set(helperOrder) == Set(queue.map(\.id)),
              helperOrder != queue.map(\.id) else { return }
        var input = route()
        input.items = helperOrder
        // The rows move at once; a refusal puts them back.
        let previousQueue = queue
        queue = helperOrder.compactMap { id in previousQueue.first { $0.id == id } }
        changeQueue("queue.reorder", input, failed: {
            self.outbox.reorder(self.key, previous)
            self.queue = previousQueue
        })
    }

    /// A paused or uncertain message: the user's own decision to send it (it goes into the queue again).
    func resendQueued(_ row: QueueRow) {
        guard case .device(let id) = row.source else { return }
        outbox.update(id) { $0.state = .waiting }
        if phase == .verified { Task { await self.drainQueue() } }
    }

    /// A message back into the composer for editing (device-only messages).
    func editInComposer(_ row: QueueRow) {
        guard case .device(let id) = row.source, let item = queueItems.first(where: { $0.id == id }), item.helperID == nil else { return }
        drafts.restore(ChatDraft(text: item.text, multiline: item.text.contains("\n"), attachments: item.attachments))
        outbox.remove(id)
    }

    /// Resumes a queue paused after Stop: the helper's (`queue.restore`) and the device's own items.
    func resumeQueue() {
        for item in queueItems where item.state == .paused(Self.stopped) { outbox.update(item.id) { $0.state = .waiting } }
        if queue.contains(where: { $0.paused == "stopped" }) {
            changeQueue("queue.restore", route(), succeeded: { Task { await self.drainQueue() } })
        } else if phase == .verified { Task { await self.drainQueue() } }
    }

    /// One queue change at a time; the helper's `chat.queue` snapshot follows each.
    private func changeQueue(_ method: String, _ input: HelperChat.Input, item: UUID? = nil,
                             succeeded: (@MainActor () -> Void)? = nil, failed: (@MainActor () -> Void)? = nil) {
        guard phase == .verified, !queueBusy else { failed?(); return }
        queueBusy = true; failure = nil
        if let item { inFlight.insert(item) }
        let generation = generation
        Task {
            defer { self.queueBusy = false; if let item { self.inFlight.remove(item) } }
            do {
                let _: HelperClient.Empty = try await call(method, input, generation: generation)
                succeeded?()
            } catch {
                failed?()
                self.failure = self.explain(error)
            }
        }
    }

    /// The helper takes attachments (hello feature `chat.attachments`) and the conversation takes input: the composer
    /// offers "+", paste and drop. A command draft takes none.
    var attachmentsAvailable: Bool { features.contains(ChatAttachment.feature) && client != nil && phase == .verified }
    var canAttach: Bool { attachmentsAvailable && !drafts.shape.command }

    /// Picked, pasted or dropped files: each is read and prepared off the main actor (`ChatAttachmentImage.prepare`),
    /// stored on the host (`attachments.put`), then added to the draft. More than a message carries uploads nothing.
    func attach(_ sources: [MobileAttachmentSource]) {
        guard canAttach, !sources.isEmpty else { return }
        attachmentError = nil
        let draft = drafts.current
        guard draft.attachments.count + draftUploads.count + sources.count <= ChatAttachment.maximumCount else {
            attachmentError = ChatAttachmentError.tooMany.localizedDescription
            return
        }
        for source in sources {
            let upload = ChatUpload(id: UUID().uuidString, draft: draft.id, scope: drafts.scope, name: source.name, kind: source.kind)
            uploads.append(upload)
            uploadSources[upload.id] = source
            start(upload.id)
        }
    }

    /// A failed upload, once more (on the current connection), for the draft the composer shows.
    func retryUpload(_ id: String) {
        guard let index = uploads.firstIndex(where: { $0.id == id }), uploads[index].error != nil else { return }
        guard attachmentsAvailable else { attachmentError = "\(hostName) is not connected."; return }
        uploads[index].error = nil
        uploads[index].draft = drafts.current.id; uploads[index].scope = drafts.scope
        start(id)
    }

    /// Drops an upload (a running one's reply is ignored; the host sweeps its copy) or a stored attachment of the draft.
    func removeAttachment(_ id: String) {
        if uploads.contains(where: { $0.id == id }) {
            uploads.removeAll { $0.id == id }
            uploadSources[id] = nil
        } else {
            drafts.detach(id)
        }
    }

    private func start(_ id: String) {
        guard let source = uploadSources[id], let client else { return }
        let connection = client.connection
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ChatAttachmentImage.prepare(name: source.name, data: try await source.load())
                }.value
                guard uploads.contains(where: { $0.id == id }) else { return }
                updateUpload(id) { $0.name = prepared.name; $0.kind = prepared.kind; $0.thumbnail = prepared.thumbnail }
                let stored: HelperChat.StoredAttachment = try await connection.request(
                    "attachments.put", params: HelperChat.AttachmentUpload(name: prepared.name, bytes: prepared.bytes))
                // Removed meanwhile: the copy stays unnamed on the host until its sweep.
                guard let upload = uploads.first(where: { $0.id == id }) else { return }
                // Into the draft it was for, wherever the user switched meanwhile; that draft gone (sent, discarded, or
                // replaced by a restored message), the chip moves to the current one and Retry attaches it there.
                guard let fitted = drafts.attach([stored.attachment(id: id, thumbnail: prepared.thumbnail)],
                                                 toDraft: upload.draft, scope: upload.scope) else {
                    updateUpload(id) {
                        $0.draft = self.drafts.current.id; $0.scope = self.drafts.scope
                        $0.error = "The draft it was for was sent or discarded. Retry attaches it here."
                    }
                    return
                }
                uploads.removeAll { $0.id == id }
                uploadSources[id] = nil
                if !fitted { attachmentError = ChatAttachmentError.tooMany.localizedDescription }
            } catch let error as ChatAttachmentError {
                // Too large or unreadable: nothing was uploaded, and trying again would not change that.
                guard uploads.contains(where: { $0.id == id }) else { return }
                uploads.removeAll { $0.id == id }
                uploadSources[id] = nil
                attachmentError = error.localizedDescription
            } catch {
                updateUpload(id) { $0.error = error.localizedDescription }
            }
        }
    }

    private func updateUpload(_ id: String, _ change: (inout ChatUpload) -> Void) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        change(&uploads[index])
    }

    /// A stored attachment's bytes (`attachments.read`), for a thumbnail or a preview the device does not have; nil when
    /// this helper cannot say (not connected, or without the feature).
    func attachmentBytes(_ path: String) async throws -> Data? {
        guard let client, features.contains(ChatAttachment.feature) else { return nil }
        let read: HelperChat.AttachmentBytes = try await client.connection.request(
            "attachments.read", params: HelperChat.AttachmentRead(path: path))
        return read.bytes
    }

    func loadEarlier() {
        guard phase == .verified, let earlier, !loadingEarlier else { return }
        loadingEarlier = true; earlierError = nil
        var input = route()
        input.earlier = earlier
        Task {
            defer { self.loadingEarlier = false }
            do {
                let page: HelperChat.Page = try await call("chat.page", input)
                self.transcript.apply(page.records, historical: true, earlier: true)
                self.earlier = page.earlier
            } catch { self.earlierError = error.localizedDescription }
        }
    }

    /// The agent's models (`chat.models`), from the cache while fresh.
    func models() async throws -> [AgentModelMenu.Choice] {
        if let catalog = modelChoices.catalog { return catalog.models }
        modelsLoading = true
        defer { modelsLoading = false }
        let menu: HelperChat.Menu = try await call("chat.models", route())
        let choices = Self.choices(menu)
        modelChoices.store(models: choices, quickModels: [])
        return choices
    }

    /// A model's efforts (`chat.settings`).
    func efforts(for model: String) async throws -> [AgentModelMenu.Choice] {
        if let cached = modelChoices.efforts(for: model) { return cached }
        var input = route()
        input.model = model
        let menu: HelperChat.Menu = try await call("chat.settings", input)
        let choices = Self.choices(menu)
        modelChoices.store(efforts: choices, for: model)
        return choices
    }

    /// The helper's menu as cache choices: `name` is the choice id the helper takes back, `detail` its label.
    private static func choices(_ menu: HelperChat.Menu) -> [AgentModelMenu.Choice] {
        menu.choices.enumerated().map { index, choice in
            AgentModelMenu.Choice(number: index + 1, name: choice.id, detail: choice.label,
                                  current: choice.id == menu.current, isDefault: choice.id == menu.default)
        }
    }

    /// Applies a model and effort through the helper's verified menu transport (`chat.settings.set`), and returns what
    /// the agent then reports (`chat.state`), as the Mac's picker does: completing the native dialog can also mean the
    /// change was declined, and only the reported choice is remembered.
    @discardableResult
    func select(model: String, effort: String?) async throws -> (model: String, effort: String?) {
        var input = route()
        input.model = model
        input.effort = effort
        let sent: HelperChat.Sent = try await call("chat.settings.set", input)
        try sent.confirmed()
        struct Observed: Decodable { let state: HelperChat.State }
        let observed: Observed? = try? await call("chat.state", route())
        let reported = observed?.state
        let chosen = reported?.model.map { ($0, reported?.effort) } ?? (model, effort)
        self.model = chosen.0
        self.effort = chosen.1
        return chosen
    }

    private func applyPendingSettings() {
        guard let pending = pendingSettings, phase == .verified, model != nil else { return }
        pendingSettings = nil
        // The remembered choice is a menu row ("Opus 5.5"); the agent reports the model's ID (claude-opus-5-5).
        let same = pending.model == model || AgentModelMenu.claudeModelID(pending.model) == model
        guard !same || (pending.effort != nil && pending.effort != effort) else { return }
        Task {
            do { try await self.select(model: pending.model, effort: pending.effort) }
            catch { self.failure = self.explain(error) }
        }
    }

    /// A step's full output (`chat.tools`), merged into the transcript.
    func fullOutput(of item: ChatItem) async throws -> HelperChat.Record {
        var input = route()
        input.record = item.source?.id ?? item.id
        let record: HelperChat.Record = try await call("chat.tools", input)
        transcript.replaceTool(record)
        return record
    }

    private func route() -> HelperChat.Input {
        HelperChat.Input(HelperChat.Route(terminal: terminal ?? 0, session: conversation))
    }

    /// `chat.send`'s and `queue.add`'s `attachments`: the host copies, nil without any.
    private static func paths(_ attachments: [ChatAttachment]) -> [String]? {
        let paths = attachments.compactMap(\.path)
        return paths.isEmpty ? nil : paths
    }

    /// One request on the current client. No client: nothing was sent (ChatInputNotSent). `generation`: the
    /// subscription the input was made for; a request built before a reconnect or a reopen is not sent to the new
    /// one (its terminal id and requests belong to the old helper), as docs/architecture.md's Delivery asks.
    private func call<R: Decodable>(_ method: String, _ input: HelperChat.Input, generation: UUID? = nil) async throws -> R {
        guard let client, terminal != nil else {
            throw ChatInputNotSent(HelperFailure(code: "connection_closed", message: "\(hostName) is not connected."))
        }
        if let generation, generation != self.generation || input.terminal != terminal {
            throw ChatInputNotSent(HelperFailure(code: "destination_changed",
                                                 message: "The connection to \(agentName) changed before this was sent. Nothing was sent."))
        }
        return try await client.connection.request(method, params: input)
    }
}

/// One approval chip (M4b): which option of the helper's approval question it answers.
struct ApprovalChoice: Identifiable, Equatable {
    enum Role: Equatable { case deny, session, allow }
    let role: Role
    /// The option index in the interaction's question (option 0 allows, 1 denies: PROTOCOL.md Interaction.approval).
    let index: Int
    var id: Int { index }
    var label: String {
        switch role { case .deny: "Deny"; case .session: "This session"; case .allow: "Allow" }
    }
}

extension HelperChat.Interaction {
    /// What the approval bubble says and the mono block it shows (M4b): the tool input's own description and
    /// command, file or pattern when the operation is JSON; else the permission's title and the operation.
    var approvalPresentation: (text: String, code: String?) {
        guard let question = questions.first else { return ("", nil) }
        let operation = question.text.isEmpty ? question.header : operation ?? question.text
        let object = ToolPresentation.json(operation) as? [String: Any]
        let title = permission?.title ?? (question.header.hasSuffix("?") ? question.header : "Allow \(question.header)?")
        let text = (object?["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
        let code = ToolPresentation.command(object?["command"] ?? object?["cmd"])
            ?? object?["file_path"] as? String ?? object?["path"] as? String ?? object?["url"] as? String
            ?? object?["pattern"] as? String ?? (object == nil ? operation : nil)
        return (text, code ?? (object != nil ? operation : nil))
    }
}

extension HelperChat.Queued {
    /// Whether this helper row is `item` as the device added it: its text, and as many attachments (the preview names
    /// them by type only).
    func carries(_ item: ChatOutboxItem) -> Bool {
        let attachments = previewAttachments
        return attachments.count == item.attachments.count && (attachments.isEmpty ? text : typedText) == item.text
    }

    /// What was typed, without the attachment lines `text` names by type.
    var typedText: String { preview.filter { $0.kind == "text" }.compactMap(\.text).joined(separator: "\n") }

    /// The attachments the preview names (`{kind: "attachment", type}`), by kind only: the queue keeps no names or paths.
    var previewAttachments: [ChatAttachment] {
        preview.enumerated().compactMap { index, entry in
            guard entry.kind == "attachment" else { return nil }
            let kind: ChatAttachment.Kind = (entry.type ?? "").localizedCaseInsensitiveContains("image") ? .image : .file
            return ChatAttachment(id: "\(id)#\(index)", name: ChatAttachment.untitled(kind), kind: kind, size: 0, path: nil)
        }
    }
}
