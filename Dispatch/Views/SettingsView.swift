import SwiftUI
import CoreText

/// Compact settings grouped into General, Appearance, Integrations, and Keys.
struct SettingsView: View {
    // Keep the controls stable while the user adjusts content typography.
    private let typography = AppTypography()
    let store: SettingsStore
    let workspace: Workspace
    var diagnostics: ChatViewportTrace = .shared
    var sshPermissions: SSHIntegrationPermissions = TerminalRuntime.shared.ssh.permissions
    var hasActiveSSHConnections: () -> Bool = { TerminalRuntime.shared.hasActiveSSHConnections }
    var resetSSHState: () async throws -> Void = { try await TerminalRuntime.shared.resetSSHState() }
    var fitInitialHeight: ((CGFloat) -> Void)?
    @State private var confirmingSSHReset = false
    @State private var resettingSSH = false
    /// Multiplexers whose terminal-started sessions can open as spaces, by the helper's name
    /// (the legacy route's fixed pair until its removal).
    private var multiplexers: [String] {
        TerminalRuntime.shared.helpers[.local].map { $0.multiplexers.filter(\.external).map(\.name) } ?? ["tmux", "herdr"]
    }
    @State private var draft = Preferences()
    @State private var error: String?
    @State private var keyError: String?
    @State private var loaded = false
    @State private var fittedInitialHeight = false
    @State private var selectedTab = SettingsTab.appearance
    @State private var themes: [String] = []
    @State private var fonts: [String] = []
    @State private var customColorsExpanded = false

    private var accent: Color { Chrome.accent }
    private var pickerWidth: CGFloat { typography.expanded(200) }

    static var monospacedFontFamilies: [String] {
        AppFont.register()
        // Inspect font metadata first. Constructing an NSFont for every installed
        // family loads proportional fonts that this picker will never display.
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        let candidates = Set(descriptors.compactMap { descriptor -> String? in
            guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any],
                  let symbolic = traits[kCTFontSymbolicTrait] as? UInt32,
                  CTFontSymbolicTraits(rawValue: symbolic).contains(.traitMonoSpace) else { return nil }
            return CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        })
        return candidates.filter { family in
            guard !["Andale Mono", "Courier New"].contains(family) else { return false }
            // Preserve the existing regular-face check for mixed-pitch families.
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Settings")
                .font(typography.font(offset: 0.5, design: .monospaced))
                .foregroundStyle(Chrome.muted)
                .frame(maxWidth: .infinity).frame(minHeight: typography.expanded(38))
                .background(Chrome.sidebar)
                .overlay(alignment: .bottom) { separator }
            HStack(spacing: 2) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        Text(tab.rawValue).font(typography.font(offset: -0.5))
                            .foregroundStyle(selectedTab == tab ? SettingsControlStyle.selectedText : Chrome.muted)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(selectedTab == tab ? Chrome.palette.control : .clear,
                                        in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }.padding(.top, 12).padding(.bottom, 14)
                .accessibilityIdentifier("settings-tabs")
            settingsPage {
                switch selectedTab {
                case .appearance: appearanceSettings
                case .keys: keySettings
                case .integrations: integrationSettings
                case .hosts: hostSettings
                case .extra: extraSettings
                }
            }.id(selectedTab)
            .padding(.horizontal, 12)
            HStack {
                Spacer()
                Button("restore defaults", action: restoreDefaults)
                    .buttonStyle(.plain)
                    .font(typography.font(offset: -1.5))
                    .foregroundStyle(SettingsControlStyle.detail)
                    .padding(.vertical, 4)
            }.padding(.horizontal, 22).padding(.vertical, 12)
            if let error {
                separator
                Text(error).font(typography.font(offset: -1.5)).foregroundStyle(.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(minWidth: min(900, typography.expanded(560)), maxWidth: min(900, typography.expanded(560)), minHeight: 440)
        .background(Chrome.window)
        .foregroundStyle(Chrome.ink)
        .font(typography.font(offset: 0))
        .environment(\.appTypography, typography)
        .controlSize(.small)
        .tint(accent)
        .preferredColorScheme(Chrome.colorScheme)
        .accessibilityIdentifier("settings-sheet")
        .alert("Forget all SSH hosts?", isPresented: $confirmingSSHReset) {
            Button("Cancel", role: .cancel) {}
            Button("Forget all", role: .destructive) { resetHosts() }
        } message: {
            Text("Disconnects all SSH connections and removes every host’s saved tabs, helper choices and cached data from Dispatch. Remote tmux and herdr sessions and running programs keep running. Global preferences are kept.")
        }
        .ignoresSafeArea()
        .onAppear {
            guard !loaded else { return }
            draft = store.values
            error = store.error
            fonts = Self.monospacedFontFamilies
            let path = Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes")
            let bundled = path.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) } ?? []
            themes = ["Default"] + Array(Set(bundled.filter { !$0.hasPrefix(".") } + [draft.theme, draft.lightTheme]).subtracting(["Default"])).sorted()
            loaded = true
        }
        .onChange(of: draft) { _, _ in
            guard loaded, draft != store.values else { return }
            save()
        }
        .onChange(of: store.values) { _, values in
            // The retained settings window also sees changes from the sidebar.
            // A failed save leaves the store unchanged and preserves its draft.
            draft = values
            error = store.error
        }
        .onPreferenceChange(SettingsPageHeights.self) { heights in
            // Open tall enough for the whole first page where the screen allows.
            guard !fittedInitialHeight, let fitInitialHeight,
                  let page = heights["page"], let viewport = heights["viewport"], page > 0, viewport > 0 else { return }
            fittedInitialHeight = true
            fitInitialHeight(page + 16 - viewport)
        }
    }

