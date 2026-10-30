import AppKit
import SwiftUI

extension ChatCoordinator {
    /// Sends a message on its flight from `from` to `to`, if the chat shows both ends: an exact copy of the destination
    /// leaves where the text was and lands on it. Reduce Motion, attachments (their chips don't fly), the radio log's
    /// own messages, a transcript scrolled away from its end and one held off screen keep the plain entrance.
    func launchFlight(_ session: ChatSession, text: String, hasAttachments: Bool,
                      from: ChatSendFlight.Place, to: ChatSendFlight.Place) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, session.showChat, !session.transcriptHeld, !hasAttachments,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ChatThemeStore.shared.current.radioLog,
              var source = session.flightFrames[from] else { return }
        if case .prompt = to, !session.atBottom { return }
        // The composer reports its editor; the text starts inside its insets (ChatComposer's textContainerInset).
        if from == .composer {
            source = CGRect(x: source.minX + 12, y: source.minY + 5, width: max(0, source.width - 24), height: max(0, source.height - 10))
        }
        if case .queued(let id) = from {
            session.flownQueuedIDs = session.flownQueuedIDs.filter { flown in session.queuedMessages.contains { $0.id == flown } }
            session.flownQueuedIDs.insert(id)
        }
        session.sendFlight = ChatSendFlight(id: System.uuid(), text: text, from: from, to: to, source: source,
                                            started: ProcessInfo.processInfo.systemUptime)
    }
}

/// Reports where a place a message flies between is laid out.
struct ChatFlightAnchor: View {
    let place: ChatSendFlight.Place
    let frames: ChatFlightFrames
    /// Stands in for a place not laid out itself (ChatFlightFrames.absorbs).
    var absorbing = false

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(ChatFlightFrames.space))
            Color.clear
                .onAppear { frames.report(place, at: frame, absorbing: absorbing) }
                .onChange(of: frame) { _, frame in frames.report(place, at: frame, absorbing: absorbing) }
                .onDisappear { frames.withdraw(place, at: frame) }
        }
    }
}

