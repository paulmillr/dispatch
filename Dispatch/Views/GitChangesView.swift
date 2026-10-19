import AppKit
import SwiftUI

/// The Changes tab: the working tree against HEAD, read-only. The changes grouped Staged,
/// Unstaged, Untracked on the left (as the header's search narrows them); the selected change's diff where the Files
/// tab shows its preview (the same divider and ⌥⌘P); the totals in the footer. The git data layer fills `status` and
/// loads `changesDiff` for `changesSelection`; this view only reads them and moves the selection.
struct GitChangesView: View {
    let session: FilesSession
    let focused: Bool
    @Environment(\.appTypography) private var typography
    /// Bumped by ⏎ in the list: the diff takes the keyboard.
    @State private var diffFocus: UUID?
    /// Bumped by esc in the diff: the list takes the keyboard back.
    @State private var listFocus: UUID?

    var body: some View {
        let theme = ChatThemeStore.shared.current
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.terminal)
            .foregroundStyle(Chrome.ink)
            .environment(\.chatTheme, theme)
            .environment(\.appTypography, typography)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("git-changes")
    }

    /// The tab shows only while `canShow` holds: inside a repository, or while one resolves (outside one, or where git
    /// cannot run, the session has already fallen back to Files).
    @ViewBuilder private var content: some View {
        if session.gitResolving {
            // Another folder's repository is being resolved: the last status is not this folder's.
            GitDelayedSpinner().accessibilityIdentifier("git-changes-resolving")
        } else if let repository = session.git.repository {
            if let status = session.status {
                if status.changes.isEmpty {
                    GitCentredNote(text: "No changes · the working tree matches HEAD", identifier: "git-changes-empty")
                } else {
                    FilesSplit(session: session,
                               list: GitChangesList(session: session, status: status,
                                                    shown: status.matching(session.changesFilter), repository: repository,
                                                    focused: focused, focusRequest: listFocus,
                                                    openDiff: { diffFocus = System.uuid() }),
                               detail: GitChangesDetail(session: session, status: status, repository: repository,
                                                        focusRequest: diffFocus,
                                                        leave: { listFocus = System.uuid() }))
                }
            } else {
                GitDelayedSpinner()
            }
        } else {
            GitDelayedSpinner()
        }
    }
}

/// The grouped list and its footer: ↑↓ move the selection, ⏎ gives the diff the keyboard, ⌘C copies the path.
private struct GitChangesList: View {
    let session: FilesSession
    let status: GitStatus
    /// What the header's search leaves of `status`.
    let shown: GitStatus
    let repository: GitRepository
    let focused: Bool
    let focusRequest: UUID?
    let openDiff: () -> Void
    @Environment(\.appTypography) private var typography
    @FocusState private var listFocused: Bool

