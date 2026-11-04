import SwiftUI

/// Tree order with the host's icon drawn once, left of its name in the group's header, instead of on every space's
/// row; the rows' activity marks move into the column the host discs held. D1 compares it with the app's tree today.
enum TreeHostIcon {
    static let screens: [Screen] = [
        Screen("D1-tree-host-compare", group: "tree-host", "Tree order: now, and the host icon once in its header") {
            HStack(alignment: .top, spacing: 36) {
                labelled("Now") {
                    SidebarColumn(model: model) {
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
                labelled("Proposed") { SidebarColumn(model: model) { ProposedTree(model: model) } }
            }
        },
        Screen("D2-tree-host-window", group: "tree-host", "Proposed, in the main window") {
            DispatchWindow {
                SidebarColumn(model: model) { ProposedTree(model: model) }
            } content: {
                Pane(strip: StripModel(tabs: [
                    TabItem(title: "app", shortcut: 1, selected: true),
                    TabItem(title: "Fix the invoice rounding", activity: .finished, shortcut: 2),
                ])) { TerminalScreen(lines: Sample.gitStatus) }
            }
        },
        Screen("D3-tree-host-states", group: "tree-host", "Proposed: a remote space selected, header hovered, failed, long names") {
            let states = SidebarModel(spaces: [
                SpaceItem(name: "app", branch: "dark-mode", activity: .finished, shortcut: 1),
                SpaceItem(name: "docs", activity: .failed, shortcut: 2),
                SpaceItem(name: "billing", host: Hosts.buildBox, branch: "fix/invoices", activity: .waiting, shortcut: 3, selected: true),
                SpaceItem(name: "e2e", host: Hosts.buildBox, activity: .working, shortcut: 4),
                SpaceItem(name: "payments-reconciliation", host: Hosts.buildBox, branch: "feature/ledger-v2", shortcut: 5),
                SpaceItem(name: "release", host: Hosts.studio, activity: .working, shortcut: 6),
                SpaceItem(name: "deploy", host: Hosts.staging, activity: .offline),
            ], tree: true)
            labelled("Proposed: build-box hovered") {
                SidebarColumn(model: states) { ProposedTree(model: states, hovered: Hosts.buildBox) }
            }
        },
    ]

    /// Every host in the tree: Local, build-box, studio and an offline staging.
    static let model = SidebarModel(spaces: [
        SpaceItem(name: "app", branch: "dark-mode", activity: .finished, shortcut: 1, selected: true),
        SpaceItem(name: "docs", shortcut: 2),
        SpaceItem(name: "billing", host: Hosts.buildBox, branch: "fix/invoices", activity: .waiting, shortcut: 3),
        SpaceItem(name: "e2e", host: Hosts.buildBox, activity: .working, shortcut: 4),
        SpaceItem(name: "release", host: Hosts.studio, shortcut: 5),
        SpaceItem(name: "deploy", host: Hosts.staging, activity: .offline),
    ], tree: true)

    /// A sidebar 560 tall under a caption.
    static func labelled<V: View>(_ caption: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(Chrome.palette.muted)
            content().frame(height: 560).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Chrome.border, lineWidth: 1))
        }
    }
}

/// The proposal: each host's header leads with its glyph in the rows' 25-point column, so the header's name lines up
/// with the spaces' names and the glyph with the activity marks under it.
struct ProposedTree: View {
    let model: SidebarModel
    var hovered: MockHost?
    var body: some View {
        VStack(spacing: 11) {
            ForEach(model.groups, id: \.0) { host, spaces in
                VStack(spacing: 2) {
                    ProposedHeader(host: host, hovered: host == hovered)
                    ForEach(spaces) { SpaceRow(space: $0, lead: .activity) }
                }
                .opacity(host.offline ? 0.65 : 1)
            }
        }
    }
}

