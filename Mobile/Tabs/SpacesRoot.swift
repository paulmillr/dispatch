import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where the Spaces stack can go.
enum TabsRoute: Hashable {
    case tab(TabRef)
    /// P2: a space's tabs.
    case space(SpaceRef)
    /// P1's Detached row: a host's detached work, to restore or remove from the list.
    case detached(UUID)
    /// M1f: host detail (Hosts' view), from the Info button in edit mode, and Files' Change integration… (S2).
    case host(UUID)
    /// A screen a tab's Files mode pushes (a file, a diff, a commit: `FilesModeContent.destination`).
    case files(TabRef, FilesRoute)

    var tab: TabRef? { if case .tab(let ref) = self { ref } else { nil } }
    var isSpace: Bool { if case .space = self { true } else { false } }
}

/// What a tab's segments show: the Terminal and Chat areas build them for a tab's pane, the Files, Review and Commits
/// areas fill the Files segment's modes (the shell's composition root wires them).
struct TabsContent {
    var terminal: @MainActor (MobileTab, MobilePane) -> AnyView
    var chat: @MainActor (MobileTab, MobilePane) -> AnyView
    /// The Terminal segment's subtitle after the host ("~/src/app · zsh", M6a); nil: the topology's folder and program.
    var terminalSubtitle: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }
    /// The Chat segment's header controls around the host disc (Chat's ⋯ menu and conversation mode's disc), given
    /// the disc (`keepsDisc`: it is the Duo header's switch, which stays); nil: the disc alone.
    var chatTrailing: (@MainActor (MobileTab, MobilePane, AnyView, _ keepsDisc: Bool) -> AnyView)? = nil
    var files = FilesModeContent()
    /// The tabs' repositories and branches (`SpaceGitFacts`); nil reads none.
    var gitFacts: SpaceGitFacts? = nil
}

/// The app's one navigation stack (`MobileRoot` wraps the tab bar in it, so pushed screens cover the whole screen
/// and the tab bar leaves with the root, as UIKit pushes do): the path, and what Spaces presents over it (New tab's
/// space picker, New space, the Tabs dialogs). Spaces and Agents push onto the same path.
@MainActor @Observable
final class SpacesNavigator {
    var path: [TabsRoute] = [] {
        didSet {
            if let ref = Self.split(path).tab, let tab = model.tab(ref) {
                lastTabs[tab.space] = ref
                remember(strip: tab)
            }
            rememberSplit()
        }
    }
    /// The tab each space showed last (the iPad sidebar's space rows open it again, `selectSpace`).
    @ObservationIgnored var lastTabs: [SpaceRef: TabRef] = [:]
    /// The shown tab's place in its strip, as last seen (`reconcile` hands the column to its neighbour when the host
    /// closes it).
    @ObservationIgnored var stripOrder: (tab: TabRef, space: SpaceRef, tabs: [TabRef])?
    /// The window shows Spaces beside the tab (`MobileSplit`, set by `MobileRoot`): a tab opened replaces the shown one.
    var split = false {
        didSet {
            // An iPad's sidebar is the tree (its space rows select, `PadSidebar`): a space's screen the stack pushed
            // before the window split stays behind, the tab it opened beside the tree.
            if split, !oldValue, sidebarHides, splitPath.tab != nil, splitPath.sidebar.contains(where: \.isSpace) {
                path.removeAll(where: \.isSpace)
            }
            rememberSplit()
        }
    }
    /// The split hides its sidebar (`toggleSidebar`): an iPad's does, the Duo's never (`MobileRoot` sets it).
    var sidebarHides = false
    /// The iPad split's sidebar is hidden and the tab takes the window (`MobileRoot`, `toggleSidebar`). Only while a tab
    /// is shown: without one the sidebar is all there is.
    var sidebarHidden = false {
        didSet { rememberSplit() }
    }
    /// The sidebar is sliding in or out (`toggleSidebar`): the tab keeps its wider width meanwhile (`MobileRoot`).
    var sidebarSliding = false
    /// The sidebar as the slide draws it (`toggleSidebar`, `sidebarShownHidden`).
    var sidebarDrawnHidden = false
    /// Which slide `sidebarSliding` waits for: one started over another ends it, not the first one's completion.
    @ObservationIgnored var sidebarSlides = 0
    /// Where the iPad split's tab and sidebar are kept across launches (`SpacesNavigator+Sidebar`); nil keeps nothing
    /// (tests, the scripted demo, the Spaces sample).
    @ObservationIgnored let memory: UserDefaults?
    var editing = false
    var picking = false
    var newSpace: NewSpaceRequest?
    /// The host whose stats sheet shows (a host disc in the tree, the switcher's host row): `hostStatsSheet(host:)`.
    var statsHost: UUID?
    /// P3: the space switcher over this tab's screen (its host disc).
    var switcher: TabRef?
    /// What the switcher asked for once it is gone (Rename's and Terminate's dialogs show over the stack, not the sheet).
    @ObservationIgnored var afterSwitcher: (() -> Void)?
    /// The tabs' repositories and branches (the tree's and P2's branch chips; the View menu's Review and Commits apply
    /// inside one); nil reads none.
    @ObservationIgnored var gitFacts: SpaceGitFacts?
    /// The agents New tab's menu offers (P2e), set by the composition; nil offers the shell and another space only.
    @ObservationIgnored var agentLauncher: SpacesAgentLauncher?
    /// Each host's agents for that menu, read when a space screen or the switcher shows (a menu's items are fixed
    /// when it opens).
    var agentChoices: [UUID: [SpacesAgentChoice]] = [:]
    /// Spaces an agent is being started in from New tab's menu: its entries wait, so a second pick starts no second one.
    private(set) var startingAgents: Set<SpaceRef> = []
    /// Hosts a space from the quick menu (holding New space) is being made on: their New space rows wait.
    var creatingSpace: Set<UUID> = []
    let model: MobileTabs
    let actions: TabsActions

    init(model: MobileTabs, memory: UserDefaults? = nil) {
        self.model = model
        self.memory = memory
        actions = TabsActions(model: model)
        actions.closed = { [weak self] in self?.closed($0) }
        model.modeChanged = { [weak self] in self?.rememberSplit() }
        model.synced = { [weak self] in self?.reconcile() }
    }

