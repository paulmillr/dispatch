import AppKit
import SwiftUI
import Term

struct SpaceHoverDetails: Equatable {
    let remote: Bool
    let route: String
    let backend: String
    let directory: String?
    /// Spaces only; a tab's hover has neither.
    var tabs: Int? = nil
    var agents: String? = nil
    var title: String? = nil
    var activity: String? = nil

    var tabCount: String? { tabs.map { $0 == 1 ? "1 tab" : "\($0) tabs" } }

    var summary: String {
        ([remote ? "ssh" : "local", route, backend] + [title, activity, directory, tabCount, agents].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The multiplexer behind a structured space, by the name its helper gives it.
    @MainActor private static func multiplexer(_ space: Space, runtime: TerminalRuntime) -> String? {
        space.backend.flatMap { runtime.workspace?.helper(space)?.multiplexer(of: $0) }
    }

    @MainActor static func make(tab: TerminalTab, host: HostRecord, runtime: TerminalRuntime, title: String? = nil) -> Self {
        var space = Space(name: tab.label, tab: tab)
        space.hostID = host.id
        let context = make(space: space, host: host, runtime: runtime)
        let owner = runtime.workspace?.spaces.first { $0.tabs.contains { $0.id == tab.id } }
        let backend = owner.flatMap { Self.multiplexer($0, runtime: runtime) } ?? "terminal"
        let surfaces = tab.surfaceIDs
        let reconnect = surfaces.compactMap { runtime.hosts.reconnect.state(for: $0) }
        let sessions = surfaces.compactMap { runtime.chat.sessions[$0] }.filter { $0.active }
        let programs = runtime.programs.visible(surfaces)
        let program = [ProgramStatus.State.blocked, .error, .done, .working].lazy.compactMap { state in programs.first { $0.state == state } }.first
        let activity: String?
        if reconnect.contains(where: { $0.reconnecting }) { activity = "Reconnecting" }
        else if !reconnect.isEmpty { activity = "Disconnected" }
        else if tab.isConnecting { activity = "Connecting" }
        else if let session = sessions.first(where: { $0.approvals.contains(where: \.pending) }) {
            activity = session.agentTitle + " · Awaiting approval"
        } else if let session = sessions.first(where: \.discoveryBlocked) {
            activity = session.agentTitle + " · Integration unavailable"
        } else if let session = sessions.first(where: { $0.terminalAttention != nil }) {
            activity = session.agentTitle + " · Needs attention"
        } else if let session = sessions.first(where: { $0.activityCheck != nil }) {
            activity = session.agentTitle + " · Checking activity"
        } else if let program, program.state != .working { activity = program.summary }
        else if let session = sessions.first(where: \.busy) {
            activity = session.agentTitle + " · " + (session.nativeActivity ?? "Working")
        } else if let program { activity = program.summary }
        else if let session = sessions.first { activity = session.agentTitle + " · Idle" }
        else { activity = nil }
        return Self(remote: context.remote, route: context.route, backend: backend, directory: owner?.structured == true ? nil : context.directory,
                    title: title ?? tab.label, activity: activity)
    }

    /// Working agents, then those needing attention (an approval or unread reply), e.g. "2 agents (1 unread)".
    /// Idle agents don't count; nil when nothing is working or waiting on you.
    @MainActor static func agentSummary(_ sessions: [ChatSession]) -> String? {
        let working = sessions.filter { $0.active && $0.busy }.count
        let attention = sessions.filter { [.waiting, .unread].contains(PaneUrgency(session: $0)) }.count
        let unread = attention > 0 ? "\(attention) unread" : nil
        guard working > 0 else { return unread }
        return (working == 1 ? "1 agent" : "\(working) agents") + (unread.map { " (\($0))" } ?? "")
    }

    @MainActor static func make(space: Space, host: HostRecord, runtime: TerminalRuntime) -> Self {
        let tab = space.tabs.first
        let machine = tab.map { runtime.machine(for: $0) } ?? .local
        let remote = host.id != .local || machine != .local
        let backend = Self.multiplexer(space, runtime: runtime) ?? "terminal"
        var route = ""
        if case .ssh(let shell) = machine {
            route = shell.destination.replacingOccurrences(of: "ssh://", with: "")
            if !route.contains("@"), let tab,
               let key = runtime.ssh.presentationScope(for: tab.id),
               let entry = runtime.ssh.permissions.entries[key] {
                route = entry.scope.account + "@" + route
            }
        } else if remote {
            route = host.destinations.count == 1 ? host.destinations[0] : (host.hostname ?? host.name)
        }
        // Multiplexer directories are launch/snapshot metadata, not a live cwd
        // for the hovered pane. Plain SSH tabs can also retain a local launch
        // path. Omit both rather than presenting a stale or unrelated directory.
        let multiplexer = space.structured
        var directory = !remote && !multiplexer ? tab?.directory : nil
        if !remote, let path = directory {
            let home = NSHomeDirectory()
            if path == home { directory = "~" }
            else if path.hasPrefix(home + "/") { directory = "~" + path.dropFirst(home.count) }
        }
        // A tmux space's tabs are its windows; its terminals are their panes.
        return Self(remote: remote, route: route, backend: backend, directory: directory,
                    tabs: space.structured ? space.windows.count : space.tabs.count,
                    agents: agentSummary(space.tabs.flatMap(\.surfaceIDs).compactMap { runtime.chat.sessions[$0] }))
    }
}

/// Shared connection identity for space hovers and host information.
struct ConnectionRouteView: View {
    let remote: Bool
    let route: String
    var fontSize: CGFloat = 12

    private var address: String {
        route.hasPrefix("ssh://") ? String(route.dropFirst(6)) : route
    }

    var body: some View {
        Group {
            Text(remote ? "ssh" : "local")
                .foregroundStyle(Color(red: 126/255, green: 166/255, blue: 201/255)).fixedSize()
            if !address.isEmpty { routeText.truncationMode(.middle) }
        }.font(AppFont.ui(size: fontSize)).lineLimit(1)
    }

    private var routeText: Text {
        guard let at = address.firstIndex(of: "@") else { return Text(address).foregroundColor(Chrome.ink) }
        return Text(String(address[..<at])).foregroundColor(Chrome.ink)
            + Text("@").foregroundColor(Color(red: 92/255, green: 92/255, blue: 100/255))
            + Text(String(address[address.index(after: at)...])).foregroundColor(Chrome.ink)
    }
}

struct SpaceHoverCard: View {
    let details: SpaceHoverDetails
    var fontSize: CGFloat = 12
    var below = false
    var above = false
    private var glass: Bool { LiquidGlassStore.shared.active }
    /// On glass the system's label colors, tuned for it, as in the host popovers.
    private var secondary: Color { glass ? StatsStyle.secondary : Chrome.muted }
    private var muted: Color { glass ? StatsStyle.muted : Chrome.palette.faint }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let title = details.title {
                Text(title).foregroundStyle(Chrome.ink).lineLimit(1).truncationMode(.middle)
                if let activity = details.activity {
                    Text(activity).foregroundStyle(secondary).lineLimit(1)
                }
            }
            HStack(spacing: 8) {
                ConnectionRouteView(remote: details.remote, route: details.route, fontSize: fontSize)
                dot
                Text(details.backend).foregroundStyle(Chrome.accent).fixedSize()
                if let directory = details.directory {
                    dot
                    Text(directory).foregroundStyle(secondary).truncationMode(.middle)
                }
                if let tabCount = details.tabCount {
                    dot
                    Text(tabCount).foregroundStyle(secondary).fixedSize()
                }
                if let agents = details.agents {
                    dot
                    Text(agents).foregroundStyle(secondary).fixedSize()
                }
            }.lineLimit(1)
        }.font(AppFont.ui(size: fontSize))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minHeight: max(30, fontSize + 18))
            .modifier(SpaceHoverSurface(glass: glass, below: below, above: above))
            .accessibilityElement(children: .ignore).accessibilityLabel(details.summary)
            .accessibilityIdentifier(details.title == nil ? "space-hover-card" : "tab-hover-card")
    }

    private var dot: some View { Text("·").foregroundStyle(muted).fixedSize() }
}

