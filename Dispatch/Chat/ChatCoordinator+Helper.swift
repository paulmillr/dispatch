import Foundation
import SwiftUI

/// User actions and UI state on the common chat interface.
extension ChatCoordinator {
    /// The agent in a tab's terminal changed (its owning helper resolved the tab).
    func helperChanged(_ tab: UUID) {
        connectHelper(session(for: tab), refresh: true)
    }

    /// Ends chats on a helper's terminal, or on every terminal when that helper is gone.
    /// The agent behind these chats is gone for the app. `disabled`: the user turned the
    /// integration off, so queued rows keep waiting for a destination the user picks again.
    func helperExited(_ endpoint: HelperWorkspace.Endpoint, terminal: UInt64? = nil, status: String? = nil, disabled: Bool = false) {
        installationFailures = installationFailures.filter {
            $0.key.endpoint != endpoint || (terminal != nil && $0.key.terminal != terminal)
        }
        for session in sessions.values
        where session.helper.map({ $0.endpoint == endpoint && (terminal == nil || $0.route.terminal == terminal) }) == true {
            rememberRemotePresentation(session)
            // An explicit exit can retire the subscription before its checked Return
            // reply arrives. Let that delivery verdict settle the draft and presentation.
            if disabled || !["/exit", "/quit"].contains(session.command?.text ?? "") {
                session.helperTask?.cancel()
            }
            session.active = false
            session.busy = false
            session.relinquish()
            session.status = status ?? "\(session.agentTitle) exited. This transcript is read-only."
            if disabled {
                session.helper?.close()
                session.helper = nil
                suspendDiscovery(session, status: session.status!)
                session.invalidateQueuedDestination()
            }
        }
    }

    func connectHelper(_ session: ChatSession, refresh: Bool = false) {
        guard let space = TerminalRuntime.shared.workspace?.spaces.first(where: { $0.tabs.contains { $0.id == session.id } }),
              let tab = space.tabs.first(where: { $0.id == session.id }) else {
            // No terminal: an archived conversation reads its transcript through the harness,
            // independent of the chat switch like the old transcript reader.
            guard session.helper == nil, let path = session.transcriptPath, let id = session.sessionID else { return }
            attach(HelperChat(archive: .init(key: session.agentID, path: path, session: id)), to: session)
            return
        }
        guard enabled else { return }
        // A live SSH origin stays remote when its helper or Chat permission is withdrawn.
        // Falling back to its local launcher would replace the retained conversation's status.
        if let connection = TerminalRuntime.shared.ssh.connectionForOrigin(tab.id),
           !TerminalRuntime.shared.ssh.helper4Connections(granting: .chat).contains(connection) { return }
        // An SSH tab with a remote helper chats with the agents on that server.
        let remote = TerminalRuntime.shared.ssh.helper4(for: tab.id)
        guard let terminal = remote?.terminal ?? tab.terminal else { return }
        // Else the helper that runs the tab's terminal (a remote backend's space, or this Mac).
        let endpoint: HelperWorkspace.Endpoint = (remote?.connection ?? space.remote).map { .remote($0) } ?? .local
        if let connection = endpoint.connection,
           !TerminalRuntime.shared.ssh.helper4Connections(granting: .chat).contains(connection) { return }
        session.host = endpoint.connection.flatMap { TerminalRuntime.shared.ssh.links[$0]?.greeting.host }
        loadLaunches()
        if let helper = session.helper, helper.route.terminal == terminal, helper.endpoint == endpoint {
            if refresh {
                Task { do { try await helper.open(refresh: true) } catch { helper.failed?(error) } }
            }
            return
        }
        attach(HelperChat(terminal: terminal, endpoint: endpoint), to: session)
    }

    private func attach(_ helper: HelperChat, to session: ChatSession) {
        session.helper?.close()
        session.helperTask?.cancel()
        session.helper = helper
        session.loadingHistory = session.turns.isEmpty
        helper.receive = { [weak self, weak session, weak helper] event in
            guard let self, let session, let helper, session.helper === helper,
                self.sessions[session.id] === session else { return }
            self.receiveHelper(event, session: session)
        }
        helper.failed = { [weak self, weak session, weak helper] error in
            guard let self, let session, let helper, session.helper === helper else { return }
            session.loadingHistory = false
            // The conversation ended while its terminal lives (core f2befec1): as an agent exit.
            if (error as? HelperFailure)?.code == "agent_exited" {
                return self.helperExited(helper.endpoint, terminal: helper.route.terminal)
            }
            session.active = false
            // No harness bound is an ordinary terminal. Anything else (connection lost, a refused open) blocks
            // the chat: draft kept and flushed, approvals released, no input.
            if (error as? HelperFailure)?.code == "unavailable" { session.status = error.localizedDescription }
            else { self.suspendDiscovery(session, status: error.localizedDescription) }
        }
        Task { do { try await helper.open() } catch { helper.failed?(error) } }
    }

