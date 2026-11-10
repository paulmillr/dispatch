import Foundation

struct TerminalTab: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var customTitle: String?
    var directory: String
    var launchCommand: String?
    var isConnecting = false
    var terminal: UInt64?
    var machine: TerminalMachine = .local
    /// The agent the helper found running here (its topology binding), named by `agent(named:)`: what a launcher-named
    /// tab shows until Chat binds the agent and gives its own key. Saved, so a relaunch shows it while the host is
    /// still disconnected; the next topology sets it again.
    var agent: String?
    /// Its terminal no longer exists on its server (closed there while the app was away): the tab stays, read-only,
    /// with what it showed, until closed. It has no terminal, and in a multiplexer's space a window of its own with no
    /// server node (`ContainerTab.gone`): its old ids could name other nodes now, so nothing of it reaches the server.
    var gone: Bool?
    var isGone: Bool { gone == true }
    var label: String { customTitle ?? title }

    private enum CodingKeys: String, CodingKey {
        case id, title, customTitle, directory, launchCommand, isConnecting, terminal, machine, agent, gone
    }
    var surfaceIDs: [UUID] { [id] }
    var focusedSurfaceID: UUID { id }

    /// A new tab's id follows its caller's own sequence (a placeholder made elsewhere does not shift it).
    init(id: UUID? = nil, directory: String, _ file: String = #fileID, _ function: String = #function) {
        self.id = id ?? System.uuid(for: "", file, function)
        self.directory = directory
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
        title = folder.path == System.home.path ? "~" : (folder.path == "/" ? "/" : folder.lastPathComponent)
    }

    /// Automatic names follow the agent's conversation, then a running program's
    /// own title, then the folder at an idle prompt. Renamed tabs keep theirs. `agent`: the tab's agent (Chat's key,
    /// else `agent`), whose name stands in for the launcher's (`shown`).
    func displayLabel(automatic: Bool, conversation: String?, agent: String? = nil) -> String {
        guard automatic, customTitle == nil else { return label }
        if let conversation = Self.conversationLabel(conversation) { return conversation }
        let title = Self.shown(title, agent: agent)
        return Self.titleNamesDirectory(title, directory) ? directoryName : title
    }

    /// The folder it is in as a name (`~`, `/`, else the last component); nil without one. Remote paths are display
    /// data: never resolved against the Mac's filesystem.
    var folder: String? {
        if directory == "/" { return "/" }
        if machine == .local, directory == System.home.path { return "~" }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// What a multiplexer names an agent Dispatch's typed launcher started (`claude` in a Dispatch shell on an SSH
    /// host runs `dispatch-helper launch claude`; tmux's automatic rename, and the helper's own terminals by its
    /// path, name it after that program): it says nothing about the tab. The Mac and the phone show the agent's.
    static let launcher = "dispatch-helper"

    /// A name as shown: the agent's in place of the launcher's.
    static func shown(_ name: String, agent: String?) -> String {
        guard let agent, isLauncher(name) else { return name }
        return agent
    }

    /// Whether a name is the launcher's (its path's last part, as a helper terminal's title has it).
    static func isLauncher(_ name: String) -> Bool {
        (name.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent == launcher
    }

    /// Whether a window's name is the user's: renamed, but not to its agent's own name (`agent`), which a launch from
    /// the phone gives its new window (`launch.names`: tmux's `new-window -n claude`, herdr's `tab.rename`) and which
    /// tmux and herdr report as a rename like any other. Such a tab still follows its conversation's title.
    static func named(_ name: String, renamed: Bool, agent: String?) -> Bool {
        renamed && name != agent
    }

    /// A numbered tab's name from its focused pane, on the Mac and the phone alike: the pane's own title (the agent's
    /// in place of the launcher's) unless it names the folder (a shell at its prompt) or only repeats the tab's name;
    /// else the folder; else the tab's name.
    static func paneLabel(_ title: String, folder: String?, directory: String, tab name: String, agent: String?) -> String {
        let title = shown(title.trimmingCharacters(in: .whitespaces), agent: agent)
        if !title.isEmpty, title != name, !titleNamesDirectory(title, directory) { return title }
        return folder ?? (title.isEmpty ? name : title)
    }

    /// The agent the names around a bound process give (its executable, its pane's title, its window's): claude, codex
    /// or pi, else "agent". The topology says an agent runs, not which; Chat's binding names it exactly.
    static func agent(named names: [String?]) -> String {
        for name in names.compactMap({ $0?.lowercased() }) {
            if name.contains("claude") { return "claude" }
            if name.contains("codex") { return "codex" }
            if name == "pi" || name.hasPrefix("pi ") || name.hasPrefix("pi-") { return "pi" }
        }
        return "agent"
    }

    static func conversationLabel(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    private var directoryName: String { folder ?? title }

    /// Shell integration titles an idle prompt with its folder (`~/src/app`, `…/src/app`,
    /// bash's `\w`) and a running command with its command line.
    static func titleNamesDirectory(_ title: String, _ directory: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard let first = title.first, "~/…".contains(first) else { return false }
        if title == "~" || title == "/" { return true }
        return (title as NSString).lastPathComponent == (directory as NSString).lastPathComponent
    }
}

/// Closing a selected tab follows visible order, independent of backend history.
enum TabSelection {
    static func replacement<ID: Equatable>(for closed: ID, in order: [ID]) -> ID? {
        guard let index = order.firstIndex(of: closed), order.count > 1 else { return nil }
        return order[index + 1 < order.count ? index + 1 : index - 1]
    }
}

struct Pane: Identifiable, Equatable, Codable {
    let id: UUID
    var tabs: [TerminalTab]
    var selected: UUID

    init(id: UUID = System.uuid(), tabs: [TerminalTab], selected: UUID? = nil) {
        precondition(!tabs.isEmpty)
        self.id = id; self.tabs = tabs
        self.selected = selected.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs[0].id
    }

    var activeTab: TerminalTab? { tabs.first { $0.id == selected } }

    mutating func removeTab(at index: Int) -> TerminalTab {
        let replacement = TabSelection.replacement(for: tabs[index].id, in: tabs.map(\.id))
        let tab = tabs.remove(at: index)
        if selected == tab.id, let replacement { selected = replacement }
        return tab
    }
}

enum SplitAxis: Codable { case columns, rows }

enum LayoutPreset: String, CaseIterable, Codable {
    case single = "single", columns = "2 columns", rows = "2 rows", twoAbove = "2 above", grid = "2 × 2 grid"
    case six = "3 × 2 grid", eight = "4 × 2 grid"
    var shortcutKey: String? {
        switch self {
        case .single: "1"
        case .columns: "2"
        case .rows: nil
        case .twoAbove: "3"
        case .grid: "4"
        case .six: "6"
        case .eight: "8"
        }
    }
    #if canImport(AppKit)
    /// The preset the Splits number keys (⌃1…4, 6, 8 by default) choose, by physical key.
    static func shortcut(keyCode: UInt16) -> LayoutPreset? {
        ApplicationMenu.digitKeyCodes.firstIndex(of: keyCode).flatMap { index in allCases.first { $0.shortcutKey == String(index + 1) } }
    }
    #endif
    var count: Int {
        switch self {
        case .single: 1
        case .columns, .rows: 2
        case .twoAbove: 3
        case .grid: 4
        case .six: 6
        case .eight: 8
        }
    }

    /// Panes across and down where the layout is densest.
    var grid: (columns: Int, rows: Int) {
        switch self {
        case .single: (1, 1)
        case .columns: (2, 1)
        case .rows: (1, 2)
        case .twoAbove, .grid: (2, 2)
        case .six: (3, 2)
        case .eight: (4, 2)
        }
    }

    /// The smallest pane, in terminal cells, a layout of more than four panes may leave.
    static let roomyPane = (columns: 60.0, rows: 24.0)
    /// A terminal's padding around its cells, on each axis (`TerminalView`'s 10 points a side).
    static let panePadding = 20.0

    /// Whether panes `area` points large leave every pane `roomyPane` cells of `cell`. Layouts of up to four panes
    /// always fit: they were there before the gate and keep working in any window.
    func fits(_ area: CGSize, cell: CGSize) -> Bool {
        guard count > 4, cell.width > 0, cell.height > 0 else { return true }
        let width = area.width / CGFloat(grid.columns) - Self.panePadding
        let height = area.height / CGFloat(grid.rows) - Self.panePadding
        return width / cell.width >= Self.roomyPane.columns && height / cell.height >= Self.roomyPane.rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        // Saved layouts retain their own tree and divider ratios. Keep old
        // two-pane presentations readable after retiring the preset.
        if value == "main + side" { self = .columns; return }
        guard let preset = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown layout: \(value)")
        }
        self = preset
    }
    /// The layout a split of this many tabs starts with: side by side, then two above one, then a grid.
    static func split(_ count: Int) -> LayoutPreset {
        switch count {
        case ...1: .single
        case 2: .columns
        case 3: .twoAbove
        default: .grid
        }
    }

    /// The layouts a split of this many tabs can take.
    static func splits(_ count: Int) -> [LayoutPreset] { allCases.filter { $0 != .single && $0.count == count } }

    /// A split's layout as the sidebar's menus name it.
    var splitTitle: String {
        switch self {
        case .single: "Single"
        case .columns: "Side by Side"
        case .rows: "Stacked"
        case .twoAbove: "Two Above One"
        case .grid: "Grid"
        case .six: "Grid of Six"
        case .eight: "Grid of Eight"
        }
    }

    var title: String {
        switch self {
        case .columns: "columns"
        case .rows: "rows"
        case .grid: "grid"
        case .single, .twoAbove, .six, .eight: rawValue
        }
    }
}

/// Room for a window's panes: their area now, the area once the window fills its screen, and a terminal cell at the
/// current font, all in points. View state (`MainView` measures it), never saved.
struct LayoutRoom: Equatable {
    var window: CGSize
    var screen: CGSize
    var cell: CGSize
}

extension LayoutPreset {
    /// Shared placement for native tabs and whole windows of a structured space.
    struct TabGroup {
        let id: UUID
        var tabs: [UUID]
        let selected: UUID
    }

    /// Moves the panes' tabs into this layout's panes. `fractions`: the old layout's divider positions, so each pane is
    /// matched where it shows. Each old pane goes into the new pane it overlaps most (the focused one first), or joins
    /// the one it overlaps most once none it overlaps is free; joined panes keep their reading order and their tabs'.
    /// A pane left empty takes the last hidden tab of the pane that covered its place, the last in reading order first,
    /// so a pane's tabs split off in runs and join back in their order. `remembered`: what this layout held when last
    /// left (`LayoutMemory`), whose tabs go back to their panes in their order.
    func arrange(_ groups: [TabGroup], in oldLayout: PaneLayout, fractions: [UUID: CGFloat] = [:], selected: UUID,
                 remembered: LayoutMemory.Arrangement? = nil) -> [TabGroup] {
        precondition(groups.reduce(0) { $0 + $1.tabs.count } >= count)
        // Thirds don't add up exactly: overlaps this close are equal.
        let tolerance: CGFloat = 1e-9
        func frames(_ layout: PaneLayout, _ fractions: [UUID: CGFloat]) -> [UUID: CGRect] {
            Dictionary(layout.paneFrames(fractions: fractions).map { ($0.id, $0.frame) }) { first, _ in first }
        }
        let oldFrames = frames(oldLayout, fractions)
        let slots = (0..<count).map { _ in System.uuid() }
        let newLayout = layout(slots)
        let newFractions = newLayout.evenFractions.mapValues { CGFloat($0) }
        let newFrames = frames(newLayout, newFractions)
        func overlap(_ group: UUID, _ index: Int) -> CGFloat {
            guard let old = oldFrames[group] else { return 0 }
            let intersection = old.intersection(newFrames[slots[index]]!)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        /// The new pane among `indices` the old pane overlaps most, the first on a tie; none it overlaps at all.
        func closest(_ group: UUID, among indices: [Int]) -> Int? {
            indices.filter { overlap(group, $0) > tolerance }.min { a, b in
                let x = overlap(group, a), y = overlap(group, b)
                return abs(x - y) <= tolerance ? a < b : x > y
            }
        }
        // Focus wins when two old panes need the same position. Ties use visual
        // order, so splitting a single pane keeps it at the top left.
        let reading = oldLayout.paneIDsInReadingOrder(fractions: fractions).compactMap { id in groups.first { $0.id == id } }
        let rank = Dictionary(reading.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let priority = reading.filter { $0.tabs.contains(selected) } + reading.filter { !$0.tabs.contains(selected) }
        var owners = [TabGroup?](repeating: nil, count: count)
        var joined = [[TabGroup]](repeating: [], count: count)
        var merged: [TabGroup] = []
        for group in priority {
            if let index = closest(group.id, among: owners.indices.filter { owners[$0] == nil }) {
                owners[index] = group; joined[index] = [group]
            } else { merged.append(group) }
        }
        for group in merged {
            let taken = owners.indices.filter { owners[$0] != nil }
            guard let index = closest(group.id, among: taken) ?? taken.first else {
                owners[0] = group; joined[0] = [group]; continue
            }
            joined[index].append(group)
        }
        var placed: [TabGroup?] = owners.indices.map { index in
            owners[index].map { owner in
                TabGroup(id: owner.id, tabs: joined[index].sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
                    .flatMap(\.tabs), selected: owner.selected)
            }
        }
        if let remembered, remembered.panes.count == count {
            placed = recall(remembered, into: placed, slots: slots, selected: selected)
        }
        // Populate additional panes using hidden tabs, retaining every visible selection.
        let order = newLayout.paneIDsInReadingOrder(fractions: newFractions).compactMap { slots.firstIndex(of: $0) }
        for index in order.reversed() where placed[index] == nil {
            let donors = placed.indices.filter { (placed[$0]?.tabs.count ?? 0) > 1 }
            let source = donors.min { a, b in
                let x = overlap(placed[a]!.id, index), y = overlap(placed[b]!.id, index)
                return abs(x - y) <= tolerance ? a < b : x > y
            }!
            let tabIndex = placed[source]!.tabs.lastIndex { $0 != placed[source]!.selected }!
            let tab = placed[source]!.tabs.remove(at: tabIndex)
            placed[index] = TabGroup(id: slots[index], tabs: [tab], selected: tab)
        }
        return placed.compactMap { $0 }
    }

    /// The remembered tabs back in their panes, in their order, before the others the placement put there; the
    /// focused tab stays shown, else each pane shows the tab it showed. A pane left empty is filled after.
    private func recall(_ remembered: LayoutMemory.Arrangement, into placed: [TabGroup?], slots: [UUID],
                        selected: UUID) -> [TabGroup?] {
        let present = Set(placed.flatMap { $0?.tabs ?? [] })
        let known = Set(remembered.panes.joined()).intersection(present)
        return placed.indices.map { index in
            let base = placed[index]
            let tabs = remembered.panes[index].filter(present.contains) + (base?.tabs ?? []).filter { !known.contains($0) }
            guard let first = tabs.first else { return nil }
            let shown = tabs.contains(selected) ? selected
                : [index < remembered.selected.count ? remembered.selected[index] : nil, base?.selected].compactMap { $0 }.first(where: tabs.contains) ?? first
            return TabGroup(id: base?.id ?? slots[index], tabs: tabs, selected: shown)
        }
    }
}

/// What each layout of a space held when the user last left it, so going back puts every tab where it was: the
/// panes' tabs (a structured space's windows) in the preset's pane order, the tab each showed and the dividers. A tab
/// the user moves to another pane meanwhile is forgotten (`leave` sees it away from where the last layout placed it);
/// tabs gone since are dropped. Kept with the space.
struct LayoutMemory: Equatable, Codable {
    struct Arrangement: Equatable, Codable {
        var panes: [[UUID]]
        var selected: [UUID]
        /// The dividers' positions in the layout's split order (`PaneLayout.splitOrder`); nil at the middle.
        var fractions: [Double?]

        func dividers(of layout: PaneLayout) -> [UUID: Double] {
            Dictionary(zip(layout.splitOrder, fractions).compactMap { id, fraction in fraction.map { (id, $0) } }) { first, _ in first }
        }
    }

    /// By `LayoutPreset.rawValue`.
    var presets: [String: Arrangement] = [:]
    /// The pane each tab had when a layout last placed it.
    var placed: [UUID: UUID] = [:]

    /// Before another layout: tabs the user moved to another pane since are forgotten, then the layout being left (a
    /// preset's, not one the user split by hand) is remembered.
    mutating func leave(_ groups: [LayoutPreset.TabGroup], preset: LayoutPreset?, layout: PaneLayout, fractions: [UUID: CGFloat]) {
        let pane = Dictionary(groups.flatMap { group in group.tabs.map { ($0, group.id) } }) { first, _ in first }
        let kept = Set(pane.compactMap { tab, id in (placed[tab].map { $0 == id } ?? true) ? tab : nil })
        for key in presets.keys {
            presets[key]!.panes = presets[key]!.panes.map { $0.filter(kept.contains) }
        }
        placed = [:]
        let ordered = layout.paneIDs.compactMap { id in groups.first { $0.id == id } }
        guard let preset, ordered.count == preset.count, ordered.count == groups.count else { return }
        presets[preset.rawValue] = Arrangement(panes: ordered.map(\.tabs), selected: ordered.map(\.selected),
                                               fractions: layout.splitOrder.map { fractions[$0].map(Double.init) })
    }

    /// After a layout placed them.
    mutating func record(_ groups: [LayoutPreset.TabGroup]) {
        placed = Dictionary(groups.flatMap { group in group.tabs.map { ($0, group.id) } }) { first, _ in first }
    }
}

enum PaneEdge: String, CaseIterable {
    case left, right, top, bottom
    var axis: SplitAxis { self == .left || self == .right ? .columns : .rows }
    var before: Bool { self == .left || self == .top }
}

indirect enum PaneLayout: Equatable, Codable {
    case pane(UUID)
    case split(UUID, SplitAxis, PaneLayout, PaneLayout)

    static let minimumPaneSize = CGSize(width: 180, height: 120)

    var minimumSize: CGSize {
        switch self {
        case .pane: return Self.minimumPaneSize
        case .split(_, let axis, let first, let second):
            let firstSize = first.minimumSize, secondSize = second.minimumSize
            // Each thin native divider occupies one point between its subtrees.
            return axis == .columns
                ? CGSize(width: firstSize.width + secondSize.width + 1, height: max(firstSize.height, secondSize.height))
                : CGSize(width: max(firstSize.width, secondSize.width), height: firstSize.height + secondSize.height + 1)
        }
    }

    /// The divider positions that give panes along each axis equal shares (a third, then a half, for three across),
    /// for the dividers not at the middle; the others default there.
    var evenFractions: [UUID: Double] {
        func span(_ node: PaneLayout, _ axis: SplitAxis) -> Int {
            switch node {
            case .pane: 1
            case .split(_, let along, let first, let second):
                along == axis ? span(first, axis) + span(second, axis) : max(span(first, axis), span(second, axis))
            }
        }
        switch self {
        case .pane: return [:]
        case .split(let id, let axis, let first, let second):
            var fractions = first.evenFractions.merging(second.evenFractions) { first, _ in first }
            let fraction = Double(span(first, axis)) / Double(span(self, axis))
            if abs(fraction - 0.5) > 0.0001 { fractions[id] = fraction }
            return fractions
        }
    }

    var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    /// Number visible panes from left to right, then top to bottom, even when
    /// a custom grid's split tree stores an entire column before the next one.
    func paneIDsInReadingOrder(fractions: [UUID: CGFloat] = [:]) -> [UUID] {
        paneFrames(fractions: fractions).sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY
        }.map(\.id)
    }

    /// Each pane's frame in the unit square, in tree order.
    func paneFrames(fractions: [UUID: CGFloat] = [:]) -> [(id: UUID, frame: CGRect)] {
        var frames: [(id: UUID, frame: CGRect)] = []
        func visit(_ node: PaneLayout, in rect: CGRect) {
            switch node {
            case .pane(let id): frames.append((id, rect))
            case .split(let id, let axis, let first, let second):
                let distance = (axis == .columns ? rect.width : rect.height) * (fractions[id] ?? 0.5)
                let parts = rect.divided(atDistance: distance, from: axis == .columns ? .minXEdge : .minYEdge)
                visit(first, in: parts.slice)
                visit(second, in: parts.remainder)
            }
        }
        visit(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return frames
    }

    /// The splits, each before its halves': the same place in two layouts a preset made.
    var splitOrder: [UUID] {
        switch self {
        case .pane: []
        case .split(let id, _, let first, let second): [id] + first.splitOrder + second.splitOrder
        }
    }

    var splitIDs: Set<UUID> {
        switch self {
        case .pane: []
        case .split(let id, _, let first, let second): first.splitIDs.union(second.splitIDs).union([id])
        }
    }

    /// The panes of the innermost split around `pane`, in reading order: what Merge Panes joins.
    func splitPanes(containing pane: UUID) -> [UUID]? {
        guard case .split(_, _, let first, let second) = self else { return nil }
        let child = first.paneIDs.contains(pane) ? first : second
        guard child.paneIDs.contains(pane) else { return nil }
        return child.splitPanes(containing: pane) ?? paneIDs
    }

    func splitting(_ id: UUID, with newID: UUID, axis: SplitAxis, before: Bool = false) -> PaneLayout {
        switch self {
        case .pane(let current):
            current == id ? .split(System.uuid(), axis, before ? .pane(newID) : self, before ? self : .pane(newID)) : self
        case .split(let key, let direction, let first, let second):
            .split(key, direction, first.splitting(id, with: newID, axis: axis, before: before), second.splitting(id, with: newID, axis: axis, before: before))
        }
    }

    func removing(_ id: UUID) -> PaneLayout? {
        switch self {
        case .pane(let current): return current == id ? nil : self
        case .split(let key, let axis, let first, let second):
            let a = first.removing(id), b = second.removing(id)
            if let a, let b { return .split(key, axis, a, b) }
            return a ?? b
        }
    }
}

/// A layout belongs to one local space or one window of a structured space.
struct PaneArrangement: Equatable, Codable {
    var panes: [Pane]
    var layout: PaneLayout
    var focusedPane: UUID
    var preset: LayoutPreset? = .single
    var splitFractions: [UUID: CGFloat] = [:]

    init(tab: TerminalTab) {
        let pane = Pane(tabs: [tab])
        panes = [pane]; layout = .pane(pane.id); focusedPane = pane.id
    }

    mutating func detachTab(_ id: UUID) -> TerminalTab? {
        guard let p = panes.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let t = panes[p].tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = panes[p].removeTab(at: t)
        if panes[p].tabs.isEmpty {
            let pane = panes.remove(at: p).id
            if let next = layout.removing(pane) {
                layout = next
                preset = nil
                splitFractions = splitFractions.filter { next.splitIDs.contains($0.key) }
                if focusedPane == pane { focusedPane = next.paneIDs[0] }
            }
        }
        return tab
    }
}

struct Space: Identifiable, Equatable, Codable {
    var id = System.uuid()
    private var storedName: String
    var usesDirectoryName = false
    var name: String {
        get {
            // A multiplexer's space named after the typed launcher (a window split off while tmux named it after
            // `dispatch-helper launch claude`, kept as the space's stored name) says nothing: its first pane's folder,
            // as the helper names a space whose stored name is all it has.
            if TerminalTab.isLauncher(storedName), let folder = tabs.first?.folder { return folder }
            guard usesDirectoryName, let directory = tabs.first?.directory,
                  directory.hasPrefix("/") else { return storedName }
            if directory == "/" { return "/" }
            // A remote directory is display data. File URLs without a directory
            // hint probe the Mac filesystem and can block on /home automounts.
            let basename = (directory as NSString).lastPathComponent
            return basename.isEmpty ? storedName : basename
        }
        set { storedName = newValue; usesDirectoryName = false }
    }
    var hostID: HostID = .local
    var splitRatios: [UUID: Double] = [:]
    var backend: UInt64?
    var node: UInt64?
    /// The SSH link whose helper hosts this backend; nil on this Mac.
    var remote: SSHConnectionID?
    private var collection: [ContainerTab]?
    var containers: [ContainerTab] {
        get { collection ?? [] }
        set { collection = newValue }
    }
    var selectedContainer: UUID?
    var presentation: TabPresentation?
    /// What its layouts held when last left (`Workspace.applyLayout`).
    var layoutMemory: LayoutMemory?
    private var local: PaneArrangement
    var arrangement: PaneArrangement {
        get {
            if !containers.isEmpty {
                return presentation?.arrangement(windows: Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0.arrangement) }), selected: selectedContainer)
                    ?? containers.first(where: { $0.id == selectedContainer })?.arrangement ?? containers[0].arrangement
            }
            return local
        }
        set {
            if !containers.isEmpty {
                for index in containers.indices {
                    let ids = Set(containers[index].arrangement.panes.map(\.id))
                    let panes = newValue.panes.filter { ids.contains($0.id) }
                    if !panes.isEmpty { containers[index].arrangement.panes = panes }
                    if ids.contains(newValue.focusedPane) { containers[index].arrangement.focusedPane = newValue.focusedPane }
                    let splits = Set(containers[index].arrangement.layout.splitIDs)
                    containers[index].arrangement.splitFractions = newValue.splitFractions.filter { splits.contains($0.key) }
                }
                presentation?.preset = newValue.preset
            } else { local = newValue }
        }
    }
    var panes: [Pane] { get { arrangement.panes } set { arrangement.panes = newValue } }
    var layout: PaneLayout { get { arrangement.layout } set { arrangement.layout = newValue; splitRatios = splitRatios.filter { newValue.splitIDs.contains($0.key) } } }
    var focusedPane: UUID { get { arrangement.focusedPane } set { arrangement.focusedPane = newValue } }
    var preset: LayoutPreset? { get { arrangement.preset } set { arrangement.preset = newValue } }
    var splitFractions: [UUID: CGFloat] { get { arrangement.splitFractions } set { arrangement.splitFractions = newValue } }

    init(name: String, directory: String, usesDirectoryName: Bool = false, _ file: String = #fileID, _ function: String = #function) {
        self.init(name: name, tab: TerminalTab(directory: directory, file, function), usesDirectoryName: usesDirectoryName)
    }

    init(name: String, tab: TerminalTab, usesDirectoryName: Bool = false) {
        self.storedName = name
        self.usesDirectoryName = usesDirectoryName
        local = PaneArrangement(tab: tab)
    }

    var activePane: Pane? { panes.first { $0.id == focusedPane } }
    var activeTab: TerminalTab? { activePane?.activeTab }
    var usesPaneShortcuts: Bool { numberedPaneIDs.count > 1 }
    var numberedTabIDs: [UUID] { !containers.isEmpty ? containers.map(\.id) : (activePane?.tabs.map(\.id) ?? []) }
    var numberedShortcutCount: Int { min(9, usesPaneShortcuts ? numberedPaneIDs.count : numberedTabIDs.count) }

    func tabShortcutNumber(for id: UUID) -> Int? {
        guard !usesPaneShortcuts, let index = numberedTabIDs.firstIndex(of: id), index < 9 else { return nil }
        return index + 1
    }

    enum TabShortcut: Equatable { case number(Int), next, previous }

    #if canImport(AppKit)
    /// What a tab's legend advertises. Without splits, its number. With them the numbers focus panes, so the
    /// focused pane's tabs either side of its selection show ⌘] and ⌘[, landing where cycleTab would (wrapping;
    /// with two tabs the other one is "next").
    func tabShortcut(for id: UUID) -> TabShortcut? {
        guard usesPaneShortcuts else { return tabShortcutNumber(for: id).map { .number($0) } }
        let cycle: [UUID], selected: UUID?
        if let active = selectedContainer, !containers.isEmpty {
            cycle = focusedWindowIDs; selected = active
        } else {
            cycle = activePane?.tabs.map(\.id) ?? []; selected = activePane?.selected
        }
        guard cycle.count > 1, let selected, let index = cycle.firstIndex(of: selected) else { return nil }
        if id == cycle[(index + 1) % cycle.count] { return .next }
        if id == cycle[(index - 1 + cycle.count) % cycle.count] { return .previous }
        return nil
    }
    #endif

    /// Native panes and window groups have stable numbers regardless of which tab is selected
    /// inside them. An ungrouped structured space is one pane.
    var numberedPaneIDs: [UUID] {
        if !containers.isEmpty { return presentation?.layout.paneIDsInReadingOrder(fractions: paneFractions) ?? [id] }
        return layout.paneIDsInReadingOrder(fractions: paneFractions)
    }

    /// The dividers' positions: a server's, or the app's own where it set one.
    var paneFractions: [UUID: CGFloat] {
        splitFractions.merging(splitRatios.mapValues { CGFloat($0) }) { _, local in local }
    }

    func paneShortcutNumber(for id: UUID) -> Int? {
        guard let index = numberedPaneIDs.firstIndex(of: id), index < 9 else { return nil }
        return index + 1
    }

    /// Includes inactive windows so terminal lifetime never depends on selection.
    var tabs: [TerminalTab] { !containers.isEmpty ? containers.flatMap(\.terminals) : panes.flatMap(\.tabs) }
}