/// The message in flight, over the whole chat. Its destination is laid out a frame after the send, and may still move
/// (the transcript follows its end, the queue grows): the copy waits at the source until it is, then follows it.
struct ChatSendFlightLayer: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    /// A user bubble's widest, as the transcript lays it out (ChatUserMessage.maxWidth).
    let bubbleWidth: CGFloat
    static let duration: TimeInterval = 0.42
    /// How long a flight waits for its destination before it gives up and the destination just appears.
    static let patience: TimeInterval = 0.3

    var body: some View {
        if let flight = session.sendFlight {
            TimelineView(.animation) { _ in
                ghost(flight, now: ProcessInfo.processInfo.systemUptime)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: flight.id) {
                while !Task.isCancelled, session.sendFlight?.id == flight.id {
                    let now = ProcessInfo.processInfo.systemUptime
                    let departed = session.flightFrames.departures[flight.id]
                    if departed.map({ now - $0 >= Self.duration }) ?? (now - flight.started >= Self.patience) {
                        session.flightFrames.departures[flight.id] = nil
                        session.sendFlight = nil
                    }
                    try? await Task.sleep(for: .milliseconds(15))
                }
            }
        }
    }

    @ViewBuilder private func ghost(_ flight: ChatSendFlight, now: TimeInterval) -> some View {
        let frames = session.flightFrames
        if let destination = frames[flight.to] {
            let departed = frames.departures[flight.id] ?? now
            let _ = { if frames.departures[flight.id] == nil { frames.departures[flight.id] = now } }()
            copy(flight, destination: destination, t: min(1, (now - departed) / Self.duration))
        } else if now - flight.started < Self.patience {
            // Not laid out yet: the copy holds the text where it was, so it never blinks out between the two.
            copy(flight, destination: nil, t: 0)
        }
    }

    /// The message at `t` (0 → 1) of the way. It leaves as an exact copy of its source (the composer's text, or the
    /// queue row's) and arrives as one of its destination (the bubble, or the row's text): the two ride one text origin,
    /// sized between the two fonts, the first fading as the second comes in, so neither end jumps.
    @ViewBuilder private func copy(_ flight: ChatSendFlight, destination: CGRect?, t: Double) -> some View {
        let travel = Self.spring(t), eased = 1 - pow(1 - t, 3)
        // Into the folded queue's count, nothing arrives: the leaving copy fades on its way there.
        let absorbed = session.flightFrames.absorbs(flight.to)
        let leaving = 1 - Self.smoothstep(0, 0.45, t), arriving = absorbed ? 0 : Self.smoothstep(0.08, 0.55, t)
        let typography = theme.typography
        // The composer's text is a point larger than a message's: the arriving copy grows from that, the leaving one
        // shrinks to the message's.
        let ratio = flight.from == .composer ? typography.replySize / typography.pointSize() : 1
        let arrivingScale = ratio + (1 - ratio) * travel, leavingScale = arrivingScale / ratio
        // A bubble's text sits inside its padding (ChatUserBubble).
        let padding: CGSize = { if case .prompt = flight.to { return CGSize(width: 12, height: 8) } else { return .zero } }()
        let start = flight.source.origin
        let end = destination.map { CGPoint(x: $0.minX + padding.width, y: $0.minY + padding.height) } ?? start
        let origin = CGPoint(x: start.x + (end.x - start.x) * travel, y: start.y + (end.y - start.y) * travel)
        ZStack(alignment: .topLeading) {
            source(flight)
                .scaleEffect(leavingScale, anchor: .topLeading)
                .opacity(leaving)
                .offset(x: origin.x, y: origin.y)
            Group {
                switch flight.to {
                case .prompt:
                    ChatUserBubble(text: flight.text, fill: eased)
                        .frame(width: bubbleWidth, alignment: .leading)
                case .queued:
                    Text(flight.text).font(typography.body).foregroundStyle(theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(width: destination?.width ?? flight.source.width, alignment: .leading)
                case .composer:
                    EmptyView()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(arrivingScale, anchor: .topLeading)
            .opacity(arriving)
            .offset(x: origin.x - padding.width * arrivingScale, y: origin.y - padding.height * arrivingScale)
        }
    }

    /// The text as it sat where it left: the composer's editor (its font, color and wrap) or the queue row's.
    @ViewBuilder private func source(_ flight: ChatSendFlight) -> some View {
        switch flight.from {
        case .composer:
            Text(flight.text).font(Font(theme.typography.reply)).foregroundStyle(theme.ink)
                .frame(width: flight.source.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .queued:
            Text(flight.text).font(theme.typography.body).foregroundStyle(theme.muted)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: flight.source.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .prompt:
            EmptyView()
        }
    }

    nonisolated static func smoothstep(_ from: Double, _ to: Double, _ t: Double) -> Double {
        let x = min(1, max(0, (t - from) / (to - from)))
        return x * x * (3 - 2 * x)
    }

    /// A damped spring's step response, settled (within a point on a chat's distances) by t = 1.
    nonisolated static func spring(_ t: Double) -> Double {
        guard t < 1 else { return 1 }
        let damping = 0.8, frequency = 17.0, seconds = t * duration
        let decay = damping * frequency, damped = frequency * (1 - damping * damping).squareRoot()
        return 1 - exp(-decay * seconds) * (cos(damped * seconds) + decay / damped * sin(damped * seconds))
    }
}

/// A sent message's bubble: its text in the transcript's user bubble. `fill` fades the bubble's background (a message
/// in flight takes it on as it leaves the composer).
struct ChatUserBubble: View {
    @Environment(\.chatTheme) private var theme
    let text: String
    var fill: Double = 1

    var body: some View {
        ChatMarkdown(text: text, fillWidth: false)
            .font(theme.typography.body)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.ink.opacity(0.08 * fill), in: UnevenRoundedRectangle(
                topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 3, topTrailingRadius: 10))
    }
}
