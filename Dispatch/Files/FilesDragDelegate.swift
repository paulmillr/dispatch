import AppKit

/// The outline's drag-and-drop hooks. The outline (list UI) calls these from its `NSOutlineView`
/// data source; the transfer code implements them. Nil, or `dragEnabled` false (Settings › Files ›
/// Drag and drop off), removes both the drag sources and the drop targets.
@MainActor protocol FilesDragDelegate: AnyObject {
    var dragEnabled: Bool { get }
    /// Pasteboard types the outline registers for drops.
    var acceptedTypes: [NSPasteboard.PasteboardType] { get }
    /// A writer for rows being dragged out (file promises, plus the paths as text); nil refuses the drag.
    func pasteboardWriter(for paths: [String], in session: FilesSession) -> NSPasteboardWriting?
    /// The operation for a drop onto `directory` (the row's folder, or the root for empty space).
    func validateDrop(_ info: NSDraggingInfo, onto directory: String, in session: FilesSession) -> NSDragOperation
    func acceptDrop(_ info: NSDraggingInfo, onto directory: String, in session: FilesSession) -> Bool
    /// The drag of `paths` ended; rows stop being highlighted.
    func dragEnded(paths: [String], operation: NSDragOperation, in session: FilesSession)
}
