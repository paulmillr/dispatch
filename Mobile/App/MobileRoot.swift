import SwiftUI

/// The two sections of the tab bar (M2a, M3a). Hosts are managed inside Spaces (M1d, M1e, M1f).
enum MobileSection: Hashable, CaseIterable, Identifiable {
    case spaces, agents
    var id: Self { self }

    var title: String {
        switch self { case .spaces: "Spaces"; case .agents: "Agents" }
    }
    var symbol: String {
        switch self { case .spaces: "square.on.square"; case .agents: "bubble.left.and.bubble.right" }
    }
    /// What New makes here (M2a: a terminal tab in the most recent space; M9a: a chat).
    var sheet: MobileSheet {
        switch self { case .spaces: .newTab; case .agents: .newChat }
    }
    /// The New button's glyph follows the selected section: a tab with a plus (M2a), a compose glyph (M3a).
    var newImage: Image {
        switch self {
        case .spaces: Image(systemName: "plus.rectangle")
        case .agents: Image(systemName: "square.and.pencil")
        }
    }
}

/// The sheets the shell presents; the feature streams supply their contents.
enum MobileSheet: Hashable, Identifiable {
    case newHost, newTab, newChat, settings
    var id: Self { self }
    var title: String {
        switch self { case .newHost: "New host"; case .newTab: "New tab"; case .newChat: "New chat"; case .settings: "Settings" }
    }
}

/// The app's root: the Liquid Glass tab bar with Spaces and Agents, and New as the separate trailing glass circle
/// (M2a). New is a tab with the role the system draws apart from the others (`newRole`); it is never selected:
/// choosing it acts for the current section and the selection stays where it was. In Spaces, New opens a terminal tab
/// in the most recent space (the space picker when there is none); with no host yet, its glyph is a display with a
/// plus and it opens New host (M1d). In Agents it opens New chat (M9a).
///
/// One navigation stack holds the tab bar: pushed screens (a tab, a space, space details, host detail, message
/// details) cover the whole screen and the tab bar leaves with the root as UIKit pushes it, frame for frame, as the
/// mockup shows them without a tab bar (M2c, M4d, M5b, the tab screen). The sections' titles and toolbars are the
/// stack's, chosen by the selected section.
struct MobileRoot: View {
    @State private var section = MobileRoot.initialSection
    @State private var sheet: MobileSheet?
    /// Runs once the presented sheet is gone (New chat's Start opens the thread then).
    @State private var afterSheet: (() -> Void)?
    /// The window's, for `MobileSplit`.
    @State private var windowSize = MobileSplit.initialSize
    /// The split's columns' space and the fold in it (`MobileFoldReader`); zero until measured.
    @State private var splitSpace = CGSize.zero
    @State private var fold: CGFloat?
    private let composition: MobileComposition
    @Bindable private var navigator: SpacesNavigator

    init(composition: MobileComposition) {
        self.composition = composition
        navigator = composition.navigator
    }

    private var tabs: MobileTabs { composition.tabs }
    private var conversations: ChatConversations { composition.conversations }

    private enum Slot: Hashable {
        case section(MobileSection)
        case new
    }

    private static var initialSection: MobileSection {
        #if DEBUG
        if ChatDemo.screen != nil || UserDefaults.standard.string(forKey: "DispatchSection") == "agents" { return .agents }
        #endif
        return .spaces
    }

    /// The role that draws a tab as the bar's separate trailing circle: iOS 27's prominent tab, else iOS 26's search
    /// tab (the slot iOS 26 sets apart from the others).
    private static var newRole: TabRole {
        if #available(iOS 27, *) { .prominent } else { .search }
    }

    private var noHosts: Bool { tabs.workspaces.isEmpty }

    /// New: in Spaces a terminal tab (or New host while there is no host), in Agents New chat.
    private func new() {
        switch section {
        case .spaces where noHosts: sheet = .newHost
        case .spaces: navigator.newTabFromBar()
        case .agents: sheet = section.sheet
        }
    }

    private var selection: Binding<Slot> {
        Binding(get: { .section(section) }, set: { slot in
            switch slot {
            case .section(let next): section = next
            case .new: new()
            }
        })
    }

    private var newImage: Image {
        section == .spaces && noHosts ? Image("NewHost") : section.newImage
    }

    private var newTitle: String {
        section == .spaces && noHosts ? MobileSheet.newHost.title : section.sheet.title
    }

    var body: some View {
        #if DEBUG
        if ChatDemo.screen != nil {
            // The chat demo's screens carry their own stacks (Debug only).
            tabView
        } else {
            root
        }
        #else
        root
        #endif
    }

    /// The one stack, or Spaces beside the tab in a wide window (`MobileSplit`). Both show the navigator's path, so
    /// folding or unfolding keeps the screens the user was on.
    private var root: some View {
        let split = MobileSplit.applies(to: windowSize)
        return Group {
            if split { splitView } else { stack(path: $navigator.path) }
        }
        .background {
            // The whole window, keyboard and bars included: the keyboard coming up must not fold the split away.
            Color.clear
                .ignoresSafeArea()
                .onGeometryChange(for: CGSize.self, of: \.size) { windowSize = $0 }
        }
        .onChange(of: split, initial: true) { _, split in navigator.split = split }
        .spacesPresentations(navigator, hostViews: composition.hostViews)
        .environment(\.hostSpaceOpening, navigator)
        #if DEBUG
        .onAppear {
            navigator.selectSection = { name in section = name == "agents" ? .agents : .spaces }
        }
        #endif
    }

    /// The split's columns: measured once the split has laid out, the window's until then.
    private var columns: MobileSplit.Columns {
        let space = splitSpace.width > 0 ? splitSpace : windowSize
        return MobileSplit.columns(width: space.width, height: space.height, fold: fold)
    }

