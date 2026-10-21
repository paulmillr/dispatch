import SwiftUI
import AppKit

/// What the strip's one mode button shows and does for a tab. In the terminal it is muted and
/// names where a click goes; away from it, accent-lit, it names what shows. A click leaves the terminal for chat (or for
/// files, without an agent) and returns to it from chat or files; files on an agent tab is a hold, a right-click or ⇧⌘F.
struct ModeSwitchState: Equatable {
    let mode: TabMode
    /// An agent runs or ran here, so chat can open.
    let chat: Bool
    /// Files can show here.
    let files: Bool
    /// The plain SSH login's host when files cannot show.
    let host: String?

    /// `FilesCoordinator.nextMode`: where a click goes; nil when it can go nowhere (the button dims). Chat never leads on
    /// to files: a click there always returns to the terminal.
    var next: TabMode? {
        switch mode {
        case .terminal: chat ? .chat : files ? .files : nil
        case .chat, .files: .terminal
        }
    }

    var glyph: String {
        switch mode {
        case .files: "folder"
        case .chat: "text.bubble"
        // Muted, it names where the click goes; with nowhere to go, what is missing.
        case .terminal: next == .chat || (next == nil && host == nil) ? "text.bubble" : "folder"
        }
    }

    var lit: Bool { mode != .terminal }
    var dimmed: Bool { next == nil }

    /// The next step, as VoiceOver reads the button.
    var label: String {
        switch next ?? (host == nil ? .chat : .files) {
        case .terminal: "Show Terminal"
        case .chat: "Show Chat"
        case .files: "Show Files"
        }
    }

    var value: String {
        switch mode {
        case .terminal: "Terminal selected"
        case .chat: "Chat selected"
        case .files: "Files selected"
        }
    }

    /// Hover text; `chatHint` is chat's own (why it cannot open yet, or "Show agent chat").
    func help(chatHint: String) -> String {
        switch next {
        case .chat: chatHint
        case .files: "Show files · ⇧⌘F"
        case .terminal: mode == .files ? "Show terminal · ⇧⌘F" : "Show terminal · ⇧⌘C"
        case nil: host.map { "Files need dispatch-helper on \($0)" } ?? chatHint
        }
    }

    /// Whether the tab can show `mode` (Nautical keeps an unreachable segment named but faint).
    func reaches(_ mode: TabMode) -> Bool {
        switch mode {
        case .terminal: true
        case .chat: chat || self.mode == .chat
        case .files: files || self.mode == .files
        }
    }
}

/// The strip's mode button: terminal, chat and files on one tab (`FilesCoordinator.cycle`). Right-click or press and hold
/// lists the modes. Keeps chat's name and identifier: it began as the chat switch.
struct ChatModeSwitch: View {
    private var theme: ChatTheme { ChatThemeStore.shared.current }
    @Bindable var session: ChatSession
    let coordinator: ChatCoordinator
    var floating = false
    /// The tab's files; defaults to the chat coordinator's own. Without one (a stand-alone chat) the button is chat's
    /// two-way switch.
    var files: FilesCoordinator?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var typing = false

    private var filesCoordinator: FilesCoordinator? { files ?? coordinator.files }
    private var state: ModeSwitchState {
        guard let files = filesCoordinator else {
            return ModeSwitchState(mode: session.showChat ? .chat : .terminal, chat: coordinator.canEnterChat(session), files: false, host: nil)
        }
        return files.switchState(session.id)
    }

