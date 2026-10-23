import SwiftUI

/// A tab that is not an agent's: what the phone knows of it. No actions; its terminal is on the phone (no terminal on
/// the watch in v1).
struct TabDetailScreen: View {
    let model: WatchModel
    let route: WatchTabRoute

    private var tab: WatchTab? { model.tab(host: route.host, key: route.tab) }
    private var host: WatchHost? { model.host(route.host) }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollView {
                if let tab {
                    content(tab, now: context.date)
                } else {
                    // Closed (or left out of the phone's snapshot) while on screen.
                    Text("This tab has closed.").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // The name wraps in full below; the bar's title would cut it after a word or two.
        .navigationTitle("Tab")
    }

    /// One block, not a card per fact: six cards would take three screens of a 42 mm watch.
    private func content(_ tab: WatchTab, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: SpacesText.symbol(tab)).font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(tab.name).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            if let host {
                HStack(spacing: 5) {
                    WatchHostMark(host: host, size: 16)
                    Text(host.name).font(.footnote.weight(.semibold)).foregroundStyle(Color(watchHex: host.tint))
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(Self.facts(tab, host: host, space: space(of: tab), now: now), id: \.label) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.label).font(.caption2).foregroundStyle(.secondary)
                    Text(fact.value).font(.footnote).fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            Divider().padding(.vertical, 2)
            Label("Terminal on your iPhone", systemImage: "iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func space(of tab: WatchTab) -> WatchSpace? {
        model.snapshot?.spaces.first { $0.host == tab.host && $0.key == tab.space }
    }

    struct Fact: Equatable {
        let label: String
        let value: String
    }

    /// Host (its system), space, folder, program, activity and status, each only when known.
    static func facts(_ tab: WatchTab, host: WatchHost?, space: WatchSpace?, now: Date) -> [Fact] {
        let rows: [(String, String?)] = [
            ("System", host?.osLabel),
            ("Space", space?.name),
            ("Folder", tab.folder ?? space?.folder),
            ("Program", tab.program ?? tab.agent),
            ("Activity", tab.activity.map { WatchTime.ago($0, now: now) }),
            ("Status", tab.status),
        ]
        return rows.compactMap { label, value in value.flatMap { $0.isEmpty ? nil : Fact(label: label, value: $0) } }
    }
}
