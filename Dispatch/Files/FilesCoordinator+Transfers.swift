import AppKit

extension FilesCoordinator {
    /// ⌘V: copies the Finder files on the general pasteboard into the folder the tab shows, refused like a drop
    /// when a file would land where it is or a folder inside itself (`copyIn`). Works with drag and drop off too:
    /// the setting removes drop targets and drag sources, not the Edit menu.
    func paste(_ id: UUID) {
        guard let session = existing(id),
              let directory = session.root(tabDirectory: TerminalRuntime.shared.workspace?.liveTab(id)?.directory) else { return }
        FilesDragController.shared.copyIn(dropped: FilesDragController.droppedFiles(.general), into: directory, in: session)
    }
}

extension TerminalRuntime {
    /// The one drag controller every files view's outline talks to.
    func installFileTransfers() {
        if files.dragDelegate == nil { files.dragDelegate = FilesDragController.shared }
    }
}

extension FilesCoordinator {
    /// Copy (⌘C): the rows' files on the general pasteboard, remote ones once fetched (`FilesDragController.copyToClipboard`).
    func copyFiles(_ id: UUID, paths: [String]) {
        guard let session = existing(id) else { return }
        FilesDragController.shared.copyToClipboard(paths, in: session)
    }

    /// Download…: one row to a name and folder from a save panel (Downloads first), several into a folder from an
    /// open panel, each under its own name or Finder's "name 2" beside one already there. As a sheet on `window`.
    func download(_ id: UUID, paths: [String], window: NSWindow?) {
        guard let session = existing(id), session.source != nil, !paths.isEmpty else { return }
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let folders = paths.map { session.isDirectory($0) }
        let start = Self.downloadFolder ?? System.home.appendingPathComponent("Downloads")
        let finish: @MainActor ([URL]) -> Void = { [weak session] destinations in
            guard let session, let folder = destinations.first?.deletingLastPathComponent() else { return }
            Self.downloadFolder = folder
            FilesDragController.shared.download(paths, to: destinations, in: session) { error in
                if let error { Self.present(error, title: "The download could not be saved", window: window) }
            }
        }
        if paths.count == 1 {
            let panel = NSSavePanel()
            panel.title = "Download"
            panel.prompt = "Download"
            panel.nameFieldStringValue = names[0]
            panel.directoryURL = start
            panel.canCreateDirectories = true
            panel.message = session.hostLabel.map { "\(names[0]) from \($0)" } ?? names[0]
            Self.run(panel, window: window) { if let url = panel.url { finish([url]) } }
        } else {
            let panel = NSOpenPanel()
            panel.title = "Download"
            panel.prompt = "Download"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = start
            panel.message = "Download \(paths.count) items" + (session.hostLabel.map { " from \($0)" } ?? "") + " into:"
            Self.run(panel, window: window) {
                guard let folder = panel.url else { return }
                finish(FilesDragController.destinations(for: names, folders: folders, in: folder, exists: System.exists))
            }
        }
    }

    /// Copy scp Command: for a remote tab's rows, the command that fetches them here; nil on this Mac or when the
    /// tab's ssh destination is unknown.
    func scpCommand(_ id: UUID, paths: [String]) -> String? {
        guard let session = existing(id), session.source?.endpoint.isLocal == false,
              let destination = Self.sshDestination(for: id) else { return nil }
        return FilesScpCommand.make(destination: destination, paths: paths, folders: paths.contains { session.isDirectory($0) })
    }

    func copyScpCommand(_ id: UUID, paths: [String]) {
        guard let command = scpCommand(id, paths: paths) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// What the tab's ssh connection was started with: its helper link's destination (a host's spaces), else the
    /// plain SSH tab's own.
    static func sshDestination(for id: UUID) -> String? {
        let runtime = TerminalRuntime.shared
        guard let workspace = runtime.workspace, let tab = workspace.liveTab(id) else { return nil }
        let space = workspace.spaces.first { $0.tabs.contains { $0.id == id } }
        if let link = (space?.remote ?? runtime.ssh.connectionForOrigin(id)).flatMap({ runtime.ssh.links[$0] }) {
            return link.launch.shell.destination
        }
        if case .ssh(let shell) = runtime.machine(for: tab) { return shell.destination }
        return nil
    }

    /// The folder the last download went to, where the next panel opens.
    @MainActor private static var downloadFolder: URL?

    private static func run(_ panel: NSSavePanel, window: NSWindow?, chosen: @escaping @MainActor () -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in if response == .OK { MainActor.assumeIsolated { chosen() } } }
        } else if panel.runModal() == .OK {
            chosen()
        }
    }

    private static func present(_ error: any Error, title: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

extension FilesSession {
    /// Whether `path` is a folder, as its parent's listing says (false when not listed).
    func isDirectory(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        return listings[parent]?.entries.first { $0.name == name }?.isDirectory == true
    }
}
