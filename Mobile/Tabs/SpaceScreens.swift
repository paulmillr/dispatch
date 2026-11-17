import SwiftUI

/// P2: a space's tabs, as the Mac strip shows them: named for what runs in them, the agent's mark or a terminal, what
/// each is doing, by time or in server order (the header's sort menu). The header is a tab's (B7): Back's circle, then
/// one glass capsule with the host's disc, the space with its branch and its host and folder, which opens the space's
/// menu (Edit, Detach, Terminate…), and the sort menu trailing. A row swipes to Close and holds the tab's menu with Move
/// to (another of the host's spaces); Edit (P2d) renames the space and its tabs in place, reorders the tabs on the
/// server and closes them; the New tab capsule opens a shell here, held the agents the host can start (P2e), and New
/// chat beside it starts the agent used last. A plain host's Shell space has its shells only: Close, no Rename, Detach
/// or reorder.
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
                HStack(spacing: 10) {
                    let chat = SpaceNewChatButton.offered(navigator: navigator, space: space)
                    if chat { SpaceNewChatButton(navigator: navigator, space: space) }
                    SpaceNewTabButton(navigator: navigator, space: space, showsStarting: !chat)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 8)
            }
        }
        .tabsPushedScreen()
        .toolbar {
            TabsScreenHeader(title: space?.name ?? "", column: column, trailingWidth: editing ? 78 : 44, branch: branch,
                             atTrailingEdge: column == nil, titleCapsule: capsule(space, host: host)) {
                TabsBackDisc(back: "Spaces") { pop() }
            } subtitle: {
                // As a tab's header: host · folder's name ("studio · app"), the whole path for VoiceOver.
                if let host {
                    TabsHostPath(host: host, path: TabScreenHeader.distinct(TabScreenHeader.folder(space?.cwd, host: host), from: space?.name),
                                 mono: false, full: host.abbreviate(space?.cwd))
                }
            } trailing: {
                if editing {
                    TabsHeaderPill(action: { editing = false }) {
                        Text("Done").fontWeight(.semibold).padding(.leading, 6)
                    }
                    .accessibilityLabel("Done")
                } else if space != nil, !shells {
                    SpaceSortMenu(model: model)
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

    /// The header's capsule (B7, as a tab's): the host's disc, the name with its branch, host · folder under it; a tap
    /// opens the space's menu, without New tab (the capsule at the bottom is New tab).
    private func capsule(_ space: MobileSpace?, host: TabsHost?) -> TabsTitleCapsule? {
        guard let space, let host else { return nil }
        let menu = SpaceMenuItems(navigator: navigator, space: space, newTab: false, edit: ("Edit", { editing = true }))
        return TabsTitleCapsule(glyph: AnyView(TabHostDisc(host: host)), menu: AnyView(menu), branch: branch,
                                hint: "Opens the space's menu", identifier: "space-menu")
    }

    private func list(_ space: MobileSpace, workspace: MobileWorkspace, now: Date) -> some View {
        // By activity; Edit shows the server's order, the one its drags change.
        let rows = model.rows(in: space, serverOrder: editing)
        let shells = space.kind == .plainShell
        let open = shownTab ?? model.openedTabs[ref]
        let reorders = workspace.canReorder(space)
        // Edit's name fields: never a plain host's shells. They rename (`entities.rename`) only while the host is
        // connected and live; meanwhile they stay, disabled, keeping what was typed.
        let renames = !shells
        let live = workspace.client != nil && workspace.host.live
        return List {
            if editing, renames {
                Section {
                    SpaceNameField(name: space.name, prompt: "Space name", live: live) { name in
                        await rename { try await workspace.rename(space: space, to: name) }
                    }
                    .accessibilityIdentifier("space-name-field")
                } header: {
                    Text("Space")
                }
            }
            Section {
                ForEach(rows) { entry in
                    let row = SpaceTabRow(entry: entry, line: SpaceTabRow.line(entry, model: model), agent: model.agent(of: entry.tab),
                                          open: entry.id == open, editing: editing, now: now, renameLive: live,
                                          rename: renames ? { name in
                                              await rename {
                                                  guard let tab = workspace.tab(entry.id.key) else { return }
                                                  try await workspace.rename(tab: tab, to: name)
                                              }
                                          } : nil)
                    Group {
                        // Edit (P2d): the row itself, no link (no chevron, not dimmed), beside the list's controls.
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
                        if !shells {
                            Button("Edit", systemImage: "pencil") { editing = true }
                        }
                        SpaceMoveMenu(targets: workspace.moveTargets(from: space)) { target in
                            move(entry.id, to: target, in: workspace)
                        }
                    }
                    // Close alone, also by a full swipe: it ends the tab, asking first while work runs (Detach, which
                    // only hides it on this connection, is in the tab's menu).
                    .swipeActions(edge: .trailing) {
                        Button { actions.close(.tab(entry.id), .close) } label: { Label("Close", systemImage: "xmark") }
                            .tint(Color.destructive)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 48 }
                }
                .onMove(perform: reorders ? { move(rows, from: $0, to: $1, in: workspace) } : nil)
                .onDelete { offsets in
                    for index in offsets { actions.close(.tab(rows[index].id), .close) }
                }
            } footer: {
                if editing {
                    Text(renames ? Self.editNote : Self.closeNote)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .contentMargins(.bottom, 90, for: .scrollContent)
        .environment(\.editMode, .constant(editing ? .active : .inactive))
        .overlay { if rows.isEmpty { TabsNothing(query: TabsQuery()) } }
    }

    static let editNote = "Tap a name to rename it. Drag to reorder. Closing a tab ends it, after asking while work runs."
    static let closeNote = "Closing a tab ends it, after asking while work runs."

    /// A rename from Edit: the server's answer, a refusal shown as the screen's other failures are. True once it took.
    private func rename(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

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

    /// Move to: the tab goes to `target` on the server; the topology takes its row away from here.
    private func move(_ ref: TabRef, to target: MobileSpace, in workspace: MobileWorkspace) {
        guard let tab = workspace.tab(ref.key) else { return }
        Task {
            do { try await workspace.move(tab: tab, to: target) } catch {
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

/// P2's sort menu, trailing in the space's header where the space's "…" was: By time (most recent first) or Manual
/// (the server's order, which Edit's drags change), for every space on this device (`MobileTabs.tabSort`).
struct SpaceSortMenu: View {
    @Bindable var model: MobileTabs

    var body: some View {
        Menu {
            Picker("Sort tabs", selection: $model.tabSort) {
                ForEach(TabsSort.allCases) { sort in
                    Label(sort.title, systemImage: sort.symbol).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        // The label's 44 point circle, which the header's title leaves room for (`TabsScreenHeader.leadingWidth`): a bar
        // item's Menu otherwise becomes the bar's own menu button, 56 by 36 points around a 36 point circle, and a long
        // space name folded it into the bar's "…" (375 points, and the iPhone Air's 420 with its 20 point margins).
        .menuStyle(.button)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .accessibilityLabel("Sort tabs")
        .accessibilityValue(model.tabSort.title)
        .accessibilityIdentifier("space-sort")
    }
}

/// A tab row's Move to (in its long press, P2): the host's other spaces; picking one moves the tab there
/// (`MobileWorkspace.move(tab:to:)`). Nothing without another space or a connection.
struct SpaceMoveMenu: View {
    let targets: [MobileSpace]
    let move: (MobileSpace) -> Void

    var body: some View {
        if !targets.isEmpty {
            Menu {
                ForEach(targets) { target in
                    Button(target.name) { move(target) }
                }
            } label: {
                Label("Move to", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

/// A space's menu items, the header's capsule and a space row's long press alike: New tab (the row's only: the space's
/// screen has its capsule), then the way to change it (the header's Edit, for the space and its tabs; the list's
/// Rename… and Edit Spaces, which reorders them), then Detach and Terminate… (a Shell space: Close all shells). As a
/// tab's menu: what it is called, then how it ends.
struct SpaceMenuItems: View {
    let navigator: SpacesNavigator
    let space: MobileSpace
    /// New tab first (a space row's long press).
    var newTab = true
    /// The header's Edit: a title and what it does.
    var edit: (title: String, action: () -> Void)? = nil
    /// The list's: Rename… and Edit Spaces.
    var list = false

    var body: some View {
        let workspace = navigator.model.workspace(space.ref.host)
        let connected = workspace?.client != nil
        let shells = space.kind == .plainShell
        if newTab, workspace?.canAddTab(to: space) == true {
            Button("New tab", systemImage: "plus") { navigator.newTab(in: space) }
        }
        if !shells {
            if let edit {
                Button(edit.title, systemImage: "pencil", action: edit.action).disabled(!connected)
            }
            if list {
                Button("Rename…", systemImage: "pencil") { navigator.actions.rename(.space(space.ref)) }.disabled(!connected)
            }
        }
        if list {
            Button("Edit Spaces", systemImage: "arrow.up.arrow.down") { navigator.editing = true }
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
    }
}

/// What closing a space says (the Mac's choices; docs/integrations.md: closing a space always detaches).
enum SpaceCloseCopy {
    static let detachNote = "keeps everything running"
    /// One line in the menu, as Detach's.
    static let terminateNote = "ends all its work"
    /// The Close space dialog's message (P3's Close space, ⌘⇧W).
    static let message = "Detach keeps the space and its work running on the host; Terminate ends its windows and the processes in them."
}

/// P2e: the New tab capsule. A tap opens a shell in this space (a new shell on a plain host); held, the menu: Shell (the
/// shell and folder it opens in), the agents the host can start (each on its own default model), and "In another
/// space…" (New tab's picker). While an agent picked there starts, the capsule says so with a spinner ("Starting
/// Claude…", the Mac's launch cover) until its tab opens in Chat, unless New chat beside it does (`showsStarting`).
struct SpaceNewTabButton: View {
    let navigator: SpacesNavigator
    let space: MobileSpace
    var showsStarting = true

    var body: some View {
        let starting = showsStarting ? navigator.startingAgents[space.ref] : nil
        Menu {
            SpaceNewTabMenu(navigator: navigator, space: space)
        } label: {
            HStack(spacing: 8) {
                if let starting {
                    ProgressView()
                    Text("Starting \(starting)…").font(.headline).lineLimit(1)
                } else {
                    Image(systemName: "plus").font(.title3.weight(.medium))
                    Text("New tab").font(.headline)
                }
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
        .accessibilityValue(starting.map { "Starting \($0)" } ?? "")
        .accessibilityHint("Hold for an agent or another space")
        .accessibilityIdentifier("space-new-tab")
    }
}

/// P2's New chat capsule, before New tab: a tap starts the agent New chat used last (`SpacesNavigator.preferredAgent`,
/// else the host's first) in a new tab here and opens it in Chat; held, the host's agents. Offered in a multiplexer's
/// space once the host's agents are known (Chat on for the host). While one starts it says so ("Starting Claude…").
struct SpaceNewChatButton: View {
    let navigator: SpacesNavigator
    let space: MobileSpace

    @MainActor static func offered(navigator: SpacesNavigator, space: MobileSpace) -> Bool {
        space.kind == .multiplexer && navigator.preferredAgent(host: space.ref.host) != nil
    }

    var body: some View {
        let starting = navigator.startingAgents[space.ref]
        let choices = navigator.agentChoices[space.ref.host] ?? []
        Menu {
            ForEach(choices) { choice in
                Button { navigator.startAgent(choice, in: space) } label: {
                    Text(choice.label)
                    if let note = choice.note { Text(note) }
                    Image(symbol: TabSegment.chat.symbol)
                }
                .disabled(starting != nil)
            }
        } label: {
            HStack(spacing: 8) {
                if let starting {
                    ProgressView()
                    Text("Starting \(starting)…").font(.headline).lineLimit(1)
                } else {
                    Image(symbol: TabSegment.chat.symbol).font(.title3.weight(.medium))
                    Text("New chat").font(.headline)
                }
            }
            .foregroundStyle(.primary)
            .padding(.leading, 18)
            .padding(.trailing, 22)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Capsule())
        } primaryAction: {
            guard starting == nil, let choice = navigator.preferredAgent(host: space.ref.host) else { return }
            navigator.startAgent(choice, in: space)
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .accessibilityLabel("New chat")
        .accessibilityValue(starting.map { "Starting \($0)" } ?? navigator.preferredAgent(host: space.ref.host)?.label ?? "")
        .accessibilityHint("Hold for another agent")
        .accessibilityIdentifier("space-new-chat")
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
                            Image(symbol: TabSegment.chat.symbol)
                        }
                        .disabled(navigator.startingAgents[space.ref] != nil)
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
}

/// An agent New tab's menu can start (P2e): the helper's launch key and label, and a note under it.
struct SpacesAgentChoice: Identifiable, Hashable, Sendable {
    let key: String
    let label: String
    /// A line under the label (the sample's model or version); nil says nothing.
    var note: String? = nil
    var id: String { key }
}

/// What Spaces asks of Chat for New tab's agents (the composition wires it to `ChatConversations` and the model
/// memory): the host's agents, and a start in a space that opens the conversation in Chat once it shows.
struct SpacesAgentLauncher {
    var choices: @MainActor (UUID) async -> [SpacesAgentChoice]
    var start: @MainActor (SpacesAgentChoice, MobileSpace) async throws -> Void
    /// The agent New chat started last (its launch key; `ChatModelMemory.lastAgent`): P2's New chat starts it.
    var preferred: @MainActor () -> String? = { nil }
}

/// P2's tab row: the state dot (blue needs you or unseen, amber working), the agent's mark or a terminal, the title as
/// the Mac strip names it, the time and a chevron; under it what the tab is doing (the question or approval in the
/// primary colour while it waits). The tab shown last is "open" to VoiceOver only. Edit mode (P2d) drops the dot and
/// the time for the list's controls, and the title becomes a field that renames the tab (`rename`).
struct SpaceTabRow: View {
    let entry: TabsEntry
    let line: TabsStatus?
    /// The agent's launch key (`MobileTabs.agent(of:)`); nil draws a terminal.
    let agent: String?
    var open = false
    var editing = false
    var now = Date()
    /// The host can take a rename now (`SpaceNameField.live`).
    var renameLive = true
    /// Edit mode's rename of this tab, true once the server took it (nil: its title stays text, as a plain shell's).
    var rename: ((String) async -> Bool)? = nil

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
                    // As a shell row: the title, then the time at its own width; a long title truncates, never the time.
                    // (The title's priority over an "open" chip and the time once folded the chip into a tall capsule
                    // and cut the time to a letter.)
                    if editing, let rename {
                        SpaceTabNameField(name: entry.label, live: renameLive, rename: rename)
                    } else {
                        Text(entry.label).font(.headline).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 2)
                    if !editing, let time = TabsTime.label(entry.activity, now: now) {
                        Text(time)
                            .font(.subheadline)
                            .foregroundStyle(entry.host.stale ? .tertiary : .secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { timeWidth?($0) }
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
        .modifier(SpaceTabRowAccessibility(field: editing && rename != nil, label: entry.label,
                                           value: Self.value(entry: entry, line: line, open: open, now: now),
                                           selected: shown == entry.id))
    }

    @Environment(\.tabsShownTab) private var shown
    @Environment(\.tabsRowTimeWidth) private var timeWidth

    /// "Needs you, Allow cargo test --workspace?, 2:51 AM", "open, ~/src/app".
    static func value(entry: TabsEntry, line: TabsStatus?, open: Bool, now: Date) -> String {
        let state: String? = switch entry.urgency {
        case .needsYou?: "Needs you"
        case .working?: "Working"
        case .unseen?: "Unread"
        case nil: nil
        }
        return [state, open ? "open" : nil, line?.note, line?.text, TabsTime.label(entry.activity, now: now)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The line under a tab's title: an ended shell's end ("Exited with status 1"); an agent's state from Chat (the
    /// current step and how long while working, the question or approval while it waits, the last message once done);
    /// else the terminal's own title ("vite ready · localhost:5173") or the program when the title is not already it;
    /// else the folder's name ("app", as the tab's header says it).
    @MainActor static func line(_ entry: TabsEntry, model: MobileTabs) -> TabsStatus? {
        let tab = entry.tab
        if let shell = tab.shell { return shell.summary.map { TabsStatus(text: $0) } }
        if let pane = tab.agentPane, let status = model.status(tab.ref.host, pane.id) { return status }
        if let pane = tab.activePane, !tab.isChat, let title = model.paneTitle(tab.ref.host, pane.key)?.trimmingCharacters(in: .whitespaces),
           !title.isEmpty, title != entry.label, !TerminalTab.titleNamesDirectory(title, pane.cwd ?? "") { return TabsStatus(text: title) }
        if let program = tab.program, program != entry.label, !tab.atShell, !tab.isChat { return TabsStatus(text: program) }
        // Never the folder under a title that already names it.
        return TabScreenHeader.distinct(TabScreenHeader.folder(tab.cwd, host: entry.host), from: entry.label).map { TabsStatus(text: $0) }
    }
}

/// A tab row as one VoiceOver element (its name, then its state, line and time), or while Edit shows its name field the
/// field on its own, which a combined element could not edit. The split's sidebar marks the tab beside it, as a
/// selected row in Mail.
private struct SpaceTabRowAccessibility: ViewModifier {
    let field: Bool
    let label: String
    let value: String
    let selected: Bool

    func body(content: Content) -> some View {
        if field {
            content.accessibilityElement(children: .contain)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(label)
                .accessibilityValue(value)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Edit's name field for a space or a tab (P2d): the name as it shows; Return, or leaving the field, renames it on the
/// server when the text changed and is not empty. What was sent last stays in the field until the topology names it so,
/// whatever earlier renames still on their way bring first, so the field never shows a name for a moment that is not
/// the latest (a name the server made of it, not one of those sent, ends the wait once every rename answered; a failed
/// rename puts the server's name back). While the host is not live (`live`) the field is disabled and keeps what was
/// typed: nothing is sent to a connection that cannot take it.
struct SpaceNameField: View {
    let name: String
    var prompt = "Tab name"
    var live = true
    let rename: (String) async -> Bool
    @State private var draft: String?
    @State private var renames = SpaceRenames()
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: Binding(get: { draft ?? renames.shown(name) }, set: { draft = $0 }))
            .font(.headline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($focused)
            .disabled(!live)
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: name) { _, now in renames.arrived(now) }
            .onDisappear(perform: commit)
            .accessibilityLabel("Rename \(name)")
    }

    private func commit() {
        // Not live: nothing is sent, and what was typed stays in the field.
        guard live, let typed = draft else { return }
        draft = nil
        guard let next = renames.send(typed, name: name) else { return }
        Task { renames.answered(next, took: await rename(next)) }
    }
}

/// The renames an Edit name field sent and what it shows meanwhile (`SpaceNameField`): the latest name sent until the
/// topology names it so, whatever earlier renames bring first; a name the server made of it (none of those sent) once
/// every rename answered; the server's own after a failed latest one.
struct SpaceRenames: Equatable {
    /// The latest name sent and not yet in the topology.
    private(set) var sent: String?
    /// Every name sent since the field last showed the topology's.
    private(set) var names: Set<String> = []
    /// Renames not answered yet.
    private(set) var pending = 0

    func shown(_ name: String) -> String { sent ?? name }

    /// Typed text to send: trimmed, nil when empty or what shows already.
    mutating func send(_ typed: String, name: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != shown(name) else { return nil }
        sent = trimmed
        names.insert(trimmed)
        pending += 1
        return trimmed
    }

    /// The topology's name now.
    mutating func arrived(_ name: String) {
        guard let sent else { return }
        if name == sent || (!names.contains(name) && pending == 0) { reset() }
    }

    /// A rename's answer: a failed latest one shows the topology's name again.
    mutating func answered(_ name: String, took: Bool) {
        pending = max(0, pending - 1)
        if !took, sent == name { reset() }
    }

    private mutating func reset() {
        sent = nil
        names = []
    }
}

/// The tab row's title while Edit renames tabs.
struct SpaceTabNameField: View {
    let name: String
    var live = true
    let rename: (String) async -> Bool
    var body: some View { SpaceNameField(name: name, live: live, rename: rename) }
}

/// A tab's one-line state where the space and folder are said elsewhere (the watch's tab rows): an ended shell's end,
/// what its agent is doing (from Chat), else the program running when the name is not already it; a bare shell has none.
enum TabsTabLine {
    /// The words only: the watch counts a working agent's time from its rows' `workingSince`, so the snapshot does not
    /// change every second.
    @MainActor static func line(_ tab: MobileTab, label: String, status: @MainActor (UUID, UInt64) -> TabsStatus?) -> String? {
        if let shell = tab.shell { return shell.summary }
        if let pane = tab.agentPane, let line = status(tab.ref.host, pane.id) { return line.note ?? line.text }
        if let program = tab.program, program != label, !tab.atShell { return program }
        return nil
    }
}

/// A tab's line: its words, and while its agent works "· 48s" counted each second from the turn's start (only then
/// does the row redraw on its own).
struct TabsStatusText: View {
    let status: TabsStatus
    /// Two: a note (`TabsStatus.note`) on a line of its own over the step and time (Agents' rows); one: the note
    /// instead of the step (Spaces, the switcher).
    var lines = 1

    var body: some View {
        if lines > 1, let note = status.note {
            VStack(alignment: .leading, spacing: 0) {
                Text(note).lineLimit(1)
                line(status.text).lineLimit(1)
            }
        } else {
            line(lines > 1 ? status.text : status.note ?? status.text)
        }
    }

    @ViewBuilder private func line(_ text: String) -> some View {
        if let since = status.since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(Self.text(text, since: since, now: context.date))
            }
        } else {
            Text(text)
        }
    }

    /// "Editing Sidebar.tsx · 48s", or the note in the step's place on one line ("Tests pass, now the docs · 3m").
    static func text(_ status: TabsStatus, now: Date) -> String {
        text(status.note ?? status.text, since: status.since, now: now)
    }

    static func text(_ text: String, since: Date?, now: Date) -> String {
        guard let since else { return text }
        return text + " · " + TabsTime.elapsed(now.timeIntervalSince(since))
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

extension EnvironmentValues {
    /// Told the width a tab row's time is laid out at (`SpaceTabRow`): tests check a long title never cuts it.
    @Entry var tabsRowTimeWidth: ((CGFloat) -> Void)? = nil
}
