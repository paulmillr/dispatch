import SwiftUI
import AppKit

/// One tab in a pane or tmux window strip. Callers own selection, hover, reorder, and menus.
struct StripTab: View {
    /// Both share Terminal's layout and differ in how they mark the selected tab: flat chrome's `.strip` with a rule
    /// along the bar's bottom edge (in a window and full screen alike), Liquid Glass's `.outlined` with a glass pill.
    enum Style { case strip, outlined }
    @Environment(\.appTypography) private var typography
    let title: String
    let activityIDs: [UUID]
    let connecting: Bool
    let shortcut: Space.TabShortcut?
    let width: CGFloat
    let selected: Bool
    let hovered: Bool
    let hostTint: HostTint?
    let closeHelp: String
    let select: () -> Void
    let close: () -> Void
    var style: Style = .strip
    /// A hairline after this tab, which callers decide with `divider(after:in:selected:)`.
    var divider = false
    /// The strip's only tab: with nothing to tell it apart from, it drops its selection mark.
    var alone = false

    static let closeButtonWidth: CGFloat = 24
    /// The close button's leading slot, which a reorder overlay leaves clickable.
    static let closeSlotWidth: CGFloat = closeButtonWidth + 2

    /// The glass capsule a windowed strip's tabs sit on while Liquid Glass is active: 28 points in the 38-point strip,
    /// leaving 5 above and below, as tall as macOS's own tab bar track. The button pill shares it, so the strip's glass
    /// reads as one row.
    static func glassTrackHeight(_ typography: AppTypography) -> CGFloat { typography.expanded(28) }

    /// Tabs split the strip equally, as in Terminal's tab bar, until they reach this width; then the strip scrolls.
    static func minimumWidth(_ typography: AppTypography) -> CGFloat { typography.expanded(120) }

    static func width(count: Int, viewport: CGFloat, typography: AppTypography) -> CGFloat {
        let minimum = minimumWidth(typography)
        guard viewport > 0 else { return minimum }
        return max(min(minimum, viewport), viewport / CGFloat(max(1, count)))
    }

    /// A hairline between two unselected tabs; the selected tab's outline separates it from its neighbours.
    static func divider<ID: Equatable>(after id: ID, in ids: [ID], selected: ID?) -> Bool {
        guard let index = ids.firstIndex(of: id), index + 1 < ids.count else { return false }
        return id != selected && ids[index + 1] != selected
    }

    /// The legend's text: a numbered tab's key, or the tab step keys (⌘] / ⌘[ by default) for the focused split's
    /// neighbours; nil while tabs are unbound, which leaves them no key.
    @MainActor private static func legendText(_ shortcut: Space.TabShortcut) -> String? {
        let keys = KeyGroupsStore.shared.current
        switch shortcut {
        case .number(let number): return keys.shortcut(\.tabs, String(number))
        case .next: return keys.steps.tabs.map { KeyGroups.symbols($0) + "]" }
        case .previous: return keys.steps.tabs.map { KeyGroups.symbols($0) + "[" }
        }
    }

