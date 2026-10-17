import SwiftUI

struct ChatComposerShortcuts: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    @Binding var presented: Bool

    var body: some View {
        ShortcutSheetButton(presented: $presented, keyFont: AppFont.shortcut(size: theme.typography.codeDetailSize),
                            ink: theme.ink, muted: theme.muted, label: "Composer shortcuts", identifier: "chat-shortcuts") {
            ShortcutSheet(style: .init(ink: theme.ink, muted: theme.muted, background: theme.sidebar,
                                       colorScheme: theme.isDark ? .dark : .light, font: theme.typography.detail,
                                       keyFont: AppFont.shortcut(size: theme.typography.codeDetailSize)),
                          primary: [.init(rows: composer)],
                          more: [.init(rows: moreComposer),
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
        ]
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
/// count, and their types on click.
struct ChatComposerAgents: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    @State private var details = false

    struct Kind: Identifiable, Equatable {
        let id: String
        let count: Int
    }

    /// Types in the order they started, each once with how many run.
    static func kinds(_ agents: [String]) -> [Kind] {
        var order: [String] = [], counts: [String: Int] = [:]
        for agent in agents {
            if counts[agent] == nil { order.append(agent) }
            counts[agent, default: 0] += 1
        }
        return order.map { Kind(id: $0, count: counts[$0] ?? 0) }
    }

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.title(agents.count)).foregroundStyle(theme.ink)
                        ForEach(Self.kinds(agents)) { kind in
                            Text(kind.count > 1 ? "\(kind.id) ×\(kind.count)" : kind.id)
                        }
                    }.font(theme.typography.detail).foregroundStyle(theme.muted)
                        .padding(14).frame(minWidth: 200, alignment: .leading)
                        // On glass the popover's own system glass shows through instead of the sidebar fill.
                        .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
                        .preferredColorScheme(theme.isDark ? .dark : .light)
                }
        }
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
