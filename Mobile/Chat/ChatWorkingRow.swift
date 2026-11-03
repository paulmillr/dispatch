import SwiftUI

/// The thinking line (the Mac's working indicator, ported for the phone): a pulsing ◆ with an orbiting satellite and a
/// shimmering "thinking", in the compositor (`ChatOrbitLoop`), so nothing redraws while it moves; it stops while scrolled
/// away. With Reduce Motion the diamond stands still, the satellite and shimmer go. An `animationDateOverride` (tests)
/// draws that instant's frame in SwiftUI, the frame the loops show then.
struct ChatThinkingGlyph: View {
    var size: CGFloat = 16
    @ReduceMotion private var reduceMotion
    @Environment(\.animationDateOverride) private var fixedDate
    @State private var onScreen = true

    var body: some View {
        if reduceMotion {
            diamond(scale: 1, opacity: 1)
                .frame(width: size, height: size)
        } else if let fixedDate {
            let time = fixedDate.timeIntervalSinceReferenceDate
            let pulse = ChatThinkingMotion.pulse(time)
            ZStack {
                diamond(scale: 0.92 + 0.16 * pulse, opacity: 0.55 + 0.45 * pulse)
                Self.dotShape(color: .dispatchPink)
                    .offset(y: -size / 2)
                    .rotationEffect(.radians(ChatThinkingMotion.orbit(time)))
            }
            .frame(width: size, height: size)
        } else {
            ChatOrbitLoop(size: size, moving: onScreen)
                .frame(width: size, height: size)
                .onScreen($onScreen)
                .accessibilityHidden(true)
        }
    }

    private func diamond(scale: Double, opacity: Double) -> some View {
        Self.diamondText(size: size, color: .dispatchPink)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
    }

    /// The ◆, as SwiftUI and the compositor's still artwork draw it.
    static func diamondText(size: CGFloat, color: Color) -> some View {
        Text("◆")
            .font(.system(size: size * 0.72))
            .foregroundStyle(color)
    }

    /// The satellite: a 4 pt dot glowing 3 pt around (the compositor draws the same with its own layer and shadow).
    static let dotSize: CGFloat = 4
    static let dotGlow: CGFloat = 3

    static func dotShape(color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: dotSize, height: dotSize)
            .shadow(color: color, radius: dotGlow)
    }
}

/// The thinking glyph's two loops as functions of the instant (in seconds): what SwiftUI draws for a given instant and
/// what the compositor's keyframes sample.
enum ChatThinkingMotion {
    /// hx-pulse: 1.6 s ease-in-out, scale .92 to 1.08, opacity .55 to 1.
    static let pulsePeriod = 1.6
    /// hx-orbit: one turn every 1.4 s.
    static let orbitPeriod = 1.4

    /// 0 at rest, 1 at the breath's peak.
    static func pulse(_ time: Double) -> Double { (1 - cos(time / pulsePeriod * 2 * .pi)) / 2 }

    /// The satellite's angle, clockwise from the top, in radians.
    static func orbit(_ time: Double) -> Double { time.truncatingRemainder(dividingBy: orbitPeriod) / orbitPeriod * 2 * .pi }
}

/// The working row's one sweep: the glint crossing the row's hairline (`ChatAccentScan`) is the light on "thinking"
/// (`ChatShimmerText` with a `ChatSweepTrack`): the label lights exactly where and while the glint passes over it,
/// leading to trailing, on one 2.2 s ease-in-out period (hx-scan's; hx-shimmer's own 2.4 s right-to-left loop ran
/// against it). A pure function of the instant, as the Mac's loops are phase-aligned to the media clock: both views,
/// and any two rows, draw the same point in a frame.
enum ChatThinkingSweep {
    static let period = 2.2

    /// 0 with the glint just off the line's leading end, 1 just off its trailing end; eased in and out.
    static func progress(at date: Date) -> Double {
        progress(phase: date.timeIntervalSinceReferenceDate)
    }

