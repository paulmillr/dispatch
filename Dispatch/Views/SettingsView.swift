import Dictation
import SwiftUI
import CoreText

/// Compact settings grouped into General (text, the window and terminals, notifications), Theme, Features, Keyboard,
/// Extra (imports, export and troubleshooting), and Hosts.
struct SettingsView: View {
    // Keep the controls stable while the user adjusts content typography: a point under the app's default.
    private let typography = SettingsView.typography
    static let typography = AppTypography(contentSize: 13)
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
    @State private var selectedTab = SettingsTab.general
    @State private var schemes = ColorSchemes()
    @State private var fonts: [String] = []
    @State private var agentsExpanded = false
    @State private var filesOptionsExpanded = false
    @State private var multiplexersExpanded = false
    @State private var remoteHelperExpanded = false
    @State private var dictationExpanded = false
    @State private var windowExpanded = false
    @State private var newTabsExpanded = false
    /// Startup command as typed, saved on Return.
    @State private var startupDraft: String?
    @State private var fontExpanded = false
    @State private var sizeExpanded = false
    @State private var notificationsExpanded = false
    @State private var securityExpanded = false
    /// /etc/shells, read when Settings opens.
    @State private var shells: [String] = []
    /// Custom… chosen in Shell: the command being typed, saved on Return.
    @State private var customShell: String?

    private var accent: Color { Chrome.accent }
    private var pickerWidth: CGFloat { typography.expanded(200) }
    /// A slider's value beside it, the same in every slider row so the sliders line up.
    private var sliderValueWidth: CGFloat { typography.expanded(60) }

    /// Families the menu never lists: Latin Modern Mono Light ships only as Latin Modern Mono's bold
    /// (ChatFont.boldPostScriptName).
    static let hiddenFontFamilies: Set<String> = ["Andale Mono", "Courier New", "Latin Modern Mono Light"]

    /// More bundled coding fonts, listed under a separator after the main list (the default, Dispatch's own fonts and
    /// the installed ones). Commit Mono and Rec Mono don't mark themselves monospaced, so they are listed by name.
    static let moreBundledFontFamilies = ["Cascadia Code", "CommitMono", "Geist Mono", "Hack", "Hasklig", "IBM Plex Mono",
                                          "Inconsolata", "Intel One Mono", "Latin Modern Mono", "Maple Mono", "Rec Mono Casual",
                                          "Victor Mono"]

    static var moreFontFamilies: [String] {
        AppFont.register()
        return moreBundledFontFamilies.filter { NSFontManager.shared.availableMembers(ofFontFamily: $0) != nil }
    }

    /// The terminal font menu: the default (Source Code Pro) first, then the monospaced fonts installed on this Mac, a
    /// separator, and the rest of Dispatch's own fonts, each part by name.
    static var fontMenuChoices: [String] {
        let all = monospacedFontFamilies, lead = all.first.map { [$0] } ?? []
        let installed = all.dropFirst().filter { !AppFont.bundledFamilies.contains($0) }
        let own = (all.dropFirst().filter(AppFont.bundledFamilies.contains) + moreFontFamilies)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return lead + installed + [SettingsDropdown.separator] + own
    }

    /// Every terminal font Settings offers, for the importers.
    static var terminalFontFamilies: [String] { monospacedFontFamilies + moreFontFamilies }

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
            guard !hiddenFontFamilies.contains(family), !moreBundledFontFamilies.contains(family) else { return false }
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
                case .general: generalSettings
                case .theme: themeSettings
                case .keyboard: keySettings
                case .extra:
                    VStack(spacing: 8) {
                        SettingsExtraPage(draft: $draft, schemesChanged: reloadSchemes)
                        experimentalSettings
                        troubleshootingSettings
                    }
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
            fonts = Self.fontMenuChoices
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
        case general = "General"
        case theme = "Theme"
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

    /// Text; then the window and terminals: the window around them, what survives a relaunch, how terminals behave and
    /// what programs in them may do, with the rows few change folded under their options buttons; then where new spaces
    /// start and what they run. Every row applies immediately. Colors are under Theme; whole features, notifications
    /// included, are under Features; troubleshooting is under Extra.
    private var generalSettings: some View {
        VStack(spacing: 8) {
            settingsGroup("Text") {
                fontRow
                sizeRow
                // The shape, and whether it blinks as a checked item below the shapes.
                row("Cursor", detail: draft.cursorBlink ? "blinking" : "steady") {
                    dropdown("Cursor", selection: Binding(get: { draft.cursor.title }, set: { title in
                        if title == Self.blinkingCursor { draft.cursorBlink.toggle() }
                        else if let cursor = TerminalCursor.allCases.first(where: { $0.title == title }) { draft.cursor = cursor }
                    }), choices: TerminalCursor.allCases.map(\.title) + [SettingsDropdown.separator, Self.blinkingCursor],
                             checked: draft.cursorBlink ? [Self.blinkingCursor] : [])
                        .help("Programs can still choose their own cursor")
                }
            }
            settingsGroup("Terminal") {
                launchRow
                row("Scrollback", detail: draft.scrollback == .automatic ? "sized to this Mac’s RAM · new tabs" : "history each new tab keeps") {
                    dropdown("Scrollback", selection: Binding(get: { draft.scrollback.title }, set: { title in
                        if let size = Scrollback.allCases.first(where: { $0.title == title }) { draft.scrollback = size }
                    }), choices: Scrollback.allCases.map(\.title))
                        .help("Unlimited keeps every line until the tab closes, in memory.")
                }
                windowOptions
                newTabOptions
                securityOptions
            }
        }
    }

