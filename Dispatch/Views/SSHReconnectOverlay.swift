import SwiftUI

struct SSHReconnectOverlay: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let surface: UUID
    let workspace: Workspace
    @State private var lastState: SSHReconnectController.State?
    var body: some View {
        let controller = TerminalRuntime.shared.hosts.reconnect
        let own = controller.presentationState(for: surface)
        // A login asking for a host none of whose tabs is open (a detached space restored) asks in the active tab.
        let orphan = own == nil ? controller.orphan(for: surface) : nil
        let state = own ?? (orphan == nil ? nil : SSHReconnectController.State(reconnecting: true, attempted: true))
        let host = orphan ?? workspace.hosts.terminals[surface]?.host
        let glass = LiquidGlassStore.shared.active
        // On glass a row like the tab strip: its glass track, below the strip's margin above that track. Flat, a
        // full-width bar.
        let track = StripTab.glassTrackHeight(typography)
        let margin = (typography.expanded(38) - track) / 2
        let height = glass ? margin + track : typography.expanded(34)
        Group {
            if let displayed = state ?? lastState, let host {
                let hostName = workspace.hosts.record(host).name
                // What the host's login asks, while this tab shows an attempt.
                let login = SSHReconnectLoginPresentation(
                    prompt: state == nil ? nil : controller.prompts[host],
                    asking: state != nil && controller.awaitingTerminal.contains(host),
                    focused: controller.sources[host] == surface || orphan != nil,
                    title: orphan == nil ? nil : "restoring " + hostName,
                    logShown: state != nil && !displayed.connected && !displayed.gone
                        && (controller.logShown.contains(surface) || controller.awaitingTerminal.contains(host)),
                    answer: { controller.answer(host, $0); workspace.focusRequest = System.uuid() },
                    confirm: { controller.confirm(host, $0); workspace.focusRequest = System.uuid() },
                    toggleLog: { controller.toggleLog(surface) })
                let reconnect = { controller.reconnect(hostID: host, sourceSurfaceID: surface) }
                let cancel = { controller.cancel(hostID: host); workspace.focusRequest = System.uuid() }
                VStack(spacing: 0) {
                    if glass {
                        SSHReconnectGlassRow(state: displayed, hostName: hostName, login: login, reconnect: reconnect, cancel: cancel, close: closeTab)
                            .frame(height: track)
                            .padding(.horizontal, Chrome.stripInset).padding(.top, margin)
                    } else if login.prompting {
                        SSHReconnectFlatPromptRow(state: displayed, login: login, cancel: cancel)
                            .frame(height: height)
                    } else {
                        SSHReconnectControl(state: displayed, reconnect: reconnect, cancel: cancel, wheel: { event in
                                let runtime = TerminalRuntime.shared
                                if let session = runtime.chat.sessions[surface], session.showChat { session.scrollPosition.forwardWheel(event) }
                                else { runtime.views[surface]?.scrollWheel(with: event) }
                            }, hostName: hostName, close: closeTab, logShown: login.logShown, toggleLog: login.toggleLog)
                            .frame(height: height)
                    }
                    if login.logShown {
                        SSHReconnectLogPanel(host: host, hostName: hostName)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: state == nil ? 0 : nil, alignment: .top)
        .clipped()
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.2), value: state == nil)
        .onChange(of: state, initial: true) { _, value in if let value { lastState = value } }
    }

    private func closeTab() {
        guard let app = NSApp.delegate as? AppDelegate,
              let tab = workspace.spaces.flatMap(\.tabs).first(where: { $0.surfaceIDs.contains(surface) }) else { return }
        app.closeTab(tab.id)
    }
}

/// What a tab's strip shows of its host's login (`SSHReconnectController`): the prompt ssh asks, or that it asks on its
/// terminal (the log then shows), whether the field takes the keyboard here, and the log.
struct SSHReconnectLoginPresentation {
    var prompt: SSHReconnectController.Prompt?
    var asking = false
    /// The attempt was asked from this tab: its field takes the keyboard.
    var focused = false
    /// Which host asks, when this tab is not on it (`SSHReconnectController.orphan`).
    var title: String?
    var logShown = false
    var answer: (String?) -> Void = { _ in }
    var confirm: (Bool) -> Void = { _ in }
    var toggleLog: () -> Void = {}
    var prompting: Bool { prompt != nil || asking }
}

