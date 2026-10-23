import SwiftUI

/// One conversation: items, pending approvals/questions, queue, composer. Calls model.open(key)/close(key) on
/// appear/disappear.
///
/// One list, oldest at the top: the header (agent, model, why input waits, the phone's notes), the page's items, the
/// working line, failures, then what waits for the user (approval cards with their chips, question cards), the queue
/// and the composer. It opens scrolled to the first request, else to the newest item.
struct ThreadScreen: View {
    let model: WatchModel
    let key: WatchConversationKey
    var router: WatchRouter = .shared

    init(model: WatchModel, key: WatchConversationKey, router: WatchRouter = .shared) {
        self.model = model
        self.key = key
        self.router = router
    }

    /// Requests with an answer on its way: their chips are disabled.
    @State private var answering: Set<String> = []
    /// Failure lines the user dismissed (by message): one comes back only when a new failure says something else.
    @State private var dismissed: Set<String> = []
    @State private var question: WatchQuestion?
    /// A dictated or typed reply waiting for Send on the confirm screen (K5).
    @State private var reply: ReplyDraft?
    /// What "Open on iPhone" did, said under its button until the page changes.
    @State private var opened: String?
    @State private var opening = false
    @State private var scrolled = false
    /// `-DispatchWatchSheet` (Debug): a sheet to open once the page is in.
    @State private var debugSheet: WatchRouter.Sheet?
    @State private var preselect: Int?

