import CoreGraphics
import Foundation

/// The iPad detail column's panes (docs/ios.md, iPad › Panes): the Mac's split panes, each showing one tab with its own
/// strip and its own stack. A tree of splits across (`columns`, Split Right) or down (`rows`, Split Down), at most
/// `limit` panes. The focused pane's tab and what is pushed over it are the navigator's path (`SpacesNavigator.
/// splitPath`), so everything that acts on "the shown tab" acts on the focused pane; the other panes keep their tab and
/// their pushed screens here until they are focused. One pane (`single`) is the column without splits.
struct PadPanes: Equatable {
    typealias ID = Int

    enum Axis: String, Codable, Sendable {
        /// Side by side (Split Right).
        case columns
        /// One above the other (Split Down).
        case rows
    }

    /// A pane. The focused one's `tab` and `detail` are the path's and stay empty here.
    struct Leaf: Equatable {
        let id: ID
        var tab: TabRef?
        var detail: [TabsRoute] = []
        /// Its tab's strip as last seen, for the neighbour that takes the pane when the host closes the tab.
        var strip: [TabRef] = []
    }

    indirect enum Node: Equatable {
        case leaf(Leaf)
        /// Children in reading order and the share of the split each takes (summing to 1).
        case split(Axis, [Node], [CGFloat])
    }

    /// The most panes a column holds, as the Mac's ⌘D splits up to four.
    static let limit = 4
    /// A pane is never split below this: the tab still lays out as on a phone (`MobileSplit.padNarrowestTab`) and its
    /// strip keeps the selected pill, "+" and the mode button; a pane under 280 points tall has a few rows of terminal.
    static let minimum = CGSize(width: MobileSplit.padNarrowestTab, height: 280)
    /// What a divider's drag leaves either side at the least.
    static let dragMinimum = CGSize(width: 240, height: 160)
    /// The hairline between panes.
    static let divider: CGFloat = 0.5

    private(set) var root: Node
    private(set) var focused: ID
    private var nextID: ID

    /// The column without splits: one pane, focused.
    static let single = PadPanes(root: .leaf(Leaf(id: 0)), focused: 0, nextID: 1)

    var leaves: [Leaf] { Self.leaves(root) }
    var count: Int { leaves.count }
    var isSplit: Bool { count > 1 }

    func leaf(_ id: ID) -> Leaf? { leaves.first { $0.id == id } }

    /// The pane (not the focused one) that shows `tab`.
    func pane(showing tab: TabRef) -> ID? { leaves.first { $0.id != focused && $0.tab == tab }?.id }

    /// The tabs the other panes show.
    var otherTabs: [TabRef] { leaves.filter { $0.id != focused }.compactMap(\.tab) }

    // MARK: Changes

    /// `id`'s pane split along `axis`: the new pane, after it, takes half its share and the focus. The pane that was
    /// focused keeps `tab` and `detail` (the path's until now). Nil when `id` is not a pane or the column is full.
    mutating func split(_ id: ID, axis: Axis, keeping tab: TabRef?, detail: [TabsRoute]) -> ID? {
        guard count < Self.limit, leaf(id) != nil else { return nil }
        let new = nextID
        nextID += 1
        if id == focused { update(id) { $0.tab = tab; $0.detail = detail } }
        root = Self.split(root, id, axis: axis, new: Leaf(id: new))
        focused = new
        return new
    }

    /// Focus moves to `id`: the pane focused until now keeps `tab` and `detail`; `id`'s come back out (to go on the
    /// path). Nil when `id` is not a pane.
    mutating func focus(_ id: ID, leaving tab: TabRef?, detail: [TabsRoute]) -> (tab: TabRef?, detail: [TabsRoute])? {
        guard id != focused, let target = leaf(id) else { return nil }
        update(focused) { $0.tab = tab; $0.detail = detail }
        update(id) { $0.tab = nil; $0.detail = [] }
        focused = id
        return (target.tab, target.detail)
    }

    /// `id`'s pane goes; its share goes to the pane before it, else the one after. When the focused one goes, focus
    /// moves to the pane that took its place (the next in reading order, else the one before), whose tab and detail
    /// come back out. False when it is the last pane.
    @discardableResult
    mutating func remove(_ id: ID) -> Bool {
        let order = leaves.map(\.id)
        guard order.count > 1, let index = order.firstIndex(of: id) else { return false }
        root = Self.removing(id, from: root) ?? root
        if id == focused { focused = index + 1 < order.count ? order[index + 1] : order[index - 1] }
        return true
    }

