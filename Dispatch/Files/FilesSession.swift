import Foundation

/// Files-mode state of one terminal tab, keyed by the tab's UUID like `ChatSession`: it follows the tab
/// through moves, splits and host changes and is never written to disk. Every stored property lives
/// here; the list, preview and transfer code add behaviour in extensions.
@MainActor @Observable final class FilesSession: Identifiable {
    let id: UUID

    // Mode. `visible` and `ChatSession.showChat` are exclusive; `FilesCoordinator` keeps them so.
    var visible = false
    /// The tab's content is in a window the user can see (its space selected, the window on screen), kept by
    /// `TerminalContentView` like `ChatSession.isPresented`. Listings refresh only while `visible && presented`.
    var presented = false
    /// The views presenting the tab: a moved tab's new view can appear before the old one disappears.
    @ObservationIgnored private var presenters: Set<UUID> = []
    /// Which files tab the tab last showed (F1a: each tab remembers).
    var tab: FilesTab = .files {
        // A narrow detail belongs to its list: another tab opens on its own list (Review then on its diff, `FilesSplit`).
        didSet { if tab != oldValue { narrowDetail = false } }
    }

    // Root. Nil follows the shell's directory; a crumb or folder click pins it (F2a).
    var pinnedRoot: String?
    var availability: FilesAvailability = .loading
    var home: String?
    var hostLabel: String?

    // List.
    var listings: [String: FileListingState] = [:]
    /// Absolute paths of folders expanded in the outline.
    var expanded: Set<String> = []
    /// Absolute paths of selected rows.
    var selection: Set<String> = []
    /// The row keyboard navigation extends from.
    var anchor: String?
    var filter = ""
    /// Nil follows Settings › Files › Show hidden files; ⇧⌘. sets it for this tab.
    var showHidden: Bool?
    var sort: FilesSort = .name
    var sortDescending = false
    var lastRefresh: Date?
    /// Set while the host is offline: when the listings shown were last live.
    var staleSince: Date?

    // Preview.
    var preview: FilePreviewState? {
        didSet {
            guard oldValue !== preview else { return }
            replacedPreview = oldValue.map(ObjectIdentifier.init)
            if preview == nil || drawnImage?.owner != replacedPreview { drawnImage = nil }
        }
    }
    /// The state `preview` last replaced, which `drawnImage` must have drawn to stand in for the new one.
    @ObservationIgnored private var replacedPreview: ObjectIdentifier?
    /// The picture the image preview last drew. Set by the pane, never observed: only a later selection reads it.
    @ObservationIgnored var drawnImage: FileImageHandoff?
    /// The picture of the image this selection replaced: the next image shows it until its own is decoded, so moving
    /// between two versions of a picture swaps them in one frame instead of blanking between them.
    var imageHandoff: FileImageHandoff? {
        guard let drawnImage, drawnImage.owner == replacedPreview else { return nil }
        return drawnImage
    }
    /// Nil follows Settings › Files › Wrap lines; the preview's wrap button sets it for this tab.
    var previewWrap: Bool?
    /// Nil follows Settings › Files › Render Markdown; the preview's eye button sets it for this tab, for every
    /// Markdown file it shows.
    var previewRendered: Bool?
    /// The sections folded in rendered Markdown (`FileMarkdownDocument.Heading.id`), by the file's path: a file comes
    /// back as it was left while the tab shows others.
    var previewFolds: [String: Set<String>] = [:]
    /// A heading the rendered Markdown is to scroll to (the outline's choice); the view clears it once shown.
    var previewReveal: FileMarkdownReveal?
    /// The preview's width as the divider left it on this tab; nil takes the last width chosen on any tab, else the
    /// default (`FilesCoordinator.previewPreference`, `FilesView.layout`). Kept while the view is too narrow for it,
    /// so the pane comes back at the width the user chose.
    var previewWidth: CGFloat?
    /// The header's views button and ⌥⌘P on this tab: one view at a time (true: the list, a chosen row's detail in its
    /// place) or the list with its detail beside or under it (false). Nil follows the layout (`FilesView.shape`: one at
    /// a time in a space of four panes or more, or where two do not fit the view's size). Either choice holds only where
    /// there is room for two (`canShowBoth`).
    var oneView: Bool?
    /// The view has room for the list and its detail together (`FilesView.fitsBoth`), as `FilesSplit` last laid it
    /// out: the views button shows only then.
    var canShowBoth = true
    /// Both views show one over the other (`FilesSplitShape.stacked`), as `FilesSplit` last laid them out.
    var stackedViews = false
    /// Settings › Features › Files › Disable file previews, inverted: off, the Files tab's preview still shows and
    /// names the selected file, its kind, size and date from the listing, but reads none of it (`FilePreviewLoader`):
    /// no text, image, video or bytes.
    static var previews: Bool { TerminalRuntime.shared.preferences.filesPreviews }
    /// A view too narrow for two columns and too short to stack them has room for one (`splitNarrow`, as `FilesSplit`
    /// last laid it out, `FilesSplitShape.single`): a row chosen there (a git row's click or ⏎, a file's ⏎ or double
    /// click) shows its detail or preview in the list's place, the header's tab name turned into a button back to the
    /// list (or esc). Review opens on its diff there. Kept while the view is wide.
    var narrowDetail = false { didSet { if !narrowDetail { narrowFile = false } } }
    var splitNarrow = false
    /// One column shows a row's detail in the list's place: the header goes back from it and steps through the rows.
    var drilled: Bool { splitNarrow && narrowDetail }
    /// One column, drilled into a commit: the picked file's diff takes the commit's place, all of the pane's height
    /// (`GitCommitDetailPane`); Back and esc return to the commit's files, ↑ ↓ step through them.
    var narrowFile = false
    var drilledFile: Bool { drilled && tab == .commits && narrowFile && commitFile != nil }

