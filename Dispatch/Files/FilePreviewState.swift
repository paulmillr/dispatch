import CoreGraphics
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
        /// Binary content, shown as hex (`FileHexDocument` reads the rest a page at a time): `head` is the start of the
        /// file the loader already read (at least its first window, or the whole file), `format` what the bytes say it
        /// is (`FileFormat`).
        case binary(size: UInt64, head: Data, format: String?)
        /// Text over 2 MB: `head` holds the first 64 KB once requested.
        case tooLarge(size: UInt64, head: String?)
        case error(String)
    }

    let path: String
    let entry: FileEntry?
    var kind: Kind = .loading
    /// The revision the content was read at; a changed file reloads instead of showing a mix.
    var revision: FileRevision?
    /// Text read in another encoding than UTF-8 ("UTF-16", "Latin-1"), named in the header; nil for UTF-8.
    var encoding: String?
    /// A folder whose size is counted only on request (`FilesSession.countNeedsConsent`): the walk would raise a macOS
    /// consent prompt, so the preview offers Count size instead.
    var countOnRequest = false
    /// A read of the file as it changed on disk is under way (`FilePreviewLoader.refresh`).
    @ObservationIgnored var refreshing = false
    /// Where each of its views was scrolled (`FilePreviewScrollKeeper.Key`): the file comes back where it was left when
    /// its view goes and returns (the split showing another tab, the pane hiding), while it stays selected.
    @ObservationIgnored var scroll: [FilePreviewScrollKeeper.Key: CGPoint] = [:]

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
        default: false
        }
    }
}
