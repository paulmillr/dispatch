import SwiftUI
import UIKit

/// The app's commands: iPadOS's menu bar and the ⌘ chords of a hardware keyboard, which the ⌘-hold overlay lists
/// (docs/ios.md, Keyboard and menu bar). They follow the Mac's menus (`Dispatch/AppDelegate+Menus.swift`) where the
/// phone has the same thing: the same titles and chords, the File, View and Navigate menus, Settings in the app menu
/// and Keyboard Shortcuts in Help. Every chord has ⌘: a focused terminal keeps Esc, Tab, Ctrl, Alt, arrows and
/// function keys (its own `UIKeyCommand`s), and it claims no ⌘ chord, so the two never meet.
enum MobileCommand: String, CaseIterable, Identifiable {
    case newTab, newSpace, newChat, newHost
    case renameTab, renameSpace, closeTab, closeSpace, detachSpace
    case clearScreen, attach, toggleSidebar, switchSegment, increaseFontSize, decreaseFontSize, resetFontSize
    case spaces, agents, previousTab, nextTab, nextAttention, previousAttention
    case settings, shortcuts

    var id: Self { self }

    enum Menu: CaseIterable {
        case app, file, edit, view, navigate, help
        var title: String {
            switch self {
            case .app: "Dispatch"
            case .file: "File"
            case .edit: "Edit"
            case .view: "View"
            case .navigate: "Navigate"
            case .help: "Help"
            }
        }
    }

    var menu: Menu {
        switch self {
        case .newTab, .newSpace, .newChat, .newHost, .renameTab, .renameSpace, .closeTab, .closeSpace, .detachSpace: .file
        case .clearScreen, .attach: .edit
        case .toggleSidebar, .switchSegment, .increaseFontSize, .decreaseFontSize, .resetFontSize: .view
        case .spaces, .agents, .previousTab, .nextTab, .nextAttention, .previousAttention: .navigate
        case .settings: .app
        case .shortcuts: .help
        }
    }

