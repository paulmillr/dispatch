import SwiftUI

/// The 24 pt line under the list (`.lfoot`): how many items the shown folder holds and how many rows are selected, and
/// at the right why git has nothing to show ("not a repository", why git cannot run; F2a, F2e). The Changes and
/// Commits tabs have footers of their own.
struct FilesFooter: View {
    let session: FilesSession
    /// Entries on the root level, after the hidden-files choice and the filter.
    let itemCount: Int
    /// The rows that show: a selected path filtered away or in a closed folder is not counted.
    let shown: Set<String>
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        let selected = session.selection.reduce(0) { $0 + (shown.contains($1) ? 1 : 0) }
        HStack(spacing: 0) {
            Text(Self.summary(items: itemCount, selected: selected))
                .accessibilityIdentifier("files-footer-summary")
            Spacer(minLength: 12)
            if let git = Self.gitSummary(session.git) {
                Text(verbatim: git)
                    .truncationMode(.middle)
                    .help(git)
                    .accessibilityIdentifier("files-footer-git")
            }
        }
        .lineLimit(1)
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(24))
        .font(AppFont.ui(size: typography.size(offset: -2)))
        .foregroundStyle(palette.detail)
        .background(Chrome.window)
        .overlay(alignment: .top) { palette.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("files-footer")
    }

    /// "not a repository" outside one, and where git cannot run why ("git is not installed on this host"; the Changes
    /// and Commits segments do not show there, so this is the one place that says it). Nothing inside a repository: the
    /// header's branch and the Changes count say it there.
    static func gitSummary(_ git: GitState) -> String? {
        switch git {
        case .none: "not a repository"
        case .unavailable(let message): message
        case .loading, .off, .repository: nil
        }
    }

    /// "16 items · 1 selected", "1 item", "5,120 items": grouped as the preview groups, whatever the locale.
    static func summary(items: Int, selected: Int) -> String {
        let count = "\(FilesFormatting.count(items)) \(items == 1 ? "item" : "items")"
        return selected > 0 ? "\(count) · \(FilesFormatting.count(selected)) selected" : count
    }
}
