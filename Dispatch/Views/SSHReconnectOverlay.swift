import SwiftUI

struct SSHReconnectOverlay: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let surface: UUID
    let workspace: Workspace
    @State private var lastState: SSHReconnectController.State?
    var body: some View {
        let controller = TerminalRuntime.shared.hosts.reconnect
        let state = controller.presentationState(for: surface)
        let host = workspace.hosts.terminals[surface]?.host
        let glass = LiquidGlassStore.shared.active
        // On glass a row like the tab strip: its glass track, below the strip's margin above that track. Flat, a
        // full-width bar.
        let track = StripTab.glassTrackHeight(typography)
        let margin = (typography.expanded(38) - track) / 2
        let height = glass ? margin + track : typography.expanded(34)
        Group {
            if let displayed = state ?? lastState, let host {
                let hostName = workspace.hosts.record(host).name
                let reconnect = { controller.reconnect(hostID: host, sourceSurfaceID: surface) }
                let cancel = { controller.cancel(hostID: host) }
                if glass {
                    SSHReconnectGlassRow(state: displayed, hostName: hostName, reconnect: reconnect, cancel: cancel, close: closeTab)
                        .frame(height: track)
                        .padding(.horizontal, Chrome.stripInset).padding(.top, margin)
                } else {
                    SSHReconnectControl(state: displayed, reconnect: reconnect, cancel: cancel, wheel: { event in
                            let runtime = TerminalRuntime.shared
                            if let session = runtime.chat.sessions[surface], session.showChat { session.scrollPosition.forwardWheel(event) }
                            else { runtime.views[surface]?.scrollWheel(with: event) }
                        }, hostName: hostName, close: closeTab)
                        .frame(height: height)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: state == nil ? 0 : height, alignment: .top)
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

/// The reconnect row on Liquid Glass, a sibling of the tab strip: the strip's glass track, tinted with the state's
/// color as a remote strip takes its host's, holding the status and its actions. Reconnect is an interactive glass
/// pill inside the track, like the selected tab's, tinted with that color; Cancel and Close tab sit on the track's
/// glass with the strip buttons' faint hover capsule.
struct SSHReconnectGlassRow: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let state: SSHReconnectController.State
    let hostName: String
    let reconnect: () -> Void
    let cancel: () -> Void
    let close: () -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        let presentation = SSHReconnectControl.Presentation(state: state, hostName: hostName)
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
                        Text("Reconnect")
                        Text("⏎").opacity(0.6)
                    }
                    .foregroundStyle(Color(nsColor: SSHReconnectControl.actionInk))
                    .padding(.horizontal, 12).frame(maxHeight: .infinity)
                    .liquidGlass(in: Capsule().inset(by: 2), interactive: true, tint: color)
                    .contentShape(Capsule())
                }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Reconnect to \(hostName)")
                .help("Reconnect to \(hostName) · ⏎")
                .transition(.opacity)
            }
            ReconnectIndicator(color: color, reconnecting: state.reconnecting)
            Text(presentation.label).foregroundStyle(color).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            Text(presentation.info.joined(separator: " · ")).foregroundStyle(Chrome.muted).lineLimit(1)
            Spacer(minLength: 0)
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
                .help(presentation.detailHelp)
            }
        }
        .font(Font(AppFont.native(size: typography.tabSize)))
        // The end actions reach the track's rounded ends, concentric with them; with Reconnect gone, the status mark
        // sits in from the leading end.
        .padding(.leading, presentation.offersReconnect ? 0 : 11)
        // Buttons act without taking focus from the terminal or the chat composer.
        .buttonStyle(.plain).focusable(false).focusEffectDisabled()
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
private struct ReconnectIndicator: View {
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
    /// Amber while offline or reconnecting, green once the session has resumed.
    static func stateColor(connected: Bool) -> NSColor {
        connected ? NSColor(srgbRed: 127/255, green: 211/255, blue: 161/255, alpha: 1)
            : NSColor(srgbRed: 217/255, green: 179/255, blue: 106/255, alpha: 1)
    }
    /// The text on the reconnect primary action, dark on its amber.
    static let actionInk = NSColor(srgbRed: 19/255, green: 19/255, blue: 21/255, alpha: 1)