/// The card's ground. Flat, an opaque card with an arrow toward its row. On Liquid Glass a glass card without the
/// arrow, with room on every side for the glass's own shadow, which a window sized to the card would cut off; the
/// card keeps the flat card's place, since the arrow's side had that room already.
private struct SpaceHoverSurface: ViewModifier {
    let glass: Bool
    let below: Bool
    let above: Bool

    func body(content: Content) -> some View {
        if glass {
            content.liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous)).padding(5)
        } else {
            content
                .background(StatsStyle.popover, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Chrome.border) }
                .padding(.leading, below || above ? 0 : 5).padding(.top, below ? 5 : 0).padding(.bottom, above ? 5 : 0)
                .overlay(alignment: above ? .bottom : below ? .top : .leading) {
                    SpaceHoverArrow().fill(StatsStyle.popover)
                        .overlay { SpaceHoverArrow().stroke(Chrome.border, lineWidth: 1) }
                        .frame(width: 5, height: 8)
                        .rotationEffect(.degrees(above ? -90 : below ? 90 : 0))
                }
        }
    }
}

private struct SpaceHoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
    }
}

/// A child panel floats over the terminal without stealing focus or mouse input.
@MainActor final class SpaceHoverPresenter {
    private var task: Task<Void, Never>?
    private var observation: NSObjectProtocol?
    private var anchor: NSRect?
    private(set) var panel: NSPanel?

