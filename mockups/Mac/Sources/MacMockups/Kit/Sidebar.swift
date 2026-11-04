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
                    ForEach(spaces) { SpaceRow(space: $0) }
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
struct SidebarColumn<List: View>: View {
    let model: SidebarModel
    @ViewBuilder let list: List
    var body: some View {
        VStack(spacing: 0) {
            SidebarTopRow(tree: model.tree)
            ScrollView { list.padding(.horizontal, 10) }.scrollDisabled(true)
            SidebarFooter(hosts: model.hosts)
        }
        .frame(width: model.width)
        .frame(maxHeight: .infinity)
        .background(Mock.glass ? GlassTone.sidebar : Chrome.sidebar)
        .foregroundStyle(Chrome.palette.ink)
    }
}

/// The traffic lights' row: sidebar toggle after them, the tree toggle and the shortcuts button at the end.
struct SidebarTopRow: View {
    var tree = false
    var body: some View {
        let p = Chrome.palette, glass = Mock.glass
        HStack(spacing: 0) {
            Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(p.ink).frame(width: 22, height: 20)
            Spacer()
            HStack(spacing: 12) {
                HostTreeGlyph().frame(width: 13.5, height: 13.5).foregroundStyle(tree ? p.ink : p.detail)
                    .frame(width: 24, height: 24)
                    .background(tree ? p.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: "keyboard").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(p.detail)
                    .frame(minWidth: 24, minHeight: 24)
            }
        }
        // Glass rows are taller (the 38-point strip) and its controls sit further in (measured from the capture).
        .padding(.leading, glass ? 89 : 82).padding(.trailing, glass ? 16 : 8)
        .frame(height: glass ? Mock.typography.expanded(38) : Mock.typography.expanded(30))
        .padding(.bottom, glass ? 0 : -0.8)
    }
}

/// A host's header in tree order, as the app draws it: the name (semibold 12, in the host's colour), "offline" when it
/// is, and the + that appears on hover (or with no spaces).
struct TreeGroupHeader: View {
    let host: MockHost
    var hovered = false
    var body: some View {
        let p = Chrome.palette
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(host.local ? "Local" : host.name).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(host.tint?.foreground ?? p.secondary)
                if host.offline { Text("offline").font(.system(size: 11)).foregroundStyle(p.muted) }
                Spacer()
            }
            .padding(.leading, 10)
            TreeGroupPlus(hovered: hovered)
        }
        .frame(height: 20)
    }
}

/// The header's +: shown on hover, in a hover circle.
struct TreeGroupPlus: View {
    var hovered = false
    var body: some View {
        let p = Chrome.palette
        Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(hovered ? p.ink : p.secondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(hovered ? p.hover : .clear))
            .padding(.trailing, 4)
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
    /// What the leading 25-point column holds: the host's disc (the app's), or the activity mark moved there from
    /// before the shortcut.
    var lead = Lead.host
    enum Lead { case host, activity }
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        let tint = space.host.tint
        let activity = space.activity == .quiet ? Activity.none : space.activity
        HStack(spacing: 9) {
            if lead == .host {
                MockHostGlyph(system: space.host.system, size: Mock.typography.hostIconSize)
                    .foregroundStyle(tint?.foreground ?? p.secondary)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(space.selected ? (tint?.glassWash ?? p.hover) : p.hover))
            } else {
                activity.glyph().frame(width: 25, height: 25)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(space.name).lineLimit(1)
                if let branch = space.branch {
                    Text(branch).interfaceFont(size: 11).foregroundStyle(p.sidebarDetail).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if lead == .host { activity.glyph() }
            Text(space.shortcut.map { "⇧⌘\($0)" } ?? "·")
                .font(.system(size: 12.5).monospacedDigit()).tracking(0.75).foregroundStyle(p.secondary.opacity(0.7))
        }
        .interfaceFont(size: 13.5)
        .foregroundStyle(space.selected ? p.ink : p.secondary)
        .padding(.leading, 5).padding(.trailing, 10)
        .frame(height: 33)
        .background(RoundedRectangle(cornerRadius: 13).fill(
            space.selected ? (tint.map { $0.foreground.opacity(0.16) } ?? p.selection) : space.hovered ? p.hover : .clear))
    }
}

/// "+ space ⌘N" in the left half of its row (the right half is "+ local" when a remote host is connected).
struct NewSpaceRow: View {
    var local = false
    private var p: SidebarPalette { Chrome.palette }
    var body: some View {
        HStack(spacing: 6) {
            tile("space", shortcut: "⌘N")
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
