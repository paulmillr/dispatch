import SwiftUI

struct ChatGoalControls: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    let coordinator: ChatCoordinator
    @State private var presented = false
    @FocusState private var keyboardFocus: Bool

    private var pendingAction: String? {
        guard case .goal(let action)? = session.command?.command else { return nil }
        return action
    }

    var body: some View {
        if let goal = session.goal {
            Button { presented.toggle() } label: {
                TimelineView(.animation(minimumInterval: 1, paused: !session.showChat || !session.active || goal.status != "active")) { timeline in
                    let elapsed = Double(goal.timeUsedSeconds) + (goal.status == "active" && session.active
                        ? max(0, timeline.date.timeIntervalSince(session.goalUpdatedAt)) : 0)
                    HStack(spacing: 6) {
                        if goal.status == "paused" {
                            Image(systemName: "pause.fill")
                        } else {
                            Text("◆").foregroundStyle(goal.status == "active" ? theme.accent : theme.muted)
                        }
                        Text(pendingAction == "pause" ? "pausing goal…" : pendingAction == "resume" ? "resuming goal…"
                             : pendingAction == "clear" ? "stopping goal…"
                             : goal.status == "active" ? "goal" : "goal \(goal.statusLabel)")
                        Text(AgentWorkingAnimation.elapsedText(elapsed)).monospacedDigit()
                    }.contentShape(Rectangle())
                }
            }.buttonStyle(.plain)
                .help("\(goal.objective) · Click to manage goal")
                .accessibilityLabel("Manage goal")
                .accessibilityValue(goal.statusLabel)
                .accessibilityIdentifier("chat-goal-info")
                .popover(isPresented: $presented, arrowEdge: .top) {
                    controls(goal)
                }
                .onChange(of: session.showChat) { _, visible in
                    if !visible { presented = false }
                }
        }
    }

    private func controls(_ goal: ChatGoal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Goal · \(goal.statusLabel)").fontWeight(.semibold)
            ScrollView {
                Text(goal.objective).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }.fixedSize(horizontal: false, vertical: true).frame(maxHeight: 160)
            if goal.status == "paused" && session.busy {
                Text("Goal paused. The current response is still running.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(theme.muted)
            }
            HStack(spacing: 10) {
                Button("Pause") { submit("pause") }
                    .disabled(goal.status != "active")
                    .accessibilityIdentifier("chat-goal-pause")
                Button("Resume") { submit("resume") }
                    .disabled(goal.status == "active")
                    .accessibilityIdentifier("chat-goal-resume")
                Spacer(minLength: 0)
                Button("Stop") { submit("clear") }
                    .help("Clear the current goal")
                    .accessibilityIdentifier("chat-goal-stop")
            }
            .disabled(!session.active || session.command != nil || session.nativePrompt != nil
                || session.inputBlocked || session.nativeInputInFlight)
        }
        .font(theme.typography.detail).foregroundStyle(theme.ink)
        .lineLimit(nil).padding(14).frame(width: 320 * theme.typography.sizeScale)
        // On glass the popover's own system glass shows through instead of the terminal fill.
        .background(LiquidGlassStore.shared.active ? Color.clear : theme.terminal)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .accessibilityIdentifier("chat-goal-controls")
        .focusable().focusEffectDisabled().focused($keyboardFocus)
        .onAppear { keyboardFocus = true }
        .onExitCommand { presented = false }
        .fittedPopoverPresentation()
    }

    private func submit(_ action: String) {
        coordinator.submitCommand(.goal(action), text: "/goal \(action)", session: session)
        presented = false
    }
}
