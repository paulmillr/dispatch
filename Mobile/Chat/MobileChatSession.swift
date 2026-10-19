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
        /// The chip the user chose (shown as their reply).
        var chosen: ApprovalChoice?
        var id: UUID { pending.id }
    }

    nonisolated let key: ChatConversationKey
    nonisolated var id: ChatConversationKey { key }
    /// The host's display name (banner, captions, facts).
    var hostName: String

    private(set) var link: HostLink = .disconnected
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
    private(set) var modelLabel: String?
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
    /// A command's own result (chat.command), shown until the next send.
    var commandResult: ChatCommandResult?

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

    /// The host's link and client changed (HostSession.link, .client).
    func update(link: HostLink, client: HelperClient?) {
        let previous = self.client
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
    var working: Bool { (busy || awaitingAck || starting || !subagents.isEmpty) && attention == nil }
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
            }
        }
        updateWorkingSince()
    }

    /// A live user record that repeats the prompt shown while it was sent takes its bubble's place
    /// (ChatSession.reconcilePrompt): the row keeps its identity, nothing moves.
    private func reconcile(_ item: ChatItem, turn: String) -> ChatItem {
        guard item.kind == .user, let pending = optimisticPrompt else { return item }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [pending.text, AgentInput.fenced(pending.text)].contains(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }) else { return item }
        var confirmed = item
        confirmed.rowID = pending.id
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
            modelLabel = state.model_label
            effort = state.effort
        }
        attention = state.attention
        if let title = state.title { self.title = title }
        compacting = state.compacting
        if !working { submittedAt = nil }
        updateWorkingSince()
        applyPendingSettings()
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
            approvals.append(Approval(pending: pending, interaction: interaction, arrived: Date(), generation: generation))
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
            approvals.append(Approval(pending: pending, interaction: interaction, arrived: Date(), generation: generation))
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

    /// Where the composer's text goes now.
    func route(steer: Bool) -> Route {
        guard phase == .verified, client != nil, terminal != nil else { return .outbox }
        if steer, working, terminalAttached { return .steer }
        if working || sending || !queueRows.isEmpty || waitingForUser || !terminalAttached { return .queue }
        return .prompt
    }

    /// The composer's text, sent by `route(steer:)`. The draft leaves the composer only once its destination took it
    /// (for the queue, once it is saved on the device); a failure restores it.
    func send(steer: Bool = false) {
        let text = drafts.current.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        failure = nil; commandResult = nil
        let route = route(steer: steer)
        guard let delivery = drafts.prepareDelivery(consume: true) else { return }
        switch route {
        case .outbox, .queue:
            let item = ChatOutboxItem(key: key, conversation: conversation, text: text)
            let accepted = outbox.add(item)
            drafts.finish(delivery, success: accepted)
            if !accepted { failure = outbox.error; return }
            if route == .queue { Task { _ = await self.mirror(item.id) } }
        case .prompt where AgentInput.isCommand(text, multiline: text.contains("\n")):
            command(text, delivery: delivery)
        case .prompt, .steer:
            prompt(text, steer: route == .steer, delivery: delivery)
        }
    }

    private func prompt(_ text: String, steer: Bool, delivery: ChatDraftDelivery) {
        var input = route()
        input.text = text
        input.mode = steer ? "steer" : "prompt"
        let generation = generation
        let pending = ChatItem(id: "pending-" + UUID().uuidString, kind: .user, text: text)
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
                self.drafts.finish(delivery, success: true)
            } catch {
                // Not retried: the draft comes back and the failure says whether it may have been sent.
                self.drafts.finish(delivery, success: false)
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

    private func command(_ text: String, delivery: ChatDraftDelivery) {
        var input = route()
        input.text = text
        let generation = generation
        let ticket = beginSending()
        Task {
            defer { if self.sendTicket == ticket { self.sending = false } }
            do {
                let outcome: HelperChat.Outcome = try await call("chat.command", input, generation: generation)
                try outcome.confirmed()
                self.drafts.finish(delivery, success: true)
                self.commandResult = outcome.result(agent: self.agentName)
            } catch {
                self.drafts.finish(delivery, success: false)
                self.failure = self.explain(error)
            }
        }
    }

    func stop() {
        guard phase == .verified, working, !stopping else { return }
        stopping = true
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
        var editable: Bool
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
            return QueueRow(source: .device(item.id), text: item.text, status: status, editable: helper?.editable ?? true)
        }
        let mirrored = Set(items.compactMap(\.helperID))
        rows += queue.filter { !mirrored.contains($0.id) }.map {
            QueueRow(source: .helper($0.id), text: $0.text, status: $0.paused.map(Self.pauseText), editable: $0.editable)
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

    /// The helper stopped its queue (Stop): Resume restores it.
    var queueStopped: Bool { queue.contains { $0.paused == "stopped" } }

    private func receive(queue items: [HelperChat.Queued]) {
        queue = items
        // A mirrored message this helper no longer holds was sent by it (the helper removes an item only once it was
        // typed, or on the user's own remove, which removes the device item first).
        for item in queueItems where !inFlight.contains(item.id) {
            guard case .queued(let id, _, let helper) = item.state, helper == helperToken else { continue }
            if let current = items.first(where: { $0.id == id }) {
                outbox.update(item.id) { $0.state = .queued(id: id, revision: current.revision, helper: helper); $0.text = current.text }
            } else { outbox.remove(item.id) }
        }
    }

    /// Puts a device item into the helper's queue (`queue.add`). A failure after the request went out pauses it.
    private func mirror(_ id: UUID) async -> Bool {
        guard let item = queueItems.first(where: { $0.id == id }), phase == .verified else { return false }
        var input = route()
        input.text = item.text; input.mode = "prompt"; input.command = false
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
            guard case .queued(let id, _, let helper) = item.state else { continue }
            let match = snapshot.first { $0.id == id && !claimed.contains($0.id) && (helper == helperToken || nativeQueue) }
                ?? snapshot.first { !claimed.contains($0.id) && $0.text == item.text }
            if let match {
                claimed.insert(match.id)
                outbox.update(item.id) { $0.state = .queued(id: match.id, revision: match.revision, helper: self.helperToken) }
            } else if delivered(item) || helper == helperToken {
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

    /// The transcript shows the message as the user's, written after it was queued.
    private func delivered(_ item: ChatOutboxItem) -> Bool {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let since = item.created.addingTimeInterval(-300).timeIntervalSince1970 * 1000
        return transcript.turns.contains { turn in
            turn.items.contains { $0.kind == .user && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
                && Double($0.source?.time_ms ?? 0) >= since }
        }
    }

    /// Mirrors every waiting device item in order. The core-held queue is held while it fills, so the agent starts on
    /// the first message only after all are in (Codex's own queue has no hold).
    private func drainQueue() async {
        let waiting = queueItems.filter { $0.state == .waiting }
        guard !waiting.isEmpty, phase == .verified, let client else { return }
        let generation = generation, hold = !nativeQueue && waiting.count > 1
        // The hold is released on the helper that took it, with the route it was taken for, whatever happened meanwhile
        // (a reconnect must not release the next helper's hold halfway through its own drain).
        let route = route()
        if hold { try? await setHeld(true, client: client, route: route) }
        for item in waiting {
            guard self.generation == generation, phase == .verified else { break }
            guard await mirror(item.id) else { break }
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
        changed?(self)
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
            if case .queued(let helperID, let revision, _) = item.state {
                var input = route()
                input.item = helperID; input.revision = revision; input.text = text; input.command = false
                changeQueue("queue.update", input, item: id, succeeded: { self.outbox.update(id) { $0.text = text } })
            } else {
                outbox.update(id) { $0.text = text }
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
            }
        case .helper(let helperID):
            guard let native = queue.first(where: { $0.id == helperID }) else { return }
            var input = route()
            input.item = native.id; input.revision = native.revision
            changeQueue("queue.remove", input)
        }
    }

    /// Long-press "send now" (interrupts the turn: steer while working). A device-only message goes by `chat.send`.
    func sendQueuedNow(_ row: QueueRow) {
        guard phase == .verified, !queueBusy else { return }
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
        } else if let item {
            method = "chat.send"
            input.text = item.text; input.mode = mode
        } else { return }
        queueBusy = true
        if let device { inFlight.insert(device) }
        let generation = generation
        Task {
            defer { self.queueBusy = false; if let device { self.inFlight.remove(device) } }
            do {
                let sent: HelperChat.Sent = try await call(method, input, generation: generation)
                try sent.confirmed()
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
        drafts.restore(ChatDraft(text: item.text, multiline: item.text.contains("\n")))
        outbox.remove(id)
    }

    /// Resumes a queue the helper paused after Stop (`queue.restore`).
    func resumeQueue() { changeQueue("queue.restore", route()) }

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

    /// Applies a model and effort through the helper's verified menu transport (`chat.settings.set`).
    func select(model: String, effort: String?) async throws {
        var input = route()
        input.model = model
        input.effort = effort
        let sent: HelperChat.Sent = try await call("chat.settings.set", input)
        try sent.confirmed()
        self.model = model
        self.effort = effort
        modelLabel = modelChoices.catalog?.models.first { $0.name == model }?.detail
    }

    private func applyPendingSettings() {
        guard let pending = pendingSettings, phase == .verified, model != nil else { return }
        pendingSettings = nil
        guard pending.model != model || (pending.effort != nil && pending.effort != effort) else { return }
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
        let operation = question.text.isEmpty ? question.header : question.text
        let object = ToolPresentation.json(operation) as? [String: Any]
        let title = permission?.title ?? (question.header.hasSuffix("?") ? question.header : "Allow \(question.header)?")
        let text = (object?["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? title
        let code = ToolPresentation.command(object?["command"] ?? object?["cmd"])
            ?? object?["file_path"] as? String ?? object?["path"] as? String ?? object?["url"] as? String
            ?? object?["pattern"] as? String ?? (object == nil ? operation : nil)
        return (text, code ?? (object != nil ? operation : nil))
    }
}
