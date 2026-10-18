import SwiftUI

/// M2c: a space's tabs, pushed from the spaces list. The header carries the space with its host and path; the host
/// pill opens space details; the floating glass button opens a new terminal tab here.
struct SpaceTabsScreen: View {
    let model: MobileTabs
    let actions: TabsActions
    let ref: SpaceRef
    @Binding var path: [TabsRoute]
    let newTab: (MobileSpace) -> Void
    /// Long-press on New tab: pick another space or make one.
    let pick: () -> Void

    var body: some View {
        let space = model.space(ref)
        let host = model.workspace(ref.host)?.host
        VStack(spacing: 0) {
            if let space {
                TimelineView(.everyMinute) { context in
                    let rows = model.rows(in: space)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { entry in
                                NavigationLink(value: TabsRoute.tab(entry.id)) {
                                    TabsTabRow(model: model, entry: entry, detail: false, now: context.date, last: entry.id == rows.last?.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TabsTabMenu(actions: actions, tab: entry.id) }
                            }
                        }
                        .padding(.top, 6)
                        .padding(.leading, 6)
                        .padding(.bottom, 100)
                    }
                    .overlay { if rows.isEmpty { TabsNothing(query: model.query) } }
                }
            } else {
                Spacer()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let space, model.workspace(ref.host)?.client != nil {
                TabsFloatingButton(title: "New tab", symbol: "plus") { newTab(space) }
                    .simultaneousGesture(LongPressGesture().onEnded { _ in pick() })
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            }
        }
        .tabsPushedScreen()
        .toolbar {
            TabsScreenHeader(title: space?.name ?? "") {
                TabsBackPill(label: "Spaces") { pop() }
            } subtitle: {
                if let host { TabsHostPath(host: host, path: host.abbreviate(space?.cwd)) }
            } trailing: {
                if let host {
                    Button { path.append(.details(ref)) } label: { HostGlyph(host: host.glyphRecord, size: 22).foregroundStyle(host.tint) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows the space’s tabs and its Close")
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .accessibilityLabel("Space details")
                }
            }
        }
        .onAppear { model.visited(ref) }
    }

    private func pop() { if !path.isEmpty { path.removeLast() } }
}

/// M4d: what the host pill opens. Identity (the host disc, the space name, host and path), its tabs, and the
/// destructive action last: Close space, with the Mac's choices (Close Space, Detach, Terminate…).
struct SpaceDetailsScreen: View {
    let model: MobileTabs
    @Bindable var actions: TabsActions
    let ref: SpaceRef
    @Binding var path: [TabsRoute]

    var body: some View {
        let space = model.space(ref)
        let host = model.workspace(ref.host)?.host
        let connected = model.workspace(ref.host)?.client != nil
        VStack(spacing: 0) {
            if let space, let host {
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 6) {
                            TabsHostDisc(host: host, size: 84, glyph: 42)
                            Text(space.name)
                                .scaledFont(24, weight: .bold, relativeTo: .title2)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) { hostLine(host, space: space) }
                                VStack(spacing: 2) { hostLine(host, space: space) }
                            }
                            .scaledFont(14, relativeTo: .subheadline)
                            .accessibilityElement(children: .combine)
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Tabs · \(space.tabs.count)")
                                .textCase(.uppercase)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .accessibilityAddTraits(.isHeader)
                            VStack(spacing: 0) {
                                ForEach(Array(space.tabs.enumerated()), id: \.element.id) { index, tab in
                                    if index > 0 { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5).padding(.leading, 16) }
                                    NavigationLink(value: TabsRoute.tab(tab.ref)) {
                                        SpaceDetailsTabRow(tab: tab, line: TabsTabRow.line(tab, host: host, status: model.status))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { TabsTabMenu(actions: actions, tab: tab.ref) }
                                }
                            }
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                        if connected {
                            Button { actions.closingSpace = ref } label: {
                                Text("Close space")
                                    .font(.headline)
                                    .foregroundStyle(Color.destructive)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .frame(minHeight: 50)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .accessibilityHint("Asks whether to close, detach or terminate")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 48)
                }
            } else {
                Spacer()
            }
        }
        .tabsPushedScreen()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TabsBackPill(label: space?.name ?? "Back") { if !path.isEmpty { path.removeLast() } }
            }
            .sharedBackgroundVisibility(.hidden)
            if space != nil, connected {
                ToolbarItem(placement: .topBarTrailing) {
                    TabsHeaderPill(action: { actions.rename(.space(ref)) }) {
                        Text("Rename").padding(.leading, 4)
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .confirmationDialog(space.map { "Close “\($0.name)”" } ?? "", isPresented: Binding(
            get: { actions.closingSpace == ref }, set: { if !$0 { actions.closingSpace = nil } }
        ), titleVisibility: .visible) {
            Button("Close Space") { actions.close(.space(ref), .close) }
            Button("Detach") { actions.close(.space(ref), .detach) }
            Button("Terminate…", role: .destructive) { actions.close(.space(ref), .terminate) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SpaceDetailsScreen.closeMessage)
        }
    }

    @ViewBuilder private func hostLine(_ host: TabsHost, space: MobileSpace) -> some View {
        Text(host.name).fontWeight(.semibold).foregroundStyle(host.tint)
        if let path = host.abbreviate(space.cwd) {
            Text(path).font(.footnote.monospaced()).foregroundStyle(.secondary).fittingLine()
        }
    }

    /// What Close Space does, in the words of docs/integrations.md.
    static let closeMessage = "Close Space ends it only if every pane is idle; otherwise it detaches and the work keeps running."
}

/// M4d's tab row: the kind glyph, the name, what it is doing, a chevron.
private struct SpaceDetailsTabRow: View {
    let tab: MobileTab
    let line: String?

    var body: some View {
        HStack(spacing: 10) {
            TabsKindGlyph(chat: tab.isChat)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(tab.name).font(.subheadline).fittingLine(2).layoutPriority(1)
            if let line {
                Text(line).font(.footnote).foregroundStyle(.tertiary).fittingLine(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
