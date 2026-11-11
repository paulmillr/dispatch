import Foundation

extension FilesCoordinator {
    /// "cd Here": type `cd 'path'` into the tab's terminal and show it; when the shell is busy nothing is typed and the
    /// files header says so.
    @discardableResult
    func changeDirectory(_ id: UUID, to path: String) -> FilesTerminalCommand.Refusal? {
        FilesTerminalCommand.changeDirectory(path, tab: id, files: self)
    }
}