/// ssh's prompt in the strip: a secure field for a password, passphrase or code (Show reveals it), Yes and No for a
/// confirmation, a notice for a security key's touch; or, when ssh asks on its terminal, where to answer.
struct SSHReconnectPromptContent: View {
    @Environment(\.appTypography) private var typography
    let login: SSHReconnectLoginPresentation
    let color: Color
    let cancel: () -> Void
    @State private var text = ""
    @State private var reveal = false
    @FocusState private var editing: Bool

    var body: some View {
        let theme = ChatThemeStore.shared.current
        let icon = Font.system(size: typography.tabSize - 1, weight: .semibold)
        if let title = login.title { Text(title).foregroundStyle(theme.muted).lineLimit(1).fixedSize() }
        if let prompt = login.prompt {
            switch prompt.kind {
            case .secret:
                Text(prompt.text).foregroundStyle(color).lineLimit(1).truncationMode(.middle).layoutPriority(2)
                    .help(prompt.text)
                field(prompt, theme: theme)
                if prompt.retry {
                    Text("Not accepted, try again").foregroundStyle(theme.red).lineLimit(1)
                } else if login.focused {
                    Text("⏎").foregroundStyle(theme.muted)
                }
            case .confirm:
                Text(prompt.text).foregroundStyle(color).lineLimit(1).truncationMode(.middle).layoutPriority(2)
                    .help(prompt.text)
                Button { login.confirm(true) } label: {
                    Text("Yes").foregroundStyle(Color(nsColor: SSHReconnectControl.actionInk))
                        .padding(.horizontal, 12).frame(maxHeight: .infinity)
                        .background(Capsule().inset(by: 2).fill(color)).contentShape(Capsule())
                }
                .fixedSize(horizontal: true, vertical: false).focusable(false)
                .accessibilityIdentifier("ssh-reconnect-yes")
                Button { login.confirm(false) } label: {
                    Text("No").foregroundStyle(theme.muted).padding(.horizontal, 10).frame(maxHeight: .infinity)
                        .modifier(StripActionHover()).contentShape(Capsule())
                }
                .fixedSize(horizontal: true, vertical: false).focusable(false)
                .accessibilityIdentifier("ssh-reconnect-no")
            case .notice:
                Image(systemName: "key.radiowaves.forward").font(icon).foregroundStyle(color)
                Text("Touch your security key").foregroundStyle(color).lineLimit(1).layoutPriority(2)
                Text(prompt.text).foregroundStyle(theme.muted).lineLimit(1).truncationMode(.middle)
            }
        } else if login.asking {
            Text("ssh is asking in the log").foregroundStyle(color).lineLimit(1).layoutPriority(2)
            Text("answer it there").foregroundStyle(theme.muted).lineLimit(1)
        }
    }

    @ViewBuilder private func field(_ prompt: SSHReconnectController.Prompt, theme: ChatTheme) -> some View {
        HStack(spacing: 4) {
            Group {
                if reveal { TextField("", text: $text) } else { SecureField("", text: $text) }
            }
            .textFieldStyle(.plain)
            .focused($editing)
            .onSubmit { login.answer(text); text = "" }
            .onExitCommand { text = ""; cancel() }
            .accessibilityLabel(prompt.text)
            .accessibilityIdentifier("ssh-reconnect-answer")
            Button { reveal.toggle(); editing = true } label: {
                Image(systemName: reveal ? "eye" : "eye.slash").foregroundStyle(theme.muted)
            }
            .focusable(false)
            .help(reveal ? "Hide what is typed" : "Show what is typed")
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 90, idealWidth: 200, maxWidth: 220, maxHeight: .infinity)
        .background {
            let shape = Capsule().inset(by: 3)
            shape.fill(theme.isDark ? Color.black.opacity(0.35) : Color.white.opacity(0.8))
                .overlay(shape.stroke(prompt.retry ? theme.red : editing ? theme.accent.opacity(0.7) : theme.border,
                                      lineWidth: editing || prompt.retry ? 1.5 : 1))
        }
        .onChange(of: prompt.request.id, initial: true) { _, _ in
            text = ""; reveal = false
            if login.focused { editing = true }
        }
    }
}

