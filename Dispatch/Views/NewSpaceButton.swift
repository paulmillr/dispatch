import AppKit
import Observation
import SwiftUI

enum SpaceBackend: String, CaseIterable, Codable, Sendable {
    case native, tmux, herdr

    var title: String {
        switch self {
        case .native: "New space"
        case .tmux: "New tmux space"
        case .herdr: "New herdr space"
        }
    }

    var menuTitle: String {
        switch self {
        case .native: "New plain space"
        case .tmux: "New tmux space"
        case .herdr: "New herdr space"
        }
    }

    var command: String? {
        switch self {
        case .native: nil
        case .tmux: "tmux -CC new-session"
        case .herdr: "herdr"
        }
    }

    static func installed(on machine: TerminalMachine) async -> Set<Self>? {
        let probe = """
        for name in tmux herdr; do
          if command -v "$name" >/dev/null 2>&1; then printf 'dispatch-backend:%s\\n' "$name"; fi
        done
        printf 'dispatch-backend:complete\\n'
        """
        let executable: String, arguments: [String]
        switch machine {
        case .local:
            executable = "/bin/zsh"
            arguments = ["-lic", probe]
        case .ssh(let shell):
            executable = shell.executable
            arguments = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=3",
                         "-o", "RemoteCommand=none", "-o", "ClearAllForwardings=yes"]
                + shell.options + ["-T", "--", shell.destination, remoteProbeCommand(probe)]
        }
        guard let result = try? await SSHCommand.run(executable: executable, arguments: arguments, timeout: 5),
              result.status == 0 else { return nil }
        let lines = String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard lines.contains("dispatch-backend:complete") else { return nil }
        return Set(allCases.filter { $0 == .native || lines.contains("dispatch-backend:" + $0.rawValue) })
    }
    private static func remoteProbeCommand(_ probe: String) -> String {
        // Load the account's actual interactive login PATH (zprofile/zshrc on
        // macOS), then run the portable probe in sh so fish syntax also works.
        let command = "exec /bin/sh -c " + HerdrLaunch.quote(probe)
        let login = "exec \"${SHELL:-/bin/sh}\" -lic " + HerdrLaunch.quote(command)
        return "/bin/sh -c " + HerdrLaunch.quote(login)
    }

}

/// Host popovers and new-space menus share discoveries for one minute. A
/// closing view does not cancel a probe another view is already waiting for.
@MainActor @Observable
final class HostBackendCache {
    static let shared = HostBackendCache()
    private struct Entry {
        let backends: Set<SpaceBackend>?
        let expires: ContinuousClock.Instant
    }
    private var entries: [HostID: Entry] = [:]
    @ObservationIgnored private var pending: [HostID: Task<Set<SpaceBackend>, Never>] = [:]
    @ObservationIgnored private let ttl: Duration
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private let probe: @MainActor (TerminalMachine) async -> Set<SpaceBackend>?

    init(ttl: Duration = .seconds(60), now: @escaping () -> ContinuousClock.Instant = { .now },
         probe: @escaping @MainActor (TerminalMachine) async -> Set<SpaceBackend>? = { await SpaceBackend.installed(on: $0) }) {
        self.ttl = ttl; self.now = now; self.probe = probe
    }

    func cached(for host: HostID) -> Set<SpaceBackend>? {
        guard let entry = entries[host], now() < entry.expires else { return nil }
        return entry.backends
    }

    func probeFailed(for host: HostID) -> Bool {
        guard let entry = entries[host], now() < entry.expires else { return false }
        return entry.backends == nil
    }

    func refreshDelay(for host: HostID) -> Duration {
        guard let entry = entries[host] else { return .milliseconds(1) }
        return max(.milliseconds(1), now().duration(to: entry.expires))
    }

    func installed(for host: HostID, on machine: TerminalMachine) async -> Set<SpaceBackend> {
        if let entry = entries[host], now() < entry.expires { return entry.backends ?? [.native] }
        if let pending = pending[host] { return await pending.value }
        let task = Task<Set<SpaceBackend>, Never> {
            let backends = await probe(machine)
            guard !Task.isCancelled else { return [.native] }
            // A failed connection is unknown, not evidence of missing software.
            entries[host] = Entry(backends: backends, expires: now().advanced(by: backends == nil ? .seconds(5) : ttl))
            pending[host] = nil
            return backends ?? [.native]
        }
        pending[host] = task
        return await task.value
    }

