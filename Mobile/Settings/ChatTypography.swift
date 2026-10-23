import SwiftUI
import UIKit

/// Chat's font (Settings, Chat, Font, G3): the Mac's three choices (`ChatFont`, the same names). iOS has no Comic Sans:
/// Chalkboard SE, its system font in that hand, stands in.
enum MobileChatFont: String, CaseIterable, Identifiable, Sendable {
    case system = "San Francisco"
    case sameAsCode = "Same as code"
    case comicSans = "Comic Sans"

    var id: Self { self }

    /// The sample bubble's text in G3; Same as code names the terminal's font and the chat's size.
    func sample(terminalFont: String, size: Int) -> String {
        switch self {
        case .system: "The system font, as Messages."
        case .sameAsCode: "\(terminalFont) \(size), as the terminal."
        case .comicSans: "For the brave."
        }
    }
}

/// Chat's text size relative to Dynamic Type (G3): one text style smaller or larger than the bubbles' callout.
enum ChatTextSize: String, CaseIterable, Identifiable, Sendable {
    case smaller, standard, larger

    var id: Self { self }

    var title: String {
        switch self { case .smaller: "Smaller"; case .standard: "Default"; case .larger: "Larger" }
    }

    /// The bubble's text style: subheadline (15), callout (16) or body (17 points at the default size).
    var style: Font.TextStyle {
        switch self { case .smaller: .subheadline; case .standard: .callout; case .larger: .body }
    }

    var uiStyle: UIFont.TextStyle {
        switch self { case .smaller: .subheadline; case .standard: .callout; case .larger: .body }
    }

    /// The style's size at the default Dynamic Type size (15, 16, 17).
    var points: CGFloat {
        UIFont.preferredFont(forTextStyle: uiStyle, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
    }
}

/// How chat draws its text: the font and size Settings chose, and the terminal's font for code blocks and paths.
/// The root sets it from the defaults (`mobileAppearance()`); bubbles (`ChatBubble`) and markdown code blocks read it.
struct ChatTypography: Equatable, Sendable {
    var font = MobileChatFont.system
    var size = ChatTextSize.standard
    var terminalFont = TerminalFont.jetBrainsMono

    init(font: MobileChatFont = .system, size: ChatTextSize = .standard, terminalFont: TerminalFont = .jetBrainsMono) {
        (self.font, self.size, self.terminalFont) = (font, size, terminalFont)
    }

    init(_ defaults: UserDefaults) {
        font = defaults.string(forKey: MobileSettings.chatFontKey).flatMap(MobileChatFont.init(rawValue:)) ?? .system
        size = defaults.string(forKey: MobileSettings.chatTextSizeKey).flatMap(ChatTextSize.init(rawValue:)) ?? .standard
        terminalFont = TerminalFont.named(defaults.string(forKey: MobileSettings.terminalFontKey))
    }

    /// The family a font choice draws in: nil for the system font.
    func family(_ choice: MobileChatFont) -> String? {
        switch choice {
        case .system: nil
        case .sameAsCode: terminalFont.name
        case .comicSans: "Chalkboard SE"
        }
    }

    /// The bubbles' text: the chosen font at the chosen style, scaling with Dynamic Type.
    var body: Font { drawn(font) }

    func drawn(_ choice: MobileChatFont) -> Font {
        guard let family = family(choice) else { return .system(size.style) }
        MobileFonts.register()
        return .custom(family, size: size.points, relativeTo: size.style)
    }

    /// Code blocks: the terminal's font three points under the chat text (13 at Default, a footnote), scaling with the
    /// chosen size and Dynamic Type.
    var code: Font {
        MobileFonts.register()
        return .custom(terminalFont.name, size: size.points - 3, relativeTo: size.style)
    }

    /// Inline code and paths in running text: the terminal's font a little under the chat text, as monospaced text
    /// sets larger.
    var inlineCode: Font {
        MobileFonts.register()
        return .custom(terminalFont.name, size: (size.points * 0.94).rounded(), relativeTo: size.style)
    }
}

extension EnvironmentValues {
    @Entry var chatTypography = ChatTypography()
}
