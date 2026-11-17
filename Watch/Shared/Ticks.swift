import Foundation

/// One beat for the counters that change on their own (a working agent's time, a recording's length, a reconnect's
/// countdown): every periodic timeline starts at `anchor`, a whole second, so two counters on screen change together
/// instead of each at its own fraction of a second. A counter computed from its timeline's date then moves by
/// exactly one step on every shared tick. Foundation only: the phone, the watch and the complication share it.
enum Ticks {
    /// The app's launch, rounded down to a whole second.
    static let anchor = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
}
