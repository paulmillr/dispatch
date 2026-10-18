import AppKit
import XCTest
@testable import DispatchApp

/// A tab's mode (terminal, chat, files) as the strip button, the menus and chat's own switches change it.
/// Window-less: coordinators only, no views.
@MainActor
final class FilesModeTests: XCTestCase {
    @MainActor private struct Fixture {
        let chat: ChatCoordinator
        let files: FilesCoordinator
        let id: UUID
        var session: ChatSession { chat.session(for: id) }
    }

    /// A stand-alone chat paired with its own files; `agent` makes chat enterable on the tab.
    private func fixture(agent: Bool) -> Fixture {
        let chat = ChatCoordinator(enabled: true, draftRepository: ChatDraftRepository(store: ChatDraftMemoryStore()), defaults: nil)
        let files = FilesCoordinator { [weak chat] in chat }
        chat.pairedFiles = files
        let id = System.uuid()
        if agent {
            let session = chat.session(for: id)
            session.helper = HelperChat(terminal: 0); session.sessionID = "files-mode"; session.active = true
        }
        addTeardownBlock { @MainActor in chat.close(id) }
        return Fixture(chat: chat, files: files, id: id)
    }

    private func state(_ dialog: String? = nil) -> HelperChat.State {
        .init(busy: false, activity: "idle", model: nil, model_label: nil, effort: nil, usage: nil, goal: nil, draft: nil,
              attention: nil, dialog: dialog, title: nil, compacting: false, service_tier: nil)
    }

    private func assertExclusive(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(fixture.files.isShowing(fixture.id) && fixture.chat.sessions[fixture.id]?.showChat == true,
                       "Files and chat never show together", file: file, line: line)
    }

