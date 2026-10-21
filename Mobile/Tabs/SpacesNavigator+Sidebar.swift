import SwiftUI

/// The iPad split's sidebar (`MobileRoot`): the tab header's sidebar button and the app's Toggle Sidebar command
/// (⌃⌘S, `MobileCommands`) hide it so the tab takes the window, and show it again. An iPad keeps the tab the window
/// shows and whether the sidebar is hidden across launches, as iPadOS's own split views come back as they were left.
extension SpacesNavigator {
    /// The window shows a tab beside the sidebar (`MobileSplit`), so the sidebar can give it the window. The shell
    /// hides it on an iPad only (`sidebarHides`).
    var canToggleSidebar: Bool { split && splitPath.tab != nil }

    /// The sidebar is out of the way now: only ever while a tab is shown beside it.
    var sidebarIsHidden: Bool { canToggleSidebar && sidebarHidden }

    /// Hides the sidebar so the tab takes the window, or shows it again.
    /// Hides the sidebar so the tab takes the window, or shows it again. The state changes at once; the drawn state
    /// (`sidebarDrawnHidden`) follows it with the slide on the next turn, after the tab took its wider width in an
    /// update of its own: changed in the slide's animated update the width animated too (a resize every frame), and
    /// keeping it out with a transaction kept the slide's offset out as well (the tab jumped while the sidebar slid).
    /// The tab narrows again once the slide ends, unanimated.
    func toggleSidebar() {
        guard canToggleSidebar else { return }
        if !sidebarSliding { sidebarDrawnHidden = sidebarIsHidden }
        sidebarHidden.toggle()
        sidebarSlides += 1
        let slide = sidebarSlides
        sidebarSliding = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sidebarSlides == slide else { return }
            withAnimation(.smooth(duration: Self.sidebarSlide)) {
                self.sidebarDrawnHidden = self.sidebarIsHidden
            } completion: { [weak self] in
                guard let self, self.sidebarSlides == slide else { return }
                self.sidebarSliding = false
            }
        }
    }

    /// Where the sidebar is drawn (`MobileRoot`): during a slide its animated state, else the state itself.
    var sidebarShownHidden: Bool { sidebarSliding ? sidebarDrawnHidden : sidebarIsHidden }

    /// The sidebar comes back (⌘1, ⌘2, a section chosen): with the slide, as the button brings it.
    func showSidebar() {
        if sidebarIsHidden { toggleSidebar() } else { sidebarHidden = false }
    }

    /// The slide's length: the detail column keeps its wider width for it (`MobileRoot`), as the Mac's split does.
    static let sidebarSlide = 0.3

    static let shownTabKey = "tabs.shownTab", sidebarHiddenKey = "tabs.sidebarHidden"

    /// The launch's window on an iPad (`MobileRoot`, before its first frame): the split shows the tab it showed last
    /// time, with the sidebar as the user left it, if the host's cached topology still has that tab. Once a launch.
    func restoreSplit(splits: Bool) {
        guard !sidebarHides else { return }
        let tab = memory?.data(forKey: Self.shownTabKey).flatMap { try? JSONDecoder().decode(TabRef.self, from: $0) }
        let hidden = memory?.bool(forKey: Self.sidebarHiddenKey) ?? false
        sidebarHides = true
        split = splits
        // A window that stacks (Slide Over, a third) opens on the tab bar, as the phone does.
        guard splits, path.isEmpty, let tab, model.tab(tab) != nil else { return }
        path = [.tab(tab)]
        sidebarHidden = hidden
    }

    /// Keeps what `restoreSplit` brings back: the tab on screen (the detail column's, or the stack's top screen) and
    /// the sidebar's state. Only on an iPad (the phone opens on the tab bar).
    func rememberSplit() {
        guard sidebarHides, let memory else { return }
        let tab = split ? splitPath.tab : path.last?.tab
        if let tab, let data = try? JSONEncoder().encode(tab) {
            if memory.data(forKey: Self.shownTabKey) != data { memory.set(data, forKey: Self.shownTabKey) }
        } else if memory.object(forKey: Self.shownTabKey) != nil {
            memory.removeObject(forKey: Self.shownTabKey)
        }
        if memory.bool(forKey: Self.sidebarHiddenKey) != sidebarHidden { memory.set(sidebarHidden, forKey: Self.sidebarHiddenKey) }
    }
}
