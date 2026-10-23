import Foundation

/// What the app's commands (`MobileCommands`: the menu bar and ⌘ chords) need from the navigator: what is on screen,
/// in the stack and in the split alike, and the moves the Mac's Navigate menu makes.
extension SpacesNavigator {
    /// The tab whose screen is on top: the stack's top screen, or the split's detail column with nothing pushed over it.
    var shownTab: TabRef? {
        if split {
            let shown = splitPath
            return shown.detail.isEmpty ? shown.tab : nil
        }
        return path.last?.tab
    }

    /// The tab Close Tab (⌘W) closes: the shown tab; on an iPad's strip its selected pill, also under a mode's
    /// pushed screen, as the pill's × does.
    var closableTab: TabRef? {
        if sidebarHides, split, let tab = splitPath.tab, model.tab(tab) != nil { return tab }
        return shownTab
    }

    /// The space of the screen on top: the shown tab's, or a space's tabs. In the split the detail column
    /// counts first, where the user last opened something.
    var shownSpace: SpaceRef? {
        let top: TabsRoute?
        if split {
            let shown = splitPath
            top = shown.detail.last ?? shown.tab.map { .tab($0) } ?? shown.sidebar.last
        } else {
            top = path.last
        }
        switch top {
        case .tab(let ref)?, .files(let ref, _)?: return model.tab(ref)?.space
        case .space(let ref)?: return ref
        case .host?, .detached?, nil: return nil
        }
    }

    /// A Spaces sheet or dialog is up (New tab's picker, New space, the switcher, Rename, Terminate, a failure).
    var presenting: Bool {
        picking || newSpace != nil || actions.renaming != nil || actions.terminating != nil || switcher != nil
            || actions.closingShells != nil || actions.failure != nil
    }

    /// The commands that apply now. Nothing applies while something is presented (`presenting`: the shell's sheets,
    /// besides the navigator's own); a tab's and a space's items need them on screen and their host connected (a
    /// request to a host that is not would only fail). A plain host's shells are the phone's own: Close Tab and Close
    /// Space need no connection, and they have no Rename or Detach. The terminal's (Find on its Terminal segment, Clear Screen, the font sizes) need a tab shown
    /// (Find on an agent's Chat segment searches its conversation):
    /// its terminal answers them when it has the focus, and refuses a size past its bounds. Attach Files… needs an agent's
    /// tab on a connected host: its chat composer opens the picker when its helper takes attachments.
    func enabledCommands(presenting: Bool) -> Set<MobileCommand> {
        guard !presenting, !self.presenting else { return [] }
        var enabled: Set<MobileCommand> = [.newChat, .newHost, .spaces, .agents, .settings, .shortcuts]
        if !model.workspaces.isEmpty { enabled.formUnion([.newTab, .newSpace]) }
        if let tab = shownTab.flatMap(model.tab) {
            enabled.formUnion([.clearScreen, .increaseFontSize, .decreaseFontSize, .resetFontSize])
            // Find searches what the tab shows: on the Terminal segment the terminal (or its search field answers
            // `find(_:)`), on the Chat segment of an agent's tab its conversation (`findsInChat`, C1).
            let segment = shownSegment(tab)
            if segment == .terminal || (segment == .chat && tab.isChat) {
                enabled.formUnion([.find, .findNext, .findPrevious])
            }
            // The Files modes where the strip offers them (`PadMode.available`): Files where the host serves it, Review
            // and Commits inside a repository.
            let modes = model.modes(tab, facts: gitFacts).available
            if modes.contains(.files) { enabled.insert(.switchFiles) }
            if modes.contains(.review) { enabled.formUnion([.reviewChanges, .commits]) }
            if tab.isShell {
                enabled.insert(.closeTab)
            } else {
                enabled.insert(.switchSegment)
                if connected(tab.ref.host) { enabled.formUnion([.renameTab, .closeTab]) }
                if connected(tab.ref.host), tab.isChat { enabled.insert(.attach) }
            }
            if (model.space(tab.space)?.tabs.count ?? 0) > 1 { enabled.formUnion([.previousTab, .nextTab]) }
        }
        if let ref = shownSpace, let space = model.space(ref) {
            if space.kind == .plainShell {
                if !space.tabs.isEmpty { enabled.insert(.closeSpace) }
            } else if connected(ref.host) {
                enabled.formUnion([.renameSpace, .closeSpace, .detachSpace])
            }
        }
        if let ref = closableTab, ref != shownTab, let tab = model.tab(ref), tab.isShell || connected(ref.host) {
            enabled.insert(.closeTab)
        }
        if !attentionTabs.isEmpty { enabled.formUnion([.nextAttention, .previousAttention]) }
        if sidebarHides && canToggleSidebar { enabled.insert(.toggleSidebar) }
        return enabled
    }

