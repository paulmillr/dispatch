import AppKit
import SwiftUI
import Observation

/// Keep motion local to chrome and visible state changes. Transcript pagination
/// and streaming revisions intentionally never animate the entire lazy stack.
enum InterfaceMotion {
    static let viewDuration = 0.2
    static let sidebarDuration = 0.12
    static let hostSwitchDuration = 0.1
    /// Title and sidebar selection follow a space switch; shorter than `viewDuration` so switching feels immediate.
    static let spaceSwitchDuration = 0.12
    static let modeSwitchDuration = 0.15
    static let accent = Color(red: 224/255, green: 123/255, blue: 224/255)
    static func animation(reduce: Bool, duration: Double = viewDuration) -> Animation? {
        reduce ? nil : .easeOut(duration: duration)
    }
}

struct AttentionMotion: ViewModifier {
    let pending: Bool
    var cornerRadius: CGFloat = 5
    /// The accent rule along the leading edge; Large's rounded cards mark attention on their own edge instead.
    var bar = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false
    func body(content: Content) -> some View {
        content
            .background(InterfaceMotion.accent.opacity(pending ? (flash ? 0.18 : 0.06) : 0), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(alignment: .leading) {
                Rectangle().fill(InterfaceMotion.accent.opacity(pending && bar ? 0.5 : 0)).frame(width: 2)
            }
            .offset(x: flash && !reduceMotion ? 3 : 0)
            .animation(InterfaceMotion.animation(reduce: reduceMotion), value: flash)
            .task(id: pending) {
                guard pending, !reduceMotion else { flash = false; return }
                flash = true
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
                flash = false
            }
    }
}

/// A short border cue confirms keyboard focus without moving terminal content.
struct PaneFocusHighlight: ViewModifier {
    let workspace: Workspace
    let paneID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var highlighted = false

    private var feedback: Workspace.PaneFocusFeedback? {
        guard let feedback = workspace.paneFocusFeedback, feedback.paneID == paneID else { return nil }
        return feedback
    }

    func body(content: Content) -> some View {
        content.overlay {
            Rectangle().strokeBorder(Chrome.accent.opacity(highlighted ? 0.7 : 0), lineWidth: 2)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .task(id: feedback?.id) {
            highlighted = false
            guard let feedback, feedback.expiresAt > .now else { return }
            withAnimation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.14)) { highlighted = true }
            let remaining = feedback.expiresAt.timeIntervalSinceNow
            do { try await Task.sleep(for: .seconds(reduceMotion ? remaining : min(0.15, remaining))) }
            catch { return }
            withAnimation(InterfaceMotion.animation(reduce: reduceMotion, duration: max(0, feedback.expiresAt.timeIntervalSinceNow))) {
                highlighted = false
            }
        }
    }
}

