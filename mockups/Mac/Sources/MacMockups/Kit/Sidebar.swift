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
                    NewSpaceRow().padding(.top, 4)
                }
            }
        }
    }

    /// Tree order's list as the app draws it, for a proposal to sit beside.
    static func treeList(_ model: SidebarModel) -> some View {
        VStack(spacing: 11) {
            ForEach(model.groups, id: \.0) { host, spaces in
                VStack(spacing: 2) {
                    TreeGroupHeader(host: host)
                    ForEach(spaces) { SpaceRow(space: $0, lead: .activity) }
                }
                .opacity(host.offline ? 0.65 : 1)
            }
        }
    }
}

extension SidebarModel {
    /// Tree order's groups: each host with spaces, in the footer's order.
    var groups: [(MockHost, [SpaceItem])] {
        hosts.compactMap { host in
            let spaces = spaces.filter { $0.host == host }
            return spaces.isEmpty ? nil : (host, spaces)
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
        .background(Mock.glass ? GlassTone.sidebar : Chrome.sidebar)
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

/// The traffic lights' row, as the app draws it (SpaceSidebar.headerControls): sidebar toggle, the mode's menu
/// (Spaces ⌄ or Tabs ⌄), then the tree toggle and the shortcuts button; tight, the shortcuts button goes, then the
/// name becomes an icon among the buttons (Screens/SidebarModeHeader.swift).
struct SidebarTopRow: View {
    var tree = false
    var tabs = false
    var body: some View { ModeWordsHeader(tabs: tabs, tree: tree, menu: true) }
}

/// A host's heading in tree order, as the app draws it (SpaceSidebar.hostGroup with `hostInHeader`): the name
/// (semibold 12, in the host's colour) 10 in, "offline" after it when it is, and at the end the host's disc, which
/// the + replaces on hover (or with no spaces). 32 tall: the disc and about 3 points above and below.
struct TreeGroupHeader: View {
    let host: MockHost
    var hovered = false
    var body: some View {
        let p = Chrome.palette
        HStack(spacing: 6) {
            Text(host.local ? "Local" : host.name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(host.tint?.foreground ?? p.secondary)
            if host.offline { Text("offline").font(.system(size: 11)).foregroundStyle(p.muted) }
            Spacer()
            ZStack {
                HostDiscMark(host: host).opacity(hovered ? 0 : 1)
                TreeGroupPlus(hovered: hovered).frame(width: 25, height: 25)
            }
        }
        .padding(.leading, 10).padding(.trailing, 10)
        .frame(height: 32)
    }
}

/// The icons style's disc: the host's glyph on a faint circle (the host's wash when its row is selected).
struct HostDiscMark: View {
    let host: MockHost
    var selected = false
    var body: some View {
        let p = Chrome.palette
        MockHostGlyph(system: host.system, size: Mock.typography.hostIconSize)
            .foregroundStyle(host.tint?.foreground ?? p.secondary)
            .frame(width: 25, height: 25)
            .background(Circle().fill(selected ? (host.tint?.glassWash ?? p.hover) : p.hover))
    }
}

/// The header's +: shown on hover, in a hover circle.
struct TreeGroupPlus: View {
    var hovered = false
    var body: some View {
        let p = Chrome.palette
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(hovered ? p.ink : p.secondary)
            .frame(width: 25, height: 25)
            .background(Circle().fill(hovered ? p.hover : .clear))
            .opacity(hovered ? 1 : 0)
    }
}

/// The footer: a rule, then each machine's glyph (a remote one with its connection dot).
struct SidebarFooter: View {
    let hosts: [MockHost]
    var body: some View {
        let p = Chrome.palette
        VStack(spacing: 0) {
            Rectangle().fill(Chrome.border).frame(height: 1)
            HStack(spacing: 4) {
                ForEach(hosts.prefix(4), id: \.self) { host in
                    HStack(spacing: 5) {
                        MockHostGlyph(system: host.system, size: Mock.typography.hostIconSize)
                            .foregroundStyle(host.local ? p.ink : host.foreground)
                        if !host.local {
                            Circle().fill(host.offline ? p.muted.opacity(0.45) : host.tint!.border).frame(width: 4, height: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Mock.typography.expanded(28))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
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
                if let branch = space.branch {
                    Text(branch).interfaceFont(size: 11).foregroundStyle(p.sidebarDetail).lineLimit(1)
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
        .background(RoundedRectangle(cornerRadius: 13).fill(
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
        HStack(spacing: 6) {
            tile(title, shortcut: shortcut)
            if local { tile("local", shortcut: "⇧⌘N", glyph: true) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
        }
    }
    private func tile(_ title: String, shortcut: String, glyph: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Mock.glass ? 100 : 8, style: .continuous)
        return HStack(spacing: 6) {
            Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.secondary)
            if glyph { MockHostGlyph(system: .mac, size: 14) }
            Text(title).interfaceFont(size: 13.5)
            Spacer(minLength: 0)
            Text(shortcut).font(.system(size: 12.5).monospacedDigit()).tracking(0.75).foregroundStyle(p.secondary.opacity(0.7))
        }
        .foregroundStyle(p.ink.opacity(0.75))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity).frame(height: Mock.typography.expanded(28))
        .background(Mock.glass ? GlassTone.track : p.sidebarAction, in: shape)
    }
}

/// The tree toggle's glyph (SpaceSidebar's HostTreeGlyph): a parent dot over two child rings on a 20-unit grid.
struct HostTreeGlyph: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 20
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
            var stem = Path()
            stem.move(to: point(5, 6)); stem.addLine(to: point(5, 15)); stem.addLine(to: point(11, 15))
            stem.move(to: point(5, 9)); stem.addLine(to: point(11, 9))
            context.stroke(stem, with: .foreground, lineWidth: 1.5 * unit)
            context.fill(Path(ellipseIn: CGRect(x: 2.5 * unit, y: 1.5 * unit, width: 5 * unit, height: 5 * unit)), with: .foreground)
            for y in [9.0, 15.0] {
                context.stroke(Path(ellipseIn: CGRect(x: 12 * unit, y: (y - 2.5) * unit, width: 5 * unit, height: 5 * unit)),
                               with: .foreground, lineWidth: 1.5 * unit)
            }
        }
    }
}
