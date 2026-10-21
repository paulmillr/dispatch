import SwiftUI

/// One space's tabs, most recent first (the phone's Activity sort): an agent's tab opens its thread, any other its own
/// screen (`TabDetailScreen`).
struct SpaceScreen: View {
    let model: WatchModel
    let route: WatchSpaceRoute

    private var section: WatchSection? { model.sections.first { $0.host.id == route.host } }
    private var space: WatchSection.Space? { section?.spaces.first { $0.space.key == route.space } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                if let section, let space {
                    Section {
                        ForEach(space.tabs) { tab in
                            SpaceTabLink(tab: tab, stale: section.host.stale, now: context.date)
                        }
                        if space.tabs.isEmpty {
                            Text(SpacesText.noTabs).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                        }
                    } header: {
                        SpaceHeader(host: section.host, space: space.space)
                    }
                } else {
                    // The space closed (or the host left the phone) while it was on screen.
                    Text("This space has closed.").font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
                }
            }
        }
        .navigationTitle(space?.space.name ?? "Space")
    }
}

/// Above the tabs: the host's mark and name, the folder.
struct SpaceHeader: View {
    let host: WatchHost
    let space: WatchSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                WatchHostMark(host: host, size: 16)
                Text(host.name).font(.footnote.weight(.semibold)).foregroundStyle(Color(watchHex: host.tint))
            }
            if let folder = space.folder {
                Text(folder).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .textCase(nil)
    }
}

struct SpaceTabLink: View {
    let tab: WatchTab
    let stale: Bool
    let now: Date

    var body: some View {
        switch SpacesText.destination(tab) {
        case .thread(let key): NavigationLink(value: key) { SpaceTabRow(tab: tab, stale: stale, now: now) }
        case .tab(let route): NavigationLink(value: route) { SpaceTabRow(tab: tab, stale: stale, now: now) }
        }
    }
}

/// A tab: gutter dot, kind glyph, name (two lines), its line two, the time.
struct SpaceTabRow: View {
    let tab: WatchTab
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            WatchDotView(color: WatchDots.color(SpacesText.dot(tab)))
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: SpacesText.symbol(tab))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(tab.name).font(.body).lineLimit(2)
                    Spacer(minLength: 2)
                    if let activity = tab.activity {
                        Text(WatchTime.relative(activity, now: now))
                            .font(.footnote)
                            .foregroundStyle(stale ? .tertiary : .secondary)
                            .fixedSize()
                    }
                }
                if let line = SpacesText.line(tab) {
                    Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
