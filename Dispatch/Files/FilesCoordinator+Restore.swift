import Foundation
import Observation

/// What a closed tab showed (files, and in files its tab, root, selection and Commits' commit; chat or the terminal),
/// kept from its close until a tab with the same id comes back: Restore of a detached tab or space gives the restored
/// tab its view again. `TerminalRuntime.close` keeps it before the sessions go; the helper's restore gives it back
/// (`restoreViews`) once the tabs are in the layout, before they draw. In memory only, like `FilesSession` and
/// `ChatSession`.
struct RetainedTabView {
    var mode: TabMode
    /// The user left chat on purpose (`ChatSession.manualViewChoice`): discovery must not bring it back.
    var manualViewChoice: Bool
    var files: Files?

    struct Files {
        var tab: FilesTab
        var pinnedRoot: String?
        var expanded: Set<String>
        var selection: Set<String>
        var anchor: String?
        var filter: String
        var showHidden: Bool?
        var sort: FilesSort
        var sortDescending: Bool
        var previewHidden: Bool
        var previewRequested: Bool
        var previewWidth: CGFloat?
        var changesSelection: String?
        var changesFilter: String
        var diffMode: GitDiffMode
        var diffWrap: Bool
        var logScope: GitLogScope
        var logFilter: String
        var selectedCommit: String?
        var commitFile: String?

        @MainActor init(_ session: FilesSession) {
            tab = session.tab; pinnedRoot = session.pinnedRoot; expanded = session.expanded; selection = session.selection
            anchor = session.anchor; filter = session.filter; showHidden = session.showHidden; sort = session.sort
            sortDescending = session.sortDescending; previewHidden = session.previewHidden
            previewRequested = session.previewRequested; previewWidth = session.previewWidth
            changesSelection = session.changesSelection; changesFilter = session.changesFilter; diffMode = session.diffMode
            diffWrap = session.diffWrap; logScope = session.logScope; logFilter = session.logFilter
            selectedCommit = session.selectedCommit; commitFile = session.commitFile
        }

        @MainActor func apply(to session: FilesSession) {
            session.tab = tab; session.pinnedRoot = pinnedRoot; session.expanded = expanded; session.selection = selection
            session.anchor = anchor; session.filter = filter; session.showHidden = showHidden; session.sort = sort
            session.sortDescending = sortDescending; session.previewHidden = previewHidden
            session.previewRequested = previewRequested; session.previewWidth = previewWidth
            session.changesSelection = changesSelection; session.changesFilter = changesFilter; session.diffMode = diffMode
            session.diffWrap = diffWrap; session.logScope = logScope; session.logFilter = logFilter
            session.selectedCommit = selectedCommit; session.commitFile = commitFile
        }
    }

    /// How many closed tabs keep their view: a terminated tab never comes back, so the oldest go.
    static let limit = 64
}

extension FilesCoordinator {
    /// A tab is closing (detached or ended): its view is kept for a Restore that brings the same tab back.
    func retainView(_ id: UUID) {
        let files = existing(id), chat = chatSession(id)
        guard files != nil || chat != nil else { return }
        // A manual choice of chat itself is no reason to keep discovery away: only leaving it for the terminal is.
        let mode = mode(for: id)
        let view = RetainedTabView(mode: mode, manualViewChoice: chat?.manualViewChoice == true && mode == .terminal,
                                   files: files.map(RetainedTabView.Files.init))
        retainedViews[id] = view
        retainedOrder.removeAll { $0 == id }
        retainedOrder.append(id)
        while retainedOrder.count > RetainedTabView.limit { retainedViews[retainedOrder.removeFirst()] = nil }
    }

    /// A restore put tabs back in the layout (`present`): those that closed with a view get it again.
    func restoreViews(present: Set<UUID>) {
        for id in retainedOrder where present.contains(id) { restoreView(id) }
    }

    /// The restored tab `id` is back: it shows what it showed when it closed. Files comes back on its tab with its root,
    /// selection and Commits' commit; if that view cannot open any more (files unavailable, the pinned folder or the
    /// commit gone, no repository for a git tab) the tab falls back to its terminal. Chat comes back by itself when its
    /// agent is found, unless the user had left it.
    func restoreView(_ id: UUID) {
        guard let saved = retainedViews.removeValue(forKey: id) else { return }
        retainedOrder.removeAll { $0 == id }
        if saved.manualViewChoice || saved.mode == .files, let chat = chatSession(id, create: true) {
            chat.manualViewChoice = true
        }
        guard let state = saved.files else { return }
        let session = session(for: id)
        state.apply(to: session)
        guard saved.mode == .files else { return }
        guard canShowFiles(id) else { return fallBack(id, session) }
        switchMode(id, to: .files, reason: "restore")
        verifyRestored(id, session: session, state: state)
    }

    /// Follows the restored view until it has loaded (or failed): the source, a pinned root's listing, the repository
    /// for a git tab and the selected commit's detail.
    private func verifyRestored(_ id: UUID, session: FilesSession, state: RetainedTabView.Files) {
        let outcome = withObservationTracking {
            Self.restoreOutcome(session, state: state)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.sessions[id] === session, session.visible else { return }
                self.verifyRestored(id, session: session, state: state)
            }
        }
        if outcome == .failed { fallBack(id, session) }
    }

    enum RestoreOutcome { case loading, shown, failed }

    static func restoreOutcome(_ session: FilesSession, state: RetainedTabView.Files) -> RestoreOutcome {
        switch session.availability {
        case .loading: return .loading
        case .plainSSH, .notGranted, .offline, .unavailable: return .failed
        case .available: break
        }
        if let root = state.pinnedRoot {
            guard let listing = session.listings[root] else { return .loading }
            if listing.error != nil { return .failed }
            if listing.listing == nil { return .loading }
        }
        if state.tab != .files {
            switch session.git {
            case .loading: return .loading
            case .none, .unavailable, .off: return .failed
            case .repository: break
            }
            if session.gitResolving { return .loading }
        }
        if state.tab == .commits, state.selectedCommit != nil {
            if session.commitDetailError != nil { return .failed }
            if session.commitDetail == nil { return .loading }
        }
        return .shown
    }

    /// The restored view does not open: the tab is its plain terminal, without the selection that failed.
    private func fallBack(_ id: UUID, _ session: FilesSession) {
        print("Files restore: tab=\(id) falls back to the terminal (\(session.availability), git=\(session.git))")
        session.selectedCommit = nil; session.commitFile = nil; session.commitDetailError = nil
        session.pinnedRoot = nil
        if session.tab != .files { session.tab = .files }
        switchMode(id, to: .terminal, reason: "restore")
    }

    private func chatSession(_ id: UUID, create: Bool = false) -> ChatSession? {
        guard let chat else { return nil }
        return create ? chat.session(for: id) : chat.sessions[id]
    }
}
