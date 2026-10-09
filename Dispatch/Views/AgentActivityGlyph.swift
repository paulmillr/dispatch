import SwiftUI
import Term

/// What a space's or tab's agents, and programs reporting through OSC 7501, report, most urgent first: a
/// connection being made or lost, then an agent waiting for approval (or a blocked program), unread output (or a
/// finished program), and work in progress. Shared by the glyph and the Large sidebar's status pill.
@MainActor
struct AgentActivity: Equatable {
    var reconnecting = false
    var offline = false
    var blocked = false
    /// An agent's approval is pending (otherwise `blocked` is a program's, for `blockedKind`).
    var approval = false
    var blockedKind: ProgramStatus.Kind?
    var finished = false
    /// A program reported an error the user hasn't seen.
    var failed = false
    var working = false
    /// Some agent is attached but reports nothing.
    var idle = false

    init(tabIDs: [UUID], connecting: Bool = false) {
        let sessions = tabIDs.compactMap { TerminalRuntime.shared.chat.sessions[$0] }
        let programs = TerminalRuntime.shared.programs.visible(tabIDs)
        approval = sessions.contains { $0.approvals.contains { $0.pending } }
        let blockedProgram = programs.first { $0.state == .blocked }
        blocked = approval || blockedProgram != nil
        blockedKind = blockedProgram?.kind
        working = sessions.contains { $0.active && $0.busy } || programs.contains { $0.state == .working }
        // Unseen output also piles up while an agent works, so only an idle tab counts as finished.
        // A finished tab outranks a working one: it needs you, the working one doesn't yet.
        failed = programs.contains { $0.state == .error }
        finished = sessions.contains { $0.hasNewMessages && !($0.active && $0.busy) } || failed || programs.contains { $0.state == .done }
        let controller = TerminalRuntime.shared.hosts.reconnect
        offline = tabIDs.contains { controller.state(for: $0) != nil }
        reconnecting = connecting || tabIDs.contains { controller.state(for: $0)?.reconnecting == true }
        idle = sessions.contains { $0.active }
    }

    /// The status in a word, for the Large sidebar's pill; nil while there's nothing to report.
    var label: String? {
        reconnecting ? "Connecting" : offline ? "Offline" : blocked ? (approval ? "Needs approval" : blockedLabel(short: true))
            : failed ? "Failed" : finished ? "Unread" : working ? "Working" : nil
    }

    var accessibilityLabel: String {
        reconnecting ? "Connecting to host" : offline ? "Host offline" : blocked ? (approval ? "Awaiting approval" : blockedLabel(short: false))
            : failed ? "Program failed" : finished ? "Unread output" : working ? "Working" : idle ? "Idle" : "No reported agent activity"
    }

    private func blockedLabel(short: Bool) -> String {
        switch blockedKind {
        case .permission: short ? "Needs approval" : "Awaiting approval"
        case .question: short ? "Question" : "Question for you"
        case .auth: short ? "Needs login" : "Needs authentication"
        case nil: short ? "Blocked" : "Program blocked"
        }
    }
}

/// Only show activity the attached local agent, or a program through OSC 7501, has actually
/// reported. Shell screens and native permission prompts are never scraped to invent status.
struct AgentActivityGlyph: View {
    let tabIDs: [UUID]
    var connecting = false
    var size: CGFloat = 10
    var tile = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let activity = AgentActivity(tabIDs: tabIDs, connecting: connecting)
        let (blocked, working, finished, failed) = (activity.blocked, activity.working, activity.finished, activity.failed)
        let (offline, reconnecting) = (activity.offline, activity.reconnecting)
        let state = offline ? "◌" : blocked ? "●" : finished ? "◆" : working ? "◐" : "·"
        let tint = offline ? Chrome.muted : blocked ? (tile ? Chrome.palette.warning : Chrome.palette.green)
            : failed ? Chrome.palette.warning : finished ? Chrome.accent : working ? Chrome.ink : Chrome.muted
        Group {
            if reconnecting {
                // Match a monospace status glyph's visible width, not its font point size.
                SSHConnectingIndicator(reduceMotion: reduceMotion, size: tile ? size * 0.75 : size == 10 ? 9 : size)
            } else { Text(tile && blocked && !offline ? "◌" : state) }
        }
            .transformEnvironment(\.font) { if tile { $0 = AppFont.ui(size: 14) } }
            .contentTransition(.opacity)
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: state)
            .modifier(ActivityPop(state: state, reduce: reduceMotion))
            .foregroundStyle(tint)
            .frame(width: tile ? size + 8 : size, height: tile ? size + 8 : nil)
            .accessibilityLabel(activity.accessibilityLabel)
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
