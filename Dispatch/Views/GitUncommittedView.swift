import AppKit
import SwiftUI

/// The Commits tab's uncommitted row, selected (F3a's Changes, now part of Commits): the working tree against HEAD,
/// read-only, laid out as a commit's detail. A summary, the changes grouped Staged, Unstaged, Untracked (a click, or ↑↓
/// once ⏎ moved the keyboard here, picks one), and under them the picked change's diff. The git data layer fills
/// `status` and loads `changesDiff` for `changesSelection`; this view only reads them and moves the selection.
struct GitUncommittedDetailPane: View {
    @Bindable var session: FilesSession
    var focus: FocusState<GitCommitsFocus?>.Binding

    var body: some View {
        if let status = session.status, let repository = session.git.repository {
            if status.changes.isEmpty {
                GitCentredNote(text: "No changes · the working tree matches HEAD", identifier: "git-changes-empty")
            } else {
                GitCommitDetailStack {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            GitUncommittedSummary(status: status)
                            GitUncommittedFiles(session: session, status: status, repository: repository, focus: focus)
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    GitUncommittedDiff(session: session, status: status, repository: repository)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("git-changes")
            }
        } else {
            GitDelayedSpinner().accessibilityIdentifier("git-changes-loading")
        }
    }
}

/// "Uncommitted changes" as a commit's subject, then how many files, the totals and what the tab cannot do (or that the
/// helper cut the status short).
private struct GitUncommittedSummary: View {
    let status: GitStatus
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        VStack(alignment: .leading, spacing: 8) {
            Text("Uncommitted changes")
                .font(.system(size: typography.size(offset: 1.5), weight: .semibold))
                .foregroundStyle(palette.ink)
                .accessibilityIdentifier("git-changes-subject")
            HStack(spacing: 10) {
                Text(verbatim: GitCommitsText.files(status.changedFiles)).fixedSize()
                Text("·").foregroundStyle(palette.faint)
                GitCounts(additions: status.additions, deletions: status.deletions, totals: true)
                    .accessibilityIdentifier("git-changes-totals")
                Text("·").foregroundStyle(palette.faint)
                if status.truncated {
                    // The helper cut the status at its bound: the counts are of what arrived.
                    Text(verbatim: GitChangesText.truncated(status))
                        .foregroundStyle(palette.warning)
                        .help("The status was cut at the helper’s bound; the shell has the rest")
                        .accessibilityIdentifier("git-changes-truncated")
                } else {
                    Text("Read-only · stage and commit in the shell").accessibilityIdentifier("git-changes-read-only")
                }
                Spacer(minLength: 0)
            }
            .font(AppFont.ui(size: typography.size(offset: -1)))
            .foregroundStyle(palette.muted)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 12, trailing: 16))
        .overlay(alignment: .bottom) { palette.separator.frame(height: 1) }
    }
}

/// The changes under "STAGED 1", "UNSTAGED 2", "UNTRACKED 1", each group's totals at its right: a click (or ↑↓ once ⏎
/// moved the keyboard here) picks the diff below; ← or esc gives the keyboard back to the log; ⌘C copies the path.
private struct GitUncommittedFiles: View {
    @Bindable var session: FilesSession
    let status: GitStatus
    let repository: GitRepository
    var focus: FocusState<GitCommitsFocus?>.Binding
    @Environment(\.appTypography) private var typography