    var body: some View {
        let state = state
        let help = state.help(chatHint: coordinator.chatAvailabilityHint(session))
        Button { choose(state.next) } label: {
            ModeSwitchLabel(state: state, radio: coordinator.enabled, hold: filesCoordinator != nil,
                            tint: state.dimmed ? Chrome.muted : state.lit ? theme.accent : theme.muted)
                .opacity(state.dimmed ? 0.35 : 1)
                .background {
                    // Borderless in a strip; floating over terminal text it keeps a ground to stay legible.
                    // On glass the capsule below is the ground and answers the pointer itself.
                    if LiquidGlassStore.shared.active {
                    } else if floating && !state.lit {
                        RoundedRectangle(cornerRadius: 5).fill(theme.ink.opacity(0.06))
                    } else if hovering && !state.dimmed {
                        RoundedRectangle(cornerRadius: 5).fill(Chrome.palette.hover)
                    }
                }
                // The floating ground leaves with the terminal, in step with the glyph's cross-fade.
                .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.modeSwitchDuration), value: state.lit)
                .stripGlassButton()
                .contentShape(Rectangle())
                // Clicks and press-and-hold are AppKit's: a held press opens the modes menu instead of clicking.
                .overlay {
                    ModeSwitchPressTracker(enabled: !state.dimmed, help: help, click: { choose(state.next) },
                                           menu: { menuItems(state) })
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.label)
        .accessibilityValue(state.value)
        .disabled(state.dimmed)
        .help(help)
        .contextMenu {
            ForEach(menuItems(state)) { item in
                Toggle(item.title, isOn: Binding(get: { item.checked }, set: { _ in item.choose() }))
                    .disabled(!item.enabled)
            }
        }
        .opacity(floating && typing && !hovering ? 0.4 : 1)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.15), value: typing && !hovering)
        .onHover { hovering = $0 }
        // Only a floating switch dims while typing; a strip's must not re-render on every keystroke.
        .task(id: floating ? session.lastInputAt : nil) {
            guard floating, let date = session.lastInputAt, Date().timeIntervalSince(date) < 1.2 else { typing = false; return }
            typing = true
            do { try await Task.sleep(for: .milliseconds(1200)) } catch { return }
            typing = false
        }
        .accessibilityIdentifier("chat-mode-switch")
    }

    private func choose(_ mode: TabMode?) {
        guard let mode else { return }
        TerminalRuntime.shared.workspace?.selectSurface(session.id)
        if let files = filesCoordinator { files.switchMode(session.id, to: mode) }
        else { coordinator.chooseChat(mode == .chat, session: session) }
    }

    private func choose(_ target: ModeSwitchMenuItem.Target) {
        switch target {
        case .mode(let mode): choose(mode)
        case .files(let tab):
            TerminalRuntime.shared.workspace?.selectSurface(session.id)
            filesCoordinator?.showFiles(session.id, tab: tab)
        }
    }

    private func menuItems(_ state: ModeSwitchState) -> [ModeSwitchMenuItem] {
        ModeSwitchMenuItem.items(state, files: filesCoordinator, id: session.id) { choose($0) }
    }
}

struct ModeSwitchMenuItem: Identifiable {
    /// A mode, or files on one of its tabs.
    enum Target: Hashable {
        case mode(TabMode)
        case files(FilesTab)
    }

    let target: Target
    let title: String
    let checked: Bool
    let enabled: Bool
    let choose: @MainActor () -> Void
    var id: Target { target }

    /// The right-click and hold menu (F1a): Terminal, Chat, then the three files tabs, the shown one checked. Files is the
    /// Files tab; Changes and Commits are always listed and enabled as the View menu's ⇧⌘U and ⇧⌘L are
    /// (`FilesCoordinator.canShowFiles(_:tab:)`: not on a folder known to be outside a repository). Without `files` (a
    /// stand-alone chat) the menu is Terminal and Chat.
    @MainActor static func items(_ state: ModeSwitchState, files: FilesCoordinator?, id: UUID,
                                 choose: @escaping @MainActor (Target) -> Void) -> [ModeSwitchMenuItem] {
        func item(_ target: Target, _ title: String, checked: Bool, enabled: Bool) -> ModeSwitchMenuItem {
            ModeSwitchMenuItem(target: target, title: title, checked: checked, enabled: enabled) { choose(target) }
        }
        var items = [item(.mode(.terminal), "Terminal", checked: state.mode == .terminal, enabled: state.reaches(.terminal)),
                     item(.mode(.chat), "Chat", checked: state.mode == .chat, enabled: state.reaches(.chat))]
        guard let files else { return items }
        let shown = state.mode == .files ? files.existing(id)?.tab ?? .files : nil
        for (tab, title) in [(FilesTab.files, "Files"), (.changes, "Uncommitted Changes"), (.commits, "Commits")] {
            items.append(item(.files(tab), title, checked: shown == tab,
                              enabled: state.reaches(.files) && files.canShowFiles(id, tab: tab)))
        }
        return items
    }
}