    /// After a topology sync: panes of tabs the host closed go; on an iPad, a shown tab the host closed (another
    /// client, the shell's exit) hands the detail column to its strip neighbour (the next, else the one before), else
    /// the space's first tab, else no tab and the sidebar back, as a close from the phone does (`closed`). A host whose
    /// spaces are not known yet (no topology) changes nothing.
    func reconcile() {
        for ref in model.paneRoutes.keys where model.tab(ref) == nil && model.workspace(ref.host)?.spaces.isEmpty == false {
            model.paneRoutes[ref] = nil
        }
        guard sidebarHides, split, let shown = splitPath.tab else { return }
        if let tab = model.tab(shown) {
            remember(strip: tab)
            return
        }
        guard let workspace = model.workspace(shown.host), !workspace.spaces.isEmpty else { return }
        var next: TabRef?
        if let order = stripOrder, order.tab == shown, let index = order.tabs.firstIndex(of: shown) {
            next = order.tabs[(index + 1)...].first { model.tab($0) != nil }
                ?? order.tabs[..<index].reversed().first { model.tab($0) != nil }
            if next == nil { next = model.space(order.space)?.tabs.first?.ref }
        }
        path.removeAll { route in
            switch route {
            case .tab(let ref), .files(let ref, _): ref == shown
            default: false
            }
        }
        if let next { path = splitPath.sidebar + [.tab(next)] }
        if splitPath.tab == nil { sidebarHidden = false }
    }

    /// The shown tab's strip, for `reconcile`.
    private func remember(strip tab: MobileTab) {
        let tabs = model.strip(for: tab.ref).map(\.ref)
        if stripOrder?.tab != tab.ref || stripOrder?.tabs != tabs { stripOrder = (tab.ref, tab.space, tabs) }
    }

    /// The iPad sidebar's space row (`PadSidebar`): the detail column shows the tab the space showed last, else its
    /// first; a space without tabs shows its tabs' screen in the sidebar.
    func selectSpace(_ ref: SpaceRef) {
        guard let space = model.space(ref) else { return }
        model.visited(ref)
        if let tab = lastTabs[ref].flatMap({ last in space.tabs.first { $0.ref == last } }) ?? space.tabs.first {
            show(tab.ref)
        } else {
            setSidebar(splitPath.sidebar + [.space(ref)])
        }
    }

    /// The space whose tab the split's detail column shows (the sidebar marks it).
    var shownSplitSpace: SpaceRef? { splitPath.tab.flatMap { model.tab($0)?.space } }

    /// The tab bar's New in Spaces: a terminal tab in the most recent space, else the space picker.
    func newTabFromBar() {
        if let space = model.recentSpace { newTab(in: space) } else { picking = true }
    }

