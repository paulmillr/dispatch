import SwiftUI
import UIKit

/// A conversation's Chat segment (M4a, M3b, M4b, M4c, M5a, M5c, M5f): the link banner, the thread, the thinking row and
/// queue, and the composer. The Tabs stream's `TabScreen` draws the header above it (back pill, title, segmented
/// control); this view is its Chat content and must sit inside a `NavigationStack` (message details push, M5b).
struct ChatThreadView: View {
    @Bindable var session: MobileChatSession
    /// The space the conversation's tab lives in (M3b's "claude in app", M5b's facts and back pill).
    var space: String
    /// The conversation's tab (M5b's facts).
    var tab: String? = nil
    /// The terminal's directory (M3b's "Runs in …", paths in steps).
    var directory: String?
    /// The host's homes, for "~" in M3b's "Runs in …" (`HomePath`).
    var homes = HomePath(account: nil)
    /// The composer takes focus on appear (M3b, a new chat). In the split's detail column with a hardware keyboard it
    /// does anyway (`focusesOnAppear`).
    var focusOnAppear = false
    /// The newest result is on screen (ChatConversations.markSeen).
    var seen: () -> Void = {}
    /// Remembers models, efforts and the choice for New chat's defaults.
    var memory: ChatModelMemory?
    /// Opens with the step list unfolded (M5f) or the queue open (M5c); for previews and the demo.
    var expandSteps = false
    var expandQueue = false

    @State private var workingExpanded = false
    @State private var queueExpanded = false
    @State private var details: ChatThreadRow?
    @State private var step: ChatStep?
    @State private var settings = false
    @State private var column: CGFloat = 370
    @FocusState private var focused: Bool
    /// The software keyboard floats (an iPad): the composer stays at the bottom (`MobileKeyboardReader`).
    @State private var floatingKeyboard = false
    @Environment(\.tabsSplitDetail) private var splitDetail
    @ScaledMetric(relativeTo: .callout) private var measure = ChatMeasure.standard

    /// Whether the composer takes focus when the thread appears: when asked (a new chat, M3b), or when the tab opens in
    /// the split's detail column while a hardware keyboard is attached, so typing goes straight to the agent as on the
    /// Mac. A touch-only iPad gets no software keyboard it did not ask for, and a phone's stack is unchanged.
    static func focusesOnAppear(requested: Bool, splitDetail: Bool, hardwareKeyboard: Bool) -> Bool {
        requested || (splitDetail && hardwareKeyboard)
    }

    private var multiline: Binding<Bool> {
        Binding(get: { session.drafts.current.multiline }, set: { session.drafts.edit(multiline: $0) })
    }