    /// Back one level on one column: from a commit's file to the commit, else from a detail to the list.
    func goBack() {
        if drilledFile { narrowFile = false } else { narrowDetail = false }
    }
    /// The pane shows: beside the list, or on one column in its place.
    var paneShown: Bool { splitNarrow ? narrowDetail : true }

    // Transfers under the list (F2b, F2c).
    var transfers: [FileTransfer] = []

    // Git (F3a, F4a). The repository enclosing the root, resolved by the loader; the Review and Commits tabs
    // read everything else from here and the git data layer writes it.
    var git: GitState = .loading {
        // The Review and Commits tabs exist only inside a repository: once the root is known to be outside one, the
        // tab falls back to Files in the same turn, so no frame shows a git tab over a folder that has none.
        didSet { if !canShow(tab) { tab = .files } }
    }
    /// The loader is resolving the repository of a new root while `git` still holds the last answer: the git tabs show
    /// a spinner rather than that repository's status and log as if they were this folder's.
    var gitResolving = false
    var status: GitStatus?
    /// Why the last status read failed (git's words, or the helper's), until one succeeds: Review shows it in place of
    /// its spinner, with Try again.
    var statusError: String?
    /// The `GitChange.id` selected among the uncommitted changes, and its diff.
    var changesSelection: String?
    var changesDiff: GitDiffState?
    /// The Review tab's search: the list shows the changes whose path holds it (any case).
    var changesFilter = ""
    /// The Review tab's comment being written, or the saved one being edited. The comments themselves are the
    /// repository's (`ReviewRepository`, by `reviewScope`); the draft stays with the tab and is never written to disk.
    var reviewDraft: ReviewDraft?
    /// The draft's text: typing updates it without re-rendering the diff.
    @ObservationIgnored var reviewDraftText = ""
    /// New comments not saved that were set aside when a comment was started on another file: Create Review lists
    /// them, to keep or discard; never sent unless kept, never written to disk.
    var reviewSetAside: [ReviewSetAside] = []
    /// A comment the diff is to scroll to; the diff clears it once shown.
    var reviewReveal: ReviewReveal?
    /// The comment ⌥↓ / ⌥↑ last went to, where they go on from.
    @ObservationIgnored var reviewPosition: UUID?
    var diffMode: GitDiffMode = .diff
    /// The diffs' long lines wrap to the pane instead of scrolling sideways (the header's wrap button); nil wraps in a
    /// view narrower than `FilesView.columnsWidth` and scrolls in a wider one (`wraps(compact:)`).
    var diffWrap: Bool?
    var log: GitLog?
    /// Why the last log read failed, until one succeeds: Commits shows it in place of "Loading the log…".
    var logError: String?
    var logScope: GitLogScope = .branch
    /// The branch Commits shows in place of the checked-out one, by its full name (`refs/heads/feature`,
    /// `refs/remotes/origin/main`), read-only: nothing is checked out. Only with the branch scope; nil shows HEAD's.
    var logRef: String?
    /// Commits lists only the commits a tag names.
    var logTagged = false
    /// The repository's branches and tags as the log last read them: the filter menu's choices.
    var gitRefs: [GitRefRecord] = []
    var logFilter = ""
    /// How many commits the Commits tab wants loaded (200 a page): the view raises it near the end of the list,
    /// the git data layer fills `log` up to it.
    var logWanted = GitLoader.page
    /// The Commits filter (`GitLogFilterMenu`): which history shows and whether only tagged commits do. Another choice
    /// starts the log again from one page.
    func showLog(scope: GitLogScope, ref: String? = nil, tagged: Bool? = nil) {
        let ref = scope == .branch ? ref : nil, tagged = tagged ?? logTagged
        guard scope != logScope || ref != logRef || tagged != logTagged else { return }
        logScope = scope
        logRef = ref
        logTagged = tagged
        logWanted = GitLoader.page
    }

