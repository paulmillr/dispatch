import SwiftUI

struct ChatPermissionCard: View {
    @Environment(\.chatTheme) private var theme
    let approval: PendingApproval
    var directory = ""
    var agent = "Claude Code"
    /// The request Chat › Allow Once (⇧⌘⏎) and Deny (⇧⌘⌫) answer (`ChatCoordinator.keyedApproval`): its buttons show
    /// the keys.
    var keyed = false
    let openTerminal: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var details = false
    private var allowButton: some View {
        Button { approval.resolve(.allow) } label: { ApprovalKeyLabel(title: "Allow Once", key: keyed ? "⇧⌘⏎" : nil) }
            .buttonStyle(ApprovalButtonStyle(primary: true))
            .help(keyed ? "Allow Once · ⇧⌘⏎" : "Allow Once").accessibilityLabel("Allow Once")
    }
    private var denyButton: some View {
        Button { approval.resolve(.deny) } label: { ApprovalKeyLabel(title: "Deny", key: keyed ? "⇧⌘⌫" : nil) }
            .buttonStyle(ApprovalButtonStyle())
            .help(keyed ? "Deny · ⇧⌘⌫" : "Deny").accessibilityLabel("Deny")
    }
    private var terminalButton: some View { Button("Open in Terminal", action: openTerminal).buttonStyle(ApprovalButtonStyle()) }

    var body: some View {
        // The transport may resolve before a coordinator tick updates decision.
        // The one-second timeline also retires an expired card without user input.
        TimelineView(.animation(minimumInterval: 1, paused: approval.decision != nil)) { context in
            let pending = approval.pending
            VStack(alignment: .leading, spacing: 10) {
                if pending {
                    if let remaining = remaining(at: context.date) {
                        Text("Expires in \(Self.countdown(remaining)) · then \(approval.questions == nil ? "decide" : "answer") in Terminal")
                            .font(theme.typography.detail).monospacedDigit().foregroundStyle(theme.yellow)
                            .accessibilityIdentifier("approval-countdown")
                    }
                    if let draft = approval.questionDraft {
                        ChatQuestionForm(draft: draft, agent: agent, submit: approval.answerDraft,
                                         skip: { approval.resolve(.deny) }, openTerminal: openTerminal)
                    } else {
                    if theme.radioLog {
                        // Nautical: an urgent call that needs an answer, the agent asking for a pilot aboard.
                        HStack(spacing: 8) {
                            ChatRadioLog.tag("PAN-PAN", color: theme.yellow, theme: theme)
                            Text("Requesting pilot").foregroundStyle(theme.yellow)
                            Spacer()
                            Text("Permission required").font(theme.typography.detail).foregroundStyle(theme.muted)
                        }
                    } else {
                    // A narrow card drops the aside rather than wrapping the question beside it.
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Label("Allow operation?", systemImage: "diamond.fill").foregroundStyle(theme.accent).fixedSize()
                            Spacer()
                            Text("Permission required").font(theme.typography.detail).foregroundStyle(theme.muted).fixedSize()
                        }
                        Label("Allow operation?", systemImage: "diamond.fill").foregroundStyle(theme.accent)
                    }
                    }
                    operation
                    // One row while the buttons fit unwrapped, else Open in terminal on a row of its own.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            allowButton.fixedSize()
                            denyButton.fixedSize()
                            terminalButton.fixedSize()
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                allowButton.fixedSize()
                                denyButton.fixedSize()
                            }
                            terminalButton.fixedSize()
                        }
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
                    // An answer typed into a card that expired is kept here to copy, never lost with the card.
                    if approval.decision == .expired, !unsent.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Not sent: \(unsent)").foregroundStyle(theme.muted).textSelection(.enabled)
                                .lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(unsent, forType: .string)
                            }.buttonStyle(ApprovalButtonStyle()).accessibilityLabel("Copy unsent answer")
                        }.accessibilityIdentifier("approval-unsent")
                    }
                    if details {
                        if let questions = approval.questions {
                            ForEach(questions.questions) { question in
                                Text(question.text).foregroundStyle(theme.ink)
                                Text(approval.answers?[question.text] ?? "No answer sent").foregroundStyle(theme.muted).textSelection(.enabled)
                            }
                            Button("Open in Terminal", action: openTerminal).buttonStyle(ApprovalButtonStyle())
                        } else { operation }
                    }
                }
            }
            .font(theme.typography.detail).padding(pending ? 14 : 10)
            .background(pending ? urgent.opacity(0.06) : theme.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(pending ? urgent.opacity(0.3) : theme.border))
            .overlay {
                if pending {
                    RoundedRectangle(cornerRadius: 8).trim(from: 0, to: arrived ? 1 : 0)
                        .stroke(urgent.opacity(0.7), lineWidth: 1)
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
    /// Seconds left in the last minute before the producer retires the request; nil before then or without a limit.
    private func remaining(at date: Date) -> TimeInterval? {
        guard let expires = approval.expires else { return nil }
        let left = expires.timeIntervalSince(date)
        return left <= 60 ? max(0, left) : nil
    }
    /// "0:42".
    static func countdown(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
    /// What the user typed as their own answers, joined: kept on an expired card's receipt.
    private var unsent: String {
        guard let draft = approval.questionDraft else { return "" }
        return draft.questionnaire.questions.compactMap { draft.custom[$0.id] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    /// A pending request's color: the accent, or Nautical's PAN-PAN amber.
    private var urgent: Color { theme.radioLog ? theme.yellow : theme.accent }
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

/// A card button's title and, for the card the keys answer, its key in a fainter weight.
struct ApprovalKeyLabel: View {
    @Environment(\.chatTheme) private var theme
    let title: String
    var key: String?
    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let key { Text(key).font(AppFont.shortcut(size: theme.typography.codeDetailSize)).opacity(0.6).accessibilityHidden(true) }
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
