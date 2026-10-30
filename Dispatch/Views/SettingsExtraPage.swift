import AppKit
import SwiftUI

/// Settings › Extra: bring settings and color schemes in from other terminals, and take everything to another Mac.
/// Imports show what they'd change first; nothing is applied until confirmed. Troubleshooting follows it on the page.
struct SettingsExtraPage: View {
    @Environment(\.appTypography) private var typography
    @Binding var draft: Preferences
    /// The schemes on disk changed: the pickers list them again.
    let schemesChanged: () -> Void
    /// iTerm2's and Terminal's preferences on this Mac; tests pass fixtures.
    var loadITerm: () -> [String: Any]? = ITermImport.load
    var loadTerminal: () -> [String: Any]? = TerminalAppImport.load
    @State private var plan: ImportPlan?
    @State private var message: String?
    /// The other terminals' preferences on this Mac, read when the page opens.
    @State private var iterm: [String: Any]?
    @State private var terminal: [String: Any]?
    @State private var itermProfile: ImportPlan.Profile?
    @State private var terminalProfile: ImportPlan.Profile?

    var body: some View {
        VStack(spacing: 8) {
            importGroup
            exportGroup
            if let message {
                Text(message).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    .accessibilityIdentifier("settings-extra-message")
            }
        }
        .onAppear {
            iterm = loadITerm()
            terminal = loadTerminal()
            itermProfile = iterm.flatMap { ITermImport.profiles(in: $0).first }
            terminalProfile = terminal.flatMap { TerminalAppImport.profiles(in: $0).first }
        }
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            ImportReviewSheet(plan: box.plan, cancel: { plan = nil }) { changes in
                apply(box.plan, changes: changes)
                plan = nil
            }
            .environment(\.appTypography, typography)
        }
    }

    // MARK: Import

    /// Dispatch's own export first, then the other terminals: Terminal, iTerm2, Ghostty.
    private var importGroup: some View {
        SettingsGroup(title: "Import") {
            SettingsRow(title: "Dispatch", detail: "settings and themes from Export, on this or another Mac") {
                Button("Choose…") { chooseExport() }.accessibilityIdentifier("settings-import-dispatch")
            }
            profileRow("Terminal", preferences: terminal, profiles: terminal.map(TerminalAppImport.profiles(in:)) ?? [], selection: $terminalProfile) { profile in
                terminal.map { TerminalAppImport.plan(preferences: $0, profile: profile.id, fonts: SettingsView.terminalFontFamilies) }
            }
            profileRow("iTerm2", preferences: iterm, profiles: iterm.map(ITermImport.profiles(in:)) ?? [], selection: $itermProfile) { profile in
                iterm.map { ITermImport.plan(preferences: $0, profile: profile.id, fonts: SettingsView.terminalFontFamilies) }
            }
            let ghostty = GhosttyImport.configURL
            SettingsRow(title: "Ghostty", detail: ghostty.map { "its config, " + $0.path.replacingOccurrences(of: System.home.path, with: "~") }
                        ?? "no Ghostty config on this Mac") {
                Button("Import…") { if let plan = GhosttyImport.plan() { review(plan) } }
                    .disabled(ghostty == nil).accessibilityIdentifier("settings-import-ghostty")
            }
        }
    }

    /// An app with profiles: which one (the default first), then Import….
    private func profileRow(_ app: String, preferences: [String: Any]?, profiles: [ImportPlan.Profile],
                            selection: Binding<ImportPlan.Profile?>, plan: @escaping (ImportPlan.Profile) -> ImportPlan?) -> some View {
        SettingsRow(title: app, detail: preferences == nil ? "no \(app) settings on this Mac" : "a profile’s look, keys and shell") {
            HStack(spacing: 8) {
                if profiles.count > 1 {
                    SettingsDropdown(title: "\(app) profile", selection: Binding(
                        get: { selection.wrappedValue.map(title) ?? "" },
                        set: { chosen in selection.wrappedValue = profiles.first { title($0) == chosen } }),
                        choices: profiles.map(title), fontName: nil, fontScale: nil)
                        // Gives way before the button does: a long profile name truncates, Import… never.
                        .frame(minWidth: typography.expanded(110), idealWidth: typography.expanded(150),
                               maxWidth: typography.expanded(150))
                        .frame(height: typography.expanded(27))
                }
                Button("Import…") { if let profile = selection.wrappedValue, let next = plan(profile) { review(next) } }
                    .fixedSize()
                    .disabled(selection.wrappedValue == nil)
                    .accessibilityIdentifier("settings-import-\(app.lowercased())")
            }
        }
    }

    private func title(_ profile: ImportPlan.Profile) -> String { profile.isDefault ? "\(profile.name) (default)" : profile.name }

    /// The review sheet for a plan, or why there's nothing to import.
    private func review(_ next: ImportPlan) {
        if next.isEmpty {
            message = "Nothing in \(next.source) that Dispatch can use" + (next.skipped.isEmpty ? "." : ": " + next.skipped.joined(separator: "; ") + ".")
        } else { plan = next }
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose a folder made by Export, or its dispatch-settings.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { review(try SettingsExport.plan(from: url)) } catch { message = "Could not read \(url.lastPathComponent): \(error.localizedDescription)" }
    }

    /// Saves the plan's themes, points the schemes at them by role, then applies the chosen changes.
    private func apply(_ plan: ImportPlan, changes: Set<UUID>) {
        var next = draft
        for change in plan.changes where changes.contains(change.id) { change.apply(&next) }
        var saved: [String] = [], failed: [String] = []
        for theme in plan.themes {
            let name: String
            do { name = try ColorSchemeGallery.save(theme) } catch { failed.append(error.localizedDescription); continue }
            saved.append(name)
            switch theme.role {
            case .light: next.lightTheme = name
            case .dark: next.theme = name
            case .both: next.lightTheme = name; next.theme = name
            case .none: break
            }
        }
        draft = next
        if !saved.isEmpty { schemesChanged() }
        let parts = [changes.isEmpty ? nil : "\(changes.count) setting\(changes.count == 1 ? "" : "s")",
                     saved.isEmpty ? nil : "\(saved.count) theme\(saved.count == 1 ? "" : "s")"].compactMap { $0 }
        message = ([parts.isEmpty ? nil : "Imported \(parts.joined(separator: " and ")) from \(plan.source)."] + failed)
            .compactMap { $0 }.joined(separator: " ")
    }

    // MARK: Export

    private var exportGroup: some View {
        SettingsGroup(title: "Export") {
            SettingsRow(title: "Export settings", detail: "a folder: Ghostty config, color schemes, settings") {
                Button("Export…") { export() }.accessibilityIdentifier("settings-export")
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Dispatch Settings"
        panel.message = "Dispatch makes a folder with config, themes/ and dispatch-settings.json."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let themes = try SettingsExport.write(draft, to: url)
            message = "Exported to \(url.path.replacingOccurrences(of: System.home.path, with: "~"))"
                + (themes.isEmpty ? "." : " with \(themes.count) color scheme\(themes.count == 1 ? "" : "s").")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { message = "Could not export: \(error.localizedDescription)" }
    }
}

/// `sheet(item:)` needs an identity; a plan is shown once.
private struct PlanBox: Identifiable {
    let id = System.uuid()
    let plan: ImportPlan
}

/// A scheme at a glance: its background with the six ANSI colors and the text color on it.
struct ThemeSwatch: View {
    let theme: TerminalTheme?

    var body: some View {
        let theme = theme ?? TerminalTheme()
        let colors = ([1, 2, 3, 4, 5, 6].compactMap { theme.palette[$0] } + [theme.foreground]).map(Self.color)
        HStack(spacing: 2) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Capsule().fill(color).frame(width: 6, height: 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.color(theme.background), in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Chrome.border) }
        .accessibilityHidden(true)
    }

    static func color(_ c: ThemeColor) -> Color { Color(.sRGB, red: c.components.0, green: c.components.1, blue: c.components.2) }
}