    var body: some View {
        let thread = model.thread(for: key)
        Group {
            if let thread {
                page(thread)
            } else {
                loading
            }
        }
        .navigationTitle(model.conversation(key)?.displayTitle ?? thread?.title ?? "")
        .toolbar {
            if thread != nil, model.loading.contains(key) {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().accessibilityLabel("Loading")
                }
            }
        }
        .sheet(item: $question) { question in
            QuestionSheet(question: question, preselect: preselect) { answer in
                Task { await model.answer(key, question: question, answer) }
            }
        }
        .sheet(item: $reply) { draft in
            ReplyConfirmScreen(draft: draft, route: ThreadComposer.routeLine(thread.map { ($0.route, ThreadComposer.split($0.queue).queued.count) })) {
                Task { await model.send(key, text: draft.text, steer: draft.steer) }
            }
        }
        .task { await model.open(key) }
        .onAppear {
            debugSheet = router.takeSheet()
            presentDebugSheet()
        }
        .onChange(of: thread != nil) { presentDebugSheet() }
        .onChange(of: question != nil || reply != nil) { _, open in router.childSheet = open }
        .onDisappear { model.close(key) }
    }

    /// No page yet: the phone's "Loading conversation…", or the failure with Try Again.
    @ViewBuilder private var loading: some View {
        if let failure = model.failures[key], !model.loading.contains(key) {
            ScrollView {
                VStack(spacing: 8) {
                    Text(failure.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await model.loadThread(key) } }
                }
            }
        } else {
            ProgressView("Loading conversation…")
        }
    }

    private func page(_ thread: WatchThread) -> some View {
        let (queued, sending) = ThreadComposer.split(thread.queue)
        let failures = Self.failures(thread: thread, failure: model.failures[key]).filter { !dismissed.contains($0) }
        let card = Self.card(thread)
        let agent = model.conversation(key)?.agent ?? thread.agent
        return ScrollViewReader { proxy in
            List {
                ThreadHeader(thread: thread, agent: agent).modifier(BareRow())
                if thread.earlier {
                    Text("Earlier messages are on your iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .modifier(BareRow())
                }
                ForEach(thread.items) { item in
                    Group {
                        if item.id == card {
                            ThreadSummaryCard(item: item, agent: thread.agent)
                        } else {
                            ThreadItemRow(item: item, agent: thread.agent)
                        }
                    }
                    .modifier(BareRow())
                    .id(item.id)
                }
                ForEach(sending) { item in
                    VStack(alignment: .trailing, spacing: 2) {
                        ThreadBubble(side: .user, faded: true) { Text(item.text) }
                        Text(item.status ?? "Sending…").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .modifier(BareRow())
                    .accessibilityElement(children: .combine)
                }
                if thread.working {
                    ThreadWorkingRow(activity: thread.activity, since: thread.workingSince).modifier(BareRow())
                }
                ForEach(failures, id: \.self) { message in
                    Button {
                        dismissed.insert(message)
                    } label: {
                        Label { Text(message).font(.footnote) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AgentsColor.destructive)
                        }
                        .modifier(ThreadButtonRow())
                    }
                    .accessibilityHint("Dismisses this message")
                    .accessibilityIdentifier("thread.failure")
                }
                ForEach(thread.approvals) { approval in
                    ApprovalCard(approval: approval, agent: agent).modifier(BareRow()).id(approval.id)
                    ForEach(ApprovalCard.ordered(approval.choices)) { choice in
                        ApprovalChoiceButton(choice: choice, busy: answering.contains(approval.id)) {
                            answer(approval, choice)
                        }
                    }
                }
                ForEach(thread.questions) { question in
                    QuestionCard(question: question).modifier(BareRow()).id(question.id)
                    CapsuleButton(title: question.answerable ? "Answer" : "Open", style: .accent,
                                  enabled: !answering.contains(question.id)) { self.question = question }
                }
                // Plain rows, not a `Section`: on watchOS 27 a Section inside this List left the row before it and its
                // own last row undrawn (a page of header and composer alone came out blank).
                if !queued.isEmpty {
                    Group {
                        QueueHeader(count: queued.count).modifier(BareRow())
                        ForEach(queued) { item in
                            QueuedRow(item: item).modifier(ThreadButtonRow())
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        Task { await model.removeQueued(key, item: item) }
                                    } label: { Label("Remove", systemImage: "trash") }
                                    if item.canSendNow {
                                        Button {
                                            Task { await model.sendQueuedNow(key, item: item) }
                                        } label: { Label("Send now", systemImage: "arrow.up.circle") }
                                        .tint(AgentsColor.pink)
                                    }
                                }
                        }
                        if thread.queueStopped {
                            CapsuleButton(title: "Resume", symbol: "play.fill", hint: "Sends the queued messages again") {
                                Task { await model.resume(key) }
                            }
                        }
                    }
                }
                composer(thread, queued: queued.count)
                // watchOS 27 leaves this List's last row undrawn and out of its scroll range (the composer, before it
                // the queue's last row): an empty row takes that place.
                Color.clear.frame(height: 1)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
            // Bubbles and step lines are as tall as their text; buttons keep 44 pt themselves.
            .environment(\.defaultMinListRowHeight, 0)
            .onAppear { scroll(proxy, thread) }
            .onChange(of: thread.items.last?.id) { scrolled = false; scroll(proxy, thread) }
        }
    }

    /// Reply (the system's dictation or keyboard, then the confirm screen), Steer while a live agent works, Stop, and
    /// Open on iPhone.
    @ViewBuilder private func composer(_ thread: WatchThread, queued: Int) -> some View {
        Group {
            TextFieldLink(prompt: Text(ThreadComposer.prompt(route: thread.route, queued: queued))) {
                CapsuleLabel(title: "Reply", symbol: "mic.fill", style: .accent)
            } onSubmit: { text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply = ReplyDraft(text: text, steer: false) }
            }
            .buttonStyle(.plain)
            .modifier(BareRow(vertical: 4))
            .accessibilityLabel("Reply")
            .accessibilityHint(ThreadComposer.routeLine((thread.route, queued)) ?? "Sends your message to the agent")
            if ThreadComposer.canSteer(thread) {
                TextFieldLink(prompt: Text("Steer the agent…")) {
                    CapsuleLabel(title: "Steer", symbol: "arrow.turn.down.right")
                } onSubmit: { text in
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { reply = ReplyDraft(text: text, steer: true) }
                }
                .buttonStyle(.plain)
                .modifier(BareRow())
                .accessibilityLabel("Steer")
                .accessibilityHint("Sends into the running turn instead of queueing")
            }
            if thread.canStop {
                CapsuleButton(title: "Stop", symbol: "stop.fill", style: .destructive,
                              hint: "Stops the agent; queued messages wait until Resume") {
                    Task { await model.stop(key) }
                }
            }
            CapsuleButton(title: "Open on iPhone", symbol: "iphone", enabled: !opening,
                          hint: "Shows this conversation on your iPhone") {
                openOnPhone()
            }
            if let opened {
                Text(opened)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .modifier(BareRow())
            }
        }
    }

    private func presentDebugSheet() {
        guard let sheet = debugSheet, let thread = model.thread(for: key) else { return }
        debugSheet = nil
        switch sheet {
        case .question(let choose):
            preselect = choose
            question = thread.questions.first
        case .reply(let text): reply = ReplyDraft(text: text, steer: false)
        }
    }

    private func openOnPhone() {
        opening = true
        Task {
            opened = await model.openOnPhone(key)
            opening = false
        }
    }

    private func answer(_ approval: WatchApproval, _ choice: WatchChoice) {
        guard answering.insert(approval.id).inserted else { return }
        Task {
            await model.answer(key, approval: approval, choice: choice)
            answering.remove(approval.id)
        }
    }

    /// Once per page: to the first request waiting, else the summary card, else the newest item.
    private func scroll(_ proxy: ScrollViewProxy, _ thread: WatchThread) {
        guard !scrolled, let target = Self.anchor(thread) else { return }
        scrolled = true
        proxy.scrollTo(target.id, anchor: target.top ? .top : .bottom)
    }

    /// The item drawn as the summary card (K2): the newest agent message, when nothing but tool lines and notices follow
    /// it (a later message of the user's means the agent has not answered yet).
    static func card(_ thread: WatchThread) -> String? {
        guard let index = thread.items.lastIndex(where: { $0.kind == .agent }) else { return nil }
        let after = thread.items[thread.items.index(after: index)...]
        return after.contains(where: { $0.kind == .user }) ? nil : thread.items[index].id
    }

    /// Where the page opens: the first approval or question (its top), else the summary card (its top, so Reply shows
    /// under it), else the newest item (its bottom).
    static func anchor(_ thread: WatchThread) -> (id: String, top: Bool)? {
        if let approval = thread.approvals.first { return (approval.id, true) }
        if let question = thread.questions.first { return (question.id, true) }
        if let card = card(thread), thread.items.last?.id == card || !thread.working { return (card, true) }
        return thread.items.last.map { ($0.id, false) }
    }

    /// The failure lines: the watch's (the request or action that failed), then the phone's own (`thread.failure`),
    /// once each.
    static func failures(thread: WatchThread, failure: WatchFailure?) -> [String] {
        var lines: [String] = []
        for message in [failure?.message, thread.failure] {
            if let message, !message.isEmpty, !lines.contains(message) { lines.append(message) }
        }
        return lines
    }
}

