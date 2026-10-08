import SwiftUI

/// Only show activity the attached local agent has actually reported. Shell
/// screens and native permission prompts are never scraped to invent status.
struct AgentActivityGlyph: View {
    let tabIDs: [UUID]
    var connecting = false
    var size: CGFloat = 10
    var tile = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How long the working glyph holds each half.
    private static let swing: TimeInterval = 1.0
    var body: some View {
        let sessions = tabIDs.compactMap { TerminalRuntime.shared.chat.sessions[$0] }
        let blocked = sessions.contains { $0.approvals.contains { $0.pending } }
        let working = sessions.contains { $0.active && $0.busy }
        // Unseen output also piles up while an agent works, so only an idle tab counts as finished.
        // A finished tab outranks a working one: it needs you, the working one doesn't yet.
        let finished = sessions.contains { $0.hasNewMessages && !($0.active && $0.busy) }
        let controller = TerminalRuntime.shared.hosts.reconnect
        let offline = tabIDs.contains { controller.state(for: $0) != nil }
        let reconnecting = connecting || tabIDs.contains { controller.state(for: $0)?.reconnecting == true }
        let state = offline ? "◌" : blocked ? "●" : finished ? "◆" : working ? "◐" : "·"
        let tint = offline ? Chrome.muted : blocked ? (tile ? Chrome.palette.warning : Chrome.palette.green)
            : finished ? Chrome.accent : working ? Chrome.ink : Chrome.muted
        Group {
            if reconnecting {
                // Match a monospace status glyph's visible width, not its font point size.
                SSHConnectingIndicator(reduceMotion: reduceMotion, size: tile ? size * 0.75 : size == 10 ? 9 : size)
            } else if state == "◐" && !reduceMotion {
                // Working swings its filled half from side to side, every working glyph in step; Reduce Motion holds it.
                TimelineView(.periodic(from: .distantPast, by: Self.swing)) { timeline in
                    Text(Int((timeline.date.timeIntervalSinceReferenceDate / Self.swing).rounded()) % 2 == 0 ? "◐" : "◑")
                }
            } else { Text(tile && blocked && !offline ? "◌" : state) }
        }
            .transformEnvironment(\.font) { if tile { $0 = AppFont.ui(size: 14) } }
            .contentTransition(.opacity)
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: state)
            .modifier(ActivityPop(state: state, reduce: reduceMotion))
            .foregroundStyle(tint)
            .frame(width: tile ? size + 8 : size, height: tile ? size + 8 : nil)
            .accessibilityLabel(reconnecting ? "Connecting to host" : offline ? "Host offline" : blocked ? "Awaiting approval" : finished ? "Unread output" : working ? "Working" : sessions.contains { $0.active } ? "Idle" : "No reported agent activity")
    }
}

struct SSHConnectingIndicator: View {
    let reduceMotion: Bool
    var size: CGFloat = 9
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion)) { timeline in
            Circle().trim(from: 0.125, to: 0.875)
                .stroke(style: StrokeStyle(lineWidth: 1.5 * size / 9, lineCap: .butt))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) * 400))
                .foregroundStyle(Chrome.palette.warning)
        }
        .accessibilityIdentifier("ssh-connecting-spinner")
    }
}

private struct ActivityPop: ViewModifier {
    let state: String
    let reduce: Bool
    @State private var popped = false
    @State private var previousState: String?
    func body(content: Content) -> some View {
        content.scaleEffect(popped && !reduce ? 1.6 : 1)
            .animation(InterfaceMotion.animation(reduce: reduce, duration: 0.18), value: popped)
            .task(id: state) {
                let previous = previousState
                previousState = state
                guard previous != nil, !reduce else { popped = false; return }
                popped = true
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                popped = false
            }
    }
}
