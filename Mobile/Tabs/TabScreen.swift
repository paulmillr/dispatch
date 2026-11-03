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

    /// Glyphs as the Mac's, but Chat's is the app's own capsule (`dispatch.chat`, drawn with `Image(symbol:)`).
    var symbol: String {
        switch self {
        case .terminal: "apple.terminal"
        case .chat: "dispatch.chat"
        case .files: "folder"
        }
    }

    /// Chat when the tab runs an agent, else Terminal (M4a, M6a).
    /// An agent tab opens on Chat unless Settings › Chat says Terminal (`agentStart`); the user's pick then sticks.
    @MainActor static func initial(for tab: MobileTab) -> TabSegment { tab.isChat && agentStart == .chat ? .chat : .terminal }
    /// Settings › Chat › Open agents in (`MobileSettings.chatAgentStart`).
    @MainActor static var agentStart = ChatAgentStart.chat

    /// The segments the tab's capsule offers: Terminal · Files for a plain SSH shell tab, all three otherwise (a tab
    /// without an agent keeps Chat, which says how to start one).
    @MainActor static func available(for tab: MobileTab) -> [TabSegment] { tab.isShell ? [.terminal, .files] : allCases }
}

extension TabScreen where Terminal == AnyView, Chat == AnyView {
    /// With the injected segment views (`TabsContent`).
    init(model: MobileTabs, ref: TabRef, path: Binding<[TabsRoute]>, content: TabsContent) {
        self.init(model: model, ref: ref, path: path, terminal: content.terminal, chat: content.chat,
                  terminalSubtitle: content.terminalSubtitle, terminalDirectory: content.terminalDirectory,
                  chatTrailing: content.chatTrailing, chatMenu: content.chatMenu, files: content.files,
                  gitFacts: content.gitFacts)
    }
}

