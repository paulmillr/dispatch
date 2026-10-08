import SwiftUI

struct LayoutPicker: View {
    @Environment(\.appTypography) private var typography
    let space: Space
    let workspace: Workspace
    @State private var presented = false
    @State private var hovered = false
    private static let iconInset: CGFloat = 7
    private var preset: LayoutPreset? { space.preset }
    private var paneCount: Int { space.layout.paneIDs.count }
    var body: some View {
        Button { presented.toggle() } label: {
            // The icon alone names the layout; its title is in the tooltip and accessibility value.
            LayoutIcon(preset: paneCount == 1 ? .grid : preset, size: typography.tabSize)
                .foregroundStyle(paneCount > 1 ? ChatThemeStore.shared.current.accent : Chrome.muted)
                .padding(.horizontal, Self.iconInset).frame(minHeight: typography.expanded(22))
                .background(hovered && !LiquidGlassStore.shared.active ? Chrome.palette.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
                // On glass, a glass button matching the new-tab button, in the strip's glass group.
                .stripGlassButton()
                .contentShape(Rectangle())
        }
        .onHover { hovered = $0 }
        .help(paneCount > 1 ? "Layout: \(shortLabel) · choose layout, moving existing tabs into panes"
                            : "Choose layout · move existing tabs into panes")
        .accessibilityLabel("Choose layout")
        .accessibilityIdentifier("layout-picker")
        .accessibilityValue(shortLabel)
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            LayoutOptions(space: space, workspace: workspace) { presented = false }
        }
    }
    private var shortLabel: String { preset?.title ?? "custom" }
}

struct LayoutOptions: View {
    @Environment(\.appTypography) private var typography
    let space: Space
    let workspace: Workspace
    var chosen: () -> Void = {}
    var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(LayoutPreset.allCases, id: \.self) { preset in
                    Button {
                        workspace.selectSpace(space.id)
                        workspace.applyLayout(preset); chosen()
                    } label: {
                        HStack(spacing: 10) {
                            LayoutIcon(preset: preset, size: typography.tabSize).frame(width: typography.expanded(18))
                            Text(preset.title)
                            Spacer()
                            if space.preset == preset { Image(systemName: "checkmark") }
                            if let key = preset.shortcutKey.flatMap({ KeyGroupsStore.shared.current.shortcut(\.splits, $0) }) {
                                Text(key).font(typography.shortcut()).foregroundStyle(Chrome.muted)
                            }
                        }.padding(7).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("layout-option-\(preset.rawValue)")
                    .disabled(!workspace.canApplyLayout(preset, in: space))
                }
                Divider()
                Text("Layouts move existing tabs. Add tabs first for more panes.")
                    .font(typography.font(offset: -2.5)).foregroundStyle(Chrome.muted).padding(5)
            }.font(typography.font(offset: -0.5)).padding(6).frame(width: typography.expanded(290))
                // On glass the popover's own system glass shows through instead of the sidebar fill.
                .background(LiquidGlassStore.shared.active ? Color.clear : Chrome.sidebar).preferredColorScheme(Chrome.colorScheme)
    }
}

private struct LayoutIcon: View {
    let preset: LayoutPreset?
    /// The glyph's point size; the drawn outline matches an SF Symbol's footprint at it.
    var size: CGFloat = 11.5

    var body: some View {
        if preset == .twoAbove {
            // No symbol shows two panes above one: the 1x2 symbol with its top half split too, so it keeps the other
            // presets' outline, divider and stroke (a twelfth of the point size). Its outline's top edge sits a point
            // below the image's top, and its divider at the image's middle.
            Image(systemName: "rectangle.split.1x2").font(.system(size: size))
                .overlay {
                    GeometryReader { box in
                        Rectangle().frame(width: size / 12, height: box.size.height / 2 - 1)
                            .position(x: box.size.width / 2, y: (box.size.height / 2 + 1) / 2)
                    }
                }
        } else {
            Image(systemName: symbol).font(.system(size: size))
        }
    }

    private var symbol: String {
        switch preset {
        case .single: "rectangle"
        case .rows: "rectangle.split.1x2"
        case .grid: "square.split.2x2"
        default: "rectangle.split.2x1"
        }
    }
}

struct SplitDropZones: View {
    let pane: Pane
    let workspace: Workspace
    var body: some View {
        GeometryReader { geometry in
            ForEach(PaneEdge.allCases, id: \.self) { edge in
                let horizontal = edge == .left || edge == .right
                LocalReorder(edge: .split(edge), accepts: { item in
                    guard case .tab(let id) = item else { return false }
                    return workspace.canSplitTab(id, beside: pane.id)
                }) { item, _ in
                    guard case .tab(let id) = item else { return }
                    workspace.splitTab(id, beside: pane.id, edge: edge)
                }
                .frame(width: geometry.size.width * (horizontal ? 0.25 : 0.5),
                       height: geometry.size.height * (horizontal ? 1 : 0.25))
                .position(x: geometry.size.width * (horizontal ? (edge == .left ? 0.125 : 0.875) : 0.5),
                          y: geometry.size.height * (horizontal ? 0.5 : (edge == .top ? 0.125 : 0.875)))
            }
        }
    }
}