    func testClickGoesTerminalChatTerminalOnATabWithAnAgent() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        XCTAssertEqual(files.mode(for: id), .terminal)
        XCTAssertEqual(files.nextMode(id), .chat)
        files.cycle(id)
        XCTAssertEqual(files.mode(for: id), .chat)
        XCTAssertTrue(fixture.session.showChat); XCTAssertTrue(fixture.session.manualViewChoice)
        // From chat a click returns to the terminal; files is the menu's, a hold's or ⇧⌘F's step.
        XCTAssertEqual(files.nextMode(id), .terminal)
        files.cycle(id)
        XCTAssertEqual(files.mode(for: id), .terminal)
        XCTAssertFalse(fixture.session.showChat)
        files.switchMode(id, to: .chat)
        files.toggleFiles(id)
        XCTAssertEqual(files.mode(for: id), .files)
        XCTAssertFalse(fixture.session.showChat, "Files hides chat")
        assertExclusive(fixture)
        XCTAssertEqual(files.nextMode(id), .terminal)
        files.cycle(id)
        XCTAssertEqual(files.mode(for: id), .terminal)
        XCTAssertFalse(files.isShowing(id)); XCTAssertFalse(fixture.session.showChat)
    }

    func testCycleTogglesTerminalAndFilesWithoutAnAgent() {
        let fixture = fixture(agent: false), files = fixture.files, id = fixture.id
        XCTAssertFalse(files.chatAvailable(id))
        XCTAssertEqual(files.nextMode(id), .files)
        let request = files.session(for: id).focusRequest
        files.cycle(id)
        XCTAssertEqual(files.mode(for: id), .files)
        XCTAssertNotEqual(files.session(for: id).focusRequest, request, "Entering files asks its view for the keyboard")
        files.cycle(id)
        XCTAssertEqual(files.mode(for: id), .terminal)
        files.cycle(id)
        XCTAssertEqual(files.mode(for: id), .files, "Without an agent the button never stops at chat")
    }

    func testToggleFilesFromEveryMode() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        files.toggleFiles(id)
        XCTAssertEqual(files.mode(for: id), .files, "Terminal → files")
        files.toggleFiles(id)
        XCTAssertEqual(files.mode(for: id), .terminal, "Files → terminal")
        files.switchMode(id, to: .chat)
        files.toggleFiles(id)
        XCTAssertEqual(files.mode(for: id), .files, "Chat → files")
        XCTAssertFalse(fixture.session.showChat)
        assertExclusive(fixture)
    }

    func testToggleChatGoesToChatFromEveryMode() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        files.toggleChat(id)
        XCTAssertEqual(files.mode(for: id), .chat, "Terminal → chat")
        files.toggleChat(id)
        XCTAssertEqual(files.mode(for: id), .terminal, "Chat → terminal")
        files.switchMode(id, to: .files)
        files.toggleChat(id)
        XCTAssertEqual(files.mode(for: id), .chat, "Files → chat, not the terminal")
        XCTAssertFalse(files.isShowing(id))
        assertExclusive(fixture)

        let plain = self.fixture(agent: false)
        plain.files.switchMode(plain.id, to: .files)
        plain.files.toggleChat(plain.id)
        XCTAssertEqual(plain.files.mode(for: plain.id), .files, "No agent: ⇧⌘C has no chat to show and leaves files")
    }

    func testEnteringFilesHidesChatAndChatHidesFiles() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        files.switchMode(id, to: .chat)
        files.switchMode(id, to: .files)
        XCTAssertTrue(files.isShowing(id)); XCTAssertFalse(fixture.session.showChat)
        XCTAssertEqual(fixture.session.viewTransitions.last?.reason, "files")
        files.switchMode(id, to: .chat)
        XCTAssertFalse(files.isShowing(id)); XCTAssertTrue(fixture.session.showChat)
        files.switchMode(id, to: .terminal)
        XCTAssertEqual(files.mode(for: id), .terminal)
    }

    func testModeForPrefersFilesAndDefaultsToTheTerminal() {
        let fixture = fixture(agent: true), files = fixture.files
        let unknown = System.uuid()
        XCTAssertEqual(files.mode(for: unknown), .terminal)
        XCTAssertNil(files.existing(unknown), "Asking for the mode creates no session")
        fixture.session.showChat = true
        XCTAssertEqual(files.mode(for: fixture.id), .chat)
        // Should showChat ever be set behind a visible files view, files stays in front.
        files.session(for: fixture.id).visible = true
        XCTAssertEqual(files.mode(for: fixture.id), .files)
        files.forget(fixture.id)
        XCTAssertEqual(files.mode(for: fixture.id), .chat)
    }

    func testAutomaticDiscoveryLeavesFilesButAnExplicitChoiceHidesThem() {
        let fixture = fixture(agent: true), files = fixture.files, chat = fixture.chat, id = fixture.id
        let session = fixture.session
        files.switchMode(id, to: .files)
        chat.receiveHelper(.state(state()), session: session)
        XCTAssertTrue(session.active)
        XCTAssertFalse(session.showChat, "Discovery's automatic chat must not cover a visible files view")
        XCTAssertEqual(files.mode(for: id), .files)

        // A notification click (or any explicit choice of chat) goes through files, which hides.
        chat.showChat(session)
        XCTAssertEqual(files.mode(for: id), .chat)
        assertExclusive(fixture)
        // Chat's own "Open in terminal" and permission cards.
        chat.showTerminal(session)
        XCTAssertEqual(files.mode(for: id), .terminal)
        files.switchMode(id, to: .files)
        chat.showTerminal(session)
        XCTAssertEqual(files.mode(for: id), .terminal, "Open in terminal from behind files shows the terminal")
    }

    func testDiscoveryStillOpensChatWhenFilesIsHidden() {
        let fixture = fixture(agent: true), files = fixture.files
        files.switchMode(fixture.id, to: .files)
        files.switchMode(fixture.id, to: .terminal)
        fixture.chat.receiveHelper(.state(state()), session: fixture.session)
        XCTAssertEqual(files.mode(for: fixture.id), .chat, "Files over the terminal was no choice about chat")
    }

    func testChatTheUserLeftForFilesStaysClosedAfterTheTerminal() {
        let fixture = fixture(agent: true), files = fixture.files, chat = fixture.chat, id = fixture.id
        let session = fixture.session
        chat.receiveHelper(.state(state()), session: session)
        XCTAssertEqual(files.mode(for: id), .chat, "Discovery opened chat by itself")
        XCTAssertFalse(session.manualViewChoice)
        var decision: PendingApproval.Decision?
        let approval = PendingApproval(key: "files-mode:Bash", operation: "test operation") { decision = $0.decision }
        session.approvals = [approval]
        session.submissionFailure = "Not sent"

        files.switchMode(id, to: .files)
        XCTAssertTrue(session.manualViewChoice, "Leaving chat for files is the user's choice")
        files.switchMode(id, to: .terminal)
        XCTAssertEqual(decision, .terminal, "Chat's requests give way to the terminal, as chat → terminal does")
        XCTAssertNil(session.submissionFailure)
        XCTAssertNil(session.nativePrompt)

        chat.receiveHelper(.state(state()), session: session)
        XCTAssertEqual(files.mode(for: id), .terminal, "The agent's next state must not reopen chat over the terminal")
    }

    func testRestoredRemoteChatStaysBehindVisibleFiles() {
        let fixture = fixture(agent: false), files = fixture.files, chat = fixture.chat, id = fixture.id
        func remote(_ session: ChatSession, _ pid: UInt64) {
            session.host = "account@host"; session.sessionID = "conversation"
            session.binding = .init(session: "conversation", transcript: nil, pid: pid, start: [pid, 0], executable: "/bin/codex")
        }
        let old = chat.session(for: System.uuid()); remote(old, 10)
        chat.chooseChat(true, session: old)
        chat.close(old.id)
        let next = chat.session(for: id); remote(next, 30)
        files.switchMode(id, to: .files)
        chat.restoreRemotePresentation(next)
        XCTAssertFalse(next.showChat, "Files stays in front: the restored chat is not shown behind it")
        XCTAssertEqual(files.mode(for: id), .files)
        assertExclusive(fixture)
        files.switchMode(id, to: .chat)
        XCTAssertEqual(files.mode(for: id), .chat, "The restored conversation is one click away")
    }

    func testSwitchingAwayFromFilesNeverMakesAFilesSession() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        files.switchMode(id, to: .chat)
        files.switchMode(id, to: .terminal)
        XCTAssertNil(files.existing(id), "A tab that never shows files has no files session (nor its loader)")
    }

    func testAgentExitLeavesFilesShown() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        files.switchMode(id, to: .files)
        fixture.session.exitRequested = true
        fixture.chat.helperExited(.local, terminal: 0)
        XCTAssertFalse(fixture.session.active)
        XCTAssertEqual(files.mode(for: id), .files, "An agent exiting behind files leaves them in front")
        XCTAssertFalse(fixture.session.exitRequested)
    }

    func testFilesTabShortcutShowsFiles() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        files.switchMode(id, to: .chat)
        files.showFiles(id, tab: .files)
        XCTAssertEqual(files.mode(for: id), .files)
        XCTAssertEqual(files.session(for: id).tab, .files)
        assertExclusive(fixture)
    }

    func testShowFilesOpensEachTabFromEveryMode() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        let session = files.session(for: id)
        session.git = .repository(GitRepository(root: "/Users/ivan/src/api"))
        for mode in [TabMode.terminal, .chat, .files] {
            for tab in FilesTab.allCases {
                files.switchMode(id, to: mode)
                XCTAssertEqual(files.mode(for: id), mode)
                // From the files view's other tab, so every case changes the tab.
                if mode == .files { session.select(tab == .files ? .commits : .files) }
                let request = session.focusRequest
                files.showFiles(id, tab: tab)
                XCTAssertEqual(files.mode(for: id), .files, "\(tab) from \(mode)")
                XCTAssertEqual(session.tab, tab, "\(tab) from \(mode)")
                XCTAssertNotEqual(session.focusRequest, request, "the new tab's view takes the keyboard")
                assertExclusive(fixture)
            }
        }
        // Showing the tab already shown leaves the focus where it is.
        let request = session.focusRequest
        files.showFiles(id, tab: .commits)
        XCTAssertEqual(session.focusRequest, request)
    }

    func testGitTabsFallBackToFilesWhenTheRepositoryGoesAway() {
        let fixture = fixture(agent: false), files = fixture.files, id = fixture.id
        let session = files.session(for: id)
        // A tab that never showed files has not resolved its repository: ⇧⌘U goes ahead and waits for the answer.
        XCTAssertEqual(session.git, .loading)
        XCTAssertTrue(files.canShowFiles(id, tab: .changes))
        files.showFiles(id, tab: .changes)
        XCTAssertEqual(session.tab, .changes)
        XCTAssertTrue(session.showsGitTabs, "the segments show while the tab waits")
        session.git = .repository(GitRepository(root: "/Users/ivan/src/api"))
        XCTAssertEqual(session.tab, .changes)
        // A root moving inside the repository resolves again: the tab keeps its intent meanwhile.
        session.git = .loading
        XCTAssertEqual(session.tab, .changes)
        session.git = .none
        XCTAssertEqual(session.tab, .files, "outside a repository the tab falls back to Files")
        XCTAssertFalse(session.showsGitTabs)
        XCTAssertEqual(files.mode(for: id), .files, "files stays shown")

        // Outside one the git tabs refuse, from files and from the terminal alike.
        files.showFiles(id, tab: .commits)
        XCTAssertEqual(session.tab, .files)
        session.select(.changes)
        XCTAssertEqual(session.tab, .files)
        files.switchMode(id, to: .terminal)
        files.showFiles(id, tab: .changes)
        XCTAssertEqual(files.mode(for: id), .terminal, "nothing changes outside a repository")
        XCTAssertFalse(files.canShowFiles(id, tab: .changes))
        XCTAssertTrue(files.canShowFiles(id, tab: .files))

        // git missing on the host is no repository either.
        session.git = .repository(GitRepository(root: "/srv"))
        files.showFiles(id, tab: .commits)
        session.git = .unavailable("git is not installed on homelab")
        XCTAssertEqual(session.tab, .files)
        XCTAssertNil(session.changedCount)
    }

    func testGitTabMenusNeedARepository() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        defer { runtime.workspace = previous }
        let workspace = Workspace()
        var plain = TerminalTab(directory: "/tmp"); plain.machine = .ssh(SSHShell(destination: "nightly"))
        let local = TerminalTab(directory: "/tmp")
        workspace.spaces = [Space(name: "nightly", tab: plain), Space(name: "local", tab: local)]
        runtime.workspace = workspace
        let files = runtime.files
        defer { files.forget(plain.id); files.forget(local.id); runtime.chat.close(plain.id); runtime.chat.close(local.id) }
        let controller = AppDelegate()

        // ⇧⌘U / ⇧⌘L from the terminal: a tab never shown in files has not been resolved, so they may go.
        XCTAssertNil(files.existing(local.id))
        XCTAssertTrue(controller.filesTabMenuEnabled(local, .changes, showing: false))
        XCTAssertTrue(controller.filesTabMenuEnabled(local, .commits, showing: false))
        XCTAssertFalse(controller.filesTabMenuEnabled(plain, .changes, showing: false), "no files on a plain SSH login")
        XCTAssertFalse(controller.filesTabMenuEnabled(nil, .changes, showing: false))
        // ⌃⌘2 / ⌃⌘3 select a tab while files shows, and only then.
        XCTAssertFalse(controller.filesTabMenuEnabled(local, .changes, showing: true))

        let session = files.session(for: local.id)
        session.git = .none
        XCTAssertFalse(controller.filesTabMenuEnabled(local, .changes, showing: false), "outside a repository")
        XCTAssertFalse(controller.filesTabMenuEnabled(local, .commits, showing: false))
        XCTAssertTrue(controller.filesMenuEnabled(local), "⇧⌘F and ⌃⌘1 do not need one")
        files.switchMode(local.id, to: .files)
        XCTAssertFalse(controller.filesTabMenuEnabled(local, .changes, showing: true))
        session.git = .repository(GitRepository(root: "/tmp"))
        XCTAssertTrue(controller.filesTabMenuEnabled(local, .changes, showing: true))
        XCTAssertTrue(controller.filesTabMenuEnabled(local, .commits, showing: true))
        files.switchMode(local.id, to: .terminal)
        XCTAssertFalse(controller.filesTabMenuEnabled(local, .commits, showing: true))
        XCTAssertTrue(controller.filesTabMenuEnabled(local, .commits, showing: false))
    }

    func testModeMenuEnablesTheGitTabsOnlyInsideARepository() {
        let fixture = fixture(agent: true), files = fixture.files, id = fixture.id
        var chosen: [ModeSwitchMenuItem.Target] = []
        func items() -> [ModeSwitchMenuItem] {
            ModeSwitchMenuItem.items(files.switchState(id), files: files, id: id) { chosen.append($0) }
        }
        func checked() -> [String] { items().filter(\.checked).map(\.title) }
        func enabled() -> [String] { items().filter(\.enabled).map(\.title) }
        let all = ["Terminal", "Chat", "Files", "Changes", "Commits"]
        // F1a: the menu always lists the modes and the three files tabs; Changes and Commits are enabled as the View
        // menu's ⇧⌘U and ⇧⌘L are.
        XCTAssertEqual(items().map(\.title), all)
        XCTAssertEqual(enabled(), all, "no files session yet: nothing resolved, so the git tabs may open")
        XCTAssertEqual(checked(), ["Terminal"])
        let session = files.session(for: id)
        session.git = .none
        XCTAssertEqual(items().map(\.title), all)
        XCTAssertEqual(enabled(), ["Terminal", "Chat", "Files"], "outside a repository")
        for tab in [FilesTab.changes, .commits] {
            XCTAssertEqual(items().first { $0.target == .files(tab) }?.enabled, files.canShowFiles(id, tab: tab),
                           "the View menu's rule")
        }
        session.git = .unavailable("git is not installed on homelab")
        XCTAssertEqual(enabled(), ["Terminal", "Chat", "Files"], "where git cannot run")
        session.git = .repository(GitRepository(root: "/Users/ivan/src/api"))
        XCTAssertEqual(enabled(), all)
        XCTAssertEqual(checked(), ["Terminal"], "the git tabs are checked only while files shows them")
        files.showFiles(id, tab: .changes)
        XCTAssertEqual(checked(), ["Changes"])
        files.showFiles(id, tab: .files)
        XCTAssertEqual(checked(), ["Files"])
        files.switchMode(id, to: .chat)
        XCTAssertEqual(checked(), ["Chat"])
        items().first { $0.title == "Commits" }?.choose()
        XCTAssertEqual(chosen, [.files(.commits)])

        // A stand-alone chat has no files: its menu is chat's two modes.
        XCTAssertEqual(ModeSwitchMenuItem.items(files.switchState(id), files: nil, id: id) { _ in }.map(\.title),
                       ["Terminal", "Chat"])
    }

    func testGitTabKeysAreBoundAndYieldToAKeysGroup() throws {
        let controller = AppDelegate(), old = (NSApp.mainMenu, NSApp.windowsMenu, NSApp.helpMenu)
        defer { NSApp.mainMenu = old.0; NSApp.windowsMenu = old.1; NSApp.helpMenu = old.2 }
        controller.buildMenus()
        let items = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        func item(_ action: Selector, tag: Int) throws -> NSMenuItem {
            try XCTUnwrap(items.first { $0.action == action && $0.tag == tag })
        }
        let changes = try item(#selector(AppDelegate.openFilesTab(_:)), tag: 1)
        let commits = try item(#selector(AppDelegate.openFilesTab(_:)), tag: 2)
        XCTAssertEqual([changes.title, changes.keyEquivalent], ["Changes", "U"])
        XCTAssertEqual([commits.title, commits.keyEquivalent], ["Commits", "L"])
        XCTAssertEqual(changes.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertFalse(changes.isHidden)
        // No other item takes ⇧⌘U or ⇧⌘L.
        for (key, owner) in [("u", changes), ("l", commits)] {
            XCTAssertEqual(items.filter { $0.keyEquivalent.lowercased() == key
                && $0.keyEquivalentModifierMask.intersection(KeyGroups.modifierMask) == [.command, .shift] }, [owner])
        }
        let digits = try (0..<3).map { try item(#selector(AppDelegate.showFilesTab(_:)), tag: $0) }
        XCTAssertEqual(digits.map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertTrue(digits.allSatisfy { $0.keyEquivalentModifierMask == [.control, .command] })
        XCTAssertEqual(digits.map(\.isHidden), [false, true, true], "⌃⌘2 and ⌃⌘3 reach what Changes and Commits name")
        XCTAssertTrue(digits[1].allowsKeyEquivalentWhenHidden)
        var keys = KeyGroups()
        keys.tabs = [.control, .command]
        controller.applyKeyGroups(keys)
        XCTAssertEqual(digits.map(\.keyEquivalent), ["", "", ""], "a Keys group on ⌃⌘ digits takes all three")
        XCTAssertEqual(changes.keyEquivalent, "U", "⇧⌘U is not a digit")
    }

    func testPlainSSHTabCannotShowFilesAndDisablesTheMenu() throws {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        defer { runtime.workspace = previous }
        let workspace = Workspace()
        var plain = TerminalTab(directory: "/tmp"); plain.machine = .ssh(SSHShell(destination: "nightly"))
        let local = TerminalTab(directory: "/tmp")
        workspace.spaces = [Space(name: "nightly", tab: plain), Space(name: "local", tab: local)]
        runtime.workspace = workspace
        let files = runtime.files
        defer { files.forget(plain.id); files.forget(local.id); runtime.chat.close(plain.id); runtime.chat.close(local.id) }

        XCTAssertFalse(files.canShowFiles(plain.id))
        XCTAssertEqual(files.plainSSHHost(plain.id), "nightly")
        XCTAssertTrue(files.canShowFiles(local.id))
        XCTAssertNil(files.plainSSHHost(local.id))

        XCTAssertNil(files.nextMode(plain.id), "No helper and no agent: the button has nowhere to go")
        files.cycle(plain.id); files.toggleFiles(plain.id); files.showFiles(plain.id, tab: .files)
        XCTAssertEqual(files.mode(for: plain.id), .terminal)
        let state = files.switchState(plain.id)
        XCTAssertTrue(state.dimmed); XCTAssertEqual(state.glyph, "folder")
        XCTAssertEqual(state.help(chatHint: "unused"), "Files need dispatch-helper on nightly")

        // ⇧⌘F and ⌃⌘1 are validated like ⇧⌘C.
        let controller = AppDelegate()
        XCTAssertFalse(controller.filesMenuEnabled(plain))
        XCTAssertTrue(controller.filesMenuEnabled(local))
        XCTAssertFalse(controller.filesMenuEnabled(nil))
    }

    func testFocusActiveGivesFilesTheKeyboardWhileItShows() {
        let runtime = TerminalRuntime.shared, previous = runtime.workspace
        defer { runtime.workspace = previous }
        let workspace = Workspace()
        let tab = TerminalTab(directory: "/tmp")
        workspace.spaces = [Space(name: "files", tab: tab)]
        workspace.selectedSpace = workspace.spaces.first?.id
        runtime.workspace = workspace
        let id = tab.id
        defer { runtime.files.forget(id); runtime.chat.close(id) }
        XCTAssertEqual(workspace.activeTab?.id, id)
        XCTAssertTrue(runtime.terminalTakesKeyboard(id))
        runtime.files.switchMode(id, to: .files)
        XCTAssertFalse(runtime.terminalTakesKeyboard(id), "Files keeps the keyboard; focusActive must not hand it to the terminal")
        // Re-selecting the tab, a window becoming key, a closed sheet: files' list takes the keyboard again.
        let request = runtime.files.session(for: id).focusRequest
        runtime.focusActive()
        XCTAssertNotEqual(runtime.files.session(for: id).focusRequest, request)
        runtime.files.switchMode(id, to: .terminal)
        XCTAssertTrue(runtime.terminalTakesKeyboard(id))
        let after = runtime.files.session(for: id).focusRequest
        runtime.focusActive()
        XCTAssertEqual(runtime.files.session(for: id).focusRequest, after, "The terminal's turn: files asks for nothing")
    }

    func testPresentedFollowsEveryViewOfTheTab() {
        let session = FilesSession(id: System.uuid())
        let old = System.uuid(), new = System.uuid()
        session.setPresented(true, by: old)
        XCTAssertTrue(session.presented)
        // A moved tab: its new view appears before the old one disappears.
        session.setPresented(true, by: new)
        session.setPresented(false, by: old)
        XCTAssertTrue(session.presented)
        session.setPresented(false, by: new)
        XCTAssertFalse(session.presented)
    }

    func testButtonStatesNameTheNextStep() {
        typealias State = ModeSwitchState
        let terminalChat = State(mode: .terminal, chat: true, files: true, host: nil)
        XCTAssertEqual(terminalChat.glyph, "text.bubble"); XCTAssertFalse(terminalChat.lit)
        XCTAssertEqual(terminalChat.label, "Show Chat"); XCTAssertEqual(terminalChat.value, "Terminal selected")
        XCTAssertEqual(terminalChat.help(chatHint: "Show agent chat"), "Show agent chat")

        let terminalFiles = State(mode: .terminal, chat: false, files: true, host: nil)
        XCTAssertEqual(terminalFiles.glyph, "folder"); XCTAssertFalse(terminalFiles.lit)
        XCTAssertEqual(terminalFiles.label, "Show Files"); XCTAssertEqual(terminalFiles.help(chatHint: ""), "Show files · ⇧⌘F")

        // Chat: the click returns to the terminal even where files could show (files is a hold, a right-click or ⇧⌘F).
        let chat = State(mode: .chat, chat: true, files: true, host: nil)
        XCTAssertEqual(chat.glyph, "text.bubble"); XCTAssertTrue(chat.lit)
        XCTAssertEqual(chat.next, .terminal); XCTAssertEqual(chat.label, "Show Terminal"); XCTAssertEqual(chat.value, "Chat selected")
        XCTAssertEqual(chat.help(chatHint: ""), "Show terminal · ⇧⌘C")
        XCTAssertTrue(chat.reaches(.files))

        let files = State(mode: .files, chat: true, files: true, host: nil)
        XCTAssertEqual(files.glyph, "folder"); XCTAssertTrue(files.lit)
        XCTAssertEqual(files.label, "Show Terminal"); XCTAssertEqual(files.value, "Files selected")
        XCTAssertEqual(files.help(chatHint: ""), "Show terminal · ⇧⌘F")

        // A plain SSH login with an agent: chat, then back to the terminal.
        let plainChat = State(mode: .chat, chat: true, files: false, host: "nightly")
        XCTAssertEqual(plainChat.next, .terminal); XCTAssertEqual(plainChat.label, "Show Terminal")
        XCTAssertEqual(plainChat.help(chatHint: ""), "Show terminal · ⇧⌘C")
        XCTAssertFalse(plainChat.reaches(.files))

        let plain = State(mode: .terminal, chat: false, files: false, host: "nightly")
        XCTAssertTrue(plain.dimmed); XCTAssertEqual(plain.glyph, "folder"); XCTAssertEqual(plain.label, "Show Files")
        XCTAssertEqual(plain.help(chatHint: ""), "Files need dispatch-helper on nightly")

        // A stand-alone chat (no files): chat's own two-way switch, dimmed until an agent runs.
        let bare = State(mode: .terminal, chat: false, files: false, host: nil)
        XCTAssertTrue(bare.dimmed); XCTAssertEqual(bare.glyph, "text.bubble")
        XCTAssertEqual(bare.help(chatHint: "Start an agent"), "Start an agent")
    }

    func testFilesTabKeyYieldsToAKeysGroupUsingControlCommand() {
        var keys = KeyGroups()
        XCTAssertEqual(AppDelegate.filesTabModifiers(keys), [.control, .command])
        XCTAssertTrue(ShortcutRow.windowRows(keys).contains { $0.key == "⌃⌘1…3" })
        XCTAssertTrue(ShortcutRow.windowRows(keys).contains { $0.key == "⇧⌘F" })
        XCTAssertTrue(ShortcutRow.windowRows(keys).contains { $0.key == "⇧⌘U / ⇧⌘L" })
        keys.splits = [.control, .command]
        XCTAssertNil(AppDelegate.filesTabModifiers(keys))
        XCTAssertFalse(ShortcutRow.windowRows(keys).contains { $0.key == "⌃⌘1…3" })
        XCTAssertTrue(ShortcutRow.windowRows(keys).contains { $0.key == "⇧⌘F" })
        XCTAssertTrue(ShortcutRow.windowRows(keys).contains { $0.key == "⇧⌘U / ⇧⌘L" }, "the git tabs' letters are not digits")
        XCTAssertTrue(ShortcutRow.windowRows(keys).contains { $0.key == "⌥⌘P" }, "the preview's chord is not a digit")
    }

    func testAChosenPreviewWidthCarriesToNewTabs() {
        let fixture = fixture(agent: false), files = fixture.files
        // Sessions exist before their tab ever shows files: one made before the choice follows it too.
        let earlier = files.session(for: System.uuid())
        let first = files.session(for: fixture.id)
        XCTAssertNil(files.previewPreference(for: first), "the default until a width is chosen")
        files.choosePreviewWidth(420, for: first)
        XCTAssertEqual(first.previewWidth, 420)
        XCTAssertEqual(files.lastPreviewWidth, 420)
        XCTAssertNil(earlier.previewWidth, "a tab's own width stays unset")
        XCTAssertEqual(files.previewPreference(for: earlier), 420, "a tab made before the choice lays out at it")
        XCTAssertEqual(files.previewPreference(for: files.session(for: System.uuid())), 420, "and one made after")

        // A tab's own width wins over the last one chosen elsewhere.
        let second = files.session(for: System.uuid())
        second.togglePreview()
        files.choosePreviewWidth(300, for: second)
        XCTAssertEqual(files.previewPreference(for: first), 420, "other tabs keep theirs")
        XCTAssertEqual(files.previewPreference(for: earlier), 300)
        XCTAssertTrue(second.previewHidden, "choosing a width does not show a hidden pane")

        // A double-click on the divider: the default again, for that tab and the tabs without a width.
        files.choosePreviewWidth(nil, for: second)
        XCTAssertNil(files.previewPreference(for: second))
        XCTAssertNil(files.previewPreference(for: earlier))
        XCTAssertEqual(files.previewPreference(for: first), 420)
        XCTAssertFalse(files.session(for: System.uuid()).previewHidden, "hiding is per tab")
    }
}
