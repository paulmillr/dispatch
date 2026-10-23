import SwiftUI
import UIKit

/// The iPad's five modes of a tab (I1–I8), the Mac's: Terminal, Chat, Files, Review and Commits, as glyphs in the
/// strip's switch. They are the phone's segment and Files mode in one (`MobileTabs.segments`, `filesModes`), so a
/// window that narrows to the phone's stack shows the same view and back.
enum PadMode: String, CaseIterable, Identifiable, Hashable {
    case terminal, chat, files, review, commits
    var id: Self { self }

    init(segment: TabSegment, files: FilesMode) {
        switch segment {
        case .terminal: self = .terminal
        case .chat: self = .chat
        case .files:
            switch files {
            case .files: self = .files
            case .review: self = .review
            case .commits: self = .commits
            }
        }
    }

    var title: String {
        switch self {
        case .terminal: TabSegment.terminal.title
        case .chat: TabSegment.chat.title
        case .files: FilesMode.files.title
        case .review: FilesMode.review.title
        case .commits: FilesMode.commits.title
        }
    }

    var symbol: String {
        switch self {
        case .terminal: TabSegment.terminal.symbol
        case .chat: TabSegment.chat.symbol
        case .files: FilesMode.files.symbol
        case .review: FilesMode.review.symbol
        case .commits: FilesMode.commits.symbol
        }
    }

    var segment: TabSegment {
        switch self {
        case .terminal: .terminal
        case .chat: .chat
        case .files, .review, .commits: .files
        }
    }

    /// The Files mode it shows; nil for Terminal and Chat.
    var filesMode: FilesMode? {
        switch self {
        case .terminal, .chat: nil
        case .files: .files
        case .review: .review
        case .commits: .commits
        }
    }

    /// The modes a tab offers: Terminal; Chat unless it is a plain SSH shell; Files where the host can serve it
    /// (`MobileFilesAvailability.showsModes`: not over plain SSH or without the Files & git grant); Review and Commits
    /// inside a git repository (`SpaceGitFacts`). While the repository is not known yet (`repository` nil) a tab that
    /// shows Review or Commits keeps them, so a launch never draws Files for a frame first.
    @MainActor static func available(tab: MobileTab, host: TabsHost, repository: Bool?, keeping shown: PadMode? = nil) -> [PadMode] {
        var modes: [PadMode] = [.terminal]
        if TabSegment.available(for: tab).contains(.chat) { modes.append(.chat) }
        guard MobileFilesAvailability(host).showsModes else { return modes }
        modes.append(.files)
        if repository == true || (repository == nil && (shown == .review || shown == .commits)) {
            modes += [.review, .commits]
        }
        return modes
    }
}

extension MobileTabs {
    /// The mode the tab chose last (its segment and Files mode), before what the host offers.
    func chosenMode(_ tab: MobileTab) -> PadMode {
        PadMode(segment: segments[tab.ref] ?? TabSegment.initial(for: tab), files: filesModes[tab.ref] ?? .files)
    }

    /// The mode the tab shows among `available`: its choice, else Files for a git mode outside a repository, else
    /// Terminal.
    func shownMode(_ tab: MobileTab, available: [PadMode]) -> PadMode {
        let chosen = chosenMode(tab)
        if available.contains(chosen) { return chosen }
        if chosen.filesMode != nil, available.contains(.files) { return .files }
        return .terminal
    }

    /// Shows `mode` in the tab: its segment, and for Files, Review and Commits the Files mode (Files' "Not now" returns
    /// to the segment shown before Files).
    func setMode(_ mode: PadMode, for ref: TabRef) {
        if mode.segment == .files, segments[ref] != .files, let tab = tab(ref) {
            segmentsBeforeFiles[ref] = segments[ref] ?? TabSegment.initial(for: tab)
        }
        if segments[ref] != mode.segment { segments[ref] = mode.segment }
        if let files = mode.filesMode, filesModes[ref] != files { filesModes[ref] = files }
    }

    /// The strip's pills: the tab's space's tabs in the space's order (the server's, as the Mac's strip has them).
    func strip(for ref: TabRef) -> [MobileTab] {
        guard let tab = tab(ref), let space = space(tab.space) else { return tab(ref).map { [$0] } ?? [] }
        return space.tabs
    }

    /// The folder a tab's git facts are read for: its active pane's, else its space's (absolute paths only).
    func gitDirectory(_ tab: MobileTab) -> String? {
        guard let directory = tab.activePane?.cwd ?? workspace(tab.ref.host)?.space(of: tab)?.cwd, directory.hasPrefix("/")
        else { return nil }
        return directory
    }

