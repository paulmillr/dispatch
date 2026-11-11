import SwiftUI
import UIKit

/// Settings' Colorblind-friendly as a UIKit trait (the window's, set by `mobileAppearance()`),
/// bridged to SwiftUI's environment, so the change colours (`UIColor.change`) resolve per view in UIKit and SwiftUI.
struct ColorVisionTrait: UITraitDefinition {
    static let defaultValue = ColorVision.typical
    static let affectsColorAppearance = true
    static let name = "DispatchColorVision"
    static let identifier = "yachts.dispatch.mobile.colorVision"
}

struct ColorVisionKey: EnvironmentKey {
    static let defaultValue = ColorVision.typical
}

extension ColorVisionKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> ColorVision { traitCollection[ColorVisionTrait.self] }
    static func write(to mutableTraits: inout UIMutableTraits, value: ColorVision) { mutableTraits[ColorVisionTrait.self] = value }
}

extension EnvironmentValues {
    var colorVision: ColorVision {
        get { self[ColorVisionKey.self] }
        set { self[ColorVisionKey.self] = newValue }
    }
}

extension ColorVision {
    /// Added and removed for this vision on each side: the green and red (palette 2 and 1) of its first bundled light
    /// and dark schemes, which those schemes keep apart (GitHub Colorblind's blue and orange); nil for typical vision.
    struct Changes: @unchecked Sendable {
        let light: (added: UIColor, removed: UIColor)
        let dark: (added: UIColor, removed: UIColor)
    }

    var changes: Changes? { Self.changes[self] }

    private static let changes: [ColorVision: Changes] = bundledSchemes.compactMapValues { schemes in
        func pair(_ file: String?) -> (added: UIColor, removed: UIColor)? {
            guard let file, let url = TerminalSchemes.url(file), let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let accents = TerminalSchemes.parse(text, file: file).accents
            guard accents.count > 1 else { return nil }
            let color = { (c: TerminalSchemes.RGB) in UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1) }
            return (color(accents[1]), color(accents[0]))
        }
        guard let light = pair(schemes.light.first), let dark = pair(schemes.dark.first) else { return nil }
        return Changes(light: light, dark: dark)
    }
}

extension UIColor {
    /// An added or removed colour (diffs, +/− counts, git's A and D): the catalog's green or red, or in colorblind mode
    /// that vision's (`ColorVision.changes`), for the side the traits draw.
    static func change(_ name: String, added: Bool) -> UIColor {
        let catalog = UIColor.dispatch(name)
        return UIColor { traits in
            guard let changes = traits[ColorVisionTrait.self].changes else { return catalog.resolvedColor(with: traits) }
            let side = traits.userInterfaceStyle == .dark ? changes.dark : changes.light
            return added ? side.added : side.removed
        }
    }
}
