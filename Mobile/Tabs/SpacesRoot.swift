import SwiftUI
import UniformTypeIdentifiers

/// Where the Spaces stack can go.
enum TabsRoute: Hashable {
    case tab(TabRef)
    /// M2c: a space's tabs.
    case space(SpaceRef)
    /// M4d: space details.
    case details(SpaceRef)
    /// M1f: host detail (Hosts' view), from the Info button in edit mode.
    case host(UUID)
}

/// What a tab's two segments show: the Terminal and Chat areas build them for a tab's pane (the shell's composition
/// root wires them).
struct TabsContent {
    var terminal: @MainActor (MobileTab, MobilePane) -> AnyView
    var chat: @MainActor (MobileTab, MobilePane) -> AnyView
    /// The Terminal segment's subtitle after the host ("~/src/app · zsh", M6a); nil: the topology's folder and program.
    var terminalSubtitle: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }
}

/// The app's one navigation stack (`MobileRoot` wraps the tab bar in it, so pushed screens cover the whole screen
/// and the tab bar leaves with the root, as UIKit pushes do): the path, and what Spaces presents over it (New tab's
/// space picker, New space, the Tabs dialogs). Spaces and Agents push onto the same path.
@MainActor @Observable
final class SpacesNavigator {
    var path: [TabsRoute] = []
    var editing = false
    var picking = false
    var newSpace: NewSpaceRequest?
    let model: MobileTabs
    let actions: TabsActions

    init(model: MobileTabs) {
        self.model = model
        actions = TabsActions(model: model)
        actions.closed = { [weak self] in self?.closed($0) }
    }

    /// The tab bar's New in Spaces: a terminal tab in the most recent space, else the space picker.
    func newTabFromBar() {
        if let space = model.recentSpace { newTab(in: space) } else { picking = true }
    }