    var body: some View {
        let ordered = GitChangesText.ordered(status)
        VStack(spacing: 0) {
            ForEach(GitChangeArea.allCases, id: \.self) { area in
                let changes = status.changes(in: area)
                if !changes.isEmpty {
                    group(area, changes)
                    ForEach(changes) { change in
                        // A button, not a tap gesture, as for the log's rows.
                        Button {
                            session.changesSelection = change.id
                            focus.wrappedValue = .files
                        } label: {
                            GitCommitFileRow(file: change, selected: change.id == session.changesSelection,
                                             diff: diff(for: change),
                                             identifier: "git-change-\(change.area.rawValue)-\(change.path)")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.bottom, 6)
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .files)
        .onKeyPress(.upArrow) { move(-1, ordered) }
        .onKeyPress(.downArrow) { move(1, ordered) }
        .onKeyPress(.leftArrow) { leave() }
        .onKeyPress(.escape) { leave() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-changes-list")
    }

    private func group(_ area: GitChangeArea, _ changes: [GitChange]) -> some View {
        let palette = Chrome.palette
        return HStack(spacing: 0) {
            Text(verbatim: GitChangesText.title(area).uppercased()).tracking(0.4)
            Text(verbatim: " \(FilesFormatting.count(changes.count))").foregroundStyle(palette.muted)
            Spacer(minLength: 8)
            GitCounts(additions: changes.reduce(0) { $0 + ($1.additions ?? 0) },
                      deletions: changes.reduce(0) { $0 + ($1.deletions ?? 0) })
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
        }
        .font(AppFont.ui(size: typography.size(offset: -2)))
        .foregroundStyle(palette.detail)
        .padding(.horizontal, 16)
        .frame(height: typography.expanded(28))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-changes-group-\(area.rawValue)")
    }

    /// The loaded diff when it is this change's: it carries a binary's sizes when the status did not.
    private func diff(for change: GitChange) -> GitDiff? {
        guard change.binary, change.id == session.changesSelection, let state = session.changesDiff,
              GitUncommittedDiff.matches(state, change, in: status) else { return nil }
        return state.diff
    }

    /// The keyboard back to the log, and on one column the log back in sight.
    private func leave() -> KeyPress.Result {
        session.narrowDetail = false
        focus.wrappedValue = .list
        return .handled
    }

    private func move(_ delta: Int, _ ordered: [GitChange]) -> KeyPress.Result {
        guard let next = GitChangesText.moved(session.changesSelection, by: delta, in: ordered) else { return .ignored }
        if next != session.changesSelection { session.changesSelection = next }
        return .handled
    }
}

/// The picked change's diff under the changes, as a commit's file diff sits under its files.
private struct GitUncommittedDiff: View {
    @Bindable var session: FilesSession
    let status: GitStatus
    let repository: GitRepository

    var body: some View {
        let palette = Chrome.palette
        VStack(spacing: 0) {
            // The same rule as between a commit's files and its diff.
            palette.controlBorder.frame(height: 1)
            Group {
                if let change = status.changes.first(where: { $0.id == session.changesSelection }) {
                    if let state = session.changesDiff, Self.matches(state, change, in: status) {
                        if let diff = state.diff {
                            GitDiffView(diff: diff, mode: $session.diffMode, wrap: $session.diffWrap, kind: change.kind, label: change.area.rawValue,
                                        source: reader(change))
                                // Each change gets its own folds, scroll and Source read.
                                .id(change.id)
                        } else if let error = state.error {
                            GitCentredNote(text: error, identifier: "git-changes-diff-error")
                        } else {
                            GitDelayedSpinner()
                        }
                    } else {
                        GitDelayedSpinner()
                    }
                } else {
                    GitCentredNote(text: "Select a change to see its diff", identifier: "git-changes-no-selection")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-changes-diff")
    }

    /// Whether `state` is `change`'s diff. The data layer keys it by `GitChange.id`; a key naming another change in
    /// the list is a diff still being replaced, and any other key is matched by path.
    static func matches(_ state: GitDiffState, _ change: GitChange, in status: GitStatus) -> Bool {
        if state.key == change.id { return true }
        if status.changes.contains(where: { $0.id == state.key }) { return false }
        return state.diff.map { $0.path == change.path } ?? state.loading
    }

    /// Source reads the working tree, which is the change's new side for unstaged and untracked files, and for a staged
    /// one only while it has no unstaged change on top; otherwise (and for a deletion) the diff's new side shows.
    private func reader(_ change: GitChange) -> (@Sendable () async throws -> String)? {
        guard let source = session.source, change.kind != .deleted else { return nil }
        if change.area == .staged, status.changes.contains(where: { $0.area == .unstaged && $0.path == change.path }) {
            return nil
        }
        let path = FilesPath.join(repository.root, change.path)
        return { try await GitChangesText.readSource(path, from: source) }
    }
}

extension GitChangesText {
    /// Source shows text up to the preview's 2 MB; past it, or for a file that is not text, it says so.
    static let sourceLimit: UInt64 = 2_000_000

    /// The working-tree file Source shows, read through the tab's source like the preview.
    static func readSource(_ path: String, from source: any FilesSource) async throws -> String {
        do {
            let (data, _) = try await source.read(path, offset: 0, length: sourceLimit + 1, revision: nil)
            if UInt64(data.count) > sourceLimit { throw GitSourceError(message: "Over 2 MB · the terminal shows the rest") }
            if data.contains(0) { throw GitSourceError(message: "Binary file · no source to show") }
            return String(decoding: data, as: UTF8.self)
        } catch let error as FilesSourceError {
            throw GitSourceError(message: error.message)
        }
    }
}

/// Why Source shows no text, in the words the pane shows.
struct GitSourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
