import SwiftUI

// The main window's sidebar at the app's defaults (SpaceSidebar.swift, SidebarSpaceTile.swift, NewSpaceButton.swift):
// icons style, flat order, 264 wide. Metrics at content size 14 (AppTypography.expanded = ×1.12).

struct SpaceItem: Identifiable {
    var id: String { name }
    var name: String
    var host = Hosts.local
    var branch: String?
    var activity = Activity.none
    /// 1…9; nil draws "·" as a space without a shortcut.
    var shortcut: Int?
    /// The shortcut's modifiers: spaces ⇧⌘, tabs only's tabs ⌘.
    var keys = "⇧⌘"
    var selected = false
    var hovered = false
}

struct SidebarModel {
    var spaces: [SpaceItem]
    /// Tree order: spaces under a header per host (the tree toggle lit).
    var tree = false
    /// The footer's machines, local first; defaults to the hosts the spaces use.
    var footer: [MockHost]?
    var width: CGFloat = 264
    var hosts: [MockHost] {
        footer ?? spaces.map(\.host).reduce(into: [Hosts.local]) { if !$0.contains($1) { $0.append($1) } }
    }
}

struct Sidebar: View {
    let model: SidebarModel
    var body: some View {
        SidebarColumn(model: model) {
            if model.tree {
                Self.treeList(model)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.spaces) { SpaceRow(space: $0) }
                    // "+ local" joins "+ space" while a remote host is connected (SpaceSidebar.newSpaceButtons).
                    NewSpaceRow(local: model.hosts.contains { !$0.local && !$0.offline }).padding(.top, 4)
                }
            }
        }
    }

    /// Tree order's list as the app draws it, for a proposal to sit beside.
    static func treeList(_ model: SidebarModel) -> some View {
        VStack(spacing: 11) {
            ForEach(model.groups, id: \.0) { host, spaces in
                VStack(spacing: 2) {
                    TreeGroupHeader(host: host, empty: spaces.isEmpty)
                    ForEach(spaces) { SpaceRow(space: $0, lead: .activity) }
                }
                .opacity(host.offline ? 0.65 : 1)
            }
        }
    }
}

extension SidebarModel {
    /// Tree order's groups: each host with spaces, in the footer's order; Local always, empty or not (SpaceSidebar's
    /// host groups), its + then showing.
    var groups: [(MockHost, [SpaceItem])] {
        hosts.compactMap { host in
            let spaces = spaces.filter { $0.host == host }
            return spaces.isEmpty && !host.local ? nil : (host, spaces)
        }
    }
}

/// The sidebar around its list: background, the top row, the list 10 points in, the footer. A sidebar proposal swaps
/// the list and keeps the rest as the app draws it.
struct SidebarColumn<Header: View, List: View>: View {
    let model: SidebarModel
    let header: Header
    let list: List
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { list.padding(.horizontal, 10) }.scrollDisabled(true)
            SidebarFooter(hosts: model.hosts)
        }
        .frame(width: model.width)
        .frame(maxHeight: .infinity)
        .background {
            if Mock.glass && Mock.insetSidebar {
                // AppKit's sidebar glass on macOS 26: a panel 8 points in from the window's leading, top and bottom edges.
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(GlassTone.sidebar).overlay(shape.strokeBorder(GlassTone.sidebarEdge, lineWidth: 1))
                    .padding([.leading, .top, .bottom], 8)
                    .background(GlassTone.sidebarWindow)
            } else if Mock.glass {
                // On macOS 27 the same glass is a flush, full-height column: no inset, corner or rim (LiquidGlass.swift,
                // SystemSidebarGlass).
                GlassTone.sidebar
            } else {
                Chrome.sidebar
            }
        }
        .foregroundStyle(Chrome.palette.ink)
    }
}

extension SidebarColumn where Header == SidebarTopRow {
    init(model: SidebarModel, @ViewBuilder list: () -> List) {
        self.init(model: model, header: SidebarTopRow(tree: model.tree), list: list())
    }
}

extension SidebarColumn {
    /// A proposal's own header row in place of the app's.
    init(model: SidebarModel, @ViewBuilder header: () -> Header, @ViewBuilder list: () -> List) {
        self.init(model: model, header: header(), list: list())
    }
}

