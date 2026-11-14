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
/// Mac's live tool group) and a disclosure chevron unfolds the row in place, as a tap on the thinking line does. Open,
/// it reads as the Mac's activity popover over a live log: the steps line carries the session's tokens and the plan's
/// limits (`ChatLimitsLine`), then the steps in a window four tall (`ChatStepWindow`); a step opens as the Mac opens one
/// (`ChatStepOutput`). Stop stops once held
/// 3 s where it is, the capsule over the row saying so and filling as it is held (`ChatStopHold`): a stray tap ends
/// nothing.
struct ChatWorkingRow: View {
    let session: MobileChatSession
    let directory: String?
    @Binding var expanded: Bool
    var openStep: (ChatStep) -> Void
    @ReduceMotion private var reduceMotion
    /// Stop's capsule is up over the row: from a touch on Stop until `ChatStopHold.idle` after the last.
    @State private var holdShown = false
    /// Stop is held down, and how far the hold is (0 to 1 over `ChatStopHold.duration`).
    @State private var pressing = false
    @State private var progress: Double = 0
    @State private var stopped = false
    /// Changes as a press on Stop starts or ends: the capsule's idle wait starts again.
    @State private var touches = 0
    /// Counts the stops a hold made: the heavy tap as it ends.
    @State private var held = 0
    @State private var holdHeight: CGFloat = 44
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// The plan's limits (`chat.limits`), read as the row unfolds, after the user agreed for that agent.
    var limits = ChatLimitsReader.shared
    @State private var askingLimits = false

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

