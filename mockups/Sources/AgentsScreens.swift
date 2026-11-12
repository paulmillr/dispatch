import SwiftUI

// The Agents tab (A1, A2), as the app draws it (`AgentsScreen` in Mobile/Agents/AgentsScreen.swift; docs/ios.md,
// Agents): one row per agent conversation across hosts, Needs you first, then Working, Recent, and the rows of hosts not
// reached now under Offline; chips All · Needs you · Unread; the row's menu; the empty states.

/// One conversation's row data (`ChatConversation` with its `MobileComposition.status` line).
struct MockAgent: Identifiable {
    enum State { case needsYou, working, unread, idle }
    let name: String
    let state: State
    let line: String
    let host: String
    let folder: String
    let time: String
    var muted = false
    /// A host not reached now: the row is what the phone last saw, dimmed whole.
    var stale = false
    var id: String { name }

    /// The gutter dot (`ChatConversation.dot`): blue needs you or unread, amber working; none when muted unless it waits.
    var dot: Color? {
        switch state {
        case .needsYou: .stateUnread
        case .working: muted ? nil : .stateWorking
        case .unread: muted ? nil : .stateUnread
        case .idle: nil
        }
    }
}

enum MockAgents {
    static func tint(_ host: String) -> Color {
        switch host {
        case "mba2": hostTint
        case "studio": Color(red: 0xB0 / 255, green: 0x8C / 255, blue: 0xD9 / 255)
        case "ai": Color.codeType
        default: Color(red: 0xE0 / 255, green: 0x9A / 255, blue: 0x5E / 255)
        }
    }

    static let needsYou: [MockAgent] = [
        .init(name: "Fix the retry loop", state: .needsYou, line: "Allow cargo test --workspace?", host: "mba2", folder: "api", time: "now"),
        .init(name: "Release notes", state: .needsYou, line: "Which changelog format should I use?", host: "studio", folder: "docs", time: "3:36 AM"),
    ]
    static let working: [MockAgent] = [
        .init(name: "Sidebar theme toggle", state: .working, line: "Editing file… · 48s", host: "mba2", folder: "app", time: "now"),
        .init(name: "Invoice export", state: .working, line: "Running shell command… · 3m", host: "studio", folder: "billing", time: "3:38 AM"),
    ]
    static let recent: [MockAgent] = [
        .init(name: "Docs site migration", state: .unread,
              line: "Moved the docs to Starlight; the old MkDocs config is gone and every old link redirects.",
              host: "ai", folder: "docs", time: "3:12 AM"),
        .init(name: "Flaky login test", state: .idle,
              line: "The login test waits for the session cookie now, and it passed twenty runs in a row.",
              host: "mba2", folder: "e2e", time: "2:47 AM", muted: true),
        .init(name: "Rate limiter for the API", state: .idle,
              line: "Added a token bucket per key, with a 429 and Retry-After once it runs dry.",
              host: "ai", folder: "api", time: "Yesterday"),
    ]
    static let offline: [MockAgent] = [
        .init(name: "Nightly backup check", state: .unread, line: "All seven nightly backups restored cleanly into a scratch database.",
              host: "vps", folder: "ops", time: "1:40 AM", stale: true),
        .init(name: "Log rotation", state: .idle, line: "Logs rotate daily now and keep two weeks.", host: "vps", folder: "~",
              time: "Yesterday", stale: true),
    ]
}

/// The phone's root with the Agents tab selected and its item badged with the needs-you count (`MobileRoot`).
struct AgentsTabBar<Content: View>: View {
    var badge = 2
    @ViewBuilder var content: Content
    private static var newRole: TabRole {
        if #available(iOS 27, *) { .prominent } else { .search }
    }
    var body: some View {
        TabView(selection: .constant(1)) {
            Tab(value: 0) { Color.canvas } label: { Label { Text("Spaces") } icon: { Image(systemName: "square.on.square").environment(\.symbolVariants, .none) } }
            Tab(value: 1) { content } label: { Label { Text("Agents") } icon: { Image(systemName: "bubble.left.and.bubble.right").environment(\.symbolVariants, .none) } }
                .badge(badge)
            Tab(value: 2, role: Self.newRole) { Color.canvas } label: {
                Label { Text("New chat") } icon: { Image(systemName: "square.and.pencil").environment(\.symbolVariants, .none) }
            }
        }
        .tint(.primary)
    }
}