/// The traffic lights' row, as the app draws it (SpaceSidebar.windowRow, headerControls): the sidebar toggle, the
/// mode's menu (Spaces ⌄ or Tabs ⌄), then the tree toggle and the shortcuts button. Tight, the shortcuts button goes,
/// then the name becomes an icon among the buttons. On glass each control is a GlassPanelControl (a track-sized
/// square, a capsule when lit); flat, a 24-point square with a 4-point corner.
struct SidebarTopRow: View {
    var tree = false
    var tabs = false
    private var p: SidebarPalette { Chrome.palette }
    private var t: AppTypography { Mock.typography }
    var body: some View {
        let glass = Mock.glass
        let height = t.expanded(glass ? 38 : 30)
        let controls = glass ? StripTab.glassTrackHeight(t) : 24
        HStack(spacing: 0) {
            // SidebarToggle: inside the glass panel one of the header's controls (in `detail`), flat a plain glyph.
            if glass {
                control(Image(systemName: "sidebar.left"), lit: false)
            } else {
                Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(p.ink).frame(width: 22, height: 20)
            }
            ViewThatFits(in: .horizontal) {
                row(named: true, shortcuts: true)
                row(named: true, shortcuts: false)
                row(named: false, shortcuts: true)
            }
        }
        .padding(.leading, Mock.controlsInset).padding(.trailing, glass ? 8 + 4 : 8)
        .frame(height: height)
        // headerGap: max(rowSpacing, glassRowInset) − (row − controls) / 2.
        .padding(.bottom, max(2, 4) - (height - controls) / 2)
    }

    private func row(named: Bool, shortcuts: Bool) -> some View {
        HStack(spacing: 0) {
            if named { menu.padding(.leading, 8) }
            Spacer(minLength: named ? 8 : 0)
            HStack(spacing: 4) {
                if !named { control(Image(systemName: "rectangle.stack.badge.minus"), lit: tabs) }
                control(HostTreeGlyph().frame(width: t.size(offset: -0.5), height: t.size(offset: -0.5)), lit: tree)
                if shortcuts {
                    // ShortcutSheetButton: flat, its glyph in the shortcut font.
                    if Mock.glass { control(Image(systemName: "keyboard"), lit: false) }
                    else { control(Image(systemName: "keyboard").font(t.shortcut()), lit: false) }
                }
            }
        }
    }

    /// The mode's name and ⌄ on a faint capsule, as wide as "Spaces" in either mode (ReservedText).
    private var menu: some View {
        HStack(spacing: 4) {
            ReservedText(text: tabs ? "Tabs" : "Spaces", variants: ["Spaces", "Tabs"])
                .interfaceFont(size: t.size(.body), weight: .semibold)
                .foregroundStyle(Chrome.ink)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(p.detail)
        }
        .padding(.horizontal, 7).frame(height: t.expanded(20))
        .background(Chrome.ink.opacity(0.05), in: Capsule())
        .fixedSize()
    }

