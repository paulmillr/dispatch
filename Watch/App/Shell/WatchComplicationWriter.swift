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