    /// The phone's stack, tab bar and all, in the sidebar; the tab its rows open beside it, past the fold.
    private var splitView: some View {
        let columns = columns
        return HStack(spacing: 0) {
            stack(path: Binding(get: { navigator.splitPath.sidebar }, set: { navigator.setSidebar($0) }))
                .frame(width: columns.sidebar)
                .environment(\.tabsColumnWidth, columns.sidebar)
                .environment(\.tabsSelectTab, { navigator.select($0) })
            // The hairline: on the fold in book posture.
            Rectangle()
                .fill(Color.hairline)
                .frame(width: 0.5)
                .frame(width: columns.gap)
                .ignoresSafeArea()
            // The rest, not a set width: the probe measures what the columns are given, and a total wider than that
            // centred the row and clipped the sidebar's leading edge.
            MobileSplitDetail(navigator: navigator, content: composition.content, hostViews: composition.hostViews)
                .frame(maxWidth: .infinity)
                .environment(\.tabsColumnWidth, columns.tab)
                .environment(\.tabsSelectTab, { navigator.select($0) })
        }
        .background {
            MobileFoldReader { size, fold in
                splitSpace = size
                self.fold = fold
            }
        }
    }

    private func stack(path: Binding<[TabsRoute]>) -> some View {
        NavigationStack(path: path) {
            tabView
                .navigationTitle(section.title)
                .toolbarTitleDisplayMode(.large)
                .toolbar {
                    switch section {
                    case .spaces: SpacesToolbar(model: tabs, editing: $navigator.editing)
                    case .agents: AgentsToolbar(conversations: conversations)
                    }
                }
                .navigationDestination(for: TabsRoute.self) { route in
                    TabsDestination(route: route, navigator: navigator, content: composition.content,
                                    hostViews: composition.hostViews)
                }
        }
    }

    private var tabView: some View {
        let split = MobileSplit.applies(to: windowSize)
        let sidebar = columns.sidebar
        let narrow = split && MobileSplit.narrow(sidebar: sidebar)
        return TabView(selection: selection) {
            ForEach(MobileSection.allCases) { item in
                Tab(value: Slot.section(item)) {
                    Group {
                        switch item {
                        case .spaces:
                            SpacesRoot(navigator: navigator, hostActions: composition.hosts, addHost: { sheet = .newHost },
                                       settings: { sheet = .settings })
                        case .agents:
                            agents
                        }
                    }
                    .tint(.dispatchPink)
                    .background(Color.canvas)
                    // Set inside each tab: the tab bar controller's tabs do not see what is set around the TabView.
                    .environment(\.tabsShownTab, split ? navigator.splitPath.tab : nil)
                    .environment(\.tabsColumnWidth, split ? sidebar : nil)
                    .environment(\.tabsNarrowSidebar, narrow)
                    .environment(\.tabsSelectTab, split ? { navigator.select($0) } : nil)
                } label: {
                    // Outlines, as in the mockup: the bar would draw the filled variants.
                    if narrow {
                        Image(systemName: item.symbol).environment(\.symbolVariants, .none).accessibilityLabel(item.title)
                    } else {
                        Label { Text(item.title) } icon: { Image(systemName: item.symbol).environment(\.symbolVariants, .none) }
                    }
                }
            }
            Tab(value: Slot.new, role: Self.newRole) {
                // Never shown: New acts instead of opening.
                Color.clear
            } label: {
                Label { Text(newTitle) } icon: { newImage.environment(\.symbolVariants, .none) }
            }
        }
        // The selected tab's glyph and label are drawn in the primary colour (M2a), not the app tint.
        .tint(.primary)
        // New never becomes the selected tab, not even for a frame: refused before UIKit switches tabs (a recording
        // showed the empty tab for 16 frames when only the binding refused it). The binding stays as the fallback.
        .background { NewTabGuard { new() }.allowsHitTesting(false).accessibilityHidden(true) }
        .sheet(item: $sheet, onDismiss: {
            let action = afterSheet
            afterSheet = nil
            action?()
        }) { sheet in
            Group {
                switch sheet {
                case .newHost: composition.hostViews.newHost { _ in self.sheet = nil }
                case .newChat:
                    NewChatSheet(conversations: conversations, memory: composition.modelMemory, look: composition.look,
                                 spaceMaker: composition.newChatSpaces, started: { key in
                        afterSheet = { composition.openChat(key, keyboard: true) }
                        self.sheet = nil
                    })
                case .settings: SettingsView(composition: composition)
                case .newTab: EmptyView()
                }
            }
            .tint(.dispatchPink)
        }
        // Host key questions show over the app; a sheet that registers later (New host) takes them over.
        .hostTrustPrompt()
    }

    /// The Agents section (Mobile/Agents), or a demo screen in Debug builds (ChatDemo).
    @ViewBuilder private var agents: some View {
        #if DEBUG
        if let screen = ChatDemo.screen { ChatDemoRoot(screen: screen) } else { agentsList }
        #else
        agentsList
        #endif
    }

    private var agentsList: some View {
        AgentsScreen(conversations: conversations, look: composition.look,
                     open: { composition.openChat($0.key, keyboard: false) },
                     close: { conversation in
                         if let ref = composition.tab(for: conversation.key) { navigator.actions.close(.tab(ref), .close) }
                     },
                     chrome: false)
    }
}

#Preview("Spaces, first run") {
    let hosts = HostSessions.demo(empty: true)
    MobileRoot(composition: MobileComposition(hosts: hosts, tabs: MobileTabs(activity: TabActivityStore(url: nil),
                                                                             defaults: UserDefaults(suiteName: "preview")!)))
        .environment(hosts)
}