    private enum SettingsTab: String, CaseIterable {
        case appearance = "Appearance"
        case keys = "Keys"
        case integrations = "Integrations"
        case hosts = "Hosts"
        case extra = "Extra"
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 0, content: content)
                .padding(.horizontal, 10).padding(.bottom, 16)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SettingsPageHeights.self, value: ["page": proxy.size.height])
                })
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SettingsPageHeights.self, value: ["viewport": proxy.size.height])
        })
    }

    /// How it looks. Every row applies immediately.
    private var appearanceSettings: some View {
        VStack(spacing: 8) {
            settingsGroup("Text") {
                row("Terminal font", detail: "With user-installed monospaced fonts") {
                    dropdown("Terminal font", selection: $draft.fontFamily, choices: fonts, fontName: { $0 })
                }
                row("Chat font") {
                    dropdown("Chat font", selection: Binding(get: { draft.chatFont.rawValue }, set: {
                        if let choice = ChatFont(rawValue: $0) { draft.chatFont = choice }
                    }), choices: ChatFont.allCases.map(\.rawValue), fontName: {
                        ChatFont(rawValue: $0)?.postScriptName ?? draft.fontFamily
                    }, fontScale: { ChatFont(rawValue: $0)?.sizeScale ?? 1 })
                }
                row("Size") {
                    HStack(spacing: 12) {
                        SettingsSlider(value: $draft.fontSize, range: 8...22, step: 0.5, label: "Font size",
                                       identifier: "settings-font-size").frame(height: 20)
                            .help("8–22 pt · 0.5 pt steps")
                        (Text(draft.fontSize.formatted(.number.precision(.fractionLength(0...1))))
                            .foregroundColor(Chrome.ink) + Text(" pt").foregroundColor(Chrome.muted))
                            .font(typography.font(offset: -0.5)).monospacedDigit().fixedSize()
                            .frame(width: typography.expanded(52), alignment: .trailing)
                    }.frame(width: pickerWidth)
                }
            }
            settingsGroup("Style") {
                // Only an older system, where the switch is off and disabled, says why.
                row("Liquid Glass", detail: LiquidGlassStore.supported ? nil : "Requires macOS 26 or later") {
                    settingToggle("Liquid Glass", isOn: $draft.liquidGlass)
                        .disabled(!LiquidGlassStore.supported)
                        .accessibilityIdentifier("settings-liquid-glass")
                }
                row("Theme", detail: "Automatic follows macOS") {
                    dropdown("Theme", selection: Binding(get: { draft.appTheme.label }, set: { label in
                        if let theme = AppTheme.allCases.first(where: { $0.label == label }) { draft.appTheme = theme }
                    }), choices: AppTheme.allCases.map(\.label))
                }
                separator
                DisclosureGroup(isExpanded: $customColorsExpanded) {
                    if draft.appTheme == .automatic {
                        row("Light color scheme") { themePicker("Light color scheme", selection: $draft.lightTheme) }
                        row("Dark color scheme") { themePicker("Dark color scheme", selection: $draft.theme) }
                    } else {
                        row("Color scheme") {
                            themePicker("Color scheme", selection: draft.appTheme == .dark ? $draft.theme : $draft.lightTheme)
                        }
                    }
                    row("Improve text contrast", detail: "Adjust text colors while keeping their hue") {
                        settingToggle("Improve text contrast", isOn: $draft.improveTextContrast)
                            .accessibilityIdentifier("improve-text-contrast")
                            .help("Adjust faint terminal colors while preserving their hue. Applies immediately to open terminals.")
                    }
                    Text("Overrides terminal and chat colors only.")
                        .font(typography.font(offset: -1.5)).foregroundStyle(Chrome.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } label: {
                    Button { customColorsExpanded.toggle() } label: {
                        Text("Custom terminal & chat colors")
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .padding(.vertical, 9)
                .accessibilityIdentifier("custom-color-schemes")
            }
            settingsGroup("Sidebar & tabs") {
                // From the densest list to the roomiest, read out by name.
                row("Space size") {
                    let order = SidebarStyle.bySize
                    HStack(spacing: 12) {
                        SettingsSlider(value: Binding(get: { Double(order.firstIndex(of: draft.sidebarStyle) ?? 0) },
                                                      set: { draft.sidebarStyle = order[min(order.count - 1, max(0, Int($0.rounded())))] }),
                                       range: 0...Double(order.count - 1), step: 1, label: "Space size",
                                       identifier: "space-list-style", stops: true,
                                       describe: { order[min(order.count - 1, max(0, Int($0.rounded())))].label })
                            .frame(height: 20)
                        Text(draft.sidebarStyle.label).foregroundColor(Chrome.ink)
                            .font(typography.font(offset: -0.5)).fixedSize()
                            .frame(width: typography.expanded(60), alignment: .trailing)
                    }.frame(width: pickerWidth)
                }
                row("Liquid sidebar", detail: "Off uses a Finder-style sidebar") {
                    settingToggle("Liquid sidebar", isOn: $draft.liquidSidebar)
                        .disabled(!LiquidGlassStore.supported || !draft.liquidGlass)
                        .accessibilityIdentifier("settings-liquid-sidebar")
                        .help("A glass panel floating over the content; off, a column in the system's sidebar glass at the window's edge, as in Finder and Mail")
                }
                row("Hide Git branches", detail: "Beside each space’s name") {
                    settingToggle("Hide Git branches", isOn: Binding(get: { !draft.showGitBranches },
                                                                     set: { draft.showGitBranches = !$0 }))
                        .accessibilityIdentifier("hide-git-branches")
                }
                row("Hide with one space") {
                    settingToggle("Hide sidebar with one space", isOn: $draft.hideSingleSpace)
                }
                row("Automatic tab names") {
                    settingToggle("Automatic tab names", isOn: $draft.automaticTabNames)
                    .help("An agent's conversation title, a running program's own title, or the folder at an idle prompt. Off shows the terminal title. Renamed tabs keep their names.")
                }
            }
        }
    }

    /// The rest: what opens at launch and where new spaces start, attention notifications, and diagnostics for
    /// troubleshooting.
    private var extraSettings: some View {
        VStack(spacing: 8) {
            settingsGroup("Startup") {
                row("Starting folder", detail: "New spaces start here; new tabs follow the current folder") {
                    HStack(spacing: 8) {
                        Text(draft.startingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                            .foregroundStyle(Chrome.muted).help(draft.startingDirectory)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                row("Reopen spaces on launch", detail: "Local and remote spaces, tabs and splits") {
                    settingToggle("Reopen spaces on launch", isOn: $draft.rememberHosts)
                        .accessibilityIdentifier("settings-remember-hosts")
                        .help("Local shells restart in their last folder; remote hosts reopen disconnected. Turning this off deletes the saved session and stops saving; open tabs stay available.")
                }
                // Indented under Reopen spaces, which it needs.
                row("Restore tab history", detail: "Previous output, dimmed", indented: true) {
                    settingToggle("Restore tab history", isOn: $draft.restoreTerminalOutput)
                        .accessibilityIdentifier("settings-restore-terminal-output")
                        .help("Saves the text of local and plain SSH tabs when Dispatch quits normally; SSH tabs show it before they reconnect. It is kept for the next launch only, excluded from backups, deleted as Dispatch starts, and ignored after a week. Turning this off deletes it.")
                        .disabled(!draft.rememberHosts)
                }
            }
            settingsGroup("Notifications") {
                row("Notify", detail: "when a pane needs input or finishes a response") {
                    settingToggle("Attention notifications", isOn: $draft.attentionNotifications)
                }
                row("Dock badge", detail: "count of panes waiting for input") {
                    settingToggle("Attention Dock badge", isOn: $draft.attentionDockBadge)
                }
                row("Sound", detail: "play a sound for new background attention") {
                    settingToggle("Attention sound", isOn: $draft.attentionSound)
                }
                if let error = TerminalRuntime.shared.workspace === workspace ? (NSApp.delegate as? AppDelegate)?.attention.notificationError : nil {
                    Text(error).font(typography.font(offset: -1)).foregroundStyle(Chrome.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
            }
            settingsGroup("Troubleshooting") {
                row("Diagnostics", detail: "Anonymous app diagnostics saved on this Mac") {
                    settingToggle("Enable diagnostics", isOn: $draft.enableDiagnostics)
                        .accessibilityIdentifier("enable-diagnostics")
                        .help("No host details, personal information, or conversation content.")
                }
                if store.values.enableDiagnostics {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(diagnostics.directory.path)
                            .font(typography.font(offset: -1.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("diagnostics-log-path")
                        Button("Copy path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostics.directory.path, forType: .string)
                        }.accessibilityIdentifier("diagnostics-copy-path")
                        if let error = diagnostics.error {
                            Text(error).font(typography.font(offset: -1.5)).foregroundStyle(.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                }
            }
        }
    }

    /// The modifiers that go with the digit keys. Recording one another group already uses swaps the two.
    private var keySettings: some View {
        VStack(spacing: 8) {
            settingsGroup("Number keys") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Click a shortcut, then hold the modifiers you want and release them. ⌫ removes it; Esc cancels.")
                    // What the modifier symbols on this page stand for, in the order macOS writes them.
                    Text(KeyGroups.names.map { "\($0.symbol) \($0.name.capitalized)" }.joined(separator: "   "))
                        .accessibilityIdentifier("settings-key-symbols")
                }.font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                // Worded as in the ⌘/ shortcut sheet.
                row("Spaces", detail: ShortcutRow.spaceDigits) { keyRecorder("Spaces", \.spaces, digits: "1…9") }
                screenshotWarning(\.spaces, digits: 9)
                row("Tabs", detail: ShortcutRow.tabDigits) { keyRecorder("Tabs", \.tabs, digits: "1…9") }
                screenshotWarning(\.tabs, digits: 9)
                row("Splits", detail: ShortcutRow.splitDigits) { keyRecorder("Splits", \.splits, digits: "1…4") }
                screenshotWarning(\.splits, digits: 4)
                if let keyError {
                    Text(keyError).font(typography.font(offset: -1)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        .accessibilityIdentifier("settings-keys-error")
                }
                let conflicts = [("spaces", \KeyGroups.spaces, 9), ("splits", \KeyGroups.splits, 4)].compactMap { name, group, count in
                    let symbols = draft.keyGroups.symbols(group), flags = draft.keyGroups[keyPath: group]
                    let digits = flags.isEmpty ? [] : ApplicationMenu.desktopShortcutConflicts(modifiers: flags).filter { $0 <= count }
                    return digits.isEmpty ? nil : (name, digits.map { "\(symbols)\($0)" })
                }
                if !conflicts.isEmpty {
                    Text("\(conflicts.flatMap(\.1).joined(separator: ", ")) also switch macOS Desktops, which takes them before Dispatch. Choose other modifiers for \(conflicts.map(\.0).joined(separator: " and ")), or turn those off in System Settings › Keyboard › Keyboard Shortcuts › Mission Control.")
                        .font(typography.font(offset: -1)).foregroundStyle(Chrome.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        .accessibilityIdentifier("settings-desktop-shortcut-conflict")
                }
            }
            settingsGroup("Prefix keys") {
                // The group names them; the controls keep the full names for VoiceOver and their identifiers.
                row("In tmux and herdr spaces", detail: "⌃B, then a key, as in the tool itself") {
                    settingToggle("Prefix keys in tmux and herdr spaces", isOn: $draft.backendPrefixKeys)
                        .accessibilityIdentifier("settings-backend-prefix-keys")
                }
                row("In other spaces", detail: "⌃B, then a key; ⌃B twice sends ⌃B") {
                    dropdown("Prefix keys in other spaces", selection: Binding(get: { draft.prefixKeys.label }, set: { label in
                        if let style = PrefixStyle.allCases.first(where: { $0.label == label }) { draft.prefixKeys = style }
                    }), choices: PrefixStyle.allCases.map(\.label))
                    .help("tmux style: c new tab, n/p next/previous tab, % and \" split, x close pane, d detach. herdr style: c new tab, v and - split, ⇧N new space, b sidebar.")
                }
            }
            settingsGroup("Keyboard") {
                row("Use Option as Alt", detail: "Types characters such as é, or @ and { on some layouts") {
                    settingToggle("Use Option as Alt", isOn: $draft.optionAsAlt)
                }
            }
        }
    }

    /// Under the group whose modifiers are ⇧⌘: macOS's screenshot shortcuts take the digits it shares with them
    /// (⇧⌘3, ⇧⌘4 and ⇧⌘5) before Dispatch sees them.
    @ViewBuilder private func screenshotWarning(_ group: KeyPath<KeyGroups, NSEvent.ModifierFlags>, digits: Int) -> some View {
        if draft.keyGroups[keyPath: group] == [.shift, .command] {
            let keys = [3, 4, 5].filter { $0 <= digits }.map { "⇧⌘\($0)" }
            let list = keys.count > 1 ? keys.dropLast().joined(separator: ", ") + " and " + keys.last! : keys.joined()
            Text("macOS takes \(list) for screenshots first. To use them here, turn those off in System Settings › Keyboard › Keyboard Shortcuts › Screenshots.")
                .font(typography.font(offset: -1.5)).foregroundStyle(Chrome.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                .accessibilityIdentifier("settings-screenshot-shortcut-conflict")
        }
    }

    private func keyRecorder(_ title: String, _ group: WritableKeyPath<KeyGroups, NSEvent.ModifierFlags>, digits: String) -> some View {
        KeyGroupRecorder(title: title, modifiers: draft.keyGroups[keyPath: group], digits: digits) { flags in
            var next = draft.keyGroups
            let previous = next[keyPath: group]
            // Taking another group's modifiers swaps the two; unbinding takes nothing from anyone.
            for other in [\KeyGroups.spaces, \.tabs, \.splits] where !flags.isEmpty && other != group && next[keyPath: other] == flags {
                next[keyPath: other] = previous
            }
            next[keyPath: group] = flags
            keyError = next.problem
            if keyError == nil { draft.keyGroups = next }
        }
        .frame(width: pickerWidth, height: typography.expanded(27))
        .help("Click, then hold the modifiers for \(title.lowercased()) and release them. ⌫ removes the shortcut; Esc cancels.")
    }

    /// Remote hosts: what the helper may do on each, and how connections behave.
    private var hostSettings: some View {
        SSHHostsSettings(workspace: workspace, permissions: sshPermissions, policy: $draft.newHostPolicy,
                         clipboard: $draft.allowRemoteClipboardWrites, reconnect: $draft.autoReconnectSSH,
                         colors: $draft.showHostColors,
                         resetting: resettingSSH) {
            if hasActiveSSHConnections() { confirmingSSHReset = true } else { resetHosts() }
        }
    }

    @ViewBuilder
    private var integrationSettings: some View {
        integrationCards.task { TerminalRuntime.shared.chat.loadLaunches() }
    }

    @ViewBuilder
    private var integrationCards: some View {
        VStack(spacing: 8) {
            integrationCard("Agents", detail: "show coding agent CLIs as chat", enabled: chatEnabled) {
                ForEach(Self.listedAgents(TerminalRuntime.shared.chat.helperLaunches ?? []), id: \.key) { helperAgentRow($0) }
                Text(agentsFootnote)
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
            VStack(spacing: 0) {
                Text("tmux & herdr").fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 11)
                separator
                ForEach(multiplexers, id: \.self) { name in
                    cardOption("Open \(name) sessions as spaces", detail: sessionDetail(name), detailBelow: true) {
                        settingToggle("Open \(name) sessions as spaces", isOn: $draft.spaces[on: name], compact: true)
                    }
                }
            }.padding(.horizontal, 14)
                .background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border) }
            integrationCard("Kitty graphics", detail: "let terminal programs display images", enabled: $draft.enableKittyGraphics,
                            hasOptions: false) { EmptyView() }
        }
        if let chatError = TerminalRuntime.shared.chat.error {
            Text(chatError).font(typography.font(offset: -1.5)).foregroundStyle(.red).textSelection(.enabled)
                .padding(.top, 8)
        }
    }

    private func resetHosts() {
        guard !resettingSSH else { return }
        resettingSSH = true
        Task { @MainActor in
            defer { resettingSSH = false }
            do {
                try await resetSSHState()
                sshPermissions.resetAll()
                error = nil
            } catch { self.error = "Could not reset SSH hosts: \(error.localizedDescription)" }
        }
    }

    /// Which integrations Chat installs and which are optional, from the helper's launches.
    private var agentsFootnote: String {
        let chat = TerminalRuntime.shared.chat
        let launches = chat.helperLaunches ?? []
        let optional = launches.filter { chat.helperInstalls[$0.key]?.optional == true }.map(\.label)
        let required = launches.map(\.label).filter { !optional.contains($0) }
        let list = { (names: [String]) in names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.first ?? "" }
        return "Chat installs \(list(required)) hooks on this Mac and connected SSH hosts."
            + optional.map { " \($0)’s extension is optional." }.joined()
    }

    /// The same row from the helper's installation facts, for any harness it lists.
    /// The helper's agents in its own order, except Codex listed just above Claude Code. Only the list moves: a
    /// launch's position is its protocol id, so the helper keeps its order.
    private static func listedAgents(_ launches: [HelperClient.Launch]) -> [HelperClient.Launch] {
        guard let codex = launches.firstIndex(where: { $0.key == "codex" }),
              let claude = launches.firstIndex(where: { $0.key == "claude" }), codex > claude else { return launches }
        var listed = launches
        listed.insert(listed.remove(at: codex), at: claude)
        return listed
    }

    private func helperAgentRow(_ launch: HelperClient.Launch) -> some View {
        let chat = TerminalRuntime.shared.chat
        let install = chat.helperInstalls[launch.key], name = launch.label, status = chat.hookStatus(launch.key)
        let text: String
        switch status {
        case .ready: text = "✓ ready"
        case .restart:
            if let trust = install?.trust { text = "restart \(name), then trust Dispatch in \(trust)" }
            else if let reload = install?.reload { text = "run \(reload) in \(name) to finish" }
            else { text = "restart \(name) to finish" }
        case .off: text = install?.optional == true ? "needs its extension" : "not set up"
        }
        return cardOption(name, detail: text) {
            if status == .off {
                Button("Install") { chat.setHelperIntegration(launch.key, enabled: true) }
                    .accessibilityIdentifier("settings-install-\(launch.key)")
            } else if install?.optional == true {
                Button("Remove") { chat.setHelperIntegration(launch.key, enabled: false) }
                    .accessibilityIdentifier("settings-remove-\(launch.key)")
            }
        }.accessibilityIdentifier("settings-agent-\(launch.key)")
    }

    private var chatEnabled: Binding<Bool> {
        Binding(get: { TerminalRuntime.shared.chat.enabled }, set: { TerminalRuntime.shared.chat.setEnabled($0) })
    }


    private func restoreDefaults() {
        draft = Preferences()
        keyError = nil
        if selectedTab == .integrations {
            let chat = TerminalRuntime.shared.chat
            chat.setEnabled(true)
            chat.restoreHelperIntegrations()
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10).padding(.bottom, 7)
            VStack(spacing: 0, content: content)
                .padding(.bottom, 4)
        }.padding(.horizontal, 14)
            .background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border) }
    }

    private func integrationCard<Options: View>(_ title: String, detail: String, enabled: Binding<Bool>,
                                                hasOptions: Bool = true, @ViewBuilder options: () -> Options) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold).foregroundStyle(SettingsControlStyle.selectedText)
                    Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                }
                Spacer(minLength: 0)
                settingToggle(title, isOn: enabled)
            }.padding(.horizontal, 14).padding(.vertical, 11)
            if hasOptions {
                separator
                VStack(spacing: 0, content: options)
                    .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 4)
                    .disabled(!enabled.wrappedValue)
            }
        }.background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border) }
            .opacity(enabled.wrappedValue ? 1 : 0.5)
    }

    /// A card's option: its detail beside the title, or below it (wrapping) for a longer one.
    private func cardOption<Control: View>(_ title: String, detail: String? = nil, detailBelow: Bool = false,
                                           @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            if detailBelow {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(typography.font(offset: -0.5))
                    if let detail {
                        Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(typography.font(offset: -0.5))
                    if let detail { Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            control()
        }.padding(.vertical, 7)
    }

    /// Which sessions "Open … sessions as spaces" takes, for the multiplexers Dispatch knows, and what happens to
    /// the tab that started one.
    private func sessionDetail(_ name: String) -> String {
        let commands = ["tmux": "tmux -CC or tmux -CC attach", "herdr": "herdr or herdr session attach"]
        return (commands[name].map { "For \($0). " } ?? "") + "The original tab closes after attach."
    }


    private var separator: some View { Rectangle().fill(Chrome.palette.separator).frame(height: 1) }


    /// An indented row depends on the row above it.
    private func row<Control: View>(_ title: String, detail: String? = nil, indented: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            separator
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail) }
                }.padding(.leading, indented ? 18 : 0)
                Spacer(minLength: 8)
                control()
            }.padding(.vertical, 9)
        }
    }

    private func themePicker(_ title: String, selection: Binding<String>) -> some View {
        dropdown(title, selection: Binding(
            get: { selection.wrappedValue == "Default" ? "Match app theme" : selection.wrappedValue },
            set: { selection.wrappedValue = $0 == "Match app theme" ? "Default" : $0 }),
            choices: themes.map { $0 == "Default" ? "Match app theme" : $0 })
    }

    private func dropdown(_ title: String, selection: Binding<String>, choices: [String],
                          fontName: ((String) -> String)? = nil,
                          fontScale: ((String) -> CGFloat)? = nil) -> some View {
        SettingsDropdown(title: title, selection: selection, choices: choices, fontName: fontName, fontScale: fontScale)
            .frame(width: pickerWidth, height: typography.expanded(27))
    }

    private func settingToggle(_ title: String, isOn: Binding<Bool>, compact: Bool = false) -> some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(SettingsSwitchStyle(title: title, compact: compact))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: draft.startingDirectory)
        if panel.runModal() == .OK, let url = panel.url { draft.startingDirectory = url.path }
    }

    private func save() {
        let old = store.values
        do {
            try TerminalRuntime.shared.apply(draft)
            do { try store.save(draft) }
            catch { try? TerminalRuntime.shared.apply(old); throw error }
            diagnostics.setEnabled(store.values.enableDiagnostics)
            (NSApp.delegate as? AppDelegate)?.applySidebarTheme(draft.resolvedSidebarTheme)
            workspace.defaultDirectory = draft.startingDirectory
            error = store.error
        } catch { self.error = error.localizedDescription }
    }
}

