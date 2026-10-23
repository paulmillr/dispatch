import SwiftUI
import UIKit

/// The tab screen's switch (the capsule, H0): Terminal, Chat and Files. A plain SSH shell tab has no Chat.
enum TabSegment: String, CaseIterable, Identifiable {
    case terminal, chat, files
    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .chat: "Chat"
        case .files: "Files"
        }
    }

    /// Glyphs as the Mac's: Chat is `text.bubble`.
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .chat: "text.bubble"
        case .files: "folder"
        }
    }

    /// Chat when the tab runs an agent, else Terminal (M4a, M6a).
    @MainActor static func initial(for tab: MobileTab) -> TabSegment { tab.isChat ? .chat : .terminal }

    /// The segments the tab's capsule offers: Terminal · Files for a plain SSH shell tab, all three otherwise (a tab
    /// without an agent keeps Chat, which says how to start one).
    @MainActor static func available(for tab: MobileTab) -> [TabSegment] { tab.isShell ? [.terminal, .files] : allCases }
}

extension TabScreen where Terminal == AnyView, Chat == AnyView {
    /// With the injected segment views (`TabsContent`).
    init(model: MobileTabs, ref: TabRef, path: Binding<[TabsRoute]>, content: TabsContent) {
        self.init(model: model, ref: ref, path: path, terminal: content.terminal, chat: content.chat,
                  terminalSubtitle: content.terminalSubtitle, chatTrailing: content.chatTrailing, files: content.files,
                  gitFacts: content.gitFacts)
    }
}

