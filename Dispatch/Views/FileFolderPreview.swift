import SwiftUI

/// A folder's summary (F2d): its items, size, when it changed and its path, with Open folder (pins it as the
/// root), cd here and Copy path. The counts arrive from the bounded walk; until then the rows say so.
struct FileFolderPreview: View {
    @Environment(\.chatTheme) private var theme
    let path: String
    let entry: FileEntry?
    let summary: FolderSummary?
    let openFolder: () -> Void
    let changeDirectory: () -> Void
    let copyPath: () -> Void
    /// ⌥⌘C copies the path while the preview has focus, as the file header's button does.
    var focused = false

    /// "5,120 files · 24 folders"; a walk stopped by its bound reads "at least".
    static func items(_ summary: FolderSummary) -> String {
        let files = FilesFormatting.count(summary.files)
        let folders = FilesFormatting.count(summary.folders)
        let text = "\(files) \(summary.files == 1 ? "file" : "files") · \(folders) \(summary.folders == 1 ? "folder" : "folders")"
        return summary.truncated ? "at least " + text : text
    }

    static func size(_ summary: FolderSummary) -> String {
        (summary.truncated ? "at least " : "") + FilesFormatting.preciseSize(summary.bytes) + " on disk"
    }

    var body: some View {
        VStack(spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    label("items")
                    if let summary { Text(Self.items(summary)).accessibilityIdentifier("file-preview-folder-items") }
                    else { HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("counting…").foregroundStyle(theme.muted) } }
                }
                GridRow {
                    label("size")
                    Text(summary.map(Self.size) ?? "—").foregroundStyle(summary == nil ? theme.muted : theme.ink)
                }
                if let modified = entry?.modified {
                    GridRow {
                        label("modified")
                        Text(FilesFormatting.timestamp(modified, now: System.date()))
                    }
                }
                GridRow {
                    label("path")
                    Text(verbatim: path).foregroundStyle(theme.ink.opacity(0.7))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("file-preview-folder-path")
                }
            }
            .font(theme.typography.font(offset: -0.5))
            .foregroundStyle(theme.ink)
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 8) {
                Button("Open folder", action: openFolder)
                    .buttonStyle(FilePreviewButtonStyle())
                    .help("Show this folder in the list")
                    .accessibilityIdentifier("file-preview-open-folder")
                Button("cd here", action: changeDirectory)
                    .buttonStyle(FilePreviewButtonStyle())
                    .help("Types cd \(FilesPath.name(path)) into the terminal")
                    .accessibilityIdentifier("file-preview-cd")
                Spacer(minLength: 8)
                Button("Copy path", action: copyPath)
                    .buttonStyle(FilePreviewButtonStyle(prominent: false))
                    .keyboardShortcut(focused ? KeyboardShortcut("c", modifiers: [.command, .option]) : nil)
                    .help("Copy path · ⌥⌘C")
                    .accessibilityIdentifier("file-preview-folder-copy-path")
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
        }
        // A container: an identifier on a plain stack would replace its buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-preview-folder")
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(theme.muted).gridColumnAlignment(.leading)
    }
}
