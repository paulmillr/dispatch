import SwiftUI

struct ChatComposerShortcuts: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    /// Settings' Return steers while the agent works (⌥⌘⏎ queues).
    var steers = false
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
            .init(multiline ? "⌘⏎" : "⏎", !session.busy ? "send · start a new turn" : steers ? steer : queue),
            .init("⌥⌘⏎", steers ? queue : steer),
            .init("⌥⏎ / ⇧⏎", "insert a newline"),
            .init("⌘E", multiline ? "editor · return to single-line mode" : "editor · Return inserts a newline"),
            .init("⌘S", "save draft"),
            .init("/", "commands · type / to browse agent commands"),
            multiline ? .init("⎋", "exit editor · keep your draft")
                : .init("⎋ twice", "stop · end the current turn, keeping your draft"),
        ] + (DictationStore.shared.shortcut.map { key in [
            .init("hold \(key.name)", "dictate one message · release inserts, ⏎ sends, ⎋ cancels"),
            .init("tap \(key.name)", "conversation mode · “\(DictationStore.shared.wakeWord), send / steer / scratch that / stop / deny / option 2”"),
        ] } ?? [])
    }

    private var queue: String { "queue · runs after the current turn" }
    private var steer: String { "steer · interrupts and redirects the current turn" }

    /// Only where the conversation's helper keeps attachments (the paperclip shows then too).
    private var attachmentRows: [ShortcutRow] {
        session.acceptsAttachments ? [.init("⇧⌘A", "attach files or images · or drop or paste them")] : []
    }

    private var moreComposer: [ShortcutRow] { [
        .init("⌘⏎ / ⌃⏎", "send from either editor mode · follows your queue/steer setting"),
        .init("⏎", "jump to new messages · empty single-line draft"),
        .init("⇧⌘M", "choose model · in single-line mode"),
        .init("⇧⌘E", "choose effort · in single-line mode"),
        .init("⌥⇧⌘E", "cycle effort · in single-line mode"),
        .init("↑↓ / ⇥", "select / complete an agent command"),
        .init("⇥ / ⇧⇥", "indent / outdent text"),
        .init("⌘[ / ⌘]", "outdent / indent lines in editor mode"),
        .init("↑ / ↓", "select queued messages when the draft is empty"),
        .init("E", "edit the selected or hovered queued message"),
        .init("⌥⌘⏎", "send the selected or hovered queued message now"),
        .init("⌘⌫", "remove the selected or hovered queued message"),
        .init("⎋", "clear queue selection or cancel a queued edit first"),
        .init("⌃D twice", "close tab and quit agent, or show Terminal if busy · empty single-line draft only"),
    ] }
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

/// The agent's background shells beside its subagents, while they run (they outlive their turn): their count, and
/// on click one row each with what it does, its command and how long it has run.
struct ChatComposerShells: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession
    @State private var details = false

    static func title(_ count: Int) -> String { count == 1 ? "1 shell running" : "\(count) shells running" }

    var body: some View {
        let shells = session.shells
        if session.active && !shells.isEmpty {
            Button { details.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "apple.terminal").imageScale(.small)
                    Text("\(shells.count)").monospacedDigit()
                }.foregroundStyle(theme.muted).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .font(theme.typography.detail)
                .help(Self.title(shells.count))
                .accessibilityLabel(Self.title(shells.count))
                .accessibilityIdentifier("chat-shells")
                .popover(isPresented: $details) {
                    ChatShellList(session: session)
                        // On glass the popover's own system glass shows through instead of the sidebar fill.
                        .background(LiquidGlassStore.shared.active ? Color.clear : theme.sidebar)
                        .preferredColorScheme(theme.isDark ? .dark : .light)
                }
        }
    }
}

/// The shells popover: one row per running background shell, oldest first. The clocks tick once a second while it shows.
struct ChatShellList: View {
    @Environment(\.chatTheme) private var theme
    let session: ChatSession

    static func elapsed(_ shell: ChatShell, now: Date) -> String { ChatTranscript.elapsed(now.timeIntervalSince(shell.started)) }