    /// The same for `time` seconds (a phase within the period, or any instant's time).
    static func progress(phase time: Double) -> Double {
        let t = (time - (time / period).rounded(.down) * period) / period
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

/// Where a label sits under the hairline's glint: the line's width and the label's leading x on it.
struct ChatSweepTrack: Equatable {
    var lineWidth: CGFloat
    var labelX: CGFloat

    /// The glint's centre and half width on the line at `progress` (`ChatThinkingSweep`).
    static func glint(lineWidth: CGFloat, progress: Double) -> (center: CGFloat, half: CGFloat) {
        let width = lineWidth * ChatAccentScan.share
        return (-width + (lineWidth + width) * progress + width / 2, width / 2)
    }
}

/// "thinking" with the light sweeping across it (`ChatThinkingSweep`); plain with Reduce Motion. On a `track` the light
/// is the hairline's glint itself, as wide and where it is; without one it crosses the label in the same period. The
/// light moves in the compositor (`ChatShimmerLoop`) and stops while scrolled away; an `animationDateOverride` (tests)
/// draws that instant in SwiftUI.
struct ChatShimmerText: View {
    let text: String
    var track: ChatSweepTrack? = nil
    @ReduceMotion private var reduceMotion
    @Environment(\.animationDateOverride) private var fixedDate
    @State private var onScreen = true
    private static let base = Color.shimmerBase
    /// Half the light's width without a track, as a share of the label's.
    static let half = 0.25

    /// The label, as SwiftUI and the compositor's still artwork draw it.
    static func label(_ text: String) -> Text { Text(text).font(.subheadline.weight(.semibold)) }

    var body: some View {
        let label = Self.label(text)
        if reduceMotion {
            label.foregroundStyle(Self.base)
        } else if let fixedDate {
            // The label keeps its place; the copy over it reads the label's width in the same pass.
            label.hidden().overlay {
                GeometryReader { proxy in
                    let (start, end) = span(progress: ChatThinkingSweep.progress(at: fixedDate), width: proxy.size.width)
                    // The gradient's ends pad with the base colour beyond its points: off the label nothing is lit, and
                    // the light leaves and comes back with nothing drawn between (no jump at the wrap).
                    label.foregroundStyle(LinearGradient(colors: [Self.base, .shimmerHighlight, Self.base],
                                                         startPoint: UnitPoint(x: start, y: 0.5),
                                                         endPoint: UnitPoint(x: end, y: 0.5)))
                }
            }
        } else {
            label.foregroundStyle(Self.base)
                .overlay { ChatShimmerLoop(text: text, track: track, moving: onScreen).accessibilityHidden(true) }
                .onScreen($onScreen)
        }
    }

    /// The light's ends in the unit space of a label `width` wide at `progress`.
    private func span(progress: Double, width: CGFloat) -> (CGFloat, CGFloat) {
        if let track {
            // Not laid out yet: unlit, rather than a frame of a light that is not the glint's.
            guard track.lineWidth > 0, width > 0 else { return (-2, -1) }
            let glint = ChatSweepTrack.glint(lineWidth: track.lineWidth, progress: progress)
            let center = glint.center - track.labelX
            return ((center - glint.half) / width, (center + glint.half) / width)
        }
        // Without a track: from just off the leading end to just off the trailing one.
        let center = -Self.half + (1 + 2 * Self.half) * progress
        return (center - Self.half, center + Self.half)
    }
}

/// The accent scan along a hairline (hx-scan, `ChatThinkingSweep`): a 30% wide pink glint crossing it, in the compositor
/// (`ChatScanLoop`) and stopped while scrolled away; an `animationDateOverride` (tests) draws that instant in SwiftUI.
struct ChatAccentScan: View {
    /// The glint's width, as a share of the line's.
    static let share: CGFloat = 0.3
    static let opacity = 0.7
    @ReduceMotion private var reduceMotion
    @Environment(\.animationDateOverride) private var fixedDate
    @State private var onScreen = true
    var body: some View {
        if reduceMotion {
            Rectangle().fill(Color.dispatchPink.opacity(0.35))
        } else if let fixedDate {
            GeometryReader { geometry in
                let glint = ChatSweepTrack.glint(lineWidth: geometry.size.width, progress: ChatThinkingSweep.progress(at: fixedDate))
                LinearGradient(colors: [.clear, .dispatchPink, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: glint.half * 2)
                    .opacity(Self.opacity)
                    .offset(x: glint.center - glint.half)
            }
            .clipped()
        } else {
            ChatScanLoop(moving: onScreen)
                .onScreen($onScreen)
                .accessibilityHidden(true)
        }
    }
}

/// The working row's round buttons, Stop and the disclosure chevron: one size, one quiet disc (`Color.chipFill`) under
/// the glyph (the chevron in the secondary ink, Stop's square in the primary).
struct ChatWorkingDisc<Content: View>: View {
    let size: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(Color.chipFill, in: Circle())
            .contentShape(Circle())
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
    }
}

/// The working row (M5a, M5f, Q1): full width under the transcript for as long as the agent works, a hairline top edge
/// with the accent scan, the thinking line and elapsed time with Stop beside it (while the conversation can take it, away
/// from the trailing controls a thumb reaches for); the trailing side counts the steps since the agent last wrote (the
/// Mac's live tool group), holds the queue's capsule while messages wait (a tap opens the queue card under the row) and
/// a disclosure chevron that unfolds those steps in place. Open, it reads as a live log; a step opens its full output.
struct ChatWorkingRow: View {
    let session: MobileChatSession
    let directory: String?
    @Binding var expanded: Bool
    /// The queue card under the row, opened and folded by the capsule.
    var queueExpanded: Binding<Bool> = .constant(false)
    var openStep: (ChatStep) -> Void
    @ReduceMotion private var reduceMotion

    private var steps: [ChatStep] {
        guard let turn = session.transcript.openTurn else { return [] }
        return ChatStep.current(turn, directory: directory)
    }

    /// What the agent waits for, when it waits for the user (the Mac's AgentWorkingIndicator).
    private var waiting: String? {
        guard session.waitingForUser else { return nil }
        let question = session.questions.contains { $0.blocking && !$0.submitted }
            || session.approvals.contains { $0.pending.pending && $0.pending.questions != nil }
        return question ? "waiting for your answer" : "waiting for your approval"
    }

    /// The clock: the prompt this phone sent, else the turn's start, else when the agent began working.
    private var started: Date? {
        if let sent = session.submittedAt { return sent }
        if let turn = session.transcript.openTurn, turn.started.timeIntervalSince1970 > 0 { return turn.started }
        return session.workingSince
    }

    /// The messages waiting for the turn's end, as the queue card shows them (none while the link is not verified:
    /// then they are faded bubbles in the thread).
    private var queued: Int {
        session.phase == .verified ? session.queueRows.count : 0
    }

    /// The row's space: the hairline spans it from 0, and the label's light is placed on it.
    private static let space = "chat-working-row"
    @State private var lineWidth: CGFloat = 0
    @State private var labelX: CGFloat = 0

    var body: some View {
        let steps = steps
        let tools = steps.filter { $0.kind != .think }
        VStack(spacing: 0) {
            ChatAccentScan()
                .frame(height: 1)
                .background(Color.thinkingBorder)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { lineWidth = $0 }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ChatThinkingGlyph(size: glyph)
                    if let waiting {
                        // Blocked on the user, as the Mac's indicator says: no thinking shimmer, no clock.
                        Text(waiting)
                    } else {
                        ChatShimmerText(text: "thinking",
                                        track: ChatSweepTrack(lineWidth: lineWidth, labelX: labelX))
                            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.space)).minX }) { labelX = $0 }
                        Text("·").foregroundStyle(.tertiary)
                        ChatElapsed(since: started)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.accessibility, Rectangle())
                // One element: the agent, the elapsed time at a ten-second cadence and the current step; VoiceOver
                // reads it again as it changes (updates frequently), never every second.
                .accessibilityElement(children: .ignore)
                .modifier(ChatWorkingAccessibility(agent: session.agentName, since: started, steps: tools.count,
                                                   current: tools.last?.kind.label, waiting: waiting))
                if session.working && session.phase == .verified {
                    // Beside the clock, quiet as the chevron.
                    Button { session.stop() } label: {
                        ChatWorkingDisc(size: disclosure) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.85)).frame(width: 9, height: 9)
                        }
                        .opacity(session.stopping ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(session.stopping)
                    .accessibilityLabel("Stop")
                }
                Spacer(minLength: 8)
                if !tools.isEmpty {
                    // The current step's kind is the unfolded log's live row and VoiceOver's value; the line counts.
                    Text("\(tools.count) \(tools.count == 1 ? "step" : "steps")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .accessibilityHidden(true)
                }
                if queued > 0 {
                    ChatQueueCapsule(count: queued, expanded: queueExpanded, size: disclosure)
                        .transition(.opacity.animation(reduceMotion ? nil : .easeOut(duration: 0.15)))
                }
                Button {
                    // The rows below appear in place; nothing else in the thread moves.
                    expanded.toggle()
                } label: {
                    ChatWorkingDisc(size: disclosure) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide steps" : "Show steps")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            if expanded {
                VStack(spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        Button { openStep(step) } label: {
                            ChatStepLogRow(step: step, live: index == steps.count - 1 && step.running)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows its full output")
                        if index < steps.count - 1 { Rectangle().fill(Color.hairline.opacity(0.6)).frame(height: 0.5) }
                    }
                    Text(steps.isEmpty ? "No steps yet" : "Tap a step for its output")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .coordinateSpace(.named(Self.space))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.agentName) is working")
    }

    @ScaledMetric(relativeTo: .subheadline) private var glyph: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var disclosure: CGFloat = 28
}