/// A common container and its app-owned presentation.
struct ContainerTab: Identifiable, Equatable, Codable {
    let id: UUID
    let node: UInt64
    var name: String
    /// Native explicit names outrank conversation titles; absent in older saved presentations.
    var renamed: Bool? = nil
    /// herdr numbers unnamed tabs by position; those show their focused pane's name instead.
    var numbered: Bool? = nil
    var arrangement: PaneArrangement
    var terminals: [TerminalTab] { arrangement.panes.flatMap(\.tabs) }
    var focusedTerminal: TerminalTab? { arrangement.panes.first { $0.id == arrangement.focusedPane }?.activeTab }

    /// `agent`: the focused pane's agent (its helper key). A window named after it is not one the user named
    /// (`TerminalTab.named`): it still follows the conversation. The phone's `MobileTab.label` follows the same rules.
    func displayLabel(automatic: Bool, conversation: String?, focused: TerminalTab? = nil, agent: String? = nil) -> String {
        guard automatic, !TerminalTab.named(name, renamed: renamed == true, agent: agent) else { return name }
        if let conversation = TerminalTab.conversationLabel(conversation) { return conversation }
        guard numbered == true, let pane = focused ?? focusedTerminal else { return TerminalTab.shown(name, agent: agent) }
        if let custom = pane.customTitle { return custom }
        return TerminalTab.paneLabel(pane.title, folder: pane.folder, directory: pane.directory, tab: name, agent: agent)
    }

