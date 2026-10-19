import SwiftUI
import UIKit

/// The iPhone app's named colours (Assets.xcassets), as the mockup fixes them: dark (M-screens) and light (L1a, L2a).
/// Every colour a view draws comes from here or from the system's semantic colours (labels, fills, separators); no
/// view spells out a dark-only value. `MobileColorTests` checks the pairs the mockup states (contrast) in both schemes.
extension Color {
    /// The desktop pink: the app tint, the approval chips, the call to action. The same in light and dark.
    static let dispatchPink = Color("AccentColor")
    /// The gutter dots, the same in light and dark: blue unread (as Mail), amber working.
    static let stateUnread = Color("StateUnread")
    static let stateWorking = Color("StateWorking")
    /// The green status dot of a connected host (M1f).
    static let stateConnected = Color("StateFinished")
    /// Chat bubbles: a deeper pink with white text in light (L2a), the desktop pink with dark text in dark (M4a);
    /// the agent's in the Messages grey with the primary label.
    static let bubbleUser = Color("BubbleUser")
    static let bubbleUserText = Color("BubbleUserText")
    static let bubbleAgent = Color("BubbleAgent")

    /// The screens' background: the system grouped grey #F2F2F7 in light (L1a), black in dark.
    static let canvas = Color("Canvas")
    /// Inset grouped cards and their rows (M2b, M4d, M5b, the queue): white in light, #1C1C1E in dark.
    static let groupedRow = Color("GroupedRow")
    /// The cards of sheets and pushed details (M5b's steps and facts, M9a's pickers): white in light, #2C2C2E in dark.
    static let raisedRow = Color("RaisedRow")
    /// Hairlines between rows and around cards.
    static let hairline = Color("Hairline")
    /// The thinking row's top edge (M5a), under the accent scan.
    static let thinkingBorder = Color("ThinkingBorder")
    /// The approval's mono command block (M4b): a slightly darker grey than the agent's bubble.
    static let approvalCode = Color("ApprovalCode")
    /// Text on the pink (Allow, the call to action, the send arrow): dark in both schemes.
    static let onAccent = Color("OnAccent")
    /// The faint disc and note backgrounds (M1d's disc, thread notes).
    static let faintFill = Color("FaintFill")
    /// Grey chips and round buttons (approval chips, the disclosure button) and their edge.
    static let chipFill = Color("ChipFill")
    static let chipBorder = Color("ChipBorder")
    /// The amber of text (M4c's banner, the tmux version warning): the state amber in dark, a darker amber that reads
    /// on the light canvas.
    static let caution = Color("Caution")
    /// Close space, failed steps, removed lines.
    static let destructive = Color("Destructive")
    /// Added lines and patch steps.
    static let added = Color("Added")
    /// The thinking word's shimmer: its grey and the sweeping light.
    static let shimmerBase = Color("ShimmerBase")
    static let shimmerHighlight = Color("ShimmerHighlight")
    /// The glass lens on a selected segment (M2a's tree toggle), and on the pink while a filter tints the capsule.
    static let lens = Color("Lens")
    static let lensOnTint = Color("LensOnTint")
    /// The arrow cluster's keys (M6a), always over the dark terminal.
    static let terminalKey = Color("TerminalKey")
}

extension UIColor {
    /// A catalog colour for UIKit and TextKit (`CodePalette`), resolved per trait collection when drawn.
    static func dispatch(_ name: String) -> UIColor {
        UIColor(named: name, in: .main, compatibleWith: nil) ?? .label
    }

    /// `self` at `alpha` in every appearance (`withAlphaComponent` of a dynamic colour, kept dynamic).
    func dynamic(alpha: CGFloat) -> UIColor {
        UIColor { traits in self.resolvedColor(with: traits).withAlphaComponent(alpha) }
    }
}
