import SwiftUI

/// "◆ fixtures/ already has 12 of these" with Replace / Keep both / Skip them / Cancel: asked before anything is
/// written, as the second form of a transfer row (F2b).
struct FileConflictPrompt: View {
    let transfer: FileTransfer
    let text: FileTransferText

    private var palette: SidebarPalette { Chrome.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("◆").foregroundStyle(palette.warning)
                Text(text.title).foregroundStyle(palette.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                choice("Replace", .replace, id: "replace", help: "Replace · the copies take the existing names")
                choice("Keep both", .keepBoth, id: "keep-both", help: "Keep both · the copies get “name 2”")
                choice("Skip them", .skip, id: "skip", help: "Skip them · copy only the other items")
                Spacer(minLength: 0)
                choice("Cancel", .cancel, id: "conflict-cancel", help: "Cancel · copy nothing", quiet: true)
            }
        }
        .font(ChatThemeStore.shared.current.typography.font(offset: -1))
        .padding(.vertical, 8)
        .padding(.leading, 14)
        .padding(.trailing, 12)
    }

    private func choice(_ title: String, _ resolution: FileTransfer.ConflictResolution, id: String, help: String,
                        quiet: Bool = false) -> some View {
        Button(title) { transfer.resolveConflict?(resolution) }
            .buttonStyle(FileTransferButtonStyle(quiet: quiet))
            .disabled(transfer.resolveConflict == nil)
            .help(help)
            .accessibilityIdentifier("file-transfer-\(id)")
    }
}
