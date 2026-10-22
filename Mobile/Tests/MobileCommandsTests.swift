import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// The app's commands (`MobileCommands`, docs/ios.md, Keyboard and menu bar): their chords, what each applies to in
/// the stack and in the split, and the moves they make, on the Spaces sample (`TabsSample`: three connected hosts, two
/// tabs that need the user and an unseen result). The menu bar's own cases run on an iPad only.
@MainActor
final class MobileCommandsTests: XCTestCase {
    private let mba2 = TabsSample.mba2.id, studio = TabsSample.studio.id, ai = TabsSample.ai.id

    private func navigator() -> SpacesNavigator { SpacesNavigator(model: TabsSample.model()) }
    private func tab(_ host: UUID, _ key: String) -> TabRef { TabRef(host: host, key: key) }
    private func space(_ host: UUID, _ key: String) -> SpaceRef { SpaceRef(host: host, key: key) }

    /// Every chord has ⌘ and means one command; the terminal claims none of them and no other ⌘ chord, so a focused
    /// terminal keeps Esc, Tab, Control, Option, arrows and function keys, and the app keeps ⌘.
    func testEveryChordHasCommandAndTheTerminalKeepsTheRest() throws {
        let chords = MobileCommand.allCases.compactMap(\.shortcut)
        XCTAssertEqual(chords.count, 20)
        for chord in chords { XCTAssertTrue(chord.modifiers.contains(.command), "\(chord.key.character)") }
        let names = MobileCommand.allCases.compactMap(\.chord)
        XCTAssertEqual(Set(names).count, names.count, "\(names)")
        XCTAssertEqual(MobileCommand.closeSpace.chord, "⇧⌘W")
        XCTAssertEqual(MobileCommand.newChat.chord, "⌥⌘N")
        XCTAssertEqual(MobileCommand.attach.chord, "⇧⌘A", "Mail's Attach Files…")
        XCTAssertEqual(MobileCommand.previousTab.chord, "⌘[")
        XCTAssertEqual(MobileCommand.toggleSidebar.chord, "⌃⌘S", "The Mac's")
        XCTAssertEqual(MobileCommand.toggleSidebarAlias.key, "\\")
        XCTAssertEqual(MobileCommand.toggleSidebarAlias.modifiers, .command)

        let controller = TerminalController(feed: ScriptedTerminalFeed(output: Data()), configuration: TerminalConfiguration())
        let terminal = try XCTUnwrap(controller.hostView.keyCommands)
        XCTAssertGreaterThan(terminal.count, 100)
        XCTAssertTrue(terminal.allSatisfy { !$0.modifierFlags.contains(.command) }, "The terminal claims no ⌘ chord")
        XCTAssertTrue(terminal.contains { $0.input == UIKeyCommand.inputEscape && $0.modifierFlags.isEmpty })
    }

    /// Each menu's items, in the Mac's order; every command is in exactly one.
    func testTheMenusFollowTheMac() {
        XCTAssertEqual(MobileCommand.groups(.file).map { $0.map(\.title) },
                       [["New Tab", "New Space…", "New Chat…", "New Host…"], ["Rename Tab…", "Rename Space…"],
                        ["Close Tab", "Close Space…", "Detach Space"]])
        XCTAssertEqual(MobileCommand.groups(.edit).joined().map(\.title), ["Clear Screen", "Attach Files…"])
        XCTAssertEqual(MobileCommand.groups(.view).joined().map(\.title),
                       ["Increase Font Size", "Decrease Font Size", "Reset Font Size", "Toggle Sidebar", "Switch Terminal / Chat"])
        XCTAssertEqual(MobileCommand.groups(.navigate).joined().map(\.title),
                       ["Spaces", "Agents", "Next Attention", "Previous Attention", "Previous Tab", "Next Tab"])
        let listed = MobileCommand.Menu.allCases.flatMap { menu in MobileCommand.groups(menu).joined().map { ($0, menu) } }
        XCTAssertEqual(listed.count, MobileCommand.allCases.count)
        for (command, menu) in listed { XCTAssertEqual(command.menu, menu, "\(command)") }
    }