/// What an import would change, each setting with its own checkbox; themes are always saved (they change nothing
/// until chosen), and what can't come along is listed so nothing silently goes missing.
struct ImportReviewSheet: View {
    @Environment(\.appTypography) private var typography
    let plan: ImportPlan
    let cancel: () -> Void
    let apply: (Set<UUID>) -> Void
    @State private var chosen: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import from \(plan.source)").font(typography.font(offset: 2)).fontWeight(.semibold)
                Text("Choose what to bring over. Nothing changes until you import.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.changes.isEmpty {
                        section("Settings") {
                            ForEach(plan.changes) { change in
                                Toggle(isOn: Binding(get: { chosen.contains(change.id) },
                                                     set: { if $0 { chosen.insert(change.id) } else { chosen.remove(change.id) } })) {
                                    HStack(spacing: 6) {
                                        Text(change.setting)
                                        Text(change.value).foregroundStyle(SettingsControlStyle.detail).lineLimit(1).truncationMode(.middle)
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }
                    }
                    if !plan.themes.isEmpty {
                        section("Color schemes") {
                            ForEach(Array(plan.themes.enumerated()), id: \.offset) { _, theme in
                                HStack(spacing: 10) {
                                    ThemeSwatch(theme: theme.theme).frame(width: 74, height: 18)
                                    Text(theme.name).lineLimit(1)
                                    Text(role(theme.role)).foregroundStyle(SettingsControlStyle.detail)
                                }
                            }
                        }
                    }
                    if !plan.skipped.isEmpty {
                        section("Not imported") {
                            ForEach(plan.skipped, id: \.self) { Text($0).foregroundStyle(SettingsControlStyle.detail) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Import") { apply(chosen) }.keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty && plan.themes.isEmpty)
                    .accessibilityIdentifier("import-apply")
            }
        }
        .padding(20)
        .frame(width: 460, height: 440)
        .background(Chrome.window)
        .foregroundStyle(Chrome.ink)
        .font(typography.font(offset: -0.5))
        .onAppear { chosen = Set(plan.changes.map(\.id)) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(typography.font(offset: -2.5)).tracking(1).foregroundStyle(SettingsControlStyle.detail)
            content()
        }
    }

    private func role(_ role: ImportPlan.Theme.Role) -> String {
        switch role {
        case .light: "becomes the light scheme"
        case .dark: "becomes the dark scheme"
        case .both: "becomes the color scheme"
        case .none: "saved"
        }
    }
}
