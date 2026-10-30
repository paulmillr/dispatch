import AppKit
import SwiftUI

/// Surprise me: a made scheme marked in its file, so the next surprise for its side replaces it instead of piling up. Keep
/// (or saving it from the maker) drops the mark and it stays.
enum SurpriseScheme {
    static let marker = "# dispatch-surprise"

    static func isSurprise(_ name: String) -> Bool {
        CustomThemes.theme(named: name)?.extra.contains(marker) ?? false
    }

    /// Every scheme name in use, the user's and the bundled ones.
    static func takenNames() -> Set<String> {
        let bundled = (try? FileManager.default.contentsOfDirectory(
            atPath: System.resources.appendingPathComponent("ghostty/themes").path)) ?? []
        return Set(bundled).union(CustomThemes.list().map(\.name))
    }

    /// A new random scheme on the `light` side for `vision`, saved in place of that side's last surprise (the other
    /// side's may be in use); its name.
    static func make(light: Bool, vision: ColorVision, seed: UInt64) throws -> String {
        for entry in CustomThemes.list() where !entry.ghostty && entry.light != !light && isSurprise(entry.name) {
            try CustomThemes.delete(named: entry.name)
        }
        var recipe = ThemeRecipe.random(seed: seed).with(vision: vision)
        recipe.light = light
        let name = ThemeGenerator.suggestedName(for: recipe, taken: takenNames())
        var theme = ThemeGenerator.make(recipe)
        theme.extra.append(marker)
        try CustomThemes.save(theme, named: name)
        return name
    }

    /// The surprise stays: the next one no longer replaces it.
    static func keep(_ name: String) throws {
        guard var theme = CustomThemes.theme(named: name) else { return }
        theme.extra.removeAll { $0 == marker }
        try CustomThemes.save(theme, named: name)
    }
}