    func resetRemote() {
        for (host, task) in pending where host != .local { task.cancel() }
        pending = pending.filter { $0.key == .local }
        entries = entries.filter { $0.key == .local }
    }

    func reset(_ host: HostID) {
        pending.removeValue(forKey: host)?.cancel()
        entries[host] = nil
    }
}

/// The new-space buttons' plus: the SF Symbol at the label's size, a little smaller and heavier than its text so it
/// sits on the text's cap height with a matching stroke.
private struct NewSpacePlus: View {
    let size: CGFloat
    var body: some View {
        Image(systemName: "plus").font(.system(size: (size * 0.82).rounded(), weight: .semibold)).accessibilityHidden(true)
    }
}

/// Both locations use the same primary action, with the backend menu on a secondary click.
struct NewSpaceButton: View {
    let workspace: Workspace
    var host: HostRecord?
    var metrics = SidebarMetrics.large(contentSize: 12.5)
    /// A tree group's header button: the plus alone, shortcut in its tooltip.
    var grouped = false
    /// A header button shows only while its group is hovered, empty or read by VoiceOver.
    var revealed = true
    @Environment(\.appTypography) private var typography
    @State private var hovered = false

    private var isLocalSidebar: Bool { host?.id == .local }
    /// Only advertise Command-N where it currently targets.
    private var shortcut: String? {
        if isLocalSidebar { return "⇧⌘N" }
        return host == nil || host?.id == (workspace.current?.hostID ?? .local) ? "⌘N" : nil
    }
    /// What it makes: in a tree group, a space on that group's host.
    private var title: String {
        if grouped, let host { return host.id == .local ? "New local space" : "New space on \(host.name)" }
        return isLocalSidebar ? "New local space" : "New space"
    }

    var body: some View {
        Group {
            if grouped { headerLabel } else { actionRow }
        }
        .allowsHitTesting(false)
        .overlay {
            NewSpaceControl(workspace: workspace, host: host?.id, identifier: host.map { "host-new-space-\($0.id.rawValue)" }
                ?? "sidebar-new-space")
                .accessibilityLabel(title)
                .accessibilityIdentifier(host.map { "host-new-space-\($0.id.rawValue)" }
                    ?? "sidebar-new-space")
        }
        .onHover { hovered = $0 }
        .help(title + (shortcut.map { " (\($0))" } ?? "") + " · Right-click for options")
    }

    /// A tree group's header button: a plus in the header's own control style, a soft capsule under the pointer and no
    /// glass of its own; in Large's host chip, a small circle at the chip's trailing end.
    private var headerLabel: some View {
        let side = metrics.cards ? metrics.headerHeight - 6 : metrics.headerHeight
        return Image(systemName: "plus")
            .font(.system(size: (metrics.headerSize * (metrics.cards ? 0.9 : 1)).rounded(), weight: .semibold))
            .foregroundStyle(hovered ? Chrome.ink : Chrome.palette.secondary)
            .frame(width: side, height: side)
            .background(hovered ? Chrome.palette.hover : .clear, in: Circle())
            .contentShape(Circle())
            .opacity(revealed || hovered ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: revealed || hovered)
    }

    /// The flat order's "+ local" and "+ space", side by side under the last space: a capsule each on Liquid Glass,
    /// their glass blending with their neighbour's; otherwise tiles in Large or rows in compact.
    @ViewBuilder private var actionRow: some View {
        if glass { glassLabel } else if metrics.large { tileLabel } else { rowLabel }
    }

    private var glass: Bool { LiquidGlassStore.shared.active }