    /// The segment the shown tab is on.
    func shownSegment(_ tab: MobileTab) -> TabSegment {
        let segment = model.segments[tab.ref] ?? TabSegment.initial(for: tab)
        return tab.isShell && segment != .files ? .terminal : segment
    }

    /// Find, Find Next and Find Previous go to the conversation's search: the shown tab is on its Chat segment.
    var findsInChat: Bool {
        guard let tab = shownTab.flatMap(model.tab) else { return false }
        return tab.isChat && shownSegment(tab) == .chat
    }

    private func connected(_ host: UUID) -> Bool { model.workspace(host)?.client != nil }

    /// New Tab (⌘T): as the Mac's, in the space on screen (a shell in a plain host's Shell space); elsewhere as the tab
    /// bar's New (the most recent space, else the space picker).
    func newTabHere() {
        if let ref = shownSpace, let space = model.space(ref), model.workspace(ref.host)?.canAddTab(to: space) == true {
            newTab(in: space)
        } else {
            newTabFromBar()
        }
    }

    /// Spaces (⌘1) and Agents (⌘2) show the tab bar: the stack goes back to it; the split's sidebar does (and comes
    /// back if it was hidden), and the detail column keeps its tab.
    func showRoot() {
        if split {
            setSidebar([])
            showSidebar()
        } else {
            path = []
        }
    }

    /// Previous and Next Tab (⌘[ ⌘]): the shown tab's neighbour in its space, round the end, as the Mac's cycle.
    func stepTab(_ delta: Int) {
        guard let ref = shownTab, let tab = model.tab(ref), let tabs = model.space(tab.space)?.tabs, tabs.count > 1,
              let index = tabs.firstIndex(where: { $0.ref == ref }) else { return }
        replaceShown(with: tabs[(index + delta % tabs.count + tabs.count) % tabs.count].ref)
    }

    /// The tabs Next Attention visits, in the Mac's order: those that need the user, then unseen results, each in the
    /// Spaces tree's order (hosts, then their spaces and tabs).
    var attentionTabs: [TabRef] {
        let tabs = model.workspaces.flatMap { model.orderedSpaces($0).flatMap(\.tabs) }
        return tabs.filter { model.urgency(of: $0) == .needsYou }.map(\.ref)
            + tabs.filter { model.urgency(of: $0) == .unseen }.map(\.ref)
    }

    /// Next and Previous Attention (⌘J ⇧⌘J): the tab after (or before) the shown one among `attentionTabs`, the first
    /// (or last) from elsewhere, on its Chat segment when an agent runs there (what needs the user is its chat).
    func attention(_ delta: Int) {
        let tabs = attentionTabs
        guard !tabs.isEmpty else { return }
        let next = shownTab.flatMap { tabs.firstIndex(of: $0) }.map { (($0 + delta) % tabs.count + tabs.count) % tabs.count }
            ?? (delta < 0 ? tabs.count - 1 : 0)
        let ref = tabs[next]
        if model.tab(ref)?.isChat == true { model.segments[ref] = .chat }
        replaceShown(with: ref)
    }

    /// Another tab in the shown one's place: the split's detail column, or the stack's top tab screen (Back still
    /// returns where that tab was opened from); pushed over anything else.
    private func replaceShown(with ref: TabRef) {
        if let tab = model.tab(ref) { model.visited(tab.space) }
        if split {
            select(ref)
        } else if path.last?.tab != nil {
            path[path.count - 1] = .tab(ref)
        } else {
            path.append(.tab(ref))
        }
    }
}