    /// The log shows something other than the checked-out branch's whole history.
    var logFiltered: Bool { logScope != .branch || logRef != nil || logTagged }

    /// The hash selected in the Commits list, its detail, the file picked there and that file's diff.
    /// Another commit leaves the file a one-column view had open (`narrowFile`) for that commit's files.
    var selectedCommit: String? { didSet { if selectedCommit != oldValue { narrowFile = false } } }
    var commitDetail: GitCommitDetail?
    /// Why the selected commit's detail did not load; the loader tries again on its tick and on ⌘R.
    var commitDetailError: String?
    var commitFile: String?
    /// The file to pick once the selected commit's files arrive (a review comment on it was asked for), in place of the
    /// first.
    var commitFileRequest: String?
    var commitDiff: GitDiffState?
    /// Bumped by ⏎ or → in a commit's files: the file's diff takes the keyboard (`commitDiffFocusPending` while it is
    /// still to appear).
    var commitDiffFocus: UUID?
    var commitDiffFocusPending = false
    /// Signatures checked so far, by commit hash: the selected signed commit is checked once, and the log's rows keep
    /// what was found.
    var signatureChecks: [String: GitSignatureCheck] = [:]

    /// Bumped when the files view should take keyboard focus.
    var focusRequest: UUID?
    /// Bumped by Edit › Find (⌘F): the filter field takes it, or the preview's find when `previewFocused`.
    var findRequest: UUID?
    var previewFocused = false
    /// A git tab's diff (or its find) has the keyboard: ⌘F finds in the diff rather than filter the list.
    var diffFocused = false

    init(id: UUID) {
        self.id = id
    }

    var followsShell: Bool { pinnedRoot == nil }

    func setPresented(_ shown: Bool, by view: UUID) {
        if shown { presenters.insert(view) } else { presenters.remove(view) }
        if presented != !presenters.isEmpty { presented = !presenters.isEmpty }
    }

    var source: (any FilesSource)? { availability.source }

    /// The host a copy in was just refused on, because its grant has Files without Copy files in: shown over the
    /// list while attempts keep coming (a drag hovering, ⌘V again), then gone (`FilesWriteRefusal`).
    var writeRefusal: String?
    /// Counts refused attempts without re-rendering: the overlay stays while it keeps changing.
    @ObservationIgnored private(set) var writeRefusals = 0

    func refuseWrite(host: String) {
        writeRefusals &+= 1
        if writeRefusal != host { writeRefusal = host }
    }

    /// Rows dragged within their own list without ⌥: shown over the list while the drag stays (`FilesWriteRefusal`),
    /// as Files copies and never moves.
    var moveRefused = false

    func refuseMove() {
        writeRefusals &+= 1
        if !moveRefused { moveRefused = true }
    }

    /// The folder the outline is rooted at: the pin, else the shell's directory, else home.
    func root(tabDirectory: String?) -> String? {
        if let pinnedRoot { return pinnedRoot }
        if let tabDirectory, !tabDirectory.isEmpty { return tabDirectory }
        return home
    }