    /// Compact flat list: a row like a space's, the icon in the status column.
    private var rowLabel: some View {
        fitted(iconSize: metrics.hostIconSize, iconWidth: max(metrics.activitySize, metrics.hostIconSize), shortcutSize: metrics.shortcutSize)
            .font(AppFont.ui(size: metrics.nameSize))
            .foregroundStyle(hovered ? Chrome.ink : Chrome.palette.detail)
            .padding(.leading, 6).padding(.trailing, 8).frame(height: metrics.rowHeight)
            .background(hovered ? Chrome.palette.hover : .clear, in: RoundedRectangle(cornerRadius: metrics.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
    }

    /// Large without glass: a filled tile as tall as the glass capsules, each filling half the row.
    private var tileLabel: some View {
        fitted(iconSize: typography.hostIconSize, shortcutSize: typography.size(offset: -1.5))
            .font(AppFont.ui(size: typography.tabSize))
            .foregroundStyle(Chrome.ink).opacity(hovered ? 1 : 0.75)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity).frame(height: StripTab.glassTrackHeight(typography))
            .background(Chrome.palette.sidebarAction, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Liquid Glass: one of the two new-space capsules, its glass blending with its neighbour's; a faint capsule nested
    /// 2 points inside it marks the pointer.
    private var glassLabel: some View {
        fitted(iconSize: typography.hostIconSize, shortcutSize: typography.size(offset: -1.5))
            .font(AppFont.ui(size: typography.tabSize))
            .foregroundStyle(hovered ? Chrome.ink : Chrome.palette.detail)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity).frame(height: StripTab.glassTrackHeight(typography))
            .background(hovered ? Chrome.palette.hover : .clear, in: Capsule().inset(by: 2))
            .liquidGlass(in: Capsule())
            .contentShape(Capsule())
    }

    /// "local" led by the Mac's icon or "space" by a plus, with its shortcut on the right, as on space tiles. A narrow
    /// sidebar drops the shortcut before the label; the tooltip still names it.
    private func fitted(iconSize: CGFloat, iconWidth: CGFloat? = nil, shortcutSize: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            contents(iconSize: iconSize, iconWidth: iconWidth, shortcutSize: shortcutSize, showsShortcut: true)
            contents(iconSize: iconSize, iconWidth: iconWidth, shortcutSize: shortcutSize, showsShortcut: false)
        }
        .lineLimit(1)
    }

    private func contents(iconSize: CGFloat, iconWidth: CGFloat?, shortcutSize: CGFloat, showsShortcut: Bool) -> some View {
        HStack(spacing: 6) {
            Group {
                if let host, isLocalSidebar { HostGlyph(host: host, size: iconSize) }
                else { NewSpacePlus(size: iconSize) }
            }
            .foregroundStyle(Chrome.palette.secondary)
            .frame(width: iconWidth)
            Text(isLocalSidebar ? "local" : "space")
            Spacer(minLength: 0)
            if showsShortcut, let shortcut {
                Text(shortcut).font(.system(size: shortcutSize).monospacedDigit()).tracking(shortcutSize * 0.06)
                    .foregroundStyle(Chrome.palette.secondary.opacity(0.7))
            }
        }
    }
}

@MainActor
enum NewSpaceMenu {
    struct Choice {
        /// The item's name ("New tmux space"); `title` adds the host when the menu lists several.
        let label: String
        let title: String
        let host: HostID
        /// Legacy route: the backend the space starts; nil for a helper multiplexer's program.
        let backend: SpaceBackend?
        /// Helper route: the command a new terminal runs; its multiplexer claims the client.
        var program: String? = nil
        var mux: (endpoint: HelperWorkspace.Endpoint, id: UInt64)? = nil
        var menuTitle: String { backend?.menuTitle ?? label }
    }

    struct Option {
        let choice: Choice
        let unavailableReason: String?
        let action: (() -> Void)?
    }

    struct HostGroup {
        let host: HostRecord
        let options: [Option]
    }

    static func groups(workspace: Workspace, host: HostID? = nil,
                       probe: (@Sendable (TerminalMachine) async -> Set<SpaceBackend>)? = nil,
                       helperAvailable: ((HostID) -> Bool)? = nil) async -> [HostGroup] {
        let choices = await choices(workspace: workspace, host: host, probe: probe)
        let hosts = host.map { [workspace.hosts.record($0)] } ?? workspace.liveHosts
        return groups(workspace: workspace, hosts: hosts, choices: choices, helperAvailable: helperAvailable)
    }

    /// Open menus from the last discovery plus direct evidence from attached
    /// spaces. Controls start a refresh when mounted, so menu presentation never
    /// waits for a local shell or SSH round trip.
    static func immediateGroups(workspace: Workspace, host: HostID? = nil,
                                helperAvailable: ((HostID) -> Bool)? = nil) -> [HostGroup] {
        let hosts = host.map { [workspace.hosts.record($0)] } ?? workspace.liveHosts
        let availability = Dictionary(uniqueKeysWithValues: hosts.compactMap { record in
            workspace.newSpaceMachine(on: record.id).map { _ in
                (record.id, HostBackendCache.shared.cached(for: record.id) ?? [.native])
            }
        })
        let choices = choices(workspace: workspace, hosts: hosts, availability: availability, scoped: host != nil)
        return groups(workspace: workspace, hosts: hosts, choices: choices, helperAvailable: helperAvailable)
    }

