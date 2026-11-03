import AppIntents
import SwiftUI
import WidgetKit

/// The "Host" widget (docs/watch.md, Complications): one host's CPU % and its 15-minute sparkline in the rectangular
/// and circular families; the host chosen for it (a face's or the Smart Stack's recommendation), else the busiest
/// connected one. Relevant to the Smart Stack while the phone flags its CPU high. The entry (`HostWidgetEntry`) is a
/// JSON file in the App Group container beside the Needs you entry, written by the watch app from its snapshots
/// (`HostWidgetWriter`); a tap opens the host's section of Spaces.
struct HostWidget: Widget {
    static let kind = "Host"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: HostWidgetIntent.self, provider: HostWidgetProvider()) { entry in
            HostWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(entry.host.map { HostWidgetEntry.url(host: $0.id) })
        }
        .configurationDisplayName("Host")
        .description("A host's CPU over the last 15 minutes.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular])
    }
}

/// What the Host widget shows: every host the phone has a reading for, the newest snapshot's time.
struct HostWidgetEntry: Codable, Equatable, Sendable {
    struct Host: Codable, Equatable, Sendable, Identifiable {
        /// `WatchHost.id`.
        var id: String
        var name: String
        /// `#RRGGBB`, the host's tint.
        var tint: String?
        /// CPU %, 0 to 100.
        var cpu: Double?
        /// The sparkline's buckets (`WatchHostStats.history`), oldest first; nil where no sample came.
        var history: [Double?]
        /// The phone flags its CPU high.
        var high: Bool
        /// Connected, with current numbers: the widget dims a host that is not.
        var current: Bool
    }

    var hosts: [Host]
    /// The snapshot's time.
    var updated: Date

    init(hosts: [Host], updated: Date) {
        self.hosts = hosts
        self.updated = updated
    }

    /// The hosts of a snapshot that have a CPU reading, in the phone's order.
    init(_ snapshot: WatchSnapshot) {
        let hosts = snapshot.hosts.sorted { ($0.order, $0.name) < ($1.order, $1.name) }.compactMap { host -> Host? in
            guard let stats = host.stats, let cpu = stats.cpu else { return nil }
            return Host(id: host.id, name: host.name, tint: host.tint, cpu: cpu.rounded(), history: stats.history.map { $0?.rounded() },
                        high: stats.warnings.contains(.cpu), current: host.state == .connected && !stats.stale)
        }
        self.init(hosts: hosts, updated: snapshot.generated)
    }

    /// The chosen host; nil while the entry does not have it (shown as unavailable, never another host's numbers in its
    /// place). Without a choice ("Busiest host"), the busiest current one (the highest CPU), else the first.
    func host(_ chosen: String?) -> Host? {
        if let chosen { return hosts.first { $0.id == chosen } }
        let current = hosts.filter(\.current)
        return current.max { ($0.cpu ?? 0) < ($1.cpu ?? 0) } ?? hosts.first
    }

    /// The same faces as `other`, whatever the times.
    func shows(_ other: HostWidgetEntry?) -> Bool {
        guard var other else { return false }
        other.updated = updated
        return other == self
    }

    /// What the Smart Stack is told: a host flagged high is worth showing now, while the reading is current (not stale,
    /// not a host that went away).
    static func relevance(_ host: Host?, stale: Bool) -> TimelineEntryRelevance {
        TimelineEntryRelevance(score: !stale && host?.high == true && host?.current == true ? 1 : 0)
    }

    /// The face older than this says "As of …": the phone has not been heard from since.
    static let staleAfter: TimeInterval = 5 * 60

    /// `dispatch-watch://host?host=<id>`: the host's section of Spaces.
    static func url(host: String) -> URL {
        var components = URLComponents()
        components.scheme = WatchComplicationEntry.scheme
        components.host = "host"
        components.queryItems = [URLQueryItem(name: "host", value: host)]
        return components.url!
    }

