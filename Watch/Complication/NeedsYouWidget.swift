import SwiftUI
import WidgetKit

/// The complications (K7): one widget, "Needs you", in the rectangular (Smart Stack and faces), corner and circular
/// families. Pink only while something needs you; grey "Nothing waiting" otherwise. A tap opens the first row that needs
/// you (`WatchComplicationEntry.url`, `WatchRouter.open(url:)`). Compiled into the watch app too, so its tests render
/// the views and read the timeline.
struct NeedsYouWidget: Widget {
    static let kind = "NeedsYou"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: NeedsYouProvider()) { entry in
            NeedsYouWidgetView(entry: entry.entry, stale: entry.stale)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(entry.entry.url)
        }
        .configurationDisplayName("Needs you")
        .description("How many agents wait for you, and the first of them.")
        .supportedFamilies([.accessoryRectangular, .accessoryCorner, .accessoryCircular, .accessoryInline])
    }
}

struct NeedsYouTimelineEntry: TimelineEntry {
    let date: Date
    let entry: WatchComplicationEntry
    /// The entry is older than `WatchComplicationEntry.staleAfter` at `date`: the rectangular face says "As of …".
    var stale = false
}

/// The last entry the app wrote: as it is, then (from `staleAfter` past its time) with its time shown. The app reloads
/// the timelines when it writes a new one; the system asks again after half an hour in case a write was missed.
struct NeedsYouProvider: TimelineProvider {
    static let refresh: TimeInterval = 30 * 60

    var directory: @Sendable () -> URL? = { WatchComplicationStore.directory() }
    var now: @Sendable () -> Date = { Date() }

    func current() -> NeedsYouTimelineEntry {
        let date = now()
        let entry = WatchComplicationStore.read(from: directory()) ?? .empty(at: date)
        return NeedsYouTimelineEntry(date: date, entry: entry, stale: date.timeIntervalSince(entry.updated) > WatchComplicationEntry.staleAfter)
    }

    func placeholder(in context: Context) -> NeedsYouTimelineEntry {
        NeedsYouTimelineEntry(date: now(), entry: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouTimelineEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouTimelineEntry>) -> Void) {
        completion(timeline())
    }

    func timeline() -> Timeline<NeedsYouTimelineEntry> {
        let first = current()
        var entries = [first]
        if !first.stale {
            entries.append(NeedsYouTimelineEntry(date: first.entry.updated.addingTimeInterval(WatchComplicationEntry.staleAfter + 1),
                                                 entry: first.entry, stale: true))
        }
        return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(Self.refresh)))
    }
}

/// The widget's face per family.
struct NeedsYouWidgetView: View {
    let entry: WatchComplicationEntry
    /// Show the entry's time: the phone has not been heard from for a while.
    var stale = false
    /// Set by the tests and previews; the widget reads its family from the environment.
    var family: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    static let pink = Color(red: 0xE0 / 255, green: 0x7B / 255, blue: 0xE0 / 255)

    private var waiting: Bool { entry.needsYou > 0 }
    private var tint: Color { waiting ? Self.pink : .secondary }

    var body: some View {
        switch family ?? environmentFamily {
        case .accessoryRectangular: rectangular
        case .accessoryCorner: corner
        case .accessoryInline: Text(inline)
        default: circular
        }
    }

    /// "Needs you · 2" over "Allow cargo test? · mba2", the glyph before them.
    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.headline)
                    .foregroundStyle(waiting ? .primary : .secondary)
                    .lineLimit(1)
                if let line = entry.line {
                    Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if stale {
                    Text("As of \(Text(entry.updated, style: .time))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The glyph in the corner, the count along the bezel.
    private var corner: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(tint)
            .widgetAccentable()
            .widgetLabel {
                Text(waiting ? "\(entry.needsYou)" : "0").foregroundStyle(tint)
            }
            .accessibilityLabel(entry.title)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold)).widgetAccentable()
                Text("\(entry.needsYou)").font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
    }

    private var inline: String { waiting ? entry.title : "Nothing waiting" }
}