/// The flat bar while ssh asks: the status mark, the prompt and Log and Cancel, on the bar's tinted ground.
struct SSHReconnectFlatPromptRow: View {
    @Environment(\.appTypography) private var typography
    let state: SSHReconnectController.State
    let login: SSHReconnectLoginPresentation
    let cancel: () -> Void
    var body: some View {
        let theme = ChatThemeStore.shared.current
        let color = Color(nsColor: SSHReconnectControl.stateColor(connected: state.connected))
        HStack(spacing: 8) {
            ReconnectIndicator(color: color, reconnecting: state.reconnecting).padding(.leading, 13)
            SSHReconnectPromptContent(login: login, color: color, cancel: cancel)
            Spacer(minLength: 0)
            SSHReconnectLogButton(shown: login.logShown, lit: login.asking, color: color, action: login.toggleLog)
            Button(action: cancel) {
                HStack(spacing: 5) { Image(systemName: "stop.fill"); Text("Cancel") }
                    .foregroundStyle(theme.muted).padding(.horizontal, 10).frame(maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.border))
            }
            .focusable(false).fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, 14)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .font(Font(AppFont.native(size: typography.size(.label))))
        .background(Color(nsColor: NSColor(theme.window).blended(withFraction: 0.09, of: SSHReconnectControl.stateColor(connected: false)) ?? .windowBackgroundColor))
        .overlay(alignment: .bottom) { Rectangle().fill(color.opacity(0.3)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ssh-reconnect-overlay")
    }
}

/// Log, which shows or hides the host's reconnect log under the strip: lit while it shows, or while ssh asks there.
struct SSHReconnectLogButton: View {
    @Environment(\.appTypography) private var typography
    let shown: Bool
    var lit = false
    let color: Color
    let action: () -> Void
    var body: some View {
        let theme = ChatThemeStore.shared.current
        Button(action: action) {
            HStack(spacing: 5) {
                Text("Log")
                Image(systemName: shown ? "chevron.up" : "chevron.down").font(.system(size: typography.tabSize - 3, weight: .semibold))
            }
            .foregroundStyle(shown || lit ? color : theme.muted)
            .padding(.horizontal, 10).frame(maxHeight: .infinity)
            .background { if shown || lit { Capsule().inset(by: 3).fill(color.opacity(0.14)) } }
            .modifier(StripActionHover()).contentShape(Capsule())
        }
        .buttonStyle(.plain).focusable(false).fixedSize(horizontal: true, vertical: false)
        .help(shown ? "Hide the login log" : "Show the login log: what the reconnect did and what ssh said")
        .accessibilityIdentifier("ssh-reconnect-log")
    }
}

/// The host's reconnect log under the strip, in this pane only: the attempt's steps with their times, ssh's own output
/// and its prompts, selectable, with Copy; a field types into the login's terminal while one runs, for an ssh that asks
/// there. Drag its foot to resize it.
struct SSHReconnectLogPanel: View {
    @Environment(\.appTypography) private var typography
    let host: HostID
    let hostName: String
    @State private var height: CGFloat = 170
    @State private var dragStart: CGFloat?
    @State private var typed = ""

