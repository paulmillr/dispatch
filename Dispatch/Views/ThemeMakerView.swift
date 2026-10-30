import AppKit
import SwiftUI

/// Makes a terminal color scheme from a `ThemeRecipe`: a harmony wheel and a lightness for the seed color, a few
/// knobs, and Random inside a style (muted, neon…) or any, with the result live as a terminal session. Shown as a sheet
/// from Settings, 620 wide and as tall as its content at the user's text size; Save hands back the name typed (not yet
/// made unique) and the theme, which carries its recipe so it can be reopened here.
struct ThemeMakerView: View {
    let save: (String, TerminalTheme) -> Void
    let cancel: () -> Void
    /// The header's title: a new scheme, a copy, or one being changed.
    private let title: String
    /// Changing a scheme in place keeps its name.
    private let nameFixed: Bool
    private let typography = AppTypography()
    private let fonts: PreviewFonts
    @State private var recipe: ThemeRecipe
    /// What the user typed; nil follows the seed's hue family.
    @State private var typedName: String?
    /// The style Random draws inside, once one is chosen; nil draws any recipe.
    @State private var style: ThemeRecipe.Style?
    /// The seed as the wheel and Lightness last set it: the stored seed is that color in the gamut, which can lose
    /// the hue (a gray) or chroma (a lightness that can't hold it). Nil follows the stored seed (Random, the color
    /// picker).
    @State private var target: OKLCH?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Who the scheme is for: Settings' colorblind mode, or the vision of the scheme being changed.
    private let vision: ColorVision
    /// Scheme names in use, which a suggested name steps around.
    private let taken = SurpriseScheme.takenNames()

    /// `name`: the name to start from, a copy's or the scheme's own (`nameFixed` while changing it in place).
    init(initial: ThemeRecipe? = nil, vision: ColorVision = .typical, title: String = "New color scheme", name: String? = nil,
         nameFixed: Bool = false, save: @escaping (String, TerminalTheme) -> Void, cancel: @escaping () -> Void) {
        self.save = save
        self.cancel = cancel
        self.title = title
        self.nameFixed = nameFixed
        self.vision = initial?.vision ?? vision
        _recipe = State(initialValue: initial ?? ThemeRecipe.standard.with(vision: vision))
        _typedName = State(initialValue: name)
        fonts = PreviewFonts(preferences: TerminalRuntime.shared.preferences)
    }

    private var automaticName: String { ThemeGenerator.suggestedName(for: recipe, taken: taken) }
    private var name: String { typedName ?? automaticName }

