import SwiftUI
import CryptoKit
import os

/// Presentation identity comes from the authenticated helper, never a PID,
/// socket path, or an SSH alias. A machine keeps its color across reconnects.
struct HostTint: Hashable, Sendable {
    var offline = false
    /// Derived from the machine identity: breaks ties between free colors, and colors
    /// a machine before HostRegistry has assigned it one.
    let seed: UInt32
    /// Names the machine in saved color choices without storing its identity.
    let machine: String

    init(hostID: String) {
        // Views derive tints on every render; hash each identity once.
        let identity = Self.identities.withLock { $0[hostID] } ?? {
            // SSHGreeting.hostID appends the remote uid for ownership isolation.
            // Presentation uses the machine part so different logins still agree.
            let suffix = hostID.lastIndex(of: ":")
            let host = suffix.flatMap { UInt32(hostID[hostID.index(after: $0)...]) == nil ? nil : String(hostID[..<$0]) } ?? hostID
            let digest = SHA256.hash(data: Data(host.utf8))
            let seed = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let identity = (seed, digest.prefix(16).map { String(format: "%02x", $0) }.joined())
            Self.identities.withLock { $0[hostID] = identity }
            return identity
        }()
        seed = identity.0
        machine = identity.1
    }
    private static let identities = OSAllocatedUnfairLock(initialState: [String: (UInt32, String)]())

    /// The color this machine gets unless one is chosen: the one HostRegistry assigned.
    @MainActor var automatic: HostColor {
        HostColorStore.shared.automatic[machine] ?? HostColor.allCases[Int(seed % UInt32(HostColor.allCases.count))]
    }
    /// The automatic color's OKLCH hue.
    @MainActor var hue: Double { automatic.hue }
    /// Set by `showing(_:)`; otherwise the saved choice applies.
    private var shown: HostColor?? = nil
    /// The color chosen for this machine, if any, replaces the automatic one.
    @MainActor var choice: HostColor? { shown ?? HostColorStore.shared.choices[machine] }
    /// This host drawn with `color` (nil: its automatic color) regardless of the saved choice.
    func showing(_ color: HostColor?) -> HostTint {
        var copy = self; copy.shown = .some(color); return copy
    }
    @MainActor private var preset: HostColor { choice ?? automatic }

    /// A role's OKLCH lightness and chroma, shared by every host so hosts differ only in hue and none looks louder
    /// than another. Chroma stays within what sRGB shows at that lightness for every hue (cyan is the limit), so no
    /// hue is drawn duller than the rest. Text roles keep 4.5:1 on the sidebars, edges 3:1 on the windows.
    struct Tone: Sendable {
        let lightness: Double, chroma: Double
        // Dark: as light as yellow needs to stay yellow rather than olive.
        static let darkColor = Tone(lightness: 0.65, chroma: 0.11)
        static let darkBorder = Tone(lightness: 0.75, chroma: 0.11)
        static let darkForeground = Tone(lightness: 0.78, chroma: 0.09)
        static let darkTabForeground = Tone(lightness: 0.70, chroma: 0.04)
        static let darkTabControl = Tone(lightness: 0.60, chroma: 0.05)
        // Light: washes are a vivid tone at low opacity, which reads as a clean pastel.
        static let lightColor = Tone(lightness: 0.68, chroma: 0.11)
        static let lightEdge = Tone(lightness: 0.62, chroma: 0.10)
        static let lightBorder = Tone(lightness: 0.70, chroma: 0.11)
        static let lightForeground = Tone(lightness: 0.50, chroma: 0.08)
        static let lightTabForeground = Tone(lightness: 0.45, chroma: 0.05)
        static let lightTabControl = Tone(lightness: 0.52, chroma: 0.07)
    }
    @MainActor private var dark: Bool { Chrome.palette.isDark }
    @MainActor private func draw(_ dark: Tone, _ light: Tone) -> Color {
        let tone = self.dark ? dark : light
        return Self.oklch(tone.lightness, HostColorStore.shared.enabled ? tone.chroma : 0, preset.hue)
    }
    @MainActor var color: Color {
        if offline { return dark ? Color(red: 90/255, green: 90/255, blue: 100/255) : Chrome.muted }
        return draw(.darkColor, .lightColor)
    }
    @MainActor var edge: Color {
        if offline { return dark ? Color(red: 69/255, green: 69/255, blue: 77/255) : Chrome.palette.faint }
        return draw(.darkColor, .lightEdge)
    }
    @MainActor var border: Color {
        if offline { return dark ? Color.white.opacity(0.08) : Chrome.border }
        return draw(.darkBorder, .lightBorder).opacity(dark ? 0.35 : 0.6)
    }
    /// The tab strip's wash and the top of the fade below it: barely there, so the edge carries the host color.
    @MainActor var stripWash: Color { color.opacity(dark ? (offline ? 0.04 : 0.06) : (offline ? 0.03 : 0.04)) }
    @MainActor var fadeWash: Color { color.opacity(dark ? (offline ? 0.03 : 0.04) : (offline ? 0.02 : 0.03)) }
    /// The Liquid Glass tab track's tint.
    @MainActor var glassWash: Color { color.opacity(0.1) }
    // Inactive labels and controls, faintly in the host hue.
    @MainActor var tabForeground: Color { offline ? Chrome.muted : draw(.darkTabForeground, .lightTabForeground) }
    @MainActor var tabControl: Color { offline ? Chrome.muted : draw(.darkTabControl, .lightTabControl) }
    @MainActor static var selectedTabRule: Color { Chrome.palette.isDark ? Color(red: 220.0 / 255, green: 220.0 / 255, blue: 224.0 / 255) : Chrome.ink }