    var body: some View {
        let controller = TerminalRuntime.shared.hosts.reconnect
        let theme = ChatThemeStore.shared.current
        let lines = controller.logs[host] ?? []
        let glass = LiquidGlassStore.shared.active
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Login log · " + hostName).font(typography, .caption, weight: .medium).foregroundStyle(theme.muted)
                Spacer()
                Button("Copy") { Self.copy(lines) }.buttonStyle(.plain).focusable(false).foregroundStyle(theme.muted)
                    .font(typography, .caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(line.time.map(Self.time) ?? "").foregroundStyle(theme.muted.opacity(0.7))
                                    .frame(width: 64, alignment: .leading)
                                Text(line.text).foregroundStyle(color(line.kind, theme: theme))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                    .font(AppFont.code(size: typography.size(.caption)))
                    .textSelection(.enabled)
                }
                .onChange(of: lines.last?.id, initial: true) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
            }
            if controller.loginsRunning.contains(host), controller.prompts[host] == nil {
                HStack(spacing: 8) {
                    Text("to ssh").foregroundStyle(theme.muted)
                    SecureField("Type an answer, then Return", text: $typed)
                        .textFieldStyle(.plain)
                        .onSubmit { controller.type(host, typed); typed = "" }
                        .accessibilityIdentifier("ssh-reconnect-log-input")
                }
                .font(typography, .caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.border))
            }
            Capsule().fill(theme.muted.opacity(0.5)).frame(width: 36, height: 4).frame(maxWidth: .infinity)
                .contentShape(Rectangle().inset(by: -6))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStart ?? height
                        dragStart = start
                        height = min(420, max(90, start + value.translation.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .frame(height: height)
        .background {
            if glass { RoundedRectangle(cornerRadius: 14).fill(.clear).liquidGlass(in: RoundedRectangle(cornerRadius: 14)) }
            else { theme.window }
        }
        .padding(.horizontal, glass ? Chrome.stripInset : 0).padding(.top, glass ? 6 : 0).padding(.bottom, glass ? 6 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ssh-reconnect-log-panel")
    }

    private func color(_ kind: SSHReconnectController.LogLine.Kind, theme: ChatTheme) -> Color {
        switch kind {
        case .step: theme.muted
        case .output: theme.ink
        case .prompt: Color(nsColor: SSHReconnectControl.stateColor(connected: false))
        case .problem: theme.red
        }
    }

    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) }

    static func copy(_ lines: [SSHReconnectController.LogLine]) {
        let text = lines.map { line in (line.time.map { time($0) + "  " } ?? "          ") + line.text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The reconnect row on Liquid Glass, a sibling of the tab strip: the strip's glass track, tinted with the state's
/// color as a remote strip takes its host's, holding the status and its actions. Reconnect is an interactive glass
/// pill inside the track, like the selected tab's, tinted with that color; Cancel and Close tab sit on the track's
/// glass with the strip buttons' faint hover capsule.
struct SSHReconnectGlassRow: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: SSHReconnectController.State
    let hostName: String
    var login = SSHReconnectLoginPresentation()
    let reconnect: () -> Void
    let cancel: () -> Void
    let close: () -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        let presentation = SSHReconnectControl.Presentation(state: state, hostName: hostName,
                                                            nautical: SidebarThemeStore.shared.current == .nautical)
        let color = Color(nsColor: presentation.color)
        // A narrow pane drops the secondary action before Reconnect, as the flat bar does.
        let detail = state.reconnecting || width >= typography.expanded(280) ? presentation.detailTitle : nil
        let icon = Font.system(size: typography.tabSize - 1, weight: .semibold)
        HStack(spacing: 8) {
            // Reconnect leads the row, the action the row exists for; once an attempt starts the status takes its place.
            if presentation.offersReconnect {
                Button(action: reconnect) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(icon)
                        Text(presentation.actionTitle)
                        Text("⏎").opacity(0.6)
                    }
                    .foregroundStyle(Color(nsColor: SSHReconnectControl.actionInk))
                    .padding(.horizontal, 12).frame(maxHeight: .infinity)
                    .liquidGlass(in: Capsule().inset(by: 2), interactive: true, tint: color)
                    .contentShape(Capsule())
                }
                .fixedSize(horizontal: true, vertical: false)
                .focusable(false)
                .accessibilityLabel(presentation.actionHelp)
                .help(presentation.actionHelp + " · ⏎")
                .transition(.opacity)
            }
            ReconnectIndicator(color: color, reconnecting: state.reconnecting)
            if login.prompting {
                SSHReconnectPromptContent(login: login, color: color, cancel: cancel)
            } else {
                Text(presentation.label).foregroundStyle(color).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                Text(presentation.info.joined(separator: " · ")).foregroundStyle(Chrome.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !state.connected && !state.gone {
                SSHReconnectLogButton(shown: login.logShown, lit: login.asking, color: color, action: login.toggleLog)
            }
            // Close tab, or Cancel while reconnecting, ends the row.
            if let detail {
                Button(action: state.reconnecting ? cancel : close) {
                    HStack(spacing: 5) {
                        Image(systemName: state.reconnecting ? "stop.fill" : "xmark").font(icon)
                        Text(detail)
                    }
                    .foregroundStyle(Chrome.muted)
                    .padding(.horizontal, 10).frame(maxHeight: .infinity)
                    .modifier(StripActionHover()).contentShape(Capsule())
                }
                .fixedSize(horizontal: true, vertical: false)
                .focusable(false)
                .help(presentation.detailHelp)
            }
        }
        .font(Font(AppFont.native(size: typography.tabSize)))
        // The end actions reach the track's rounded ends, concentric with them; with Reconnect gone, the status mark
        // sits in from the leading end.
        .padding(.leading, presentation.offersReconnect ? 0 : 11)
        // Buttons act without taking focus from the terminal or the chat composer; only the prompt's field takes it.
        .buttonStyle(.plain).focusEffectDisabled()
        .liquidGlass(in: Capsule(), tint: color.opacity(0.1))
        .glassGroup()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.15), value: presentation.offersReconnect)
        .help(presentation.help)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ssh-reconnect-overlay")
    }
}

