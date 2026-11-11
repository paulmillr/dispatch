import SwiftUI

struct ChatQuestionForm: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var draft: ClaudeQuestionDraft
    /// The asking agent's name as reported (helper launch label or legacy adapter title).
    var agent = "Claude Code"
    let submit: () -> Void
    let skip: () -> Void
    var openTerminal: (() -> Void)? = nil
    var scrollAnswers = false
    @FocusState private var customFocused: Bool
    @State private var choiceFocused: String?
    @FocusState private var formFocused: Bool
    private var question: ClaudeQuestions.Question { draft.question }
    private var index: Int { draft.index }
    private var questions: ClaudeQuestions { draft.questionnaire }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(agent) has a question", systemImage: "questionmark.bubble").foregroundStyle(theme.accent)
                Spacer()
                Text("\(index + 1) of \(questions.questions.count)").foregroundStyle(theme.muted)
            }
            if scrollAnswers { ScrollView { answerFields }.id(question.id) }
            else { answerFields }
            HStack(spacing: 8) {
                if index > 0 { Button("Back", action: draft.back).buttonStyle(ApprovalButtonStyle()).accessibilityIdentifier("claude-question-back") }
                if index + 1 < questions.questions.count {
                    Button { draft.next() } label: { ApprovalKeyLabel(title: "Next", key: keys ? "⏎" : nil) }
                        .buttonStyle(ApprovalButtonStyle(primary: true)).disabled(draft.answer(question) == nil)
                        .accessibilityLabel("Next").accessibilityIdentifier("claude-question-next")
                } else {
                    Button { submit() } label: { ApprovalKeyLabel(title: "Send Answers", key: keys ? "⏎" : nil) }
                        .buttonStyle(ApprovalButtonStyle(primary: true))
                        .disabled(!draft.actions.canSubmit).accessibilityLabel("Send Answers").accessibilityIdentifier("claude-question-submit")
                }
                Button { skip() } label: { ApprovalKeyLabel(title: "Skip", key: keys && skipsOnEscape ? "⎋" : nil) }
                    .buttonStyle(ApprovalButtonStyle()).accessibilityLabel("Skip")
                if let openTerminal { Button("Open in Terminal", action: openTerminal).buttonStyle(ApprovalButtonStyle()) }
            }
        }.font(theme.typography.detail).accessibilityIdentifier("claude-question-form")
            .focusable().focused($formFocused)
            // Return (or ⌘⏎) is the default button: Next, then Send Answers on the last question.
            .onKeyPress(.return, phases: .down) { event in
                guard event.modifiers.isEmpty || event.modifiers == .command else { return .ignored }
                advance(); return .handled
            }
            // Esc is Skip while nothing is answered, so it never throws typed or chosen answers away.
            .onExitCommand { if skipsOnEscape { skip() } }
            .onKeyPress(.space, phases: .down) { _ in
                guard !customFocused, let choiceFocused else { return .ignored }
                draft.select(choiceFocused); return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { event in moveChoice(-1, event: event) }
            .onKeyPress(.downArrow, phases: .down) { event in moveChoice(1, event: event) }
            .task { await Task.yield(); restoreFocus() }
            .onChange(of: index) { _, _ in restoreFocus() }
    }
    /// The form has the keys (it took focus from the composer): its buttons show them.
    private var keys: Bool { formFocused || customFocused }
    private var skipsOnEscape: Bool { draft.answers.isEmpty && !draft.custom.values.contains { !$0.isEmpty } }
    private func advance() {
        if draft.actions.canGoNext { draft.next() } else if draft.actions.canSubmit { submit() }
    }
    private func restoreFocus() {
        choiceFocused = question.options.first(where: { draft.isSelected($0.label, in: question) })?.label ?? question.options.first?.label
        customFocused = false
        formFocused = true
    }
    private func moveChoice(_ delta: Int, event: KeyPress) -> KeyPress.Result {
        guard !customFocused, event.modifiers.isEmpty, !question.options.isEmpty else { return .ignored }
        let index = question.options.firstIndex { $0.label == choiceFocused } ?? 0
        choiceFocused = question.options[max(0, min(question.options.count - 1, index + delta))].label
        if !question.multiple, let choiceFocused { draft.select(choiceFocused) }
        return .handled
    }
    private var answerFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question.text).font(theme.typography.body).foregroundStyle(theme.ink).textSelection(.enabled)
            if question.multiple { Text("Choose any that apply").foregroundStyle(theme.muted) }
            ForEach(question.options) { option in
                let chosen = draft.isSelected(option.label, in: question)
                Button {
                    draft.select(option.label)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? theme.accent : theme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label).foregroundStyle(theme.ink)
                            if !option.description.isEmpty { Text(option.description).font(theme.typography.codeDetail).foregroundStyle(theme.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(9).contentShape(Rectangle())
                        .background(chosen ? theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(chosen ? theme.accent.opacity(0.5) : theme.border))
                }.buttonStyle(.plain).accessibilityLabel(option.label)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("claude-question-option-\(index)-\(option.label)")
                if let preview = option.preview, chosen {
                    ScrollView { Text(preview).font(theme.typography.codeDetail).foregroundStyle(theme.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                }
            }
            TextField("Or type your own answer", text: Binding(get: { draft.custom[question.id, default: ""] }, set: { value in
                draft.type(value)
            }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).focused($customFocused).onSubmit { advance() }.padding(9)
                .background(theme.window, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(draft.usingCustom.contains(question.id) ? theme.accent : theme.border))
                .accessibilityIdentifier("claude-question-custom-\(index)")
        }
    }
}
