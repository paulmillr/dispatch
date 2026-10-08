import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let workspace: Workspace = Workspace()
    let settings: SettingsStore
    let windowState: WindowState = WindowState()
    var window: NSWindow! {
        // Read the traffic lights once, outside SwiftUI rendering: querying AppKit frames from a body forces reentrant layout.
        didSet {
            guard let button = window?.standardWindowButton(.zoomButton) else { return }
            windowState.nativeControlsInset = button.convert(button.bounds, to: nil).maxX + 16
        }
    }
    private var settingsWindow: NSWindow?
    private var appearanceObservation: NSKeyValueObservation?
    private var termination: Task<Void, Never>?
    let hostSessionStore: HostSessionStore?
    private var closingNativeTabs: Set<UUID> = []
    private var savedHostSession = false

    private func saveHostSession() {
        guard !savedHostSession, hostSessionStore != nil else { return }
        savedHostSession = true
        persistHostSession(quitting: true)
    }

    /// Terminal output is saved only as the app quits, so a crash or kill never leaves it on disk.
    func persistHostSession(quitting: Bool = false) {
        guard !TerminalRuntime.shared.isResettingSSH, let hostSessionStore else { return }
        do {
            if settings.values.rememberHosts {
                try hostSessionStore.save(runtime: TerminalRuntime.shared, history: quitting && settings.values.restoreTerminalOutput)
            } else { try hostSessionStore.clear() }
        } catch { settings.error = "Could not update saved hosts: \(error.localizedDescription)" }
    }

    func resetSSHState() async throws {
        // Fail visibly before disconnecting if the saved state cannot be removed.
        try hostSessionStore?.clear()
        try await TerminalRuntime.shared.resetSSHState()
        try hostSessionStore?.clear()
    }

    @discardableResult
    func restoreHostSession() -> Bool {
        // Saved output is for this launch only: off the disk before anything can fail.
        let history = hostSessionStore?.terminalHistory.take() ?? [:]
        guard settings.values.rememberHosts else {
            persistHostSession()
            return false
        }
        guard hostSessionStore?.restore(runtime: TerminalRuntime.shared) == true else { return false }
        if settings.values.restoreTerminalOutput {
            let surfaces = workspace.allSurfaceIDs
            TerminalRuntime.shared.restoredHistory = history.filter { surfaces.contains($0.key) }
        }
        return true
    }

    init(settings: SettingsStore = SettingsStore(),
         hostSessionStore: HostSessionStore? = ProcessInfo.processInfo.environment["DISPATCH_TESTING"] == "1" ? nil : .standard) {
        self.settings = settings
        self.hostSessionStore = hostSessionStore
        super.init()
        settings.onSave = { [weak self] preferences in
            ChatViewportTrace.shared.setEnabled(preferences.enableDiagnostics)
            self?.applyKeyGroups(preferences.keyGroups)
            if !preferences.rememberHosts { self?.persistHostSession() }
            if !preferences.restoreTerminalOutput {
                TerminalRuntime.shared.restoredHistory = [:]
                do { try self?.hostSessionStore?.terminalHistory.remove() }
                catch { self?.settings.error = "Could not delete saved terminal output: \(error.localizedDescription)" }
            }
        }
        HostColorStore.shared.persist = { [weak self] choices in
            guard let self else { return }
            var values = settings.values
            values.hostColors = choices
            do { try settings.save(values) } catch { settings.error = error.localizedDescription }
        }
        workspace.onForgetHost = { [weak self] in self?.persistHostSession() }
        workspace.prefixKeys.table = { [weak self] in self?.prefixTable(for: $0) }
        workspace.prefixKeys.perform = { [weak self] in self?.performPrefix($0, surface: $1) }
    }

    func updateMinimumContentSize(_ size: NSSize) {
        guard let window, let content = window.contentView else { return }
        window.contentMinSize = size
        guard !windowState.isFullScreen else { return }
        let desired = NSSize(width: max(size.width, content.bounds.width), height: max(size.height, content.bounds.height))
        guard desired != content.bounds.size else { return }
        var frame = window.frame
        let nextSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: desired)).size
        frame.origin.y -= nextSize.height - frame.height
        frame.size = nextSize
        window.setFrame(frame, display: true)
    }

    private var automaticSidebarVisible: Bool {
        !settings.values.hideSingleSpace || workspace.lastingSpaceCount > 1
    }
    var sidebarVisible: Bool {
        windowState.sidebarVisibilityOverride ?? automaticSidebarVisible
    }

    @objc func toggleSidebar() {
        let visible = !sidebarVisible
        // Returning to the automatic state releases the manual exception, so
        // adding/removing spaces can control visibility again.
        windowState.sidebarVisibilityOverride = visible == automaticSidebarVisible ? nil : visible
        DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
    }

    /// Chat's sheet when the active pane shows chat; otherwise the workspace sheet.
    @objc func showKeyboardShortcuts() {
        if let id = workspace.activeSurfaceID, let session = TerminalRuntime.shared.chat.sessions[id],
           session.showChat, session.hasConversation {
            windowState.shortcutsPresented = false
            session.shortcutsPresented.toggle()
        } else {
            windowState.shortcutsPresented.toggle()
        }
    }

    @objc func focusSpaceSearch() {
        windowState.sidebarVisibilityOverride = true
        windowState.spaceSearchFocusRequest = UUID()
    }

    lazy var attention = AttentionCoordinator(controller: self)

    @objc func nextAttention() { attention.navigate(1) }
    @objc func previousAttention() { attention.navigate(-1) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["DISPATCH_TESTING"] != "1" else { return }
        HostStats.shared.startBackgroundHistory()
        let runtime = TerminalRuntime.shared
        runtime.workspace = workspace
        runtime.start(preferences: settings.values)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                TerminalRuntime.shared.systemAppearanceDidChange()
                if let self { self.applySidebarTheme(self.settings.values.resolvedSidebarTheme) }
            }
        }
        workspace.defaultDirectory = settings.values.startingDirectory
        workspace.spaceOrder = settings.values.spaceOrder
        workspace.onCloseTabs = { TerminalRuntime.shared.close($0) }
        if restoreHostSession() {
            // Keep restored offline hosts visible; local-only sessions follow the usual sidebar rules.
            if workspace.spaces.contains(where: { $0.hostID != .local }) { windowState.sidebarVisibilityOverride = true }
        } else { workspace.newSpace() }
        window = MainWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Dispatch"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(settings.values.resolvedSidebarTheme.palette.window)
        window.appearance = NSAppearance(named: settings.values.resolvedSidebarTheme == .dark ? .darkAqua : .aqua)
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Dispatch.Local.MainWindow")
        window.contentView = NSHostingView(rootView: MainView(workspace: workspace, settings: settings, controller: self))
        buildMenus()
        attention.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { runtime.focusActive() }
    }

    func applicationDidBecomeActive(_ notification: Notification) { TerminalRuntime.shared.setActive(true) }
    func applicationDidResignActive(_ notification: Notification) { TerminalRuntime.shared.setActive(false) }
    func windowDidBecomeKey(_ notification: Notification) {
        TerminalRuntime.shared.setActive(true)
    }

    func windowDidResignKey(_ notification: Notification) { TerminalRuntime.shared.setActive(false) }
    func windowWillEnterFullScreen(_ notification: Notification) { windowState.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        windowState.isFullScreen = false
        DispatchQueue.main.async { TerminalRuntime.shared.focusActive() }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { windowState.isFullScreen = false }
    // Full-screen transitions use temporary AppKit windows. Only an explicit
    // close of our main window should end the application session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }
    func requestTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard termination == nil else { return .terminateLater }
        guard confirmClosing(Array(workspace.allTabIDs), detaching: true) else { return .terminateCancel }
        saveHostSession()
        // Unmount terminal views before stopping the runtime, then keep AppKit
        // alive until private SSH masters and their mailbox paths are released.
        window?.orderOut(nil); window?.contentView = nil
        settingsWindow?.close()
        let cleanup = TerminalRuntime.shared.stop()
        // Quit waits for the cleanup, not forever: a release that never finishes must not keep the
        // app open in AppKit's terminate loop (a test host stayed there).
        let (finished, finish) = AsyncStream<Void>.makeStream()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            let part = TerminalRuntime.shared.stopping ?? "unknown"
            FileHandle.standardError.write(Data("Quit: runtime cleanup still running after 10 s (\(part))\n".utf8))
            finish.finish()
        }
        Task { await cleanup.value; deadline.cancel(); finish.finish() }
        termination = Task {
            for await _ in finished {}
            reply(true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        saveHostSession()
        attention.stop()
        HostStats.shared.stop()
        TerminalRuntime.shared.stop()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        guard confirmClosing(Array(workspace.allTabIDs), detaching: true) else { return false }
        saveHostSession()
        // A window close ends the client presentation; multiplexer sessions survive.
        workspace.spaces.map(\.id).forEach { workspace.detachSpace($0) }
        settingsWindow?.close()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    func confirmClosing(_ ids: [UUID], detaching: Bool = false) -> Bool {
        guard needsCloseConfirmation(ids, detaching: detaching) else { return true }
        return Self.confirmClose()
    }

    static func confirmClose() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close running processes?"
        alert.informativeText = "Closing these terminals will end the processes running inside them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Close")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Detaching a multiplexer session preserves its work. A parked SSH launcher
    /// has no active SSH channel to interrupt; the renderer still sees the launcher
    /// as a foreground command, so its generic process check is insufficient.
    func needsCloseConfirmation(_ ids: [UUID], detaching: Bool = false) -> Bool {
        let runtime = TerminalRuntime.shared
        let kept = Set(workspace.spaces.filter(\.structured).flatMap(\.tabs).map(\.id))
        let tabs = workspace.spaces.flatMap(\.tabs)
        return ids.contains { id in
            guard let tab = tabs.first(where: { $0.id == id }) else { return false }
            if detaching, kept.contains(id) { return false }
            // Closing a multiplexer client's tab (an attach, or a restore waiting for it) ends only
            // that client; the server keeps its work.
            if workspace.helpers.values.contains(where: { $0.controls(id) }) { return false }
            return tab.surfaceIDs.contains { surfaceID in
                if runtime.hosts.reconnect.state(for: surfaceID) != nil { return false }
                return runtime.views[surfaceID]?.surface?.needsConfirmQuit ?? false
            }
        }
    }

    /// Explicit Detach always preserves the native server, even at an idle prompt.
    func detachTab(_ id: UUID) {
        if workspace.helper(containing: id) != nil, workspace.spaces.flatMap(\.tabs).first(where: { $0.id == id })?.terminal != nil {
            workspace.closeTab(id, policy: .detach)
            return
        }
        if confirmClosing([id], detaching: true) { workspace.closeTab(id) }
    }

    func closeTab(_ id: UUID) {
        guard let tab = workspace.spaces.flatMap(\.tabs).first(where: { $0.id == id }) else { return }
        if workspace.helper(containing: id) != nil, tab.terminal != nil {
            workspace.closeTab(id, policy: .prompt)
            return
        }
        detachTab(id)
    }

    /// Window tabs of any structured space; helper containers close through the helper's policy.
    func closeWindow(_ id: UUID) {
        if workspace.helpers.values.contains(where: { $0.dismiss(id) }) { return }
        if let container = workspace.spaces.flatMap(\.containers).first(where: { $0.id == id }) {
            workspace.helper(containing: id)?.close(container.node, policy: .prompt)
        }
    }

    /// Explicit Detach keeps the window running on its server and lists it as detached.
    func detachWindow(_ id: UUID) {
        if let container = workspace.spaces.flatMap(\.containers).first(where: { $0.id == id }) {
            workspace.helper(containing: id)?.close(container.node, policy: .detach)
        }
    }

    func terminateWindow(_ id: UUID) {
        if let container = workspace.spaces.flatMap(\.containers).first(where: { $0.id == id }) {
            if confirmTermination("tab “\(container.name)”") { workspace.helper(containing: id)?.close(container.node, policy: .terminate) }
        }
    }

    func closeSpace(_ id: UUID) {
        guard let space = workspace.spaces.first(where: { $0.id == id }) else { return }
        // Multiplexer sessions keep running when their space closes.
        if space.structured { workspace.detachSpace(id) }
        else if confirmClosing(space.tabs.map(\.id)) { workspace.closeSpace(id) }
    }

    private func confirmTermination(_ subject: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Terminate \(subject)?"
        alert.informativeText = "This ends its server windows or panes and the processes running inside them. To keep work running, use Detach."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Terminate")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func terminateSpace(_ id: UUID) {
        guard let space = workspace.spaces.first(where: { $0.id == id }),
              confirmTermination("space “\(space.name)”") else { return }
        workspace.closeSpace(id, policy: .terminate)
    }

    func terminatePane(_ id: UUID) {
        guard let terminal = workspace.spaces.flatMap(\.tabs).first(where: { $0.id == id })?.terminal,
              confirmTermination("pane") else { return }
        workspace.helper(containing: id)?.close(terminal, policy: .terminate)
    }

    func rename(title: String, value: String, apply: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let input = NSTextField(string: value)
        input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn { apply(input.stringValue) }
        TerminalRuntime.shared.focusActive()
    }

    @objc func newSpace() { workspace.newSpace() }
    @objc func newLocalSpace() { workspace.newSpace(on: .local) }
    /// Detaches the current multiplexer session (its space leaves, its work keeps running).
    @objc func detachCurrent() {
        if let space = workspace.current, space.structured { workspace.detachSpace(space.id) }
    }
    @objc func newTab() { workspace.newTab() }
    @objc func closeCurrentTab() {
        if let settingsWindow, NSApp.keyWindow === settingsWindow { settingsWindow.close(); return }
        if workspace.current?.structured == true, let window = workspace.current?.activeWindow { closeWindow(window.id); return }
        if let id = workspace.activeTab?.id { closeTab(id) }
    }
    @objc func closeCurrentSpace() {
        if let settingsWindow, NSApp.keyWindow === settingsWindow { settingsWindow.close(); return }
        if let id = workspace.selectedSpace { closeSpace(id) }
    }
    @objc func splitColumns() { workspace.toggleSplit(.columns) }
    @objc func splitRows() { workspace.toggleSplit(.rows) }
    @objc func nextTab() { workspace.cycleTab(1) }
    @objc func previousTab() { workspace.cycleTab(-1) }
    @objc func nextSpace() { workspace.cycleSpace(1) }
    @objc func previousSpace() { workspace.cycleSpace(-1) }
    @objc func selectNumberedItem(_ sender: NSMenuItem) { workspace.selectNumberedItem(at: sender.tag) }
    @objc func nextPane() { workspace.cyclePane(1) }
    @objc func previousPane() { workspace.cyclePane(-1) }
    @objc func selectSpace(_ sender: NSMenuItem) {
        workspace.selectSpace(at: sender.tag)
    }
    @objc func renameSpace() {
        guard let current = workspace.current else { return }
        rename(title: "Rename space", value: current.name) { workspace.renameSpace(current.id, to: $0) }
    }
    @objc func renameTab() {
        if workspace.current?.structured == true, let window = workspace.current?.activeWindow {
            rename(title: "Rename tab", value: window.name) { [workspace] in workspace.renameWindow(window.id, to: $0) }
            return
        }
        guard let tab = workspace.activeTab else { return }
        rename(title: "Rename tab", value: tab.label) { workspace.updateTab(tab.id, customTitle: $0) }
    }
    @objc func moveTabToNextPane() {
        guard let space = workspace.current, let tab = space.activeTab,
              space.layout.paneIDs.count > 1,
              let index = space.layout.paneIDs.firstIndex(of: space.focusedPane) else { return }
        workspace.moveTab(tab.id, to: space.layout.paneIDs[(index + 1) % space.layout.paneIDs.count])
    }
    @objc func toggleChat() {
        guard NSApp.keyWindow === window, let id = workspace.activeSurfaceID else { return }
        TerminalRuntime.shared.chat.toggle(id)
    }
    @objc func applyLayout(_ sender: NSMenuItem) {
        guard LayoutPreset.allCases.indices.contains(sender.tag) else { return }
        workspace.applyLayout(LayoutPreset.allCases[sender.tag])
    }
    func applySidebarTheme(_ theme: SidebarTheme) {
        for window in [window, settingsWindow].compactMap({ $0 }) {
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            window.backgroundColor = NSColor(theme.palette.window)
        }
    }

    @objc func showSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let screen = self.window?.screen ?? NSScreen.main
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: min(680, screen?.visibleFrame.height ?? 680)),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 560, height: 440)
        window.maxSize = NSSize(width: 560, height: screen?.visibleFrame.height ?? 900)
        window.backgroundColor = NSColor(settings.values.resolvedSidebarTheme.palette.window)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: settings.values.resolvedSidebarTheme == .dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: SettingsView(store: settings, workspace: workspace,
            resetSSHState: { [weak self] in try await self?.resetSSHState() }, fitInitialHeight: { [weak window] difference in
            guard let window, let available = (window.screen ?? screen)?.visibleFrame else { return }
            var frame = window.frame
            let height = min(available.height, max(min(440, available.height), ceil(frame.height + difference)))
            guard abs(height - frame.height) > 1 else { return }
            frame.origin.y = max(available.minY, min(frame.maxY - height, available.maxY - height))
            frame.size.height = height
            window.setFrame(frame, display: true)
        }))
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(clearScreen):
            guard NSApp.keyWindow === window, let id = workspace.activeSurfaceID else { return false }
            return TerminalRuntime.shared.chat.sessions[id]?.showChat != true && TerminalRuntime.shared.views[id] != nil
        case #selector(findInContent), #selector(findNext), #selector(findPrevious):
            guard NSApp.keyWindow === window, let id = workspace.activeSurfaceID,
                  let session = TerminalRuntime.shared.chat.sessions[id] else { return false }
            return item.action == #selector(findInContent) || (session.showChat ? session.search : session.terminalSearch).visible
        case #selector(closeCurrentTab), #selector(closeCurrentSpace):
            let isSpace = item.action == #selector(closeCurrentSpace)
            let native = workspace.current?.structured == true
            item.title = native && isSpace ? "Detach Space" : (isSpace ? "Close Space" : "Close Tab")
            return workspace.current != nil
        case #selector(focusSpaceSearch), #selector(showKeyboardShortcuts):
            return NSApp.keyWindow === window
        case #selector(toggleSidebar):
            item.title = sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            return NSApp.keyWindow === window
        case #selector(splitColumns), #selector(splitRows):
            return workspace.canToggleSplit(item.action == #selector(splitColumns) ? .columns : .rows)
        case #selector(detachCurrent):
            return workspace.current?.structured == true
        case #selector(applyLayout(_:)):
            guard LayoutPreset.allCases.indices.contains(item.tag) else { return false }
            let preset = LayoutPreset.allCases[item.tag]
            item.title = preset.title.capitalized
            return workspace.current?.structured == true || (workspace.current?.tabs.count ?? 0) >= preset.count
        case #selector(toggleChat):
            guard NSApp.keyWindow === window, let tab = workspace.activeTab else { return false }
            let chat = TerminalRuntime.shared.chat
            let session = chat.session(for: tab.focusedSurfaceID)
            return session.showChat || chat.canEnterChat(session)
        case #selector(nextPane), #selector(previousPane):
            return (workspace.current?.layout.paneIDs.count ?? 0) > 1
        case #selector(moveTabToNextPane):
            return (workspace.current?.layout.paneIDs.count ?? 0) > 1
        case #selector(closeCurrentSpace), #selector(renameSpace):
            return workspace.current != nil
        case #selector(closeCurrentTab):
            return NSApp.keyWindow === settingsWindow || workspace.activeTab != nil
        case #selector(renameTab):
            return workspace.activeTab != nil && workspace.current.map { workspace.helper($0)?.offline($0) == true } != true
        case #selector(nextTab), #selector(previousTab):
            return NSApp.keyWindow === window && workspace.currentTabs.count > 1
        case #selector(nextSpace), #selector(previousSpace):
            return NSApp.keyWindow === window && workspace.spaces.count > 1
        case #selector(selectNumberedItem(_:)):
            item.title = "\(workspace.current?.usesPaneShortcuts == true ? "Pane" : "Tab") \(item.tag + 1)"
            return NSApp.keyWindow === window && item.tag >= 0 && item.tag < (workspace.current?.numberedShortcutCount ?? 0)
        case #selector(selectSpace(_:)):
            return NSApp.keyWindow === window && (item.tag == 8 ? !workspace.spaces.isEmpty : workspace.spaces.indices.contains(item.tag))
        default: return true
        }
    }
}