    /// The focused pane's tab and detail, taken out to go on the path.
    mutating func takeFocused() -> (tab: TabRef?, detail: [TabsRoute]) {
        let leaf = leaf(focused)
        update(focused) { $0.tab = nil; $0.detail = [] }
        return (leaf?.tab, leaf?.detail ?? [])
    }

    /// Merge Panes, as the Mac's: the innermost split around the focused pane becomes that pane alone (the tabs the
    /// others showed stay in their strips). The panes that went.
    @discardableResult
    mutating func merge() -> [ID] {
        let before = Set(leaves.map(\.id))
        root = Self.merging(focused, in: root) ?? root
        return Array(before.subtracting(leaves.map(\.id)))
    }

    mutating func update(_ id: ID, _ change: (inout Leaf) -> Void) { root = Self.updating(id, in: root, change) }

    /// The shares of the split at `path` (child indices from the root).
    mutating func setShares(_ shares: [CGFloat], at path: [Int]) { root = Self.setting(shares, at: path, in: root) }

    // MARK: Geometry

    struct Divider: Equatable {
        /// The split's place in the tree (child indices from the root) and the boundary after child `index`.
        let path: [Int]
        let index: Int
        let axis: Axis
        /// The hairline.
        let frame: CGRect
        /// The split's whole rect and its shares, to turn a drag into shares.
        let span: CGRect
        let shares: [CGFloat]
    }

    struct Layout: Equatable {
        var panes: [ID: CGRect] = [:]
        var dividers: [Divider] = []
    }

    /// Every pane's frame and every divider in `rect`, the hairlines between the panes taking `divider` each.
    func layout(in rect: CGRect) -> Layout {
        var layout = Layout()
        Self.lay(root, in: rect, path: [], into: &layout)
        return layout
    }

    /// Whether `id`'s pane (in a column of `size`) can split along `axis`: the column is not full and both halves keep
    /// `minimum`.
    func canSplit(_ id: ID, axis: Axis, in size: CGSize) -> Bool {
        guard count < Self.limit, let frame = layout(in: CGRect(origin: .zero, size: size)).panes[id] else { return false }
        switch axis {
        case .columns: return (frame.width - Self.divider) / 2 >= Self.minimum.width && frame.height >= Self.minimum.height
        case .rows: return (frame.height - Self.divider) / 2 >= Self.minimum.height && frame.width >= Self.minimum.width
        }
    }

    /// The shares after dragging the boundary after child `index` to `position` (along the axis, in the split's
    /// space): only the two panes either side change, each kept at `dragMinimum`.
    static func dragged(_ divider: Divider, to position: CGFloat) -> [CGFloat] {
        let length = divider.axis == .columns ? divider.span.width : divider.span.height
        let gaps = divider.divider * CGFloat(divider.shares.count - 1)
        let room = length - gaps
        guard room > 0 else { return divider.shares }
        let origin = divider.axis == .columns ? divider.span.minX : divider.span.minY
        let start = origin + divider.shares[..<divider.index].reduce(0, +) * room + divider.divider * CGFloat(divider.index)
        let pair = (divider.shares[divider.index] + divider.shares[divider.index + 1]) * room
        let least = min(divider.axis == .columns ? dragMinimum.width : dragMinimum.height, pair / 2)
        let first = min(max(position - start, least), pair - least)
        var shares = divider.shares
        shares[divider.index] = first / room
        shares[divider.index + 1] = (pair - first) / room
        return shares
    }

    // MARK: Layouts

    /// The layout the panes have when it is a preset's (the picker's checkmark and icon); nil for any other tree.
    var preset: PadLayout? { PadLayout.allCases.first { $0.matches(root) } }

    /// The same tree with every split's shares even (choosing the layout already shown, as the Mac's picker does).
    mutating func even() { root = Self.evened(root) }