struct SettingsSwitchStyle: ToggleStyle {
    let title: String
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Chrome.accent : SettingsControlStyle.border)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(configuration.isOn ? .white : Chrome.muted)
                        .frame(width: compact ? 12 : 16, height: compact ? 12 : 16).padding(2)
                }
                .frame(width: compact ? 28 : 34, height: compact ? 16 : 20)
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct SettingsPageHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

@MainActor enum SettingsControlStyle {
    static var detail: Color { Chrome.palette.detail }
    static var fill: Color { Chrome.palette.control }
    static var border: Color { Chrome.palette.controlBorder }
    static var selected: Color { Chrome.palette.selectedControl }
    static var selectedText: Color { Chrome.ink }
}

/// Keep native slider input and accessibility with the mockup’s thin track and knob. Values snap to `step`; with
/// `stops`, each step is a choice, marked on the track and named by `describe` for VoiceOver.
private struct SettingsSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let identifier: String
    /// A stepped picker's choices: marked on the track, the value read out by name.
    var stops = false
    var describe: ((Double) -> String)?
    func makeCoordinator() -> Coordinator { Coordinator(value: $value, step: step) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = SteppedSlider()
        let cell = SliderCell()
        cell.stops = stops ? Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1 : 0
        slider.cell = cell
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.step = step
        slider.isContinuous = true
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        slider.setAccessibilityIdentifier(identifier)
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        // A saved size outside the mockup’s range stays intact until edited.
        slider.doubleValue = value
        slider.setAccessibilityValueDescription(describe?(value))
        slider.appearance = NSAppearance(named: Chrome.palette.isDark ? .darkAqua : .aqua)
        slider.needsDisplay = true
    }
    final class Coordinator: NSObject {
        var value: Binding<Double>
        let step: Double
        init(value: Binding<Double>, step: Double) { self.value = value; self.step = step }
        @objc func changed(_ slider: NSSlider) {
            let rounded = (slider.doubleValue / step).rounded() * step
            slider.doubleValue = rounded
            if value.wrappedValue != rounded { value.wrappedValue = rounded }
        }
    }
    final class SteppedSlider: NSSlider {
        var step = 1.0
        override func keyDown(with event: NSEvent) {
            if [123, 124, 125, 126].contains(event.keyCode) {
                doubleValue = min(maxValue, max(minValue, doubleValue + ([124, 126].contains(event.keyCode) ? step : -step)))
                sendAction(action, to: target)
            } else { super.keyDown(with: event) }
        }
    }
    final class SliderCell: NSSliderCell {
        /// Marks drawn along the track, one per choice; none for a continuous slider.
        var stops = 0
        override func barRect(flipped: Bool) -> NSRect {
            let bounds = controlView?.bounds ?? .zero
            return NSRect(x: bounds.minX + 7, y: bounds.midY - 1.5, width: max(0, bounds.width - 14), height: 3)
        }
        override func knobRect(flipped: Bool) -> NSRect {
            let bar = barRect(flipped: flipped)
            let fraction = min(1, max(0, (doubleValue - minValue) / (maxValue - minValue)))
            return NSRect(x: bar.minX + bar.width * fraction - 7, y: bar.midY - 7, width: 14, height: 14)
        }
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let bar = barRect(flipped: flipped)
            let filled = NSColor(srgbRed: 154/255, green: 154/255, blue: 162/255, alpha: 1)
            NSColor(SettingsControlStyle.border).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            let knob = knobRect(flipped: flipped).midX
            var fill = bar
            fill.size.width = max(0, knob - bar.minX)
            filled.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            // Each choice a dot on the track, filled up to the knob.
            guard stops > 1 else { return }
            for index in 0..<stops {
                let x = bar.minX + bar.width * CGFloat(index) / CGFloat(stops - 1)
                (x <= knob + 0.5 ? filled : NSColor(SettingsControlStyle.border)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3, y: bar.midY - 3, width: 6, height: 6)).fill()
            }
        }
        override func drawKnob(_ knobRect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 3; shadow.shadowOffset = NSSize(width: 0, height: -1); shadow.set()
            NSColor(SettingsControlStyle.selectedText).setFill()
            NSBezierPath(ovalIn: knobRect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

private struct SettingsDropdown: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTypography) private var typography
    let title: String
    @Binding var selection: String
    let choices: [String]
    let fontName: ((String) -> String)?
    let fontScale: ((String) -> CGFloat)?
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = PopupButton(frame: .zero, pullsDown: false)
        button.cell = PopupCell(textCell: "", pullsDown: false)
        button.target = context.coordinator; button.action = #selector(Coordinator.changed(_:))
        button.font = AppFont.native(size: typography.size(offset: -0.5))
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        button.isEnabled = isEnabled
        button.appearance = NSAppearance(named: Chrome.palette.isDark ? .darkAqua : .aqua)
        button.font = AppFont.native(size: typography.size(offset: -0.5))
        button.needsDisplay = true
        context.coordinator.selection = $selection
        let items = choices.contains(selection) ? choices : choices + [selection]
        if button.itemTitles != items {
            button.removeAllItems(); button.addItems(withTitles: items)
        }
        if let fontName {
            for item in button.itemArray {
                let size = typography.size(offset: -0.5) * (fontScale?(item.title) ?? 1)
                let name = fontName(item.title)
                let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
                    ?? NSFont(name: name, size: size)
                    ?? .monospacedSystemFont(ofSize: size, weight: .regular)
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
        }
        button.selectItem(withTitle: selection)
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("settings-dropdown-\(title)")
    }
    final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        @objc func changed(_ sender: NSPopUpButton) {
            if let title = sender.selectedItem?.title { selection.wrappedValue = title }
        }
    }
    final class PopupButton: NSPopUpButton {
        // Native popup sizing otherwise uses the longest menu item and spills
        // outside the fixed-width field when the theme list contains long names.
        override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 27) }
    }
    final class PopupCell: NSPopUpButtonCell {
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
            let rect = cellFrame.insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor(SettingsControlStyle.fill).setFill(); shape.fill()
            NSColor(SettingsControlStyle.border).setStroke(); shape.lineWidth = 1; shape.stroke()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let previewTitle = selectedItem?.attributedTitle
            let previewFont = previewTitle.flatMap {
                $0.length > 0 ? $0.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: previewFont ?? font ?? AppFont.native(size: 12),
                .foregroundColor: NSColor(Chrome.ink), .paragraphStyle: paragraph
            ]
            let label = title as NSString
            let height = label.size(withAttributes: attributes).height
            label.draw(in: NSRect(x: rect.minX + 9, y: rect.midY - height / 2,
                                 width: max(0, rect.width - 32), height: height), withAttributes: attributes)
            let arrow = NSBezierPath()
            let x = rect.maxX - 13, y = rect.midY
            let direction: CGFloat = controlView.isFlipped ? 1 : -1
            arrow.move(to: NSPoint(x: x - 3, y: y - 2 * direction))
            arrow.line(to: NSPoint(x: x + 3, y: y - 2 * direction))
            arrow.line(to: NSPoint(x: x, y: y + 2 * direction)); arrow.close()
            NSColor(Chrome.palette.detail).setFill(); arrow.fill()
        }
    }
}