    /// The node that moves this window: its only terminal (every multiplexer moves a lone pane with its
    /// window; herdr places panes only), else the window itself.
    var placeable: UInt64 { terminals.count == 1 ? terminals[0].terminal ?? node : node }
    /// The node a window of gone tabs has (`TerminalTab.gone`): none on any server. A window still being made has it
    /// too, with tabs that are not gone.
    static let goneNode: UInt64 = 0
    var gone: Bool { node == Self.goneNode && !terminals.isEmpty && terminals.allSatisfy(\.isGone) }
}

/// A workspace command edits this value, then publishes the complete result.
/// Backend commands and terminal lifetime effects stay with the caller.
struct WorkspaceLayout: Equatable {
    var spaces: [Space]
    var selectedSpace: UUID?

    func location(ofTab id: UUID) -> (space: Int, pane: Int, tab: Int)? {
        for s in spaces.indices {
            let panes = spaces[s].panes
            for p in panes.indices {
                if let t = panes[p].tabs.firstIndex(where: { $0.id == id }) { return (s, p, t) }
            }
        }
        return nil
    }

    func location(ofPane id: UUID) -> (space: Int, pane: Int)? {
        for s in spaces.indices {
            if let p = spaces[s].panes.firstIndex(where: { $0.id == id }) { return (s, p) }
        }
        return nil
    }

