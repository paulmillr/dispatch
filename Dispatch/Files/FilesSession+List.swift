import Foundation

/// One line of the outline (F2a): an entry, or what stands in for a folder's entries while they load, when it is
/// empty, when listing it failed, or after the 10,000-entry bound.
struct FilesRow: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case entry, loading, empty, error, truncated
    }

    /// The entry's absolute path; a placeholder's folder with a suffix no path can contain.
    let id: String
    /// The folder the row lists in: the root for the first level.
    let parent: String
    let depth: Int
    let kind: Kind
    let entry: FileEntry?
    /// The entry's name, or the placeholder's text.
    let title: String
    let modified: String
    let size: String
    /// A folder whose rows show below it.
    var expanded = false

    var isEntry: Bool { kind == .entry }
    var isDirectory: Bool { entry?.isDirectory == true }

    static func placeholderID(_ kind: Kind, in folder: String) -> String { "\(folder)\u{0}\(kind)" }
}

/// What Return, ⌘↓ or a double click does to a row.
enum FilesOpenAction: Hashable, Sendable {
    /// A folder becomes the root.
    case pin(String)
    /// A file shows in the preview.
    case preview(String)
}

/// Turns a session's listings into outline rows. A level's sorted rows are kept until its listing, sort or hidden
/// choice changes: the loading code replaces listings every 2 s, and re-sorting 10,000 names on each would stall
/// typing in the filter.
@MainActor final class FilesRowBuilder {
    struct Result: Equatable {
        var rows: [FilesRow] = []
        /// Every row's id, for counting the selection's rows that show.
        var ids: Set<String> = []
        /// Entries on the root level: the footer's "16 items".
        var itemCount = 0
        /// Why the root's last refresh failed while its earlier rows still show; nil when they are live. Folders below
        /// say it in a row of their own.
        var rootError: String?
    }

    fileprivate struct Order: Equatable {
        let listing: FileListing
        let sort: FilesSort
        let descending: Bool
        let hidden: Bool
    }

    private struct Level {
        var order: Order
        var sorted: [FileEntry]
        var reference: Date
        var depth: Int
        var rows: [FilesRow]
    }

    private var levels: [String: Level] = [:]

    /// `now`: the minute the list shows (`minute(_:)`), so ages move on while an unchanged folder keeps its listing;
    /// nil measures from when each listing was taken.
    func rows(for session: FilesSession, root: String, hidden: Bool, now: Date? = nil) -> Result {
        let root = FilesPath.normalized(root)
        let query = session.filter.trimmingCharacters(in: .whitespacesAndNewlines)
        var fallback: Date?
        // Ages are relative to the later of when each listing was taken and the shown minute: the loader keeps an
        // unchanged folder's listing (and its time), so the minute is what moves them on. Within a minute the
        // reference holds still, so a render reuses the level's rows; only a listing without a time reads the clock.
        func reference(_ state: FileListingState) -> Date {
            let taken: Date
            if let date = state.loadedAt ?? session.lastRefresh {
                taken = date
            } else if let fallback {
                taken = fallback
            } else {
                taken = System.date()
                fallback = taken
            }
            return now.map { max($0, taken) } ?? taken
        }
        var seen: Set<String> = []
        func level(_ folder: String, depth: Int) -> [FilesRow] {
            seen.insert(folder)
            func placeholder(_ kind: FilesRow.Kind, _ title: String) -> [FilesRow] {
                // The root level's states are the view's to show (centred, not as a row).
                guard depth > 0, query.isEmpty else { return [] }
                return [FilesRow(id: FilesRow.placeholderID(kind, in: folder), parent: folder, depth: depth, kind: kind,
                                 entry: nil, title: title, modified: "", size: "")]
            }
            guard let state = session.listings[folder] else { return placeholder(.loading, "…") }
            guard let listing = state.listing else {
                if let error = state.error { return placeholder(.error, error.message) }
                return placeholder(.loading, "…")
            }
            let base = entries(folder, listing: listing, reference: reference(state), session: session, hidden: hidden,
                               depth: depth)
            var out: [FilesRow] = []
            out.reserveCapacity(base.count)
            for var row in base {
                row.expanded = row.isDirectory && session.expanded.contains(row.id)
                let below = row.expanded ? level(row.id, depth: depth + 1) : []
                if !query.isEmpty, !Self.matches(row.title, query), !below.contains(where: \.isEntry) { continue }
                out.append(row)
                out.append(contentsOf: below)
            }
            if query.isEmpty {
                if base.isEmpty { out += placeholder(.empty, "Empty folder") }
                if listing.truncated {
                    out.append(FilesRow(id: FilesRow.placeholderID(.truncated, in: folder), parent: folder, depth: depth,
                                        kind: .truncated, entry: nil, title: "showing the first 10,000", modified: "",
                                        size: ""))
                }
                // A refresh that failed after a good listing: the rows stay, the reason shows under them.
                if let error = state.error, depth > 0 {
                    out.append(FilesRow(id: FilesRow.placeholderID(.error, in: folder), parent: folder, depth: depth,
                                        kind: .error, entry: nil, title: error.message, modified: "", size: ""))
                }
            }
            return out
        }
        var result = Result()
        result.rows = level(root, depth: 0)
        result.ids = Set(result.rows.map(\.id))
        result.itemCount = result.rows.reduce(0) { $0 + ($1.depth == 0 && $1.isEntry ? 1 : 0) }
        if let state = session.listings[root], state.listing != nil { result.rootError = state.error?.message }
        // Folders that are no longer shown give their sorted rows back.
        if levels.count > seen.count { levels = levels.filter { seen.contains($0.key) } }
        return result
    }

