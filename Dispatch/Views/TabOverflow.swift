import SwiftUI

/// Tabs mostly scrolled past either edge of a horizontal tab strip, and whether any tab is clipped there at all.
struct TabStripEdges: Equatable {
    var leading: Set<UUID> = []
    var trailing: Set<UUID> = []
    var clipsLeading = false
    var clipsTrailing = false
    var overflowing: Bool { clipsLeading || clipsTrailing }

    /// The strip's content coordinate space, which scrolling never changes.
    static let space = "tab-strip"
    static let viewport = "tab-strip-viewport"

    init() {}

    /// Tab frames are in content coordinates; `scroll` is the content offset showing through the viewport.
    init(frames: [UUID: CGRect], scroll: CGFloat, viewport: CGFloat) {
        for (id, frame) in frames {
            let minX = frame.minX - scroll, maxX = frame.maxX - scroll, midX = (minX + maxX) / 2
            if midX < 0 { leading.insert(id) }
            if midX > viewport { trailing.insert(id) }
            clipsLeading = clipsLeading || minX < -1
            clipsTrailing = clipsTrailing || maxX > viewport + 1
        }
    }
}

/// Each tab's frame in the strip's content coordinates.
struct TabStripFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct TabStripScrollOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reads the strip's horizontal scroll offset. Programmatic `scrollTo` does not
/// reliably re-run geometry readers inside the content, so macOS 15+ observes
/// the scroll view itself.
private struct TabStripScroll: ViewModifier {
    @Binding var offset: CGFloat
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, value in
                offset = value
            }
        } else {
            content.coordinateSpace(name: TabStripEdges.viewport)
                .onPreferenceChange(TabStripScrollOffset.self) { offset = $0 }
        }
    }
}

extension View {
    /// Publishes this tab's frame in the strip's content coordinates.
    func tabStripEdge(_ id: UUID) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: TabStripFrames.self, value: [id: proxy.frame(in: .named(TabStripEdges.space))])
        })
    }

    /// Marks the strip's scrolling content: the coordinate space tab frames are read in.
    func tabStripContent() -> some View {
        coordinateSpace(name: TabStripEdges.space)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TabStripScrollOffset.self, value: -proxy.frame(in: .named(TabStripEdges.viewport)).minX)
            })
    }

    /// Applied to the strip's `ScrollView`: tracks its scroll offset and the tabs' frames.
    func tabStripGeometry(frames: Binding<[UUID: CGRect]>, scroll: Binding<CGFloat>) -> some View {
        modifier(TabStripScroll(offset: scroll))
            .onPreferenceChange(TabStripFrames.self) { frames.wrappedValue = $0 }
    }

    func tabStripFade(_ edges: TabStripEdges) -> some View {
        mask {
            HStack(spacing: 0) {
                if edges.clipsLeading {
                    LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                }
                Rectangle().fill(.white)
                if edges.clipsTrailing {
                    LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 18)
                }
            }
        }
    }
}

/// Left-anchored `‹ 3 │ 5 ›` pill: how many tabs are scrolled out of view on each side.
/// Clicking a side pages the strip toward them; right-click lists every tab.
struct TabOverflowControl: View {
    struct Item: Identifiable {
        let id: UUID
        let title: String
        let surfaceIDs: [UUID]
    }

    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let items: [Item]
    let selected: UUID?
    let edges: TabStripEdges
    let scroll: ScrollViewProxy
    let select: (UUID) -> Void

    var body: some View {
        HStack(spacing: 0) {
            side(leading: true)
            Rectangle().fill(Chrome.border).frame(width: 1)
            side(leading: false)
        }.frame(height: typography.expanded(20)).fixedSize()
            .modifier(OverflowSurface())
            .contextMenu {
                ForEach(items) { item in
                    Button { select(item.id) } label: {
                        if item.id == selected { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                    }
                }
            }
            .accessibilityIdentifier("tab-overflow")
    }

    private func hidden(leading: Bool) -> [Item] {
        let ids = leading ? edges.leading : edges.trailing
        return items.filter { ids.contains($0.id) }
    }

    private func side(leading: Bool) -> some View {
        let hidden = hidden(leading: leading)
        let pending = hidden.contains { $0.surfaceIDs.contains { TerminalRuntime.shared.chat.sessions[$0]?.approvals.contains(where: \.pending) == true } }
        let chevron = Image(systemName: leading ? "chevron.left" : "chevron.right").font(AppFont.ui(size: 9, weight: .semibold))
        // A constant width: the strip re-reveals the selected tab whenever its viewport resizes.
        let count = ZStack {
            Text(String(repeating: "8", count: String(items.count).count)).hidden()
            Text("\(hidden.count)")
        }.font(typography.shortcut(offset: -2.5)).monospacedDigit()
        return Button {
            // Page rather than step: bring the nearest hidden tab fully in, against the far edge.
            guard let target = leading ? hidden.last : hidden.first else { return }
            withAnimation(InterfaceMotion.animation(reduce: reduceMotion)) {
                scroll.scrollTo(target.id, anchor: leading ? .trailing : .leading)
            }
        } label: {
            HStack(spacing: 3) {
                if leading { chevron; count } else { count; chevron }
            }.padding(.horizontal, 6).frame(maxHeight: .infinity).contentShape(Rectangle())
        }
        .disabled(hidden.isEmpty)
        .foregroundStyle(pending ? Chrome.accent : hidden.isEmpty ? Chrome.palette.faint : Chrome.muted)
        .help(hidden.isEmpty ? "" : "\(hidden.count) more \(hidden.count == 1 ? "tab" : "tabs") \(leading ? "before" : "after") · right-click for all tabs")
        .accessibilityLabel(leading ? "Show earlier tabs" : "Show later tabs")
        .accessibilityValue("\(hidden.count) hidden\(pending ? ", awaiting approval" : "")")
        .animation(InterfaceMotion.animation(reduce: reduceMotion), value: pending)
    }
}

/// The overflow control's panel; on glass an interactive capsule joining the strip's glass group, or on a split pane's
/// capsule a faint capsule on the strip's own glass.
private struct OverflowSurface: ViewModifier {
    @Environment(\.stripActionsMerged) private var onCapsule
    func body(content: Content) -> some View {
        if LiquidGlassStore.shared.active {
            if onCapsule {
                content.padding(.horizontal, 2).background(Chrome.palette.selection, in: Capsule())
            } else {
                content.padding(.horizontal, 2).liquidGlass(in: Capsule(), interactive: true)
            }
        } else {
            content.chromePanel(cornerRadius: 4)
        }
    }
}
