import SwiftUI

/// One item of a thread page as the phone's thread draws it, at watch size: the user's message right-aligned in the
/// pink bubble, the agent's in the grey one (its turn caption under it), Claude's or Pi's thinking in an agent bubble
/// of its own, a notice small and centred. Tools are not rows (`ThreadScreen.items` leaves them out).
struct ThreadItemRow: View {
    let item: WatchItem
    /// "Claude Code", for VoiceOver.
    var agent: String?

    var body: some View {
        Group {
            switch item.kind {
            case .user:
                ThreadBubble(side: .user) { Text(item.text) }
            case .agent:
                VStack(alignment: .leading, spacing: 2) {
                    ThreadBubble(side: .agent) { Text(item.text) }
                    if let caption = item.caption {
                        Text(caption).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 6)
                    }
                }
            case .thinking:
                // In the same colours and font as its messages, as the phone's thread shows it.
                ThreadBubble(side: .agent) { Text(item.text) }
            case .tool, .notice, .unknown:
                Text(item.text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(item, agent: agent))
    }

    static func accessibilityLabel(_ item: WatchItem, agent: String?) -> String {
        switch item.kind {
        case .user: return "You: " + item.text
        case .agent: return [(agent ?? "Agent") + ": " + item.text, item.caption].compactMap { $0 }.joined(separator: ", ")
        case .thinking: return (agent ?? "Agent") + ": " + item.text
        case .tool, .notice, .unknown: return item.text
        }
    }
}

/// The phone's bubble (ChatBubble, M4a) at watch size: the user's on the right in pink with dark text, the agent's on
/// the left in grey; a faded user bubble is a message on its way.
struct ThreadBubble<Content: View>: View {
    enum Side { case user, agent }
    let side: Side
    var faded = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            if side == .user { Spacer(minLength: 18) }
            content
                .font(.footnote)
                .foregroundStyle(side == .user ? AgentsColor.onPink : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(side == .user ? AgentsColor.pink.opacity(faded ? 0.55 : 1) : AgentsColor.agentBubble,
                            in: UnevenRoundedRectangle(cornerRadii: side == .user
                                ? .init(topLeading: 14, bottomLeading: 14, bottomTrailing: 4, topTrailing: 14)
                                : .init(topLeading: 14, bottomLeading: 4, bottomTrailing: 14, topTrailing: 14),
                                style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            if side == .agent { Spacer(minLength: 0) }
        }
    }
}

/// The phone's working row (ChatWorkingRow), reduced: what the agent does and for how long, in amber; Stop at its
/// trailing end while the conversation can take it (the phone's quiet disc with its square, a 44 pt target), away from
/// where a crown scroll or a flick ends at the composer.
struct ThreadWorkingRow: View {
    let activity: String?
    let since: Date?
    /// Stop's tap (the thread asks first); nil while Stop is not offered.
    var stop: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .symbolEffect(.pulse)
                        .accessibilityHidden(true)
                    Text(Self.text(activity: activity, since: since, now: context.date))
                        .font(.footnote)
                        .lineLimit(1)
                }
                .foregroundStyle(AgentsColor.working)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            if let stop {
                Button(action: stop) {
                    StopDisc()
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
                .accessibilityHint(Self.stopHint)
                .accessibilityIdentifier("thread.stop")
            }
        }
    }

    /// "editing files 4m 2s", "thinking 48s", as the phone's row reads (its activity word, then the elapsed time).
    static func text(activity: String?, since: Date?, now: Date) -> String {
        let word = activity?.isEmpty == false ? activity! : "Working"
        guard let since else { return word }
        return word + " " + WatchTime.elapsed(now.timeIntervalSince(since))
    }

    static let stopHint = "Stops the agent; queued messages wait until Resume"

    /// The confirmation's destructive button: "Stop Claude", "Stop Codex", "Stop Pi", else the agent's own label, else
    /// "Stop the agent".
    static func stopTitle(agent: String?) -> String {
        "Stop " + (AgentsGlyph.shortName(agent).flatMap { $0.isEmpty ? nil : $0 } ?? "the agent")
    }

    /// The confirmation's line.
    static let stopMessage = "Queued messages wait until Resume."
}

/// The phone's working-row Stop (`ChatWorkingDisc`): a quiet disc with the primary square on it.
struct StopDisc: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.primary.opacity(0.85))
            .frame(width: 9, height: 9)
            .frame(width: 26, height: 26)
            .background(Color.white.opacity(0.16), in: Circle())
    }
}
