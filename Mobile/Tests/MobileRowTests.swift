import SwiftUI
import UIKit
import XCTest
@testable import DispatchMobile

@MainActor
final class MobileRowTests: XCTestCase {
    private func row(dot: MobileRow<Image>.Dot?, subtitle: String? = "astra-6 · needs approval", lines: Int = 1) -> some View {
        MobileRow(dot: dot, tint: .purple, name: "codex", detail: "e2e · mba2", time: "9:31", subtitle: subtitle, lines: lines) {
            Image(systemName: "apple.logo")
        }
        .frame(width: 402)
        .environment(\.colorScheme, .dark)
    }

    private func size(_ view: some View) -> CGSize {
        let host = UIHostingController(rootView: view)
        return host.sizeThatFits(in: CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude))
    }

    /// M2a: a two-line row is the disc's 46 points plus the row's insets, about 66 points.
    func testTwoLineRowHasTheMockupHeight() {
        let height = size(row(dot: .unread)).height
        XCTAssertGreaterThan(height, 58)
        XCTAssertLessThan(height, 78)
    }

    /// M3a: a two-line preview adds one line; a row without a subtitle still fits the disc.
    func testPreviewRowsGrowAndShortRowsFitTheDisc() {
        let preview = size(row(dot: .unread, subtitle: "Run the migration on staging, then confirm the webhook replays cleanly before Monday.", lines: 2)).height
        XCTAssertGreaterThan(preview, size(row(dot: .unread)).height + 12)
        let short = size(row(dot: nil, subtitle: nil)).height
        XCTAssertGreaterThanOrEqual(short, MobileRow<Image>.disc + 10)
        XCTAssertLessThan(short, size(row(dot: nil)).height)
    }

    /// The separator starts at the text column: list inset, gutter, disc and both gaps.
    func testTextColumnInset() {
        XCTAssertEqual(MobileRow<Image>.textInset, 96)
    }

    /// M2a's grid: the list pads 6 pt and the row 10 pt, so the dot starts 16 pt from the edge and the disc at 40 pt
    /// (the row once padded 16 pt inside the list's 6, putting everything 6 pt right of the mockup).
    func testRowStartsSixteenPointsFromTheEdge() throws {
        let probe = MobileRow(dot: .unread, tint: .purple, name: "codex", detail: nil, time: nil, subtitle: nil) {
            Image(systemName: "apple.logo")
        }
        .padding(.leading, MobileRow<Image>.listInset)
        .frame(width: 402)
        let renderer = ImageRenderer(content: probe.background(.black))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        // The leftmost saturated blue pixel: the dot's leading edge (the disc and glyph are purple, the rest black).
        let first = (0..<image.width).first { x in
            (0..<image.height).contains { y in
                let p = y * image.bytesPerRow + x * 4
                let channels = [data[p], data[p + 1], data[p + 2]]
                return channels.max()! > 200 && channels.min()! < 40
            }
        }
        XCTAssertEqual(try XCTUnwrap(first), 16, accuracy: 1)
    }

    /// The dots are the mockup's colours (Mail's blue for unread, amber working), the same in light and dark.
    func testDotColoursComeFromTheAssetCatalog() {
        let expected: [(MobileRow<Image>.Dot, UInt32)] = [(.unread, 0x0a84ff), (.working, 0xd9b36a)]
        for (dot, hex) in expected {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let color = UIColor(dot.color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), "\(dot)")
                let value = UInt32((red * 255).rounded()) << 16 | UInt32((green * 255).rounded()) << 8 | UInt32((blue * 255).rounded())
                XCTAssertEqual(value, hex, "\(dot) in \(style == .dark ? "dark" : "light")")
            }
        }
    }

    /// The M2a rows render (DISPATCH_MOBILE_ROW_PNG names a file to inspect them in).
    func testRowsRender() throws {
        let rows = VStack(spacing: 0) {
            row(dot: .unread)
            row(dot: .working, subtitle: "fable-5.1 · thinking 48s")
            row(dot: nil, subtitle: "~/src/docs")
        }.background(.black)
        let renderer = ImageRenderer(content: rows)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 402, accuracy: 1)
        if let path = ProcessInfo.processInfo.environment["DISPATCH_MOBILE_ROW_PNG"], let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
