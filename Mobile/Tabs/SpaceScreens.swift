import SwiftUI

/// P2: a space's tabs, as the Mac strip shows them: named for what runs in them, the agent's mark or a terminal, what
/// each is doing, in server order. The header carries the space with its branch, its host and path, and the space's
/// menu (Rename…, New tab, Edit tabs, Detach, Terminate…); a row swipes to Detach and Close and holds the tab's menu;
/// Edit tabs (P2d) reorders them on the server and closes them; the New tab capsule opens a shell here, held the agents
/// the host can start (P2e). A plain host's Shell space has its shells only: Close, no Rename, Detach or reorder.
struct SpaceTabsScreen: View {
    let navigator: SpacesNavigator
    let ref: SpaceRef
    @Binding var path: [TabsRoute]
    @Environment(\.tabsColumnWidth) private var column
    @Environment(\.tabsShownTab) private var shownTab
    @State private var editing = false

    private var model: MobileTabs { navigator.model }
    private var actions: TabsActions { navigator.actions }

    var body: some View {
        let space = model.space(ref)
        let workspace = model.workspace(ref.host)
        let host = workspace?.host
        let shells = space?.kind == .plainShell
        VStack(spacing: 0) {
            if let space, let workspace {
                TimelineView(.everyMinute) { context in
                    list(space, workspace: workspace, now: context.date)
                }
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let space, !editing, workspace?.canAddTab(to: space) == true {
                SpaceNewTabButton(navigator: navigator, space: space)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }
        }
        .tabsPushedScreen()
        .toolbar {
            TabsScreenHeader(title: space?.name ?? "", column: column, trailingWidth: editing ? 78 : 44, branch: branch,
                             atTrailingEdge: column == nil) {
                TabsBackPill(label: "Spaces") { pop() }
            } subtitle: {
                if let host { TabsHostPath(host: host, path: host.abbreviate(space?.cwd)) }
            } trailing: {
                if editing {
                    TabsHeaderPill(action: { editing = false }) {
                        Text("Done").fontWeight(.semibold).padding(.leading, 6)
                    }
                    .accessibilityLabel("Done")
                } else if let space {
                    SpaceMenu(navigator: navigator, space: space, shells: shells, editTabs: { editing = true })
                }
            }
        }
        .onAppear {
            model.visited(ref)
            #if DEBUG
            if navigator.editingSpace == ref {
                navigator.editingSpace = nil
                editing = true
            }
            #endif
        }
        // Again once the host connects: a menu's items are fixed when it opens.
        .task(id: workspace?.client != nil) { await navigator.loadAgents(host: ref.host) }
        .task(id: gitWatch) {
            guard let gitWatch, let gitFacts = navigator.gitFacts else { return }
            await gitFacts.watch(gitWatch.key, directory: gitWatch.directory)
        }
        .onChange(of: space == nil) { _, gone in if gone { editing = false } }
    }

    private func list(_ space: MobileSpace, workspace: MobileWorkspace, now: Date) -> some View {
        let rows = model.rows(in: space)
        let shells = space.kind == .plainShell
        let open = shownTab ?? model.openedTabs[ref]
        let reorders = workspace.canReorder(space)
        return List {
            Section {
                ForEach(rows) { entry in
                    let row = SpaceTabRow(entry: entry, line: SpaceTabRow.line(entry, model: model), agent: model.agent(of: entry.tab),
                                          open: entry.id == open, editing: editing, now: now)
                    Group {
                        // Edit tabs (P2d): the row itself, no link (no chevron, not dimmed), beside the list's controls.
                        if editing {
                            row
                        } else {
                            TabsTabLink(tab: entry.id) { row }
                                .buttonStyle(.plain)
                        }
                    }
                    .accessibilityIdentifier("space-tab")
                    .contextMenu {
                        TabsTabMenu(actions: actions, tab: entry.id)
                        if reorders {
                            Button("Edit tabs", systemImage: "arrow.up.arrow.down") { editing = true }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button { actions.close(.tab(entry.id), .close) } label: { Label("Close", systemImage: "xmark") }
                            .tint(Color.destructive)
                        if !shells {
                            Button { actions.close(.tab(entry.id), .detach) } label: { Label("Detach", systemImage: "eject.fill") }
                                .tint(Color.caution)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 48 }
                }
                .onMove(perform: reorders ? { move(rows, from: $0, to: $1, in: workspace) } : nil)
                .onDelete { offsets in
                    for index in offsets { actions.close(.tab(rows[index].id), .close) }
                }
            } footer: {
                Text(editing ? Self.editNote : Self.note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .contentMargins(.bottom, 90, for: .scrollContent)
        .environment(\.editMode, .constant(editing ? .active : .inactive))
        .overlay { if rows.isEmpty { TabsNothing(query: TabsQuery()) } }
    }

    static let note = "Long-press a tab for Rename, Detach and Terminate."
    static let editNote = "Drag to reorder. Closing a tab detaches it unless it is idle."

    /// P2d's drag: the rows take the new order at once (`MobileWorkspace.reorder` keeps it until the server answers),
    /// and the tab moves before its new neighbour on the server (`memberships.move`: tmux's window order, herdr's tab
    /// order); a refused move puts them back and says why.
    private func move(_ rows: [TabsEntry], from source: IndexSet, to destination: Int, in workspace: MobileWorkspace) {
        var keys = rows.map(\.id.key)
        keys.move(fromOffsets: source, toOffset: destination)
        guard keys != rows.map(\.id.key), let first = source.first, let space = model.space(ref) else { return }
        let moved = rows[first].id.key
        Task {
            do { try await workspace.reorder(space: space, keys: keys, moved: moved) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private struct GitWatch: Hashable {
        let key: SpaceGitFacts.Key
        let directory: String
        let generation: Int
    }

    /// The space's folder, whose branch the header shows (polled while the screen shows, as Files does).
    private var gitWatch: GitWatch? {
        guard let space = model.space(ref), let directory = space.cwd, directory.hasPrefix("/"), let gitFacts = navigator.gitFacts
        else { return nil }
        return GitWatch(key: SpaceGitFacts.Key(host: ref.host, key: ref.key), directory: directory,
                        generation: gitFacts.generation(ref.host))
    }

    private var branch: String? {
        gitWatch.flatMap { navigator.gitFacts?.facts($0.key, directory: $0.directory)?.branch }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }
}

/// P2c: the space's menu behind the header's "…": Rename…, New tab, Edit tabs, then Detach ("keeps everything
/// running") and Terminate… ("ends every shell and agent"), which asks first. A Shell space's: New tab and Close all.
private struct SpaceMenu: View {
    let navigator: SpacesNavigator
    let space: MobileSpace
    let shells: Bool
    let editTabs: () -> Void

    var body: some View {
        let workspace = navigator.model.workspace(space.ref.host)
        let connected = workspace?.client != nil
        Menu {
            if !shells {
                Button("Rename…", systemImage: "pencil") { navigator.actions.rename(.space(space.ref)) }
                    .disabled(!connected)
            }
            if workspace?.canAddTab(to: space) == true {
                Button("New tab", systemImage: "plus") { navigator.newTab(in: space) }
            }
            if !shells, workspace?.canReorder(space) == true {
                Button("Edit tabs", systemImage: "arrow.up.arrow.down", action: editTabs)
            }
            Divider()
            if shells {
                Button(role: .destructive) { navigator.actions.close(.space(space.ref), .close) } label: {
                    Text("Close all shells"); Text("ends every shell of this host"); Image(systemName: "xmark")
                }
                .disabled(space.tabs.isEmpty)
            } else {
                Button { navigator.actions.close(.space(space.ref), .detach) } label: {
                    Text("Detach"); Text(SpaceCloseCopy.detachNote); Image(systemName: "eject")
                }
                .disabled(!connected)
                Button(role: .destructive) { navigator.actions.close(.space(space.ref), .terminate) } label: {
                    Text("Terminate…"); Text(SpaceCloseCopy.terminateNote); Image(systemName: "xmark.octagon")
                }
                .disabled(!connected)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        // The label's 44 point circle, which the header's title leaves room for (`TabsScreenHeader.leadingWidth`): a bar
        // item's Menu otherwise becomes the bar's own menu button, 56 by 36 points around a 36 point circle, and a long
        // space name folded the ⋯ into the bar's "…" (375 points, and the iPhone Air's 420 with its 20 point margins).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("Space menu")
        .accessibilityIdentifier("space-menu")
    }
}

/// What closing a space says (the Mac's choices; docs/integrations.md: closing a space always detaches).
enum SpaceCloseCopy {
    static let detachNote = "keeps everything running"
    static let terminateNote = "ends every shell and agent"
    /// The Close space dialog's message (P3's Close space, ⌘⇧W).
    static let message = "Detach keeps the space and its work running on the host; Terminate ends its windows and the processes in them."
}

/// P2e: the New tab capsule. A tap opens a shell in this space (a new shell on a plain host); held, the menu: Shell (the
/// shell and folder it opens in), the agents the host can start with the model New chat would use, and "In another
/// space…" (New tab's picker).
struct SpaceNewTabButton: View {
    let navigator: SpacesNavigator
    let space: MobileSpace

    var body: some View {
        Menu {
            SpaceNewTabMenu(navigator: navigator, space: space)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.title3.weight(.medium))
                Text("New tab").font(.headline)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Capsule())
        } primaryAction: {
            navigator.newTab(in: space)
        }
        // Shell first, as drawn: a menu opening upwards from the capsule would list it last.
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .accessibilityLabel("New tab")
        .accessibilityHint("Hold for an agent or another space")
        .accessibilityIdentifier("space-new-tab")
    }
}

/// New tab's held menu (P2e, and P3's New tab row): Shell, the host's agents, and "In another space…".
struct SpaceNewTabMenu: View {
    let navigator: SpacesNavigator
    let space: MobileSpace

    var body: some View {
        let model = navigator.model
        let host = model.workspace(space.ref.host)?.host
        Section {
            Button { act { navigator.newTab(in: space) } } label: {
                // Title, subtitle and image: a menu item's three parts (a Label's second text was dropped).
                Text("Shell"); Text(Self.shellNote(space, host: host)); Image(systemName: "apple.terminal")
            }
        }
        if space.kind == .multiplexer {
            let choices = navigator.agentChoices[space.ref.host] ?? []
            if !choices.isEmpty {
                Section {
                    ForEach(choices) { choice in
                        Button { act { navigator.startAgent(choice, in: space) } } label: {
                            Text(choice.label)
                            if let note = choice.note { Text(note) }
                            Self.agentIcon(choice.key)
                        }
                        .disabled(navigator.startingAgents.contains(space.ref))
                    }
                }
            }
        }
        Section {
            Button("In another space…", systemImage: "square.on.square") { act { navigator.picking = true } }
        }
    }

    /// From the switcher, the sheet goes first: what the item opens (a tab, New tab's picker) shows over the stack.
    private func act(_ action: @escaping () -> Void) {
        if navigator.switcher != nil { navigator.afterClosingSwitcher(action) } else { action() }
    }

    /// "zsh in ~/src/app": the shell its tabs run (the first tab, or a renamed tab's pane, at a shell prompt), in the
    /// space's folder.
    @MainActor static func shellNote(_ space: MobileSpace, host: TabsHost?) -> String {
        let shell = space.tabs.compactMap { $0.program ?? $0.activePane?.name }.first(where: MobileTab.isShell) ?? "shell"
        guard let folder = host?.abbreviate(space.cwd) else { return shell }
        return "\(shell) in \(folder)"
    }

    /// A menu item's icon is an image: the agents' marks as their symbols in their colours (Claude's coral, Pi's π in the
    /// code purple; a menu draws a template image in its own colour, so these are drawn as they are).
    static func agentIcon(_ key: String) -> Image {
        func colored(_ symbol: String, _ color: UIColor) -> Image {
            guard let image = UIImage(systemName: symbol)?.withTintColor(color, renderingMode: .alwaysOriginal) else {
                return Image(systemName: symbol)
            }
            return Image(uiImage: image)
        }
        switch AgentGlyph.kind(key) {
        case .claude: return colored("sparkle", UIColor(AgentGlyph.claudeOrange))
        case .codex: return Image(systemName: "chevron.left.forwardslash.chevron.right")
        case .pi: return colored("pi", UIColor.dispatch("CodeType"))
        case .terminal: return Image(systemName: "text.bubble")
        }
    }
}

/// An agent New tab's menu can start (P2e): the helper's launch key and label, and the model New chat would use.
struct SpacesAgentChoice: Identifiable, Hashable, Sendable {
    let key: String
    let label: String
    /// The model it starts on ("fable-5.1"), or its version; nil says nothing.
    var note: String? = nil
    var id: String { key }
}

/// What Spaces asks of Chat for New tab's agents (the composition wires it to `ChatConversations` and the model
/// memory): the host's agents, and a start in a space that opens the conversation in Chat once it shows.
struct SpacesAgentLauncher {
    var choices: @MainActor (UUID) async -> [SpacesAgentChoice]
    var start: @MainActor (SpacesAgentChoice, MobileSpace) async throws -> Void
}

/// P2's tab row: the state dot (blue needs you or unseen, amber working), the agent's mark or a terminal, the title as
/// the Mac strip names it with "open" on the tab shown last, the time and a chevron; under it what the tab is doing (the
/// question or approval in the primary colour while it waits). Edit mode (P2d) drops the dot and the time for the
/// list's controls.
struct SpaceTabRow: View {
    let entry: TabsEntry
    let line: TabsStatus?
    /// The agent's launch key (`MobileTabs.agent(of:)`); nil draws a terminal.
    let agent: String?
    var open = false
    var editing = false
    var now = Date()

    var body: some View {
        HStack(spacing: 12) {
            if !editing {
                Circle()
                    .fill(entry.urgency.map { $0 == .working ? Color.stateWorking : Color.stateUnread } ?? .clear)
                    .frame(width: 10, height: 10)
                    .frame(width: 14)
            }
            AgentGlyph(agent: entry.tab.isChat ? (agent ?? "agent") : nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The title first: the time gives way (it shrinks a little) before a title like the mockup's does.
                    Text(entry.label).font(.headline).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    if open {
                        Text("open")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 16)
                            .background(Color.chipFill, in: Capsule())
                    }
                    Spacer(minLength: 2)
                    if !editing, let time = TabsTime.label(entry.activity, now: now) {
                        Text(time)
                            .font(.subheadline)
                            .foregroundStyle(entry.host.stale ? .tertiary : .secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                if let line {
                    TabsStatusText(status: line)
                        .font(.subheadline)
                        .foregroundStyle(entry.urgency == .needsYou ? Color.primary : .secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.label)
        .accessibilityValue(Self.value(entry: entry, line: line, open: open, now: now))
        // The split's sidebar marks the tab beside it, as a selected row in Mail.
        .accessibilityAddTraits(shown == entry.id ? .isSelected : [])
    }

    @Environment(\.tabsShownTab) private var shown

    /// "Needs you, Allow cargo test --workspace?, 2:51 AM", "open, ~/src/app".
    static func value(entry: TabsEntry, line: TabsStatus?, open: Bool, now: Date) -> String {
        let state: String? = switch entry.urgency {
        case .needsYou?: "Needs you"
        case .working?: "Working"
        case .unseen?: "Unread"
        case nil: nil
        }
        return [state, open ? "open" : nil, line?.text, TabsTime.label(entry.activity, now: now)].compactMap { $0 }.joined(separator: ", ")
    }

    /// The line under a tab's title: an ended shell's end ("Exited with status 1"); an agent's state from Chat (the
    /// current step and how long while working, the question or approval while it waits, the last message once done);
    /// else the terminal's own title ("vite ready · localhost:5173") or the program when the title is not already it;
    /// else the folder ("~/src/app").
    @MainActor static func line(_ entry: TabsEntry, model: MobileTabs) -> TabsStatus? {
        let tab = entry.tab
        if let shell = tab.shell { return shell.summary.map { TabsStatus(text: $0) } }
        if let pane = tab.agentPane, let status = model.status(tab.ref.host, pane.id) { return status }
        if let pane = tab.activePane, !tab.isChat, let title = model.paneTitle(tab.ref.host, pane.key)?.trimmingCharacters(in: .whitespaces),
           !title.isEmpty, title != entry.label, !TerminalTab.titleNamesDirectory(title, pane.cwd ?? "") { return TabsStatus(text: title) }
        if let program = tab.program, program != entry.label, !tab.atShell, !tab.isChat { return TabsStatus(text: program) }
        return entry.host.abbreviate(tab.cwd).map { TabsStatus(text: $0) }
    }
}

/// A tab's one-line state where the space and folder are said elsewhere (the watch's tab rows): an ended shell's end,
/// what its agent is doing (from Chat), else the program running when the name is not already it; a bare shell has none.
enum TabsTabLine {
    /// The words only: the watch counts a working agent's time from its rows' `workingSince`, so the snapshot does not
    /// change every second.
    @MainActor static func line(_ tab: MobileTab, label: String, status: @MainActor (UUID, UInt64) -> TabsStatus?) -> String? {
        if let shell = tab.shell { return shell.summary }
        if let pane = tab.agentPane, let text = status(tab.ref.host, pane.id)?.text { return text }
        if let program = tab.program, program != label, !tab.atShell { return program }
        return nil
    }
}

/// A tab's line: its words, and while its agent works "· 48s" counted each second from the turn's start (only then
/// does the row redraw on its own).
struct TabsStatusText: View {
    let status: TabsStatus

    var body: some View {
        if let since = status.since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.text(status, now: context.date))
            }
        } else {
            Text(status.text)
        }
    }

    /// "Editing Sidebar.tsx · 48s".
    static func text(_ status: TabsStatus, now: Date) -> String {
        guard let since = status.since else { return status.text }
        return status.text + " · " + TabsTime.elapsed(now.timeIntervalSince(since))
    }
}

/// P1's Detached list for one host: each detached space or tab with Restore, and Remove from list on a swipe or its
/// menu; Restore all in the header. Restoring brings the work back into the host's lists (and the Mac's) with its
/// processes as they were; removing only stops listing it, the work keeps running on the host.
struct SpacesDetachedScreen: View {
    let model: MobileTabs
    let actions: TabsActions
    let host: UUID
    @Binding var path: [TabsRoute]
    @Environment(\.tabsColumnWidth) private var column

    var body: some View {
        let workspace = model.workspace(host)
        let items = workspace?.detached ?? []
        let connected = workspace?.client != nil && workspace?.host.live == true
        List {
            Section {
                ForEach(items) { item in
                    SpacesDetachedRow(item: item, restore: connected ? { restore(item) } : nil)
                        .contextMenu {
                            Button("Restore", systemImage: "arrow.uturn.backward") { restore(item) }.disabled(!connected)
                            Button("Remove from list", systemImage: "minus.circle", role: .destructive) { forget(item) }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { forget(item) } label: { Label("Remove from list", systemImage: "minus.circle") }
                        }
                }
            } footer: {
                if let name = workspace?.host.name {
                    Text("Detached work keeps running on \(name). Restore brings it back here and on the Mac; Remove from list only stops listing it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if items.isEmpty {
                Text("Nothing is detached.").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .tabsPushedScreen()
        .toolbar {
            TabsScreenHeader(title: "Detached", column: column, trailingWidth: 120, atTrailingEdge: column == nil) {
                TabsBackPill(label: "Spaces") { if !path.isEmpty { path.removeLast() } }
            } subtitle: {
                if let host = workspace?.host { TabsHostPath(host: host, path: nil) }
            } trailing: {
                if items.count > 1 {
                    TabsHeaderPill(action: { for item in items { restore(item) } }) {
                        Text("Restore all").padding(.leading, 4)
                    }
                    .disabled(!connected)
                }
            }
        }
    }

    private func restore(_ item: MobileDetached) {
        guard let workspace = model.workspace(host) else { return }
        Task {
            do { try await workspace.restore(item) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func forget(_ item: MobileDetached) {
        guard let workspace = model.workspace(host) else { return }
        Task {
            do { try await workspace.forget(item) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// A detached space or tab: its kind's glyph, its name, "Space" or "Tab in app", and Restore.
private struct SpacesDetachedRow: View {
    let item: MobileDetached
    /// Nil while the host is not connected (or its spaces are the cache's).
    let restore: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .space ? "square.on.square" : "apple.terminal")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(1)
                Text(item.kind == .space ? "Space" : item.space.map { "Tab in \($0)" } ?? "Tab")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Restore") { restore?() }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.glass)
                .disabled(restore == nil)
                .accessibilityLabel("Restore \(item.name)")
        }
        .padding(.vertical, 4)
    }
}
