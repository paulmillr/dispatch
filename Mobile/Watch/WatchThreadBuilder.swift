import Foundation

/// A conversation as a watch thread page (docs/watch.md, "The page"): what `ChatThreadView` shows, flattened for a small
/// screen. Rows keep the phone's ids (`ChatThreadRow.id`'s form), so the watch's cache keys stay the same across pages;
/// tools, which the phone folds into captions and steps, are one line each.
@MainActor
enum WatchThreadBuilder {
    /// The most items one page holds, whatever the watch asks.
    static let maximumItems = 200

    /// The page for `session`. `row` is its Agents row (title, folder), `offline` the reason to show while the
    /// conversation is not live when the phone knows better than the session (the phone locked, a host only the phone's
    /// screen can connect).
    static func page(_ session: MobileChatSession, row: ChatConversation?, limit: Int = WatchLimits.threadItems,
                     offline: String? = nil, now: Date = Date()) -> WatchThread {
        let all = items(session, directory: row?.cwd)
        let limit = min(max(limit, 1), maximumItems)
        let (phase, reason) = phase(session, offline: offline)
        var thread = WatchThread(
            key: WatchConversationKey(host: session.key.host.uuidString, node: session.key.node), generated: now,
            title: row?.name ?? session.title ?? session.key.node, agent: session.agentLabel ?? session.agentKey,
            model: session.modelLabel, phase: phase, reason: reason, working: session.working,
            activity: session.activity, workingSince: session.workingSince, items: Array(all.suffix(limit)),
            earlier: all.count > limit || session.hasEarlier, queueStopped: session.queueStopped,
            canStop: session.phase == .verified && session.working, route: route(session), notes: notes(session),
            failure: session.failure)
        for approval in session.approvals where approval.pending.pending {
            if approval.pending.questions != nil {
                thread.questions.append(question(approval))
            } else {
                thread.approvals.append(Self.approval(approval))
            }
        }
        thread.questions += session.questions.filter { !$0.submitted }.map(question)
        thread.queue = session.queueRows.map {
            WatchQueued(id: $0.id, text: $0.text, status: $0.status, canSendNow: session.canSendNow($0))
        }
        return WatchCodec.fit(thread)
    }

    /// Per turn, its displayed items (`ChatTurnSummary.displayed`) as the thread shows them, plus each tool as a line;
    /// the turn's caption under its last agent message once it ended; the prompt being sent last.
    static func items(_ session: MobileChatSession, directory: String?) -> [WatchItem] {
        var result: [WatchItem] = []
        for turn in session.transcript.turns {
            let displayed = ChatTurnSummary.displayed(turn.items, turnID: turn.id)
            let lastAgent = displayed.lastIndex { $0.kind == .assistant }
            for (index, item) in displayed.enumerated() {
                // `MobileTranscript.rows`' id, so a row is the same item on the phone and in every page.
                let id = item.rowID ?? "\(turn.id.utf8.count):\(turn.id):\(item.id)"
                let time = item.source?.time_ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                func text(_ kind: WatchItemKind, caption: String? = nil) -> WatchItem {
                    WatchItem(id: id, kind: kind, text: WatchText.plain(item.text), time: time, turn: turn.id, caption: caption)
                }
                switch item.kind {
                case .user: result.append(text(.user))
                case .assistant:
                    let caption = index == lastAgent && turn.ended != nil ? ChatTurnSummary(turn).caption : nil
                    result.append(text(.agent, caption: caption))
                case .notice: result.append(text(.notice))
                case .reasoning where item.isNarration && !item.text.isEmpty: result.append(text(.thinking))
                case .tool:
                    let step = ChatStep(item, directory: directory)
                    result.append(WatchItem(id: id, kind: .tool, text: step.title, time: time, turn: turn.id,
                                            tool: step.kind.label, detail: step.detail, failed: step.failed,
                                            running: step.running))
                case .reasoning: break
                }
            }
        }
        if let prompt = session.optimisticPrompt {
            result.append(WatchItem(id: prompt.id, kind: .user, text: WatchText.plain(prompt.text)))
        }
        return result
    }

    /// Verified is live; detached is offline with the host's problem (or `offline`, the phone's own reason).
    static func phase(_ session: MobileChatSession, offline: String?) -> (WatchPhase, String?) {
        switch session.phase {
        case .verified: return (.live, nil)
        case .opening: return (.opening, nil)
        case .paused(let reason): return (.paused, reason)
        case .detached:
            if let offline { return (.offline, offline) }
            if case .failed(let reason) = session.link { return (.offline, reason) }
            return (.offline, session.linkProblem)
        }
    }

    static func route(_ session: MobileChatSession) -> WatchRoute {
        switch session.route(steer: false) {
        case .prompt, .steer: .send
        case .queue: .queue
        case .outbox: .outbox
        }
    }

    /// `ChatThreadView.notices` but the paused reason and the failure (the page's own `reason` and `failure`).
    static func notes(_ session: MobileChatSession) -> [String] {
        var notes: [String] = []
        if session.needsHookTrust, session.phase == .verified {
            notes.append("Codex sends approvals here only after you pick Trust all under “Hooks need review” in its terminal. Until then they wait in the Terminal tab.")
        }
        if session.phase == .verified, !session.terminalAttached {
            notes.append("Attaching the terminal… messages wait in the queue until it shows.")
        }
        if let result = session.commandResult {
            notes.append(result.title + (result.text.isEmpty ? "" : "\n" + result.text))
        }
        return notes
    }

    static func approval(_ approval: MobileChatSession.Approval) -> WatchApproval {
        let presentation = approval.interaction.approvalPresentation
        let choices = MobileChatSession.choices(for: approval.interaction).map { choice in
            let role: WatchChoiceRole = switch choice.role {
            case .allow: .allow
            case .deny: .deny
            case .session: .session
            }
            return WatchChoice(index: choice.index, label: choice.label, role: role)
        }
        return WatchApproval(id: approval.interaction.id, title: presentation.text, detail: presentation.code,
                             arrived: approval.arrived, choices: choices)
    }

    /// A question form (an approval with `ClaudeQuestions`): the phone's form offers only its options.
    static func question(_ approval: MobileChatSession.Approval) -> WatchQuestion {
        WatchQuestion(id: approval.interaction.id, blocking: approval.interaction.blocking, arrived: approval.arrived,
                      parts: approval.interaction.questions.map { question in
                          WatchQuestion.Part(id: question.id, header: question.header, text: question.text,
                                             options: options(question.options.map { ($0.label, $0.detail) }),
                                             multiple: question.multiple, custom: false, secret: question.secret)
                      })
    }

    /// A side question (`ChatSideQuestion`): options, a typed answer where it allows one, secret parts marked.
    static func question(_ question: ChatSideQuestion) -> WatchQuestion {
        WatchQuestion(id: question.id, blocking: question.blocking, parts: question.questions.map { part in
            WatchQuestion.Part(id: part.id, header: part.header, text: part.question,
                               options: options((part.options ?? []).map { ($0.label, $0.description) }),
                               multiple: part.multiple, custom: part.allowsCustom, secret: part.isSecret)
        })
    }

    private static func options(_ options: [(label: String, detail: String?)]) -> [WatchOption] {
        options.enumerated().map { index, option in
            WatchOption(index: index, label: option.label,
                        detail: option.detail.flatMap { $0.isEmpty ? nil : WatchText.clip($0, to: WatchLimits.line) })
        }
    }
}
