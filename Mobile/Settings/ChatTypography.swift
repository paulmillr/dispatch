import SwiftUI
import UIKit

/// Chat's font (Settings, Chat, Font, G3): the Mac's choices (`ChatFont`, the same names). iOS has no Comic Sans:
/// Chalkboard SE, its system font in that hand, stands in. Latin Modern is bundled (`TermFonts`).
enum MobileChatFont: String, CaseIterable, Identifiable, Sendable {
    case system = "San Francisco"
    case sameAsCode = "Same as code"
    case comicSans = "Comic Sans"
    case latinModernRoman = "Latin Modern Roman"
    case newYork = "New York"
    case sfRounded = "SF Rounded"

    var id: Self { self }

    /// The system font's own designs (San Francisco, New York, SF Rounded); nil for fonts drawn by name.
    var systemDesign: Font.Design? {
        switch self {
        case .system: .default
        case .newYork: .serif
        case .sfRounded: .rounded
        case .sameAsCode, .comicSans, .latinModernRoman: nil
        }
    }

    /// The sample bubble's text in G3; Same as code names the terminal's font and the chat's size.
    func sample(terminalFont: String, size: Int) -> String {
        switch self {
        case .system: "The system font, as Messages."
        case .sameAsCode: "\(terminalFont) \(size), as the terminal."
        case .comicSans: "For the brave."
        case .latinModernRoman: "As set in TeX, Knuth's Computer Modern."
        case .newYork: "Apple's serif, as Books."
        case .sfRounded: "The system font, rounded."
        }
    }

    /// Latin Modern's small lowercase drawn at the Mac's calibrated size (`ChatFont.sizeScale`).
    var sizeScale: CGFloat {
        switch self {
        case .latinModernRoman: 1.126
        case .system, .sameAsCode, .comicSans, .newYork, .sfRounded: 1
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
    var terminalFont = TerminalFont.sourceCodePro
    /// Settings' line spacing, shared with the terminal.
    var lineSpacing = LineSpacing.normal

    init(font: MobileChatFont = .system, size: ChatTextSize = .standard, terminalFont: TerminalFont = .sourceCodePro,
         lineSpacing: LineSpacing = .normal) {
        (self.font, self.size, self.terminalFont, self.lineSpacing) = (font, size, terminalFont, lineSpacing)
    }

    init(_ defaults: UserDefaults) {
        font = defaults.string(forKey: MobileSettings.chatFontKey).flatMap(MobileChatFont.init(rawValue:)) ?? .system
        size = defaults.string(forKey: MobileSettings.chatTextSizeKey).flatMap(ChatTextSize.init(rawValue:)) ?? .standard
        terminalFont = TerminalFont.named(defaults.string(forKey: MobileSettings.terminalFontKey))
        lineSpacing = defaults.string(forKey: MobileSettings.lineSpacingKey).flatMap(LineSpacing.init(rawValue:)) ?? .normal
    }

    /// Between the bubbles' lines: 2 points at Normal, moved with the line spacing.
    var bodySpacing: CGFloat { lineSpacing.chatSpacing(normal: 2, size: size.points) }

    /// The family a font choice draws in: nil for the system font's designs.
    func family(_ choice: MobileChatFont) -> String? {
        switch choice {
        case .system, .newYork, .sfRounded: nil
        case .sameAsCode: terminalFont.name
        case .comicSans: "Chalkboard SE"
        // By PostScript name, as the Mac draws it.
        case .latinModernRoman: "LMRoman10-Regular"
        }
    }

    /// The bubbles' text: the chosen font at the chosen style, scaling with Dynamic Type.
    var body: Font { drawn(font) }

    func drawn(_ choice: MobileChatFont) -> Font {
        guard let family = family(choice) else { return .system(size.style, design: choice.systemDesign ?? .default) }
        MobileFonts.register()
        return .custom(family, size: size.points * choice.sizeScale, relativeTo: size.style)
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
