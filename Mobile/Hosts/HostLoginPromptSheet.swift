import SwiftUI

/// A keyboard-interactive login round (PAM passwords, one-time codes; not in the mockup, kept plain): the server's
/// instruction and one field per prompt, hidden unless the server lets it echo. Continue answers, Cancel ends the
/// login.
struct HostLoginPromptSheet: View {
    let prompt: HostLoginPrompt
    @Environment(HostSessions.self) private var sessions
    @State private var answers: [String]
    @FocusState private var focused: Int?

    init(prompt: HostLoginPrompt) {
        self.prompt = prompt
        _answers = State(initialValue: Array(repeating: "", count: prompt.challenge.prompts.count))
    }

    var body: some View {
        NavigationStack {
            Form {
                let challenge = prompt.challenge
                Section {
                    ForEach(Array(challenge.prompts.enumerated()), id: \.offset) { index, item in
                        let label = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        Group {
                            if item.echo {
                                TextField(label, text: $answers[index])
                            } else {
                                SecureField(label, text: $answers[index])
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: index)
                        .submitLabel(index == challenge.prompts.count - 1 ? .done : .next)
                        .onSubmit { index == challenge.prompts.count - 1 ? submit() : (focused = index + 1) }
                    }
                } header: {
                    Text(challenge.name.isEmpty ? "Log in" : challenge.name)
                } footer: {
                    if !challenge.instruction.isEmpty { Text(challenge.instruction) }
                }
            }
            .navigationTitle(prompt.hostName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sessions.answer(prompt, with: nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: submit).buttonStyle(.glassProminent)
                }
            }
            .onAppear { focused = 0 }
        }
        .interactiveDismissDisabled()
    }

    private func submit() { sessions.answer(prompt, with: answers) }
}
