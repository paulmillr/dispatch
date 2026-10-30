import SwiftUI

struct ChatComposerShortcuts: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    @Binding var presented: Bool

    var body: some View {
        // The ⌘/ chip sits beside the paperclip and microphone: as tall and heavy as those symbols, in their square.
        ShortcutSheetButton(presented: $presented,
                            keyFont: .system(size: theme.typography.detailSize + 2, weight: .medium, design: .monospaced),
                            ink: theme.ink, muted: theme.muted, label: "Composer shortcuts", identifier: "chat-shortcuts",
                            side: max(24, theme.typography.detailLineHeight + 10)) {
            ShortcutSheet(style: .init(ink: theme.ink, muted: theme.muted, background: theme.sidebar,
                                       colorScheme: theme.isDark ? .dark : .light, font: theme.typography.detail,
                                       keyFont: AppFont.shortcut(size: theme.typography.codeDetailSize)),
                          primary: [.init(rows: composer)],
                          more: [.init(rows: moreComposer + attachmentRows),
                                 .init(title: "Navigation", rows: ShortcutRow.navigation),
                                 .init(title: "Window", rows: ShortcutRow.window)])
                .accessibilityIdentifier("chat-shortcut-sheet")
        }
    }

    private var composer: [ShortcutRow] {
        let multiline = session.drafts.shape.multiline
        return (multiline ? [.init("⏎", "newline · insert a new line")] : []) + [
            .init(multiline ? "⌘⏎" : "⏎", session.busy ? "queue · runs after the current turn" : "send · start a new turn"),
            .init("⌥⏎", "steer · interrupts and redirects the current turn"),
            .init("⌘E", multiline ? "editor · return to single-line mode" : "editor · Return inserts a newline"),
            .init("⌘S", "save draft"),
            .init("/", "commands · type / to browse agent commands"),
            multiline ? .init("⎋", "exit editor · keep your draft") : .init("⎋", "stop · end the current turn, keeping your draft"),
        ] + (DictationStore.shared.shortcut.map { key in [
            .init("hold \(key.name)", "dictate one message · release inserts, ⏎ sends, ⎋ cancels"),
            .init("tap \(key.name)", "conversation mode · “\(DictationStore.shared.wakeWord), send / steer / scratch that / stop / deny / option 2”"),
        ] } ?? [])
    }

    /// Only where the conversation's helper keeps attachments (the paperclip shows then too).
    private var attachmentRows: [ShortcutRow] {
        session.acceptsAttachments ? [.init("⇧⌘A", "attach files or images · or drop or paste them")] : []
    }

    private let moreComposer: [ShortcutRow] = [
        .init("⌘⏎ / ⌃⏎", "send or queue from either editor mode"),
        .init("⇧⏎", "insert a newline and enter editor mode"),
        .init("⏎", "jump to new messages · empty single-line draft"),
        .init("⇧⌘M", "choose model · in single-line mode"),
        .init("⇧⌘E", "choose effort · in single-line mode"),
        .init("⌥⇧⌘E", "cycle effort · in single-line mode"),
        .init("↑↓ / ⇥", "select / complete an agent command"),
        .init("⇥ / ⇧⇥", "indent / outdent text"),
        .init("⌘[ / ⌘]", "outdent / indent lines in editor mode"),
        .init("↑ / ↓", "select queued messages when the draft is empty"),
        .init("E", "edit the selected or hovered queued message"),
        .init("⌥⏎", "send the selected or hovered queued message now"),
        .init("⌘⌫", "remove the selected or hovered queued message"),
        .init("⎋", "clear queue selection or cancel a queued edit first"),
        .init("⌃D twice", "quit agent, or show Terminal if busy · empty single-line draft only"),
    ]
}

/// The agent's running subagents beside its activity, while they run (they can outlive their turn): their
/// count, and on click one row each with its task, type, tokens and how long it has run.
struct ChatComposerAgents: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    @State private var details = false

    static func title(_ count: Int) -> String { count == 1 ? "1 agent running" : "\(count) agents running" }

    var body: some View {
        let agents = session.subagents
        if session.active && !agents.isEmpty {
            Button { details.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2").imageScale(.small)
                    Text("\(agents.count)").monospacedDigit()
                }.foregroundStyle(theme.muted).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .font(theme.typography.detail)
                .help(Self.title(agents.count))
                .accessibilityLabel(Self.title(agents.count))
                .accessibilityIdentifier("chat-agents")
                .popover(isPresented: $details) {
                    ChatSubagentList(session: session)
                        // On glass the popover's own system glass shows through instead of the sidebar fill.
                        .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
                        .preferredColorScheme(theme.isDark ? .dark : .light)
                }
        }
    }
}

