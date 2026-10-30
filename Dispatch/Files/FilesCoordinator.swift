import Foundation

/// What a tab shows: its terminal, the agent's chat, or files. A presentation choice only: the shell keeps
/// running, the PTY is never resized, nothing is relaunched.
enum TabMode: String, Hashable, Sendable {
    case terminal, chat, files
}

/// Owns every tab's `FilesSession` and the exclusivity between files and chat. Lives on
/// `TerminalRuntime.shared.files`; the mode switch, menus and the files view talk to it.
@MainActor @Observable final class FilesCoordinator {
    private(set) var sessions: [UUID: FilesSession] = [:]
    /// Drag sources and drop targets of the outline; nil until the transfer code installs it, once. Settings ›
    /// Files › Drag and drop off leaves it installed: its `dragEnabled` gates both.
    var dragDelegate: (any FilesDragDelegate)?
    @ObservationIgnored private let chatCoordinator: @MainActor () -> ChatCoordinator?
    /// The preview width last chosen on any tab: every tab without a width of its own lays out at it
    /// (`previewPreference`), so it reaches tabs whose session existed before the choice. In memory only.
    var lastPreviewWidth: CGFloat?
    /// Closed tabs' views, oldest first, for Restore (FilesCoordinator+Restore.swift).
    @ObservationIgnored var retainedViews: [UUID: RetainedTabView] = [:]
    @ObservationIgnored var retainedOrder: [UUID] = []

    init(chat: @escaping @MainActor () -> ChatCoordinator?) {
        chatCoordinator = chat
    }

    var chat: ChatCoordinator? { chatCoordinator() }

    func session(for id: UUID) -> FilesSession {
        if let session = sessions[id] { return session }
        let session = FilesSession(id: id)
        sessions[id] = session
        observe(session)
        return session
    }

    func existing(_ id: UUID) -> FilesSession? { sessions[id] }

    /// A divider drag (or its double-click, nil: the default width again) on `session`, remembered for the tabs that
    /// have not chosen one.
    func choosePreviewWidth(_ width: CGFloat?, for session: FilesSession) {
        if session.previewWidth != width { session.previewWidth = width }
        if lastPreviewWidth != width { lastPreviewWidth = width }
    }

    /// The width `FilesView.layout` starts from: the tab's own choice, else the last one made anywhere, else nil for
    /// the default rule.
    func previewPreference(for session: FilesSession) -> CGFloat? { session.previewWidth ?? lastPreviewWidth }

    func isShowing(_ id: UUID) -> Bool { sessions[id]?.visible == true }

    func mode(for id: UUID) -> TabMode {
        if isShowing(id) { return .files }
        if chat?.sessions[id]?.showChat == true { return .chat }
        return .terminal
    }

    /// Chat can be entered on this tab (an agent runs or ran in it).
    func chatAvailable(_ id: UUID) -> Bool {
        guard let chat else { return false }
        return chat.canEnterChat(chat.session(for: id))
    }

    /// Shows one view and hides the others. `reason` "user" records a manual choice. Entering files on a plain SSH tab,
    /// or chat where no agent ran, does nothing: the switch and menus never offer them.
    func switchMode(_ id: UUID, to mode: TabMode, reason: String = "user") {
        let user = reason == "user"
        switch mode {
        case .files:
            guard isShowing(id) || canShowFiles(id) else { return }
            let files = session(for: id)
            if let chat, let session = chat.sessions[id], session.showChat {
                chat.setChatVisible(false, session: session, reason: "files")
                // The user left chat: discovery must not bring it back over the terminal once files closes.
                if user { session.manualViewChoice = true }
            }
            if !files.visible {
                files.visible = true
                files.focusRequest = System.uuid()
            }
            // The occluded terminal must not keep typing; the files view takes the keyboard on its focus request.
            if let terminal = TerminalRuntime.shared.views[id], terminal.window?.firstResponder === terminal {
                terminal.window?.makeFirstResponder(nil)
            }
        case .chat:
            guard let chat, chatAvailable(id) || chat.sessions[id]?.showChat == true else { return }
            existing(id)?.visible = false
            chat.chooseChat(true, session: chat.session(for: id))
        case .terminal:
            let wasFiles = isShowing(id)
            existing(id)?.visible = false
            if let chat, let session = chat.sessions[id], session.showChat {
                chat.chooseChat(false, session: session)
            } else if let chat, user, wasFiles, let session = chat.sessions[id] {
                // Files hid the chat, so `showChat` is already false; what chat started still gives way to the terminal.
                chat.leaveChat(session)
            } else if wasFiles {
                Task { @MainActor in TerminalRuntime.shared.focusActive() }
            }
        }
    }