    /// New tab: a terminal tab in `space`, opened once the host shows it.
    func newTab(in space: MobileSpace) {
        guard let workspace = model.workspace(space.ref.host) else { return }
        Task {
            do { open(try await workspace.newTab(in: space), terminal: true) } catch {
                actions.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Pushes a tab's screen; New tab and Create open theirs in Terminal.
    func open(_ tab: MobileTab, terminal: Bool) {
        model.visited(tab.space)
        if terminal { model.segments[tab.ref] = .terminal }
        path.append(.tab(tab.ref))
    }

    /// Agents: a conversation's tab on its Chat segment.
    func openChat(_ ref: TabRef) {
        model.segments[ref] = .chat
        path.append(.tab(ref))
    }

    /// Host detail's Spaces rows: the space's tabs (M2c) over the detail.
    func openSpace(host: UUID, node: UInt64) {
        guard let space = model.workspace(host)?.spaces.first(where: { $0.node == node }) else { return }
        path.append(.space(space.ref))
    }

    /// What closed leaves the stack: a space takes its tabs and details with it.
    func closed(_ target: TabsActions.Target) {
        path.removeAll { route in
            switch (target, route) {
            case (.tab(let closed), .tab(let shown)): closed == shown
            case (.space(let closed), .space(let shown)), (.space(let closed), .details(let shown)): closed == shown
            case (.space(let closed), .tab(let shown)): model.tab(shown)?.space == closed
            default: false
            }
        }
    }

    #if DEBUG
    /// Screenshot launches (`-DispatchTabsSample YES`): `-DispatchTabsShow space:<key>|details:<key>|tab:<key>|new-space|
    /// pick|edit` opens that screen of the sample; `-DispatchTabsTree YES`, `-DispatchTabsFilter chats` and
    /// `-DispatchTabsCollapse <host name>` set the menu and the tree.
    func screenshotState() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DispatchTabsTree") != nil { model.tree = defaults.bool(forKey: "DispatchTabsTree") }
        if let filter = defaults.string(forKey: "DispatchTabsFilter").flatMap(TabsQuery.Filter.init(rawValue:)) { model.query.filter = filter }
        if let name = defaults.string(forKey: "DispatchTabsCollapse"), let host = model.workspaces.first(where: { $0.host.name == name }),
           !model.collapsed.contains(host.id) {
            model.toggle(host.id)
        }
        if let script = defaults.string(forKey: "DispatchTabsScript") { run(script) }
        guard let show = defaults.string(forKey: "DispatchTabsShow") else { return }
        let parts = show.split(separator: ":", maxSplits: 1).map(String.init)
        func host(_ key: String) -> UUID? { model.workspaces.first { $0.space(key) != nil || $0.tab(key) != nil }?.id }
        switch (parts.first, parts.count > 1 ? parts[1] : nil) {
        case ("space", let key?): if let id = host(key) { path = [.space(SpaceRef(host: id, key: key))] }
        case ("details", let key?): if let id = host(key) { path = [.space(SpaceRef(host: id, key: key)), .details(SpaceRef(host: id, key: key))] }
        case ("tab", let key?): if let id = host(key) { path = [.tab(TabRef(host: id, key: key))] }
        case ("new-space", _): newSpace = NewSpaceRequest(host: model.workspaces.last?.id)
        case ("pick", _): picking = true
        case ("edit", _): editing = true
        default: break
        }
    }

    /// `-DispatchTabsScript "tree,edit,done,flat,space:herdr:app,pop,tab:herdr:app:1,pop"`: one step every 1.5 s after a
    /// 2 s start, for screen recordings that check every transition frame by frame. `agents` and `spaces` switch the
    /// tab bar (through `selectSection`).
    func run(_ script: String) {
        let steps = script.split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                let key = parts.count > 1 ? parts[1] : ""
                let host = model.workspaces.first { $0.space(key) != nil || $0.tab(key) != nil || $0.host.name == key }?.id
                switch parts[0] {
                case "tree": model.tree = true
                case "flat": model.tree = false
                case "edit": editing = true
                case "done": editing = false
                case "filter": model.query.filter = TabsQuery.Filter(rawValue: key) ?? .all
                case "collapse": if let host { model.toggle(host) }
                case "space": if let host { path.append(.space(SpaceRef(host: host, key: key))) }
                case "details": if let host { path.append(.details(SpaceRef(host: host, key: key))) }
                case "tab": if let host { path.append(.tab(TabRef(host: host, key: key))) }
                case "chat": if let host { openChat(TabRef(host: host, key: key)) }
                case "pop": if !path.isEmpty { path.removeLast() }
                case "agents", "spaces": selectSection?(parts[0])
                default: break
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Set by the shell for scripts that switch tabs.
    @ObservationIgnored var selectSection: ((String) -> Void)?
    #endif
}

/// Where the shared stack goes: the Tabs screens and Hosts' detail.
struct TabsDestination: View {
    let route: TabsRoute
    @Bindable var navigator: SpacesNavigator
    let content: TabsContent
    let hostViews: SpacesHostViews

    var body: some View {
        let model = navigator.model
        switch route {
        case .tab(let ref):
            TabScreen(model: model, ref: ref, path: $navigator.path, content: content)
        case .space(let ref):
            SpaceTabsScreen(model: model, actions: navigator.actions, ref: ref, path: $navigator.path,
                            newTab: { navigator.newTab(in: $0) }, pick: { navigator.picking = true })
        case .details(let ref):
            SpaceDetailsScreen(model: model, actions: navigator.actions, ref: ref, path: $navigator.path)
        case .host(let id):
            // M1f's back pill names Spaces, as M2c's does (the system's button showed a bare chevron here).
            hostViews.detail(id)
                .navigationBarBackButtonHidden(true)
                .background(TabsSwipeBack())
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        TabsBackPill(label: "Spaces") { if !navigator.path.isEmpty { navigator.path.removeLast() } }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
        }
    }
}

extension View {
    /// What Spaces presents over the whole stack: its dialogs, New tab's space picker and New space.
    func spacesPresentations(_ navigator: SpacesNavigator, hostViews: SpacesHostViews) -> some View {
        modifier(SpacesPresentations(navigator: navigator, hostViews: hostViews))
    }
}

private struct SpacesPresentations: ViewModifier {
    @Bindable var navigator: SpacesNavigator
    let hostViews: SpacesHostViews

    func body(content: Content) -> some View {
        content
            .tabsDialogs(navigator.actions)
            .sheet(isPresented: $navigator.picking) {
                NewTabPicker(model: navigator.model, choose: { space in
                    navigator.picking = false
                    navigator.newTab(in: space)
                }, newSpace: {
                    navigator.picking = false
                    navigator.newSpace = NewSpaceRequest(host: navigator.model.recentSpace?.ref.host)
                })
                .tint(.dispatchPink)
            }
            .sheet(item: $navigator.newSpace) { request in
                NewSpaceSheet(model: navigator.model, host: request.host, hostViews: hostViews) { tab in
                    navigator.newSpace = nil
                    navigator.open(tab, terminal: true)
                }
                .tint(.dispatchPink)
            }
    }
}

/// The Spaces tab (M1d, M1e, M2a, M2b): every tab across hosts as a flat list or the hosts as sections of spaces, and
/// the host editing of M1e. Its title and toolbar (Mail's header: the tree toggle and the sort/filter menu in one glass
/// capsule leading, Edit or Done trailing, the large title below) are the shared stack's (`SpacesToolbar`).
struct SpacesRoot: View {
    @Bindable var navigator: SpacesNavigator
    let hostActions: SpacesHostActions
    /// Opens New host (M8a): the empty state and edit mode's Add host.
    let addHost: () -> Void
    /// Opens Settings: edit mode's Settings, beside Add host.
    var settings: (() -> Void)? = nil

    var body: some View {
        SpacesHome(model: navigator.model, actions: navigator.actions, hostActions: hostActions, editing: $navigator.editing,
                   addHost: addHost, settings: settings)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) { ForEach(Array(SpacesNotice.notices(hostActions).enumerated()), id: \.offset) { $1 } }
            }
            #if DEBUG
            .onAppear { navigator.screenshotState() }
            #endif
    }
}

struct NewSpaceRequest: Identifiable {
    let id = UUID()
    var host: UUID?
}

/// M1d / M2a / M2b / M1e: the tab's top level.
private struct SpacesHome: View {
    @Bindable var model: MobileTabs
    let actions: TabsActions
    let hostActions: SpacesHostActions
    @Binding var editing: Bool
    let addHost: () -> Void
    let settings: (() -> Void)?

    var body: some View {
        Group {
            if model.workspaces.isEmpty {
                MobileEmptyState(section: .spaces, add: addHost)
            } else if model.tree || editing {
                SpacesTree(model: model, hostActions: hostActions, editing: editing, addHost: addHost, settings: settings)
            } else {
                SpacesFlatList(model: model, actions: actions)
            }
        }
        .onChange(of: model.workspaces.isEmpty) { _, empty in if empty { editing = false } }
    }
}

/// Mail's header for Spaces, in the shared stack's navigation bar: the capsule leading, Edit or Done trailing.
struct SpacesToolbar: ToolbarContent {
    @Bindable var model: MobileTabs
    @Binding var editing: Bool

    var body: some ToolbarContent {
        if !model.workspaces.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                TabsCapsule(tree: $model.tree, query: $model.query, editing: editing)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing.toggle() } label: {
                    Text(editing ? "Done" : "Edit")
                        .font(.body.weight(editing ? .semibold : .regular))
                        .foregroundStyle(editing ? Color.dispatchPink : .primary)
                }
            }
        }
    }
}

