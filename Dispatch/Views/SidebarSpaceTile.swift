import SwiftUI

/// The large and compact sidebars share one layout; only these numbers differ.
/// Large follows shell.dc.html (S3c flat, S4h host groups); compact keeps its
/// structure with smaller type and no gaps between rows.
struct SidebarMetrics: Equatable, Sendable {
    let large: Bool
    let nameSize: CGFloat
    let detailSize: CGFloat
    let shortcutSize: CGFloat
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let groupSpacing: CGFloat
    let activitySize: CGFloat
    let hostIconSize: CGFloat
    let cornerRadius: CGFloat
    let headerSize: CGFloat
    let headerHeight: CGFloat
    /// The host picker's rows (SidebarStyle.icons): each led by its host's icon, groups headed by name alone.
    var icons = false
    /// The icon's disc, in the icons style.
    var discSize: CGFloat = 0

    /// Large's cards (SidebarSpaceCard): names a point and a half above the content font, 14 points at the default
    /// 12.5, over a details line; the host's icon in a 32-point orb. Cards sit 6 points apart and host groups 16, under
    /// glass chip headers. Sizes grow with the font like the tab strip's and never shrink below their defaults; the
    /// same with or without Liquid Glass.
    static func large(contentSize: CGFloat, glass: Bool = false) -> SidebarMetrics {
        let name = max(10, contentSize + 1.5), scale = max(1, contentSize / 12.5)
        func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        return SidebarMetrics(large: true, nameSize: name, detailSize: max(8, name - 3), shortcutSize: max(8, name - 3),
                              rowHeight: scaled(58), rowSpacing: scaled(6),
                              groupSpacing: scaled(16), activitySize: max(8, name - 4),
                              hostIconSize: AppTypography(contentSize: contentSize).hostIconSize,
                              cornerRadius: scaled(14), headerSize: max(8, name - 3), headerHeight: scaled(26),
                              discSize: scaled(32))
    }

    /// Large's glass cards: large items that aren't the icons style.
    var cards: Bool { large && !icons }
    /// How far a row's jump shortcut text ends from the row's trailing edge: the row's padding, or on a card its
    /// padding and the keycap's. Tree headers end their new-space shortcut here too, so the keys share a column.
    var shortcutInset: CGFloat { cards ? 17 : icons ? 10 : 8 }

    /// On Liquid Glass the rows nest in the panel with corners concentric to it.
    func nested(cornerRadius: CGFloat) -> SidebarMetrics {
        SidebarMetrics(large: large, nameSize: nameSize, detailSize: detailSize, shortcutSize: shortcutSize,
                       rowHeight: rowHeight, rowSpacing: rowSpacing,
                       groupSpacing: groupSpacing, activitySize: activitySize, hostIconSize: hostIconSize,
                       cornerRadius: cornerRadius, headerSize: headerSize, headerHeight: headerHeight,
                       icons: icons, discSize: discSize)
    }

    /// The host picker's rows (StripSpacePicker) at the sidebar's width: names at the sidebar font, a point and a half
    /// below large names, each row led by its host's icon on a disc and ending with its activity and shortcut. Rows sit
    /// 2 points apart and host groups 10, as in the picker; sizes grow with the font like the large tiles'.
    static func icons(contentSize: CGFloat) -> SidebarMetrics {
        let name = max(8, contentSize - 0.5), scale = max(1, contentSize / 12.5)
        func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        let disc = scaled(22)
        return SidebarMetrics(large: true, nameSize: name, detailSize: max(8, name - 2.5), shortcutSize: max(8, name - 1),
                              rowHeight: disc + 8, rowSpacing: 2, groupSpacing: scaled(10),
                              activitySize: max(8, contentSize - 3), hostIconSize: AppTypography(contentSize: contentSize).hostIconSize,
                              cornerRadius: scaled(12), headerSize: max(8, contentSize - 3), headerHeight: scaled(18),
                              icons: true, discSize: disc)
    }

    /// Compact text follows the terminal font a point smaller, which keeps it below the large sidebar. Host headers
    /// grow with the font like the other styles', so their heading never runs into the first row.
    static func compact(contentSize: CGFloat) -> SidebarMetrics {
        let name = max(8, contentSize - 1), scale = max(1, contentSize / 12.5)
        return SidebarMetrics(large: false, nameSize: name, detailSize: max(8, name - 1.5), shortcutSize: max(8, name - 1),
                              rowHeight: (name + 9).rounded(), rowSpacing: 0,
                              groupSpacing: 6, activitySize: 10, hostIconSize: AppTypography(contentSize: contentSize).hostIconSize, cornerRadius: 4,
                              headerSize: max(8, name - 2), headerHeight: (14 * scale).rounded())
    }
}