/// Whether a pane's strip shows its shortcut badge: the focused badge's accent-colored key marks the focused pane, so the
/// pane drops its accent border; without a badge (narrow strip, hidden tabs, pane 5+) the border marks it.
struct PaneShortcutBadgeShown: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// A split pane's ⌘N shortcut; the focused pane's key is in the accent color, on the same background as the others.
struct PaneShortcutBadge: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flash = false
    let number: Int
    let focused: Bool
    var feedbackID: UUID? = nil
    /// On a split pane's glass capsule, sized like the strip's buttons.
    var glass = false
    let action: () -> Void

    /// The badge's laid-out width, its trailing gap included, so a strip leaves the tabs room for it in the same update
    /// that shows it (TabBar).
    @MainActor static func width(number: Int, glass: Bool, typography: AppTypography) -> CGFloat {
        labelWidth(KeyGroupsStore.shared.current.symbols(\.tabs) + String(number), glass: glass, typography: typography) + 4
    }

    @MainActor private static func labelWidth(_ key: String, glass: Bool, typography: AppTypography) -> CGFloat {
        let text = ceil((key as NSString).size(withAttributes: [.font: AppFont.nativeShortcut(size: typography.size(offset: -2))]).width)
        return glass ? max(text + 14, StripTab.glassTrackHeight(typography)) : text + 14
    }

    var body: some View {
        let keys = KeyGroupsStore.shared.current, key = keys.symbols(\.tabs) + String(number)
        let stepping = keys.steps.tabs.map { "\nSwitch tabs in this pane with \(KeyGroups.symbols($0))[ and \(KeyGroups.symbols($0))]" } ?? ""
        Button(action: action) {
            if glass { glassLabel(key) } else { flatLabel(key) }
        }
        // Exactly the width the strip leaves for it.
        .buttonStyle(.plain).fixedSize().frame(width: Self.labelWidth(key, glass: glass, typography: typography))
        .padding(.trailing, 4)
        .help("Focus pane \(number) · \(key)" + stepping)
        .accessibilityLabel("Focus pane \(number)")
        .accessibilityValue(focused ? "Focused" : "")
        .accessibilityIdentifier("pane-shortcut-\(number)")
        .preference(key: PaneShortcutBadgeShown.self, value: true)
        .animation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.14), value: focused)
        .task(id: feedbackID) {
            flash = false
            guard feedbackID != nil, focused else { return }
            flash = true
            do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            withAnimation(InterfaceMotion.animation(reduce: reduceMotion, duration: 0.14)) { flash = false }
        }
    }

    private func flatLabel(_ key: String) -> some View {
        Text(key).font(typography.shortcut(offset: -2))
            .foregroundStyle(focused ? Chrome.accent : Chrome.muted)
            // The strip's trailing buttons pad their glyphs by 7 too, so both ends sit Chrome.stripInset
            // from the edge by their boxes and their contents.
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Chrome.ink.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
            .scaleEffect(flash && !reduceMotion ? 1.12 : 1)
    }

    /// A capsule on the strip capsule's glass; the focus flash bumps it.
    private func glassLabel(_ key: String) -> some View {
        let size = StripTab.glassTrackHeight(typography)
        return Text(key).font(typography.shortcut(offset: -2))
            .foregroundStyle(focused ? Chrome.accent : Chrome.muted)
            .padding(.horizontal, 7).frame(minWidth: size, minHeight: size)
            .modifier(StripActionHover())
            .contentShape(Capsule())
            .scaleEffect(flash && !reduceMotion ? 1.08 : 1)
    }
}

/// Snapshot layout changes within a space, then replace the one hosting tree.
/// Host navigation crossfades the composited container without rasterizing
/// outgoing content on the main thread. Other navigation switches directly.
struct MotionContent: NSViewRepresentable {
    @Environment(\.appTypography) private var typography
    private var styledContent: AnyView { AnyView(content.environment(\.appTypography, typography)) }
    let content: AnyView
    let identity: String
    let spaceID: UUID
    let layout: PaneLayout
    var hostID: HostID = .local
    var selectedTabID: UUID? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> MotionContentView {
        MotionContentView(content: styledContent, identity: identity, spaceID: spaceID, layout: layout, hostID: hostID, selectedTabID: selectedTabID)
    }
    func updateNSView(_ view: MotionContentView, context: Context) {
        view.update(styledContent, identity: identity, spaceID: spaceID, layout: layout, animated: !reduceMotion, hostID: hostID, selectedTabID: selectedTabID)
    }
}