    @MainActor private static func legendWidth(_ legend: String?, typography: AppTypography) -> CGFloat {
        legend.map { legend in
            8 + (legend as NSString)
                .size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: typography.size(offset: -2.5), weight: .regular)]).width
        } ?? 0
    }

    /// Terminal's layout: a centred title, and the close button in place of the status glyph while hovered.
    var body: some View {
        // Both side slots reserve the wider of the two, so the title stays centred on the tab.
        let legend = width >= 110 ? shortcut.flatMap(Self.legendText) : nil
        let side = max(Self.closeButtonWidth, Self.legendWidth(legend, typography: typography)) + 4
        // Glass marks the selected tab with its own pill and a semibold title, as macOS's tab bar does; Source Code
        // Pro keeps one advance width across weights, so the title neither shifts nor truncates differently.
        let glassSelected = selected && style == .outlined && !alone && LiquidGlassStore.shared.active
        return ZStack {
            Button(action: select) {
                Text(title).font(Font(AppFont.native(size: typography.tabSize, semibold: glassSelected)))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, width >= 100 ? side : Self.closeButtonWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            // The selection outline marks the tab; a focus ring around it would read as a second selection.
            .focusEffectDisabled()
            HStack(spacing: 0) {
                ZStack {
                    if hovered { closeButton }
                    else if width >= 100 || connecting { AgentActivityGlyph(tabIDs: activityIDs, connecting: connecting) }
                }.frame(width: Self.closeButtonWidth)
                Spacer(minLength: 0)
                if let legend { legendView(legend).padding(.trailing, 10) }
            }.padding(.leading, 2)
        }
        // Strip tabs fill their 30-point bar so the selected rule sits on its bottom edge and stays put between local
        // and remote tabs.
        .frame(width: width, height: style == .strip ? nil : Self.glassTrackHeight(typography))
        .frame(minHeight: style == .strip ? typography.expanded(30) : nil, maxHeight: style == .strip ? .infinity : nil)
        .modifier(SelectedTabGlass(on: glassSelected))
        .overlay(alignment: .bottom) {
            if selected && style == .strip && !alone {
                Rectangle().fill(hostTint == nil ? Chrome.ink.opacity(0.7) : HostTint.selectedTabRule)
                    .frame(height: 1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if divider {
                Rectangle().fill(Chrome.border).frame(width: 1, height: typography.expanded(style == .outlined ? 16 : 14))
                    .offset(x: 0.5).allowsHitTesting(false)
            }
        }
        .foregroundStyle(selected ? Chrome.ink : (hostTint?.tabForeground ?? Chrome.muted))
        .contentShape(Rectangle())
    }

    private func legendView(_ legend: String) -> some View {
        Text(legend).font(typography.shortcut(offset: -2.5)).foregroundStyle(Chrome.muted)
    }

    private var closeButton: some View {
        Button(action: close) {
            CloseGlyph().frame(width: Self.closeButtonWidth, height: typography.expanded(26)).contentShape(Rectangle())
        }.fixedSize().focusEffectDisabled().accessibilityLabel("Close \(title)")
            .help(closeHelp)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
    }
}

/// The close cross, on a small rounded square while the pointer is over it, as in Terminal's tabs.
struct CloseGlyph: View {
    @Environment(\.appTypography) private var typography
    @State private var hovered = false
    var body: some View {
        let size = typography.expanded(16)
        Image(systemName: "xmark").font(AppFont.ui(size: 8))
            .frame(width: size, height: size)
            .background(Chrome.ink.opacity(hovered ? (Chrome.palette.isDark ? 0.16 : 0.1) : 0), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onHover { hovered = $0 }
    }
}

/// The selected tab's own glass pill on a glass strip, inset 2 points inside the track as macOS's tab bar insets its
/// tabs; it answers the pointer.
private struct SelectedTabGlass: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.liquidGlass(in: Capsule().inset(by: 2), interactive: true) } else { content }
    }
}

/// The host a glass strip leads with (StripHostMark).
struct StripHost {
    /// The registry's record, or nil while it has none for a remote tab (the glyph falls back to a server).
    var record: HostRecord?
    /// Nil while the active tab is local.
    var tint: HostTint?
    /// The active tab is connecting or reconnecting: the mark pulses until it lands.
    var connecting = false
    /// Which host the mark shows: a change swaps its glyph with motion (StripHostMark).
    var key: String { record?.id.rawValue ?? "remote" }
    /// A connection not yet identified: its color is a placeholder, so the mark stays neutral until the real host
    /// arrives and swaps in.
    var provisional: Bool { record?.id.isProvisional == true }
}

