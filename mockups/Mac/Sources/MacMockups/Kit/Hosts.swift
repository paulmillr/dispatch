import SwiftUI

/// A machine as the mockups show it: its glyph and, for a remote one, its colour (the app's HostTint, linked, so the
/// tones are the app's).
struct MockHost: Hashable {
    enum System: Hashable { case mac, debian, server }
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

/// HostGlyph's artwork: the Apple logo, Debian's swirl (the app's HostDebian asset, read from the checkout), a server
/// rack; 0.82 of the frame.
struct MockHostGlyph: View {
    let system: MockHost.System
    var size: CGFloat = 16.8
    var body: some View {
        Group {
            switch system {
            case .mac: Image(systemName: "apple.logo").resizable().scaledToFit().frame(width: size * 0.82 / 0.965, height: size * 0.82 / 0.965)
            case .server: Image(systemName: "server.rack").resizable().scaledToFit().frame(width: size * 0.82, height: size * 0.82)
            case .debian:
                if let debian = Self.debian {
                    Image(nsImage: debian).renderingMode(.template).resizable().scaledToFit()
                        .frame(width: size * 0.82 / 0.745, height: size * 0.82 / 0.745)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// HostGlyph's Extent.debian: the swirl fills 0.745 of its 14-point viewBox.
    @MainActor private static let debian: NSImage? = NSImage(contentsOf: Paths.mockups
        .appendingPathComponent("../Dispatch/Resources/Assets.xcassets/HostDebian.imageset/HostDebian.svg"))
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
    static let buildBox = MockHost(name: "build-box", system: .debian, color: .cyan)
    static let ai = MockHost(name: "ai", system: .server, color: .orange)
    static let staging = MockHost(name: "staging", system: .server, color: .green, offline: true)
}