    private var canStop: Bool { session.working && session.phase == .verified }

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
                // A tap on the line unfolds the row, as a click on the Mac's Thinking opens its activity.
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
                .contentShape(.accessibility, Rectangle())
                // One element: the agent, the elapsed time at a ten-second cadence and the current step; VoiceOver
                // reads it again as it changes (updates frequently), never every second.
                .accessibilityElement(children: .ignore)
                .modifier(ChatWorkingAccessibility(agent: session.agentName, since: started, steps: tools.count,
                                                   current: tools.last?.kind.label, waiting: waiting))
                .accessibilityHint(expanded ? "Hides the usage and steps" : "Shows the usage and steps")
                .accessibilityAction { expanded.toggle() }
                if canStop {
                    // Beside the clock, quiet as the chevron. Held 3 s it stops; a touch brings up the capsule that
                    // says so, which fills while it is held.
                    ChatWorkingDisc(size: disclosure) {
                        RoundedRectangle(cornerRadius: 2).fill(stopInk.opacity(0.85)).frame(width: 9, height: 9)
                    }
                    .opacity(session.stopping ? 0.5 : 1)
                    .scaleEffect(pressing ? 0.92 : 1)
                    .onLongPressGesture(minimumDuration: ChatStopHold.duration, maximumDistance: 40) {
                        stopped = true
                        stop()
                    } onPressingChanged: { press in
                        pressing = press
                        touches += 1
                        if press {
                            stopped = false
                            holdShown = true
                            withAnimation(.linear(duration: ChatStopHold.duration)) { progress = 1 }
                        } else if !stopped {
                            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                        }
                    }
                    .allowsHitTesting(!session.stopping)
                    .sensoryFeedback(.impact(weight: .light), trigger: pressing) { old, new in !old && new }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Stop")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Touch and hold for three seconds")
                    // VoiceOver: a double tap and hold passes the hold through; a double tap brings up the capsule,
                    // and the Stop Now action stops at once.
                    .accessibilityAction { holdShown = true; touches += 1 }
                    .accessibilityAction(named: "Stop Now") { stop() }
                    .accessibilityIdentifier("chat-stop")
                }
                Spacer(minLength: 8)
                if !expanded, !tools.isEmpty {
                    // Folded, the count; open, the log's own line counts (`ChatStepWindow`).
                    Text("\(tools.count) \(tools.count == 1 ? "step" : "steps")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                        .accessibilityHidden(true)
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
                ChatStepWindow(steps: steps, usage: ChatUsageText.text(session.usage, cost: session.agentKey == "pi"),
                               limits: limitsLine, openStep: openStep)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }
        }
        .coordinateSpace(.named(Self.space))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.agentName) is working")
        // Over the row, from its leading edge: the transcript above stays where it is.
        .overlay(alignment: .topLeading) {
            if holdShown && canStop && !session.stopping {
                ChatStopHold(pressing: pressing, progress: progress)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { holdHeight = $0 }
                    .padding(.leading, 12)
                    // Its foot just above the row's hairline.
                    .offset(y: -holdHeight - 6)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: holdShown)
        .sensoryFeedback(.impact(weight: .heavy), trigger: held)
        .task(id: touches) {
            // Untouched for a while, the capsule goes (not under VoiceOver, where reaching Stop's actions takes longer).
            guard holdShown, !pressing, !voiceOver else { return }
            do { try await Task.sleep(for: ChatStopHold.idle) } catch { return }
            if !pressing { holdShown = false }
        }
        .onChange(of: canStop) { _, can in if !can { holdShown = false; pressing = false; progress = 0 } }
        .onChange(of: expanded) { _, open in if open { readLimits() } }
        .onAppear { if expanded { readLimits() } }
        .alert(limitsWording?.title ?? "", isPresented: $askingLimits) {
            Button("Show Limits") {
                guard let agent = session.agentKey else { return }
                limits.accept(agent)
                readLimits()
            }
            Button("Not Now", role: .cancel) { if let agent = session.agentKey { limits.decline(agent) } }
        } message: {
            Text(limitsWording?.explanation ?? "")
        }
    }

    /// The agent's limits wording, for an agent that reports them (Claude Code, Codex).
    private var limitsWording: ChatLimitsWording? {
        session.agentKey.flatMap { ChatLimitsWording.of($0, opening: "unfold the working row", pace: "every 10 minutes") }
    }

    private var limitsKey: ChatLimitsReader.Key? {
        session.agentKey.map { ChatLimitsReader.Key(host: session.key.host, agent: $0) }
    }

    /// What the steps line shows of the limits: nothing for an agent that reports none, a helper without `chat.limits`
    /// or after Not Now; Show Limits until the user agreed; then the reading.
    private var limitsLine: ChatLimitsLine? {
        guard limitsWording != nil, session.limitsAvailable, let key = limitsKey, !limits.declined(key.agent) else { return nil }
        guard limits.consented(key.agent) else { return ChatLimitsLine(state: .ask, action: { askingLimits = true }) }
        switch limits.phases[key] {
        case .shown(let windows, _): return ChatLimitsLine(state: .windows(windows), action: {})
        case .failed(let reason): return ChatLimitsLine(state: .failed(reason), action: readLimits)
        case .reading, nil: return ChatLimitsLine(state: .reading, action: {})
        }
    }

    private func readLimits() {
        guard limitsWording != nil, session.limitsAvailable, let key = limitsKey else { return }
        limits.open(key) { [session] in try await session.limits() }
    }

    private func stop() {
        session.stop()
        held += 1
        holdShown = false
        pressing = false
        progress = 0
    }

    @ScaledMetric(relativeTo: .subheadline) private var glyph: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var disclosure: CGFloat = 28
    @Environment(\.chatPalette) private var palette
    /// Stop's square: the thread's ink (`ChatPalette`).
    private var stopInk: Color { palette.monochrome ?? palette.ink }
}

/// What holding Stop does, over the working row: a glass capsule saying "Hold to stop" that fills as Stop is held
/// (`progress`, 0 to 1 over `duration`) and empties if it is let go early. It only says; Stop itself is held, so the
/// thumb never moves. Untouched for `idle` it goes.
struct ChatStopHold: View {
    let pressing: Bool
    let progress: Double
    static let duration: TimeInterval = 3
    static let idle: Duration = .seconds(4)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stop.fill")
                .font(.footnote)
                .foregroundStyle(Color.destructive)
            Text(pressing ? "Keep holding…" : "Hold to stop")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(Color.destructive.opacity(0.28))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .clipShape(Capsule())
        .glassEffect(.regular, in: Capsule())
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-stop-hold")
    }
}