    var body: some View {
        let theme = ThemeGenerator.make(recipe)
        VStack(spacing: 0) {
            header
            styleStrip.padding(.bottom, 12)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    TerminalPreview(theme: theme, fonts: fonts)
                    SwatchGrid(theme: theme)
                }.frame(width: 356)
                controls(theme)
            }.padding(.horizontal, 18).padding(.bottom, 16)
            footer(theme)
        }
        // As tall as the controls at the user's text size, so the footer never falls off the bottom.
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: recipe.seed) { _, seed in
            // Something other than the wheel and Lightness chose the seed: they follow it.
            if let target, ThemeColor(oklch: target, displayP3: recipe.displayP3) != seed { self.target = nil }
        }
        .onChange(of: recipe.displayP3) { _, wide in
            // The seed the controls hold, in the new gamut: P3 off brings a seed beyond sRGB back inside it.
            let held = seed
            recipe.seed = ThemeColor(oklch: held, displayP3: wide)
            target = held
        }
        .background(Chrome.window)
        .foregroundStyle(Chrome.ink)
        .font(typography.font(offset: 0))
        .environment(\.appTypography, typography)
        .controlSize(.small)
        .tint(Chrome.accent)
        .preferredColorScheme(Chrome.colorScheme)
        .accessibilityIdentifier("theme-maker")
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText).lineLimit(1)
                Text(vision == .typical ? "Grow a readable scheme from one color."
                     : "Grow a readable scheme from one color, for \(vision.title.lowercased()) color blindness.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }
            Spacer()
            ModeSwitch(light: $recipe.light)
            // "P3" fits beside Dark and Light; the help and VoiceOver say Display P3 in full.
            Toggle(isOn: $recipe.displayP3) { Text("P3").font(typography.font(offset: -1)) }
                .toggleStyle(.checkbox)
                .help("Display P3: colors beyond sRGB for wide-color displays. Ghostty and other apps get the nearest sRGB colors.")
                .accessibilityLabel("Display P3")
                .accessibilityIdentifier("theme-maker-display-p3")
            Button(action: surprise) {
                Label("Random", systemImage: "dice")
                    .font(typography.font(offset: -1))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border) }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
                .help(style.map { "Another random \($0.title.lowercased()) scheme" } ?? "A new random recipe")
                .accessibilityIdentifier("theme-maker-surprise")
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    /// The styles: each chip shows one of its schemes on the side the switch shows, and a click makes a random one.
    private var styleStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ThemeRecipe.Style.allCases) { style in
                    StyleChip(style: style, theme: ThemeGenerator.make(sample(style)), selected: self.style == style) {
                        self.style = style
                        surprise()
                    }
                }
            }.padding(.horizontal, 18)
        }
    }

    /// A style's chip colors: always the same draw, one whose hue suits the style (Neon on a green that can be
    /// that colorful), on the side and for the vision the maker shows.
    private func sample(_ style: ThemeRecipe.Style) -> ThemeRecipe {
        let seeds: [ThemeRecipe.Style: UInt64] = [.muted: 9, .pastel: 10, .earthy: 3, .cool: 1, .vivid: 3, .neon: 5, .mono: 6]
        var sample = ThemeRecipe.random(seed: seeds[style] ?? 1, style: style, light: recipe.light).with(vision: vision)
        sample.displayP3 = recipe.displayP3
        return sample
    }

    private func controls(_ theme: TerminalTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HarmonyWheel(recipe: recipe, seed: seed, theme: theme, pick: setSeed)
                .frame(width: HarmonyWheel.size, height: HarmonyWheel.size)
                .frame(maxWidth: .infinity)
            GradientSlider(title: "Lightness", value: Binding(get: { seed.l }, set: { setSeed(OKLCH(l: $0, c: seed.c, h: seed.h)) }),
                           colors: lightnessRamp)
                .help("The seed's lightness: the cursor is the seed, moved only as far as it must to read")
            HStack(spacing: 8) {
                ColorPicker("Seed", selection: seedColor, supportsOpacity: false).labelsHidden()
                    .help("The color the scheme grows from")
                VStack(alignment: .leading, spacing: 0) {
                    Text(recipe.seed.displayP3.map { "P3 \($0.hex)" } ?? recipe.seed.hex)
                    Text(recipe.seed.oklchText).accessibilityIdentifier("theme-maker-oklch")
                }.font(typography.font(offset: -1.5, design: .monospaced)).foregroundStyle(Chrome.muted)
                    .lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if vision == .typical {
                // What the harmony does is the menu's tooltip.
                harmonyMenu.help(recipe.harmony.detail)
            } else {
                Text("accent hues stay fixed so \(vision.title.lowercased()) color blindness can tell them apart")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("theme-maker-colorblind")
            }
            GradientSlider(title: "Vibrancy", value: $recipe.vibrancy, colors: vibrancyRamp)
            GradientSlider(title: "Contrast", value: $recipe.contrast, colors: contrastRamp)
            GradientSlider(title: "Tint", value: $recipe.tint, colors: tintRamp)
        }.frame(maxWidth: .infinity)
    }

    private var harmonyMenu: some View {
        Menu {
            Picker("Harmony", selection: $recipe.harmony) {
                ForEach(ThemeRecipe.Harmony.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack {
                Text(recipe.harmony.title).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(SettingsControlStyle.detail)
            }.font(typography.font(offset: -0.5))
                .padding(.horizontal, 9).frame(height: typography.expanded(26))
                .background(SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border) }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Harmony")
            .accessibilityValue(recipe.harmony.title)
    }

    private func footer(_ theme: TerminalTheme) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Chrome.palette.separator).frame(height: 1)
            HStack(spacing: 10) {
                Text("Name").font(typography.font(offset: -0.5)).foregroundStyle(Chrome.muted)
                TextField(automaticName, text: Binding(get: { name }, set: { typedName = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder).font(typography.font(offset: -0.5, design: .monospaced))
                    .frame(width: 200)
                    .disabled(nameFixed)
                    .onSubmit(commit)
                    .accessibilityIdentifier("theme-maker-name")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: commit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("theme-maker-save")
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }.background(Chrome.sidebar)
    }

    // MARK: - Actions and ramps

    private func commit() {
        save(CustomThemes.sanitized(name), ThemeGenerator.make(recipe))
    }

    /// Random: a new recipe inside the chosen style, else any.
    private func surprise() {
        // Seeded from System so a replayed test sees the same surprise.
        let bytes = System.uuid().uuid
        let seed = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // A surprise stays on the side the switch shows.
        var next = (style.map { ThemeRecipe.random(seed: seed, style: $0, light: recipe.light) } ?? ThemeRecipe.random(seed: seed))
            .with(vision: vision)
        (next.light, next.displayP3) = (recipe.light, recipe.displayP3)
        change { recipe = next; typedName = nil }
    }

    /// Whole-recipe jumps (styles, surprises) cross-fade; knobs follow the pointer directly.
    private func change(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(.easeInOut(duration: 0.22), body) }
    }

    /// The seed as the controls hold it.
    private var seed: OKLCH { target ?? recipe.seed.oklch }

    /// The wheel or Lightness chose `lch`: the seed becomes it, in the gamut, and the controls keep it as chosen.
    private func setSeed(_ lch: OKLCH) {
        target = lch
        recipe.seed = ThemeColor(oklch: lch, displayP3: recipe.displayP3)
    }

    /// The seed's hue and chroma from dark to light, each step as colorful as it can be.
    private var lightnessRamp: [Color] {
        stride(from: 0.0, through: 1, by: 0.1).map {
            ThemeColor(oklch: OKLCH(l: $0, c: seed.c, h: seed.h), displayP3: recipe.displayP3).swiftUI
        }
    }

    private var seedColor: Binding<Color> {
        Binding(get: { recipe.seed.swiftUI }, set: { color in
            // Display P3 picks outside sRGB stay P3, and make the scheme Display P3 too.
            guard let seed = ThemeColor(NSColor(color)) else { return }
            recipe.seed = seed
            if seed.displayP3 != nil { recipe.displayP3 = true }
        })
    }

    private var vibrancyRamp: [Color] {
        let hue = recipe.seed.oklch.h
        return stride(from: 0.0, through: 1, by: 0.25).map {
            ThemeColor(oklch: OKLCH(l: 0.68, c: 0.06 + (recipe.displayP3 ? 0.19 : 0.14) * $0, h: hue),
                       displayP3: recipe.displayP3).swiftUI
        }
    }

    private var contrastRamp: [Color] {
        var soft = recipe, crisp = recipe
        soft.contrast = 0; crisp.contrast = 1
        return [ThemeGenerator.make(soft).background.swiftUI, ThemeGenerator.make(crisp).foreground.swiftUI]
    }

    private var tintRamp: [Color] {
        let seed = recipe.seed.oklch
        let chroma = 0.08 * ThemeGenerator.presence(seed)
        return [ThemeColor(oklch: OKLCH(l: 0.6, c: 0, h: seed.h)).swiftUI,
                ThemeColor(oklch: OKLCH(l: 0.6, c: chroma, h: seed.h)).swiftUI]
    }
}