/// The queue in the working row (Q1): the glyph and how many messages wait, pink on a faint pink fill, as tall as the
/// row's discs; lit (the accent's fill, its ink on it) while the card under the row is open. A tap opens or folds it.
struct ChatQueueCapsule: View {
    let count: Int
    @Binding var expanded: Bool
    let size: CGFloat
    @ReduceMotion private var reduceMotion

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.message")
                Text("\(count)")
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(count)))
                    .animation(.snappy(duration: 0.25), value: count)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(expanded ? Color.onAccent : Color.dispatchPink)
            .padding(.horizontal, size * 0.32)
            .frame(minWidth: size, minHeight: size)
            .background(expanded ? Color.dispatchPink : Color.dispatchPink.opacity(0.14), in: Capsule())
            .contentShape(.hoverEffect, Capsule())
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Queued")
        .accessibilityValue(count == 1 ? "1 message" : "\(count) messages")
        .accessibilityHint(expanded ? "Hides the queued messages" : "Shows the queued messages")
        .accessibilityAddTraits(expanded ? .isSelected : [])
    }
}

/// The thinking line for VoiceOver: "claude is thinking, 40 seconds", the steps as its value. The time is spoken in
/// ten-second steps (whole minutes after ten), so the label changes at most every ten seconds.
struct ChatWorkingAccessibility: ViewModifier {
    let agent: String
    let since: Date?
    let steps: Int
    let current: String?
    /// "waiting for your approval": said instead of the time.
    var waiting: String? = nil

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: since ?? .now, by: 10)) { context in
            content
                .accessibilityLabel(waiting.map { "\(agent) is \($0)" }
                    ?? Self.label(agent: agent, elapsed: since.map { context.date.timeIntervalSince($0) } ?? 0))
                .accessibilityValue(Self.value(steps: steps, current: current))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    static func label(agent: String, elapsed: TimeInterval) -> String {
        "\(agent) is thinking, " + spoken(elapsed)
    }

    static func value(steps: Int, current: String?) -> String {
        guard steps > 0 else { return "No steps yet" }
        return "\(steps) \(steps == 1 ? "step" : "steps")" + (current.map { ", now \($0)" } ?? "")
    }

    /// "less than 10 seconds", "40 seconds", "1 minute, 20 seconds", "12 minutes".
    static func spoken(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 10 { return "less than 10 seconds" }
        let step = seconds >= 600 ? seconds / 60 * 60 : seconds / 10 * 10
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = step >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: TimeInterval(step)) ?? "\(step) seconds"
    }
}