/// The agents popover: one row per running subagent, oldest first. The clocks tick once a second while it shows.
struct ChatSubagentList: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession

    /// "Find the timer": its task, else its type.
    static func title(_ agent: ChatSubagent) -> String { agent.name ?? agent.kind }
    /// Its type under the task; nothing when the type is already the title.
    static func subtitle(_ agent: ChatSubagent) -> String? { agent.name == nil ? nil : agent.kind }
    /// "12.3K tokens"; nil when the helper cannot count them.
    static func tokens(_ agent: ChatSubagent) -> String? {
        agent.tokens.map { "\(ChatSessionStats.count(Int(clamping: $0))) tokens" }
    }
    static func elapsed(_ agent: ChatSubagent, now: Date) -> String { ChatTranscript.elapsed(now.timeIntervalSince(agent.started)) }

    var body: some View {
        let agents = session.subagents
        VStack(alignment: .leading, spacing: 10) {
            Text(ChatComposerAgents.title(agents.count)).foregroundStyle(theme.ink)
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(agents) { agent in row(agent, now: timeline.date) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.typography.detail).foregroundStyle(theme.muted)
        .padding(14).frame(width: 360, alignment: .leading)
        .accessibilityIdentifier("chat-agents-list")
    }

    private func row(_ agent: ChatSubagent, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(agent)).foregroundStyle(theme.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = Self.subtitle(agent) { Text(subtitle).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.elapsed(agent, now: now)).foregroundStyle(theme.ink)
                if let tokens = Self.tokens(agent) { Text(tokens) }
            }.monospacedDigit().fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-agent-\(agent.id)")
    }
}

/// Keep animation ticks in the footer, outside the transcript and native editor.
struct ChatComposerActivity: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ChatSession
    var active = true
    @State private var appeared = Date()
    @State private var details = false
    @State private var visible = false

    var body: some View {
        let state = AgentWorkingState(session)
        if state.visible && !state.loading {
            // Motion runs in the compositor (ChatComposerMotion.swift); SwiftUI updates only the whole seconds.
            let moving = active && visible && !reduceMotion && !state.waiting && session.showChat
            Button { details.toggle() } label: {
                HStack(spacing: 8) {
                    if theme.radioLog {
                        // Nautical: the vessel's status, as the radar plots it.
                        Text("◆").foregroundStyle(state.waiting ? theme.yellow : theme.accent)
                        Text(state.waiting ? "calling" : "under way").foregroundStyle(theme.ink)
                    } else {
                        ChatComposerOrbit(moving: moving)
                        ChatComposerStatus(label: state.label, moving: moving)
                    }
                    if !state.waiting {
                        TimelineView(.animation(minimumInterval: 1, paused: !active || !visible || !session.showChat)) { timeline in
                            Text("· " + AgentWorkingAnimation.timeText(state, now: timeline.date, appeared: appeared,
                                                                       reduceMotion: reduceMotion))
                                .monospacedDigit().fixedSize()
                        }
                    }
                }.foregroundStyle(theme.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chat-activity-details")
                .help("Show activity details")
                .accessibilityElement(children: .contain)
                .font(theme.typography.detail).accessibilityIdentifier("chat-working")
                .onAppear { appeared = .now; visible = true }
                .onDisappear { visible = false }
                .onChange(of: session.activeTurnID) { _, _ in appeared = .now }
                .popover(isPresented: $details) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(state.label).foregroundStyle(theme.ink)
                        if !state.fragment.isEmpty { Text(state.fragment).fixedSize(horizontal: false, vertical: true) }
                        ChatSessionStats(session: session)
                    }.font(theme.typography.detail).foregroundStyle(theme.muted)
                        .padding(14).frame(width: 320)
                        // On glass the popover's own system glass shows through instead of the sidebar fill.
                        .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
                        .preferredColorScheme(theme.isDark ? .dark : .light)
                }
        }
    }
}