    /// What is on screen: the stack's top screen; in the split the detail column's tab (not under its details) and
    /// the space of what the user last opened there.
    func testTheShownTabAndSpaceInTheStackAndTheSplit() {
        let navigator = navigator()
        let app = space(mba2, "herdr:app"), dev = tab(mba2, "herdr:app:2")
        XCTAssertNil(navigator.shownTab)
        XCTAssertNil(navigator.shownSpace)
        navigator.path = [.space(app)]
        XCTAssertNil(navigator.shownTab)
        XCTAssertEqual(navigator.shownSpace, app)
        navigator.path = [.space(app), .tab(dev)]
        XCTAssertEqual(navigator.shownTab, dev)
        XCTAssertEqual(navigator.shownSpace, app, "The tab's own space")
        navigator.path = [.space(app), .tab(dev), .details(app)]
        XCTAssertNil(navigator.shownTab, "Details are on top")
        XCTAssertEqual(navigator.shownSpace, app)

        navigator.split = true
        XCTAssertNil(navigator.shownTab, "The detail column shows details over the tab")
        navigator.path = [.space(space(studio, "tmux:docs")), .tab(dev)]
        XCTAssertEqual(navigator.shownTab, dev, "The detail column's tab")
        XCTAssertEqual(navigator.shownSpace, app, "Its space, not the sidebar's")
        navigator.path = [.space(space(studio, "tmux:docs"))]
        XCTAssertEqual(navigator.shownSpace, space(studio, "tmux:docs"), "No tab: the sidebar's space")
    }

