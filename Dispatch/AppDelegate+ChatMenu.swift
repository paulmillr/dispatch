import AppKit

/// The menu bar's Chat menu: the composer's actions with their keys, for the chat the active pane shows, so menus and
/// Help search find them. Each is enabled only while that chat shows and the action can run. The composer handles
/// its own keys first (`ChatComposer.ComposerTextView`); these reach the chat from anywhere in its pane.
@MainActor
final class ChatMenu: NSObject, NSMenuItemValidation {
    static let shared = ChatMenu()

    /// Adds the Chat menu to `main`, after `after` (the View menu).
    static func add(to main: NSMenu, after: NSMenu) {
        let item = NSMenuItem(title: "Chat", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Chat")
        item.submenu = menu
        let index = main.items.firstIndex { $0.submenu === after }.map { $0 + 1 } ?? main.items.count
        main.insertItem(item, at: index)
        func add(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = shared
            menu.addItem(entry)
        }
        add("Allow Once", #selector(allowOnce), "\r", [.command, .shift])
        add("Deny", #selector(deny), "\u{8}", [.command, .shift])
        menu.addItem(.separator())
        add("Stop Agent", #selector(stop))
        menu.addItem(.separator())
        add("Editor Mode", #selector(toggleEditor), "e")
        add("Save Draft", #selector(saveDraft), "s")
        add("Attach Files…", #selector(attach), "A", [.command, .shift])
        menu.addItem(.separator())
        add("Choose Model…", #selector(chooseModel), "M", [.command, .shift])
        add("Choose Effort…", #selector(chooseEffort), "E", [.command, .shift])
        menu.addItem(.separator())
        add("Agent Commands", #selector(commands))
        add("Ask on the Side…", #selector(askOnTheSide))
    }

    private var chat: ChatCoordinator { TerminalRuntime.shared.chat }

    /// The chat the key window's active pane shows; nil while it shows its terminal or files.
    var session: ChatSession? {
        guard let workspace = TerminalRuntime.shared.workspace, let window = NSApp.keyWindow, window === NSApp.mainWindow,
              let id = workspace.activeSurfaceID, let session = chat.sessions[id], session.showChat,
              !TerminalRuntime.shared.files.isShowing(id) else { return nil }
        return session
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let session else {
            if item.action == #selector(toggleEditor) { item.state = .off }
            return false
        }
        switch item.action {
        case #selector(allowOnce), #selector(deny): return chat.canAnswerPermission(session)
        case #selector(stop): return chat.canInterrupt(session)
        case #selector(toggleEditor):
            item.state = session.drafts.shape.multiline ? .on : .off
            return session.sideConversation == nil
        case #selector(saveDraft): return !session.drafts.current.isEmpty
        case #selector(attach): return chat.canAttach(session)
        case #selector(chooseModel), #selector(chooseEffort): return chat.canPickModel(session) && !session.drafts.shape.multiline
        case #selector(commands): return session.drafts.shape.isEmpty && session.sideConversation == nil
        case #selector(askOnTheSide):
            return session.drafts.shape.isEmpty && session.sideConversation == nil && session.helperCommands.contains("/btw")
        default: return true
        }
    }

    @objc func allowOnce() { if let session { chat.answerPermission(session, allow: true) } }
    @objc func deny() { if let session { chat.answerPermission(session, allow: false) } }
    @objc func stop() { if let session { chat.interrupt(session) } }
    @objc func toggleEditor() {
        guard let session else { return }
        session.drafts.edit(multiline: !session.drafts.current.multiline)
        session.focusRequest = System.uuid()
    }
    @objc func saveDraft() { session?.drafts.keep() }
    @objc func attach() {
        guard let session else { return }
        ChatAttachButton.choose(session: session, coordinator: chat, window: NSApp.keyWindow)
    }
    @objc func chooseModel() { if let session { chat.openModelPicker(session, column: .model) } }
    @objc func chooseEffort() { if let session { chat.openModelPicker(session, column: .effort) } }
    /// Types "/" into the empty composer: the agent's commands list opens.
    @objc func commands() { start("/") }
    /// Types "/btw " into the empty composer: the question after it opens a read-only side conversation.
    @objc func askOnTheSide() { start("/btw ") }

    private func start(_ text: String) {
        guard let session, session.drafts.shape.isEmpty else { return }
        session.drafts.edit(text: text, selection: NSRange(location: text.utf16.count, length: 0))
        session.commandSelection = 0
        session.focusRequest = System.uuid()
    }
}