/// One line of the live log (M5f): badge, what it acted on, its short result.
struct ChatStepLogRow: View {
    let step: ChatStep
    var live = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChatStepBadge(kind: step.kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .scaledFont(13.5, relativeTo: .footnote)
                    .foregroundStyle(.primary)
                    // One line as in M5f; wrapped rather than cut in the middle at the larger sizes.
                    .lineLimit(typeSize > .large ? 3 : 1)
                    .truncationMode(.middle)
                if let detail = detailText {
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if live {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .opacity(live ? 1 : 0.72)
    }

    private var detailText: Text? {
        switch step.kind {
        case .patch where step.additions + step.deletions > 0:
            return Text("+\(step.additions)").foregroundStyle(ChatStep.added) + Text(" ")
                + Text("−\(step.deletions)").foregroundStyle(ChatStep.removed)
        case .run where step.failed:
            return Text(step.detail ?? "failed").foregroundStyle(ChatStep.removed)
        default:
            return step.detail.map { Text($0) }
        }
    }
}

/// Seconds since `since`, ticking once a second; with Reduce Motion the first ten seconds count, then every five.
struct ChatElapsed: View {
    let since: Date?
    @ReduceMotion private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.text(since.map { context.date.timeIntervalSince($0) } ?? 0, reduceMotion: reduceMotion))
                .monospacedDigit()
        }
    }

    static func text(_ interval: TimeInterval, reduceMotion: Bool) -> String {
        let seconds = max(0, Int(interval))
        return ChatTurnSummary.elapsed(TimeInterval(reduceMotion && seconds >= 10 ? seconds / 5 * 5 : seconds))
    }
}
