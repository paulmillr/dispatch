import SwiftUI

/// How Agents and New chat draw a host: its tint (the rows' host name) and its glyph. The Hosts stream supplies both (HostTint, HostGlyph from
/// its records); the default is the shared tint of the host id and a display glyph.
struct ChatHostLook {
    var tint: @MainActor (UUID) -> Color = { HostTint(hostID: $0.uuidString).color }
    var glyph: @MainActor (UUID) -> AnyView = { _ in AnyView(Image(systemName: "display").resizable().scaledToFit()) }
}

/// A host as Agents' empty state and its offline section tell it: whether it is reached, why not, and whether it lists
/// agents at all (Chat off, plain SSH).
struct AgentsHost: Identifiable, Equatable {
    let id: UUID
    var name: String
    var state: SpacesHostState
    /// Why it is not connected (`HostSession.problem`).
    var problem: String? = nil
    /// When its helper last answered.
    var updated: Date? = nil
    /// Its Chat switch is off, or it is reached over plain SSH: its agents are terminals only, never rows here.
    var listsAgents = true
}

/// What the Agents list asks of the app around it. The defaults serve a standalone list (the Debug demo): rows open
/// nothing and carry no tab menu.
struct AgentsContext {
    /// Opens the conversation's tab in Chat (the shell pushes Tabs' `TabScreen`).
    var open: @MainActor (ChatConversation) -> Void = { _ in }
    /// Opens the conversation's tab on its Terminal segment.
    var openTerminal: (@MainActor (ChatConversation) -> Void)? = nil
    /// Closes the conversation's tab; Tabs owns the close policy (`close.request` with check).
    var close: (@MainActor (ChatConversation) -> Void)? = nil
    /// Line two: what the agent is doing, the question it waits on, or its last message (`MobileComposition.status`).
    var status: @MainActor (ChatConversation) -> TabsStatus? = { MobileComposition.status($0, session: nil) }
    /// The folder it runs in, as the tab's header names it ("app", "~").
    var folder: @MainActor (ChatConversation) -> String? = { row in
        row.cwd.flatMap { $0.split(separator: "/").last.map(String.init) }
    }
    /// The conversation's tab, for its menu (Rename, Detach, Close) and the split's selection.
    var tab: (@MainActor (ChatConversation) -> TabRef?)? = nil
    var actions: TabsActions? = nil
    /// The hosts, for the empty state and the offline section.
    var hosts: @MainActor () -> [AgentsHost] = { [] }
    var addHost: (() -> Void)? = nil
    var newChat: (() -> Void)? = nil
}

/// The Agents tab: one row per agent conversation across hosts. Needs you first, then the agents working, then the
/// rest by their newest message, and the rows of hosts not reached now in an Offline section at the end, folded on a
/// tap. Each row says where the agent runs (host · folder) and what it is doing in words, the question in full when
/// it waits on the user. Chips filter (All, Needs you with its count, Unread); a row's menu and swipes mute it, mark it
/// read, open its terminal, rename, detach or close its tab. docs/ios.md, Agents.
struct AgentsScreen: View {
    @Bindable var conversations: ChatConversations
    var look = ChatHostLook()
    var context = AgentsContext()
    /// Its own title; off in the app, whose shared stack's bar carries it.
    var chrome = true
    /// Pull to refresh: the links answer and every host's rows are read again; none in the Debug demo.
    var refresh: (@MainActor () async -> Void)?
    @Environment(\.tabsShownTab) private var shownTab
    @AppStorage("agents.offlineFolded") private var offlineFolded = false
    @AppStorage(AgentsGrouping.key) private var grouping = AgentsGrouping.status
    /// Between the list's appearance and disappearance (a change of its first rows meanwhile is reported too).
    @State private var listOnScreen = false

