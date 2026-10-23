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
            if session.exitRequested, !disabled {
                session.exitRequested = false
                if !filesShowing(session) { setChatVisible(false, session: session, reason: "exit") }
            }
            rememberRemotePresentation(session)
            // An explicit exit can retire the subscription before its checked Return
            // reply arrives. Let that delivery verdict settle the draft and presentation.
            if disabled || !["/exit", "/quit"].contains(session.command?.text ?? "") {
                session.helperTask?.cancel()
            }
            session.active = false
            session.busy = false; session.subagents = []
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
           !TerminalRuntime.shared.ssh.helperConnections(granting: .chat).contains(connection) { return }
        // An SSH tab with a remote helper chats with the agents on that server.
        let remote = TerminalRuntime.shared.ssh.helper(for: tab.id)
        guard let terminal = remote?.terminal ?? tab.terminal else { return }
        // Else the helper that runs the tab's terminal (a remote backend's space, or this Mac).
        let endpoint: HelperWorkspace.Endpoint = (remote?.connection ?? space.remote).map { .remote($0) } ?? .local
        if let connection = endpoint.connection,
           !TerminalRuntime.shared.ssh.helperConnections(granting: .chat).contains(connection) { return }
        session.host = endpoint.connection.flatMap { TerminalRuntime.shared.ssh.links[$0]?.greeting.host }
        loadLaunches()
        if let helper = session.helper, helper.route.terminal == terminal, helper.endpoint == endpoint {
            if refresh {
                // A chat closed or replaced before this task runs (its permission withdrawn) is not reopened.
                Task { [weak session] in
                    guard session?.helper === helper else { return }
                    do { try await helper.open(refresh: true) } catch { helper.failed?(error) }
                }
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
            // A reopen after that exit finds the terminal retired ("expired").
            if ["agent_exited", "expired"].contains((error as? HelperFailure)?.code) {
                return self.helperExited(helper.endpoint, terminal: helper.route.terminal)
            }
            session.active = false
            // No harness bound is an ordinary terminal. Anything else (connection lost, a refused open) blocks
            // the chat: draft kept and flushed, approvals released, no input.
            if (error as? HelperFailure)?.code == "unavailable" { session.status = error.localizedDescription }
            else { self.suspendDiscovery(session, status: error.localizedDescription) }
        }
        Task { do { try await helper.open() } catch { helper.failed?(error) } }
        // Attachments need a helper that accepted `chat.attachments`; an archived transcript takes no input.
        session.acceptsAttachments = false
        if helper.transcript == nil {
            Task { [weak session] in
                let features = await HelperApp.shared.features(helper.endpoint)
                guard let session, session.helper === helper else { return }
                session.acceptsAttachments = features.contains(ChatAttachment.feature)
            }
        }
    }

    /// Internal (not private): unit tests feed helper events through the same path.
    func receiveHelper(_ event: HelperChat.Event, session: ChatSession) {
        switch event {
        case .history(let page):
            session.discoveryBlocked = false
            // A provisional binding ("") names no conversation yet; its first conversation is not a change.
            let conversation = page.session.isEmpty ? nil : page.session
            let sameProcess = session.agentID == page.key && session.binding?.pid != nil
                && session.binding?.pid == page.binding.pid && session.binding?.start == page.binding.start
            // The same process losing its transcript is no new conversation: Codex closes its rollout before
            // printing its exit hint, and rediscovery on that output reports it provisional. Keep the transcript
            // and draft for its exit; a conversation it names next is the change.
            if conversation == nil, session.sessionID != nil, sameProcess { return }
            let shown = session.sessionID
            if let previous = shown, previous != conversation {
                rememberRemotePresentation(session)
                session.helperTask?.cancel()
                let result = session.command?.command?.replacementResult
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
            if agent { session.exitRequested = false }
            session.binding = page.binding
            if agent, let helper = session.helper { installHelperIntegration(page.key, endpoint: helper.endpoint, terminal: helper.route.terminal) }
            restoreRemotePresentation(session)
            session.process = session.helper?.endpoint == .local ? page.binding.process : nil
            // A verified process before its first conversation has no history to wait for. A chat already showing this
            // conversation (reopened as its binding changed: its transcript appeared) is not loading: what the reopen
            // reads merges by record, and blocking it meanwhile blocked the picker and the composer after a turn.
            session.loadingHistory = page.history_pending && conversation != nil && (shown != conversation || session.turns.isEmpty)
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
            // The helper sends its state with every transcript read: write only what differs, so an unchanged
            // field invalidates no view (Observation reports every write, equal or not).
            if !session.active { session.active = true }
            if let version = state.version, session.version != version { session.version = version }
            // A native dialog owns the terminal (e.g. Claude's startup review of changed hooks, which
            // runs after the session registers): Chat opens once it closes.
            if session.sessionID != nil, state.dialog == nil, !session.manualViewChoice, !session.exitRequested, !session.showChat,
               !filesShowing(session) {
                setChatVisible(true, session: session)
                adoptTerminalTypeahead(session)
            }
            // Before busy, so a turn ending while its agents run keeps one working clock.
            if session.subagents != state.agents ?? [] { session.subagents = state.agents ?? [] }
            let busy = state.busy && !(session.agentID == "claude" && session.modelPicker != nil && state.activity == "waiting")
            if session.busy != busy { session.busy = busy }
            if session.starting { session.starting = false }
            if session.nativeActivity != state.activity { session.nativeActivity = state.activity }
            if !state.busy, state.dialog == nil, session.retiredInteraction { session.retiredInteraction = false }
            if session.activityCheck != nil { session.activityCheck = nil }
            if let model = state.model {
                session.applyConfiguration(model: model, effort: state.effort)
            }
            // Core's State.usage is the documented ChatUsage object (api.rs State.usage).
            if let usage = state.usage, let payload = HelperBinary.foundation(usage) as? [String: Any] {
                let usage = ChatUsage(payload)
                if session.usage != usage { session.usage = usage }
            }
            let attention = session.modelPicker == nil ? state.attention : nil
            if session.agentAttention != attention { session.agentAttention = attention }
            if let attention = state.attention, session.modelPicker == nil {
                requireTerminalAttention(session, status: attention)
            }
            // State.goal: the harness's goal object (codex native.rs goal); nil means no goal.
            let goal = state.goal.flatMap { HelperBinary.foundation($0) as? [String: Any] }.flatMap(ChatGoal.init)
            if goal != session.goal {
                session.goal = goal; session.goalUpdatedAt = .now; session.goalRevision += 1
                if session.commandResult?.title == "Goal" { session.commandResult?.text = goal?.summary ?? "Goal cleared." }
            }
            if let title = state.title, session.title != title { session.title = title }
            if session.threadName != state.title { session.threadName = state.title }
            if session.serviceTier != state.service_tier { session.serviceTier = state.service_tier }
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

    /// How long a launch line keeps the terminal covered waiting for Chat; then the terminal shows, as it would have.
    static let launchCoverLimit: Duration = .seconds(3)

    /// Return in a tab's terminal with `line` typed: a line that starts an agent Chat follows covers the terminal until
    /// Chat opens, so the agent's first second of terminal output never flashes before it. Only where discovery would
    /// open Chat by itself: never over files, an agent already attached, or a tab the user put on its terminal.
    func terminalSubmitted(_ line: String, tab: UUID) {
        guard enabled, let session = sessions[tab], !session.showChat, !session.active, !session.manualViewChoice,
              !session.exitRequested, !filesShowing(session), session.launchingAgent == nil,
              let agent = Self.launchedAgent(line, programs: launchPrograms) else { return }
        let cover = System.uuid()
        session.launchingAgent = agent
        session.launchCover = cover
        Task { @MainActor [weak session] in
            try? await Task.sleep(for: Self.launchCoverLimit)
            guard let session, session.launchCover == cover else { return }
            session.launchCover = nil
            session.launchingAgent = nil
        }
    }

    /// The commands that start each agent Chat is on for, to their launch keys: the helper's list once loaded, else
    /// the two it ships.
    private var launchPrograms: [String: String] {
        let disabled = disabledIntegrations
        let listed = (helperLaunches ?? []).filter { !disabled.contains($0.key) }
            .map { (($0.program ?? $0.key).split(separator: " ").first.map(String.init) ?? $0.key, $0.key) }
        let known = listed.isEmpty && helperLaunches?.isEmpty != false
            ? [("claude", "claude"), ("codex", "codex")].filter { !disabled.contains($0.1) } : listed
        return Dictionary(known, uniquingKeysWith: { first, _ in first })
    }

    /// The agent's name for the launch cover, as Settings lists it.
    func launchTitle(_ key: String) -> String {
        helperLaunches?.first { $0.key == key }?.label ?? key.prefix(1).uppercased() + key.dropFirst()
    }

    /// Subcommands that run and exit rather than open the agent's conversation.
    nonisolated private static let exitingSubcommands: [String: Set<String>] = [
        "claude": ["auth", "config", "doctor", "install", "login", "logout", "mcp", "migrate-installer", "plugin",
                   "plugins", "setup-token", "update", "upgrade"],
        "codex": ["a", "app-server", "apply", "cloud", "completion", "debug", "e", "exec", "features", "generate-ts",
                  "help", "login", "logout", "mcp", "mcp-server", "proto", "sandbox"]]

    /// The agent `line` starts, by launch key: its program (by name or path, after any VAR=value words) alone or with
    /// options, a prompt or a resume; nil for a subcommand or an option that prints and exits (`claude -p`,
    /// `codex exec`, `--version`).
    nonisolated static func launchedAgent(_ line: String, programs: [String: String]) -> String? {
        var words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, !first.hasPrefix("-"), first.contains("="), !first.hasPrefix("=") { words.removeFirst() }
        guard let first = words.first, let key = programs[(first as NSString).lastPathComponent] else { return nil }
        let rest = words.dropFirst()
        if rest.contains(where: ["-p", "--print", "-h", "--help", "-v", "-V", "--version"].contains) { return nil }
        if let command = rest.first(where: { !$0.hasPrefix("-") }), exitingSubcommands[key]?.contains(command) == true {
            return nil
        }
        return key
    }

    /// Text typed in Terminal after the launch command, before Chat opened, sits in Claude's own
    /// prompt, where it would refuse every Chat send. When Claude's composer shows exactly that
    /// text, it moves to the Chat draft ahead of anything typed there since.
    func adoptTerminalTypeahead(_ session: ChatSession) {
        guard session.agentID == "claude", let terminal = TerminalRuntime.shared.views[session.id],
              let typed = terminal.typeahead, !typed.trimmingCharacters(in: .whitespaces).isEmpty,
              // Delete removes one character; keep to characters that are one UTF-16 unit.
              typed.unicodeScalars.count == typed.count, typed.unicodeScalars.allSatisfy({ $0.value <= 0xFFFF })
        else { return }
        terminal.typeahead = nil
        let expected = typed.trimmingCharacters(in: .whitespaces)
        operations.run(for: session.id) { [weak self, weak session, weak terminal] in
            // The last keystrokes may still be on their way to Claude's screen.
            @MainActor func settled(_ condition: (String) -> Bool) async -> Bool {
                for _ in 0..<25 {
                    guard let self, let session, let terminal, self.sessions[session.id] === session,
                          session.active, session.showChat, !Task.isCancelled else { return false }
                    // An empty composer shows a faint placeholder after the cursor.
                    let tail = terminal.surface?.cursorFaintTail()
                    let screen = ClaudeModelMenu.removingPlaceholder(terminal.agentMenuScreen, column: Int(tail?.column ?? 0),
                                                                     row: Int(tail?.row ?? 0), faint: tail?.faint == true)
                    if condition(screen) { return true }
                    try? await Task.sleep(for: .milliseconds(40))
                }
                return false
            }
            guard await settled({ ClaudeModelMenu.composerText($0) == expected }), let terminal else { return }
            terminal.eraseTypedCharacters(typed.count)
            guard await settled({ ClaudeModelMenu.composerText($0) == "" }), let session else { return }
            let draft = session.drafts.current, shift = typed.utf16.count
            session.drafts.edit(text: typed + draft.text,
                                selection: NSRange(location: draft.selection.location + shift, length: draft.selection.length))
        }
    }

    /// Records come in transcript order: an earlier page goes before everything shown, the rest after.
    /// Their positions order records with equal times, as file offsets did (legacy transcript reader).
    private func receiveHelper(_ records: [HelperChat.Record], session: ChatSession, historical: Bool, earlier: Bool = false) {
        let decoded = session.transcriptIndex.decode(records, historical: historical, earlier: earlier, now: Date())
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
        let attachments = queued?.attachments ?? session.drafts.current.attachments
        // Commands take no attachments (the helper refuses them); the draft keeps both.
        if command, !attachments.isEmpty {
            session.submissionFailure = "Commands cannot carry attachments. Remove them to run this command; your draft is preserved."
            return
        }
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        // An attachment still uploading would be left out of the message.
        if queued == nil, session.draftUploads.contains(where: \.uploading) {
            session.submissionFailure = "Attachments are still uploading. Send again when they are ready."
            return
        }
        let id = System.uuid()
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
            session.showOptimisticPrompt(text, attachments: attachments)
        }
        var input = HelperChat.Input(helper.route)
        input.text = text
        input.attachments = Self.attachmentPaths(attachments)
        let wasBusy = session.busy
        let turn = session.activeTurnID
        // A prompt shows the agent working at once, as the old app did; the harness's State confirms it.
        if !command { input.mode = immediately && wasBusy ? "steer" : "prompt"; session.busy = true }
        // A command is running until the harness replies.
        if command { session.command = ChatCommandRequest(text: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let exits = command && ["/exit", "/quit"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if exits { session.exitRequested = true }
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
                if exits, !self.filesShowing(session) { self.setChatVisible(false, session: session, reason: "exit") }
                // The picker is open: Terminal takes the keyboard, as the user's own switch would.
                // Nothing prints back to Chat; a picked conversation arrives as a new history.
                if opensTerminal {
                    session.observedCommand = nil
                    self.showTerminal(session)
                }
            } catch {
                guard session.helper === helper, session.submissionID == id else { return }
                // The agent exited before the command's reply: the exit was delivered.
                if exits, !session.active {
                    if let delivery { session.drafts.finish(delivery, success: true) }
                    if let queued { session.queuedMessages.removeAll { $0.id == queued.id } }
                    session.command = nil
                    session.observedCommand = nil
                    session.awaitingPromptAck = false
                    session.promptBoundary = nil
                    session.submissionID = nil
                    session.queuedSubmissionID = nil
                    session.helperTask = nil
                    if !self.filesShowing(session) { self.setChatVisible(false, session: session, reason: "exit") }
                    return
                }
                if exits { session.exitRequested = false }
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
            session.focusRequest = System.uuid()
            self.drainQueue(session)
        }
    }

    func interruptHelper(_ session: ChatSession) -> Bool {
        guard let helper = session.helper, canInterrupt(session) else { return false }
        let id = System.uuid()
        session.interruptionID = id
        session.stopQueue()
        let upload = session.upload
        operations.run(for: session.id) { [weak session] in
            guard let session else { return }
            defer { if session.interruptionID == id { session.interruptionID = nil } }
            // An upload already on its way reaches the helper first, so its Stop pauses that row too
            // (helper calls are not ordered between tasks).
            await upload?.value
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
        session.modelChoices = modelChoices(for: session)
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
                                                     item: interaction.tool(in: session.turns), turnID: interaction.turn, toolItemID: interaction.record,
                                                     anchorTurnID: session.turns.last?.id) { [weak self, weak session] in
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
                                                     turnID: interaction.turn, toolItemID: interaction.record, anchorTurnID: session.turns.last?.id,
                                                     questions: questions) { [weak self, weak session] in
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
        let id = System.uuid()
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
        let id = System.uuid()
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
    /// On, it installs on this Mac and connected SSH hosts whose agent hooks allow it; off, it is off on all of
    /// them, leaving each machine's own choice for when it is turned on again.
    func setHelperIntegration(_ key: String, enabled: Bool) {
        if enabled { disabledIntegrations.remove(key) } else { disabledIntegrations.insert(key) }
        let endpoints = [HelperWorkspace.Endpoint.local] + TerminalRuntime.shared.ssh.helperConnections(granting: .hooks).map { .remote($0) }
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

    /// This Mac's agent hooks (Hosts settings). Off, the local helper ignores the agent and its local chats return
    /// to their terminals; on, it installs here, unless Chat mode or the agent is off.
    func setLocalHooks(_ key: String, allowed: Bool) {
        localHooks[key] = allowed
        if !allowed {
            for session in sessions.values where session.agentID == key && session.helper?.endpoint == .local {
                if helperInstalls[key]?.optional == true {
                    end(session, preservingPresentation: false)
                    suspendDiscovery(session, status: "\(session.agentTitle) hooks are off on this Mac. Continue in Terminal.")
                } else { session.relinquish() }
            }
        } else if !enabled || disabledIntegrations.contains(key) { return }
        integrationWork { chat in
            do {
                if let install = try await HelperChat.setup(.local, key: key, enabled: allowed, terminal: nil) {
                    chat.helperInstalls[key] = install
                }
                chat.installed(key, endpoint: .local, error: nil)
            } catch { chat.installed(key, endpoint: .local, error: error) }
        }
    }

    private func installed(_ key: String, endpoint: HelperWorkspace.Endpoint, terminal: UInt64? = nil, error: Error?) {
        let current = endpoint.connection.map { TerminalRuntime.shared.ssh.helperConnections(granting: .hooks).contains($0) } ?? true
        installationFailures[.init(key: key, endpoint: endpoint, terminal: terminal)] = current ? error?.localizedDescription : nil
    }

    private func permits(_ key: String, on endpoint: HelperWorkspace.Endpoint) -> Bool {
        guard let connection = endpoint.connection else { return localHooksAllowed(key) }
        let ssh = TerminalRuntime.shared.ssh
        guard let scope = ssh.links[connection]?.launch.integrationScope,
              let agent = SSHHookAgent(rawValue: key) else { return true }
        return ssh.permissions.hooks(scope, agent: agent) != false
    }

    /// SSH agents may read their own config root rather than the remote account's
    /// (c1654cc SSHCoordinator.configureAgentHooks). Local setup stays account-wide.
    private func installHelperIntegration(_ key: String, endpoint: HelperWorkspace.Endpoint, terminal: UInt64) {
        integrationWork { chat in
            guard let connection = endpoint.connection, chat.enabled, !chat.disabledIntegrations.contains(key),
                  chat.helperInstalls[key].map({ $0.optional != true || $0.status != "off" }) == true,
                  TerminalRuntime.shared.ssh.helperConnections(granting: .hooks).contains(connection) else { return }
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
            guard chat.enabled, TerminalRuntime.shared.ssh.helperConnections(granting: .hooks).contains(connection) else { return }
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

    /// The first-launch answer to whether agents run on this Mac (LocalAgentsConsent). Yes (the launch keys whose
    /// CLIs were found) installs their integrations here; optional ones stay opt-in, as for a new SSH host. No
    /// (nil) turns this Mac's agent hooks off, leaving the agents' settings as they are.
    func adoptLocalAgents(_ found: Set<String>?) {
        loadLaunches()
        integrationWork { chat in
            for launch in chat.helperLaunches ?? [] {
                guard let found else { chat.setLocalHooks(launch.key, allowed: false); continue }
                guard found.contains(launch.key), let install = chat.helperInstalls[launch.key], install.optional != true else { continue }
                if !chat.localHooksAllowed(launch.key) { chat.localHooks[launch.key] = nil }
                chat.setHelperIntegration(launch.key, enabled: true)
            }
        }
    }

    /// Settings defaults: every required integration on, every optional one off.
    func restoreHelperIntegrations() {
        for launch in helperLaunches ?? [] {
            let optional = helperInstalls[launch.key]?.optional == true
            if !optional || helperInstalls[launch.key]?.status != "off" { setHelperIntegration(launch.key, enabled: !optional) }
        }
    }

    /// The helper's agents in its own order, except Codex listed just above Claude Code. Only the list moves: a
    /// launch's position is its protocol id, so the helper keeps its order.
    var listedLaunches: [HelperClient.Launch] {
        let launches = helperLaunches ?? []
        guard let codex = launches.firstIndex(where: { $0.key == "codex" }),
              let claude = launches.firstIndex(where: { $0.key == "claude" }), codex > claude else { return launches }
        var listed = launches
        listed.insert(listed.remove(at: codex), at: claude)
        return listed
    }

    /// Inactive composer hint, named from the helper's launches rather than a fixed agent list.
    func placeholder(_ session: ChatSession) -> String {
        if ChatThemeStore.shared.current.radioLog {
            let channel = HarbourRadio.channel(for: session.id)
            return session.active ? "Transmit on \(channel)…" : "Hail \(agents) on \(channel)…"
        }
        if session.active { return "Reply…" }
        return "Start \(agents) in this terminal…"
    }

    /// Loads the helper's launch labels once; failures leave the generic wording.
    func loadLaunches() {
        guard helperLaunches == nil else { return }
        helperLaunches = []
        // The first audit is installation work too: a toggle made meanwhile runs after it, never under it.
        integrationWork { chat in
            let launches = (try? await HelperClient(HelperApp.shared.connection()).launches()) ?? []
            chat.helperLaunches = launches
            for launch in launches {
                // A new helper starts with every integration enabled: repeat the user's turned-off ones.
                let off = chat.disabledIntegrations.contains(launch.key) || !chat.enabled || !chat.localHooksAllowed(launch.key)
                guard var install = try? await HelperChat.setup(.local, key: launch.key, enabled: nil, terminal: nil) else { continue }
                if off, install.status != "off", let changed = try? await HelperChat.setup(.local, key: launch.key, enabled: false, terminal: nil) {
                    install = changed
                }
                // An earlier opt-in missing hooks a newer helper installs (its audit shows the edit) is upgraded.
                if !off, install.optional != true, install.installed == true, install.edits.contains(where: { $0.before != $0.after }),
                   let upgraded = try? await HelperChat.setup(.local, key: launch.key, enabled: true, terminal: nil) {
                    install = upgraded
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

    // Attachments (docs/integrations.md, Attachments): read here, uploaded to the conversation's helper, named by path.

    /// Whether the composer offers attachments: a live chat whose helper accepted `chat.attachments`, not a side
    /// conversation, a command or an edit of a queued message (whose row keeps its own).
    func canAttach(_ session: ChatSession) -> Bool {
        enabled && sessions[session.id] === session && session.acceptsAttachments && session.helper != nil && session.active
            && session.sideConversation == nil && session.editingQueuedID == nil && !session.draftIsCommand
            && !session.inputBlocked && session.helper?.transcript == nil
    }

    /// Reads, prepares and uploads `sources` for the current draft; each shows as an uploading chip on that draft until
    /// the host stored it, then joins it (`ChatDraftCollection.attach(_:toDraft:scope:)`), also when the user switched to
    /// another draft meanwhile. Too many for one message: nothing is uploaded.
    func attach(_ sources: [ChatAttachmentSource], to session: ChatSession) {
        guard !sources.isEmpty, canAttach(session), let helper = session.helper else { return }
        session.attachmentError = nil
        let draft = session.drafts.current
        let pending = session.draftUploads.filter(\.uploading).count
        guard draft.attachments.count + pending + sources.count <= ChatAttachment.maximumCount else {
            session.attachmentError = ChatAttachmentError.tooMany.localizedDescription
            return
        }
        for source in sources {
            let upload = ChatAttachmentUpload(id: System.uuid().uuidString, draft: draft.id, scope: session.drafts.scope,
                                              name: source.name, source: source)
            session.attachmentUploads.append(upload)
            startUpload(upload.id, endpoint: helper.endpoint, session: session)
        }
    }

    /// Uploads a failed attachment again, from what was read the first time, to the conversation's helper now.
    func retryAttachment(_ id: String, in session: ChatSession) {
        guard let helper = session.helper, canAttach(session),
              let index = session.attachmentUploads.firstIndex(where: { $0.id == id }), !session.attachmentUploads[index].uploading else { return }
        session.attachmentError = nil
        guard session.drafts.current.attachments.count + session.draftUploads.filter(\.uploading).count < ChatAttachment.maximumCount else {
            session.attachmentError = ChatAttachmentError.tooMany.localizedDescription
            return
        }
        // A chip shows on the current draft only, so Retry is for that one.
        session.attachmentUploads[index].draft = session.drafts.current.id
        session.attachmentUploads[index].scope = session.drafts.scope
        session.attachmentUploads[index].failure = nil
        startUpload(id, endpoint: helper.endpoint, session: session)
    }

    /// Removes an attachment from the draft, or stops its upload (a copy the host already stored is swept with the rest).
    func removeAttachment(_ id: String, from session: ChatSession) {
        if let index = session.attachmentUploads.firstIndex(where: { $0.id == id }) {
            session.attachmentUploads.remove(at: index).task?.cancel()
        } else { session.drafts.detach(id) }
        session.attachmentError = nil
    }

    /// Reads, prepares and stores one upload on `endpoint`'s helper. Only removing the chip cancels it; any other
    /// failure (the link dropped, the host refused, the draft is gone) keeps the chip with the reason and Retry.
    private func startUpload(_ id: String, endpoint: HelperWorkspace.Endpoint, session: ChatSession) {
        guard let source = session.attachmentUploads.first(where: { $0.id == id })?.source else { return }
        let task = Task { [weak session] in
            @MainActor func update(_ change: (inout ChatAttachmentUpload) -> Void) {
                guard let session, let index = session.attachmentUploads.firstIndex(where: { $0.id == id }) else { return }
                change(&session.attachmentUploads[index])
            }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { try source.prepare() }.value
                try Task.checkCancellation()
                update { $0.name = prepared.name; $0.size = prepared.bytes.count; $0.thumbnail = prepared.thumbnail }
                let stored = try await Self.put(prepared, endpoint: endpoint)
                guard let session, let upload = session.attachmentUploads.first(where: { $0.id == id }) else { return }
                try Self.land(stored.attachment(id: id, thumbnail: prepared.thumbnail), upload: upload, endpoint: endpoint, in: session)
            } catch {
                // Removed: the chip is gone, and so is anything to say.
                guard !Task.isCancelled else { return }
                let reason = error is CancellationError ? "The upload was interrupted." : error.localizedDescription
                update { $0.failure = reason; $0.task = nil }
            }
        }
        if let index = session.attachmentUploads.firstIndex(where: { $0.id == id }) { session.attachmentUploads[index].task = task }
    }

    /// A stored attachment into the draft its upload was for. That draft gone (sent, discarded, or replaced by a
    /// restored one) or the conversation now on another host: the chip moves to the current draft with the reason, and
    /// Retry attaches it there.
    static func land(_ attachment: ChatAttachment, upload: ChatAttachmentUpload, endpoint: HelperWorkspace.Endpoint,
                             in session: ChatSession) throws {
        let current = session.drafts.repository.resolvedScope(upload.scope) == session.drafts.scope
        if current, let helper = session.helper, helper.endpoint != endpoint {
            session.retarget(upload.id)
            throw HelperFailure(code: "unavailable", message: "The conversation moved to another host. Retry uploads it there.")
        }
        guard let fitted = session.drafts.attach([attachment], toDraft: upload.draft, scope: upload.scope) else {
            session.retarget(upload.id)
            throw HelperFailure(code: "unavailable", message: "The draft it was for was sent or discarded. Retry attaches it here.")
        }
        session.attachmentUploads.removeAll { $0.id == upload.id }
        if !fitted { session.attachmentError = ChatAttachmentError.tooMany.localizedDescription }
    }

    /// `attachments.put` on the helper of the conversation's host. Not bound to the chat's subscription: a copy belongs
    /// to the host, and the draft takes it whatever the chat did meanwhile. A remote upload has the Files view's bound
    /// for its size: a copy stored after the timeout is never named by a message and is swept with the rest.
    static func put(_ prepared: ChatAttachmentImage.Prepared, endpoint: HelperWorkspace.Endpoint) async throws -> HelperChat.StoredAttachment {
        let params = HelperChat.AttachmentUpload(name: prepared.name, bytes: prepared.bytes)
        let put: @Sendable () async throws -> HelperChat.StoredAttachment = {
            try await HelperApp.shared.connection(endpoint).request("attachments.put", params: params)
        }
        guard endpoint.connection != nil else { return try await put() }
        let bound = HelperFilesSource.Bound.bytes(UInt64(prepared.bytes.count))
        return try await SSHTimeout.run(bound.duration ?? .seconds(600), "chat.attachments.put", operation: put)
    }

    /// The host paths a message names; nil (absent on the wire) without attachments.
    static func attachmentPaths(_ attachments: [ChatAttachment]) -> [String]? {
        let paths = attachments.compactMap(\.path)
        return paths.isEmpty ? nil : paths
    }

    /// `queue.add` for a held row: its text, command flag and attachments.
    static func queueInput(_ row: ChatQueuedMessage, route: HelperChat.Route) -> HelperChat.Input {
        var input = HelperChat.Input(route)
        input.text = row.text
        input.mode = "prompt"
        input.command = row.isCommand
        input.attachments = attachmentPaths(row.attachments)
        return input
    }

    /// A native queue row's attachment previews (`{kind: "attachment", type}`) as chips without a path.
    static func attachmentPlaceholders(_ native: HelperChat.Queued) -> [ChatAttachment] {
        native.preview.enumerated().compactMap { index, preview in
            guard preview.kind == "attachment" else { return nil }
            let kind: ChatAttachment.Kind = ["image", "localImage"].contains(preview.type ?? "") ? .image : .file
            return ChatAttachment(id: "\(native.id)#\(index)", name: ChatAttachment.untitled(kind), kind: kind, size: 0, path: nil)
        }
    }

    /// A native queue row's typed text, without its attachment previews.
    static func typedText(_ native: HelperChat.Queued) -> String {
        native.preview.filter { $0.kind != "attachment" }.compactMap(\.text).joined(separator: "\n")
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
            row.native = native; row.pending = false
            // Attachments show as chips: the text keeps what was typed. A row this Mac handed over keeps its own.
            let placeholders = Self.attachmentPlaceholders(native)
            row.text = placeholders.isEmpty ? native.text : Self.typedText(native)
            row.attachments = ChatAttachment.merge(placeholders, keeping: row.attachments)
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

    /// Whether the host's queue store keeps this conversation's queue: a helper-held queue (not
    /// the agent's own) of a conversation the agent has named.
    func storesQueue(_ session: ChatSession) -> Bool {
        guard let helper = session.helper, !session.helperNativeQueue else { return false }
        return !(helper.route.session ?? "").isEmpty && helper.route.session == session.sessionID
    }

    /// Hand the oldest held row to the host's queue store, one at a time and in order. The row
    /// becomes the host's in place once accepted (on disk there); one the host refuses stays here
    /// and this Mac sends it itself. True while an upload runs or starts.
    @discardableResult
    func uploadHeldQueue(_ session: ChatSession) -> Bool {
        guard storesQueue(session), let helper = session.helper else { return false }
        if session.queueBusy { return session.queuedMessages.contains { $0.held && $0.pending } }
        // Pending without an upload running: one cancelled before it started.
        for index in session.queuedMessages.indices where session.queuedMessages[index].held && session.queuedMessages[index].pending {
            session.queuedMessages[index].pending = false
        }
        if let id = session.sendAfterUpload {
            session.sendAfterUpload = nil
            if let row = session.queuedMessages.first(where: { $0.id == id }), row.pause == nil {
                if row.native != nil { mutateHelperQueue(row, session: session, operation: "send"); return true }
                if row.local { sendNow(session, queuedID: id); return true }
            }
        }
        // Only the first held row, in order: one waiting for review (paused) or for this Mac
        // (local) keeps the rows behind it here, and a row being sent directly is not uploaded.
        guard session.binding != nil, session.editingQueuedID == nil, session.queuedSubmissionID == nil,
              let row = session.queuedMessages.first(where: \.held),
              !row.local, !row.pending, row.pause == nil, row.matches(session) else { return false }
        // Pending from now on: Stop and Send now see the row is being handed over.
        if let index = session.queuedMessages.firstIndex(where: { $0.id == row.id }) { session.queuedMessages[index].pending = true }
        let input = Self.queueInput(row, route: helper.route)
        session.upload = changeHelperQueue(session, message: nil) { session in
            defer { session.upload = nil }
            @MainActor func update(_ change: (inout ChatQueuedMessage) -> Void) {
                if let index = session.queuedMessages.firstIndex(where: { $0.id == row.id }) { change(&session.queuedMessages[index]) }
            }
            // Stopped, sent directly or removed since: nothing goes to the host.
            guard let current = session.queuedMessages.first(where: { $0.id == row.id }), current.held,
                  current.pause == nil, session.queuedSubmissionID != row.id else {
                update { $0.pending = false }
                return
            }
            let added: HelperChat.Queued
            do { added = try await helper.call("queue.add", input: input) } catch {
                // A refusal stored nothing: this Mac sends the row itself. Anything else (a reply lost
                // with the connection, a storage error after the write) may hide an add the host kept
                // and will send: never twice.
                let refusals = ["invalid_input", "shell_command", "unavailable", "permission_denied", "expired"]
                let uncertain = !((error as? HelperFailure).map { refusals.contains($0.code) } ?? false)
                update { row in
                    row.pending = false
                    if uncertain { row.pause = .uncertain } else { row.local = true }
                }
                throw error
            }
            update { row in
                if let delivery = row.delivery { session.drafts.finish(delivery, success: true) }
                row.delivery = nil
                row.native = added
                row.pending = false
            }
        } failed: { _ in }
        return true
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
    @discardableResult
    private func changeHelperQueue(_ session: ChatSession, message: UUID?,
                                   _ body: @escaping @MainActor (ChatSession) async throws -> Void,
                                   failed: @escaping @MainActor (ChatSession) -> Void) -> Task<Void, Never> {
        let helper = session.helper, generation = session.queueGeneration
        session.queueBusy = true; session.queuedSubmissionID = message; session.submissionFailure = nil
        return operations.run(for: session.id) { [weak self, weak session] in
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