    private var draft: Binding<String> {
        Binding(get: { session.drafts.current.text }, set: { session.drafts.edit(text: $0, fromEditor: true) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatLinkBanner(link: session.link, host: session.hostName, problem: session.linkProblem)
            ScrollView {
                VStack(spacing: 8) {
                    transcript
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, session.working ? 4 : 12)
                if session.working {
                    ChatWorkingRow(session: session, directory: directory, expanded: $workingExpanded) { step = $0 }
                }
                if session.phase == .verified, !session.queueRows.isEmpty {
                    ChatQueueCard(session: session, expanded: $queueExpanded)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 32 }) { column = $0 }
            .environment(\.chatColumnWidth, column)
            .environment(\.chatMeasure, measure)
            CodeComposer(text: draft, placeholder: placeholder, working: session.working && session.phase == .verified,
                         stopping: session.stopping, focus: $focused,
                         send: { session.send() },
                         steer: session.working ? { session.send(steer: true) } : nil,
                         stop: { session.stop() },
                         dictationOwner: ObjectIdentifier(session), multiline: multiline)
        }
        .background(Color.canvas)
        // A floating keyboard sits over the thread, as the terminal's capsule leaves it: SwiftUI's inset for it lifted
        // the composer part of the way, under the keyboard. The user moves the keyboard; a docked one still raises it.
        .ignoresSafeArea(.keyboard, edges: floatingKeyboard ? .bottom : [])
        .background {
            if UIDevice.current.userInterfaceIdiom == .pad {
                MobileKeyboardReader { floatingKeyboard = $0 == .floating }
            }
        }
        .onAppear {
            if Self.focusesOnAppear(requested: focusOnAppear, splitDetail: splitDetail,
                                    hardwareKeyboard: HardwareKeyboard.shared.attached) { focused = true }
            if expandSteps { workingExpanded = true }
            if expandQueue { queueExpanded = true }
            seen()
        }
        .onChange(of: session.transcript.lastActivity) { _, _ in seen() }
        .onChange(of: session.working) { _, working in if !working { workingExpanded = false } }
        .navigationDestination(item: $details) { row in
            ChatMessageDetails(session: session, row: row, space: space, tab: tab, directory: directory) { step = $0 }
        }
        .sheet(item: $step) { step in
            ChatStepOutputSheet(session: session, step: step)
        }
        .sheet(isPresented: $settings) {
            ChatSettingsSheet(session: session, memory: memory)
        }
    }

    /// The composer's hint (M4a, M4c, M5a, M5c).
    private var placeholder: String {
        if session.route(steer: false) == .outbox { return "Queue a message…" }
        if !session.queueRows.isEmpty { return "Queue another…" }
        return session.working ? "Queue a message…" : "Message"
    }

    @ViewBuilder private var transcript: some View {
        if session.hasEarlier {
            Group {
                if let error = session.earlierError {
                    Button("Load earlier messages") { session.loadEarlier() }
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().onAppear { session.loadEarlier() }
                }
            }
            .frame(maxWidth: .infinity)
        }
        if session.loadingHistory && session.transcript.isEmpty {
            ProgressView("Loading conversation…")
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if session.transcript.isEmpty, session.optimisticPrompt == nil, session.queueRows.isEmpty, session.approvals.isEmpty {
            ChatIntro(session: session, space: space, directory: directory, homes: homes) { settings = true }
        }
        ForEach(entries) { entry in
            switch entry {
            case .row(let row): rowView(row)
            case .approval(let approval):
                if approval.pending.questions != nil {
                    ChatQuestionFormView(approval: approval) { session.answer(approval, answers: $0) }
                } else {
                    ChatApprovalView(approval: approval) { session.answer(approval, with: $0) }
                }
            }
        }
        if let prompt = session.optimisticPrompt {
            ChatBubble(side: .user) { Text(prompt.text) }
                .id(prompt.id)
        }
        ForEach(session.questions) { question in
            ChatSideQuestionView(question: question) { session.answer(question, skip: $0) }
        }
        if session.phase != .verified {
            ChatQueuedBubbles(session: session)
        }
        notices
    }

    @ViewBuilder private func rowView(_ row: ChatThreadRow) -> some View {
        switch row.kind {
        case .user:
            ChatBubble(side: .user) { Text(row.item.text) }
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text } }
        case .agent(let summary):
            VStack(spacing: 5) {
                ChatBubble(side: .agent) { MobileChatMarkdownView(text: row.item.text) }
                    .environment(\.openURL, MobileChatMarkdown.openURL)
                    .onTapGesture { details = row }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text }
                        Button("Reply", systemImage: "arrowshape.turn.up.left") {
                            let quote = row.item.text.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
                            session.drafts.edit(text: quote + "\n\n" + session.drafts.current.text)
                            focused = true
                        }
                    }
                if let caption = summary?.caption {
                    ChatCaption(text: caption)
                        // A 44 point target for the 12 point line; the outer padding gives the room back.
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                        .onTapGesture { details = row }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows the steps")
                        .padding(.vertical, -14)
                }
            }
        case .thinking:
            // Claude's thinking, inline and muted as the Mac shows it (not a bubble, never collapsed).
            MobileChatMarkdownView(text: row.item.text, muted: true)
                .font(.footnote)
                .padding(.horizontal, 14)
                .frame(maxWidth: measure, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.item.text } }
        case .notice:
            Text(row.item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var notices: some View {
        if session.needsHookTrust, session.phase == .verified {
            ChatNote(text: "Codex sends approvals here only after you pick Trust all under “Hooks need review” in its terminal. Until then they wait in the Terminal tab.")
        }
        if session.phase == .verified, !session.terminalAttached {
            ChatNote(text: "Attaching the terminal… messages wait in the queue until it shows.")
        }
        if case .paused(let reason) = session.phase {
            ChatNote(text: reason)
        }
        if let result = session.commandResult {
            ChatNote(text: result.title + (result.text.isEmpty ? "" : "\n" + result.text))
                .onTapGesture { session.commandResult = nil }
        }
        if let failure = session.failure {
            ChatNote(text: failure)
                .onTapGesture { session.failure = nil }
        }
    }

    /// The thread in order: rows, with each approval after the turn that holds its tool call (the Mac's placement),
    /// else after the turn that was last when it arrived, else at the end. A pending one stays last, where it is answered;
    /// a decided one whose turn is not loaded waits for that earlier history instead of sitting at the end.
    private var entries: [Entry] {
        let rows = session.transcript.rows
        var placed: [String: [MobileChatSession.Approval]] = [:]
        var unplaced: [MobileChatSession.Approval] = []
        let turns = session.transcript.turns
        for approval in session.approvals {
            let owner = approval.pending.turnID.flatMap { id in turns.contains { $0.id == id } ? id : nil }
                ?? approval.pending.toolItemID.flatMap { item in turns.first { $0.items.contains { $0.id == item } }?.id }
            if let owner, rows.contains(where: { $0.turnID == owner }) { placed[owner, default: []].append(approval) }
            else if !approval.pending.pending, let anchor = approval.anchor, rows.contains(where: { $0.turnID == anchor }) {
                placed[anchor, default: []].append(approval)
            } else if !approval.pending.pending, approval.anchor != nil {
                continue
            } else { unplaced.append(approval) }
        }
        var result: [Entry] = []
        for (index, row) in rows.enumerated() {
            result.append(.row(row))
            if index == rows.count - 1 || rows[index + 1].turnID != row.turnID {
                result += (placed.removeValue(forKey: row.turnID) ?? []).map(Entry.approval)
            }
        }
        return result + unplaced.map(Entry.approval)
    }

    private enum Entry: Identifiable {
        case row(ChatThreadRow)
        case approval(MobileChatSession.Approval)
        var id: String {
            switch self { case .row(let row): row.id; case .approval(let approval): "approval-" + approval.id.uuidString }
        }
    }
}

