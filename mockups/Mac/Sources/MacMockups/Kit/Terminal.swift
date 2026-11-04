import SwiftUI

// A terminal's screen: Source Code Pro 14 (the default font, the scale's reference) on the scheme's background, 10
// points in and 8 below the strip (Ghostty's window padding), lines 17.7 points apart as the app's capture shows.

/// A run of text in one style. `color` is an ANSI index (0–15) in the theme's terminal scheme; nil the foreground.
struct TermSpan {
    var text: String
    var color: Int?
    var bold = false
    var dim = false
    /// Drawn as a selection or a reverse-video cell.
    var inverse = false
}

struct TermLine: ExpressibleByStringLiteral {
    var spans: [TermSpan]
    init(_ spans: [TermSpan]) { self.spans = spans }
    init(stringLiteral value: String) { spans = [TermSpan(text: value)] }

    /// A zsh prompt as the fictional user's: `alex@mba2 app %` then the command.
    static func prompt(_ command: String = "", user: String = "alex", host: String = "mba2", folder: String = "app") -> TermLine {
        TermLine([TermSpan(text: "\(user)@\(host) \(folder) % "), TermSpan(text: command)])
    }
}

/// Builds a line from styled runs: `T("On branch ", c(2, "main"))`.
func T(_ parts: TermSpan...) -> TermLine { TermLine(parts) }
func c(_ color: Int?, _ text: String, bold: Bool = false, dim: Bool = false) -> TermSpan {
    TermSpan(text: text, color: color, bold: bold, dim: dim)
}
extension TermSpan: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self.init(text: value) }
}

struct TerminalScreen: View {
    var lines: [TermLine]
    /// The cursor after the last line's text: a bar, as the app's terminal draws it focused.
    var cursor = true
    var blockCursor = false
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 17.7
    var body: some View {
        let scheme = TerminalScheme.current
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 0) {
                    ForEach(Array(line.spans.enumerated()), id: \.offset) { _, span in
                        let color = span.color.map { scheme.palette[$0] } ?? scheme.foreground
                        Text(span.text)
                            .font(.custom(span.bold ? "SourceCodePro-Semibold" : "SourceCodePro-Regular", size: fontSize))
                            .foregroundStyle(span.inverse ? scheme.background : color.opacity(span.dim ? 0.6 : 1))
                            .background(span.inverse ? color : .clear)
                    }
                    if cursor && index == lines.count - 1 {
                        Rectangle().fill(scheme.foreground).frame(width: blockCursor ? fontSize * 0.6 : 1.5, height: lineHeight - 2).padding(.leading, blockCursor ? 0 : 1)
                    }
                }
                .frame(height: lineHeight, alignment: .leading)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme.background)
        .clipped()
    }
}