struct ProposedHeader: View {
    let host: MockHost
    var hovered = false
    var body: some View {
        let p = Chrome.palette
        let color = host.tint?.foreground ?? p.secondary
        HStack(spacing: 9) {
            MockHostGlyph(system: host.system, size: Mock.typography.hostIconSize).foregroundStyle(color).frame(width: 25)
            HStack(spacing: 6) {
                Text(host.local ? "Local" : host.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                if host.offline { Text("offline").font(.system(size: 11)).foregroundStyle(p.muted) }
            }
            Spacer()
            TreeGroupPlus(hovered: hovered)
        }
        .padding(.leading, 5)
        .frame(height: 24)
    }
}

// MARK: Second round: three ways out of D1's flat, holey column

extension TreeHostIcon {
    static let variants: [Screen] = [
        Screen("D4-tree-host-variants", group: "tree-host", "Now, then A indented, B narrow column, C marks stay") {
            HStack(alignment: .top, spacing: 28) {
                labelled("Now") { SidebarColumn(model: model) { Sidebar.treeList(model) } }
                labelled("A  Indented rows") { SidebarColumn(model: model) { VariantTree(model: model, style: .indented) } }
                labelled("B  Narrow column") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrow) } }
                labelled("C  Marks stay") { SidebarColumn(model: model) { VariantTree(model: model, style: .trailing) } }
            }
        },
        Screen("D5-tree-host-abd", group: "tree-host", "A indented, B narrow column, D icon at the header's end") {
            HStack(alignment: .top, spacing: 28) {
                labelled("A  Indented rows") { SidebarColumn(model: model) { VariantTree(model: model, style: .indented) } }
                labelled("B  Narrow column") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrow) } }
                labelled("D  Icon on the right") { SidebarColumn(model: model) { VariantTree(model: model, style: .rightIcon) } }
            }
        },
        Screen("D6-tree-host-b-right", group: "tree-host", "B, and B with the host icon at the header's end") {
            HStack(alignment: .top, spacing: 28) {
                labelled("B  Narrow column") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrow) } }
                labelled("B′  Icon on the right") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrowRight) } }
            }
        },
        Screen("D7-tree-host-c-after", group: "tree-host", "D4's C, and C with the host icon just after its name") {
            HStack(alignment: .top, spacing: 28) {
                labelled("C  Marks stay") { SidebarColumn(model: model) { VariantTree(model: model, style: .trailing) } }
                labelled("C′  host ◁") { SidebarColumn(model: model) { VariantTree(model: model, style: .trailingAfter) } }
            }
        },
        Screen("D8-tree-host-outdented", group: "tree-host", "B′, B″ (host name out of the names' line), C′") {
            HStack(alignment: .top, spacing: 28) {
                labelled("B′  Icon on the right") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrowRight) } }
                labelled("B″  Name outdented") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrowOut) } }
                labelled("C′  host ◁") { SidebarColumn(model: model) { VariantTree(model: model, style: .trailingAfter) } }
            }
        },
        Screen("D9-tree-host-c-outdented", group: "tree-host", "C′, C″ (host name further out, spaces further in), B″") {
            HStack(alignment: .top, spacing: 28) {
                labelled("C′  host ◁") { SidebarColumn(model: model) { VariantTree(model: model, style: .trailingAfter) } }
                labelled("C″  Name outdented") { SidebarColumn(model: model) { VariantTree(model: model, style: .trailingOut) } }
                labelled("B″  Name outdented") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrowOut) } }
            }
        },
        Screen("D10-tree-host-c-right", group: "tree-host", "C′ and C″ with the host icon at the header's far right, and B″") {
            HStack(alignment: .top, spacing: 28) {
                labelled("C′  Icon at the right") { SidebarColumn(model: model) { VariantTree(model: model, style: .rightName) } }
                labelled("C″  Icon at the right, names not indented") { SidebarColumn(model: model) { VariantTree(model: model, style: .rightNameFlat) } }
                labelled("B″  Name outdented") { SidebarColumn(model: model) { VariantTree(model: model, style: .narrowOut) } }
            }
        },
    ]
}