    /// Whether the tab's folder is in a git repository: the facts' answer, else what an earlier run learned
    /// (`knownRepositories`, kept with the iPad's split memory); nil while not known.
    func repository(_ tab: MobileTab, facts: SpaceGitFacts?) -> Bool? {
        let key = SpaceGitFacts.Key(host: tab.ref.host, key: tab.ref.key)
        return facts?.isRepository(key, directory: gitDirectory(tab)) ?? facts?.isRepository(key)
            ?? knownRepositories[Self.repositoryKey(tab.ref)]
    }

    /// `knownRepositories`' key for a tab.
    static func repositoryKey(_ ref: TabRef) -> String { ref.host.uuidString + "|" + ref.key }

    /// The modes the tab offers now (`PadMode.available`), the one it shows, and the switch's slots: while the
    /// repository is not known the git two hold their places, disabled, so the switch never changes its width when the
    /// answer comes (only when it is no).
    func modes(_ tab: MobileTab, facts: SpaceGitFacts?) -> (available: [PadMode], shown: PadMode, slots: [PadMode]) {
        guard let host = workspace(tab.ref.host)?.host else { return ([.terminal], .terminal, [.terminal]) }
        let repository = repository(tab, facts: facts)
        let available = PadMode.available(tab: tab, host: host, repository: repository, keeping: chosenMode(tab))
        let slots = repository == nil && available.contains(.files)
            ? PadMode.allCases.filter { available.contains($0) || $0 == .review || $0 == .commits } : available
        return (available, shownMode(tab, available: available), slots)
    }
}

/// The iPad split's strip (I1–I8), the Mac's: the shown tab's space's tabs as pills in one glass track (state dot,
/// the agent's mark or a terminal glyph, the title, × on the selected one), "+" (a tap a shell, held the agents), and
/// the mode switch at the trailing end. With the sidebar hidden (I8) it leads with the sidebar pill and the space's
/// capsule. Above the detail column's stack, so a screen a mode pushes (a file, a commit's diff) opens under it.
struct PadStrip: View {
    let navigator: SpacesNavigator
    let ref: TabRef
    let content: TabsContent
    /// The sidebar is hidden: its pill and the space's capsule lead the strip.
    let sidebarHidden: Bool

    private var model: MobileTabs { navigator.model }

