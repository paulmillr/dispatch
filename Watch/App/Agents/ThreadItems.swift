import SwiftUI

/// One item of a thread page as the phone's thread draws it, at watch size: the user's message right-aligned in the
/// pink bubble, the agent's in the grey one (its turn caption under it), Claude's thinking muted and italic, a tool as
/// one line with its state, a notice small and centred.
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
                Text(item.text)
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            case .tool:
                ThreadToolLine(item: item)
            case .notice, .unknown:
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

    /// The tool's state as a symbol: running, failed, done. Nil for anything but a tool.
    static func symbol(for item: WatchItem) -> String? {
        guard item.kind == .tool else { return nil }
        if item.running { return "ellipsis.circle" }
        return item.failed ? "xmark.circle.fill" : "checkmark.circle.fill"
    }

    /// "Run · cargo test · ok": the step's kind, what it acted on, its short result (docs/watch.md, Thread).
    static func toolLine(_ item: WatchItem) -> String {
        [item.tool ?? "Tool", item.text, item.detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    static func accessibilityLabel(_ item: WatchItem, agent: String?) -> String {
        switch item.kind {
        case .user: return "You: " + item.text
        case .agent: return [(agent ?? "Agent") + ": " + item.text, item.caption].compactMap { $0 }.joined(separator: ", ")
        case .thinking: return "Thinking: " + item.text
        case .tool:
            let state = item.running ? "running" : item.failed ? "failed" : "done"
            return toolLine(item) + ", " + state
        case .notice, .unknown: return item.text
        }
    }
}

/// A tool step on one line: its state symbol, the kind in bold, then what it acted on in mono.
struct ThreadToolLine: View {
    let item: WatchItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let symbol = ThreadItemRow.symbol(for: item) {
                Image(systemName: symbol)
                    .font(.caption2)
                    .foregroundStyle(item.running ? AgentsColor.working : item.failed ? AgentsColor.destructive : AgentsColor.added)
                    .symbolEffect(.pulse, isActive: item.running)
            }
            let rest = [item.text, item.detail].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
            Text("\(Text(item.tool ?? "Tool").bold()) \(Text(rest).monospaced())")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
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

/// The phone's working row (ChatWorkingRow), reduced: what the agent does and for how long, in amber.
struct ThreadWorkingRow: View {
    let activity: String?
    let since: Date?

    var body: some View {
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
    }

    /// "editing files 4m 2s", "thinking 48s", as the phone's row reads (its activity word, then the elapsed time).
    static func text(activity: String?, since: Date?, now: Date) -> String {
        let word = activity?.isEmpty == false ? activity! : "Working"
        guard let since else { return word }
        return word + " " + WatchTime.elapsed(now.timeIntervalSince(since))
    }
}
