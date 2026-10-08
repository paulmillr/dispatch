import AppKit
import Term

@MainActor
final class TerminalRuntime {
    // Avoid resolving the initializer graph in every file that uses the runtime.
    static let shared: TerminalRuntime = TerminalRuntime()
    /// The terminal engine (TerminalBackend.swift), while the runtime runs.
    private(set) var engine: (any TerminalEngine)?
    /// Dispatch's terminal config as Ghostty reads it: the chrome's colors.
    private(set) var config: Config?
    private(set) var error: String?
    private(set) var isResettingSSH = false
    private(set) var views: [UUID: TerminalView] = [:]
    /// Saved text for relaunched local tabs, shown when each one starts its shell (TerminalHistoryStore).
    var restoredHistory: [UUID: String] = [:]
    var chat: ChatCoordinator = ChatCoordinator()
    let herdrLaunch: HerdrLaunch = HerdrLaunch()
    let ssh: SSHCoordinator = SSHCoordinator()
    lazy var hosts: HostCoordinator = HostCoordinator(runtime: self)
    var preferences: Preferences = Preferences()
    /// This Mac's helper and one per SSH link whose remote helper hosts backends.
    private(set) var helpers: [HelperWorkspace.Endpoint: HelperWorkspace] = [:] {
        didSet { workspace?.helpers = helpers }
    }
    /// Draws every helper terminal, whichever helper runs it.
    private(set) var renderer: HelperRenderer?
    weak var workspace: Workspace? {
        didSet {
            for helper in helpers.values { helper.bind(workspace) }
            workspace?.helpers = helpers
            workspace?.closeLaunching = preferences.closeLaunching
            workspace?.machineForTab = { [weak self] in self?.machine(for: $0) ?? $0.machine }
            workspace?.owningMachineForTab = { [weak self] in self?.owningMachine(for: $0) ?? $0.machine }
        }
    }

    func machine(for tab: TerminalTab) -> TerminalMachine {
        if let machine = hosts.machine(for: tab.focusedSurfaceID) { return machine }
        return owningMachine(for: tab)
    }

    /// A tab's shown name; an exited agent's read-only transcript no longer names it.
    func label(for tab: TerminalTab, automatic: Bool) -> String {
        tab.displayLabel(automatic: automatic, conversation: liveConversationTitle(tab))
    }

    func label(for window: ContainerTab, automatic: Bool) -> String {
        window.displayLabel(automatic: automatic, conversation: window.focusedTerminal.flatMap(liveConversationTitle))
    }

    private func liveConversationTitle(_ tab: TerminalTab) -> String? {
        let session = chat.sessions[tab.focusedSurfaceID]
        return session?.active == true ? session?.conversationTitle : nil
    }

    func owningMachine(for tab: TerminalTab) -> TerminalMachine {
        // A multiplexer's terminal belongs to the machine running its server (its space's helper: this Mac,
        // or the SSH link it came over), never to an SSH login started inside it.
        if let space = workspace?.spaces.first(where: { $0.structured && $0.tabs.contains { $0.id == tab.id } }) {
            if let connection = space.remote, let link = ssh.links[connection] { return .ssh(link.launch.shell) }
            if let backend = space.backend, let helper = workspace?.helper(space),
               let machine = helper.sources(backend).compactMap({ hosts.machine(for: $0) ?? ssh.machine(for: $0) }).first {
                return machine
            }
            return .local
        }
        if let machine = ssh.machine(for: tab.id) { return machine }
        return tab.machine
    }