/// The status mark: filled while offline or connected, a sweeping three-quarter ring while reconnecting (still with
/// reduced motion), drawn as the flat bar's.
struct ReconnectIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let reconnecting: Bool

    var body: some View {
        Group {
            if reconnecting {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle().trim(from: 0.125, to: 0.875).stroke(color, lineWidth: 1.5)
                        .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
                }
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8).padding(1)
        .accessibilityHidden(true)
    }
}

struct SSHReconnectControl: NSViewRepresentable {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let themes = ChatThemeStore.shared
    let state: SSHReconnectController.State
    let reconnect: () -> Void
    let cancel: () -> Void
    let wheel: (NSEvent) -> Void
    var hostName = "Host"
    var close: () -> Void = {}
    var logShown = false
    var toggleLog: () -> Void = {}
    /// Amber while offline or reconnecting, green once the session has resumed, grey for a tab gone from its server.
    static func stateColor(connected: Bool, gone: Bool = false) -> NSColor {
        gone ? NSColor(srgbRed: 142/255, green: 142/255, blue: 150/255, alpha: 1)
            : connected ? NSColor(srgbRed: 127/255, green: 211/255, blue: 161/255, alpha: 1)
            : NSColor(srgbRed: 217/255, green: 179/255, blue: 106/255, alpha: 1)
    }
    /// The text on the reconnect primary action, dark on its amber.
    static let actionInk = NSColor(srgbRed: 19/255, green: 19/255, blue: 21/255, alpha: 1)

    /// What the bar says and offers in a state; the flat bar and the glass row draw the same.
    struct Presentation {
        let label: String
        let info: [String]
        /// Reconnect is offered until an attempt starts or the session resumes; never for a tab gone from its server.
        let offersReconnect: Bool
        let actionTitle: String
        let actionHelp: String
        /// Cancel while reconnecting, Close tab while offline, nothing once connected.
        let detailTitle: String?
        let detailHelp: String
        let color: NSColor
        var help: String { ([label] + info).joined(separator: " · ") }