    private func entries(_ folder: String, listing: FileListing, reference: Date, session: FilesSession, hidden: Bool,
                         depth: Int) -> [FilesRow] {
        let order = Order(listing: listing, sort: session.sort, descending: session.sortDescending, hidden: hidden)
        var level = levels[folder]
        if level?.order != order {
            let shown = hidden ? listing.entries : listing.entries.filter { !$0.isHidden }
            let sorted = level.flatMap { previous in
                previous.order.sort == order.sort && previous.order.descending == order.descending
                    && previous.order.hidden == order.hidden ? Self.merged(shown, into: previous.sorted, order: order) : nil
            } ?? Self.sorted(shown, by: order.sort, descending: order.descending)
            level = Level(order: order, sorted: sorted, reference: reference, depth: depth, rows: [])
        } else if level?.reference == reference, level?.depth == depth, let rows = level?.rows {
            return rows
        }
        // Each refresh moves the reference time; only the texts are made again, the order stays.
        guard var level else { return [] }
        level.reference = reference
        level.depth = depth
        level.rows = level.sorted.map { entry in
            FilesRow(id: FilesPath.join(folder, entry.name), parent: folder, depth: depth, kind: .entry, entry: entry,
                     title: entry.name, modified: FilesFormatting.age(entry.modified, at: reference),
                     size: FilesFormatting.size(of: entry))
        }
        levels[folder] = level
        return level.rows
    }

    /// `date` down to its minute: the list's ages move on once a minute, and every render within it shares one
    /// reference (so the sorted levels' texts are made once a minute, not on each render).
    nonisolated static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// Folders first in either direction, as Finder keeps them; ties fall back to the name, ascending.
    nonisolated static func sorted(_ entries: [FileEntry], by sort: FilesSort, descending: Bool) -> [FileEntry] {
        entries.sorted { precedes($0, $1, by: sort, descending: descending) }
    }

    nonisolated static func precedes(_ a: FileEntry, _ b: FileEntry, by sort: FilesSort, descending: Bool) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let order: ComparisonResult
        switch sort {
        case .name: order = compareNames(a.name, b.name)
        case .modified: order = compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .size: order = compare(a.size, b.size)
        }
        if order == .orderedSame { return compareNames(a.name, b.name) == .orderedAscending }
        return descending ? order == .orderedDescending : order == .orderedAscending
    }

    /// A refreshed listing in the previous order: entries that did not change keep their places and the few that did
    /// are placed by binary search, instead of sorting 10,000 names again because one file grew. Nil when much
    /// changed, for a full sort.
    nonisolated private static func merged(_ entries: [FileEntry], into previous: [FileEntry], order: Order) -> [FileEntry]? {
        let current = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = previous.filter { current[$0.name] == $0 }
        let keptNames = Set(kept.map(\.name))
        let added = entries.filter { !keptNames.contains($0.name) }
        guard added.count <= 64 else { return nil }
        for entry in added {
            var low = 0, high = kept.count
            while low < high {
                let middle = (low + high) / 2
                if precedes(kept[middle], entry, by: order.sort, descending: order.descending) { low = middle + 1 } else { high = middle }
            }
            kept.insert(entry, at: low)
        }
        return kept
    }

    /// Finder's order: case-insensitive, numbers by value ("file2" before "file10"); names equal that way fall back
    /// to their bytes so the order is total.
    nonisolated static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        let order = a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: nil)
        if order != .orderedSame || a == b { return order }
        return Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) ? .orderedAscending : .orderedDescending
    }

    nonisolated private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    /// The filter: a case-insensitive substring of the name.
    nonisolated static func matches(_ name: String, _ query: String) -> Bool {
        query.isEmpty || name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }
}

// The list's behaviour on the session: what the outline, header and footer read and the keys they map to it.
extension FilesSession {
    /// The outline's rows under `root`: listings flattened through the expanded folders, filtered (a match keeps
    /// its folders) and sorted. `settingHidden` is Settings › Files › Show hidden files.
    func rows(root: String, settingHidden: Bool) -> [FilesRow] {
        FilesRowBuilder().rows(for: self, root: root, hidden: showsHidden(default: settingHidden)).rows
    }

