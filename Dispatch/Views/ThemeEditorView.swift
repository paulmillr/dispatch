import AppKit
import SwiftUI

/// One color a scheme sets: the six named ones, or an ANSI color.
enum ThemeSlot: Hashable {
    case background, foreground, cursor, cursorText, selection, selectionText, ansi(Int)

    static let named: [ThemeSlot] = [.background, .foreground, .cursor, .cursorText, .selection, .selectionText]
    private static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

    var title: String {
        switch self {
        case .background: "Background"
        case .foreground: "Text"
        case .cursor: "Cursor"
        case .cursorText: "Cursor text"
        case .selection: "Selection"
        case .selectionText: "Selected text"
        case .ansi(let index): "\(index) \(index >= 8 ? "bright " : "")\(Self.ansiNames[index % 8])"
        }
    }

    /// The color it is read against: text on the background, cursor text on the cursor, and so on.
    var against: ThemeSlot {
        switch self {
        case .background: .foreground
        case .cursorText: .cursor
        case .cursor: .cursorText
        case .selection: .selectionText
        case .selectionText: .selection
        default: .background
        }
    }
}

extension TerminalTheme {
    /// A slot's color, or what the terminal uses when the scheme leaves it out: Ghostty's inverted cursor and
    /// selection, xterm's ANSI colors. Setting one writes it into the scheme.
    subscript(slot: ThemeSlot) -> ThemeColor {
        get {
            switch slot {
            case .background: background
            case .foreground: foreground
            case .cursor: cursor ?? foreground
            case .cursorText: cursorText ?? background
            case .selection: selectionBackground ?? foreground
            case .selectionText: selectionForeground ?? background
            case .ansi(let index): palette[index] ?? SchemeDemo.standard[index]
            }
        }
        set {
            switch slot {
            case .background: background = newValue
            case .foreground: foreground = newValue
            case .cursor: cursor = newValue
            case .cursorText: cursorText = newValue
            case .selection: selectionBackground = newValue
            case .selectionText: selectionForeground = newValue
            case .ansi(let index): palette[index] = newValue
            }
        }
    }
}

/// Changes a scheme color by color: a copy of any scheme (Duplicate and Edit), or one of yours in place. Pick a slot
/// under the live session, then its hue and colorfulness on the disc and its lightness below, or type its hex. Save
/// hands back the name and the theme, without a made scheme's recipe (the maker could no longer make these colors) and
/// with the colorblind mode it was edited in, so it stays listed there. Shown as a sheet from Settings, like the maker.
struct ThemeEditorView: View {
    let save: (String, TerminalTheme) -> Void
    let cancel: () -> Void
    private let title: String
    private let original: TerminalTheme
    private let vision: ColorVision
    private let nameFixed: Bool
    private let typography = AppTypography()
    private let fonts: PreviewFonts
    @State private var theme: TerminalTheme
    @State private var slot = ThemeSlot.background
    @State private var name: String
    /// Picks beyond sRGB, as in the maker; on when the scheme already has Display P3 colors.
    @State private var wide: Bool
    /// The slot's color as the disc and Lightness last set it (see ThemeMakerView.target); nil follows the slot.
    @State private var target: OKLCH?
    /// The hex being typed; nil shows the slot's.
    @State private var hexDraft: String?

    /// The comment line that keeps an edited scheme's colorblind mode, as a made one's recipe does.
    nonisolated static let visionMarker = "# dispatch-vision: "

    /// The colorblind mode a scheme's file names, if it names one.
    nonisolated static func vision(in theme: TerminalTheme) -> ColorVision? {
        theme.extra.first { $0.hasPrefix(visionMarker) }.flatMap { ColorVision(rawValue: String($0.dropFirst(visionMarker.count))) }
    }

    /// `theme` as the editor saves it: no recipe or surprise mark, and its colorblind mode named unless typical.
    nonisolated static func saved(_ theme: TerminalTheme, vision: ColorVision) -> TerminalTheme {
        var theme = theme
        theme.extra.removeAll { $0.hasPrefix(ThemeRecipe.marker) || $0 == SurpriseScheme.marker || $0.hasPrefix(visionMarker) }
        if vision != .typical { theme.extra.append(visionMarker + vision.rawValue) }
        return theme
    }