    /// The Mac's titles; an ellipsis where the phone asks for more first (a form, a name, a choice).
    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newSpace: "New Space…"
        case .newChat: "New Chat…"
        case .newHost: "New Host…"
        case .renameTab: "Rename Tab…"
        case .renameSpace: "Rename Space…"
        case .closeTab: "Close Tab"
        case .closeSpace: "Close Space…"
        case .detachSpace: "Detach Space"
        case .clearScreen: "Clear Screen"
        case .attach: "Attach Files…"
        case .toggleSidebar: "Toggle Sidebar"
        case .switchSegment: "Switch Terminal / Chat"
        case .increaseFontSize: "Increase Font Size"
        case .decreaseFontSize: "Decrease Font Size"
        case .resetFontSize: "Reset Font Size"
        case .spaces: "Spaces"
        case .agents: "Agents"
        case .previousTab: "Previous Tab"
        case .nextTab: "Next Tab"
        case .nextAttention: "Next Attention"
        case .previousAttention: "Previous Attention"
        case .settings: "Settings…"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .newTab: "plus.rectangle"
        case .newSpace: "plus.square.on.square"
        case .newChat: "square.and.pencil"
        case .newHost: "display"
        case .renameTab, .renameSpace: "pencil"
        case .closeTab: "xmark"
        case .closeSpace: "xmark.square"
        case .detachSpace: "eject"
        case .clearScreen: "clear"
        case .attach: "paperclip"
        case .toggleSidebar: "sidebar.leading"
        case .switchSegment: "arrow.left.arrow.right"
        case .increaseFontSize: "textformat.size.larger"
        case .decreaseFontSize: "textformat.size.smaller"
        case .resetFontSize: "textformat.size"
        case .spaces: MobileSection.spaces.symbol
        case .agents: MobileSection.agents.symbol
        case .previousTab: "chevron.left"
        case .nextTab: "chevron.right"
        case .nextAttention: "bell.badge"
        case .previousAttention: "bell"
        case .settings: "gearshape"
        case .shortcuts: "keyboard"
        }
    }

    /// The chord: the Mac's (⌘T, ⌘N, ⌘W, ⇧⌘W, ⌘K, ⌃⌘S, ⇧⌘C, ⌘+ ⌘- ⌘0, ⌘[ ⌘], ⌘J ⇧⌘J, ⌘, and ⌘/). New Chat takes ⌥⌘N, which the
    /// Mac leaves free (its ⇧⌘N is New Local Space); ⌘1 and ⌘2 select the tab bar's sections, as iPad apps number
    /// their sidebar's; Attach Files… takes Mail's ⇧⌘A. Renames, Detach and New Host have none, as on the Mac.
    var shortcut: KeyboardShortcut? {
        switch self {
        case .newTab: KeyboardShortcut("t")
        case .newSpace: KeyboardShortcut("n")
        case .newChat: KeyboardShortcut("n", modifiers: [.command, .option])
        case .closeTab: KeyboardShortcut("w")
        case .closeSpace: KeyboardShortcut("w", modifiers: [.command, .shift])
        case .clearScreen: KeyboardShortcut("k")
        case .attach: KeyboardShortcut("a", modifiers: [.command, .shift])
        case .toggleSidebar: KeyboardShortcut("s", modifiers: [.command, .control])
        case .switchSegment: KeyboardShortcut("c", modifiers: [.command, .shift])
        case .increaseFontSize: KeyboardShortcut("+")
        case .decreaseFontSize: KeyboardShortcut("-")
        case .resetFontSize: KeyboardShortcut("0")
        case .spaces: KeyboardShortcut("1")
        case .agents: KeyboardShortcut("2")
        case .previousTab: KeyboardShortcut("[")
        case .nextTab: KeyboardShortcut("]")
        case .nextAttention: KeyboardShortcut("j")
        case .previousAttention: KeyboardShortcut("j", modifiers: [.command, .shift])
        case .settings: KeyboardShortcut(",")
        case .shortcuts: KeyboardShortcut("/")
        case .newHost, .renameTab, .renameSpace, .detachSpace: nil
        }
    }

    /// Toggle Sidebar's second chord, ⌘\, hidden on the Mac (`AppDelegate+Menus`): the shell takes it (`MobileCommandHost`).
    static let toggleSidebarAlias = KeyboardShortcut("\\")

    /// The action a terminal command sends down the responder chain: the focused terminal answers it
    /// (`TerminalHostView`'s `clearScreen(_:)`, `increaseSize(_:)`, `decreaseSize(_:)`, `resetFontSize(_:)`, which
    /// size it, save the size where a pinch and Settings do, and refuse past the bounds); nil for the other commands.
    var terminalAction: Selector? {
        switch self {
        case .clearScreen: #selector(MobileTerminalActions.clearScreen(_:))
        case .increaseFontSize: #selector(UIResponderStandardEditActions.increaseSize(_:))
        case .decreaseFontSize: #selector(UIResponderStandardEditActions.decreaseSize(_:))
        case .resetFontSize: #selector(MobileTerminalActions.resetFontSize(_:))
        default: nil
        }
    }

    /// The groups a menu separates its items into, in order.
    static func groups(_ menu: Menu) -> [[MobileCommand]] {
        switch menu {
        case .app: [[.settings]]
        case .file: [[.newTab, .newSpace, .newChat, .newHost], [.renameTab, .renameSpace], [.closeTab, .closeSpace, .detachSpace]]
        case .edit: [[.clearScreen], [.attach]]
        case .view: [[.increaseFontSize, .decreaseFontSize, .resetFontSize], [.toggleSidebar, .switchSegment]]
        case .navigate: [[.spaces, .agents], [.nextAttention, .previousAttention], [.previousTab, .nextTab]]
        case .help: [[.shortcuts]]
        }
    }

    /// "⇧⌘W": the chord as the menu bar and the Mac print it.
    var chord: String? {
        guard let shortcut else { return nil }
        let modifiers = shortcut.modifiers
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + String(shortcut.key.character).uppercased()
    }
}

/// What the commands act on: the shell's state as the menu bar reads it (which items apply) and the way to perform one.
/// The shell publishes it for the scene (`mobileCommands`), so the menu bar follows the stack and the split alike.
struct MobileCommandTarget {
    var enabled: Set<MobileCommand>
    var perform: @MainActor (MobileCommand) -> Void
}

extension FocusedValues {
    @Entry var mobileCommands: MobileCommandTarget?
}

/// The menu bar (`WindowGroup.commands`): the system's menus with the app's items in them, and Navigate. Items that do
/// not apply where the user is are disabled, so a chord does nothing rather than acting on something unseen.
struct MobileCommands: Commands {
    @FocusedValue(\.mobileCommands) private var target

