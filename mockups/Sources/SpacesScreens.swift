import SwiftUI

// The Spaces screens reworked: tree only, a filter row instead of the sort menu, a space screen that matches the Mac
// strip, and the host disc on a tab opening a space switcher sheet.

struct MockTab: Identifiable {
    let name: String        // the Mac strip's label: the program, or the agent
    let kind: String        // "chat" or "terminal"
    let line: String        // what it is doing
    let time: String
    var dot: Color? = nil
    var current = false
    var id: String { name + line }
}

enum MockSpaces {
    /// The line follows the state: the current step while working, the question while waiting, the last message
    /// once done. The agent is the row's glyph, the model stays in the chat.
    static let appTabs: [MockTab] = [
        .init(name: "Sidebar theme toggle", kind: "claude", line: "Editing Sidebar.tsx · 48s", time: "now", dot: .stateWorking),
        .init(name: "pnpm dev", kind: "terminal", line: "vite ready · localhost:5173", time: "3:28 AM", current: true),
        .init(name: "zsh", kind: "terminal", line: "~/src/app", time: "3:06 AM"),
        .init(name: "Rate limiter for the API", kind: "codex", line: "Allow cargo test --workspace?", time: "2:51 AM", dot: .stateUnread),
        .init(name: "Docs site migration", kind: "claude", line: "Moved the docs to Starlight; the old MkDocs config is gone.", time: "1:12 AM"),
    ]
}

/// P1: Spaces, tree only. The capsule's tree toggle is gone; a filter row under the title replaces the sort menu.
struct SpacesRootScreen: View {
    var filter = 0
    /// iPad: the space whose tab is open in the detail column.
    var selected: String? = nil
    /// iPad: the stats popover anchored to mba2's glyph.
    var popover = false
    /// iPad's 320-point sidebar: the filter chips as glyph-only discs in one row.
    var compactFilters = false
    /// iPad: 0 discs under the bar; 1 discs in the bar row between the title and Edit; 2 a single filter menu button.
    var barFilter = 0
    /// iPad without the bottom bar: New as a plus disc in the bar row.
    var newInBar = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if compactFilters {
                        if barFilter == 0 { FilterDiscs(selected: filter) }
                    } else { FilterRow(selected: filter) }
                    hostSection("mba2", glyph: "apple.logo", tint: hostTint, mux: "herdr",
                                spaces: [("app", "dark-mode", "1", true), ("e2e", nil, "", false)], detached: 2)
                    hostSection("studio", glyph: "apple.logo", tint: .primary, mux: "tmux",
                                spaces: [("docs", "main", "1", false), ("billing", "fix/invoices", "", false)])
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 6) {
                            Text("Offline").textCase(.uppercase)
                            Text("1").foregroundStyle(.tertiary)
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                        hostHeader("ai", glyph: "point.3.connected.trianglepath.dotted", tint: Color.codeType, mux: "herdr", note: "as of 2h ago", offline: true)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 16).padding(.top, 2)
            }
            .background(Color.canvas)
            .safeAreaBar(edge: .bottom) {
                if newInBar {
                    // The Mac's sidebar footer: "+ space ⌘N" as a button under the tree.
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                        Text("New space").font(.body.weight(.semibold))
                        Spacer()
                        Text("⌘N").font(.subheadline).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16).frame(height: 44)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .navigationTitle(compactFilters ? "" : "Spaces")
            // The iPad sidebar (320 points) puts the title on the bar's row at the leading edge, as Apple's iPad
            // sidebars do, with Edit at the trailing end of the same row; the phone keeps the large title.
            .navigationBarTitleDisplayMode(compactFilters ? .inline : .large)
            .toolbar {
                if compactFilters {
                    ToolbarItem(placement: .topBarLeading) {
                        HStack(spacing: 10) {
                            if newInBar {
                                // Hide the sidebar, as the Mac's sidebar has its toggle at the top: the strip's leading
                                // pill brings it back.
                                Image(systemName: "sidebar.leading").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.dispatchPink)
                                    .frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
                            }
                            Text("Spaces").font(.title2.weight(.bold)).lineLimit(1).fixedSize().padding(.leading, newInBar ? 0 : 4)
                            if barFilter == 1 { FilterDiscs(selected: filter, spacing: 6).fixedSize() }
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                if compactFilters, barFilter == 2 {
                    ToolbarItem(placement: .topBarTrailing) {
                        // One menu: the current filter's glyph, pink while a filter other than All is on, the count on Needs you.
                        Image(systemName: filter == 1 ? "exclamationmark.bubble" : filter == 2 ? "text.bubble" : "line.3.horizontal.decrease")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(filter == 0 ? Color.primary : Color.onAccent)
                            .frame(width: 44, height: 44)
                            .glassEffect(filter == 0 ? .regular.interactive() : .regular.tint(.dispatchPink).interactive(), in: Circle())
                            .overlay(alignment: .topTrailing) {
                                Text("2").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).frame(height: 16).background(Color.stateUnread, in: Capsule())
                                    .overlay(Capsule().stroke(Color.canvas, lineWidth: 1.5))
                                    .offset(x: 4, y: -3)
                            }
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if compactFilters, barFilter != 0 {
                        Image(systemName: "pencil").font(.body.weight(.semibold)).frame(width: 44, height: 44).glassEffect(.regular.interactive(), in: Circle())
                    } else {
                        Text("Edit").fixedSize().padding(.horizontal, 18).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private func hostHeader(_ name: String, glyph: String, tint: Color, mux: String, note: String? = nil, offline: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.title3.weight(.semibold)).foregroundStyle(offline ? .secondary : .primary)
            Text(mux).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 22).background(Color.chipFill, in: Capsule())
            if let note { Text(note).font(.subheadline).foregroundStyle(.tertiary) }
            Spacer()
            Image(systemName: glyph).font(.subheadline).foregroundStyle(offline ? Color.secondary : tint).frame(width: 34, height: 34)
                .glassEffect(.regular.interactive(), in: Circle())
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(offline ? Color.secondary.opacity(0.5) : Color.stateConnected).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.canvas, lineWidth: 1.5))
                }
                .background { if popover, name == "mba2" { Circle().fill(Color.lens) } }
        }
        .padding(.horizontal, 16)
    }

    /// spaces: (name, branch, count, working)
    private func hostSection(_ name: String, glyph: String, tint: Color, mux: String, spaces: [(String, String?, String, Bool)], detached: Int = 0) -> some View {
        VStack(spacing: 10) {
            hostHeader(name, glyph: glyph, tint: tint, mux: mux)
            VStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 8) {
                        Text(s.0).font(.body)
                        if let branch = s.1 {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                                Text(branch).font(.caption)
                            }
                            .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if s.3 { Circle().fill(Color.stateWorking).frame(width: 10, height: 10) }
                        if !s.2.isEmpty { Text(s.2).font(.body).foregroundStyle(Color.stateUnread) }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .background { if selected == s.0 { Color.lens } }
                    if i < spaces.count - 1 || detached > 0 { Hairline() }
                }
                if detached > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "eject").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        Text("Detached").font(.body).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(detached)").font(.body).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
            }
            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