    /// The host a Host widget's URL names.
    static func host(_ url: URL) -> String? {
        guard url.scheme == WatchComplicationEntry.scheme, url.host == "host",
              let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "host" })?.value,
              UUID(uuidString: host) != nil else { return nil }
        return host
    }

    /// The gallery's and the placeholder's entry (fictional).
    static let sample = HostWidgetEntry(hosts: [Host(id: "00000000-0000-4000-8000-000000000001", name: "studio", tint: "#C98BD9", cpu: 34,
                                                     history: (0..<60).map { Double(20 + ($0 * 7) % 30) }, high: false, current: true)],
                                        updated: .distantPast)
}

/// The Host entry's file in the App Group container, as `WatchComplicationStore` keeps the Needs you entry.
enum HostWidgetStore {
    static let fileName = "hosts.json"

    static func write(_ entry: HostWidgetEntry, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entry).write(to: directory.appendingPathComponent(fileName),
                                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read(from directory: URL?) -> HostWidgetEntry? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(HostWidgetEntry.self, from: data)
    }
}

// MARK: Configuration

/// Which host a Host widget shows; none: the busiest. A watch face offers the recommendations (one per host the entry
/// knows, and Busiest host), as watchOS has no configuration screen.
struct HostWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Host"
    static let description = IntentDescription("The host whose CPU the widget shows.")

    @Parameter(title: "Host")
    var host: HostWidgetHost?

    init() {}

    init(host: HostWidgetHost?) {
        self.host = host
    }
}

/// A host as the configuration names it: its id and name from the entry.
struct HostWidgetHost: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Host"
    static let defaultQuery = HostWidgetHostQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct HostWidgetHostQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [HostWidgetHost] {
        Self.hosts().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [HostWidgetHost] { Self.hosts() }

    static func hosts(directory: URL? = WatchComplicationStore.directory()) -> [HostWidgetHost] {
        (HostWidgetStore.read(from: directory)?.hosts ?? []).map { HostWidgetHost(id: $0.id, name: $0.name) }
    }
}

// MARK: Timeline

struct HostTimelineEntry: TimelineEntry {
    let date: Date
    let host: HostWidgetEntry.Host?
    /// The chosen host's name, for a face whose host the entry does not have ("studio", unavailable); nil for Busiest.
    var chosen: String? = nil
    /// The entry's time: "As of" once it is older than `HostWidgetEntry.staleAfter`.
    let updated: Date
    var stale = false
    var relevance: TimelineEntryRelevance? { HostWidgetEntry.relevance(host, stale: stale) }
    /// Dimmed: the reading is old, or its host is not connected, or there is none.
    var dimmed: Bool { stale || host?.current != true }
}

/// The last entry the app wrote, for the chosen host: as it is, then (from `staleAfter` past its time) with its time
/// shown. The app reloads the timelines when what a face shows changed, within its budget (`HostWidgetWriter`); the
/// system asks again after 15 minutes.
struct HostWidgetProvider: AppIntentTimelineProvider {
    static let refresh: TimeInterval = 15 * 60

    var directory: @Sendable () -> URL? = { WatchComplicationStore.directory() }
    var now: @Sendable () -> Date = { Date() }

    func current(_ chosen: HostWidgetHost?) -> HostTimelineEntry {
        let date = now()
        let entry = HostWidgetStore.read(from: directory())
        let updated = entry?.updated ?? date
        return HostTimelineEntry(date: date, host: entry?.host(chosen?.id), chosen: chosen?.name, updated: updated,
                                 stale: date.timeIntervalSince(updated) > HostWidgetEntry.staleAfter)
    }

    func placeholder(in context: Context) -> HostTimelineEntry {
        HostTimelineEntry(date: now(), host: HostWidgetEntry.sample.hosts.first, updated: now())
    }

    func snapshot(for configuration: HostWidgetIntent, in context: Context) async -> HostTimelineEntry {
        context.isPreview ? placeholder(in: context) : current(configuration.host)
    }

