import SwiftUI

// An iPhone on its side (874 × 402 points on an iPhone 18 Pro, 956 × 440 on a Pro Max): the pieces the one-rail
// screens (FullHeight.swift, L12–L15) draw. Shot on an iPhone simulator turned by `shoot.py rotate landscape`.

/// A terminal at landscape's width: rows of a test run, coloured as the shell prints them.
struct WideTerminal: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(color(line))
                    .lineLimit(1)
                    .frame(height: 20)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
    private func color(_ line: String) -> Color {
        if line.hasPrefix("~") { return .added }
        if line.contains("✗") || line.contains("AssertionError") || line.contains("failed") { return .destructive }
        if line.contains("✓") { return .added.opacity(0.85) }
        if line.contains("❯") { return .secondary }
        return .primary
    }
}

/// A software keyboard as the system draws it on its side, for scale (the simulator shows none over a mockup).
struct LandscapeKeyboard: View {
    private let rows: [[String]] = [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                                    ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
                                    ["⇧", "z", "x", "c", "v", "b", "n", "m", "⌫"]]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 6) {
                    if r == 1 { Spacer().frame(width: 22) }
                    ForEach(row, id: \.self) { key in
                        Text(key).font(.system(size: 20))
                            .frame(maxWidth: key == "⇧" || key == "⌫" ? 70 : .infinity).frame(height: 36)
                            .background(Color.white.opacity(key == "⇧" || key == "⌫" ? 0.12 : 0.28), in: RoundedRectangle(cornerRadius: 7))
                    }
                    if r == 1 { Spacer().frame(width: 22) }
                }
            }
            HStack(spacing: 6) {
                Text("123").font(.system(size: 16)).frame(width: 90, height: 36).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Image(systemName: "face.smiling").frame(width: 60, height: 36).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Text("space").font(.system(size: 16)).frame(maxWidth: .infinity).frame(height: 36).background(Color.white.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
                Text("return").font(.system(size: 16)).frame(width: 120, height: 36).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 70).padding(.top, 8).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.17))
    }
}