/// The filter chips as glyph-only 34-point glass discs (iPad sidebar): All, Needs you with its count, Agents; the
/// selected one tinted.
struct FilterDiscs: View {
    var selected = 0
    var spacing: CGFloat = 10
    let items = [("All", "square.on.square"), ("Needs you", "exclamationmark.bubble"), ("Agents", "text.bubble")]
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let on = i == selected
                Image(systemName: item.1).font(.subheadline.weight(.semibold))
                    .foregroundStyle(on ? Color.onAccent : .primary)
                    .frame(width: 34, height: 34)
                    .glassEffect(on ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if i == 1 {
                            Text("2").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).frame(height: 16).background(Color.stateUnread, in: Capsule())
                                .overlay(Capsule().stroke(Color.canvas, lineWidth: 1.5))
                                .offset(x: 7, y: -5)
                        }
                    }
                    .accessibilityLabel(item.0)
            }
            if spacing == 10 { Spacer() }
        }
        .padding(.horizontal, 2).padding(.vertical, spacing == 10 ? 4 : 0)
    }
}

/// Mail-style filter chips: All · Needs you · Chats · Terminals. One line, under the title, scrolls if it must.
struct FilterRow: View {
    var selected = 0
    let items = [("All", "square.on.square"), ("Needs you", "exclamationmark.bubble"), ("Agents", "text.bubble")]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    let on = i == selected
                    HStack(spacing: 5) {
                        Image(systemName: item.1).font(.caption.weight(.semibold))
                        Text(item.0).font(.subheadline.weight(.semibold))
                        if i == 1 { Text("2").font(.caption2.weight(.bold)).foregroundStyle(.white).padding(.horizontal, 5).frame(height: 16).background(Color.stateUnread, in: Capsule()) }
                    }
                    .foregroundStyle(on ? Color.onAccent : .primary)
                    .padding(.horizontal, 12).frame(height: 34)
                    .glassEffect(on ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Capsule())
                }
            }
            .padding(.horizontal, 2).padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// P2: a space, as the Mac strip shows it: tabs named for what runs in them, the kind glyph, what they are doing,
