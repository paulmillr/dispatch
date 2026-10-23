import SwiftUI
import UIKit

enum TabSegment: String, CaseIterable, Identifiable {
    case terminal, chat
    var id: Self { self }
    var title: String { self == .terminal ? "Terminal" : "Chat" }
    var symbol: String { self == .terminal ? "apple.terminal" : "bubble.left.and.text.bubble.right" }

    /// Chat when the tab runs an agent, else Terminal (M4a, M6a).
    @MainActor static func initial(for tab: MobileTab) -> TabSegment { tab.isChat ? .chat : .terminal }
}

extension TabScreen where Terminal == AnyView, Chat == AnyView {
    /// With the injected segment views (`TabsContent`).
    init(model: MobileTabs, ref: TabRef, path: Binding<[TabsRoute]>, content: TabsContent) {
        self.init(model: model, ref: ref, path: path, terminal: content.terminal, chat: content.chat,
                  terminalSubtitle: content.terminalSubtitle)
    }
}

/// One tab, shared by Chat and Terminal (M4a, M5a, M6a top area): the back pill with the needs-you count, the title,
/// the subtitle (host · cwd in Chat; host · cwd · shell in Terminal) that becomes the pane switcher when the window has
/// splits, the host disc that opens space details, and the Terminal / Chat segmented control over the two injected
/// views. The views get the pane to show: Terminal the active pane, Chat the pane running the agent.
struct TabScreen<Terminal: View, Chat: View>: View {
    let model: MobileTabs
    let ref: TabRef
    @Binding var path: [TabsRoute]
    let terminal: @MainActor (MobileTab, MobilePane) -> Terminal
    let chat: @MainActor (MobileTab, MobilePane) -> Chat
    /// The Terminal segment's subtitle after the host (`TabsContent.terminalSubtitle`).
    var terminalSubtitle: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }

    @State private var segment: TabSegment?
    @Environment(\.tabsColumnWidth) private var column
    @Environment(\.tabsSplitDetail) private var splitDetail
    @Environment(\.tabsSidebarToggle) private var sidebar
    /// The switch sits in the header beside the Duo's sidebar, where the column is a phone's; an iPad's detail column
    /// keeps it under the header, at its own width (`TabSegmentControl.maxWidth`), and the host pill in the header.
    private var segmentInHeader: Bool { splitDetail && UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        let tab = model.tab(ref)
        let workspace = model.workspace(ref.host)
        Group {
            if let tab {
                switch current(tab) {
                case .terminal:
                    if let pane = tab.activePane { terminal(tab, pane) } else { TabGone() }
                case .chat:
                    if let pane = tab.agentPane { chat(tab, pane) } else { TabNoAgent() }
                }
            } else {
                TabGone()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The switch is part of the bar, under the header: the thread scrolls beneath both, through the system's
        // scroll edge effect, as content does under the system's bars; the terminal, a fixed grid, starts below them.
        // Beside the Duo's sidebar it is in the header itself, where the host pill was (`segmentInHeader`).
        .safeAreaBar(edge: .top, spacing: 0) {
            // A shell tab has no Chat: no switch.
            if let tab, !segmentInHeader, !tab.isShell {
                TabSegmentControl(selection: Binding(get: { current(tab) }, set: { choose($0) }))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .tabsPushedScreen()
        .toolbar {
            if let tab, let workspace {
                TabScreenHeader(tab: tab, title: model.label(of: tab, host: workspace.host), host: workspace.host,
                                space: workspace.space(of: tab), needsYou: model.needsYou(excluding: ref), backTitle: backTitle,
                                segment: current(tab), terminalSubtitle: tab.activePane.flatMap { terminalSubtitle(tab, $0) },
                                column: column, showsBack: !splitDetail,
                                segmentSelection: segmentInHeader && !tab.isShell ? Binding(get: { current(tab) }, set: { choose($0) }) : nil,
                                sidebar: splitDetail ? sidebar : nil,
                                back: back, details: { path.append(.details(tab.space)) })
            } else if !splitDetail {
                ToolbarItem(placement: .topBarLeading) {
                    TabsBackPill.needsYou(model.needsYou(), back: backTitle, action: back)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .onAppear {
            guard let tab else { return }
            model.visited(tab.space)
            // The segment the tab opened on stays until the user picks the other one: an agent starting in the shell
            // (or a snapshot briefly without its binding) does not flip the screen under the user's fingers.
            if segment == nil { segment = current(tab) }
        }
        // Switch Terminal / Chat (⇧⌘C, MobileCommands) for this tab.
        .onReceive(NotificationCenter.default.publisher(for: TabSegment.switchRequested)) { note in
            guard let tab, TabSegment.switchRequest(note) == ref else { return }
            choose(current(tab) == .terminal ? .chat : .terminal)
        }
    }

    private func current(_ tab: MobileTab) -> TabSegment {
        if tab.isShell { return .terminal }
        return segment ?? model.segments[ref] ?? TabSegment.initial(for: tab)
    }

    private func choose(_ next: TabSegment) {
        segment = next
        model.segments[ref] = next
    }

    private func back() { if !path.isEmpty { path.removeLast() } }

    /// The screen Back returns to: the space, a host, or Spaces itself.
    private var backTitle: String {
        switch path.dropLast().last {
        case .space(let space)?, .details(let space)?: model.space(space)?.name ?? "Back"
        case .host(let id)?: model.workspace(id)?.host.name ?? "Back"
        case .tab(let tab)?: model.tab(tab).flatMap { tab in model.workspace(tab.ref.host).map { model.label(of: tab, host: $0.host) } } ?? "Back"
        case nil: "Spaces"
        }
    }
}

/// The top of a tab (M4a): back pill "‹ 1", title, subtitle or pane switcher, host disc.
struct TabScreenHeader: ToolbarContent {
    let tab: MobileTab
    /// The tab's shown name (`MobileTabs.label(of:)`).
    var title: String? = nil
    let host: TabsHost
    let space: MobileSpace?
    let needsYou: Int
    /// What Back returns to, shown when nothing needs the user elsewhere.
    var backTitle = "Back"
    let segment: TabSegment
    /// Terminal's "~/src/app · zsh" from the terminal itself, when it knows.
    var terminalSubtitle: String? = nil
    /// The column the bar is in (`TabsScreenHeader.column`).
    var column: CGFloat? = nil
    var showsBack = true
    /// The split's detail column: the Terminal / Chat switch in place of the host pill, one header row (the space's
    /// details stay a row away in the sidebar).
    var segmentSelection: Binding<TabSegment>? = nil
    /// The iPad split's sidebar button, in the back pill's place (`TabsSidebarPill`).
    var sidebar: TabsSidebarToggle? = nil
    let back: () -> Void
    let details: () -> Void

    var body: some ToolbarContent {
        TabsScreenHeader(title: title ?? tab.name, column: column, showsBack: showsBack || sidebar != nil,
                         trailingWidth: segmentSelection == nil ? 44 : TabSegmentControl.headerWidth,
                         atTrailingEdge: column == nil || segmentSelection != nil) {
            if let sidebar {
                TabsSidebarPill(toggle: sidebar, needsYou: needsYou)
            } else {
                TabsBackPill.needsYou(needsYou, back: backTitle, action: back)
            }
        } subtitle: {
            if tab.panes.count > 1 {
                Menu {
                    Section("Panes") {
                        Picker("Pane", selection: Binding(get: { tab.activePane?.key ?? "" }, set: { key in
                            if let pane = tab.panes.first(where: { $0.key == key }) { tab.pick(pane) }
                        })) {
                            ForEach(Array(tab.panes.enumerated()), id: \.element.key) { index, pane in
                                Text(Self.paneTitle(pane, index: index, host: host)).tag(pane.key)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    HStack(spacing: 3) {
                        subtitle
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).imageScale(.small)
                    }
                    .fixedSize()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Pane \((tab.panes.firstIndex { $0.key == tab.activePane?.key } ?? 0) + 1) of \(tab.panes.count)")
            } else {
                subtitle
            }
        } trailing: {
            if let segmentSelection {
                TabSegmentControl(selection: segmentSelection, compact: true)
                    .frame(width: TabSegmentControl.headerWidth)
            } else {
                Button(action: details) { HostGlyph(host: host.glyphRecord, size: 22).foregroundStyle(host.tint) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows the space’s tabs and its Close")
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(.hoverEffect, Circle())
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Space details")
            }
        }
    }

    /// Chat: host · cwd (mono). Terminal: host · cwd · shell (M6a).
    private var subtitle: some View {
        if segment == .terminal, let terminalSubtitle {
            return TabsHostPath(host: host, path: terminalSubtitle, trailing: nil, mono: false)
        }
        let pane = segment == .chat ? (tab.agentPane ?? tab.activePane) : tab.activePane
        let cwd = host.abbreviate(pane?.cwd ?? space?.cwd)
        return TabsHostPath(host: host, path: cwd, trailing: segment == .terminal ? tab.program : nil, mono: segment == .chat)
    }

    static func paneTitle(_ pane: MobilePane, index: Int, host: TabsHost) -> String {
        let place = host.abbreviate(pane.cwd).map { " · " + $0 } ?? ""
        return "Pane \(index + 1)" + place
    }
}

/// M4a's segmented control: Terminal and Chat in a 34 point capsule.
struct TabSegmentControl: View {
    /// In a header beside the split's sidebar (`TabScreenHeader`): glyphs only, as a bar's controls are.
    static let headerWidth: CGFloat = 96

    @Binding var selection: TabSegment
    /// Glyphs for the header; the titles stay the segments' accessibility labels.
    var compact = false

    /// The control's widest on an iPad, centred over the column: two segments across a 1,000-point column (a 13-inch
    /// split, a hidden sidebar) read as a phone's control stretched; iPadOS keeps its segmented controls this narrow.
    /// The phone's spans its column.
    static func maxWidth(idiom: UIUserInterfaceIdiom) -> CGFloat { idiom == .pad ? 400 : .infinity }

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(TabSegment.allCases) { segment in
                if compact {
                    Image(systemName: segment.symbol).accessibilityLabel(segment.title).tag(segment)
                } else {
                    Text(segment.title).tag(segment)
                }
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: Self.maxWidth(idiom: UIDevice.current.userInterfaceIdiom))
    }
}

private struct TabGone: View {
    var body: some View {
        Text("This tab is no longer on the host.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct TabNoAgent: View {
    var body: some View {
        Text("No agent runs in this tab. Start one in Terminal and it shows up here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 44)
    }
}
