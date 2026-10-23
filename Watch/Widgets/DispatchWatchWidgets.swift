import SwiftUI
import WidgetKit

/// The watch's widget extension (docs/watch.md, Complications): the "Needs you" complication, its views and timeline in
/// `Watch/Complication` (shared with the app, which writes the entry).
@main
struct DispatchWatchWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
    }
}