/// The session's usage on the steps line, what a click on the Mac's Thinking shows (`ChatSessionStats`): its tokens
/// in and out and Pi's cost. Nothing for an agent that reports neither count (its token counter is off) or no usage.
enum ChatUsageText {
    static func text(_ usage: ChatUsage?, cost: Bool) -> String? {
        guard let usage, usage.input != nil || usage.output != nil else { return nil }
        var text = "\(ChatUsage.count(usage.input)) in · \(ChatUsage.count(usage.output)) out"
        // Pi reports what the session cost; the other agents' reports are not shown as a price (the Mac's rule).
        if cost, let price = usage.costText { text += " · " + price }
        return text
    }
}

/// The agents' plan limits for the working row (the Mac's `ChatLimitsStore`): nothing is asked before the user agrees
/// for that agent (kept on this device), and then only as the row unfolds, at most every 10 minutes per host and agent;
/// readings stay in memory (docs/security.md, Agent limits). Not Now holds until the app next starts.
@MainActor @Observable
final class ChatLimitsReader {
    enum Phase: Equatable {
        case reading
        case shown([ChatLimitWindow], at: Date)
        /// The helper's reason ("Claude Code did not run its status line").
        case failed(String)
    }

    struct Key: Hashable {
        let host: UUID
        let agent: String
    }

    static let shared = ChatLimitsReader()
    /// How long a reading answers for itself.
    static let reuse: TimeInterval = 600
    static func consentKey(_ agent: String) -> String { "chatLimitsConsent." + agent }

    private(set) var phases: [Key: Phase] = [:]
    private var consents: Set<String> = []
    private var declines: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let clock: () -> Date

    init(defaults: UserDefaults? = .standard, clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.clock = clock
    }

    func consented(_ agent: String) -> Bool { consents.contains(agent) || defaults?.bool(forKey: Self.consentKey(agent)) == true }
    func declined(_ agent: String) -> Bool { declines.contains(agent) }

    func accept(_ agent: String) {
        consents.insert(agent)
        declines.remove(agent)
        defaults?.set(true, forKey: Self.consentKey(agent))
    }

    func decline(_ agent: String) { declines.insert(agent) }

    /// The row unfolded: reads unless one is under way or the last answered within `reuse`. A failure is not kept.
    func open(_ key: Key, read: @escaping @MainActor () async throws -> [ChatLimitWindow]) {
        guard consented(key.agent) else { return }
        switch phases[key] {
        case .reading: return
        case .shown(_, let at) where clock().timeIntervalSince(at) < Self.reuse: return
        default: break
        }
        phases[key] = .reading
        Task { @MainActor in
            do {
                let windows = try await read()
                phases[key] = .shown(windows, at: clock())
            } catch {
                phases[key] = .failed((error as? HelperFailure)?.message ?? error.localizedDescription)
            }
        }
    }
}

/// The plan's limits at the steps line's end (N4a): the longest window (the week) as a ring with its share and when it
/// resets; an account that still reports the 5-hour window shows that window's ring in the reset's place. The week's
/// name is left out where the line is too narrow (`named`). Dim as the rest of the line until a window passes 80%
/// (`LimitCaution`), then 95% (red), the Mac's thresholds. Before the user agreed, Show Limits; while reading, a
/// spinner; a failed read, Retry.
struct ChatLimitsLine: View {
    enum Shown: Equatable {
        case ask, reading
        /// Why the read failed, for VoiceOver's hint.
        case failed(String)
        case windows([ChatLimitWindow])
    }

    let state: Shown
    let action: () -> Void
    @Environment(\.chatPalette) private var palette
    var named = true
    var now = Date()