    /// `layout`'s panes in `rect`, the tabs placed as the Mac's presets place them (`LayoutPreset.arrange`): each pane now
    /// goes into the new pane it overlaps most (the focused one first, ties to the earlier in reading order); one with
    /// no free pane to overlap takes a free one left after; panes still empty take `spare` (the space's tabs no pane
    /// shows, in strip order). A pane keeps its id, and so its view, with its tab. The focused pane stays focused, its
    /// tab and detail the path's (`focused`). Nil without tabs enough for every pane.
    func arranged(_ layout: PadLayout, focused shown: (tab: TabRef, detail: [TabsRoute]), spare: [TabRef],
                  in rect: CGRect) -> PadPanes? {
        let old = self.layout(in: rect).panes
        let reading = leaves.map { leaf in
            leaf.id == focused ? Leaf(id: leaf.id, tab: shown.tab, detail: shown.detail, strip: leaf.strip) : leaf
        }.filter { $0.tab != nil }
        let priority = reading.filter { $0.id == focused } + reading.filter { $0.id != focused }
        let slots = layout.frames(in: rect)
        func overlap(_ leaf: Leaf, _ slot: Int) -> CGFloat {
            guard let frame = old[leaf.id] else { return 0 }
            let shared = frame.intersection(slots[slot])
            return shared.isNull ? 0 : shared.width * shared.height
        }
        var placed = [Leaf?](repeating: nil, count: slots.count)
        var waiting: [Leaf] = []
        for leaf in priority {
            let free = placed.indices.filter { placed[$0] == nil && overlap(leaf, $0) > 0.5 }
            if let slot = free.max(by: { a, b in
                let x = overlap(leaf, a), y = overlap(leaf, b)
                // Whole-point panes overlap a hair unevenly: within a hundredth, a tie, the earlier pane taking it.
                return abs(x - y) <= 0.01 * max(x, y) ? a > b : x < y
            }) {
                placed[slot] = leaf
            } else {
                waiting.append(leaf)
            }
        }
        // Panes that found no place they overlap, in reading order, before the space's other tabs.
        for leaf in reading where waiting.contains(where: { $0.id == leaf.id }) {
            if let slot = placed.firstIndex(where: { $0 == nil }) { placed[slot] = leaf }
        }
        var next = nextID
        var spare = spare.filter { tab in !reading.contains { $0.tab == tab } }[...]
        for slot in placed.indices where placed[slot] == nil {
            guard let tab = spare.popFirst() else { return nil }
            placed[slot] = Leaf(id: next, tab: tab)
            next += 1
        }
        let leaves = placed.compactMap { $0 }
        guard let focusedLeaf = leaves.first(where: { $0.id == focused }) else { return nil }
        var panes = PadPanes(root: layout.shape(leaves.map { leaf in
            leaf.id == focusedLeaf.id ? Leaf(id: leaf.id, strip: leaf.strip) : leaf
        }), focused: focused, nextID: next)
        panes.even()
        return panes
    }

    // MARK: Memory

    /// What a launch brings back (`SpacesNavigator.rememberSplit`): the tree with the other panes' tabs (nil for the
    /// focused pane's, which is the remembered shown tab).
    indirect enum Kept: Codable, Equatable {
        case leaf(TabRef?)
        case split(Axis, [Kept], [Double])
    }

    var kept: Kept { Self.kept(root, focused: focused) }

    /// The panes `kept` describes, the tabs `exists` no longer finds left out; nil when one pane or none is left.
    init?(kept: Kept, exists: (TabRef) -> Bool) {
        var next = 0
        var focused: ID?
        func build(_ kept: Kept) -> Node? {
            switch kept {
            case .leaf(let tab):
                if let tab, !exists(tab) { return nil }
                if tab == nil, focused != nil { return nil }
                let id = next
                next += 1
                if tab == nil { focused = id }
                return .leaf(Leaf(id: id, tab: tab))
            case .split(let axis, let children, let shares):
                let built = zip(children, shares).compactMap { child, share in build(child).map { ($0, CGFloat(share)) } }
                if built.isEmpty { return nil }
                if built.count == 1 { return built[0].0 }
                let total = built.map(\.1).reduce(0, +)
                return .split(axis, built.map(\.0), built.map { total > 0 ? $0.1 / total : 1 / CGFloat(built.count) })
            }
        }
        guard let root = build(kept), let focused, Self.leaves(root).count > 1 else { return nil }
        self.init(root: root, focused: focused, nextID: next)
    }

    private init(root: Node, focused: ID, nextID: ID) {
        self.root = root
        self.focused = focused
        self.nextID = nextID
    }

    // MARK: Tree

    private static func leaves(_ node: Node) -> [Leaf] {
        switch node {
        case .leaf(let leaf): [leaf]
        case .split(_, let children, _): children.flatMap(leaves)
        }
    }

    private static func contains(_ node: Node, _ id: ID) -> Bool { leaves(node).contains { $0.id == id } }

