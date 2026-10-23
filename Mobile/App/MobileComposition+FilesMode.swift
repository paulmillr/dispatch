import SwiftUI

extension MobileComposition {
    /// The Files segment's Files mode (`FilesModeSlot`, docs/ios.md Files): H1's listing in the tab's folder with its
    /// breadcrumb row, and the screens it pushes (F2's preview, a folder's listing), which Review and Commits push too
    /// (`FilesRoute.preview`). Each tab keeps its listing (`filesBrowsers`) while it lives; everything is read through
    /// the host's connected helper while its Files & git switch is on.
    func installFilesMode(_ slot: inout FilesModeSlot) {
        let browsers = filesBrowsers, hosts = hosts, tabs = tabs, conversations = conversations
        #if DEBUG
        let sample = !feedsTabs
        #else
        let sample = false
        #endif
        browsers.source = { [weak hosts] id in
            #if DEBUG
            if sample { return FilesSample.shared }
            #endif
            guard let session = hosts?.session(id), session.host.files, !session.plainSSH, session.link.isConnected,
                  let client = session.client else { return nil }
            return HelperMobileFilesSource(client: client, host: session.host.name)
        }
        browsers.alive = { [weak tabs] in Set(tabs?.workspaces.flatMap { $0.tabs.map(\.ref) } ?? []) }
        slot.body = { context in
            // The tab's agent working (read here, so the segment redraws when its turn ends).
            let working = context.tab.agentPane.map { pane in
                conversations.sessions[ChatConversationKey(host: context.tab.ref.host, node: pane.key)]?.turnRunning ?? false
            } ?? false
            return AnyView(FilesModeBody(context: context, browser: browsers.browser(context.tab.ref, host: context.host.name),
                                         working: working))
        }
        slot.bar = { context in
            AnyView(FilesListingBar(browser: browsers.browser(context.tab.ref, host: context.host.name),
                                    fallback: FilesBrowser.crumbs(folder: context.directory, repository: context.git?.root,
                                                                  home: context.host.home)))
        }
        slot.destination = { [weak self] tab, route in
            self?.filesDestination(tab, route) ?? AnyView(FilesModePlaceholder(mode: .files))
        }
    }

    /// F2 for a file, a folder's listing for a folder (`detail` "directory", or a path that turns out to be one). A
    /// relative path is the repository's (Review's and Commits' changes).
    private func filesDestination(_ ref: TabRef, _ route: FilesRoute) -> AnyView {
        guard let raw = route.path, let workspace = tabs.workspace(ref.host) else { return AnyView(FilesModePlaceholder(mode: .files)) }
        let host = workspace.host
        let root = gitFacts.facts(SpaceGitFacts.Key(host: ref.host, key: ref.key))?.root
        let path = raw.hasPrefix("/") ? FilesPath.normalized(raw) : FilesPath.join(root ?? host.home ?? "/", raw)
        let browsers = filesBrowsers, navigator = navigator
        let back = filesBackTitle(ref, route)
        let pop = { if !navigator.path.isEmpty { navigator.path.removeLast() } }
        let push = { (path: String, directory: Bool) in navigator.path.append(.files(ref, .preview(path, directory: directory))) }
        let folder = {
            AnyView(FilesFolderScreen(browser: FilesBrowser(tab: ref, host: host.name, preferences: browsers.preferences) {
                browsers.source(ref.host)
            }, path: path, repository: root, host: host, back: back, pop: pop, preview: push))
        }
        if route.detail == FilesRoute.directory { return folder() }
        let tab = tabs.tab(ref)
        let actions = FilesPreviewActions(agent: tab.flatMap(filesAgentName), ask: tab.flatMap(filesAsk),
                                          openInTerminal: tab.flatMap { filesOpenInTerminal($0, folder: FilesPath.parent(path) ?? "/") },
                                          back: back, pop: pop)
        let preview = FilePreview(path: path, host: host.name) { browsers.source(ref.host) }
        return AnyView(FilePreviewScreen(preview: preview, host: host,
                                         root: browsers.browser(ref, host: host.name).root ?? root,
                                         actions: actions, folder: folder))
    }

