import SwiftUI

// Z: "dispatch-off", a night theme darker than Dispatch's true black (dispatch-black). The same chat screen in four
// palettes: Z0 today's Dispatch for reference; Z1 outline (no fills: bubbles, code and chrome are hairline borders on
// black, text dimmed); Z2 dim fills (the fills stay but sink to near black, the user's bubble a deep plum, text and
// accent dimmed); Z3 red night (night-vision red: every colour a shade of dim red on black, as astronomy apps do).
// The night palettes drop Liquid Glass (it lifts whatever is under it): the chrome is flat black with a hairline.

struct NightPalette {
    var canvas = Color.black
    var text: Color
    var secondary: Color
    var tertiary: Color
    var accent: Color
    var agentFill: Color?
    var agentBorder: Color?
    var userFill: Color?
    var userBorder: Color?
    var userText: Color
    var codeFill: Color?
    var codeBorder: Color?
    var keyword: Color
    var string: Color
    var type: Color
    var chromeFill: Color?
    var chromeBorder: Color?
    /// Today's chrome: Liquid Glass.
    var glass = false
    var badge: Color
    var check: Color

    static func srgb(_ hex: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    /// Z0: Dispatch today.
    static let today = NightPalette(
        text: .white, secondary: srgb(0xEBEBF5, 0.6), tertiary: srgb(0xEBEBF5, 0.3), accent: .dispatchPink,
        agentFill: .bubbleAgent, agentBorder: nil, userFill: Color("BubbleUser"), userBorder: nil,
        userText: Color("BubbleUserText"), codeFill: .codePanel, codeBorder: nil,
        keyword: .codeKeyword, string: .codeString, type: .codeType,
        chromeFill: nil, chromeBorder: nil, glass: true, badge: Color("StepRead"), check: .added)

    /// Z1: outline. No fills; hairlines; text at about 60%.
    static let outline = NightPalette(
        text: srgb(0x9C9CA2), secondary: srgb(0x6A6A70), tertiary: srgb(0x46464B), accent: srgb(0x9A5A90),
        agentFill: nil, agentBorder: srgb(0x2A2A2E), userFill: nil, userBorder: srgb(0x5A2E52),
        userText: srgb(0xB88AAE), codeFill: nil, codeBorder: srgb(0x232327),
        keyword: srgb(0x9A6A94), string: srgb(0x6E8A6E), type: srgb(0x6E829A),
        chromeFill: .black, chromeBorder: srgb(0x26262A), badge: srgb(0x5E7088), check: srgb(0x4E7A5A))

    /// Z2: dim fills. The shapes stay, sunk to near black; the user's bubble a deep plum.
    static let dim = NightPalette(
        text: srgb(0x8E8E94), secondary: srgb(0x606066), tertiary: srgb(0x3E3E43), accent: srgb(0x8A4A80),
        agentFill: srgb(0x0F0F11), agentBorder: nil, userFill: srgb(0x1E0D1A), userBorder: nil,
        userText: srgb(0xA9809F), codeFill: srgb(0x09090A), codeBorder: nil,
        keyword: srgb(0x8A5E84), string: srgb(0x627A62), type: srgb(0x62748A),
        chromeFill: srgb(0x0B0B0D), chromeBorder: nil, badge: srgb(0x52627A), check: srgb(0x46684F))

    /// Z3: red night. One hue, dim, on black.
    static let red = NightPalette(
        text: srgb(0xB0403C), secondary: srgb(0x7A2A28), tertiary: srgb(0x4E1A19), accent: srgb(0xC24A44),
        agentFill: nil, agentBorder: srgb(0x3A1513), userFill: srgb(0x1C0706), userBorder: srgb(0x4A1A18),
        userText: srgb(0xC4504A), codeFill: nil, codeBorder: srgb(0x2E1110),
        keyword: srgb(0xD0584F), string: srgb(0x8E3632), type: srgb(0xA8443F),
        chromeFill: .black, chromeBorder: srgb(0x341311), badge: srgb(0x8E3632), check: srgb(0x8E3632))
}

struct NightThemeScreen: View {
    let palette: NightPalette

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 10) {
                    bubble(user: true) { Text("Make billing webhook retries idempotent.") }
                    bubble(user: false) {
                        Text("Stripe retries the same event with a new attempt counter, so a counter-based guard can double-process. I'll key on the event id in ")
                            + Text("invoice.paid").font(.system(.callout, design: .monospaced)).foregroundColor(palette.keyword)
                            + Text(" too.")
                    }
                    code
                    bubble(user: true) { Text("Also cover the refund path.") }
                    bubble(user: false) { Text("Done: both routes go through the shared guard now, and the tests cover a replayed event.") }
                    step
                }
                .padding(.horizontal, 16).padding(.top, 10)
            }
            thinking
            composer
        }
        .background(palette.canvas.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 10) {
            chrome(Circle()) {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).foregroundStyle(palette.accent)
                    .frame(width: 44, height: 44)
            }
            chrome(Capsule()) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo").font(.system(size: 16)).foregroundStyle(palette.secondary)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Billing webhook retries").font(.subheadline.weight(.semibold)).foregroundStyle(palette.text)
                        Text("mba2 · app").font(.caption).foregroundStyle(palette.secondary)
                    }
                }
                .padding(.leading, 4).padding(.trailing, 16).frame(height: 44)
            }
            Spacer(minLength: 0)
            chrome(Circle()) {
                Image(systemName: "bubble.left.fill").font(.body).foregroundStyle(palette.accent)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 4)
    }

    private var thinking: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.chromeBorder ?? NightPalette.srgb(0x2A2A2E)).frame(height: 0.5)
            HStack(spacing: 8) {
                Text("◆").font(.system(size: 12)).foregroundStyle(palette.accent)
                Text("thinking").font(.subheadline.weight(.semibold)).foregroundStyle(palette.secondary)
                Text("· 52s").font(.subheadline).monospacedDigit().foregroundStyle(palette.secondary)
                Spacer()
                Text("4 steps").font(.caption).foregroundStyle(palette.tertiary)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(palette.secondary)
            }
            .frame(height: 44).padding(.horizontal, 16)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            chrome(Circle()) {
                Image(systemName: "plus").font(.body.weight(.semibold)).foregroundStyle(palette.text).frame(width: 44, height: 44)
            }
            chrome(Capsule()) {
                HStack {
                    Text("Queue a message…").foregroundStyle(palette.tertiary)
                    Spacer()
                    Image(systemName: "mic").foregroundStyle(palette.secondary)
                }
                .padding(.horizontal, 16).frame(height: 44)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 4)
    }

    /// A control's surface: glass today, flat at night (a fill, a hairline or both).
    @ViewBuilder private func chrome<S: InsettableShape, Content: View>(_ shape: S, @ViewBuilder _ content: () -> Content) -> some View {
        if palette.glass {
            content().glassEffect(.regular.interactive(), in: shape)
        } else {
            content()
                .background { if let fill = palette.chromeFill { shape.fill(fill) } }
                .overlay { if let border = palette.chromeBorder { shape.strokeBorder(border, lineWidth: 1) } }
        }
    }

    // MARK: Messages

    private func bubble(user: Bool, @ViewBuilder _ text: () -> Text) -> some View {
        let shape = UnevenRoundedRectangle(cornerRadii: user
            ? .init(topLeading: 20, bottomLeading: 20, bottomTrailing: 6, topTrailing: 20)
            : .init(topLeading: 20, bottomLeading: 6, bottomTrailing: 20, topTrailing: 20), style: .continuous)
        let fill = user ? palette.userFill : palette.agentFill
        let border = user ? palette.userBorder : palette.agentBorder
        return HStack(spacing: 0) {
            if user { Spacer(minLength: 0) }
            text()
                .font(.system(.callout, design: .rounded))
                .lineSpacing(2)
                .foregroundStyle(user ? palette.userText : palette.text)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background { if let fill { shape.fill(fill) } }
                .overlay { if let border { shape.stroke(border, lineWidth: 1) } }
                .frame(maxWidth: 370 * (user ? 0.78 : 0.86), alignment: user ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !user { Spacer(minLength: 0) }
        }
    }

    private var code: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let lines: [Text] = [
            Text("export ").foregroundColor(palette.keyword) + Text("function ").foregroundColor(palette.keyword)
                + Text("seen").foregroundColor(palette.type) + Text("(id: ").foregroundColor(palette.text)
                + Text("string").foregroundColor(palette.type) + Text(") {").foregroundColor(palette.text),
            Text("  return ").foregroundColor(palette.keyword) + Text("db.has(").foregroundColor(palette.text)
                + Text("\"evt_\"").foregroundColor(palette.string) + Text(" + id);").foregroundColor(palette.text),
            Text("}").foregroundColor(palette.text),
        ]
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in line }
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { if let fill = palette.codeFill { shape.fill(fill) } }
        .overlay { if let border = palette.codeBorder { shape.stroke(border, lineWidth: 1) } }
    }

    private var step: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.caption2.weight(.semibold)).imageScale(.small)
                Text("READ").font(.caption2.weight(.bold).monospaced()).tracking(0.44)
            }
            .foregroundStyle(palette.badge)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(palette.badge.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("src/routes/invoices.ts").font(.system(size: 13.5)).foregroundStyle(palette.text)
            Spacer()
            Image(systemName: "checkmark.circle").font(.footnote).foregroundStyle(palette.check)
        }
        .padding(.vertical, 6)
    }
}
