import AppKit
import SwiftUI

/// Makes a terminal color scheme from a `ThemeRecipe`: a harmony wheel for the seed color, a few knobs, presets and
/// "Surprise me", with the result live as a terminal session. Shown as a sheet from Settings (about 620×560); Save
/// hands back the name typed (not yet made unique) and the theme, which carries its recipe so it can be reopened here.
struct ThemeMakerView: View {
    let save: (String, TerminalTheme) -> Void
    let cancel: () -> Void
    private let typography = AppTypography()
    private let fonts: PreviewFonts
    @State private var recipe: ThemeRecipe
    /// What the user typed; nil follows the preset or the seed's hue family.
    @State private var typedName: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Who the scheme is for: Settings' colorblind mode, or the vision of the scheme being changed.
    private let vision: ColorVision
    /// Scheme names in use, which a suggested name steps around.
    private let taken = SurpriseScheme.takenNames()

    init(initial: ThemeRecipe? = nil, vision: ColorVision = .typical, save: @escaping (String, TerminalTheme) -> Void,
         cancel: @escaping () -> Void) {
        self.save = save
        self.cancel = cancel
        self.vision = initial?.vision ?? vision
        _recipe = State(initialValue: initial ?? ThemeRecipe.standard.with(vision: vision))
        fonts = PreviewFonts(preferences: TerminalRuntime.shared.preferences)
    }

    private var preset: ThemeRecipe.Preset? { ThemeRecipe.presets.first { $0.recipe.with(vision: vision) == recipe } }
    private var automaticName: String { preset?.name ?? ThemeGenerator.suggestedName(for: recipe, taken: taken) }
    private var name: String { typedName ?? automaticName }

