import SwiftUI

/// The iPad split's sidebar (I1–I5, the Mac's): Spaces' tree or the Agents list on its own stack, no tab bar. Its bar
/// row holds the pink sidebar toggle and the title, which switches between Spaces and Agents (⌘1, ⌘2; the needs-you
/// count beside it while Spaces shows); with Spaces the filter menu (All · Needs you · Agents, pink while one filters,
/// the needs-you count on it) and Edit, and New space ⌘N as its footer; with Agents New chat. A space's row, or an
/// agent's, shows the tab in the detail column and is marked while it shows; a host's glyph shows its stats in a
/// popover. The tree and the list are the phone's own (`SpacesRoot`, `AgentsScreen`): this is a wrapper around them.
struct PadSidebar: View {
    @Bindable var navigator: SpacesNavigator
    @Binding var section: MobileSection
    /// The Agents list (`MobileRoot.agentsList`), and New chat's sheet.
    let agents: AnyView
    let newChat: () -> Void
    /// Conversations waiting for the user: the switch shows them while the sidebar shows Spaces.
    let needsYou: Int
    let hostActions: SpacesHostActions
    let hostViews: SpacesHostViews
    let content: TabsContent
    let addHost: () -> Void
    let settings: () -> Void
    let width: CGFloat
    /// What a windowed app's controls take of the bar's leading corner (`containerCornerInsets`); zero full screen.
    @State private var controls: CGFloat = 0

    private var model: MobileTabs { navigator.model }

    /// The title fits beside the toggle, the filter and Edit (and the window controls): about 290 points of bar. Without
    /// it the bar keeps its controls out of an overflow menu down to the sidebar's 280 beside the window controls.
    static func showsTitle(width: CGFloat, controls: CGFloat) -> Bool { width - controls >= 290 }

