import Dictation
import SwiftUI
import CoreText

/// Compact settings grouped into Appearance, General, Features, Keyboard, Extra (imports, export and
/// troubleshooting), and Hosts.
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
    @State private var schemes = ColorSchemes()
    @State private var fonts: [String] = []
    @State private var customColorsExpanded = false
    @State private var agentsExpanded = false
    @State private var filesOptionsExpanded = false
    @State private var multiplexersExpanded = false
    @State private var remoteHelperExpanded = false
    @State private var dictationExpanded = false
    @State private var interfaceExpanded = false
    @State private var notificationsExpanded = false
    /// /etc/shells, read when Settings opens.
    @State private var shells: [String] = []
    /// Custom… chosen in Shell: the command being typed, saved on Return.
    @State private var customShell: String?

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
        // The default font leads; the rest follow alphabetically.
        let lead = Preferences().fontFamily
        return candidates.filter { family in
            guard !["Andale Mono", "Courier New"].contains(family) else { return false }
            // Preserve the existing regular-face check for mixed-pitch families.
            guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 13) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }.sorted { a, b in
            if a == lead || b == lead { return a == lead }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Nautical's settings are the ship's bridge.
            Text(SidebarThemeStore.shared.current == .nautical ? "Bridge" : "Settings")
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
                case .keyboard: keySettings
                case .extra:
                    VStack(spacing: 8) {
                        SettingsExtraPage(draft: $draft, schemesChanged: reloadSchemes)
                        troubleshootingSettings
                    }
                case .general: generalSettings
                case .features: featureSettings
                case .hosts: hostSettings
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
            shells = Self.listedShells
            schemes = ColorSchemes(directory: System.resources.appendingPathComponent("ghostty/themes"))
            loaded = true
        }
        .onChange(of: SidebarThemeStore.shared.nauticalUnlocked) { _, unlocked in
            if unlocked { draft.appTheme = .nautical }
        }
        .onChange(of: draft.colorVision) { _, vision in
            if loaded { conformSchemes(to: vision) }
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
        case general = "General"
        case features = "Features"
        case keyboard = "Keyboard"
        case extra = "Extra"
        case hosts = "Hosts"
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
                row("Terminal font", detail: "any monospaced font on this Mac") {
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
                row("Theme", detail: SidebarThemeStore.shared.nauticalUnlocked || draft.appTheme == .nautical
                    ? "automatic follows macOS · ⚓ Nautical unlocked" : "automatic follows macOS") {
                    dropdown("Theme", selection: Binding(get: { draft.appTheme.label }, set: { label in
                        if let theme = AppTheme.allCases.first(where: { $0.label == label }) { draft.appTheme = theme }
                    }), choices: AppTheme.offered(selected: draft.appTheme,
                                                  nauticalUnlocked: SidebarThemeStore.shared.nauticalUnlocked).map(\.label))
                }
                colorSchemes
                interfaceOptions
            }
            settingsGroup("Sidebar") {
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
                row("Show git branch", detail: draft.gitEnabled ? nil : "needs Git, in Features") {
                    settingToggle("Show git branch", isOn: $draft.showGitBranches)
                        .disabled(!draft.gitEnabled)
                        .accessibilityIdentifier("show-git-branch")
                }
                // Off by default: one space needs no sidebar until asked for (the setting is stored as hiding).
                row(draft.tabsOnly ? "Show with one tab" : "Show with one space") {
                    settingToggle("Show with one space", isOn: Binding(get: { !draft.hideSingleSpace }, set: { draft.hideSingleSpace = !$0 }))
                }
                row("Disable spaces", detail: "removes spaces, makes tabs vertical") {
                    settingToggle("Disable spaces", isOn: $draft.tabsOnly)
                        .accessibilityIdentifier("settings-tabs-only")
                        .help("Lists every tab in the sidebar instead of tab strips. ⌘T adds a tab and ⌘1…9 jump through the list.")
                }
            }
        }
    }

    /// What opens at launch and where new spaces start, how terminals behave, and attention notifications. Whole
    /// features and their options are under Features; troubleshooting is under Extra.
    private var generalSettings: some View {
        VStack(spacing: 8) {
            settingsGroup("Startup") {
                startingFolderRow
                shellRow
                row("Reopen spaces on launch", detail: "local and remote spaces, tabs and splits",
                    privacy: "Keeps your spaces, tabs, folders and SSH destinations in a private file on this Mac. No passwords, keys or commands.") {
                    settingToggle("Reopen spaces on launch", isOn: $draft.rememberHosts)
                        .accessibilityIdentifier("settings-remember-hosts")
                        .help("Local shells restart in their last folder; remote hosts reopen disconnected. Turning this off deletes the saved session and stops saving; open tabs stay available.")
                }
                // Indented under Reopen spaces, which it needs.
                row("Restore tab history", detail: "previous output, dimmed", indented: true,
                    privacy: "Writes everything local and plain SSH tabs showed to disk on quit, including any secrets you typed or printed.") {
                    settingToggle("Restore tab history", isOn: $draft.restoreTerminalOutput)
                        .accessibilityIdentifier("settings-restore-terminal-output")
                        .help("Saves the text of local and plain SSH tabs when Dispatch quits normally; SSH tabs show it before they reconnect. It is kept for the next launch only, excluded from backups, deleted as Dispatch starts, and ignored after a week. Turning this off deletes it.")
                        .disabled(!draft.rememberHosts)
                }
            }
            settingsGroup("Terminal") {
                row("Programs can copy", detail: "to your clipboard, via OSC 52",
                    privacy: "Any program in any tab, remote hosts included, can replace your clipboard without asking.") {
                    settingToggle("Programs can copy", isOn: $draft.allowClipboardWrites)
                        .accessibilityIdentifier("settings-remote-clipboard")
                        .help("OSC 52, the kitty clipboard protocol and tmux buffers, in local and remote tabs alike. Programs can never read your clipboard.")
                }
                row("Secure keyboard entry", detail: "other apps can't read what you type",
                    privacy: "While Dispatch is the active app, apps with Input Monitoring see none of your keystrokes, passwords included. Some text expanders and keyboard tools stop working meanwhile.") {
                    settingToggle("Secure keyboard entry", isOn: $draft.secureKeyboardEntry)
                        .accessibilityIdentifier("settings-secure-keyboard-entry")
                }
                row("Scrollback", detail: draft.scrollback == .automatic ? "sized from this Mac’s memory · new tabs" : "history each new tab keeps") {
                    dropdown("Scrollback", selection: Binding(get: { draft.scrollback.title }, set: { title in
                        if let size = Scrollback.allCases.first(where: { $0.title == title }) { draft.scrollback = size }
                    }), choices: Scrollback.allCases.map(\.title))
                        .help("Unlimited keeps every line until the tab closes, in memory.")
                }
                row("Kitty graphics", detail: "images in terminal; less secure",
                    privacy: "Output in a local tab can make Dispatch open any file on this Mac you can read.") {
                    settingToggle("Kitty graphics", isOn: $draft.enableKittyGraphics)
                        .help("Kitty's image protocol. Any output in a local tab, even a file you cat, can make Dispatch open a file on this Mac and decode it as an image; remote tabs can only send image data.")
                }
                row("Automatic tab names") {
                    settingToggle("Automatic tab names", isOn: $draft.automaticTabNames)
                    .help("An agent's conversation title, a running program's own title, or the folder at an idle prompt. Off shows the terminal title. Renamed tabs keep their names.")
                }
            }
            // One switch for banners and the Dock badge (either one still on, an older split choice, shows it on); the
            // rest folded until asked for.
            integrationCard("Notifications", detail: "banner and Dock badge when a pane needs input or finishes a response",
                            enabled: Binding(get: { draft.attentionNotifications || draft.attentionDockBadge },
                                             set: { draft.attentionNotifications = $0; draft.attentionDockBadge = $0 }),
                            fold: Fold(title: "Options",
                                       on: [draft.attentionSound, draft.attentionTextContent,
                                            draft.appTheme == .nautical && draft.shipsBell].filter { $0 }.count,
                                       isExpanded: $notificationsExpanded)) {
                cardOption("Sound", detail: "play a sound for new background attention", detailBelow: true) {
                    settingToggle("Attention sound", isOn: $draft.attentionSound)
                }
                cardOption("Display text content", detail: "the start of the agent's reply and the pane's folder", detailBelow: true,
                           privacy: "Banners show the pane, its folder and the start of the agent's reply, and can appear on the lock screen.") {
                    settingToggle("Display text content", isOn: $draft.attentionTextContent)
                        .accessibilityIdentifier("settings-notification-text")
                }
                if draft.appTheme == .nautical {
                    cardOption("Ship's bell", detail: "two bells when an agent finishes in the background", detailBelow: true) {
                        settingToggle("Ship's bell", isOn: $draft.shipsBell)
                            .accessibilityIdentifier("settings-ships-bell")
                    }
                }
            }.accessibilityIdentifier("settings-notifications")
            if let error = TerminalRuntime.shared.workspace === workspace ? (NSApp.delegate as? AppDelegate)?.attention.notificationError : nil {
                Text(error).font(typography.font(offset: -1)).foregroundStyle(Chrome.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            }
        }
    }

    /// Why SSH integration fell back to a plain shell, and the app's anonymous diagnostics; on the Extra page.
    private var troubleshootingSettings: some View {
        settingsGroup("Troubleshooting") {
            let setup = SSHSetupLog.shared
            if !setup.fallbacks.isEmpty {
                // Why SSH integration fell back to a plain shell since Dispatch started; the system log has each one.
                row("SSH integration fallbacks", detail: setup.fallbacks.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                    .map { "\($0.key) ×\($0.value)" }.joined(separator: " · ")) {
                    Text(verbatim: "\(setup.fallbacks.values.reduce(0, +))").foregroundStyle(Chrome.muted)
                }
                .accessibilityIdentifier("settings-ssh-fallbacks")
            }
            row("Diagnostics", detail: "anonymous app diagnostics saved on this Mac",
                privacy: "Stays on this Mac; nothing is sent anywhere.") {
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

    /// Style's third row: the window and the cursor, folded like Color schemes; its title opens it too.
    @ViewBuilder private var interfaceOptions: some View {
        let fold = Fold(title: "Interface", on: [draft.liquidGlass && LiquidGlassStore.supported, draft.showHostColors,
                                                 draft.cursorBlink].filter { $0 }.count, isExpanded: $interfaceExpanded)
        row("Interface", detail: "glass, host colors and cursor") { foldButton(fold, card: "Interface") }
            .contentShape(Rectangle()).onTapGesture { toggle(fold) }
            .accessibilityIdentifier("settings-interface")
        if interfaceExpanded {
            // Only an older system, where the switch is off and disabled, says why.
            cardOption("Liquid Glass", detail: LiquidGlassStore.supported ? nil : "requires macOS 26 or later", detailBelow: true) {
                settingToggle("Liquid Glass", isOn: $draft.liquidGlass)
                    .disabled(!LiquidGlassStore.supported)
                    .accessibilityIdentifier("settings-liquid-glass")
            }
            cardOption("Color-code remote hosts", detail: "colored or gray icons, tabs and borders", detailBelow: true) {
                settingToggle("Color-code remote hosts", isOn: $draft.showHostColors)
                    .accessibilityIdentifier("settings-host-colors")
                    .help("Tints remote tabs, borders and sidebar items in each host’s color. Off, they’re marked in gray.")
            }
            cardOption("Cursor") {
                dropdown("Cursor", selection: Binding(get: { draft.cursor.title }, set: { title in
                    if let cursor = TerminalCursor.allCases.first(where: { $0.title == title }) { draft.cursor = cursor }
                }), choices: TerminalCursor.allCases.map(\.title))
            }
            cardOption("Blinking cursor", detail: "programs can still choose their own", detailBelow: true) {
                settingToggle("Blinking cursor", isOn: $draft.cursorBlink)
                    .accessibilityIdentifier("settings-cursor-blink")
            }
        }
    }

    /// Style's terminal and chat colors, folded into one row: colorblind mode, a scheme for light and dark (or the app
    /// theme's one), text contrast, and your own schemes, each applied in a click. Its title opens it too.
    @ViewBuilder private var colorSchemes: some View {
        let fold = Fold(title: "Color schemes", on: nil, isExpanded: $customColorsExpanded)
        row("Color schemes", detail: "terminal and chat") {
            HStack(spacing: 8) {
                Button(action: surpriseScheme) {
                    // Lit like an opened options button, so it reads as an action rather than a muted control.
                    Label("Surprise me", systemImage: "dice").font(typography.font(offset: -1.5))
                        .foregroundStyle(Chrome.ink)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(SettingsControlStyle.selected, in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border, lineWidth: 0.5) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .help("Make a new scheme for this side and use it; the next surprise replaces it unless you keep it")
                    .accessibilityIdentifier("settings-surprise-scheme")
                foldButton(fold, card: "Color schemes")
            }
        }
            .contentShape(Rectangle()).onTapGesture { toggle(fold) }
            .accessibilityIdentifier("custom-color-schemes")
        if customColorsExpanded {
            VStack(spacing: 0) {
                if draft.appTheme == .automatic {
                    cardOption("Light color scheme", detail: missingScheme(draft.lightTheme)) {
                        themePicker("Light color scheme", selection: $draft.lightTheme, light: true)
                    }
                    cardOption("Dark color scheme", detail: missingScheme(draft.theme)) {
                        themePicker("Dark color scheme", selection: $draft.theme, light: false)
                    }
                } else {
                    let dark = draft.appTheme.isDark(systemIsDark: SidebarThemeStore.systemIsDark)
                    cardOption("Color scheme", detail: missingScheme(dark ? draft.theme : draft.lightTheme)) {
                        themePicker("Color scheme", selection: dark ? $draft.theme : $draft.lightTheme, light: !dark)
                    }
                }
                cardOption("Terminal opacity", detail: draft.terminalOpacity < 1 ? "the desktop shows through terminals" : nil,
                           detailBelow: true) {
                    HStack(spacing: 12) {
                        SettingsSlider(value: $draft.terminalOpacity, range: Preferences.terminalOpacityRange, step: 0.05,
                                       label: "Terminal opacity", identifier: "settings-terminal-opacity").frame(height: 20)
                        Text(draft.terminalOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundColor(Chrome.ink).font(typography.font(offset: -0.5)).monospacedDigit().fixedSize()
                            .frame(width: typography.expanded(52), alignment: .trailing)
                    }.frame(width: pickerWidth)
                }
                cardOption("Improve text contrast", detail: "adjust text colors while keeping their hue", detailBelow: true) {
                    settingToggle("Improve text contrast", isOn: $draft.improveTextContrast)
                        .accessibilityIdentifier("improve-text-contrast")
                        .help("Adjust faint terminal colors while preserving their hue. Applies immediately to open terminals.")
                }
                cardOption("Colorblind-friendly", detail: "only schemes made for color blindness; new schemes are made for it",
                           detailBelow: true) {
                    settingToggle("Colorblind-friendly", isOn: Binding(get: { draft.colorVision != .typical },
                                                                       set: { draft.colorVision = $0 ? .redGreen : .typical }))
                        .accessibilityIdentifier("settings-colorblind")
                }
                if draft.colorVision != .typical {
                    cardOption("Color blindness", detail: draft.colorVision.detail, detailBelow: true) {
                        dropdown("Color blindness", selection: Binding(
                            get: { draft.colorVision.title },
                            set: { title in
                                if let vision = ColorVision.allCases.first(where: { $0.title == title }) { draft.colorVision = vision }
                            }), choices: [ColorVision.redGreen, .blueYellow].map(\.title))
                    }
                }
                Text("Your color schemes").font(typography.font(offset: -0.5)).fontWeight(.semibold)
                    .foregroundStyle(SettingsControlStyle.selectedText)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.bottom, 7)
                YourColorSchemes(draft: $draft, schemesChanged: reloadSchemes, importSchemes: { selectedTab = .extra },
                                 themes: schemes.custom)
            }.padding(.bottom, 4)
        }
    }

    /// "Surprise me": a new random scheme for the side showing now (and the colorblind mode), in place of the last
    /// surprise, used at once.
    private func surpriseScheme() {
        let systemIsDark = SidebarThemeStore.systemIsDark
        let dark = draft.appTheme == .automatic ? systemIsDark : draft.appTheme.isDark(systemIsDark: systemIsDark)
        // Seeded from System so a replayed test sees the same surprise.
        let bytes = System.uuid().uuid
        let seed = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        do {
            let name = try SurpriseScheme.make(light: !dark, vision: draft.colorVision, seed: seed)
            reloadSchemes()
            if dark { draft.theme = name } else { draft.lightTheme = name }
        } catch { self.error = "Could not make a surprise scheme: \(error.localizedDescription)" }
    }

    /// The schemes on disk changed (made, edited, added, imported, deleted): list them again, and let terminals and chat
    /// read the scheme in use again, which may be the one that changed under the same name.
    private func reloadSchemes() {
        schemes = ColorSchemes(directory: System.resources.appendingPathComponent("ghostty/themes"))
        try? TerminalRuntime.shared.apply(TerminalRuntime.shared.preferences)
    }

    /// Whole features, each with its options: Chat mode and its agents, tmux and herdr sessions as spaces, files mode,
    /// and git.
    private var featureSettings: some View {
        VStack(spacing: 8) {
            // An agent on or off for Chat on every machine; Hosts chooses where its hooks are installed.
            integrationCard("Chat mode", detail: "coding agent CLIs as chat",
                            privacy: "Adds hooks to the agents' own config and reads their transcripts, in memory only.",
                            enabled: chatEnabled, fold: agentFold) {
                ForEach(TerminalRuntime.shared.chat.listedLaunches, id: \.key) { agentRow($0) }
            }.accessibilityIdentifier("settings-agents")
            if let chatError = TerminalRuntime.shared.chat.error {
                Text(chatError).font(typography.font(offset: -1.5)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One switch for every multiplexer: on while any is, and it turns them all on or off.
            integrationCard("Tmux & herdr", detail: "open sessions as native spaces with tmux -CC or herdr",
                            enabled: Binding(get: { multiplexers.contains { draft.spaces[on: $0] } },
                                             set: { on in for name in multiplexers { draft.spaces[on: name] = on } }),
                            fold: Fold(title: "Multiplexers", on: multiplexers.filter { draft.spaces[on: $0] }.count,
                                       isExpanded: $multiplexersExpanded)) {
                ForEach(multiplexers, id: \.self) { name in
                    cardOption(name, detail: sessionDetail(name), detailBelow: true) {
                        settingToggle("Open \(name) sessions as spaces", isOn: $draft.spaces[on: name])
                    }
                }
                Text("the original tab closes after attach.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 7)
            }
            integrationCard("Files", detail: "browse, preview and copy a tab’s files · ⇧⌘F",
                            enabled: $draft.filesEnabled,
                            fold: Fold(title: "Options", on: [draft.filesDragAndDrop, draft.filesShowHidden].filter { $0 }.count,
                                       isExpanded: $filesOptionsExpanded)) {
                cardOption("Drag and drop", detail: "copy files in from Finder, out to Finder, or onto a terminal as paths",
                           detailBelow: true) {
                    settingToggle("Drag and drop", isOn: $draft.filesDragAndDrop)
                        .accessibilityIdentifier("settings-files-drag-and-drop")
                }
                cardOption("Show hidden files", detail: "dotfiles and ignored folders; ⇧⌘. toggles per tab", detailBelow: true) {
                    settingToggle("Show hidden files", isOn: $draft.filesShowHidden)
                        .accessibilityIdentifier("settings-files-show-hidden")
                }
            }
                .accessibilityIdentifier("settings-files")
            integrationCard("Git", detail: "review mode and commit log · ⇧⌘F",
                            enabled: $draft.gitEnabled, hasOptions: false) { EmptyView() }
                .accessibilityIdentifier("settings-git")
            remoteHelperSettings
            dictationSettings
        }.task { TerminalRuntime.shared.chat.loadLaunches() }
    }

    /// The helper Dispatch uploads to SSH hosts for stats, files and remote chat; off, hosts connect over plain SSH.
    /// Without Auto-confirm, a new host asks which features to allow; with it, the helper gets them all.
    private var remoteHelperSettings: some View {
        integrationCard("Remote helper", detail: "uploads to ~/.dispatch",
                        privacy: "On each SSH host the helper can see processes, files you can read, agent transcripts and Git, as features allow.",
                        enabled: $draft.enableHostDetection,
                        fold: Fold(title: "Options", on: [draft.autoGrantNewHosts, draft.autoReconnectSSH].filter { $0 }.count,
                                   isExpanded: $remoteHelperExpanded)) {
            cardOption("Auto-confirm uploads", detail: "new hosts get every feature without asking", detailBelow: true,
                       privacy: "Skips choosing what the helper may see on a new host.") {
                settingToggle("Auto-confirm uploads", isOn: $draft.autoGrantNewHosts)
                    .accessibilityIdentifier("settings-auto-confirm-uploads")
                    .help("The helper can see processes, files you can read, agent transcripts and Git. It is kept at ~/.dispatch/bin/versions/<hash>/dispatch-helper.")
            }
            cardOption("Reconnect automatically", detail: "after a drop, with your keys or SSH agent", detailBelow: true) {
                settingToggle("Reconnect automatically", isOn: $draft.autoReconnectSSH)
                    .accessibilityIdentifier("settings-ssh-auto-reconnect")
                    .help("For connections with the helper, retrying after sleep or a network change. Hosts that ask for a password, connections you disconnect, and hosts reopened at launch wait for Reconnect.")
            }
        }
            .accessibilityIdentifier("settings-remote-helper")
    }

    /// How the first wake word is said: "Dispatch".
    private var wakeWord: String { WakeWordsSetting.title(draft.dictationWakeWords.first ?? "dispatch") }

    /// Chat dictation's engine; choosing Whisper lists its models to download and pick from.
    private var dictationSettings: some View {
        integrationCard("Dictation", detail: "always local & on-device",
                        privacy: "Listens only while you dictate; audio stays in memory. The text goes into the draft, which is saved.",
                        enabled: $draft.dictationEnabled,
                        fold: Fold(title: "Options",
                                   on: [draft.dictationRightCommand, draft.dictationNavigation, draft.dictationReadReplies].filter { $0 }.count,
                                   isExpanded: $dictationExpanded)) {
            cardOption("Engine", detail: "Apple uses your macOS language; Whisper understands many languages.",
                       detailBelow: true) {
                dropdown("Dictation engine", selection: Binding(get: { draft.dictationEngine.title }, set: { title in
                    if let engine = DictationEngine.allCases.first(where: { $0.title == title }) { draft.dictationEngine = engine }
                }), choices: DictationEngine.allCases.map(\.title))
            }
            cardOption("Hold right ⌘ to dictate", detail: "release inserts, ↩ sends, esc cancels; a tap starts conversation mode until the next tap",
                       detailBelow: true) {
                settingToggle("Hold right ⌘ to dictate", isOn: $draft.dictationRightCommand)
                    .accessibilityIdentifier("settings-dictation-right-command")
            }
            cardOption("Navigate by voice", detail: "say “\(wakeWord), …” to switch spaces and tabs or the sidebar: “\(wakeWord), billing tab 2”, “\(wakeWord), back”, “\(wakeWord), hide sidebar”",
                       detailBelow: true) {
                settingToggle("Navigate by voice", isOn: $draft.dictationNavigation)
                    .accessibilityIdentifier("settings-dictation-navigation")
            }
            cardOption("Wake words", detail: "what voice commands start with, in chat and everywhere else; one word each, separated by commas",
                       detailBelow: true) {
                if draft.dictationWakeWords != VoiceCommand.defaultWakeWords {
                    Button("Restore default") { draft.dictationWakeWords = VoiceCommand.defaultWakeWords }
                        .buttonStyle(.plain).font(typography.font(offset: -1.5)).foregroundStyle(accent)
                        .accessibilityIdentifier("settings-wake-words-restore")
                }
            }
            WakeWordsSetting(words: $draft.dictationWakeWords, engine: draft.dictationEngine, model: draft.whisperModel)
            cardOption("Read replies aloud", detail: "in conversation mode: this chat's replies and questions, and a word when other agents finish or need you",
                       detailBelow: true, privacy: "Anyone nearby hears the replies, permission requests and questions.") {
                settingToggle("Read replies aloud", isOn: $draft.dictationReadReplies)
                    .accessibilityIdentifier("settings-dictation-read-replies")
            }
            if draft.dictationEngine == .whisper {
                ForEach(WhisperModel.allCases) { model in
                    VStack(spacing: 0) {
                        separator
                        WhisperModelRow(model: model, selected: draft.whisperModel == model) { draft.whisperModel = model }
                            .padding(.vertical, 7)
                    }
                }
                Text("models come from huggingface.co and stay on this Mac. Click a downloaded model to use it.")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
            }
        }.accessibilityIdentifier("settings-dictation")
    }

    /// Where new spaces start: Home, or a folder chosen under Custom… (listed by its path once chosen), like Shell.
    private var startingFolderRow: some View {
        let home = System.home.path, path = draft.startingDirectory
        let homeTitle = "Home (~)", customTitle = "Custom…"
        let shown = path == home ? homeTitle : path.replacingOccurrences(of: home, with: "~")
        return row("Starting folder", detail: "new spaces start here; new tabs follow the current folder") {
            dropdown("Starting folder", selection: Binding(get: { shown }, set: { choice in
                switch choice {
                case homeTitle: draft.startingDirectory = home
                case customTitle: chooseFolder()
                default: break
                }
            }), choices: [homeTitle] + (path == home ? [] : [shown]) + [customTitle])
            .help(path)
        }
    }

    /// What new local tabs run: the login shell, a shell /etc/shells lists, or a command typed under Custom….
    /// SSH, tmux and herdr tabs keep their own.
    @ViewBuilder private var shellRow: some View {
        let login = "Login shell" + (System.machine.launch.shell.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")
        let custom = customShell != nil || (!draft.shell.isEmpty && !shells.contains(draft.shell))
        let missing = draft.shellProgram.map { !$0.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: $0) } ?? false
        row("Shell", detail: missing ? "not found; new tabs use the login shell" : "new local tabs") {
            dropdown("Shell", selection: Binding(get: { custom ? "Custom…" : draft.shell.isEmpty ? login : draft.shell }, set: { choice in
                switch choice {
                case login: customShell = nil; draft.shell = ""
                case "Custom…": customShell = draft.shell
                default: customShell = nil; draft.shell = choice
                }
            }), choices: [login] + shells + ["Custom…"])
        }
        if custom {
            HStack(spacing: 8) {
                TextField("/opt/homebrew/bin/fish -l", text: Binding(get: { customShell ?? draft.shell }, set: { customShell = $0 }))
                    .textFieldStyle(.roundedBorder).font(typography.font(offset: -0.5, design: .monospaced))
                    .onSubmit { if let customShell { draft.shell = customShell.trimmingCharacters(in: .whitespaces) } }
                    .accessibilityIdentifier("settings-custom-shell")
            }.padding(.bottom, 9)
            Text("A program by its full path, then its arguments. Press Return to use it.")
                .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
        }
    }

    /// The shells /etc/shells lists that exist here.
    /// bash, sh and zsh, the first of each /etc/shells lists that exists; any other shell goes under Custom….
    static var listedShells: [String] {
        let text = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        let listed = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        return ["bash", "sh", "zsh"].compactMap { name in listed.first { ($0 as NSString).lastPathComponent == name } }
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
            settingsGroup("Option key") {
                row("Option as Alt", detail: "any other Option key types characters such as é, or @ and { on some layouts") {
                    dropdown("Option as Alt", selection: Binding(get: { draft.optionAsAlt.title }, set: { title in
                        if let keys = OptionKeys.allCases.first(where: { $0.title == title }) { draft.optionAsAlt = keys }
                    }), choices: OptionKeys.allCases.map(\.title))
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

    /// How SSH connections behave and each machine's choices, this Mac first, with its agent hooks; Chat mode itself
    /// is under Features.
    private var hostSettings: some View {
        VStack(spacing: 8) {
            SSHHostsSettings(workspace: workspace, permissions: sshPermissions, resetting: resettingSSH) {
                if hasActiveSSHConnections() { confirmingSSHReset = true } else { resetHosts() }
            }
        }.task { TerminalRuntime.shared.chat.loadLaunches() }
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

    /// Chat mode's agents, counted in its header until opened.
    private var agentFold: Fold {
        let chat = TerminalRuntime.shared.chat
        return Fold(title: "Agents", on: chat.listedLaunches.filter { !chat.disabledIntegrations.contains($0.key) }.count,
                    isExpanded: $agentsExpanded)
    }

    /// A card's options folded under its header, whose button counts those switched on and opens them.
    struct Fold {
        let title: String
        /// How many are switched on; nil for options that aren't switches.
        let on: Int?
        let isExpanded: Binding<Bool>
    }

    private func toggle(_ fold: Fold) {
        withAnimation(.snappy(duration: 0.22)) { fold.isExpanded.wrappedValue.toggle() }
    }

    private func foldButton(_ fold: Fold, card: String) -> some View {
        let open = fold.isExpanded.wrappedValue
        return Button { toggle(fold) } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                if let on = fold.on { Text("\(on)").font(typography.font(offset: -2.5)).monospacedDigit() }
            }
            .foregroundStyle(open ? Chrome.ink : SettingsControlStyle.detail)
            .padding(.horizontal, 8).frame(height: 24)
            .background(open ? SettingsControlStyle.selected : SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border, lineWidth: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(fold.title)
        .accessibilityLabel(fold.title).accessibilityValue(fold.on.map { "\($0) on" } ?? "")
        .accessibilityIdentifier("settings-options-\(card)")
    }

    private func agentRow(_ launch: HelperClient.Launch) -> some View {
        let chat = TerminalRuntime.shared.chat
        return cardOption(launch.label) {
            settingToggle(launch.label, isOn: Binding(get: { !chat.disabledIntegrations.contains(launch.key) },
                                                      set: { chat.setHelperIntegration(launch.key, enabled: $0) }), compact: true)
                .accessibilityIdentifier("settings-agent-toggle-\(launch.key)")
        }.accessibilityIdentifier("settings-agent-\(launch.key)")
    }

    private var chatEnabled: Binding<Bool> {
        Binding(get: { TerminalRuntime.shared.chat.enabled }, set: { TerminalRuntime.shared.chat.setEnabled($0) })
    }


    private func restoreDefaults() {
        draft = Preferences()
        keyError = nil
        customShell = nil
        // Chat mode (Features) and this Mac's agent hooks (Hosts) restore together: the agents install their hooks here
        // again.
        if selectedTab == .hosts || selectedTab == .features {
            // This Mac's agent hooks first, so restoring the agents installs them here again.
            let chat = TerminalRuntime.shared.chat
            chat.localHooks = [:]
            chat.setEnabled(true)
            chat.restoreHelperIntegrations()
        }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        SettingsGroup(title: title, content: content)
    }

    /// A feature's card: its switch, if it has one, in the header, its options below; folded, they show once its button
    /// opens them.
    private func integrationCard<Options: View>(_ title: String, detail: String, privacy: String? = nil, enabled: Binding<Bool>? = nil,
                                                fold: Fold? = nil, hasOptions: Bool = true,
                                                @ViewBuilder options: () -> Options) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // A folded card's title opens it too.
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsTitle(title: title, privacy: privacy).fontWeight(.semibold)
                            .foregroundStyle(SettingsControlStyle.selectedText)
                        Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).onTapGesture { if let fold { toggle(fold) } }
                if let fold { foldButton(fold, card: title) }
                // A card without a switch keeps its place, so the option buttons line up.
                settingToggle(title, isOn: enabled ?? .constant(false))
                    .opacity(enabled == nil ? 0 : 1).allowsHitTesting(enabled != nil).accessibilityHidden(enabled == nil)
            }.padding(.horizontal, 14).padding(.vertical, 11)
            if hasOptions && fold?.isExpanded.wrappedValue != false {
                separator
                VStack(spacing: 0, content: options)
                    .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 4)
                    .disabled(enabled?.wrappedValue == false)
            }
        }.background(Chrome.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Chrome.border) }
            .opacity(enabled?.wrappedValue == false ? 0.5 : 1)
    }

    /// A card's option: its detail beside the title, or below it (wrapping) for a longer one.
    private func cardOption<Control: View>(_ title: String, detail: String? = nil, detailBelow: Bool = false,
                                           privacy: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            if detailBelow {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsTitle(title: title, privacy: privacy).font(typography.font(offset: -0.5))
                    if let detail {
                        Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SettingsTitle(title: title, privacy: privacy).font(typography.font(offset: -0.5))
                    if let detail { Text(detail).font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            control()
        }.padding(.vertical, 7)
    }

    /// The commands whose sessions a multiplexer's switch opens as spaces, for the multiplexers Dispatch knows; the
    /// card's footer says what happens to the tab that started one.
    private func sessionDetail(_ name: String) -> String? {
        let commands = ["tmux": "tmux -CC or tmux -CC attach", "herdr": "herdr or herdr session attach"]
        return commands[name]
    }


    private var separator: some View { SettingsSeparator() }


    /// An indented row depends on the row above it.
    private func row<Control: View>(_ title: String, detail: String? = nil, indented: Bool = false, privacy: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        SettingsRow(title: title, detail: detail, indented: indented, privacy: privacy, control: control)
    }

    /// The light or the dark schemes, then those that read as either below a separator. A saved choice from the
    /// other side still shows (the dropdown adds its selection).
    /// Custom schemes for that side (or either) come first, then the bundled ones.
    /// The schemes for the current vision; colorblind modes leave out Match app theme, whose colors aren't made for it.
    private func themePicker(_ title: String, selection: Binding<String>, light: Bool) -> some View {
        let schemes = schemes.filtered(for: draft.colorVision)
        let side = light ? schemes.light : schemes.dark
        let custom = schemes.custom.filter { $0.light == nil || $0.light == light }.map(\.name)
        let groups = [custom, side, schemes.either].filter { !$0.isEmpty }
        let choices = groups.flatMap { [SettingsDropdown.separator] + $0 }
        return dropdown(title, selection: Binding(
            get: { selection.wrappedValue == "Default" ? "Match app theme" : selection.wrappedValue },
            set: { selection.wrappedValue = $0 == "Match app theme" ? "Default" : $0 }),
            choices: draft.colorVision == .typical ? ["Match app theme"] + choices : Array(choices.dropFirst()))
    }

    /// After the vision changes, a scheme that isn't for it gives way: to the vision's own light or dark scheme, or,
    /// leaving colorblind mode, to Match app theme.
    private func conformSchemes(to vision: ColorVision) {
        let pair = ColorSchemes.colorblind[vision]
        if ColorSchemes.vision(of: draft.lightTheme) != vision { draft.lightTheme = pair?.light.first ?? "Default" }
        if ColorSchemes.vision(of: draft.theme) != vision { draft.theme = pair?.dark.first ?? "Default" }
    }

    /// Why a chosen scheme isn't used: its file is gone.
    private func missingScheme(_ name: String) -> String? {
        name == "Default" || !ThemeResolution.value(for: name).missing ? nil : "“\(name)” not found; using Dispatch’s own"
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

struct SettingsDropdown: NSViewRepresentable {
    /// A choice that draws as the menu's separator line.
    static let separator = ""
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTypography) private var typography
    let title: String
    @Binding var selection: String
    let choices: [String]
    let fontName: ((String) -> String)?
    let fontScale: ((String) -> CGFloat)?
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    /// The width it is given, never the longest menu item's: a long theme or profile name truncates instead of
    /// spilling over the control beside it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: proposal.height ?? 27)
    }

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
            button.removeAllItems()
            for title in items {
                if title == Self.separator { button.menu?.addItem(.separator()) } else { button.addItem(withTitle: title) }
            }
        }
        if let fontName {
            for item in button.itemArray where !item.isSeparatorItem {
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

/// The bundled terminal color schemes sorted by their background: dark ones, light ones, and those that read as either
/// (no background, or one near the middle), which both pickers offer below the rest.
struct ColorSchemes {
    var dark: [String] = [], light: [String] = [], either: [String] = []
    /// The user's own (CustomThemes), listed first.
    var custom: [CustomThemes.Entry] = []

    /// The bundled schemes made for color blindness, by vision, light first: listed only in that colorblind mode.
    static let colorblind: [ColorVision: (light: [String], dark: [String])] = [
        .redGreen: (["GitHub Light Colorblind", "Modus Operandi Deuteranopia"], ["GitHub Dark Colorblind", "Modus Vivendi Deuteranopia"]),
        .blueYellow: (["Modus Operandi Tritanopia"], ["Modus Vivendi Tritanopia"]),
    ]

    /// Who a scheme is for: a bundled colorblind scheme's vision, or the vision a made scheme's recipe names.
    static func vision(of name: String) -> ColorVision {
        if let bundled = colorblind.first(where: { $0.value.light.contains(name) || $0.value.dark.contains(name) }) {
            return bundled.key
        }
        return CustomThemes.theme(named: name).flatMap(ThemeRecipe.init(theme:))?.vision ?? .typical
    }

    /// Only the schemes for `vision`: colorblind modes list their own schemes; typical vision lists none of them.
    func filtered(for vision: ColorVision) -> ColorSchemes {
        var schemes = self
        let made = Dictionary(uniqueKeysWithValues: custom.map { ($0.name, Self.vision(of: $0.name)) })
        schemes.custom = custom.filter { made[$0.name] == vision }
        if let own = Self.colorblind[vision] {
            schemes.light = light.filter(own.light.contains)
            schemes.dark = dark.filter(own.dark.contains)
            schemes.either = []
        } else {
            let all = Set(Self.colorblind.values.flatMap { $0.light + $0.dark })
            schemes.light = light.filter { !all.contains($0) }
            schemes.dark = dark.filter { !all.contains($0) }
        }
        return schemes
    }

    init() {}

    init(directory: URL, custom: [CustomThemes.Entry] = CustomThemes.list()) {
        self.custom = custom
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "Default" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            switch Self.side(text) {
            case true?: light.append(name)
            case false?: dark.append(name)
            case nil: either.append(name)
            }
        }
    }

    /// true: light, false: dark, nil: either. A background darker than its text and well below the middle is dark;
    /// lighter than its text and well above it, light.
    static func side(_ theme: String) -> Bool? {
        let rgb = { (c: (Double, Double, Double)) in ThemeColor(red: c.0, green: c.1, blue: c.2) }
        guard let background = color("background", in: theme).map(rgb) else { return nil }
        return TerminalTheme.side(background: background, foreground: color("foreground", in: theme).map(rgb))
    }

    /// A `key = #rrggbb` line's color as 0...1 components.
    static func color(_ key: String, in theme: String) -> (Double, Double, Double)? {
        for line in theme.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { continue }
            var hex = parts[1].hasPrefix("#") ? String(parts[1].dropFirst()) : parts[1]
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
            return (Double(value >> 16 & 0xFF) / 255, Double(value >> 8 & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
        return nil
    }
}