final class MotionContentView: NSView {
    // A transition host fills its pane; its transcript does not size the pane.
    override var intrinsicContentSize: NSSize { .zero }
    let host: NSHostingView<AnyView>
    private var identity: String
    private var spaceID: UUID
    private var paneLayout: PaneLayout
    private var hostID: HostID
    private var selectedTabID: UUID?
    private var outgoing: [NSImageView] = []
    private var generation = UUID()
    override var isFlipped: Bool { true }
    init(content: AnyView, identity: String, spaceID: UUID, layout: PaneLayout, hostID: HostID = .local, selectedTabID: UUID? = nil) {
        self.identity = identity; self.spaceID = spaceID; self.paneLayout = layout
        self.hostID = hostID
        self.selectedTabID = selectedTabID
        host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(host)
        host.autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); host.frame = bounds }
    func update(_ content: AnyView, identity: String, spaceID: UUID, layout: PaneLayout, animated: Bool, hostID: HostID = .local, selectedTabID: UUID? = nil) {
        // A different tmux window brings different pane IDs, even when both
        // tabs are single panes. That is navigation, not a layout edit. Track
        // selection explicitly; grouped tabs can also retain some pane IDs.
        let navigation = self.spaceID != spaceID || self.selectedTabID != selectedTabID
        let hostSwitch = self.spaceID != spaceID && self.hostID != hostID
        let changed = self.identity != identity || navigation
        let morph = !navigation && paneLayout != layout
        var snapshots: [(UUID?, NSImageView)] = []
        if changed || !animated {
            generation = UUID()
            outgoing.forEach { $0.removeFromSuperview() }; outgoing = []
            layer?.removeAnimation(forKey: kCATransition)
        }
        if changed && morph && animated && window != nil && bounds.width > 0 && bounds.height > 0 {
            let regions: [(UUID?, CGRect)] = morph && paneLayout.paneIDs.count <= 8
                ? paneFrames(paneLayout, in: host).map { (Optional($0.key), $0.value) }
                : [(nil, host.bounds)]
            for (id, rect) in regions where rect.width > 0 && rect.height > 0 {
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                host.cacheDisplay(in: rect, to: bitmap)
                let image = NSImage(size: rect.size); image.addRepresentation(bitmap)
                let overlay = MotionSnapshot(frame: rect)
                overlay.image = image; overlay.imageScaling = .scaleAxesIndependently
                overlay.setAccessibilityElement(false)
                snapshots.append((id, overlay))
            }
        }
        self.identity = identity; self.spaceID = spaceID; self.paneLayout = layout
        self.hostID = hostID
        self.selectedTabID = selectedTabID
        host.rootView = content
        if hostSwitch && animated && window != nil && !isHiddenOrHasHiddenAncestor && bounds.width > 0 && bounds.height > 0 {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = InterfaceMotion.hostSwitchDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(transition, forKey: kCATransition)
        }
        guard !snapshots.isEmpty else { return }
        for (_, snapshot) in snapshots { addSubview(snapshot); outgoing.append(snapshot) }
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.host.layoutSubtreeIfNeeded()
            let destinations = morph ? self.paneFrames(layout, in: self.host) : [:]
            NSAnimationContext.runAnimationGroup { context in
                context.duration = InterfaceMotion.viewDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for (id, snapshot) in snapshots {
                    if let id, let target = destinations[id] { snapshot.animator().frame = target }
                    snapshot.animator().alphaValue = 0
                }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token else { return }
                    self.outgoing.forEach { $0.removeFromSuperview() }; self.outgoing = []
                }
            }
        }
    }
    /// Read real split geometry, including user-resized divider positions.
    private func paneFrames(_ layout: PaneLayout, in view: NSView) -> [UUID: CGRect] {
        switch layout {
        case .pane(let id): return [id: host.convert(view.bounds, from: view)]
        case .split(_, _, let first, let second):
            func findSplit(_ view: NSView) -> TerminalSplitView? {
                if let split = view as? TerminalSplitView { return split }
                return view.subviews.lazy.compactMap(findSplit).first
            }
            guard let split = findSplit(view), split.arrangedSubviews.count == 2 else { return [:] }
            return paneFrames(first, in: split.arrangedSubviews[0]).merging(
                paneFrames(second, in: split.arrangedSubviews[1]), uniquingKeysWith: { first, _ in first })
        }
    }
}

private final class MotionSnapshot: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Window-coordinate markers bridge the separate sidebar and pane hosting trees.
/// Only snapshots of chrome fly; terminal views never move into an overlay.
@MainActor @Observable
final class HostMoveMotion {
    var connecting: Set<UUID> = []
    enum Item: Hashable { case space(UUID), tab(UUID) }
    final class Marker: NSView {
        weak var motion: HostMoveMotion?
        var item: Item?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private final class WeakMarker {
        weak var view: Marker?
        init(_ view: Marker) { self.view = view }
    }
    @ObservationIgnored private var markers: [Item: [WeakMarker]] = [:]
    @ObservationIgnored private var departures: [UUID: HostID] = [:]
    @ObservationIgnored private var departureGeneration = UUID()
    @ObservationIgnored weak var canvas: Marker?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var tokens: [UUID: UUID] = [:]
    private(set) var hidden: Set<UUID> = []
    private(set) var pulling: Set<UUID> = []
    private(set) var arrivals: [UUID: HostID] = [:]
    /// Flat rows changing host: out of sight while the list slides the others around them, so they never cross the rows
    /// they pass; they fade back in at their new place.
    private(set) var moving: Set<UUID> = []
    @ObservationIgnored private var movingTokens: [UUID: UUID] = [:]

