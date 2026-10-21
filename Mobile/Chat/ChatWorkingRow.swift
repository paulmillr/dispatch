import SwiftUI

/// The thinking line (the Mac's working indicator, ported for the phone): a pulsing ◆ with an orbiting satellite and a
/// shimmering "thinking", driven by one timeline so only this small view redraws. With Reduce Motion the diamond
/// stands still, the satellite and shimmer go.
struct ChatThinkingGlyph: View {
    var size: CGFloat = 16
    @ReduceMotion private var reduceMotion
    @Environment(\.animationDateOverride) private var fixedDate

    var body: some View {
        if reduceMotion {
            diamond(scale: 1, opacity: 1)
                .frame(width: size, height: size)
        } else {
            TimelineView(.animation) { context in
                let time = (fixedDate ?? context.date).timeIntervalSinceReferenceDate
                // hx-pulse: 1.6 s ease-in-out, scale .92 to 1.08, opacity .55 to 1.
                let pulse = (1 - cos(time / 1.6 * 2 * .pi)) / 2
                // hx-orbit: one turn every 1.4 s.
                let angle = Angle.degrees(time.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360)
                ZStack {
                    diamond(scale: 0.92 + 0.16 * pulse, opacity: 0.55 + 0.45 * pulse)
                    Circle()
                        .fill(Color.dispatchPink)
                        .frame(width: 4, height: 4)
                        .shadow(color: .dispatchPink, radius: 3)
                        .offset(y: -size / 2)
                        .rotationEffect(angle)
                }
                .frame(width: size, height: size)
            }
        }
    }

    private func diamond(scale: Double, opacity: Double) -> some View {
        Text("◆")
            .font(.system(size: size * 0.72))
            .foregroundStyle(Color.dispatchPink)
            .scaleEffect(scale)
            .opacity(opacity)
            .accessibilityHidden(true)
    }
}

/// "thinking" with the light sweeping across it (hx-shimmer, 2.4 s); plain with Reduce Motion.
struct ChatShimmerText: View {
    let text: String
    @ReduceMotion private var reduceMotion
    @Environment(\.animationDateOverride) private var fixedDate
    private static let base = Color.shimmerBase

    var body: some View {
        let label = Text(text).font(.subheadline.weight(.semibold))
        if reduceMotion {
            label.foregroundStyle(Self.base)
        } else {
            TimelineView(.animation) { context in
                let phase = (fixedDate ?? context.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                // The background-position sweep from 120% to -120% over a 250% wide gradient.
                let center = 1.2 - 2.4 * phase
                label.foregroundStyle(LinearGradient(stops: [
                    .init(color: Self.base, location: 0),
                    .init(color: Self.base, location: max(0, min(1, center - 0.25))),
                    .init(color: .shimmerHighlight, location: max(0, min(1, center))),
                    .init(color: Self.base, location: max(0, min(1, center + 0.25))),
                    .init(color: Self.base, location: 1),
                ], startPoint: .leading, endPoint: .trailing))
            }
        }
    }
}

/// The accent scan along a hairline (hx-scan, 2.2 s ease-in-out): a 30% wide pink glint crossing it.
struct ChatAccentScan: View {
    @ReduceMotion private var reduceMotion
    @Environment(\.animationDateOverride) private var fixedDate
    var body: some View {
        if reduceMotion {
            Rectangle().fill(Color.dispatchPink.opacity(0.35))
        } else {
            GeometryReader { geometry in
                TimelineView(.animation) { context in
                    let t = (fixedDate ?? context.date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    let width = geometry.size.width * 0.3
                    LinearGradient(colors: [.clear, .dispatchPink, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width)
                        .opacity(0.7)
                        .offset(x: -width + (geometry.size.width + width) * eased)
                }
            }
            .clipped()
        }
    }
}

/// The working row (M5a, M5f): full width under the transcript, a hairline top edge with the accent scan, the thinking
/// line and elapsed time; the trailing side gives the step count and the current step's kind and a disclosure chevron
/// that unfolds the step list in place. Open, it reads as a live log; a step opens its full output.
struct ChatWorkingRow: View {
    let session: MobileChatSession
    let directory: String?
    @Binding var expanded: Bool
    var openStep: (ChatStep) -> Void
    @ReduceMotion private var reduceMotion

    private var steps: [ChatStep] {
        guard let turn = session.transcript.openTurn else { return [] }
        return ChatStep.steps(turn, directory: directory, reasoning: true)
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

    var body: some View {
        let steps = steps
        let tools = steps.filter { $0.kind != .think }
        VStack(spacing: 0) {
            ChatAccentScan()
                .frame(height: 1)
                .background(Color.thinkingBorder)
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ChatThinkingGlyph(size: glyph)
                    if let waiting {
                        // Blocked on the user, as the Mac's indicator says: no thinking shimmer, no clock.
                        Text(waiting)
                    } else {
                        ChatShimmerText(text: "thinking")
                        Text("·").foregroundStyle(.tertiary)
                        ChatElapsed(since: started)
                    }
                    Spacer(minLength: 8)
                    if !tools.isEmpty {
                        Text("\(tools.count) \(tools.count == 1 ? "step" : "steps")" + (expanded ? "" : " · " + (tools.last?.kind.label ?? "")))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.accessibility, Rectangle())
                // One element: the agent, the elapsed time at a ten-second cadence and the current step; VoiceOver
                // reads it again as it changes (updates frequently), never every second.
                .accessibilityElement(children: .ignore)
                .modifier(ChatWorkingAccessibility(agent: session.agentName, since: started, steps: tools.count,
                                                   current: tools.last?.kind.label, waiting: waiting))
                Button {
                    // The rows below appear in place; nothing else in the thread moves.
                    expanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: disclosure, height: disclosure)
                        .background(Color.chipFill, in: Circle())
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.agentName) is working")
    }

    @ScaledMetric(relativeTo: .subheadline) private var glyph: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var disclosure: CGFloat = 28
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