/// While the sidebar is hidden, leads a lone strip's tabs, or a split layout's first pane's, while any of them is
/// remote: the active tab's host glyph in the host color, or the Mac's, muted, while that tab is local, so the tabs keep
/// their place across tab switches. With other spaces to switch to, it shows the Mac's on local strips too. Glass otherwise
/// shows the host only as a faint wash, where flat chrome has the pane's solid edge. On glass it is a circle of its own
/// before the track (on a split pane's capsule, a circle on the capsule), `gap` points from it; flat, a plain circle.
/// Clicking it, or a secondary click, opens the space picker (StripSpacePicker). Leading the window it also stands in
/// for the sidebar toggle, which the picker carries.
struct StripHostMark: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let host: StripHost
    let workspace: Workspace
    let controller: AppDelegate
    /// Told when the picker opens and closes, e.g. to keep a revealed mark showing while it is open.
    var presentedChanged: ((Bool) -> Void)?
    @State private var presented = false

    /// A remote tab whose host the registry has no record for yet: a server, as for any unidentified system.
    private static let unknownHost = HostRecord(id: HostID(rawValue: "remote"), name: "Remote", destinations: [], order: .max)
    /// The gap between the mark and the track, matching the glass group's blend spacing.
    static let gap: CGFloat = 4
    /// The mark's circle: on glass as tall as the track, flat as tall as the flat new-tab button. The full-screen
    /// sidebar button is a circle this size too.
    @MainActor static func size(_ typography: AppTypography) -> CGSize {
        let side = LiquidGlassStore.shared.active ? StripTab.glassTrackHeight(typography) : typography.expanded(26)
        return CGSize(width: side, height: side)
    }
    /// The mark and its gap: what the track gives up for it.
    @MainActor static func width(_ typography: AppTypography) -> CGFloat { size(typography).width + gap }

    /// The glyph's color: the host's, muted while offline or not yet identified.
    private var color: Color { host.provisional ? Chrome.muted : host.tint?.foreground ?? Chrome.muted }

    var body: some View {
        let name = host.tint == nil ? "Local" : host.provisional ? "Connecting" : host.record?.name ?? "Remote"
        let size = Self.size(typography)
        Button { presented.toggle() } label: {
            // A new host swaps the glyph: the old one swells away as the new one springs in, and a ring in the new
            // host's color ripples out, as the sidebar's rows move between host groups. While the tab connects the
            // glyph dims under a pulse, so the connection landing reads as the same motion finishing.
            ZStack {
                Group {
                    HostGlyph(host: host.record ?? Self.unknownHost, size: typography.hostIconSize)
                }
                .foregroundStyle(color)
                .opacity(host.connecting ? 0.55 : 1)
                .id(host.key)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 0.3).combined(with: .opacity),
                    removal: .scale(scale: 1.6).combined(with: .opacity)))
            }
            .frame(width: size.width, height: size.height)
            .modifier(HostMarkEffectsPlacement(trigger: host.key, color: color, connecting: host.connecting))
            .modifier(StripHostMarkSurface(tint: host.provisional ? nil : host.tint?.glassWash))
            .animation(reduceMotion ? .easeOut(duration: InterfaceMotion.hostSwitchDuration)
                                    : .spring(response: 0.34, dampingFraction: 0.62), value: host.key)
            // Going offline or coming back eases the color, at the pane edge's pace (HostTintBorder).
            .animation(.easeOut(duration: 0.36), value: host.tint?.offline)
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: host.connecting)
        }
        .buttonStyle(.plain)
        .overlay { HostSecondaryClick(identifier: "strip-host-secondary") { presented = true } }
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            StripSpacePicker(workspace: workspace, controller: controller) { presented = false }
        }
        .onChange(of: presented) { _, value in presentedChanged?(value) }
        .help((host.tint?.offline == true ? "\(name) · offline" : name) + "\nClick to switch spaces")
        .accessibilityLabel("Host \(name)")
        .accessibilityHint("Switch spaces")
        .accessibilityIdentifier("strip-host")
        .padding(.trailing, Self.gap)
    }
}

/// Where the mark's ripple and pulse draw: behind it, or on a split pane's capsule, which clips what it holds, over
/// the strip instead (TabBar reads HostMarkEffectsAnchor).
private struct HostMarkEffectsPlacement: ViewModifier {
    let trigger: String
    let color: Color
    let connecting: Bool
    @Environment(\.stripActionsMerged) private var onCapsule