extension ThemeColor {
    var swiftUI: Color {
        if let p3 = displayP3 { return Color(.displayP3, red: Double(p3.r) / 255, green: Double(p3.g) / 255, blue: Double(p3.b) / 255) }
        return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

// MARK: - Preview

/// The terminal's font family at a size that fits the preview.
struct PreviewFonts {
    let regular: Font
    let bold: Font

    @MainActor init(preferences: Preferences) {
        AppFont.register()
        let size = min(12.5, max(10, preferences.fontSize))
        let base = NSFontManager.shared.font(withFamily: preferences.fontFamily, traits: [], weight: 5, size: size)
            ?? NSFont(name: preferences.fontFamily, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        regular = Font(base)
        bold = Font(NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask))
    }
}

/// A short, typical session drawn with the theme: prompt, `ls`, a diff, compiler output, a link, a selection and a
/// block cursor with a dim autosuggestion.
struct TerminalPreview: View {
    let theme: TerminalTheme
    let fonts: PreviewFonts

    /// Where a run's color comes from.
    private enum Ink { case text, ansi(Int), cursor, selection }
    private struct Run {
        var text: String
        var ink = Ink.text
        var bold = false
        var underline = false
    }

    private static let session: [[Run]] = {
        func prompt(_ command: String, dirty: Bool = true) -> [Run] {
            [Run(text: "~/orbit", ink: .ansi(4), bold: true), Run(text: " "), Run(text: "main", ink: .ansi(5)),
             Run(text: dirty ? "*" : "", ink: .ansi(3)), Run(text: " ❯ ", ink: .ansi(2), bold: true), Run(text: command)]
        }
        return [
            prompt("ls -F"),
            [Run(text: "README.md  "), Run(text: "Sources/", ink: .ansi(12), bold: true), Run(text: "  "),
             Run(text: "build.sh*", ink: .ansi(10), bold: true), Run(text: "  "), Run(text: "logo.png", ink: .ansi(13))],
            prompt("git diff"),
            [Run(text: "@@ -12,6 +12,6 @@", ink: .ansi(6)), Run(text: " struct Orbit {")],
            [Run(text: "-    let radius = 1.0", ink: .ansi(1))],
            [Run(text: "+    let radius = 1.5", ink: .ansi(2))],
            [Run(text: "     "), Run(text: "let speed = 0.3", ink: .selection)],
            prompt("make test"),
            [Run(text: "   Compiling", ink: .ansi(2), bold: true), Run(text: " orbit v0.3.1")],
            [Run(text: "warning:", ink: .ansi(11), bold: true), Run(text: " unused variable 'tilt'")],
            [Run(text: "✓ 42 passed", ink: .ansi(10)), Run(text: "  "), Run(text: "✗ 1 failed", ink: .ansi(9), bold: true),
             Run(text: "  "), Run(text: "2 skipped", ink: .ansi(14))],
            [Run(text: "docs ", ink: .ansi(8)), Run(text: "https://example.com/orbit", ink: .ansi(4), underline: true)],
            prompt("", dirty: false) + [Run(text: "g", ink: .cursor), Run(text: "it push", ink: .ansi(8))],
        ]
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([1, 3, 2], id: \.self) { index in
                    Circle().fill((theme.palette[index] ?? theme.foreground).swiftUI.opacity(0.85)).frame(width: 8, height: 8)
                }
                Spacer()
                Text("zsh — 52×14").font(fonts.regular).foregroundStyle((theme.palette[8] ?? theme.foreground).swiftUI)
                Spacer()
                Color.clear.frame(width: 36, height: 8)
            }.padding(.horizontal, 10).frame(height: 24)
            Rectangle().fill(theme.foreground.swiftUI.opacity(0.08)).frame(height: 1)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Self.session.indices, id: \.self) { index in
                    Text(line(Self.session[index])).lineLimit(1).fixedSize()
                }
            }.padding(.horizontal, 12).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
        }
        .background(theme.background.swiftUI, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.border) }
        .shadow(color: .black.opacity(Chrome.palette.isDark ? 0.45 : 0.14), radius: 12, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the color scheme")
    }

    private func line(_ runs: [Run]) -> AttributedString {
        runs.reduce(into: AttributedString()) { line, run in
            var part = AttributedString(run.text)
            let fore: Color, back: Color?
            switch run.ink {
            case .text: (fore, back) = (theme.foreground.swiftUI, nil)
            case .ansi(let index): (fore, back) = ((theme.palette[index] ?? theme.foreground).swiftUI, nil)
            case .cursor: (fore, back) = ((theme.cursorText ?? theme.background).swiftUI, (theme.cursor ?? theme.foreground).swiftUI)
            case .selection:
                (fore, back) = ((theme.selectionForeground ?? theme.foreground).swiftUI,
                                (theme.selectionBackground ?? theme.foreground).swiftUI)
            }
            part.foregroundColor = fore
            if let back { part.backgroundColor = back }
            part.font = run.bold ? fonts.bold : fonts.regular
            if run.underline { part.underlineStyle = Text.LineStyle.single }
            line += part
        }
    }
}