/// the branch in the header; swipe for Close and Detach; Rename and Close space in the menu.
struct SpaceScreen: View {
    var swiped = false
    var menuOpen = false
    /// Edit mode: reorder handles, the red minus, Done.
    var editing = false
    /// New tab held: the agents to start.
    var newTabMenu = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(MockSpaces.appTabs.enumerated()), id: \.element.id) { i, tab in
                            tabRow(tab, index: i)
                                .background(Color.groupedRow)
                                .offset(x: swiped && i == 2 ? -150 : 0)
                                .background(alignment: .trailing) {
                                    if swiped, i == 2 {
                                        HStack(spacing: 0) {
                                            VStack(spacing: 4) { Image(systemName: "eject.fill"); Text("Detach").font(.caption2.weight(.semibold)) }
                                                .foregroundStyle(.white).frame(width: 75).frame(maxHeight: .infinity).background(Color.caution)
                                            VStack(spacing: 4) { Image(systemName: "xmark"); Text("Close").font(.caption2.weight(.semibold)) }
                                                .foregroundStyle(.white).frame(width: 75).frame(maxHeight: .infinity).background(Color.destructive)
                                        }
                                    }
                                }
                                .clipped()
                            if i < MockSpaces.appTabs.count - 1 { Hairline(inset: 60).background(Color.groupedRow) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(.horizontal, 16).padding(.top, 8)
                    Text(editing ? "Drag to reorder. Closing a tab detaches it unless it is idle."
                                 : "Long-press a tab for Rename, Detach and Terminate.")
                        .font(.caption).foregroundStyle(.tertiary).padding(.top, 14)
                    Color.clear.frame(height: 100)
                }
            }
            .background(Color.canvas)
            .overlay(alignment: .topTrailing) {
                if menuOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        menuRow("Rename…", "pencil")
                        menuRow("Edit tabs", "arrow.up.arrow.down")
                        Divider().padding(.vertical, 4)
                        menuRow("Detach", "eject", note: "keeps everything running")
                        menuRow("Terminate…", "xmark.octagon", note: "ends every shell and agent", destructive: true)
                    }
                    .padding(.vertical, 6)
                    .frame(width: 290)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                    .padding(.trailing, 16).padding(.top, 2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !editing {
                    VStack(alignment: .trailing, spacing: 10) {
                        if newTabMenu {
                            VStack(alignment: .leading, spacing: 0) {
                                agentRow("Shell", kind: "terminal", note: "zsh in ~/src/app")
                                Divider().padding(.vertical, 4)
                                agentRow("Claude", kind: "claude", note: "fable-5.1")
                                agentRow("Codex", kind: "codex", note: "astra-6")
                                agentRow("Pi", kind: "pi", note: "pi 1.3")
                                Divider().padding(.vertical, 4)
                                HStack {
                                    Text("In another space…").font(.body)
                                    Spacer()
                                    Image(systemName: "square.on.square").font(.body)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                            }
                            .padding(.vertical, 6)
                            .frame(width: 270)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
                        }
                        Label("New tab", systemImage: "plus").font(.body.weight(.semibold))
                            .padding(.horizontal, 18).frame(height: 50)
                            .glassEffect(newTabMenu ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Capsule())
                            .foregroundStyle(newTabMenu ? Color.onAccent : .primary)
                    }
                    .padding(.trailing, 16).padding(.bottom, 8)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 12) {
                        BackPill(count: nil, title: "Spaces")
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text("app").font(.headline)
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                                    Text("dark-mode").font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            HostPath(path: "~/src/app").font(.caption)
                        }
                        .padding(.leading, 4)
                    }
                    .frame(width: 402 - 52 - (editing ? 78 : 44), alignment: .leading)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        Text("Done").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink).fixedSize()
                            .padding(.horizontal, 18).frame(height: 44).glassEffect(.regular.interactive(), in: Capsule())
                    } else {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    private func agentRow(_ title: String, kind: String, note: String) -> some View {
        HStack(spacing: 12) {
            AgentGlyph(kind: kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func menuRow(_ title: String, _ symbol: String, note: String? = nil, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: symbol).font(.body)
        }
        .foregroundStyle(destructive ? Color.destructive : .primary)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func tabRow(_ tab: MockTab, index: Int) -> some View {
        HStack(spacing: 12) {
            if editing {
                Image(systemName: "minus").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(Color(uiColor: .systemRed), in: Circle())
            } else {
                ZStack {
                    Circle().fill(tab.dot ?? .clear).frame(width: 10, height: 10)
                }
                .frame(width: 14)
            }
            AgentGlyph(kind: tab.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tab.name).font(.headline).lineLimit(1).truncationMode(.tail)
                    if tab.current {
                        Text("open").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).frame(height: 16).background(Color.chipFill, in: Capsule())
                    }
                    Spacer()
                    if editing {
                        Image(systemName: "line.3.horizontal").font(.body).foregroundStyle(.tertiary)
                    } else {
                        Text(tab.time).font(.subheadline).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                Text(tab.line).font(.subheadline).foregroundStyle(tab.dot == .stateUnread ? Color.primary : .secondary).lineLimit(1)
            }
        }
        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 11)
    }
}

