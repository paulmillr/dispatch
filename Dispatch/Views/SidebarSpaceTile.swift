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
    /// Large flat tiles for another host carry the host on a second line.
    let hostLineRowHeight: CGFloat
    let rowSpacing: CGFloat
    let groupSpacing: CGFloat
    let activitySize: CGFloat
    let hostIconSize: CGFloat
    let cornerRadius: CGFloat
    let headerSize: CGFloat
    let headerHeight: CGFloat

    /// Large items follow the content font a point and a half larger: 14-point names at the default 12.5, with or
    /// without Liquid Glass. Heights and gaps grow with the font like the tab strip's, and never shrink below their
    /// default sizes. Both looks share one size; flat rows sit on the bare sidebar, so they keep a little more room
    /// between them than glass rows nested in their panel.
    static func large(contentSize: CGFloat, glass: Bool = false) -> SidebarMetrics {
        let name = max(10, contentSize + 1.5), scale = max(1, contentSize / 12.5)
        func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }
        return SidebarMetrics(large: true, nameSize: name, detailSize: max(8, name - 3), shortcutSize: max(8, name - 2),
                              rowHeight: scaled(32), hostLineRowHeight: scaled(46), rowSpacing: glass ? scaled(4) : scaled(8),
                              groupSpacing: scaled(10), activitySize: scaled(14), hostIconSize: max(8, name - 3),
                              cornerRadius: 9, headerSize: max(8, name - 3), headerHeight: scaled(18))
    }

    /// On Liquid Glass the rows nest in the panel with corners concentric to it.
    func nested(cornerRadius: CGFloat) -> SidebarMetrics {
        SidebarMetrics(large: large, nameSize: nameSize, detailSize: detailSize, shortcutSize: shortcutSize,
                       rowHeight: rowHeight, hostLineRowHeight: hostLineRowHeight, rowSpacing: rowSpacing,
                       groupSpacing: groupSpacing, activitySize: activitySize, hostIconSize: hostIconSize,
                       cornerRadius: cornerRadius, headerSize: headerSize, headerHeight: headerHeight)
    }

    /// Compact text follows the terminal font a point smaller, which keeps it below the large sidebar.
    static func compact(contentSize: CGFloat) -> SidebarMetrics {
        let name = max(8, contentSize - 1)
        return SidebarMetrics(large: false, nameSize: name, detailSize: max(8, name - 1.5), shortcutSize: max(8, name - 1),
                              rowHeight: (name + 9).rounded(), hostLineRowHeight: (name + 9).rounded(), rowSpacing: 0,
                              groupSpacing: 6, activitySize: 10, hostIconSize: 10, cornerRadius: 4,
                              headerSize: max(8, name - 2), headerHeight: 14)
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

    private var tint: Color { host.tint?.foreground ?? Chrome.palette.secondary }
    /// Local is the default, so only other hosts earn a host line on large flat tiles.
    private var showsHostLine: Bool { metrics.large && !grouped && (host.id != .local || mixedHost != nil) }
    private var selectedFill: Color { host.tint.map { $0.foreground.opacity(0.16) } ?? Chrome.palette.selection }
    private var label: SpaceBranchName {
        SpaceBranchName(space: space, showBranch: showBranch, fontSize: metrics.nameSize,
                        inline: true, branchFontSize: metrics.detailSize, branch: branch,
                        branchColor: selected ? Chrome.palette.sidebarDetail : Chrome.palette.detail)
    }

    private var activity: some View {
        AgentActivityGlyph(tabIDs: space.tabs.flatMap(\.surfaceIDs),
                           connecting: connecting, size: metrics.activitySize, tile: metrics.large)
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

    /// Without a host line, another host shows as icons before the shortcut.
    @ViewBuilder private var inlineHostIcons: some View {
        if !showsHostLine {
            if !grouped && host.id != .local {
                glyph(host).help(host.name)
                    .accessibilityLabel("\(host.name) · \(host.system?.label ?? "Remote host, OS unavailable")")
            }
            if let mixedHost { mixedGlyph(mixedHost) }
        }
    }

    private var shortcutLabel: some View {
        Text(shortcut.isEmpty ? "·" : shortcut)
            .font(.system(size: metrics.shortcutSize).monospacedDigit()).tracking(metrics.shortcutSize * 0.06)
            .foregroundStyle(Chrome.palette.secondary.opacity(0.7))
            .accessibilityLabel(shortcut.isEmpty ? "No jump shortcut" : "Jump to space: \(shortcut)")
    }

    /// Large flat tiles on another host: the host name, then its icon, under the space name.
    private var hostLine: some View {
        HStack(spacing: 6) {
            Text(host.id == .local ? "LOCAL" : host.name.uppercased())
                .font(AppFont.ui(size: metrics.headerSize)).tracking(metrics.headerSize * 0.08)
                .foregroundStyle(host.id == .local ? Chrome.palette.sidebarHostLabel : tint)
                .lineLimit(1).truncationMode(.middle)
            HostGlyph(host: host, size: metrics.hostIconSize)
                .foregroundStyle(tint)
                .help(host.id == .local ? "Local" : host.details)
            if let mixedHost { mixedGlyph(mixedHost) }
        }
    }

    var body: some View {
        // Status, name, branch (when shown), host icons and jump shortcut;
        // a large flat tile on another host adds its host line below.
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                activity
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    label.name
                    label.branchLine
                }.frame(maxWidth: .infinity, alignment: .leading)
                inlineHostIcons
                shortcutLabel.fixedSize()
            }.frame(height: metrics.large ? metrics.nameSize + 8 : nil)
            if showsHostLine {
                // Under the name, past the status column (the tile glyph's width plus the row's spacing).
                hostLine.padding(.leading, metrics.activitySize + 14)
            }
        }
        .font(AppFont.ui(size: metrics.nameSize))
        .foregroundStyle(selected ? Chrome.ink : Chrome.palette.secondary)
        .padding(.leading, metrics.large ? 8 : 6).padding(.trailing, metrics.large ? 12 : 8)
        .frame(height: showsHostLine ? metrics.hostLineRowHeight : metrics.rowHeight)
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
