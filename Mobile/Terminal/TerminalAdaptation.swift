import CoreGraphics
import UIKit

/// What the terminal adapts to on an iPad, as pure rules so tests check every device class and keyboard on any
/// simulator: the default font size, the key capsule's form with and without a hardware keyboard, its width, and
/// where the software keyboard is (docked, floating or split, or only the shortcut bar a hardware keyboard leaves).
enum TerminalAdaptation {
    /// The Mac's default is 14 points (`Preferences.fontSize`) at a laptop's distance; an iPad on a stand or a
    /// Magic Keyboard sits at about that distance, and 14.5 reads the same (13 matched the Mac's earlier 12.5). The
    /// phone keeps its 12 (held closer, every M6a screenshot is at 12, and each point costs four of its ~51 columns).
    /// A pinch or Settings replaces either; the choice is kept per device (`TerminalController.fontSizeKey`), which is
    /// one device class.
    static let padFontSize = 14.5

    static func defaultFontSize(idiom: UIUserInterfaceIdiom) -> Double {
        idiom == .pad ? padFontSize : TerminalConfiguration.defaultFontSize
    }

    // MARK: Dynamic Type

    /// The text size whose factor is the largest the terminal takes: the accessibility sizes enlarge body text up to
    /// 3.1 times, which would leave a phone's terminal a dozen columns. A pinch still goes past it.
    static let largestScaledCategory = UIContentSizeCategory.extraExtraExtraLarge

    /// How much the system text size enlarges body text (`UIFontMetrics`): 1 at the standard Large, about 1.32 at XXXL
    /// and above, below 1 at the smaller sizes.
    static func textScale(_ category: UIContentSizeCategory) -> Double {
        let category = category == .unspecified ? .large : min(category, largestScaledCategory)
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        return Double(UIFontMetrics(forTextStyle: .body).scaledValue(for: 1000, compatibleWith: traits)) / 1000
    }

    /// The size a terminal draws `base` at, `base` being the size at the standard text size (what Settings shows and
    /// `TerminalController.fontSizeKey` keeps), within the terminal's sizes.
    static func fontSize(base: Double, category: UIContentSizeCategory) -> Double {
        let size = (base * textScale(category) * 100).rounded() / 100
        return min(max(size, TerminalConfiguration.fontSizes.lowerBound), TerminalConfiguration.fontSizes.upperBound)
    }

    /// The size at the standard text size that draws at `size` (a pinch's), kept so the choice follows a later change
    /// of text size.
    static func baseSize(drawn size: Double, category: UIContentSizeCategory) -> Double {
        (size / textScale(category) * 100).rounded() / 100
    }

    /// The text size the user chose in iOS's Settings.
    @MainActor static var category: UIContentSizeCategory { UIApplication.shared.preferredContentSizeCategory }

    /// The key capsule: the phone's six keys (`full`), or on an iPad with a hardware keyboard a small button that
    /// brings them back (`collapsed`): the keyboard has Esc, Tab, Ctrl, Option and arrows of its own (one without Esc
    /// still has Ctrl-[), and the rows the capsule took go back to the terminal.
    enum CapsuleForm: Equatable, Sendable { case full, collapsed }

    /// `shown`: the user brought the keys back while a hardware keyboard was attached (remembered). The phone keeps
    /// the full capsule whatever is attached: its M6a layout stays, and the simulator forwards the Mac's keyboard to
    /// every iPhone run.
    static func capsuleForm(idiom: UIUserInterfaceIdiom, hardwareKeyboard: Bool, shown: Bool) -> CapsuleForm {
        idiom == .pad && hardwareKeyboard && !shown ? .collapsed : .full
    }

    /// The capsule's widest on an iPad: six keys of a phone's width (66 points each), centred, rather than keys a
    /// sixth of a 1,000-point column wide. The phone's capsule spans its width (at most 420 points) as before.
    static let padCapsuleWidth = 6 * 66.0 + 8

    static func capsuleMaxWidth(idiom: UIUserInterfaceIdiom) -> CGFloat {
        idiom == .pad ? padCapsuleWidth : .infinity
    }

    /// Where the software keyboard is, from its frame in the window's coordinates.
    enum Keyboard: Equatable, Sendable {
        /// Off screen, or only the shortcut bar a hardware keyboard leaves (no keys to type with).
        case hidden
        /// Docked along the window's bottom: the capsule rides on it.
        case docked
        /// Floating, undocked or split: it sits over the content and the capsule stays at the bottom.
        case floating
    }

    /// The shortest frame that is a keyboard with keys: the shortcut bar alone is 55 to 75 points tall.
    static let keysHeight = 120.0

    static func keyboard(frame: CGRect?, window: CGRect) -> Keyboard {
        guard let frame, !frame.isNull, !frame.isEmpty else { return .hidden }
        let shown = frame.intersection(window)
        guard !shown.isNull, shown.height > 1 else { return .hidden }
        guard shown.height >= keysHeight else { return .hidden }
        // A floating keyboard ends above the window's bottom (a split one too, full width); a docked one reaches it.
        return frame.maxY < window.maxY - 1 ? .floating : .docked
    }
}