/// The agent's mark at the row's leading edge: Claude's sparkle, Codex's angle brackets, Pi's π, a terminal glyph for a shell.
struct AgentGlyph: View {
    let kind: String
    var body: some View {
        Group {
            switch kind {
            case "claude": Image(systemName: "sparkle").foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
            case "codex": Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(.primary)
            case "pi": Text("π").font(.system(size: 18, weight: .semibold, design: .serif)).foregroundStyle(Color.codeType)
            default: Image(systemName: "apple.terminal").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 18))
        .frame(width: 26)
    }
}

/// P3: the host disc on a tab screen opens the space switcher: this space's tabs with the current one marked, New tab,
/// the space's actions, and the host row that leads to its stats.
struct SpaceSwitcherSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 0) {
                        ForEach(Array(MockSpaces.appTabs.enumerated()), id: \.element.id) { i, tab in
                            HStack(spacing: 12) {
                                Circle().fill(tab.dot ?? .clear).frame(width: 10, height: 10).frame(width: 14)
                                AgentGlyph(kind: tab.kind)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.name).font(.headline).lineLimit(1)
                                    Text(tab.line).font(.subheadline).foregroundStyle(tab.dot == .stateUnread ? Color.primary : .secondary).lineLimit(1)
                                }
                                Spacer()
                                if tab.current { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink) }
                            }
                            .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 11)
                            .background { if tab.current { Color.lens } }
                            if i < MockSpaces.appTabs.count - 1 { Hairline(inset: 60) }
                        }
                        Hairline(inset: 60)
                        HStack(spacing: 12) {
                            Color.clear.frame(width: 14)
                            Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.dispatchPink).frame(width: 26)
                            Text("New tab").font(.headline).foregroundStyle(Color.dispatchPink)
                            Spacer()
                        }
                        .padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 13)
                    }
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22))

                    // The host: stats at a tap, as the Spaces list's glyph.
                    HStack(spacing: 12) {
                        Image(systemName: "apple.logo").font(.system(size: 17)).foregroundStyle(hostTint)
                            .frame(width: 34, height: 34).background(hostTint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("mba2").font(.headline)
                            Text("34% cpu · 34% mem · 18 ms").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22))

                    HStack(spacing: 10) {
                        Label("Rename", systemImage: "pencil").font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                        Label("Close space", systemImage: "xmark").font(.body.weight(.semibold)).foregroundStyle(Color.destructive)
                            .frame(maxWidth: .infinity).frame(height: 50).glassEffect(.regular.interactive(), in: Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            .background(Color.canvas)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Text("app").font(.headline)
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                                Text("dark-mode").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                        HostPath(path: "~/src/app").font(.caption)
                    }
                }
                ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "xmark") } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct SpaceSwitcherHost: View {
    var body: some View {
        HybridTerminalScreen()
            .sheet(isPresented: .constant(true)) {
                SpaceSwitcherSheet()
                    .presentationDetents([.height(560), .large])
                    .presentationDragIndicator(.visible)
            }
    }
}
