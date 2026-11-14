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
    /// A terminal rang its bell (BEL) while it was not shown, and nobody has typed in it since.
    var bell = false
    /// The bell is all that is unread: the mark and its words say so.
    var bellOnly = false
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
        bell = tabIDs.contains { TerminalRuntime.shared.programs.rang.contains($0) }
        let unread = sessions.contains { $0.hasNewMessages && !($0.active && $0.busy) } || programs.contains { $0.state == .done }
        finished = unread || failed || bell
        bellOnly = bell && !unread && !failed
        let controller = TerminalRuntime.shared.hosts.reconnect
        offline = tabIDs.contains { controller.state(for: $0) != nil }
        reconnecting = connecting || tabIDs.contains { controller.state(for: $0)?.reconnecting == true }
        idle = sessions.contains { $0.active }
    }

    /// The status in a word, for the Large sidebar's pill; nil while there's nothing to report.
    var label: String? {
        reconnecting ? "Connecting" : offline ? "Offline" : blocked ? (approval ? "Needs approval" : blockedLabel(short: true))
            : failed ? "Failed" : bellOnly ? "Bell" : finished ? "Unread" : working ? "Working" : nil
    }

    var accessibilityLabel: String {
        reconnecting ? "Connecting to host" : offline ? "Host offline" : blocked ? (approval ? "Awaiting approval" : blockedLabel(short: false))
            : failed ? "Program failed" : bellOnly ? "Bell rang" : finished ? "Unread output" : working ? "Working"
            : idle ? "Idle" : "No reported agent activity"
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

/// An activity status's mark: SF Symbols, the same shapes and sizes in every interface font. San Francisco has none of
/// ◌ ◆ ◐ itself and would draw them from three unrelated fallback fonts, oversized; quiet is a small dot.
enum ActivityMark: Hashable {
    case quiet, working, blocked, finished, failed, bell, offline

    init(_ urgency: PaneUrgency) {
        switch urgency { case .waiting: self = .blocked; case .unread: self = .finished; case .running: self = .working; case .idle: self = .quiet }
    }

    var symbol: String? {
        switch self {
        case .quiet: nil
        case .working: "circle.lefthalf.filled"
        case .blocked: "circle.fill"
        case .finished: "diamond.fill"
        // Its own shape, not only its colour, tells a failure and a bell from unread output.
        case .failed: "exclamationmark.triangle.fill"
        case .bell: "bell.fill"
        case .offline: "circle.dotted"
        }
    }

    /// The symbol's point size for text at `size`: about the ink of a lowercase letter, the filled circle a little less.
    func symbolSize(_ size: CGFloat) -> CGFloat { size * (self == .blocked ? 0.55 : 0.62) }

    /// The mark beside text at `size` points.
    @ViewBuilder func view(size: CGFloat) -> some View {
        if let symbol { Image(systemName: symbol).font(.system(size: symbolSize(size))) }
        else { Circle().frame(width: size * 0.2, height: size * 0.2) }
    }

    /// The mark inside a line of text at `size` points.
    func text(size: CGFloat) -> Text {
        symbol.map { Text(Image(systemName: $0)).font(.system(size: symbolSize(size))) } ?? Text("·")
    }
}

/// Only show activity the attached local agent, or a program through OSC 7501, has actually
/// reported. Shell screens and native permission prompts are never scraped to invent status.
struct AgentActivityGlyph: View {
    let tabIDs: [UUID]
    var connecting = false
    var size: CGFloat = 10
    var tile = false
    /// Draw the "·" when nothing is reported; without it the slot stays, empty, so rows keep their alignment.
    var showsQuiet = true
    @MotionReduced private var reduceMotion
    @Environment(\.appTypography) private var typography
    var body: some View {
        let activity = AgentActivity(tabIDs: tabIDs, connecting: connecting)
        let (blocked, working, finished, failed) = (activity.blocked, activity.working, activity.finished, activity.failed)
        let (offline, reconnecting) = (activity.offline, activity.reconnecting)
        let state: ActivityMark = offline ? .offline : blocked ? .blocked : failed ? .failed : activity.bellOnly ? .bell
            : finished ? .finished : working ? .working : .quiet
        // Needs you is green everywhere (strips, tiles, the attention banner, the sidebar's "needs you").
        let tint = offline ? Chrome.muted : blocked ? Chrome.palette.green
            : failed ? Chrome.palette.warning : finished ? Chrome.accent : working ? Chrome.ink : Chrome.muted
        Group {
            if reconnecting {
                // Match a monospace status glyph's visible width, not its font point size.
                SSHConnectingIndicator(reduceMotion: reduceMotion, size: tile ? size * 0.75 : size == 10 ? 9 : size)
            } else {
                (tile && blocked && !offline ? ActivityMark.offline : state).view(size: tile ? 14 : typography.size(.label))
                    .opacity(state == .quiet && !showsQuiet ? 0 : 1)
            }
        }
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
    let state: ActivityMark
    let reduce: Bool
    @State private var popped = false
    @State private var previousState: ActivityMark?
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