    var body: some View {
        let ordered = GitChangesText.ordered(shown)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if shown.changes.isEmpty {
                            Text("No changed file matches “\(session.changesFilter)”")
                                .font(AppFont.ui(size: typography.size(offset: -1)))
                                .foregroundStyle(Chrome.palette.detail)
                                .padding(.leading, FilesColumns.leading).padding(.top, 14)
                                .accessibilityIdentifier("git-changes-no-match")
                        }
                        ForEach(GitChangeArea.allCases, id: \.self) { area in
                            let changes = shown.changes(in: area)
                            if !changes.isEmpty {
                                group(area, count: changes.count)
                                ForEach(changes) { change in
                                    // A button, not a tap gesture: in the focusable scroll view a tap gesture never
                                    // saw the click (measured in the test VM, macOS 26).
                                    Button {
                                        session.changesSelection = change.id
                                        listFocused = true
                                    } label: {
                                        GitChangeRow(change: change, repository: repository,
                                                     selected: change.id == session.changesSelection,
                                                     diff: diff(for: change))
                                    }
                                    .buttonStyle(.plain)
                                    .id(change.id)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.upArrow) { move(-1, ordered) }
                .onKeyPress(.downArrow) { move(1, ordered) }
                .onKeyPress(.return) {
                    guard session.changesSelection != nil else { return .ignored }
                    openDiff()
                    return .handled
                }
                .onChange(of: session.changesSelection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            .frame(maxHeight: .infinity)
            GitChangesFooter(session: session, status: status, repository: repository)
        }
        // ⌘C while the list has the keyboard: the selected change's repository-relative path.
        .gitCopyShortcut(active: listFocused) {
            status.changes.first { $0.id == session.changesSelection }?.path
        }
        .onAppear { if focused { listFocused = true } }
        .onChange(of: focused ? session.focusRequest : nil) { _, request in if request != nil { listFocused = true } }
        .onChange(of: focusRequest) { listFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-changes-list")
    }

    private func group(_ area: GitChangeArea, count: Int) -> some View {
        HStack {
            Text(GitChangesText.title(area)).fontWeight(.semibold).foregroundStyle(Chrome.palette.ink)
            Spacer(minLength: 8)
            Text(verbatim: FilesFormatting.count(count)).foregroundStyle(Chrome.palette.detail)
        }
        .font(AppFont.ui(size: typography.size(offset: -1.5)))
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(26))
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-changes-group-\(area.rawValue)")
    }

    /// The loaded diff when it is this change's: it carries a binary's sizes when the status did not.
    private func diff(for change: GitChange) -> GitDiff? {
        guard change.binary, change.id == session.changesSelection, let state = session.changesDiff,
              GitChangesDetail.matches(state, change, in: status) else { return nil }
        return state.diff
    }

    private func move(_ delta: Int, _ ordered: [GitChange]) -> KeyPress.Result {
        guard let next = GitChangesText.moved(session.changesSelection, by: delta, in: ordered) else { return .ignored }
        if next != session.changesSelection { session.changesSelection = next }
        return .handled
    }

}

/// One change (`.cr`): the badge, the name over its folder, and its `+/−` or a binary's sizes.
private struct GitChangeRow: View {
    let change: GitChange
    let repository: GitRepository
    let selected: Bool
    let diff: GitDiff?
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 10) {
            GitChangeBadge(kind: change.kind).frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: change.name)
                    .font(AppFont.ui(size: typography.size()))
                    .foregroundStyle(palette.ink)
                Text(verbatim: folder)
                    .font(AppFont.ui(size: typography.size(offset: -2)))
                    .foregroundStyle(palette.detail)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            GitCounts(additions: change.additions, deletions: change.deletions,
                      binary: change.binary ? GitChangesText.binary(old: change.oldSize ?? diff?.oldSize,
                                                                    new: change.newSize ?? diff?.newSize, kind: change.kind)
                          : nil)
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
        }
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(38))
        .background(selected ? palette.ink.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .help(change.path)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-change-\(change.area.rawValue)-\(change.path)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The folder line: the repository's own name for a file at its top, "old → new" for a rename or copy.
    private var folder: String {
        let folder = GitChangesText.folder(change)
        return folder.isEmpty ? FilesPath.name(repository.root) : folder
    }
}

/// The line under the list (`.lfoot`): what the tab cannot do (or that the helper cut the status short), the totals, and
/// the terminal for doing it.
private struct GitChangesFooter: View {
    let session: FilesSession
    let status: GitStatus
    let repository: GitRepository
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        let notice = FilesEditorNotices.shared.notice(for: session.id)
        HStack(spacing: 8) {
            if let notice {
                Text(verbatim: notice).foregroundStyle(palette.warning).accessibilityIdentifier("git-changes-notice")
            } else if status.truncated {
                // The helper cut the status at its bound: the counts are of what arrived.
                Text(verbatim: GitChangesText.truncated(status))
                    .foregroundStyle(palette.warning)
                    .help("The status was cut at the helper’s bound; the shell has the rest")
                    .accessibilityIdentifier("git-changes-truncated")
            } else {
                Text("Read-only · stage and commit in the shell")
            }
            Spacer(minLength: 8)
            GitCounts(additions: status.additions, deletions: status.deletions, totals: true)
                .layoutPriority(1)
                .accessibilityIdentifier("git-changes-totals")
            Button {
                FilesEditor.runGit("add -p", repository: repository.root, tab: session.id, files: TerminalRuntime.shared.files)
            } label: {
                Text("git add -p ›").foregroundStyle(palette.accent).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Typed into the tab's own shell, so it stages on that shell's host; refused (with the notice) while a
            // program runs there.
            .help("Switch to the terminal and type git add -p")
            .accessibilityIdentifier("git-add-patch")
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
        .accessibilityIdentifier("git-changes-footer")
    }
}

/// The selected change's diff where the Files tab has its preview.
private struct GitChangesDetail: View {
    let session: FilesSession
    let status: GitStatus
    let repository: GitRepository
    let focusRequest: UUID?
    let leave: () -> Void

    var body: some View {
        @Bindable var session = session
        let theme = ChatThemeStore.shared.current
        Group {
            if let change = status.changes.first(where: { $0.id == session.changesSelection }) {
                if let state = session.changesDiff, Self.matches(state, change, in: status) {
                    if let diff = state.diff {
                        GitDiffView(diff: diff, mode: $session.diffMode, kind: change.kind, label: change.area.rawValue,
                                    source: reader(change), focusRequest: focusRequest, onEscape: leave)
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
        .background(theme.terminal)
        .foregroundStyle(theme.ink)
        .environment(\.chatTheme, theme)
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
