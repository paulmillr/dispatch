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
    var label: String { customTitle ?? title }
    var surfaceIDs: [UUID] { [id] }
    var focusedSurfaceID: UUID { id }

    init(id: UUID = UUID(), directory: String) {
        self.id = id
        self.directory = directory
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath).standardizedFileURL
        title = folder.path == NSHomeDirectory() ? "~" : (folder.path == "/" ? "/" : folder.lastPathComponent)
    }

    /// Automatic names follow the agent's conversation, then a running program's
    /// own title, then the folder at an idle prompt. Renamed tabs keep theirs.
    func displayLabel(automatic: Bool, conversation: String?) -> String {
        guard automatic, customTitle == nil else { return label }
        if let conversation = Self.conversationLabel(conversation) { return conversation }
        return Self.titleNamesDirectory(title, directory) ? directoryName : title
    }

    static func conversationLabel(_ title: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    // Remote paths are display data; don't resolve them against the Mac filesystem.
    private var directoryName: String {
        if directory == "/" { return "/" }
        if machine == .local, directory == NSHomeDirectory() { return "~" }
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty ? title : name
    }

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

    init(id: UUID = UUID(), tabs: [TerminalTab], selected: UUID? = nil) {
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
    var shortcutKey: String? {
        switch self {
        case .single: "1"
        case .columns: "2"
        case .rows: nil
        case .twoAbove: "3"
        case .grid: "4"
        }
    }
    /// The preset the Splits number keys (⌃1…4 by default) choose, by physical key.
    static func shortcut(keyCode: UInt16) -> LayoutPreset? {
        ApplicationMenu.digitKeyCodes.firstIndex(of: keyCode).flatMap { index in allCases.first { $0.shortcutKey == String(index + 1) } }
    }
    var count: Int {
        switch self {
        case .single: 1
        case .columns, .rows: 2
        case .twoAbove: 3
        case .grid: 4
        }
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
    var title: String {
        switch self {
        case .columns: "columns"
        case .rows: "rows"
        case .grid: "grid"
        case .single, .twoAbove: rawValue
        }
    }
}

extension LayoutPreset {
    /// Shared placement for native tabs and whole windows of a structured space.
    struct TabGroup {
        let id: UUID
        var tabs: [UUID]
        let selected: UUID
    }

    func arrange(_ groups: [TabGroup], in oldLayout: PaneLayout, selected: UUID) -> [TabGroup] {
        precondition(groups.reduce(0) { $0 + $1.tabs.count } >= count)
        func frames(_ layout: PaneLayout, in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
            switch layout {
            case .pane(let id): return [id: rect]
            case .split(_, let axis, let first, let second):
                let parts = rect.divided(atDistance: (axis == .columns ? rect.width : rect.height) / 2,
                                         from: axis == .columns ? .minXEdge : .minYEdge)
                return frames(first, in: parts.slice).merging(frames(second, in: parts.remainder)) { first, _ in first }
            }
        }
        let oldFrames = frames(oldLayout)
        let slots = (0..<count).map { _ in UUID() }
        let newFrames = frames(layout(slots))
        func overlap(_ group: TabGroup, _ index: Int) -> CGFloat {
            let intersection = oldFrames[group.id]!.intersection(newFrames[slots[index]]!)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        // Focus wins when two old panes need the same position. Ties use visual
        // order, so splitting a single pane keeps it at the top left.
        let ordered = oldLayout.paneIDs.compactMap { id in groups.first { $0.id == id } }
        let priority = ordered.filter { $0.tabs.contains(selected) } + ordered.filter { !$0.tabs.contains(selected) }
        var placed = [TabGroup?](repeating: nil, count: count)
        var merged: [TabGroup] = []
        for group in priority {
            let available = placed.indices.filter { placed[$0] == nil }
            guard let index = available.sorted(by: {
                let a = overlap(group, $0), b = overlap(group, $1)
                return a == b ? $0 < $1 : a > b
            }).first else { merged.append(group); continue }
            placed[index] = group
        }
        for group in merged {
            let index = placed.indices.filter { placed[$0] != nil }.sorted {
                let a = overlap(group, $0), b = overlap(group, $1)
                return a == b ? $0 < $1 : a > b
            }[0]
            placed[index]!.tabs += group.tabs
        }
        // Populate additional panes using hidden tabs, retaining every visible
        // selection and the order of the tabs left in each original pane.
        for index in placed.indices where placed[index] == nil {
            let source = placed.indices.first { (placed[$0]?.tabs.count ?? 0) > 1 }!
            let tabIndex = placed[source]!.tabs.firstIndex { $0 != placed[source]!.selected }!
            let tab = placed[source]!.tabs.remove(at: tabIndex)
            placed[index] = TabGroup(id: slots[index], tabs: [tab], selected: tab)
        }
        return placed.compactMap { $0 }
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

    var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    /// Number visible panes from left to right, then top to bottom, even when
    /// a custom grid's split tree stores an entire column before the next one.
    func paneIDsInReadingOrder(fractions: [UUID: CGFloat] = [:]) -> [UUID] {
        var positions: [(id: UUID, origin: CGPoint)] = []
        func visit(_ node: PaneLayout, in rect: CGRect) {
            switch node {
            case .pane(let id): positions.append((id, rect.origin))
            case .split(let id, let axis, let first, let second):
                let distance = (axis == .columns ? rect.width : rect.height) * (fractions[id] ?? 0.5)
                let parts = rect.divided(atDistance: distance, from: axis == .columns ? .minXEdge : .minYEdge)
                visit(first, in: parts.slice)
                visit(second, in: parts.remainder)
            }
        }
        visit(self, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return positions.sorted {
            $0.origin.y == $1.origin.y ? $0.origin.x < $1.origin.x : $0.origin.y < $1.origin.y
        }.map(\.id)
    }

    var splitIDs: Set<UUID> {
        switch self {
        case .pane: []
        case .split(let id, _, let first, let second): first.splitIDs.union(second.splitIDs).union([id])
        }
    }

    /// Find the innermost split in this direction around the focused pane.
    func splitPanes(containing pane: UUID, axis: SplitAxis) -> [UUID]? {
        guard case .split(_, let direction, let first, let second) = self else { return nil }
        let child = first.paneIDs.contains(pane) ? first : second
        guard child.paneIDs.contains(pane) else { return nil }
        return child.splitPanes(containing: pane, axis: axis) ?? (direction == axis ? paneIDs : nil)
    }

    func splitting(_ id: UUID, with newID: UUID, axis: SplitAxis, before: Bool = false) -> PaneLayout {
        switch self {
        case .pane(let current):
            current == id ? .split(UUID(), axis, before ? .pane(newID) : self, before ? self : .pane(newID)) : self
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
    var id = UUID()
    private var storedName: String
    var usesDirectoryName = false
    var name: String {
        get {
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

    init(name: String, directory: String, usesDirectoryName: Bool = false) {
        self.init(name: name, tab: TerminalTab(directory: directory), usesDirectoryName: usesDirectoryName)
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
    var numberedShortcutCount: Int { usesPaneShortcuts ? min(4, numberedPaneIDs.count) : min(9, numberedTabIDs.count) }

    func tabShortcutNumber(for id: UUID) -> Int? {
        guard !usesPaneShortcuts, let index = numberedTabIDs.firstIndex(of: id), index < 9 else { return nil }
        return index + 1
    }

    enum TabShortcut: Equatable { case number(Int), next, previous }

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

    /// Native panes and window groups have stable numbers regardless of which tab is selected
    /// inside them. An ungrouped structured space is one pane.
    var numberedPaneIDs: [UUID] {
        let fractions = splitFractions.merging(splitRatios.mapValues { CGFloat($0) }) { _, local in local }
        if !containers.isEmpty { return presentation?.layout.paneIDsInReadingOrder(fractions: fractions) ?? [id] }
        return layout.paneIDsInReadingOrder(fractions: fractions)
    }

    func paneShortcutNumber(for id: UUID) -> Int? {
        guard let index = numberedPaneIDs.firstIndex(of: id), index < 4 else { return nil }
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

    func displayLabel(automatic: Bool, conversation: String?, focused: TerminalTab? = nil) -> String {
        guard automatic, renamed != true else { return name }
        if let conversation = TerminalTab.conversationLabel(conversation) { return conversation }
        guard numbered == true, let pane = focused ?? focusedTerminal else { return name }
        let label = pane.displayLabel(automatic: true, conversation: nil)
        return label.isEmpty ? name : label
    }

    /// The node that moves this window: its only terminal (every multiplexer moves a lone pane with its
    /// window; herdr places panes only), else the window itself.
    var placeable: UInt64 { terminals.count == 1 ? terminals[0].terminal ?? node : node }
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
            return Group(id: UUID(), windows: members, selected: members.contains(selected) ? selected : members[0])
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
            let destination = groups.firstIndex { $0.windows.contains(where: { $0 == selected }) } ?? 0
            groups[destination].windows += windows.filter { !known.contains($0) }
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
            let added = Group(id: UUID(), windows: [window], selected: window)
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
        case .columns: .split(UUID(), .columns, .pane(ids[0]), .pane(ids[1]))
        case .rows: .split(UUID(), .rows, .pane(ids[0]), .pane(ids[1]))
        case .twoAbove: .split(UUID(), .rows,
            .split(UUID(), .columns, .pane(ids[0]), .pane(ids[1])), .pane(ids[2]))
        case .grid: .split(UUID(), .rows,
            .split(UUID(), .columns, .pane(ids[0]), .pane(ids[1])),
            .split(UUID(), .columns, .pane(ids[2]), .pane(ids[3])))
        }
    }
}