    /// ⇧⌘F: files from any mode, the terminal from files.
    func toggleFiles(_ id: UUID) {
        switchMode(id, to: isShowing(id) ? .terminal : .files)
    }

    /// ⇧⌘C: chat from any mode (from files too), the terminal from chat.
    func toggleChat(_ id: UUID) {
        guard let chat else { return }
        if isShowing(id) { return switchMode(id, to: .chat) }
        chat.toggle(id)
    }

    /// ⌃⌘1–3, ⇧⌘U, ⇧⌘L and the mode button's menu: files on one of its tabs, from any mode. Changes and Commits need a
    /// repository (or one still resolving: the tab falls back to Files if there is none); outside one nothing changes.
    func showFiles(_ id: UUID, tab: FilesTab) {
        guard isShowing(id) || canShowFiles(id) else { return }
        let files = session(for: id)
        guard files.canShow(tab) else { return }
        files.select(tab)
        switchMode(id, to: .files)
    }

    /// The tab can open files on `tab`: files can show here, and for Changes and Commits the folder is not known to be
    /// outside a repository. A tab that never showed files has resolved nothing yet, so it may.
    func canShowFiles(_ id: UUID, tab: FilesTab) -> Bool {
        (isShowing(id) || canShowFiles(id)) && existing(id)?.canShow(tab) != false
    }

    /// The strip button: terminal → chat → files → terminal, or terminal ⇄ files without an agent.
    func cycle(_ id: UUID) {
        if let next = nextMode(id) { switchMode(id, to: next) }
    }

    /// Where the strip button's click goes from the mode shown: from the terminal to chat where an agent runs or ran,
    /// else to files (except on a plain SSH login); from chat or files back to the terminal. Nil when it can go nowhere
    /// (a plain SSH login without an agent: the button dims).
    func nextMode(_ id: UUID) -> TabMode? { switchState(id).next }

    /// What the strip button shows for this tab.
    func switchState(_ id: UUID) -> ModeSwitchState {
        // With Files off the button is chat's alone, and no host is blamed for files it would not show anyway.
        let host = enabled ? plainSSHHost(id) : nil
        return ModeSwitchState(mode: mode(for: id), chat: chatAvailable(id), files: enabled && host == nil, host: host)
    }

    /// Settings › Features › Files.
    var enabled: Bool { TerminalRuntime.shared.preferences.filesEnabled }

    /// Files turned off: the tabs showing it go back to their terminals.
    func leaveFiles() {
        for id in sessions.keys where isShowing(id) { switchMode(id, to: .terminal, reason: "settings") }
    }

    /// Files can show on this tab: Files is on, and the tab is not a plain SSH login with no helper on the host, where
    /// the button dims and explains itself (F1a d). A remote tab with a helper but no Files grant can: the view explains
    /// that.
    func canShowFiles(_ id: UUID) -> Bool { enabled && plainSSHHost(id) == nil }

    /// The host of a plain SSH login in this tab, whose files no helper can list; nil when files can show. The login is
    /// plain when the tab's terminal runs ssh (its own or one typed in it) that Dispatch did not integrate, and no helper
    /// came over that connection or the space's link.
    func plainSSHHost(_ id: UUID) -> String? {
        let runtime = TerminalRuntime.shared
        guard let workspace = runtime.workspace,
              let tab = workspace.spaces.lazy.flatMap(\.tabs).first(where: { $0.id == id }),
              case .ssh(let shell) = runtime.machine(for: tab),
              !runtime.ssh.helperBacked(id),
              // An integrated login still connecting (or reconnecting) gets its helper: the view says it is loading.
              runtime.hosts.integrated(id) != true else { return nil }
        if let host = workspace.hosts.terminals[id]?.host, host != .local, let record = workspace.hosts.records[host] {
            return record.name
        }
        return shell.destination
    }

    // Hooks the files view calls.

    /// The shell printed a prompt: the visible files view refreshes once, and the sidebar reads that space's branch.
    func shellPrompted(_ id: UUID) {
        shellPromptedNow(id)
        SpaceBranchPrompts.shared.prompted(id)
    }
    /// ⌘R: list the root and the expanded folders again now.
    func refresh(_ id: UUID) { refreshNow(id) }
    // openInEditor(_:path:) and changeDirectory(_:to:) live in FilesCoordinator+Editor.swift, paste(_:) in
    // FilesCoordinator+Transfers.swift, the loading in FilesCoordinator+Loading.swift.

    func forget(_ id: UUID) {
        sessions[id] = nil
        FilesOutlineController.forget(id)
        FilesEditorNotices.shared.clear(id)
    }
}
