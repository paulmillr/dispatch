import Dictation
import Foundation

/// "Dispatch, …" spoken commands that switch spaces and tabs, and show or hide the sidebar (Settings › Dictation › Navigate by voice; the grammar is
/// `VoiceCommand`, in the Dictation package). A chat's dictation hands its transcript here first and keeps it as text
/// unless it was a command; on a terminal or files pane the voice key shortcut listens for commands only. Every switch
/// shows what it did, or why it did nothing, in a short note over the window. "Dispatch, back" returns to where the
/// window was before its last switch, by voice or not.
@MainActor @Observable
final class VoiceNavigation {
    static let shared = VoiceNavigation()
    /// The dictation owner of listening for commands alone.
    static let owner = "voice-navigation"

    struct Note: Equatable {
        let id = System.uuid()
        let text: String
        let failed: Bool
    }

    private(set) var note: Note?

    private struct Place: Equatable {
        let space: UUID
        let tab: UUID?
    }

    @ObservationIgnored private var here: Place?
    @ObservationIgnored private var previous: Place?
    @ObservationIgnored private var tracking = false

    private var workspace: Workspace? { TerminalRuntime.shared.workspace }
    /// Shows (true), hides (false) or toggles (nil) the window's sidebar; answers whether it now shows. Set by the app.
    @ObservationIgnored var sidebar: ((Bool?) -> Bool)?

    // MARK: Listening for commands alone

    var listening: Bool { Dictation.shared.active(Self.owner) }

    func toggleListening() { listening ? stopListening() : listen() }

    func listen() {
        let preferences = TerminalRuntime.shared.preferences
        note = nil
        Dictation.shared.start(owner: Self.owner, engine: preferences.dictationEngine, model: preferences.whisperModel) {
            [weak self] update in
            guard case .finished(let transcript) = update, let self else { return }
            if !transcript.isEmpty, !ChatDictation.shared.takeCommand(transcript) { _ = self.handle(transcript, fromChat: false) }
        }
    }

    func stopListening() {
        guard listening else { return }
        if Dictation.shared.phase == .listening { Dictation.shared.stop() }
        else if Dictation.shared.phase != .transcribing { Dictation.shared.cancel() }
    }

    // MARK: Commands

    /// Runs `transcript` if it is a command; false when it is text after all (a chat keeps it in its draft).
    func handle(_ transcript: String, fromChat: Bool) -> Bool {
        let store = DictationStore.shared
        switch VoiceCommand.read(transcript, wakeWords: store.wakeWords) {
        case .text:
            if !fromChat {
                let words = store.wakeWords.map { "“\(WakeWordsSetting.title($0))”" }.joined(separator: " or ")
                show("Start with \(words): “\(store.wakeWord), billing”, “\(store.wakeWord), tab 2”…", failed: true)
            }
            return !fromChat
        case .unrecognized(let said):
            if !fromChat { show("Not a command: “\(store.wakeWord), \(said)”", failed: true) }
            return !fromChat
        case .command(let command):
            return perform(command, fromChat: fromChat)
        }
    }

    private func perform(_ command: VoiceCommand, fromChat: Bool) -> Bool {
        guard let workspace else { return false }
        startTracking()
        switch command {
        case .send, .steer, .newLine, .scratch, .clear, .interrupt, .deny, .option, .listen, .stopListening, .readAgain, .quiet:
            // The chat's (ChatDictation).
            return false
        case .sidebar(let visible):
            guard let sidebar else { return true }
            show(sidebar(visible) ? "Sidebar shown" : "Sidebar hidden", failed: false)
        case .back:
            goBack(workspace)
        case .step(let kind, let delta):
            kind == .space ? workspace.cycleSpace(delta) : workspace.cycleTab(delta)
            arrived(workspace)
        case .go(let spaceReference, let tabReference):
            var space = workspace.current
            if let spaceReference {
                switch resolveSpace(spaceReference, workspace) {
                case .success(let found): space = found
                case .failure(let problem): show(problem.text, failed: true); return true
                }
            }
            guard let space else { return true }
            guard let tabReference else {
                workspace.selectSpace(space.id)
                arrived(workspace)
                return true
            }
            switch resolveTab(tabReference, in: space, workspace) {
            case .success(let select):
                select()
                arrived(workspace)
            case .failure(let problem):
                show(problem.text, failed: true)
            }
        case .named(let name):
            // A tab of this space, else a space, else a tab of another space.
            let here = workspace.current.map { resolveTab(.name(name), in: $0, workspace) }
            if case .success(let select) = here {
                select()
            } else if case .failure(let problem) = here, problem.ambiguous {
                show(problem.text, failed: true)
                return true
            } else if case .success(let space) = resolveSpace(.name(name), workspace) {
                workspace.selectSpace(space.id)
            } else if case .failure(let problem) = resolveSpace(.name(name), workspace), problem.ambiguous {
                show(problem.text, failed: true)
                return true
            } else {
                let elsewhere = workspace.presentationSpaces.filter { $0.id != workspace.current?.id }
                    .flatMap { space in tabNames(space).map { (id: $0.id, name: $0.name, space: space) } }
                switch VoiceMatch.best(name, among: elsewhere.map { ($0.id, $0.name) }) {
                case .one(let id):
                    if let match = elsewhere.first(where: { $0.id == id }) { select(id, in: match.space, workspace) }
                case .several(let ids):
                    show("Several tabs match “\(name)”: " + ids.compactMap { id in
                        elsewhere.first { $0.id == id }.map { "\($0.name) in \($0.space.name)" }
                    }.joined(separator: ", "), failed: true)
                    return true
                case .none:
                    // In a chat, "Dispatch the build" is a sentence, not a place.
                    if !fromChat { show("No space or tab called “\(name)”", failed: true) }
                    return !fromChat
                }
            }
            arrived(workspace)
        }
        return true
    }