    private static func groups(workspace: Workspace, hosts: [HostRecord], choices: [Choice],
                               helperAvailable: ((HostID) -> Bool)?) -> [HostGroup] {
        return hosts.compactMap { host in
            let options = choices.filter { $0.host == host.id }.map { choice in
                let supported = choice.backend != .herdr || host.id == .local
                    || (helperAvailable?(host.id) ?? hasHelper(workspace: workspace, host: host.id))
                let create: () -> Void = {
                    if let mux = choice.mux,
                       let space = ([workspace.current].compactMap { $0 } + workspace.presentationSpaces).first(where: { space in
                           space.hostID == choice.host && space.structured
                               && workspace.helper(space)?.endpoint == mux.endpoint
                               && space.backend.flatMap { workspace.helper(space)?.kind(of: $0)?.mux } == mux.id
                       }), let backend = space.backend, let helper = workspace.helper(space) {
                        helper.create(backend, in: space)
                    } else if let program = choice.program {
                        workspace.newLocalSpace(program: program)
                    } else {
                        workspace.newSpace(on: choice.host, backend: choice.backend)
                    }
                }
                return Option(choice: choice, unavailableReason: supported ? nil : "no helper",
                              action: supported ? create : nil)
            }
            return options.isEmpty ? nil : HostGroup(host: host, options: options)
        }
    }

    /// A remote multiplexer opens as spaces only through that host's helper.
    private static func hasHelper(workspace: Workspace, host: HostID) -> Bool {
        workspace.helpers.values.contains { $0.endpoint != .local && $0.host == host }
    }

    static func choices(workspace: Workspace, host: HostID? = nil,
                        probe: (@Sendable (TerminalMachine) async -> Set<SpaceBackend>)? = nil) async -> [Choice] {
        let hosts = host.map { [workspace.hosts.record($0)] } ?? workspace.liveHosts
        // Probe independently so an unreachable host cannot delay each later host.
        let machines = hosts.compactMap { record in
            workspace.newSpaceMachine(on: record.id).map { (record.id, $0) }
        }
        let availability = await withTaskGroup(of: (HostID, Set<SpaceBackend>).self) { group in
            for (id, machine) in machines {
                group.addTask {
                    if let probe { return (id, await probe(machine)) }
                    return (id, await HostBackendCache.shared.installed(for: id, on: machine))
                }
            }
            var result: [HostID: Set<SpaceBackend>] = [:]
            for await (id, installed) in group { result[id] = installed }
            return result
        }
        return choices(workspace: workspace, hosts: hosts, availability: availability, scoped: host != nil)
    }

    private static func choices(workspace: Workspace, hosts: [HostRecord], availability: [HostID: Set<SpaceBackend>],
                                scoped: Bool) -> [Choice] {
        hosts.flatMap { record -> [Choice] in
            guard var installed = availability[record.id] else { return [] }
            installed.insert(.native)
            // An attached backend proves availability even if a fresh SSH probe fails.
            let spaces = workspace.spaces.filter { $0.hostID == record.id }
            for space in spaces where space.structured {
                if let name = space.backend.flatMap({ workspace.helper(space)?.multiplexer(of: $0) }),
                   let kind = SpaceBackend(rawValue: name) { installed.insert(kind) }
            }
            let suffix = !scoped && record.id != .local ? " on \(record.name)" : ""
            // This Mac's helper lists what it can start: a plain space and each multiplexer with a program.
            if record.id == .local, let helper = workspace.helpers[.local] {
                return [Choice(label: SpaceBackend.native.title, title: SpaceBackend.native.title, host: .local, backend: .native)]
                    + helper.multiplexers.compactMap { kind in
                        kind.program.map {
                            let label = "New \(kind.name) space"
                            return Choice(label: label, title: label, host: .local, backend: nil, program: $0, mux: (.local, kind.mux))
                        }
                    }
            }
            return SpaceBackend.allCases.filter { installed.contains($0) }.map {
                Choice(label: $0.title, title: $0.title + suffix, host: record.id, backend: $0)
            }
        }
    }
}

private struct NewSpaceControl: NSViewRepresentable {
    let workspace: Workspace
    let host: HostID?
    let identifier: String