/// One tab, shared by Terminal, Chat and Files (M4a, M5a, M6a top area, B7): the header (`TabScreenHeader`) over the
/// injected views; on a phone's stack its mode button (`TabModeButton`) switches them, in Files with the modes' capsule
/// under it (`FilesModeCapsule`). The views get the pane to show: Terminal the active pane, Chat the pane running the
/// agent; Files shows the modes (`TabFilesSegment`) in the active pane's folder.
/// A phone on its side (`MobileLandscape`, mockups L12–L15) gives the content the whole window: no header and no
/// capsule, the chrome in a rail on the Dynamic Island's side (`TabRail`: Back and the menu disc, the five modes, the
/// mode's action at its foot), the tab's name in a chip for a moment as it opens; Review and Commits beside their panes
/// with the mode's row heading the list.
struct TabScreen<Terminal: View, Chat: View>: View {
    let model: MobileTabs
    let ref: TabRef
    @Binding var path: [TabsRoute]
    let terminal: @MainActor (MobileTab, MobilePane) -> Terminal
    let chat: @MainActor (MobileTab, MobilePane) -> Chat
    /// The Terminal segment's subtitle after the host (`TabsContent.terminalSubtitle`).
    var terminalSubtitle: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }
    /// The Terminal segment's folder as the shell reports it (`TabsContent.terminalDirectory`); nil: the topology's.
    var terminalDirectory: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }
    /// The Chat segment's trailing header controls around the host disc (`TabsContent.chatTrailing`); nil: the disc.
    /// `keepsDisc`: the given view is the Duo header's switch, which stays.
    var chatTrailing: (@MainActor (MobileTab, MobilePane, AnyView, _ keepsDisc: Bool) -> AnyView)? = nil
    /// The Chat segment's items in the tab's menu (`TabsContent.chatMenu`).
    var chatMenu: (@MainActor (MobileTab, MobilePane) -> AnyView)? = nil
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
    /// A phone on its side: the rail and the whole window (`sideways`).
    @Environment(\.mobileLandscape) private var landscape
    /// The rail's side: the Dynamic Island's, and how deep the island reaches in.
    @Environment(\.mobileRailEdge) private var railEdge
    @Environment(\.mobileIsland) private var island
    /// What the segments give the rail (the terminal's controller, Chat's Reply).
    @State private var rail = TabRailState()
    /// The tab's name in its chip, for a moment as the tab opens on its side.
    @State private var titleShown = false
    /// Files' Change integration… opens Edit host over Spaces (`SpacesNavigator.editHost`).
    @Environment(\.tabsNavigator) private var navigator
    /// Where the software keyboard is, while on its side (the rail keeps Back and the disc above a docked one).
    @State private var keyboard = TerminalAdaptation.Keyboard.hidden
    /// The switch sits in the header beside the Duo's sidebar, where the column is a phone's; an iPad's detail column
    /// keeps it under the header, at its own width (`TabSegmentCapsule.maxWidth`), and the host pill in the header.
    private var segmentInHeader: Bool { splitDetail && UIDevice.current.userInterfaceIdiom == .phone }
    /// Upright on a phone's stack (B7): Back and the host's menu share a capsule, the mode button (`TabModeButton`) is the
    /// header's trailing control, and no switch sits under the header (Files' modes do, `FilesModeCapsule`).
    private var modeButton: Bool { !splitDetail && !strip && !sideways }
    /// A phone on its side (`MobileLandscape`): the rail beside the content, the strip's bodies.
    private var sideways: Bool { landscape && !strip && !splitDetail }
    /// The strip's layout, on an iPad or on a phone's side: the five modes are the model's (`MobileTabs.modes`).
    private var wide: Bool { strip || sideways }

    var body: some View {
        let tab = model.tab(ref)
        let workspace = model.workspace(ref.host)
        Group {
            if let tab, sideways {
                sidewaysBody(tab, workspace: workspace)
            } else {
                standardBody(tab, workspace: workspace)
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

    /// Upright, on an iPad, beside the Duo's sidebar: the header and the capsule (or the strip's context row) over the
    /// segment.
    @ViewBuilder private func standardBody(_ tab: MobileTab?, workspace: MobileWorkspace?) -> some View {
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
                                        repository: repository(tab) == true, modesOnTop: modeButton,
                                        notNow: { notNow(tab) }, changeIntegration: { changeIntegration(ref.host) })
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
        // On a phone's stack the mode button is in the header (`modeButton`), Files' modes under it; beside the Duo's
        // sidebar the switch is in the header itself, where the host pill was (`segmentInHeader`).
        .safeAreaBar(edge: .top, spacing: 0) {
            if let tab, strip {
                stripContext(tab, workspace: workspace)
            } else if let tab {
                let bar = current(tab) == .files ? workspace.flatMap { filesBar(tab, host: $0.host) } : nil
                VStack(spacing: 10) {
                    if !segmentInHeader && !modeButton {
                        TabSegmentCapsule(selection: Binding(get: { current(tab) }, set: { choose($0) }),
                                          segments: TabSegment.available(for: tab), badge: filesBadge)
                    }
                    // With the mode button Files' modes leave the system tab bar for the capsule's place.
                    if modeButton, current(tab) == .files, let modes = filesModesOnTop(tab) {
                        FilesModeCapsule(selection: Binding(get: { modes.shown }, set: { pick($0) }), modes: modes.available,
                                         badge: filesBadge)
                    }
                    if let bar {
                        HStack(spacing: 10) { bar }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                // Beside the Duo's sidebar, or with the mode button, the switch is in the header: the Files bar row keeps
                // its own margins.
                .padding(.top, (segmentInHeader || modeButton) && bar == nil && !filesCapsule(tab) ? 0 : 4)
                .padding(.bottom, (segmentInHeader || modeButton) && bar == nil && !filesCapsule(tab) ? 0 : 10)
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
                                terminalDirectory: tab.activePane.flatMap { terminalDirectory(tab, $0) },
                                column: column, showsBack: !splitDetail,
                                segmentSelection: segmentInHeader ? Binding(get: { current(tab) }, set: { choose($0) }) : nil,
                                segments: TabSegment.available(for: tab), filesBadge: filesBadge,
                                sidebar: splitDetail ? sidebar : nil,
                                chatTrailing: chatControls(tab, host: workspace.host),
                                modeButton: modeButton ? AnyView(modeButtonView(tab)) : nil,
                                menuChat: modeButton && current(tab) == .chat ? tab.agentPane.flatMap { chatMenu?(tab, $0) } : nil,
                                back: back)
            } else if !strip, !splitDetail {
                ToolbarItem(placement: .topBarLeading) {
                    TabsBackDisc(back: backTitle, needsYou: model.needsYou(), action: back)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// The Chat segment's header controls around the host disc (`chatTrailing`), nil elsewhere: the tab's menu holding
    /// the conversation's items, which conversation mode's waveform replaces while on. Beside the Duo's sidebar the
    /// switch is the header's trailing control: the conversation's ⋯ menu goes before it. On a phone's stack the
    /// conversation's items are in the host's menu beside Back, and the waveform takes the mode button's place.
    private func chatControls(_ tab: MobileTab, host: TabsHost) -> AnyView? {
        guard current(tab) == .chat, let pane = tab.agentPane, let chatTrailing else { return nil }
        if modeButton { return chatTrailing(tab, pane, AnyView(modeButtonView(tab)), false) }
        if segmentInHeader {
            let segments = TabSegment.available(for: tab)
            let capsule = TabSegmentCapsule(selection: Binding(get: { current(tab) }, set: { choose($0) }), segments: segments,
                                            badge: filesBadge, compact: true)
                .frame(width: TabSegmentCapsule.headerWidth(segments.count))
            return chatTrailing(tab, pane, AnyView(capsule), true)
        }
        let menu = TabHeaderMenu(tab: tab, host: host, segment: .chat, chat: chatMenu?(tab, pane))
        return chatTrailing(tab, pane, AnyView(menu), false)
    }

    /// The mode button: Terminal to Chat (or Files), back to Terminal; held, every mode (`TabModeButton`).
    private func modeButtonView(_ tab: MobileTab) -> some View {
        let shown = current(tab)
        let repository = repository(tab) == true
        return TabModeButton(shown: shown, agent: tab.isChat, segments: TabSegment.available(for: tab),
                             filesModes: FilesMode.available(repository: repository),
                             filesMode: shown == .files && FilesMode.available(repository: repository).contains(currentMode) ? currentMode : nil,
                             reviewCount: filesBadge) { segment, mode in
            if let mode { pick(mode) }
            choose(segment)
        }
    }

    /// Files' modes for the capsule at the top (`FilesModeCapsule`), with the mode button: while the host can show them and
    /// the tab is inside a repository (outside one Files is alone, and there is no capsule, as there was no tab bar).
    private func filesModesOnTop(_ tab: MobileTab) -> (available: [FilesMode], shown: FilesMode)? {
        guard let host = model.workspace(ref.host)?.host, MobileFilesAvailability(host).showsModes else { return nil }
        let available = FilesMode.available(repository: repository(tab) == true)
        guard available.count > 1 else { return nil }
        return (available, available.contains(currentMode) ? currentMode : .files)
    }

    private func filesCapsule(_ tab: MobileTab) -> Bool { modeButton && current(tab) == .files && filesModesOnTop(tab) != nil }

    /// The five modes' switch in a phone's landscape rail: the iPad strip's, stood on end, its slots held while the
    /// repository is not known.
    private func modeSwitch(_ tab: MobileTab) -> some View {
        let modes = model.modes(tab, facts: gitFacts)
        return PadModeSwitch(modes: modes.slots, axis: .vertical, enabled: Set(modes.available), selected: modes.shown,
                             review: modes.available.contains(.review) ? filesBadge : 0) { setMode($0) }
    }

    /// Shows a mode of the strip's layout. On a phone's side through `choose` and `pick`, so the segment and Files
    /// mode the upright screen keeps follow it when the phone turns back.
    private func setMode(_ mode: PadMode) {
        guard !strip else { model.setMode(mode, for: ref); return }
        choose(mode.segment)
        if let files = mode.filesMode { pick(files) }
    }

    private func current(_ tab: MobileTab) -> TabSegment {
        if wide { return model.modes(tab, facts: gitFacts).shown.segment }
        let chosen = segment ?? model.segments[ref] ?? TabSegment.initial(for: tab)
        return TabSegment.available(for: tab).contains(chosen) ? chosen : .terminal
    }

    private func choose(_ next: TabSegment) {
        if next == .files, let tab = model.tab(ref), current(tab) != .files { model.segmentsBeforeFiles[ref] = current(tab) }
        segment = next
        model.segments[ref] = next
    }

    /// S1, S2's Not now: the segment shown before Files.
    /// S2's Change integration…: Edit host, where Files & git is switched on.
    private func changeIntegration(_ host: UUID) {
        navigator?.editHost = host
    }

    private func notNow(_ tab: MobileTab) {
        let previous = model.segmentsBeforeFiles[ref] ?? TabSegment.initial(for: tab)
        choose(previous == .files ? .terminal : previous)
    }

    private var currentMode: FilesMode { (wide ? nil : filesMode) ?? model.filesModes[ref] ?? .files }

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
                                    // The iPad's Review and Commits open a change or a commit in their pane, as
                                    // a phone's on its side.
                                    if wide, route.opensInPane {
                                        model.paneRoutes[ref, default: [:]][route.mode] = route
                                    } else {
                                        path.append(.files(ref, route))
                                    }
                                }, select: { pick($0) })
    }

    // MARK: A phone on its side

    /// The rail on the island's side and the content from the window's top to its bottom, into the other side's inset
    /// (L12–L15). No navigation bar: Back, the menu and the modes are the rail's; the tab's name shows in a chip for a
    /// moment.
    @ViewBuilder private func sidewaysBody(_ tab: MobileTab, workspace: MobileWorkspace?) -> some View {
        let leading = railEdge == .leading
        HStack(spacing: 6) {
            if leading { tabRail(tab, workspace: workspace) }
            sidewaysContent(tab, workspace: workspace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .vertical)
                .overlay(alignment: .top) {
                    if titleShown, let workspace {
                        TabTitleChip(title: model.label(of: tab, host: workspace.host), host: workspace.host,
                                     folder: TabScreenHeader.folder(tab.activePane?.cwd ?? workspace.space(of: tab)?.cwd,
                                                                    host: workspace.host))
                            .padding(.top, 8)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
            if !leading { tabRail(tab, workspace: workspace) }
        }
        .padding(leading ? .leading : .trailing, MobileLandscape.railInset(island: island))
        .padding(leading ? .trailing : .leading, MobileLandscape.contentInset)
        .ignoresSafeArea(.container, edges: .horizontal)
        .environment(\.tabRail, rail)
        .tabsPushedScreen()
        .toolbarVisibility(.hidden, for: .navigationBar)
        .background { MobileKeyboardReader { keyboard = $0 } }
        .task(id: ref) {
            titleShown = true
            try? await Task.sleep(for: MobileLandscape.titleDuration)
            withAnimation(.easeOut(duration: 0.3)) { titleShown = false }
        }
    }

    /// The shown mode's body at the window's full height: Terminal and Chat across it, Files' listing under its row,
    /// Review and Commits beside their panes with the row heading the list; offline or a review just sent, its line
    /// above.
    @ViewBuilder private func sidewaysContent(_ tab: MobileTab, workspace: MobileWorkspace?) -> some View {
        let shown = model.modes(tab, facts: gitFacts).shown
        switch shown {
        case .terminal:
            if let pane = tab.activePane { terminal(tab, pane) } else { TabGone() }
        case .chat:
            if let pane = tab.agentPane {
                chat(tab, pane).environment(\.chatShowTerminal, ChatTerminalSwitch { setMode(.terminal) })
            } else {
                TabNoAgent()
            }
        case .files, .review, .commits:
            if let workspace {
                let context = filesContext(tab, host: workspace.host).with(mode: shown.filesMode ?? .files)
                VStack(spacing: 6) {
                    if context.availability.showsModes, let banner = sidewaysBanner(context) {
                        PadBanner { banner }.padding(.top, 8)
                    }
                    stripFiles(context, mode: shown.filesMode ?? .files, header: sidewaysRow(context))
                }
            } else {
                TabGone()
            }
        }
    }

    /// The mode's row (a breadcrumb or the branch, and its buttons) heading its list. Not the iPad's row: Create review
    /// is the rail's foot here.
    private func sidewaysRow(_ context: FilesModeContext) -> AnyView? {
        guard context.availability.showsModes, let bar = files.bar(context) else { return nil }
        return AnyView(HStack(spacing: 10) { bar }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .environment(\.tabsPadStrip, false))
    }

    /// Offline with Reconnect, or a review just sent with Undo: the line the phone's accessory is.
    private func sidewaysBanner(_ context: FilesModeContext) -> AnyView? {
        if case .offline(let host, let since) = context.availability {
            return AnyView(FilesOfflineAccessory(host: host, since: since) { files.reconnect(context.host.id) })
        }
        return files.banner(context)
    }

    /// The rail (L12): Back with the needs-you count and the menu disc (the conversation's items on Chat), the modes
    /// stacked, the mode's action at the foot. Above a docked keyboard only Back and the disc.
    private func tabRail(_ tab: MobileTab, workspace: MobileWorkspace?) -> some View {
        let compact = MobileLandscape.compactRail(keyboard: keyboard)
        return VStack(spacing: 0) {
            TabsBackDisc(back: backTitle, needsYou: model.needsYou(excluding: ref), action: back)
            if let workspace {
                Group {
                    if let controls = chatControls(tab, host: workspace.host) {
                        controls
                    } else {
                        TabHeaderMenu(tab: tab, host: workspace.host, segment: current(tab))
                    }
                }
                .padding(.top, 8)
            }
            Spacer(minLength: MobileLandscape.railGap)
            if !compact {
                modeSwitch(tab)
                Spacer(minLength: MobileLandscape.railGap)
                railAction(tab, workspace: workspace)
            }
        }
        .frame(width: MobileLandscape.railWidth)
        .padding(.vertical, MobileLandscape.railMargin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-rail")
    }

    /// The mode's action at the rail's foot: the keyboard in Terminal (held, the keys a program at rest needs), Reply in
    /// Chat while its composer is folded, Create review in Review; none in the others.
    @ViewBuilder private func railAction(_ tab: MobileTab, workspace: MobileWorkspace?) -> some View {
        switch model.modes(tab, facts: gitFacts).shown {
        case .terminal:
            if let terminal = rail.terminal { TabRailKeyboardButton(controller: terminal) }
        case .chat:
            if rail.replyShown { TabRailButton(title: "Reply", symbol: "arrowshape.turn.up.left.fill") { rail.reply() } }
        case .review:
            if let workspace, let action = files.railAction(filesContext(tab, host: workspace.host).with(mode: .review)) {
                TabRailButton(title: action.title, symbol: action.symbol, count: action.count, action: action.action)
            }
        case .files, .commits:
            EmptyView()
        }
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
                    .environment(\.chatShowTerminal, ChatTerminalSwitch { setMode(.terminal) })
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

    /// `header`: a phone on its side heads the mode's list with its row (the iPad has it under the strip).
    @ViewBuilder private func stripFiles(_ context: FilesModeContext, mode: FilesMode, header: AnyView? = nil) -> some View {
        if !context.availability.showsModes {
            FilesUnavailableView(availability: context.availability, notNow: { setMode(.terminal) },
                                 installHelper: { files.installHelper(context.host.id) },
                                 changeIntegration: { changeIntegration(ref.host) })
        } else {
            let shown = context.with(mode: mode)
            Group {
                switch mode {
                case .files:
                    VStack(spacing: 0) {
                        header
                        files.body(shown)
                    }
                case .review, .commits:
                    let chosen = model.paneRoutes[ref]?[mode]
                    let stale = chosen.map { !files.paneShows(ref, $0) } ?? false
                    let selection = stale ? nil : chosen
                    PadListPane(listWidth: sideways ? MobileLandscape.listWidth : nil) {
                        VStack(spacing: 0) {
                            header
                            files.body(shown).environment(\.filesPaneSelection, selection)
                        }
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
        case .detached(let id)?: model.workspace(id)?.host.name ?? "Back"
        case .tab(let tab)?, .files(let tab, _)?: model.tab(tab).flatMap { tab in model.workspace(tab.ref.host).map { model.label(of: tab, host: $0.host) } } ?? "Back"
        case nil: "Spaces"
        }
    }
}

/// The top of a tab. On the phone (B7): Back and the host's glyph in one capsule, the glyph the tab's menu
/// (`TabHeaderBackAndMenu`, `TabHeaderMenu`), the title block (`TabsTitleBlock`: host · folder under a title that fits
/// one line, else the title on two), and the mode button (`TabModeButton`). Beside the Duo's sidebar (M4a): no Back,
/// the title over its subtitle or pane switcher, and the glyph switch in the mode button's place.
struct TabScreenHeader: ToolbarContent {
    let tab: MobileTab
    /// The tab's shown name (`MobileTabs.label(of:)`).
    var title: String? = nil
    let host: TabsHost
    let space: MobileSpace?
    let needsYou: Int
    /// What Back returns to: its VoiceOver label.
    var backTitle = "Back"
    let segment: TabSegment
    /// Terminal's "~/src/app · zsh" from the terminal itself, when it knows (beside the Duo's sidebar).
    var terminalSubtitle: String? = nil
    /// Terminal's folder from the terminal itself, when it knows (the phone's subtitle).
    var terminalDirectory: String? = nil
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
    /// The Chat segment's controls in the disc's place (the tab's menu with the conversation's items, conversation
    /// mode's waveform; beside the Duo's sidebar the ⋯ menu before the switch).
    var chatTrailing: AnyView? = nil
    /// The mode button (`TabModeButton`), the trailing control on a phone's stack: Back and the host's menu then share
    /// the leading capsule (`TabHeaderBackAndMenu`), the menu holding `menuChat`, the conversation's items.
    var modeButton: AnyView? = nil
    var menuChat: AnyView? = nil
    let back: () -> Void

    /// The phone's header (B7): Back and the tab's menu, the title block, the mode button.
    private var stack: Bool { segmentSelection == nil && sidebar == nil }

    /// The trailing slot's width: the split's switch (with the chat's ⋯ before it), the mode button's bar item (52: the
    /// bar's glass around conversation mode's 44 point waveform, the wider of the two), else the 44 point disc.
    private var trailingWidth: CGFloat {
        if modeButton != nil { return 52 }
        guard segmentSelection != nil else { return 44 }
        let switchWidth = TabSegmentCapsule.headerWidth(segments.count)
        return chatTrailing != nil ? ChatHeaderControls<EmptyView>.width(disc: switchWidth) : switchWidth
    }

    var body: some ToolbarContent {
        TabsScreenHeader(title: title ?? tab.name, column: column, showsBack: showsBack || sidebar != nil,
                         trailingWidth: trailingWidth,
                         atTrailingEdge: column == nil || segmentSelection != nil, titleBlock: stack,
                         trailingGlass: modeButton != nil) {
            if let sidebar {
                TabsSidebarPill(toggle: sidebar, needsYou: needsYou)
            } else if modeButton != nil {
                TabHeaderBackAndMenu(back: backTitle, needsYou: needsYou, action: back) {
                    TabHeaderMenu(tab: tab, host: host, segment: segment, chat: menuChat, inCapsule: true)
                }
            } else {
                TabsBackDisc(back: backTitle, needsYou: needsYou, action: back)
            }
        } subtitle: {
            if stack {
                folderSubtitle
            } else if tab.panes.count > 1 {
                Menu {
                    Section("Panes") { Self.panePicker(tab, host: host) }
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
            } else if let modeButton {
                modeButton
            } else if let segmentSelection {
                TabSegmentCapsule(selection: segmentSelection, segments: segments, badge: filesBadge, compact: true)
                    .frame(width: TabSegmentCapsule.headerWidth(segments.count))
            } else {
                TabHeaderMenu(tab: tab, host: host, segment: segment)
            }
        }
    }

    /// The tab's panes, the shown one checked: a pick shows that pane. On `segment` (the tab's menu) only the panes it
    /// can show: Chat shows the pane running an agent (`MobileTab.agentPane`), so a pane without one is not offered.
    /// Without a segment (beside the Duo's sidebar) every pane, the active one checked.
    static func panePicker(_ tab: MobileTab, host: TabsHost, segment: TabSegment? = nil) -> some View {
        let choices = segment.map { panes(tab, segment: $0) } ?? tab.panes
        let shown = segment == .chat ? tab.agentPane : tab.activePane
        return Picker("Pane", selection: Binding(get: { shown?.key ?? "" }, set: { key in
            if let pane = tab.panes.first(where: { $0.key == key }) { tab.pick(pane) }
        })) {
            ForEach(choices, id: \.key) { pane in
                Text(paneTitle(pane, index: tab.panes.firstIndex { $0.key == pane.key } ?? 0, host: host)).tag(pane.key)
            }
        }
        .pickerStyle(.inline)
    }

    /// The panes a pick can show on `segment`: on Chat those running an agent, else all.
    static func panes(_ tab: MobileTab, segment: TabSegment) -> [MobilePane] {
        segment == .chat ? tab.panes.filter { $0.agent != nil } : tab.panes
    }

    /// Beside the Duo's sidebar. Chat and Files: host · cwd (mono). Terminal: host · cwd · shell (M6a).
    private var subtitle: some View {
        if segment == .terminal, let terminalSubtitle {
            return TabsHostPath(host: host, path: terminalSubtitle, trailing: nil, mono: false)
        }
        let pane = segment == .chat ? (tab.agentPane ?? tab.activePane) : tab.activePane
        let cwd = host.abbreviate(pane?.cwd ?? space?.cwd)
        return TabsHostPath(host: host, path: cwd, trailing: segment == .terminal ? tab.program : nil, mono: segment != .terminal)
    }

    /// The phone's (X9b): host · folder, and the shell's name in Terminal ("mba2 · app · zsh").
    private var folderSubtitle: some View {
        let pane = segment == .chat ? (tab.agentPane ?? tab.activePane) : tab.activePane
        let directory = (segment == .terminal ? terminalDirectory : nil) ?? pane?.cwd ?? space?.cwd
        let shell = segment == .terminal ? tab.program.map(TerminalSubtitle.name(ofShell:)).flatMap { $0.isEmpty ? nil : $0 } : nil
        return TabsHostPath(host: host, path: Self.folder(directory, host: host), trailing: shell, mono: false)
    }

    /// A folder's name: its path's last component, "~" for the home folder, "/" for the root.
    static func folder(_ path: String?, host: TabsHost) -> String? {
        guard let short = host.abbreviate(path), !short.isEmpty else { return nil }
        return short.split(separator: "/").last.map(String.init) ?? short
    }

    static func paneTitle(_ pane: MobilePane, index: Int, host: TabsHost) -> String {
        let place = host.abbreviate(pane.cwd).map { " · " + $0 } ?? ""
        return "Pane \(index + 1)" + place
    }
}

/// A tab's menu: the host's glyph, beside Back in their capsule in a phone's header (B7), or on a 44 point glass disc
/// with a ⋯ badge on its lower trailing edge at a landscape rail, as on an avatar that opens a menu. One menu for the conversation (Chat's items, on the Chat segment), the tab's panes
/// when it has splits (the subtitle that switched them may be gone), the tab (its row's menu: Rename…, Close,
/// Detach, Terminate…) and the host (Stats).
struct TabHeaderMenu: View {
    let tab: MobileTab
    let host: TabsHost
    /// The segment shown: its panes are the ones the picker offers (`TabScreenHeader.panes`).
    let segment: TabSegment
    /// The Chat segment's items (`ChatThreadMenuItems`).
    var chat: AnyView? = nil
    /// Beside Back in their capsule (`TabHeaderBackAndMenu`): the capsule is the glass, and no ⋯ badge.
    var inCapsule = false
    @Environment(\.tabsNavigator) private var navigator

    static let identifier = "tab-menu"

    private var picksPane: Bool { TabScreenHeader.panes(tab, segment: segment).count > 1 }

    var body: some View {
        if chat == nil && !picksPane && navigator == nil {
            // Nothing to offer (a preview without the stack): the host's disc alone, no empty menu.
            disc.glassEffect(inCapsule ? .identity : .regular, in: Circle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(host.name)
        } else {
            menu
        }
    }

    private var disc: some View {
        HostGlyph(host: host.glyphRecord, size: 22)
            .foregroundStyle(host.tint)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    private var menu: some View {
        Menu {
            if let chat { chat }
            if picksPane {
                Section("Panes") { TabScreenHeader.panePicker(tab, host: host, segment: segment) }
            }
            if let navigator {
                Section("Tab") { TabsTabMenu(actions: navigator.actions, tab: tab.ref) }
                Section(host.name) {
                    Button("Stats", systemImage: "gauge.with.dots.needle.33percent") { navigator.statsHost = host.id }
                }
            }
        } label: {
            disc
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(Color.primary)
        .glassEffect(inCapsule ? .identity : .regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .overlay(alignment: .bottomTrailing) { if !inCapsule { TabHeaderMenuBadge().offset(x: 2, y: 2) } }
        .accessibilityLabel("Tab menu")
        .accessibilityValue(host.name)
        .accessibilityIdentifier(Self.identifier)
    }
}

/// Back and the host's menu in one glass capsule (B7, a phone tab's header): the chevron, then the host's glyph
/// that opens the tab's menu (`TabHeaderMenu` in its capsule). The needs-you count on Back's corner, as `TabsBackDisc`'s.
struct TabHeaderBackAndMenu<Content: View>: View {
    /// The screen Back returns to.
    let back: String
    var needsYou = 0
    let action: () -> Void
    @ViewBuilder var menu: Content

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.dispatchPink)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(.hoverEffect, Circle())
            .hoverEffect(.highlight)
            .overlay(alignment: .topTrailing) {
                if needsYou > 0 {
                    TabsCountBadge(label: "\(needsYou)")
                        .offset(x: 6, y: -4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Back to \(back)")
            .accessibilityValue(TabsBackDisc.value(needsYou))
            // The badge over the menu's half of the capsule.
            .zIndex(1)
            menu
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// A phone tab's mode button (B7), the Mac strip's (`ChatModeSwitch`) on the phone: one system bar item for Terminal, Chat
/// and Files, a menu with a primary action, so the bar draws its glass and a hold opens the menu. Away from Terminal it
/// is on, as a bar button that filters is (Mail's): the symbol filled, in the accent; in Terminal off, its outline in
/// the label colour naming where a tap goes: Chat on a tab that runs an agent, else Files. A tap from Chat or Files
/// returns to Terminal. Held, every mode: Terminal, Chat, then Files, Review and Commits (those two inside a
/// repository), the shown one checked. (A button-style Toggle draws on as a pink prominent disc and takes no menu.)
struct TabModeButton: View {
    let shown: TabSegment
    /// An agent runs in the tab (`MobileTab.isChat`).
    let agent: Bool
    /// The tab's segments (`TabSegment.available(for:)`).
    let segments: [TabSegment]
    /// Files' modes the tab offers (`FilesMode.available(repository:)`).
    let filesModes: [FilesMode]
    /// Files' mode shown, on Files.
    var filesMode: FilesMode? = nil
    /// Review's comments, beside Review in the menu.
    var reviewCount = 0
    /// Shows a segment, and Files' mode with it.
    let choose: (TabSegment, FilesMode?) -> Void

    static let identifier = "tab-mode-button"

    /// Where a tap goes (`ModeSwitchState.next` on the Mac); nil: nowhere (the button dims).
    static func next(shown: TabSegment, agent: Bool, segments: [TabSegment]) -> TabSegment? {
        switch shown {
        case .terminal: agent && segments.contains(.chat) ? .chat : segments.contains(.files) ? .files : nil
        case .chat, .files: .terminal
        }
    }

    /// Chat shown, or Terminal with an agent to go to: the bubble; else the folder.
    static func symbol(shown: TabSegment, agent: Bool) -> String {
        switch shown {
        case .chat: TabSegment.chat.symbol
        case .files: TabSegment.files.symbol
        case .terminal: agent ? TabSegment.chat.symbol : TabSegment.files.symbol
        }
    }

    private var next: TabSegment? { Self.next(shown: shown, agent: agent, segments: segments) }
    private var on: Bool { shown != .terminal }

    var body: some View {
        Menu {
            item("Terminal", TabSegment.terminal.symbol, checked: shown == .terminal) { choose(.terminal, nil) }
            if segments.contains(.chat) {
                item("Chat", TabSegment.chat.symbol, checked: shown == .chat) { choose(.chat, nil) }
                    .disabled(!agent && shown != .chat)
            }
            if segments.contains(.files) {
                Section {
                    ForEach(filesModes) { mode in
                        item(mode.title, mode.symbol, detail: mode == .review && reviewCount > 0 ? Self.comments(reviewCount) : nil,
                             checked: shown == .files && (filesMode ?? .files) == mode) { choose(.files, mode) }
                    }
                }
            }
        } label: {
            Label(next.map { "Show \($0.title)" } ?? shown.title,
                  symbol: Self.symbol(shown: shown, agent: agent) + (on ? ".fill" : ""))
        } primaryAction: {
            if let next { choose(next, nil) }
        }
        // The bar draws its items in their tint: the accent when on, the label colour when off.
        .tint(on ? Color.dispatchPink : Color.primary)
        .disabled(next == nil && !segments.contains(.chat) && !segments.contains(.files))
        .accessibilityLabel(next.map { "Show \($0.title)" } ?? shown.title)
        .accessibilityValue("\(shown.title) selected")
        .accessibilityHint("Hold for every mode")
        .accessibilityIdentifier(Self.identifier)
    }

    static func comments(_ count: Int) -> String { "\(count) \(count == 1 ? "comment" : "comments")" }

    /// A menu row checked when shown, as the system's toggles in a menu.
    private func item(_ title: String, _ symbol: String, detail: String? = nil, checked: Bool,
                      action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { checked }, set: { _ in action() })) {
            Text(title)
            if let detail { Text(detail) }
            Image(symbol: symbol)
        }
    }
}

/// The disc's ⋯ badge: a small grey circle ringed in the canvas, so it reads as a separate mark on the glass.
private struct TabHeaderMenuBadge: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.primary)
            .frame(width: 17, height: 17)
            .background(Color(uiColor: .systemGray4), in: Circle())
            .overlay { Circle().stroke(Color.canvas, lineWidth: 2) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        TabSegmentRow(selection: $selection, segments: segments, badged: .files, badge: badge, compact: compact)
            .modifier(TabCapsuleGlass(label: "View", identifier: Self.identifier))
    }

    static let identifier = "tab-segments"
}

/// Files' modes at the top of the Files segment on a phone's stack (`TabFilesSegment.modesOnTop`): the
/// capsule the Terminal · Chat · Files switch was, Files · Review · Commits in it, Review with its comment count.
struct FilesModeCapsule: View {
    @Binding var selection: FilesMode
    let modes: [FilesMode]
    var badge = 0

    var body: some View {
        TabSegmentRow(selection: $selection, segments: modes, badged: .review, badge: badge, compact: false)
            .modifier(TabCapsuleGlass(label: "Files", identifier: Self.identifier))
    }

    static let identifier = "files-modes"
}

/// What a capsule's segment shows: its title and glyph.
protocol TabCapsuleItem: Identifiable, Hashable {
    var title: String { get }
    var symbol: String { get }
}

extension TabSegment: TabCapsuleItem {}
extension FilesMode: TabCapsuleItem {}

/// The capsules' glass and width (`TabSegmentCapsule`, `FilesModeCapsule`).
private struct TabCapsuleGlass: ViewModifier {
    let label: String
    let identifier: String

    func body(content: Content) -> some View {
        content
            .padding(2)
            .glassEffect(.regular, in: Capsule())
            .frame(maxWidth: TabSegmentCapsule.maxWidth(idiom: UIDevice.current.userInterfaceIdiom))
            // The bar keeps its height: the titles grow to xxxLarge; larger sizes show the large content viewer.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityIdentifier(identifier)
    }
}

/// The capsule's segments, in their own view so their height scales under the capsule's Dynamic Type cap. `badged`
/// carries the count: Files in the switch, Review in Files' modes.
private struct TabSegmentRow<Item: TabCapsuleItem>: View {
    @Binding var selection: Item
    let segments: [Item]
    let badged: Item
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
                        Image(symbol: segment.symbol)
                            .font(.subheadline.weight(.medium))
                        if !compact {
                            Text(segment.title)
                                .font(.subheadline.weight(on ? .semibold : .medium))
                        }
                        if segment == badged, badge > 0 {
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
                .accessibilityShowsLargeContentViewer { Label(segment.title, symbol: segment.symbol) }
                .accessibilityLabel(segment.title)
                .accessibilityValue(segment == badged && badge > 0 ? "\(badge) \(badge == 1 ? "comment" : "comments")" : "")
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

/// The mode's action at a phone's landscape rail (L12): a pink disc, its count on the corner.
struct TabRailButton: View {
    let title: String
    let symbol: String
    var count = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TabRailDisc(symbol: symbol, count: count)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count)" : "")
    }
}

/// The rail's pink disc: 50 points, the glyph in the accent's ink, a count in a capsule on its corner.
struct TabRailDisc: View {
    let symbol: String
    var count = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(Color.onAccent)
            .frame(width: 50, height: 50)
            .contentShape(Circle())
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.dispatchPink)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.onAccent, in: Capsule())
                        .offset(x: 3, y: -3)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// Terminal's action at the rail (L14): a tap shows or hides the keyboard, whose key row then rides it; held, the
/// keys a program at rest needs without it (L14c): Esc, Ctrl-C, Ctrl-D, Tab, the previous command, Paste.
struct TabRailKeyboardButton: View {
    let controller: TerminalController

    var body: some View {
        // A button, not a Menu with a primary action: the menu's tracking held the focus while the terminal took it,
        // and the keyboard stayed down. The keys are its context menu (held).
        Button { controller.toggleKeyboard() } label: {
            TabRailDisc(symbol: controller.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.dispatchPink).interactive(), in: Circle())
        .contextMenu {
            Button("Esc", systemImage: "escape") { controller.press(.escape) }
            Button { controller.press(.character("c", mods: .ctrl)) } label: {
                Text("Ctrl-C"); Text("interrupt"); Image(systemName: "xmark.octagon")
            }
            Button { controller.press(.character("d", mods: .ctrl)) } label: {
                Text("Ctrl-D"); Text("end of input"); Image(systemName: "eject")
            }
            Button("Tab", systemImage: "arrow.right.to.line") { controller.press(.tab) }
            Divider()
            Button("Previous Command", systemImage: "arrow.up") { controller.press(.up) }
            Button("Paste", systemImage: "doc.on.clipboard") { controller.paste() }
        }
        .accessibilityLabel(controller.keyboardVisible ? "Hide keyboard" : "Show keyboard")
        .accessibilityHint("Hold for Esc, Control-C and other keys")
        .accessibilityIdentifier("rail-keyboard")
    }
}

/// The tab's name on a phone's side, where the header said it: in a glass chip over the content's top for a moment as
/// the tab opens (`MobileLandscape.titleDuration`).
struct TabTitleChip: View {
    let title: String
    let host: TabsHost
    let folder: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            TabsHostPath(host: host, path: folder, mono: false).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tab-title-chip")
    }
}
