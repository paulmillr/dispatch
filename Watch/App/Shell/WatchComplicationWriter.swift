import Foundation
import WidgetKit

/// Writes the complications' entry (`WatchComplicationEntry`) to the App Group container and reloads the widget's
/// timelines (docs/watch.md, Complications). Entries come from every snapshot the model takes (the application context,
/// a reply, at activation too) and from the phone's `transferCurrentComplicationUserInfo`, which reaches the app in the
/// background (`DispatchWatchApp`'s WatchConnectivity background task). The newest wins; an older one is ignored.
/// Nothing happens when the container is not there (the app not signed into the group).
@MainActor
final class WatchComplicationWriter {
    /// The app's: the App Group container, the widget's reload.
    static let shared = WatchComplicationWriter(directory: WatchComplicationStore.directory())

    private let directory: URL?
    private let reload: () -> Void
    private let now: () -> Date
    private(set) var written: WatchComplicationEntry?

    init(directory: URL?, now: @escaping () -> Date = Date.init,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: NeedsYouWidget.kind) }) {
        self.directory = directory
        self.now = now
        self.reload = reload
        written = WatchComplicationStore.read(from: directory)
    }

    /// The model's `snapshotChanged`.
    func write(_ snapshot: WatchSnapshot) { write(entry: WatchComplicationEntry(snapshot)) }

    /// Writes `entry` unless an entry as new is written; reloads the faces when they change: what they show, or the
    /// "As of" time they show once the last entry was older than `WatchComplicationEntry.staleAfter`.
    func write(entry: WatchComplicationEntry) {
        guard let directory else { return }
        if let written, written.updated >= entry.updated { return }
        let faces = !entry.shows(written) || written.map { now().timeIntervalSince($0.updated) > WatchComplicationEntry.staleAfter } ?? true
        guard (try? WatchComplicationStore.write(entry, to: directory)) != nil else { return }
        written = entry
        if faces { reload() }
    }
}

/// Writes the Host widget's entry (`HostWidgetEntry`) beside the complication's, from every snapshot the model takes, but
/// only when what a face could show changed; reloads the Host widget's timelines within its budget: at most every
/// `reloadInterval` for changed numbers, sooner (`urgentInterval`) when a host's high flag or currency flips, and never
/// more than `dailyCap` times a day, so a host dropping in and out or CPU hovering at the threshold cannot spend the
/// widget's budget. What a skipped reload would have shown is in the file: the next reload, or the widget's own
/// 15-minute refresh, reads it. The recommendations follow the hosts. docs/watch.md, Complications.
@MainActor
final class HostWidgetWriter {
    static let shared = HostWidgetWriter(directory: WatchComplicationStore.directory())

    /// For numbers alone.
    static let reloadInterval: TimeInterval = 15 * 60
    /// For a flag that flipped.
    static let urgentInterval: TimeInterval = 5 * 60
    /// Reloads in any 24 hours, within WidgetKit's daily budget for a widget.
    static let dailyCap = 40

    private let directory: URL?
    private let now: () -> Date
    private let reload: () -> Void
    private let recommend: () -> Void
    private(set) var written: HostWidgetEntry?
    /// This run's reloads in the last 24 hours, oldest first.
    private(set) var reloads: [Date] = []

    init(directory: URL?, now: @escaping () -> Date = Date.init,
         reload: @escaping () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: HostWidget.kind) },
         recommend: @escaping () -> Void = { WidgetCenter.shared.invalidateConfigurationRecommendations() }) {
        self.directory = directory
        self.now = now
        self.reload = reload
        self.recommend = recommend
        written = HostWidgetStore.read(from: directory)
    }

    func write(_ snapshot: WatchSnapshot) {
        guard let directory else { return }
        let entry = HostWidgetEntry(snapshot)
        if let written, written.updated >= entry.updated { return }
        guard !entry.shows(written) else { return }
        guard (try? HostWidgetStore.write(entry, to: directory)) != nil else { return }
        let previous = written
        written = entry
        let names = { (entry: HostWidgetEntry?) in entry?.hosts.map { [$0.id, $0.name] } ?? [] }
        let flags = { (entry: HostWidgetEntry?) in entry?.hosts.map { [$0.id, "\($0.high)", "\($0.current)"] } ?? [] }
        if names(previous) != names(entry) { recommend() }
        let urgent = flags(previous) != flags(entry)
        let date = now()
        reloads.removeAll { date.timeIntervalSince($0) >= 86_400 }
        guard reloads.count < Self.dailyCap else { return }
        if let last = reloads.last, date.timeIntervalSince(last) < (urgent ? Self.urgentInterval : Self.reloadInterval) { return }
        reloads.append(date)
        reload()
    }
}
