import SwiftUI

/// Settings › Terminal › Font (G2): the bundled monospaced fonts, each with a sample line in it, then bold colours and
/// the cursor. Every choice reaches the open terminals at once (`TerminalStyle.changed`).
struct TerminalFontSettingsView: View {
    @Bindable var settings: MobileSettings

    var body: some View {
        // The samples draw in the bundled fonts.
        let _ = MobileFonts.register()
        List {
            Group {
                Section {
                    ForEach(TerminalFont.all) { font in
                        Button {
                            settings.terminalFont = font.name
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(font.name).font(.body).foregroundStyle(.primary)
                                        if font.ligatures { Text("ligatures").font(.caption).foregroundStyle(.secondary) }
                                        if font.system { Text("system").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Text(TerminalFont.sample)
                                        .font(.custom(font.name, size: 13, relativeTo: .footnote))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if settings.terminalFont == font.name {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(font.name)
                        .accessibilityValue(font.ligatures ? "ligatures" : font.system ? "system" : "")
                        .accessibilityAddTraits(settings.terminalFont == font.name ? [.isButton, .isSelected] : .isButton)
                    }
                } footer: {
                    Text("Fonts bundled with Dispatch. Ligatures follow the font.")
                }
                Section {
                    Toggle("Bold text as bright colors", isOn: $settings.boldIsBright)
                    Picker("Cursor", selection: $settings.cursor) {
                        ForEach(TerminalCursorStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Blinking cursor", isOn: $settings.cursorBlink)
                }
            }
            // The theme's cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Terminal font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Terminal › Color scheme: Dispatch's two, then Ghostty's bundled themes by dark and light, each with a
/// swatch of its background, text and colours. The terminal's scheme alone: the app's theme does not change it.
struct TerminalSchemeSettingsView: View {
    @Bindable var settings: MobileSettings
    @State private var schemes: [TerminalSchemes.Scheme] = []
    @State private var query = ""

    var body: some View {
        let shown = query.isEmpty ? schemes : schemes.filter { $0.title.localizedStandardContains(query) }
        let own = shown.filter { TerminalSchemes.dispatch[$0.file] != nil }
        let others = shown.filter { TerminalSchemes.dispatch[$0.file] == nil }
        List {
            Group {
                if !own.isEmpty { Section("Dispatch") { rows(own) } }
                if others.contains(where: \.isDark) { Section("Dark") { rows(others.filter(\.isDark)) } }
                if others.contains(where: { !$0.isDark }) { Section("Light") { rows(others.filter { !$0.isDark }) } }
            }
            // The theme's cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Color scheme")
        .navigationBarTitleDisplayMode(.inline)
        .task { if schemes.isEmpty { schemes = TerminalSchemes.all() } }
    }

    private func rows(_ schemes: [TerminalSchemes.Scheme]) -> some View {
        ForEach(schemes) { scheme in
            Button {
                settings.terminalScheme = scheme.file
            } label: {
                HStack(spacing: 12) {
                    TerminalSchemeSwatch(scheme: scheme)
                    Text(scheme.title).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    if settings.terminalScheme == scheme.file {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(scheme.title)
            .accessibilityAddTraits(settings.terminalScheme == scheme.file ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// A scheme's background with its text colour and red to cyan.
struct TerminalSchemeSwatch: View {
    let scheme: TerminalSchemes.Scheme

    var body: some View {
        HStack(spacing: 3) {
            Text("Aa").font(.caption.monospaced().weight(.semibold)).foregroundStyle(color(scheme.foreground))
            ForEach(Array(scheme.accents.enumerated()), id: \.offset) { _, rgb in
                Circle().fill(color(rgb)).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .background(color(scheme.background), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func color(_ rgb: TerminalSchemes.RGB) -> Color { Color(red: rgb.red, green: rgb.green, blue: rgb.blue) }
}

/// Settings › Chat › Font (G3): the Mac's three fonts, each with a sample bubble in it, and the text size relative to
/// Dynamic Type. Code blocks and paths keep the terminal's font.
struct ChatFontSettingsView: View {
    @Bindable var settings: MobileSettings

    var body: some View {
        let typography = ChatTypography(font: settings.chatFont, size: settings.chatTextSize,
                                        terminalFont: TerminalFont.named(settings.terminalFont))
        List {
            Group {
                Section {
                    ForEach(MobileChatFont.allCases) { choice in
                        Button {
                            settings.chatFont = choice
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(choice.rawValue).font(.body).foregroundStyle(.primary)
                                    Text(choice.sample(terminalFont: typography.terminalFont.name, size: Int(typography.size.points)))
                                        .font(typography.drawn(choice))
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(Color.bubbleAgent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if settings.chatFont == choice {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(choice.rawValue)
                        .accessibilityAddTraits(settings.chatFont == choice ? [.isButton, .isSelected] : .isButton)
                    }
                } footer: {
                    Text("Code blocks and paths always use the terminal font.")
                }
                Section {
                    Picker("Text size", selection: $settings.chatTextSize) {
                        ForEach(ChatTextSize.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Relative to Dynamic Type.")
                }
            }
            // The theme's cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Chat font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Appearance › Theme (G4): the themes as tiles in two columns, each drawn in its own palette.
struct ThemeSettingsView: View {
    @Bindable var settings: MobileSettings

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(MobileTheme.allCases) { theme in
                    ThemeTile(theme: theme, selected: settings.theme == theme) { settings.theme = theme }
                }
            }
            .padding(16)
            Text("Themes color the app's chrome and chat. The terminal keeps its own color scheme.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
        }
        .background(Color.canvas)
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One theme's tile: a small window in its canvas with its accent and two lines of text, its name and what it is.
struct ThemeTile: View {
    let theme: MobileTheme
    let selected: Bool
    let select: () -> Void

    var body: some View {
        let palette = theme.palette
        // Automatic is drawn in the catalog's own colours, whatever theme is chosen now.
        let canvas = palette.map { Color(uiColor: $0.canvas) } ?? Color("Canvas")
        let accent = palette.map { Color(uiColor: $0.accent) } ?? Color("AccentColor")
        let line = palette.map { Color(uiColor: $0.line) } ?? Color.primary.opacity(0.18)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(canvas)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(accent).frame(width: 60, height: 10)
                        Capsule().fill(line).frame(width: 90, height: 8)
                        Capsule().fill(line).frame(width: 70, height: 8)
                    }
                    .padding(12)
                }
                .frame(height: 96)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.dispatchPink : Color.hairline, lineWidth: selected ? 2 : 1))
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(theme.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(theme.subtitle).font(.caption).foregroundStyle(.secondary).fittingLine()
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dispatchPink) }
                }
            }
            .padding(10)
            .background(Color.groupedRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(theme.title)
        .accessibilityValue(theme.subtitle)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
