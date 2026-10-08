import SwiftUI

struct ChatPermissionCard: View {
    @Environment(\.chatTheme) private var theme
    let approval: PendingApproval
    var directory = ""
    var agent = "Claude Code"
    let openTerminal: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var details = false
    var body: some View {
        // The transport may resolve before a coordinator tick updates decision.
        // The one-second timeline also retires an expired card without user input.
        TimelineView(.animation(minimumInterval: 1, paused: approval.decision != nil)) { _ in
            let pending = approval.pending
            VStack(alignment: .leading, spacing: 10) {
                if pending {
                    if let draft = approval.questionDraft {
                        ChatQuestionForm(draft: draft, agent: agent, submit: approval.answer,
                                         skip: { approval.resolve(.deny) }, openTerminal: openTerminal)
                    } else {
                    HStack {
                        Label("Allow operation?", systemImage: "diamond.fill").foregroundStyle(theme.accent)
                        Spacer()
                        Text("Permission required").font(theme.typography.detail).foregroundStyle(theme.muted)
                    }
                    operation
                    HStack(spacing: 8) {
                        Button("Allow once") { approval.resolve(.allow) }.buttonStyle(ApprovalButtonStyle(primary: true))
                        Button("Deny") { approval.resolve(.deny) }.buttonStyle(ApprovalButtonStyle())
                        Button("Open in terminal", action: openTerminal).buttonStyle(ApprovalButtonStyle())
                        Spacer(minLength: 0)
                    }
                    }
                } else {
                    Button { details.toggle() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "diamond").foregroundStyle(theme.muted)
                            Text(receipt).fixedSize()
                            Text(approval.questions?.questions.map(\.header).joined(separator: ", ") ?? approval.operation.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).foregroundStyle(theme.muted)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").rotationEffect(.degrees(details ? 90 : 0))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("\(receipt), show requested operation")
                    if details {
                        if let questions = approval.questions {
                            ForEach(questions.questions) { question in
                                Text(question.text).foregroundStyle(theme.ink)
                                Text(approval.answers?[question.text] ?? "No answer sent").foregroundStyle(theme.muted).textSelection(.enabled)
                            }
                            Button("Open in terminal", action: openTerminal).buttonStyle(ApprovalButtonStyle())
                        } else { operation }
                    }
                }
            }
            .font(theme.typography.detail).padding(pending ? 14 : 10)
            .background(pending ? theme.accent.opacity(0.06) : theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pending ? theme.accent.opacity(0.3) : theme.border))
            .overlay {
                if pending {
                    RoundedRectangle(cornerRadius: 8).trim(from: 0, to: arrived ? 1 : 0)
                        .stroke(theme.accent.opacity(0.7), lineWidth: 1)
                        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.35), value: arrived)
                        .allowsHitTesting(false)
                }
            }
            // Permission controls must be readable on their first frame,
            // including when a lazy transcript row has just been mounted.
            // Animate the border above, never the availability of the card.
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: pending)
            .onAppear { arrived = true }
            .accessibilityIdentifier("approval-\(approval.id)")
        }
    }
    @ViewBuilder private var operation: some View {
        if let item = approval.item {
            ChatToolCard(item: item, expanded: .constant(true), directory: directory, requested: true)
        } else { ChatCodeBlock(code: approval.operation, language: "shell", title: "Requested operation") }
    }
    private var receipt: String {
        switch approval.decision {
        case .allow: approval.questions == nil ? "Allowed once" : "Answered"
        case .deny: approval.questions == nil ? "Denied" : "Skipped questions"
        case .terminal: "Continued in terminal"
        case .expired, nil: "Expired"
        }
    }
}

struct ApprovalButtonStyle: ButtonStyle {
    @Environment(\.chatTheme) private var theme
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(primary || configuration.isPressed ? theme.window : theme.ink)
            .chatPanel(configuration.isPressed ? theme.accent : primary ? theme.ink : .clear, cornerRadius: 5)
    }
}
