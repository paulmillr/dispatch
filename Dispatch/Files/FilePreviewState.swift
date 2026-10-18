import Foundation

/// What the right pane shows for the selected row. The preview loader fills
/// `kind`; nothing is loaded until a row is selected.
@MainActor @Observable final class FilePreviewState: Identifiable {
    enum Kind {
        case loading
        /// UTF-8 text up to 2 MB; `language` is a `SyntaxHighlight` language name.
        case text(String, language: String)
        /// Markdown source; the pane offers a rendered view.
        case markdown(String)
        /// The file's bytes, decoded by the pane at the size it draws; `pixelSize` is read from the header.
        case image(Data, pixelSize: CGSize)
        /// A folder; the summary arrives after the bounded walk (nil while it runs).
        case folder(FolderSummary?)
        /// Binary content: `head` is the first bytes, for the "Show first 64 KB" offer.
        case binary(size: UInt64, head: Data?)
        /// Text over 2 MB: `head` holds the first 64 KB once requested.
        case tooLarge(size: UInt64, head: String?)
        case error(String)
    }

    let path: String
    let entry: FileEntry?
    var kind: Kind = .loading
    /// The revision the content was read at; a changed file reloads instead of showing a mix.
    var revision: FileRevision?

    init(path: String, entry: FileEntry?) {
        self.path = path
        self.entry = entry
    }

    nonisolated var id: String { path }
    var name: String { FilesPath.name(path) }

    /// There is text to find in: ⌘F opens the preview's find only then, and the list's filter takes it otherwise.
    var findable: Bool {
        switch kind {
        case .text, .markdown: true
        case .tooLarge(_, let head): head != nil
        case .binary(_, let head): head != nil
        default: false
        }
    }
}
