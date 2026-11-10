import SwiftUI

/// One conversation: items, pending approvals/questions, queue, composer. Calls model.open(key)/close(key) on
/// appear/disappear.
///
/// One list, oldest at the top: the header (agent, model, why input waits, the phone's notes), the page's items, the
/// working line (Stop at its end), failures, then what waits for the user (approval cards with their chips, question
/// cards), the queue and the composer (Reply, Open on iPhone). It opens scrolled to the first request, else to the newest item.
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
    /// Stop was tapped on the working line: its confirmation is up.
    @State private var confirmStop = false
    /// The turn that confirmation is for (`stopKey`): it closes, and does nothing, once that turn is over.
    @State private var stopFor: String?
    /// Reply's first step is up: the quick replies and "Dictate or type".
    @State private var composing = false
    /// What that step chose: the confirm screen opens with it once its sheet is gone.
    @State private var chosen: String?
    /// A dictated or typed reply waiting for Send on the confirm screen (K5).
    @State private var reply: ReplyDraft?
    /// What "Open on iPhone" did, said under its button until the page changes.
    @State private var opened: String?
    @State private var opening = false
    @State private var scrolled = false
    /// `-DispatchWatchSheet` (Debug): a sheet to open once the page is in.
    @State private var debugSheet: WatchRouter.Sheet?
    @State private var preselect: Int?
    /// The page's turns before the newest show (the "Earlier" row expanded them).
    @State private var showEarlier = false
    /// Where the newest turn began when the page first showed: kept while the screen is open, so a reply sent from here
    /// does not put the answer just read behind "Earlier".
    @State private var newestFrom: String?

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
        .sheet(isPresented: $composing, onDismiss: {
            if let text = chosen { reply = ReplyDraft(text: text, actions: ThreadComposer.actions(model.thread(for: key))) }
            chosen = nil
        }) {
            QuickReplySheet(prompt: ThreadComposer.prompt(route: thread?.route ?? .send,
                                                          queued: thread.map { ThreadComposer.ahead($0.queue) } ?? 0)) {
                chosen = $0
            }
        }
        .sheet(item: $reply) { draft in
            // The buttons as the screen opened (no button moves under a finger); their lines say what each does now.
            ReplyConfirmScreen(draft: draft, actions: ThreadComposer.relabel(draft.actions, thread)) { steer in
                Task { await model.send(key, text: draft.text, steer: steer) }
            }
        }
        .confirmationDialog(ThreadWorkingRow.stopMessage, isPresented: $confirmStop, titleVisibility: .visible) {
            Button(ThreadWorkingRow.stopTitle(agent: model.conversation(key)?.agent ?? thread?.agent), role: .destructive) {
                // Only the turn it was asked for: a turn the queue started meanwhile is not stopped by it.
                guard Self.stopStillMeant(stopFor, model.thread(for: key)) else { return }
                Task { await model.stop(key) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task { await model.open(key) }
        .onAppear {
            debugSheet = router.takeSheet()
            presentDebugSheet()
        }
        .onChange(of: thread != nil) { presentDebugSheet() }
        .onChange(of: Self.stopKey(thread)) { _, now in
            if confirmStop, now != stopFor { confirmStop = false }
        }
        .onChange(of: question != nil || reply != nil || confirmStop || composing) { _, open in router.childSheet = open }
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
        let primary = Self.primaryAction(thread)
        return ScrollViewReader { proxy in
            List {
                ThreadHeader(thread: thread, agent: agent, cpu: model.host(key.host).flatMap(ThreadHeader.cpu))
                    .modifier(BareRow())
                let turns = Self.turns(thread, from: newestFrom)
                if !turns.earlier.isEmpty, !showEarlier {
                    Button { showEarlier = true } label: {
                        Label(Self.earlierTitle(turns.earlier.count), systemImage: "chevron.up")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .modifier(BareRow())
                    .accessibilityLabel(Self.earlierTitle(turns.earlier.count))
                    .accessibilityHint("Shows the earlier messages of this page")
                } else if thread.earlier {
                    Text("Earlier messages are on your iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .modifier(BareRow())
                }
                ForEach(showEarlier ? turns.earlier + turns.newest : turns.newest) { item in
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
                    ThreadWorkingRow(activity: thread.activity, since: thread.workingSince,
                                     stop: Self.stop(thread) { askStop(thread) })
                        .modifier(BareRow())
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
                    let layout = ApprovalCard.layout(approval.choices)
                    ApprovalCard(approval: approval, agent: agent).modifier(BareRow()).id(approval.id)
                    // Allow and Deny side by side, one row of two capsules; This session (where offered) under them.
                    if !layout.row.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(layout.row) { choice in
                                ApprovalChoiceButton(choice: choice, busy: answering.contains(approval.id)) {
                                    answer(approval, choice)
                                }
                                // Double tap: Allow on the first card.
                                .handGestureShortcut(.primaryAction,
                                                     isEnabled: primary == .allow(approval.id) && choice.role == .allow)
                            }
                        }
                        .modifier(BareRow(vertical: 3))
                    }
                    ForEach(layout.below) { choice in
                        ApprovalChoiceButton(choice: choice, busy: answering.contains(approval.id)) {
                            answer(approval, choice)
                        }
                    }
                }
                ForEach(thread.questions) { question in
                    QuestionCard(question: question).modifier(BareRow()).id(question.id)
                    CapsuleButton(title: question.answerable ? "Answer" : "Open", style: .accent,
                                  enabled: !answering.contains(question.id)) { self.question = question }
                        .handGestureShortcut(.primaryAction, isEnabled: primary == .answer(question.id))
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
                                        // A row with a status (paused, not sent) goes into the queue again: the phone's
                                        // Send; one that waits is sent now, into the turn.
                                        Button {
                                            Task { await model.sendQueuedNow(key, item: item) }
                                        } label: {
                                            Label(item.status == nil ? "Send now" : "Send",
                                                  systemImage: item.status == nil ? "arrow.up.circle" : "paperplane")
                                        }
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
                composer(thread, queued: queued.count, primary: primary == .reply)
                // watchOS 27 leaves this List's last row undrawn and out of its scroll range (the composer, before it
                // the queue's last row): an empty row takes that place.
                Color.clear.frame(height: 1)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .accessibilityHidden(true)
            }
            // Bubbles are as tall as their text; buttons keep 44 pt themselves.
            .environment(\.defaultMinListRowHeight, 0)
            .onAppear {
                if newestFrom == nil { newestFrom = Self.turns(thread).newest.first?.id }
                scroll(proxy, thread)
            }
            .onChange(of: Self.items(thread).last?.id) { scrolled = false; scroll(proxy, thread) }
        }
    }

    /// Reply (the quick replies or the system's dictation or keyboard, then the confirm screen, which carries the route: Queue or Steer now
    /// while a live agent works) and Open on iPhone; only Open on iPhone while an approval or a question waits (its
    /// chips are the answer). Stop is on the working line, not here, where a crown scroll or a flick ends.
    @ViewBuilder private func composer(_ thread: WatchThread, queued: Int, primary: Bool) -> some View {
        Group {
            if Self.offersReply(thread) {
                // The quick replies and "Dictate or type" first (`QuickReplySheet`), then the confirm screen.
                Button { composing = true } label: {
                    CapsuleLabel(title: "Reply", symbol: "mic.fill", style: .accent)
                }
                .buttonStyle(.plain)
                .handGestureShortcut(.primaryAction, isEnabled: primary)
                .modifier(BareRow(vertical: 4))
                .accessibilityLabel("Reply")
                .accessibilityHint(ThreadComposer.canSteer(thread) ? "Then queue it or steer the running turn"
                    : ThreadComposer.routeLine((thread.route, ThreadComposer.ahead(thread.queue))) ?? "Sends your message to the agent")
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

    private func askStop(_ thread: WatchThread) {
        stopFor = Self.stopKey(thread)
        confirmStop = stopFor != nil
    }

    private func presentDebugSheet() {
        guard let sheet = debugSheet, let thread = model.thread(for: key) else { return }
        debugSheet = nil
        switch sheet {
        case .question(let choose):
            preselect = choose
            question = thread.questions.first
        case .reply(let text): reply = ReplyDraft(text: text, actions: ThreadComposer.actions(thread))
        case .stop: if thread.canStop { askStop(thread) }
        case .quick: composing = ThreadScreen.offersReply(thread)
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

    /// The page's rows: its items but tools, which an older phone still sends and the phone's own thread leaves to the
    /// turn's caption.
    static func items(_ thread: WatchThread) -> [WatchItem] {
        thread.items.filter { $0.kind != .tool }
    }

    /// The page's items split at the newest turn (the one the user's newest message started; the whole page when the
    /// user wrote nothing in it): what the thread opens with, and the earlier turns behind the "Earlier" row. The page
    /// still holds what the phone sent (40 items).
    static func turns(_ thread: WatchThread, from pinned: String? = nil) -> (earlier: [WatchItem], newest: [WatchItem]) {
        let items = items(thread)
        // Kept where it began while the screen is open (a page that no longer holds it splits afresh).
        if let pinned, let start = items.firstIndex(where: { $0.id == pinned }) {
            return (Array(items[..<start]), Array(items[start...]))
        }
        guard let user = items.lastIndex(where: { $0.kind == .user }) else { return ([], items) }
        var start = user
        if let turn = items[user].turn, let first = items.firstIndex(where: { $0.turn == turn }) { start = min(first, user) }
        return (Array(items[..<start]), Array(items[start...]))
    }

    /// "Earlier · 6".
    static func earlierTitle(_ count: Int) -> String { "Earlier · \(count)" }

    /// What a double tap (`handGestureShortcut(.primaryAction)`) does on this page: Allow on the first approval card (one
    /// that offers Allow), else, as Reply is hidden while a question waits, Answer on the first question, else Reply.
    enum PrimaryAction: Equatable {
        case allow(String), answer(String), reply, none
    }

    static func primaryAction(_ thread: WatchThread) -> PrimaryAction {
        if let approval = thread.approvals.first, approval.choices.contains(where: { $0.role == .allow }) {
            return .allow(approval.id)
        }
        if let question = thread.questions.first { return .answer(question.id) }
        return offersReply(thread) ? .reply : .none
    }

    /// Reply shows unless an approval or a question waits: then the composer is Open on iPhone alone.
    static func offersReply(_ thread: WatchThread) -> Bool { thread.approvals.isEmpty && thread.questions.isEmpty }

    /// The item drawn as the summary card (K2): the newest agent message, when no message of the user's follows it (one
    /// means the agent has not answered yet).
    static func card(_ thread: WatchThread) -> String? {
        let items = items(thread)
        guard let index = items.lastIndex(where: { $0.kind == .agent }) else { return nil }
        let after = items[items.index(after: index)...]
        return after.contains(where: { $0.kind == .user }) ? nil : items[index].id
    }

    /// Where the page opens: the first approval or question (its top), else the summary card (its top, so Reply shows
    /// under it), else the newest item (its bottom).
    static func anchor(_ thread: WatchThread) -> (id: String, top: Bool)? {
        if let approval = thread.approvals.first { return (approval.id, true) }
        if let question = thread.questions.first { return (question.id, true) }
        let last = items(thread).last
        if let card = card(thread), last?.id == card || !thread.working { return (card, true) }
        return last.map { ($0.id, false) }
    }

    /// The turn Stop would stop: when it began and the user's message that started it; nil while Stop is not offered.
    static func stopKey(_ thread: WatchThread?) -> String? {
        guard let thread, thread.working, thread.canStop else { return nil }
        let since = thread.workingSince.map { String($0.timeIntervalSince1970) } ?? "-"
        return since + "|" + (items(thread).last { $0.kind == .user }?.id ?? "-")
    }

    /// The confirmation still names the running turn: it was asked for this one, and Stop is still offered.
    static func stopStillMeant(_ asked: String?, _ thread: WatchThread?) -> Bool {
        asked != nil && asked == stopKey(thread)
    }

    /// The working line's Stop: only while the phone offers it (`canStop`: a live conversation whose agent works).
    static func stop(_ thread: WatchThread, _ action: @escaping () -> Void) -> (() -> Void)? {
        thread.working && thread.canStop ? action : nil
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

/// A reply on its way to the confirm screen, with the buttons it opened with (`ThreadComposer.actions` at that moment).
struct ReplyDraft: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let actions: [ThreadComposer.ReplyAction]
}

/// K5: what was dictated or typed, in the user's pink bubble, then the route's buttons (`ThreadComposer.actions`: Queue
/// and Steer now while a live agent works, else Send), each with the line saying where the words go, and Cancel. The
/// system's dictation (the mockup's waveform) comes before it; nothing is sent until a button is tapped.
struct ReplyConfirmScreen: View {
    let draft: ReplyDraft
    let actions: [ThreadComposer.ReplyAction]
    /// The chosen action's steer.
    let send: (Bool) -> Void

    var body: some View {
        NavigationStack {
            ReplyConfirmContent(draft: draft, actions: actions, send: send)
                .navigationTitle("Reply")
        }
    }
}

/// The confirm screen's content, without its navigation stack.
struct ReplyConfirmContent: View {
    let draft: ReplyDraft
    let actions: [ThreadComposer.ReplyAction]
    let send: (Bool) -> Void

    var body: some View {
        ScrollView {
            ReplyConfirmStack(draft: draft, actions: actions, send: send)
        }
    }
}

/// The confirm screen's bubble and buttons, without its scroll view (the tests draw it: `ImageRenderer` draws no
/// `ScrollView`).
struct ReplyConfirmStack: View {
    let draft: ReplyDraft
    let actions: [ThreadComposer.ReplyAction]
    let send: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            Text(draft.text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(AgentsColor.pink.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Your reply: " + draft.text)
            ForEach(actions) { action in
                VStack(spacing: 3) {
                    Button {
                        send(action.steer)
                        dismiss()
                    } label: {
                        CapsuleLabel(title: action.title, symbol: action.symbol, style: action.style)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(action.title)
                    .accessibilityHint(action.line ?? "")
                    if let line = action.line {
                        Text(line)
                            .font(.caption2)
                            .foregroundStyle(action.style == .accent ? AgentsColor.pink : .secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityHidden(true)
                    }
                }
            }
            Button { dismiss() } label: { CapsuleLabel(title: "Cancel") }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")
        }
        .padding(.horizontal, 2)
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

    /// "5 steps in 1m 26s" (the time from 5 s, as the phone's), then " · 4 files" and the line counts when its patches
    /// changed files.
    static func words(_ summary: WatchTurnSummary) -> String {
        var text = "\(summary.steps) \(summary.steps == 1 ? "step" : "steps")"
        if let seconds = summary.seconds, seconds.rounded() >= 5 { text += " in " + WatchTime.elapsed(seconds.rounded()) }
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

/// The thread's top: the agent's glyph with the agent and model ("Claude Code · opus-5.5", then the host's CPU, a chip
/// symbol and "34%", while the agent works), why input waits (paused, offline, attaching), and the phone's notes.
struct ThreadHeader: View {
    let thread: WatchThread
    /// The agent's key or label, for the glyph.
    var agent: String?
    /// The host's CPU %, said after the model while the agent works (is it the machine or the agent?).
    var cpu: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let detail = Self.detail(thread) {
                HStack(spacing: 5) {
                    AgentGlyph(agent: agent ?? thread.agent, size: 12)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    if let load = Self.load(thread, cpu: cpu) {
                        Label(load, systemImage: "cpu")
                            .labelStyle(ThreadHeaderLoadStyle())
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityLabel("Host CPU " + load.dropLast() + " percent")
                    }
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

    /// "34%" (after the chip's symbol) while the agent works and the host has a current reading.
    static func load(_ thread: WatchThread, cpu: Double?) -> String? {
        guard thread.working, let cpu else { return nil }
        return "\(Int(cpu.rounded()))%"
    }

    /// The host's CPU for the header: a connected host's current reading only.
    static func cpu(_ host: WatchHost) -> Double? {
        guard host.state == .connected, let stats = host.stats, !stats.stale else { return nil }
        return stats.cpu
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

/// The header's CPU: the chip symbol tight before the number.
struct ThreadHeaderLoadStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A tappable row's height: the list's own minimum is off for the bubbles, so its buttons keep watchOS's 44 pt here.
struct ThreadButtonRow: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}