    func register(_ view: Marker, as item: Item) {
        guard view.motion !== self || view.item != item else { return }
        view.motion?.unregister(view)
        view.motion = self; view.item = item
        markers[item] = (markers[item] ?? []).filter { $0.view != nil }
        markers[item, default: []].append(WeakMarker(view))
    }

    func unregister(_ view: Marker) {
        guard view.motion === self, let item = view.item else { return }
        markers[item]?.removeAll { $0.view == nil || $0.view === view }
        if markers[item]?.isEmpty == true { markers[item] = nil }
        view.motion = nil; view.item = nil
    }

    private func marker(for item: Item) -> Marker? {
        markers[item]?.reversed().compactMap(\.view).first {
            $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.visibleRect.width > 0 && $0.visibleRect.height > 0
        }
    }

    /// `groupedByHost`: the sidebar lists spaces under their hosts, so a space that changes host flies between groups.
    /// In one list a space keeps its row, which the list slides to its new place; only a tab becoming a space flies.
    func reconcile(from old: [Space], to new: [Space], groupedByHost: Bool = true,
                   reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        markers = markers.mapValues { $0.filter { $0.view != nil } }.filter { !$0.value.isEmpty }
        guard !markers.isEmpty else { return }
        for id in Array(tasks.keys) where !new.contains(where: { $0.id == id }) || reduceMotion {
            tasks.removeValue(forKey: id)?.cancel()
        }
        guard !reduceMotion else { return }
        let remainingTabs = Set(new.flatMap(\.tabs).map(\.id))
        for space in old {
            for tab in space.tabs where !remainingTabs.contains(tab.id) { departures[tab.id] = space.hostID }
        }
        if !departures.isEmpty {
            let generation = UUID(); departureGeneration = generation
            Task { [weak self] in
                await Task.yield()
                guard let self, self.departureGeneration == generation else { return }
                self.departures.removeAll()
            }
        }
        for space in new {
            if let previous = old.first(where: { $0.id == space.id }) {
                guard previous.hostID != space.hostID else { continue }
                guard groupedByHost else { move(space.id); continue }
                if tasks[space.id] != nil { arrivals[space.id] = space.hostID; continue }
                start(source: .space(space.id), destination: space.id, host: space.hostID, pull: false)
            } else if let tab = space.tabs.first,
                      let origin = old.first(where: { $0.tabs.contains(where: { $0.id == tab.id }) })?.hostID ?? departures[tab.id],
                      origin != space.hostID {
                departures[tab.id] = nil
                start(source: .tab(tab.id), destination: space.id, host: space.hostID, pull: true)
            }
        }
    }

