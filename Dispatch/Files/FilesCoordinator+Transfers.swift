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
