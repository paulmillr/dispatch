import Foundation
#if canImport(WatchKit)
import WatchKit
#endif

/// A tap on the wrist for what changed while the app is frontmost (docs/watch.md, Behaviour, Haptics): a conversation
/// that starts needing you (`.notification`) or one whose turn finished (`.success`); none for working updates. One per
/// snapshot, needs you first. In the background the phone's notifications speak instead. None for what changed while the
/// watch was away (launch, reconnection) or for a turn the user stopped here.
enum WatchHaptic: Equatable {
    case needsYou, finished

    /// What `next` brings that `previous` did not: a row that needs you now and did not, else a row whose agent stopped
    /// working without needing you, unless the user stopped it from this watch (`ignoring`). Nothing for the first
    /// snapshot (launch is not news; the model also stays quiet until the phone answered its `hello`), nor for a muted
    /// row, nor for a row the phone did not list before.
    static func event(from previous: WatchSnapshot?, to next: WatchSnapshot,
                      ignoring stopped: Set<WatchConversationKey> = []) -> WatchHaptic? {
        guard let previous else { return nil }
        let before = Dictionary(previous.conversations.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var finished = false
        for row in next.conversations where !row.muted {
            guard let old = before[row.key] else { continue }
            if row.needsYou && !old.needsYou { return .needsYou }
            if old.busy && !row.busy && !row.needsYou && !stopped.contains(row.key) { finished = true }
        }
        return finished ? .finished : nil
    }

    #if canImport(WatchKit)
    /// The app's: plays it only while the app is frontmost.
    @MainActor static func play(_ haptic: WatchHaptic) {
        guard WKApplication.shared().applicationState == .active else { return }
        WKInterfaceDevice.current().play(haptic == .needsYou ? .notification : .success)
    }
    #endif
}