    /// The pushed screen's back pill: the Files mode the tab shows, or the folder or mode pushed before it.
    func filesBackTitle(_ ref: TabRef, _ route: FilesRoute) -> String {
        let path = navigator.path
        guard let index = path.lastIndex(of: .files(ref, route)), index > 0 else { return "Files" }
        switch path[index - 1] {
        case .tab(let tab): return (tabs.filesModes[tab] ?? .files).title
        case .files(_, let previous):
            guard previous.mode == .files else { return previous.mode.title }
            return previous.path.map(FilesPath.name) ?? "Files"
        default: return "Back"
        }
    }

    /// "claude", "codex", "pi": the tab's agent as its conversation names it, else as the tab's program does.
    private func filesAgentName(_ tab: MobileTab) -> String? {
        guard let pane = tab.agentPane else { return nil }
        let key = ChatConversationKey(host: tab.ref.host, node: pane.key)
        return FilesAsk.agentName(key: conversations.sessions[key]?.agentKey, program: tab.program,
                                  executable: pane.agent?.executable)
    }

    /// Ask: back to the tab on its Chat segment, the file on its way into the composer as an attachment (read through
    /// `files.read`, stored with `attachments.put` as any attachment) once the conversation takes one.
    private func filesAsk(_ tab: MobileTab) -> ((FilePreview) -> Void)? {
        guard let pane = tab.agentPane else { return nil }
        let ref = tab.ref, navigator = navigator, conversations = conversations
        return { preview in
            let session = conversations.session(for: ChatConversationKey(host: ref.host, node: pane.key))
            FilesAsk.ask(preview, session: session, tab: ref, navigator: navigator)
        }
    }

    /// Open in Terminal: the tab's shell changes to the file's folder and the tab shows Terminal. Offered only for a
    /// folder whose name has no control characters, while the tab's program is a shell and the host is connected; checked
    /// again when tapped (the pane's program by its window, a full-screen program on the emulator's screen), else "The
    /// terminal is busy". The line is cleared (^U) and the `cd` sent as a bracketed paste when the shell asked for it,
    /// then Return (`FilesAsk.typing`). Returns why it did nothing, nil when it typed.
    private func filesOpenInTerminal(_ tab: MobileTab, folder: String) -> (() -> String?)? {
        guard FilesAsk.typable(folder), tab.atShell, hosts.session(tab.ref.host)?.client != nil else { return nil }
        let ref = tab.ref, navigator = navigator, tabs = tabs, hosts = hosts, presences = presences
        return {
            guard let tab = tabs.tab(ref), let pane = tab.activePane, let client = hosts.session(ref.host)?.client else {
                return "The tab is not connected."
            }
            let state = presences.presence(.init(host: ref.host, node: pane.key))?.filesTypingState
            guard FilesAsk.ready(program: tab.program, agent: pane.agent != nil, alternate: state?.alternate ?? false),
                  let bytes = FilesAsk.typing(folder, bracketed: state?.bracketed ?? false) else {
                return "The terminal is busy."
            }
            Task { try? await client.input(HelperClient.Output(terminal: pane.id, bytes: bytes)) }
            TabSegment.requestSwitch(ref, to: .terminal)
            FilesAsk.popToTab(ref, navigator: navigator)
            return nil
        }
    }
}

extension FilesRoute {
    /// `detail` of a folder's route.
    static let directory = "directory"

    /// A file's preview (F2), or a folder's listing: Files pushes it from a row, Review and Commits for a changed path
    /// (absolute, or relative to the repository's root).
    static func preview(_ path: String, directory: Bool = false) -> FilesRoute {
        FilesRoute(mode: .files, path: path, detail: directory ? Self.directory : nil)
    }
}

extension TabSegment {
    /// Shows `segment` in `tab` (Files' Ask and Open in Terminal), through the tab screen's switch request.
    @MainActor static func requestSwitch(_ tab: TabRef, to segment: TabSegment) {
        NotificationCenter.default.post(name: switchRequested, object: nil, userInfo: ["tab": tab, "segment": segment.rawValue])
    }

