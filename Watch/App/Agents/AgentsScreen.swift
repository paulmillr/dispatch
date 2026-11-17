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
        let sections = Self.sections(rows, hosts: model.hosts)
        List {
            // A row, not an overlay: it stays under the shell's notice banner and scrolls at large text sizes. Before
            // the first snapshot it is the only word (the shell's banner leaves `waiting` to it).
            if rows.isEmpty {
                AgentsEmptyState(waiting: model.snapshot == nil).listRowBackground(Color.clear)
            }
            ForEach(sections.reached) { row($0) }
            if !sections.offline.isEmpty {
                Section {
                    ForEach(sections.offline) { row($0) }
                } header: {
                    Text("Offline · \(sections.offline.count)")
                        .accessibilityLabel("Offline, \(sections.offline.count)")
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

    private func row(_ conversation: WatchConversation) -> some View {
        NavigationLink(value: conversation.key) {
            // Each row keeps its own minute clock: a TimelineView around the List with another inside a row (a
            // working row's seconds) relaid the list out at full CPU for as long as the row showed.
            TimelineView(.everyMinute) { context in
                AgentsRow(conversation: conversation, host: model.host(conversation.host), now: context.date)
            }
        }
        .id(conversation.key)
    }

    /// The rows in the phone's order, those of hosts not reached now (offline, or unknown) apart at the end, as the
    /// phone's Offline section: their rows are what the phone last saw.
    static func sections(_ rows: [WatchConversation], hosts: [WatchHost]) -> (reached: [WatchConversation], offline: [WatchConversation]) {
        let reached = Set(hosts.filter { $0.state != .offline }.map(\.id))
        return (rows.filter { reached.contains($0.host) }, rows.filter { !reached.contains($0.host) })
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

/// One Agents row, the phone's row grammar (A1) at watch size: the gutter dot alone in the leading column (no agent
/// mark: every row is an agent; the phone's moving thinking glyph would redraw the list for as long as an agent works),
/// then the name (two lines, a muted row's bell beside it), what it is doing, and a caption with "host · space" in grey
/// and the time. Working: what the agent last said (else its prompt) over the step ("Run · 4 steps"), and the time
/// counts the turn in amber, as the phone's time column; needing you, what it asks on two lines in primary; idle, its
/// last message on one line (a wrist reads more rows at once). Dimmed while its data is last-known (`stale`).
struct AgentsRow: View {
    let conversation: WatchConversation
    let host: WatchHost?
    let now: Date

    static let dotSize: CGFloat = 8

    var body: some View {
        let dot = AgentsDot.of(conversation)
        HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(dot?.color ?? .clear)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(conversation.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if conversation.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                lines
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Self.subtitle(conversation, host: host) ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    time
                        .lineLimit(1)
                        .fixedSize()
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

    /// Working: the note over the step, one line each; else the state line.
    @ViewBuilder private var lines: some View {
        if Self.working(conversation) {
            if let note = Self.text(conversation.note) {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 3) {
                if let symbol = conversation.stepSymbol {
                    Image(systemName: symbol).font(.caption2.weight(.semibold)).accessibilityHidden(true)
                }
                Text(Self.line(conversation, now: now) ?? "Working…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if let line = Self.line(conversation, now: now) {
            Text(line)
                .font(.caption)
                .foregroundStyle(conversation.needsYou ? Color.primary : Color.secondary)
                .lineLimit(Self.lineLimit(conversation))
        }
    }

    /// The turn's elapsed time while it runs (amber, every second; only this text redraws), else when it last changed.
    @ViewBuilder private var time: some View {
        if Self.working(conversation), let since = conversation.workingSince {
            TimelineView(.periodic(from: Ticks.anchor, by: 1)) { context in
                Text(WatchTime.elapsed(context.date.timeIntervalSince(since)))
                    .monospacedDigit()
                    .foregroundStyle(conversation.stale ? Color.secondary : AgentsColor.working)
            }
        } else if let time = conversation.lastActivity.map({ WatchTime.relative($0, now: now) }) {
            Text(time).foregroundStyle(.tertiary)
        }
    }

    /// A turn runs and nothing waits for the user.
    static func working(_ conversation: WatchConversation) -> Bool { conversation.busy && !conversation.needsYou }

    private static func text(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }

    /// Two lines for what a needs-you row asks; one for anything else.
    static func lineLimit(_ conversation: WatchConversation) -> Int {
        conversation.needsYou ? 2 : 1
    }

    /// "studio · dispatch": the host, then the space it runs in.
    static func subtitle(_ conversation: WatchConversation, host: WatchHost?) -> String? {
        let parts = [host?.name, conversation.space].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The line under the name, by state: needs you, what it asks (the approval's command, the question; else the
    /// agent's attention line); working, the step ("Run · 4 steps", else "Working…"; its time is the caption's); else
    /// the last message.
    static func line(_ conversation: WatchConversation, now: Date) -> String? {
        if conversation.needsYou {
            return text(conversation.waitingText) ?? text(conversation.attention) ?? text(conversation.preview) ?? "Needs you"
        }
        if working(conversation) { return text(conversation.step) ?? "Working…" }
        return text(conversation.preview) ?? text(conversation.attention)
    }

    /// The ticking time of a working row: "48s", "4m 2s".
    static func elapsed(_ conversation: WatchConversation, now: Date) -> String? {
        guard working(conversation), let since = conversation.workingSince else { return nil }
        return WatchTime.elapsed(now.timeIntervalSince(since))
    }

    /// VoiceOver: the name, the agent, the detail, muted, the time, "Needs you" or "Working" (for how long), then what
    /// the agent last said and the line.
    static func accessibilityLabel(_ conversation: WatchConversation, host: WatchHost?, now: Date) -> String {
        let state = conversation.needsYou ? "Needs you" : working(conversation)
            ? ["Working", elapsed(conversation, now: now).map { "for " + $0 }].compactMap { $0 }.joined(separator: " ") : nil
        return [conversation.displayTitle, conversation.agent, subtitle(conversation, host: host),
                conversation.muted ? "Muted" : nil, conversation.lastActivity.map { WatchTime.ago($0, now: now) }, state,
                working(conversation) ? conversation.note : nil, line(conversation, now: now)]
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