    /// Internal (not private): unit tests feed helper events through the same path.
    func receiveHelper(_ event: HelperChat.Event, session: ChatSession) {
        switch event {
        case .history(let page):
            session.discoveryBlocked = false
            // A provisional binding ("") names no conversation yet; its first conversation is not a change.
            let conversation = page.session.isEmpty ? nil : page.session
            if let previous = session.sessionID, previous != conversation {
                rememberRemotePresentation(session)
                session.helperTask?.cancel()
                let result = session.command?.command?.replacementResult
                let sameProcess = session.agentID == page.key && session.binding?.pid != nil
                    && session.binding?.pid == page.binding.pid && session.binding?.start == page.binding.start
                session.resetConversation(keepingConfiguration: sameProcess)
                session.commandResult = result
            }
            session.sessionID = conversation
            session.agentID = page.key
            session.helperTitle = page.label
            session.helperCommands = page.commands
            session.helperNativeQueue = page.native_queue
            session.transcriptPath = page.binding.transcript
            // AgentProcess names a process on this Mac; a remote agent's identity stays in its binding.
            let agent = page.binding.pid != nil && (session.binding?.pid, session.binding?.start) != (page.binding.pid, page.binding.start)
            session.binding = page.binding
            if agent, let helper = session.helper { installHelperIntegration(page.key, endpoint: helper.endpoint, terminal: helper.route.terminal) }
            restoreRemotePresentation(session)
            session.process = session.helper?.endpoint == .local ? page.binding.process : nil
            // A verified process before its first conversation has no history to wait for.
            session.loadingHistory = page.history_pending && conversation != nil
            session.transcriptAvailable = !page.history_pending && page.history_error == nil
            session.helperEarlier = page.earlier
            session.hasEarlier = page.earlier != nil
            session.status = page.history_error?.localizedDescription ?? page.state_error?.localizedDescription
            if let error = page.state_error, error.code == "setup" {
                session.active = false
                var status = error.localizedDescription
                if let endpoint = session.helper?.endpoint, !permits(page.key, on: endpoint) {
                    status = "\(session.agentTitle) Chat hooks are not enabled for this SSH configuration."
                }
                suspendDiscovery(session, status: status)
            }
            receiveHelper(page.records, session: session, historical: true)
            if let state = page.state { receiveHelper(.state(state), session: session) }
        case .records(let records):
            receiveHelper(records, session: session, historical: false)
            // Completion can follow idle; a start acknowledgement still has the preceding idle state.
            if let turn = session.activeTurnID, records.contains(where: { $0.kind == "turn_ended" && $0.turn == turn }) {
                drainQueue(session)
            }
        case .replacement(let page):
            session.clearBranchHistory()
            receiveHelper(.page(page), session: session)
        case .page(let page):
            session.loadingHistory = page.snapshot?.awaiting_creation == true && session.turns.isEmpty
            session.transcriptAvailable = !session.loadingHistory
            // A page's title is the transcript's; the live name stays session.title (legacy split).
            if let title = page.state?.title { session.transcriptTitle = title }
            session.status = session.loadingHistory ? "Waiting for transcript metadata." : nil
            // An opened transcript's model and effort (earlier pages come through pageHelper, never here).
            if let model = page.state?.model {
                session.applyConfiguration(model: model, effort: page.state?.effort)
            }
            receiveHelper(page.records, session: session, historical: true)
            session.helperEarlier = page.earlier
            session.hasEarlier = page.earlier != nil
        case .archive(let page):
            if session.loadingHistory || page.snapshot?.initial != false {
                if !session.turns.isEmpty { session.resetConversation() }
                receiveHelper(.page(page), session: session)
            } else {
                receiveHelper(page.records, session: session, historical: false)
                if let title = page.state?.title { session.transcriptTitle = title }
                if let model = page.state?.model {
                    session.applyConfiguration(model: model, effort: page.state?.effort)
                }
            }
        case .queue(let items, let error):
            receiveHelperQueue(items, session: session)
            session.queueError = error?.message
        case .state(let state):
            guard !(helperInstalls[session.agentID]?.optional == true && disabledIntegrations.contains(session.agentID)) else {
                session.active = false; session.busy = false
                return
            }
            session.active = true
            if let version = state.version { session.version = version }
            if session.sessionID != nil, !session.manualViewChoice, !session.showChat {
                setChatVisible(true, session: session)
            }
            session.busy = state.busy && !(session.agentID == "claude" && session.modelPicker != nil && state.activity == "waiting")
            session.nativeActivity = state.activity
            if !state.busy, state.dialog == nil { session.retiredInteraction = false }
            session.activityCheck = nil
            if let model = state.model {
                session.applyConfiguration(model: model, effort: state.effort)
            }
            // Core's State.usage is the documented ChatUsage JSON (api.rs State.usage).
            if let data = state.usage?.data(using: .utf8),
               let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                session.usage = ChatUsage(payload)
            }
            if let attention = state.attention, session.modelPicker == nil {
                requireTerminalAttention(session, status: attention)
            }
            // State.goal: the harness's goal JSON (codex native.rs goal); nil means no goal.
            let goal = state.goal.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }.flatMap(ChatGoal.init)
            if goal != session.goal {
                session.goal = goal; session.goalUpdatedAt = .now; session.goalRevision += 1
                if session.commandResult?.title == "Goal" { session.commandResult?.text = goal?.summary ?? "Goal cleared." }
            }
            if let title = state.title { session.title = title }
            session.threadName = state.title
            session.serviceTier = state.service_tier
            if session.collaborationMode != state.mode {
                session.collaborationMode = state.mode
                session.settingsRevision += 1
            }
            let compacting = "\(session.agentTitle) is compacting the conversation…"
            if state.compacting { session.status = compacting } else if session.status == compacting { session.status = nil }
            drainQueue(session)
        case .interaction(let interaction):
            receiveHelper(interaction, session: session)
        case .exit:
            if let helper = session.helper { helperExited(helper.endpoint, terminal: helper.route.terminal) }
        }
    }

    /// Records come in transcript order: an earlier page goes before everything shown, the rest after.
    /// Their positions order records with equal times, as file offsets did (legacy transcript reader).
    private func receiveHelper(_ records: [HelperChat.Record], session: ChatSession, historical: Bool, earlier: Bool = false) {
        let date = Date(), count = UInt64(records.count), span = session.helperPositions ?? (1 << 62)...(1 << 62)
        let start = earlier ? span.lowerBound - count : span.upperBound + 1
        session.helperPositions = min(start, span.lowerBound)...max(start + count, span.upperBound)
        let decoded = records.enumerated().compactMap { index, record in
            record.display(at: historical ? Date(timeIntervalSince1970: 0) : date).map { var shown = $0; shown.fileOffset = start + UInt64(index); return shown }
        }
        // What a native command printed: the pending command's result (more of it extends that result),
        // never a turn, whether it arrives live or in a page.
        func output(_ text: String) {
            if let pending = session.observedCommand {
                session.observedCommand = nil
                session.awaitingPromptAck = false
                session.promptBoundary = nil
                session.commandResult = .init(title: pending.title, text: text)
            } else if let result = session.commandResult, !result.text.hasSuffix(text) {
                session.commandResult?.text = result.text + "\n" + text
            }
        }
        var rows: [ChatRecord] = []
        for record in decoded {
            if case .commandOutput(let text) = record.action { if !earlier { output(text) } } else { rows.append(record) }
        }
        // A first transcript snapshot can acknowledge the prompt that created it.
        // Only earlier pages are excluded from live delivery state changes.
        apply(rows, to: session, earlier: earlier, historical: historical)
        if historical {
            // An earlier page counts as a history change only when it changed the rows (pageHelper decides).
            if !earlier {
                session.historyRevision += 1
                session.revision += 1
            }
        }
    }

    /// An earlier page, applied when scrolling settles: an open standalone tool that older records turn
    /// into a group keeps the group open, and the visible rows keep their place (or the bottom stays put
    /// when it was followed). Loading ends when the page is applied, not when it arrives.
    func pageHelper(_ session: ChatSession, preservingBottom: Bool = false) -> Bool {
        guard let helper = session.helper, let earlier = session.helperEarlier,
            !session.loadingEarlier, !session.scrollPosition.isRestoring else { return false }
        session.loadingEarlier = true
        session.earlierError = nil
        let started = ProcessInfo.processInfo.systemUptime
        operations.run(for: session.id) { [weak self, weak session] in
            guard let self, let session else { return }
            let page: HelperChat.Page
            do { page = try await helper.page(earlier: earlier) } catch {
                session.loadingEarlier = false
                session.earlierError = error.localizedDescription
                session.scrollPosition.historyLoadFinished(madeProgress: false)
                return
            }
            session.scrollPosition.observedHistoryRead(seconds: ProcessInfo.processInfo.systemUptime - started)
            session.scrollPosition.performAfterScrolling { [weak self, weak session] in
                guard let self, let session else { return }
                guard session.helper === helper else {
                    session.loadingEarlier = false
                    session.scrollPosition.geometryChanged()
                    return
                }
                defer {
                    session.loadingEarlier = false
                    session.scrollPosition.historyLoadFinished(madeProgress: !page.records.isEmpty)
                }
                let hadEarlier = session.hasEarlier, oldRows = session.visibleTranscriptRows.map(\.id)
                let expandedRows = Set(oldRows).intersection(session.expanded)
                // Decided when applying: a wheel event meanwhile has already cancelled following the bottom.
                let keepBottom = preservingBottom && session.scrollPosition.followsBottom?() == true
                withTransaction(Transaction(animation: nil)) {
                    self.receiveHelper(page.records, session: session, historical: true, earlier: true)
                    session.helperEarlier = page.earlier
                    session.hasEarlier = page.earlier != nil
                    for row in session.transcriptRows {
                        if let group = row.group, group.children.contains(where: { expandedRows.contains($0.id) }) {
                            session.expandedToolGroups.insert(group.id)
                        }
                    }
                    if keepBottom { session.scrollPosition.cancelPreservation() }
                    else { session.scrollPosition.preserveForPrepend(retaining: Set(session.visibleTranscriptRows.map(\.id))) }
                    if oldRows != session.visibleTranscriptRows.map(\.id) || hadEarlier != session.hasEarlier {
                        session.historyRevision += 1
                    } else { session.scrollPosition.cancelPreservation() }
                }
                session.scrollPosition.restoreAfterPrepend()
            }
        }
        return true
    }

    func submitHelper(_ session: ChatSession, queued: ChatQueuedMessage?, immediately: Bool) {
        let text = queued?.text ?? session.draft
        let command = queued?.isCommand ?? session.draftIsCommand
        // /terminal only switches to the terminal: no agent is addressed.
        if command, text.trimmingCharacters(in: .whitespacesAndNewlines) == "/terminal" {
            chooseChat(false, session: session)
            return
        }
        if helperInstalls[session.agentID]?.optional == true, disabledIntegrations.contains(session.agentID) {
            session.submissionFailure = "\(session.agentTitle) integration is disabled. Continue in Terminal; your draft is preserved."
            return
        }
        if command, text.trimmingCharacters(in: .whitespacesAndNewlines) == "/copy" {
            guard let item = session.turns.reversed().first(where: {
                $0.ended != nil && $0.items.contains(where: { $0.kind == .assistant })
            })?.items.last(where: { $0.kind == .assistant }) else {
                session.commandResult = .init(title: "Copy", text: "No completed response to copy yet.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
            if let queued {
                if let delivery = queued.delivery { session.drafts.finish(delivery, success: true) }
                session.queuedMessages.removeAll { $0.id == queued.id }
                session.queuedSubmissionID = nil
            } else { session.clearDraft() }
            session.commandResult = .init(title: "Copy", text: "Response copied.")
            return
        }
        if command, ChatCommand(text) == .model {
            openModelPicker(session, column: .model)
            if session.modelPicker != nil {
                if let queued {
                    if let delivery = queued.delivery { session.drafts.finish(delivery, success: true) }
                    session.queuedMessages.removeAll { $0.id == queued.id }
                    session.queuedSubmissionID = nil
                } else { session.clearDraft() }
            }
            return
        }
        // A failed "Send now" says why; the message keeps its place and sends normally when the turn ends.
        let sendingNow = queued != nil && immediately
        func notSentNow(_ reason: String) -> String {
            "Could not send now: \(reason)\(reason.hasSuffix(".") ? "" : ".") The message stays queued."
        }
        guard inputReady(session, immediately: immediately || command), let helper = session.helper else {
            print("Helper input waiting: active=\(session.active), history=\(session.loadingHistory), busy=\(session.busy), ack=\(session.awaitingPromptAck), blocked=\(session.inputBlocked), command=\(session.command != nil), interaction=\(session.waitingForAnswer)")
            if queued != nil { session.queueWaiting = "Waiting for the terminal to be ready…" }
            if sendingNow { session.submissionFailure = notSentNow("\(session.agentTitle) cannot safely take input right now.") }
            return
        }
        session.queueWaiting = nil
        // No agent bound by the helper yet: nothing can be addressed; the draft stays.
        guard session.binding != nil else {
            session.submissionFailure = sendingNow ? notSentNow("\(session.agentTitle) cannot safely take input right now.")
                : "Cannot safely send to \(session.agentTitle). Open the terminal to continue; your draft is preserved."
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID()
        let delivery = queued?.delivery ?? session.drafts.prepareDelivery(consume: !command)
        guard delivery != nil || queued != nil else { return }
        session.submissionID = id
        session.queuedSubmissionID = queued?.id
        session.submissionFailure = nil
        // A picker answers in Terminal, never with a turn.
        let opensTerminal = command && ChatCommand(text)?.opensTerminal == true
        session.awaitingPromptAck = !command || ChatCommand(text)?.startsTurn == true
            || (["claude", "pi"].contains(session.agentID) && !opensTerminal
                && !["/exit", "/quit"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        session.promptBoundary = session.awaitingPromptAck ? .firstRemoteTurn : nil
        if command {
            session.commandResult = nil
            session.observedCommand = (title: text.trimmingCharacters(in: .whitespacesAndNewlines), output: nil)
        } else {
            session.showOptimisticPrompt(text)
        }
        var input = HelperChat.Input(helper.route)
        input.text = text
        let wasBusy = session.busy
        let turn = session.activeTurnID
        // A prompt shows the agent working at once, as the old app did; the harness's State confirms it.
        if !command { input.mode = immediately && wasBusy ? "steer" : "prompt"; session.busy = true }
        // A command is running until the harness replies.
        if command { session.command = ChatCommandRequest(text: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        session.helperTask = operations.run(for: session.id) { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                // Composer commands get the harness's native result (chat.command); prompts are sent.
                let result: ChatCommandResult?
                if command {
                    let outcome: HelperChat.Outcome = try await helper.call("chat.command", input: input)
                    try outcome.confirmed()
                    result = outcome.result(agent: session.agentTitle)
                } else {
                    let sent: HelperChat.Sent = try await helper.call("chat.send", input: input)
                    try sent.confirmed()
                    result = nil
                }
                guard session.helper === helper, session.submissionID == id else { return }
                if let delivery { session.drafts.finish(delivery, success: true) }
                if let queued { session.queuedMessages.removeAll { $0.id == queued.id } }
                struct Observed: Decodable, Sendable {
                    let binding: HelperTopology.Binding
                    let state: HelperChat.State
                }
                if result != nil,
                   let observed: Observed = try? await helper.call("chat.state", input: .init(helper.route)) {
                    guard session.helper === helper, session.submissionID == id else { return }
                    if session.active, observed.binding.session == session.sessionID {
                        self.receiveHelper(.state(observed.state), session: session)
                    }
                }
                guard session.helper === helper, session.submissionID == id else { return }
                // A written command may still be waiting in the native composer. Preserve the
                // original command contract: a new turn or question acknowledges its start.
                if command, session.agentID == "codex", ChatCommand(text)?.startsTurn == true, result == nil {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                    for _ in 0... {
                        try Task.checkCancellation()
                        guard session.helper === helper, session.submissionID == id else { return }
                        guard session.active else { throw HerdrFailure("The agent conversation ended.") }
                        if session.activeTurnID != turn || !session.questions.isEmpty || session.approvals.contains(where: \.pending) { break }
                        guard ContinuousClock.now < deadline else {
                            throw HerdrFailure("Codex has not confirmed this command. Continue in Terminal to check its result.")
                        }
                        try await Task.sleep(for: .milliseconds(80))
                    }
                }
                // Replacement commands finish only when history follows their new conversation.
                if command, ChatCommand(text)?.replacesConversation == true {
                    try await helper.open(refresh: true)
                    let deadline = ContinuousClock.now.advanced(by: .seconds(6))
                    for _ in 0... {
                        try Task.checkCancellation()
                        guard session.helper === helper, session.submissionID == id else { return }
                        if session.sessionID != input.session { break }
                        guard ContinuousClock.now < deadline else {
                            throw HerdrFailure("The command completed but Chat has not followed its new conversation. Continue in Terminal.")
                        }
                        try await Task.sleep(for: .milliseconds(80))
                    }
                }
                // The harness has run it: a result now, or printed output arriving as records (observedCommand).
                session.command = nil
                if let result {
                    session.commandResult = result
                    session.observedCommand = nil
                    session.awaitingPromptAck = false
                    session.promptBoundary = nil
                }
                // A native turn or output may have acknowledged the command before its write reply.
                session.optimisticPromptDelivered = true
                session.lastInputAt = .now
                if command, ["/exit", "/quit"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    self.setChatVisible(false, session: session)
                }
                // The picker is open: Terminal takes the keyboard, as the user's own switch would.
                // Nothing prints back to Chat; a picked conversation arrives as a new history.
                if opensTerminal {
                    session.observedCommand = nil
                    self.chooseChat(false, session: session)
                }
            } catch {
                guard session.helper === helper, session.submissionID == id else { return }
                let attention = command && (error as? HelperFailure)?.code == "attention"
                if let delivery { session.drafts.finish(delivery, success: attention) }
                // The harness refused the command's arguments before running anything (old app's text).
                let arguments = (error as? HelperFailure)?.code == "command_arguments"
                let uncertain = ChatInputNotSent.deliveryUncertain(error, started: true)
                // Definitely not sent: a "Send now" stays queued, unpaused, for the end of the turn.
                let keep = sendingNow && !attention && !arguments && !uncertain
                if let queued, !attention, !keep {
                    let refusal = error.localizedDescription.isEmpty
                        ? "Queue paused: \(session.agentTitle) did not take this message. Edit or discard it." : error.localizedDescription
                    session.pauseQueued(queued.id, reason: arguments ? .needsEdit("Queue paused: edit this command's arguments.")
                        : uncertain ? .uncertain : .needsEdit(refusal))
                }
                if !attention { session.failOptimisticPrompt(restoreDraft: false) }
                session.awaitingPromptAck = false
                session.promptBoundary = nil
                session.observedCommand = nil
                if !command { session.busy = wasBusy }
                session.command = nil
                if attention {
                    if let queued { session.queuedMessages.removeAll { $0.id == queued.id } }
                    session.terminalAttention = error.localizedDescription
                } else if arguments {
                    session.commandResult = .init(title: "Command arguments", text: "This command does not accept those arguments. Use its listed form.")
                } else { session.submissionFailure = keep ? notSentNow(error.localizedDescription) : error.localizedDescription }
            }
            guard session.helper === helper, session.submissionID == id else { return }
            session.submissionID = nil
            session.queuedSubmissionID = nil
            session.helperTask = nil
            session.focusRequest = UUID()
            self.drainQueue(session)
        }
    }

    func interruptHelper(_ session: ChatSession) -> Bool {
        guard let helper = session.helper, canInterrupt(session) else { return false }
        let id = UUID()
        session.interruptionID = id
        session.stopQueue()
        operations.run(for: session.id) { [weak session] in
            guard let session else { return }
            defer { if session.interruptionID == id { session.interruptionID = nil } }
            do {
                let sent: HelperChat.Sent = try await helper.call("chat.stop", input: .init(helper.route))
                try sent.confirmed()
            } catch { session.submissionFailure = error.localizedDescription }
        }
        return true
    }

    func modelHelper(_ session: ChatSession, column: ChatModelPicker.Column, cycle: Bool) {
        guard sessions[session.id] === session, let helper = session.helper, canPickModel(session) else { return }
        if let picker = session.modelPicker {
            if cycle { picker.cycleEffort() } else { picker.showColumn(column) }
            return
        }
        session.modelChoices.prepare(for: session)
        let picker = ChatModelPicker(model: session.model, effort: session.effort, column: column, cache: session.modelChoices, helper: helper,
            confirmed: { [weak session] model, effort in
                guard let session, session.helper === helper else { return }
                session.confirmConfiguration(model: model, effort: effort)
            }, finished: { [weak session] interrupted in
                guard let session, session.helper === helper else { return }
                session.modelPicker = nil
                if interrupted { session.submissionFailure = "Check Terminal before changing the model again." }
            })
        session.modelPicker = picker
        picker.start(cycle: cycle)
    }

    private func receiveHelper(_ interaction: HelperChat.Interaction, session: ChatSession) {
        guard let helper = session.helper else { return }
        restoreRemotePresentation(session)
        if session.retiredInteraction, interaction.id.hasPrefix("prompt:") {
            if interaction.questions.isEmpty { session.retiredInteraction = false }
            else {
                session.terminalAttention = "The previous connection's request must be handled in Terminal."
                return
            }
        }
        if interaction.questions.isEmpty {
            session.modelPicker?.clearAsk(interaction.id)
            session.questions.removeAll { $0.id == interaction.id }
            // Decided cards stay as receipts; only an undecided one expires.
            session.approvals.filter { $0.interaction == interaction.id && $0.decision == nil }.forEach { $0.retire() }
            return
        }
        // A native question confirms delivery even when the command opens no turn.
        session.awaitingPromptAck = false
        session.promptBoundary = nil
        if session.modelPicker?.ask(interaction) == true { return }
        guard !session.approvals.contains(where: { $0.interaction == interaction.id && $0.pending }),
              !session.questions.contains(where: { $0.id == interaction.id }) else { return }
        // Tool questions stay with their inline card; standalone multi-question forms keep their ordered answers.
        let choices = interaction.questions.allSatisfy { $0.options.count >= 2 && !$0.secret }
        if let permission = interaction.permission {
            let key = interaction.key ?? interaction.id
            session.approvals.append(PendingApproval(key: key, interaction: interaction.id, operation: permission.operation,
                                                     item: interaction.tool(in: session.turns), turnID: interaction.turn, toolItemID: interaction.record) { [weak self, weak session] in
                guard let self, let session else { return }
                self.completeHelper($0, interaction: interaction, helper: helper, session: session)
            })
        } else if interaction.blocking, !interaction.approval, choices,
                  interaction.questions.count == 1 || interaction.record != nil {
            let questions = ClaudeQuestions(interaction.questions.map { question in
                ClaudeQuestions.Question(text: question.text, header: question.header,
                                         options: question.options.map { .init(label: $0.label, description: $0.detail ?? "", preview: nil) },
                                         multiple: question.multiple)
            })
            session.approvals.append(PendingApproval(key: interaction.id, interaction: interaction.id, operation: interaction.questions.map(\.text).joined(separator: "\n"),
                                                     turnID: interaction.turn, toolItemID: interaction.record, questions: questions) { [weak self, weak session] in
                guard let self, let session else { return }
                self.completeHelper($0, interaction: interaction, helper: helper, session: session)
            })
        } else if let id = session.sessionID, let question = ChatSideQuestion(interaction: interaction, session: id) {
            session.questions.append(question)
        }
    }

    /// Approval: option 0 allows, 1 denies. Questions: the draft's choices or typed text; skip sends null answers.
    /// Terminal or expiry dismisses, leaving the native prompt to the terminal.
    private func completeHelper(_ approval: PendingApproval, interaction: HelperChat.Interaction,
                                helper: HelperChat, session: ChatSession) {
        guard session.helper === helper else { return }
        if approval.decision == .terminal, interaction.id.hasPrefix("prompt:") {
            session.retiredInteraction = true
            session.terminalAttention = "Continue with this request in Terminal."
            return
        }
        var input = HelperChat.Input(helper.route)
        input.interaction = interaction.id
        var method = "interactions.answer"
        switch (approval.decision, approval.questionDraft) {
        case (.allow, _?):
            // The submitted answers (the form's or a caller's), never the form's editing state.
            input.answers = interaction.answers(approval.answers ?? [:])
        case (.deny, _?):
            input.answers = Dictionary(uniqueKeysWithValues: interaction.questions.map { ($0.id, .skip) })
        case (.allow, nil), (.deny, nil):
            guard let question = interaction.questions.first else { return }
            input.answers = [question.id: .options([approval.decision == .allow ? 0 : 1])]
        default:
            method = "interactions.dismiss"
        }
        let installation = method == "interactions.dismiss" ? integrationChanges : nil
        let id = UUID()
        session.nativeInputs.insert(id)
        operations.run(for: session.id) { [weak session] in
            guard let session else { return }
            defer { session.nativeInputs.remove(id) }
            do {
                await installation?.value
                try Task.checkCancellation()
                guard session.helper === helper else { return }
                let sent: HelperChat.Sent = try await helper.call(method, input: input)
                try sent.confirmed()
            } catch {
                guard session.helper === helper else { return }
                session.submissionFailure = error.localizedDescription
            }
        }
    }

    func answerHelper(_ question: ChatSideQuestion, skip: Bool, session: ChatSession) {
        guard enabled, let helper = session.helper, session.active, session.showChat,
              session.sessionID == question.threadID, session.questions.contains(where: { $0 === question }),
              !question.submitted, skip || question.complete else { return }
        var input = HelperChat.Input(helper.route)
        input.interaction = question.id
        input.answers = skip ? Dictionary(uniqueKeysWithValues: question.questions.map { ($0.id, .skip) }) : question.answers
        question.submitted = true
        let id = UUID()
        session.nativeInputs.insert(id)
        operations.run(for: session.id) { [weak session] in
            guard let session else { return }
            defer { session.nativeInputs.remove(id) }
            do {
                try Task.checkCancellation()
                guard session.helper === helper else { return }
                let sent: HelperChat.Sent = try await helper.call("interactions.answer", input: input)
                try sent.confirmed()
                guard session.helper === helper else { return }
                question.clearAnswers()
            } catch {
                guard session.helper === helper else { return }
                question.submitted = false
                question.submissionUncertain = ChatInputNotSent.deliveryUncertain(error, started: true)
                question.submissionError = error.localizedDescription
                session.submissionFailure = error.localizedDescription
            }
        }
    }

    /// Integration on/off is harness work in the helper (installation.install). Turning it off first returns
    /// pending approvals of that agent to its terminal. `key` is the helper's opaque launch key.
    func setHelperIntegration(_ key: String, enabled: Bool) {
        let changed = disabledIntegrations.contains(key) == enabled
        if enabled { disabledIntegrations.remove(key) } else { disabledIntegrations.insert(key) }
        // Like the legacy hooks, the integration follows to connected SSH hosts that granted hooks.
        let endpoints = [HelperWorkspace.Endpoint.local] + TerminalRuntime.shared.ssh.helper4Connections(granting: .hooks).map { .remote($0) }
        if changed, let agent = SSHHookAgent(rawValue: key) {
            let ssh = TerminalRuntime.shared.ssh
            for endpoint in endpoints {
                if let connection = endpoint.connection, let scope = ssh.links[connection]?.launch.integrationScope {
                    ssh.permissions.saveHooks(enabled, for: scope, agent: agent)
                }
            }
        }
        integrationWork { chat in
            for endpoint in endpoints {
                if enabled, !chat.permits(key, on: endpoint) { continue }
                do {
                    let install = try await HelperChat.setup(endpoint, key: key, enabled: enabled, terminal: nil)
                    if endpoint == .local {
                        guard let install else {
                            throw HelperFailure(code: "unsupported", message: "This agent is not available from the helper.")
                        }
                        chat.helperInstalls[key] = install
                    }
                    chat.installed(key, endpoint: endpoint, error: nil)
                } catch { chat.installed(key, endpoint: endpoint, error: error) }
            }
        }
        if !enabled {
            for session in sessions.values where session.helper != nil && session.agentID == key {
                if helperInstalls[key]?.optional == true {
                    end(session, preservingPresentation: false)
                    suspendDiscovery(session, status: "\(session.agentTitle) integration is disabled. Continue in Terminal.")
                } else { session.relinquish() }
            }
        } else {
            for session in sessions.values where session.agentID == key {
                if let helper = session.helper {
                    installHelperIntegration(key, endpoint: helper.endpoint, terminal: helper.route.terminal)
                }
            }
        }
    }

    private func installed(_ key: String, endpoint: HelperWorkspace.Endpoint, terminal: UInt64? = nil, error: Error?) {
        let current = endpoint.connection.map { TerminalRuntime.shared.ssh.helper4Connections(granting: .hooks).contains($0) } ?? true
        installationFailures[.init(key: key, endpoint: endpoint, terminal: terminal)] = current ? error?.localizedDescription : nil
    }

    private func permits(_ key: String, on endpoint: HelperWorkspace.Endpoint) -> Bool {
        let ssh = TerminalRuntime.shared.ssh
        guard let connection = endpoint.connection, let scope = ssh.links[connection]?.launch.integrationScope,
              let agent = SSHHookAgent(rawValue: key) else { return true }
        return ssh.permissions.hooks(scope, agent: agent) != false
    }

    /// SSH agents may read their own config root rather than the remote account's
    /// (c1654cc SSHCoordinator.configureAgentHooks). Local setup stays account-wide.
    private func installHelperIntegration(_ key: String, endpoint: HelperWorkspace.Endpoint, terminal: UInt64) {
        integrationWork { chat in
            guard let connection = endpoint.connection, chat.enabled, !chat.disabledIntegrations.contains(key),
                  chat.helperInstalls[key].map({ $0.optional != true || $0.status != "off" }) == true,
                  TerminalRuntime.shared.ssh.helper4Connections(granting: .hooks).contains(connection) else { return }
            guard chat.permits(key, on: endpoint) else { return }
            do {
                _ = try await HelperChat.setup(endpoint, key: key, enabled: true, terminal: terminal)
                chat.installed(key, endpoint: endpoint, terminal: terminal, error: nil)
                for session in chat.sessions.values where session.agentID == key {
                    if let helper = session.helper, helper.endpoint == endpoint, helper.route.terminal == terminal {
                        try await helper.open(refresh: true)
                    }
                }
            } catch { chat.installed(key, endpoint: endpoint, terminal: terminal, error: error) }
        }
    }

    /// A newly connected SSH host gets the integrations installed on this Mac.
    func installHelperIntegrations(on connection: SSHConnectionID) {
        integrationWork { chat in
            guard chat.enabled, TerminalRuntime.shared.ssh.helper4Connections(granting: .hooks).contains(connection) else { return }
            for key in (chat.helperLaunches ?? []).map(\.key)
            where !chat.disabledIntegrations.contains(key) && chat.helperInstalls[key].map({ $0.optional != true || $0.status != "off" }) == true {
                guard chat.permits(key, on: .remote(connection)) else { continue }
                do {
                    _ = try await HelperChat.setup(.remote(connection), key: key, enabled: true, terminal: nil)
                    chat.installed(key, endpoint: .remote(connection), error: nil)
                } catch { chat.installed(key, endpoint: .remote(connection), error: error) }
            }
            // A turned-off integration stays off on this host too (its helper starts with hooks enabled).
            for key in chat.disabledIntegrations { _ = try? await HelperChat.setup(.remote(connection), key: key, enabled: false, terminal: nil) }
        }
    }

    /// Settings defaults: every required integration on, every optional one off.
    func restoreHelperIntegrations() {
        for launch in helperLaunches ?? [] {
            let optional = helperInstalls[launch.key]?.optional == true
            if !optional || helperInstalls[launch.key]?.status != "off" { setHelperIntegration(launch.key, enabled: !optional) }
        }
    }

    /// Inactive composer hint, named from the helper's launches rather than a fixed agent list.
    func placeholder(_ session: ChatSession) -> String {
        if session.active { return "Reply…" }
        return "Start \(agents) in this terminal…"
    }

    /// Loads the helper's launch labels once; failures leave the generic wording.
    func loadLaunches(file: StaticString = #fileID, line: UInt = #line) {
        guard helperLaunches == nil else { return }
        NSLog("[HelperOrder] launches schedule caller=%@:%lu", String(describing: file), line)
        helperLaunches = []
        // The first audit is installation work too: a toggle made meanwhile runs after it, never under it.
        integrationWork { chat in
            NSLog("[HelperOrder] launches submit caller=%@:%lu", String(describing: file), line)
            let launches = (try? await HelperClient(HelperApp.shared.connection()).launches()) ?? []
            chat.helperLaunches = launches
            for launch in launches {
                // A new helper starts with every integration enabled: repeat the user's turned-off ones.
                let off = chat.disabledIntegrations.contains(launch.key) || !chat.enabled
                guard var install = try? await HelperChat.setup(.local, key: launch.key, enabled: nil, terminal: nil) else { continue }
                if off, install.status != "off", let changed = try? await HelperChat.setup(.local, key: launch.key, enabled: false, terminal: nil) {
                    install = changed
                }
                chat.helperInstalls[launch.key] = install
            }
        }
    }

    /// Installation work shares profiles across coordinators and runs one at a time in the order
    /// asked, so an older reply never lands over a newer choice; tests await `integrationChanges` to settle it.
    private func integrationWork(_ work: @escaping @MainActor (ChatCoordinator) async -> Void) {
        let previous = Self.integrationTail
        Self.integrationTail = Task { [weak self] in
            await previous?.value
            if let self { await work(self) }
        }
    }

    /// "A, B or C" from the helper's launches; "an agent" until they load.
    var agents: String {
        let names = (helperLaunches ?? []).map(\.label)
        return names.count > 1 ? names.dropLast().joined(separator: ", ") + " or " + names.last! : names.first ?? "an agent"
    }

    // Native queue: same states as the old Codex queue, addressed by the helper's opaque id and revision.

    func receiveHelperQueue(_ items: [HelperChat.Queued], session: ChatSession) {
        session.queueError = nil
        if session.queueBusy { session.helperQueueSnapshot = items; return }
        let previous = session.queuedMessages
        var rows: [ChatQueuedMessage] = items.map { native in
            var row = previous.first { $0.native?.id == native.id }
                ?? ChatQueuedMessage(text: native.text, process: session.process,
                                     binding: session.binding, host: session.host, conversation: session.sessionID, generation: session.queueGeneration)
            if let delivery = row.delivery { session.drafts.finish(delivery, success: true); row.delivery = nil }
            row.native = native; row.pending = false; row.text = native.text
            row.process = session.process; row.binding = session.binding; row.host = session.host
            row.conversation = session.sessionID; row.generation = session.queueGeneration
            row.pause = switch native.paused {
            case "stopped": .stopped
            case "uncertain": .uncertain
            case "destination_changed": .destinationChanged
            case "needs_edit": .needsEdit(native.error?.message ?? "Edit this message before sending it.")
            default: nil
            }
            return row
        }
        rows += previous.filter { old in old.held && !rows.contains(where: { $0.id == old.id }) }
        session.queuedMessages = rows
        if let editing = session.editingQueuedID, !rows.contains(where: { $0.id == editing }) {
            session.editingQueuedID = nil; session.editingQueuedDraftID = nil
            session.submissionFailure = "The queued message is no longer pending. Your edit is preserved as a draft."
        }
        if let selected = session.selectedQueuedID, !rows.contains(where: { $0.id == selected }) { session.selectedQueuedID = nil }
        drainQueue(session)
    }

    /// Edit (and optionally send) a helper-owned row; the editor keeps the draft on failure.
    func updateHelperQueued(_ message: ChatQueuedMessage, session: ChatSession, text: String, send: Bool) {
        guard let helper = session.helper, let native = message.native, native.editable,
              !session.queueBusy, let delivery = session.drafts.prepareDelivery(consume: false) else { return }
        var input = HelperChat.Input(helper.route)
        input.item = native.id
        input.revision = native.revision
        input.text = text
        changeHelperQueue(session, message: message.id) { session in
            let _: HelperClient.Empty = try await helper.call("queue.update", input: input)
            if send {
                // An edit advances the producer's revision; send the row the helper now reports.
                let snapshot: [HelperChat.Queued] = try await helper.call("queue.list", input: .init(helper.route))
                guard let current = snapshot.first(where: { $0.id == native.id }) else { throw CancellationError() }
                try await self.startHelperQueued(current, helper: helper, busy: session.busy)
            }
            session.drafts.finish(delivery, success: true)
            session.editingQueuedID = nil; session.editingQueuedDraftID = nil
        } failed: { session in
            session.drafts.forgetDelivery(delivery)
        }
    }

    /// remove, start (resume) or send (now) one helper-owned row.
    func mutateHelperQueue(_ message: ChatQueuedMessage, session: ChatSession, operation: String) {
        guard enabled, sessions[session.id] === session, session.active, message.matches(session),
              !session.queueBusy, let helper = session.helper, let native = message.native else { return }
        var recovery: ChatDraftDelivery?
        if operation == "send", session.busy {
            guard native.editable,
                  let saved = session.drafts.prepareRecovery(ChatDraft(text: native.text, multiline: native.text.contains("\n"))) else { return }
            recovery = saved
        }
        let delivery = recovery
        changeHelperQueue(session, message: message.id) { session in
            if operation == "remove" {
                var input = HelperChat.Input(helper.route)
                input.item = native.id
                input.revision = native.revision
                let _: HelperClient.Empty = try await helper.call("queue.remove", input: input)
                if session.editingQueuedID == message.id { self.cancelQueuedEdit(session) }
            } else if operation == "start", !session.helperNativeQueue {
                // Resume: core unpauses its held items and drains them when idle.
                let _: HelperClient.Empty = try await helper.call("queue.restore", input: .init(helper.route))
            } else {
                try await self.startHelperQueued(native, helper: helper, busy: operation == "send" && session.busy)
            }
            if let delivery { session.drafts.finish(delivery, success: true) }
        } failed: { session in
            if let delivery { session.drafts.finish(delivery, success: false) }
        }
    }

    func reorderHelperQueue(_ rows: [ChatQueuedMessage], session: ChatSession) {
        guard let helper = session.helper else { return }
        var input = HelperChat.Input(helper.route)
        input.items = rows.compactMap { $0.native?.id }
        changeHelperQueue(session, message: nil) { _ in
            let _: HelperClient.Empty = try await helper.call("queue.reorder", input: input)
        } failed: { _ in }
    }

    private func startHelperQueued(_ native: HelperChat.Queued, helper: HelperChat, busy: Bool) async throws {
        var input = HelperChat.Input(helper.route)
        input.item = native.id
        input.revision = native.revision
        input.mode = busy ? "steer" : "prompt"
        let sent: HelperChat.Sent = try await helper.call("queue.start", input: input)
        try sent.confirmed()
    }

    /// One queue operation at a time; snapshots arriving meanwhile apply after it.
    private func changeHelperQueue(_ session: ChatSession, message: UUID?,
                                   _ body: @escaping @MainActor (ChatSession) async throws -> Void,
                                   failed: @escaping @MainActor (ChatSession) -> Void) {
        let helper = session.helper, generation = session.queueGeneration
        session.queueBusy = true; session.queuedSubmissionID = message; session.submissionFailure = nil
        operations.run(for: session.id) { [weak self, weak session] in
            guard let self, let session else { return }
            let current = { session.helper === helper && session.queueGeneration == generation }
            do {
                try Task.checkCancellation()
                guard current() else { return }
                try await body(session)
            } catch {
                guard current() else { return }
                failed(session)
                session.submissionFailure = error.localizedDescription
            }
            guard current() else { return }
            session.queueBusy = false; session.queuedSubmissionID = nil
            if let snapshot = session.helperQueueSnapshot {
                session.helperQueueSnapshot = nil
                self.receiveHelperQueue(snapshot, session: session)
            } else { self.drainQueue(session) }
        }
    }
}
