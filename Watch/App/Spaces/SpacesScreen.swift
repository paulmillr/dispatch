import SwiftUI

/// The Spaces tab (docs/watch.md, Behaviour, Spaces): every host in the phone's order, a section each with its spaces.
/// A space pushes its tabs (`SpaceScreen`), a tab its thread or its screen: two pushes, because a 42 mm list holding
/// hosts, spaces and tabs at once would be mostly indentation and a host with ten tabs would bury the next host.
struct SpacesScreen: View {
    let model: WatchModel
    var router: WatchRouter = .shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                list(now: context.date)
                    .onAppear {
                        guard let target = router.scrollTarget else { return }
                        router.scrollTarget = nil
                        proxy.scrollTo(target, anchor: .top)
                    }
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

    private func list(now: Date) -> some View {
        let notice = model.notice(at: now)
        return List {
            // A row only when there is a notice: an empty row (a TimelineView with no content) in a watch list looped
            // its layout at full CPU.
            if let notice {
                WatchNoticeBanner(content: notice.content(now: now))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(model.sections) { section in
                SpacesHostSection(section: section, notice: notice, now: now)
            }
            if model.snapshot?.truncated == true {
                Text(SpacesText.truncated)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
    }
}

/// One host: its header (mark, name, state, multiplexer), what blocks it, then its spaces.
struct SpacesHostSection: View {
    let section: WatchSection
    var notice: WatchNotice?
    let now: Date

    var body: some View {
        Section {
            if let problem = SpacesText.problem(section.host, now: now, notice: notice) {
                WatchHostProblemLine(symbol: problem.symbol, text: problem.text, detail: problem.detail)
                    .listRowBackground(Color.clear)
            }
            ForEach(section.spaces) { space in
                NavigationLink(value: WatchSpaceRoute(host: space.space.host, space: space.space.key)) {
                    SpacesSpaceRow(space: space.space, tabs: space.tabs.count, stale: section.host.stale, now: now)
                }
            }
            if section.spaces.isEmpty {
                Text(section.host.sameMachine.map(SpacesText.sameMachine) ?? SpacesText.noSpaces)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        } header: {
            // The header opens the host's screen (K6: its statistics, Connect).
            NavigationLink(value: WatchHostRoute(host: section.host.id)) {
                SpacesHostHeader(host: section.host)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the host's load and connection")
            .id(section.host.id)
        }
    }
}

/// The section header: the host's mark, its name, a state dot (or "Connecting…"/"Offline") and the multiplexer chip.
struct SpacesHostHeader: View {
    let host: WatchHost

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            if let stats = HostStatsLine.stats(host) {
                HostStatsLine(stats: stats, tint: Color(watchHex: host.tint))
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(host.name)
        .accessibilityValue(([SpacesText.state(host) ?? "Connected", host.multiplexer]
            + [HostStatsLine.stats(host).map(HostStatsLine.accessibilityLabel)]).compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isHeader)
    }
}

/// The host's load under its Spaces header, one line: CPU % with a small 15-minute sparkline, then memory used of
/// total; red where the phone flags it high, dimmed while the phone's numbers are not current. Only for a connected
/// host with a reading (the host screen keeps the last-known strip of one that is not).
struct HostStatsLine: View {
    let stats: WatchHostStats
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                Text("CPU").foregroundStyle(.secondary)
                Text(HostStatsText.cpu(stats).value + "%")
                    .foregroundStyle(stats.warnings.contains(.cpu) ? AgentsColor.destructive : .primary)
            }
            if stats.history.compactMap({ $0 }).count > 1 {
                Sparkline(values: stats.history, color: tint)
                    .frame(width: 44, height: 14)
            }
            Spacer(minLength: 4)
            if let memory = Self.memory(stats) {
                Text(memory)
                    .foregroundStyle(stats.warnings.contains(.memory) ? AgentsColor.destructive : .secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .opacity(stats.stale ? 0.5 : 1)
    }

    /// A connected host's stats; nil otherwise.
    static func stats(_ host: WatchHost) -> WatchHostStats? {
        guard host.state == .connected, let stats = host.stats, stats.cpu != nil || stats.memoryUsed != nil else { return nil }
        return stats
    }

    /// "11/16 GB" (one unit when both share it), "512 MB/16 GB", "11 GB" without a total.
    static func memory(_ stats: WatchHostStats) -> String? {
        guard stats.memoryUsed != nil else { return nil }
        let used = HostStatsText.bytes(stats.memoryUsed)
        guard stats.memoryTotal != nil else { return "\(used.value) \(used.unit)" }
        let total = HostStatsText.bytes(stats.memoryTotal)
        return used.unit == total.unit ? "\(used.value)/\(total.value) \(total.unit)"
            : "\(used.value) \(used.unit)/\(total.value) \(total.unit)"
    }

    /// "CPU 34 percent, memory 11 of 16 GB used, not current".
    static func accessibilityLabel(_ stats: WatchHostStats) -> String {
        var parts: [String] = []
        if let cpu = stats.cpu { parts.append("CPU \(Int(cpu.rounded())) percent") }
        if stats.memoryUsed != nil {
            let used = HostStatsText.bytes(stats.memoryUsed)
            if stats.memoryTotal != nil {
                let total = HostStatsText.bytes(stats.memoryTotal)
                parts.append("memory \(used.value) \(used.unit) of \(total.value) \(total.unit) used")
            } else {
                parts.append("memory \(used.value) \(used.unit) used")
            }
        }
        if stats.stale { parts.append("not current") }
        return parts.joined(separator: ", ")
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