    var body: some View {
        NavigationStack(path: Binding(get: { navigator.splitPath.sidebar }, set: { navigator.setSidebar($0) })) {
            Group {
                switch section {
                case .spaces: SpacesRoot(navigator: navigator, hostActions: hostActions, addHost: addHost, settings: settings)
                case .agents: agents
                }
            }
                .background(Color.canvas)
                .environment(\.spacesSidebar, true)
                .environment(\.tabsSelectSpace, { navigator.selectSpace($0) })
                .environment(\.tabsShownSpace, navigator.shownSplitSpace)
                .environment(\.tabsShownTab, navigator.splitPath.tab)
                .environment(\.tabsSelectTab, { navigator.select($0) })
                .environment(\.tabsColumnWidth, width)
                .navigationTitle(section.title)
                .toolbarTitleDisplayMode(.inline)
                // The title is the bar's leading item, beside the toggle (the screen's name stays for VoiceOver).
                .toolbar(removing: .title)
                .toolbar { toolbar }
                .safeAreaBar(edge: .bottom) {
                    if !model.workspaces.isEmpty, !navigator.editing {
                        switch section {
                        case .spaces: PadNewSpaceButton(navigator: navigator)
                        case .agents: PadNewChatButton(action: newChat)
                        }
                    }
                }
                .navigationDestination(for: TabsRoute.self) { route in
                    TabsDestination(route: route, navigator: navigator, content: content, hostViews: hostViews)
                }
        }
        .tint(.dispatchPink)
        .onGeometryChange(for: CGFloat.self) { $0.containerCornerInsets.topLeading.width } action: { controls = $0 }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 10) {
                Button { navigator.toggleSidebar() } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.dispatchPink)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
                .disabled(!navigator.canToggleSidebar)
                .accessibilityLabel("Hide sidebar")
                PadSectionSwitch(section: $section, needsYou: needsYou,
                                 titled: Self.showsTitle(width: width, controls: controls))
            }
        }
        .sharedBackgroundVisibility(.hidden)
        if section == .spaces, !model.workspaces.isEmpty {
            // One item: as two, the bar folded them into its overflow menu beside the window controls.
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                PadFilterMenu(model: model)
                Button { navigator.editing.toggle() } label: {
                    Image(systemName: navigator.editing ? "checkmark" : "pencil")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(navigator.editing ? Color.onAccent : Color.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(navigator.editing ? .regular.tint(.dispatchPink).interactive() : .regular.interactive(), in: Circle())
                .contentShape(.hoverEffect, Circle())
                .hoverEffect(.highlight)
                .accessibilityLabel(navigator.editing ? "Done" : "Edit")
                }
                .fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
        } else if section == .agents {
            ToolbarItem(placement: .topBarTrailing) {
                AgentsGroupMenu(circle: true).fixedSize()
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// The sidebar's filter: the tree's filter row (`TabsQuery`: All, Needs you, Agents) as one menu, with Show offline hosts;
/// the disc shows the filter's glyph, pink while one filters, and the needs-you count.
struct PadFilterMenu: View {
    @Bindable var model: MobileTabs

    var body: some View {
        let filter = model.query.filter, needsYou = model.needsYou()
        Menu {
            Picker("Show", selection: $model.query.filter) {
                ForEach(TabsQuery.Filter.allCases) { filter in
                    Label(filter.title, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.inline)
            Section {
                Toggle("Show offline hosts", systemImage: "wifi.slash", isOn: $model.showOffline)
            }
        } label: {
            Image(systemName: filter == .all ? "line.3.horizontal.decrease" : filter.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(model.query.filtering ? Color.onAccent : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .background { if model.query.filtering { Circle().fill(Color.dispatchPink) } }
        .glassEffect(.regular.interactive(), in: Circle())
        .overlay(alignment: .topTrailing) {
            if needsYou > 0 {
                Text("\(needsYou)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.stateUnread, in: Capsule())
                    .overlay(Capsule().stroke(Color.canvas, lineWidth: 1.5))
                    .offset(x: 4, y: -3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.hoverEffect, Circle())
        .hoverEffect(.highlight)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("Filter")
        .accessibilityValue([filter.title, needsYou > 0 ? "\(needsYou) need you" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The sidebar's footer (the Mac's): New space with its chord, a glass capsule across the sidebar.
struct PadNewSpaceButton: View {
    let navigator: SpacesNavigator

    var body: some View {
        Button {
            navigator.newSpace = NewSpaceRequest(host: navigator.shownSpace?.host ?? navigator.model.recentSpace?.ref.host)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.body.weight(.semibold)).accessibilityHidden(true)
                Text("New space").font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(MobileCommand.newSpace.chord ?? "").font(.subheadline).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("New space")
    }
}

/// The sidebar's title as the switch between its sections (the phone's tab bar): "Spaces ⌄" or "Agents ⌄" opens a menu
/// of both with their shortcuts; while Spaces shows, the needs-you count sits beside it, as the phone's Agents tab
/// item carries it. Without room for the title, the section's glyph.
struct PadSectionSwitch: View {
    @Binding var section: MobileSection
    let needsYou: Int
    let titled: Bool

    var body: some View {
        Menu {
            Picker("Show", selection: $section) {
                ForEach(MobileSection.allCases) { item in
                    Label(item.title, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if titled {
                    Text(section.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Image(systemName: section.symbol).font(.title3.weight(.semibold))
                }
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                if section == .spaces, needsYou > 0 {
                    Text("\(needsYou)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.stateUnread, in: Capsule())
                }
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityLabel(section.title)
        .accessibilityHint("Switches between Spaces and Agents")
        .accessibilityValue(section == .spaces && needsYou > 0 ? "\(needsYou) agents need you" : "")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("pad-section")
    }
}

/// The sidebar's footer while it shows Agents: New chat, as New space's capsule (`PadNewSpaceButton`).
struct PadNewChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.body.weight(.semibold)).accessibilityHidden(true)
                Text("New chat").font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .contentShape(.hoverEffect, Capsule())
        .hoverEffect(.highlight)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("pad-new-chat")
    }
}
