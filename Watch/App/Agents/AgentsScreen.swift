import SwiftUI

/// The Agents tab: every conversation across hosts, the phone's order. Rows are NavigationLink(value: WatchConversationKey).
/// A host only the phone's screen can bring back says so under the rows (`WatchModel.blockedMessage`); the toolbar's
/// button asks the phone to retry its hosts (`refresh`).
struct AgentsScreen: View {
    let model: WatchModel

    init(model: WatchModel) {
        self.model = model
    }

    var body: some View {
        let rows = model.conversations
        let blocked = Self.blocked(hosts: model.hosts, conversations: rows)
        TimelineView(.everyMinute) { context in
            List {
                // A row, not an overlay: it stays under the shell's notice banner and scrolls at large text sizes. Before
                // the first snapshot it is the only word (the shell's banner leaves `waiting` to it).
                if rows.isEmpty {
                    AgentsEmptyState(waiting: model.snapshot == nil).listRowBackground(Color.clear)
                }
                ForEach(rows) { conversation in
                    NavigationLink(value: conversation.key) {
                        AgentsRow(conversation: conversation, host: model.host(conversation.host), now: context.date)
                    }
                }
                if !blocked.isEmpty {
                    Section {
                        ForEach(blocked, id: \.host.id) { entry in
                            AgentsBlockedNote(message: entry.message)
                        }
                    }
                }
            }
        }
        .navigationTitle("Agents")
        .toolbar {
            // The trailing slot is the shell's needs-you badge.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.refreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.refreshing)
                .accessibilityLabel("Refresh")
                .accessibilityHint("Asks your iPhone to reconnect its hosts")
            }
        }
    }

    /// The hosts to name under the rows: blocked ones with a row listed (a blocked host without agents says so in
    /// Spaces), each with what the phone must do, in the user's host order.
    static func blocked(hosts: [WatchHost], conversations: [WatchConversation]) -> [(host: WatchHost, message: String)] {
        let listed = Set(conversations.map(\.host))
        return hosts.compactMap { host in
            guard listed.contains(host.id), let message = WatchModel.blockedMessage(host) else { return nil }
            return (host, message)
        }
    }
}

/// One Agents row, the phone's grammar (MobileRow, M3a) at watch size: the gutter dot, the name on up to two lines, then
/// the agent's mark in the host's tint with "host · space" and the time, then the preview on up to two lines. The phone's
/// 46 pt disc would take a quarter of a 42 mm screen; the mark carries its tint instead. Dimmed while its data is
/// last-known (`stale`).
struct AgentsRow: View {
    let conversation: WatchConversation
    let host: WatchHost?
    let now: Date

    static let dotSize: CGFloat = 8

    var body: some View {
        let tint = Color(watchHex: host?.tint)
        let dot = AgentsDot.of(conversation)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(dot?.color ?? .clear)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    AgentsMark(agent: conversation.agent, tint: tint)
                    Text(Self.subtitle(conversation, host: host) ?? "")
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let time = conversation.lastActivity.map({ WatchTime.relative($0, now: now) }) {
                        Text(time)
                            .foregroundStyle(conversation.stale ? .tertiary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.caption2)
                if let line = Self.line(conversation) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 3)
        .opacity(conversation.stale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(conversation, host: host, now: now))
        .accessibilityValue(dot?.accessibilityLabel ?? "")
    }

    /// "studio · dispatch": the host, then the space it runs in; " · muted" as the phone's detail adds it.
    static func subtitle(_ conversation: WatchConversation, host: WatchHost?) -> String? {
        var parts = [host?.name, conversation.space].compactMap { $0?.isEmpty == false ? $0 : nil }
        if conversation.muted { parts.append("muted") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The preview, else the agent's attention line (the phone's subtitle). A needs-you row whose agent waits on the
    /// terminal says what it waits for.
    static func line(_ conversation: WatchConversation) -> String? {
        let preview = conversation.preview?.isEmpty == false ? conversation.preview : nil
        let attention = conversation.attention?.isEmpty == false ? conversation.attention : nil
        if conversation.needsYou, let attention { return attention }
        return preview ?? attention
    }

    /// VoiceOver: the name, the agent, the detail, the time, "Needs you" or "Working", then the line.
    static func accessibilityLabel(_ conversation: WatchConversation, host: WatchHost?, now: Date) -> String {
        let state = conversation.needsYou ? "Needs you" : conversation.busy ? "Working" : nil
        return [conversation.name, conversation.agent, subtitle(conversation, host: host),
                conversation.lastActivity.map { WatchTime.ago($0, now: now) }, state, line(conversation)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }
}

/// The agent's mark, in the host's tint, at the text's size.
struct AgentsMark: View {
    let agent: String?
    let tint: Color

    var body: some View {
        Group {
            switch AgentsGlyph.agent(agent) {
            case .symbol(let name): Image(systemName: name).fontWeight(.bold)
            case .letter(let letter): Text(letter).fontWeight(.bold).fontDesign(.serif)
            }
        }
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }
}

/// "Open Dispatch on your iPhone to connect pi": a host whose rows wait for the phone's screen.
struct AgentsBlockedNote: View {
    let message: String

    var body: some View {
        Label {
            Text(message).font(.footnote)
        } icon: {
            Image(systemName: "iphone").foregroundStyle(AgentsColor.working)
        }
        .foregroundStyle(.secondary)
        .listRowBackground(Color.clear)
    }
}

/// No conversations: the phone's copy ("No agents yet"), pointed at the phone, where agents start. Before the first
/// snapshot: waiting for the phone, in the shell's banner words (`WatchNotice.waiting`).
struct AgentsEmptyState: View {
    var waiting = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: waiting ? "iphone.radiowaves.left.and.right" : "bubble.left.and.bubble.right")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(waiting ? "Waiting for your iPhone" : "No agents yet")
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(waiting ? "Keep it nearby with Dispatch installed."
                 : "Start an agent in a space on your iPhone and it shows up here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
