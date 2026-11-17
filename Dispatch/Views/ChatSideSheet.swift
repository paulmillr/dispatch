import SwiftUI

struct ChatSideSheet: View {
    @Environment(\.chatTheme) private var theme
    @MotionReduced private var reduceMotion
    @Bindable var side: ChatSideConversation
    let close: () -> Void
    var maximumHeight: CGFloat = 360
    var shortcutsEnabled = true
    /// Esc once an answer is in (or one is coming): a second press within `ChatEscapeStop.window` closes, as Esc twice
    /// stops the agent, since closing ends the side conversation and its replies.
    @State private var escapeArmedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !side.messages.isEmpty && !side.hasQuestions { transcript }
            if let question = side.questions.first {
                ChatSideQuestionForm(request: question, agent: side.title ?? "Codex") { skip in side.answerQuestion(question, skip: skip) }
                    .frame(maxHeight: .infinity)
            }
            if side.busy {
                HStack(spacing: 8) {
                    if !side.waitingForAnswer { ProgressView().controlSize(.mini) }
                    Text(side.waitingForAnswer ? "waiting for your answer" : side.ready ? "thinking" : "opening side conversation…")
                        .foregroundStyle(theme.muted)
                }.font(theme.typography.detail).fixedSize(horizontal: false, vertical: true)
            }
            if let failure = side.failure {
                Text(failure).font(theme.typography.detail).foregroundStyle(theme.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let permission = side.permission {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(permission.title, systemImage: "diamond.fill").foregroundStyle(theme.accent)
                        ChatCodeBlock(code: permission.operation, language: permission.language, title: "Requested operation")
                        HStack {
                            Button { side.resolvePermission(true) } label: { ApprovalKeyLabel(title: "Allow Once", key: shortcutsEnabled ? "⇧⌘⏎" : nil) }
                                .accessibilityLabel("Allow Once")
                            Button { side.resolvePermission(false) } label: { ApprovalKeyLabel(title: "Deny", key: shortcutsEnabled ? "⇧⌘⌫" : nil) }
                                .accessibilityLabel("Deny")
                        }.buttonStyle(ApprovalButtonStyle())
                    }.font(theme.typography.detail).padding(10).chatPanel()
                }.scrollBounceBehavior(.basedOnSize)
            }
            if side.hasQuestions { modelReadout }
            else { composer }
        }
        .padding(12)
        .frame(maxHeight: maximumHeight)
        .background(theme.terminal, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.muted.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
        .font(theme.typography.body).foregroundStyle(theme.ink)
        .onExitCommand { escape() }
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: side.messages.map(\.id))
        .accessibilityIdentifier("chat-side-sheet")
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                badge
                permissions
                Spacer(minLength: 8)
                back
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { badge; Spacer(minLength: 8); back }
                permissions
            }
        }.font(theme.typography.detail).fixedSize(horizontal: false, vertical: true)
            .help("Side conversation · kept out of the main thread")
    }

    private var permissions: some View {
        Text(side.mode.readOnly ? "read-only" : "full permissions").foregroundStyle(theme.muted)
    }

    private var transcript: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(side.messages) { message in
                            messageView(message, width: max(0, geometry.size.width - 2))
                                .id(message.id)
                                .transition(reduceMotion ? .opacity : .offset(y: 4).combined(with: .opacity))
                        }
                        Color.clear.frame(height: 1).id("side-bottom")
                    }.padding(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .defaultScrollAnchor(.bottom)
                .onChange(of: side.messages.last?.text) { _, _ in proxy.scrollTo("side-bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func messageView(_ message: ChatSideConversation.Message, width: CGFloat) -> some View {
        if message.user {
            ChatUserMessage(text: message.text, contentWidth: width)
        } else {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 3,
                                               bottomTrailingRadius: 10, topTrailingRadius: 10)
            ChatMarkdown(text: message.text)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: min(width, theme.typography.characterWidth * 80), alignment: .leading)
                .background(theme.sidebar, in: shape)
                .overlay { shape.strokeBorder(theme.border) }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            ChatSideComposer(side: side, focused: shortcutsEnabled && side.ready && !side.hasQuestions, close: escape)
                .id(side.id)
                .frame(height: min(max(theme.typography.replyLineHeight + 10, side.composerHeight),
                                   theme.typography.replyLineHeight * CGFloat(composerLineLimit) + 10))
            HStack(spacing: 12) {
                modelReadout.frame(maxWidth: .infinity, alignment: .leading)
                ChatReplyButton(canSubmit: side.ready && !side.busy && !side.hasQuestions
                                && !side.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                multiline: side.draftMultiline, identifier: "chat-side-send") { side.send() }
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 9)
        }.padding(.top, 4).chatPanel().fixedSize(horizontal: false, vertical: true)
    }

    private var composerLineLimit: Int {
        max(1, min(6, Int(maximumHeight * 0.25 / max(1, theme.typography.replyLineHeight))))
    }

    /// As the main composer's footer reads (ChatModelControls): the model's ID, then its effort; not choosable here.
    private var modelReadout: some View {
        Text(Self.readout(side))
            .font(theme.typography.detail).foregroundStyle(theme.muted.opacity(0.65))
            .lineLimit(1).truncationMode(.middle)
            .help(side.model + (Self.effort(side).map { " · effort: " + $0 } ?? ""))
    }

    static func readout(_ side: ChatSideConversation) -> String {
        ([ChatModelControls.label(for: side.model)] + [effort(side)].compactMap { $0 }
            + (side.steps > 0 ? ["\(side.steps) steps"] : [])).joined(separator: " · ")
    }

    private static func effort(_ side: ChatSideConversation) -> String? {
        ChatModelControls.effortLabel(side.effort, agentID: side.agentID, model: side.model, agentTitle: side.title)
    }

    private var badge: some View {
        Text("/" + side.mode.rawValue).fontWeight(.semibold).foregroundStyle(theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
    private var back: some View {
        Button(backTitle, action: close).buttonStyle(.plain).foregroundStyle(theme.muted)
            .help("Ends the side conversation; its replies are not kept")
            .background {
                // Esc, through `escape`: a click on the button closes at once, the key may need a second press.
                Button(action: escape) { Color.clear.frame(width: 0, height: 0) }
                    .buttonStyle(.plain).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    .keyboardShortcut(canCloseWithEscape ? .cancelAction : nil)
            }
            .accessibilityLabel("Back to Main")
            .accessibilityIdentifier("chat-side-close")
    }
    private var backTitle: String {
        guard canCloseWithEscape else { return "Back to Main" }
        if escapeArmedAt != nil { return "⎋ Again to Close" }
        return keepsAnswer ? "⎋⎋ Back to Main" : "⎋ Back to Main"
    }
    private var canCloseWithEscape: Bool {
        shortcutsEnabled && !side.draftMultiline && !side.composingText
    }
    /// An answer to keep, or one on its way: one Esc must not throw it away.
    private var keepsAnswer: Bool { side.busy || side.messages.contains { !$0.user } }
    /// Esc from the sheet or its composer: closes an unanswered sheet at once, an answered one on the second press.
    private func escape() {
        guard canCloseWithEscape else { return }
        let now = System.date()
        if !keepsAnswer { return close() }
        if let armed = escapeArmedAt, now.timeIntervalSince(armed) <= ChatEscapeStop.window { escapeArmedAt = nil; return close() }
        escapeArmedAt = now
        DispatchQueue.main.asyncAfter(deadline: .now() + ChatEscapeStop.window) {
            if escapeArmedAt == now { escapeArmedAt = nil }
        }
    }
}