    var body: some View {
        let shells = session.shells
        VStack(alignment: .leading, spacing: 10) {
            Text(ChatComposerShells.title(shells.count)).foregroundStyle(theme.ink)
            ScrollView {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shells) { shell in row(shell, now: timeline.date) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(theme.typography.detail).foregroundStyle(theme.muted)
        .padding(14).frame(width: 360, alignment: .leading)
        .accessibilityIdentifier("chat-shells-list")
    }

    private func row(_ shell: ChatShell, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shell.title).foregroundStyle(theme.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = shell.detail {
                    Text(detail).font(theme.typography.codeDetail).lineLimit(1).truncationMode(.middle)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(Self.elapsed(shell, now: now)).foregroundStyle(theme.ink).monospacedDigit().fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-shell-\(shell.id)")
    }
}

/// The composer footer's copy of the agent's activity, shared by every variant of the footer's `ViewThatFits`. It is
/// computed again after each change to what it reads, but publishes only a different value: a record that only adds
/// output to the turn re-renders no variant, so `ViewThatFits` measures none of them again. Bound by the view that
/// shows the footer, and tracked only while that view lives.
@MainActor @Observable final class ChatComposerActivityState {
    private(set) var current: AgentWorkingState?
    @ObservationIgnored private weak var session: ChatSession?

    func bind(_ session: ChatSession) {
        guard self.session !== session else { return }
        self.session = session
        refresh()
    }

    private func refresh() {
        guard let session else { current = nil; return }
        let value = withObservationTracking {
            AgentWorkingState(session, details: false)
        } onChange: { [weak self] in
            // Before the change is stored; read it after, before the run loop next waits. A block on the loop it runs
            // on, not the main queue: that would wake the loop again for every streamed record. A constant, not the
            // weak capture: Swift 6.2's optimized build rejects sending that into the main-actor closure.
            let owner = self
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { owner?.refresh() }
            }
        }
        if value != current { current = value }
    }
}

/// Keep animation ticks in the footer, outside the transcript and native editor.
struct ChatComposerActivity: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ChatSession
    /// The footer's shared state, once bound; without it the view reads the session itself.
    var activity: ChatComposerActivityState? = nil
    var active = true
    /// Without it, a tight footer shows the orbit and time only; the label stays in the help and details.
    var showsLabel = true
    @State private var appeared = Date()
    @State private var details = false
    @State private var visible = false

    var body: some View {
        let state = activity?.current ?? AgentWorkingState(session, details: false)
        if state.visible && !state.loading {
            // Motion runs in the compositor (ChatComposerMotion.swift); SwiftUI updates only the whole seconds.
            // The reply placeholder in view shows the activity instead (ChatReplyPlaceholderStatus): this one dims and
            // stills, its time blank in its slot, so the footer keeps its place and its details.
            let handedOff = session.replyShowsStatus
            let moving = active && visible && !reduceMotion && !state.waiting && session.showChat && !handedOff
            Button { details.toggle() } label: {
                HStack(spacing: 8) {
                    if theme.radioLog {
                        // Nautical: the vessel's status, as the radar plots it.
                        Image(systemName: "diamond.fill").imageScale(.small).foregroundStyle(state.waiting ? theme.yellow : theme.accent)
                        if showsLabel || state.waiting {
                            Text(state.waiting ? "calling" : "under way").foregroundStyle(theme.ink)
                        }
                    } else {
                        ChatComposerOrbit(moving: moving)
                        // Waiting has no time beside it, so its label stays.
                        if showsLabel || state.waiting { ChatComposerStatus(label: state.label, moving: moving) }
                    }
                    if !state.waiting {
                        TimelineView(.animation(minimumInterval: 1, paused: !active || !visible || !session.showChat || handedOff)) { timeline in
                            let time = (showsLabel ? "· " : "") + AgentWorkingAnimation.timeText(state, now: timeline.date, appeared: appeared,
                                                                                               reduceMotion: reduceMotion)
                            // Sized by its template, which a tick changes only when the clock gains a digit: the
                            // time itself is an overlay, so a tick changes no size and the footer's `ViewThatFits`
                            // does not measure its variants again every second.
                            ChatClockSlot(template: ChatClockSlot.template(time)).equatable()
                                .overlay(alignment: .leading) { Text(time).monospacedDigit().fixedSize().opacity(handedOff ? 0 : 1) }
                        }
                    }
                }.foregroundStyle(theme.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("chat-activity-details")
                .help(showsLabel ? "Show activity details" : "\(state.label) · show activity details")
                .accessibilityElement(children: .contain)
                .font(theme.typography.detail).accessibilityIdentifier("chat-working")
                .opacity(handedOff ? 0.45 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: handedOff)
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

/// A running clock's footprint: its text with every digit a zero, digits being monospaced.
struct ChatClockSlot: View, Equatable {
    let template: String

    static func template(_ time: String) -> String {
        String(time.map { $0.isASCII && $0.isNumber ? "0" : $0 })
    }

    var body: some View {
        Text(template).monospacedDigit().fixedSize().hidden().accessibilityHidden(true)
    }
}
