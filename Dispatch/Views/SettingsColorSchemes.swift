import AppKit
import SwiftUI

/// "Surprise me": a made scheme marked in its file, so the next surprise replaces it instead of piling up. Keep (or
/// saving it from the maker) drops the mark and it stays.
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

    /// A new random scheme on the `light` side for `vision`, saved in place of the last surprise; its name.
    static func make(light: Bool, vision: ColorVision, seed: UInt64) throws -> String {
        for entry in CustomThemes.list() where !entry.ghostty && isSurprise(entry.name) { try CustomThemes.delete(named: entry.name) }
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

/// Settings › Appearance › Style › Color schemes: the schemes you made, added or imported. Apply makes one the scheme
/// in use now; made schemes open in the maker again, a surprise can be kept, and any can go to the Trash.
struct YourColorSchemes: View {
    @Environment(\.appTypography) private var typography
    @Binding var draft: Preferences
    /// The schemes on disk changed: the pickers list them again.
    let schemesChanged: () -> Void
    /// Opens Extra, whose imports bring schemes from other terminals.
    let importSchemes: () -> Void
    /// The user's schemes, as Settings last listed them.
    let themes: [CustomThemes.Entry]
    @State private var making = false
    /// A made scheme being changed in the maker: saved back under its name.
    @State private var editing: (name: String, recipe: ThemeRecipe)?
    @State private var deleting: CustomThemes.Entry?
    @State private var message: String?

    /// The schemes for the current vision: made for that color blindness in colorblind mode, none of those otherwise.
    private var shown: [CustomThemes.Entry] { themes.filter { ColorSchemes.vision(of: $0.name) == draft.colorVision } }

    var body: some View {
        let shown = shown
        VStack(spacing: 0) {
            ForEach(shown, id: \.self) { entry in
                SettingsSeparator()
                row(entry)
            }
            if shown.count < themes.count {
                SettingsSeparator()
                Text(draft.colorVision == .typical
                     ? "\(themes.count - shown.count) made for color blindness, shown in colorblind mode"
                     : "\(themes.count - shown.count) not made for \(draft.colorVision.title.lowercased()) color blindness, hidden")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
            }
            if themes.isEmpty {
                SettingsSeparator()
                Text("none yet. Make one, add a theme file, or import one from another terminal.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
            }
            SettingsSeparator()
            HStack(spacing: 10) {
                Button("New…") { editing = nil; making = true }.accessibilityIdentifier("settings-new-theme")
                Button("Add File…") { addFile() }.accessibilityIdentifier("settings-add-theme")
                Button("Import…", action: importSchemes)
                    .help("From Ghostty, iTerm2, Terminal or a Dispatch export, in Extra")
                    .accessibilityIdentifier("settings-import-schemes")
                Spacer(minLength: 8)
                Button("Show in Finder") { showFolder() }.buttonStyle(.plain)
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }.padding(.vertical, 9)
            if let message {
                Text(message).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
                    .accessibilityIdentifier("settings-themes-message")
            }
        }
        .sheet(isPresented: $making, onDismiss: { editing = nil }) {
            ThemeMakerView(initial: editing?.recipe, vision: draft.colorVision, save: { name, theme in
                if let editing { save(.init(name: editing.name, theme: theme, role: .none, keepsName: true)) }
                else { save(.init(name: name, theme: theme, role: .none)) }
                making = false
            }, cancel: { making = false })
            .environment(\.appTypography, typography)
        }
        .alert("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { if let deleting { delete(deleting) } }
        } message: {
            Text("The theme file is moved to the Trash. A scheme that used it goes back to Match app theme.")
        }
    }

    private func row(_ entry: CustomThemes.Entry) -> some View {
        HStack(spacing: 10) {
            ThemeSwatch(theme: CustomThemes.theme(named: entry.name)).frame(width: 74, height: 18)
            let surprise = !entry.ghostty && SurpriseScheme.isSurprise(entry.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(typography.font(offset: -0.5)).lineLimit(1)
                Text([entry.light.map { $0 ? "light" : "dark" } ?? "light or dark", entry.ghostty ? "Ghostty’s" : nil,
                      surprise ? "surprise, replaced by the next" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }
            Spacer(minLength: 8)
            if surprise {
                Button("Keep") { keep(entry) }
                    .buttonStyle(.plain).font(typography.font(offset: -1.5)).fontWeight(.medium).foregroundStyle(Chrome.accent)
                    .help("Keep this scheme when the next surprise comes").accessibilityLabel("Keep \(entry.name)")
                    .accessibilityIdentifier("settings-theme-keep-\(entry.name)")
            }
            if inUse(entry) {
                Text("In use").font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            } else {
                Button("Apply") { apply(entry) }
                    .buttonStyle(.plain).font(typography.font(offset: -1.5)).fontWeight(.medium).foregroundStyle(Chrome.accent)
                    .help("Use this scheme now").accessibilityLabel("Apply \(entry.name)")
                    .accessibilityIdentifier("settings-theme-apply-\(entry.name)")
            }
            if !entry.ghostty, let recipe = CustomThemes.theme(named: entry.name).flatMap(ThemeRecipe.init(theme:)) {
                Button { editing = (entry.name, recipe); making = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).foregroundStyle(SettingsControlStyle.detail)
                    .help("Change this scheme in the maker").accessibilityLabel("Edit \(entry.name)")
            }
            if !entry.ghostty {
                Button { deleting = entry } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(SettingsControlStyle.detail)
                    .help("Delete this color scheme").accessibilityLabel("Delete \(entry.name)")
            }
        }.padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-theme-\(entry.name)")
    }

    private func inUse(_ entry: CustomThemes.Entry) -> Bool { draft.theme == entry.name || draft.lightTheme == entry.name }

    /// Makes the scheme the one showing now: with Automatic, the light or dark one it reads as (one that reads as
    /// either takes the system's current side); with a fixed app theme, that theme's side.
    private func apply(_ entry: CustomThemes.Entry) {
        let systemIsDark = SidebarThemeStore.systemIsDark
        let dark = draft.appTheme == .automatic ? entry.light.map { !$0 } ?? systemIsDark
            : draft.appTheme.isDark(systemIsDark: systemIsDark)
        if dark { draft.theme = entry.name } else { draft.lightTheme = entry.name }
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