/// Settings › Theme's color schemes: every scheme for each side in use (dark, then light, while the theme follows the
/// system), each drawn as a demo in its own colors, a click choosing it for that side. Yours lead, then the bundled
/// ones under their `SchemeGroup` headers (Dispatch first in OLED or White), then those that read as either side. Your own can be kept
/// (a surprise), changed in the maker or put in the Trash; New…, Add File…, Import… and each side's Surprise me add more.
/// Any scheme can be duplicated and edited (its hover button or context menu): a made one's copy in the maker, any
/// other's color by color in the editor; yours can be edited in place the same way.
struct ColorSchemeGallery: View {
    @Environment(\.appTypography) private var typography
    @Binding var draft: Preferences
    /// The schemes Settings lists, for the current vision.
    let schemes: ColorSchemes
    /// The sides shown, light (true) or dark, in order.
    let sides: [Bool]
    /// Dispatch's colors on the light (true) or dark side: dispatch-black under the app theme's palette.
    let matching: (Bool) -> TerminalTheme?
    /// The schemes on disk changed: list them again.
    let schemesChanged: () -> Void
    /// Opens Extra, whose imports bring schemes from other terminals.
    let importSchemes: () -> Void
    /// Surprise me: a random scheme for the light (true) or dark side, used at once.
    let surprise: (Bool) -> Void
    /// The user's schemes in any vision, for the count of those hidden in this one.
    let allCustom: Int
    /// The maker or the color editor, open over Settings.
    @State private var sheet: SchemeSheet?
    /// The tile under the pointer (side and name), which shows its duplicate button.
    @State private var hoveredTile: String?
    @State private var deleting: CustomThemes.Entry?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(sides, id: \.self) { light in side(light) }
            SettingsGroup(title: "Your color schemes") {
                SettingsSeparator()
                HStack(spacing: 10) {
                    Button("New…") { sheet = SchemeSheet(kind: .maker(nil), title: "New color scheme") }
                        .accessibilityIdentifier("settings-new-theme")
                    Button("Add File…") { addFile() }.accessibilityIdentifier("settings-add-theme")
                    Button("Import…", action: importSchemes)
                        .help("From Ghostty, iTerm2, Terminal or a Dispatch export, in Extra")
                        .accessibilityIdentifier("settings-import-schemes")
                    Spacer(minLength: 8)
                    Button("Show in Finder") { showFolder() }.buttonStyle(.plain)
                        .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                }.padding(.vertical, 9)
                if allCustom > schemes.custom.count {
                    Text(draft.colorVision == .typical
                         ? "\(allCustom - schemes.custom.count) made for color blindness, shown in colorblind mode"
                         : "\(allCustom - schemes.custom.count) not made for \(draft.colorVision.title.lowercased()) color blindness, hidden")
                        .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
                }
                if let message {
                    Text(message).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
                        .accessibilityIdentifier("settings-themes-message")
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet.kind {
                case .maker(let recipe):
                    ThemeMakerView(initial: recipe, vision: draft.colorVision, title: sheet.title, name: sheet.name,
                                   nameFixed: sheet.replacing != nil, save: { finish(sheet, name: $0, theme: $1) },
                                   cancel: { self.sheet = nil })
                case .colors(let theme):
                    ThemeEditorView(theme: theme, vision: draft.colorVision, title: sheet.title, name: sheet.name ?? "",
                                    nameFixed: sheet.replacing != nil, save: { finish(sheet, name: $0, theme: $1) },
                                    cancel: { self.sheet = nil })
                }
            }.environment(\.appTypography, typography)
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { if let deleting { delete(deleting) } }
        } message: {
            Text("The theme file is moved to the Trash. A scheme that used it goes back to Dispatch.")
        }
    }

    private func selection(_ light: Bool) -> Binding<String> { light ? $draft.lightTheme : $draft.theme }

    /// One side: the scheme in use and Surprise me, then the tiles under their headers.
    private func side(_ light: Bool) -> some View {
        let chosen = selection(light).wrappedValue
        let missing = chosen != "Default" && ThemeResolution.value(for: chosen).missing
        return SettingsGroup(title: sides.count > 1 ? (light ? "Light color scheme" : "Dark color scheme") : "Color scheme") {
            SettingsSeparator()
            HStack(spacing: 12) {
                Text(missing ? "“\(chosen)” not found; using Dispatch’s own" : chosen == "Default" ? "Dispatch" : SchemeGroup.title(chosen))
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail).lineLimit(1)
                    .accessibilityIdentifier("settings-scheme-in-use-\(light ? "light" : "dark")")
                Spacer(minLength: 8)
                Button { surprise(light) } label: { Label("Surprise me", systemImage: "dice") }
                    .help("Make a random \(light ? "light" : "dark") scheme and use it; the next one replaces it unless you keep it")
                    .accessibilityIdentifier("settings-surprise-scheme-\(light ? "light" : "dark")")
            }.padding(.vertical, 9)
            ForEach(sections(light), id: \.title) { section in
                if !section.title.isEmpty {
                    Text(section.title).font(typography.font(offset: -1.5)).fontWeight(.semibold)
                        .foregroundStyle(SettingsControlStyle.detail)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 6)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(section.names, id: \.self) { tile($0, light: light) }
                }
            }
            Spacer().frame(height: 10)
        }
    }

    /// Yours, the bundled ones by group, then those that read as either side. Dispatch, the Default tile, leads OLED or
    /// White (typical vision only: its colors aren't made for color blindness), so dispatch-black isn't listed again
    /// unless it is chosen by name.
    private func sections(_ light: Bool) -> [(title: String, names: [String])] {
        var result: [(title: String, names: [String])] = []
        let yours = schemes.custom.filter { $0.light == nil || $0.light == light }.map(\.name)
        if !yours.isEmpty { result.append(("Yours", yours)) }
        let side = (light ? schemes.light : schemes.dark)
            .filter { $0 != "dispatch-black" || selection(light).wrappedValue == $0 }
        for group in light ? SchemeGroup.light : SchemeGroup.dark {
            let own = draft.colorVision == .typical && group == (light ? .white : .oled) ? ["Default"] : []
            let names = own + group.ordered(side.filter { schemes.groups[$0] == group }) { $0 }
            if !names.isEmpty { result.append((group.title, names)) }
        }
        if !schemes.either.isEmpty { result.append(("Light or dark", schemes.either)) }
        return result
    }

    private func tile(_ name: String, light: Bool) -> some View {
        let selected = selection(light).wrappedValue == name
        let entry = schemes.custom.first { $0.name == name }
        let problems = schemes.problems[name] ?? []
        // A bundled classic, never your own scheme of the same name; Dispatch is one.
        let history = entry == nil ? SchemeGroup.classics[name == "Default" ? "dispatch-black" : name] : nil
        let notes = (history.map { [$0] } ?? []) + problems
        return Button { selection(light).wrappedValue = name } label: {
            SchemeDemo(title: name == "Default" ? "Dispatch" : SchemeGroup.title(name),
                       theme: name == "Default" ? matching(light) : schemes.themes[name],
                       selected: selected, fontFamily: draft.fontFamily, classic: history != nil, problems: problems)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            let key = "\(light)/\(name)"
            if inside { hoveredTile = key } else if hoveredTile == key { hoveredTile = nil }
        }
        .overlay(alignment: .topTrailing) {
            if let entry { actions(entry, light: light) }
            else if hoveredTile == "\(light)/\(name)" { duplicateButton(name, light: light).modifier(TileActions(ink: tileInk(name, light: light))) }
        }
        .contextMenu {
            Button("Duplicate and Edit…") { duplicate(name, light: light) }
            if let entry, !entry.ghostty {
                Button("Edit…") { edit(entry, colors: false) }
                if ThemeRecipe(theme: schemes.themes[name] ?? TerminalTheme()) != nil {
                    Button("Edit Colors…") { edit(entry, colors: true) }
                }
                Divider()
                Button("Delete…") { deleting = entry }
            }
        }
        .help(name == "Default" ? "Dispatch's own colors, made alongside the app and following its theme"
              : notes.isEmpty ? SchemeGroup.title(name) : "\(SchemeGroup.title(name)): \(notes.joined(separator: "; "))")
        .accessibilityLabel(name == "Default" ? "Dispatch" : SchemeGroup.title(name))
        .accessibilityValue(notes.joined(separator: "; "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings-scheme-\(light ? "light" : "dark")-\(name)")
    }

    /// Your scheme's own buttons on its tile: Keep for a surprise, Edit (the maker for a made one, else the color
    /// editor), Duplicate and Edit, and the Trash. Ghostty's own schemes are only read, so they can only be duplicated.
    private func actions(_ entry: CustomThemes.Entry, light: Bool) -> some View {
        HStack(spacing: 8) {
            if !entry.ghostty && SurpriseScheme.isSurprise(entry.name) {
                Button("Keep") { keep(entry) }.buttonStyle(.plain).font(typography.font(offset: -2)).fontWeight(.semibold)
                    .help("Keep this scheme when the next random one comes").accessibilityLabel("Keep \(entry.name)")
                    .accessibilityIdentifier("settings-theme-keep-\(entry.name)")
            }
            if !entry.ghostty {
                let made = ThemeRecipe(theme: schemes.themes[entry.name] ?? TerminalTheme()) != nil
                Button { edit(entry, colors: false) } label: { Image(systemName: made ? "slider.horizontal.3" : "paintpalette") }
                    .buttonStyle(.plain).help(made ? "Change this scheme in the maker" : "Change this scheme's colors")
                    .accessibilityLabel("Edit \(entry.name)")
                    .accessibilityIdentifier("settings-theme-edit-\(entry.name)")
            }
            duplicateButton(entry.name, light: light)
            if !entry.ghostty {
                Button { deleting = entry } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete this color scheme").accessibilityLabel("Delete \(entry.name)")
            }
        }.modifier(TileActions(ink: tileInk(entry.name, light: light)))
    }

    private func duplicateButton(_ name: String, light: Bool) -> some View {
        Button { duplicate(name, light: light) } label: { Image(systemName: "plus.square.on.square") }
            .buttonStyle(.plain).help("Duplicate and edit this scheme")
            .accessibilityLabel("Duplicate and edit \(name == "Default" ? "Dispatch" : SchemeGroup.title(name))")
            .accessibilityIdentifier("settings-theme-duplicate-\(light ? "light" : "dark")-\(name)")
    }

    /// A tile's scheme: Dispatch's for the side, else the listed one.
    private func theme(of name: String, light: Bool) -> TerminalTheme? {
        name == "Default" ? matching(light) : schemes.themes[name]
    }

    /// The tile's text color, which its buttons are drawn in.
    private func tileInk(_ name: String, light: Bool) -> ThemeColor {
        (theme(of: name, light: light) ?? TerminalTheme()).foreground
    }

    /// A copy under a free name, in the maker when the scheme was made there, else in the color editor; saved as a
    /// new scheme, which takes over a side the original was chosen for.
    private func duplicate(_ name: String, light: Bool) {
        guard let theme = theme(of: name, light: light) else { return }
        let title = name == "Default" ? "Dispatch" : SchemeGroup.title(name)
        let copy = CustomThemes.uniqueName("\(title) copy", taken: SurpriseScheme.takenNames())
        let kind: SchemeSheet.Kind = ThemeRecipe(theme: theme).map { .maker($0) } ?? .colors(theme)
        sheet = SchemeSheet(kind: kind, title: "Copy of \(title)", name: copy, selects: sides.filter { selection($0).wrappedValue == name })
    }

    /// Your scheme changed in place under its name: a made one in the maker unless `colors`, any other in the editor.
    private func edit(_ entry: CustomThemes.Entry, colors: Bool) {
        guard let theme = CustomThemes.theme(named: entry.name) else { return }
        let recipe = colors ? nil : ThemeRecipe(theme: theme)
        sheet = SchemeSheet(kind: recipe.map { .maker($0) } ?? .colors(theme), title: "Edit “\(entry.name)”",
                            name: entry.name, replacing: entry.name)
    }

    /// Saves what the sheet made: in place of the scheme it changed, else as a new one, chosen where its original was.
    private func finish(_ done: SchemeSheet, name: String, theme: TerminalTheme) {
        let saved = done.replacing.map { save(.init(name: $0, theme: theme, role: .none, keepsName: true)) }
            ?? save(.init(name: name, theme: theme, role: .none))
        if let saved { for light in done.selects { selection(light).wrappedValue = saved } }
        sheet = nil
    }

    private func keep(_ entry: CustomThemes.Entry) {
        do { try SurpriseScheme.keep(entry.name) } catch { message = "Could not keep “\(entry.name)”: \(error.localizedDescription)" }
        schemesChanged()
    }

    @discardableResult
    private func save(_ theme: ImportPlan.Theme) -> String? {
        do {
            let name = try Self.save(theme)
            schemesChanged()
            return name
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Saves under a free name unless the theme keeps its own; the name used.
    static func save(_ theme: ImportPlan.Theme) throws -> String {
        let bundled = Set((try? FileManager.default.contentsOfDirectory(
            atPath: System.resources.appendingPathComponent("ghostty/themes").path)) ?? [])
        let name = theme.keepsName ? CustomThemes.sanitized(theme.name) : CustomThemes.uniqueName(theme.name, taken: bundled)
        do { try CustomThemes.save(theme.theme, named: name) } catch {
            throw SaveError(description: "Could not save “\(name)”: \(error.localizedDescription)")
        }
        return name
    }

    private struct SaveError: LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.message = "Choose Ghostty theme files or iTerm2 .itermcolors files."
        guard panel.runModal() == .OK else { return }
        var added = 0, unreadable: [String] = []
        for url in panel.urls {
            let name = url.deletingPathExtension().lastPathComponent
            if let theme = Self.theme(from: url) { if save(.init(name: name, theme: theme, role: .none)) != nil { added += 1 } }
            else { unreadable.append(url.lastPathComponent) }
        }
        message = (added > 0 ? "Added \(added) color scheme\(added == 1 ? "" : "s"). " : "")
            + (unreadable.isEmpty ? "" : "Not a color scheme: \(unreadable.joined(separator: ", ")).")
    }

    /// A Ghostty theme file, or an iTerm2 color preset (a plist of iTerm2's color keys).
    static func theme(from url: URL) -> TerminalTheme? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let colors = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           ITermImport.color(colors["Background Color"]) != nil {
            return ITermImport.theme(colors, suffix: "")
        }
        return String(data: data, encoding: .utf8).flatMap(TerminalTheme.init(text:))
    }

    private func delete(_ entry: CustomThemes.Entry) {
        do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil) } catch {
            message = "Could not delete “\(entry.name)”: \(error.localizedDescription)"
            return
        }
        if draft.theme == entry.name { draft.theme = "Default" }
        if draft.lightTheme == entry.name { draft.lightTheme = "Default" }
        deleting = nil
        schemesChanged()
    }

    private func showFolder() {
        try? FileManager.default.createDirectory(at: CustomThemes.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CustomThemes.directory)
    }
}

