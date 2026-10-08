import SwiftUI

struct ChatCommandControls: View {
    @Environment(\.chatTheme) private var theme
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.command != nil {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Running command…") }
                    .font(theme.typography.detail).foregroundStyle(theme.muted)
            }
            if let question = session.questions.first {
                ChatSideQuestionForm(request: question, agent: session.agentTitle) { skip in coordinator.answerQuestion(question, skip: skip, session: session) }
                    .frame(height: 270)
            }
            if let result = session.commandResult {
                let shellOutput = result.title.hasPrefix("!")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(result.title).fontWeight(.semibold)
                        Spacer()
                        Button { session.commandResult = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("Dismiss command result")
                    }
                    ScrollView(shellOutput ? [.horizontal, .vertical] : .vertical) {
                        Text(result.text)
                            .fixedSize(horizontal: shellOutput, vertical: true)
                            .frame(maxWidth: shellOutput ? nil : .infinity, alignment: .leading)
                            .contextMenu {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(result.text, forType: .string)
                                }
                            }
                    }.frame(maxHeight: result.title == "Session status" ? 220 : 100)
                }.font(theme.typography.detail).padding(10).chatPanel().accessibilityIdentifier("chat-command-result")
            }
        }
    }
}