    func crumbs(root: String) -> [FilesCrumb] { FilesPath.crumbs(root: root, home: home) }

    func openAction(for row: FilesRow) -> FilesOpenAction? {
        guard row.isEntry else { return nil }
        return row.isDirectory ? .pin(row.id) : .preview(row.id)
    }

    /// Return, ⌘↓ and a double click: a folder becomes the root, a file shows in the preview.
    func open(_ row: FilesRow) {
        switch openAction(for: row) {
        case .pin(let path): pin(path)
        case .preview(let path):
            showPreview(path, entry: row.entry)
            // Asking for a file's preview is asking to see it: a hidden pane comes back, on one column in the list's
            // place.
            setPreviewHidden(false)
            if splitNarrow { narrowDetail = true }
        case nil: break
        }
    }

    /// ⌥⌘P and the header's button: on one column, the detail in the list's place instead.
    func togglePreview() {
        if splitNarrow {
            narrowDetail.toggle()
            if narrowDetail { setPreviewHidden(false) }
        } else {
            setPreviewHidden(!previewOff)
        }
    }

    /// Hiding keeps `previewWidth` for when the pane returns. A preview that had the keyboard is unmounted with it, so
    /// the list takes the keyboard rather than leaving the window with no responder. Showing it counts as asking for it.
    func setPreviewHidden(_ hidden: Bool) {
        if !hidden, !previewRequested { previewRequested = true }
        guard hidden != previewHidden else { return }
        previewHidden = hidden
        if hidden, previewFocused {
            previewFocused = false
            focusRequest = System.uuid()
        }
    }

    /// A crumb or a folder: the view stops following the shell and shows `path`. `selecting` keeps a row selected in
    /// it (the folder ⌘↑ came from).
    func pin(_ path: String, selecting: String? = nil) {
        pinnedRoot = FilesPath.normalized(path)
        filter = ""
        let selected: Set<String> = selecting.map { [$0] } ?? []
        if selection != selected { selection = selected }
        anchor = selecting
        if preview?.path != selecting { preview = nil }
    }

    /// ↩: back to following the shell's directory.
    func followShell() {
        guard pinnedRoot != nil else { return }
        pinnedRoot = nil
        filter = ""
    }

    /// ⌘↑: the folder enclosing the root, with the root selected in it. False at "/".
    @discardableResult
    func showEnclosingFolder(of root: String) -> Bool {
        let root = FilesPath.normalized(root)
        guard let parent = FilesPath.parent(root) else { return false }
        pin(parent, selecting: root)
        return true
    }

    func showPreview(_ path: String, entry: FileEntry?) {
        if preview?.path != path { preview = FilePreviewState(path: path, entry: entry) }
    }

    /// The outline's selection changed under the user's hand. One entry previews; none clears the preview; several
    /// keep what shows.
    func selectionChanged(to rows: [FilesRow], anchor anchorRow: FilesRow?) {
        let entries = rows.filter(\.isEntry)
        let paths = Set(entries.map(\.id))
        if selection != paths { selection = paths }
        let anchorPath = anchorRow.flatMap { $0.isEntry ? $0.id : nil } ?? entries.last?.id
        if anchor != anchorPath { anchor = anchorPath }
        if entries.count == 1, let row = entries.first {
            showPreview(row.id, entry: row.entry)
        } else if entries.isEmpty, preview != nil {
            preview = nil
        }
    }

    /// The rows the outline selects for `selection`: paths that show, wherever a refresh moved them.
    func selectionIndexes(in rows: [FilesRow]) -> IndexSet {
        guard !selection.isEmpty else { return [] }
        return IndexSet(rows.indices.filter { rows[$0].isEntry && selection.contains(rows[$0].id) })
    }

    /// ⌥⌘C and ⌘C: the selected rows' paths in row order, one per line. A selected path that does not show (filtered
    /// out, in a closed folder) is not copied: the footer does not count it either.
    func pathsText(in rows: [FilesRow]) -> String {
        rows.lazy.filter { $0.isEntry && self.selection.contains($0.id) }.map(\.id).joined(separator: "\n")
    }

    /// ⇧⌘.: this tab's choice overrides the setting.
    func toggleHidden(settingHidden: Bool) {
        showHidden = !showsHidden(default: settingHidden)
    }

    /// Choosing the sort key again flips the direction; a new key starts where Finder does: names A to Z, dates and
    /// sizes newest and largest first.
    func chooseSort(_ key: FilesSort) {
        if sort == key {
            sortDescending.toggle()
        } else {
            sort = key
            sortDescending = key != .name
        }
    }
}