    @discardableResult
    mutating func selectTab(_ id: UUID) -> UUID? {
        for s in spaces.indices {
            if let container = spaces[s].containers.first(where: { $0.terminals.contains { $0.id == id } }) {
                spaces[s].selectedContainer = container.id
                spaces[s].presentation?.select(container.id)
                break
            }
        }
        guard let (s, p, _) = location(ofTab: id) else { return nil }
        spaces[s].panes[p].selected = id
        spaces[s].focusedPane = spaces[s].panes[p].id
        selectedSpace = spaces[s].id
        return selectedSpace
    }

    /// Arrivals join the end of their host's spaces, including newly seen hosts.
    mutating func positionAtHostEnd(_ id: UUID) {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        let moved = spaces.remove(at: index)
        let insertion = spaces.lastIndex(where: { $0.hostID == moved.hostID }).map { $0 + 1 } ?? spaces.count
        spaces.insert(moved, at: insertion)
    }

    mutating func removeSpace(at index: Int) {
        let id = spaces[index].id
        spaces.remove(at: index)
        if selectedSpace == id { selectedSpace = spaces.isEmpty ? nil : spaces[min(index, spaces.count - 1)].id }
    }

    mutating func detachTab(_ id: UUID) -> TerminalTab? {
        for s in spaces.indices {
            for c in spaces[s].containers.indices {
                if let tab = spaces[s].containers[c].arrangement.detachTab(id) {
                    if spaces[s].containers[c].arrangement.panes.isEmpty {
                        let id = spaces[s].containers[c].id
                        let order = spaces[s].presentation?.groups.first { $0.windows.contains(id) }?.windows
                            ?? spaces[s].containers.map(\.id)
                        let replacement = TabSelection.replacement(for: id, in: order)
                        spaces[s].containers.remove(at: c)
                        let windows = spaces[s].containers.map(\.id), selected = spaces[s].selectedContainer
                        spaces[s].presentation?.reconcile(windows, near: selected)
                        if !spaces[s].containers.contains(where: { $0.id == spaces[s].selectedContainer }) {
                            spaces[s].selectedContainer = replacement ?? spaces[s].containers.first?.id
                            if let selected = spaces[s].selectedContainer { spaces[s].presentation?.select(selected) }
                        }
                        if spaces[s].containers.isEmpty { removeSpace(at: s) }
                    }
                    return tab
                }
            }
            if spaces[s].containers.isEmpty, let tab = spaces[s].arrangement.detachTab(id) {
                if spaces[s].arrangement.panes.isEmpty { removeSpace(at: s) }
                return tab
            }
        }
        return nil
    }