    private struct Problem: Error {
        let text: String
        /// Several places match, rather than none.
        var ambiguous = false
    }

    private func resolveSpace(_ reference: VoiceCommand.Reference, _ workspace: Workspace) -> Result<Space, Problem> {
        let spaces = workspace.presentationSpaces
        switch reference {
        case .number(let number):
            guard spaces.indices.contains(number - 1) else { return .failure(Problem(text: "There is no space \(number)")) }
            return .success(spaces[number - 1])
        case .last:
            return spaces.last.map(Result.success) ?? .failure(Problem(text: "There are no spaces"))
        case .name(let name):
            switch VoiceMatch.best(name, among: spaces.map { ($0.id, $0.name) }) {
            case .one(let id): return .success(spaces.first { $0.id == id }!)
            case .several(let ids):
                let listed = ids.compactMap { id in spaces.firstIndex { $0.id == id }.map { "\(spaces[$0].name) (space \($0 + 1))" } }
                return .failure(Problem(text: "Several spaces match “\(name)”: " + listed.joined(separator: ", "), ambiguous: true))
            case .none: return .failure(Problem(text: "No space called “\(name)”"))
            }
        }
    }

    /// What selecting the tab `reference` names in `space` does; numbers count as ⌘1…9 do there (panes when split).
    private func resolveTab(_ reference: VoiceCommand.Reference, in space: Space, _ workspace: Workspace)
        -> Result<() -> Void, Problem> {
        switch reference {
        case .number, .last:
            let count = workspace.tabsOnly ? workspace.sidebarTabs.count { $0.space == space.id } : space.numberedShortcutCount
            let what = workspace.tabsOnly || !space.usesPaneShortcuts ? "tab" : "pane"
            let index: Int
            if case .number(let number) = reference { index = number - 1 } else { index = count - 1 }
            guard index >= 0, index < count else {
                return .failure(Problem(text: "There is no \(what) \(index + 1) in \(space.name)"))
            }
            return .success { [space] in
                if workspace.tabsOnly {
                    let tabs = workspace.sidebarTabs.filter { $0.space == space.id }
                    workspace.selectSidebarTab(tabs[index].id)
                } else {
                    workspace.selectSpace(space.id)
                    workspace.selectNumberedItem(at: index)
                }
            }
        case .name(let name):
            let names = tabNames(space)
            switch VoiceMatch.best(name, among: names) {
            case .one(let id): return .success { [weak self] in self?.select(id, in: space, workspace) }
            case .several(let ids):
                let listed = ids.map { id in
                    space.tabShortcutNumber(for: id).map { "tab \($0)" } ?? names.first { $0.id == id }?.name ?? ""
                }
                return .failure(Problem(text: "Several tabs match “\(name)”: " + listed.joined(separator: ", "), ambiguous: true))
            case .none: return .failure(Problem(text: "No tab called “\(name)” in \(space.name)"))
            }
        }
    }

    /// A space's tabs by name: a tmux or herdr space's windows, else its terminal tabs.
    private func tabNames(_ space: Space) -> [(id: UUID, name: String)] {
        space.structured ? space.windows.map { ($0.id, $0.name) } : space.tabs.map { ($0.id, $0.label) }
    }

    private func select(_ id: UUID, in space: Space, _ workspace: Workspace) {
        space.structured ? workspace.selectContainer(id) : workspace.selectTab(id)
    }

    private func goBack(_ workspace: Workspace) {
        guard let previous else { return show("Nowhere to go back to yet", failed: true) }
        if let tab = previous.tab { workspace.selectTab(tab) }
        if workspace.selectedSpace != previous.space {
            guard workspace.spaces.contains(where: { $0.id == previous.space }) else {
                return show("The previous space is closed", failed: true)
            }
            workspace.selectSpace(previous.space)
        }
        arrived(workspace)
    }

    private func arrived(_ workspace: Workspace) {
        guard let space = workspace.current else { return }
        let tab = space.structured ? space.activeWindow?.name : space.activeTab?.label
        show("→ " + space.name + (tab.map { " · " + $0 } ?? ""), failed: false)
    }

    // MARK: Note and history

    func show(_ text: String, failed: Bool) {
        VoiceConversation.shared.cue(failed ? .failed : .done)
        let note = Note(text: text, failed: failed)
        self.note = note
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(failed ? 3.5 : 1.6))
            if self?.note == note { self?.note = nil }
        }
    }

    func dismiss() { note = nil }

    /// Follows the window's place, so "back" knows the one before. Started by the app, and again by any command.
    func startTracking() {
        guard !tracking, let workspace else { return }
        tracking = true
        follow(workspace)
    }

    private func follow(_ workspace: Workspace) {
        let place = workspace.selectedSpace.map { Place(space: $0, tab: workspace.activeSurfaceID) }
        if let place, place != here {
            if here != nil { previous = here }
            here = place
            // Conversation mode listens to the chat the window shows.
            ChatDictation.shared.follow()
        }
        withObservationTracking {
            _ = workspace.selectedSpace
            _ = workspace.activeSurfaceID
        } onChange: { [weak self, weak workspace] in
            Task { @MainActor in
                guard let self, let workspace else { return }
                self.follow(workspace)
            }
        }
    }
}
