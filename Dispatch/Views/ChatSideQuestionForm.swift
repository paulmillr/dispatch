import SwiftUI

struct ChatSideQuestionForm: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var request: ChatSideQuestion
    /// The asking agent's name, as the helper reports it.
    var agent = "Codex"
    let submit: (_ skip: Bool) -> Void
    @FocusState private var customFocused: Bool
    @State private var choiceFocused: String?
    @FocusState private var formFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(agent) has a question", systemImage: "questionmark.bubble")
                    .foregroundStyle(theme.accent)
                Spacer()
                Text("\(request.index + 1) of \(request.questions.count)").foregroundStyle(theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(request.question.question).font(theme.typography.body).textSelection(.enabled)
                    ForEach(request.question.options ?? []) { option in
                        choice(option)
                    }
                    if request.question.allowsCustom {
                        Group {
                            if request.question.isSecret {
                                SecureField("Your answer", text: answerBinding)
                            } else {
                                TextField("Your own answer…", text: answerBinding, axis: .vertical).lineLimit(1...4)
                            }
                        }.textFieldStyle(.plain).focused($customFocused).padding(9).chatPanel()
                            .accessibilityIdentifier("chat-side-question-custom")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.id(request.question.id)
            if let error = request.submissionError {
                Text(error).foregroundStyle(theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat-side-question-error")
            }
            HStack(spacing: 10) {
                if request.index > 0 { Button("Back") { request.index -= 1 } }
                if request.index + 1 < request.questions.count {
                    Button("Next") { request.index += 1 }.disabled(request.answer(request.question) == nil)
                } else {
                    Button("Send answers") { submit(false) }.disabled(!request.complete)
                        .accessibilityIdentifier("chat-side-question-submit")
                        .keyboardShortcut(formFocused || customFocused ? KeyboardShortcut(.return, modifiers: .command) : nil)
                }
                Button("Skip") { submit(true) }
                if request.submitted { ProgressView().controlSize(.mini) }
            }.buttonStyle(ApprovalButtonStyle())
        }.font(theme.typography.detail).padding(10).chatPanel()
            .disabled(request.submitted || request.submissionUncertain)
            .focusable().focused($formFocused)
            .onChange(of: request.index) { _, _ in restoreFocus() }
            .task { await Task.yield(); restoreFocus() }
            .onKeyPress(.return, phases: .down) { event in
                guard event.modifiers.contains(.command) else { return .ignored }
                if request.complete && !request.submitted { submit(false) }
                return .handled
            }
            .onKeyPress(.space, phases: .down) { _ in
                guard !customFocused, let choiceFocused else { return .ignored }
                request.select(choiceFocused); return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { event in moveChoice(-1, event: event) }
            .onKeyPress(.downArrow, phases: .down) { event in moveChoice(1, event: event) }
            .accessibilityIdentifier("chat-side-question-form")
    }

    private func restoreFocus() {
        choiceFocused = request.question.options?.first?.label
        customFocused = choiceFocused == nil
        formFocused = choiceFocused != nil
    }
    private func moveChoice(_ delta: Int, event: KeyPress) -> KeyPress.Result {
        guard !customFocused, event.modifiers.isEmpty, let options = request.question.options, !options.isEmpty else { return .ignored }
        let index = options.firstIndex { $0.label == choiceFocused } ?? 0
        choiceFocused = options[max(0, min(options.count - 1, index + delta))].label
        if let choiceFocused { request.select(choiceFocused) }
        return .handled
    }

    private func choice(_ option: ChatSideQuestion.Option) -> some View {
        let chosen = !request.usingCustom.contains(request.question.id)
            && (request.selections[request.question.id]?.contains(option.label)
                ?? (request.selected[request.question.id] == option.label))
        return Button { request.select(option.label) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? theme.accent : theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label).foregroundStyle(theme.ink)
                    Text(option.description).foregroundStyle(theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(8).contentShape(Rectangle()).chatPanel()
        }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var answerBinding: Binding<String> {
        Binding(get: { request.custom[request.question.id, default: ""] }, set: { request.type($0) })
    }
}