/// One space in the sidebar, in either density.
struct SidebarSpaceTile: View {
    let space: Space
    let host: HostRecord
    let mixedHost: HostRecord?
    let grouped: Bool
    let selected: Bool
    var pending = false
    let shortcut: String
    let connecting: Bool
    let branch: String?
    var showBranch = true
    var metrics = SidebarMetrics.large(contentSize: 12.5)
    var selection: Namespace.ID?
    @State private var hovered = false

    private var selectedFill: Color { host.tint.map { $0.foreground.opacity(0.16) } ?? Chrome.palette.selection }
    private var label: SpaceBranchName {
        SpaceBranchName(space: space, showBranch: showBranch, fontSize: metrics.nameSize,
                        inline: true, branchFontSize: metrics.detailSize, branch: branch,
                        branchColor: selected ? Chrome.palette.sidebarDetail : Chrome.palette.detail)
    }

    private var activity: some View {
        AgentActivityGlyph(tabIDs: space.tabs.flatMap(\.surfaceIDs),
                           connecting: connecting, size: metrics.activitySize)
            .fixedSize()
    }

    private func glyph(_ host: HostRecord) -> some View {
        HostGlyph(host: host, size: metrics.hostIconSize)
            .frame(width: metrics.hostIconSize)
            .foregroundStyle(host.tint?.foreground ?? Chrome.muted)
    }

    private func mixedGlyph(_ mixedHost: HostRecord) -> some View {
        glyph(mixedHost)
            .help("This terminal is connected to \(mixedHost.name). Its backend placement could not be changed.")
            .accessibilityLabel("Terminal connected to \(mixedHost.name)")
    }

    /// Another host shows as icons before the shortcut.
    @ViewBuilder private var inlineHostIcons: some View {
        if !grouped && host.id != .local {
            glyph(host).help(host.name)
                .accessibilityLabel("\(host.name) · \(host.system?.label ?? "Remote host, OS unavailable")")
        }
        if let mixedHost { mixedGlyph(mixedHost) }
    }

    private var shortcutLabel: some View {
        Text(shortcut.isEmpty ? "·" : shortcut)
            .font(.system(size: metrics.shortcutSize).monospacedDigit()).tracking(metrics.shortcutSize * 0.06)
            .foregroundStyle(Chrome.palette.secondary.opacity(0.7))
            .accessibilityLabel(shortcut.isEmpty ? "No jump shortcut" : "Jump to space: \(shortcut)")
    }

    /// The icons style, as the host picker draws a space: its host's icon on a disc, the name and branch, then any
    /// other host its terminals reach, its activity and its jump shortcut. Every row carries its icon, in groups too.
    private var iconsRow: some View {
        HStack(spacing: 9) {
            HostGlyph(host: host, size: metrics.hostIconSize)
                .foregroundStyle(host.tint?.foreground ?? Chrome.palette.secondary)
                .frame(width: metrics.discSize, height: metrics.discSize)
                // On the selected row's fill a plain disc: no glass on the selection.
                .background { if selected { Circle().fill(host.tint?.glassWash ?? Chrome.palette.hover) } }
                .liquidGlass(in: Circle(), fallback: selected ? nil : Chrome.palette.hover, tint: host.tint?.glassWash,
                             enabled: !selected)
                .help(host.id == .local ? "Local" : host.details)
                .accessibilityLabel(host.id == .local ? "Local" : "\(host.name) · \(host.system?.label ?? "Remote host, OS unavailable")")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                label.name
                label.branchLine
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let mixedHost { mixedGlyph(mixedHost) }
            AgentActivityGlyph(tabIDs: space.tabs.flatMap(\.surfaceIDs), connecting: connecting, size: metrics.activitySize)
                .fixedSize()
            shortcutLabel.fixedSize()
        }
    }