/// A small centred note in the thread (paused input, hints, failures).
struct ChatNote: View {
    let text: String
    @Environment(\.chatMeasure) private var measure
    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(Color.faintFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            // Centred at the readable measure in a wide column.
            .frame(maxWidth: measure)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }
}

/// M3b: a fresh chat shows who you are talking to and the settings this turn will use, as a line that opens the pickers.
struct ChatIntro: View {
    let session: MobileChatSession
    let space: String
    let directory: String?
    var homes = HomePath(account: nil)
    let pick: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.bubbleAgent, in: Circle())
                .accessibilityHidden(true)
            Text("\(session.agentKey ?? "Agent") in \(space)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Button(action: pick) {
                HStack(spacing: 5) {
                    Text([session.modelLabel ?? session.model, session.effort].compactMap { $0 }.joined(separator: " · ")
                        .nilIfEmpty ?? "Model and effort")
                    Text("›").font(.subheadline).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .scaledFont(14, relativeTo: .subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 13)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -13)
            .accessibilityHint("Chooses the model and effort")
            .disabled(session.phase != .verified)
            if let directory {
                (Text("Runs in ") + Text(homes.abbreviate(directory)).font(.footnote.monospaced())
                    + Text(" on \(session.hostName) with the tools the space allows."))
                    .scaledFont(14, relativeTo: .subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
    }
}
