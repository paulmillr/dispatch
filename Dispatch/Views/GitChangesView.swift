import AppKit
import SwiftUI

/// The Review tab: the working tree against HEAD, read-only, where every line takes a comment for an agent. The changes
/// grouped Staged, Unstaged, Untracked on the left (as the header's search narrows them, each with its comment count);
/// the selected change's diff with its comments where the Files tab shows its preview (the same divider and ⌥⌘P); over
/// the list one line of how many files and their totals; Create review in the header (`ReviewHeaderButton`). The git data layer fills `status` and loads `changesDiff` for
/// `changesSelection`; this view only reads them and moves the selection. The comments are `ReviewRepository`'s.
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
                    // Comments written before the changes were committed can still go out: the header keeps Create review.
                    GitCentredNote(text: "No changes · the working tree matches HEAD", identifier: "git-changes-empty")
                } else {
                    FilesSplit(session: session,
                               list: GitChangesList(session: session, status: status,
                                                    shown: status.matching(session.changesFilter), repository: repository,
                                                    focused: focused, focusRequest: listFocus,
                                                    openDiff: { diffFocus = System.uuid() }),
                               detail: GitChangesDetail(session: session, status: status, repository: repository,
                                                        focusRequest: diffFocus,
                                                        leave: {
                                                            session.narrowDetail = false
                                                            listFocus = System.uuid()
                                                        }),
                               back: "Review")
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
    /// One column: a chosen change's diff takes the list's place (`FilesSplit`).
    @Environment(\.filesSplitNarrow) private var narrow
    @FocusState private var listFocused: Bool

    var body: some View {
        let ordered = GitChangesText.ordered(shown)
        let comments = session.reviewScope.map { ReviewRepository.shared.review($0).comments } ?? []
        // One group needs no name: the summary line says it all.
        let grouped = GitChangeArea.allCases.filter { !shown.changes(in: $0).isEmpty }.count > 1
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !shown.changes.isEmpty { summary }
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
                                if grouped { group(area, count: changes.count) }
                                ForEach(changes) { change in
                                    // A button, not a tap gesture: in the focusable scroll view a tap gesture never
                                    // saw the click (measured in the test VM, macOS 26).
                                    Button {
                                        session.changesSelection = change.id
                                        listFocused = true
                                        if narrow { session.narrowDetail = true }
                                    } label: {
                                        GitChangeRow(change: change,
                                                     selected: change.id == session.changesSelection,
                                                     diff: diff(for: change),
                                                     comments: comments.lazy.filter { $0.path == change.path }.count)
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
                // ⌥↑↓: the previous or next review comment, on whichever file it is.
                .onKeyPress(.upArrow) { NSEvent.modifierFlags.contains(.option) ? comment(-1) : move(-1, ordered) }
                .onKeyPress(.downArrow) { NSEvent.modifierFlags.contains(.option) ? comment(1) : move(1, ordered) }
                .onKeyPress(.return) {
                    guard session.changesSelection != nil else { return .ignored }
                    if narrow { session.narrowDetail = true }
                    openDiff()
                    return .handled
                }
                .onChange(of: session.changesSelection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
            }
            .frame(maxHeight: .infinity)
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

    /// "18 files · +1,754 −61" over the list (what the search leaves), and that the helper cut the status short.
    private var summary: some View {
        let palette = Chrome.palette
        return HStack(spacing: 8) {
            Text(verbatim: GitCommitsText.files(shown.changedFiles)).foregroundStyle(palette.detail)
            GitCounts(additions: shown.additions, deletions: shown.deletions, totals: true)
                .accessibilityIdentifier("git-changes-totals")
            if status.truncated {
                // The helper cut the status at its bound: the counts are of what arrived.
                Text(verbatim: GitChangesText.truncated(status))
                    .foregroundStyle(palette.warning)
                    .help("The status was cut at the helper’s bound; the shell has the rest")
                    .accessibilityIdentifier("git-changes-truncated")
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .font(AppFont.ui(size: typography.size(offset: -1.5)))
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(28))
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-changes-summary")
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

    private func comment(_ delta: Int) -> KeyPress.Result {
        guard GitDiffReview.step(session, status: status, by: delta) else { return .ignored }
        if narrow { session.narrowDetail = true }
        return .handled
    }
}

/// One change on one line: its status letter, the name with its folder dimmed after it, its review comments, and its
/// `+/−` or a binary's sizes.
private struct GitChangeRow: View {
    let change: GitChange
    let selected: Bool
    let diff: GitDiff?
    let comments: Int
    @Environment(\.appTypography) private var typography

    var body: some View {
        let palette = Chrome.palette
        HStack(spacing: 8) {
            GitChangeBadge(kind: change.kind, side: 14, plain: true)
            HStack(spacing: 8) {
                Text(verbatim: change.name)
                    .font(AppFont.ui(size: typography.size()))
                    .foregroundStyle(palette.ink)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                // The folder gives way first, keeping its end: the folder the file is in.
                Text(verbatim: GitChangesText.folder(change))
                    .font(AppFont.ui(size: typography.size(offset: -1.5)))
                    .foregroundStyle(palette.detail)
                    .truncationMode(.head)
            }
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if comments > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "text.bubble.fill").font(.system(size: 9))
                    Text(verbatim: FilesFormatting.count(comments))
                }
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
                .foregroundStyle(ChatThemeStore.shared.current.blue)
                .help(ReviewText.count(comments))
                .accessibilityLabel(ReviewText.count(comments))
                .accessibilityIdentifier("git-change-comments")
            }
            GitCounts(additions: change.additions, deletions: change.deletions,
                      binary: change.binary ? GitChangesText.binary(old: change.oldSize ?? diff?.oldSize,
                                                                    new: change.newSize ?? diff?.newSize, kind: change.kind)
                          : nil)
                .font(AppFont.ui(size: typography.size(offset: -1.5)))
        }
        .padding(.leading, FilesColumns.leading)
        .padding(.trailing, FilesColumns.trailing)
        .frame(height: typography.expanded(28))
        .background(selected ? palette.ink.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .help(change.path)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("git-change-\(change.area.rawValue)-\(change.path)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                        GitDiffView(diff: diff, mode: $session.diffMode, wrap: $session.diffWrap, kind: change.kind,
                                    source: reader(change), focusRequest: focusRequest, onEscape: leave,
                                    review: session.reviewScope.map {
                                        GitDiffReview(session: session, scope: $0, path: change.path, area: change.area,
                                                      status: status)
                                    })
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