    func start(preferences: Preferences) {
        guard engine == nil else { return }
        error = nil
        var started = false
        defer { if !started { stop() } }
        AppFont.register()
        self.preferences = preferences
        workspace?.closeLaunching = preferences.closeLaunching
        hosts.reconnect.automatic = preferences.autoReconnectSSH
        if ProcessInfo.processInfo.environment["DISPATCH_TESTING"] != "1" {
            ChatViewportTrace.shared.setEnabled(preferences.enableDiagnostics)
        }
        SidebarThemeStore.shared.current = preferences.resolvedSidebarTheme
        KeyGroupsStore.shared.current = preferences.keyGroups
        LiquidGlassStore.shared.enabled = preferences.liquidGlass
        HostColorStore.shared.choices = preferences.hostColors
        HostColorStore.shared.enabled = preferences.showHostColors
        chat.start()
        guard let resources = Bundle.main.resourceURL else { error = "Terminal resources are missing."; return }
        do {
            // The launch mailbox, shims and shell wrappers (ssh/codex --*-launch) serve every terminal;
            // helper terminals receive them through their creation environment.
            try herdrLaunch.start()
            try ssh.start()
            setenv("GHOSTTY_RESOURCES_DIR", resources.appendingPathComponent("ghostty").path, 1)
            herdrLaunch.sshHandler = { [weak self] request in self?.hosts.accept(request) }
            herdrLaunch.sshConnecting = { [weak self] request in self?.hosts.accept(request, connectingOnly: true) }
            herdrLaunch.sshConsent = { [weak self] request, reply in self?.hosts.consent(request, reply: reply) }
            herdrLaunch.sshClosed = { [weak self] id, notice in self?.hosts.closed(id, notice: notice) }
        } catch { self.error = error.localizedDescription; return }
        do {
            let text = try makeConfig(preferences), dark = isDark(preferences)
            engine = try SwiftEngine(text, dark: dark)
            let config = SwiftEngine.parse(text, dark: dark)
            self.config = config
            ChatThemeStore.shared.current = ChatTheme(config: config, preferences: preferences)
            let executable = HelperApp.executable ?? resources.appendingPathComponent("dispatch-helper")
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("r-\(UUID().uuidString.prefix(8))")
            let renderer = try HelperRenderer(directory: directory, executable: executable)
            renderer.onConnect = { [weak self] tab, channel in self?.workspace?.helper(containing: tab)?.attach(tab, channel) }
            self.renderer = renderer
            helpers[.local] = HelperWorkspace(workspace: workspace, renderer: renderer)
            hosts.start()
            started = true
        } catch { self.error = error.localizedDescription }
    }

    /// Programs set the clipboard (OSC 52, kitty clipboard, tmux buffers) on this Mac
    /// and over plain SSH. Over a connection that has had the helper, Settings decides.
    func allowsClipboardWrite(from surface: UUID) -> Bool {
        preferences.allowRemoteClipboardWrites || !ssh.helperBacked(surface)
    }

    func allowsClipboardWrite(over connection: SSHConnectionID?) -> Bool {
        preferences.allowRemoteClipboardWrites || !(connection.map(ssh.helperInstalled) ?? false)
    }

    func apply(_ preferences: Preferences) throws {
        let text = try makeConfig(preferences), dark = isDark(preferences)
        try engine?.configure(text, dark: dark)
        let next = SwiftEngine.parse(text, dark: dark)
        config = next
        ChatThemeStore.shared.current = ChatTheme(config: next, preferences: preferences)
        self.preferences = preferences
        workspace?.closeLaunching = preferences.closeLaunching
        hosts.reconnect.automatic = preferences.autoReconnectSSH
        for helper in helpers.values { helper.claim(preferences.spaces) }
        SidebarThemeStore.shared.current = preferences.resolvedSidebarTheme
        KeyGroupsStore.shared.current = preferences.keyGroups
        LiquidGlassStore.shared.enabled = preferences.liquidGlass
        HostColorStore.shared.choices = preferences.hostColors
        HostColorStore.shared.enabled = preferences.showHostColors
        for view in views.values { configureBackground(view) }
    }

    func configureBackground(_ view: TerminalView) {
        guard let config else { return }
        view.setBackground(r: config.background.r, g: config.background.g, b: config.background.b)
    }

    /// Each new terminal's scrollback: 1/64 of this Mac's memory (256 MB with 16 GB), bounded so a
    /// single output stream cannot claim gigabytes on high-memory Macs.
    nonisolated static let scrollbackLimit = min(256_000_000, max(50_000_000, Int(clamping: ProcessInfo.processInfo.physicalMemory / 64)))