    var body: some Commands {
        let file = MobileCommand.groups(.file), view = MobileCommand.groups(.view)
        CommandGroup(replacing: .appSettings) { items(.app) }
        CommandGroup(replacing: .newItem) { group(file[0]) }
        // The system's groups are the menu's sections (a Divider inside a group does not separate on iPadOS, and a
        // group before or after a replaced one is dropped). The scene's Close (⌘W, which would close the app's one
        // window) gives way to the renames, and Close Tab takes its chord.
        CommandGroup(replacing: .saveItem) { group(file[1]) }
        CommandGroup(replacing: .importExport) { group(file[2]) }
        // Bold, italic and fonts are not something the app's text has.
        CommandGroup(replacing: .textFormatting) {}
        CommandGroup(after: .pasteboard) { items(.edit) }
        // In place of Customize Toolbar…: the app's toolbars are fixed.
        CommandGroup(replacing: .toolbar) { group(view[0]) }
        CommandGroup(replacing: .sidebar) { group(view[1]) }
        CommandMenu(MobileCommand.Menu.navigate.title) { items(.navigate) }
        CommandGroup(replacing: .help) { items(.help) }
    }

    @ViewBuilder private func items(_ menu: MobileCommand.Menu) -> some View {
        let groups = MobileCommand.groups(menu)
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            group(groups[index])
        }
    }

    private func group(_ commands: [MobileCommand]) -> some View {
        ForEach(commands) { command in
            Button(command.title, systemImage: command.symbol) { target?.perform(command) }
                .keyboardShortcut(command.shortcut)
                .disabled(target?.enabled.contains(command) != true)
        }
    }
}

extension View {
    /// The shell's side of the commands (`MobileRoot`): publishes what they act on and presents what they open that
    /// the shell does not (Close Space's choice, Keyboard Shortcuts).
    func mobileCommands(_ composition: MobileComposition, section: Binding<MobileSection>, sheet: Binding<MobileSheet?>) -> some View {
        modifier(MobileCommandHost(composition: composition, section: section, sheet: sheet))
    }
}

private struct MobileCommandHost: ViewModifier {
    let composition: MobileComposition
    @Binding var section: MobileSection
    @Binding var sheet: MobileSheet?
    @State private var closingSpace: SpaceRef?
    @State private var shortcuts = false

    private var navigator: SpacesNavigator { composition.navigator }

    /// The shell presents something (the navigator knows its own): the items wait, as a chord would act under the
    /// sheet or dialog.
    private var presenting: Bool { sheet != nil || shortcuts || closingSpace != nil }

