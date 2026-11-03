import SwiftUI

/// The phone's 15-minute CPU sparkline, reduced: a filled line in the host's tint with the last sample marked; gaps
/// (nil buckets) are skipped.
struct Sparkline: View {
    let values: [Double?]
    var color: Color = .gray
    /// The value of the top edge.
    var ceiling: Double = 100

    var body: some View {
        Canvas { context, size in
            guard let path = Self.points(values, in: size, ceiling: ceiling), path.count > 1 else { return }
            var line = Path()
            line.move(to: path[0])
            for point in path.dropFirst() { line.addLine(to: point) }
            var area = line
            area.addLine(to: CGPoint(x: path[path.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: path[0].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            let last = path[path.count - 1]
            context.fill(Path(ellipseIn: CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)), with: .color(color))
        }
        .accessibilityHidden(true)
    }

    /// Each sample's point (x by its bucket, y by its value); nil for fewer than two buckets.
    static func points(_ values: [Double?], in size: CGSize, ceiling: Double) -> [CGPoint]? {
        guard values.count > 1, ceiling > 0 else { return nil }
        return values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            let clamped = min(max(value, 0), ceiling)
            return CGPoint(x: size.width * Double(index) / Double(values.count - 1),
                           y: size.height - 3 - (size.height - 6) * clamped / ceiling)
        }
    }
}
