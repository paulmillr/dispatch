import AppKit
import SwiftUI

/// The list's column geometry, shared by the outline and the SwiftUI column header above it so the two line up
/// (`1fr 64px 72px`, 14 pt in from the leading edge, 12 pt from the trailing).
enum FilesColumns {
    static let leading: CGFloat = 14
    static let trailing: CGFloat = 12
    static func modified(_ typography: AppTypography) -> CGFloat { typography.expanded(64) }
    static func size(_ typography: AppTypography) -> CGFloat { typography.expanded(72) }
    /// The names' room before a narrow list gives up a column for them.
    static func nameMinimum(_ typography: AppTypography) -> CGFloat { typography.expanded(220) }

    /// The columns a list `width` wide shows beside the names, which keep `name` at least: Size goes first, then
    /// Modified.
    static func shown(width: CGFloat, name: CGFloat, modified: CGFloat, size: CGFloat) -> (modified: Bool, size: Bool) {
        let room = width - leading - trailing - name
        return (modified: room >= modified, size: room >= modified + size)
    }

    @MainActor static func shown(width: CGFloat, typography: AppTypography) -> (modified: Bool, size: Bool) {
        shown(width: width, name: nameMinimum(typography), modified: modified(typography), size: size(typography))
    }
    static func rowHeight(_ typography: AppTypography) -> CGFloat { typography.expanded(24) }
    /// The list's column header and the preview's header, side by side: one height above their 1 pt rules.
    static func headerHeight(_ typography: AppTypography) -> CGFloat { max(40, typography.expanded(34)).rounded() }
    /// `.d1`, `.d2`: each level 20 pt further in.
    static func indent(_ typography: AppTypography) -> CGFloat { typography.expanded(20) }
}

/// Fonts and inks of the outline, resolved once per theme or text size change; the cells only read them.
struct FilesOutlineStyle: Equatable {
    var nameFont: NSFont
    var metaFont: NSFont
    /// Names (#c9c9ce), selected names (#ececf0), icons (#8f8f98).
    var text: NSColor
    var selectedText: NSColor
    var icon: NSColor
    /// Modified and size (#6f6f78), and on a selected row (#9a9aa2).
    var meta: NSColor
    var selectedMeta: NSColor
    /// Placeholders (#5c5c64).
    var dim: NSColor
    var wash: NSColor
    var accent: NSColor
    var warning: NSColor
    var rowHeight: CGFloat
    var modifiedWidth: CGFloat
    var sizeWidth: CGFloat
    /// What the names keep before Size, then Modified, give way (`FilesColumns.shown`).
    var nameMinimum: CGFloat
    var indent: CGFloat
    var iconSize: CGFloat

    @MainActor init(typography: AppTypography) {
        let palette = Chrome.palette
        nameFont = AppFont.native(size: typography.size())
        metaFont = AppFont.native(size: typography.size(offset: -1.5))
        text = NSColor(palette.secondary)
        selectedText = NSColor(palette.ink)
        icon = NSColor(palette.muted)
        meta = NSColor(palette.sidebarDetail)
        selectedMeta = NSColor(palette.sidebarHostLabel)
        dim = NSColor(palette.detail)
        // The mockup's `.sel`: the ink at 8 %, on any palette.
        wash = NSColor(palette.ink).withAlphaComponent(0.08)
        accent = NSColor(palette.accent)
        warning = NSColor(palette.warning)
        rowHeight = FilesColumns.rowHeight(typography)
        modifiedWidth = FilesColumns.modified(typography)
        sizeWidth = FilesColumns.size(typography)
        nameMinimum = FilesColumns.nameMinimum(typography)
        indent = FilesColumns.indent(typography)
        iconSize = typography.expanded(14)
    }

    @MainActor private static var cache: (key: CacheKey, style: FilesOutlineStyle)?

    private struct CacheKey: Equatable {
        let typography: AppTypography
        let theme: SidebarTheme
    }

    /// The style for this text size and the app theme, made again only when one of them changes: the list's body runs
    /// on every refresh, and resolving fonts and colours each time is wasted work.
    @MainActor static func cached(typography: AppTypography) -> FilesOutlineStyle {
        let key = CacheKey(typography: typography, theme: SidebarThemeStore.shared.current)
        if let cache, cache.key == key { return cache.style }
        let style = FilesOutlineStyle(typography: typography)
        cache = (key, style)
        return style
    }
}

