import SwiftUI
import XCTest
@testable import DispatchMobile

/// The working row's sweep, measured in rendered frames: the pink glint crossing the row's hairline (`ChatAccentScan`)
/// is the light on "thinking" (`ChatShimmerText` on a `ChatSweepTrack`): at every instant the label's brightest point is
/// where the glint's is, both travel leading to trailing on one period, and the label is unlit while the glint is
/// elsewhere on the line.
@MainActor
final class ChatThinkingSweepTests: XCTestCase {
    /// A period's start: the glint just off the line's leading end.
    private static let start = Date(timeIntervalSinceReferenceDate: 363_636_363 * ChatThinkingSweep.period)
    private static let line: CGFloat = 300
    private static let labelX: CGFloat = 40
    private static let scale: CGFloat = 2

    /// Per column, how far the drawn pixels stray from `base` (0...255, the largest in the column), or how opaque they
    /// are without a base; nil where nothing is drawn.
    private static func columns(_ view: some View, width: CGFloat, height: CGFloat, at date: Date,
                                base: [Double]?) -> [Double?] {
        let renderer = ImageRenderer(content: view.environment(\.reduceMotionOverride, false)
            .environment(\.animationDateOverride, date)
            .environment(\.colorScheme, .dark)
            .frame(width: width, height: height, alignment: .leading))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return [] }
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (0..<image.width).map { x in
            var largest: Double?
            for y in 0..<image.height {
                let offset = y * bytesPerRow + x * 4
                let alpha = Double(pixels[offset + 3])
                guard let base else {
                    largest = max(largest ?? 0, alpha)
                    continue
                }
                guard alpha > 200 else { continue }
                let rgb = (0..<3).map { Double(pixels[offset + $0]) * 255 / alpha }
                largest = max(largest ?? 0, zip(rgb, base).map { abs($0 - $1) }.max() ?? 0)
            }
            return largest
        }
    }

    /// The brightest column, in points; nil when no column strays more than `threshold`.
    private static func peak(_ columns: [Double?], threshold: Double) -> CGFloat? {
        var best: (Int, Double)?
        for (x, value) in columns.enumerated() {
            guard let value, value > threshold, value > (best?.1 ?? 0) else { continue }
            best = (x, value)
        }
        return best.map { CGFloat($0.0) / scale }
    }

    private static let shimmerBase: [Double] = [0x8E, 0x8E, 0x96]

    /// The label's drawn width.
    private static var label: CGFloat {
        let renderer = ImageRenderer(content: ChatShimmerText(text: "thinking").environment(\.reduceMotionOverride, true))
        return renderer.uiImage?.size.width ?? 60
    }

    /// The light on "thinking", on the line's x.
    private static func shimmer(at date: Date, width: CGFloat) -> CGFloat? {
        let view = ChatShimmerText(text: "thinking", track: ChatSweepTrack(lineWidth: line, labelX: labelX)).fixedSize()
        return peak(columns(view, width: width, height: 24, at: date, base: shimmerBase), threshold: 12).map { $0 + labelX }
    }

    /// The glint on the hairline.
    private static func scan(at date: Date) -> CGFloat? {
        peak(columns(ChatAccentScan(), width: line, height: 2, at: date, base: nil), threshold: 20)
    }

    /// The light on the label is the glint over it: same x at every instant (within a glyph's gap), leading to
    /// trailing, unlit while the glint is away, on one period.
    func testTheLabelLightsWhereTheGlintPassesOverIt() {
        let width = Self.label
        var report: [String] = []
        var lit: [(CGFloat, CGFloat)] = []
        var lines: [CGFloat] = []
        for step in 0..<Int(ChatThinkingSweep.period / 0.02) {
            let date = Self.start.addingTimeInterval(Double(step) * 0.02)
            let label = Self.shimmer(at: date, width: width)
            let line = Self.scan(at: date)
            report.append(String(format: "%.2f s: label %@ line %@", Double(step) * 0.02,
                                 label.map { String(format: "%.1f", $0) } ?? "-", line.map { String(format: "%.1f", $0) } ?? "-"))
            if let line { lines.append(line) }
            guard let line else { continue }
            let glintHalf = Self.line * ChatAccentScan.share / 2
            if line > Self.labelX + 4, line < Self.labelX + width - 4 {
                // The glint's peak is over the label: so is the label's.
                if let label { lit.append((label, line)) } else { XCTFail("unlit under the glint\n\(report.joined(separator: "\n"))") }
            } else if line < Self.labelX - glintHalf - 2 || line > Self.labelX + width + glintHalf + 2 {
                XCTAssertNil(label, "lit while the glint is away\n\(report.joined(separator: "\n"))")
            }
        }
        let text = report.joined(separator: "\n")
        XCTAssertGreaterThan(lit.count, 3, "the glint crosses the label\n\(text)")
        for (label, line) in lit { XCTAssertEqual(label, line, accuracy: 4, "the same x\n\(text)") }
        for (before, after) in zip(lines, lines.dropFirst()) { XCTAssertGreaterThanOrEqual(after, before - 0.5, "leading to trailing\n\(text)") }
        for (before, after) in zip(lit, lit.dropFirst()) { XCTAssertGreaterThanOrEqual(after.0, before.0 - 2, "leading to trailing\n\(text)") }
        // One period: a period later both draw what they drew.
        for step in [0, 9, 21, 33] {
            let date = Self.start.addingTimeInterval(Double(step) * 0.05)
            let later = date.addingTimeInterval(ChatThinkingSweep.period)
            XCTAssertEqual(Self.shimmer(at: date, width: width) ?? -1, Self.shimmer(at: later, width: width) ?? -1, accuracy: 0.5)
            XCTAssertEqual(Self.scan(at: date) ?? -1, Self.scan(at: later) ?? -1, accuracy: 0.5)
        }
    }

    /// One clock for both, from the media time: two rows drawn at the same instant are at the same point.
    func testTheSweepIsAFunctionOfTheInstant() {
        let date = Self.start.addingTimeInterval(0.7)
        XCTAssertEqual(ChatThinkingSweep.progress(at: date), ChatThinkingSweep.progress(at: date))
        XCTAssertEqual(ChatThinkingSweep.progress(at: Self.start), 0, accuracy: 0.001, "a period starts at the leading end")
        let values = (0..<44).map { ChatThinkingSweep.progress(at: Self.start.addingTimeInterval(Double($0) * 0.05)) }
        XCTAssertEqual(values, values.sorted(), "never back within a period")
        XCTAssertEqual(values.last ?? 0, 1, accuracy: 0.01)
    }
}