    /// The week (the longest window still running) and the shorter one shown beside it, if any.
    static func windows(_ all: [ChatLimitWindow], now: Date) -> (main: ChatLimitWindow, short: ChatLimitWindow?)? {
        let running = all.filter { $0.resets > now }.sorted { ($0.minutes ?? 0) > ($1.minutes ?? 0) }
        guard let main = running.first else { return nil }
        return (main, running.dropFirst().last)
    }

    /// "Resets Thu 9:40am", "Resets in 2h 18m".
    static func resets(_ window: ChatLimitWindow, now: Date) -> String {
        let text = window.resetText(now: now)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func tone(_ used: Int) -> AnyShapeStyle {
        used >= 95 ? AnyShapeStyle(Color.destructive) : used >= 80 ? AnyShapeStyle(Color.limitCaution) : AnyShapeStyle(.tertiary)
    }

    /// "Weekly limit, 83 percent used, resets Thu 9:40am. 5-hour limit, 42 percent used, resets in 2h 18m."
    static func spoken(_ windows: [ChatLimitWindow], now: Date) -> String {
        Self.windows(windows, now: now).map { pair in
            ([pair.main] + (pair.short.map { [$0] } ?? [])).map {
                "\($0.title) limit, \($0.used) percent used, \($0.resetText(now: now))"
            }.joined(separator: ". ")
        } ?? ""
    }

    var body: some View {
        switch state {
        case .ask:
            Button("Show limits", action: action)
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .accessibilityIdentifier("chat-limits-ask")
        case .reading:
            ProgressView().controlSize(.mini).accessibilityLabel("Reading limits")
        case .failed(let reason):
            Button("Retry limits", action: action)
                .buttonStyle(.plain)
                .foregroundStyle(palette.accent)
                .accessibilityHint("Couldn't read limits: \(reason)")
                .accessibilityIdentifier("chat-limits-retry")
        case .windows(let all):
            if let (main, short) = Self.windows(all, now: now) {
                HStack(spacing: 5) {
                    ChatLimitRing(used: main.used)
                    Text(named ? "\(main.title) \(main.used)%" : "\(main.used)%").foregroundStyle(Self.tone(main.used))
                    if let short {
                        Text("·")
                        ChatLimitRing(used: short.used)
                        Text("\(short.title) \(short.used)%").foregroundStyle(Self.tone(short.used))
                    } else {
                        Text((named ? "· " : "") + Self.resets(main, now: now))
                    }
                }
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spoken(all, now: now))
                .accessibilityIdentifier("chat-limits")
            }
        }
    }

    func named(_ named: Bool) -> Self {
        var copy = self
        copy.named = named
        return copy
    }
}

/// A limit's share as a ring filling clockwise from the top, in its tone over a faint track.
struct ChatLimitRing: View {
    let used: Int
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 12