private struct ModeSwitchLabel: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil marks no mode (a slot's placeholder).
    var state: ModeSwitchState?
    /// Nautical's radio segment (chat is on) and hold segment (files exist).
    var radio = true
    var hold = true
    var tint: Color = Chrome.muted

    private var motion: Animation? { InterfaceMotion.animation(reduce: reduceMotion, duration: InterfaceMotion.modeSwitchDuration) }

    var body: some View {
        if SidebarThemeStore.shared.current == .nautical {
            // Nautical names every side: the terminal is the deck, chat the radio, files the hold. On Liquid Glass the
            // strip's glass is its ground and the selected side a capsule nested in the pill; flat, a bordered well with
            // square segments. Every tab shows the same segments, so switching tabs never shifts the strip.
            let glass = LiquidGlassStore.shared.active
            HStack(spacing: 2) {
                segment("deck", symbol: "terminal", mode: .terminal, glass: glass)
                if radio { segment("radio", symbol: "antenna.radiowaves.left.and.right", mode: .chat, glass: glass) }
                if hold { segment("hold", symbol: "shippingbox", mode: .files, glass: glass) }
            }
            .padding(.horizontal, glass ? 3 : 2).padding(.vertical, glass ? 0 : 2)
            .background { if !glass { RoundedRectangle(cornerRadius: 5).fill(Chrome.window) } }
            .overlay { if !glass { RoundedRectangle(cornerRadius: 5).strokeBorder(Chrome.border) } }
            .frame(minHeight: typography.expanded(22))
        } else {
            // Same glyph size and height as the layout picker, so the strip's icons scale together. Both glyphs are laid
            // out, so the button keeps one width; the shown one cross-fades in with the mode switch, and only it animates.
            let glyph = state?.glyph ?? "text.bubble"
            ZStack {
                ForEach(["text.bubble", "folder"], id: \.self) { name in
                    Image(systemName: name).opacity(name == glyph ? 1 : 0)
                }
            }
            .font(.system(size: typography.tabSize))
            .foregroundStyle(tint)
            .animation(motion, value: glyph)
            .animation(motion, value: state?.lit)
            .padding(.horizontal, 7).frame(minHeight: typography.expanded(22))
        }
    }

    private func segment(_ title: String, symbol: String, mode: TabMode, glass: Bool) -> some View {
        let on = state?.mode == mode
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: typography.size(offset: -3)))
            Text(title)
        }
        .font(HarbourType.mono(typography.size(offset: -2)))
        .foregroundStyle(on ? Chrome.ink : Chrome.muted)
        // A side the tab cannot show (no agent, a plain SSH login) stays named but faint.
        .opacity(state?.reaches(mode) == false ? 0.45 : 1)
        .padding(.horizontal, glass ? 9 : 7)
        // On glass, 3 points inside the 28-point track all round, as the selected tab's pill sits in its track.
        .frame(height: glass ? StripTab.glassTrackHeight(typography) - 6 : typography.expanded(18))
        .background {
            if on {
                if glass { Capsule().fill(Chrome.ink.opacity(Chrome.palette.isDark ? 0.14 : 0.09)) }
                else { RoundedRectangle(cornerRadius: 3).fill(Chrome.palette.control) }
            }
        }
        .animation(motion, value: on)
    }
}