    @discardableResult
    mutating func splitTab(_ id: UUID, beside target: UUID, edge: PaneEdge) -> UUID? {
        guard let source = location(ofTab: id), location(ofPane: target) != nil,
              spaces[source.space].panes[source.pane].id != target || spaces[source.space].panes[source.pane].tabs.count > 1 else { return nil }
        guard let tab = detachTab(id), let (s, _) = location(ofPane: target) else { return nil }
        let pane = Pane(tabs: [tab])
        spaces[s].layout = spaces[s].layout.splitting(target, with: pane.id, axis: edge.axis, before: edge.before)
        spaces[s].panes.append(pane); spaces[s].preset = nil
        return selectTab(id)
    }
}

/// Groups of a structured space's windows shown side by side. A window's server layout stays
/// intact inside its selected group; changing this tree never creates a terminal.
struct TabPresentation: Equatable, Codable {
    struct Group: Equatable, Identifiable, Codable {
        let id: UUID
        var windows: [UUID]
        var selected: UUID
    }
    var groups: [Group]
    var layout: PaneLayout
    var preset: LayoutPreset?

    init(windows: [UUID], selected: UUID, preset: LayoutPreset) {
        precondition(windows.count >= preset.count)
        groups = (0..<preset.count).map { index in
            let members = index == 0 ? [windows[0]] + windows.dropFirst(preset.count) : [windows[index]]
            return Group(id: System.uuid(), windows: members, selected: members.contains(selected) ? selected : members[0])
        }
        layout = preset.layout(groups.map(\.id)); self.preset = preset
    }

