import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class ChatCoordinator {
    private(set) var sessions: [UUID: ChatSession] = [:]
    private(set) var enabled: Bool
    @ObservationIgnored private let draftRepository: ChatDraftRepository
    var error: String?
    struct InstallationTarget: Hashable {
        let key: String
        let endpoint: HelperWorkspace.Endpoint
        let terminal: UInt64?
    }
    @ObservationIgnored var installationFailures: [InstallationTarget: String] = [:] {
        didSet { error = installationFailures.isEmpty ? nil : installationFailures.values.sorted().joined(separator: "\n") }
    }
    /// Agent names the helper can launch; nil until loaded.
    var helperLaunches: [HelperClient.Launch]?
    /// Latest helper installation facts by opaque launch key.
    var helperInstalls: [String: HelperChat.Installation] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    /// Integrations the user turned off. The helper keeps that choice only while it runs, so every
    /// connection is told again (installation.install enabled:false).
    var disabledIntegrations: Set<String> {
        get { Set(defaults?.stringArray(forKey: "disabledIntegrations") ?? disabledInMemory) }
        set { disabledInMemory = Array(newValue); defaults?.set(Array(newValue).sorted(), forKey: "disabledIntegrations") }
    }
    @ObservationIgnored private var disabledInMemory: [String] = []
    /// Integration changes run one after another, so rapid toggles end in the last choice everywhere.
    /// All coordinators install into shared profiles; teardown joins the same queue.
    var integrationChanges: Task<Void, Never>? { Self.integrationTail }
    static var integrationTail: Task<Void, Never>?
    /// The first queued message showed its steering tip (once, ever).
    var queueTipShown: Bool { didSet { defaults?.set(queueTipShown, forKey: "chatQueueSteerTipShown") } }
    @ObservationIgnored private var owners: [String: UUID] = [:]
    /// A remote chat's presentation outlives its surface: after a reconnect the same host's conversation
    /// (or, before it has one, the same process) shows it again in whichever tab it appears.
    private struct RemotePresentation {
        let surface: UUID
        let conversation: String?
        let draftScope: String
        let saved: ChatSession.Presentation
        let interaction: Bool
        let date: Date
    }
    private struct RemotePresentationKey: Hashable {
        let host: String
        let agent: String
        let conversation: String?
        let provisionalProcess: String?
    }
    @ObservationIgnored private var remotePresentations: [RemotePresentationKey: RemotePresentation] = [:]
    @ObservationIgnored let operations = ChatOperations()
    @ObservationIgnored private var submissions: [UUID: Task<Void, Never>] = [:]

    /// An explicit chat opt-out takes precedence over the default (on).
    init(enabled: Bool? = nil, draftRepository: ChatDraftRepository = .shared, defaults: UserDefaults? = .app) {
        self.enabled = enabled ?? (defaults?.object(forKey: "agentChatEnabled") as? Bool) ?? true
        self.draftRepository = draftRepository
        self.defaults = defaults
        queueTipShown = defaults?.bool(forKey: "chatQueueSteerTipShown") ?? false
    }

    func session(for id: UUID) -> ChatSession {
        if let session = sessions[id] {
            connectHelper(session)
            return session
        }
        let session = ChatSession(id: id, draftRepository: draftRepository)
        sessions[id] = session
        connectHelper(session)
        return session
    }
    func start() {
        for session in sessions.values { connectHelper(session) }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults?.set(value, forKey: "agentChatEnabled")
        error = nil
        installationFailures.removeAll()
        // Chat is the switch for every required integration the helper lists; optional ones stay opt-in.
        if !value { for session in sessions.values { end(session, preservingPresentation: false) } }
        for launch in helperLaunches ?? [] where helperInstalls[launch.key]?.optional != true {
            setHelperIntegration(launch.key, enabled: value)
        }
    }
    enum AgentHookStatus: Equatable { case off, restart, ready }
    /// Hooks installed during this run, by agent ID. Agents read them at startup.
    private(set) var hooksInstalledAt: [String: Date] = [:]

    /// Installed hooks only reach agents started afterwards; a local agent
    /// already running when they were installed needs a restart (Pi: /reload).
    func hookStatus(_ agent: String) -> AgentHookStatus {
        if disabledIntegrations.contains(agent) { return .off }
        switch helperInstalls[agent]?.status {
        case "restart": return .restart
        case "ready": return .ready
        default: return .off
        }
    }

    func close(_ id: UUID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        rememberRemotePresentation(session)
        session.helper?.close()
        session.helperTask?.cancel()
        cancelSubmission(session)
        session.drafts.persist(flush: true)
        draftRepository.activeScopes.remove(session.drafts.scope)
        session.relinquish()
        detachIdentity(session)
    }

    func answerQuestion(_ question: ChatSideQuestion, skip: Bool, session: ChatSession) {
        guard session.helper != nil else { return }
        answerHelper(question, skip: skip, session: session)
    }

    func stop() {
        sessions.values.forEach { $0.drafts.persist(flush: true); draftRepository.activeScopes.remove($0.drafts.scope) }
        draftRepository.flush()
        submissions.values.forEach { $0.cancel() }; submissions.removeAll()
        sessions.values.forEach {
            $0.helper?.close(); $0.helperTask?.cancel(); $0.helper = nil; $0.helperTask = nil
            $0.sideConversation?.close(); $0.sideConversation = nil
            $0.command?.cancel(); $0.command = nil; $0.modelPicker?.abandon(); $0.modelPicker = nil; $0.relinquish()
        }
        sessions.removeAll(); owners.removeAll()
    }
    func canEnterChat(_ session: ChatSession) -> Bool {
        enabled && (session.hasOpenedChat || session.sessionID != nil || !session.draft.isEmpty || (session.active && !session.discoveryBlocked))
    }
    /// Whether any of these terminals can switch to chat or is showing it. Unlike `session(for:)`, creates no sessions.
    func canShowChat(anyOf ids: some Sequence<UUID>) -> Bool {
        ids.contains { id in sessions[id].map { canEnterChat($0) || $0.showChat } ?? false }
    }
    func chatAvailabilityHint(_ session: ChatSession) -> String {
        if !enabled { return "Enable Agent chat in Settings, then start \(agents) in this terminal." }
        if (!session.active || session.inputBlocked), session.hasOpenedChat || session.sessionID != nil || !session.draft.isEmpty { return "View the retained conversation and edit drafts · sending paused" }
        if session.discoveryBlocked { return session.status ?? "Cannot safely identify this agent session. Continue in terminal." }
        if !session.active { return "Start \(agents) in this terminal. Finish any startup menus, then select Chat." }
        return "Show agent chat"
    }
    func toggle(_ id: UUID) {
        let session = session(for: id)
        guard session.showChat || canEnterChat(session) else { return }
        chooseChat(!session.showChat, session: session)
    }
    /// Only explicit UI actions call this. Backend failures request attention instead.
    func chooseChat(_ value: Bool, session: ChatSession) {
        session.manualViewChoice = true
        if value { session.terminalAttention = nil }
        setChatVisible(value, session: session, reason: "user")
        if !value {
            session.submissionFailure = nil
            session.command?.cancel(); session.command = nil; session.nativePrompt = nil
            session.relinquish(); DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
        }
    }
    /// Double Ctrl+D quits the agent, as it does in Terminal. An agent without
    /// a quit command, or one that is not idle, only switches to Terminal.
    func quitCommand(_ session: ChatSession) -> String? {
        guard session.helperCommands.contains("/quit"), session.draft.isEmpty, session.queuedMessages.isEmpty,
              inputReady(session) else { return nil }
        return "/quit"
    }
    func quitFromChat(_ session: ChatSession) {
        guard let command = quitCommand(session) else { return chooseChat(false, session: session) }
        session.draft = command
        submit(session)
    }
    func setChatVisible(_ value: Bool, session: ChatSession, reason: String = "discovery") {
        if !value { session.drafts.persist(flush: true) }
        session.setView(value, reason: reason)
        if value, let terminal = TerminalRuntime.shared.views[session.id], terminal.window?.firstResponder === terminal {
            terminal.window?.makeFirstResponder(nil)
        }
    }

    /// Keep presentation and discovery independent of native UI readiness.
    /// Rediscovery must not clear this pause or replay an interrupted operation.
    func requireTerminalAttention(_ session: ChatSession, status: String) {
        guard sessions[session.id] === session else { return }
        if session.terminalAttention == nil {
            cancelSubmission(session)
            session.relinquish()
            session.drafts.persist(flush: true)
        }
        session.terminalAttention = status
    }

    func retryChat(_ session: ChatSession) {
        guard sessions[session.id] === session else { return }
        session.terminalAttention = nil
        // Retry readiness. Messages with uncertain delivery retain their own pause.
        drainQueue(session)
        session.focusRequest = UUID()
    }
    private func presentationKey(_ session: ChatSession) -> RemotePresentationKey? {
        guard let host = session.host else { return nil }
        let process = session.binding.map { "\($0.pid ?? 0):\($0.start ?? [])" }
        return .init(host: host, agent: session.agentID, conversation: session.sessionID,
                     provisionalProcess: session.sessionID == nil ? process : nil)
    }

    /// Display state belongs to the host and conversation, not a process or SSH generation (provisional
    /// chats still require the exact process). Input operations and approval replies never move with it.
    func rememberRemotePresentation(_ session: ChatSession) {
        guard let key = presentationKey(session) else { return }
        if session.approvals.contains(where: \.pending) || !session.questions.isEmpty {
            session.retiredInteraction = true
        }
        remotePresentations[key] = RemotePresentation(surface: session.id, conversation: session.sessionID, draftScope: session.drafts.scope,
                                                      saved: session.presentation, interaction: session.retiredInteraction, date: Date())
        if remotePresentations.count > 128, let oldest = remotePresentations.min(by: { $0.value.date < $1.value.date })?.key {
            remotePresentations[oldest] = nil
        }
    }

    func restoreRemotePresentation(_ session: ChatSession) {
        // A native prompt can arrive before the first history identifies the agent.
        // Retire its old connection's authority now; display state waits for history.
        if session.sessionID == nil, let conversation = session.helper?.route.session, let host = session.host {
            session.retiredInteraction = remotePresentations.contains {
                $0.key.host == host && $0.key.conversation == conversation && $0.value.interaction
            }
            return
        }
        guard let key = presentationKey(session), let saved = remotePresentations[key], saved.conversation == session.sessionID else { return }
        remotePresentations[key] = nil
        session.retiredInteraction = saved.interaction
        guard saved.surface != session.id else { return }
        if session.sessionID == nil { session.drafts.resumeProvisional(saved.draftScope) }
        let choice = session.manualViewChoice ? session.showChat : nil
        session.restorePresentation(saved.saved)
        if let choice {
            session.manualViewChoice = true
            session.setView(choice, reason: "user-preference-retained")
        }
    }

    func end(_ session: ChatSession, preservingPresentation: Bool = true) {
        if preservingPresentation { rememberRemotePresentation(session) }
        cancelSubmission(session)
        if !preservingPresentation { session.invalidateQueuedDestination() }
        session.drafts.persist(flush: true)
        session.active = false; session.busy = false; session.activityCheck = nil; session.relinquish()
        session.activityNeedsRefresh = true; session.activityRetryAfter = nil
        if !preservingPresentation { session.setView(false, reason: "integration-disabled") }
        session.status = "\(session.agentTitle) exited. This transcript is read-only."
        if !preservingPresentation {
            session.focusRequest = UUID()
            DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
        }
    }

    @discardableResult
    func loadEarlier(_ session: ChatSession, preservingBottom: Bool = false) -> Bool {
        guard session.helper != nil else { return false }
        return pageHelper(session, preservingBottom: preservingBottom)
    }

    func apply(_ records: [ChatRecord], to session: ChatSession, earlier: Bool, historical: Bool,
               configurationRevision: UUID? = nil) {
        var historicalRecords: [ChatRecord] = []
        let acceptTitle = !earlier || session.transcriptTitle == nil
        if historical { historicalRecords.reserveCapacity(records.count) }
        func insert(_ item: ChatItem, from record: ChatRecord) {
            if historical {
                historicalRecords.append(ChatRecord(key: record.key, turnID: record.turnID, date: record.date,
                    action: .item(item), fileOffset: record.fileOffset))
            } else {
                session.insert(item, turnID: record.turnID, at: record.date, fileOffset: record.fileOffset)
            }
        }
        for record in records where session.seen.insert(record.key).inserted {
            if !earlier, let reviewing = record.reviewing { session.reviewing = reviewing }
            switch record.action {
            case .title(let title):
                if acceptTitle { session.transcriptTitle = title }
            case .settings(let settings):
                if !earlier {
                    session.configurationRequest = nil
                    session.model = settings.model; session.effort = settings.effort
                    session.serviceTier = settings.serviceTier; session.collaborationMode = settings.mode
                    session.settingsRevision += 1
                }
            case .usage(let usage):
                if !earlier { session.usage = usage }
            case .goal(let goal):
                if !earlier {
                    session.goal = goal; session.goalUpdatedAt = record.date.timeIntervalSince1970 > 0 ? record.date : .now; session.goalRevision += 1
                    if session.commandResult?.title == "Goal" { session.commandResult?.text = goal?.summary ?? "Goal cleared." }
                }
            case .metadata(_, let version): session.version = version
            case .configuration(let model, let effort):
                if !earlier { session.applyConfiguration(model: model, effort: effort, revision: configurationRevision) }
            case .started:
                if historical { historicalRecords.append(record) }
                else { _ = session.turn(record.turnID, at: record.date, fileOffset: record.fileOffset) }
                // A later prompt may steer this turn without another start event.
                if !earlier { session.activeTurnID = record.turnID }
                if !earlier && session.promptBoundary?.accepts(record) != false {
                    session.activityCheck = nil
                    session.activityNeedsRefresh = false; session.activityRetryAfter = nil
                    if session.helper == nil { session.busy = session.active }
                    session.awaitingPromptAck = false; session.promptBoundary = nil
                }
            case .ended:
                if !earlier {
                    session.activityCheck = nil
                    session.activityNeedsRefresh = false; session.activityRetryAfter = nil
                }
                if historical { historicalRecords.append(record) }
                else {
                    let index = session.turn(record.turnID, at: record.date, fileOffset: record.fileOffset)
                    session.turns[index].ended = record.date
                }
                if !earlier && session.activeTurnID == record.turnID && !session.awaitingPromptAck && session.helper == nil { session.busy = false }
            case .compacted:
                insert(ChatItem(id: record.key, kind: .notice, text: "Conversation compacted"), from: record)
            case .commandOutput(let text):
                // Output from an earlier command cannot answer the pending one.
                if !earlier, session.observedCommand != nil, session.promptBoundary?.accepts(record) == true {
                    let output = session.observedCommand?.output
                    if output?.hasSuffix(text) != true { session.observedCommand?.output = output.map { $0 + "\n" + text } ?? text }
                }
            case .item(let item):
                // A slash command that became a user turn has no separate printed result.
                if !earlier, item.kind == .user, item.text == session.observedCommand?.title {
                    session.observedCommand = nil
                }
                // A retained accepted bubble keeps its own boundary after live
                // delivery state is cleared. Older identical text, including a
                // record in a replaced transcript file, cannot consume it.
                let retainedBoundary = session.optimisticPromptRetained ? session.optimisticPromptBoundary : nil
                let acknowledges = !earlier && (retainedBoundary?.accepts(record)
                    ?? ((session.promptBoundary ?? session.optimisticPromptBoundary)?.accepts(record) == true
                        || (!session.awaitingPromptAck && session.activeTurnID == record.turnID)))
                let confirmsPrompt = acknowledges && session.matchesPrompt(item)
                let inserted = acknowledges ? session.reconcilePrompt(item) : item
                insert(inserted, from: record)
                // The first transcript read can be historical even when this
                // command created that fresh transcript. Only explicitly older
                // pages are ineligible to complete the pending shell command.
                if !earlier { receiveCommandExecution(inserted, session: session) }
                if confirmsPrompt {
                    // Steering may add a user message to the current turn,
                    // without emitting another turn-start event.
                    session.awaitingPromptAck = false; session.promptBoundary = nil
                }
            }
        }
        if historical { session.mergeHistorical(historicalRecords) }
    }

    private func discover(_ session: ChatSession) {
        connectHelper(session)
    }
    func detachIdentity(_ session: ChatSession) {
        if let old = session.ownershipKey, owners[old] == session.id { owners.removeValue(forKey: old) }
    }

    func sendFromComposer(_ session: ChatSession) {
        if session.draftIsCommand, session.helper != nil, let side = ChatSideMode.parse(session.draft), session.editingQueuedID == nil {
            openSideConversation(side.mode, question: side.question, session: session); return
        }
        if session.editingQueuedID != nil { queue(session) }
        else if !session.draftIsCommand && session.queuedMessages.isEmpty && directSubmissionReady(session) { submit(session) }
        else if session.draftIsCommand && ((!session.busy && session.nativePrompt == nil && !session.nativeInputInFlight
                    && !session.waitingForAnswer && !session.loadingHistory && session.activityCheck == nil)
                    || session.draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/terminal") { submit(session) }
        else { queue(session) }
    }

    private func directSubmissionReady(_ session: ChatSession) -> Bool {
        session.supportsQueue && inputReady(session)
    }

    func inputReady(_ session: ChatSession, immediately: Bool = false) -> Bool {
        sessions[session.id] === session && enabled
            && !(helperInstalls[session.agentID]?.optional == true && disabledIntegrations.contains(session.agentID))
            && session.active && session.helper != nil
            && (immediately || !session.busy) && !session.awaitingPromptAck && session.sideConversation == nil
            && session.command == nil && !session.nativeInputInFlight && session.nativePrompt == nil
            && !session.waitingForAnswer && session.commandEditor == nil && !session.loadingHistory
            && session.activityCheck == nil && !session.inputBlocked && session.submissionID == nil
            && session.modelPicker == nil && !session.approvals.contains(where: \.pending)
    }

    func canReorderQueue(_ session: ChatSession) -> Bool {
        enabled && sessions[session.id] === session && session.active && session.helper != nil
            && session.queuedMessages.count > 1 && session.editingQueuedID == nil && session.queuedSubmissionID == nil
            && !session.queueBusy && session.queuedMessages.allSatisfy { $0.matches(session) && !$0.pending && $0.pause != .uncertain }
            // The agent's own queue reorders only its own entries: none move across rows still held here.
            && (session.queuedMessages.allSatisfy(\.held) || !session.queuedMessages.contains(where: \.held))
    }

    /// Drops move to the target row's position. A drag captures the complete
    /// order so a consumed/replaced entry cannot silently change its destination.
    @discardableResult
    func moveQueued(_ id: UUID, to target: UUID, in session: ChatSession, expectedOrder: [UUID]? = nil) -> Bool {
        guard canReorderQueue(session), id != target,
              expectedOrder == nil || expectedOrder == session.queuedMessages.map(\.id),
              let from = session.queuedMessages.firstIndex(where: { $0.id == id }),
              let to = session.queuedMessages.firstIndex(where: { $0.id == target }) else { return false }
        var reordered = session.queuedMessages
        reordered.insert(reordered.remove(at: from), at: to)
        if reordered.allSatisfy(\.held) {
            session.queuedMessages = reordered
            drainQueue(session)
            return true
        }
        reorderHelperQueue(reordered, session: session)
        return true
    }

    func moveQueued(_ id: UUID, by offset: Int, in session: ChatSession) {
        guard let index = session.queuedMessages.firstIndex(where: { $0.id == id }),
              [-1, 1].contains(offset), session.queuedMessages.indices.contains(index + offset) else { return }
        moveQueued(id, to: session.queuedMessages[index + offset].id, in: session)
    }

    func queue(_ session: ChatSession, drain: Bool = true) {
        let text = session.draft
        guard sessions[session.id] === session, session.supportsQueue, enabled,
              session.active, !session.inputBlocked,
              session.helper != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        session.submissionFailure = nil
        if session.editingQueuedID != nil, session.editingQueuedDraftID != session.drafts.current.id {
            session.submissionFailure = "Return to the queued message's draft or cancel its edit before sending."; return
        }
        if session.draftIsCommand, text.trimmingCharacters(in: .whitespaces).hasPrefix("!") {
            session.status = "Shell commands cannot be queued. Send them when the agent is idle."; return
        }
        guard !text.unicodeScalars.contains(where: { $0.value < 32 && $0 != "\n" && $0 != "\t" }),
              session.queuedMessages.count < 50 || session.editingQueuedID != nil, text.utf8.count <= 1_048_576 else {
            session.status = "Cannot queue this message; your draft is preserved."; return
        }
        if let id = session.editingQueuedID,
           let message = session.queuedMessages.first(where: { $0.id == id }), !message.held {
            if message.native != nil { updateHelperQueued(message, session: session, text: text, send: false) }
            return
        }
        let isCommand = session.draftIsCommand
        guard let delivery = session.drafts.prepareDelivery(consume: true) else { return }
        if let id = session.editingQueuedID, let index = session.queuedMessages.firstIndex(where: { $0.id == id }) {
            if let previous = session.queuedMessages[index].delivery { session.drafts.forgetDelivery(previous) }
            session.queuedMessages[index].text = text
            session.queuedMessages[index].delivery = delivery
            session.queuedMessages[index].isCommand = isCommand
            session.queuedMessages[index].process = session.process
            session.queuedMessages[index].binding = session.binding
            session.queuedMessages[index].host = session.host
            session.queuedMessages[index].conversation = session.sessionID
            session.queuedMessages[index].generation = session.queueGeneration
            session.queuedMessages[index].pause = nil
            session.editingQueuedID = nil; session.editingQueuedDraftID = nil
        } else {
            session.queuedMessages.append(ChatQueuedMessage(text: text, process: session.process, binding: session.binding, host: session.host, delivery: delivery, isCommand: isCommand, conversation: session.sessionID, generation: session.queueGeneration))
        }
        session.selectedQueuedID = nil
        if drain { drainQueue(session) }
    }

    func removeQueued(_ id: UUID, from session: ChatSession) {
        guard session.queuedSubmissionID != id, !session.queueBusy else { return }
        if let message = session.queuedMessages.first(where: { $0.id == id }), !message.held {
            if message.native != nil { mutateHelperQueue(message, session: session, operation: "remove") }
            return
        }
        if session.editingQueuedID == id { cancelQueuedEdit(session) }
        if let delivery = session.queuedMessages.first(where: { $0.id == id })?.delivery {
            session.drafts.forgetDelivery(delivery)
        }
        session.queuedMessages.removeAll { $0.id == id }
        if session.selectedQueuedID == id { session.selectedQueuedID = nil }
        session.queueWaiting = nil; session.queueRetryAfter = nil
        drainQueue(session)
    }

    func editQueued(_ id: UUID, in session: ChatSession) {
        guard session.draft.isEmpty, session.editingQueuedID == nil, session.queuedSubmissionID != id,
              let message = session.queuedMessages.first(where: { $0.id == id }),
              !session.queueBusy, !message.pending, message.editable else { return }
        session.drafts.restore(message.delivery?.draft ?? ChatDraft(text: message.text, multiline: message.text.contains("\n")))
        session.editingQueuedID = id; session.selectedQueuedID = nil
        session.editingQueuedDraftID = session.drafts.current.id
        session.focusRequest = UUID()
    }

    func cancelQueuedEdit(_ session: ChatSession) {
        guard session.editingQueuedID != nil else { return }
        if session.drafts.current.id == session.editingQueuedDraftID { session.clearDraft() }
        session.editingQueuedID = nil; session.editingQueuedDraftID = nil; session.selectedQueuedID = nil
        session.focusRequest = UUID()
    }

    func resumeQueue(_ session: ChatSession) {
        guard sessions[session.id] === session else { return }
        if let first = session.queuedMessages.first, !first.held {
            if first.native != nil { mutateHelperQueue(first, session: session, operation: "start") }
            return
        }
        for index in session.queuedMessages.indices where session.queuedMessages[index].pause == .stopped {
            session.queuedMessages[index].pause = nil
        }
        drainQueue(session)
    }

    func sendNow(_ session: ChatSession, queuedID: UUID? = nil) {
        if session.editingQueuedID != nil, queuedID == nil {
            if let message = session.queuedMessages.first(where: { $0.id == session.editingQueuedID }), !message.held {
                if message.native != nil { updateHelperQueued(message, session: session, text: session.draft, send: true) }
                return
            }
            let id = session.editingQueuedID
            queue(session, drain: false)
            guard session.editingQueuedID == nil, let id else { return }
            sendNow(session, queuedID: id)
        } else if let queuedID {
            guard let message = session.queuedMessages.first(where: { $0.id == queuedID }),
                  message.matches(session), message.pause == nil, !message.pending,
                  session.editingQueuedID != queuedID else { return }
            if message.native != nil { mutateHelperQueue(message, session: session, operation: "send"); return }
            submit(session, queued: message, immediately: true)
        } else { submit(session, queued: nil, immediately: true) }
    }

    func drainQueue(_ session: ChatSession) {
        guard session.helper != nil else { return }
        // Rows queued before initial binding adopt that verified owner once, while their destination matches.
        for index in session.queuedMessages.indices
        where session.queuedMessages[index].held && session.queuedMessages[index].binding == nil
            && session.queuedMessages[index].matches(session) {
            session.queuedMessages[index].binding = session.binding
        }
        // Pending messages stay here until checked submission. A changed destination needs review.
        for index in session.queuedMessages.indices
        where session.queuedMessages[index].held && session.queuedMessages[index].pause == nil && !session.queuedMessages[index].matches(session) {
            session.queuedMessages[index].pause = .destinationChanged
        }
        // Until the helper has bound the agent, held rows stay here and wait for it.
        session.queueWaiting = session.binding == nil && session.queuedMessages.contains(where: \.held)
            ? "Waiting for the terminal to be ready…" : nil
        if let row = session.queuedMessages.first, row.held, row.pause == nil, !row.pending, row.matches(session),
           session.showChat, session.editingQueuedID == nil, !session.queueBusy,
           session.binding != nil, inputReady(session) {
            submit(session, queued: row)
        }
    }

    func submit(_ session: ChatSession) { submit(session, queued: nil) }

    private func submit(_ session: ChatSession, queued: ChatQueuedMessage?, immediately: Bool = false) {
        guard session.helper != nil else {
            // No helper chat verified this terminal's agent: nothing is sent, and the user is told so.
            if queued == nil, !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                session.submissionFailure = "Cannot safely send to \(session.agentTitle). Open the terminal to continue; your draft is preserved."
            }
            return
        }
        submitHelper(session, queued: queued, immediately: immediately)
    }

    /// A chat that cannot be trusted with input: the draft stays (flushed), approvals return to the
    /// terminal, input is blocked until the chat opens again.
    func suspendDiscovery(_ session: ChatSession, status: String) {
        if !session.discoveryBlocked {
            session.discoveryBlocked = true
            cancelSubmission(session)
            session.relinquish()
            session.drafts.persist(flush: true)
        }
        session.status = status
    }

    private func cancelSubmission(_ session: ChatSession) {
        operations.cancel(for: session.id)
        session.sideConversation?.close(); session.sideConversation = nil
        session.interruptionID = nil
        session.submissionFailure = nil
        session.command?.cancel(); session.command = nil; session.nativePrompt = nil; session.commandEditor = nil
        session.failOptimisticPrompt(restoreDraft: session.queuedSubmissionID == nil)
        session.finishDirectDraft(success: false)
        if let id = session.queuedSubmissionID { session.pauseQueued(id, reason: .uncertain) }
        session.queuedSubmissionID = nil
        session.modelPicker?.abandon(); session.modelPicker = nil
        submissions.removeValue(forKey: session.id)?.cancel()
        session.submissionID = nil
        session.promptBoundary = nil; session.awaitingPromptAck = false; session.observedCommand = nil
    }

    func canInterrupt(_ session: ChatSession) -> Bool {
        enabled && session.helper != nil && session.active && session.showChat && session.busy && !session.inputBlocked
            && session.submissionID == nil && session.interruptionID == nil
            && !session.awaitingPromptAck && !session.loadingHistory && session.command == nil
            && session.nativePrompt == nil && !session.nativeInputInFlight
            && session.modelPicker == nil && !session.approvals.contains(where: \.pending)
    }

    @discardableResult
    func interrupt(_ session: ChatSession) -> Bool {
        guard session.helper != nil else { return false }
        return interruptHelper(session)
    }

    func canPickModel(_ session: ChatSession) -> Bool {
        session.helper != nil && session.active && !session.busy && !session.loadingHistory && !session.inputBlocked && session.activityCheck == nil
            && session.submissionID == nil && !session.approvals.contains(where: \.pending)
    }

    func openModelPicker(_ session: ChatSession, column: ChatModelPicker.Column, cycle: Bool = false) {
        guard session.helper != nil else { return }
        modelHelper(session, column: column, cycle: cycle)
    }

    func closeModelPicker(_ session: ChatSession) { session.modelPicker?.close() }
}