    var body: some View {
        let theme = ThemeGenerator.make(recipe)
        VStack(spacing: 0) {
            header
            presetStrip.padding(.bottom, 12)
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    TerminalPreview(theme: theme, fonts: fonts)
                    SwatchGrid(theme: theme)
                }.frame(width: 356)
                controls(theme)
            }.padding(.horizontal, 18)
            Spacer(minLength: 12)
            footer(theme)
        }
        .frame(width: 620, height: 560)
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
                Text("New color scheme").fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                Text(vision == .typical ? "Grow a readable scheme from one color."
                     : "Grow a readable scheme from one color, for \(vision.title.lowercased()) color blindness.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }
            Spacer()
            ModeSwitch(light: $recipe.light)
            Button(action: surprise) {
                Label("Surprise me", systemImage: "dice")
                    .font(typography.font(offset: -1))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border) }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
                .help("A new random recipe")
                .accessibilityIdentifier("theme-maker-surprise")
        }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ThemeRecipe.presets) { preset in
                    let made = preset.recipe.with(vision: vision)
                    PresetChip(name: preset.name, theme: ThemeGenerator.make(made), selected: made == recipe) {
                        change { recipe = made; typedName = nil }
                    }
                }
            }.padding(.horizontal, 18)
        }
    }

    private func controls(_ theme: TerminalTheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HarmonyWheel(recipe: $recipe, theme: theme)
                .frame(width: 148, height: 148)
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                ColorPicker("Seed", selection: seedColor, supportsOpacity: false).labelsHidden()
                    .help("The color the scheme grows from")
                Text(recipe.seed.hex).font(typography.font(offset: -1)).foregroundStyle(Chrome.muted)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            if vision == .typical {
                harmonyMenu
                Text(recipe.harmony.detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func surprise() {
        // Seeded from System so a replayed test sees the same surprise.
        let bytes = System.uuid().uuid
        let seed = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7]
            .reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        // A surprise stays on the side the switch shows.
        var next = ThemeRecipe.random(seed: seed).with(vision: vision)
        next.light = recipe.light
        change { recipe = next; typedName = nil }
    }

    /// Whole-recipe jumps (presets, surprises) cross-fade; knobs follow the pointer directly.
    private func change(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(.easeInOut(duration: 0.22), body) }
    }

    private var seedColor: Binding<Color> {
        Binding(get: { recipe.seed.swiftUI }, set: { color in
            guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            recipe.seed = ThemeColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
        })
    }

    private var vibrancyRamp: [Color] {
        let hue = recipe.seed.oklch.h
        return stride(from: 0.0, through: 1, by: 0.25).map {
            ThemeColor(oklch: OKLCH(l: 0.68, c: 0.06 + 0.14 * $0, h: hue)).swiftUI
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
    var swiftUI: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
}

// MARK: - Preview

/// The terminal's font family at a size that fits the preview.
private struct PreviewFonts {
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
private struct TerminalPreview: View {
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

/// The seed on an OKLCH hue/chroma disc: drag to choose hue (angle) and colorfulness (distance from the middle).
/// The ring shows the six accents where the harmony turned them (an arc from each one's standard hue) and the
/// harmony's shape joins its attractor hues.
private struct HarmonyWheel: View {
    @Binding var recipe: ThemeRecipe
    let theme: TerminalTheme
    /// The disc's edge stands for this chroma; sRGB's most colorful colors sit near it.
    private static let maxChroma = 0.26

    var body: some View {
        let seed = recipe.seed.oklch
        let fieldL = min(0.85, max(0.5, seed.l))
        let stops = stride(from: 0.0, through: 360, by: 15).map { hue in
            Gradient.Stop(color: ThemeColor(oklch: OKLCH(l: fieldL, c: 0.3, h: hue)).swiftUI, location: hue / 360)
        }
        let ringStops = stride(from: 0.0, through: 360, by: 15).map { hue in
            Gradient.Stop(color: ThemeColor(oklch: OKLCH(l: 0.74, c: 0.13, h: hue)).swiftUI, location: hue / 360)
        }
        let gray = ThemeColor(oklch: OKLCH(l: fieldL, c: 0, h: 0)).swiftUI
        let accents = ThemeGenerator.hues(for: recipe).enumerated().map { index, hue in
            (anchor: ThemeGenerator.anchors(for: recipe.vision)[index], hue: hue, color: (theme.palette[index + 1] ?? theme.foreground).swiftUI)
        }
        // Colorblind accents don't follow a harmony, so it has no shape to show.
        let attractors = recipe.vision == .typical ? recipe.harmony.attractors(seed: seed.h) : []
        let seedColor = recipe.seed.swiftUI
        let chroma = min(1, seed.c / Self.maxChroma)
        let background = theme.background.swiftUI
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 1
            let ringWidth: CGFloat = 12, disc = outer - ringWidth - 5
            func point(_ hue: Double, _ radius: CGFloat) -> CGPoint {
                let angle = (hue - 90) * .pi / 180
                return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            }
            func circle(_ at: CGPoint, _ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            }
            // Hue ring.
            var ring = Path()
            ring.addArc(center: center, radius: outer - ringWidth / 2, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            context.stroke(ring, with: .conicGradient(Gradient(stops: ringStops), center: center, angle: .degrees(-90)),
                           lineWidth: ringWidth)
            // Hue and chroma field: hues around, gray in the middle.
            let field = circle(center, disc)
            context.fill(field, with: .conicGradient(Gradient(stops: stops), center: center, angle: .degrees(-90)))
            context.fill(field, with: .radialGradient(Gradient(colors: [gray, gray.opacity(0)]), center: center,
                                                      startRadius: 0, endRadius: disc))
            context.stroke(field, with: .color(background.opacity(0.35)), lineWidth: 1)
            // The harmony's shape.
            if attractors.count > 1 {
                var shape = Path()
                shape.addLines(attractors.map { point($0, disc * 0.82) })
                if attractors.count > 2 { shape.closeSubpath() }
                context.stroke(shape, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.25, dash: [3, 3]))
            }
            for hue in attractors {
                context.fill(circle(point(hue, disc * 0.82), 2.5), with: .color(.white.opacity(0.9)))
            }
            // Accents on the ring, each with an arc back to its standard hue.
            let mid = outer - ringWidth / 2
            for accent in accents {
                let turn = ThemeGenerator.turn(from: accent.anchor, to: accent.hue)
                if abs(turn) > 0.5 {
                    var arc = Path()
                    arc.addArc(center: center, radius: mid, startAngle: .degrees(accent.anchor - 90),
                               endAngle: .degrees(accent.anchor + turn - 90), clockwise: turn < 0)
                    context.stroke(arc, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                let at = point(accent.hue, mid)
                context.fill(circle(at, 6.5), with: .color(background))
                context.fill(circle(at, 5), with: .color(accent.color))
            }
            // The seed.
            let knob = point(seed.h, disc * chroma)
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(0.5), radius: 3, y: 1))
            shadow.fill(circle(knob, 8), with: .color(.white))
            context.fill(circle(knob, 6), with: .color(seedColor))
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in pick(drag.location, fieldL: fieldL) })
        .accessibilityElement()
        .accessibilityLabel("Seed color")
        .accessibilityValue("\(recipe.seed.hex), hue \(Int(seed.h.rounded())) degrees")
        .accessibilityAdjustableAction { direction in
            let step: Double = direction == .increment ? 10 : -10
            recipe.seed = ThemeColor(oklch: OKLCH(l: seed.l, c: seed.c, h: ThemeGenerator.wrap(seed.h + step)))
        }
    }

    private func pick(_ location: CGPoint, fieldL: Double) {
        // The frame is 148 square; the disc's radius matches the Canvas's layout above.
        let size: CGFloat = 148, disc = size / 2 - 1 - 12 - 5
        let dx = location.x - size / 2, dy = location.y - size / 2
        let hue = ThemeGenerator.wrap(atan2(dy, dx) * 180 / .pi + 90)
        let chroma = min(1, (dx * dx + dy * dy).squareRoot() / disc) * Self.maxChroma
        recipe.seed = ThemeColor(oklch: OKLCH(l: fieldL, c: chroma, h: hue))
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
private struct GradientSlider: View {
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

/// A preset: its background with four accents, and its name.
private struct PresetChip: View {
    let name: String
    let theme: TerminalTheme
    let selected: Bool
    let action: () -> Void
    @Environment(\.appTypography) private var typography

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
            .accessibilityLabel(name)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
