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

    init(model: WatchModel, key: WatchConversationKey) {
        self.model = model
        self.key = key
    }

    /// Requests with an answer on its way: their chips are disabled.
    @State private var answering: Set<String> = []
    /// Failure lines the user dismissed (by message): one comes back only when a new failure says something else.
    @State private var dismissed: Set<String> = []
    @State private var question: WatchQuestion?
    @State private var scrolled = false

    var body: some View {
        let thread = model.thread(for: key)
        Group {
            if let thread {
                page(thread)
            } else {
                loading
            }
        }
        .navigationTitle(thread?.title ?? model.conversation(key)?.name ?? "")
        .toolbar {
            if thread != nil, model.loading.contains(key) {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView().accessibilityLabel("Loading")
                }
            }
        }
        .sheet(item: $question) { question in
            QuestionSheet(question: question) { answer in
                Task { await model.answer(key, question: question, answer) }
            }
        }
        .task { await model.open(key) }
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
        return ScrollViewReader { proxy in
            List {
                ThreadHeader(thread: thread)
                    .listRowBackground(Color.clear)
                if thread.earlier {
                    Text("Earlier messages are on your iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                ForEach(thread.items) { item in
                    ThreadItemRow(item: item, agent: thread.agent)
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
                    ApprovalCard(approval: approval).modifier(BareRow()).id(approval.id)
                    ForEach(approval.choices) { choice in
                        ApprovalChoiceButton(choice: choice, busy: answering.contains(approval.id)) {
                            answer(approval, choice)
                        }
                    }
                }
                ForEach(thread.questions) { question in
                    QuestionCard(question: question).modifier(BareRow()).id(question.id)
                    Button { self.question = question } label: {
                        Text(question.answerable ? "Answer" : "Open").modifier(ThreadButtonRow())
                    }
                        .font(.headline)
                        .foregroundStyle(AgentsColor.onPink)
                        .listRowBackground(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(AgentsColor.pink))
                        .disabled(answering.contains(question.id))
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
                            Button { Task { await model.resume(key) } } label: {
                                Label("Resume", systemImage: "play.fill").modifier(ThreadButtonRow())
                            }
                            .accessibilityHint("Sends the queued messages again")
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
            // Bubbles and step lines are as tall as their text; buttons keep 44 pt themselves (`ThreadButtonRow`).
            .environment(\.defaultMinListRowHeight, 0)
            .onAppear { scroll(proxy, thread) }
            .onChange(of: thread.items.last?.id) { scrolled = false; scroll(proxy, thread) }
        }
    }

    @ViewBuilder private func composer(_ thread: WatchThread, queued: Int) -> some View {
        Group {
            if thread.canStop {
                Button(role: .destructive) {
                    Task { await model.stop(key) }
                } label: {
                    Label("Stop", systemImage: "stop.fill").modifier(ThreadButtonRow())
                }
                .accessibilityHint("Stops the agent; queued messages wait until Resume")
            }
            TextFieldLink(prompt: Text(ThreadComposer.prompt(route: thread.route, queued: queued))) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(ThreadComposer.title(route: thread.route, queued: queued), systemImage: "mic.fill")
                    if thread.route == .outbox {
                        Text("Queued on your iPhone").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .modifier(ThreadButtonRow())
            } onSubmit: { text in
                Task { await model.send(key, text: text) }
            }
            if ThreadComposer.canSteer(thread) {
                TextFieldLink(prompt: Text("Steer the agent…")) {
                    Label("Steer", systemImage: "arrow.turn.down.right").modifier(ThreadButtonRow())
                } onSubmit: { text in
                    Task { await model.send(key, text: text, steer: true) }
                }
                .accessibilityHint("Sends into the running turn instead of queueing")
            }
        }
    }

    private func answer(_ approval: WatchApproval, _ choice: WatchChoice) {
        guard answering.insert(approval.id).inserted else { return }
        Task {
            await model.answer(key, approval: approval, choice: choice)
            answering.remove(approval.id)
        }
    }

    /// Once per page: to the first request waiting, else the newest item.
    private func scroll(_ proxy: ScrollViewProxy, _ thread: WatchThread) {
        guard !scrolled, let target = Self.anchor(thread) else { return }
        scrolled = true
        proxy.scrollTo(target.id, anchor: target.top ? .top : .bottom)
    }

    /// Where the page opens: the first approval or question (its top), else the newest item (its bottom).
    static func anchor(_ thread: WatchThread) -> (id: String, top: Bool)? {
        if let approval = thread.approvals.first { return (approval.id, true) }
        if let question = thread.questions.first { return (question.id, true) }
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

/// The thread's top: the agent and model ("Claude Code · opus-5.5"), why input waits (paused, offline, attaching), and
/// the phone's notes.
struct ThreadHeader: View {
    let thread: WatchThread

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let detail = Self.detail(thread) {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
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

/// A bubble's row: no platter, tight insets, so the thread reads as a conversation, not a list.
private struct BareRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2))
    }
}