/// The Finder-style list: name, modified, size; folders expand in place (F2a). Backed by an `NSOutlineView`
/// for keyboard navigation, type-select, selection, 10,000-row scrolling and the drag-and-drop hooks of
/// `FilesDragDelegate`.
struct FilesOutline: View {
    let session: FilesSession
    let rows: [FilesRow]
    let root: String
    var settingHidden = false
    /// The tab's pane has the focus: only then does the list take the keyboard for a focus request.
    var focused = true
    /// The rows again, now: expanding a folder needs its rows before the outline asks for them, not a frame later.
    var rebuild: @MainActor () -> [FilesRow] = { [] }
    @Environment(\.appTypography) private var typography

    var body: some View {
        let files = TerminalRuntime.shared.files
        let drag = files.dragDelegate.flatMap { $0.dragEnabled ? $0 : nil }
        FilesOutlineTable(session: session, rows: rows, root: FilesPath.normalized(root), settingHidden: settingHidden,
                          selection: session.selection, focusRequest: focused ? session.focusRequest : nil, drag: drag,
                          style: FilesOutlineStyle.cached(typography: typography), rebuild: rebuild)
    }
}

private struct FilesOutlineTable: NSViewRepresentable {
    let session: FilesSession
    let rows: [FilesRow]
    let root: String
    let settingHidden: Bool
    /// Read here so a selection set elsewhere (⌘↑ selecting the folder it came from) reaches the outline.
    let selection: Set<String>
    let focusRequest: UUID?
    let drag: (any FilesDragDelegate)?
    let style: FilesOutlineStyle
    let rebuild: @MainActor () -> [FilesRow]

    func makeCoordinator() -> FilesOutlineController { FilesOutlineController() }

    func makeNSView(context: Context) -> FilesOutlineContainer {
        FilesOutlineContainer(controller: context.coordinator)
    }

    func updateNSView(_ view: FilesOutlineContainer, context: Context) {
        context.coordinator.update(configuration)
    }

    static func dismantleNSView(_ view: FilesOutlineContainer, coordinator: FilesOutlineController) {
        coordinator.dismantle()
    }

    private var configuration: FilesOutlineController.Configuration {
        .init(session: session, rows: rows, root: root, settingHidden: settingHidden, focusRequest: focusRequest,
              drag: drag, style: style, rebuild: rebuild)
    }
}

/// The outline's scroll view, with the ring a drop onto the root (empty space) draws around the whole list.
final class FilesOutlineContainer: NSView {
    let scrollView = NSScrollView()
    let outline = FilesOutlineView()
    fileprivate let ring = FilesDropRing()

    init(controller: FilesOutlineController) {
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = outline
        addSubview(scrollView)
        ring.isHidden = true
        addSubview(ring)
        controller.attach(outline, container: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        ring.frame = bounds.insetBy(dx: 1, dy: 1)
    }
}

/// Drawn over the list, never hit: drags and clicks reach the outline under it.
fileprivate final class FilesDropRing: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderWidth = 1.5
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ visible: Bool, style: FilesOutlineStyle?) {
        guard let style else { return }
        layer?.borderColor = style.accent.cgColor
        layer?.backgroundColor = style.accent.withAlphaComponent(0.05).cgColor
        isHidden = !visible
    }
}