    /// GlassPanelControl on glass; flat, SpaceSidebar.headerButton (the shortcuts button draws the same).
    @ViewBuilder private func control(_ label: some View, lit: Bool) -> some View {
        if Mock.glass {
            let size = StripTab.glassTrackHeight(t)
            label.font(.system(size: 14)).frame(width: size, height: size)
                .foregroundStyle(lit ? Chrome.ink : p.detail)
                .background(lit ? Chrome.ink.opacity(0.07) : .clear, in: Capsule())
        } else {
            label.font(t.symbol(.body)).frame(width: 24, height: 24)
                .foregroundStyle(lit ? Chrome.ink : p.detail)
                .background(lit ? Chrome.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// A host's heading in tree order, as the app draws it (SpaceSidebar.hostGroup with `hostInHeader`): the name
/// (semibold 12, in the host's colour) 10 in, "offline" after it when it is, and at the end the host's disc, which
/// the + replaces on hover (or with no spaces). 32 tall: the disc and about 3 points above and below.
struct TreeGroupHeader: View {
    let host: MockHost
    var hovered = false
    /// No spaces under it: the + shows in the disc's place (NewSpaceButton's header label, `revealed`).
    var empty = false
    var body: some View {
        let p = Chrome.palette
        HStack(spacing: 6) {
            Text(host.local ? "Local" : host.name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(host.tint?.foreground ?? p.secondary)
            if host.offline { Text("offline").font(.system(size: 11)).foregroundStyle(p.muted) }
            Spacer()
            ZStack {
                HostDiscMark(host: host).opacity(hovered || empty ? 0 : 1)
                TreeGroupPlus(hovered: hovered, revealed: empty).frame(width: 25, height: 25)
            }
        }
        .padding(.leading, 10).padding(.trailing, 10)
        .frame(height: 32)
    }
}

/// The icons style's disc (HostDisc): the host's glyph on a circle, glass tinted with the host's wash on Liquid Glass
/// (drawn as GlassTone's track under the wash) and the hover tone flat; plain on the selected row's fill, the host's
/// wash there.
struct HostDiscMark: View {
    let host: MockHost
    var selected = false
    var body: some View {
        let p = Chrome.palette
        MockHostGlyph(system: host.system, size: Mock.typography.hostIconSize)
            .foregroundStyle(host.tint?.foreground ?? p.secondary)
            .frame(width: 25, height: 25)
            .background {
                if selected { Circle().fill(host.tint?.glassWash ?? p.hover) }
                else if Mock.glass {
                    Circle().fill(host.tint?.glassWash ?? .clear).background(Circle().fill(GlassTone.track))
                        .overlay(Circle().strokeBorder(GlassTone.trackEdge, lineWidth: 1))
                }
                else { Circle().fill(p.hover) }
            }
    }
}

/// The header's +: on hover in a hover circle, or `revealed` (an empty group) without one.
struct TreeGroupPlus: View {
    var hovered = false
    var revealed = false
    var body: some View {
        let p = Chrome.palette
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(hovered ? p.ink : p.secondary)
            .frame(width: 25, height: 25)
            .background(Circle().fill(hovered ? p.hover : .clear))
            .opacity(hovered || revealed ? 1 : 0)
    }
}

/// The footer: a rule, then each machine's glyph (a remote one with its connection dot).
struct SidebarFooter: View {
    let hosts: [MockHost]
    var body: some View {
        let p = Chrome.palette
        let glass = Mock.glass, t = Mock.typography
        // SpaceSidebar.hostStrip: up to four columns, wrapping; on glass the hairline and cells inset like the rows.
        VStack(spacing: 0) {
            Rectangle().fill(glass ? Chrome.border.opacity(0.6) : Chrome.border).frame(height: 1)
                .padding(.horizontal, glass ? 6 + 4 : 0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: min(4, max(1, hosts.count))), spacing: 4) {
                ForEach(hosts, id: \.self) { host in
                    HStack(spacing: 5) {
                        MockHostGlyph(system: host.system, size: t.hostIconSize)
                            .foregroundStyle(host.local ? p.ink : host.foreground)
                        if !host.local {
                            Circle().fill(host.offline ? Chrome.muted.opacity(0.45) : host.tint!.border).frame(width: 4, height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: glass ? StripTab.glassTrackHeight(t) : max(t.expanded(28), t.hostIconSize + 12))
                }
            }
            .padding(.horizontal, glass ? 6 + 4 : 8).padding(.vertical, 4)
            .padding(.bottom, glass ? 4 : 0)
        }
    }
}

/// A space's row: host disc, name (and branch), activity, ⇧⌘ shortcut; selected on a fill the host's colour tints.
struct SpaceRow: View {
    let space: SpaceItem
    /// What leads the row: the host's disc (flat order), or grouped by host the activity in a 16-point column, the
    /// disc being in the group's heading (the app's `hostInHeader`).
    var lead = Lead.host
    enum Lead { case host, activity }
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        let tint = space.host.tint
        let activity = space.activity == .quiet ? Activity.none : space.activity
        HStack(spacing: lead == .host ? 9 : 8) {
            if lead == .host {
                HostDiscMark(host: space.host, selected: space.selected)
            } else {
                activity.glyph().frame(width: 16)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(space.name).lineLimit(1)
                // Settings › Show git branches, off by default: a screen sets `branch` only to show it on.
                if let branch = space.branch {
                    Text(branch).interfaceFont(size: 11).foregroundStyle(space.selected ? p.sidebarDetail : p.detail).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if lead == .host { activity.glyph() }
            Text(space.shortcut.map { "\(space.keys)\($0)" } ?? "·")
                .font(.system(size: 12.5).monospacedDigit()).tracking(0.75).foregroundStyle(p.secondary.opacity(0.7))
        }
        .interfaceFont(size: 13.5)
        .foregroundStyle(space.selected ? p.ink : p.secondary)
        .padding(.leading, lead == .host ? 5 : 10).padding(.trailing, 10)
        .frame(height: 33)
        // SidebarMetrics.icons' 13, nested on glass: glassRadius (16 − 6) − glassRowInset (4).
        .background(RoundedRectangle(cornerRadius: Mock.glass ? 6 : 13).fill(
            space.selected ? (tint.map { $0.foreground.opacity(0.16) } ?? p.selection) : space.hovered ? p.hover : .clear))
    }
}

/// "+ space ⌘N" in the left half of its row (the right half is "+ local" when a remote host is connected).
struct NewSpaceRow: View {
    var local = false
    /// "space" and ⌘N; tabs only's "tab" and ⌘T.
    var title = "space"
    var shortcut = "⌘N"
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        HStack(spacing: Mock.glass ? 4 : 6) {
            tile(title, shortcut: shortcut)
            if local { tile("local", shortcut: "⇧⌘N", glyph: true) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
    }
    /// NewSpaceButton's glassLabel (a capsule, text in `detail`) or tileLabel (a filled tile, ink at 0.75): "local" led
    /// by the Mac's glyph, "space" by a plus at 0.82 of the host glyph's size; a narrow row drops the shortcut first.
    private func tile(_ title: String, shortcut: String, glyph: Bool = false) -> some View {
        let t = Mock.typography
        let shape = RoundedRectangle(cornerRadius: Mock.glass ? 100 : 8, style: .continuous)
        return ViewThatFits(in: .horizontal) {
            contents(title, shortcut: shortcut, glyph: glyph)
            contents(title, shortcut: nil, glyph: glyph)
        }
        .lineLimit(1)
        .interfaceFont(size: t.tabSize)
        .foregroundStyle(Mock.glass ? p.detail : p.ink.opacity(0.75))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity).frame(height: StripTab.glassTrackHeight(t))
        .background(Mock.glass ? GlassTone.track : p.sidebarAction, in: shape)
        .overlay { if Mock.glass { shape.strokeBorder(GlassTone.trackEdge, lineWidth: 1) } }
    }
    private func contents(_ title: String, shortcut: String?, glyph: Bool) -> some View {
        let t = Mock.typography
        return HStack(spacing: 6) {
            Group {
                if glyph { MockHostGlyph(system: .mac, size: t.hostIconSize) }
                else { Image(systemName: "plus").font(.system(size: (t.hostIconSize * 0.82).rounded(), weight: .semibold)) }
            }
            .foregroundStyle(p.secondary)
            Text(title)
            Spacer(minLength: 0)
            if let shortcut {
                let size = t.size(offset: -1.5)
                Text(shortcut).font(.system(size: size).monospacedDigit()).tracking(size * 0.06).foregroundStyle(p.secondary.opacity(0.7))
            }
        }
    }
}

/// The tree toggle's glyph, SpaceSidebar's HostTreeGlyph as drawn there: a parent dot over two child rings on a 20-unit
/// grid.
struct HostTreeGlyph: View {
    var body: some View {
        Canvas { context, canvas in
            let unit = canvas.width / 20
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            var branches = Path()
            branches.move(to: point(5.5, 5)); branches.addLine(to: point(5.5, 17)); branches.addLine(to: point(10, 17))
            branches.move(to: point(5.5, 10.5)); branches.addLine(to: point(10, 10.5))
            context.stroke(branches, with: .foreground,
                           style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: 3.25 * unit, y: 0.75 * unit, width: 4.5 * unit, height: 4.5 * unit)), with: .foreground)
            for y: CGFloat in [10.5, 17] {
                context.stroke(Path(ellipseIn: CGRect(x: 12.5 * unit, y: (y - 2) * unit, width: 4 * unit, height: 4 * unit)),
                               with: .foreground, lineWidth: 1.5 * unit)
            }
        }
    }
}
