import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WidgetKit
import XCTest
@testable import DispatchWatch

/// The complications (K7): the entry a snapshot gives, the tap's URL, the App Group file, the timeline the widget reads
/// and the writer that keeps it current. With `DISPATCH_WATCH_AGENTS_SHOTS` set to a directory, the rectangular, corner
/// and circular faces are saved there as PNGs (K7's fidelity pair).
@MainActor
final class WatchComplicationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("complication-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The count is the phone's; the first row is the newest that needs you, with what it asks and its host.
    func testTheEntryNamesTheFirstRowThatNeedsYou() {
        let entry = WatchComplicationEntry(WatchFixtures.demo(now: now))
        XCTAssertEqual(entry.needsYou, 2)
        XCTAssertEqual(entry.text, "Which schedule should I use for the next run?")
        XCTAssertEqual(entry.host, "lab")
        XCTAssertEqual(entry.key, WatchFixtures.question)
        XCTAssertEqual(entry.title, "Needs you · 2")
        XCTAssertEqual(entry.line, "Which schedule should I use for the next run? · lab")

        let mockup = WatchComplicationEntry(WatchFixtures.mockup(now: now))
        XCTAssertEqual(mockup.line, "Allow cargo test --workspace? · mba2")
        XCTAssertEqual(mockup.agent, "codex")
    }

    func testNothingWaitingIsGrey() {
        let entry = WatchComplicationEntry(WatchSnapshot(generated: now, phone: WatchPhone(), hosts: []))
        XCTAssertEqual(entry.needsYou, 0)
        XCTAssertEqual(entry.title, "Nothing waiting")
        XCTAssertNil(entry.line)
        XCTAssertNil(entry.key)
        XCTAssertEqual(entry.url.absoluteString, "dispatch-watch://agents")
    }

    /// A tap opens the first row's thread through the router; one with nothing waiting brings Agents forward.
    func testATapOpensTheFirstRowThatNeedsYou() throws {
        let entry = WatchComplicationEntry(WatchFixtures.demo(now: now))
        XCTAssertEqual(WatchComplicationEntry.key(entry.url), WatchFixtures.question)
        let router = WatchRouter()
        router.open(url: entry.url)
        XCTAssertEqual(router.take(), WatchFixtures.question)
        router.open(url: try XCTUnwrap(URL(string: "dispatch-watch://agents")))
        XCTAssertNil(router.take())
        XCTAssertTrue(router.showAgents)
        XCTAssertNil(WatchComplicationEntry.key(try XCTUnwrap(URL(string: "dispatch-watch://open?host=nope&node=term_1"))))
        XCTAssertNil(WatchComplicationEntry.key(try XCTUnwrap(URL(string: "https://example.com/open?host=x"))))
    }

    /// The widget's timeline is the file the app wrote; without a file it is "Nothing waiting".
    func testTheTimelineReadsWhatTheAppWrote() throws {
        let directory = try directory()
        let now = now
        let provider = NeedsYouProvider(directory: { directory }, now: { now })
        XCTAssertEqual(provider.current().entry, .empty(at: now))
        let entry = WatchComplicationEntry(WatchFixtures.demo(now: now))
        try WatchComplicationStore.write(entry, to: directory)
        let timeline = provider.timeline()
        XCTAssertEqual(timeline.entries.first?.entry, entry)
        XCTAssertNil(WatchComplicationStore.read(from: nil))
    }

    /// The writer keeps the newest entry; it reloads the faces when what they show changed, or when the last entry was
    /// old enough to show its time.
    func testTheWriterKeepsTheNewestAndReloadsOnAChange() throws {
        let directory = try directory()
        var reloads = 0
        var clock = now
        let writer = WatchComplicationWriter(directory: directory, now: { clock }, reload: { reloads += 1 })
        var snapshot = WatchFixtures.demo(now: now)
        writer.write(snapshot)
        XCTAssertEqual(reloads, 1)
        snapshot.generated = now.addingTimeInterval(30)
        clock = snapshot.generated
        writer.write(snapshot)
        XCTAssertEqual(reloads, 1, "only the time changed")
        XCTAssertEqual(WatchComplicationStore.read(from: directory)?.updated, snapshot.generated, "the newer time is kept")
        snapshot.conversations.removeAll { $0.key == WatchFixtures.question }
        snapshot.phone.needsYou = 1
        snapshot.generated = now.addingTimeInterval(60)
        writer.write(snapshot)
        XCTAssertEqual(reloads, 2)
        XCTAssertEqual(WatchComplicationStore.read(from: directory)?.host, "studio")
        // An older entry (a late context after the phone's transfer) is ignored.
        writer.write(entry: WatchComplicationEntry(needsYou: 7, updated: now))
        XCTAssertEqual(WatchComplicationStore.read(from: directory)?.needsYou, 1)
        // The faces showed "As of": the same entry, newer, reloads them.
        clock = now.addingTimeInterval(3600)
        var entry = try XCTUnwrap(writer.written)
        entry.updated = clock
        writer.write(entry: entry)
        XCTAssertEqual(reloads, 3)
        // A new writer starts from the file (a background launch).
        XCTAssertEqual(WatchComplicationWriter(directory: directory, reload: {}).written, entry)
        // No container (not signed into the group): nothing written, nothing reloaded.
        let unsigned = WatchComplicationWriter(directory: nil, reload: { reloads += 1 })
        unsigned.write(snapshot)
        XCTAssertEqual(reloads, 3)
    }

    /// The phone's transfer: the entry travels as user info under its own key.
    func testTheEntryTravelsAsUserInfo() throws {
        let entry = WatchComplicationEntry(WatchFixtures.mockup(now: now))
        XCTAssertEqual(WatchComplicationEntry.value(in: try entry.userInfo()), entry)
        XCTAssertNil(WatchComplicationEntry.value(in: [WatchCodec.key: Data()]))
        XCTAssertTrue(entry.shows(WatchComplicationEntry(WatchFixtures.mockup(now: now.addingTimeInterval(60)))))
        XCTAssertFalse(entry.shows(nil))
        XCTAssertFalse(entry.shows(.empty(at: now)))
        let long = WatchComplicationEntry(WatchFixtures.crowded(hosts: 1, conversations: 3, now: now))
        XCTAssertLessThanOrEqual(long.text?.count ?? 0, WatchLimits.preview)
    }

    /// Fresh: one entry, then the same with its time from `staleAfter` on; old: with its time at once. The system asks
    /// again after half an hour.
    func testTheTimelineShowsTheEntrysTimeOnceItIsOld() throws {
        let directory = try directory()
        let now = now, later = now.addingTimeInterval(600)
        try WatchComplicationStore.write(WatchComplicationEntry(WatchFixtures.demo(now: now)), to: directory)
        var timeline = NeedsYouProvider(directory: { directory }, now: { now }).timeline()
        XCTAssertEqual(timeline.entries.map(\.stale), [false, true])
        XCTAssertEqual(timeline.entries[1].date, now.addingTimeInterval(WatchComplicationEntry.staleAfter + 1))
        XCTAssertEqual(timeline.policy, .after(now.addingTimeInterval(NeedsYouProvider.refresh)))
        timeline = NeedsYouProvider(directory: { directory }, now: { later }).timeline()
        XCTAssertEqual(timeline.entries.map(\.stale), [true])
    }

    /// Every family draws for both states; with the shots directory set, K7's preview (the rectangular and corner faces
    /// as the mockup's note lays them out) is saved too.
    func testTheFacesRender() throws {
        let shots = ProcessInfo.processInfo.environment["DISPATCH_WATCH_AGENTS_SHOTS"].map { URL(fileURLWithPath: $0) }
        if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        let waiting = WatchComplicationEntry(WatchFixtures.mockup(now: now))
        for entry in [waiting, .empty(at: now)] {
            for family in [WidgetFamily.accessoryRectangular, .accessoryCorner, .accessoryCircular, .accessoryInline] {
                let view = NeedsYouWidgetView(entry: entry, stale: true, family: family).frame(width: 170, height: 60)
                XCTAssertNotNil(ImageRenderer(content: view).cgImage, "\(family)")
            }
        }
        guard let shots else { return }
        let renderer = ImageRenderer(content: ComplicationPreview(entry: waiting).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let url = shots.appendingPathComponent("complication.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

// MARK: Host widget

extension WatchComplicationTests {
    /// The hosts with a CPU reading, in the phone's order; the chosen one while the entry has it, else the busiest
    /// current one; the Smart Stack's relevance only while the phone flags a current host's CPU high.
    func testTheHostEntryChoosesItsHostElseTheBusiest() throws {
        var snapshot = WatchFixtures.demo(now: now)
        var entry = HostWidgetEntry(snapshot)
        XCTAssertEqual(entry.hosts.map(\.name), ["studio", "lab", "pi"])
        XCTAssertEqual(entry.hosts.map(\.current), [true, true, false])
        XCTAssertEqual(entry.hosts.first?.cpu, 34)
        XCTAssertEqual(entry.hosts.first?.history.count, WatchHostStats.historyCount)
        XCTAssertEqual(entry.host(nil)?.name, "studio", "the busiest connected host")
        XCTAssertEqual(entry.host(WatchFixtures.lab)?.name, "lab")
        XCTAssertEqual(entry.host(WatchFixtures.pi)?.name, "pi", "chosen, though offline (shown dimmed)")
        XCTAssertNil(entry.host("gone"), "a chosen host the entry lacks is unavailable, not another host")
        XCTAssertEqual(HostWidgetEntry.relevance(entry.host(nil), stale: false).score, 0)
        snapshot.hosts[1].stats?.cpu = 96
        snapshot.hosts[1].stats?.warnings = [.cpu]
        entry = HostWidgetEntry(snapshot)
        XCTAssertEqual(entry.host(nil)?.name, "lab")
        XCTAssertEqual(HostWidgetEntry.relevance(entry.host(nil), stale: false).score, 1)
        XCTAssertEqual(HostWidgetEntry.relevance(entry.host(nil), stale: true).score, 0, "an old reading is not news")
        XCTAssertEqual(HostWidgetEntry.relevance(entry.host(WatchFixtures.pi), stale: false).score, 0)
        XCTAssertNil(HostWidgetEntry(WatchSnapshot(generated: now, phone: WatchPhone(), hosts: [])).host(nil))
        // A tap opens the host's screen.
        let url = HostWidgetEntry.url(host: WatchFixtures.lab)
        XCTAssertEqual(HostWidgetEntry.host(url), WatchFixtures.lab)
        let router = WatchRouter()
        router.open(url: url)
        XCTAssertEqual(router.show, .host(WatchHostRoute(host: WatchFixtures.lab)))
        XCTAssertNil(router.take())
        XCTAssertNil(HostWidgetEntry.host(try XCTUnwrap(URL(string: "dispatch-watch://host?host=nope"))))
    }

    /// The timeline reads the file for the chosen host, shows its time once old; the recommendations are Busiest host
    /// and one per host.
    func testTheHostTimelineReadsWhatTheAppWrote() throws {
        let directory = try directory()
        let now = now
        let provider = HostWidgetProvider(directory: { directory }, now: { now })
        XCTAssertNil(provider.current(nil).host)
        XCTAssertEqual(provider.choices().map(\.?.name), [nil])
        XCTAssertEqual(provider.recommendations().count, 1)
        try HostWidgetStore.write(HostWidgetEntry(WatchFixtures.demo(now: now)), to: directory)
        var timeline = provider.timeline(HostWidgetHost(id: WatchFixtures.lab, name: "lab"))
        XCTAssertEqual(timeline.entries.first?.host?.name, "lab")
        XCTAssertEqual(timeline.entries.map(\.stale), [false, true])
        XCTAssertEqual(timeline.policy, .after(now.addingTimeInterval(HostWidgetProvider.refresh)))
        timeline = HostWidgetProvider(directory: { directory }, now: { now.addingTimeInterval(600) }).timeline(nil)
        XCTAssertEqual(timeline.entries.map(\.stale), [true])
        XCTAssertEqual(timeline.entries.first?.host?.name, "studio")
        XCTAssertEqual(timeline.entries.first?.dimmed, true, "stale")
        XCTAssertEqual(timeline.entries.first?.relevance?.score, 0)
        // A chosen host the entry no longer has: unavailable, by its name.
        let gone = provider.current(HostWidgetHost(id: "6E1D1A5C-57D1-4C0A-8000-000000000009", name: "old-box"))
        XCTAssertNil(gone.host)
        XCTAssertEqual(gone.chosen, "old-box")
        XCTAssertEqual(HostWidgetView.accessibilityLabel(gone), "old-box, not available")
        XCTAssertEqual(provider.choices().map(\.?.name), [nil, "studio", "lab", "pi"])
        XCTAssertEqual(provider.recommendations().count, 4)
        XCTAssertEqual(HostWidgetHostQuery.hosts(directory: directory).map(\.id), [WatchFixtures.studio, WatchFixtures.lab, WatchFixtures.pi])
    }

    /// Written only when what a face could show changed; the faces reload at most every `reloadInterval` for numbers,
    /// every `urgentInterval` when a host is flagged high (or no longer), never more than `dailyCap` a day; the
    /// recommendations follow the hosts.
    func testTheHostWriterWritesOnChangeAndReloadsWithinItsBudget() throws {
        let directory = try directory()
        var reloads = 0, recommendations = 0
        var clock = now
        let writer = HostWidgetWriter(directory: directory, now: { clock }, reload: { reloads += 1 }, recommend: { recommendations += 1 })
        var snapshot = WatchFixtures.demo(now: now)
        func write(at offset: TimeInterval, _ change: (inout WatchSnapshot) -> Void) {
            clock = now.addingTimeInterval(offset)
            snapshot.generated = clock
            change(&snapshot)
            writer.write(snapshot)
        }
        writer.write(snapshot)
        XCTAssertEqual([reloads, recommendations], [1, 1])
        // Only the time: nothing written.
        write(at: 15) { _ in }
        XCTAssertEqual(HostWidgetStore.read(from: directory)?.updated, now, "unchanged faces are not written")
        // New numbers within the interval: written, not reloaded.
        write(at: 30) { $0.hosts[0].stats?.cpu = 40 }
        XCTAssertEqual(HostWidgetStore.read(from: directory)?.hosts.first?.cpu, 40)
        XCTAssertEqual(reloads, 1)
        // Flagged high a minute after the last reload: not yet (urgent reloads are paced too); after five minutes, yes.
        write(at: 60) { $0.hosts[0].stats?.warnings = [.cpu] }
        XCTAssertEqual(reloads, 1)
        write(at: 60 + HostWidgetWriter.urgentInterval) { $0.hosts[0].stats?.warnings = [] }
        XCTAssertEqual(reloads, 2)
        // New numbers once the interval passed: reloaded.
        write(at: 120 + HostWidgetWriter.urgentInterval + HostWidgetWriter.reloadInterval) { $0.hosts[0].stats?.cpu = 55 }
        XCTAssertEqual(reloads, 3)
        XCTAssertEqual(recommendations, 1)
        // A host renamed: new recommendations; the faces wait for their interval.
        write(at: 121 + HostWidgetWriter.urgentInterval + HostWidgetWriter.reloadInterval) { $0.hosts[1].name = "lab2" }
        XCTAssertEqual([reloads, recommendations], [3, 2])
        // An older snapshot is ignored; a new writer starts from the file.
        let latest = writer.written
        snapshot.generated = now
        snapshot.hosts[0].stats?.cpu = 1
        writer.write(snapshot)
        XCTAssertEqual(HostWidgetStore.read(from: directory)?.hosts.first?.cpu, 55)
        XCTAssertEqual(HostWidgetWriter(directory: directory, reload: {}, recommend: {}).written, latest)
        HostWidgetWriter(directory: nil, reload: { reloads += 1 }, recommend: {}).write(WatchFixtures.demo(now: clock))
        XCTAssertEqual(reloads, 3)
    }

    /// A host flapping between current and not, or CPU hovering at the threshold, all day long: at most `dailyCap`
    /// reloads in 24 hours.
    func testUrgentReloadsAreCappedPerDay() throws {
        let directory = try directory()
        var reloads = 0
        var clock = now
        let writer = HostWidgetWriter(directory: directory, now: { clock }, reload: { reloads += 1 }, recommend: {})
        var snapshot = WatchFixtures.demo(now: now)
        for step in 0..<(24 * 60) {
            clock = now.addingTimeInterval(Double(step) * 60)
            snapshot.generated = clock
            snapshot.hosts[0].stats?.warnings = step.isMultiple(of: 2) ? [.cpu] : []
            writer.write(snapshot)
        }
        XCTAssertLessThanOrEqual(reloads, HostWidgetWriter.dailyCap)
        XCTAssertGreaterThan(reloads, 0)
        // A day later there is budget again.
        clock = now.addingTimeInterval(2 * 86_400)
        snapshot.generated = clock
        snapshot.hosts[0].stats?.warnings = [.cpu]
        let before = reloads
        writer.write(snapshot)
        XCTAssertEqual(reloads, before + 1)
    }

    /// Both families draw with a host, flagged high, stale and without one. With the shots directory set, saved as
    /// `host-widget.png`.
    func testTheHostFacesRender() throws {
        let entry = HostWidgetEntry(WatchFixtures.demo(now: now))
        var high = try XCTUnwrap(entry.hosts.first)
        high.cpu = 92
        high.high = true
        let entries = [HostTimelineEntry(date: now, host: entry.hosts.first, updated: now),
                       HostTimelineEntry(date: now, host: high, updated: now),
                       HostTimelineEntry(date: now, host: entry.hosts.last, updated: now.addingTimeInterval(-900), stale: true),
                       HostTimelineEntry(date: now, host: nil, updated: now),
                       HostTimelineEntry(date: now, host: nil, chosen: "old-box", updated: now)]
        XCTAssertEqual(HostWidgetView.accessibilityLabel(entries[1]), "studio, CPU 92 percent, high")
        XCTAssertEqual(HostWidgetView.accessibilityLabel(entries[2]), "pi, CPU 3 percent, not current")
        XCTAssertEqual(HostWidgetView.accessibilityLabel(entries[3]), "No host statistics")
        let faces = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 10) {
                    HostWidgetView(entry: entry, family: .accessoryRectangular)
                        .frame(width: 150, height: 56)
                        .padding(8)
                        .background(AgentsColor.groupedRow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    HostWidgetView(entry: entry, family: .accessoryCircular).frame(width: 46, height: 46)
                }
            }
        }
        .padding(8)
        .background(.black)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: faces)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        guard let shots = ProcessInfo.processInfo.environment["DISPATCH_WATCH_AGENTS_SHOTS"].map({ URL(fileURLWithPath: $0) }) else { return }
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let url = shots.appendingPathComponent("host-widget.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// K7's preview at 46 mm (208 × 248 pt): the rectangular face on a Smart Stack platter, the corner face in a face's
/// top-left corner with its count along the bezel, as the mockup's note shows them.
private struct ComplicationPreview: View {
    let entry: WatchComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Complication").font(.title3).foregroundStyle(.secondary).padding(.leading, 6).padding(.top, 30)
            Text("Rectangular (Smart Stack)").font(.caption2).foregroundStyle(.secondary)
            NeedsYouWidgetView(entry: entry, family: .accessoryRectangular)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(AgentsColor.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("Corner").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    Circle().trim(from: 0.5, to: 0.75)
                        .stroke(NeedsYouWidgetView.pink.opacity(0.4), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 104, height: 104)
                        .offset(x: 2, y: 2)
                    NeedsYouWidgetView(entry: entry, family: .accessoryCorner).scaleEffect(0.75).offset(x: 4, y: 26)
                    Text("\(entry.needsYou)").font(.system(size: 14, weight: .semibold, design: .rounded)).offset(x: 31, y: 30)
                }
                .frame(width: 56, height: 50, alignment: .topLeading)
                .clipped()
                Text("Pink only while something needs you.").font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AgentsColor.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(width: 208, height: 248, alignment: .topLeading)
        .background(.black)
    }
}
