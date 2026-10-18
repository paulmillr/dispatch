import SwiftUI

/// M4c: a thin amber banner under the segmented control while the host is away, counting since it dropped. Nothing
/// modal: the thread stays readable and the composer queues.
struct ChatLinkBanner: View {
    let link: HostLink
    let host: String
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

    static func spoken(_ link: HostLink, title: String) -> String {
        if case .failed(let reason) = link { return title + ", " + reason }
        return title
    }

    var body: some View {
        if let title = Self.title(link, host: host) {
            HStack(spacing: 8) {
                ChatWaitingDots(color: Self.amber)
                Text(title).font(.footnote.weight(.semibold)).fittingLine()
                Spacer(minLength: 4)
                if case .reconnecting(_, let since) = link {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(ChatTurnSummary.elapsed(context.date.timeIntervalSince(since)))
                            .monospacedDigit()
                            .foregroundStyle(Self.amber.opacity(0.7))
                    }
                } else if case .failed(let reason) = link {
                    Text(reason).lineLimit(1).foregroundStyle(Self.amber.opacity(0.7))
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
            .accessibilityLabel(Self.spoken(link, title: title))
        }
    }
}

/// Three dots rising in turn (hx-dot, 1.3 s); still with Reduce Motion.
struct ChatWaitingDots: View {
    @Environment(\.animationDateOverride) private var fixedDate
    var color: Color
    var size: CGFloat = 5
    @ReduceMotion private var reduceMotion
    var body: some View {
        if reduceMotion {
            HStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(color).frame(width: size, height: size) } }
        } else {
            TimelineView(.animation) { context in
                let time = (fixedDate ?? context.date).timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (time - Double(index) * 0.18).truncatingRemainder(dividingBy: 1.3) / 1.3
                        let lift = phase < 0 ? 0 : phase < 0.3 ? phase / 0.3 : phase < 0.6 ? (0.6 - phase) / 0.3 : 0
                        Circle().fill(color).frame(width: size, height: size)
                            .opacity(0.35 + 0.65 * lift)
                            .offset(y: -2 * lift)
                    }
                }
            }
        }
    }
}
