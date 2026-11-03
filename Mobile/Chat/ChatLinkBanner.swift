import SwiftUI

/// M4c: a thin amber banner under the segmented control while the host is away, counting since it dropped. Nothing
/// modal: the thread stays readable and the composer queues.
struct ChatLinkBanner: View {
    let link: HostLink
    let host: String
    /// Why the host is not connected yet (`HostSession.problem`): a second line while reconnecting.
    var problem: String? = nil
    /// The state amber in dark; a darker amber in light, which reads on the light canvas.
    private static let amber = Color.caution

    /// The banner's line, or nil when connected.
    static func title(_ link: HostLink, host: String) -> String? {
        switch link {
        case .connected: nil
        case .reconnecting: "Reconnecting to \(host)"
        case .connecting, .authenticating, .bootstrapping: "Connecting to \(host)"
        case .disconnected: "\(host) is offline"
        case .failed: "Can’t reach \(host)"
        }
    }

    static func spoken(_ link: HostLink, title: String, problem: String? = nil) -> String {
        if case .failed(let reason) = link { return title + ", " + reason }
        return [title, problem].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        if let title = Self.title(link, host: host) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    ChatWaitingDots(color: Self.amber)
                    Text(title).font(.footnote.weight(.semibold)).fittingLine()
                    Spacer(minLength: 4)
                    if case .reconnecting(_, let since, _) = link {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(ChatTurnSummary.elapsed(context.date.timeIntervalSince(since)))
                                .monospacedDigit()
                                .foregroundStyle(Self.amber.opacity(0.7))
                        }
                    } else if case .failed(let reason) = link {
                        Text(reason).lineLimit(1).foregroundStyle(Self.amber.opacity(0.7))
                    }
                }
                if let problem, !link.isConnected {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Self.amber.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 23)
                }
            }
            .font(.footnote)
            .foregroundStyle(Self.amber)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(Color.stateWorking.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            // The title (and a failure's reason), not the counting seconds: VoiceOver reads it once.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(link, title: title, problem: problem))
        }
    }
}

/// Three dots rising in turn (hx-dot, 1.3 s), in the compositor (`ChatDotsLoop`) and stopped while scrolled away; still
/// with Reduce Motion. An `animationDateOverride` (tests) draws that instant in SwiftUI.
struct ChatWaitingDots: View {
    @Environment(\.animationDateOverride) private var fixedDate
    var color: Color
    var size: CGFloat = 5
    @ReduceMotion private var reduceMotion
    @State private var onScreen = true
    static let period = 1.3
    /// Each dot's delay after the one before it.
    static let lag = 0.18
    static let spacing: CGFloat = 3

    var body: some View {
        if reduceMotion {
            HStack(spacing: Self.spacing) { ForEach(0..<3, id: \.self) { _ in Self.dot(color: color, size: size) } }
        } else if let fixedDate {
            let time = fixedDate.timeIntervalSinceReferenceDate
            HStack(spacing: Self.spacing) {
                ForEach(0..<3, id: \.self) { index in
                    let lift = Self.lift(phase: (time - Double(index) * Self.lag).truncatingRemainder(dividingBy: Self.period) / Self.period)
                    Self.dot(color: color, size: size)
                        .opacity(0.35 + 0.65 * lift)
                        .offset(y: -2 * lift)
                }
            }
        } else {
            ChatDotsLoop(color: color, size: size, moving: onScreen)
                .onScreen($onScreen)
                .accessibilityHidden(true)
        }
    }

    static func dot(color: Color, size: CGFloat) -> some View {
        Circle().fill(color).frame(width: size, height: size)
    }

    /// How far a dot has risen (0 to 1) at `phase` of its period: up over the first 0.3, down over the next, then still.
    static func lift(phase: Double) -> Double {
        phase < 0 ? 0 : phase < 0.3 ? phase / 0.3 : phase < 0.6 ? (0.6 - phase) / 0.3 : 0
    }
}

/// The haptic for the host's link changing while a thread is open: a warning as it drops once the app has been in use
/// for a moment, a success as it comes back after being away long enough for the banner to be read. A drop in the
/// background, and the reconnect that follows returning to the app or opening the thread, get none.
struct ChatLinkHaptic {
    /// How long the app is in use before a drop warns, and how long the link is away before its return is told.
    static let settle: TimeInterval = 3
    /// Counts the haptics given: what `sensoryFeedback` follows.
    private(set) var count = 0
    private(set) var feedback: SensoryFeedback?
    private var dropped: Date?
    private var active: Date?

    init(now: Date = Date()) { active = now }

    mutating func scene(active isActive: Bool, now: Date = Date()) {
        active = isActive ? active ?? now : nil
    }

    mutating func link(connected: Bool, now: Date = Date()) {
        guard let active, now.timeIntervalSince(active) >= Self.settle else {
            dropped = nil
            return
        }
        if !connected {
            guard dropped == nil else { return }
            dropped = now
            give(.warning)
        } else if let dropped {
            self.dropped = nil
            if now.timeIntervalSince(dropped) >= Self.settle { give(.success) }
        }
    }

    private mutating func give(_ haptic: SensoryFeedback) {
        feedback = haptic
        count += 1
    }
}

/// Gives `ChatLinkHaptic`'s haptics as the link changes.
struct ChatLinkHaptics: ViewModifier {
    let connected: Bool
    @Binding var haptic: ChatLinkHaptic

    func body(content: Content) -> some View {
        content
            .onChange(of: connected) { _, connected in haptic.link(connected: connected) }
            .sensoryFeedback(trigger: haptic.count) { _, _ in haptic.feedback }
    }
}