    /// The segment a switch request names; nil toggles Terminal and Chat.
    static func switchTarget(_ note: Notification) -> TabSegment? {
        (note.userInfo?["segment"] as? String).flatMap(TabSegment.init(rawValue:))
    }

    /// Shows Files on `mode` in `tab` (the View menu's Review Changes, Commits, Switch Terminal / Files).
    @MainActor static func requestSwitch(_ tab: TabRef, to mode: FilesMode) {
        NotificationCenter.default.post(name: switchRequested, object: nil,
                                        userInfo: ["tab": tab, "segment": TabSegment.files.rawValue, "mode": mode.rawValue])
    }

    /// The Files mode a switch request names, with the Files segment.
    static func switchMode(_ note: Notification) -> FilesMode? {
        (note.userInfo?["mode"] as? String).flatMap(FilesMode.init(rawValue:))
    }
}

/// Files' ways into the tab's other segments.
@MainActor
enum FilesAsk {
    /// Ask: the tab shows Chat, the Files screens over it go, and the file follows into the composer.
    static func ask(_ preview: FilePreview, session: MobileChatSession, tab: TabRef, navigator: SpacesNavigator) {
        let kind: ChatAttachment.Kind = if case .image = preview.content { .image } else { .file }
        let source = MobileAttachmentSource(name: preview.name, kind: kind) {
            try await preview.bytes(limit: UInt64(MobileAttachmentSource.readLimit))
        }
        TabSegment.requestSwitch(tab, to: .chat)
        popToTab(tab, navigator: navigator)
        attach(source, to: session)
    }

    /// Attaches `source` to the conversation's composer once it takes attachments (it opens when first asked for, and
    /// verifies within a moment); one that does not within `attempts` × `pause` says so in the composer's strip.
    static func attach(_ source: MobileAttachmentSource, to session: MobileChatSession, attempts: Int = 150,
                       pause: Duration = .milliseconds(100)) {
        Task { @MainActor in
            for _ in 0..<attempts {
                if session.canAttach {
                    session.attach([source])
                    return
                }
                try? await Task.sleep(for: pause)
            }
            session.attachmentError = notReady(source.name)
        }
    }

    static func notReady(_ name: String) -> String { "Couldn’t attach \(name): the conversation isn’t ready." }

    /// The stack back to the tab: the Files screens pushed over it go.
    static func popToTab(_ ref: TabRef, navigator: SpacesNavigator) {
        var path = navigator.path
        while case .files(let tab, _)? = path.last, tab == ref { path.removeLast() }
        if path != navigator.path { navigator.path = path }
    }

    /// The agent's name for "Ask claude": the conversation's agent key, else the tab's program unless it is a shell,
    /// else the agent's executable's name.
    static func agentName(key: String?, program: String?, executable: String?) -> String {
        if let key, !key.isEmpty { return key }
        if let program, !program.isEmpty, !MobileTab.isShell(program) { return program }
        if let executable, let name = executable.split(separator: "/").last, !name.isEmpty { return String(name) }
        return "agent"
    }

    /// A folder Open in Terminal may type: no C0 or C1 control character, DEL or line break, which a shell's line editor
    /// would act on (^C, Return, an escape sequence) instead of reading as the name.
    static func typable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
            || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    /// Whether the pane can be typed into: its program (the window's, as tmux names it after the foreground program) is
    /// a shell, no agent is bound there, and no full-screen program holds the emulator's screen.
    static func ready(program: String?, agent: Bool, alternate: Bool) -> Bool {
        !agent && !alternate && program.map(MobileTab.isShell) == true
    }

