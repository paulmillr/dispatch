import CoreGraphics
import UIKit

/// What the terminal adapts to on an iPad, as pure rules so tests check every device class and keyboard on any
/// simulator: the default font size, the key capsule's form with and without a hardware keyboard, its width, and
/// where the software keyboard is (docked, floating or split, or only the shortcut bar a hardware keyboard leaves).
enum TerminalAdaptation {
    /// The Mac's default is 12.5 points (`Preferences.fontSize`) at a laptop's distance; an iPad on a stand or a
    /// Magic Keyboard sits at about that distance with points some 15 % smaller than a MacBook's, so 13 reads the
    /// same. The phone keeps its 12 (held closer, and every M6a screenshot is at 12). A pinch or Settings replaces
    /// either; the choice is kept per device (`TerminalController.fontSizeKey`), which is one device class.
    static let padFontSize = 13.0

    static func defaultFontSize(idiom: UIUserInterfaceIdiom) -> Double {
        idiom == .pad ? padFontSize : TerminalConfiguration.defaultFontSize
    }

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