/// What the scheme sheet shows: the maker (new, or a made scheme's recipe) or the color editor, for a new scheme or one
/// of yours changed in place.
struct SchemeSheet: Identifiable {
    enum Kind {
        case maker(ThemeRecipe?)
        case colors(TerminalTheme)
    }
    let id = System.uuid()
    let kind: Kind
    let title: String
    /// The name it opens with; nil lets the maker suggest one.
    var name: String?
    /// Your scheme it saves over; nil saves a new one.
    var replacing: String?
    /// The sides (light true) whose choice moves to the new scheme: its original was chosen there.
    var selects: [Bool] = []
}

/// A tile's buttons, drawn in the tile's text color at its top right.
private struct TileActions: ViewModifier {
    let ink: ThemeColor

    func body(content: Content) -> some View {
        content.font(.system(size: 10.5)).foregroundStyle(ink.swiftUI.opacity(0.7))
            .padding(.top, 9).padding(.trailing, 30)
    }
}

/// A color scheme drawn in its own colors: its name, then lorem ipsum as wide as the tile in every color it sets, the 16
/// ANSI colors (0 behind "et"), the foreground, the selection ("dolore") and the cursor.
struct SchemeDemo: View {
    let title: String
    let theme: TerminalTheme?
    let selected: Bool
    /// The terminal's font.
    let fontFamily: String
    /// A classic (SchemeGroup.classics): a star after the title.
    var classic = false
    /// What SchemeAudit found: a warning sign after the title (the tile's tooltip says what).
    var problems: [String] = []
    @State private var hovered = false

