import CoreGraphics

/// Settings › Line spacing, on the Mac and the iPhone: one choice for the terminal's rows and chat's lines. Normal is
/// the font's own line, so it changes nothing; tight and relaxed scale the line height by the same share in both.
enum LineSpacing: String, CaseIterable, Codable, Identifiable, Sendable {
    case tight, normal, relaxed

    var id: Self { self }

    var title: String { rawValue.capitalized }

    /// The line height against the font's own. Tight stays modest: shorter rows clip glyphs that fill the line.
    var scale: Double {
        switch self {
        case .tight: 0.94
        case .normal: 1
        case .relaxed: 1.18
        }
    }

    /// The terminal's `adjust-cell-height`, nil for the font's own rows (Ghostty's config syntax; box drawing and
    /// powerline glyphs fill the adjusted cell, text stays centred in it).
    var cellHeight: String? {
        self == .normal ? nil : "\(Int(((scale - 1) * 100).rounded()))%"
    }

    /// Chat's space between lines: the platform's usual `normal` spacing, moved by the same share of a line of text at
    /// `size` points (about 1.2 em) as the terminal's rows.
    func chatSpacing(normal: CGFloat, size: CGFloat) -> CGFloat {
        max(0, normal + CGFloat(scale - 1) * 1.2 * size)
    }
}
