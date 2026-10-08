import SwiftUI
import Observation

/// Shared across the separate hosting views used by the sidebar and split panes.
@MainActor @Observable
final class WorkspaceFooterLayout {
    struct Measurement {
        let surface: UUID?
        let height: CGFloat
    }
    var measurements: [UUID: Measurement] = [:]

    func height(in workspace: Workspace) -> CGFloat {
        measurements.values.filter { measurement in
            measurement.surface.map { workspace.isSurfacePresented($0) } ?? true
        }.map(\.height).max() ?? 0
    }
}

struct WorkspaceFooter: ViewModifier {
    let workspace: Workspace?
    var surface: UUID?
    @State private var measurementID = UUID()

    func body(content: Content) -> some View {
        content
            // Measure the natural content, before applying the common height,
            // so footers can shrink again after wrapping or host rows disappear.
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                    workspace?.footerLayout.measurements[measurementID] = .init(surface: surface, height: height)
                }
            })
            .frame(minHeight: workspace.map { $0.footerLayout.height(in: $0) } ?? 0)
            .onDisappear { workspace?.footerLayout.measurements[measurementID] = nil }
    }
}
