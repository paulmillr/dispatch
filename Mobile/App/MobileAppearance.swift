import SwiftUI
import UIKit

/// The app's appearance: what Settings writes to `UserDefaults.standard` under `appearance` (`system`, `dark`,
/// `light`; dark by default, as the mockup draws the app). The root applies it live (`mobileAppearance()`); every colour
/// follows from the scheme (`MobileColors`, the asset catalog's light and dark variants).
enum MobileAppearance: String, CaseIterable, Sendable {
    case system, dark, light

    static let key = "appearance"
    static let fallback = MobileAppearance.dark

    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? Self.fallback
    }

    /// The scheme the root asks for; nil follows the system.
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .dark: .dark; case .light: .light }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self { case .system: .unspecified; case .dark: .dark; case .light: .light }
    }
}

extension View {
    /// The root's appearance from the `appearance` default, updated the moment it changes.
    func mobileAppearance(defaults: UserDefaults = .standard) -> some View {
        modifier(MobileAppearanceModifier(defaults: defaults))
    }
}

private struct MobileAppearanceModifier: ViewModifier {
    @AppStorage private var stored: String

    init(defaults: UserDefaults) {
        _stored = AppStorage(wrappedValue: MobileAppearance.fallback.rawValue, MobileAppearance.key, store: defaults)
    }

    func body(content: Content) -> some View {
        let appearance = MobileAppearance(stored: stored)
        content
            .preferredColorScheme(appearance.colorScheme)
            // The window too: going back to System must clear the override `preferredColorScheme` left on it, and UIKit
            // presentations (alerts, menus, the share sheet) read the window's style.
            .background(MobileWindowStyle(style: appearance.interfaceStyle).allowsHitTesting(false).accessibilityHidden(true))
    }
}

/// Sets the hosting window's `overrideUserInterfaceStyle`.
private struct MobileWindowStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    final class Probe: UIView {
        var style: UIUserInterfaceStyle = .unspecified { didSet { apply() } }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }
        func apply() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.style = style
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) { probe.style = style }
}

/// A system font of `size` points at the default content size that scales with Dynamic Type as `style` does: for the
/// mockup's sizes that are no text style (14, 13.5, 24 points). Sizes that are a text style use it directly.
struct ScaledSystemFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design, relativeTo: style))
    }
}

extension EnvironmentValues {
    /// Forces Reduce Motion on or off below this point (tests and previews); nil follows the system setting.
    @Entry var reduceMotionOverride: Bool? = nil
    /// The moment the looping animations draw (tests render chosen instants instead of sampling the clock); nil: now.
    @Entry var animationDateOverride: Date? = nil
}

/// Reduce Motion as the views read it: the system setting unless `reduceMotionOverride` says otherwise.
@propertyWrapper
struct ReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system
    @Environment(\.reduceMotionOverride) private var override
    var wrappedValue: Bool { override ?? system }
}

extension DynamicTypeSize {
    /// `value` scaled for this size as `style` scales (for metrics capped below the environment's size).
    func scaled(_ value: CGFloat, relativeTo style: UIFont.TextStyle) -> CGFloat {
        UIFontMetrics(forTextStyle: style)
            .scaledValue(for: value, compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(self)))
    }
}

extension View {
    /// The glass key capsule of the terminal (M6a) and of the composer's key row (M5e): keys flush in one interactive
    /// glass capsule. Its labels grow with the text up to the first accessibility size; beyond, a long press shows the
    /// large content viewer.
    func keyCapsule(height: CGFloat) -> some View {
        padding(.horizontal, 4)
            .frame(height: height)
            .glassEffect(.regular.interactive(), in: .capsule)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .accessibilityShowsLargeContentViewer()
    }

    /// Text that wraps onto as many lines as it needs (paths, short labels) and takes its width first in a row: never
    /// cut off at the larger text sizes. At the default size these are one line.
    func fittingLine(_ lines: Int? = nil) -> some View {
        lineLimit(lines).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
    }
}

/// The keys of a key capsule: no pressed shading beyond the glass's own, so they sit flush in it.
struct KeyCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}