    /// What applies where: the app-wide items always, a tab's and a space's with them on screen (the terminal's sent
    /// to the focused terminal), nothing while something is presented.
    func testWhatAppliesWhere() {
        let navigator = navigator()
        let always: Set<MobileCommand> = [.newTab, .newSpace, .newChat, .newHost, .spaces, .agents, .settings, .shortcuts,
                                          .nextAttention, .previousAttention]
        let terminal: Set<MobileCommand> = [.switchSegment, .clearScreen, .increaseFontSize, .decreaseFontSize, .resetFontSize]
        XCTAssertEqual(navigator.enabledCommands(presenting: false), always)
        XCTAssertEqual(navigator.enabledCommands(presenting: true), [], "A sheet is up")

        let docs = space(studio, "tmux:docs")
        navigator.path = [.space(docs)]
        XCTAssertEqual(navigator.enabledCommands(presenting: false).subtracting(always),
                       [.renameSpace, .closeSpace, .detachSpace])
        navigator.path = [.space(docs), .tab(tab(studio, "tmux:docs:@1"))]
        XCTAssertEqual(navigator.enabledCommands(presenting: false).subtracting(always),
                       terminal.union([.renameSpace, .closeSpace, .detachSpace, .renameTab, .closeTab, .previousTab, .nextTab,
                                       .attach]), "An agent's tab: Attach Files… for its chat")
        navigator.picking = true
        XCTAssertEqual(navigator.enabledCommands(presenting: false), [], "New tab's picker is up")
        navigator.picking = false
        navigator.actions.rename(.tab(tab(studio, "tmux:docs:@1")))
        XCTAssertEqual(navigator.enabledCommands(presenting: false), [], "Rename's dialog is up")
        navigator.actions.renaming = nil

        XCTAssertEqual(MobileCommand.increaseFontSize.terminalAction, #selector(UIResponderStandardEditActions.increaseSize(_:)))
        XCTAssertEqual(MobileCommand.clearScreen.terminalAction, NSSelectorFromString("clearScreen:"))
        XCTAssertEqual(MobileCommand.resetFontSize.terminalAction, NSSelectorFromString("resetFontSize:"))
        XCTAssertNil(MobileCommand.newTab.terminalAction)
    }

    /// A tab on a host that is not connected offers no request to it; a space with one tab has no neighbour to step to.
    func testADisconnectedHostAndALoneTab() {
        let model = TabsSample.model()
        let navigator = SpacesNavigator(model: model)
        let offline = MobileWorkspace(host: TabsFixtures.host, client: nil, activity: TabActivityStore(url: nil))
        offline.apply(TabsFixtures.app().topology)
        model.insert(offline)
        let shown = tab(TabsFixtures.host.id, "herdr:docs:1")
        navigator.path = [.tab(shown)]
        let enabled = navigator.enabledCommands(presenting: false)
        XCTAssertTrue(enabled.contains(.switchSegment))
        XCTAssertTrue(enabled.isDisjoint(with: [.renameTab, .closeTab, .renameSpace, .closeSpace, .detachSpace]), "\(enabled)")
        XCTAssertTrue(enabled.isDisjoint(with: [.previousTab, .nextTab]), "docs has one tab")
    }

    /// Previous and Next Tab step round the shown tab's space in place: the stack's top tab is replaced (Back still
    /// returns to the space), the split's detail column shows the neighbour.
    func testNextAndPreviousTabStepRoundTheSpaceInPlace() {
        let navigator = navigator()
        let app = space(mba2, "herdr:app")
        navigator.path = [.space(app), .tab(tab(mba2, "herdr:app:1"))]
        navigator.stepTab(1)
        XCTAssertEqual(navigator.path, [.space(app), .tab(tab(mba2, "herdr:app:2"))])
        navigator.stepTab(1)
        navigator.stepTab(1)
        XCTAssertEqual(navigator.path, [.space(app), .tab(tab(mba2, "herdr:app:1"))], "Round the end")
        navigator.stepTab(-1)
        XCTAssertEqual(navigator.path, [.space(app), .tab(tab(mba2, "herdr:app:3"))])

        navigator.split = true
        navigator.path = [.space(space(studio, "tmux:docs")), .tab(tab(mba2, "herdr:app:1"))]
        navigator.stepTab(-1)
        XCTAssertEqual(navigator.path, [.space(space(studio, "tmux:docs")), .tab(tab(mba2, "herdr:app:3"))],
                       "The sidebar keeps its space")
        navigator.path = [.space(app)]
        navigator.stepTab(1)
        XCTAssertEqual(navigator.path, [.space(app)], "No tab shown: nothing to step from")
    }

    /// Next Attention visits what needs the user first, then unseen results (the Mac's order), from the shown tab,
    /// round the end; it opens a tab running an agent on its Chat segment, in the shown tab's place.
    func testAttentionVisitsWhatNeedsTheUserThenUnseenResults() {
        let navigator = navigator()
        let order = [tab(mba2, "herdr:e2e:1"), tab(studio, "tmux:docs:@1"), tab(ai, "herdr:curves:1")]
        XCTAssertEqual(navigator.attentionTabs, order)
        navigator.attention(1)
        XCTAssertEqual(navigator.path, [.tab(order[0])], "From elsewhere: the first, pushed")
        XCTAssertEqual(navigator.model.segments[order[0]], .chat)
        navigator.attention(1)
        XCTAssertEqual(navigator.path, [.tab(order[1])], "In the shown tab's place")
        navigator.attention(1)
        navigator.attention(1)
        XCTAssertEqual(navigator.path, [.tab(order[0])], "Round the end")
        navigator.attention(-1)
        XCTAssertEqual(navigator.path, [.tab(order[2])])
        navigator.path = [.space(space(mba2, "herdr:app"))]
        navigator.attention(-1)
        XCTAssertEqual(navigator.path, [.space(space(mba2, "herdr:app")), .tab(order[2])], "From elsewhere back: the last")
        navigator.split = true
        navigator.attention(1)
        XCTAssertEqual(navigator.path, [.space(space(mba2, "herdr:app")), .tab(order[0])], "The split's detail column")
    }

    /// Toggle Sidebar (⌃⌘S) applies where the split can hide its sidebar: an iPad's, beside a tab. With the sidebar
    /// hidden, Spaces and Agents (⌘1 ⌘2) bring it back, and Previous and Next Tab, Next Attention and New Tab act on the
    /// tab that has the window, which keeps it.
    func testToggleSidebarAndTheCommandsWithTheSidebarHidden() {
        let navigator = navigator()
        let app = space(mba2, "herdr:app"), dev = tab(mba2, "herdr:app:2")
        navigator.split = true
        navigator.path = [.space(app), .tab(dev)]
        XCTAssertFalse(navigator.enabledCommands(presenting: false).contains(.toggleSidebar), "The Duo's split keeps its sidebar")
        navigator.sidebarHides = true
        XCTAssertTrue(navigator.enabledCommands(presenting: false).contains(.toggleSidebar))
        XCTAssertFalse(navigator.enabledCommands(presenting: true).contains(.toggleSidebar), "A sheet is up")
        navigator.split = false
        XCTAssertFalse(navigator.enabledCommands(presenting: false).contains(.toggleSidebar), "The stack has no sidebar")
        navigator.split = true
        navigator.path = [.space(app)]
        XCTAssertFalse(navigator.enabledCommands(presenting: false).contains(.toggleSidebar), "No tab: the sidebar is all there is")

        navigator.path = [.space(app), .tab(dev)]
        navigator.toggleSidebar()
        XCTAssertTrue(navigator.sidebarIsHidden)
        XCTAssertTrue(navigator.enabledCommands(presenting: false).isSuperset(of: [.toggleSidebar, .previousTab, .nextTab, .closeTab]))
        navigator.stepTab(1)
        XCTAssertEqual(navigator.shownTab, tab(mba2, "herdr:app:3"))
        XCTAssertTrue(navigator.sidebarIsHidden, "⌘]: the next tab takes the window as well")
        navigator.stepTab(-1)
        navigator.attention(1)
        XCTAssertEqual(navigator.shownTab, tab(mba2, "herdr:e2e:1"))
        XCTAssertTrue(navigator.sidebarIsHidden, "⌘J too")
        navigator.showRoot()
        XCTAssertFalse(navigator.sidebarIsHidden, "⌘1, ⌘2: the sidebar comes back with its tab bar")
        XCTAssertEqual(navigator.shownTab, tab(mba2, "herdr:e2e:1"), "The detail column keeps its tab")
        navigator.toggleSidebar()
        navigator.toggleSidebar()
        XCTAssertFalse(navigator.sidebarIsHidden)
    }

    /// Help › Keyboard Shortcuts lists Toggle Sidebar on an iPad only, where the split hides its sidebar.
    func testTheShortcutsSheetListsToggleSidebarOnAnIPad() {
        XCTAssertEqual(MobileShortcutsSheet.listed(.toggleSidebar), UIDevice.current.userInterfaceIdiom == .pad)
        XCTAssertTrue(MobileShortcutsSheet.listed(.closeTab))
        XCTAssertFalse(MobileShortcutsSheet.listed(.newHost), "No chord")
    }

    /// Spaces and Agents show the tab bar: the stack goes back to it; the split's sidebar does and keeps its tab.
    func testSectionsGoBackToTheTabBar() {
        let navigator = navigator()
        let shown = tab(mba2, "herdr:app:2")
        navigator.path = [.space(space(mba2, "herdr:app")), .tab(shown), .details(space(mba2, "herdr:app"))]
        navigator.showRoot()
        XCTAssertEqual(navigator.path, [])
        navigator.split = true
        navigator.path = [.space(space(mba2, "herdr:app")), .tab(shown)]
        navigator.showRoot()
        XCTAssertEqual(navigator.path, [.tab(shown)])
    }

    /// The menu bar the iPad shows (SwiftUI's commands in UIKit's main menu, read through its root menu): the app's
    /// items in the system's File, View and Help menus, Navigate before Window, no scene Close or Customize Toolbar,
    /// and each item's chord as the table has it.
    func testTheMenuBarHoldsTheCommands() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The menu bar is the iPad's") }
        let system = UIMainMenuSystem.shared
        let selector = NSSelectorFromString("_rootMenu")
        guard system.responds(to: selector), let root = system.perform(selector)?.takeUnretainedValue() as? UIMenu else {
            throw XCTSkip("UIKit no longer exposes its built main menu")
        }
        func elements(_ menu: UIMenu) -> [UIMenuElement] {
            menu.children.flatMap { child in (child as? UIMenu).map { $0.options.contains(.displayInline) ? elements($0) : [$0] } ?? [child] }
        }
        let menus = root.children.compactMap { $0 as? UIMenu }
        XCTAssertEqual(menus.map(\.title), ["Dispatch", "File", "Edit", "View", "Navigate", "Window", "Help"])
        for menu in MobileCommand.Menu.allCases {
            let items = try XCTUnwrap(menus.first { $0.title == menu.title }).map(elements) ?? []
            for command in MobileCommand.groups(menu).joined() {
                let item = items.first { $0.title == command.title }
                XCTAssertNotNil(item, "\(command.title) in \(menu.title)")
                if let shortcut = command.shortcut {
                    let key = try XCTUnwrap(item as? UIKeyCommand, command.title)
                    XCTAssertEqual(key.input, String(shortcut.key.character), command.title)
                    XCTAssertTrue(key.modifierFlags.contains(.command), command.title)
                }
            }
        }
        let all = menus.flatMap(elements)
        XCTAssertFalse(all.contains { $0.title == "Close" }, "The scene's Close gave ⌘W to Close Tab")
        XCTAssertFalse(all.contains { $0.title == "Customize Toolbar…" })
        let keys = all.compactMap { $0 as? UIKeyCommand }.filter { $0.input == "w" && $0.modifierFlags == .command }
        XCTAssertEqual(keys.map(\.title), ["Close Tab"])
    }

    /// The window turns every way on an iPad, as `UISupportedInterfaceOrientations~ipad` says; an iPhone keeps its
    /// three (never upside down).
    func testTheWindowTurnsEveryWayOnAnIPadOnly() throws {
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first)
        let orientations = UIApplication.shared.supportedInterfaceOrientations(for: window)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertEqual(orientations, .all)
        } else {
            XCTAssertEqual(orientations, .allButUpsideDown)
        }
    }
}
