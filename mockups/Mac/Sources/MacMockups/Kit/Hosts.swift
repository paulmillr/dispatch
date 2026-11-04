import SwiftUI

/// A machine as the mockups show it: its glyph and, for a remote one, its colour (the app's HostTint, linked, so the
/// tones are the app's).
struct MockHost: Hashable {
    enum System: Hashable { case mac, ubuntu, server }
    var name: String
    var system = System.mac
    var color: HostColor?
    var offline = false
    var local: Bool { color == nil }

    static let local = MockHost(name: "Local")

    @MainActor var tint: HostTint? {
        guard let color else { return nil }
        var tint = HostTint(hostID: name).showing(color)
        tint.offline = offline
        return tint
    }
    /// The glyph's colour: the host's, else the palette's secondary.
    @MainActor var foreground: Color { tint?.foreground ?? Chrome.palette.secondary }
}

/// HostGlyph's artwork: the Apple logo, Ubuntu's circle of friends, a server rack; 0.82 of the frame.
struct MockHostGlyph: View {
    let system: MockHost.System
    var size: CGFloat = 16.8
    var body: some View {
        Group {
            switch system {
            case .mac: Image(systemName: "apple.logo").resizable().scaledToFit().frame(width: size * 0.82 / 0.965, height: size * 0.82 / 0.965)
            case .server: Image(systemName: "server.rack").resizable().scaledToFit().frame(width: size * 0.82, height: size * 0.82)
            case .ubuntu: Canvas { context, box in Self.ubuntu(context, size: box) }.frame(width: size * 0.82 / 0.95, height: size * 0.82 / 0.95)
            }
        }
        .frame(width: size, height: size)
    }

    private static func ubuntu(_ context: GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.28
        let scale = min(size.width, size.height) / 15
        for index in 0..<3 {
            let angle = Double(index) * 120 + 180
            var arc = Path()
            arc.addArc(center: center, radius: radius, startAngle: .degrees(angle + 24), endAngle: .degrees(angle + 96), clockwise: false)
            context.stroke(arc, with: .foreground, lineWidth: 1.7 * scale)
            let x = center.x + CGFloat(cos(angle * .pi / 180)) * radius * 1.5
            let y = center.y + CGFloat(sin(angle * .pi / 180)) * radius * 1.5
            context.fill(Path(ellipseIn: CGRect(x: x - 1.6 * scale, y: y - 1.6 * scale, width: 3.2 * scale, height: 3.2 * scale)), with: .foreground)
        }
    }
}

/// An agent's state as the sidebar and tabs mark it (AgentActivityGlyph): ◆ finished, ● waiting on you, ◐ working.
enum Activity: Hashable {
    /// `quiet`: a tab with nothing to report, a small dot (hidden in the sidebar, as the app's).
    case none, quiet, working, waiting, finished, failed, offline

    @MainActor @ViewBuilder func glyph(size: CGFloat = 13.5, frame: CGFloat = 11) -> some View {
        let p = Chrome.palette
        Group {
            switch self {
            case .none: Color.clear
            case .quiet: Circle().fill(p.muted).frame(width: size * 0.2, height: size * 0.2)
            case .finished: Image(systemName: "diamond.fill").font(.system(size: size * 0.62)).foregroundStyle(p.accent)
            case .failed: Image(systemName: "diamond.fill").font(.system(size: size * 0.62)).foregroundStyle(p.warning)
            case .waiting: Image(systemName: "circle.fill").font(.system(size: size * 0.55)).foregroundStyle(p.green)
            case .working: Image(systemName: "circle.lefthalf.filled").font(.system(size: size * 0.62)).foregroundStyle(p.ink)
            case .offline: Image(systemName: "circle.dotted").font(.system(size: size * 0.62)).foregroundStyle(p.muted)
            }
        }
        .frame(width: frame)
    }
}

/// The fictional machines the mockups share with the iOS ones (mockups/README.md): no real hosts.
enum Hosts {
    static let local = MockHost.local
    static let studio = MockHost(name: "studio", system: .mac, color: .purple)
    static let buildBox = MockHost(name: "build-box", system: .ubuntu, color: .cyan)
    static let ai = MockHost(name: "ai", system: .server, color: .orange)
    static let staging = MockHost(name: "staging", system: .server, color: .green, offline: true)
}