/// M2a: one glass capsule holding the tree toggle and the sort/filter menu with a hairline between; the toggle's
/// segment is the glass lens while the tree is on, and the capsule takes the app tint while a filter is active.
struct TabsCapsule: View {
    @Binding var tree: Bool
    @Binding var query: TabsQuery
    /// Edit mode always shows the host sections (M1e): the lens stays on and the toggle waits for Done, so the capsule
    /// never says "flat" over the tree.
    var editing = false

    var body: some View {
        let shown = tree || editing
        HStack(spacing: 0) {
            Button { tree.toggle() } label: {
                TabsMockupGlyph.tree
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 36)
                    .background(shown ? (query.filtering ? Color.lensOnTint : Color.lens) : .clear, in: Capsule())
                    .contentShape(Capsule())
            }
            .allowsHitTesting(!editing)
            .accessibilityLabel("Spaces")
            .accessibilityAddTraits(shown ? .isSelected : [])
            Rectangle()
                .fill(query.filtering ? Color.onAccent.opacity(0.18) : Color.hairline)
                .frame(width: 0.5, height: 22)
                .padding(.horizontal, 2)
            Menu {
                Section("Sort by") {
                    Picker("Sort by", selection: $query.sort) {
                        ForEach(TabsQuery.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Section("Show") {
                    Picker("Show", selection: $query.filter) {
                        ForEach(TabsQuery.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                TabsMockupGlyph.filter
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 36)
                    .contentShape(Capsule())
            }
            .accessibilityLabel(query.filtering ? "Sort and filter, showing \(query.filter.title)" : "Sort and filter")
        }
        .buttonStyle(.plain)
        .foregroundStyle(query.filtering ? Color.onAccent : .primary)
        .padding(.horizontal, 4)
        .frame(height: 44)
        // The tint is a fill in the capsule's content, not the glass's tint: picked from the menu, a filter tinted the
        // glass only once the menu's morph back into the capsule ended, so for about 0.9 s the glyphs were already
        // dark on untinted glass (a screen recording showed it). Content changes in the same frame as the choice.
        .background { if query.filtering { Capsule().fill(Color.dispatchPink) } }
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// M2a: every tab, sorted and filtered by the menu.
private struct SpacesFlatList: View {
    let model: MobileTabs
    let actions: TabsActions

    var body: some View {
        TimelineView(.everyMinute) { context in
            let rows = model.rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { entry in
                        NavigationLink(value: TabsRoute.tab(entry.id)) {
                            TabsTabRow(model: model, entry: entry, detail: true, now: context.date, last: entry.id == rows.last?.id)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TabsTabMenu(actions: actions, tab: entry.id) }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 6)
            }
            .overlay { if rows.isEmpty { TabsNothing(query: model.query) } }
        }
    }
}

/// One tab (M2a, M2c): the host glyph on its tint disc (none in a space's own list), the name with "space · host" in
/// the flat list, the time, and what it is doing.
struct TabsTabRow: View {
    let model: MobileTabs
    let entry: TabsEntry
    var detail: Bool
    var now: Date
    var last = false

    var body: some View {
        let tab = entry.tab
        MobileRow(dot: entry.urgency?.rowDot, tint: entry.host.tint, name: tab.name,
                  detail: detail ? [entry.space?.name, entry.host.name].compactMap { $0 }.joined(separator: " · ") : nil,
                  time: TabsTime.label(tab.activity, now: now), subtitle: Self.line(tab, host: entry.host, status: model.status),
                  separator: !last, disc: detail, stale: entry.host.stale) {
            HostGlyph(host: entry.host.glyphRecord, size: MobileRow<HostGlyph>.glyphSize)
        }
    }

    /// The line: what a chat tab's agent is doing (from Chat), else the program and where it runs.
    static func line(_ tab: MobileTab, host: TabsHost, status: @MainActor (UUID, UInt64) -> String?) -> String? {
        if let pane = tab.agentPane, let text = status(tab.ref.host, pane.id) { return text }
        let cwd = host.abbreviate(tab.cwd)
        if let program = tab.program, program != tab.name, !tab.atShell {
            return [program, cwd].compactMap { $0 }.joined(separator: " · ")
        }
        return cwd
    }
}

/// M2b and M1e: each host a section (name, glyph, disclosure; collapsed, the unread inside rolls up by the toggle),
/// its spaces in an inset grouped card, one line each with the unread count and an amber dot while something works.
/// Editing: a red remove control and Info on each host, drag handles on hosts and spaces (spaces stay in their host),
/// and Add host at the end.
private struct SpacesTree: View {
    let model: MobileTabs
    let hostActions: SpacesHostActions
    let editing: Bool
    let addHost: () -> Void
    var settings: (() -> Void)? = nil
    @State private var removing: (host: UUID, question: HostRemovalConfirmation)?

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section {
                    if !section.collapsed {
                        ForEach(section.spaces) { row in
                            SpacesSpaceLine(row: row, editing: editing)
                        }
                        .onMove { source, destination in
                            model.moveSpaces(of: section.host.id, visible: section.spaces.map(\.id.key), from: source, to: destination)
                        }
                    }
                } header: {
                    SpacesHostHeader(section: section, editing: editing, toggle: { model.toggle(section.host.id) },
                                     remove: {
                        if let question = hostActions.removalConfirmation(for: section.host.id) { removing = (section.host.id, question) }
                    })
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first, let id = UUID(uuidString: item) else { return false }
                            model.moveHost(id, before: section.host.id, actions: hostActions)
                            return true
                        }
                }
            }
            if editing {
                Section {
                    HStack(spacing: 12) {
                        Button(action: addHost) {
                            // Not a Label: a list row restyles labels (their title did not follow Dynamic Type there).
                            HStack(spacing: 8) {
                                Image(systemName: "plus").accessibilityHidden(true)
                                Text("Add host").fittingLine()
                            }
                                .font(.headline)
                                .padding(.leading, 20)
                                .padding(.trailing, 24)
                                .padding(.vertical, 8)
                                .frame(minHeight: 50)
                        }
                        .buttonStyle(MobileCallToAction())
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first, let id = UUID(uuidString: item) else { return false }
                            model.moveHost(id, before: nil, actions: hostActions)
                            return true
                        }
                        if let settings {
                            // Not in the mockup: the app's settings, beside Add host where hosts are managed (docs/ios.md).
                            Button(action: settings) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 19, weight: .semibold))
                                    .frame(width: 36, height: 36)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Settings")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(20)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(editing ? .active : .inactive))
        .alert(removing?.question.title ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { removing in
            Button("Cancel", role: .cancel) {}
            Button(removing.question.button, role: .destructive) { hostActions.removeHost(removing.host) }
        } message: { removing in
            Text(removing.question.message)
        }
        .overlay { if model.sections.allSatisfy({ $0.spaces.isEmpty }) && model.query.filtering { TabsNothing(query: model.query) } }
    }
}

/// A host's section header (M2b, M1e).
private struct SpacesHostHeader: View {
    let section: SpacesSection
    let editing: Bool
    let toggle: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if editing {
                Button(action: remove) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(uiColor: .systemRed), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(section.host.name)")
            }
            Text(section.host.name)
                .font(.title3.bold())
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(!editing && section.collapsed && section.unread > 0 ? "\(section.unread) unread" : "")
            HostGlyph(host: section.host.glyphRecord, size: 18)
                .foregroundStyle(section.host.tint)
                .opacity(section.host.state == .offline ? 0.5 : 1)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            if !editing, section.collapsed, section.unread > 0 {
                Text("\(section.unread)")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
            if editing {
                NavigationLink(value: TabsRoute.host(section.host.id)) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.dispatchPink)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(section.host.name) details")
            }
            Button(action: toggle) {
                Image(systemName: section.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 28, height: 28)
                    .background(Color.chipFill, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(section.collapsed ? "Show \(section.host.name)" : "Hide \(section.host.name)")
            if editing {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .draggable(section.host.id.uuidString) {
                        Text(section.host.name).font(.title3.bold()).padding(8)
                    }
                    .accessibilityLabel("Reorder \(section.host.name)")
            }
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }

    @Environment(\.dynamicTypeSize) private var typeSize
}

/// A space in the tree: its name, the amber dot while something works, the unread count, a chevron.
struct SpacesSpaceLine: View {
    let row: SpacesSpaceRow
    let editing: Bool

    var body: some View {
        if editing {
            Text(row.space.name).font(.body).lineLimit(2)
        } else {
            NavigationLink(value: TabsRoute.space(row.space.ref)) {
                HStack(spacing: 8) {
                    Text(row.space.name).font(.body).lineLimit(2)
                    Spacer(minLength: 0)
                    if row.working {
                        Circle().fill(Color.stateWorking).frame(width: 10, height: 10)
                    }
                    if row.unread > 0 {
                        Text("\(row.unread)").font(.body).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            // "app", the unread count and the amber dot's meaning as the value.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.space.name)
            .accessibilityValue(Self.value(unread: row.unread, working: row.working))
        }
    }
}

extension SpacesSpaceLine {
    static func value(unread: Int, working: Bool) -> String {
        [unread > 0 ? "\(unread) unread" : nil, working ? "Working" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// When the filter leaves nothing (or a host has no tabs yet).
struct TabsNothing: View {
    let query: TabsQuery
    var body: some View {
        Text(query.filtering ? "No tabs match “\(query.filter.title)”." : "No tabs yet. New makes one.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 44)
            .multilineTextAlignment(.center)
    }
}
