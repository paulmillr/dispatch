import SwiftUI

/// iMessage's bubble (M4a, L2a): the user on the right in pink (the app tint with dark text in dark, a deeper pink with
/// white text in light), the agent on the left in grey; 20 pt corners with a 6 pt one at the speaker's side. Text only.
struct ChatBubble<Content: View>: View {
    enum Side { case user, agent }
    let side: Side
    var faded = false
    @ViewBuilder var content: Content
    @Environment(\.chatColumnWidth) private var column

    var body: some View {
        HStack(spacing: 0) {
            if side == .user { Spacer(minLength: 0) }
            content
                .font(.callout)
                .lineSpacing(2)
                .foregroundStyle(side == .user ? Color.bubbleUserText : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(side == .user ? Color.bubbleUser.opacity(faded ? 0.55 : 1) : Color.bubbleAgent,
                            in: UnevenRoundedRectangle(cornerRadii: side == .user
                                ? .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20)
                                : .init(topLeading: 20, bottomLeading: 6, bottomTrailing: 20, topTrailing: 20),
                                style: .continuous))
                // 78% of the column for the user, 86% for the agent (M4a); the bubble hugs shorter text.
                .frame(maxWidth: column * (side == .user ? 0.78 : 0.86), alignment: side == .user ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if side == .agent { Spacer(minLength: 0) }
        }
    }
}

extension EnvironmentValues {
    /// The thread's text column (the screen less 16 pt each side), which bubble widths are a share of.
    @Entry var chatColumnWidth: CGFloat = 370
}

/// The line under a bubble where iMessage puts "Delivered" (12 pt, the tertiary label: 30 % in both schemes, L2a).
struct ChatCaption: View {
    let text: String
    var trailing = false
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color(uiColor: .tertiaryLabel))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// M4b: the agent asks in an ordinary bubble with the operation as a mono block; the answers are quick-reply chips on
/// the user's side. A chip sends its answer and becomes the user's reply; the caption counts the wait.
struct ChatApprovalView: View {
    let approval: MobileChatSession.Approval
    let answer: (ApprovalChoice) -> Void

    var body: some View {
        let presentation = approval.interaction.approvalPresentation
        VStack(spacing: 5) {
            ChatBubble(side: .agent) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.text)
                    if let code = presentation.code {
                        Text(code)
                            .font(.footnote.monospaced())
                            .lineSpacing(2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.approvalCode, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }
            if approval.pending.pending {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ChatCaption(text: "Waiting · " + ChatTurnSummary.elapsed(context.date.timeIntervalSince(approval.arrived)))
                }
                ChatChips(choices: MobileChatSession.choices(for: approval.interaction), choose: answer)
                    .padding(.top, 2)
            } else if let chosen = approval.chosen {
                ChatBubble(side: .user) { Text(chosen.label) }
                    .padding(.top, 3)
            } else if approval.pending.decision == .expired {
                ChatCaption(text: "No longer waiting · continue in Terminal if it still asks")
            }
        }
    }
}

/// Quick-reply chips, right-aligned and wrapping onto more lines when they do not fit (large text): grey glass, the
/// affirmative one in the app tint.
struct ChatChips: View {
    let choices: [ApprovalChoice]
    let choose: (ApprovalChoice) -> Void
    var body: some View {
        ChatChipFlow {
            ForEach(choices) { choice in
                ChatChip(title: choice.label, prominent: choice.role == .allow,
                         hint: "Answers the agent’s request") { choose(choice) }
            }
        }
    }
}

