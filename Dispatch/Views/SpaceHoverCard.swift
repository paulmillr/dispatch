import AppKit
import SwiftUI
import Term

struct SpaceHoverDetails: Equatable {
    let remote: Bool
    let route: String
    let backend: String
    /// Spaces only; a tab's hover has neither.
    var tabs: Int? = nil
    var agents: String? = nil
    /// A tab's title: the card does not show it (the tab does), VoiceOver hears it first.
    var title: String? = nil
    /// A tab's agent or reporting program, under the line ("Claude Code · Idle"); nil without one.
    var activity: String? = nil
    /// The host the line names in its colour ("ssh build-box"); a login without a host of its own is named by its route.
    var host: HostRecord? = nil

    var tabCount: String? { tabs.map { $0 == 1 ? "1 tab" : "\($0) tabs" } }

    /// The remote host's name, or its route where it has no host of its own; nil for local.
    var hostName: String? {
        guard remote else { return nil }
        if let host, host.id != .local { return host.name }
        return route.isEmpty ? nil : route.replacingOccurrences(of: "ssh://", with: "")
    }

    /// "local · tmux · 3 tabs", "ssh build-box · tmux · 3 tabs"; a tab's adds its agent.
    var line: String {
        ([remote ? (["ssh"] + [hostName].compactMap { $0 }).joined(separator: " ") : "local", backend]
            + [tabCount, agents].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var summary: String {
        ([title, line, activity].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A folder's name unless the name beside it already says it: never "api" under "api".
    static func distinct(_ folder: String?, from name: String?) -> String? {
        guard let folder, let name, folder.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
        else { return folder }
        return nil
    }

    /// A folder's name as the phone says it: the last component, "~" for the home folder, "/" for the root.
    static func folderName(_ path: String?, home: String?) -> String? {
        guard var path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if let home = home.map({ $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }), !home.isEmpty, path == home { return "~" }
        return path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    /// The tab's live folder and its host's home (for "~"); nil for a plain SSH tab or an unknown one.
    @MainActor static func liveDirectory(_ id: UUID, runtime: TerminalRuntime) -> (path: String, home: String?)? {
        guard let workspace = runtime.workspace, let tab = workspace.liveTab(id), !tab.directory.isEmpty else { return nil }
        if case .ssh = runtime.machine(for: tab) { return nil }
        let space = workspace.spaces.first { $0.tabs.contains { $0.id == id } }
        let remote = space.map { $0.hostID != .local } ?? false
        let home = remote ? (space?.remote ?? runtime.ssh.connectionForOrigin(id)).flatMap { runtime.ssh.links[$0]?.greeting.home }
            : System.home.path
        return (FilesPath.normalized(tab.directory), home)
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
        return Self(remote: context.remote, route: context.route, backend: backend, title: title ?? tab.label,
                    activity: activity(tab, runtime: runtime), host: host)
    }

    /// The tab's agent, or a program that reports its state, as it needs the user most: nil when it has neither.
    @MainActor static func activity(_ tab: TerminalTab, runtime: TerminalRuntime) -> String? {
        let surfaces = tab.surfaceIDs
        let sessions = surfaces.compactMap { runtime.chat.sessions[$0] }.filter { $0.active }
        let programs = runtime.programs.visible(surfaces)
        let program = [ProgramStatus.State.blocked, .error, .done, .working].lazy.compactMap { state in programs.first { $0.state == state } }.first
        if let session = sessions.first(where: { $0.approvals.contains(where: \.pending) }) {
            return session.agentTitle + " · Awaiting approval"
        } else if let session = sessions.first(where: \.discoveryBlocked) {
            return session.agentTitle + " · Integration unavailable"
        } else if let session = sessions.first(where: { $0.terminalAttention != nil }) {
            return session.agentTitle + " · Needs attention"
        } else if let session = sessions.first(where: { $0.activityCheck != nil }) {
            return session.agentTitle + " · Checking activity"
        } else if let program, program.state != .working { return program.summary }
        else if let session = sessions.first(where: \.busy) {
            return session.agentTitle + " · " + (session.nativeActivity ?? "Working")
        } else if let program { return program.summary }
        else if let session = sessions.first { return session.agentTitle + " · Idle" }
        return nil
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
        // A tmux space's tabs are its windows; its terminals are their panes.
        return Self(remote: remote, route: route, backend: backend,
                    tabs: space.structured ? space.windows.count : space.tabs.count,
                    agents: agentSummary(space.tabs.flatMap(\.surfaceIDs).compactMap { runtime.chat.sessions[$0] }),
                    host: host)
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
            if !address.isEmpty { Self.address(route).truncationMode(.middle) }
        }.interfaceFont(size: fontSize).lineLimit(1)
    }

    /// The route without its scheme, its `@` dimmed between account and host.
    static func address(_ route: String) -> Text {
        let address = route.hasPrefix("ssh://") ? String(route.dropFirst(6)) : route
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
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text(details.remote ? "ssh" : "local")
                        .foregroundStyle(Color(red: 126/255, green: 166/255, blue: 201/255)).fixedSize()
                    if let name = details.hostName {
                        Text(name).foregroundStyle(details.host.flatMap { $0.id == .local ? nil : $0.tint?.foreground } ?? Chrome.ink)
                            .truncationMode(.middle)
                    }
                }
                dot
                Text(details.backend).foregroundStyle(Chrome.accent).fixedSize()
                if let tabCount = details.tabCount {
                    dot
                    Text(tabCount).foregroundStyle(secondary).fixedSize()
                }
                if let agents = details.agents {
                    dot
                    Text(agents).foregroundStyle(secondary).fixedSize()
                }
            }.lineLimit(1)
            if let activity = details.activity {
                Text(activity).foregroundStyle(secondary).lineLimit(1).truncationMode(.tail)
            }
        }.interfaceFont(size: fontSize)
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