    @MainActor var foreground: Color { offline ? Chrome.muted : draw(.darkForeground, .lightForeground) }

    /// OKLCH (`hue`: 0..<1 of a turn) in sRGB, its chroma reduced until the color fits.
    static func oklch(_ lightness: Double, _ chroma: Double, _ hue: Double) -> Color {
        let angle = hue * 2 * .pi
        func linear(_ chroma: Double) -> (Double, Double, Double) {
            let a = chroma * cos(angle), b = chroma * sin(angle)
            let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
            return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        }
        func fits(_ rgb: (Double, Double, Double)) -> Bool { [rgb.0, rgb.1, rgb.2].allSatisfy { (-1e-4...1 + 1e-4).contains($0) } }
        var rgb = linear(chroma)
        if !fits(rgb) {
            var low = 0.0, high = chroma
            for _ in 0..<16 {
                let middle = (low + high) / 2
                if fits(linear(middle)) { low = middle } else { high = middle }
            }
            rgb = linear(low)
        }
        func encoded(_ value: Double) -> Double {
            let value = min(1, max(0, value))
            return value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return Color(.sRGB, red: encoded(rgb.0), green: encoded(rgb.1), blue: encoded(rgb.2))
    }
}

/// The host colors, in picker order. Automatic colors are drawn from this list too,
/// so removing a case also retires it for hosts that never chose a color.
enum HostColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink
    var title: String { rawValue.capitalized }
    /// The OKLCH hue (0..<1 of a turn); HostTint.Tone sets the rest. Steps of about 45°, each nudged onto a clear
    /// color: exact steps can't land on both red (25°) and a yellow that isn't olive (95°).
    var hue: Double {
        let degrees: Double = switch self {
        case .red: 25
        case .orange: 60
        case .yellow: 95
        case .green: 145
        case .cyan: 195
        case .blue: 250
        case .purple: 300
        case .pink: 345
        }
        return degrees / 360
    }
}

/// Saved host color choices (Preferences.hostColors), applied with the other settings.
@MainActor @Observable
final class HostColorStore {
    static let shared = HostColorStore()
    var choices: [String: HostColor] = [:]
    /// Automatic colors HostRegistry assigned to remembered hosts, by HostTint.machine.
    var automatic: [String: HostColor] = [:]
    /// Settings' Host colors; off draws every host in neutral gray (Preferences.showHostColors).
    var enabled = true
    /// Saves the choices; the application sets it.
    @ObservationIgnored var persist: ([String: HostColor]) -> Void = { _ in }

    func choose(_ color: HostColor?, for machine: String) {
        guard choices[machine] != color else { return }
        choices[machine] = color
        persist(choices)
    }
}

extension View {
    func hostTintStrip(_ tint: HostTint?, surface: StripSurface = .solid) -> some View {
        modifier(HostTintStrip(tint: tint, surface: surface))
    }