    var body: some View {
        let all = conversations.conversations
        let hosts = context.hosts()
        TimelineView(.everyMinute) { timeline in
            List {
                if !all.isEmpty {
                    Section {
                        AgentsFilterRow(filter: $conversations.filter, needsYou: conversations.needsYouCount)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    } footer: {
                        // Every host's last update, where the rows mix hosts (once the large title's subtitle).
                        if let line = HostFreshness.summary(hosts.map(\.freshness), now: timeline.date) {
                            Text(line).accessibilityIdentifier("agents-freshness")
                        }
                    }
                    .listSectionSpacing(4)
                }
                if grouping == .status {
                    let sections = AgentsSections(rows: conversations.visible, offline: { offline($0) })
                    section("Needs you", sections.needsYou, now: timeline.date)
                    section("Working", sections.working, now: timeline.date)
                    section(sections.needsYou.isEmpty && sections.working.isEmpty ? nil : "Recent", sections.recent, now: timeline.date)
                    if !sections.offline.isEmpty {
                        offlineSection(sections.offline, hosts: hosts, now: timeline.date)
                    }
                } else {
                    ForEach(AgentsGroup.groups(conversations.visible, by: grouping, hosts: hosts.map(\.id))) { group in
                        hostGroup(group, hosts: hosts, now: timeline.date)
                    }
                }
                if !all.isEmpty, conversations.visible.isEmpty {
                    filteredEmpty
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .hostsRefreshable(refresh)
            .background { SectionScrollLink().accessibilityHidden(true) }
            .animation(.default, value: conversations.visible.map(\.id))
        }
        .overlay {
            if all.isEmpty { AgentsEmptyState(hosts: hosts, context: context, refresh: refresh) }
        }
        .modifier(AgentsChrome(on: chrome))
        // The first rows as shown open ahead of a tap while the list is on screen
        // (`ChatConversations.agentsListShown`).
        .onChange(of: firstRows(hosts: hosts)) { _, rows in
            if listOnScreen { conversations.agentsListShown(rows) }
        }
        .onAppear {
            listOnScreen = true
            conversations.agentsListShown(firstRows(hosts: hosts))
        }
        .onDisappear {
            listOnScreen = false
            conversations.agentsListHidden()
        }
    }

    /// The keys of the rows the list shows first, in its order (`shownOrder`).
    private func firstRows(hosts: [AgentsHost]) -> [ChatConversationKey] {
        Self.shownOrder(conversations.visible, grouping: grouping, hosts: hosts.map(\.id), offline: { offline($0) },
                        offlineFolded: offlineFolded).prefix(ChatConversations.prewarmCount).map(\.key)
    }

    /// The rows top to bottom as the list draws them: by status, its sections in order (Needs you, Working, Recent,
    /// then Offline unless folded); by host or by host and space, the groups in order.
    static func shownOrder(_ rows: [ChatConversation], grouping: AgentsGrouping, hosts: [UUID],
                           offline: (ChatConversation) -> Bool, offlineFolded: Bool) -> [ChatConversation] {
        guard grouping == .status else { return AgentsGroup.groups(rows, by: grouping, hosts: hosts).flatMap(\.rows) }
        let sections = AgentsSections(rows: rows, offline: offline)
        return sections.needsYou + sections.working + sections.recent + (offlineFolded ? [] : sections.offline)
    }

    /// A host not reached now (failed, disconnected): its rows are what the phone last saw.
    private func offline(_ row: ChatConversation) -> Bool {
        guard let link = conversations.hosts[row.key.host]?.link else { return true }
        return !link.isConnected && !link.isPending
    }

    @ViewBuilder private func section(_ title: String?, _ rows: [ChatConversation], now: Date) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in item(row, now: now) }
            } header: {
                if let title { header(title, count: rows.count) }
            }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func offlineSection(_ rows: [ChatConversation], hosts: [AgentsHost], now: Date) -> some View {
        let offlineHosts = hosts.filter { host in rows.contains { $0.key.host == host.id } }
        return Section {
            if !offlineFolded {
                ForEach(rows) { row in item(row, now: now) }
            }
        } header: {
            Button { withAnimation { offlineFolded.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Offline")
                    Text("\(rows.count)").foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(offlineFolded ? -90 : 0))
                        .font(.footnote.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Offline, \(rows.count)")
            .accessibilityValue(offlineFolded ? "Folded" : "Shown")
            .accessibilityAddTraits(.isHeader)
        } footer: {
            if !offlineFolded {
                // Each host's last update and why it is not reached: the rows are as it last said.
                Text(offlineHosts.map { host in
                    let state = HostFreshness.label(state: host.state, updated: host.updated, now: now)
                    return host.name + " · " + state + (host.problem.map { " · " + $0 } ?? "")
                }.joined(separator: "\n"))
            }
        }
    }

    /// A host's rows (grouped by host), or one space's (by host and space); a host not reached says so under its last
    /// group, as the Offline section does.
    private func hostGroup(_ group: AgentsGroup, hosts: [AgentsHost], now: Date) -> some View {
        Section {
            ForEach(group.rows) { row in item(row, now: now) }
        } header: {
            HStack(spacing: 6) {
                Text(group.hostName).foregroundStyle(look.tint(group.host))
                if let space = group.space { Text("· " + space) }
                Text("\(group.rows.count)").foregroundStyle(.tertiary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        } footer: {
            if group.last, let row = group.rows.first, offline(row), let host = hosts.first(where: { $0.id == group.host }) {
                let state = HostFreshness.label(state: host.state, updated: host.updated, now: now)
                Text(state + (host.problem.map { " · " + $0 } ?? ""))
            }
        }
    }

    private func item(_ row: ChatConversation, now: Date) -> some View {
        let tab = context.tab?(row)
        let selected = shownTab != nil && tab == shownTab
        return Button { context.open(row) } label: {
            AgentRow(row: row, status: context.status(row), location: location(row),
                     host: grouping == .status ? row.hostName : nil, tint: look.tint(row.key.host), now: now, selected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("agents-row")
        // Under an iPad's pointer: the highlight Spaces' rows have (a plain button in a list has none).
        .tabsRowHover()
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
        .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
        .listRowBackground(selected ? Color.primary.opacity(0.08) : nil)
        .contextMenu { menu(row, tab: tab) }
        // Close as Spaces' rows have it, without the delete role: the row stays while Tabs asks (a working agent) or
        // the host refuses, instead of sliding out and back. Not on a host not reached: there is nothing to close.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let close = context.close, !offline(row) {
                Button { close(row) } label: { Label("Close", systemImage: "xmark") }
                    .tint(Color.destructive)
            }
            Button { conversations.setMuted(!row.muted, row) } label: {
                Label(row.muted ? "Unmute" : "Mute", systemImage: row.muted ? "bell" : "bell.slash")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if row.unread {
                Button { conversations.markRead(row.key) } label: { Label("Read", systemImage: "envelope.open") }
                    .tint(Color.stateUnread)
            }
        }
    }

    @ViewBuilder private func menu(_ row: ChatConversation, tab: TabRef?) -> some View {
        Button("Open Chat", systemImage: "bubble.left.and.bubble.right") { context.open(row) }
        if let openTerminal = context.openTerminal {
            Button("Open Terminal", systemImage: "apple.terminal") { openTerminal(row) }
        }
        if row.unread {
            Button("Mark as Read", systemImage: "envelope.open") { conversations.markRead(row.key) }
        }
        Button(row.muted ? "Unmute" : "Mute", systemImage: row.muted ? "bell" : "bell.slash") {
            conversations.setMuted(!row.muted, row)
        }
        if let tab, let actions = context.actions, !offline(row) {
            Divider()
            TabsTabMenu(actions: actions, tab: tab)
        }
    }

    /// "studio · app": where the agent runs; the space's name when the folder is not known.
    private func location(_ row: ChatConversation) -> String {
        let place = context.folder(row) ?? row.space
        return [row.hostName, place].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var filteredEmpty: some View {
        VStack(spacing: 6) {
            Text(conversations.filter == .needsYou ? "Nothing needs you" : "Nothing unread")
                .font(.headline)
            Text(conversations.filter == .needsYou ? "Agents waiting on an approval or a question show up here."
                 : "Results you have not read and agents that need you show up here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show All") { conversations.filter = .all }
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowBackground(Color.clear)
    }
}

/// The list's sections: rows of hosts not reached now apart, the rest by what they need (the model's order within).
struct AgentsSections {
    var needsYou: [ChatConversation] = []
    var working: [ChatConversation] = []
    var recent: [ChatConversation] = []
    var offline: [ChatConversation] = []

    init(rows: [ChatConversation], offline isOffline: (ChatConversation) -> Bool) {
        for row in rows {
            if isOffline(row) { offline.append(row); continue }
            switch row.urgency {
            case .waiting: needsYou.append(row)
            case .running: working.append(row)
            case .unread, .idle: recent.append(row)
            }
        }
    }

    var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && recent.isEmpty && offline.isEmpty }
}

/// How the list groups its rows (the Group menu by the title, kept across launches): by what they need (Needs you,
/// Working, Recent, Offline), by host, or by host and space.
enum AgentsGrouping: String, CaseIterable, Identifiable {
    case status, host, space
    static let key = "agents.grouping"
    var id: Self { self }
    var title: String {
        switch self {
        case .status: "Status"
        case .host: "Host"
        case .space: "Host and Space"
        }
    }
    var symbol: String {
        switch self {
        case .status: "exclamationmark.bubble"
        case .host: "desktopcomputer"
        case .space: "square.on.square"
        }
    }
}

/// One group of rows when grouped by host, or by host and space: the hosts in their list's order, a host's spaces by
/// their most pressing row (the model's order: needs you, working, newest).
struct AgentsGroup: Identifiable {
    let id: String
    let host: UUID
    let hostName: String
    let space: String?
    var rows: [ChatConversation]
    var title: String { [hostName, space].compactMap { $0 }.joined(separator: " · ") }
    /// The host's last group: where a host not reached says why.
    var last = false

    static func groups(_ rows: [ChatConversation], by grouping: AgentsGrouping, hosts order: [UUID]) -> [AgentsGroup] {
        var groups: [AgentsGroup] = []
        var index: [String: Int] = [:]
        for row in rows {
            let space = grouping == .space ? row.space : nil
            let id = row.key.host.uuidString + "/" + (space ?? "")
            if let at = index[id] {
                groups[at].rows.append(row)
            } else {
                index[id] = groups.count
                groups.append(AgentsGroup(id: id, host: row.key.host, hostName: row.hostName, space: space, rows: [row]))
            }
        }
        // Stable: within a host its groups keep their order.
        let rank = { (host: UUID) in order.firstIndex(of: host) ?? order.count }
        groups = groups.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.host), rank(b.element.host))
            if ra != rb { return ra < rb }
            if a.element.host != b.element.host { return a.element.title < b.element.title }
            return a.offset < b.offset
        }.map(\.element)
        for at in groups.indices where at == groups.count - 1 || groups[at + 1].host != groups[at].host {
            groups[at].last = true
        }
        return groups
    }
}

/// One conversation: the gutter dot (blue needs you or unread, amber working), its name and time, what it is doing
/// in two lines (the question in the primary colour when it waits on the user), and its host under the time in the
/// host's colour (none when
/// the list groups by host: the section names it). Three lines at most (A1). A row whose data is not live dims whole,
/// dot included, until its host answers.
struct AgentRow: View {
    let row: ChatConversation
    let status: TabsStatus?
    /// "studio · app", for VoiceOver.
    let location: String
    /// The host's name under the time, in the host's colour.
    var host: String?
    var tint: Color = .secondary
    var now = Date()
    var selected = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(row.dot?.color ?? .clear)
                .frame(width: 10, height: 10)
                .frame(width: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.headline).lineLimit(1).truncationMode(.tail)
                    if row.muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 2)
                    if let time = TabsTime.label(row.summary.lastActivity, now: now) {
                        Text(time)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                if status != nil || host != nil {
                    // Beside the status, not under it: its second line stays in the status's column.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if let status {
                                TabsStatusText(status: TabsStatus(text: Self.capitalized(status.text), since: status.since,
                                                                  note: status.note), lines: 2)
                            } else {
                                Text(verbatim: "")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(needsYou ? Color.primary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let host {
                            Text(host)
                                .font(.subheadline)
                                .foregroundStyle(tint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .opacity(row.stale ? 0.55 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(Self.value(row, status: status, location: location, now: now))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var needsYou: Bool { row.urgency == .waiting }

    /// The fallbacks ("needs you", "working") start a line of their own.
    static func capitalized(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// What VoiceOver reads after the name: its state in words, muted, the line, where, when, and whether it is live.
    static func value(_ row: ChatConversation, status: TabsStatus?, location: String, now: Date) -> String {
        let state: String? = switch row.urgency {
        case .waiting: "Needs you"
        case .running: "Working"
        case .unread: "Unread"
        case .idle: nil
        }
        return [state, row.muted ? "Muted" : nil, status?.note, status.map { capitalized($0.text) }, location,
                TabsTime.label(row.summary.lastActivity, now: now), row.stale ? "Not up to date" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// Agents' filter chips, as Spaces' (`SpacesFilterRow`): All, Needs you with its count, Unread.
struct AgentsFilterRow: View {
    @Binding var filter: AgentsFilter
    let needsYou: Int

    var body: some View {
        // Titled while they fit; in a narrow column (an iPad's sidebar, large text) the chips keep only their glyphs,
        // the selected one its title too, rather than one cut at the edge.
        ViewThatFits(in: .horizontal) {
            chips(titled: { _ in true })
            chips(titled: { $0 == filter })
            chips(titled: { _ in false })
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
        .accessibilityIdentifier("agents-filter")
    }

    private func chips(titled: @escaping (AgentsFilter) -> Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(AgentsFilter.allCases) { chip($0, titled: titled($0)) }
        }
        .fixedSize()
    }

    private func chip(_ item: AgentsFilter, titled: Bool) -> some View {
        let on = item == filter
        return Button { filter = item } label: {
            HStack(spacing: 5) {
                Image(systemName: item.symbol).font(.caption.weight(.semibold))
                if titled { Text(item.title).font(.subheadline.weight(.semibold)) }
                if item == .needsYou, needsYou > 0 {
                    Text("\(needsYou)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.stateUnread, in: Capsule())
                }
            }
            .lineLimit(1)
            .foregroundStyle(on ? Color.onAccent : .primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background { if on { Capsule().fill(Color.dispatchPink) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .accessibilityLabel(item.title)
        .accessibilityValue(item == .needsYou && needsYou > 0 ? "\(needsYou)" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Why there are no rows, and what to do about it: no host yet (Add host), hosts still connecting, none reached
/// (Try again, and why), hosts whose agents are not listed (Chat off, plain SSH), or hosts reached with no agent
/// running (New chat).
struct AgentsEmptyState: View {
    let hosts: [AgentsHost]
    let context: AgentsContext
    var refresh: (@MainActor () async -> Void)?

    enum Kind: Equatable {
        case noHosts, connecting([String]), offline([String]), notListed([String]), noAgents
    }

    static func kind(_ hosts: [AgentsHost]) -> Kind {
        guard !hosts.isEmpty else { return .noHosts }
        let listing = hosts.filter(\.listsAgents)
        guard !listing.isEmpty else { return .notListed(hosts.map(\.name)) }
        if listing.contains(where: { $0.state == .connected }) { return .noAgents }
        let connecting = listing.filter { $0.state == .connecting }
        if !connecting.isEmpty { return .connecting(connecting.map(\.name)) }
        return .offline(listing.map(\.name))
    }

    var body: some View {
        switch Self.kind(hosts) {
        case .noHosts:
            MobileEmptyState(section: .agents) { context.addHost?() }
        case .connecting(let names):
            message(symbol: nil, title: "Connecting", text: "Reaching \(Self.list(names))…")
        case .offline(let names):
            let reasons = hosts.compactMap { host in host.problem.map { host.name + ": " + $0 } }
            message(symbol: "wifi.slash", title: "No host reached",
                    text: ([Self.list(names) + (names.count == 1 ? " is" : " are") + " not connected."] + reasons)
                        .joined(separator: "\n"),
                    action: refresh.map { refresh in ("Try Again", { Task { await refresh() } }) })
        case .notListed(let names):
            message(symbol: "terminal", title: "No agents listed",
                    text: "Chat is off for \(Self.list(names)), so its agents stay terminals. Turn on Chat in the host's settings to see them here.")
        case .noAgents:
            message(symbol: "bubble.left.and.bubble.right", title: "No agents running",
                    text: "Start Claude, Codex or Pi in a space's tab, or start a chat here.",
                    action: context.newChat.map { new in ("New Chat", new) })
        }
    }

    static func list(_ names: [String]) -> String {
        names.count <= 2 ? names.joined(separator: " and ") : names.prefix(2).joined(separator: ", ") + " and \(names.count - 2) more"
    }

    private func message(symbol: String?, title: String, text: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, height: 72)
                    .background(Color.faintFill, in: Circle())
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.large).padding(.bottom, 6)
            }
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.1) {
                    Text(action.0)
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .frame(minHeight: 50)
                }
                .buttonStyle(MobileCallToAction())
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension AgentsHost {
    var freshness: HostFreshness { HostFreshness(id: id, name: name, tint: .clear, state: state, updated: updated) }
}

private struct AgentsChrome: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content
                .navigationTitle("Agents")
                .toolbarTitleDisplayMode(.large)
                .toolbar { AgentsToolbar() }
        } else {
            content
        }
    }
}

/// Agents' item by the title, where Spaces has Edit: the Group menu (Status, Host, Host and Space). An icon in the bar;
/// a glyph in the Duo's narrow sidebar; a glass disc in the iPad's sidebar (`circle`), as its filter and Edit.
struct AgentsToolbar: ToolbarContent {
    var glyph = false

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { AgentsGroupMenu(glyph: glyph) }
    }
}

struct AgentsGroupMenu: View {
    var glyph = false
    var circle = false
    @AppStorage(AgentsGrouping.key) private var grouping = AgentsGrouping.status

    var body: some View {
        let on = grouping != .status
        Menu {
            Picker("Group By", selection: $grouping) {
                ForEach(AgentsGrouping.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            if circle {
                Image(systemName: "rectangle.3.group")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(on ? Color.onAccent : Color.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            } else if glyph {
                Image(systemName: "rectangle.3.group")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(on ? Color.dispatchPink : .primary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            } else {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(on ? Color.dispatchPink : .primary)
            }
        }
        .modifier(AgentsGroupCircle(on: circle, tinted: on))
        .accessibilityLabel("Group")
        .accessibilityValue(grouping.title)
        .accessibilityIdentifier("agents-group")
    }
}

private struct AgentsGroupCircle: ViewModifier {
    let on: Bool
    let tinted: Bool
    func body(content: Content) -> some View {
        if on {
            content
                .menuStyle(.button)
                .buttonStyle(.plain)
                .glassEffect(tinted ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Circle())
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
        } else {
            content
        }
    }
}