    /// What Open in Terminal sends: ^U (the shell's line cleared), `cd '<folder>'` (single-quoted for sh, bash, zsh and
    /// fish; a bracketed paste when the shell asked for one, so its editor takes it as text) and Return. Nil for a
    /// folder that is not `typable`.
    static func typing(_ folder: String, bracketed: Bool) -> Data? {
        guard typable(folder) else { return nil }
        let line = Array(("cd '" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'").utf8)
        var bytes: [UInt8] = [0x15]
        bytes += bracketed ? Array("\u{1B}[200~".utf8) + line + Array("\u{1B}[201~".utf8) : line
        bytes.append(0x0D)
        return Data(bytes)
    }
}

/// Files mode's body: the listing of the tab's folder (`FilesBrowser.follow` on the tab's folder, the repository's root
/// and the home folder as they change); a file pushes F2.
private struct FilesModeBody: View {
    let context: FilesModeContext
    let browser: FilesBrowser
    /// The tab's agent is in a turn: when it ends, the folder and git's letters are read again.
    var working = false

    private struct Followed: Equatable {
        let directory: String?
        let repository: String?
        let home: String?
    }

    private var followed: Followed { Followed(directory: context.directory, repository: context.git?.root, home: context.host.home) }

    var body: some View {
        Group {
            if context.directory?.hasPrefix("/") == true {
                FilesListingView(browser: browser, tint: context.host.tint, offline: context.availability.isOffline) { path, _ in
                    context.push(.preview(path))
                }
            } else {
                FilesStateView(symbol: "folder", title: "No folder yet", message: "The tab has not said which folder it is in.")
            }
        }
        .onAppear {
            follow()
            #if DEBUG
            FilesDebug.apply(browser: browser, push: context.push)
            #endif
        }
        .onChange(of: followed) { follow() }
        .onChange(of: working) { old, new in
            if old, !new { Task { await browser.refresh() } }
        }
        // The connection back: a listing first asked offline, and git's letters, are read now.
        .onChange(of: context.availability) { old, new in
            if old != .available, new == .available { Task { await browser.reconnected() } }
        }
    }

    private func follow() {
        browser.follow(directory: context.directory, repository: context.git?.root, home: context.host.home)
    }
}

#if DEBUG
/// `-DispatchFilesFolder src` opens the listing in that folder below the tab's; `-DispatchFilesPreview src/theme.ts`
/// pushes that file (the fidelity screens H1, F2). Once per launch.
@MainActor
enum FilesDebug {
    private static var applied = false

    static func apply(browser: FilesBrowser, push: (FilesRoute) -> Void) {
        guard !applied, let folder = browser.folder else { return }
        applied = true
        let defaults = UserDefaults.standard
        if let below = defaults.string(forKey: "DispatchFilesFolder") { browser.open(FilesPath.join(folder, below)) }
        if let file = defaults.string(forKey: "DispatchFilesPreview") { push(.preview(FilesPath.join(folder, file))) }
    }
}
#endif

/// A folder pushed over the tab (a route to a folder: Review's, a deep link's, a path that turned out to be one): its
/// breadcrumb row and listing, the back pill naming the screen before it.
struct FilesFolderScreen: View {
    @State private var browser: FilesBrowser
    let path: String
    let repository: String?
    let host: TabsHost
    let back: String
    let pop: () -> Void
    let preview: (String, Bool) -> Void
    @Environment(\.tabsColumnWidth) private var column

    init(browser: FilesBrowser, path: String, repository: String?, host: TabsHost, back: String, pop: @escaping () -> Void,
         preview: @escaping (String, Bool) -> Void) {
        _browser = State(initialValue: browser)
        self.path = path
        self.repository = repository
        self.host = host
        self.back = back
        self.pop = pop
        self.preview = preview
    }

    var body: some View {
        FilesListingView(browser: browser, tint: host.tint) { path, _ in preview(path, false) }
            // Once: the browser keeps its folder (follow does nothing for the same one).
            .onAppear { browser.follow(directory: path, repository: repository, home: host.home) }
            .safeAreaBar(edge: .top, spacing: 0) {
                FilesListingBar(browser: browser)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
            .tabsPushedScreen()
            .toolbar {
                TabsScreenHeader(title: browser.folder.map(FilesPath.name) ?? "Folder", column: column) {
                    TabsBackPill(label: back, action: pop)
                } subtitle: {
                    TabsHostPath(host: host, path: host.abbreviate(browser.folder))
                } trailing: {
                    EmptyView()
                }
            }
    }
}