/// Holds a tab strip's switch position while the selected tab has none of its own (a server window split into panes,
/// whose pane headers switch each pane), as wide as the switch, so switching tabs does not shift the strip.
struct ChatModeSwitchSlot: View {
    /// In a lone glass strip's button pill an empty slot would leave a hole: the switch shows dimmed and inert instead.
    var dimmed = false
    var body: some View {
        if dimmed {
            ModeSwitchLabel(radio: TerminalRuntime.shared.chat.enabled).opacity(0.35).foregroundStyle(Chrome.muted)
                .stripGlassButton().fixedSize()
                .help("Each pane switches in its own header").accessibilityLabel("Mode switch in pane headers")
        } else {
            ModeSwitchLabel(radio: TerminalRuntime.shared.chat.enabled).stripGlassButton().fixedSize().hidden().accessibilityHidden(true)
        }
    }
}

/// Room a floating mode switch takes at the trailing end of the files header, which sits under it.
private struct FilesHeaderTrailingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Room at the files header's trailing end for the floating mode switch over it (TerminalContentView); 0 in a strip.
    var filesHeaderTrailingInset: CGFloat {
        get { self[FilesHeaderTrailingInsetKey.self] }
        set { self[FilesHeaderTrailingInsetKey.self] = newValue }
    }
}

/// The mode button's pointer: a click acts on release inside, as a button does; a press held past the delay opens the
/// modes menu under the button instead, as a toolbar back button does. A right-click falls through to SwiftUI's menu.
/// Internal, not private, so the presentation tests can read the menu a hold opens.
struct ModeSwitchPressTracker: NSViewRepresentable {
    let enabled: Bool
    let help: String
    let click: @MainActor () -> Void
    let menu: @MainActor () -> [ModeSwitchMenuItem]

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.enabled = enabled
        view.click = click
        view.items = menu
        // The tracker is what the pointer is over, so it carries the hover text.
        if view.toolTip != help { view.toolTip = help }
    }

    final class TrackerView: NSView {
        /// How long a press waits before it becomes the menu, about a toolbar button's menu delay.
        static let holdDelay: TimeInterval = 0.45
        var enabled = true
        var click: @MainActor () -> Void = {}
        var items: @MainActor () -> [ModeSwitchMenuItem] = { [] }

        override var mouseDownCanMoveWindow: Bool { false }
        override func isAccessibilityElement() -> Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Right and control clicks reach SwiftUI's context menu.
            if let event = NSApp.currentEvent, event.type == .rightMouseDown || event.modifierFlags.contains(.control) { return nil }
            return super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // Periodic events time the hold inside AppKit's own tracking loop, with no clock of the app's.
            NSEvent.startPeriodicEvents(afterDelay: Self.holdDelay, withPeriod: 0.1)
            defer { NSEvent.stopPeriodicEvents() }
            while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic]) {
                switch next.type {
                case .periodic:
                    NSEvent.stopPeriodicEvents()
                    showMenu()
                    return
                case .leftMouseUp:
                    if enabled, bounds.contains(convert(next.locationInWindow, from: nil)) { click() }
                    return
                default:
                    continue
                }
            }
        }

        private func showMenu() {
            modesMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4), in: self)
        }

        /// The menu a hold opens, as it stands now.
        func modesMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items() {
                let entry = ClosureMenuItem(title: item.title, action: item.choose)
                entry.state = item.checked ? .on : .off
                entry.isEnabled = item.enabled
                menu.addItem(entry)
            }
            return menu
        }
    }

    @MainActor final class ClosureMenuItem: NSMenuItem {
        private let perform: @MainActor () -> Void
        init(title: String, action: @escaping @MainActor () -> Void) {
            perform = action
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        @objc private func run() { perform() }
    }
}