    /// What the bar says and offers in a state; the flat bar and the glass row draw the same.
    struct Presentation {
        let label: String
        let info: [String]
        /// Reconnect is offered until an attempt starts or the session resumes.
        let offersReconnect: Bool
        /// Cancel while reconnecting, Close tab while offline, nothing once connected.
        let detailTitle: String?
        let detailHelp: String
        let color: NSColor
        var help: String { ([label] + info).joined(separator: " · ") }

        init(state: SSHReconnectController.State, hostName: String) {
            color = SSHReconnectControl.stateColor(connected: state.connected)
            label = state.connected ? "connected" : state.reconnecting ? "reconnecting to \(hostName)" : "\(hostName) disconnected"
            var info: [String] = []
            if state.connected { info = ["session resumed"] }
            else {
                if let date = state.disconnectedAt { info.append(date.formatted(date: .omitted, time: .shortened)) }
                if state.attempts > 0 { info.append("\(state.attempts) \(state.attempts == 1 ? "attempt" : "attempts")") }
                if state.retryAt != nil { info.append("retrying automatically") }
                if let error = state.error { info.append(error) }
            }
            self.info = info
            offersReconnect = !state.reconnecting && !state.connected
            detailTitle = state.connected ? nil : state.reconnecting ? "Cancel" : "Close tab"
            detailHelp = state.reconnecting ? "Cancel reconnect" : "Close tab; keep remote jobs running"
        }
    }
    func makeNSView(context: Context) -> Control { Control() }
    func updateNSView(_ view: Control, context: Context) {
        view.update(state: state, reconnect: reconnect, cancel: cancel, wheel: wheel,
                    hostName: hostName, close: close, reduceMotion: reduceMotion)
        view.appearance(theme: themes.current, font: AppFont.native(size: typography.size(offset: -1)))
    }
    final class Control: NSView {
        private let button = NSButton()
        private let details = NSButton()
        private let indicator = NSView()
        private let arc = CAShapeLayer()
        private let label = NSTextField(labelWithString: "")
        private let metadata = NSTextField(labelWithString: "")
        private var action: () -> Void = {}
        private var detailAction: () -> Void = {}
        private var wheel: (NSEvent) -> Void = { _ in }
        private var state = SSHReconnectController.State()
        private var color = SSHReconnectControl.stateColor(connected: false)
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for button in [button, details] {
                button.isBordered = false; button.focusRingType = .none; button.refusesFirstResponder = true
                button.wantsLayer = true; button.layer?.cornerRadius = 5
                button.target = self
                addSubview(button)
            }
            button.action = #selector(performAction)
            details.action = #selector(performDetailAction)
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
            return hit === button || hit === details ? hit : nil
        }
        override func scrollWheel(with event: NSEvent) { wheel(event) }
        func update(state: SSHReconnectController.State, reconnect: @escaping () -> Void,
                    cancel: @escaping () -> Void, wheel: @escaping (NSEvent) -> Void,
                    hostName: String = "Host", close: @escaping () -> Void = {}, reduceMotion: Bool = false) {
            let starting = state.reconnecting && !self.state.reconnecting
            self.state = state; self.wheel = wheel
            let presentation = Presentation(state: state, hostName: hostName)
            color = presentation.color
            label.stringValue = presentation.label
            label.textColor = color
            metadata.stringValue = presentation.info.joined(separator: " · ")
            toolTip = presentation.help
            button.title = "Reconnect  ⏎"
            button.setAccessibilityLabel("Reconnect to " + hostName)
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
            details.layer?.borderWidth = 1; details.layer?.borderColor = NSColor(theme.border).cgColor
            metadata.textColor = NSColor(theme.muted)
            for control in [button, details] { control.font = font }
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
            let closeWidth: CGFloat = 84 * scale, buttonWidth: CGFloat = 118 * scale
            details.isHidden = state.connected || (!state.reconnecting && bounds.width < 280 * scale)
            details.frame = NSRect(x: bounds.width - closeWidth - 14, y: bounds.midY - height / 2, width: closeWidth, height: height)
            let trailing = details.isHidden ? bounds.width - 14 : details.frame.minX - 8
            button.frame = NSRect(x: max(30, trailing - buttonWidth), y: bounds.midY - height / 2, width: buttonWidth, height: height)
            let textEnd = !button.isHidden ? button.frame.minX - 12 : !details.isHidden ? details.frame.minX - 12 : bounds.width - 14
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
    }
}
