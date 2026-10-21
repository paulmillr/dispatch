import SwiftUI

extension Color {
    /// A host's tint as the phone sends it (`WatchHost.tint`, `#RRGGBB` sRGB, `WatchTint.hex`); grey for nil or anything
    /// else, as the phone draws a host it has not reached.
    init(watchHex hex: String?) {
        if let hex, let rgb = WatchTint.components(hex) {
            self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self = .gray
        }
    }
}

/// The gutter dots, the phone's `StateUnread`/`StateWorking` (Mobile/App/Assets.xcassets, the same in light and dark).
enum WatchDots {
    /// Needs you, or a result not yet seen (as Mail marks unread).
    static let needsYou = Color(.sRGB, red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let unseen = needsYou
    static let working = Color(.sRGB, red: 0xD9 / 255, green: 0xB3 / 255, blue: 0x6A / 255)
    /// A connected host's status dot (`StateFinished`).
    static let connected = Color(.sRGB, red: 0x7F / 255, green: 0xD3 / 255, blue: 0xA1 / 255)

    static func color(_ dot: WatchDot?) -> Color? {
        switch dot {
        case .unread?: needsYou
        case .working?: working
        case .unknown?, nil: nil
        }
    }
}

/// Row times on a watch: the phone's Messages-style "9:31"/"Yesterday" does not fit beside a name on a 42 mm screen, so
/// the watch abbreviates as watchOS lists do: "now" within a minute, then "5m", "2h", "3d", "6w", "2y".
enum WatchTime {
    static func relative(_ date: Date, now: Date = .now) -> String {
        // A time slightly ahead (the phone's clock) reads as now; the rows never show future times.
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
        if minutes < 1 { return "now" }
        if hours < 1 { return "\(minutes)m" }
        if days < 1 { return "\(hours)h" }
        if days < 14 { return "\(days)d" }
        if days < 365 { return "\(days / 7)w" }
        return "\(days / 365)y"
    }

    /// "25 min ago", "2 hr ago", "3 days ago": the notices' and the offline host's longer form.
    static func ago(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
        if minutes < 1 { return "just now" }
        if hours < 1 { return "\(minutes) min ago" }
        if days < 1 { return "\(hours) hr ago" }
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// A duration as the phone's captions word it (`ChatTurnSummary.elapsed`): "48s", "4m 2s", "1h 5m".
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }
}

/// A host's mark (the phone's `HostGlyph` in a tinted disc, as `MobileRow` draws it): the system's glyph (apple.logo for
/// macOS, server.rack for Linux, as HostGlyph falls back without its distribution artwork), or the name's initial before
/// the host was reached.
struct WatchHostMark: View {
    let host: WatchHost
    var size: CGFloat = 22

    var body: some View {
        let tint = Color(watchHex: host.tint)
        Group {
            if let symbol = Self.symbol(host.system) {
                Image(systemName: symbol).resizable().scaledToFit().padding(size * 0.24)
            } else {
                Text(host.name.prefix(1).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background(tint.opacity(0.2), in: Circle())
        .accessibilityHidden(true)
    }

    static func symbol(_ system: String?) -> String? {
        switch system {
        case "macos"?: "apple.logo"
        case "linux"?: "server.rack"
        default: nil
        }
    }
}

/// A row's gutter dot (`MobileRowDot`): fixed width so rows line up whether or not they have one.
struct WatchDotView: View {
    let color: Color?
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color ?? .clear).frame(width: size, height: size).accessibilityHidden(true)
    }
}