    func hostTintBorder(_ tint: HostTint?, surfaceID: UUID?, stripHeight: CGFloat) -> some View {
        overlay(alignment: .top) {
            HostBorder(tint: tint, stripHeight: stripHeight)
                .id(surfaceID)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

private struct RemoteTabHighlightKey: EnvironmentKey {
    static let defaultValue = RemoteTabHighlight.border
}

extension EnvironmentValues {
    var remoteTabHighlight: RemoteTabHighlight {
        get { self[RemoteTabHighlightKey.self] }
        set { self[RemoteTabHighlightKey.self] = newValue }
    }
}

/// What a tab strip paints behind itself.
enum StripSurface {
    /// Its own row, on the window color.
    case solid
    /// Over content as Liquid Glass: the glass track is the surface, so the strip paints nothing.
    case none
}

private struct HostTintStrip: ViewModifier {
    let tint: HostTint?
    let surface: StripSurface
    @Environment(\.remoteTabHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if surface == .none {
            content
        } else {
            painted(content)
        }
    }

    private func painted(_ content: Content) -> some View {
        content.background {
            if let tint, highlight == .fade {
                tint.stripWash
                    .overlay(alignment: .bottom) { tint.border.frame(height: 1) }
            } else if Chrome.palette.isDark {
                // Dark content shares the strip's near-black, so a hairline marks where the strip ends.
                Chrome.border.frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        // Its own surface in both themes: in dark, a clear strip read as part of the chat or terminal below.
        // Over content (Liquid Glass) the flat strip frosts what scrolls under it instead.
        .background(Chrome.window)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: tint)
    }
}

private struct HostBorder: View {
    let tint: HostTint?
    let stripHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.remoteTabHighlight) private var highlight
    @State private var displayedTint: HostTint?
    @State private var started: Date?
    @State private var startProgress = 0.0
    @State private var targetProgress = 0.0
    @State private var duration = 1.1

    init(tint: HostTint?, stripHeight: CGFloat) {
        self.tint = tint
        self.stripHeight = stripHeight
        // An already-connected surface is fully drawn when selected. Only
        // connection changes on the same visible surface animate.
        _displayedTint = State(initialValue: tint)
        _startProgress = State(initialValue: tint == nil ? 0 : 1)
        _targetProgress = State(initialValue: tint == nil ? 0 : 1)
    }

    /// Liquid Glass tints the strip instead of an edge; with no strip to tint, the edge marks the host.
    private var washes: Bool { highlight == .fade && stripHeight > 0 }

    private func progress(at date: Date) -> Double {
        guard let started else { return targetProgress }
        let phase = min(1, max(0, date.timeIntervalSince(started) / duration))
        let eased = (1 - cos(phase * .pi)) / 2
        return startProgress + (targetProgress - startProgress) * eased
    }

    var body: some View {
        TimelineView(.animation(paused: started == nil || reduceMotion)) { timeline in
            GeometryReader { geometry in
                if let color = reduceMotion ? tint : displayedTint {
                    let progress = reduceMotion ? (tint == nil ? 0.0 : 1.0) : progress(at: timeline.date)
                    // Fade (Liquid Glass) under a strip: a faint wash fades linearly over 80 pt below it, with no edge.
                    // Otherwise only a solid 2 pt edge.
                    if washes {
                        LinearGradient(colors: [color.fadeWash, color.color.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 80)
                            .offset(y: stripHeight)
                            .opacity(progress)
                    } else {
                        color.edge.frame(width: geometry.size.width * progress, height: 2)
                    }
                    if !washes && started != nil && !reduceMotion {
                        // The thinking-line sweep reveals the border on entry
                        // and follows its retracting edge on return to local.
                        LinearGradient(colors: [.clear, color.foreground.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.3, height: 2)
                            .offset(x: geometry.size.width * (progress * 1.3 - 0.3))
                    }
                }
            }
        }
        .frame(height: washes ? stripHeight + 80 : 2).clipped()
        .task(id: tint) {
            let now = Date()
            // Reversing an unfinished entrance starts from its current width.
            let current = progress(at: now)
            duration = displayedTint?.offline != tint?.offline ? 0.36 : 1.1
            startProgress = tint != nil && tint != displayedTint ? 0 : current
            targetProgress = tint == nil ? 0 : 1
            displayedTint = tint ?? displayedTint
            started = reduceMotion || startProgress == targetProgress ? nil : now
            guard started != nil else { displayedTint = tint; return }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            started = nil
            displayedTint = tint
        }
        .onDisappear {
            started = nil
            startProgress = tint == nil ? 0 : 1
            targetProgress = startProgress
            displayedTint = tint
        }
    }
}
