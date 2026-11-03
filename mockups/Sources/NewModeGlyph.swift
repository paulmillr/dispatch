import SwiftUI

// N: new glyphs for the mode button's Chat (2026-11-02), none of them `text.bubble`. Drawn on a 24 point grid: off, a
// 1.8 point outline in primary; on, the same shape filled in pink, no knockouts.

enum NewModeGlyph: CaseIterable {
    /// N1: a capsule with a short tail, softer than the square bubble.
    case pill
    /// N2: the thread itself: one message left, one reply right.
    case thread
    /// N3: the typing indicator's three dots.
    case typing
    /// N4: a four-point spark with a small one beside it: the agent, not the bubble.
    case spark
    /// N5: a pair of opening quote marks: someone speaking.
    case quote

    var title: String {
        switch self {
        case .pill: "N1 · Pill: a capsule with a tail"
        case .thread: "N2 · Thread: message left, reply right"
        case .typing: "N3 · Typing: three dots"
        case .spark: "N4 · Spark: the agent"
        case .quote: "N5 · Quote: opening marks"
        }
    }

    var id: String {
        switch self {
        case .pill: "N1-new-glyph-pill"
        case .thread: "N2-new-glyph-thread"
        case .typing: "N3-new-glyph-typing"
        case .spark: "N4-new-glyph-spark"
        case .quote: "N5-new-glyph-quote"
        }
    }

    /// The shape on the 24 point grid, every subpath closed so it fills and strokes alike.
    var path: Path {
        switch self {
        case .pill:
            let body = Path(roundedRect: CGRect(x: 2.5, y: 4.5, width: 19, height: 12.5), cornerRadius: 6.25)
            var tail = Path()
            tail.move(to: CGPoint(x: 6.5, y: 15))
            tail.addLine(to: CGPoint(x: 5, y: 20.5))
            tail.addLine(to: CGPoint(x: 11, y: 16.5))
            tail.closeSubpath()
            return body.union(tail)
        case .thread:
            var path = Path()
            path.addRoundedRect(in: CGRect(x: 2.5, y: 3.5, width: 13, height: 7), cornerSize: CGSize(width: 3.5, height: 3.5))
            path.addRoundedRect(in: CGRect(x: 8.5, y: 13.5, width: 13, height: 7), cornerSize: CGSize(width: 3.5, height: 3.5))
            return path
        case .typing:
            var path = Path()
            for x in [4.5, 12, 19.5] { path.addEllipse(in: CGRect(x: x - 3, y: 12 - 3, width: 6, height: 6)) }
            return path
        case .spark:
            var path = Path()
            Self.star(&path, center: CGPoint(x: 10.5, y: 13.5), radius: 8.5)
            Self.star(&path, center: CGPoint(x: 19, y: 5), radius: 3.2)
            return path
        case .quote:
            var path = Path()
            for x in [7.0, 17.0] {
                let ball = Path(ellipseIn: CGRect(x: x - 3.6, y: 11.4, width: 7.2, height: 7.2))
                // The 6 of an opening mark: the stroke rises from the ball's left and leans right at the top.
                var tail = Path()
                tail.move(to: CGPoint(x: x - 3.6, y: 15))
                tail.addQuadCurve(to: CGPoint(x: x + 2.4, y: 4.5), control: CGPoint(x: x - 4, y: 7))
                tail.addQuadCurve(to: CGPoint(x: x + 0.6, y: 11.5), control: CGPoint(x: x - 0.6, y: 7.8))
                tail.closeSubpath()
                path.addPath(ball.union(tail))
            }
            return path
        }
    }

    /// A four-point star with concave sides.
    private static func star(_ path: inout Path, center c: CGPoint, radius r: CGFloat) {
        let k = r * 0.16
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        path.closeSubpath()
    }
}

/// A new glyph, filled pink when lit, else outlined in primary.
struct NewModeGlyphView: View {
    let glyph: NewModeGlyph
    let lit: Bool
    var size: CGFloat = 25
    /// The outline's colour.
    var tint: Color = .primary

    var body: some View {
        Canvas { context, canvas in
            let scale = min(canvas.width, canvas.height) / 24
            let shape = glyph.path.applying(CGAffineTransform(scaleX: scale, y: scale))
            if lit {
                context.fill(shape, with: .color(.dispatchPink))
            } else {
                context.stroke(shape, with: .foreground, style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
    }
}

/// N0: the five, on over off in the header, the pair at the right enlarged.
struct NewModeGlyphCompareScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(NewModeGlyph.allCases, id: \.self) { glyph in
                    HStack {
                        Text(glyph.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        HStack(spacing: 22) {
                            NewModeGlyphView(glyph: glyph, lit: true, size: 30)
                            NewModeGlyphView(glyph: glyph, lit: false, size: 30)
                        }
                    }
                    .frame(height: 40)
                    .padding(.top, 6).padding(.horizontal, 20)
                    ForEach([true, false], id: \.self) { lit in
                        NavigationStack {
                            Color.canvas
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar { ModeGlyphHeader(lit: lit, glyph: AnyView(NewModeGlyphView(glyph: glyph, lit: lit))) }
                        }
                        .frame(height: 52)
                    }
                }
            }
        }
        .background(Color.canvas)
    }
}

/// N1–N5: the chat with the glyph lit.
struct NewModeGlyphChatScreen: View {
    let glyph: NewModeGlyph
    var body: some View {
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeGlyphHeader(lit: true, glyph: AnyView(NewModeGlyphView(glyph: glyph, lit: true))) }
        }
    }
}

/// N7: N1 as the asset catalog's symbol (`dispatch.chat`, `.fill`) beside the system's, at the sizes and weights the app
/// draws them, and in a list's labels.
struct ChatSymbolCheckScreen: View {
    private let sizes: [(CGFloat, Font.Weight)] = [(13, .semibold), (15, .medium), (17, .regular), (18, .regular), (22, .regular), (36, .light)]
    var body: some View {
        List {
            Section("Size · weight: text.bubble, dispatch.chat, .fill, apple.terminal") {
                ForEach(Array(sizes.enumerated()), id: \.offset) { _, size in
                    HStack(spacing: 18) {
                        Text("\(Int(size.0)) pt").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        Image(systemName: "text.bubble")
                        Image("dispatch.chat")
                        Image("dispatch.chat.fill").foregroundStyle(Color.dispatchPink)
                        Image(systemName: "apple.terminal")
                        Text("Chat")
                    }
                    .font(.system(size: size.0, weight: size.1))
                }
            }
            Section("Scales: small, medium, large") {
                HStack(spacing: 18) {
                    Image("dispatch.chat").imageScale(.small)
                    Image("dispatch.chat").imageScale(.medium)
                    Image("dispatch.chat").imageScale(.large)
                    Image(systemName: "text.bubble").imageScale(.large)
                    Label("Chat", image: "dispatch.chat")
                }
            }
            Section("Labels") {
                Label { Text("Terminal") } icon: { Image(systemName: "apple.terminal") }
                Label { Text("Chat") } icon: { Image("dispatch.chat") }
                Label { Text("Files") } icon: { Image(systemName: "folder") }
            }
        }
    }
}