    /// Dispatch's terminal config text (Ghostty's config syntax, read by the Swift terminal).
    private func makeConfig(_ settings: Preferences) throws -> String {
        try SettingsStore.validate(settings)
        let theme = settings.resolvedTheme(systemIsDark: systemIsDark)
        // A small app-owned config keeps unsupported standalone Ghostty actions
        // and external command wrappers out of this embedding.
        return """
        term = xterm-256color
        font-family = \(settings.fontFamily)
        font-size = \(settings.fontSize)
        theme = \(theme)
        \(settings.usesDefaultColorScheme(systemIsDark: systemIsDark) ? settings.resolvedSidebarTheme.defaultColorSchemeOverrides : "")
        minimum-contrast = \(settings.improveTextContrast ? 4.5 : 1)
        macos-option-as-alt = \(settings.optionAsAlt ? "true" : "false")
        window-padding-x = 10
        window-padding-y = 8
        scrollback-limit-bytes = \(Self.scrollbackLimit)
        image-storage-limit = \(settings.enableKittyGraphics ? ImageStorage.defaultTotalLimit : 0)
        clipboard-read = ask
        clipboard-write = ask
        shell-integration-features = cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,no-path
        keybind = clear
        keybind = super+c=copy_to_clipboard
        keybind = super+v=paste_from_clipboard
        keybind = super+a=select_all
        keybind = shift+page_up=scroll_page_up
        keybind = shift+page_down=scroll_page_down
        """
    }

    private var systemIsDark: Bool {
        SidebarThemeStore.systemIsDark
    }

    private func isDark(_ settings: Preferences) -> Bool { settings.appTheme.isDark(systemIsDark: systemIsDark) }

    func systemAppearanceDidChange() {
        guard engine != nil, preferences.appTheme == .automatic else { return }
        do { try apply(preferences) }
        catch { self.error = error.localizedDescription }
    }

    /// Every tab is a helper terminal drawn by the renderer; its owning helper starts it.
    func view(for tab: TerminalTab) -> TerminalView {
        if let view = views[tab.id] { return view }
        // Kitty file/shared-memory media may read this Mac only for output produced on it: not a remote
        // helper's space, not a space whose host is elsewhere, not an SSH tab.
        let space = workspace?.spaces.first { $0.tabs.contains { $0.id == tab.id } }
        let local = tab.machine == .local && space?.remote == nil && (space?.hostID ?? .local) == .local
        let view = TerminalView(id: tab.id, directory: tab.directory, machine: tab.machine, allowHostMedia: local, helper: renderer)
        views[tab.id] = view
        if let helper = workspace?.helper(containing: tab.id) {
            helper.prepare(tab)
            helper.constrain(tab)
        }
        return view
    }

    /// A remote helper's backends open as spaces of that SSH link; clients started in its login
    /// terminal (shown here as the local tab running ssh) are claimed like those in a shown tab.
    func connect(_ id: SSHConnectionID, terminal: UInt64, tab: UUID, granted: Set<String>, host: HostID,
                 previous: HelperWorkspace? = nil, retained: [HelperWorkspace.Detached] = []) {
        guard let renderer, helpers[.remote(id)].map({ $0.stopped }) ?? true else {
            print("Helper remote observation refused: connection=\(id), renderer=\(renderer != nil), existing=\(helpers[.remote(id)] != nil)")
            return
        }
        print("Helper remote observation start: connection=\(id), terminal=\(terminal), tab=\(tab)")
        let helper = HelperWorkspace(
            workspace: workspace, renderer: renderer, endpoint: .remote(id), granted: granted, host: host, previous: previous, retained: retained)
        helpers[.remote(id)] = helper
        prune()
        helper.observe(terminal, tab: tab)
    }

    /// A lost transport leaves its tabs readable; only a fresh authenticated helper can resume them.
    @discardableResult
    func disconnect(_ id: SSHConnectionID) -> HelperWorkspace? {
        guard let helper = helpers[.remote(id)] else { return nil }
        helper.stop(retaining: true)
        if helper.disposable { helpers[.remote(id)] = nil }
        return helper
    }

    func prune() {
        helpers = helpers.filter { !$0.value.disposable }
    }