    /// xterm's colors, for a scheme that leaves one to the terminal.
    static let standard: [ThemeColor] = ["000000", "cd0000", "00cd00", "cdcd00", "0000ee", "cd00cd", "00cdcd", "e5e5e5",
                                         "7f7f7f", "ff0000", "00ff00", "ffff00", "5c5cff", "ff00ff", "00ffff", "ffffff"]
        .compactMap { ThemeColor(hex: $0) }

    var body: some View {
        let theme = theme ?? TerminalTheme()
        let ink = color(theme.foreground)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                if classic {
                    Image(systemName: "star").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.75)).accessibilityLabel("Classic")
                }
                if !problems.isEmpty {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.75)).accessibilityLabel("Problems: \(problems.joined(separator: "; "))")
                }
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Chrome.accent) }
                Spacer(minLength: 0)
            }.padding(.bottom, 5)
            // One text, so its lines scale together: the longest fills the tile's width, up to 18 points.
            Text(lines(theme).reduce(AttributedString()) { $0.characters.isEmpty ? $1 : $0 + AttributedString("\n") + $1 })
                .font(.custom(fontFamily, fixedSize: 18)).lineSpacing(1).lineLimit(4).minimumScaleFactor(0.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(theme.background), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Chrome.accent : hovered ? Chrome.palette.secondary : Chrome.border, lineWidth: selected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
    }

    private func lines(_ theme: TerminalTheme) -> [AttributedString] {
        func ansi(_ index: Int) -> ThemeColor { theme.palette[index] ?? Self.standard[index] }
        func run(_ text: String, _ ink: ThemeColor, behind: ThemeColor? = nil) -> AttributedString {
            var run = AttributedString(text)
            run.foregroundColor = color(ink)
            if let behind { run.backgroundColor = color(behind) }
            return run
        }
        let space = AttributedString(" ")
        return [
            run("Lorem", theme.foreground) + space + run("ipsum", ansi(1)) + space + run("dolor", ansi(2)) + space
                + run("sit", ansi(3)) + space + run("amet", ansi(4)),
            run("consectetur", ansi(5)) + space + run("adipiscing", ansi(6)) + space + run("elit", ansi(7)),
            run("sed", ansi(9)) + space + run("do", ansi(10)) + space + run("eiusmod", ansi(11)) + space
                + run("tempor", ansi(12)) + space + run("ut", ansi(13)),
            run("labore", ansi(14)) + space + run("et", ansi(15), behind: ansi(0)) + space
                + run("dolore", theme.selectionForeground ?? theme.foreground, behind: theme.selectionBackground ?? ansi(8)) + space
                + run("magna", ansi(8)) + space + run(" ", theme.cursorText ?? theme.background, behind: theme.cursor ?? theme.foreground),
        ]
    }

    private func color(_ c: ThemeColor) -> Color { c.swiftUI }
}
