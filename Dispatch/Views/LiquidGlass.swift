import SwiftUI

/// The Liquid Glass setting in effect, for chrome hosted outside the main view's environment; TerminalRuntime applies it.
@MainActor @Observable
final class LiquidGlassStore {
    static let shared = LiquidGlassStore()
    var enabled = false

    nonisolated static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
    /// Only macOS 26 and later draw glass; earlier systems keep the flat chrome whatever the setting says.
    var active: Bool { enabled && Self.supported }
}

/// Glass in `shape` while Liquid Glass is active, otherwise the flat `fallback` fill, if any.
private struct LiquidGlassBackground<S: Shape>: ViewModifier {
    let shape: S
    let fallback: Color?
    var interactive = false
    var tint: Color?
    var enabled = true

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if LiquidGlassStore.shared.active, #available(macOS 26, *) {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else if let fallback {
            content.background(fallback, in: shape)
        } else {
            content
        }
    }
}

/// A lone tab strip on one glass capsule, as macOS 26's own tab bars are; remote strips tint it with the host color.
/// A `bare` strip keeps the capsule's frame but draws no glass, so the strip keeps its identity as it comes and goes.
/// The glass fades in and out as the strip turns bare or back; only that change animates, since an animation here
/// carries everything drawn in the glass with it, the tabs' layout included.
private struct TabStripGlass: ViewModifier {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: HostTint?
    var bare = false

    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active, #available(macOS 26, *) {
            content.frame(height: StripTab.glassTrackHeight(typography))
                .clipShape(Capsule())
                .glassEffect(bare ? .identity : .regular.tint(tint?.glassWash), in: Capsule())
                .animation(InterfaceMotion.animation(reduce: reduceMotion), value: bare)
        } else {
            content
        }
    }
}

/// A split pane's glass strip (or a tmux pane's header): the lone strip's capsule, but holding the badge, tabs and
/// buttons together from the strip's leading inset to its trailing one. They draw no glass of their own besides the selected tab's pill, so a
/// grid reads as one bar per pane rather than a cluster of shapes. Remote strips tint it with the host color.
private struct StripCapsule: ViewModifier {
    let tint: HostTint?

    func body(content: Content) -> some View {
        content.modifier(TabStripGlass(tint: tint)).environment(\.stripActionsMerged, true)
    }
}

/// Lets a strip's glass shapes (its capsule or track, the selected tab's pill, the new-tab circle, the button pill, the
/// title row's sidebar toggle) blend as one bar.
private struct GlassBar: ViewModifier {
    var spacing: CGFloat = 4
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active, #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct FloatingGlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active {
            content.padding(.horizontal, 10).padding(.vertical, 6)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            content
        }
    }
}

/// A glass strip's button (chat switch, layout picker) at the new-tab button's size: as tall as the glass track, a
/// circle when icon-only and a pill when it carries text. On shared glass (a split pane's capsule, a lone strip's
/// button pill, a tmux pane's header) it draws no glass of its own; elsewhere (the floating chat switch) it is its own
/// capsule.
private struct StripGlassButton: ViewModifier {
    @Environment(\.appTypography) private var typography
    @Environment(\.stripActionsMerged) private var merged
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active {
            let size = StripTab.glassTrackHeight(typography)
            if merged {
                content.frame(minWidth: size, minHeight: size).modifier(StripActionHover())
            } else {
                content.frame(minWidth: size, minHeight: size).liquidGlass(in: Capsule(), interactive: true)
            }
        } else {
            content
        }
    }
}

/// A button on a strip's shared glass: no glass of its own, a faint circle while the pointer is over it.
struct StripActionHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.background(hovering ? Chrome.palette.hover : .clear, in: Capsule())
            .onHover { hovering = $0 }
    }
}

/// A control inside a glass panel (the sidebar header's): an SF Symbol at the sidebar toggle's size in the secondary
/// color, brightening with a faint capsule under the pointer, and keeping a steady capsule while `active`.
struct GlassPanelControl: ViewModifier {
    var active = false
    @Environment(\.appTypography) private var typography
    @State private var hovering = false

    func body(content: Content) -> some View {
        let size = StripTab.glassTrackHeight(typography)
        content.font(.system(size: 14))
            .frame(width: size, height: size)
            .foregroundStyle(active || hovering ? Chrome.ink : Chrome.palette.detail)
            .background(active ? Chrome.ink.opacity(0.07) : hovering ? Chrome.palette.hover : .clear, in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

/// A lone glass strip's buttons (chat, layout) drawn on one shared glass pill, like a toolbar group.
private struct StripActionsPill: ViewModifier {
    let merged: Bool
    func body(content: Content) -> some View {
        if merged {
            content.liquidGlass(in: Capsule()).padding(.leading, 4).environment(\.stripActionsMerged, true)
        } else {
            content
        }
    }
}

private struct StripActionsMergedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// On a strip's shared glass (a split pane's capsule, a lone strip's button pill): buttons draw no glass of their own.
    var stripActionsMerged: Bool {
        get { self[StripActionsMergedKey.self] }
        set { self[StripActionsMergedKey.self] = newValue }
    }
}

private struct GlassStripInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How much of a pane's top a glass tab strip covers. Terminals pad below it; chat scrolls under it.
    var glassStripInset: CGFloat {
        get { self[GlassStripInsetKey.self] }
        set { self[GlassStripInsetKey.self] = newValue }
    }
}

extension View {
    /// `enabled`: false leaves the content bare, for glass that comes and goes on one view.
    func liquidGlass(in shape: some Shape, fallback: Color? = nil, interactive: Bool = false, tint: Color? = nil,
                     enabled: Bool = true) -> some View {
        modifier(LiquidGlassBackground(shape: shape, fallback: fallback, interactive: interactive, tint: tint, enabled: enabled))
    }

    /// Applied to a lone glass strip's scroll view.
    /// `bare`: the track without its glass.
    @ViewBuilder func tabStripGlass(_ on: Bool, tint: HostTint?, bare: Bool = false) -> some View {
        if on { modifier(TabStripGlass(tint: tint, bare: bare)) } else { self }
    }

    /// Applied to a split pane's whole glass strip, inside its padding.
    @ViewBuilder func stripCapsule(_ on: Bool, tint: HostTint?) -> some View {
        if on { modifier(StripCapsule(tint: tint)) } else { self }
    }

    /// Applied to a whole strip, so its glass reads as a single bar.
    @ViewBuilder func glassBar(_ style: StripTab.Style) -> some View {
        if style == .outlined { glassGroup() } else { self }
    }

    func stripGlassButton() -> some View { modifier(StripGlassButton()) }
    func stripActionsPill(_ merged: Bool) -> some View { modifier(StripActionsPill(merged: merged)) }

    /// Lets the glass shapes inside blend as one group while Liquid Glass is active.
    func glassGroup(spacing: CGFloat = 4) -> some View { modifier(GlassBar(spacing: spacing)) }

    /// A bare row floating over content (chat status, queue, working indicator) gets its own small glass panel,
    /// so it stays legible over the transcript; without Liquid Glass it is unchanged.
    func floatingGlassPanel() -> some View { modifier(FloatingGlassPanel()) }
}

/// Stacks a strip above `content`, or with Liquid Glass lays it over the content's top edge so the glass has
/// something behind it. The content keeps one identity either way, so toggling glass never remounts a terminal.
struct GlassStripStack<Strip: View, Content: View>: View {
    let overlaid: Bool
    @ViewBuilder let strip: Strip
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            if !overlaid { strip }
            content
        }
        .overlay(alignment: .top) { if overlaid { strip } }
    }
}
