import SwiftUI

/// The Spaces tab (docs/watch.md, Behaviour, Spaces): every host in the phone's order, a section each with its load (the
/// statistics card) and its spaces. A space pushes its tabs (`SpaceScreen`), a tab its thread or its screen: two pushes,
/// because a 42 mm list holding hosts, spaces and tabs at once would be mostly indentation and a host with ten tabs would
/// bury the next host.
///
/// Spaces follows the phone's snapshots and its 30-second clock only while `active` (its page on screen, nothing pushed
/// over it). Hidden, it keeps drawing what it showed when it was left, so the snapshots agents send while working cost it
/// nothing; coming back reads the model afresh.
struct SpacesScreen: View {
    let model: WatchModel
    var router: WatchRouter = .shared
    var active = true

    @State private var now = Date()
    /// What the hidden page draws: the lists as they were when it was left.
    @State private var frozen: SpacesContent?

    var body: some View {
        ScrollViewReader { proxy in
            // Read only while shown (or hidden before the first freeze): a hidden page observes nothing.
            list(active ? SpacesContent(model, now: now) : frozen ?? SpacesContent(model, now: now))
                .onAppear { scroll(proxy) }
                .onChange(of: router.scrollTarget) { scroll(proxy) }
        }
        .task(id: active) {
            guard active else {
                frozen = SpacesContent(model, now: now)
                return
            }
            frozen = nil
            // Not a TimelineView around the List: one inside a row as well loops the list's layout (AgentsScreen).
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .navigationTitle("Spaces")
        .toolbar {
            // As Agents' (watchOS lists have no pull to refresh): the phone retries its hosts.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(model.refreshing)
                .accessibilityLabel("Refresh")
                .accessibilityHint("Asks your iPhone to reconnect its hosts")
            }
        }
    }

    /// A host to bring to the top (a Host widget's tap, `WatchRouter.Show.host`), once.
    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = router.scrollTarget else { return }
        router.scrollTarget = nil
        proxy.scrollTo(target, anchor: .top)
    }

    private func list(_ content: SpacesContent) -> some View {
        List {
            // A row only when there is a notice: an empty row (a TimelineView with no content) in a watch list looped
            // its layout at full CPU.
            if let notice = content.notice {
                WatchNoticeBanner(content: notice.content(now: content.now))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(content.sections) { section in
                SpacesHostSection(section: section, notice: content.notice, now: content.now,
                                  connecting: content.connecting.contains(section.host.id)) {
                    Task { await model.connect(host: section.host.id) }
                }
            }
            if content.truncated {
                Text(SpacesText.truncated)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

/// What Spaces draws, read from the model at once: the hidden page keeps one.
struct SpacesContent {
    var sections: [WatchSection]
    var notice: WatchNotice?
    var truncated: Bool
    /// Hosts with a Connect on its way.
    var connecting: Set<String>
    var now: Date

    @MainActor init(_ model: WatchModel, now: Date) {
        sections = model.sections
        notice = model.notice(at: now)
        truncated = model.snapshot?.truncated == true
        connecting = model.connecting
        self.now = now
    }
}

/// One host: its header (mark, name, state, multiplexer), its load (`HostStatsCard`: as last known and dimmed while not
/// connected), what blocks it, Connect while offline, then its spaces.
struct SpacesHostSection: View {
    let section: WatchSection
    var notice: WatchNotice?
    let now: Date
    var connecting = false
    var connect: () -> Void = {}

    var body: some View {
        let host = section.host
        let offline = SpacesText.offline(host)
        let problem = SpacesText.problem(host, now: now, notice: notice)
        Section {
            if host.stats != nil {
                HostStatsCard(stats: host.stats, tint: Color(watchHex: host.tint), live: !offline)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))
            }
            if let problem {
                WatchHostProblemLine(symbol: problem.symbol, text: problem.text, detail: problem.detail)
                    .listRowBackground(Color.clear)
            } else if let since = HostStatsText.offlineSince(host, now: now) {
                Label(since, systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            if offline, WatchModel.blockedMessage(host) == nil {
                Group {
                    if connecting {
                        HStack(spacing: 6) {
                            ProgressView().frame(width: 18, height: 18)
                            Text("Connecting…").font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    } else {
                        Button(action: connect) {
                            CapsuleLabel(title: "Connect", symbol: "bolt.fill", style: .accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Connect")
                        .accessibilityHint("Asks your iPhone to connect \(host.name)")
                    }
                }
                .listRowBackground(Color.clear)
            }
            ForEach(section.spaces) { space in
                NavigationLink(value: WatchSpaceRoute(host: space.space.host, space: space.space.key)) {
                    SpacesSpaceRow(space: space.space, tabs: space.tabs.count, stale: host.stale, now: now)
                }
            }
            if section.spaces.isEmpty {
                Text(host.sameMachine.map(SpacesText.sameMachine) ?? SpacesText.noSpaces)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        } header: {
            SpacesHostHeader(host: host)
                .id(host.id)
        }
    }
}

/// The section header: the host's mark, its name, a state dot and the multiplexer chip.
struct SpacesHostHeader: View {
    let host: WatchHost

    var body: some View {
        HStack(spacing: 5) {
            WatchHostMark(host: host, size: 20)
                .opacity(host.state == .offline ? 0.5 : 1)
            Text(host.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
            Circle().fill(SpacesText.stateColor(host)).frame(width: 6, height: 6).accessibilityHidden(true)
            if let multiplexer = host.multiplexer {
                Text(multiplexer)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host.name)
        .accessibilityValue([SpacesText.state(host) ?? "Connected", host.multiplexer].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

/// A space: gutter dot, name, its folder under it; the time and the unread count at the end.
struct SpacesSpaceRow: View {
    let space: WatchSpace
    let tabs: Int
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            WatchDotView(color: WatchDots.color(SpacesText.dot(space)))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(space.name).font(.body).lineLimit(1)
                    Spacer(minLength: 2)
                    if let activity = space.activity {
                        Text(WatchTime.relative(activity, now: now))
                            .font(.footnote)
                            .foregroundStyle(stale ? .tertiary : .secondary)
                            .fixedSize()
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let folder = SpacesText.folder(space.folder) {
                        Text(folder).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 2)
                    if space.working && space.unread > 0 {
                        WatchDotView(color: WatchDots.working, size: 6)
                    }
                    if space.unread > 0 {
                        Text("\(space.unread)").font(.footnote.monospacedDigit()).foregroundStyle(WatchDots.needsYou)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(SpacesText.value(space))
    }
}