/// The 16 ANSI colors, normal above bright, on the theme's background.
private struct SwatchGrid: View {
    let theme: TerminalTheme
    private static let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { column in
                        let index = row * 8 + column
                        let color = theme.palette[index] ?? theme.foreground
                        RoundedRectangle(cornerRadius: 5).fill(color.swiftUI)
                            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(theme.foreground.swiftUI.opacity(0.1)) }
                            .frame(height: 20)
                            .help("\(index) \(row == 1 ? "bright " : "")\(Self.names[column]) \(color.hex)")
                    }
                }
            }
        }.padding(8)
            .background(theme.background.swiftUI, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.border) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("ANSI colors")
    }
}

// MARK: - Controls

/// The seed on an OKLCH hue/chroma disc at the seed's lightness (`OKLCHDisc`): drag to choose hue (angle) and
/// colorfulness (distance from the middle); the lightness is the Lightness slider's. The ring shows the six accents where
/// the harmony turned them (an arc from each one's standard hue) and the harmony's shape joins its attractor hues.
private struct HarmonyWheel: View {
    let recipe: ThemeRecipe
    /// The seed as the controls hold it, so its hue outlives a gray and its chroma a lightness that can't reach it.
    let seed: OKLCH
    let theme: TerminalTheme
    let pick: (OKLCH) -> Void
    static let size: CGFloat = 148
    @State private var cache = OKLCHDiscCache()
    @Environment(\.displayScale) private var scale