    /// Features that are off by default while they prove themselves; on the Extra page, above Troubleshooting.
    private var experimentalSettings: some View {
        settingsGroup("Experimental") {
            row("Slow connection mode", detail: "keeps typing and Chat responsive while a tab floods · tmux and herdr · new connections",
                info: "Each helper started after you change this sends at most 256 KB of terminal output before Dispatch confirms it has drawn it, so a tab printing flat out on a slow connection cannot park megabytes in the link ahead of your keystrokes, Ctrl-C or a Chat reply. The printing program pauses briefly on the host while it waits; nothing is lost, and that tab may look choppier on a slow connection. On a fast connection you will notice no difference. Applies to tmux and herdr tabs: on remote hosts at their next login or reconnect, locally after Dispatch restarts.") {
                settingToggle("Slow connection mode", isOn: $draft.outputWindow)
                    .accessibilityIdentifier("settings-output-window")
                    .help("Off: output streams as fast as the connection takes it. On: at most 256 KB in flight per connection.")
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

    /// Text's first row: the terminal's font, with chat's and text contrast folded under its options button. Only the button opens it: a
    /// tap on the row would reach the dropdown too.
    @ViewBuilder private var fontRow: some View {
        let fold = Fold(title: "Ligatures, chat font and contrast", changed: changed { [AnyHashable($0.fontLigatures), $0.chatFont, $0.textContrast] },
                        isExpanded: $fontExpanded)
        row("Font", detail: "installed fonts too · chat: \(chatFontName)") {
            // The button beside a dropdown as wide as every other, so the column lines up, folds included.
            HStack(spacing: 8) {
                foldButton(fold, card: "Font")
                dropdown("Terminal font", selection: $draft.fontFamily, choices: fonts, fontName: { $0 })
                    .help("Dispatch's fonts and every monospaced font installed on this Mac")
            }
        }
        if fontExpanded {
            foldedOptions {
                cardOption("Ligatures", detail: "-> and != drawn as one symbol, in fonts that have them", detailBelow: true) {
                    settingToggle("Ligatures", isOn: $draft.fontLigatures)
                        .accessibilityIdentifier("settings-font-ligatures")
                }
                cardOption("Chat font", detail: "Same as code follows the font above", detailBelow: true) {
                    dropdown("Chat font", selection: Binding(get: { draft.chatFont.rawValue }, set: {
                        if let choice = ChatFont(rawValue: $0) { draft.chatFont = choice }
                    }), choices: ChatFont.allCases.map(\.rawValue), fontName: { title in
                        // Each choice in its own face: the system's designs from previewFont, only Same as code in the terminal's.
                        switch ChatFont(rawValue: title) {
                        case let font?: font.postScriptName ?? draft.fontFamily
                        case nil: draft.fontFamily
                        }
                    }, fontScale: { ChatFont(rawValue: $0)?.sizeScale ?? 1 },
                       previewFont: { title, size in ChatFont(rawValue: title)?.systemFont(ofSize: size) })
                }
                cardOption("Improve text contrast", detail: "brightens faint colors, keeps their hue", detailBelow: true) {
                    dropdown("Improve text contrast", selection: Binding(get: { draft.textContrast.title }, set: { title in
                        if let contrast = TextContrast.allCases.first(where: { $0.title == title }) { draft.textContrast = contrast }
                    }), choices: TextContrast.allCases.map(\.title))
                        .accessibilityIdentifier("improve-text-contrast")
                        .help("Raises faint terminal text to 4.5:1 against its background. Applies at once to open terminals.")
                }
            }
        }
    }

    /// Chat's font as Font's detail names it: SF for the system's, the terminal's for Same as code.
    private var chatFontName: String {
        switch draft.chatFont {
        case .system: "SF"
        case .sameAsCode: draft.fontFamily
        default: draft.chatFont.rawValue
        }
    }

    /// Text's second row: the size of terminal and chat text, with their line spacing folded under its options button,
    /// which alone opens it (a row tap would reach the slider).
    @ViewBuilder private var sizeRow: some View {
        let fold = Fold(title: "Line spacing", changed: changed { [$0.lineSpacing] }, isExpanded: $sizeExpanded)
        row("Size", detail: "\(draft.lineSpacing.title.lowercased()) line spacing") {
            // The button beside a slider row as wide as every other, Line spacing's below included.
            HStack(spacing: 8) {
                foldButton(fold, card: "Size")
                HStack(spacing: 12) {
                    SettingsSlider(value: $draft.fontSize, range: 8...22, step: 0.5, label: "Font size",
                                   identifier: "settings-font-size").frame(height: 20)
                        .help("8–22 pt · 0.5 pt steps")
                    (Text(draft.fontSize.formatted(.number.precision(.fractionLength(0...1))))
                        .foregroundColor(Chrome.ink) + Text(" pt").foregroundColor(Chrome.muted))
                        .font(typography.font(offset: -0.5)).monospacedDigit().fixedSize()
                        .frame(width: sliderValueWidth, alignment: .trailing)
                }.frame(width: pickerWidth)
            }
        }
        if sizeExpanded {
            foldedOptions {
                cardOption("Line spacing", detail: "terminal rows and chat lines", detailBelow: true) {
                    let order = LineSpacing.allCases
                    let spacing = { (value: Double) in order[min(order.count - 1, max(0, Int(value.rounded())))] }
                    HStack(spacing: 12) {
                        SettingsSlider(value: Binding(get: { Double(order.firstIndex(of: draft.lineSpacing) ?? 1) },
                                                      set: { draft.lineSpacing = spacing($0) }),
                                       range: 0...Double(order.count - 1), step: 1, label: "Line spacing",
                                       identifier: "settings-line-spacing", stops: true, describe: { spacing($0).title })
                            .frame(height: 20)
                        Text(draft.lineSpacing.title).foregroundColor(Chrome.ink)
                            .font(typography.font(offset: -0.5)).fixedSize()
                            .frame(width: sliderValueWidth, alignment: .trailing)
                    }.frame(width: pickerWidth)
                }
            }
        }
    }

    /// The Cursor menu's checked item, below the shapes.
    private static let blinkingCursor = "Blinking"

    /// Terminal's row above Security: the window around the terminals, folded like it; its title opens it too. The
    /// labels first (tab names, git branches), then the sidebar's options, then the chrome's. The detail leads with tab
    /// names and git branches, the options most come looking for.
    @ViewBuilder private var windowOptions: some View {
        // Switches that can't be changed here (git off, no Liquid Glass on this system) aren't counted.
        let fold = Fold(title: "Window", changed: changed {
            [$0.automaticTabNames, $0.sidebarStyle, $0.hideSingleSpace, $0.tabsOnly, $0.showHostColors] + (draft.gitEnabled ? [$0.showGitBranches] : [])
                + (LiquidGlassStore.supported ? [$0.liquidGlass] : [])
        }, isExpanded: $windowExpanded)
        row("Window", detail: "tab names, git branches, host colors and glass") { foldButton(fold, card: "Window") }
            .contentShape(Rectangle()).onTapGesture { toggle(fold) }
        if windowExpanded {
            foldedOptions {
                cardOption("Automatic tab names", detail: "an agent's title, a program's own, or the folder", detailBelow: true) {
                    settingToggle("Automatic tab names", isOn: $draft.automaticTabNames)
                        .help("An agent's conversation title, a running program's own title, or the folder at an idle prompt. Off shows the terminal title. Renamed tabs keep their names.")
                }
                cardOption("Show git branch", detail: draft.gitEnabled ? "each folder's current branch, in the sidebar" : "needs Git, in Features › Files",
                           detailBelow: true) {
                    settingToggle("Show git branch", isOn: $draft.showGitBranches)
                        .disabled(!draft.gitEnabled)
                        .accessibilityIdentifier("show-git-branch")
                }
                // From the densest list to the roomiest, read out by name.
                cardOption("Space size") {
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
                            .frame(width: sliderValueWidth, alignment: .trailing)
                    }.frame(width: pickerWidth)
                }
                // Off by default: one space needs no sidebar until asked for (the setting is stored as hiding).
                cardOption(draft.tabsOnly ? "Show with one tab" : "Show with one space") {
                    settingToggle("Show with one space", isOn: Binding(get: { !draft.hideSingleSpace }, set: { draft.hideSingleSpace = !$0 }))
                }
                cardOption("Disable spaces", detail: "the sidebar lists tabs, no tab strips", detailBelow: true) {
                    settingToggle("Disable spaces", isOn: $draft.tabsOnly)
                        .accessibilityIdentifier("settings-tabs-only")
                        .help("Lists every tab in the sidebar instead of tab strips. ⌘T adds a tab and ⌘1…9 jump through the list.")
                }
                Rectangle().fill(SettingsControlStyle.border).frame(height: 0.5).padding(.vertical, 6)
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
            }
        }
    }

    /// The app theme, opacity and colorblind mode; then every color scheme for each side in use, drawn in its own
    /// colors, a click choosing it; then New…, Add File… and Import….
    private var themeSettings: some View {
        VStack(spacing: 8) {
            settingsGroup("Colors") {
                row("App theme", detail: SidebarThemeStore.shared.nauticalUnlocked || draft.appTheme == .nautical ? "⚓ Nautical unlocked" : "app, terminal and chat") {
                    dropdown("Theme", selection: Binding(get: { draft.appTheme.label }, set: { label in
                        if let theme = AppTheme.allCases.first(where: { $0.label == label }) { draft.appTheme = theme }
                    }), choices: AppTheme.offered(selected: draft.appTheme,
                                                  nauticalUnlocked: SidebarThemeStore.shared.nauticalUnlocked).map(\.label))
                }
                row("Terminal opacity", detail: draft.terminalOpacity < 1 ? "the desktop shows through terminals" : nil) {
                    HStack(spacing: 12) {
                        SettingsSlider(value: $draft.terminalOpacity, range: Preferences.terminalOpacityRange, step: 0.05,
                                       label: "Terminal opacity", identifier: "settings-terminal-opacity").frame(height: 20)
                        Text(draft.terminalOpacity.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundColor(Chrome.ink).font(typography.font(offset: -0.5)).monospacedDigit().fixedSize()
                            .frame(width: sliderValueWidth, alignment: .trailing)
                    }.frame(width: pickerWidth)
                }
                row("Colorblind-friendly", detail: "lists and makes only colorblind-safe schemes") {
                    settingToggle("Colorblind-friendly", isOn: Binding(get: { draft.colorVision != .typical },
                                                                       set: { draft.colorVision = $0 ? .redGreen : .typical }))
                        .accessibilityIdentifier("settings-colorblind")
                }
                if draft.colorVision != .typical {
                    // Indented under Colorblind-friendly, which it refines.
                    row("Color blindness", detail: draft.colorVision.detail, indented: true) {
                        dropdown("Color blindness", selection: Binding(
                            get: { draft.colorVision.title },
                            set: { title in
                                if let vision = ColorVision.allCases.first(where: { $0.title == title }) { draft.colorVision = vision }
                            }), choices: [ColorVision.redGreen, .blueYellow].map(\.title))
                    }
                }
            }
            // Each side in use, dark first while the theme follows the system.
            ColorSchemeGallery(draft: $draft, schemes: schemes.filtered(for: draft.colorVision),
                               sides: draft.appTheme == .automatic ? [false, true]
                                   : [!draft.appTheme.isDark(systemIsDark: SidebarThemeStore.systemIsDark)],
                               matching: matchingScheme(light:), schemesChanged: reloadSchemes,
                               importSchemes: { selectedTab = .extra }, surprise: surpriseScheme(light:),
                               allCustom: schemes.custom.count)
        }
    }

    /// The Dispatch tile's colors on the `light` or dark side: dispatch-black under the app theme's own palette, as the
    /// terminal draws it (TerminalRuntime's config).
    private func matchingScheme(light: Bool) -> TerminalTheme? {
        TerminalTheme(text: Self.dispatchBlack + "\n" + draft.appTheme.sidebarTheme(systemIsDark: !light).defaultColorSchemeOverrides)
    }

    private static let dispatchBlack = (try? String(contentsOf: System.resources.appendingPathComponent("ghostty/themes/dispatch-black"),
                                                    encoding: .utf8)) ?? ""

    /// Surprise me: a new random scheme for the `light` or dark side (and the colorblind mode), in place of that side's last
    /// surprise, used at once.
    private func surpriseScheme(light: Bool) {
        let dark = !light
        // Seeded from System so a replayed test sees the same surprise.
        let bytes = System.uuid().uuid
        let seed = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        do {
            let name = try SurpriseScheme.make(light: !dark, vision: draft.colorVision, seed: seed)
            reloadSchemes()
            if dark { draft.theme = name } else { draft.lightTheme = name }
        } catch { self.error = "Could not make a random scheme: \(error.localizedDescription)" }
    }

    /// The schemes on disk changed (made, edited, added, imported, deleted): list them again, and let terminals and chat
    /// read the scheme in use again, which may be the one that changed under the same name.
    private func reloadSchemes() {
        schemes = ColorSchemes(directory: System.resources.appendingPathComponent("ghostty/themes"))
        try? TerminalRuntime.shared.apply(TerminalRuntime.shared.preferences)
    }

    /// Whole features, each with its options: Chat mode and its agents, tmux and herdr sessions as spaces, files mode
    /// and git, attention notifications, the remote helper, and dictation.
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
                            fold: Fold(title: "Multiplexers", changed: changed { preferences in multiplexers.map { preferences.spaces[on: $0] } },
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
            // Git (review mode, the commit log and the sidebar's branch names) is one of Files' options.
            integrationCard("Files", detail: "list, preview, drag · git with review mode · ⇧⌘F",
                            enabled: $draft.filesEnabled,
                            fold: Fold(title: "Options",
                                       changed: changed { [$0.gitEnabled, $0.filesDragAndDrop, $0.filesShowHidden, $0.filesPreviews,
                                                           $0.filesLineNumbers, $0.filesWrapLines] },
                                       isExpanded: $filesOptionsExpanded)) {
                cardOption("Git", detail: "review mode, commit log and the sidebar's branch names", detailBelow: true) {
                    settingToggle("Git", isOn: $draft.gitEnabled)
                        .accessibilityIdentifier("settings-git")
                }
                cardOption("Drag and drop", detail: "copy files to and from Finder, or onto a terminal as paths",
                           detailBelow: true) {
                    settingToggle("Drag and drop", isOn: $draft.filesDragAndDrop)
                        .accessibilityIdentifier("settings-files-drag-and-drop")
                }
                cardOption("Show hidden files", detail: "dotfiles and ignored folders; ⇧⌘. toggles per tab", detailBelow: true) {
                    settingToggle("Show hidden files", isOn: $draft.filesShowHidden)
                        .accessibilityIdentifier("settings-files-show-hidden")
                }
                cardOption("Disable file previews", detail: "the list only: no file is opened to show it", detailBelow: true) {
                    settingToggle("Disable file previews", isOn: Binding(get: { !draft.filesPreviews }, set: { draft.filesPreviews = !$0 }))
                        .accessibilityIdentifier("settings-files-disable-previews")
                }
                cardOption("Line numbers", detail: "beside the lines of a previewed file", detailBelow: true) {
                    settingToggle("Line numbers", isOn: $draft.filesLineNumbers)
                        .disabled(!draft.filesPreviews)
                        .accessibilityIdentifier("settings-files-line-numbers")
                }
                cardOption("Wrap lines", detail: "long lines wrap in the preview; its wrap button sets each tab", detailBelow: true) {
                    settingToggle("Wrap lines", isOn: $draft.filesWrapLines)
                        .disabled(!draft.filesPreviews)
                        .accessibilityIdentifier("settings-files-wrap-lines")
                }
            }
                .accessibilityIdentifier("settings-files")
            // One switch for banners and the Dock badge (either one still on, an older split choice, shows it on); the
            // rest folded until asked for.
            integrationCard("Notifications", detail: "dock badge and banner below tabs",
                            enabled: Binding(get: { draft.attentionNotifications || draft.attentionDockBadge },
                                             set: { draft.attentionNotifications = $0; draft.attentionDockBadge = $0 }),
                            fold: Fold(title: "Options",
                                       changed: changed { [$0.attentionSound, $0.attentionTextContent] + (draft.appTheme == .nautical ? [$0.shipsBell] : []) },
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
                        fold: Fold(title: "Options", changed: changed { [$0.autoGrantNewHosts, $0.autoReconnectSSH] },
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

    /// Chat dictation's engine; choosing Whisper lists its models to download and pick from, choosing Parakeet shows its
    /// one.
    private var dictationSettings: some View {
        integrationCard("Dictation", detail: "always local & on-device",
                        privacy: "Listens only while you dictate; audio stays in memory. The text goes into the draft, which is saved.",
                        enabled: $draft.dictationEnabled,
                        fold: Fold(title: "Options",
                                   changed: changed {
                                       [$0.dictationEngine, $0.dictationNavigation, $0.dictationWakeWords,
                                        $0.dictationReadReplies] + (draft.dictationEngine == .whisper ? [$0.whisperModel] : [])
                                   },
                                   isExpanded: $dictationExpanded)) {
            cardOption("Engine", detail: "Apple: macOS language · Whisper: many · Parakeet: 25 European",
                       detailBelow: true) {
                dropdown("Dictation engine", selection: Binding(get: { draft.dictationEngine.title }, set: { title in
                    if let engine = DictationEngine.allCases.first(where: { $0.title == title }) { draft.dictationEngine = engine }
                }), choices: DictationEngine.allCases.map(\.title))
            }
            cardOption("Navigate by voice", detail: "say “\(wakeWord), …” to switch spaces, tabs or the sidebar\ne.g. “\(wakeWord), billing tab 2”, “\(wakeWord), hide sidebar”",
                       detailBelow: true) {
                settingToggle("Navigate by voice", isOn: $draft.dictationNavigation)
                    .accessibilityIdentifier("settings-dictation-navigation")
            }
            cardOption("Wake words", detail: "what voice commands start with · one word each",
                       detailBelow: true) {
                if draft.dictationWakeWords != VoiceCommand.defaultWakeWords {
                    Button("Restore default") { draft.dictationWakeWords = VoiceCommand.defaultWakeWords }
                        .buttonStyle(.plain).font(typography.font(offset: -1.5)).foregroundStyle(accent)
                        .accessibilityIdentifier("settings-wake-words-restore")
                }
            }
            WakeWordsSetting(words: $draft.dictationWakeWords, engine: draft.dictationEngine, model: draft.whisperModel)
            cardOption("Read replies aloud", detail: "in conversation mode: this chat's replies and questions,\nand a word when other agents finish or need you",
                       detailBelow: true, privacy: "Anyone nearby hears the replies, permission requests and questions.") {
                settingToggle("Read replies aloud", isOn: $draft.dictationReadReplies)
                    .accessibilityIdentifier("settings-dictation-read-replies")
            }
            if draft.dictationEngine == .whisper {
                ForEach(WhisperModel.allCases) { model in
                    VStack(spacing: 0) {
                        separator
                        DictationModelRow(model: .whisper(model), selected: draft.whisperModel == model) { draft.whisperModel = model }
                            .padding(.vertical, 7)
                    }
                }
                Text("from huggingface.co, kept on this Mac · click a downloaded one to use it")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
            } else if draft.dictationEngine == .parakeet {
                separator
                DictationModelRow(model: .parakeet, selected: true) {}
                    .padding(.vertical, 7)
                Text("NVIDIA's Parakeet TDT 0.6B v3 (CC BY 4.0) as Core ML models converted by FluidInference,\nfrom huggingface.co, kept on this Mac · runs on the Neural Engine")
                    .font(typography.font(offset: -1.5)).foregroundStyle(SettingsControlStyle.detail)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 9)
            }
        }.accessibilityIdentifier("settings-dictation")
    }

    /// Where new spaces start, what new local tabs run and what they type first, folded like Window; the detail reads
    /// out the folder, the shell and the command, so folding hides the controls but not where they stand.
    @ViewBuilder private var newTabOptions: some View {
        let fold = Fold(title: "New tabs", changed: changed { [$0.startingDirectory, $0.shell, $0.startupCommand] }, isExpanded: $newTabsExpanded)
        let folder = draft.startingDirectory == "/" ? "/" : draft.startingDirectory.replacingOccurrences(of: System.home.path, with: "~")
        let shell = draft.shellProgram.map { ($0 as NSString).lastPathComponent } ?? "login shell"
        let command = draft.startupCommand.trimmingCharacters(in: .whitespaces)
        row("New tabs", detail: ([folder, shell] + (command.isEmpty ? [] : ["runs \(command)"])).joined(separator: " · ")) {
            foldButton(fold, card: "New tabs")
        }
            .contentShape(Rectangle()).onTapGesture { toggle(fold) }
            .accessibilityIdentifier("settings-new-tabs")
        if newTabsExpanded {
            foldedOptions {
                startingFolderOption
                shellOption
                startupCommandOption
            }
        }
    }

    /// Where new spaces start: Home, the root folder, or a folder chosen under Custom… (listed by its path once chosen).
    private var startingFolderOption: some View {
        let home = System.home.path, path = draft.startingDirectory
        let homeTitle = "Home (~)", rootTitle = "Root (/)", customTitle = "Custom…"
        let shown = path == home ? homeTitle : path == "/" ? rootTitle : path.replacingOccurrences(of: home, with: "~")
        return cardOption("Starting folder", detail: "where new spaces start", detailBelow: true) {
            dropdown("Starting folder", selection: Binding(get: { shown }, set: { choice in
                switch choice {
                case homeTitle: draft.startingDirectory = home
                case rootTitle: draft.startingDirectory = "/"
                case customTitle: chooseFolder()
                default: break
                }
            }), choices: [homeTitle, rootTitle] + (path == home || path == "/" ? [] : [shown]) + [customTitle])
            .help(path)
        }
    }

    /// A line typed into each new local shell as it starts, saved on Return.
    @ViewBuilder private var startupCommandOption: some View {
        cardOption("Startup command", detail: "typed into each new local shell; empty types nothing", detailBelow: true) {
            TextField("tmux new -A -s main", text: Binding(get: { startupDraft ?? draft.startupCommand }, set: { startupDraft = $0 }))
                .textFieldStyle(.roundedBorder).font(typography.font(offset: -0.5, design: .monospaced))
                .frame(width: pickerWidth)
                .onSubmit {
                    if let startupDraft { draft.startupCommand = startupDraft.trimmingCharacters(in: .whitespaces) }
                    startupDraft = nil
                }
                .accessibilityIdentifier("settings-startup-command")
                .help("Typed at the first prompt of new local tabs, as if you had. SSH, tmux and herdr tabs are left alone. Press Return to use it.")
        }
    }

    /// A chosen shell that isn't an executable here; tabs use the login shell instead.
    private var shellMissing: Bool {
        draft.shellProgram.map { !$0.hasPrefix("/") || !FileManager.default.isExecutableFile(atPath: $0) } ?? false
    }

    /// What comes back at launch, as one choice over Reopen spaces and Restore tab history, which needs it: nothing, the
    /// spaces, or the spaces with their tabs' previous output. A step down deletes what it no longer keeps: the saved
    /// session, or the saved output.
    private var launchRow: some View {
        let fresh = "Start fresh", spaces = "Reopen spaces", history = "Reopen spaces and history"
        let shown = !draft.rememberHosts ? fresh : draft.restoreTerminalOutput ? history : spaces
        let detail = switch shown {
        case fresh: "new spaces each time"
        case history: "spaces, tabs and their output"
        default: "spaces, tabs and splits"
        }
        return row("On launch", detail: detail, privacy: "Keeps your spaces, tabs, folders and SSH destinations in a private file on this Mac. No passwords, keys or commands. "
            + "With history, also writes everything local and plain SSH tabs showed to disk on quit, including any secrets you typed or printed.") {
            dropdown("On launch", selection: Binding(get: { shown }, set: { choice in
                draft.rememberHosts = choice != fresh
                draft.restoreTerminalOutput = choice == history
            }), choices: [fresh, spaces, history])
                .accessibilityIdentifier("settings-on-launch")
                .help("Local shells restart in their last folder; remote hosts reopen disconnected. History saves the text of local and plain SSH tabs when Dispatch quits normally, for the next launch only, excluded from backups and ignored after a week. Start fresh deletes the saved session; leaving history deletes the saved output. Open tabs stay available.")
        }
    }

    /// What programs in terminals may do, folded like Window; its title opens it too. The detail reads out each switch's
    /// state, so folding hides the switches but not where they stand, the permissive default included.
    @ViewBuilder private var securityOptions: some View {
        let fold = Fold(title: "Security", changed: changed { [$0.allowClipboardWrites, $0.autoApproveUnsafePastes, $0.secureKeyboardEntry, $0.enableKittyGraphics] },
                        isExpanded: $securityExpanded)
        let state = [draft.allowClipboardWrites ? "programs can copy" : "no clipboard writes",
                     draft.autoApproveUnsafePastes ? "pastes approved" : "unsafe pastes ask",
                     draft.secureKeyboardEntry ? "secure keyboard" : "keyboard not secured",
                     draft.enableKittyGraphics ? "kitty images" : "no images"]
        row("Security", detail: state.joined(separator: " · "),
            privacy: "What programs in any tab, and other apps, can reach: your clipboard, your keystrokes and files on this Mac.") {
            foldButton(fold, card: "Security")
        }
            .contentShape(Rectangle()).onTapGesture { toggle(fold) }
        if securityExpanded {
            foldedOptions {
                cardOption("Programs can copy", detail: "to your clipboard, via OSC 52", detailBelow: true,
                           privacy: "Any program in any tab, remote hosts included, can replace your clipboard without asking.") {
                    settingToggle("Programs can copy", isOn: $draft.allowClipboardWrites)
                        .accessibilityIdentifier("settings-remote-clipboard")
                        .help("OSC 52, the kitty clipboard protocol and tmux buffers, in local and remote tabs alike. Programs can never read your clipboard.")
                }
                cardOption("Automatically approve unsafe pastes", detail: "off asks before a paste could run commands", detailBelow: true,
                           privacy: "Line breaks outside bracketed paste and embedded paste terminators can execute commands immediately. Ordinary bracketed pastes never ask.") {
                    settingToggle("Automatically approve unsafe pastes", isOn: $draft.autoApproveUnsafePastes)
                        .accessibilityIdentifier("settings-auto-approve-unsafe-pastes")
                }
                cardOption("Secure keyboard entry", detail: "other apps can't read what you type", detailBelow: true,
                           privacy: "While Dispatch is the active app, apps with Input Monitoring see none of your keystrokes, passwords included. Some text expanders and keyboard tools stop working meanwhile.") {
                    settingToggle("Secure keyboard entry", isOn: $draft.secureKeyboardEntry)
                        .accessibilityIdentifier("settings-secure-keyboard-entry")
                }
                cardOption("Kitty graphics", detail: "images in terminal; less secure", detailBelow: true,
                           privacy: "Output in a local tab can make Dispatch open any file on this Mac you can read.") {
                    settingToggle("Kitty graphics", isOn: $draft.enableKittyGraphics)
                        .help("Kitty's image protocol. Any output in a local tab, even a file you cat, can make Dispatch open a file on this Mac and decode it as an image; remote tabs can only send image data.")
                }
            }
        }
    }

    /// What new local tabs run: the login shell, a shell /etc/shells lists, or a command typed under Custom….
    /// SSH, tmux and herdr tabs keep their own.
    @ViewBuilder private var shellOption: some View {
        let login = "Login shell" + (System.machine.launch.shell.map { " (\(($0 as NSString).lastPathComponent))" } ?? "")
        let custom = customShell != nil || (!draft.shell.isEmpty && !shells.contains(draft.shell))
        cardOption("Shell", detail: shellMissing ? "not found; using the login shell" : "what new local tabs run", detailBelow: true) {
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
                    Text("click, then hold the modifiers and release · ⌫ removes · esc cancels")
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
            settingsGroup("Key bindings") {
                row("Prefix keys", detail: "⌃B, then a key; ⌃B twice sends ⌃B") {
                    dropdown("Prefix keys", selection: Binding(get: { draft.prefixKeys.label }, set: { label in
                        if let spaces = PrefixSpaces.allCases.first(where: { $0.label == label }) { draft.prefixKeys = spaces }
                    }), choices: PrefixSpaces.allCases.map(\.label))
                    .help("tmux and herdr spaces answer their tool's own keys; other spaces tmux's: c new tab, n/p next/previous tab, % and \" split, x close pane, d detach.")
                    .accessibilityIdentifier("settings-prefix-keys")
                }
                row("Dictate", detail: voiceKeyDetail) {
                    dropdown("Voice key", selection: Binding(get: { draft.dictationKey.title }, set: { title in
                        if let key = VoiceKey.allCases.first(where: { $0.title == title }) { draft.dictationKey = key }
                    }), choices: VoiceKey.allCases.map(\.title))
                    .disabled(!draft.dictationEnabled)
                    .accessibilityIdentifier("settings-voice-key")
                }
                if draft.dictationEnabled, draft.dictationKey == .function {
                    Text("macOS answers 🌐 too. To leave it to Dispatch, choose Do Nothing in System Settings › Keyboard › Press 🌐 key to.")
                        .font(typography.font(offset: -1.5)).foregroundStyle(Chrome.palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
                        .accessibilityIdentifier("settings-voice-key-globe")
                }
                row("Option as Alt", detail: "the other Option key types é, @, {") {
                    dropdown("Option as Alt", selection: Binding(get: { draft.optionAsAlt.title }, set: { title in
                        if let keys = OptionKeys.allCases.first(where: { $0.title == title }) { draft.optionAsAlt = keys }
                    }), choices: OptionKeys.allCases.map(\.title))
                }
            }
        }
    }

    /// What holding and tapping the voice key do, and what else may answer it.
    private var voiceKeyDetail: String {
        guard draft.dictationEnabled else { return "Dictation is off in Features" }
        switch draft.dictationKey {
        case .off: return "the mic beside Send still works"
        default: return "hold: message · tap: conversation"
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
        // Every agent is on unless turned off here.
        return Fold(title: "Agents", changed: chat.listedLaunches.filter { chat.disabledIntegrations.contains($0.key) }.count,
                    isExpanded: $agentsExpanded)
    }

    /// A card's options folded under its header, whose button opens them and counts those changed from a fresh
    /// install's, so a number says something here was set.
    struct Fold {
        let title: String
        /// How many options differ from their defaults; none shows no number.
        let changed: Int
        let isExpanded: Binding<Bool>
    }

    /// How many of the options `values` reads differ between the draft and the defaults.
    private func changed(_ values: (Preferences) -> [AnyHashable]) -> Int {
        zip(values(draft), values(Preferences())).filter { $0 != $1 }.count
    }

    /// A fold's options, opened under its row or card header: recessed into the page's color, so they read as that
    /// row's own rather than rows of their own. Opening and closing don't animate the layout (see the transition).
    private func foldedOptions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, foldInset).padding(.vertical, 2)
            .background(Chrome.window, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Chrome.border, lineWidth: 0.5) }
            // Out into the group's margin by as much as it pads its options, so their titles and controls line up
            // with the rows above.
            .padding(.horizontal, -foldInset)
            .padding(.bottom, 8)
            // The rows below move at once and the well fades in: rows sliding down over it would cross its text.
            .transition(.opacity.animation(.easeOut(duration: 0.15)))
    }

    /// How far a fold's well reaches into its group's 14-point margin, and pads its options by.
    private let foldInset: CGFloat = 8

    private func toggle(_ fold: Fold) {
        fold.isExpanded.wrappedValue.toggle()
    }

    private func foldButton(_ fold: Fold, card: String) -> some View {
        let open = fold.isExpanded.wrappedValue
        return Button { toggle(fold) } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .medium))
                if fold.changed > 0 { Text("\(fold.changed)").font(typography.font(offset: -2.5)).monospacedDigit() }
            }
            .foregroundStyle(open ? Chrome.ink : SettingsControlStyle.detail)
            .padding(.horizontal, 8).frame(height: 24)
            .background(open ? SettingsControlStyle.selected : SettingsControlStyle.fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsControlStyle.border, lineWidth: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(fold.title)
        .accessibilityLabel(fold.title).accessibilityValue(fold.changed > 0 ? "\(fold.changed) changed" : "")
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
                if fold != nil {
                    foldedOptions(options).padding(.horizontal, 14).disabled(enabled?.wrappedValue == false)
                } else {
                    separator
                    VStack(spacing: 0, content: options)
                        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 4)
                        .disabled(enabled?.wrappedValue == false)
                }
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
                                    info: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        SettingsRow(title: title, detail: detail, indented: indented, privacy: privacy, info: info, control: control)
    }

    /// After the vision changes, a scheme that isn't for it gives way: to the vision's own light or dark scheme, or,
    /// leaving colorblind mode, to Dispatch.
    private func conformSchemes(to vision: ColorVision) {
        let pair = ColorSchemes.colorblind[vision]
        if ColorSchemes.vision(of: draft.lightTheme) != vision { draft.lightTheme = pair?.light.first ?? "Default" }
        if ColorSchemes.vision(of: draft.theme) != vision { draft.theme = pair?.dark.first ?? "Default" }
    }


    private func dropdown(_ title: String, selection: Binding<String>, choices: [String],
                          fontName: ((String) -> String)? = nil,
                          fontScale: ((String) -> CGFloat)? = nil, checked: Set<String> = [],
                          previewFont: ((String, CGFloat) -> NSFont?)? = nil) -> some View {
        SettingsDropdown(title: title, selection: selection, choices: choices, fontName: fontName, fontScale: fontScale, checked: checked,
                         previewFont: previewFont)
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
    /// A choice that draws as a section header (a title that can't be chosen) above the choices after it.
    static func header(_ title: String) -> String { "\u{1}" + title }
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appTypography) private var typography
    let title: String
    @Binding var selection: String
    let choices: [String]
    let fontName: ((String) -> String)?
    let fontScale: ((String) -> CGFloat)?
    /// Items that are switches rather than choices, drawn checked: choosing one reaches `selection`, which toggles it
    /// and leaves the chosen item selected.
    var checked: Set<String> = []
    /// An item's face when it can't be found by name (the system font's designs), tried before `fontName`.
    var previewFont: ((String, CGFloat) -> NSFont?)? = nil
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
        let titles = items.map { $0.hasPrefix("\u{1}") ? String($0.dropFirst()) : $0 }
        if button.itemTitles != titles || button.itemArray.map(\.isSectionHeader) != items.map({ $0.hasPrefix("\u{1}") }) {
            button.removeAllItems()
            for (title, shown) in zip(items, titles) {
                if title == Self.separator { button.menu?.addItem(.separator()) }
                else if title.hasPrefix("\u{1}") { button.menu?.addItem(.sectionHeader(title: shown)) }
                else { button.addItem(withTitle: title) }
            }
        }
        if let fontName {
            for item in button.itemArray where !item.isSeparatorItem && !item.isSectionHeader {
                let size = typography.size(offset: -0.5) * (fontScale?(item.title) ?? 1)
                let name = fontName(item.title)
                let font = previewFont?(item.title, size)
                    ?? NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size)
                    ?? NSFont(name: name, size: size)
                    ?? .monospacedSystemFont(ofSize: size, weight: .regular)
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
        }
        // By index: a header may share a choice's title.
        button.selectItem(at: button.itemArray.firstIndex { $0.title == selection && !$0.isSectionHeader } ?? -1)
        for item in button.itemArray where item.title != selection { item.state = checked.contains(item.title) ? .on : .off }
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
    /// Each light or dark scheme's section in its picker.
    var groups: [String: SchemeGroup] = [:]
    /// The user's own (CustomThemes), listed first.
    var custom: [CustomThemes.Entry] = []
    /// Every listed scheme's colors, bundled and yours, by name: the gallery draws each in them.
    var themes: [String: TerminalTheme] = [:]
    /// The bundled schemes' problems (SchemeAudit), for those that have some: the gallery marks them.
    var problems: [String: [String]] = [:]

    /// The bundled schemes made for color blindness, by vision, light first: listed only in that colorblind mode.
    static let colorblind: [ColorVision: (light: [String], dark: [String])] = [
        .redGreen: (["GitHub Light Colorblind", "Modus Operandi Deuteranopia"], ["GitHub Dark Colorblind", "Modus Vivendi Deuteranopia"]),
        .blueYellow: (["Modus Operandi Tritanopia"], ["Modus Vivendi Tritanopia"]),
    ]

    /// Who a scheme is for: a bundled colorblind scheme's vision, or the vision a made scheme's recipe (or an edited one's
    /// file) names.
    static func vision(of name: String) -> ColorVision {
        if let bundled = colorblind.first(where: { $0.value.light.contains(name) || $0.value.dark.contains(name) }) {
            return bundled.key
        }
        // A made one's recipe names it; an edited one keeps the mode it was edited in.
        let theme = CustomThemes.theme(named: name)
        return theme.flatMap(ThemeRecipe.init(theme:))?.vision ?? theme.flatMap(ThemeEditorView.vision(in:)) ?? .typical
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
        for entry in custom { themes[entry.name] = CustomThemes.theme(named: entry.name) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "Default" }
            // By the name shown (Solarized Dark under S, not its file's iTerm2).
            .sorted { SchemeGroup.title($0).localizedStandardCompare(SchemeGroup.title($1)) == .orderedAscending }
        for name in names {
            let text = (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            themes[name] = TerminalTheme(text: text)
            if case let found = SchemeAudit.problems(name: name, theme: text), !found.isEmpty { problems[name] = found }
            if SchemeGroup.bothSides.contains(name) {
                (light, dark) = (light + [name], dark + [name])
                groups[name] = .fun
                continue
            }
            switch Self.side(text) {
            case true?:
                light.append(name)
                groups[name] = Self.group(name, theme: text, light: true)
            case false?:
                dark.append(name)
                groups[name] = Self.group(name, theme: text, light: false)
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

    /// A light or dark scheme's `SchemeGroup`, from its background and palette colors 1 to 6 (red to cyan).
    static func group(_ name: String, theme: String, light: Bool) -> SchemeGroup {
        var accents: [Int: (Double, Double, Double)] = [:]
        for line in theme.split(separator: "\n") {
            // palette = N=#rrggbb
            let parts = line.split(separator: "=", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, parts[0] == "palette", let index = Int(parts[1]), (1...6).contains(index) else { continue }
            accents[index] = color(parts[1], in: "\(parts[1]) = \(parts[2])")
        }
        return SchemeGroup.of(name, background: color("background", in: theme) ?? (0, 0, 0),
                              accents: (1...6).compactMap { accents[$0] }, light: light)
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