    /// Whether dot-names show, from the tab's override or the setting.
    func showsHidden(default setting: Bool) -> Bool { showHidden ?? setting }

    /// Files always shows; Review and Commits inside a repository, and while it is still being resolved: the loader
    /// resolves only once files shows, so ⇧⌘U on a tab that never showed files waits for the answer (and falls back
    /// to Files if there is no repository) rather than refusing. Where git cannot run (not installed on the host, left
    /// out of its grant, or refusing the folder, as for dubious ownership) they show too, to say why.
    func canShow(_ tab: FilesTab) -> Bool {
        switch git {
        case .repository, .loading, .unavailable: true
        case .none, .off: tab == .files
        }
    }

    /// Why git cannot run here: nil unless `git` is unavailable.
    var gitUnavailable: String? {
        if case .unavailable(let message) = git { return message }
        return nil
    }

    /// The mode button's menu, ⌃⌘1–3 or ⇧⌘U / ⇧⌘L: the tab shows `tab` if it can, and the new tab's view takes the keyboard
    /// (the one that had it is gone).
    func select(_ tab: FilesTab) {
        guard canShow(tab), tab != self.tab else { return }
        self.tab = tab
        focusRequest = System.uuid()
    }

    /// Commits shows (its log and refs are read).
    var showsLog: Bool { tab == .commits }

    /// Whether the diffs wrap in a view that is `compact` (narrower than `FilesView.columnsWidth`).
    func wraps(compact: Bool) -> Bool { diffWrap ?? compact }

    /// The Review list's changes in its order, as the header's search leaves them.
    var orderedChanges: [GitChange] {
        guard let status else { return [] }
        return GitChangesText.ordered(status.matching(changesFilter))
    }

    /// The header's ↑↓ on one column: the change or commit `delta` rows on from the shown one. False when there is none.
    @discardableResult func step(by delta: Int) -> Bool {
        switch tab {
        case .changes:
            guard let next = GitChangesText.moved(changesSelection, by: delta, in: orderedChanges),
                  next != changesSelection else { return false }
            changesSelection = next
        case .commits where drilledFile:
            let files = (commitDetail?.files ?? []).map(\.path)
            guard let current = commitFile.flatMap({ files.firstIndex(of: $0) }),
                  files.indices.contains(current + delta) else { return false }
            commitFile = files[current + delta]
        case .commits:
            let hashes = (log?.commits ?? []).map(\.hash)
            guard let current = selectedCommit.flatMap({ hash in hashes.firstIndex(of: hash) }),
                  hashes.indices.contains(current + delta) else { return false }
            selectedCommit = hashes[current + delta]
        case .files:
            return false
        }
        return true
    }

    /// Whose comments the Review tab shows: the repository's working tree on this tab's host, a remote host by its
    /// stable identity (`ReviewScope`). Nil until both are known.
    var reviewScope: String? {
        guard let repository = git.repository, let source else { return nil }
        if source.endpoint.isLocal { return ReviewRepository.scope(local: true, host: nil, root: repository.root) }
        guard let host = source.hostIdentity else { return nil }
        return ReviewRepository.scope(local: false, host: host, root: repository.root)
    }

    /// The git tabs can be reached: inside a repository, or while a git tab waits for the repository to resolve
    /// (outside one the tab has already fallen back to Files).
    var showsGitTabs: Bool { git.repository != nil || tab != .files }

    /// The review comments Create review counts: nil while there are none (or no repository).
    var reviewCommentCount: Int? {
        guard let scope = reviewScope else { return nil }
        let count = ReviewRepository.shared.review(scope).comments.count
        return count > 0 ? count : nil
    }

    /// The uncommitted files: nil until the status is loaded inside a repository.
    var changedCount: Int? {
        guard git.repository != nil else { return nil }
        return status?.changedFiles
    }
}

extension GitStatus {
    /// The files the status lists as changed, each once (a file staged and changed again is one file), as Commits'
    /// uncommitted row counts them; ignored entries are not changes.
    var changedFiles: Int { Set(changes.lazy.filter { $0.kind != .ignored }.map(\.path)).count }
}