/// One tab, shared by Terminal, Chat and Files (M4a, M5a, M6a top area, H0): the back pill with the needs-you count, the
/// title, the subtitle (host · cwd in Chat and Files; host · cwd · shell in Terminal) that becomes the pane switcher
/// when the window has splits, the host disc that opens space details, and the capsule (Terminal · Chat · Files) over
/// the injected views. The views get the pane to show: Terminal the active pane, Chat the pane running the agent; Files
/// shows the modes (`TabFilesSegment`) in the active pane's folder.
struct TabScreen<Terminal: View, Chat: View>: View {
    let model: MobileTabs
    let ref: TabRef
    @Binding var path: [TabsRoute]
    let terminal: @MainActor (MobileTab, MobilePane) -> Terminal
    let chat: @MainActor (MobileTab, MobilePane) -> Chat
    /// The Terminal segment's subtitle after the host (`TabsContent.terminalSubtitle`).
    var terminalSubtitle: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }
    /// The Chat segment's trailing header controls around the host disc (`TabsContent.chatTrailing`); nil: the disc.
    /// `keepsDisc`: the given view is the Duo header's switch, which stays.
    var chatTrailing: (@MainActor (MobileTab, MobilePane, AnyView, _ keepsDisc: Bool) -> AnyView)? = nil
    /// The Files segment's modes (`FilesModeContent`): placeholders until the areas fill them.
    var files = FilesModeContent()
    /// The tab's repository and branch; nil reads nothing (the modes' bar stays hidden).
    var gitFacts: SpaceGitFacts? = nil

    @State private var segment: TabSegment?
    @State private var filesMode: FilesMode?
    @Environment(\.tabsColumnWidth) private var column
    @Environment(\.tabsSplitDetail) private var splitDetail
    @Environment(\.tabsSidebarToggle) private var sidebar
    /// The iPad split's detail column: the strip above (`PadStrip`) owns the switch; this screen shows the mode's body,
    /// its context row and banner, and Review and Commits beside their panes.
    @Environment(\.tabsPadStrip) private var strip
    /// The host disc's space switcher (P3): `SpacesNavigator.switcher`, set where the stack is.
    @Environment(\.tabsSwitcher) private var switcher
    /// The switch sits in the header beside the Duo's sidebar, where the column is a phone's; an iPad's detail column
    /// keeps it under the header, at its own width (`TabSegmentCapsule.maxWidth`), and the host pill in the header.
    private var segmentInHeader: Bool { splitDetail && UIDevice.current.userInterfaceIdiom == .phone }

    var body: some View {
        let tab = model.tab(ref)
        let workspace = model.workspace(ref.host)
        Group {
            if let tab, strip {
                stripBody(tab, workspace: workspace)
            } else if let tab {
                switch current(tab) {
                case .terminal:
                    if let pane = tab.activePane { terminal(tab, pane) } else { TabGone() }
                case .chat:
                    if let pane = tab.agentPane {
                        chat(tab, pane).environment(\.chatShowTerminal, ChatTerminalSwitch { choose(.terminal) })
                    } else { TabNoAgent() }
                case .files:
                    if let workspace {
                        TabFilesSegment(context: filesContext(tab, host: workspace.host), content: files,
                                        mode: Binding(get: { currentMode }, set: { pick($0) }),
                                        repository: repository(tab) == true,
                                        notNow: { notNow(tab) }, changeIntegration: { path.append(.host(ref.host)) })
                    } else {
                        TabGone()
                    }
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
            if let tab, strip {
                stripContext(tab, workspace: workspace)
            } else if let tab {
                let bar = current(tab) == .files ? workspace.flatMap { filesBar(tab, host: $0.host) } : nil
                VStack(spacing: 10) {
                    if !segmentInHeader {
                        TabSegmentCapsule(selection: Binding(get: { current(tab) }, set: { choose($0) }),
                                          segments: TabSegment.available(for: tab), badge: filesBadge)
                    }
                    if let bar {
                        HStack(spacing: 10) { bar }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                // Beside the Duo's sidebar the capsule is in the header: the Files bar row keeps its own margins.
                .padding(.top, segmentInHeader && bar == nil ? 0 : 4)
                .padding(.bottom, segmentInHeader && bar == nil ? 0 : 10)
            }
        }
        .tabsPushedScreen()
        // The strip is the iPad's header: no bar over the tab.
        .toolbarVisibility(strip ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            // None in the iPad's strip layout: the strip above the column is its header.
            if !strip, let tab, let workspace {
                TabScreenHeader(tab: tab, title: model.label(of: tab, host: workspace.host), host: workspace.host,
                                space: workspace.space(of: tab), needsYou: model.needsYou(excluding: ref), backTitle: backTitle,
                                segment: current(tab), terminalSubtitle: tab.activePane.flatMap { terminalSubtitle(tab, $0) },
                                column: column, showsBack: !splitDetail,
                                segmentSelection: segmentInHeader ? Binding(get: { current(tab) }, set: { choose($0) }) : nil,
                                segments: TabSegment.available(for: tab), filesBadge: filesBadge,
                                sidebar: splitDetail ? sidebar : nil,
                                chatTrailing: chatControls(tab, host: workspace.host),
                                back: back, details: { switcher?.switcher = ref })
            } else if !strip, !splitDetail {
                ToolbarItem(placement: .topBarLeading) {
                    TabsBackPill.needsYou(model.needsYou(), back: backTitle, action: back)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .onAppear {
            guard let tab else { return }
            model.opened(tab)
            // The segment the tab opened on stays until the user picks the other one: an agent starting in the shell
            // (or a snapshot briefly without its binding) does not flip the screen under the user's fingers.
            if segment == nil { segment = current(tab) }
            // The strip reads the model's: the segment it opened on is the model's from now on.
            if strip, model.segments[ref] == nil { model.segments[ref] = current(tab) }
        }
        // The tab's repository once per folder and connection (the modes' bar); the branch polled only while Files shows.
        .task(id: gitWatch) {
            guard let gitFacts, let gitWatch else { return }
            if gitWatch.polling {
                await gitFacts.watch(gitWatch.key, directory: gitWatch.directory)
            } else {
                await gitFacts.resolve(gitWatch.key, directory: gitWatch.directory)
            }
        }
        // Switch Terminal / Chat (⇧⌘C, MobileCommands) for this tab, or to a named segment.
        .onReceive(NotificationCenter.default.publisher(for: TabSegment.switchRequested)) { note in
            guard let tab, TabSegment.switchRequest(note) == ref else { return }
            // A named segment (Files' Ask and Open in Terminal, the View menu's modes); else the toggle.
            if let target = TabSegment.switchTarget(note) {
                if TabSegment.available(for: tab).contains(target) {
                    if let mode = TabSegment.switchMode(note) { pick(mode) }
                    choose(target)
                }
                return
            }
            guard TabSegment.available(for: tab).contains(.chat) else { return }
            choose(current(tab) == .terminal ? .chat : .terminal)
        }
    }

    /// The Chat segment's header controls around the host disc (`chatTrailing`), nil elsewhere.
    /// Beside the Duo's sidebar the switch is the header's trailing control: the menu goes before it.
    private func chatControls(_ tab: MobileTab, host: TabsHost) -> AnyView? {
        guard current(tab) == .chat, let pane = tab.agentPane, let chatTrailing else { return nil }
        if segmentInHeader {
            let segments = TabSegment.available(for: tab)
            let capsule = TabSegmentCapsule(selection: Binding(get: { current(tab) }, set: { choose($0) }), segments: segments,
                                            badge: filesBadge, compact: true)
                .frame(width: TabSegmentCapsule.headerWidth(segments.count))
            return chatTrailing(tab, pane, AnyView(capsule), true)
        }
        let disc = TabScreenHeader.disc(host: host) { switcher?.switcher = ref }
        return chatTrailing(tab, pane, AnyView(disc), false)
    }

    private func current(_ tab: MobileTab) -> TabSegment {
        if strip { return model.modes(tab, facts: gitFacts).shown.segment }
        let chosen = segment ?? model.segments[ref] ?? TabSegment.initial(for: tab)
        return TabSegment.available(for: tab).contains(chosen) ? chosen : .terminal
    }

    private func choose(_ next: TabSegment) {
        if next == .files, let tab = model.tab(ref), current(tab) != .files { model.segmentsBeforeFiles[ref] = current(tab) }
        segment = next
        model.segments[ref] = next
    }

    /// S1, S2's Not now: the segment shown before Files.
    private func notNow(_ tab: MobileTab) {
        let previous = model.segmentsBeforeFiles[ref] ?? TabSegment.initial(for: tab)
        choose(previous == .files ? .terminal : previous)
    }

    private var currentMode: FilesMode { (strip ? nil : filesMode) ?? model.filesModes[ref] ?? .files }

    private func pick(_ mode: FilesMode) {
        filesMode = mode
        model.filesModes[ref] = mode
    }

    private struct GitWatch: Equatable {
        let key: SpaceGitFacts.Key
        let directory: String
        /// The host's connection or grant (`SpaceGitFacts.generation`): a new one reads the root again.
        let generation: Int
        /// The Files segment shows: the branch is polled.
        let polling: Bool
    }

    /// What the git facts read: the tab's active folder (the facts store asks only a host whose grant may).
    private var gitWatch: GitWatch? {
        guard let tab = model.tab(ref), let directory = tab.activePane?.cwd ?? model.workspace(ref.host)?.space(of: tab)?.cwd,
              directory.hasPrefix("/") else { return nil }
        return GitWatch(key: SpaceGitFacts.Key(host: ref.host, key: ref.key), directory: directory,
                        generation: gitFacts?.generation(ref.host) ?? 0, polling: current(tab) == .files)
    }

    /// The capsule's Files badge: Review's count, while the host can show Files' modes (none over S1 and S2).
    private var filesBadge: Int {
        guard let host = model.workspace(ref.host)?.host, MobileFilesAvailability(host).showsModes else { return 0 }
        return files.reviewCount(ref)
    }

    private func repository(_ tab: MobileTab) -> Bool? {
        guard let gitWatch else { return nil }
        return gitFacts?.isRepository(gitWatch.key, directory: gitWatch.directory)
            ?? gitFacts?.isRepository(gitWatch.key)
    }

    private func filesContext(_ tab: MobileTab, host: TabsHost) -> FilesModeContext {
        let directory = gitWatch?.directory
        let facts = gitWatch.flatMap { gitFacts?.facts($0.key) }
        return FilesModeContext(tab: tab, host: host, mode: currentMode, directory: directory, git: facts,
                                availability: MobileFilesAvailability(host),
                                push: { route in
                                    // The iPad's Review and Commits open a change or a commit in their pane.
                                    if strip, route.opensInPane {
                                        model.paneRoutes[ref, default: [:]][route.mode] = route
                                    } else {
                                        path.append(.files(ref, route))
                                    }
                                }, select: { pick($0) })
    }

    // MARK: The iPad's strip layout

    /// The shown mode's body: Terminal, Chat at a readable width, Files' listing, Review's and Commits' lists beside
    /// their panes.
    @ViewBuilder private func stripBody(_ tab: MobileTab, workspace: MobileWorkspace?) -> some View {
        let shown = model.modes(tab, facts: gitFacts).shown
        switch shown {
        case .terminal:
            if let pane = tab.activePane { terminal(tab, pane) } else { TabGone() }
        case .chat:
            if let pane = tab.agentPane {
                chat(tab, pane)
                    .environment(\.chatShowTerminal, ChatTerminalSwitch { model.setMode(.terminal, for: ref) })
                    .frame(maxWidth: Self.chatWidth)
                    .frame(maxWidth: .infinity)
            } else {
                TabNoAgent()
            }
        case .files, .review, .commits:
            if let workspace {
                stripFiles(filesContext(tab, host: workspace.host), mode: shown.filesMode ?? .files)
            } else {
                TabGone()
            }
        }
    }

    /// The thread's width on an iPad (I4): a readable column, centred in a wider one.
    static var chatWidth: CGFloat { 720 }

    @ViewBuilder private func stripFiles(_ context: FilesModeContext, mode: FilesMode) -> some View {
        if !context.availability.showsModes {
            FilesUnavailableView(availability: context.availability, notNow: { model.setMode(.terminal, for: ref) },
                                 installHelper: { files.installHelper(context.host.id) },
                                 changeIntegration: { path.append(.host(ref.host)) })
        } else {
            let shown = context.with(mode: mode)
            Group {
                switch mode {
                case .files:
                    files.body(shown)
                case .review, .commits:
                    let chosen = model.paneRoutes[ref]?[mode]
                    let stale = chosen.map { !files.paneShows(ref, $0) } ?? false
                    let selection = stale ? nil : chosen
                    PadListPane {
                        files.body(shown).environment(\.filesPaneSelection, selection)
                    } pane: {
                        if let selection {
                            files.pane(ref, selection).id(selection)
                        } else {
                            PadPaneEmpty(mode: mode)
                        }
                    }
                    .onChange(of: stale, initial: true) { _, stale in
                        if stale { model.paneRoutes[ref]?[mode] = nil }
                    }
                }
            }
            .opacity(context.availability.isOffline ? 0.45 : 1)
        }
    }

    /// The row under the strip (I1–I3): the mode's breadcrumb or branch with its buttons, and the banner the phone's
    /// accessory is (offline with Reconnect, a review sent with Undo).
    @ViewBuilder private func stripContext(_ tab: MobileTab, workspace: MobileWorkspace?) -> some View {
        let shown = model.modes(tab, facts: gitFacts).shown
        if let workspace, let mode = shown.filesMode {
            let context = filesContext(tab, host: workspace.host).with(mode: mode)
            if context.availability.showsModes {
                let banner: AnyView? = if case .offline(let host, let since) = context.availability {
                    AnyView(FilesOfflineAccessory(host: host, since: since) { files.reconnect(context.host.id) })
                } else {
                    files.banner(context)
                }
                VStack(spacing: 8) {
                    if let bar = files.bar(context) {
                        HStack(spacing: 10) { bar }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let banner { PadBanner { banner } }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .environment(\.tabsPadStrip, true)
            }
        }
    }

    /// The shown mode's row under the capsule (a breadcrumb or the branch, and its buttons), while the modes show.
    private func filesBar(_ tab: MobileTab, host: TabsHost) -> AnyView? {
        let context = filesContext(tab, host: host)
        guard context.availability.showsModes else { return nil }
        let mode = FilesMode.available(repository: repository(tab) == true).contains(currentMode) ? currentMode : .files
        return files.bar(context.with(mode: mode))
    }

    private func back() { if !path.isEmpty { path.removeLast() } }

    /// The screen Back returns to: the space, a host, or Spaces itself.
    private var backTitle: String {
        switch path.dropLast().last {
        case .space(let space)?: model.space(space)?.name ?? "Back"
        case .host(let id)?, .detached(let id)?: model.workspace(id)?.host.name ?? "Back"
        case .tab(let tab)?, .files(let tab, _)?: model.tab(tab).flatMap { tab in model.workspace(tab.ref.host).map { model.label(of: tab, host: $0.host) } } ?? "Back"
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
    /// The split's detail column: the capsule, glyphs only, in place of the host pill, one header row (the space's
    /// details stay a row away in the sidebar).
    var segmentSelection: Binding<TabSegment>? = nil
    /// The capsule's segments (`TabSegment.available(for:)`) and the Files badge.
    var segments: [TabSegment] = TabSegment.allCases
    var filesBadge = 0
    /// The iPad split's sidebar button, in the back pill's place (`TabsSidebarPill`).
    var sidebar: TabsSidebarToggle? = nil
    /// The Chat segment's controls around the host disc (the ⋯ menu, conversation mode's disc), in its place.
    var chatTrailing: AnyView? = nil
    let back: () -> Void
    let details: () -> Void

    /// The trailing slot's width: the split's switch, the chat's menu and disc, or the disc alone.
    private var trailingWidth: CGFloat {
        let switchWidth = TabSegmentCapsule.headerWidth(segments.count)
        if chatTrailing != nil { return ChatHeaderControls<EmptyView>.width(disc: segmentSelection == nil ? 44 : switchWidth) }
        return segmentSelection != nil ? switchWidth : 44
    }

    var body: some ToolbarContent {
        TabsScreenHeader(title: title ?? tab.name, column: column, showsBack: showsBack || sidebar != nil,
                         trailingWidth: trailingWidth,
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
            if let chatTrailing {
                chatTrailing
            } else if let segmentSelection {
                TabSegmentCapsule(selection: segmentSelection, segments: segments, badge: filesBadge, compact: true)
                    .frame(width: TabSegmentCapsule.headerWidth(segments.count))
            } else {
                Self.disc(host: host, details: details)
            }
        }
    }

    /// The host disc's identifier (P3's switcher; the iPad stream's tests find it by this).
    static let switcherIdentifier = "space-switcher"

    /// The host disc: the space switcher (P3).
    static func disc(host: TabsHost, details: @escaping () -> Void) -> some View {
        Button(action: details) { HostGlyph(host: host.glyphRecord, size: 22).foregroundStyle(host.tint) }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the space’s tabs, its host and its Close")
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
            .accessibilityLabel("Space switcher")
            .accessibilityIdentifier(switcherIdentifier)
    }

    /// Chat and Files: host · cwd (mono). Terminal: host · cwd · shell (M6a).
    private var subtitle: some View {
        if segment == .terminal, let terminalSubtitle {
            return TabsHostPath(host: host, path: terminalSubtitle, trailing: nil, mono: false)
        }
        let pane = segment == .chat ? (tab.agentPane ?? tab.activePane) : tab.activePane
        let cwd = host.abbreviate(pane?.cwd ?? space?.cwd)
        return TabsHostPath(host: host, path: cwd, trailing: segment == .terminal ? tab.program : nil, mono: segment != .terminal)
    }

    static func paneTitle(_ pane: MobilePane, index: Int, host: TabsHost) -> String {
        let place = host.abbreviate(pane.cwd).map { " · " + $0 } ?? ""
        return "Pane \(index + 1)" + place
    }
}

/// The tab screen's switch (H0): a glass capsule of glyph-and-title segments, the selected one on the lens, the Files
/// segment with the tab's review comment count. Beside the Duo's sidebar it sits in the header, glyphs only (`compact`).
/// Each segment is a button labelled with its title (the UI tests find them so), the capsule a container.
struct TabSegmentCapsule: View {
    @Binding var selection: TabSegment
    var segments: [TabSegment] = TabSegment.allCases
    /// The Files segment's badge: the tab's review comments; zero draws none.
    var badge = 0
    /// Glyphs for the header; the titles stay the segments' accessibility labels.
    var compact = false

    /// In a header beside the split's sidebar (`TabScreenHeader`): glyphs only, 40 points a segment.
    static func headerWidth(_ count: Int) -> CGFloat { CGFloat(count) * 40 + 4 }

    /// The capsule's widest on an iPad, centred over the column: three segments across a 1,000-point column (a 13-inch
    /// split, a hidden sidebar) read as a phone's control stretched; iPadOS keeps its segmented controls this narrow.
    /// The phone's spans its column.
    static func maxWidth(idiom: UIUserInterfaceIdiom) -> CGFloat { idiom == .pad ? 400 : .infinity }

    var body: some View {
        TabSegmentRow(selection: $selection, segments: segments, badge: badge, compact: compact)
            .padding(2)
            .glassEffect(.regular, in: Capsule())
            .frame(maxWidth: Self.maxWidth(idiom: UIDevice.current.userInterfaceIdiom))
            // The bar keeps its height: the titles grow to xxxLarge; larger sizes show the large content viewer.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("View")
            .accessibilityIdentifier(Self.identifier)
    }

    static let identifier = "tab-segments"
}

/// The capsule's segments, in their own view so their height scales under the capsule's Dynamic Type cap.
private struct TabSegmentRow: View {
    @Binding var selection: TabSegment
    let segments: [TabSegment]
    let badge: Int
    let compact: Bool
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 30

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let on = segment == selection
                Button {
                    selection = segment
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: segment.symbol)
                            .font(.subheadline.weight(.medium))
                        if !compact {
                            Text(segment.title)
                                .font(.subheadline.weight(on ? .semibold : .medium))
                        }
                        if segment == .files, badge > 0 {
                            Text("\(badge)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.stateUnread, in: Capsule())
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(30, height))
                    .background { if on { Capsule().fill(Color.lens) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(.hoverEffect, Capsule())
                .hoverEffect(.highlight)
                .accessibilityShowsLargeContentViewer { Label(segment.title, systemImage: segment.symbol) }
                .accessibilityLabel(segment.title)
                .accessibilityValue(segment == .files && badge > 0 ? "\(badge) \(badge == 1 ? "comment" : "comments")" : "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
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