    /// The ring and the disc inside it.
    private static let outer = size / 2 - 1, ringWidth: CGFloat = 12
    private static let disc = outer - ringWidth - 5

    var body: some View {
        let p3 = recipe.displayP3
        let ringStops = stride(from: 0.0, through: 360, by: 15).map { hue in
            Gradient.Stop(color: ThemeColor(oklch: OKLCH(l: 0.74, c: 0.13, h: hue)).swiftUI, location: hue / 360)
        }
        let accents = ThemeGenerator.hues(for: recipe).enumerated().map { index, hue in
            (anchor: ThemeGenerator.anchors(for: recipe.vision)[index], hue: hue, color: (theme.palette[index + 1] ?? theme.foreground).swiftUI)
        }
        // Colorblind accents don't follow a harmony, so it has no shape to show.
        let attractors = recipe.vision == .typical ? recipe.harmony.attractors(seed: seed.h) : []
        let seedColor = recipe.seed.swiftUI
        let fraction = OKLCHDisc.radius(chroma: seed.c, hue: seed.h, l: seed.l, displayP3: p3)
        let image = cache.image(l: seed.l, displayP3: p3, pixels: Int((Self.disc * 2 * scale).rounded()))
        let background = theme.background.swiftUI
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let disc = Self.disc
            func point(_ hue: Double, _ fraction: Double, _ radius: CGFloat = disc) -> CGPoint {
                OKLCHDisc.point(center: center, radius: radius, hue: hue, fraction: fraction)
            }
            func circle(_ at: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            }
            // Hue ring.
            var ring = Path()
            ring.addArc(center: center, radius: Self.outer - Self.ringWidth / 2, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            context.stroke(ring, with: .conicGradient(Gradient(stops: ringStops), center: center, angle: .degrees(-90)),
                           lineWidth: Self.ringWidth)
            // The disc: the sRGB core, and with P3 the band around it.
            let field = circle(center, disc * (p3 ? 1 : OKLCHDisc.core))
            if let image {
                var clipped = context
                clipped.clip(to: field)
                clipped.draw(Image(decorative: image, scale: scale), in: CGRect(x: center.x - disc, y: center.y - disc,
                                                                                width: disc * 2, height: disc * 2))
            }
            context.stroke(field, with: .color(background.opacity(0.35)), lineWidth: 1)
            if p3 {
                // sRGB's edge: beyond it other apps get the nearest sRGB color.
                context.stroke(circle(center, disc * OKLCHDisc.core), with: .color(.black.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [1, 2.5]))
            }
            // The harmony's shape, inside the core so turning P3 on doesn't move it.
            let shapeAt = OKLCHDisc.core * 0.9
            if attractors.count > 1 {
                var shape = Path()
                shape.addLines(attractors.map { point($0, shapeAt) })
                if attractors.count > 2 { shape.closeSubpath() }
                context.stroke(shape, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
            }
            for hue in attractors {
                context.fill(circle(point(hue, shapeAt), 2.5), with: .color(.white.opacity(0.9)))
            }
            // Accents on the ring, each with an arc back to its standard hue.
            let mid = Self.outer - Self.ringWidth / 2
            for accent in accents {
                let turn = ThemeGenerator.turn(from: accent.anchor, to: accent.hue)
                if abs(turn) > 0.5 {
                    var arc = Path()
                    arc.addArc(center: center, radius: mid, startAngle: .degrees(accent.anchor - 90),
                               endAngle: .degrees(accent.anchor + turn - 90), clockwise: turn < 0)
                    context.stroke(arc, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                let at = point(accent.hue, 1, mid)
                context.fill(circle(at, 6.5), with: .color(background))
                context.fill(circle(at, 5), with: .color(accent.color))
            }
            // The seed.
            let knob = point(seed.h, fraction)
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(0.5), radius: 3, y: 1))
            shadow.fill(circle(knob, 8), with: .color(.white))
            context.fill(circle(knob, 6), with: .color(seedColor))
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let at = OKLCHDisc.pick(drag.location, center: CGPoint(x: Self.size / 2, y: Self.size / 2), radius: Self.disc)
            pick(OKLCH(l: seed.l, c: OKLCHDisc.chroma(radius: at.fraction, hue: at.hue, l: seed.l, displayP3: p3), h: at.hue))
        })
        .accessibilityElement()
        .accessibilityLabel("Seed color")
        .accessibilityValue("\(recipe.seed.hex), \(recipe.seed.oklchText)")
        .accessibilityAdjustableAction { direction in
            pick(OKLCH(l: seed.l, c: seed.c, h: ThemeGenerator.wrap(seed.h + (direction == .increment ? 10 : -10))))
        }
    }
}

