import SwiftUI
import WidgetKit

/// The watch's widget extension (docs/watch.md, Complications): the "Needs you" and "Host" complications, their views
/// and timelines in `Watch/Complication` (shared with the app, which writes their entries).
@main
struct DispatchWatchWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        HostWidget()
    }
}