/// The table itself: the files keys of F5b, copy and paste, and its own indentation (the mockup's 14 pt in and
/// 20 pt per level).
final class FilesOutlineView: NSOutlineView {
    fileprivate weak var controller: FilesOutlineController?
    /// The disclosure triangle's slot ahead of a name, `.ch` 10 pt and its 7 pt gap.
    var disclosureWidth: CGFloat = 17

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.tookFocus() }
        return became
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.windowChanged()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.fitColumns()
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        let x = FilesColumns.leading - 3 + CGFloat(level(forRow: row)) * indentationPerLevel
        return NSRect(x: x, y: frame.minY, width: frame.width, height: frame.height)
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let frame = super.frameOfCell(atColumn: column, row: row)
        guard column == 0, row >= 0 else { return frame }
        let columnRect = rect(ofColumn: column)
        let x = FilesColumns.leading + CGFloat(level(forRow: row)) * indentationPerLevel + disclosureWidth
        return NSRect(x: x, y: frame.minY, width: max(0, columnRect.maxX - x), height: frame.height)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, event.keyCode == 36 || event.keyCode == 76 {
            controller?.openSelection()
            return
        }
        super.keyDown(with: event)
    }

    /// The files keys win over the menus' while the list has focus: ⌘↑ / ⌘↓ / ⌘O / ⌥⌘C / ⌘R / ⇧⌘. / ⌘F.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let controller else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch flags {
        case [.command] where event.keyCode == 126: controller.showEnclosingFolder()
        case [.command] where event.keyCode == 125: controller.openSelection()
        case [.command] where key == "o": controller.openInEditor()
        case [.command] where key == "r": controller.refresh()
        case [.command] where key == "f": controller.find()
        case [.command, .option] where event.keyCode == 8: controller.copyPaths()
        case [.command, .shift] where event.keyCode == 47: controller.toggleHidden()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    @objc func copy(_ sender: Any?) { controller?.copyPaths() }
    @objc func paste(_ sender: Any?) { controller?.paste() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return controller?.hasSelection == true
        case #selector(paste(_:)): return true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // A drag that leaves or ends without a drop takes its ring and wash with it.
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        controller?.clearDropTarget()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
        controller?.clearDropTarget()
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        super.concludeDragOperation(sender)
        controller?.clearDropTarget()
    }
}