    var body: some View {
        if metrics.cards {
            SidebarSpaceCard(space: space, host: host, mixedHost: mixedHost, selected: selected, pending: pending,
                             shortcut: shortcut, connecting: connecting, branch: branch, showBranch: showBranch,
                             metrics: metrics, selection: selection)
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        // The compact row (status, name, branch when shown, host icons and jump shortcut) or the icons style's.
        Group {
            if metrics.icons {
                iconsRow
            } else {
                HStack(spacing: 6) {
                    activity
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        label.name
                        label.branchLine
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    inlineHostIcons
                    shortcutLabel.fixedSize()
                }
            }
        }
        .font(AppFont.ui(size: metrics.nameSize))
        .foregroundStyle(selected ? Chrome.ink : Chrome.palette.secondary)
        .padding(.leading, metrics.icons ? 5 : 6).padding(.trailing, metrics.shortcutInset)
        .frame(height: metrics.rowHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius)
            if selected {
                if let selection {
                    shape.fill(selectedFill).matchedGeometryEffect(id: "space-selection", in: selection)
                } else {
                    shape.fill(selectedFill)
                }
            } else if hovered {
                shape.fill(Chrome.palette.hover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
        .modifier(AttentionMotion(pending: pending, cornerRadius: metrics.cornerRadius))
        .onHover { hovered = $0 }
    }
}


/// Large's space: a two-line glass card. The host's icon sits in an orb of its color; the name and a keycap shortcut
/// lead, over a details line (host, branch, tabs) and the agents' status in a word. On Liquid Glass every card is its
/// own glass, the selected one interactive and tinted with its host with a soft glow of that color; without it the
/// same card is drawn with translucent fills and a specular edge. The selection slides between cards as rows' does.
struct SidebarSpaceCard: View {
    let space: Space
    let host: HostRecord
    let mixedHost: HostRecord?
    let selected: Bool
    var pending = false
    let shortcut: String
    let connecting: Bool
    let branch: String?
    var showBranch = true
    let metrics: SidebarMetrics
    var selection: Namespace.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var glass: Bool { LiquidGlassStore.shared.active }
    private var dark: Bool { Chrome.palette.isDark }
    /// The host's color; local cards stay neutral.
    private var hue: Color? { host.tint?.foreground }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous) }

    var body: some View {
        let activity = AgentActivity(tabIDs: space.tabs.flatMap(\.surfaceIDs), connecting: connecting)
        HStack(spacing: 11) {
            orb
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(space.name)
                        .font(Font(AppFont.native(size: metrics.nameSize, semibold: selected)))
                        .foregroundStyle(selected ? Chrome.ink : Chrome.palette.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    keycap
                }
                // The fullest details line that fits: the tab count goes first, then the status's word for its glyph;
                // the last choice truncates the host and branch if it must.
                ViewThatFits(in: .horizontal) {
                    detailsLine(tabs: true, status: activity.label, activity: activity)
                    detailsLine(tabs: false, status: activity.label, activity: activity)
                    detailsLine(tabs: false, status: nil, activity: activity)
                }
            }
        }
        .padding(.leading, 9).padding(.trailing, 11)
        .frame(height: metrics.rowHeight)
        .background { surface }
        .overlay { edge }
        .contentShape(shape)
        // Lifts a little under the pointer; Reduce Motion keeps it still.
        .scaleEffect(hovered && !selected && !reduceMotion ? 1.012 : 1)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.15), value: hovered)
        .modifier(AttentionMotion(pending: pending, cornerRadius: metrics.cornerRadius, bar: false))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }

    /// The host's icon in a soft orb of its color: glass on Liquid Glass, a gradient without it.
    private var orb: some View {
        let size = metrics.discSize
        return HostGlyph(host: host, size: metrics.hostIconSize)
            .foregroundStyle(hue ?? Chrome.palette.secondary)
            .frame(width: size, height: size)
            .background {
                Circle().fill(RadialGradient(colors: [(hue ?? Chrome.ink).opacity(dark ? 0.26 : 0.18),
                                                      (hue ?? Chrome.ink).opacity(dark ? 0.08 : 0.05)],
                                             center: .topLeading, startRadius: 0, endRadius: size))
            }
            .overlay { Circle().strokeBorder((hue ?? Chrome.ink).opacity(selected ? 0.45 : 0.2), lineWidth: 1) }
            .liquidGlass(in: Circle(), tint: host.tint?.glassWash)
            .help(host.id == .local ? "Local" : host.details)
            .accessibilityLabel(host.id == .local ? "Local" : "\(host.name) · \(host.system?.label ?? "Remote host, OS unavailable")")
    }

    /// The jump shortcut as a small keycap; none while the space has no key.
    @ViewBuilder private var keycap: some View {
        if !shortcut.isEmpty {
            Text(shortcut)
                .font(.system(size: metrics.shortcutSize).monospacedDigit()).tracking(metrics.shortcutSize * 0.04)
                .foregroundStyle(Chrome.palette.secondary.opacity(selected ? 0.95 : 0.7))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Chrome.ink.opacity(dark ? 0.07 : 0.05), in: Capsule())
                .overlay { Capsule().strokeBorder(Chrome.ink.opacity(dark ? 0.1 : 0.08), lineWidth: 0.5) }
                .fixedSize()
                .accessibilityLabel("Jump to space: \(shortcut)")
        }
    }

    private func detailsLine(tabs: Bool, status: String?, activity: AgentActivity) -> some View {
        HStack(spacing: 6) {
            details(tabs: tabs)
            Spacer(minLength: 0)
            if activity.label != nil { statusPill(status, activity: activity) }
        }
    }

    /// Another host's name (and one a terminal reaches besides it), the branch, and how many tabs; the host's name
    /// outlasts the branch.
    private func details(tabs: Bool) -> some View {
        let count = space.tabs.count
        return HStack(spacing: 5) {
            if host.id != .local {
                Text(host.name).foregroundStyle(hue ?? detailColor).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
            }
            if let mixedHost {
                HostGlyph(host: mixedHost, size: metrics.detailSize + 2).foregroundStyle(mixedHost.tint?.foreground ?? Chrome.muted)
                    .help("This terminal is connected to \(mixedHost.name). Its backend placement could not be changed.")
                    .accessibilityLabel("Terminal connected to \(mixedHost.name)")
            }
            if showBranch, branch != nil {
                if host.id != .local { separator }
                SpaceBranchName(space: space, showBranch: true, fontSize: metrics.nameSize,
                                branchFontSize: metrics.detailSize, branch: branch, branchColor: detailColor).branchLine
            }
            if tabs {
                if host.id != .local || (showBranch && branch != nil) { separator }
                Text(count == 1 ? "1 tab" : "\(count) tabs").foregroundStyle(detailColor).fixedSize()
            }
        }
        .font(AppFont.ui(size: metrics.detailSize))
        .lineLimit(1)
    }

    private var separator: some View { Text("·").foregroundStyle(detailColor.opacity(0.6)) }
    /// Details stay legible over a card's glass and its host's tint.
    private var detailColor: Color { Chrome.palette.secondary.opacity(selected ? 0.8 : 0.62) }

    /// The agents' status in a word on a pill of its color, with the glyph the other styles show; the glyph alone when
    /// `label` is nil.
    private func statusPill(_ label: String?, activity: AgentActivity) -> some View {
        let color = activity.reconnecting ? Chrome.palette.warning : activity.offline ? Chrome.muted
            : activity.blocked || activity.failed ? Chrome.palette.warning : activity.finished ? Chrome.accent : Chrome.ink
        return HStack(spacing: 4) {
            AgentActivityGlyph(tabIDs: space.tabs.flatMap(\.surfaceIDs), connecting: connecting, size: metrics.activitySize)
                .fixedSize()
            if let label { Text(label).foregroundStyle(color).lineLimit(1) }
        }
        .font(AppFont.ui(size: metrics.detailSize))
        .padding(.horizontal, 6).padding(.vertical, 1.5)
        .background(color.opacity(dark ? 0.14 : 0.1), in: Capsule())
        .fixedSize()
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    /// The card's body: its own glass on Liquid Glass, interactive and host-tinted while selected, with the selection
    /// sliding from card to card; without glass, translucent fills.
    @ViewBuilder private var surface: some View {
        let selectedWash = hue.map { $0.opacity(dark ? 0.16 : 0.1) } ?? Chrome.ink.opacity(dark ? 0.09 : 0.06)
        ZStack {
            if glass {
                Color.clear.liquidGlass(in: shape, interactive: selected,
                                        tint: selected ? (host.tint?.glassWash ?? Chrome.ink.opacity(0.06)) : nil)
            } else {
                shape.fill(Chrome.ink.opacity(hovered ? (dark ? 0.06 : 0.045) : (dark ? 0.035 : 0.025)))
            }
            if selected {
                if let selection {
                    shape.fill(selectedWash).matchedGeometryEffect(id: "space-selection", in: selection)
                } else {
                    shape.fill(selectedWash)
                }
            }
        }
        // A soft glow of another host's color under its selected card; local cards stay neutral.
        .shadow(color: selected ? (hue?.opacity(dark ? 0.3 : 0.18) ?? .clear) : .clear, radius: 12, y: 4)
    }

    /// A specular edge: brighter along the top, as light catches glass; the host's color while selected, the attention
    /// accent while the space needs you.
    private var edge: some View {
        let accent = pending ? InterfaceMotion.accent : selected ? hue : nil
        let top = accent.map { $0.opacity(pending ? 0.7 : 0.55) } ?? Color.white.opacity(dark ? (hovered || selected ? 0.18 : 0.1) : 0.5)
        let bottom = accent.map { $0.opacity(0.2) } ?? Color.white.opacity(dark ? 0.03 : 0.15)
        return shape.strokeBorder(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}