    func close(_ ids: [UUID]) {
        let ids = ids.filter { id in !helpers.values.contains { $0.retains(id) } }
        for helper in helpers.values { ids.forEach(helper.detach) }
        for id in ids { ssh.closeTab(id); hosts.close(id); herdrLaunch.close(id); chat.close(id); views.removeValue(forKey: id)?.destroy() }
        prune()
    }

    var hasActiveSSHConnections: Bool {
        hosts.hasActiveSSHConnections || ssh.hasActiveConnections
    }

    func resetSSHState() async throws {
        guard !isResettingSSH else { return }
        isResettingSSH = true
        defer { isResettingSSH = false }
        let remote = hosts.remoteSurfaces.union(ssh.originSurfaces)
        let tabs = workspace?.spaces.flatMap { space in
            space.tabs.filter { tab in
                if space.remote == nil, let helper = workspace?.helper(space),
                   space.backend.map(helper.external) == true { return false }
                return space.hostID != .local || machine(for: tab) != .local || !remote.isDisjoint(with: tab.surfaceIDs)
            }
        } ?? []
        let terminals = tabs.compactMap { tab -> Task<Void, Never>? in
            guard let space = workspace?.spaces.first(where: { $0.tabs.contains { $0.id == tab.id } }),
                  space.remote == nil, let helper = workspace?.helper(space), let terminal = tab.terminal else { return nil }
            return helper.close(terminal, policy: .terminate)
        }
        let pending = hosts.pendingLaunches
        hosts.disconnectOrdinarySSH()
        hosts.stop()
        workspace?.updateLayout { next in
            for tab in tabs { _ = next.detachTab(tab.id) }
            if !next.spaces.contains(where: { $0.id == next.selectedSpace }) { next.selectedSpace = next.spaces.first?.id }
            for index in next.spaces.indices { next.spaces[index].hostID = .local }
        }
        close(tabs.flatMap { [$0.id] + $0.surfaceIDs })
        close(Array(remote.subtracting(workspace?.allSurfaceIDs ?? [])))
        let cleanup = ssh.reset(pending: pending)
        SSHStatisticsStore.shared.reset()
        HostBackendCache.shared.resetRemote()
        workspace?.hosts.reset()
        await cleanup.value
        for terminal in terminals { await terminal.value }
        await hosts.resetDiscoveryCache()
        if engine != nil {
            try ssh.start()
            hosts.start()
            if workspace?.spaces.isEmpty == true { workspace?.newSpace(on: .local, backend: .native) }
        }
    }

    func focusActive() {
        guard let tab = workspace?.activeTab else { return }
        let id = tab.id
        guard chat.sessions[id]?.showChat != true,
              chat.sessions[id]?.terminalSearch.visible != true,
              let view = views[id], view.isPresented, view.window?.isKeyWindow == true else { return }
        view.window?.makeFirstResponder(view)
    }

    func setActive(_ active: Bool) {
        engine?.setActive(active)
        for view in views.values { view.updateFocus() }
    }

    @discardableResult
    func stop() -> Task<Void, Never> {
        for helper in helpers.values { helper.stop() }
        helpers = [:]
        renderer?.stop()
        renderer = nil
        hosts.stop()
        let cleanup = ssh.stop()
        chat.stop()
        close(Array(views.keys))
        engine = nil
        config = nil
        let launcherCleanup = herdrLaunch.stop(after: cleanup)
        let operations = chat.operations
        // In order; `stopping` names the part still running (the quit deadline reports it).
        let parts: [(String, () async -> Void)] = [
            ("SSH masters and launchers", { await launcherCleanup.value }),
            ("chat operations", { await operations.wait() }),
            ("chat integrations", { await self.chat.integrationChanges?.value }),
            ("helper processes", { await HelperApp.shared.stop() }),
        ]
        let task = Task {
            for (name, part) in parts { stopping = name; await part() }
            stopping = nil
        }
        shutdown = task
        return task
    }
    /// The part of `stop()` still running, if any.
    private(set) var stopping: String?
    private(set) var shutdown: Task<Void, Never>?

    enum RuntimeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
    }
}
