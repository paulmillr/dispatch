import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

/// What the Spaces screens draw: the M2a capsule takes the app tint only while a filter is active and shows the lens
/// on the tree segment while the tree is on; the rows keep the mockup's size. Renders in a window of the test host's
/// scene (glass samples what is behind it). `DISPATCH_TABS_PNG` (`TEST_RUNNER_DISPATCH_TABS_PNG` through xcodebuild)
/// names a folder to write the renders to.
@MainActor
final class TabsRenderTests: XCTestCase {
    private func render(_ view: some View, size: CGSize) throws -> UIImage {
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: view.ignoresSafeArea().environment(\.colorScheme, .dark))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// The segment a tab opened on stays: an agent starting in its shell (the topology binding it) does not switch a
    /// Terminal the user is typing in to Chat.
    func testTheSegmentShownStaysWhenTheTabStartsAnAgent() throws {
        let defaults = UserDefaults(suiteName: "tabs-render-\(#function)")!
        defaults.removePersistentDomain(forName: "tabs-render-\(#function)")
        let model = MobileTabs(activity: TabActivityStore(url: nil), defaults: defaults)
        var sketch = TabsFixtures.app()
        model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        let ref = try XCTUnwrap(model.workspace(TabsFixtures.host.id)?.tabs.first { $0.panes.contains { $0.key == "p:docs" } }?.ref)
        final class Shown { var segments: [String] = [] }
        let shown = Shown()
        let screen = TabScreen(model: model, ref: ref, path: .constant([]),
                               terminal: { _, _ in shown.segments.append("terminal"); return Text("terminal") },
                               chat: { _, _ in shown.segments.append("chat"); return Text("chat") })
        let scene = try XCTUnwrap(TestSupport.windowScene())
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        window.rootViewController = UIHostingController(rootView: NavigationStack { screen })
        window.isHidden = false
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(shown.segments.last, "terminal")
        sketch.spaces[1].tabs[0].panes[0].agent = "s5"
        model.sync([TabsHostInput(host: TabsFixtures.host, client: nil, topology: sketch.topology)])
        XCTAssertTrue(try XCTUnwrap(model.tab(ref)).isChat)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(shown.segments.last, "terminal", "The screen switched to Chat by itself")
        XCTAssertFalse(shown.segments.contains("chat"))
    }

    private func write(_ image: UIImage, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DISPATCH_TABS_PNG"], let data = image.pngData() else { return }
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    /// The mean colour of a small square, 0...255 per channel.
    private func color(_ image: UIImage, around point: CGPoint) -> (red: Int, green: Int, blue: Int) {
        let cg = image.cgImage!
        let scale = image.scale, side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: -(point.x * scale - CGFloat(side) / 2), y: -(CGFloat(cg.height) - point.y * scale - CGFloat(side) / 2))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var sum = (0, 0, 0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum.0 += Int(pixels[index]); sum.1 += Int(pixels[index + 1]); sum.2 += Int(pixels[index + 2])
        }
        let count = side * side
        return (sum.0 / count, sum.1 / count, sum.2 / count)
    }

    private func capsule(_ query: TabsQuery, tree: Bool = false) -> some View {
        TabsCapsule(tree: .constant(tree), query: .constant(query))
            .frame(width: 140, height: 80)
            .background(.black)
    }

    private let size = CGSize(width: 140, height: 80)

    /// M2a: neutral glass with no filter or with a sort only; the app tint with a filter.
    func testCapsuleTintsOnlyWhileFiltering() throws {
        let plain = try render(capsule(TabsQuery()), size: size)
        let sorted = try render(capsule(TabsQuery(sort: .name)), size: size)
        let filtered = try render(capsule(TabsQuery(filter: .chats)), size: size)
        try write(plain, "capsule-plain")
        try write(filtered, "capsule-filtered")
        // Inside the capsule, clear of both glyphs: just right of the hairline, near the bottom edge.
        let probe = CGPoint(x: 70, y: 54)
        for image in [plain, sorted] {
            let c = color(image, around: probe)
            XCTAssertLessThan(abs(c.red - c.blue), 24, "neutral: \(c)")
            XCTAssertLessThan(abs(c.red - c.green), 24, "neutral: \(c)")
        }
        let pink = color(filtered, around: probe)
        XCTAssertGreaterThan(pink.red, pink.green + 40, "app tint: \(pink)")
        XCTAssertGreaterThan(pink.blue, pink.green + 30, "app tint: \(pink)")
    }

    /// The tree segment is the lens while the tree is on.
    func testTreeSegmentShowsTheLens() throws {
        let probe = CGPoint(x: 32, y: 52)
        let off = color(try render(capsule(TabsQuery()), size: size), around: probe)
        let image = try render(capsule(TabsQuery(), tree: true), size: size)
        try write(image, "capsule-tree")
        let on = color(image, around: probe)
        XCTAssertGreaterThan(on.green, off.green + 12, "lens \(on) over \(off)")
    }

    /// M2a rows: the 46 point disc and two lines, about 66 points each; M2c rows drop the disc but keep the height.
    func testRowsHaveTheMockupHeight() throws {
        let model = TabsSample.model()
        let rows = Array(model.rows.prefix(6))
        XCTAssertEqual(rows.count, 6)
        func height(detail: Bool) -> CGFloat {
            let list = VStack(spacing: 0) {
                ForEach(rows) { TabsTabRow(model: model, entry: $0, detail: detail, now: Date()) }
            }
            .frame(width: 402)
            return UIHostingController(rootView: list).sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude)).height / 6
        }
        XCTAssertGreaterThan(height(detail: true), 58)
        XCTAssertLessThan(height(detail: true), 78)
        XCTAssertEqual(height(detail: false), height(detail: true), accuracy: 2)
        let list = VStack(spacing: 0) { ForEach(rows) { TabsTabRow(model: model, entry: $0, detail: true, now: Date()) } }
        try write(try render(list.frame(width: 402).background(.black), size: CGSize(width: 402, height: 420)), "rows")
    }
}