/// A1: the list. `filter` 0 All, 1 Needs you, 2 Unread; `scrolled` to its end (A1d: Recent and Offline).
struct AgentsListScreen: View {
    var filter = 0
    var scrolled = false
    /// A1e: grouped by host (the Group menu's Host), each host a section, the host gone from its rows.
    var byHost = false
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        AgentsChips(selected: filter)
                        // In from the chip's edge to its text: the row's rounded corner masks a line at its bottom
                        // leading edge (the app's 4 points lose the first letter).
                        Text("Updated just now · vps offline")
                            .font(.footnote).foregroundStyle(.secondary).padding(.leading, 14)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
                }
                .listSectionSpacing(4)
                if byHost {
                    let all = MockAgents.needsYou + MockAgents.working + MockAgents.recent
                    ForEach(["mba2", "studio", "ai"], id: \.self) { host in
                        section(host, all.filter { $0.host == host }, tint: MockAgents.tint(host))
                    }
                    Section {
                        ForEach(MockAgents.offline) { row($0) }
                    } header: {
                        HStack(spacing: 6) {
                            Text("vps").foregroundStyle(MockAgents.tint("vps"))
                            Text("\(MockAgents.offline.count)").foregroundStyle(.tertiary).monospacedDigit()
                        }
                    } footer: {
                        Text("Offline · updated 2h ago · Connection refused")
                    }
                } else {
                section("Needs you", MockAgents.needsYou)
                }
                if filter == 0, !byHost {
                    section("Working", MockAgents.working)
                    section("Recent", MockAgents.recent)
                    Section {
                        ForEach(MockAgents.offline) { row($0) }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Offline")
                            Text("\(MockAgents.offline.count)").foregroundStyle(.tertiary).monospacedDigit()
                            Spacer()
                            Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                        }
                    } footer: {
                        Text("vps · Offline · updated 2h ago · Connection refused")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listSectionSpacing(20)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .task {
                // A1d: Recent's first row at the top, so Offline and its footer show above the tab bar.
                guard scrolled else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(MockAgents.recent[0].id, anchor: .top)
            }
            }
            .background(Color.canvas)
            .navigationTitle("Agents")
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: "rectangle.3.group")
                        .foregroundStyle(byHost ? Color.dispatchPink : .primary)
                }
            }
        }
    }

    private func section(_ title: String, _ rows: [MockAgent], tint: Color? = nil) -> some View {
        Section {
            ForEach(rows) { row($0) }
        } header: {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(tint ?? .secondary)
                Text("\(rows.count)").foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }

    private func row(_ agent: MockAgent) -> some View {
        AgentRowMock(agent: agent, host: !byHost)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
            .alignmentGuide(.listRowSeparatorLeading) { _ in 36 }
            .listRowBackground(Color.groupedRow)
    }
}

