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
        // A narrow detail belongs to its list: another tab opens on its own list.
        didSet { if (tab == .files) != (oldValue == .files) { narrowDetail = false } }
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
    var preview: FilePreviewState?
    /// Nil follows Settings › Files › Wrap lines; the preview's wrap button sets it for this tab.
    var previewWrap: Bool?
    /// The preview's width as the divider left it on this tab; nil takes the last width chosen on any tab, else the
    /// default (`FilesCoordinator.previewPreference`, `FilesView.layout`). Kept while the view is too narrow for it,
    /// so the pane comes back at the width the user chose.
    var previewWidth: CGFloat?
    /// ⌥⌘P or the header's button: the list spans the view and the pane is not mounted, so selections load nothing.
    /// `preview` still follows the selection, so showing the pane again loads what is selected.
    var previewHidden = false
    /// Files shows no preview until one is asked for on this tab: a double click or ⏎ on a file, or ⌥⌘P. The Changes and
    /// Commits tabs' diffs, in the same place, are what those tabs are for and show from the start.
    var previewRequested = false
    /// The pane is off for the tab shown: hidden, or on Files not yet asked for or with previews off in Settings.
    var previewOff: Bool { previewHidden || (tab == .files && (!previewRequested || !Self.previews)) }
    /// Settings › Features › Files › Disable file previews, inverted: off, the Files tab never mounts its preview.
    static var previews: Bool { TerminalRuntime.shared.preferences.filesPreviews }
    /// The tab shown has a pane to show: the git tabs always, Files unless its previews are off.
    var hasPane: Bool { tab != .files || Self.previews }
    /// Under `FilesView.collapseWidth` the split has room for one column (`splitNarrow`, as `FilesSplit` last laid it
    /// out): a row chosen there (a git row's click or ⏎, a file's ⏎ or double click) shows its detail or preview in the
    /// list's place, under a bar back to the list (or esc). Kept while the view is wide.
    var narrowDetail = false
    var splitNarrow = false
    /// The pane shows: beside the list, or on one column in its place.
    var paneShown: Bool { splitNarrow ? narrowDetail : !previewOff }

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
    /// A comment the diff is to scroll to; the diff clears it once shown.
    var reviewReveal: ReviewReveal?
    /// The comment ⌥↓ / ⌥↑ last went to, where they go on from.
    @ObservationIgnored var reviewPosition: UUID?
    var diffMode: GitDiffMode = .diff
    /// The diffs' long lines wrap to the pane instead of scrolling sideways (the header's wrap button).
    var diffWrap = false
    var log: GitLog?
    var logScope: GitLogScope = .branch
    var logFilter = ""
    /// How many commits the Commits tab wants loaded (200 a page): the view raises it near the end of the list,
    /// the git data layer fills `log` up to it.
    var logWanted = GitLoader.page
    /// The hash selected in the Commits list, its detail, the file picked there and that file's diff.
    var selectedCommit: String?
    var commitDetail: GitCommitDetail?
    /// Why the selected commit's detail did not load; the loader tries again on its tick and on ⌘R.
    var commitDetailError: String?
    var commitFile: String?
    var commitDiff: GitDiffState?
    /// Signatures checked so far, by commit hash: the selected signed commit is checked once, and the log's rows keep
    /// what was found.
    var signatureChecks: [String: GitSignatureCheck] = [:]

    /// Bumped when the files view should take keyboard focus.
    var focusRequest: UUID?
    /// Bumped by Edit › Find (⌘F): the filter field takes it, or the preview's find when `previewFocused`.
    var findRequest: UUID?
    var previewFocused = false

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
    /// to Files if there is no repository) rather than refusing.
    func canShow(_ tab: FilesTab) -> Bool {
        switch git {
        case .repository, .loading: true
        case .none, .unavailable, .off: tab == .files
        }
    }

    /// A segment click, ⌃⌘1–3 or ⇧⌘U / ⇧⌘L: the tab shows `tab` if it can, and the new tab's view takes the keyboard
    /// (the one that had it is gone).
    func select(_ tab: FilesTab) {
        guard canShow(tab), tab != self.tab else { return }
        self.tab = tab
        focusRequest = System.uuid()
    }

    /// Commits shows (its log and refs are read).
    var showsLog: Bool { tab == .commits }

    /// Whose comments the Review tab shows: the repository's working tree on this tab's host. Nil until both are known.
    var reviewScope: String? {
        guard let repository = git.repository, let source else { return nil }
        return ReviewRepository.scope(local: source.endpoint.isLocal, host: source.hostLabel, root: repository.root)
    }

    /// The header shows the git segments: inside a repository, or while a git tab waits for the repository to resolve
    /// (outside one the tab has already fallen back to Files).
    var showsGitTabs: Bool { git.repository != nil || tab != .files }

    /// The review comments the Review segment counts: nil while there are none (or no repository).
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