    func timeline(for configuration: HostWidgetIntent, in context: Context) async -> Timeline<HostTimelineEntry> {
        timeline(configuration.host)
    }

    func timeline(_ chosen: HostWidgetHost?) -> Timeline<HostTimelineEntry> {
        let first = current(chosen)
        var entries = [first]
        if !first.stale {
            entries.append(HostTimelineEntry(date: first.updated.addingTimeInterval(HostWidgetEntry.staleAfter + 1), host: first.host,
                                             chosen: first.chosen, updated: first.updated, stale: true))
        }
        return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(Self.refresh)))
    }

    /// Busiest host (nil), then one per host the entry knows.
    func choices() -> [HostWidgetHost?] { [nil] + HostWidgetHostQuery.hosts(directory: directory()) }

    func recommendations() -> [AppIntentRecommendation<HostWidgetIntent>] {
        choices().map { host in
            AppIntentRecommendation(intent: HostWidgetIntent(host: host), description: host.map { Text($0.name) } ?? Text("Busiest host"))
        }
    }
}

// MARK: Views

/// The Host widget's face per family: the host's name and CPU % over its sparkline (rectangular), a CPU gauge
/// (circular); red when the phone flags the CPU high, dimmed while not current.
struct HostWidgetView: View {
    let entry: HostTimelineEntry
    /// Set by the tests; the widget reads its family from the environment.
    var family: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    static let red = Color(red: 0xE0 / 255, green: 0x7B / 255, blue: 0x7B / 255)

    private var tint: Color {
        guard let rgb = entry.host?.tint.flatMap(WatchTint.components) else { return .gray }
        return Color(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    var body: some View {
        switch family ?? environmentFamily {
        case .accessoryRectangular: rectangular
        default: circular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let host = entry.host {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(host.name).font(.headline).foregroundStyle(tint).lineLimit(1).widgetAccentable()
                    Spacer(minLength: 2)
                    Text(Self.cpu(host)).font(.headline.monospacedDigit())
                        .foregroundStyle(host.high ? Self.red : .primary)
                }
                if host.history.compactMap({ $0 }).count > 1 {
                    Sparkline(values: host.history, color: host.high ? Self.red : tint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                }
                if entry.stale {
                    Text("As of \(Text(entry.updated, style: .time))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                } else {
                    Text("CPU · 15 min").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(entry.chosen ?? "Host").font(.headline).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.chosen == nil ? "No host statistics" : "Not available").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(entry.dimmed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(entry))
    }

    private var circular: some View {
        let cpu = entry.host?.cpu ?? 0
        return Gauge(value: min(max(cpu, 0), 100), in: 0...100) {
            Text("CPU")
        } currentValueLabel: {
            Text(entry.host.map { "\(Int(($0.cpu ?? 0).rounded()))" } ?? "—")
                .foregroundStyle(entry.host?.high == true ? Self.red : .primary)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(entry.host?.high == true ? Self.red : tint)
        .widgetAccentable()
        .opacity(entry.dimmed ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(entry))
    }

    /// "34%"; "—%" without a reading.
    static func cpu(_ host: HostWidgetEntry.Host) -> String {
        host.cpu.map { "\(Int($0.rounded()))%" } ?? "—%"
    }

    /// "studio, CPU 34 percent, high, not current"; "studio, not available" for a chosen host the entry lacks.
    static func accessibilityLabel(_ entry: HostTimelineEntry) -> String {
        guard let host = entry.host else { return entry.chosen.map { $0 + ", not available" } ?? "No host statistics" }
        var parts = [host.name]
        if let cpu = host.cpu { parts.append("CPU \(Int(cpu.rounded())) percent") }
        if host.high { parts.append("high") }
        if !host.current || entry.stale { parts.append("not current") }
        return parts.joined(separator: ", ")
    }
}