    func body(content: Content) -> some View {
        if onCapsule && LiquidGlassStore.shared.active {
            content.anchorPreference(key: HostMarkEffectsAnchor.self, value: .bounds) {
                HostMarkEffectsAnchor.Effects(bounds: $0, trigger: trigger, color: color, connecting: connecting)
            }
        } else {
            content.background { HostMarkEffects(trigger: trigger, color: color, connecting: connecting) }
        }
    }
}

/// A capsule mark's bounds and effects, for the strip to draw them outside the capsule's clip.
struct HostMarkEffectsAnchor: PreferenceKey {
    struct Effects {
        let bounds: Anchor<CGRect>
        let trigger: String
        let color: Color
        let connecting: Bool
    }
    static let defaultValue: Effects? = nil
    static func reduce(value: inout Effects?, nextValue: () -> Effects?) { value = value ?? nextValue() }
}

/// The mark's motion around it: a ripple when its host changes, a pulse while it connects.
struct HostMarkEffects: View {
    let trigger: String
    let color: Color
    let connecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion { HostSwitchRipple(trigger: trigger, color: color) }
            if connecting { HostConnectingPulse(color: color, reduceMotion: reduceMotion).transition(.opacity) }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Rings breathing out of the mark while its tab connects; with Reduce Motion a steady faint ring.
private struct HostConnectingPulse: View {
    let color: Color
    let reduceMotion: Bool
    private static let period = 1.2

    var body: some View {
        if reduceMotion {
            Circle().strokeBorder(color.opacity(0.5), lineWidth: 1.5)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                Circle().strokeBorder(color, lineWidth: 1.5)
                    .scaleEffect(1 + 0.45 * phase)
                    .opacity(0.7 * (1 - phase))
            }
        }
    }
}

/// A ring that ripples out of the mark once each time its host changes; at rest it is invisible.
private struct HostSwitchRipple: View {
    let trigger: String
    let color: Color

    private struct Ring { var scale: CGFloat = 1; var opacity: Double = 0 }

    var body: some View {
        Circle().strokeBorder(color, lineWidth: 1.5)
            .keyframeAnimator(initialValue: Ring(), trigger: trigger) { ring, value in
                ring.scaleEffect(value.scale).opacity(value.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1, duration: 0.05)
                    CubicKeyframe(1.9, duration: 0.5)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.8, duration: 0.05)
                    CubicKeyframe(0, duration: 0.5)
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The mark's glass circle, or without glass a circle that fills under the pointer.
private struct StripHostMarkSurface: ViewModifier {
    let tint: Color?
    @Environment(\.stripActionsMerged) private var onCapsule
    @State private var hovered = false
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active && onCapsule {
            // On a split pane's capsule, a circle on its glass like the capsule's other buttons: no glass on glass.
            content.modifier(StripActionHover()).contentShape(Circle())
        } else if LiquidGlassStore.shared.active {
            content.liquidGlass(in: Circle(), interactive: true, tint: tint).contentShape(Circle())
        } else {
            content.background(hovered ? Chrome.palette.hover : .clear, in: Circle())
                .contentShape(Circle()).onHover { hovered = $0 }
        }
    }
}

/// The host mark's spaces: every space in the sidebar's order, under its host while the sidebar groups spaces by host.
enum StripSpaceMenu {
    struct Section: Identifiable {
        /// Nil while the sidebar lists spaces flat.
        let host: HostRecord?
        let spaces: [Space]
        var id: String { host?.id.rawValue ?? "" }
    }

    @MainActor static func sections(_ workspace: Workspace) -> [Section] {
        let spaces = workspace.presentationSpaces
        guard workspace.spaceOrder == .tree else { return [Section(host: nil, spaces: spaces)] }
        var sections: [Section] = []
        for space in spaces {
            if let last = sections.last, last.host?.id == space.hostID {
                sections[sections.count - 1] = Section(host: last.host, spaces: last.spaces + [space])
            } else {
                sections.append(Section(host: workspace.hosts.record(space.hostID), spaces: [space]))
            }
        }
        return sections
    }