/// `AgentRow`, three lines at most: the gutter dot, name (bell.slash when muted) and time; the status in two lines
/// (the question in the primary colour; a working agent's step by its kind only), beside the host's name in its colour
/// under the time (none when grouped by host: the section's name takes the colour). A stale row dims whole, dot included.
struct AgentRowMock: View {
    let agent: MockAgent
    var host = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(agent.dot ?? .clear).frame(width: 10, height: 10).frame(width: 14)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name).font(.headline).lineLimit(1).truncationMode(.tail)
                    if agent.muted {
                        Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Text(agent.time).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).fixedSize().layoutPriority(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(agent.line).font(.subheadline)
                        .foregroundStyle(agent.state == .needsYou ? Color.primary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if host {
                        Text(agent.host).font(.subheadline).foregroundStyle(MockAgents.tint(agent.host))
                            .lineLimit(1).layoutPriority(1)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .opacity(agent.stale ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// `AgentsFilterRow`: All, Needs you with its count, Unread; the selected chip filled pink, every chip on glass.
struct AgentsChips: View {
    var selected = 0
    let items = [("All", "bubble.left.and.bubble.right"), ("Needs you", "exclamationmark.bubble"), ("Unread", "envelope.badge")]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let on = i == selected
                    HStack(spacing: 5) {
                        Image(systemName: item.1).font(.caption.weight(.semibold))
                        Text(item.0).font(.subheadline.weight(.semibold))
                        if i == 1 {
                            Text("2").font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                                .background(Color.stateUnread, in: Capsule())
                        }
                    }
                    .lineLimit(1)
                    .foregroundStyle(on ? Color.onAccent : .primary)
                    .padding(.horizontal, 12).frame(minHeight: 34)
                    .background { if on { Capsule().fill(Color.dispatchPink) } }
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// A1c: a row held: the list blurred behind, the row lifted, its menu under it (Open Chat, Open Terminal, Mark as Read,
/// Mute, then the tab's Rename…, Detach, Close Tab), drawn as P2c draws a menu.
struct AgentsMenuScreen: View {
    var body: some View {
        AgentsTabBar { AgentsListScreen() }
            .blur(radius: 9)
            .overlay {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 10) {
                        AgentRowMock(agent: MockAgents.recent[0])
                            .padding(.leading, 12).padding(.trailing, 16)
                            .frame(width: 370)
                            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22))
                        VStack(alignment: .leading, spacing: 0) {
                            menuRow("Open Chat", "bubble.left.and.bubble.right")
                            menuRow("Open Terminal", "apple.terminal")
                            menuRow("Mark as Read", "envelope.open")
                            menuRow("Mute", "bell.slash")
                            Divider().padding(.vertical, 4)
                            menuRow("Rename…", "pencil")
                            Divider().padding(.vertical, 4)
                            menuRow("Detach", "eject")
                            menuRow("Close Tab", "xmark")
                        }
                        .padding(.vertical, 6)
                        .frame(width: 250)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .padding(.leading, 16).padding(.top, 330)
                }
            }
    }

    private func menuRow(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.body)
            Spacer()
            Image(systemName: symbol).font(.body)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// A2: `AgentsEmptyState`, why there are no rows: no host reached (each problem, Try Again), or none running (New Chat).
struct AgentsEmptyScreen: View {
    enum Kind { case offline, noAgents }
    let kind: Kind
    var body: some View {
        AgentsTabBar(badge: 0) {
            NavigationStack {
                Group {
                    switch kind {
                    case .offline:
                        message(symbol: "wifi.slash", title: "No host reached",
                                text: "studio and vps are not connected.\nvps: Connection refused", action: "Try Again")
                    case .noAgents:
                        message(symbol: "bubble.left.and.bubble.right", title: "No agents running",
                                text: "Start Claude, Codex or Pi in a space's tab, or start a chat here.", action: "New Chat")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .navigationTitle("Agents")
                .toolbarTitleDisplayMode(.large)
            }
        }
    }

    private func message(symbol: String, title: String, text: String, action: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
                .frame(width: 72, height: 72).background(Color.faintFill, in: Circle())
            Text(title).font(.title2.weight(.bold)).multilineTextAlignment(.center)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(action).font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 8).frame(minHeight: 50)
                .foregroundStyle(Color.onAccent)
                .background(Color.dispatchPink, in: Capsule())
                .shadow(color: Color.dispatchPink.opacity(0.3), radius: 9, y: 6)
                .padding(.top, 8)
        }
        .padding(.horizontal, 36)
    }
}