    private static func split(_ node: Node, _ id: ID, axis: Axis, new: Leaf) -> Node {
        switch node {
        case .leaf(let leaf):
            return leaf.id == id ? .split(axis, [node, .leaf(new)], [0.5, 0.5]) : node
        case .split(let along, var children, var shares):
            // Along the same axis the new pane joins this split, halving the pane's share, as iTerm's and Ghostty's
            // splits do; across it, the pane becomes a split of its own.
            if along == axis, let index = children.firstIndex(where: { if case .leaf(let leaf) = $0 { leaf.id == id } else { false } }) {
                let half = shares[index] / 2
                shares[index] = half
                children.insert(.leaf(new), at: index + 1)
                shares.insert(half, at: index + 1)
                return .split(along, children, shares)
            }
            return .split(along, children.map { split($0, id, axis: axis, new: new) }, shares)
        }
    }

    private static func removing(_ id: ID, from node: Node) -> Node? {
        switch node {
        case .leaf(let leaf):
            return leaf.id == id ? nil : node
        case .split(let axis, let children, var shares):
            var kept: [Node] = []
            var keptShares: [CGFloat] = []
            for (index, child) in children.enumerated() {
                if let child = removing(id, from: child) {
                    kept.append(child)
                    keptShares.append(shares[index])
                } else if !keptShares.isEmpty {
                    keptShares[keptShares.count - 1] += shares[index]
                } else if index + 1 < shares.count {
                    shares[index + 1] += shares[index]
                }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0] }
            return flattened(.split(axis, kept, keptShares))
        }
    }

    /// A child split along its parent's axis joins the parent (after a removal left one).
    private static func flattened(_ node: Node) -> Node {
        guard case .split(let axis, let children, let shares) = node else { return node }
        var flat: [Node] = []
        var flatShares: [CGFloat] = []
        for (child, share) in zip(children, shares) {
            if case .split(let inner, let grand, let innerShares) = child, inner == axis {
                flat.append(contentsOf: grand)
                flatShares.append(contentsOf: innerShares.map { $0 * share })
            } else {
                flat.append(child)
                flatShares.append(share)
            }
        }
        return .split(axis, flat, flatShares)
    }

    private static func merging(_ id: ID, in node: Node) -> Node? {
        guard case .split(let axis, let children, let shares) = node else { return nil }
        if children.contains(where: { if case .leaf(let leaf) = $0 { leaf.id == id } else { false } }) {
            return leaves(node).first { $0.id == id }.map { .leaf($0) }
        }
        return .split(axis, children.map { child in contains(child, id) ? merging(id, in: child) ?? child : child }, shares)
    }

    private static func updating(_ id: ID, in node: Node, _ change: (inout Leaf) -> Void) -> Node {
        switch node {
        case .leaf(var leaf):
            guard leaf.id == id else { return node }
            change(&leaf)
            return .leaf(leaf)
        case .split(let axis, let children, let shares):
            return .split(axis, children.map { updating(id, in: $0, change) }, shares)
        }
    }

    private static func evened(_ node: Node) -> Node {
        guard case .split(let axis, let children, _) = node else { return node }
        return .split(axis, children.map(evened), children.map { _ in 1 / CGFloat(children.count) })
    }

    private static func setting(_ new: [CGFloat], at path: [Int], in node: Node) -> Node {
        guard case .split(let axis, var children, let shares) = node else { return node }
        guard let first = path.first else { return new.count == shares.count ? .split(axis, children, new) : node }
        guard children.indices.contains(first) else { return node }
        children[first] = setting(new, at: Array(path.dropFirst()), in: children[first])
        return .split(axis, children, shares)
    }

    private static func lay(_ node: Node, in rect: CGRect, path: [Int], into layout: inout Layout) {
        switch node {
        case .leaf(let leaf):
            layout.panes[leaf.id] = rect
        case .split(let axis, let children, let shares):
            let length = axis == .columns ? rect.width : rect.height
            let room = max(0, length - divider * CGFloat(children.count - 1))
            var offset = axis == .columns ? rect.minX : rect.minY
            for (index, child) in children.enumerated() {
                // Whole points, the last pane taking what is left, so no hairline lands between two pixels.
                let size = index == children.count - 1
                    ? (axis == .columns ? rect.maxX : rect.maxY) - offset
                    : (shares[index] * room).rounded()
                let frame = axis == .columns
                    ? CGRect(x: offset, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: offset, width: rect.width, height: size)
                lay(child, in: frame, path: path + [index], into: &layout)
                offset += size
                if index < children.count - 1 {
                    let line = axis == .columns
                        ? CGRect(x: offset, y: rect.minY, width: divider, height: rect.height)
                        : CGRect(x: rect.minX, y: offset, width: rect.width, height: divider)
                    layout.dividers.append(Divider(path: path, index: index, axis: axis, frame: line, span: rect, shares: shares))
                    offset += divider
                }
            }
        }
    }

    private static func kept(_ node: Node, focused: ID) -> Kept {
        switch node {
        case .leaf(let leaf): .leaf(leaf.id == focused ? nil : leaf.tab)
        case .split(let axis, let children, let shares): .split(axis, children.map { kept($0, focused: focused) }, shares.map(Double.init))
        }
    }
}