    var body: some View {
        if let tab = model.tab(ref), let workspace = model.workspace(ref.host) {
            let modes = model.modes(tab, facts: content.gitFacts)
            HStack(spacing: 10) {
                if sidebarHidden {
                    // One glass pill (the toggle and the count), the space's capsule apart from it.
                    PadSidebarPill(needsYou: model.needsYou(excluding: ref), hidden: true) { navigator.toggleSidebar() }
                        .padding(.trailing, 2)
                    if let space = workspace.space(of: tab) {
                        PadSpaceCapsule(host: workspace.host, space: space,
                                        branch: content.gitFacts?.facts(SpaceGitFacts.Key(host: ref.host, key: ref.key))?.branch,
                                        switcher: { navigator.switcher = ref })
                    }
                }
                PadTabPills(model: model, tabs: model.strip(for: ref), selected: ref,
                            select: { navigator.select($0) },
                            close: { navigator.actions.close(.tab($0), .close) }) {
                    if let space = workspace.space(of: tab) {
                        PadNewTabButton(navigator: navigator, space: space, connected: workspace.client != nil || workspace.opensShells)
                    }
                }
                PadModeSwitch(modes: modes.slots, enabled: Set(modes.available), selected: modes.shown,
                              review: modes.available.contains(.review) ? content.files.reviewCount(ref) : 0) { mode in
                    model.setMode(mode, for: ref)
                }
                .onChange(of: model.repository(tab, facts: content.gitFacts), initial: true) { _, known in
                    if let known { navigator.rememberRepository(ref, known) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
            // A windowed app's controls sit in the window's leading corner: the strip starts after them when the
            // sidebar (whose bar holds them otherwise) is hidden.
            .containerCornerOffset(.leading, sizeToFit: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pad-strip")
        }
    }
}

/// The sidebar's toggle as a pill with the needs-you count (I8, the strip's leading edge), or as the sidebar bar's disc.
struct PadSidebarPill: View {
    let needsYou: Int
    /// The sidebar is hidden (the strip's pill shows it again).
    let hidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.dispatchPink)
                if needsYou > 0 {
                    Text("\(needsYou)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.onAccent)
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Color.dispatchPink, in: Circle())
                }
            }
            .padding(.leading, needsYou > 0 ? 13 : 0)
            .padding(.trailing, needsYou > 0 ? 9 : 0)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel(hidden ? "Show sidebar" : "Hide sidebar")
        .accessibilityValue(needsYou > 0 ? "\(needsYou) \(needsYou == 1 ? "conversation needs" : "conversations need") you" : "")
    }
}

/// I8's space capsule: the host's glyph (a tap shows the host's stats in a popover, I5) and the space's name and branch
/// (a tap opens the space switcher, P3: its tabs, New tab, the host, Rename and Close).
struct PadSpaceCapsule: View {
    let host: TabsHost
    let space: MobileSpace
    let branch: String?
    let switcher: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PadHostStatsButton(host: host, size: 30)
            Button(action: switcher) {
                HStack(spacing: 6) {
                    Text(space.name).font(.subheadline.weight(.semibold))
                    if let branch {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                            Text(branch).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Space switcher")
            .accessibilityValue([space.name, branch].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Shows the space’s tabs, New tab and Close")
            .accessibilityIdentifier("space-switcher")
        }
        .fixedSize()
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .frame(height: 38)
        .glassEffect(.regular.interactive(), in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// A host's glyph as a glass disc with its connection dot, which shows the host's stats as a popover (I5,
/// `HostStatsPopoverContent`): from the sidebar's host header and the strip's space capsule.
struct PadHostStatsButton: View {
    let host: TabsHost
    var size: CGFloat = 34
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            HostGlyph(host: host.glyphRecord, size: size * 0.5)
                .foregroundStyle(host.state == .offline ? Color.secondary : host.tint)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(host.state == .connected ? Color.stateConnected : Color.secondary)
                .frame(width: 7, height: 7)
                .offset(x: 1, y: 1)
                .accessibilityHidden(true)
        }
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .popover(isPresented: $shown, arrowEdge: .leading) {
            HostStatsPopoverContent(hostID: host.id)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("\(host.name) stats")
        .accessibilityHint("Shows the host’s CPU, memory and disk")
    }
}

/// The space's tabs as pills in one glass track: the selected one on the lens with its ×, the others up to 200 points
/// and it up to 260, at their own widths while they fit. When they do not, every pill shrinks (its title truncating) down
/// to 120 points (the selected one 150, its × kept) before any is left out; past that the track keeps the pills that fit
/// (the selected one always) and an overflow menu of the rest, so no pill is cut by the track's edge. `trailing` ("+")
/// follows the track.
struct PadTabPills<Trailing: View>: View {
    let model: MobileTabs
    let tabs: [MobileTab]
    let selected: TabRef
    let select: (TabRef) -> Void
    let close: (TabRef) -> Void
    @ViewBuilder var trailing: Trailing
    /// The room for the track and `trailing`, measured; nil before the first layout (every pill, shrinking).
    @State private var room: CGFloat?


    var body: some View {
        let split = PadPills.visible(tabs.map(\.ref), selected: selected, room: room.map { $0 - PadPills.reserved })
        HStack(spacing: 10) {
            PadPillsLayout(spacing: 2) {
                ForEach(tabs.filter { split.shown.contains($0.ref) }) { tab in
                    PadTabPill(title: label(tab), urgency: model.urgency(of: tab), agent: model.agent(of: tab), shell: tab.isShell,
                               selected: tab.ref == selected, select: { select(tab.ref) }, close: { close(tab.ref) })
                        .accessibilityIdentifier("pad-tab-" + tab.ref.key)
                        .layoutValue(key: PadPillMinimum.self, value: tab.ref == selected ? PadPills.selectedMinimum : PadPills.minimum)
                }
                if !split.hidden.isEmpty {
                    PadOverflowPill(tabs: tabs.filter { split.hidden.contains($0.ref) }, label: label, select: select)
                        .layoutValue(key: PadPillMinimum.self, value: PadPills.overflowWidth)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
            .accessibilityIdentifier("pad-tabs")
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
    }

    private func label(_ tab: MobileTab) -> String { model.label(of: tab, host: model.workspace(tab.ref.host)?.host) }
}

/// The strip's pill sizes and which pills the track holds (`PadTabPills`).
enum PadPills {
    static let width: CGFloat = 200, selectedWidth: CGFloat = 260
    static let minimum: CGFloat = 120, selectedMinimum: CGFloat = 150
    /// What the overflow menu's pill takes.
    static let overflowWidth: CGFloat = 64
    /// "+" and the gap before it, the track's padding.
    static let reserved: CGFloat = 38 + 10 + 6

    /// The pills the track holds in `room` (nil: all) at their narrowest, the selected one always, in the strip's
    /// order, and the ones the overflow menu lists.
    static func visible(_ tabs: [TabRef], selected: TabRef, room: CGFloat?) -> (shown: [TabRef], hidden: [TabRef]) {
        func narrowest(_ count: Int, overflow: Bool) -> CGFloat {
            guard count > 0 else { return overflow ? overflowWidth : 0 }
            let pills = CGFloat(count - 1) * minimum + selectedMinimum
            return pills + CGFloat(count - 1 + (overflow ? 1 : 0)) * 2 + (overflow ? overflowWidth : 0)
        }
        guard let room, narrowest(tabs.count, overflow: false) > room else { return (tabs, []) }
        var count = max(1, tabs.count - 1)
        while count > 1, narrowest(count, overflow: true) > room { count -= 1 }
        var shown = Array(tabs.prefix(count))
        if !shown.contains(selected) { shown[count - 1] = selected }
        return (shown, tabs.filter { !shown.contains($0) })
    }
}

/// The narrowest a pill may be drawn (`PadPillsLayout`).
struct PadPillMinimum: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// The track: the pills side by side at their own widths when they fit; else the widest give way first, each down to
/// its `PadPillMinimum`, so all of them share the room.
struct PadPillsLayout: Layout {
    var spacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(proposal.width, subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let width = widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        // Never wider than offered: the column keeps its width whatever the pills need.
        return CGSize(width: proposal.width.map { Swift.min(width, $0) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    /// Each pill's width in `room`: its own when all fit, else the widest capped at a common width found by halving,
    /// none under its minimum.
    func widths(_ room: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let minimum = subviews.map { $0[PadPillMinimum.self] }
        return Self.shrink(ideal: ideal, minimum: minimum, room: room.map { $0 - spacing * CGFloat(max(0, subviews.count - 1)) })
    }

    static func shrink(ideal: [CGFloat], minimum: [CGFloat], room: CGFloat?) -> [CGFloat] {
        guard let room, ideal.reduce(0, +) > room else { return ideal }
        // Under the minimums (before the track's room is measured, `PadPills.visible`): all in proportion.
        let floor = zip(ideal, minimum).map { Swift.min($0, $1) }
        let least = floor.reduce(0, +)
        if least > room { return floor.map { ($0 * Swift.max(0, room) / least).rounded(.down) } }
        func widths(_ cap: CGFloat) -> [CGFloat] { zip(ideal, minimum).map { Swift.min($0, Swift.max(cap, $1)) } }
        var low: CGFloat = 0, high = ideal.max() ?? 0
        for _ in 0..<24 {
            let cap = (low + high) / 2
            if widths(cap).reduce(0, +) > room { high = cap } else { low = cap }
        }
        return widths(low).map { $0.rounded(.down) }
    }
}

/// The track's overflow: "+3" opens a menu of the pills left out; choosing one shows it (and so its pill).
struct PadOverflowPill: View {
    let tabs: [MobileTab]
    let label: (MobileTab) -> String
    let select: (TabRef) -> Void

    var body: some View {
        Menu {
            ForEach(tabs) { tab in
                Button(label(tab)) { select(tab.ref) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                Text("\(tabs.count)").font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .frame(width: PadPills.overflowWidth, height: 32)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .accessibilityLabel("More tabs")
        .accessibilityValue("\(tabs.count)")
    }
}

/// One pill (I1): the state dot (blue unread for needs you or an unseen result, amber working), the agent's mark or a
/// terminal glyph, the title; selected, on the lens and with its × (Close Tab).
struct PadTabPill: View {
    let title: String
    let urgency: TabUrgency?
    let agent: String?
    let shell: Bool
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 32

    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 7) {
                    if let urgency {
                        Circle().fill(urgency == .working ? Color.stateWorking : Color.stateUnread).frame(width: 7, height: 7)
                    }
                    AgentGlyph(agent: agent, size: 14)
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: max(32, height))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue([Self.spoken(urgency), agent].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? .isSelected : [])
            if selected {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, selected ? 6 : 12)
        .modifier(PadPillWidth(max: selected ? PadPills.selectedWidth : PadPills.width))
        .background { if selected { Capsule().fill(Color.lens) } }
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    static func spoken(_ urgency: TabUrgency?) -> String? {
        switch urgency {
        case .needsYou?: "Needs you"
        case .working?: "Working"
        case .unseen?: "Unread"
        case nil: nil
        }
    }
}

/// A pill at its own width up to `max`, its title truncating past it (`TabsCappedWidth`).
private struct PadPillWidth: ViewModifier {
    let max: CGFloat
    func body(content: Content) -> some View {
        PadPillCap(max: max) { content }
    }
}

/// Its content at its own width up to `max`, or narrower when the track proposes less (`PadPillsLayout`), the title
/// truncating.
private struct PadPillCap: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = width(content, proposal)
        return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                      proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    private func width(_ content: LayoutSubview, _ proposal: ProposedViewSize) -> CGFloat {
        Swift.min(content.sizeThatFits(.unspecified).width, max, proposal.width ?? .infinity)
    }
}

/// The strip's "+": a tap opens a shell in the space (New Tab, ⌘T), held the space screen's menu (P2e,
/// `SpaceNewTabMenu`): Shell, the host's agents (started in a new tab of this space, as New chat starts them), and
/// another space (New tab's picker).
struct PadNewTabButton: View {
    let navigator: SpacesNavigator
    let space: MobileSpace
    let connected: Bool

    var body: some View {
        Menu {
            SpaceNewTabMenu(navigator: navigator, space: space)
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        } primaryAction: {
            navigator.newTab(in: space)
        }
        .menuOrder(.fixed)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .disabled(!connected)
        .accessibilityLabel("New tab")
        .accessibilityHint("Hold for an agent or another space")
        .task(id: LaunchKey(host: space.ref.host, connected: connected)) {
            guard connected else { return }
            await navigator.loadAgents(host: space.ref.host)
        }
    }

    private struct LaunchKey: Hashable {
        let host: UUID
        let connected: Bool
    }
}

/// The mode switch (I1): the modes as glyphs in one glass capsule, the shown one pink on the lens, Review with its
/// comment count. Each is a button labelled with its title inside the `tab-segments` container, as the phone's capsule
/// is, so the UI tests find them the same way.
struct PadModeSwitch: View {
    let modes: [PadMode]
    /// The modes that can be chosen now; the others hold their places, greyed (Review and Commits until the
    /// repository is known).
    var enabled: Set<PadMode>? = nil
    let selected: PadMode
    /// Review's comment count; zero draws none.
    let review: Int
    let choose: (PadMode) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(modes) { mode in
                let on = mode == selected
                let usable = enabled?.contains(mode) ?? true
                Button { choose(mode) } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(on ? Color.dispatchPink : usable ? Color.primary : Color.secondary.opacity(0.5))
                        .frame(width: 40, height: 32)
                        .background { if on { Capsule().fill(Color.lens) } }
                        .overlay(alignment: .topTrailing) {
                            if mode == .review, review > 0 {
                                Text("\(review)")
                                    .font(.system(size: 10, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 14, minHeight: 14)
                                    .background(Color.stateUnread, in: Capsule())
                                    .offset(x: 2, y: -2)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!usable)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
                .accessibilityLabel(mode.title)
                .accessibilityValue(mode == .review && review > 0 ? ReviewText.count(review) : "")
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityShowsLargeContentViewer { Label(mode.title, systemImage: mode.symbol) }
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
        .accessibilityIdentifier(TabSegmentCapsule.identifier)
    }
}

/// Under the iPad's context row: the line a mode's accessory is on the phone (Review sent with Undo, offline with
/// Reconnect), in a rounded row across the column.
struct PadBanner<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Review's and Commits' list beside its pane (I2, I3): the list at 360 points, a hairline, the pane; before a row is
/// chosen the pane says how to fill it (I2b, I3b).
struct PadListPane<List: View, Pane: View>: View {
    @ViewBuilder var list: List
    @ViewBuilder var pane: Pane

    static var listWidth: CGFloat { 360 }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: Self.listWidth)
            Rectangle().fill(Color.hairline).frame(width: 0.5).ignoresSafeArea(edges: .bottom)
            pane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension FilesRoute {
    /// Whether the screen opens in the iPad's pane beside its mode's list rather than over the tab: a change's diff
    /// (Review) and a commit (Commits); a file or a commit's file is pushed.
    var opensInPane: Bool {
        switch mode {
        case .review: path != nil
        case .commits: revision != nil && path == nil
        case .files: false
        }
    }
}

/// The pane before a row is chosen (I2b, I3b): the mode's glyph and a line.
struct PadPaneEmpty: View {
    let mode: FilesMode

    var text: String { mode == .commits ? "Select a commit" : "Select a change to see its diff" }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: mode.symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pad-pane-empty")
    }
}

/// A pane's own header (I2, I3), where a pushed screen has its bar: the title and a line under it, the controls trailing.
struct PadPaneHeader<Subtitle: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1).accessibilityAddTraits(.isHeader)
                subtitle.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

extension EnvironmentValues {
    /// The iPad's Review and Commits panes: the route the pane shows, so its list marks the row (`PadListPane`).
    @Entry var filesPaneSelection: FilesRoute? = nil
}
