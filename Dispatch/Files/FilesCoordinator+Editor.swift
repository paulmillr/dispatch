import Foundation

extension FilesCoordinator {
    /// ⌘O: type `${EDITOR:-vi} 'path'` into the tab's terminal and show it; when the shell is busy nothing is
    /// typed and the preview header says so.
    @discardableResult
    func openInEditor(_ id: UUID, path: String) -> FilesEditor.Refusal? {
        FilesEditor.run(.edit, path: path, tab: id, files: self)
    }

    /// "cd here": type `cd 'path'` into the tab's terminal and show it, under the same rule.
    @discardableResult
    func changeDirectory(_ id: UUID, to path: String) -> FilesEditor.Refusal? {
        FilesEditor.run(.changeDirectory, path: path, tab: id, files: self)
    }
}