    init(theme: TerminalTheme, vision: ColorVision, title: String, name: String, nameFixed: Bool = false,
         save: @escaping (String, TerminalTheme) -> Void, cancel: @escaping () -> Void) {
        self.save = save
        self.cancel = cancel
        self.title = title
        self.original = theme
        self.vision = vision
        self.nameFixed = nameFixed
        _theme = State(initialValue: theme)
        _name = State(initialValue: name)
        let slots = ThemeSlot.named + (0..<16).map(ThemeSlot.ansi)
        _wide = State(initialValue: slots.contains { theme[$0].displayP3 != nil })
        fonts = PreviewFonts(preferences: TerminalRuntime.shared.preferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 10) {
                    TerminalPreview(theme: theme, fonts: fonts)
                    SlotGrid(theme: theme, selected: $slot)
                }.frame(width: 356)
                controls
            }.padding(.horizontal, 18).padding(.bottom, 16)
            footer
        }
        // As tall as the controls at the user's text size, as the maker.
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
        .background(Chrome.window)
        .foregroundStyle(Chrome.ink)
        .font(typography.font(offset: 0))
        .environment(\.appTypography, typography)
        .controlSize(.small)
        .tint(Chrome.accent)
        .preferredColorScheme(Chrome.colorScheme)
        .onChange(of: slot) { _, _ in target = nil; hexDraft = nil }
        .accessibilityIdentifier("theme-editor")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText).lineLimit(1)
            Text("Choose a color below the preview, then its hue, colorfulness and lightness.")
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
    }

    private var controls: some View {
        let color = theme[slot]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(slot.title).fontWeight(.semibold).accessibilityIdentifier("theme-editor-slot")
                Spacer()
                if color != original[slot] {
                    Button("Revert") { set(original[slot]) }.buttonStyle(.plain)
                        .font(typography.font(offset: -1.5)).foregroundStyle(Chrome.accent)
                        .help("Back to this color as the scheme had it")
                        .accessibilityIdentifier("theme-editor-revert")
                }
            }
            ColorDisc(color: held, displayP3: wide, swatch: color.swiftUI, pick: setHeld)
                .frame(width: ColorDisc.size, height: ColorDisc.size)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(slot.title)
                .accessibilityValue("\(color.hex), \(color.oklchText)")
            GradientSlider(title: "Lightness", value: Binding(get: { held.l }, set: { setHeld(OKLCH(l: $0, c: held.c, h: held.h)) }),
                           colors: stride(from: 0.0, through: 1, by: 0.1).map {
                               ThemeColor(oklch: OKLCH(l: $0, c: held.c, h: held.h), displayP3: wide).swiftUI
                           })
            HStack(spacing: 8) {
                ColorPicker(slot.title, selection: pickerColor, supportsOpacity: false).labelsHidden()
                TextField("#rrggbb", text: Binding(get: { hexDraft ?? color.hex }, set: { hexDraft = $0 }))
                    .textFieldStyle(.roundedBorder).font(typography.font(offset: -1, design: .monospaced))
                    .frame(width: 84)
                    .onSubmit(commitHex)
                    .accessibilityIdentifier("theme-editor-hex")
                Spacer(minLength: 0)
                Toggle(isOn: $wide) { Text("P3").font(typography.font(offset: -1)) }
                    .toggleStyle(.checkbox)
                    .help("Display P3: colors beyond sRGB for wide-color displays. Ghostty and other apps get the nearest sRGB colors.")
                    .accessibilityLabel("Display P3")
            }
            VStack(alignment: .leading, spacing: 2) {
                if let p3 = color.displayP3 { Text("P3 \(p3.hex)") }
                Text(color.oklchText).accessibilityIdentifier("theme-editor-oklch")
                Text(String(format: "%.1f:1 against %@", color.contrast(with: theme[slot.against]), slot.against.title.lowercased()))
            }.font(typography.font(offset: -1.5, design: .monospaced)).foregroundStyle(Chrome.muted).textSelection(.enabled)
            let problems = SchemeAudit.problems(name: name, theme: theme.text)
            if !problems.isEmpty {
                Label(problems.joined(separator: "; "), systemImage: "exclamationmark.triangle")
                    .font(typography.font(offset: -1.5)).foregroundStyle(Chrome.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("theme-editor-problems")
            }
        }.frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Chrome.palette.separator).frame(height: 1)
            HStack(spacing: 10) {
                Text("Name").font(typography.font(offset: -0.5)).foregroundStyle(Chrome.muted)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder).font(typography.font(offset: -0.5, design: .monospaced))
                    .frame(width: 200)
                    .disabled(nameFixed)
                    .onSubmit(commit)
                    .accessibilityIdentifier("theme-editor-name")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: commit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("theme-editor-save")
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }.background(Chrome.sidebar)
    }

    // MARK: - Editing

    /// The slot's color as the disc and Lightness hold it.
    private var held: OKLCH { target ?? theme[slot].oklch }

    private func setHeld(_ lch: OKLCH) {
        target = lch
        hexDraft = nil
        theme[slot] = ThemeColor(oklch: lch, displayP3: wide)
    }

    /// A color from elsewhere (Revert, the hex, the color picker): the disc follows it.
    private func set(_ color: ThemeColor) {
        target = nil
        hexDraft = nil
        theme[slot] = color
    }

    private func commitHex() {
        guard let draft = hexDraft else { return }
        if let color = ThemeColor(hex: draft) { set(color) } else { hexDraft = nil }
    }

    private var pickerColor: Binding<Color> {
        Binding(get: { theme[slot].swiftUI }, set: { color in
            guard let picked = ThemeColor(NSColor(color)) else { return }
            if picked.displayP3 != nil { wide = true }
            set(picked)
        })
    }

    private func commit() {
        commitHex()
        save(CustomThemes.sanitized(name), Self.saved(theme, vision: vision))
    }
}

