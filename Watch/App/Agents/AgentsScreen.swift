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
                    .id(conversation.key)
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

/// One Agents row, the phone's new row grammar at watch size (mockups K1): the gutter dot, the agent's glyph in its own
/// column, then the name (two lines), the state line (two lines: the current step and how long it has run while
/// working, what it asks while it needs you, in primary, else its last message) and a caption with "host · space" in the
/// host's tint and the time. Dimmed while its data is last-known (`stale`).
struct AgentsRow: View {
    let conversation: WatchConversation
    let host: WatchHost?
    let now: Date

    static let dotSize: CGFloat = 8

    var body: some View {
        let tint = Color(watchHex: host?.tint)
        let dot = AgentsDot.of(conversation)
        HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(dot?.color ?? .clear)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .padding(.top, 5)
                .accessibilityHidden(true)
            AgentGlyph(agent: conversation.agent, size: 13)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                stateLine
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Self.subtitle(conversation, host: host) ?? "")
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let time = conversation.lastActivity.map({ WatchTime.relative($0, now: now) }) {
                        Text(time)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 1)
        .opacity(conversation.stale ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(conversation, host: host, now: now))
        .accessibilityValue(dot?.accessibilityLabel ?? "")
    }

    /// The state line; a working one ticks its seconds (only that line redraws).
    @ViewBuilder private var stateLine: some View {
        if conversation.busy, !conversation.needsYou, let since = conversation.workingSince {
            TimelineView(.periodic(from: since, by: 1)) { context in
                lineText(Self.line(conversation, now: context.date))
            }
        } else {
            lineText(Self.line(conversation, now: now))
        }
    }

    @ViewBuilder private func lineText(_ line: String?) -> some View {
        if let line {
            Text(line)
                .font(.caption)
                .foregroundStyle(conversation.needsYou ? Color.primary : Color.secondary)
                .lineLimit(2)
        }
    }

    /// "studio · dispatch": the host, then the space it runs in; " · muted" as the phone's detail adds it.
    static func subtitle(_ conversation: WatchConversation, host: WatchHost?) -> String? {
        var parts = [host?.name, conversation.space].compactMap { $0?.isEmpty == false ? $0 : nil }
        if conversation.muted { parts.append("muted") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The line under the name, by state: needs you, what it asks (the approval's command, the question; else the
    /// agent's attention line); working, the current step and its elapsed time ("Editing Sidebar.tsx · 48s"); else the
    /// last message.
    static func line(_ conversation: WatchConversation, now: Date) -> String? {
        func text(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }
        if conversation.needsYou {
            return text(conversation.waitingText) ?? text(conversation.attention) ?? text(conversation.preview) ?? "Needs you"
        }
        if conversation.busy {
            let step = text(conversation.step) ?? "Working"
            guard let since = conversation.workingSince else { return step }
            return step + " · " + WatchTime.elapsed(now.timeIntervalSince(since))
        }
        return text(conversation.preview) ?? text(conversation.attention)
    }

    /// VoiceOver: the name, the agent, the detail, the time, "Needs you" or "Working", then the line.
    static func accessibilityLabel(_ conversation: WatchConversation, host: WatchHost?, now: Date) -> String {
        let state = conversation.needsYou ? "Needs you" : conversation.busy ? "Working" : nil
        return [conversation.displayTitle, conversation.agent, subtitle(conversation, host: host),
                conversation.lastActivity.map { WatchTime.ago($0, now: now) }, state, line(conversation, now: now)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
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
