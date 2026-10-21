import SwiftUI
import UIKit

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
    /// The phone's split rules or the iPad's (`MobileSplit.Device`).
    private let device: MobileSplit.Device
    private let composition: MobileComposition
    @Bindable private var navigator: SpacesNavigator

    init(composition: MobileComposition, device: MobileSplit.Device = .current) {
        self.composition = composition
        self.device = device
        navigator = composition.navigator
        // Before the first frame: the launch's window shows the tab and the sidebar as they were left (once a launch).
        if device == .pad { navigator.restoreSplit(splits: MobileSplit.applies(to: MobileSplit.initialSize, device: .pad)) }
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
        let split = MobileSplit.applies(to: windowSize, device: device)
        return Group {
            if split {
                splitView
            } else {
                // The window's width, not the screen's: an iPad window in a third or Slide Over is a phone's width on a
                // 13-inch screen, and its headers must truncate to it.
                stack(path: $navigator.path, titleInBar: false)
                    .environment(\.tabsColumnWidth, windowSize.width > 0 ? windowSize.width : nil)
                    .mobileCompactWidth(device == .pad)
            }
        }
        .background {
            // The whole window, keyboard and bars included: the keyboard coming up must not fold the split away, nor
            // the status bar on the Duo's unfolded screen, 553 points high held as a book (`MobileWindowReader`:
            // SwiftUI's geometry here shrank with both).
            MobileWindowReader { windowSize = $0 }
                .ignoresSafeArea()
        }
        .onChange(of: split, initial: true) { _, split in
            navigator.split = split
            // Folded or unfolded: the vertical bar follows the screen (`MobileVerticalBar`).
            MobileVerticalBar.refresh()
        }
        // A section chosen while the sidebar is hidden (⌘1, ⌘2) shows it.
        .onChange(of: section) { navigator.showSidebar() }
        .spacesPresentations(navigator, hostViews: composition.hostViews)
        .environment(\.hostSpaceOpening, navigator)
        // The menu bar and ⌘ chords (MobileCommands).
        .mobileCommands(composition, section: $section, sheet: $sheet)
        #if DEBUG
        .onAppear {
            navigator.selectSection = { name in section = name == "agents" ? .agents : .spaces }
        }
        #endif
    }

    /// The split's columns: measured once the split has laid out, the window's until then. An iPad has no fold and
    /// no side insets: the window's size, which changes in the same update as `split`, so a rotation or a resize never
    /// draws a frame of the last size's columns while the probe's report waits for the next turn.
    private var columns: MobileSplit.Columns {
        let space = device == .pad || splitSpace.width <= 0 ? windowSize : splitSpace
        return MobileSplit.columns(width: space.width, height: space.height, fold: fold, device: device)
    }

    /// The phone's stack, tab bar and all, in the sidebar; the tab its rows open beside it, past the fold. On an iPad
    /// the sidebar can give the tab the whole window (`SpacesNavigator.toggleSidebar`): it slides off the leading edge
    /// at its own width, still alive (its stack, scroll position and tab bar stay), and comes back the same way. As
    /// the Mac's split slides its sidebar (`NativeSplit`), the tab keeps the wider of its two widths for the whole
    /// slide and only moves, the window's edge clipping the overhang: its terminal and chat lay out once a slide, not
    /// on every frame (which resized the terminal's grid, and the server's window, sixty times a second).
    private var splitView: some View {
        let columns = columns
        let hidden = device == .pad && navigator.sidebarShownHidden
        let leading = columns.sidebar + columns.gap
        let wide = hidden || (device == .pad && navigator.sidebarSliding)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                stack(path: Binding(get: { navigator.splitPath.sidebar }, set: { navigator.setSidebar($0) }),
                      titleInBar: device == .phone)
                    .frame(width: columns.sidebar)
                    .mobileCompactWidth(device == .pad)
                    .environment(\.tabsColumnWidth, columns.sidebar)
                    .environment(\.tabsSelectTab, { navigator.select($0) })
                // The hairline: on the fold in book posture.
                Rectangle()
                    .fill(Color.hairline)
                    .frame(width: 0.5)
                    .frame(width: columns.gap)
                    .ignoresSafeArea()
            }
            .offset(x: hidden ? -leading : 0)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            detail(columns: columns, leading: leading, hidden: hidden, wide: wide)
                .environment(\.tabsColumnWidth, wide ? columns.sidebar + columns.gap + columns.tab : columns.tab)
                .environment(\.tabsSelectTab, { navigator.select($0) })
                .environment(\.tabsSidebarToggle, device == .pad && navigator.canToggleSidebar
                    ? TabsSidebarToggle(hidden: hidden, toggle: { navigator.toggleSidebar() }) : nil)
        }
        .background {
            MobileFoldReader { size, fold in
                splitSpace = size
                self.fold = fold
            }
        }
    }

    /// The detail column: on an iPad a set width, which changes only outside the slide's animation (the slide moves
    /// it, `SpacesNavigator.toggleSidebar`); on the Duo the rest of the split's space.
    @ViewBuilder private func detail(columns: MobileSplit.Columns, leading: CGFloat, hidden: Bool, wide: Bool) -> some View {
        let detail = MobileSplitDetail(navigator: navigator, content: composition.content, hostViews: composition.hostViews)
        if device == .pad {
            // Across the window whatever its width: a narrower stack centred the columns.
            detail
                .frame(width: wide ? leading + columns.tab : columns.tab)
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: hidden ? 0 : leading)
        } else {
            // The rest, not a set width: the probe measures what the columns are given, and a total wider than that
            // centred the row and clipped the sidebar's leading edge.
            detail
                .frame(maxWidth: .infinity)
                .padding(.leading, leading)
        }
    }

    /// `titleInBar`: the Duo's sidebar names its section in the bar's row, beside its controls, instead of the
    /// phone's large title on a second line (M2a, M3a): the sidebar sits beside a tab whose header is one row. An
    /// iPad's keeps the large title: its tab's header keeps the switch under it (`TabScreen.segmentInHeader`), and
    /// name, capsule and Edit in one row overflowed its 280-point sidebar.
    private func stack(path: Binding<[TabsRoute]>, titleInBar: Bool) -> some View {
        let narrow = titleInBar && MobileSplit.narrow(sidebar: columns.sidebar, device: device)
        return NavigationStack(path: path) {
            tabView
                .navigationTitle(section.title)
                .toolbarTitleDisplayMode(titleInBar ? .inline : .large)
                // The section's name is the leading item instead (the title stays the screen's name for VoiceOver).
                .toolbar(removing: titleInBar ? .title : nil)
                .toolbar {
                    if titleInBar {
                        ToolbarItem(placement: .topBarLeading) {
                            Text(section.title)
                                .font(narrow ? .headline : .title2.weight(.bold))
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                                .fixedSize()
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                    switch section {
                    case .spaces: SpacesToolbar(model: tabs, editing: $navigator.editing, capsuleTrailing: titleInBar, glyphEdit: narrow)
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
        let split = MobileSplit.applies(to: windowSize, device: device)
        let sidebar = columns.sidebar
        let narrow = split && MobileSplit.narrow(sidebar: sidebar, device: device)
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

extension View {
    /// The iPad's stack and sidebar column at a compact width, as `UISplitViewController` gives its own columns (its
    /// primary reports compact in a regular window): SwiftUI's `TabView` then draws the phone's bottom bar with New as
    /// its own glass circle. In a regular width it drew iPadOS's floating top bar, under the stack's large title, with
    /// New folded into a chevron. The phone's sizes are compact already and get nothing.
    @ViewBuilder func mobileCompactWidth(_ apply: Bool) -> some View {
        if apply { environment(\.horizontalSizeClass, .compact) } else { self }
    }

    /// The sheets' grabber: drawn on the phone, as the mockups' sheets (M7a, M8a, M9a) have it; none on an iPad, whose
    /// form sheets in the middle of the window carry none (they still swipe down), as the system's own do.
    func mobileSheetGrabber() -> some View {
        presentationDragIndicator(UIDevice.current.userInterfaceIdiom == .pad ? .hidden : .visible)
    }

    /// A sheet's detents on the phone (`[.medium, .large]`: half the screen, then all of it); none on an iPad, where
    /// detents made a card anchored to the window's bottom with the phone's grabber, its list cut by the screen's edge,
    /// instead of the system's form sheet in the middle that the other sheets are.
    @ViewBuilder func mobilePhoneDetents(_ detents: Set<PresentationDetent>) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad { self } else { presentationDetents(detents) }
    }

    /// On an iPad, a sheet that needs more than a form sheet's height (the host key questions: the message, the key's
    /// rows and two large buttons) as a page sheet, whose height is the window's; the phone's sheets are its height
    /// already.
    @ViewBuilder func mobileTallSheet() -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad { presentationSizing(.page) } else { self }
    }
}

#Preview("Spaces, first run") {
    let hosts = HostSessions.demo(empty: true)
    MobileRoot(composition: MobileComposition(hosts: hosts, tabs: MobileTabs(activity: TabActivityStore(url: nil),
                                                                             defaults: UserDefaults(suiteName: "preview")!)))
        .environment(hosts)
}