    func makeNSView(context: Context) -> NewSpaceNativeButton { NewSpaceNativeButton() }

    func updateNSView(_ button: NewSpaceNativeButton, context: Context) {
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(host == .local ? "New local space" : "New space")
        button.create = { workspace.newSpace(on: host ?? workspace.current?.hostID ?? .local) }
        button.host = host
        button.immediateOptions = { NewSpaceMenu.immediateGroups(workspace: workspace, host: host) }
        button.options = { await NewSpaceMenu.groups(workspace: workspace, host: host) }
        button.prefetchOptions()
    }
}

final class NewSpaceNativeButton: NSButton {
    var host: HostID? {
        didSet { if host != oldValue { prefetched = false } }
    }
    var create: () -> Void = {}
    var immediateOptions: (() -> [NewSpaceMenu.HostGroup])?
    var options: () async -> [NewSpaceMenu.HostGroup] = { [] }
    var presentMenu: (NSMenu, NSView, NSPoint) -> Void = { menu, view, point in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    private var menuTask: Task<Void, Never>?
    private var prefetched = false
    private var choices: [(() -> Void)?] = []

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        target = self
        action = #selector(createSpace)
        setAccessibilityLabel("New space")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    @objc private func createSpace() { create() }
    @objc private func choose(_ sender: NSMenuItem) {
        guard choices.indices.contains(sender.tag) else { return }
        choices[sender.tag]?()
    }

    /// A click makes a space; the backend menu is the secondary click's, as a context menu (control-click too).
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { showOptions(at: convert(event.locationInWindow, from: nil)); return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) { showOptions(at: convert(event.locationInWindow, from: nil)) }

    func makeMenu(groups: [NewSpaceMenu.HostGroup]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.minimumWidth = 200
        choices = []
        if let host {
            for group in groups where group.host.id == host {
                addOptions(group.options, to: menu)
            }
            return menu
        }
        choices = [create]
        let here = NSMenuItem(title: "New space here", action: #selector(choose(_:)), keyEquivalent: "n")
        here.keyEquivalentModifierMask = .command
        here.target = self; here.tag = 0
        menu.addItem(here)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "On host"))
        for group in groups {
            let entry = NSMenuItem(title: group.host.id == .local ? "local" : group.host.name, action: nil, keyEquivalent: "")
            let renderer = ImageRenderer(content: HostGlyph(host: group.host)
                .foregroundStyle(group.host.tint?.foreground ?? Chrome.ink))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            entry.image = renderer.nsImage
            entry.image?.size = NSSize(width: 12, height: 12)
            let submenu = NSMenu(title: entry.title)
            submenu.autoenablesItems = false
            submenu.minimumWidth = 190
            addOptions(group.options, to: submenu)
            entry.submenu = submenu
            menu.addItem(entry)
        }
        return menu
    }

    private func addOptions(_ options: [NewSpaceMenu.Option], to menu: NSMenu) {
        for option in options {
            let item = NSMenuItem(title: option.choice.menuTitle, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choices.count
            choices.append(option.action)
            item.isEnabled = option.action != nil
            if let reason = option.unavailableReason {
                item.attributedTitle = NSAttributedString(string: item.title + "    " + reason,
                    attributes: [.font: NSFont.menuFont(ofSize: 13), .foregroundColor: NSColor.disabledControlTextColor])
                item.toolTip = "Requires an active SSH helper with All features on this connection."
            }
            menu.addItem(item)
        }
    }

    private func showOptions(at point: NSPoint) {
        if let immediateOptions {
            presentMenu(makeMenu(groups: immediateOptions()), self, point)
            return
        }
        menuTask?.cancel()
        let load = options
        menuTask = Task { [weak self] in
            let items = await load()
            guard !Task.isCancelled, let self, self.window != nil else { return }
            let menu = self.makeMenu(groups: items)
            self.presentMenu(menu, self, point)
        }
    }

    func prefetchOptions() {
        guard !prefetched else { return }
        prefetched = true
        let load = options
        Task { _ = await load() }
    }
}