    /// The sidebar's jump shortcuts: the first eight spaces, then the last; unbound spaces show none.
    static func shortcuts(_ order: [Space], keys: KeyGroups) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: order.enumerated().map { index, space in
            (space.id, (index < 8 ? keys.shortcut(\.spaces, String(index + 1))
                : space.id == order.last?.id ? keys.shortcut(\.spaces, "9") : nil) ?? "")
        })
    }
}

/// The host mark's popover: the spaces as rows on the popover's glass, each led by its host's glyph on a small tinted
/// glass disc, with its agent activity and jump shortcut; the current space sits on a glass capsule of its own, in its
/// host's color. While the sidebar groups spaces by host, each host's name heads its spaces.
struct StripSpacePicker: View {
    @Environment(\.appTypography) private var typography
    let workspace: Workspace
    let controller: AppDelegate
    let chosen: () -> Void

    private var glass: Bool { LiquidGlassStore.shared.active }

    var body: some View {
        let sections = StripSpaceMenu.sections(workspace)
        let shortcuts = StripSpaceMenu.shortcuts(workspace.presentationSpaces, keys: KeyGroupsStore.shared.current)
        VStack(spacing: 0) {
        FittingPopoverContent(maxHeight: typography.popoverHeight(640) - typography.expanded(48)) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        if let host = section.host { heading(host) }
                        ForEach(section.spaces) { space in
                            StripSpaceRow(space: space, host: workspace.hosts.record(space.hostID),
                                          selected: space.id == workspace.selectedSpace,
                                          shortcut: shortcuts[space.id] ?? "") {
                                workspace.selectSpace(space.id)
                                chosen()
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
            Divider().padding(.horizontal, 12)
            VStack(spacing: 2) {
                // The sidebar's "+ space" and "+ local": "New local space" only while another host is live, where it
                // differs from "New space".
                StripPickerAction(title: "New space", shortcut: "⌘N") {
                    Image(systemName: "plus").font(.system(size: typography.size(offset: -1), weight: .medium))
                } action: {
                    chosen()
                    controller.newSpace()
                }
                .accessibilityIdentifier("strip-space-picker-new-space")
                if workspace.liveHosts.contains(where: { $0.id != .local }) {
                    StripPickerAction(title: "New local space", shortcut: "⇧⌘N") {
                        HostGlyph(host: workspace.hosts.record(.local), size: typography.hostIconSize)
                    } action: {
                        chosen()
                        controller.newLocalSpace()
                    }
                    .accessibilityIdentifier("strip-space-picker-new-local-space")
                }
                // The sidebar toggle, which the mark stands in for while the sidebar is hidden.
                StripPickerAction(title: controller.sidebarVisible ? "Hide sidebar" : "Show sidebar", shortcut: "⌘\\") {
                    Image(systemName: "sidebar.left").font(.system(size: typography.size(offset: -1)))
                } action: {
                    chosen()
                    controller.toggleSidebar()
                }
                .accessibilityIdentifier("strip-space-picker-sidebar")
            }
            .padding(8)
        }
        .font(typography.font(offset: -0.5)).foregroundStyle(Chrome.ink)
        .frame(width: typography.expanded(280))
        // On glass the popover's own system glass shows through instead of the sidebar fill.
        .background(glass ? Color.clear : Chrome.sidebar).preferredColorScheme(Chrome.colorScheme)
        .fittedPopoverPresentation()
        .accessibilityIdentifier("strip-space-picker")
    }

    private func heading(_ host: HostRecord) -> some View {
        let size = typography.size(offset: -3)
        return Text(host.id == .local ? "LOCAL" : host.name.uppercased())
            .font(AppFont.ui(size: size)).tracking(size * 0.08)
            .foregroundStyle(host.tint?.foreground ?? Chrome.palette.sidebarHostLabel)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A command under the picker's spaces, laid out like a space row: its icon where a row's host disc sits, and its
/// shortcut in line with the rows', before the same check slot.
private struct StripPickerAction<Icon: View>: View {
    @Environment(\.appTypography) private var typography
    let title: String
    let shortcut: String
    @ViewBuilder let icon: Icon
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: typography.expanded(12), style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                icon.foregroundStyle(Chrome.palette.secondary)
                    .frame(width: typography.expanded(22), height: typography.expanded(22))
                Text(title).foregroundStyle(Chrome.palette.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Text(shortcut).font(typography.shortcut()).foregroundStyle(Chrome.muted)
                StripPickerCheck(shown: false, color: Chrome.ink)
            }
            .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 4)
            .background { if hovered { shape.fill(Chrome.palette.hover) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}

/// The picker rows' trailing check: every row keeps its slot, so the shortcuts before it line up.
private struct StripPickerCheck: View {
    @Environment(\.appTypography) private var typography
    let shown: Bool
    let color: Color

    var body: some View {
        Image(systemName: "checkmark").font(.system(size: typography.size(offset: -2.5), weight: .semibold))
            .foregroundStyle(color)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(!shown)
    }
}

private struct StripSpaceRow: View {
    @Environment(\.appTypography) private var typography
    let space: Space
    let host: HostRecord
    let selected: Bool
    let shortcut: String
    let action: () -> Void
    @State private var hovered = false

    private var glass: Bool { LiquidGlassStore.shared.active }

    var body: some View {
        let disc = typography.expanded(22)
        let shape = RoundedRectangle(cornerRadius: typography.expanded(12), style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                HostGlyph(host: host, size: typography.hostIconSize)
                    .foregroundStyle(host.tint?.foreground ?? Chrome.palette.secondary)
                    .frame(width: disc, height: disc)
                    // On the current row's glass a plain disc: no glass on glass.
                    .background { if selected { Circle().fill(host.tint?.glassWash ?? Chrome.palette.hover) } }
                    .liquidGlass(in: Circle(), fallback: selected ? nil : Chrome.palette.hover,
                                 tint: host.tint?.glassWash, enabled: !selected)
                Text(space.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(selected ? Chrome.ink : Chrome.palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AgentActivityGlyph(tabIDs: space.tabs.flatMap(\.surfaceIDs), size: typography.size(offset: -3)).fixedSize()
                if !shortcut.isEmpty {
                    Text(shortcut).font(typography.shortcut()).foregroundStyle(Chrome.muted)
                }
                StripPickerCheck(shown: selected, color: host.tint?.foreground ?? Chrome.ink)
            }
            .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 4)
            .background { if hovered && !selected { shape.fill(Chrome.palette.hover) } }
            // The current row's content sits in its glass, not over a glass background, which the glass layer would
            // draw above its name and shortcut.
            .liquidGlass(in: shape, fallback: host.tint.map { $0.foreground.opacity(0.16) } ?? Chrome.palette.selection,
                         interactive: true, tint: host.tint?.glassWash ?? Chrome.ink.opacity(0.04), enabled: selected)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(host.id == .local ? space.name : "\(space.name) · \(host.name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("strip-space-\(space.id)")
    }
}

/// The new-tab button ending a strip's tabs: on a split pane's glass capsule a circle on the capsule, on a lone glass
/// strip its own glass circle beside the track.
struct NewTabLabel: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.stripActionsMerged) private var onCapsule
    let style: StripTab.Style

    var body: some View {
        if style == .outlined && LiquidGlassStore.shared.active {
            let size = StripTab.glassTrackHeight(typography)
            if onCapsule {
                Image(systemName: "plus").frame(width: size, height: size)
                    .modifier(StripActionHover()).contentShape(Circle())
            } else {
                // Its own glass circle, as tall as the track and 4 points after it.
                Image(systemName: "plus").frame(width: size, height: size)
                    .liquidGlass(in: Circle(), interactive: true).contentShape(Circle())
                    .padding(.leading, 4)
            }
        } else {
            Image(systemName: "plus").frame(width: 28, height: typography.expanded(26)).contentShape(Rectangle())
        }
    }
}
