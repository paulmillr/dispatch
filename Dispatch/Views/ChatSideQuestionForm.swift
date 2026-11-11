import SwiftUI

struct ChatSideQuestionForm: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var request: ChatSideQuestion
    /// The asking agent's name, as the helper reports it.
    var agent = "Codex"
    let submit: (_ skip: Bool) -> Void
    /// The main chat's question (not a side conversation's): its terminal shows the same question.
    var openTerminal: (() -> Void)? = nil
    /// Below the main chat, the panel takes only the question's height (up to its frame); in the side sheet it fills.
    var fitsContent = false
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
            if fitsContent {
                // The question's own height while it fits the frame given; a scroll view only past it.
                ViewThatFits(in: .vertical) {
                    fields
                    ScrollView { fields }.id(request.question.id)
                }
            } else {
                ScrollView { fields }.id(request.question.id)
            }
            if let error = request.submissionError {
                Text(error).foregroundStyle(theme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("chat-side-question-error")
            }
            HStack(spacing: 10) {
                if request.index > 0 { Button("Back", action: request.back) }
                if request.index + 1 < request.questions.count {
                    Button { request.next() } label: { ApprovalKeyLabel(title: "Next", key: keys ? "⏎" : nil) }
                        .disabled(!request.actions.canGoNext).accessibilityLabel("Next")
                } else {
                    Button { submit(false) } label: { ApprovalKeyLabel(title: "Send Answers", key: keys ? "⏎" : nil) }
                        .disabled(!request.canSubmit(skip: false))
                        .accessibilityLabel("Send Answers").accessibilityIdentifier("chat-side-question-submit")
                }
                Button { submit(true) } label: { ApprovalKeyLabel(title: "Skip", key: keys && skipsOnEscape ? "⎋" : nil) }
                    .disabled(!request.canSubmit(skip: true)).accessibilityLabel("Skip")
                if let openTerminal { Button("Open in Terminal", action: openTerminal) }
                if request.submitted { ProgressView().controlSize(.mini) }
            }.buttonStyle(ApprovalButtonStyle())
        }.font(theme.typography.detail).padding(10).chatPanel()
            .disabled(!request.actions.canEdit)
            .focusable().focused($formFocused)
            .onChange(of: request.index) { _, _ in restoreFocus() }
            .task { await Task.yield(); restoreFocus() }
            // Return (or ⌘⏎) is the default button: Next, then Send Answers on the last question.
            .onKeyPress(.return, phases: .down) { event in
                guard event.modifiers.isEmpty || event.modifiers == .command else { return .ignored }
                advance(); return .handled
            }
            // Esc is Skip while nothing is answered, so it never throws typed or chosen answers away.
            .onExitCommand { if skipsOnEscape, request.canSubmit(skip: true) { submit(true) } }
            .onKeyPress(.space, phases: .down) { _ in
                guard !customFocused, let choiceFocused else { return .ignored }
                request.select(choiceFocused); return .handled
            }
            .onKeyPress(.upArrow, phases: .down) { event in moveChoice(-1, event: event) }
            .onKeyPress(.downArrow, phases: .down) { event in moveChoice(1, event: event) }
            .accessibilityIdentifier("chat-side-question-form")
    }

    /// The form has the keys: its buttons show them.
    private var keys: Bool { formFocused || customFocused }
    private var skipsOnEscape: Bool {
        !request.questions.contains { request.answer($0) != nil || !(request.custom[$0.id] ?? "").isEmpty }
    }
    private func advance() {
        if request.actions.canGoNext { request.next() } else if request.canSubmit(skip: false) { submit(false) }
    }
    private var fields: some View {
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
                        TextField("Or type your own answer", text: answerBinding, axis: .vertical).lineLimit(1...4)
                    }
                }.textFieldStyle(.plain).focused($customFocused).onSubmit { advance() }.padding(9).chatPanel()
                    .accessibilityIdentifier("chat-side-question-custom")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)

    }

    private func restoreFocus() {
        choiceFocused = request.question.options?.first(where: { request.isSelected($0.label, in: request.question) })?.label
            ?? request.question.options?.first?.label
        customFocused = choiceFocused == nil
        formFocused = choiceFocused != nil
    }
    private func moveChoice(_ delta: Int, event: KeyPress) -> KeyPress.Result {
        guard !customFocused, event.modifiers.isEmpty, let options = request.question.options, !options.isEmpty else { return .ignored }
        let index = options.firstIndex { $0.label == choiceFocused } ?? 0
        choiceFocused = options[max(0, min(options.count - 1, index + delta))].label
        if !request.question.multiple, let choiceFocused { request.select(choiceFocused) }
        return .handled
    }

    private func choice(_ option: ChatSideQuestion.Option) -> some View {
        let chosen = request.isSelected(option.label, in: request.question)
        return Button { request.select(option.label) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? theme.accent : theme.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label).foregroundStyle(theme.ink)
                    Text(option.description).font(theme.typography.codeDetail).foregroundStyle(theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(8).contentShape(Rectangle()).chatPanel()
        }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var answerBinding: Binding<String> {
        Binding(get: { request.custom[request.question.id, default: ""] }, set: { request.type($0) })
    }
}