        /// `nautical`: the radio's wording, contact with the host lost and re-established.
        init(state: SSHReconnectController.State, hostName: String, nautical: Bool = false) {
            color = SSHReconnectControl.stateColor(connected: state.connected, gone: state.gone)
            label = state.gone ? (nautical ? "LOST WITH \(hostName.uppercased())" : "no longer on \(hostName)")
                : nautical
                ? (state.connected ? "contact re-established" : state.reconnecting ? "re-establishing contact with \(hostName.uppercased())"
                    : "\(hostName.uppercased()) out of range")
                : state.connected ? "connected" : state.reconnecting ? "reconnecting to \(hostName)" : "\(hostName) disconnected"
            var info: [String] = []
            if state.gone { info = ["its terminal ended there; what it showed stays here, read-only"] }
            else if state.connected { info = ["session resumed"] }
            else {
                if let date = state.disconnectedAt { info.append(date.formatted(date: .omitted, time: .shortened)) }
                if state.attempts > 0 { info.append("\(state.attempts) \(state.attempts == 1 ? "attempt" : "attempts")") }
                if state.retryAt != nil { info.append("retrying automatically") }
                if let error = state.error { info.append(error) }
            }
            self.info = info
            offersReconnect = !state.reconnecting && !state.connected && !state.gone
            actionTitle = "Reconnect"
            actionHelp = "Reconnect to \(hostName)"
            detailTitle = state.connected ? nil : state.reconnecting ? "Cancel" : "Close tab"
            detailHelp = state.reconnecting ? "Cancel reconnect"
                : state.gone ? "Close this tab; nothing changes on \(hostName)" : "Close tab; keep remote jobs running"
        }
    }
    func makeNSView(context: Context) -> Control { Control() }
    func updateNSView(_ view: Control, context: Context) {
        view.update(state: state, reconnect: reconnect, cancel: cancel, wheel: wheel,
                    hostName: hostName, close: close, reduceMotion: reduceMotion, logShown: logShown, toggleLog: toggleLog)
        view.appearance(theme: themes.current, font: AppFont.native(size: typography.size(.label)))
    }
    final class Control: NSView {
        private let button = NSButton()
        private let details = NSButton()
        /// Log: the host's reconnect log under the bar.
        private let log = NSButton()
        private let indicator = NSView()
        private let arc = CAShapeLayer()
        private let label = NSTextField(labelWithString: "")
        private let metadata = NSTextField(labelWithString: "")
        private var action: () -> Void = {}
        private var detailAction: () -> Void = {}
        private var logAction: () -> Void = {}
        private var wheel: (NSEvent) -> Void = { _ in }
        private var state = SSHReconnectController.State()
        private var color = SSHReconnectControl.stateColor(connected: false)
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for button in [button, details, log] {
                button.isBordered = false; button.focusRingType = .none; button.refusesFirstResponder = true
                button.wantsLayer = true; button.layer?.cornerRadius = 5
                button.target = self
                addSubview(button)
            }
            button.action = #selector(performAction)
            details.action = #selector(performDetailAction)
            log.action = #selector(performLogAction)
            log.setAccessibilityIdentifier("ssh-reconnect-log")
            for text in [label, metadata] {
                text.lineBreakMode = .byTruncatingTail
                text.maximumNumberOfLines = 1
                addSubview(text)
            }
            indicator.wantsLayer = true
            indicator.layer?.addSublayer(arc)
            arc.fillColor = nil; arc.lineWidth = 1.5
            addSubview(indicator)
            setAccessibilityIdentifier("ssh-reconnect-overlay")
        }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let hit = super.hitTest(point)
            return hit === button || hit === details || hit === log ? hit : nil
        }
        override func scrollWheel(with event: NSEvent) { wheel(event) }
        func update(state: SSHReconnectController.State, reconnect: @escaping () -> Void,
                    cancel: @escaping () -> Void, wheel: @escaping (NSEvent) -> Void,
                    hostName: String = "Host", close: @escaping () -> Void = {}, reduceMotion: Bool = false,
                    logShown: Bool = false, toggleLog: @escaping () -> Void = {}) {
            let starting = state.reconnecting && !self.state.reconnecting
            self.state = state; self.wheel = wheel
            let presentation = Presentation(state: state, hostName: hostName, nautical: SidebarThemeStore.shared.current == .nautical)
            color = presentation.color
            label.stringValue = presentation.label
            label.textColor = color
            metadata.stringValue = presentation.info.joined(separator: " · ")
            toolTip = presentation.help
            button.title = presentation.actionTitle + "  ⏎"
            button.setAccessibilityLabel(presentation.actionHelp)
            button.toolTip = presentation.actionHelp
            button.isHidden = !presentation.offersReconnect
            if starting && !reduceMotion {
                button.isHidden = false
                let press = CAKeyframeAnimation(keyPath: "transform.scale")
                press.values = [1, 0.94, 1]; press.duration = 0.12
                button.layer?.add(press, forKey: "reconnect-press")
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard let self, self.state.reconnecting else { return }
                    self.button.isHidden = true; self.needsLayout = true
                }
            }
            action = reconnect
            details.title = presentation.detailTitle ?? ""
            details.isHidden = presentation.detailTitle == nil
            details.toolTip = presentation.detailHelp
            detailAction = state.reconnecting ? cancel : close
            log.title = logShown ? "Log ▴" : "Log ▾"
            log.isHidden = state.connected || state.gone
            log.toolTip = logShown ? "Hide the login log" : "Show the login log: what the reconnect did and what ssh said"
            logAction = toggleLog
            arc.strokeColor = color.cgColor
            arc.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: 8, height: 8), transform: nil)
            arc.strokeStart = state.reconnecting ? 0.125 : 0
            arc.strokeEnd = state.reconnecting ? 0.875 : 1
            arc.fillColor = state.reconnecting ? nil : color.cgColor
            if state.reconnecting && !reduceMotion {
                if arc.animation(forKey: "sweep") == nil {
                    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                    animation.fromValue = 0; animation.toValue = Double.pi * 2
                    animation.duration = 0.9; animation.repeatCount = .infinity
                    arc.add(animation, forKey: "sweep")
                }
            } else { arc.removeAnimation(forKey: "sweep") }
            needsLayout = true; needsDisplay = true
        }
        func appearance(theme: ChatTheme, font: NSFont) {
            layer?.backgroundColor = NSColor(theme.window).blended(withFraction: 0.09, of: color)?.cgColor
            button.layer?.backgroundColor = color.cgColor
            button.contentTintColor = SSHReconnectControl.actionInk
            details.contentTintColor = NSColor(theme.muted)
            log.contentTintColor = NSColor(theme.muted)
            details.layer?.borderWidth = 1; details.layer?.borderColor = NSColor(theme.border).cgColor
            metadata.textColor = NSColor(theme.muted)
            for control in [button, details, log] { control.font = font }
            label.font = font; metadata.font = font
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            color.withAlphaComponent(0.3).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        }
        override func layout() {
            super.layout()
            let scale = max(1, (label.font?.pointSize ?? 11.5) / 11.5)
            let height = min(bounds.height - 8, 22 * scale)
            let closeWidth: CGFloat = 84 * scale
            let buttonWidth = max(118 * scale, ceil(button.intrinsicContentSize.width) + 20 * scale)
            details.isHidden = state.connected || (!state.reconnecting && bounds.width < 280 * scale)
            details.frame = NSRect(x: bounds.width - closeWidth - 14, y: bounds.midY - height / 2, width: closeWidth, height: height)
            let logWidth = ceil(log.intrinsicContentSize.width) + 12 * scale
            let afterLog = details.isHidden ? bounds.width - 14 : details.frame.minX - 8
            log.frame = NSRect(x: afterLog - logWidth, y: bounds.midY - height / 2, width: logWidth, height: height)
            let trailing = log.isHidden ? afterLog : log.frame.minX - 4
            button.frame = NSRect(x: max(30, trailing - buttonWidth), y: bounds.midY - height / 2, width: buttonWidth, height: height)
            let textEnd = !button.isHidden ? button.frame.minX - 12 : !log.isHidden ? log.frame.minX - 12
                : !details.isHidden ? details.frame.minX - 12 : bounds.width - 14
            indicator.frame = NSRect(x: 13, y: bounds.midY - 5, width: 10, height: 10)
            arc.frame = indicator.bounds
            let available = max(0, textEnd - 34)
            let textWidth = (label.stringValue as NSString).size(withAttributes: [.font: label.font ?? AppFont.native(size: 11.5)]).width
            let labelWidth = min(available, ceil(textWidth) + 6)
            label.frame = NSRect(x: 34, y: bounds.midY - label.intrinsicContentSize.height / 2, width: labelWidth, height: label.intrinsicContentSize.height)
            metadata.frame = NSRect(x: label.frame.maxX + 12, y: bounds.midY - metadata.intrinsicContentSize.height / 2,
                                    width: max(0, textEnd - label.frame.maxX - 12), height: metadata.intrinsicContentSize.height)
            label.isHidden = available < 65
        }
        @objc private func performAction() { action() }
        @objc private func performDetailAction() { detailAction() }
        @objc private func performLogAction() { logAction() }
    }
}
