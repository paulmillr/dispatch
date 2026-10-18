import SwiftUI

/// "main · 1 staged · 2 unstaged · 1 untracked · ~/src/api", and the totals "+26 −5" at the right (F3a). It fills the
/// width it is given and draws no bar of its own: `FilesHeader`'s 34 pt row carries it after the segments.
struct GitChangesHeaderLine: View {
    let session: FilesSession
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        let status = session.status
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if let status {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: typography.size(offset: -2.5)))
                        Text(verbatim: GitChangesText.branch(status))
                    }
                    .foregroundStyle(palette.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("git-changes-branch")
                    ForEach(GitChangeArea.allCases, id: \.self) { area in
                        dot
                        let count = status.changes(in: area).count
                        Text(verbatim: GitChangesText.count(status, area))
                            .foregroundStyle(count == 0 ? palette.detail : area == .unstaged ? palette.sidebarHostLabel
                                             : palette.green)
                            .accessibilityIdentifier("git-changes-count-\(area.rawValue)")
                    }
                    dot
                    if status.truncated {
                        // The helper cut the status at its bound: the counts are of what arrived.
                        Text(verbatim: GitChangesText.truncated(status))
                            .foregroundStyle(palette.warning)
                            .help("The status was cut at the helper’s bound; the shell has the rest")
                            .accessibilityIdentifier("git-changes-truncated")
                        dot
                    }
                }
                if let root = session.git.repository?.root {
                    Text(verbatim: GitChangesText.repositoryPath(root, home: session.home ?? session.source?.home,
                                                                 host: session.hostLabel))
                        .foregroundStyle(palette.detail)
                        .truncationMode(.head)
                        .help(root)
                        .accessibilityIdentifier("git-changes-repository")
                }
            }
            .font(AppFont.ui(size: typography.size(offset: -0.5)))
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            if let status {
                GitCounts(additions: status.additions, deletions: status.deletions, totals: true)
                    .font(AppFont.ui(size: typography.size(offset: -1)))
                    .accessibilityIdentifier("git-changes-totals")
            }
        }
        .foregroundStyle(palette.muted)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-changes-header-line")
    }

    private var dot: some View { Text("·").foregroundStyle(Chrome.palette.faint) }
}