    /// New tab: a terminal tab in `space`, opened once the host shows it; in a plain host's Shell space a new shell,
    /// opened at once.
    func newTab(in space: MobileSpace) {
        guard let workspace = model.workspace(space.ref.host) else { return }
        if space.kind == .plainShell {
            newShell(host: space.ref.host)
            return
        }
        Task {
            do { open(try await workspace.newTab(in: space), terminal: true) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// A new shell on a plain host (its Shell space's New tab, an ended shell's New shell), opened in Terminal.
    func newShell(host: UUID) {
        do { open(try model.newShell(on: host), terminal: true) } catch {
            actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The quick menu's entry (holding New space): a space with New space's defaults on that host and multiplexer,
    /// without the form; its first tab opens in Terminal, as Create's does.
    func quickSpace(_ destination: NewSpaceDestination) {
        guard !creatingSpace.contains(destination.host) else { return }
        Task {
            do { open(try await makeSpace(destination), terminal: true) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// A space with New space's defaults (home, no name: the server names it after its folder, as the Mac's new spaces
    /// are named, `NewSpaceName`) on that host and multiplexer: its first tab. The host's New space rows wait meanwhile.
    /// Spaces' quick menu opens the tab; New chat's makes the space the chat's.
    func makeSpace(_ destination: NewSpaceDestination) async throws -> MobileTab {
        guard creatingSpace.insert(destination.host).inserted else {
            throw TabsFailure(message: "A space is already being made on \(destination.hostName).")
        }
        defer { creatingSpace.remove(destination.host) }
        return try await model.createSpace(on: destination.host, name: "", directory: "~", multiplexer: destination.multiplexer)
    }

    /// Pushes a tab's screen; New tab and Create open theirs in Terminal.
    func open(_ tab: MobileTab, terminal: Bool) {
        model.visited(tab.space)
        if terminal { model.segments[tab.ref] = .terminal }
        show(tab.ref)
    }

    /// Agents: a conversation's tab on its Chat segment.
    func openChat(_ ref: TabRef) {
        model.segments[ref] = .chat
        show(ref)
    }

    /// A tab row in the split (`TabsTabLink`): the detail column shows it, its segment as the user left it.
    func select(_ ref: TabRef) { show(ref) }

    /// On top of the stack; in the split, in the detail column in place of the tab shown there (and what it pushed).
    private func show(_ ref: TabRef) {
        if split { path = splitPath.sidebar + [.tab(ref)] } else { path.append(.tab(ref)) }
    }

    /// The path as the split shows it (`MobileSplit`): the sidebar's routes, the tab the detail column shows (the last
    /// one on the path) and what is pushed over it there. The path stays the one source, so folding the phone shows the
    /// same screens as one stack, the tab on top, and unfolding it splits them again.
    struct SplitPath: Equatable {
        var sidebar: [TabsRoute]
        var tab: TabRef?
        var detail: [TabsRoute]
    }

    static func split(_ path: [TabsRoute]) -> SplitPath {
        guard let index = path.lastIndex(where: { $0.tab != nil }), let tab = path[index].tab else {
            return SplitPath(sidebar: path, tab: nil, detail: [])
        }
        return SplitPath(sidebar: path[..<index].filter { $0.tab == nil }, tab: tab, detail: Array(path[(index + 1)...]))
    }

    var splitPath: SplitPath { Self.split(path) }

    /// The sidebar's stack moved (a push, Back): a tab it pushed (a row) goes to the detail column instead, in place of
    /// the one there.
    func setSidebar(_ routes: [TabsRoute]) {
        if let tab = routes.last(where: { $0.tab != nil }) {
            path = routes.filter { $0.tab == nil } + [tab]
        } else {
            let shown = splitPath
            path = routes + (shown.tab.map { [.tab($0)] } ?? []) + shown.detail
        }
    }

    /// The detail column's stack moved: a screen over the tab (a Files push, host detail), or Back from it. A tab it
    /// opens takes the column.
    func setDetail(_ routes: [TabsRoute]) {
        let shown = splitPath
        if let tab = routes.last(where: { $0.tab != nil }) {
            path = shown.sidebar + [tab]
        } else if let tab = shown.tab {
            path = shown.sidebar + [.tab(tab)] + routes
        }
    }

    /// Host detail's Spaces rows: the space's tabs (P2) over the detail; `MobileSpace.shellNode` is a plain host's Shell
    /// space.
    func openSpace(host: UUID, node: UInt64) {
        guard let workspace = model.workspace(host),
              let space = node == MobileSpace.shellNode ? workspace.shellSpace : workspace.spaces.first(where: { $0.node == node && $0.kind == .multiplexer })
        else { return }
        path.append(.space(space.ref))
    }

    /// What closed leaves the stack: a tab takes the screens its Files modes pushed (and the switcher over it), a space
    /// its screen and its tabs. With no tab left to show, a hidden sidebar comes back for good, so the next tab opened
    /// does not arrive without it. On an iPad the strip's neighbour takes the detail column, as a closed tab's
    /// neighbour does on the Mac (the next, else the one before).
    func closed(_ target: TabsActions.Target) {
        var neighbour: TabRef?
        if sidebarHides, split, case .tab(let closed) = target, splitPath.tab == closed {
            let tabs = model.strip(for: closed).map(\.ref)
            if let index = tabs.firstIndex(of: closed) {
                neighbour = index + 1 < tabs.count ? tabs[index + 1] : index > 0 ? tabs[index - 1] : nil
            }
        }
        if case .tab(let closed) = target { model.paneRoutes[closed] = nil }
        path.removeAll { route in
            switch (target, route) {
            case (.tab(let closed), .tab(let shown)), (.tab(let closed), .files(let shown, _)): closed == shown
            case (.space(let closed), .space(let shown)): closed == shown
            case (.space(let closed), .tab(let shown)), (.space(let closed), .files(let shown, _)): model.tab(shown)?.space == closed
            default: false
            }
        }
        if let neighbour, splitPath.tab == nil { path = splitPath.sidebar + [.tab(neighbour)] }
        if splitPath.tab == nil { sidebarHidden = false }
        switch target {
        case .tab(let ref): if switcher == ref { switcher = nil }
        case .space(let ref): if let shown = switcher, model.tab(shown)?.space == ref || model.tab(shown) == nil { switcher = nil }
        }
    }

    /// P2e: New tab's menu items for the host, read once a space screen or the switcher shows (its agents, with the
    /// model New chat would start them on).
    func loadAgents(host: UUID) async {
        guard let agentLauncher else { return }
        let choices = await agentLauncher.choices(host)
        if agentChoices[host] != choices { agentChoices[host] = choices }
    }

    /// P2e's agent entries: the agent starts in a new tab of `space` and opens in Chat, as New chat's Start does.
    func startAgent(_ choice: SpacesAgentChoice, in space: MobileSpace) {
        let ref = space.ref
        guard let agentLauncher, startingAgents.insert(ref).inserted else { return }
        Task {
            defer { startingAgents.remove(ref) }
            do { try await agentLauncher.start(choice, space) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// P3's tab rows: that tab in place of the one shown (Back still returns where the first was opened from).
    func switchTab(to ref: TabRef) {
        switcher = nil
        guard path.last?.tab != ref else { return }
        if let tab = model.tab(ref) { model.opened(tab) }
        if split {
            select(ref)
        } else if path.last?.tab != nil {
            path[path.count - 1] = .tab(ref)
        } else {
            path.append(.tab(ref))
        }
    }

    /// The switcher closes, then `action` runs (a dialog over the stack).
    func afterClosingSwitcher(_ action: @escaping () -> Void) {
        afterSwitcher = action
        switcher = nil
    }

    #if DEBUG
    /// Screenshot launches (`-DispatchTabsSample YES`): `-DispatchTabsShow space:<key>|space-edit:<key>|switcher:<tab key>|tab:<key>|
    /// detached:<host name>|new-space|pick|edit` opens that screen of the sample; `-DispatchTabsFilter needsYou|agents`,
    /// `-DispatchTabsCollapse <host name>` and `-DispatchTabsOfflineFolded YES` set the tree.
    func screenshotState() {
        // Once a launch: SpacesRoot appears again whenever the split's sidebar comes back to it, and the launch's tab
        // took the detail column back from the one the user had opened.
        guard !screenshotStateApplied else { return }
        screenshotStateApplied = true
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DispatchTabsOfflineFolded") != nil { model.offlineFolded = defaults.bool(forKey: "DispatchTabsOfflineFolded") }
        if let filter = defaults.string(forKey: "DispatchTabsFilter").flatMap(TabsQuery.Filter.init(rawValue:)) { model.query.filter = filter }
        if let name = defaults.string(forKey: "DispatchTabsCollapse"), let host = model.workspaces.first(where: { $0.host.name == name }),
           !model.collapsed.contains(host.id) {
            model.toggle(host.id)
        }
        if let script = defaults.string(forKey: "DispatchTabsScript") { run(script) }
        guard let show = defaults.string(forKey: "DispatchTabsShow") else { return }
        let parts = show.split(separator: ":", maxSplits: 1).map(String.init)
        func host(_ key: String) -> UUID? { model.workspaces.first { $0.space(key) != nil || $0.tab(key) != nil }?.id }
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("space", let key?): if let id = host(key) { path = [.space(SpaceRef(host: id, key: key))] }
        case ("space-edit", let key?):
            if let id = host(key) {
                editingSpace = SpaceRef(host: id, key: key)
                path = [.space(SpaceRef(host: id, key: key))]
            }
        case ("switcher", let key?):
            if let id = host(key) {
                let ref = TabRef(host: id, key: key)
                path = [.tab(ref)]
                switcher = ref
            }
        case ("detached", let name?):
            if let id = model.workspaces.first(where: { $0.host.name == name })?.id { path = [.detached(id)] }
        case ("tab", let key?):
            if let id = host(key) {
                let ref = TabRef(host: id, key: key)
                // `-DispatchTabsSegment files` and `-DispatchTabsFilesMode review`: the tab opens on that segment and mode.
                if let segment = defaults.string(forKey: "DispatchTabsSegment").flatMap(TabSegment.init(rawValue:)) {
                    model.segments[ref] = segment
                }
                if let mode = defaults.string(forKey: "DispatchTabsFilesMode").flatMap(FilesMode.init(rawValue:)) {
                    model.filesModes[ref] = mode
                }
                path = [.tab(ref)]
                // `-DispatchTabsFilesRoute commits:<revision>[:<path>]`: a Files mode's screen pushed over the tab (C2).
                if let route = defaults.string(forKey: "DispatchTabsFilesRoute") {
                    let parts = route.split(separator: ":", maxSplits: 2).map(String.init)
                    if let mode = parts.first.flatMap(FilesMode.init(rawValue:)) {
                        let route = FilesRoute(mode: mode, path: parts.count > 2 ? parts[2] : nil,
                                               revision: parts.count > 1 ? parts[1] : nil)
                        // The iPad's strip opens a commit in the pane beside the log (I3).
                        if sidebarHides, split, route.opensInPane {
                            model.paneRoutes[ref, default: [:]][mode] = route
                        } else {
                            path.append(.files(ref, route))
                        }
                    }
                }
            }
        case ("new-space", _): newSpace = NewSpaceRequest(host: model.workspaces.last?.id)
        case ("pick", _): picking = true
        case ("edit", _): editing = true
        default: break
        }
    }

    /// `-DispatchTabsScript "edit,done,space:herdr:app,pop,tab:herdr:app:1,pop"`: one step every 1.5 s after a
    /// 2 s start, for screen recordings that check every transition frame by frame. `agents` and `spaces` switch the
    /// tab bar (through `selectSection`).
    func run(_ script: String) {
        let steps = script.split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let key = parts.count > 1 ? parts[1] : ""
                let host = model.workspaces.first { $0.space(key) != nil || $0.tab(key) != nil || $0.host.name == key }?.id
                switch parts[0] {
                case "edit": editing = true
                case "done": editing = false
                case "filter": model.query.filter = TabsQuery.Filter(rawValue: key) ?? .all
                case "collapse": if let host { model.toggle(host) }
                case "space": if let host { path.append(.space(SpaceRef(host: host, key: key))) }
                case "switcher": if let host { switcher = TabRef(host: host, key: key) }
                case "tab": if let host { path.append(.tab(TabRef(host: host, key: key))) }
                case "chat": if let host { openChat(TabRef(host: host, key: key)) }
                case "pop": if !path.isEmpty { path.removeLast() }
                case "agents", "spaces": selectSection?(parts[0])
                default: break
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    @ObservationIgnored private var screenshotStateApplied = false
    /// `-DispatchTabsShow space-edit:<key>`: that space's screen opens in Edit tabs (P2d).
    @ObservationIgnored var editingSpace: SpaceRef?

    /// Set by the shell for scripts that switch tabs.
    @ObservationIgnored var selectSection: ((String) -> Void)?
    #endif
}

/// Where the shared stack goes: the Tabs screens and Hosts' detail.
struct TabsDestination: View {
    let route: TabsRoute
    @Bindable var navigator: SpacesNavigator
    let content: TabsContent
    let hostViews: SpacesHostViews

    var body: some View {
        let model = navigator.model
        switch route {
        case .tab(let ref):
            TabScreen(model: model, ref: ref, path: $navigator.path, content: content)
        case .space(let ref):
            SpaceTabsScreen(navigator: navigator, ref: ref, path: $navigator.path)
        case .detached(let host):
            SpacesDetachedScreen(model: model, actions: navigator.actions, host: host, path: $navigator.path)
        case .host(let id):
            // M1f's back pill names Spaces, as M2c's does (the system's button showed a bare chevron here).
            hostViews.detail(id)
                .navigationBarBackButtonHidden(true)
                .background(TabsSwipeBack())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        TabsBackPill(label: "Spaces") { if !navigator.path.isEmpty { navigator.path.removeLast() } }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        case .files(let tab, let route):
            content.files.destination(tab, route)
        }
    }
}

extension View {
    /// What Spaces presents over the whole stack: its dialogs, New tab's space picker and New space.
    func spacesPresentations(_ navigator: SpacesNavigator, hostViews: SpacesHostViews) -> some View {
        modifier(SpacesPresentations(navigator: navigator, hostViews: hostViews))
    }
}

private struct SpacesPresentations: ViewModifier {
    @Bindable var navigator: SpacesNavigator
    let hostViews: SpacesHostViews

    func body(content: Content) -> some View {
        content
            .tabsDialogs(navigator.actions)
            .sheet(isPresented: $navigator.picking) {
                NewTabPicker(model: navigator.model, choose: { space in
                    navigator.picking = false
                    navigator.newTab(in: space)
                }, newSpace: {
                    navigator.picking = false
                    navigator.newSpace = NewSpaceRequest(host: navigator.model.recentSpace?.ref.host)
                }, quickSpace: { destination in
                    navigator.picking = false
                    navigator.quickSpace(destination)
                })
                .tint(.dispatchPink)
            }
            .sheet(item: $navigator.newSpace) { request in
                NewSpaceSheet(model: navigator.model, host: request.host, hostViews: hostViews) { tab in
                    navigator.newSpace = nil
                    navigator.open(tab, terminal: true)
                }
                .tint(.dispatchPink)
            }
            .sheet(item: $navigator.switcher, onDismiss: {
                let action = navigator.afterSwitcher
                navigator.afterSwitcher = nil
                action?()
            }) { tab in
                SpaceSwitcherSheet(navigator: navigator, tab: tab, hostLine: hostViews.statsLine)
                    .tint(.dispatchPink)
            }
            .hostStatsSheet(host: $navigator.statsHost)
    }
}

/// The Spaces tab (P1, W0): the hosts as sections of spaces under a filter row, the OFFLINE group at the end, and the
/// host editing of M1e. Its title and Edit (the large title, Edit or Done trailing) are the shared stack's
/// (`SpacesToolbar`).
struct SpacesRoot: View {
    @Bindable var navigator: SpacesNavigator
    let hostActions: SpacesHostActions
    /// Opens New host (M8a): the empty state and edit mode's Add host.
    let addHost: () -> Void
    /// Opens Settings: edit mode's Settings, beside Add host.
    var settings: (() -> Void)? = nil

    var body: some View {
        SpacesHome(navigator: navigator, hostActions: hostActions, addHost: addHost, settings: settings)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) { ForEach(Array(SpacesNotice.notices(hostActions).enumerated()), id: \.offset) { $1 } }
            }
            #if DEBUG
            .onAppear { navigator.screenshotState() }
            #endif
    }

    @Environment(\.spacesSidebar) private var sidebar
}

struct NewSpaceRequest: Identifiable {
    let id = UUID()
    var host: UUID?
}

/// The tab's top level: the empty state without hosts, else the tree.
private struct SpacesHome: View {
    @Bindable var navigator: SpacesNavigator
    let hostActions: SpacesHostActions
    let addHost: () -> Void
    let settings: (() -> Void)?
    /// The iPad's sidebar holds the tree alone (`PadSidebar`).
    @Environment(\.spacesSidebar) private var sidebar

    var body: some View {
        let model = navigator.model
        Group {
            if model.workspaces.isEmpty {
                MobileEmptyState(section: .spaces, add: addHost)
            } else {
                SpacesTree(navigator: navigator, hostActions: hostActions, editing: navigator.editing, addHost: addHost,
                           settings: settings)
            }
        }
        .onChange(of: model.workspaces.isEmpty) { _, empty in if empty { navigator.editing = false } }
    }
}

/// The Spaces header's trailing item, in the shared stack's navigation bar: Edit, or Done in edit mode (P1).
struct SpacesToolbar: ToolbarContent {
    @Bindable var model: MobileTabs
    @Binding var editing: Bool
    /// The split's sidebar: the section's name leads the row (kept for the split's callers; Edit stays trailing).
    var capsuleTrailing = false
    /// The narrow sidebar: Edit as a glyph, beside the name in 263 points.
    var glyphEdit = false

    var body: some ToolbarContent {
        if !model.workspaces.isEmpty, glyphEdit {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing.toggle() } label: {
                    Image(systemName: editing ? "checkmark" : "pencil")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(editing ? Color.dispatchPink : .primary)
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(editing ? "Done" : "Edit")
            }
            .sharedBackgroundVisibility(.hidden)
        } else if !model.workspaces.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing.toggle() } label: {
                    Text(editing ? "Done" : "Edit")
                        .font(.body.weight(editing ? .semibold : .regular))
                        .foregroundStyle(editing ? Color.dispatchPink : .primary)
                }
            }
        }
    }
}

/// P1's filter row under the title: All · Needs you (with the count of conversations waiting) · Agents as glass chips,
/// the chosen one on the app tint. One line; it scrolls sideways when a narrow column or a large text size needs it.
struct SpacesFilterRow: View {
    @Binding var filter: TabsQuery.Filter
    let needsYou: Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(TabsQuery.Filter.allCases) { item in
                    chip(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
        .accessibilityIdentifier("spaces-filter")
    }

    private func chip(_ item: TabsQuery.Filter) -> some View {
        let on = item == filter
        return Button { filter = item } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbol).font(.caption.weight(.semibold))
                Text(item.title).font(.subheadline.weight(.semibold))
                if item == .needsYou, needsYou > 0 {
                    Text("\(needsYou)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.stateUnread, in: Capsule())
                }
            }
            .lineLimit(1)
            .foregroundStyle(on ? Color.onAccent : .primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            // The tint is a fill in the chip's content, not the glass's: the glass's tint followed a choice only once
            // its own animation ended, so the label was already dark on untinted glass for a moment.
            .background { if on { Capsule().fill(Color.dispatchPink) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .accessibilityLabel(item.title)
        .accessibilityValue(item == .needsYou && needsYou > 0 ? "\(needsYou)" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// P1, W0 and M1e: each host a section (its header folds it; its glyph disc opens the host's stats), its spaces in an
/// inset grouped card with their branch, the amber dot while something works and the unread count, then a Detached row
/// when some of its work is detached; the OFFLINE group's hosts as header rows at the end, folding as one.
/// Editing: every host, a red remove control and Info on each, drag handles on hosts and spaces (spaces stay in their
/// host), and Add host at the end. A connected host without spaces offers New space in their place (holding it, the
/// quick menu of its multiplexers).
private struct SpacesTree: View {
    let navigator: SpacesNavigator
    let hostActions: SpacesHostActions
    let editing: Bool
    let addHost: () -> Void
    var settings: (() -> Void)? = nil
    @State private var removing: (host: UUID, question: HostRemovalConfirmation)?
    @Environment(\.spacesSidebar) private var sidebar

    private var model: MobileTabs { navigator.model }

    var body: some View {
        let groups = model.groups
        let sections = editing ? model.sections(filter: .all) : groups.online
        TimelineView(.everyMinute) { context in
            List {
                // The iPad's sidebar has its filter as a menu in its bar (`PadFilterMenu`).
                if !editing, !sidebar {
                    Section {
                        SpacesFilterRow(filter: Binding(get: { model.query.filter }, set: { model.query.filter = $0 }),
                                        needsYou: model.needsYou())
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                    .listSectionSpacing(4)
                }
                ForEach(sections) { section in
                    hostSection(section, now: context.date)
                }
                if !editing, !groups.offline.isEmpty {
                    SpacesOfflineGroup(model: model, hosts: groups.offline, now: context.date,
                                       stats: { navigator.statsHost = $0 })
                }
                if editing { editFooter }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            // The chips right under the large title (P1): the list's own top margin would leave a gap there.
            .contentMargins(.top, editing ? nil : 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            // Not while editing: the drags start where the pull would.
            .hostsRefreshable(editing ? nil : model.refresh)
            .environment(\.editMode, .constant(editing ? .active : .inactive))
            .alert(removing?.question.title ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                   presenting: removing) { removing in
                Button("Cancel", role: .cancel) {}
                Button(removing.question.button, role: .destructive) { hostActions.removeHost(removing.host) }
            } message: { removing in
                Text(removing.question.message)
            }
            .overlay { if !editing, model.query.filtering, groups.online.isEmpty { TabsNothing(query: model.query) } }
        }
    }

    @ViewBuilder private func hostSection(_ section: SpacesSection, now: Date) -> some View {
        Section {
            if !section.collapsed, !(section.offline && !editing) {
                ForEach(section.spaces) { row in
                    SpacesSpaceLine(row: row, editing: editing, gitFacts: navigator.gitFacts)
                }
                .onMove { source, destination in
                    model.moveSpaces(of: section.host.id, visible: section.spaces.map(\.id.key), from: source, to: destination)
                }
                if section.detached > 0, !editing, !model.query.filtering {
                    SpacesDetachedLine(host: section.host, count: section.detached)
                }
            }
            if let other = section.host.sameMachine, !section.collapsed, !editing {
                Text("Same machine as \(other): its spaces show there.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if section.offersNewSpace(editing: editing, filter: model.query.filter) {
                SpacesNewSpaceLine(host: section.host,
                                   destinations: NewSpaceDestination.all(model.workspaces, host: section.host.id),
                                   creating: navigator.creatingSpace.contains(section.host.id),
                                   open: { navigator.newSpace = NewSpaceRequest(host: section.host.id) },
                                   quick: { navigator.quickSpace($0) })
            }
        } header: {
            SpacesHostHeader(section: section, editing: editing, toggle: { model.toggle(section.host.id) },
                             remove: {
                if let question = hostActions.removalConfirmation(for: section.host.id) { removing = (section.host.id, question) }
            }, stats: { navigator.statsHost = section.host.id }, updated: model.updated.map { updated in { updated(section.host.id) } },
               now: now)
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, let id = UUID(uuidString: item) else { return false }
                    model.moveHost(id, before: section.host.id, actions: hostActions)
                    return true
                }
        }
    }

    private var editFooter: some View {
        Section {
            HStack(spacing: 12) {
                Button(action: addHost) {
                    // Not a Label: a list row restyles labels (their title did not follow Dynamic Type there).
                    HStack(spacing: 8) {
                        Image(systemName: "plus").accessibilityHidden(true)
                        Text("Add host").fittingLine()
                    }
                        .font(.headline)
                        .padding(.leading, 20)
                        .padding(.trailing, 24)
                        .padding(.vertical, 8)
                        .frame(minHeight: 50)
                }
                .buttonStyle(MobileCallToAction())
                .dropDestination(for: String.self) { items, _ in
                    guard let item = items.first, let id = UUID(uuidString: item) else { return false }
                    model.moveHost(id, before: nil, actions: hostActions)
                    return true
                }
                if let settings {
                    // Not in the mockup: the app's settings, beside Add host where hosts are managed (docs/ios.md).
                    Button(action: settings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 19, weight: .semibold))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Settings")
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }
}

/// W0's OFFLINE group: its header (the count, a chevron that folds the group, remembered; held, the "Show offline
/// hosts" switch, which Settings has too) and each offline host as a header row: the name and multiplexer dimmed, "as of
/// 2h ago" (when its helper last answered), and its glyph disc, which opens the stats sheet's offline variant.
private struct SpacesOfflineGroup: View {
    @Bindable var model: MobileTabs
    let hosts: [SpacesSection]
    let now: Date
    let stats: (UUID) -> Void

    var body: some View {
        Section {
            if !model.offlineFolded {
                ForEach(hosts) { section in
                    SpacesOfflineHostRow(host: section.host, note: SpacesOfflineHostRow.note(model.updated?(section.host.id), now: now),
                                         stats: { stats(section.host.id) })
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            // A tap folds the group; held, its menu (W0c). A context menu on a list's header never opened.
            Menu {
                Toggle("Show offline hosts", systemImage: "wifi.slash", isOn: $model.showOffline)
            } label: {
                HStack(spacing: 6) {
                    Text("Offline").textCase(.uppercase)
                    Text("\(hosts.count)").foregroundStyle(.tertiary).monospacedDigit()
                    Spacer(minLength: 0)
                    Image(systemName: model.offlineFolded ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            } primaryAction: {
                model.offlineFolded.toggle()
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .accessibilityLabel("Offline, \(hosts.count) \(hosts.count == 1 ? "host" : "hosts")")
            .accessibilityValue(model.offlineFolded ? "Collapsed" : "Expanded")
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(model.offlineFolded ? "Shows the offline hosts" : "Hides the offline hosts")
            .accessibilityActions {
                Button("Hide offline hosts") { model.showOffline = false }
            }
            .accessibilityIdentifier("spaces-offline")
        }
    }
}

/// An offline host in W0's group: no spaces, only who it is, since when, and its stats behind the glyph.
struct SpacesOfflineHostRow: View {
    let host: TabsHost
    let note: String
    let stats: () -> Void

    /// "as of 2h ago" from when its helper last answered; "offline" when it never did.
    static func note(_ updated: Date?, now: Date) -> String {
        guard let when = TabsTime.ago(updated, now: now) else { return "offline" }
        return "as of " + (when == "now" ? "just now" : when == "Yesterday" ? "yesterday" : when)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(host.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            SpacesHostChip(host: host)
            Text(note)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            SpacesHostDisc(host: host, action: stats)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: stats)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(host.name)
        .accessibilityValue([host.plain ? HostSummary.plainSSH : host.multiplexer, "Offline", note].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows the host’s connection")
    }
}

/// The multiplexer a host's spaces come from (`MultiplexerMark`), the plain SSH mark, or nothing while unknown.
struct SpacesHostChip: View {
    let host: TabsHost
    var body: some View {
        if host.plain {
            PlainSSHMark()
        } else if let multiplexer = host.multiplexer {
            MultiplexerMark(name: multiplexer)
        }
    }
}

/// A host's glyph on a 34-point glass disc with its connection dot (green connected, amber on its way, grey offline,
/// the glyph dimmed): the host's stats (W0). The iPad stream finds it by `spaces-host-<name>`.
struct SpacesHostDisc: View {
    let host: TabsHost
    let action: () -> Void
    /// The iPad's sidebar (`PadSidebar`): the stats show in a popover from the disc (I5,
    /// `HostStatsPopoverContent`) instead of the sheet.
    @Environment(\.spacesSidebar) private var sidebar
    @State private var popover = false

    static let size: CGFloat = 34

    var body: some View {
        Button(action: { if sidebar { popover = true } else { action() } }) {
            HostGlyph(host: host.glyphRecord, size: 16)
                .foregroundStyle(host.state == .offline ? Color.secondary : host.tint)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
                .overlay(Circle().stroke(Color.canvas, lineWidth: 1.5))
                .accessibilityHidden(true)
        }
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("\(host.name) stats")
        .accessibilityValue(host.state == .connected ? "Connected" : host.state == .connecting ? "Connecting" : "Offline")
        .accessibilityIdentifier("spaces-host-\(host.name)")
        .popover(isPresented: $popover, arrowEdge: .leading) {
            HostStatsPopoverContent(hostID: host.id)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var dot: Color {
        switch host.state {
        case .connected: .stateConnected
        case .connecting: .stateWorking
        case .offline: Color.secondary.opacity(0.5)
        }
    }
}

/// A host's section header (P1, M1e): the name, the multiplexer its spaces come from (`SpacesHostChip`) and, folded,
/// "2 spaces · 1"; the glyph disc at the end opens its stats. The name (the whole row but the disc) folds or unfolds the
/// host's spaces: one button outside edit mode (VoiceOver: the host's name, a heading, the multiplexer and "Expanded"
/// or "Collapsed" with the unread it rolls up); in edit mode its remove, Info and reorder controls keep their own taps
/// and the rest of the row toggles.
struct SpacesHostHeader: View {
    let section: SpacesSection
    let editing: Bool
    let toggle: () -> Void
    let remove: () -> Void
    /// The glyph disc: the host's stats sheet.
    var stats: () -> Void = {}
    /// When the host's helper last answered (`HostFreshness`), for VoiceOver and a host that is not connected.
    var updated: (@MainActor () -> Date?)? = nil

    /// The tree's minute (its `TimelineView`): a timeline in a list's section header kept the list laying out
    /// without end (100 % CPU, XCUITest never saw the app idle).
    var now = Date()

    var body: some View {
        let freshness = updated.map { HostFreshness.label(state: section.host.state, updated: $0(), now: now) }
        Group {
            if editing {
                row(freshness)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
            } else {
                HStack(spacing: 8) {
                    // A button reads its label as one element: the name replaces it (the chip and the note would be read).
                    Button(action: toggle) { identity(note: true).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(section.host.name)
                        .accessibilityValue(Self.value(collapsed: section.collapsed, unread: section.unread,
                                                       multiplexer: section.host.plain ? HostSummary.plainSSH : section.host.multiplexer,
                                                       freshness: freshness))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityHint(section.collapsed ? "Shows its spaces" : "Hides its spaces")
                    Spacer(minLength: 0)
                    SpacesHostDisc(host: section.host, action: stats)
                }
                .textCase(nil)
                .padding(.bottom, 2)
            }
        }
    }

    /// "tmux, Collapsed, 3 unread, Updated just now", "Expanded": where the spaces come from when known, the row's
    /// state, the unread a collapsed host rolls up, and the host's last update.
    static func value(collapsed: Bool, unread: Int, multiplexer: String? = nil, freshness: String? = nil) -> String {
        [multiplexer, collapsed ? "Collapsed" : "Expanded", collapsed && unread > 0 ? "\(unread) unread" : nil, freshness]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private func row(_ freshness: String?) -> some View {
        HStack(spacing: 8) {
            Button(action: remove) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color(uiColor: .systemRed), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(section.host.name)")
            VStack(alignment: .leading, spacing: 2) {
                if column != nil, UIDevice.current.userInterfaceIdiom == .pad {
                    // An iPad's sidebar (320 points, 280 beside the window controls): the chip gives way before the
                    // name, which edit mode's controls left as "…" beside it.
                    ViewThatFits(in: .horizontal) {
                        identity(note: false)
                        identity(chip: false, note: false)
                    }
                } else {
                    identity(note: false)
                }
                if let freshness {
                    Text(freshness)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            NavigationLink(value: TabsRoute.host(section.host.id)) {
                Image(systemName: "info.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.dispatchPink)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.host.name) details")
            Button(action: toggle) { disclosure }
                .buttonStyle(.plain)
                .accessibilityLabel(section.collapsed ? "Show \(section.host.name)" : "Hide \(section.host.name)")
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                // The handle drags; a tap on it is not the row's.
                .onTapGesture {}
                .draggable(section.host.id.uuidString) {
                    Text(section.host.name).font(.title3.bold()).padding(8)
                }
                .accessibilityLabel("Reorder \(section.host.name)")
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    /// The host's name, the multiplexer's chip when `chip`, and folded the spaces and their unread ("2 spaces · 1").
    private func identity(chip: Bool = true, note: Bool) -> some View {
        HStack(spacing: 8) {
            Text(section.host.name)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .accessibilityAddTraits(.isHeader)
            if chip { SpacesHostChip(host: section.host) }
            if note, section.collapsed {
                Text(section.foldedNote)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var disclosure: some View {
        Image(systemName: section.collapsed ? "chevron.right" : "chevron.down")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
            .background(Color.chipFill, in: Circle())
            .contentShape(Circle())
    }

    @Environment(\.dynamicTypeSize) private var typeSize
    /// Set in the split's sidebar only (`MobileRoot`); the phone's screens and the Duo's keep their layout.
    @Environment(\.tabsColumnWidth) private var column
}

/// P1's Detached row at the end of a host's card: how much of its work is detached, opening the list that restores it.
struct SpacesDetachedLine: View {
    let host: TabsHost
    let count: Int

    var body: some View {
        NavigationLink(value: TabsRoute.detached(host.id)) {
            HStack(spacing: 8) {
                Image(systemName: "eject")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text("Detached").font(.body).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(count)").font(.body).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Detached on \(host.name)")
        .accessibilityValue("\(count)")
    }
}

/// M2b's line for a connected host without spaces: New space, which opens the form for this host; held, the quick
/// menu of its multiplexers makes one at once (New space's defaults), as a row's context menu (Close, Rename) is held.
/// VoiceOver offers the menu's entries as actions.
struct SpacesNewSpaceLine: View {
    let host: TabsHost
    let destinations: [NewSpaceDestination]
    let creating: Bool
    let open: () -> Void
    let quick: (NewSpaceDestination) -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "plus").accessibilityHidden(true)
                Text("New space").font(.body).lineLimit(2)
                Spacer(minLength: 0)
                if creating { ProgressView() }
            }
            .foregroundStyle(Color.dispatchPink)
            .contentShape(Rectangle())
        }
        .disabled(creating)
        .contextMenu { NewSpaceQuickMenu(destinations: destinations, host: host.id, create: quick) }
        .accessibilityLabel("New space on \(host.name)")
        .accessibilityValue(creating ? "Creating" : "")
        .accessibilityHint(destinations.isEmpty ? "" : "Hold for a space with the defaults")
        .accessibilityActions {
            ForEach(destinations) { destination in
                Button(destination.spoken(host: host.id)) { quick(destination) }
            }
        }
    }
}

/// A space in the tree (P1): its name, its branch, the amber dot while something works, the unread count (blue, as
/// Mail's), a chevron. The branch is the space's folder's (`SpaceGitFacts`, read once per folder and connection).
struct SpacesSpaceLine: View {
    let row: SpacesSpaceRow
    let editing: Bool
    var gitFacts: SpaceGitFacts? = nil
    /// The iPad sidebar: the row selects the space (its tab beside the sidebar) and is marked while it shows.
    @Environment(\.tabsSelectSpace) private var select
    @Environment(\.tabsShownSpace) private var shown

    var body: some View {
        if editing {
            Text(row.space.name).font(.body).lineLimit(2)
        } else if let select {
            let selected = shown == row.space.ref
            Button { select(row.space.ref) } label: {
                HStack(spacing: 8) {
                    label
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selected ? Color.lens : nil)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.space.name)
            .accessibilityValue(Self.value(unread: row.unread, working: row.working, branch: branch))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("space-row")
            .task(id: gitKey) {
                guard let gitFacts, let gitKey else { return }
                await gitFacts.resolve(gitKey.key, directory: gitKey.directory)
            }
        } else {
            NavigationLink(value: TabsRoute.space(row.space.ref)) {
                label
            }
            // "app", the unread count and the amber dot's meaning as the value.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.space.name)
            .accessibilityValue(Self.value(unread: row.unread, working: row.working, branch: branch))
            .accessibilityIdentifier("space-row")
            .task(id: gitKey) {
                guard let gitFacts, let gitKey else { return }
                await gitFacts.resolve(gitKey.key, directory: gitKey.directory)
            }
        }
    }

    /// The name and branch, the amber dot while something works, the unread count.
    private var label: some View {
        HStack(spacing: 8) {
            Text(row.space.name).font(.body).lineLimit(2).layoutPriority(1).foregroundStyle(.primary)
            if let branch { SpacesBranchChip(branch: branch) }
            Spacer(minLength: 0)
            if row.working {
                Circle().fill(Color.stateWorking).frame(width: 10, height: 10)
            }
            if row.unread > 0 {
                Text("\(row.unread)").font(.body).foregroundStyle(Color.stateUnread).monospacedDigit()
            }
        }
    }

    private struct GitKey: Hashable {
        let key: SpaceGitFacts.Key
        let directory: String
        let generation: Int
    }

    private var gitKey: GitKey? {
        guard let gitFacts, let directory = row.space.cwd, directory.hasPrefix("/") else { return nil }
        return GitKey(key: SpaceGitFacts.Key(host: row.space.ref.host, key: row.space.ref.key), directory: directory,
                      generation: gitFacts.generation(row.space.ref.host))
    }

    private var branch: String? {
        gitKey.flatMap { gitFacts?.facts($0.key, directory: $0.directory)?.branch }
    }
}

/// A branch beside a space's name (P1, P2, P3): the branch glyph and its name, secondary.
struct SpacesBranchChip: View {
    /// A header's title with the branch after it, as one text that truncates as one line (P2, P3).
    static func title(_ title: String, branch: String?) -> Text {
        guard let branch else { return Text(title).font(.headline) }
        // The glyph's own spoken name is "Divide".
        let mark = Text(Image(systemName: "arrow.triangle.branch")).font(.caption2.weight(.semibold)).accessibilityLabel("branch")
        return Text("\(Text(title).font(.headline))  \(mark.foregroundStyle(.secondary)) \(Text(branch).font(.caption.weight(.semibold)).foregroundStyle(.secondary))")
    }

    let branch: String
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
            Text(branch).font(font)
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // A usual branch keeps its whole name (the space's name gives way first); a long one truncates.
        .fixedSize(horizontal: branch.count <= 24, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("branch \(branch)")
    }
}

extension SpacesSpaceLine {
    static func value(unread: Int, working: Bool, branch: String? = nil) -> String {
        [branch.map { "branch \($0)" }, unread > 0 ? "\(unread) unread" : nil, working ? "Working" : nil].compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// When the filter leaves nothing.
struct TabsNothing: View {
    let query: TabsQuery
    var body: some View {
        Text(query.filter == .needsYou ? "Nothing needs you." : query.filter == .agents ? "No agents are running."
             : "No tabs yet. New makes one.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 44)
            .multilineTextAlignment(.center)
    }
}