/// Keeps the `NSOutlineView` in step with the session's rows. Rows are diffed by path, folder by folder, so a refresh
/// every 2 s moves, adds and removes only what changed: no reload, no flash, expansion and selection kept.
@MainActor final class FilesOutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    struct Configuration {
        var session: FilesSession
        var rows: [FilesRow]
        var root: String
        var settingHidden: Bool
        var focusRequest: UUID?
        var drag: (any FilesDragDelegate)?
        var style: FilesOutlineStyle
        var rebuild: @MainActor () -> [FilesRow]
    }

    final class Node: NSObject {
        let id: String
        var row: FilesRow
        init(_ row: FilesRow) {
            id = row.id
            self.row = row
        }
    }

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let modifiedColumn = NSUserInterfaceItemIdentifier("modified")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")
    /// The drop target meaning the root: empty space under the rows.
    private static let rootTarget = "\u{0}root"
    /// The focus request each tab's outline last took, so a list that mounts again (a mode switch, a split) does not
    /// take focus for a request it already answered.
    private static var answeredFocus: [UUID: UUID] = [:]

    /// The tab closed: its answered request goes with it.
    static func forget(_ tab: UUID) { answeredFocus[tab] = nil }

    private var configuration: Configuration?
    private weak var outline: FilesOutlineView?
    private weak var container: FilesOutlineContainer?
    private var nodes: [String: Node] = [:]
    private var children: [String: [String]] = [:]
    private var root: String?
    private var rows: [FilesRow] = []
    private var style: FilesOutlineStyle?
    /// Set while the controller itself changes the outline, so its notifications are not taken for the user's.
    private var applying = false
    private var pendingFocus = false
    private var dragged: [String] = []
    private var dragSource: (any FilesDragDelegate)?
    private var dropTarget: String?
    private var registeredTypes: [NSPasteboard.PasteboardType] = []
    private let menu = NSMenu()

    private var session: FilesSession? { configuration?.session }

    func attach(_ outline: FilesOutlineView, container: FilesOutlineContainer) {
        self.outline = outline
        self.container = container
        outline.controller = self
        outline.headerView = nil
        outline.style = .plain
        // `.default` takes the system's row height for the style; the mockup's rows are 24 pt.
        outline.rowSizeStyle = .custom
        outline.backgroundColor = .clear
        outline.usesAlternatingRowBackgroundColors = false
        outline.gridStyleMask = []
        outline.intercellSpacing = .zero
        outline.focusRingType = .none
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true
        outline.autoresizesOutlineColumn = false
        outline.indentationMarkerFollowsCell = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.selectionHighlightStyle = .regular
        // The ring and wash are drawn by the row views; AppKit's drop highlight is not the mockup's.
        outline.draggingDestinationFeedbackStyle = .none
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setAccessibilityIdentifier("files-outline")
        outline.setAccessibilityLabel("Files")
        for (identifier, title) in [(Self.nameColumn, "Name"), (Self.modifiedColumn, "Modified"), (Self.sizeColumn, "Size")] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.resizingMask = identifier == Self.nameColumn ? .autoresizingMask : []
            column.isEditable = false
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked(_:))
        menu.delegate = self
        menu.autoenablesItems = false
        outline.menu = menu
    }

    /// Hides Size, then Modified, when the list is too narrow to keep the names readable beside them.
    func fitColumns() {
        guard let outline, let style, let width = outline.enclosingScrollView?.contentSize.width, width > 0 else { return }
        let shown = FilesColumns.shown(width: width, name: style.nameMinimum, modified: style.modifiedWidth,
                                       size: style.sizeWidth)
        for column in outline.tableColumns {
            let hidden = switch column.identifier {
            case Self.modifiedColumn: !shown.modified
            case Self.sizeColumn: !shown.size
            default: false
            }
            if column.isHidden != hidden { column.isHidden = hidden }
        }
    }

    func dismantle() {
        outline?.dataSource = nil
        outline?.delegate = nil
        outline?.controller = nil
        configuration = nil
    }

    /// Configurations SwiftUI has pushed. A divider drag must push none (`FilesView` keeps its list column equatable):
    /// each would compare 10,000 rows on every move.
    private(set) var updates = 0

    func update(_ configuration: Configuration) {
        updates += 1
        self.configuration = configuration
        guard let outline else { return }
        let restyled = style != configuration.style
        if restyled {
            let style = configuration.style
            self.style = style
            outline.rowHeight = style.rowHeight
            outline.indentationPerLevel = style.indent
            outline.disclosureWidth = style.indent - 3
            for column in outline.tableColumns {
                switch column.identifier {
                case Self.modifiedColumn:
                    column.minWidth = style.modifiedWidth; column.maxWidth = style.modifiedWidth; column.width = style.modifiedWidth
                case Self.sizeColumn:
                    let width = style.sizeWidth + FilesColumns.trailing
                    column.minWidth = width; column.maxWidth = width; column.width = width
                default:
                    column.minWidth = 80
                }
            }
        }
        if restyled { fitColumns() }
        // The same filter and hidden setting: rows that come or go are the folder's own changes, which may animate. A
        // filter typed or hidden files shown changes the listing at once.
        let listing = (filter: configuration.session.filter, hidden: configuration.settingHidden)
        let refresh = shownListing.map { $0 == listing } ?? false
        shownListing = listing
        apply(configuration.rows, root: configuration.root, reload: restyled, refresh: refresh)
        syncSelection()
        syncDrag(configuration.drag)
        if let request = configuration.focusRequest, Self.answeredFocus[configuration.session.id] != request {
            Self.answeredFocus[configuration.session.id] = request
            pendingFocus = true
            focusIfReady()
        }
    }

    // MARK: Rows

    /// The filter and hidden setting the rows were last listed with.
    private var shownListing: (filter: String, hidden: Bool)?

    private func apply(_ rows: [FilesRow], root: String, reload: Bool, refresh: Bool) {
        guard let outline else { return }
        guard reload || root != self.root || rows != self.rows else { return }
        applying = true
        defer { applying = false }
        var grouped: [String: [String]] = [:]
        var byID: [String: FilesRow] = [:]
        byID.reserveCapacity(rows.count)
        for row in rows {
            grouped[row.parent, default: []].append(row.id)
            byID[row.id] = row
        }
        if reload || root != self.root {
            let rootChanged = root != self.root
            self.root = root
            self.rows = rows
            var rebuilt: [String: Node] = [:]
            rebuilt.reserveCapacity(rows.count)
            for row in rows {
                let node = nodes[row.id] ?? Node(row)
                node.row = row
                rebuilt[row.id] = node
            }
            nodes = rebuilt
            children = grouped
            outline.reloadData()
            expandRows(rows)
            if rootChanged, outline.numberOfRows > 0 { outline.scrollRowToVisible(0) }
            return
        }
        self.rows = rows
        var changed: [Node] = []
        var reordered = false
        outline.beginUpdates()
        // Folders top-down: a folder's rows are in the model before the outline can ask for them.
        var queue = [root]
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            let new = grouped[parent] ?? []
            let old = children[parent] ?? []
            for id in new {
                guard let row = byID[id] else { continue }
                if let node = nodes[id] {
                    var previous = node.row
                    previous.expanded = row.expanded
                    let kindChanged = node.row.isDirectory != row.isDirectory
                    let textChanged = previous != row
                    node.row = row
                    if kindChanged { outline.reloadItem(node, reloadChildren: false) }
                    else if textChanged { changed.append(node) }
                } else {
                    nodes[id] = Node(row)
                }
                if grouped[id] != nil || children[id] != nil { queue.append(id) }
            }
            guard new != old else { continue }
            children[parent] = new
            let parentNode = parent == root ? nil : nodes[parent]
            let shown = parent == root || parentNode.map { outline.isItemExpanded($0) } == true
            guard shown else { continue }
            // Paths are unique, so a refresh or a filter is removals and insertions around rows that keep their
            // order: linear, where a general diff of 10,000 rows is quadratic. A new order (a sort) reloads instead.
            let oldSet = Set(old), newSet = Set(new)
            guard old.filter(newSet.contains) == new.filter(oldSet.contains) else {
                if let parentNode { outline.reloadItem(parentNode, reloadChildren: true) } else { reordered = true }
                continue
            }
            let removals = IndexSet(old.indices.filter { !newSet.contains(old[$0]) })
            let insertions = IndexSet(new.indices.filter { !oldSet.contains(new[$0]) })
            // A file or two appearing or going in a folder already listed (a build's output, an agent's edit) fades
            // and slides; a first listing, a checkout's worth of change, or Reduce Motion stays instant.
            let animated = refresh && !old.isEmpty && removals.count + insertions.count <= 20
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if !removals.isEmpty { outline.removeItems(at: removals, inParent: parentNode, withAnimation: animated ? [.effectFade, .slideUp] : []) }
            if !insertions.isEmpty { outline.insertItems(at: insertions, inParent: parentNode, withAnimation: animated ? [.effectFade, .slideDown] : []) }
        }
        outline.endUpdates()
        if reordered {
            outline.reloadData()
            changed = []
        }
        expandRows(rows)
        // Texts that changed in place (a size, an age) redraw their rows only.
        let valid = IndexSet(changed.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        if !valid.isEmpty {
            outline.reloadData(forRowIndexes: valid, columnIndexes: IndexSet(integersIn: 0..<outline.numberOfColumns))
        }
        if nodes.count > byID.count { nodes = nodes.filter { byID[$0.key] != nil } }
        if children.count > grouped.count + 1 { children = children.filter { $0.key == root || byID[$0.key] != nil } }
    }

    /// Folders the session expanded open in the outline and the others close, top-down.
    private func expandRows(_ rows: [FilesRow]) {
        guard let outline else { return }
        for row in rows where row.isDirectory {
            guard let node = nodes[row.id] else { continue }
            let open = outline.isItemExpanded(node)
            if row.expanded && !open { outline.expandItem(node) }
            else if !row.expanded && open { outline.collapseItem(node) }
        }
    }

    /// The model of `id` and every expanded folder below it, before the outline asks for its rows.
    private func load(_ id: String, from rows: [FilesRow]) {
        var grouped: [String: [String]] = [:]
        for row in rows where FilesPath.isWithin(row.parent, id) {
            grouped[row.parent, default: []].append(row.id)
            if let node = nodes[row.id] { node.row = row } else { nodes[row.id] = Node(row) }
        }
        children[id] = grouped[id] ?? []
        for (parent, ids) in grouped where parent != id { children[parent] = ids }
    }

    private func syncSelection() {
        guard let outline, let session else { return }
        let desired = IndexSet(session.selection.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        guard desired != outline.selectedRowIndexes else { return }
        applying = true
        outline.selectRowIndexes(desired, byExtendingSelection: false)
        applying = false
        if let first = desired.first { outline.scrollRowToVisible(first) }
    }

    private func node(at row: Int) -> Node? {
        guard let outline, row >= 0, row < outline.numberOfRows else { return nil }
        return outline.item(atRow: row) as? Node
    }

    private var selectedRows: [FilesRow] {
        guard let outline else { return [] }
        return outline.selectedRowIndexes.compactMap { node(at: $0)?.row }.filter(\.isEntry)
    }

    var hasSelection: Bool { !selectedRows.isEmpty }

    /// The row keys act on: the anchor if it is selected, else the first selected.
    private var primaryRow: FilesRow? {
        let selected = selectedRows
        if let anchor = session?.anchor, let row = selected.first(where: { $0.id == anchor }) { return row }
        return selected.first
    }

    // MARK: Focus

    func tookFocus() {
        if let session, session.previewFocused { session.previewFocused = false }
    }

    func windowChanged() { focusIfReady() }

    private func focusIfReady() {
        guard pendingFocus, let outline, outline.window != nil else { return }
        pendingFocus = false
        // After this update: the window may still be laying out the view that holds the list.
        DispatchQueue.main.async { [weak outline] in
            guard let outline, let window = outline.window else { return }
            window.makeFirstResponder(outline)
        }
    }

    // MARK: Actions

    func openSelection() {
        guard let session, let row = primaryRow else { return }
        session.open(row)
    }

    func showEnclosingFolder() {
        guard let session, let root else { return }
        session.showEnclosingFolder(of: root)
    }

    func openInEditor() {
        guard let session, let row = primaryRow else { return }
        TerminalRuntime.shared.files.openInEditor(session.id, path: row.id)
    }

    func copyPaths() {
        guard let session else { return }
        let text = session.pathsText(in: rows)
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func paste() {
        guard let session else { return }
        TerminalRuntime.shared.files.paste(session.id)
    }

    func refresh() {
        guard let session else { return }
        TerminalRuntime.shared.files.refresh(session.id)
    }

    func toggleHidden() {
        guard let session, let configuration else { return }
        session.toggleHidden(settingHidden: configuration.settingHidden)
    }

    func find() {
        session?.findRequest = System.uuid()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard let session, let outline, let row = node(at: outline.clickedRow)?.row else { return }
        session.open(row)
    }

    // MARK: Data source

    private func id(of item: Any?) -> String { (item as? Node)?.id ?? root ?? "" }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children[id(of: item)]?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let siblings = children[id(of: item)] ?? []
        let id = siblings.indices.contains(index) ? siblings[index] : Self.missingID(index, in: self.id(of: item))
        if let node = nodes[id] { return node }
        // The model and the outline disagree only if a row went missing between two calls; a blank row is safer
        // than a crash.
        let node = Node(FilesRow(id: id, parent: self.id(of: item), depth: 0, kind: .loading, entry: nil, title: "",
                                 modified: "", size: ""))
        nodes[id] = node
        return node
    }

    /// A stand-in row's id: unique per slot, and no path contains a NUL.
    private static func missingID(_ index: Int, in parent: String) -> String { "\(parent)\u{0}missing\(index)" }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.row.isDirectory == true
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node, let tableColumn, let style else { return nil }
        switch tableColumn.identifier {
        case Self.nameColumn:
            let cell = outlineView.makeView(withIdentifier: FilesNameCell.reuse, owner: nil) as? FilesNameCell ?? FilesNameCell()
            cell.configure(node.row, style: style)
            return cell
        case Self.modifiedColumn, Self.sizeColumn:
            let size = tableColumn.identifier == Self.sizeColumn
            let reuse = size ? FilesValueCell.sizeReuse : FilesValueCell.modifiedReuse
            let cell = outlineView.makeView(withIdentifier: reuse, owner: nil) as? FilesValueCell ?? FilesValueCell(reuse: reuse)
            cell.configure(size ? node.row.size : node.row.modified, style: style, trailing: size ? FilesColumns.trailing : 0)
            return cell
        default:
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let view = outlineView.makeView(withIdentifier: FilesRowView.reuse, owner: nil) as? FilesRowView ?? FilesRowView()
        view.identifier = FilesRowView.reuse
        view.style = style
        if let node = item as? Node { decorate(view, node) }
        return view
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let view = rowView as? FilesRowView, let node = node(at: row) else { return }
        view.style = style
        decorate(view, node)
    }

    private func decorate(_ view: FilesRowView, _ node: Node) {
        view.dragged = dragged.contains(node.id)
        view.dropTarget = dropTarget == node.id
    }

    private func redecorate() {
        outline?.enumerateAvailableRowViews { view, row in
            guard let view = view as? FilesRowView, let node = self.node(at: row) else { return }
            self.decorate(view, node)
        }
        container?.ring.show(dropTarget == Self.rootTarget, style: style)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Node)?.row.isEntry == true
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard tableColumn?.identifier == Self.nameColumn, let node = item as? Node, node.row.isEntry else { return nil }
        return node.row.title
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !applying, let session, let outline else { return }
        let rows = outline.selectedRowIndexes.compactMap { node(at: $0)?.row }
        session.selectionChanged(to: rows, anchor: node(at: outline.selectedRow)?.row)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !applying, let session, let configuration,
              let node = notification.userInfo?["NSObject"] as? Node else { return }
        session.expanded.insert(node.id)
        load(node.id, from: configuration.rebuild())
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !applying, let session, let node = notification.userInfo?["NSObject"] as? Node else { return }
        // Folders inside close with it: polling stops for everything out of sight.
        let closing = session.expanded.filter { FilesPath.isWithin($0, node.id) }
        if !closing.isEmpty { session.expanded.subtract(closing) }
        children[node.id] = []
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline else { return }
        let clicked = outline.clickedRow
        // Like Finder: a right-click outside the selection acts on the clicked row alone.
        if clicked >= 0, node(at: clicked)?.row.isEntry == true, !outline.selectedRowIndexes.contains(clicked) {
            outline.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        let targets = clicked >= 0 ? selectedRows : []
        let single = targets.count == 1 ? targets.first : nil
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
                 enabled: Bool) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(single?.isDirectory == true ? "Open" : "Preview", #selector(menuOpen), enabled: single != nil)
        add("Open in Editor", #selector(menuOpenInEditor), key: "o", enabled: single != nil)
        menu.addItem(.separator())
        add("Copy Path", #selector(menuCopy), key: "c", modifiers: [.command, .option], enabled: !targets.isEmpty)
        add("Copy", #selector(menuCopy), key: "c", enabled: !targets.isEmpty)
        menu.addItem(.separator())
        add("Show Enclosing Folder", #selector(menuEnclosingFolder), enabled: (single?.depth ?? 0) > 0)
        add("Refresh", #selector(menuRefresh), key: "r", enabled: true)
    }

    @objc private func menuOpen() { openSelection() }
    @objc private func menuOpenInEditor() { openInEditor() }
    @objc private func menuCopy() { copyPaths() }
    @objc private func menuRefresh() { refresh() }

    @objc private func menuEnclosingFolder() {
        guard let session, let row = primaryRow else { return }
        session.pin(row.parent, selecting: row.id)
    }

    // MARK: Drag and drop

    private func syncDrag(_ drag: (any FilesDragDelegate)?) {
        guard let outline else { return }
        let types = drag?.acceptedTypes ?? []
        guard types != registeredTypes else { return }
        outline.unregisterDraggedTypes()
        if !types.isEmpty { outline.registerForDraggedTypes(types) }
        registeredTypes = types
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let session, let drag = configuration?.drag, let node = item as? Node, node.row.isEntry else { return nil }
        return drag.pasteboardWriter(for: [node.id], in: session)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        dragged = draggedItems.compactMap { ($0 as? Node)?.id }
        dragSource = configuration?.drag
        redecorate()
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        let paths = dragged
        let source = dragSource
        dragged = []
        dragSource = nil
        redecorate()
        if let source, let files = self.session { source.dragEnded(paths: paths, operation: operation, in: files) }
    }

    /// A folder row takes the drop itself; a file (or a placeholder) hands it to its folder; empty space to the root.
    private func dropFolder(for node: Node?) -> (node: Node?, directory: String) {
        let root = root ?? ""
        guard let node else { return (nil, root) }
        if node.row.isEntry && node.row.isDirectory { return (node, node.id) }
        let parent = node.row.parent
        return (parent == root ? nil : nodes[parent], parent)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let session, let drag = configuration?.drag else { return [] }
        let target = dropFolder(for: item as? Node)
        outlineView.setDropItem(target.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let operation = drag.validateDrop(info, onto: target.directory, in: session)
        setDropTarget(operation.isEmpty ? nil : target.node?.id ?? Self.rootTarget)
        return operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let session, let drag = configuration?.drag else { return false }
        let target = dropFolder(for: item as? Node)
        clearDropTarget()
        return drag.acceptDrop(info, onto: target.directory, in: session)
    }

    private func setDropTarget(_ id: String?) {
        guard dropTarget != id else { return }
        dropTarget = id
        redecorate()
    }

    func clearDropTarget() { setDropTarget(nil) }
}

// MARK: Rows and cells

/// The row's wash when selected (`.sel`), while its row is being dragged out, and the 1.5 pt accent ring and wash of
/// a drop target (F2b).
final class FilesRowView: NSTableRowView {
    static let reuse = NSUserInterfaceItemIdentifier("files-row")
    var style: FilesOutlineStyle?
    var dragged = false { didSet { if dragged != oldValue { needsDisplay = true } } }
    var dropTarget = false { didSet { if dropTarget != oldValue { needsDisplay = true } } }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for case let cell as FilesCell in subviews { cell.selected = isSelected }
        }
    }

    /// Text keeps the list's inks on a selected row instead of AppKit's white on blue.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let style else { return }
        style.wash.setFill()
        bounds.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard let style, dragged, !isSelected else { return }
        style.wash.setFill()
        bounds.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let style, dropTarget else { return }
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
        style.accent.withAlphaComponent(0.10).setFill()
        ring.fill()
        ring.lineWidth = 1.5
        style.accent.setStroke()
        ring.stroke()
    }
}

/// A cell that follows its row's selection.
class FilesCell: NSTableCellView {
    var selected = false { didSet { if selected != oldValue { recolor() } } }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        selected = (superview as? NSTableRowView)?.isSelected == true
    }

    func recolor() {}
}

/// Icon (folder, document, a link badge for symlinks) and name.
final class FilesNameCell: FilesCell {
    static let reuse = NSUserInterfaceItemIdentifier("files-name")
    private let icon = NSImageView()
    private let badge = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var row: FilesRow?
    private var style: FilesOutlineStyle?

    init() {
        super.init(frame: .zero)
        identifier = Self.reuse
        icon.imageScaling = .scaleProportionallyDown
        badge.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        for view in [icon, badge, label] { addSubview(view) }
        textField = label
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: FilesRow, style: FilesOutlineStyle) {
        self.row = row
        self.style = style
        let visibleTitle = TextRendering.visible(row.title)
        label.stringValue = visibleTitle
        label.font = row.isEntry ? style.nameFont : style.metaFont
        let symbol: String? = switch row.kind {
        case .entry: row.isDirectory ? "folder" : "doc"
        case .error: "exclamationmark.triangle"
        case .loading, .empty, .truncated: nil
        }
        icon.image = symbol.flatMap { FilesSymbols.image($0, size: style.iconSize) }
        icon.isHidden = symbol == nil
        badge.image = row.entry?.kind == .symlink
            ? FilesSymbols.image("arrow.up.right", size: style.iconSize * 0.55, weight: .bold) : nil
        badge.isHidden = badge.image == nil
        setAccessibilityLabel(row.entry?.kind == .symlink ? "\(visibleTitle), symbolic link" : visibleTitle)
        recolor()
        needsLayout = true
    }

    override func recolor() {
        guard let row, let style else { return }
        label.textColor = row.kind == .error ? style.warning : !row.isEntry ? style.dim : selected ? style.selectedText : style.text
        icon.contentTintColor = row.kind == .error ? style.warning : style.icon
        badge.contentTintColor = selected ? style.selectedText : style.text
    }

    override func layout() {
        super.layout()
        guard let style else { return }
        let size = style.iconSize
        var x: CGFloat = 0
        if !icon.isHidden {
            icon.frame = NSRect(x: 0, y: (bounds.height - size) / 2, width: size, height: size)
            let badgeSize = size * 0.6
            badge.frame = NSRect(x: size - badgeSize * 0.7, y: icon.frame.minY - badgeSize * 0.2, width: badgeSize, height: badgeSize)
            x = size + 7
        }
        let height = ceil(label.intrinsicContentSize.height)
        let available = max(0, bounds.width - x - 4)
        // The cell's size, not the intrinsic one: that leaves out the 2 pt the label draws on each side, and every
        // name came out a character short, middle-truncated ("bill…g.ts").
        let width = min(available, ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width))
        label.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// The right-aligned, muted modified and size columns.
final class FilesValueCell: FilesCell {
    static let modifiedReuse = NSUserInterfaceItemIdentifier("files-modified")
    static let sizeReuse = NSUserInterfaceItemIdentifier("files-size")
    private let label = NSTextField(labelWithString: "")
    private var style: FilesOutlineStyle?
    private var trailing: CGFloat = 0

    init(reuse: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = reuse
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, style: FilesOutlineStyle, trailing: CGFloat) {
        self.style = style
        self.trailing = trailing
        label.stringValue = text
        label.font = style.metaFont
        recolor()
        needsLayout = true
    }

    override func recolor() {
        guard let style else { return }
        label.textColor = selected ? style.selectedMeta : style.meta
    }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: max(0, bounds.width - trailing), height: height)
    }
}

/// SF Symbols as template images, made once per name and size: 10,000 rows share a handful.
@MainActor enum FilesSymbols {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name) \(size) \(weight.rawValue)"
        if let image = cache[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.86, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        image.isTemplate = true
        cache[key] = image
        return image
    }
}