    private func move(_ id: UUID) {
        moving.insert(id)
        let token = UUID(); movingTokens[id] = token
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(InterfaceMotion.viewDuration)) } catch { return }
            guard let self, self.movingTokens[id] == token else { return }
            self.movingTokens[id] = nil
            self.moving.remove(id)
        }
    }

    private func start(source: Item, destination: UUID, host: HostID, pull: Bool) {
        tasks.removeValue(forKey: destination)?.cancel()
        guard let marker = marker(for: source), let window = marker.window,
              let content = window.contentView else { return }
        let root: NSView = canvas ?? content
        let rect = marker.convert(marker.bounds, to: root)
        guard rect.width > 0, rect.height > 0, rect.intersects(root.bounds),
              marker.visibleRect.width > 0, marker.visibleRect.height > 0 else { return }
        let overlay = MotionSnapshot(frame: rect)
        overlay.wantsLayer = true
        overlay.setAccessibilityElement(false)
        let tint = NSColor(red: 126/255, green: 166/255, blue: 201/255, alpha: 1)
        if pull {
            overlay.frame = CGRect(x: rect.minX + 12, y: rect.midY - 4, width: 8, height: 8)
            overlay.layer?.backgroundColor = tint.cgColor
            overlay.layer?.cornerRadius = 4
            overlay.layer?.shadowColor = tint.cgColor
            overlay.layer?.shadowOpacity = 0.8
            overlay.layer?.shadowRadius = 10
        } else {
            let captureRect = root.convert(rect, to: content)
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: captureRect) else { return }
            content.cacheDisplay(in: captureRect, to: bitmap)
            let image = NSImage(size: rect.size); image.addRepresentation(bitmap)
            overlay.image = image; overlay.imageScaling = .scaleAxesIndependently
            overlay.layer?.cornerRadius = 5
            overlay.layer?.backgroundColor = NSColor(red: 38/255, green: 38/255, blue: 43/255, alpha: 1).cgColor
            overlay.layer?.shadowColor = NSColor.black.cgColor
            overlay.layer?.shadowOpacity = 0.55
            overlay.layer?.shadowRadius = 10
            overlay.layer?.shadowOffset = CGSize(width: 0, height: -5)
        }
        root.addSubview(overlay)
        let token = UUID(); tokens[destination] = token
        hidden.insert(destination)
        if pull { pulling.insert(destination) }
        arrivals[destination] = host
        tasks[destination] = Task { [weak self, weak root, weak window] in
            guard let self else { overlay.removeFromSuperview(); return }
            defer {
                overlay.removeFromSuperview()
                if self.tokens[destination] == token {
                    self.hidden.remove(destination); self.pulling.remove(destination)
                    self.arrivals[destination] = nil
                    self.tasks[destination] = nil; self.tokens[destination] = nil
                }
            }
            // First open the destination slot, then fly into it.
            if !pull {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.1
                    overlay.animator().frame = rect.insetBy(dx: -rect.width * 0.015, dy: -rect.height * 0.015)
                }, completionHandler: nil)
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let root, let window, window.isVisible,
                  let target = self.marker(for: .space(destination)), target.window === window,
                  target.visibleRect.height > 0 else { return }
            root.layoutSubtreeIfNeeded()
            let end = target.convert(target.bounds, to: root)
            guard end.intersects(root.bounds) else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.1, 1)
                overlay.animator().frame = pull
                    ? CGRect(x: end.minX + 8, y: end.midY - 4, width: 8, height: 8) : end
            }, completionHandler: nil)
            do { try await Task.sleep(for: .milliseconds(280)) } catch { return }
            withAnimation(.easeOut(duration: pull ? 0.2 : 0.12)) { _ = self.hidden.remove(destination) }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                overlay.animator().alphaValue = 0
            }, completionHandler: nil)
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
        }
    }
}

struct HostMoveCanvas: NSViewRepresentable {
    let motion: HostMoveMotion
    func makeNSView(context: Context) -> HostMoveMotion.Marker {
        let view = HostMoveMotion.Marker()
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        motion.canvas = view
        return view
    }
    func updateNSView(_ view: HostMoveMotion.Marker, context: Context) { motion.canvas = view }
}

struct HostMoveMarker: NSViewRepresentable {
    let motion: HostMoveMotion
    let item: HostMoveMotion.Item
    func makeNSView(context: Context) -> HostMoveMotion.Marker {
        let view = HostMoveMotion.Marker()
        view.setAccessibilityElement(false)
        motion.register(view, as: item)
        return view
    }
    func updateNSView(_ view: HostMoveMotion.Marker, context: Context) { motion.register(view, as: item) }
    static func dismantleNSView(_ view: HostMoveMotion.Marker, coordinator: ()) { view.motion?.unregister(view) }
}

struct HostMoveRow: ViewModifier {
    let motion: HostMoveMotion
    let id: UUID
    func body(content: Content) -> some View {
        let moving = motion.moving.contains(id)
        content
            .opacity(motion.hidden.contains(id) && !motion.pulling.contains(id) ? 0 : 1)
            // Gone before the slide's midpoint, where rows cross, whatever the list's own animation.
            .opacity(moving ? 0 : 1)
            .animation(.easeOut(duration: moving ? 0.05 : 0.15), value: moving)
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: motion.hidden.contains(id) && motion.pulling.contains(id) ? 0 : 1, anchor: .leading)
            }
            .overlay { HostMoveMarker(motion: motion, item: .space(id)).allowsHitTesting(false) }
    }
}