/// The colors to choose from: the six named ones, then the 16 ANSI colors, normal above bright, each on the
/// background; the chosen one ringed.
private struct SlotGrid: View {
    let theme: TerminalTheme
    @Binding var selected: ThemeSlot
    @Environment(\.appTypography) private var typography

    var body: some View {
        VStack(spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(ThemeSlot.named, id: \.self) { slot in
                    Button { selected = slot } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(theme[slot].swiftUI).frame(width: 14, height: 14)
                                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(theme.foreground.swiftUI.opacity(0.25)) }
                            Text(slot.title).font(typography.font(offset: -2)).foregroundStyle(theme.foreground.swiftUI).lineLimit(1)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                            .overlay { ring(slot) }
                    }.buttonStyle(.plain)
                        .accessibilityLabel(slot.title).accessibilityAddTraits(selected == slot ? .isSelected : [])
                }
            }
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<8, id: \.self) { column in
                        let slot = ThemeSlot.ansi(row * 8 + column)
                        Button { selected = slot } label: {
                            RoundedRectangle(cornerRadius: 5).fill(theme[slot].swiftUI)
                                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(theme.foreground.swiftUI.opacity(0.1)) }
                                .frame(height: 20).padding(2).overlay { ring(slot) }
                        }.buttonStyle(.plain)
                            .help("\(slot.title) \(theme[slot].hex)")
                            .accessibilityLabel(slot.title).accessibilityAddTraits(selected == slot ? .isSelected : [])
                    }
                }
            }
        }.padding(8)
            .background(theme.background.swiftUI, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Chrome.border) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("theme-editor-slots")
    }

    @ViewBuilder private func ring(_ slot: ThemeSlot) -> some View {
        if selected == slot { RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.accent, lineWidth: 2) }
    }
}

/// A plain `OKLCHDisc` picker: hue and colorfulness at the color's lightness, the knob where the color is.
struct ColorDisc: View {
    let color: OKLCH
    let displayP3: Bool
    /// The color as stored, for the knob.
    let swatch: Color
    let pick: (OKLCH) -> Void
    static let size: CGFloat = 148
    @State private var cache = OKLCHDiscCache()
    @Environment(\.displayScale) private var scale

    var body: some View {
        let radius = Self.size / 2 - 2
        let image = cache.image(l: color.l, displayP3: displayP3, pixels: Int((radius * 2 * scale).rounded()))
        let fraction = OKLCHDisc.radius(chroma: color.c, hue: color.h, l: color.l, displayP3: displayP3)
        return Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            func circle(_ at: CGPoint, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
            }
            let field = circle(center, radius * (displayP3 ? 1 : OKLCHDisc.core))
            if let image {
                var clipped = context
                clipped.clip(to: field)
                clipped.draw(Image(decorative: image, scale: scale),
                             in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            context.stroke(field, with: .color(Chrome.border), lineWidth: 1)
            if displayP3 {
                context.stroke(circle(center, radius * OKLCHDisc.core), with: .color(.black.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [1, 2.5]))
            }
            let knob = OKLCHDisc.point(center: center, radius: radius, hue: color.h, fraction: fraction)
            var shadow = context
            shadow.addFilter(.shadow(color: .black.opacity(0.5), radius: 3, y: 1))
            shadow.fill(circle(knob, 8), with: .color(.white))
            context.fill(circle(knob, 6), with: .color(swatch))
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let at = OKLCHDisc.pick(drag.location, center: CGPoint(x: Self.size / 2, y: Self.size / 2), radius: radius)
            pick(OKLCH(l: color.l, c: OKLCHDisc.chroma(radius: at.fraction, hue: at.hue, l: color.l, displayP3: displayP3), h: at.hue))
        })
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            pick(OKLCH(l: color.l, c: color.c, h: ThemeGenerator.wrap(color.h + (direction == .increment ? 10 : -10))))
        }
    }
}