/// C′ (second round): the header's name where today's is (10 in), its icon at the far right over the shortcuts; rows as C
/// (names 30 in, the mark before the shortcut). C″: the name 4 in, the icon at the far right, the spaces' names 10 in.
/// C″: C′ with the header's name 4 points in (C′'s 10) and the spaces' names at 34 (C′'s 30): a 30-point step.
/// B″: B′ with the header's name over the marks' column, out of the spaces' names' line.
/// C′: C with the header's icon right after the name ("build-box ◁"), the name where today's header has it; rows
/// keep the mark before the shortcut, names indented under the header.
/// B′: B with the header's icon at its end over the shortcuts; the header's name stays over the spaces' names.
/// D: the header's name where today's is, the host icon at its end over the shortcuts (+ before it on hover); rows
/// lead with the mark in a 16-point column under the name, names after it.
/// A: the header as today with the icon before the name; rows indented under the name, the mark leading them.
/// B: icon and marks in a 16-point column, header and space names aligned after it, rows 28 tall (no disc to hold).
/// C: the header as A's; rows drop the disc and keep the mark before the shortcut, names under the header's name.
struct VariantTree: View {
    enum Style { case indented, narrow, trailing, rightIcon, narrowRight, trailingAfter, narrowOut, trailingOut, rightName, rightNameFlat }
    private var nameRight: Bool { style == .rightName || style == .rightNameFlat }
    private var narrowish: Bool { style == .narrow || style == .narrowRight || style == .narrowOut }
    private var iconRight: Bool { style == .rightIcon || style == .narrowRight || style == .narrowOut }
    let model: SidebarModel
    let style: Style
    var body: some View {
        VStack(spacing: narrowish ? 8 : 11) {
            ForEach(model.groups, id: \.0) { host, spaces in
                VStack(spacing: 2) {
                    header(host)
                    ForEach(spaces) { row($0) }
                }
                .opacity(host.offline ? 0.65 : 1)
            }
        }
    }

    private var p: SidebarPalette { Chrome.palette }
    private var icon: CGFloat { style == .narrow ? 15 : 14 }

    @ViewBuilder private func header(_ host: MockHost) -> some View {
        let color = host.tint?.foreground ?? p.secondary
        if nameRight {
            HStack(spacing: 6) {
                Text(host.local ? "Local" : host.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                if host.offline { Text("offline").font(.system(size: 11)).foregroundStyle(p.muted) }
                Spacer()
                MockHostGlyph(system: host.system, size: 15).foregroundStyle(color)
            }
            .padding(.leading, style == .rightNameFlat ? 4 : 10).padding(.trailing, 10)
            .frame(height: 22)
        } else {
            plainHeader(host, color)
        }
    }

    private func plainHeader(_ host: MockHost, _ color: Color) -> some View {
        HStack(spacing: narrowish ? 8 : 6) {
            if style == .narrowRight {
                Color.clear.frame(width: 16, height: 1)
            } else if style != .rightIcon && style != .trailingAfter && style != .narrowOut && style != .trailingOut {
                MockHostGlyph(system: host.system, size: icon).foregroundStyle(color).frame(width: style == .narrow ? 16 : icon)
            }
            Text(host.local ? "Local" : host.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            if style == .trailingAfter || style == .trailingOut { MockHostGlyph(system: host.system, size: 13).foregroundStyle(color) }
            if host.offline { Text("offline").font(.system(size: 11)).foregroundStyle(p.muted) }
            Spacer()
            if iconRight {
                MockHostGlyph(system: host.system, size: 15).foregroundStyle(color)
            } else {
                TreeGroupPlus()
            }
        }
        .padding(.leading, style == .trailingOut ? 4 : 10).padding(.trailing, iconRight ? 10 : 0)
        .frame(height: 22)
    }

    private func row(_ space: SpaceItem) -> some View {
        let activity = space.activity == .quiet ? Activity.none : space.activity
        let tint = space.host.tint
        return HStack(spacing: 8) {
            switch style {
            case .indented:
                activity.glyph().frame(width: 14)
                name(space)
            case .narrow, .rightIcon, .narrowRight, .narrowOut:
                activity.glyph().frame(width: 16)
                name(space)
            case .trailing, .trailingAfter, .trailingOut, .rightName, .rightNameFlat:
                name(space)
                activity.glyph()
            }
            Text(space.shortcut.map { "⇧⌘\($0)" } ?? "·")
                .font(.system(size: 12.5).monospacedDigit()).tracking(0.75).foregroundStyle(p.secondary.opacity(0.7))
        }
        .interfaceFont(size: 13.5)
        .foregroundStyle(space.selected ? p.ink : p.secondary)
        // A: the mark under the header's name; B: under the header's icon; C: the name under the header's name.
        .padding(.leading, style == .trailingOut ? 34 : style == .indented || style == .trailing || style == .trailingAfter || style == .rightName ? 30 : 10).padding(.trailing, 10)
        .frame(height: narrowish ? 28 : 30)
        .background(RoundedRectangle(cornerRadius: narrowish ? 10 : 11).fill(
            space.selected ? (tint.map { $0.foreground.opacity(0.16) } ?? p.selection) : .clear))
    }

    private func name(_ space: SpaceItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(space.name).lineLimit(1)
            if let branch = space.branch { Text(branch).interfaceFont(size: 11).foregroundStyle(p.sidebarDetail).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