struct ChatChip: View {
    let title: String
    var prominent = false
    var selected = false
    /// VoiceOver's hint: what choosing the chip does.
    var hint: String? = nil
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .multilineTextAlignment(.center)
                .foregroundStyle(prominent || selected ? Color.onAccent : Color.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minHeight: 36)
                .background {
                    if prominent || selected {
                        Capsule().fill(Color.dispatchPink)
                    } else {
                        Capsule().fill(Color.chipFill)
                            .overlay(Capsule().strokeBorder(Color.chipBorder, lineWidth: 0.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A question form from a helper interaction (`ClaudeQuestions`): the question in the agent's bubble, its options as
/// chips on the user's side, one question at a time; Submit sends the answers, Skip declines.
struct ChatQuestionFormView: View {
    let approval: MobileChatSession.Approval
    let submit: ([String: String]?) -> Void

    var body: some View {
        if let draft = approval.pending.questionDraft {
            let question = draft.question
            let answered = draft.answer(question) != nil
            let last = draft.questionnaire.questions.last?.id == question.id
            VStack(spacing: 6) {
                ChatBubble(side: .agent) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !question.header.isEmpty {
                            Text(question.header).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text(question.text)
                    }
                }
                if approval.pending.pending {
                    ChatChipFlow {
                        ForEach(question.options) { option in
                            ChatChip(title: option.label, selected: draft.answer(question)?.components(separatedBy: ", ").contains(option.label) == true,
                                     hint: "Selects this answer") {
                                draft.select(option.label)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        ChatChip(title: "Skip") { submit(nil) }
                        ChatChip(title: last ? "Send" : "Next", prominent: answered) {
                            if last { submit(draft.answers) } else { draft.next() }
                        }
                        .disabled(!answered)
                    }
                } else if let answers = approval.pending.answers {
                    ChatBubble(side: .user) { Text(answers.values.sorted().joined(separator: "\n")) }
                } else {
                    ChatCaption(text: approval.pending.decision == .deny ? "Skipped" : "No longer waiting", trailing: true)
                }
            }
        }
    }
}

/// A side question (`ChatSideQuestion`): options as chips or a typed answer; Send or Skip.
struct ChatSideQuestionView: View {
    @Bindable var question: ChatSideQuestion
    let submit: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ChatBubble(side: .agent) {
                VStack(alignment: .leading, spacing: 4) {
                    if !question.question.header.isEmpty {
                        Text(question.question.header).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(question.question.question)
                }
            }
            if let options = question.question.options, !options.isEmpty {
                ChatChipFlow {
                    ForEach(options) { option in
                        ChatChip(title: option.label, selected: question.answer(question.question)?.components(separatedBy: ", ").contains(option.label) == true,
                                 hint: "Selects this answer") {
                            question.select(option.label)
                        }
                    }
                }
            }
            if question.question.allowsCustom {
                Group {
                    if question.question.isSecret {
                        SecureField("Answer", text: Binding(get: { question.custom[question.question.id] ?? "" }, set: { question.type($0) }))
                    } else {
                        TextField("Answer", text: Binding(get: { question.custom[question.question.id] ?? "" }, set: { question.type($0) }), axis: .vertical)
                    }
                }
                .textFieldStyle(.roundedBorder)
            }
            if let error = question.submissionError { ChatCaption(text: error, trailing: true) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if question.index > 0 { ChatChip(title: "Back") { question.index -= 1 } }
                ChatChip(title: "Skip") { submit(true) }
                if question.index + 1 < question.questions.count {
                    ChatChip(title: "Next", prominent: question.answer(question.question) != nil) { question.index += 1 }
                } else {
                    ChatChip(title: "Send", prominent: question.complete) { submit(false) }.disabled(!question.complete)
                }
            }
            .disabled(question.submitted)
        }
    }
}

/// Chips that wrap onto more lines, aligned to the user's side.
struct ChatChipFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.maxX - row.width
            for index in row.items {
                let proposal = Self.proposal(subviews[index], width: bounds.width)
                let size = subviews[index].sizeThatFits(proposal)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: proposal)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    /// A chip as wide as it likes, or the row's width when that is less (it wraps its title then).
    private static func proposal(_ subview: LayoutSubview, width: CGFloat) -> ProposedViewSize {
        subview.sizeThatFits(.unspecified).width > width ? ProposedViewSize(width: width, height: nil) : .unspecified
    }
    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(Self.proposal(subview, width: width))
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1].items.append(index)
                rows[rows.count - 1].width += spacing + size.width
                rows[rows.count - 1].height = max(last.height, size.height)
            } else { rows.append(([index], size.width, size.height)) }
        }
        return rows
    }
}