    var orderedWindows: [UUID] {
        layout.paneIDs.flatMap { id in groups.first(where: { $0.id == id })?.windows ?? [] }
    }

    mutating func select(_ window: UUID) {
        if let index = groups.firstIndex(where: { $0.windows.contains(window) }) { groups[index].selected = window }
    }

    mutating func reconcile(_ windows: [UUID], near selected: UUID?) {
        let live = Set(windows)
        for index in groups.indices {
            let order = groups[index].windows.filter { live.contains($0) || $0 == groups[index].selected }
            let replacement = TabSelection.replacement(for: groups[index].selected, in: order)
            groups[index].windows.removeAll { !live.contains($0) }
            if !groups[index].windows.contains(groups[index].selected), let next = replacement ?? groups[index].windows.first { groups[index].selected = next }
        }
        for group in groups where group.windows.isEmpty {
            if let next = layout.removing(group.id) { layout = next }
        }
        groups.removeAll { $0.windows.isEmpty }
        let known = Set(groups.flatMap(\.windows))
        if !groups.isEmpty {
            // An arriving window (made here, or moved in from another space before or after one of these) takes its
            // server place: after the nearest window before it in the server's order that the group holds, else
            // before the nearest after it. Appended, a window moved before the first would land last.
            let destination = groups.firstIndex { $0.windows.contains(where: { $0 == selected }) } ?? 0
            for (index, window) in windows.enumerated() where !known.contains(window) {
                let members = groups[destination].windows
                if let previous = windows[..<index].last(where: members.contains), let at = members.firstIndex(of: previous) {
                    groups[destination].windows.insert(window, at: at + 1)
                } else if let following = windows[(index + 1)...].first(where: members.contains),
                          let at = members.firstIndex(of: following) {
                    groups[destination].windows.insert(window, at: at)
                } else {
                    groups[destination].windows.append(window)
                }
            }
        }
        if groups.count == 1 { preset = .single }
        else if groups.count != preset?.count { preset = nil }
    }