/// Dark or light, styled like Settings' tabs.
private struct ModeSwitch: View {
    @Binding var light: Bool
    @Environment(\.appTypography) private var typography

    var body: some View {
        HStack(spacing: 2) {
            option("Dark", light: false)
            option("Light", light: true)
        }.padding(2).fixedSize()
            .background(SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsControlStyle.border) }
    }

    private func option(_ title: String, light value: Bool) -> some View {
        Button { light = value } label: {
            Text(title).font(typography.font(offset: -1))
                .foregroundStyle(light == value ? SettingsControlStyle.selectedText : Chrome.muted)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(light == value ? SettingsControlStyle.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
            .accessibilityAddTraits(light == value ? .isSelected : [])
    }
}

/// A 0…1 knob whose track shows what it does, with Settings' slider knob.
struct GradientSlider: View {
    let title: String
    @Binding var value: Double
    let colors: [Color]
    @Environment(\.appTypography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(typography.font(offset: -1))
                Spacer()
                Text("\(Int((value * 100).rounded()))").font(typography.font(offset: -1.5)).monospacedDigit()
                    .foregroundStyle(SettingsControlStyle.detail)
            }
            GeometryReader { proxy in
                let width = proxy.size.width, knob: CGFloat = 14
                let x = knob / 2 + (width - knob) * min(1, max(0, value))
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .overlay { Capsule().strokeBorder(SettingsControlStyle.border) }
                        .frame(height: 6)
                    Circle().fill(SettingsControlStyle.selectedText)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 1)
                        .frame(width: knob, height: knob)
                        .position(x: x, y: proxy.size.height / 2)
                }.frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        let fraction = Double((drag.location.x - knob / 2) / max(1, width - knob))
                        value = (min(1, max(0, fraction)) * 100).rounded() / 100
                    })
            }.frame(height: 16)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            value = min(1, max(0, value + (direction == .increment ? 0.05 : -0.05)))
        }
    }
}

/// A style: one of its schemes' background with four accents, and its name; the tooltip says what it is.
private struct StyleChip: View {
    let style: ThemeRecipe.Style
    let theme: TerminalTheme
    let selected: Bool
    let action: () -> Void
    @Environment(\.appTypography) private var typography
    private var name: String { style.title }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                HStack(spacing: 2) {
                    ForEach([1, 3, 4, 5], id: \.self) { index in
                        Circle().fill((theme.palette[index] ?? theme.foreground).swiftUI).frame(width: 5, height: 5)
                    }
                }.padding(.horizontal, 5).frame(height: 14)
                    .background(theme.background.swiftUI, in: Capsule())
                    .overlay { Capsule().strokeBorder(theme.foreground.swiftUI.opacity(0.15)) }
                Text(name).font(typography.font(offset: -1))
                    .foregroundStyle(selected ? SettingsControlStyle.selectedText : Chrome.muted)
            }.padding(.leading, 5).padding(.trailing, 9).padding(.vertical, 4)
                .background(selected ? SettingsControlStyle.selected : SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Chrome.accent : SettingsControlStyle.border) }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
            .help("\(name): \(style.detail) · a click makes a random one, and Random makes another")
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("theme-maker-style-\(style.rawValue)")
    }
}