/// A reply on its way to the confirm screen.
struct ReplyDraft: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// Into the running turn (Steer) rather than routed as a message.
    let steer: Bool
}

/// K5: what was dictated or typed, in the user's pink bubble, with where it goes, then Send and Cancel. The system's
/// dictation (the mockup's waveform) comes before it; nothing is sent until Send.
struct ReplyConfirmScreen: View {
    let draft: ReplyDraft
    var route: String?
    let send: () -> Void

    var body: some View {
        NavigationStack {
            ReplyConfirmContent(draft: draft, route: route, send: send)
                .navigationTitle(draft.steer ? "Steer" : "Reply")
        }
    }
}

/// The confirm screen's content, without its stack (the tests draw it).
struct ReplyConfirmContent: View {
    let draft: ReplyDraft
    var route: String?
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(draft.text)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(AgentsColor.pink.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("Your reply: " + draft.text)
                if let line = draft.steer ? "Steers the running turn" : route {
                    Text(line).font(.caption2).foregroundStyle(AgentsColor.pink)
                }
                Button {
                    send()
                    dismiss()
                } label: {
                    CapsuleLabel(title: draft.steer ? "Steer" : "Send", symbol: "arrow.up", style: .accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(draft.steer ? "Steer" : "Send")
                Button { dismiss() } label: { CapsuleLabel(title: "Cancel") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel")
            }
            .padding(.horizontal, 2)
        }
    }
}

/// K2: the newest agent message in its bubble with what the turn did under it ("5 steps in 1m 26s · 4 files +61 −9",
/// the counts green and red); an older phone's caption when it sent no summary.
struct ThreadSummaryCard: View {
    let item: WatchItem
    var agent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ThreadBubble(side: .agent) { Text(item.text) }
            if let summary = item.summary {
                Self.footnote(summary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            } else if let caption = item.caption {
                Text(caption).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ThreadItemRow.accessibilityLabel(item, agent: agent))
    }

    /// "5 steps in 1m 26s", then " · 4 files" and the line counts when its patches changed files.
    static func words(_ summary: WatchTurnSummary) -> String {
        var text = "\(summary.steps) \(summary.steps == 1 ? "step" : "steps")"
        if let seconds = summary.seconds { text += " in " + WatchTime.elapsed(seconds) }
        if summary.files > 0 { text += " · \(summary.files) \(summary.files == 1 ? "file" : "files")" }
        return text
    }

    static func footnote(_ summary: WatchTurnSummary) -> Text {
        guard summary.files > 0 || summary.additions + summary.deletions > 0 else { return Text(words(summary)) }
        let added = Text("+\(summary.additions)").foregroundStyle(AgentsColor.added)
        let removed = Text("−\(summary.deletions)").foregroundStyle(AgentsColor.destructive)
        return Text("\(words(summary)) \(added) \(removed)")
    }
}

/// The thread's top: the agent's glyph with the agent and model ("Claude Code · opus-5.5"), why input waits (paused,
/// offline, attaching), and the phone's notes.
struct ThreadHeader: View {
    let thread: WatchThread
    /// The agent's key or label, for the glyph.
    var agent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let detail = Self.detail(thread) {
                HStack(spacing: 5) {
                    AgentGlyph(agent: agent ?? thread.agent, size: 12)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let status = Self.status(thread) {
                Text(status).font(.footnote).foregroundStyle(AgentsColor.working)
            }
            ForEach(Array(thread.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    static func detail(_ thread: WatchThread) -> String? {
        let parts = [thread.agent, thread.model].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Why the conversation does not take input now, in the phone's words where it sent them.
    static func status(_ thread: WatchThread) -> String? {
        let reason = thread.reason?.isEmpty == false ? thread.reason : nil
        switch thread.phase {
        case .live: return nil
        case .opening: return "Attaching…"
        case .paused: return reason ?? "Paused"
        case .offline: return reason ?? "Offline"
        case .unknown: return reason
        }
    }
}

/// A tappable row's height: the list's own minimum is off for the bubbles, so its buttons keep watchOS's 44 pt here.
struct ThreadButtonRow: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
