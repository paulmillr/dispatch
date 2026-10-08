import SwiftUI

struct ChatQuestionForm: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var draft: ClaudeQuestionDraft
    /// The asking agent's name as reported (helper launch label or legacy adapter title).
    var agent = "Claude Code"
    let submit: ([String: String]) -> Void
    let skip: () -> Void
    var openTerminal: (() -> Void)? = nil
    var scrollAnswers = false
    @FocusState private var customFocused: Bool
    @State private var choiceFocused: String?
    @FocusState private var formFocused: Bool
    private var question: ClaudeQuestions.Question { draft.question }
    private var index: Int { draft.index }
    private var questions: ClaudeQuestions { draft.questionnaire }
    private var answers: [String: String] { draft.answers }
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
                    Button("Next", action: draft.next).buttonStyle(ApprovalButtonStyle(primary: true)).disabled(draft.answer(question) == nil).accessibilityIdentifier("claude-question-next")
                } else {
                    Button("Send answers") { submit(answers) }.buttonStyle(ApprovalButtonStyle(primary: true))
                        .disabled(answers.count != questions.questions.count).accessibilityIdentifier("claude-question-submit")
                        .keyboardShortcut(formFocused || customFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
                Button("Skip", action: skip).buttonStyle(ApprovalButtonStyle())
                if let openTerminal { Button("Open in terminal", action: openTerminal).buttonStyle(ApprovalButtonStyle()) }
            }
        }.font(theme.typography.detail).accessibilityIdentifier("claude-question-form")
            .focusable().focused($formFocused)
            .onKeyPress(.return, phases: .down) { event in
                guard event.modifiers.contains(.command) else { return .ignored }
                if answers.count == questions.questions.count { submit(answers) }
                return .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                guard !customFocused, let choiceFocused else { return .ignored }
                draft.select(choiceFocused); return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { event in moveChoice(-1, event: event) }
            .onKeyPress(.downArrow, phases: .down) { event in moveChoice(1, event: event) }
            .task { await Task.yield(); choiceFocused = question.options.first?.label; formFocused = true }
            .onChange(of: index) { _, _ in choiceFocused = question.options.first?.label; formFocused = true }
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
                let chosen = !draft.usingCustom.contains(question.id) && draft.selected[question.id, default: []].contains(option.label)
                Button {
                    draft.select(option.label)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? theme.accent : theme.muted)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.label).foregroundStyle(theme.ink)
                            if !option.description.isEmpty { Text(option.description).foregroundStyle(theme.muted) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(9).contentShape(Rectangle())
                        .background(chosen ? theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(chosen ? theme.accent.opacity(0.5) : theme.border))
                }.buttonStyle(.plain).accessibilityLabel(option.label)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                    .accessibilityIdentifier("claude-question-option-\(index)-\(option.label)")
                if let preview = option.preview, chosen {
                    ScrollView { Text(preview).foregroundStyle(theme.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 140)
                }
            }
            TextField("Or type your own answer", text: Binding(get: { draft.custom[question.id, default: ""] }, set: { value in
                draft.type(value)
            }), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4).focused($customFocused).padding(9)
                .background(theme.window, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(draft.usingCustom.contains(question.id) ? theme.accent : theme.border))
                .accessibilityIdentifier("claude-question-custom-\(index)")
        }
    }
}
