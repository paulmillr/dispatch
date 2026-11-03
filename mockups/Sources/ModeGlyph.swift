import SwiftUI

// Z: the mode button's lit glyph (2026-11-02). Today Chat shown draws `text.bubble.fill` in the tint: a solid pink
// blob with the lines knocked out. Four other ways to say "on", each beside its unlit form (an agent's tab in Terminal).

enum ModeGlyphIdea: CaseIterable {
    /// The app today: `text.bubble.fill` in pink; off, `text.bubble` in primary.
    case today
    /// Z1: the outline stays, pink, over a faint pink body: a tint, not a blob.
    case softFill
    /// Z2: the outline in pink on a small pink platter inside the bar's glass (the system's selected-item look).
    case platter
    /// Z3: the bubble without lines: `bubble.left.fill` / `bubble.left`, a clean solid shape.
    case plainBubble
    /// Z4: the glyph never changes; a pink dot under it says the mode is on.
    case dot

    var title: String {
        switch self {
        case .today: "Today · text.bubble.fill"
        case .softFill: "Z1 · Soft fill: pink outline, 25 % body"
        case .platter: "Z2 · Platter: pink outline, tinted disc"
        case .plainBubble: "Z3 · Plain bubble: bubble.left.fill"
        case .dot: "Z4 · Dot: pink dot under the outline"
        }
    }
}

/// The glyph of an idea, lit (Chat shown) or not (an agent's tab in Terminal).
struct ModeGlyph: View {
    let idea: ModeGlyphIdea
    let lit: Bool
    var size: CGFloat = 17

    var body: some View {
        switch idea {
        case .today:
            Image(systemName: lit ? "text.bubble.fill" : "text.bubble")
                .font(.system(size: size))
                .foregroundStyle(lit ? Color.dispatchPink : Color.primary)
        case .softFill:
            ZStack {
                if lit {
                    Image(systemName: "bubble.left.fill").foregroundStyle(Color.dispatchPink.opacity(0.25))
                }
                Image(systemName: "text.bubble").foregroundStyle(lit ? Color.dispatchPink : Color.primary)
            }
            .font(.system(size: size))
        case .platter:
            Image(systemName: "text.bubble")
                .font(.system(size: size))
                .foregroundStyle(lit ? Color.dispatchPink : Color.primary)
                // Outside the layout, so the bar keeps the item's width.
                .background { Circle().fill(lit ? Color.dispatchPink.opacity(0.2) : .clear).padding(-size * 0.45) }
        case .plainBubble:
            Image(systemName: lit ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: size))
                .foregroundStyle(lit ? Color.dispatchPink : Color.primary)
        case .dot:
            VStack(spacing: size * 0.15) {
                Image(systemName: "text.bubble")
                    .font(.system(size: size))
                    .foregroundStyle(Color.primary)
                Circle().fill(Color.dispatchPink).frame(width: size * 0.28, height: size * 0.28)
                    .opacity(lit ? 1 : 0)
            }
            .padding(.top, size * 0.43)
        }
    }
}

/// The phone's chat header with the mode button and the host sharing one glass capsule, as the app draws it.
struct ModeGlyphHeader: ToolbarContent {
    var idea: ModeGlyphIdea = .today
    let lit: Bool
    /// Another glyph than the idea's (`NewModeGlyph`).
    var glyph: AnyView? = nil
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                BackPill()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Billing webhook retries").lineLimit(1)
                    TabSubtitle(folder: "app").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 40, alignment: .topLeading)
                .padding(.leading, 4)
            }
            .frame(width: 402 - 52 - 44 - 64, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {} label: { glyph ?? AnyView(ModeGlyph(idea: idea, lit: lit)) }
            Button {} label: { Image(systemName: "apple.logo").foregroundStyle(hostTint) }
        }
    }
}

/// Z0: every idea, on over off (Chat shown over Terminal shown), in the header as it sits; the pair at the right is
/// the glyph enlarged, on then off.
struct ModeGlyphCompareScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ModeGlyphIdea.allCases, id: \.self) { idea in
                    HStack {
                        Text(idea.title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer()
                        HStack(spacing: 22) {
                            ModeGlyph(idea: idea, lit: true, size: 22)
                            ModeGlyph(idea: idea, lit: false, size: 22)
                        }
                    }
                    .frame(height: 40)
                    .padding(.top, 6).padding(.horizontal, 20)
                    ForEach([true, false], id: \.self) { lit in
                        NavigationStack {
                            Color.canvas
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar { ModeGlyphHeader(idea: idea, lit: lit) }
                        }
                        .frame(height: 52)
                    }
                }
            }
        }
        .background(Color.canvas)
    }
}

/// Z1–Z4: the chat with the idea's lit glyph, as one would see it.
struct ModeGlyphChatScreen: View {
    let idea: ModeGlyphIdea
    var body: some View {
        NavigationStack {
            Transcript()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.canvas)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { Composer() }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ModeGlyphHeader(idea: idea, lit: true) }
        }
    }
}