    func arrangement(windows: [UUID: PaneArrangement], selected: UUID?) -> PaneArrangement? {
        let visible = groups.compactMap { group in windows[group.selected].map { (id: group.selected, arrangement: $0) } }
        guard var result = visible.first?.arrangement else { return nil }
        func expand(_ node: PaneLayout) -> PaneLayout {
            switch node {
            case .pane(let id):
                return groups.first(where: { $0.id == id }).flatMap { group in
                    visible.first(where: { $0.id == group.selected })?.arrangement.layout
                } ?? node
            case .split(let id, let axis, let first, let second): return .split(id, axis, expand(first), expand(second))
            }
        }
        result.layout = expand(layout)
        result.panes = visible.flatMap { $0.arrangement.panes }
        result.focusedPane = visible.first(where: { $0.id == selected })?.arrangement.focusedPane ?? result.focusedPane
        result.preset = preset
        result.splitFractions = visible.reduce(into: [:]) { $0.merge($1.arrangement.splitFractions) { _, new in new } }
        return result
    }

    mutating func move(_ window: UUID, beside target: UUID, edge: PaneEdge?, after: Bool = false) -> Bool {
        guard let source = groups.firstIndex(where: { $0.windows.contains(window) }),
              let destination = groups.firstIndex(where: { $0.windows.contains(target) }), window != target else { return false }
        if edge != nil, groups.count >= 4, groups[source].windows.count > 1 { return false }
        let targetGroup = groups[destination].id
        groups[source].windows.removeAll { $0 == window }
        if groups[source].selected == window, let first = groups[source].windows.first { groups[source].selected = first }
        if let edge {
            let added = Group(id: System.uuid(), windows: [window], selected: window)
            layout = layout.splitting(targetGroup, with: added.id, axis: edge.axis, before: edge.before)
            groups.append(added)
        } else {
            let index = groups[destination].windows.firstIndex(of: target)!
            groups[destination].windows.insert(window, at: index + (after ? 1 : 0))
            groups[destination].selected = window
        }
        for group in groups where group.windows.isEmpty {
            if let next = layout.removing(group.id) { layout = next }
        }
        groups.removeAll { $0.windows.isEmpty }
        preset = groups.count == 1 ? .single : nil
        return true
    }
}

