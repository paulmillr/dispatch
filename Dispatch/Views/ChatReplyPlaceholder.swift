import SwiftUI

/// The reply placeholder's content (ChatPendingReply): the composer footer's activity, ◆ and orbit, label and time, on
/// the reply's first line where its first word will be; the footer's hides meanwhile. Hovered, it offers the stop the
/// composer has (⎋⎋). Its line and the time's line below keep a one-line reply's height, so a short first reply takes
/// its place without moving.
struct ChatReplyPlaceholderStatus: View {
    @Environment(\.chatTheme) private var theme
    @MotionReduced private var reduceMotion
    let session: ChatSession
    let coordinator: ChatCoordinator
    @State private var appeared = Date()
    @State private var hovering = false

    var body: some View {
        let state = AgentWorkingState(session, details: false)
        let moving = !reduceMotion && session.showChat
        ZStack(alignment: .leading) {
            Text("\u{00A0}").accessibilityHidden(true)
            HStack(spacing: 8) {
                ChatComposerOrbit(moving: moving)
                ChatComposerStatus(label: state.label, moving: moving)
                if session.showChat {
                    // A tick a hair after each whole second of the clock, as its text changes (AgentWorkingIndicator's).
                    TimelineView(.periodic(from: (state.started ?? appeared).addingTimeInterval(-0.99), by: 1)) { timeline in
                        clock(state, now: timeline.date)
                    }
                } else {
                    clock(state, now: .now)
                }
                Spacer(minLength: 8)
                if hovering, coordinator.canInterrupt(session) {
                    Button { coordinator.interrupt(session) } label: {
                        Text("stop  ⎋⎋").padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(theme.border))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Stop agent · ⎋⎋ · Draft kept")
                        .accessibilityIdentifier("chat-reply-stop")
                        .transition(.opacity)
                }
            }
            .font(theme.typography.detail).foregroundStyle(theme.muted)
            // The orbit's slot is 16 wide around a narrower ◆: it starts where the reply's text will.
            .padding(.leading, -2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            if reduceMotion { hovering = inside } else { withAnimation(.easeInOut(duration: 0.15)) { hovering = inside } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.agentTitle) is \(state.label)")
        Text("\u{00A0}").font(theme.typography.detail).accessibilityHidden(true)
    }

    private func clock(_ state: AgentWorkingState, now: Date) -> some View {
        let time = "· " + AgentWorkingAnimation.timeText(state, now: now, appeared: appeared, reduceMotion: reduceMotion)
        return ChatClockSlot(template: ChatClockSlot.template(time)).equatable()
            .overlay(alignment: .leading) { Text(time).monospacedDigit().fixedSize() }
    }
}
