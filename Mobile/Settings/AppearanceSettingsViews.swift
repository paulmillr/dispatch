import SwiftUI

/// Settings › Terminal › Font (G2): the Mac's terminal fonts in the Mac's order (the default and the system's, then
/// Dispatch's own after its separator), each with a sample line in it, then Ligatures, bold colours and the cursor.
/// Every choice reaches the open terminals at once (`TerminalStyle.changed`).
struct TerminalFontSettingsView: View {
    @Bindable var settings: MobileSettings

    var body: some View {
        // The samples draw in the bundled fonts.
        let _ = MobileFonts.register()
        List {
            Group {
                Section {
                    rows(TerminalFont.leading)
                }
                Section {
                    rows(TerminalFont.bundled)
                } footer: {
                    Text("Fonts bundled with Dispatch, as on the Mac.")
                }
                Section {
                    Toggle("Ligatures", isOn: $settings.ligatures)
                    Toggle("Bold text as bright colors", isOn: $settings.boldIsBright)
                    Picker("Cursor", selection: $settings.cursor) {
                        ForEach(TerminalCursorStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Blinking cursor", isOn: $settings.cursorBlink)
                }
            }
            // The cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Terminal font")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rows(_ fonts: [TerminalFont]) -> some View {
        ForEach(fonts) { font in
            Button {
                settings.terminalFont = font.name
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(font.name).font(.body).foregroundStyle(.primary)
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
            .accessibilityValue(font.system ? "system" : "")
            .accessibilityAddTraits(settings.terminalFont == font.name ? [.isButton, .isSelected] : .isButton)
        }
    }
}

/// Settings › Terminal › Color scheme: Ghostty's bundled themes and Dispatch's two, dark then light, each side by
/// `SchemeGroup`, each with a swatch of its background, text and colours. Dispatch's lead their groups: Dispatch (true
/// black) Dark · OLED, Dispatch Gray Dark · Graphite.
struct TerminalSchemeSettingsView: View {
    @Bindable var settings: MobileSettings
    @State private var schemes: [TerminalSchemes.Scheme] = []
    @State private var query = ""

    var body: some View {
        let listed = TerminalSchemes.listed(schemes, for: settings.colorVision)
        let shown = query.isEmpty ? listed : listed.filter { $0.title.localizedStandardContains(query) }
        let own = shown.filter { TerminalSchemes.dispatch[$0.file] != nil }
        let others = shown.filter { TerminalSchemes.dispatch[$0.file] == nil }
        List {
            Group {
                // Dispatch's are dark: each in its group's first rows.
                sections(own + others.filter { $0.side != true || SchemeGroup.bothSides.contains($0.file) }, light: false)
                sections(others.filter { $0.side != false || SchemeGroup.bothSides.contains($0.file) }, light: true)
                if settings.colorVision != .typical {
                    Section {} footer: {
                        Text("Colorblind-friendly lists only the schemes made for \(settings.colorVision.title.lowercased()) color blindness.")
                    }
                }
            }
            // The cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic))
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Color scheme")
        .navigationBarTitleDisplayMode(.inline)
        .task { if schemes.isEmpty { schemes = TerminalSchemes.all() } }
    }

    /// One side's schemes, a section per group: "Dark · OLED", "Light · Cream".
    private func sections(_ schemes: [TerminalSchemes.Scheme], light: Bool) -> some View {
        ForEach(light ? SchemeGroup.light : SchemeGroup.dark, id: \.self) { group in
            let shown = group.ordered(schemes.filter { Self.group($0, light: light) == group }, name: \.file)
            if !shown.isEmpty { Section("\(light ? "Light" : "Dark") · \(group.title)") { rows(shown) } }
        }
    }

    /// A scheme's section: Dispatch's by name (Dispatch is true black, Dispatch Gray a near-black grey), the rest by
    /// `SchemeGroup`.
    static func group(_ scheme: TerminalSchemes.Scheme, light: Bool) -> SchemeGroup {
        switch scheme.file {
        case "dispatch-black": .oled
        case "dispatch": .graphite
        default: scheme.group(light: light)
        }
    }

    private func rows(_ schemes: [TerminalSchemes.Scheme]) -> some View {
        ForEach(schemes) { scheme in
            Button {
                settings.terminalScheme = scheme.file
            } label: {
                HStack(spacing: 12) {
                    TerminalSchemeSwatch(scheme: scheme)
                    Text(scheme.title).foregroundStyle(.primary)
                    if SchemeGroup.classics[scheme.file] != nil {
                        Image(systemName: "star").font(.footnote).foregroundStyle(.secondary)
                    }
                    if !scheme.problems.isEmpty {
                        Image(systemName: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                    }
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
            .accessibilityValue(((SchemeGroup.classics[scheme.file] != nil ? ["classic"] : []) + scheme.problems)
                .joined(separator: "; "))
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
            // The cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
            .listRowBackground(Color.groupedRow)
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Chat font")
        .navigationBarTitleDisplayMode(.inline)
    }
}