    var body: some View {
        ZStack {
            Circle().stroke(Color.hairline, lineWidth: 2.5)
            Circle().trim(from: 0, to: CGFloat(min(100, max(0, used))) / 100)
                .stroke(ChatLimitsLine.tone(used), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The unfolded log (M5f): a line counting the steps and how many lie above and below the window, then a window four
/// steps tall that scrolls through them, the newest at its foot and followed while the foot is in view. The window is
/// as tall with one step as with forty, so the row keeps its height as steps come.
struct ChatStepWindow: View {
    let steps: [ChatStep]
    /// The session's tokens (`ChatUsageText`), after the count.
    var usage: String? = nil
    /// The plan's limits at the line's end.
    var limits: ChatLimitsLine? = nil
    var openStep: (ChatStep) -> Void
    static let visible = 4
    /// The window's scroll offset and one step's height with its rule: what lies above.
    @State private var offset: CGFloat = 0
    @State private var pitch: CGFloat = 0
    @State private var following = true

    var body: some View {
        let hidden = Self.hidden(count: steps.count, offset: offset, pitch: pitch)
        VStack(spacing: 0) {
            let caption = [Self.caption(steps, above: hidden.above, below: hidden.below), usage].compactMap { $0 }
                .joined(separator: " · ")
            // The limits keep their place; their name goes first, then the line's own end is cut.
            ViewThatFits(in: .horizontal) {
                line(caption, named: true)
                line(caption, named: false)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
            // Four empty rows set the window's height; the steps scroll over them.
            rows(Array(repeating: nil, count: Self.visible))
                .hidden()
                .accessibilityHidden(true)
                .overlay {
                    ScrollView {
                        rows(steps.map(Optional.some))
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .defaultScrollAnchor(.top, for: .alignment)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(following ? .bottom : .top, for: .sizeChanges)
                    .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in
                        offset = y
                    }
                    .onScrollGeometryChange(for: Bool.self, of: { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2
                    }) { _, atFoot in following = atFoot }
                }
        }
    }

    private func line(_ caption: String, named: Bool) -> some View {
        HStack(spacing: 8) {
            Text(caption).accessibilityIdentifier("chat-steps-caption")
            Spacer(minLength: 0)
            limits?.named(named)
        }
    }

    private func rows(_ steps: [ChatStep?]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Group {
                    if let step {
                        Button { openStep(step) } label: {
                            ChatStepLogRow(step: step, live: index == steps.count - 1 && step.running)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows what it did")
                    } else {
                        ChatStepLogRow(step: nil)
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { if index == 0 { pitch = $0 + Self.rule } }
                if index < steps.count - 1 { Rectangle().fill(Color.hairline.opacity(0.6)).frame(height: Self.rule) }
            }
        }
    }

    static let rule: CGFloat = 0.5

    /// How many steps lie wholly or mostly above the window and below it, scrolled `offset` with rows `pitch` apart.
    static func hidden(count: Int, offset: CGFloat, pitch: CGFloat) -> (above: Int, below: Int) {
        guard count > visible, pitch > 0 else { return (0, 0) }
        let above = min(count - visible, max(0, Int((offset / pitch).rounded())))
        return (above, count - visible - above)
    }

    /// "No steps yet", "3 steps · 1 thought", "12 steps · 5 above · 3 below": the tools counted as the folded row
    /// counts them, the thoughts apart (message details' rule), then what the window hides.
    static func caption(_ steps: [ChatStep], above: Int, below: Int) -> String {
        guard !steps.isEmpty else { return "No steps yet" }
        let thoughts = steps.count(where: { $0.kind == .think })
        var parts = [ChatTurnSummary.count(steps.count - thoughts, "step")]
        if thoughts > 0 { parts.append(ChatTurnSummary.count(thoughts, "thought")) }
        if above > 0 { parts.append("\(above) above") }
        if below > 0 { parts.append("\(below) below") }
        return parts.joined(separator: " · ")
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

/// One step of the live log (M5f): badge, what it acted on, its short result and its status (the Mac's step marks: a
/// check, a failure mark, a spinner on the live step and a dotted ring on another still running). Always two lines,
/// the result's kept when there is none, so every row is as tall; `nil` draws an empty row of that height.
struct ChatStepLogRow: View {
    let step: ChatStep?
    var live = false
    @Environment(\.chatPalette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ChatStepBadge(kind: step?.kind ?? .read)
                .opacity(step == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(step?.title ?? " ")
                    .scaledFont(13.5, relativeTo: .footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                (detailText ?? Text(verbatim: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let step {
                status(step)
                    .frame(width: 18, height: 20)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .opacity(live || step == nil ? 1 : 0.72)
    }

    @ViewBuilder private func status(_ step: ChatStep) -> some View {
        if step.running && live {
            ProgressView().controlSize(.mini).accessibilityLabel("Running")
        } else {
            let symbol = step.failed ? "exclamationmark.circle" : step.running ? "circle.dotted" : "checkmark.circle"
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(palette.monochrome ?? (step.failed ? Color.caution : step.running ? Color.secondary : Color.added))
                .accessibilityLabel(step.failed ? "Failed" : step.running ? "Running" : "Completed")
        }
    }

    private var detailText: Text? {
        guard let step else { return nil }
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
