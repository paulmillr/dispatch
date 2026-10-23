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

    private func directory() throws -> URL {
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
