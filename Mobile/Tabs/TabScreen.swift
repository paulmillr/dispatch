import SwiftUI

enum TabSegment: String, CaseIterable, Identifiable {
    case terminal, chat
    var id: Self { self }
    var title: String { self == .terminal ? "Terminal" : "Chat" }

    /// Chat when the tab runs an agent, else Terminal (M4a, M6a).
    @MainActor static func initial(for tab: MobileTab) -> TabSegment { tab.isChat ? .chat : .terminal }
}

extension TabScreen where Terminal == AnyView, Chat == AnyView {
    /// With the injected segment views (`TabsContent`).
    init(model: MobileTabs, ref: TabRef, path: Binding<[TabsRoute]>, content: TabsContent) {
        self.init(model: model, ref: ref, path: path, terminal: content.terminal, chat: content.chat,
                  terminalSubtitle: content.terminalSubtitle)
    }
}

/// One tab, shared by Chat and Terminal (M4a, M5a, M6a top area): the back pill with the needs-you count, the title,
/// the subtitle (host · cwd in Chat; host · cwd · shell in Terminal) that becomes the pane switcher when the window has
/// splits, the host disc that opens space details, and the Terminal / Chat segmented control over the two injected
/// views. The views get the pane to show: Terminal the active pane, Chat the pane running the agent.
struct TabScreen<Terminal: View, Chat: View>: View {
    let model: MobileTabs
    let ref: TabRef
    @Binding var path: [TabsRoute]
    let terminal: @MainActor (MobileTab, MobilePane) -> Terminal
    let chat: @MainActor (MobileTab, MobilePane) -> Chat
    /// The Terminal segment's subtitle after the host (`TabsContent.terminalSubtitle`).
    var terminalSubtitle: @MainActor (MobileTab, MobilePane) -> String? = { _, _ in nil }

    @State private var segment: TabSegment?

    var body: some View {
        let tab = model.tab(ref)
        let workspace = model.workspace(ref.host)
        VStack(spacing: 0) {
            if let tab {
                TabSegmentControl(selection: Binding(get: { current(tab) }, set: { choose($0) }))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                Group {
                    switch current(tab) {
                    case .terminal:
                        if let pane = tab.activePane { terminal(tab, pane) } else { TabGone() }
                    case .chat:
                        if let pane = tab.agentPane { chat(tab, pane) } else { TabNoAgent() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TabGone().frame(maxHeight: .infinity)
            }
        }
        .tabsPushedScreen()
        .toolbar {
            if let tab, let workspace {
                TabScreenHeader(tab: tab, host: workspace.host, space: workspace.space(of: tab), needsYou: model.needsYou(excluding: ref),
                                segment: current(tab), terminalSubtitle: tab.activePane.flatMap { terminalSubtitle(tab, $0) },
                                back: back, details: { path.append(.details(tab.space)) })
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    TabsBackPill(label: "\(model.needsYou())", count: true, action: back)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .onAppear {
            guard let tab else { return }
            model.visited(tab.space)
            // The segment the tab opened on stays until the user picks the other one: an agent starting in the shell
            // (or a snapshot briefly without its binding) does not flip the screen under the user's fingers.
            if segment == nil { segment = current(tab) }
        }
    }

    private func current(_ tab: MobileTab) -> TabSegment {
        segment ?? model.segments[ref] ?? TabSegment.initial(for: tab)
    }

    private func choose(_ next: TabSegment) {
        segment = next
        model.segments[ref] = next
    }

    private func back() { if !path.isEmpty { path.removeLast() } }
}

/// The top of a tab (M4a): back pill "‹ 1", title, subtitle or pane switcher, host disc.
struct TabScreenHeader: ToolbarContent {
    let tab: MobileTab
    let host: TabsHost
    let space: MobileSpace?
    let needsYou: Int
    let segment: TabSegment
    /// Terminal's "~/src/app · zsh" from the terminal itself, when it knows.
    var terminalSubtitle: String? = nil
    let back: () -> Void
    let details: () -> Void

    var body: some ToolbarContent {
        TabsScreenHeader(title: tab.name) {
            TabsBackPill(label: "\(needsYou)", count: true, action: back)
        } subtitle: {
            if tab.panes.count > 1 {
                Menu {
                    Section("Panes") {
                        Picker("Pane", selection: Binding(get: { tab.activePane?.key ?? "" }, set: { key in
                            if let pane = tab.panes.first(where: { $0.key == key }) { tab.pick(pane) }
                        })) {
                            ForEach(Array(tab.panes.enumerated()), id: \.element.key) { index, pane in
                                Text(Self.paneTitle(pane, index: index, host: host)).tag(pane.key)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                } label: {
                    HStack(spacing: 3) {
                        subtitle
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).imageScale(.small)
                    }
                    .fixedSize()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Pane \((tab.panes.firstIndex { $0.key == tab.activePane?.key } ?? 0) + 1) of \(tab.panes.count)")
            } else {
                subtitle
            }
        } trailing: {
            Button(action: details) { HostGlyph(host: host.glyphRecord, size: 22).foregroundStyle(host.tint) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the space’s tabs and its Close")
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Space details")
        }
    }

    /// Chat: host · cwd (mono). Terminal: host · cwd · shell (M6a).
    private var subtitle: some View {
        if segment == .terminal, let terminalSubtitle {
            return TabsHostPath(host: host, path: terminalSubtitle, trailing: nil, mono: false)
        }
        let pane = segment == .chat ? (tab.agentPane ?? tab.activePane) : tab.activePane
        let cwd = host.abbreviate(pane?.cwd ?? space?.cwd)
        return TabsHostPath(host: host, path: cwd, trailing: segment == .terminal ? tab.program : nil, mono: segment == .chat)
    }

    static func paneTitle(_ pane: MobilePane, index: Int, host: TabsHost) -> String {
        let place = host.abbreviate(pane.cwd).map { " · " + $0 } ?? ""
        return "Pane \(index + 1)" + place
    }
}

/// M4a's segmented control: Terminal and Chat in a 34 point capsule.
struct TabSegmentControl: View {
    @Binding var selection: TabSegment

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(TabSegment.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

private struct TabGone: View {
    var body: some View {
        Text("This tab is no longer on the host.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct TabNoAgent: View {
    var body: some View {
        Text("No agent runs in this tab. Start one in Terminal and it shows up here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 44)
    }
}