extension LayoutPreset {
    func layout(_ ids: [UUID]) -> PaneLayout {
        switch self {
        case .single: .pane(ids[0])
        case .columns: .split(System.uuid(), .columns, .pane(ids[0]), .pane(ids[1]))
        case .rows: .split(System.uuid(), .rows, .pane(ids[0]), .pane(ids[1]))
        case .twoAbove: .split(System.uuid(), .rows,
            .split(System.uuid(), .columns, .pane(ids[0]), .pane(ids[1])), .pane(ids[2]))
        case .grid: .split(System.uuid(), .rows,
            .split(System.uuid(), .columns, .pane(ids[0]), .pane(ids[1])),
            .split(System.uuid(), .columns, .pane(ids[2]), .pane(ids[3])))
        // Each row a column split in reading order; `evenFractions` puts the three's first divider at a third.
        case .six: .split(System.uuid(), .rows,
            .split(System.uuid(), .columns, .pane(ids[0]), .split(System.uuid(), .columns, .pane(ids[1]), .pane(ids[2]))),
            .split(System.uuid(), .columns, .pane(ids[3]), .split(System.uuid(), .columns, .pane(ids[4]), .pane(ids[5]))))
        case .eight: .split(System.uuid(), .rows,
            .split(System.uuid(), .columns,
                .split(System.uuid(), .columns, .pane(ids[0]), .pane(ids[1])),
                .split(System.uuid(), .columns, .pane(ids[2]), .pane(ids[3]))),
            .split(System.uuid(), .columns,
                .split(System.uuid(), .columns, .pane(ids[4]), .pane(ids[5])),
                .split(System.uuid(), .columns, .pane(ids[6]), .pane(ids[7]))))
        }
    }
}