    func body(content: Content) -> some View {
        let enabled = navigator.enabledCommands(presenting: presenting)
        content
            .focusedSceneValue(\.mobileCommands, MobileCommandTarget(enabled: enabled, perform: { command in
                // Checked again when it runs: a chord can arrive before the menu bar has redrawn.
                guard navigator.enabledCommands(presenting: presenting)
                    .contains(command) else { return }
                perform(command)
            }))
            .alert(closingSpace.flatMap { navigator.model.space($0) }.map { "Close “\($0.name)”" } ?? "Close space",
                   isPresented: Binding(get: { closingSpace != nil }, set: { if !$0 { closingSpace = nil } }),
                   presenting: closingSpace) { ref in
                Button("Detach") { navigator.actions.close(.space(ref), .detach) }
                Button("Terminate…", role: .destructive) { navigator.actions.close(.space(ref), .terminate) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(SpaceDetailsScreen.closeMessage)
            }
            .sheet(isPresented: $shortcuts) {
                MobileShortcutsSheet().tint(.dispatchPink)
            }
            .background {
                // ⌘\, the Mac's hidden alias of Toggle Sidebar: SwiftUI's commands have no hidden item, so a view's
                // shortcut without a title (no menu item, nothing in the ⌘-hold overlay) takes it.
                Button(action: { if enabled.contains(.toggleSidebar) { perform(.toggleSidebar) } }) { EmptyView() }
                    .keyboardShortcut(MobileCommand.toggleSidebarAlias)
                    .disabled(!enabled.contains(.toggleSidebar))
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }

    private func perform(_ command: MobileCommand) {
        switch command {
        case .newTab: navigator.newTabHere()
        case .newSpace: navigator.newSpace = NewSpaceRequest(host: navigator.shownSpace?.host ?? navigator.model.recentSpace?.ref.host)
        case .newChat: sheet = .newChat
        case .newHost: sheet = .newHost
        case .renameTab: if let tab = navigator.shownTab { navigator.actions.rename(.tab(tab)) }
        case .renameSpace: if let space = navigator.shownSpace { navigator.actions.rename(.space(space)) }
        case .closeTab: if let tab = navigator.shownTab { navigator.actions.close(.tab(tab), .close) }
        case .closeSpace:
            // A Shell space (plain SSH) closes its shells, asking while one is live; no Detach or Terminate.
            if let ref = navigator.shownSpace, navigator.model.space(ref)?.kind == .plainShell {
                navigator.actions.close(.space(ref), .close)
            } else {
                closingSpace = navigator.shownSpace
            }
        case .detachSpace: if let space = navigator.shownSpace { navigator.actions.close(.space(space), .detach) }
        case .toggleSidebar: navigator.toggleSidebar()
        case .switchSegment: if let tab = navigator.shownTab { TabSegment.requestSwitch(tab) }
        // The chat composer on screen opens its file picker (when its helper takes attachments).
        case .attach: NotificationCenter.default.post(name: CodeComposer.attachRequested, object: nil)
        case .clearScreen, .increaseFontSize, .decreaseFontSize, .resetFontSize:
            if let action = command.terminalAction { UIApplication.shared.sendAction(action, to: nil, from: nil, for: nil) }
        case .spaces, .agents:
            section = command == .spaces ? .spaces : .agents
            navigator.showRoot()
        case .previousTab: navigator.stepTab(-1)
        case .nextTab: navigator.stepTab(1)
        case .nextAttention: navigator.attention(1)
        case .previousAttention: navigator.attention(-1)
        case .settings: sheet = .settings
        case .shortcuts: shortcuts = true
        }
    }
}

/// The terminal's own actions the menu sends (`TerminalHostView`), named here so the menu needs no terminal type.
@objc protocol MobileTerminalActions {
    func clearScreen(_ sender: Any?)
    func resetFontSize(_ sender: Any?)
}

extension TabSegment {
    /// Switch Terminal / Chat (⇧⌘C) for a tab: its screen (`TabScreen`) flips its segment, as a tap on the other one.
    static let switchRequested = Notification.Name("DispatchMobileTabSegmentSwitch")

    @MainActor static func requestSwitch(_ tab: TabRef) {
        NotificationCenter.default.post(name: switchRequested, object: nil, userInfo: ["tab": tab])
    }

    /// The tab a switch request names.
    static func switchRequest(_ note: Notification) -> TabRef? { note.userInfo?["tab"] as? TabRef }
}

/// Help › Keyboard Shortcuts (⌘/): every command with its chord, by menu, and what the terminal keeps, as the Mac's
/// shortcuts sheet lists its own. The ⌘-hold overlay shows the same commands.
struct MobileShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(MobileCommand.Menu.allCases.filter { $0 != .app && $0 != .help }, id: \.self) { menu in
                    Section(menu.title) {
                        ForEach(MobileCommand.groups(menu).joined().filter(Self.listed)) { row($0.title, $0.chord ?? "") }
                    }
                }
                Section("App") {
                    row(MobileCommand.settings.title, MobileCommand.settings.chord ?? "")
                    row(MobileCommand.shortcuts.title, MobileCommand.shortcuts.chord ?? "")
                }
                Section {
                    row("Copy, Paste", "⌘C ⌘V")
                } header: {
                    Text("In the terminal")
                } footer: {
                    Text("A terminal keeps every key without ⌘: Esc, Tab, Control and Option chords, the arrows and the function keys go to the program running in it.")
                }
            }
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    /// The commands with a chord; Toggle Sidebar on an iPad only (the Duo's split keeps its sidebar).
    static func listed(_ command: MobileCommand) -> Bool {
        command.chord != nil && (command != .toggleSidebar || UIDevice.current.userInterfaceIdiom == .pad)
    }

    private func row(_ title: String, _ chord: String) -> some View {
        LabeledContent(title) {
            Text(chord).font(.body.monospaced()).foregroundStyle(.secondary)
        }
    }
}