/// The Mac's layout presets that fit the iPad's four panes (`LayoutPreset`: the same names and shapes), which the
/// layout button, the mode button's menu and the View menu offer (`SpacesNavigator.applyLayout`).
enum PadLayout: String, CaseIterable, Identifiable {
    case single, columns, rows, twoAbove, grid

    var id: Self { self }

    /// Its panes.
    var count: Int {
        switch self {
        case .single: 1
        case .columns, .rows: 2
        case .twoAbove: 3
        case .grid: 4
        }
    }

    /// The Mac's names (`LayoutPreset.title`).
    var title: String {
        switch self {
        case .single: "Single"
        case .columns: "Side by Side"
        case .rows: "Stacked"
        case .twoAbove: "Two Above One"
        case .grid: "Grid"
        }
    }

    /// Its glyph; Two Above One has no symbol of its own (`PadLayoutIcon` draws it).
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .columns: "rectangle.split.2x1"
        case .rows, .twoAbove: "rectangle.split.1x2"
        case .grid: "square.split.2x2"
        }
    }

    /// Its tree over `leaves` in reading order (the Mac's: a grid is two rows of two, two above one a row of two over
    /// one), the shares even.
    func shape(_ leaves: [PadPanes.Leaf]) -> PadPanes.Node {
        let nodes = leaves.map { PadPanes.Node.leaf($0) }
        let half: [CGFloat] = [0.5, 0.5]
        switch self {
        case .single: return nodes[0]
        case .columns: return .split(.columns, nodes, half)
        case .rows: return .split(.rows, nodes, half)
        case .twoAbove: return .split(.rows, [.split(.columns, Array(nodes[0..<2]), half), nodes[2]], half)
        case .grid:
            return .split(.rows, [.split(.columns, Array(nodes[0..<2]), half), .split(.columns, Array(nodes[2..<4]), half)], half)
        }
    }

    /// Its panes' frames in `rect`, in reading order.
    func frames(in rect: CGRect) -> [CGRect] {
        let leaves = (0..<count).map { PadPanes.Leaf(id: $0) }
        guard let panes = PadPanes(root: shape(leaves)) else { return [rect] }
        let layout = panes.layout(in: rect)
        return (0..<count).compactMap { layout.panes[$0] }
    }

    /// Every pane keeps the least a pane needs (`PadPanes.minimum`) in `size`.
    func fits(_ size: CGSize) -> Bool {
        frames(in: CGRect(origin: .zero, size: size)).allSatisfy {
            $0.width >= PadPanes.minimum.width && $0.height >= PadPanes.minimum.height
        }
    }

    /// Whether `node` is this layout's tree (a grid split down then across, as ⌘D then ⇧⌘D in each half makes it, is a
    /// grid too).
    func matches(_ node: PadPanes.Node) -> Bool {
        func leaves(_ node: PadPanes.Node, _ count: Int) -> Bool {
            if case .leaf = node { return count == 1 }
            guard case .split(_, let children, _) = node, children.count == count else { return false }
            return children.allSatisfy { if case .leaf = $0 { true } else { false } }
        }
        switch (self, node) {
        case (.single, .leaf): return true
        case (.columns, .split(.columns, _, _)), (.rows, .split(.rows, _, _)): return leaves(node, 2)
        case (.twoAbove, .split(.rows, let children, _)):
            guard children.count == 2, case .split(.columns, _, _) = children[0] else { return false }
            return leaves(children[0], 2) && leaves(children[1], 1)
        case (.grid, .split(let axis, let children, _)):
            return children.count == 2 && children.allSatisfy { child in
                if case .split(let inner, _, _) = child { inner != axis && leaves(child, 2) } else { false }
            }
        default: return false
        }
    }
}

private extension PadPanes {
    /// A tree's panes with no focus or memory to speak of (`PadLayout.frames`).
    init?(root: Node) {
        guard let first = Self.leaves(root).first else { return nil }
        self.init(root: root, focused: first.id, nextID: Self.leaves(root).count)
    }
}

private extension PadPanes.Divider {
    var divider: CGFloat { PadPanes.divider }
}