    private func frame(of view: NSView) -> NSRect? {
        guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        let visible = view.bounds.intersection(view.visibleRect)
        return visible.isEmpty ? nil : window.convertToScreen(view.convert(visible, to: nil))
    }

    func schedule(from view: ReorderTrackingView) {
        dismiss()
        guard let row = frame(of: view) else { return }
        task = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self, let view, let window = view.window, window.isKeyWindow,
                  NSEvent.pressedMouseButtons == 0,
                  frame(of: view) == row,
                  view.visibleRect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                  view.configuration.spaceHover != nil else { return }
            present(from: view)
            // Keep dismissal tied to the original row even while the terminal
            // scrolls or another window gains focus.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard view.window === window, window.isKeyWindow, window.isVisible, NSEvent.pressedMouseButtons == 0,
                      view.visibleRect.contains(view.convert(window.mouseLocationOutsideOfEventStream, from: nil)),
                      frame(of: view) == row else {
                    self.dismiss(); return
                }
            }
        }
    }

    func present(from view: ReorderTrackingView) {
        guard panel == nil, let window = view.window, let row = frame(of: view),
              let details = view.configuration.spaceHover else { return }
        let screen = window.screen?.visibleFrame ?? window.frame
        let content = NSHostingView(rootView: SpaceHoverCard(details: details, fontSize: view.configuration.hoverFontSize, below: view.configuration.edge == .horizontal))
        let fitting = content.fittingSize
        let size = NSSize(width: min(fitting.width, screen.width - 20, details.title == nil ? screen.width : 560), height: fitting.height)
        let below = view.configuration.edge == .horizontal
        let above = below && row.minY - size.height - 6 < screen.minY + 10
            && row.maxY + size.height + 6 <= screen.maxY - 10
        content.rootView = SpaceHoverCard(details: details, fontSize: view.configuration.hoverFontSize, below: below && !above, above: above)
        let preferredY = below ? (above ? row.maxY + 6 : row.minY - size.height - 6) : row.midY - size.height / 2
        let origin = NSPoint(x: min(max(screen.minX + 10, below ? row.midX - size.width / 2 : row.maxX + 10), screen.maxX - size.width - 10),
                             y: min(max(screen.minY + 10, preferredY), screen.maxY - size.height - 10))
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false
        // Glass draws its own shadow; the window's would trace the translucent card.
        panel.hasShadow = !LiquidGlassStore.shared.active; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.contentView = content
        self.panel = panel
        anchor = row
        if let clip = view.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        window.addChildWindow(panel, ordered: .above)
    }

    func refresh(from view: ReorderTrackingView) {
        guard let details = view.configuration.spaceHover, let row = frame(of: view), row == anchor else { dismiss(); return }
        guard let panel, let content = panel.contentView as? NSHostingView<SpaceHoverCard> else { return }
        content.rootView = SpaceHoverCard(details: details, fontSize: view.configuration.hoverFontSize, below: view.configuration.edge == .horizontal)
        let screen = view.window?.screen?.visibleFrame ?? panel.frame
        let fitting = content.fittingSize
        var frame = panel.frame
        frame.size = NSSize(width: min(fitting.width, screen.width - 20, details.title == nil ? screen.width : 560), height: fitting.height)
        if view.window != nil {
            let below = view.configuration.edge == .horizontal
            let above = below && row.minY - frame.height - 6 < screen.minY + 10
                && row.maxY + frame.height + 6 <= screen.maxY - 10
            content.rootView = SpaceHoverCard(details: details, fontSize: view.configuration.hoverFontSize, below: below && !above, above: above)
            frame.origin.x = min(max(screen.minX + 10, below ? row.midX - frame.width / 2 : row.maxX + 10), screen.maxX - frame.width - 10)
            frame.origin.y = min(max(screen.minY + 10, below ? (above ? row.maxY + 6 : row.minY - frame.height - 6) : row.midY - frame.height / 2), screen.maxY - frame.height - 10)
        }
        panel.setFrame(frame, display: true)
    }

    func dismiss() {
        task?.cancel(); task = nil
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil; anchor = nil
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }
}
