import SwiftUI

/// P3: the space switcher a tab's host disc opens (detents 560 points and large). Its title is the space with its
/// branch and the host's path; then the space's tabs (the one on screen checked on the lens), New tab (held, P2e's
/// menu), the host's row with its numbers (to its stats sheet), and Rename and Close space (Detach or Terminate…).
struct SpaceSwitcherSheet: View {
    let navigator: SpacesNavigator
    /// The tab whose screen opened it.
    let tab: TabRef
    /// The host row's numbers (`SpacesHostViews.statsLine`).
    var hostLine: @MainActor (UUID) -> String? = { _ in nil }
    @State private var closing = false
    @State private var stats: UUID?
    @Environment(\.dismiss) private var dismiss

    static let height: CGFloat = 560

    private var model: MobileTabs { navigator.model }

    var body: some View {
        let space = model.tab(tab).flatMap { model.space($0.space) }
        let workspace = model.workspace(tab.host)
        NavigationStack {
            Group {
                if let space, let workspace {
                    TimelineView(.everyMinute) { context in
                        content(space, workspace: workspace, now: context.date)
                    }
                } else {
                    Color.clear
                }
            }
            .background(Color.canvas)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                if let space, let host = workspace?.host {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            SpacesBranchChip.title(space.name, branch: branch(space))
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                            TabsHostPath(host: host, path: host.abbreviate(space.cwd))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                }
            }
        }
        // An iPad's form sheet in the middle of the window, as its other sheets (a detent made the phone's card at the
        // window's bottom, `mobilePhoneDetents`).
        .mobilePhoneDetents([.height(Self.height), .large])
        .mobileSheetGrabber()
        .task(id: tab.host) { await navigator.loadAgents(host: tab.host) }
        .onChange(of: space == nil) { _, gone in if gone { dismiss() } }
        .hostStatsSheet(host: $stats)
    }

    private func content(_ space: MobileSpace, workspace: MobileWorkspace, now: Date) -> some View {
        let rows = model.rows(in: space)
        let shells = space.kind == .plainShell
        let connected = workspace.client != nil
        return ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 0) {
                    ForEach(rows) { entry in
                        Button { navigator.switchTab(to: entry.id) } label: {
                            SwitcherTabRow(entry: entry, line: SpaceTabRow.line(entry, model: model),
                                           agent: model.agent(of: entry.tab), current: entry.id == tab)
                        }
                        .buttonStyle(.plain)
                        .tabsRowHover()
                        MobileHairline(inset: 60)
                    }
                    if workspace.canAddTab(to: space) {
                        SwitcherNewTab(navigator: navigator, space: space)
                    }
                }
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button { stats = workspace.id } label: {
                    HStack(spacing: 12) {
                        TabsHostDisc(host: workspace.host, size: 34, glyph: 17)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workspace.host.name).font(.headline)
                            Text(hostLine(workspace.id) ?? HostFreshness.label(state: workspace.host.state,
                                                                                updated: model.updated?(workspace.id), now: now))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityHint("Shows the host’s stats")
                .accessibilityIdentifier("switcher-host")

                HStack(spacing: 10) {
                    if !shells {
                        Button { navigator.afterClosingSwitcher { navigator.actions.rename(.space(space.ref)) } } label: {
                            Label("Rename", systemImage: "pencil")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .disabled(!connected)
                    }
                    Button {
                        if shells {
                            navigator.afterClosingSwitcher { navigator.actions.close(.space(space.ref), .close) }
                        } else {
                            closing = true
                        }
                    } label: {
                        Label("Close space", systemImage: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.destructive)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .disabled(shells ? space.tabs.isEmpty : !connected)
                    .accessibilityHint(shells ? "Ends every shell of this space" : "Asks whether to detach or terminate")
                    .confirmationDialog("Close “\(space.name)”", isPresented: $closing, titleVisibility: .visible) {
                        Button("Detach") { navigator.afterClosingSwitcher { navigator.actions.close(.space(space.ref), .detach) } }
                        Button("Terminate…", role: .destructive) {
                            navigator.afterClosingSwitcher { navigator.actions.close(.space(space.ref), .terminate) }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(SpaceCloseCopy.message)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    private func branch(_ space: MobileSpace) -> String? {
        guard let directory = space.cwd else { return nil }
        return navigator.gitFacts?.facts(SpaceGitFacts.Key(host: space.ref.host, key: space.ref.key), directory: directory)?.branch
    }
}

/// A tab in the switcher: P2's row without the time, the one on screen checked on the lens.
private struct SwitcherTabRow: View {
    let entry: TabsEntry
    let line: TabsStatus?
    let agent: String?
    let current: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(entry.urgency.map { $0 == .working ? Color.stateWorking : Color.stateUnread } ?? .clear)
                .frame(width: 10, height: 10)
                .frame(width: 14)
            AgentGlyph(agent: entry.tab.isChat ? (agent ?? "agent") : nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label).font(.headline).lineLimit(1)
                if let line {
                    TabsStatusText(status: line)
                        .font(.subheadline)
                        .foregroundStyle(entry.urgency == .needsYou ? Color.primary : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if current {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.dispatchPink)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 11)
        .background { if current { Color.lens } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.label)
        .accessibilityValue(SpaceTabRow.value(entry: entry, line: line, open: false, now: Date()))
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
    }
}

/// The switcher's "+ New tab" row: a shell in this space; held, P2e's menu.
private struct SwitcherNewTab: View {
    let navigator: SpacesNavigator
    let space: MobileSpace

    var body: some View {
        Menu {
            SpaceNewTabMenu(navigator: navigator, space: space)
        } label: {
            HStack(spacing: 12) {
                Color.clear.frame(width: 14, height: 1)
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 26)
                Text("New tab").font(.headline)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.dispatchPink)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        } primaryAction: {
            navigator.afterClosingSwitcher { navigator.newTab(in: space) }
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .accessibilityLabel("New tab")
        .accessibilityHint("Hold for an agent or another space")
    }
}
