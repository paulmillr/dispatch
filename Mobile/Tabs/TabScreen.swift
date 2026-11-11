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
                  terminalDirectory: content.terminalDirectory,
                  chatTrailing: content.chatTrailing, chatMenu: content.chatMenu, files: content.files,
                  gitFacts: content.gitFacts)
    }
}

/// One tab, shared by Terminal, Chat and Files (M4a, M5a, M6a top area, B7): the header (`TabScreenHeader`) over the
/// injected views; on a phone's stack and beside the Duo's sidebar its mode button (`TabModeButton`) switches them and
/// Files' modes. The views get the pane to show: Terminal the active pane, Chat the pane running the
/// agent; Files shows the modes (`TabFilesSegment`) in the active pane's folder.
/// A phone on its side (`MobileLandscape`, mockups L12–L15) gives the content the whole window: no header and no
/// capsule, the chrome in a rail on the Dynamic Island's side (`TabRail`: Back and the menu disc, the five modes, the
/// mode's action at its foot), the tab's title capsule for a moment as it opens; Review and Commits beside their panes
/// with the mode's row heading the list.
struct TabScreen<Terminal: View, Chat: View>: View {
    let model: MobileTabs
    let ref: TabRef
    @Binding var path: [TabsRoute]
    let terminal: @MainActor (MobileTab, MobilePane) -> Terminal
    let chat: @MainActor (MobileTab, MobilePane) -> Chat
    /// The Terminal segment's folder as the shell reports it (`TabsContent.terminalDirectory`); nil: the topology's.
    var terminalDirectory: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }
    /// The Chat segment's trailing header control around the mode button (`TabsContent.chatTrailing`); nil: the button.
    var chatTrailing: (@MainActor (MobileTab, MobilePane, AnyView) -> AnyView)? = nil
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
    /// Upright on a phone's stack and beside the Duo's sidebar (B7): the title capsule opens the tab's menu, the mode
    /// button (`TabModeButton`) is the header's trailing control and the one switch, Files' modes in its menu: no
    /// switch sits under the header.
    private var modeButton: Bool { !strip && !sideways }
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

    /// Upright, on an iPad, beside the Duo's sidebar: the header (or the strip's context row) over the segment.
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
                                        repository: repository(tab) == true,
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
        // The mode's row (Files' folder, Review's branch) is part of the bar, under the header: the content scrolls
        // beneath both, through the system's scroll edge effect, as it does under the system's bars. The mode button in
        // the header is the one switch (`modeButton`): nothing else sits under it.
        .safeAreaBar(edge: .top, spacing: 0) {
            if let tab, strip {
                stripContext(tab, workspace: workspace)
            } else if let tab, current(tab) == .files, let bar = workspace.flatMap({ filesBar(tab, host: $0.host) }) {
                HStack(spacing: 10) { bar }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
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
                                segment: current(tab),
                                terminalDirectory: tab.activePane.flatMap { terminalDirectory(tab, $0) },
                                column: column, showsBack: !splitDetail,
                                sidebar: splitDetail ? sidebar : nil,
                                chatTrailing: chatControls(tab, host: workspace.host),
                                modeButton: modeButton ? AnyView(modeButtonView(tab)) : nil,
                                menuChat: modeButton && current(tab) == .chat ? tab.agentPane.flatMap { chatMenu?(tab, $0) } : nil,
                                capsuleMenu: navigator != nil,
                                back: back)
            } else if !strip, !splitDetail {
                ToolbarItem(placement: .topBarLeading) {
                    TabsBackDisc(back: backTitle, needsYou: model.needsYou(), action: back)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// The Chat segment's control, nil elsewhere, which conversation mode's waveform replaces while on: in the header
    /// the mode button (the conversation's items are in the title capsule's menu); on a phone's side the rail's menu
    /// disc, holding the conversation's items.
    private func chatControls(_ tab: MobileTab, host: TabsHost) -> AnyView? {
        guard current(tab) == .chat, let pane = tab.agentPane, let chatTrailing else { return nil }
        if modeButton { return chatTrailing(tab, pane, AnyView(modeButtonView(tab))) }
        return chatTrailing(tab, pane, AnyView(TabHeaderMenu(tab: tab, host: host, segment: .chat, chat: chatMenu?(tab, pane))))
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
    /// (L12–L15). No navigation bar: Back, the menu and the modes are the rail's; the tab's title capsule shows for a
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
                        let label = model.label(of: tab, host: workspace.host)
                        TabTitleChip(title: label, host: workspace.host,
                                     folder: TabScreenHeader.distinct(TabScreenHeader.folder(tab.activePane?.cwd ?? workspace.space(of: tab)?.cwd,
                                                                                             host: workspace.host), from: label))
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
                // Its place kept when the mode has none: the modes stay where they are from mode to mode.
                ZStack {
                    Color.clear.frame(width: MobileLandscape.railAction, height: MobileLandscape.railAction)
                    railAction(tab, workspace: workspace)
                }
            }
        }
        // The window's height whatever the mode shows, so the modes' place never depends on the content beside them.
        .frame(width: MobileLandscape.railWidth)
        .frame(maxHeight: .infinity)
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

/// The top of a tab. On the phone (B7): Back in its own circle, then one capsule with the host's disc, the title and
/// host · folder under it (`TabsTitleCapsuleView`), which opens the tab's menu (`TabMenuItems`: the conversation's
/// items, its panes, the tab's actions, the host's Stats), and the mode button (`TabModeButton`). Beside the Duo's sidebar
/// (M4a) the same, without Back.
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
    /// Terminal's folder from the terminal itself, when it knows (the phone's subtitle).
    var terminalDirectory: String? = nil
    /// The column the bar is in (`TabsScreenHeader.column`).
    var column: CGFloat? = nil
    /// False beside the Duo's sidebar, which is where Back would return.
    var showsBack = true
    /// The iPad split's sidebar button, in the back pill's place (`TabsSidebarPill`).
    var sidebar: TabsSidebarToggle? = nil
    /// The Chat segment's control in the mode button's place (the button, or conversation mode's waveform).
    var chatTrailing: AnyView? = nil
    /// The mode button (`TabModeButton`), the trailing control on a phone's stack: Back then has its own circle and the
    /// title its capsule (`TabsTitleCapsuleView`).
    var modeButton: AnyView? = nil
    /// The conversation's items, on Chat, for the capsule's menu.
    var menuChat: AnyView? = nil
    /// The capsule opens the tab's menu; false (a preview without the stack) leaves it none.
    var capsuleMenu = true
    let back: () -> Void

    /// The phone's header (B7), also beside the Duo's sidebar: Back (on the phone), the title capsule, the mode button.
    private var stack: Bool { sidebar == nil }

    /// The trailing slot's width: the mode button's bar item (52: the bar's glass around conversation mode's 44 point
    /// waveform, the wider of the two), else the 44 point disc.
    private var trailingWidth: CGFloat { modeButton != nil ? 52 : 44 }

    var body: some ToolbarContent {
        // The phone's bar and the Duo's tab column both end at the screen's trailing edge, the Duo's status in its row.
        TabsScreenHeader(title: title ?? tab.name, column: column, showsBack: showsBack || sidebar != nil,
                         trailingWidth: trailingWidth,
                         atTrailingEdge: column == nil || !showsBack, titleBlock: stack,
                         trailingGlass: modeButton != nil,
                         titleCapsule: modeButton == nil ? nil
                            : TabsTitleCapsule(glyph: AnyView(TabHostDisc(host: host)),
                                               menu: capsuleMenu ? AnyView(TabMenuItems(tab: tab, host: host, segment: segment, chat: menuChat))
                                                   : nil)) {
            if let sidebar {
                TabsSidebarPill(toggle: sidebar, needsYou: needsYou)
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

    /// Beside the Duo's sidebar: the phone's line (`folderSubtitle`), host · folder's name, and the shell in Terminal.
    private var subtitle: some View { folderSubtitle }

    /// The phone's (X9b): host · folder, and the shell's name in Terminal ("mba2 · app · zsh").
    private var folderSubtitle: some View {
        let pane = segment == .chat ? (tab.agentPane ?? tab.activePane) : tab.activePane
        let directory = (segment == .terminal ? terminalDirectory : nil) ?? pane?.cwd ?? space?.cwd
        let shell = segment == .terminal ? tab.program.map(TerminalSubtitle.name(ofShell:)).flatMap { $0.isEmpty ? nil : $0 } : nil
        return TabsHostPath(host: host, path: Self.distinct(Self.folder(directory, host: host), from: title ?? tab.name),
                            trailing: shell, mono: false, full: host.abbreviate(directory))
    }

    /// `folder`, unless the name beside it already is that folder's (an automatic name, a space named for its folder):
    /// the host line then says the host alone, never "app" under "app".
    static func distinct(_ folder: String?, from name: String?) -> String? {
        guard let folder, let name, folder.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame
        else { return folder }
        return nil
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

/// A tab's menu: the host's glyph on a 44 point glass disc with a ⋯ badge on its lower trailing edge (a landscape rail,
/// an iPad's header), as on an avatar that opens a menu; upright on a phone the title capsule opens the same menu
/// (`TabMenuItems`): the conversation (Chat's items, on the Chat segment), the tab's panes when it has splits, the tab
/// (its row's menu: Rename…, Close, Detach) and the host (Stats).
struct TabHeaderMenu: View {
    let tab: MobileTab
    let host: TabsHost
    /// The segment shown: its panes are the ones the picker offers (`TabScreenHeader.panes`).
    let segment: TabSegment
    /// The Chat segment's items (`ChatThreadMenuItems`).
    var chat: AnyView? = nil
    @Environment(\.tabsNavigator) private var navigator

    static let identifier = "tab-menu"

    private var picksPane: Bool { TabScreenHeader.panes(tab, segment: segment).count > 1 }

    var body: some View {
        if chat == nil && !picksPane && navigator == nil {
            // Nothing to offer (a preview without the stack): the host's disc alone, no empty menu.
            disc.glassEffect(.regular, in: Circle())
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
        // A tap opens it, so no haptic: that is for menus a hold reveals (`menuHoldHaptic`).
        Menu {
            TabMenuItems(tab: tab, host: host, segment: segment, chat: chat)
        } label: {
            disc
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .tint(Color.primary)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .overlay(alignment: .bottomTrailing) { TabHeaderMenuBadge().offset(x: 2, y: 2) }
        .accessibilityLabel("Tab menu")
        .accessibilityValue(host.name)
        .accessibilityIdentifier(Self.identifier)
    }
}

/// The tab's one menu, from the title capsule (B7) or the menu disc (`TabHeaderMenu`): on Chat Search, the host's Stats
/// and the conversation's other items; the panes the segment can show when there are several; the tab's (Rename…,
/// Detach, Close Tab).
struct TabMenuItems: View {
    let tab: MobileTab
    let host: TabsHost
    let segment: TabSegment
    var chat: AnyView? = nil
    @Environment(\.tabsNavigator) private var navigator

    var body: some View {
        // The host's Stats right under Search on Chat, else first.
        if let chat {
            chat.environment(\.chatMenuAfterSearch, stats.map { AnyView($0) })
        } else if let stats {
            stats
        }
        if TabScreenHeader.panes(tab, segment: segment).count > 1 {
            Section("Panes") { TabScreenHeader.panePicker(tab, host: host, segment: segment) }
        }
        if let navigator {
            Section("Tab") { TabsTabMenu(actions: navigator.actions, tab: tab.ref) }
        }
    }

    private var stats: (some View)? {
        navigator.map { navigator in
            Button("Stats", systemImage: "gauge.with.dots.needle.33percent") { navigator.statsHost = host.id }
        }
    }
}

/// The host's glyph on a disc of its colour: the title capsule's leading circle (B7), as a contact's avatar heads a
/// conversation in Messages.
struct TabHostDisc: View {
    let host: TabsHost
    var size: CGFloat = 36

    var body: some View {
        HostGlyph(host: host.glyphRecord, size: (size * 0.5).rounded())
            .foregroundStyle(host.tint)
            .frame(width: size, height: size)
            .background(host.tint.opacity(0.18), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A phone tab's mode button (B7), the Mac strip's (`ChatModeSwitch`) on the phone: one system bar item, a menu, so the
/// bar draws its glass. A tap opens it on every segment, as the Mac's click does: Terminal, Chat, then Files, Review and
/// Commits (those two inside a repository), the shown one checked. Away from Terminal it is on, as a bar button that
/// filters is (Mail's): the symbol filled, in the accent; in Terminal off, its outline in the label colour naming where
/// the tab would go: Chat on a tab that runs an agent, else Files. (A button-style Toggle draws on as a pink prominent
/// disc and takes no menu.)
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

    /// The step a switch would take (`ModeSwitchState.next` on the Mac), which the glyph names in Terminal; nil:
    /// nowhere to go (the button dims). A tap opens the menu whatever the segment.
    static func next(shown: TabSegment, agent: Bool, segments: [TabSegment]) -> TabSegment? {
        switch shown {
        case .terminal: agent && segments.contains(.chat) ? .chat : segments.contains(.files) ? .files : nil
        case .chat, .files: .terminal
        }
    }

    /// Chat shown, or Terminal with an agent to go to: the bubble; Files the shown mode's glyph (the folder, Review's
    /// clipboard, Commits' clock); else the folder.
    static func symbol(shown: TabSegment, agent: Bool, filesMode: FilesMode? = nil) -> String {
        switch shown {
        case .chat: TabSegment.chat.symbol
        case .files: (filesMode ?? .files).symbol
        case .terminal: agent ? TabSegment.chat.symbol : TabSegment.files.symbol
        }
    }

    /// `symbol`'s filled form where it has one: the app's own symbols their `.fill` asset, the system's their `.fill`
    /// name when the system has it (Commits' clock has none and stays outlined).
    static func filled(_ symbol: String) -> String {
        if symbol.hasPrefix("dispatch.") { return symbol + ".fill" }
        return UIImage(systemName: symbol + ".fill") == nil ? symbol : symbol + ".fill"
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
            // A tap opens the menu, on every segment, as the Mac's button's click does.
            let symbol = Self.symbol(shown: shown, agent: agent, filesMode: filesMode)
            Label("Mode", symbol: on ? Self.filled(symbol) : symbol)
        }
        // The bar draws its items in their tint: the accent when on, the label colour when off.
        .tint(on ? Color.dispatchPink : Color.primary)
        .disabled(next == nil && !segments.contains(.chat) && !segments.contains(.files))
        .accessibilityLabel("Mode")
        .accessibilityValue("\(shown == .files ? (filesMode ?? .files).title : shown.title) selected")
        .accessibilityHint("Lists Terminal, Chat and Files")
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

/// The tab's title on a phone's side, where the header said it: the upright header's title capsule (the host's disc, the
/// title over host · folder, `TabsTitleCapsuleView`) over the content's top for a moment as the tab opens
/// (`MobileLandscape.titleDuration`). No menu: the rail's disc has it.
struct TabTitleChip: View {
    let title: String
    let host: TabsHost
    let folder: String?

    var body: some View {
        TabsTitleCapsuleView(title: title, capsule: TabsTitleCapsule(glyph: AnyView(TabHostDisc(host: host)), menu: nil)) {
            TabsHostPath(host: host, path: folder, mono: false)
        }
        // As wide as it needs, a long title cut short of the content's edges.
        .padding(.horizontal, 24)
    }
}
