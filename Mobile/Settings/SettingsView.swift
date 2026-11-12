import Dictation
import SwiftUI

/// Settings (G1): appearance and the colour scheme, the terminal's font (G2), size, line spacing and contrast, chat's
/// font (G3) and dictation, notifications (G5) and background refresh, Hosts (host colours, unsafe pastes; a host's own
/// choices are in Edit host), the Apple Watch, and last Remove all data. Opened from the end of
/// Spaces' edit mode, beside Add host, where hosts are managed: the headers of M2a and M3a stay as the mockup draws them.
struct SettingsView: View {
    let composition: MobileComposition
    @Bindable var settings: MobileSettings
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    /// The removal waiting for confirmation: everything, or everything but the SSH keys.
    @State private var confirmingRemoval: MobileComposition.Removal?
    /// Why background refresh stayed off (notifications not allowed).
    @State private var refreshNote: String?
    @AppStorage(MobileSettings.gitBranchesKey) private var showGitBranches = false
    /// The pushed screens (G2 to G5, and Color scheme).
    @State private var path: [Route]

    /// Settings' pushed screens.
    enum Route: Hashable {
        case terminalFont, terminalScheme, chatFont, notifications
    }

    init(composition: MobileComposition) {
        self.composition = composition
        settings = composition.settings
        _path = State(initialValue: Self.initialPath)
    }

    /// Screenshot launches (Debug): `-DispatchSettingsShow G2|G3|G5|scheme` opens that screen (G1: Settings itself).
    private static var initialPath: [Route] {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "DispatchSettingsShow") {
        case "G2": return [.terminalFont]
        case "G3": return [.chatFont]
        case "G5": return [.notifications]
        case "scheme": return [.terminalScheme]
        default: return []
        }
        #else
        return []
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Group {
                    Section {
                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(MobileSettings.Appearance.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        NavigationLink(value: Route.terminalScheme) {
                            LabeledContent("Color scheme") { Text(TerminalSchemes.title(settings.terminalScheme)) }
                        }
                        // As the Mac's: on picks red-green, the most common; the picker below refines it.
                        Toggle("Colorblind-friendly", isOn: Binding(get: { settings.colorVision != .typical },
                                                                    set: { settings.colorVision = $0 ? .redGreen : .typical }))
                        if settings.colorVision != .typical {
                            Picker("Color blindness", selection: $settings.colorVision) {
                                ForEach([ColorVision.redGreen, .blueYellow]) { Text($0.title).tag($0) }
                            }
                        }
                    } header: {
                        Text("Appearance")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if settings.colorVision != .typical {
                                Text("Host colors, changes and Color scheme's list are made for \(settings.colorVision.title.lowercased()) color blindness (\(settings.colorVision.detail)).")
                            }
                        }
                    }

                    Section {
                        NavigationLink(value: Route.terminalFont) {
                            LabeledContent("Font") { Text(settings.terminalFont) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("Font size") { Text(MobileSettings.fontSizeLabel(settings.terminalFontSize)).monospacedDigit() }
                            Slider(value: $settings.terminalFontSize, in: MobileSettings.fontSizeRange, step: 1) {
                                Text("Font size")
                            } minimumValueLabel: {
                                Image(systemName: "textformat.size.smaller")
                            } maximumValueLabel: {
                                Image(systemName: "textformat.size.larger")
                            }
                            .accessibilityValue(MobileSettings.fontSizeLabel(settings.terminalFontSize))
                        }
                        // The terminal's rows and chat's lines together, as on the Mac.
                        Picker("Line spacing", selection: $settings.lineSpacing) {
                            ForEach(LineSpacing.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Improve text contrast", selection: $settings.textContrast) {
                            ForEach(TextContrast.allCases) { Text($0.title).tag($0) }
                        }
                    } header: {
                        Text("Terminal")
                    } footer: {
                        Text("Terminals open at this size, larger or smaller with the system text size. Pinch a terminal to zoom it; the last size becomes the default.")
                    }

                    Section {
                        NavigationLink(value: Route.chatFont) {
                            LabeledContent("Font") { Text(settings.chatFont.rawValue) }
                        }
                        Picker("While the agent works", selection: $settings.chatSendWhileWorking) {
                            ForEach(ChatSendWhileWorking.allCases) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("settings-chat-send-while-working")
                        Picker("Open agents in", selection: $settings.chatAgentStart) {
                            ForEach(ChatAgentStart.allCases) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("settings-chat-agent-start")
                        NavigationLink {
                            DictationSettingsView(settings: settings)
                        } label: {
                            LabeledContent("Dictation") {
                                Text(settings.dictationEngine.label(whisper: settings.whisperModel))
                            }
                        }
                        NavigationLink {
                            SpeechVoiceSettingsView(settings: settings)
                        } label: {
                            LabeledContent("Voice") { Text(SpeechVoice.label(settings.speechVoice)) }
                        }
                        .accessibilityIdentifier("settings-chat-voice")
                    } header: {
                        Text("Chat")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("While the agent works, send queues a message for after the turn, or steers it into the turn; its long press offers the other.")
                            Text("With a hardware keyboard, editor mode's Return adds a line and ⌘Return sends; a multi-line paste turns it on, ⌘E switches it.")
                            Text("Open agents in picks what an agent tab shows first; the tab's switch shows the other. Esc twice keeps a stray Esc from a hardware keyboard from stopping the agent.")
                            Text("Swipe the conversation to the left to see when each reply came and what a turn changed, as in Messages.")
                            Text("Voice is what conversation mode and Read Aloud speak in.")
                        }
                    }

                    Section {
                        NavigationLink(value: Route.notifications) {
                            LabeledContent("Notifications") { Text(settings.notificationSummary) }
                        }
                        Toggle("Background refresh", isOn: Binding(get: { settings.backgroundRefresh }, set: { enabled in
                            refreshNote = nil
                            Task {
                                let now = await composition.refresh?.setEnabled(enabled) ?? false
                                if enabled, !now {
                                    refreshNote = "Allow notifications for Dispatch in the Settings app to use background refresh."
                                }
                            }
                        }))
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("About every 15 minutes, as iOS allows, Dispatch connects to the hosts with Chat on and notifies you as Notifications says. Hosts that log in with a Secure Enclave key are skipped: it asks for Face ID, which iOS shows only in the foreground.")
                            if let refreshNote { Text(refreshNote).foregroundStyle(.red) }
                        }
                    }

                    Section {
                        if !sessions.ordered.isEmpty {
                            Toggle("Color-code hosts", isOn: $settings.showHostColors)
                        }
                        Toggle("Show git branches", isOn: $showGitBranches)
                            .accessibilityIdentifier("settings-git-branches")
                        Toggle("Automatically approve unsafe pastes", isOn: $settings.autoApproveUnsafePastes)
                            .accessibilityIdentifier("settings-auto-approve-unsafe-pastes")
                    } header: {
                        Text("Hosts")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if !sessions.ordered.isEmpty {
                                Text("With Color-code hosts off, every host is gray.")
                            }
                            Text("Show git branches puts each space's branch beside its name in Spaces.")
                            Text("Turn off unsafe pastes to confirm pastes that could run commands immediately. Ordinary bracketed pastes never ask.")
                        }
                    }

                    if let watch = composition.watch {
                        Section {
                            LabeledContent("Apple Watch") { Text(watch.status.pairing.label) }
                        } footer: {
                            Text(Self.watchFooter(watch.status.pairing))
                        }
                    }

                    Section {
                        ForEach(MobileComposition.Removal.allCases) { removal in
                            Button(removal.title, role: .destructive) { confirmingRemoval = removal }
                        }
                    } footer: {
                        Text(MobileComposition.removeAllMessage + " Except SSH keys keeps your SSH keys and their passphrases.")
                    }
                    .confirmationDialog(confirmingRemoval.map { $0.title + "?" } ?? "", isPresented: Binding(
                        get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }
                    ), titleVisibility: .visible, presenting: confirmingRemoval) { removal in
                        Button(removal.title, role: .destructive) {
                            composition.removeAllData(keepingKeys: removal == .keepingKeys)
                            dismiss()
                        }
                    } message: { removal in
                        Text(removal.message)
                    }
                }
                // The cards (`Color.groupedRow`), also in a sheet, whose own rows are a shade lighter.
                .listRowBackground(Color.groupedRow)
            }
            // The canvas, as Spaces': black in dark (the mockup's G1).
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Settings")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .terminalFont: TerminalFontSettingsView(settings: settings)
                case .terminalScheme: TerminalSchemeSettingsView(settings: settings)
                case .chatFont: ChatFontSettingsView(settings: settings)
                case .notifications: NotificationSettingsView(composition: composition)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

extension SettingsView {
    /// Under the Apple Watch row (docs/watch.md, Consent): uninstalling the watch app is the off switch.
    static func watchFooter(_ pairing: WatchPairing) -> String {
        switch pairing {
        case .notPaired: "Pair an Apple Watch to see your agents and answer them from your wrist."
        case .notInstalled: "Install Dispatch from the Watch app on this iPhone to see your agents and answer them from your wrist."
        case .installed: "Your watch shows your agents and spaces. Opening a conversation there connects its host from this iPhone, also in the background; remove Dispatch from the watch to stop that."
        }
    }
}

extension MobileComposition {
    static let removeAllMessage = Removal.everything.message

    /// Settings' two removals.
    enum Removal: String, CaseIterable, Identifiable {
        case everything, keepingKeys
        var id: Self { self }
        var title: String {
            switch self { case .everything: "Remove all data"; case .keepingKeys: "Remove all data except SSH keys" }
        }
        var message: String {
            switch self {
            case .everything: "Removes every host, the keys and passwords in the Keychain, trusted host keys, read markers, cached lists, drafts, review comments, queued messages and remembered models from this \(MobileDevice.name). Nothing changes on your hosts."
            case .keepingKeys: "Removes every host, their passwords, trusted host keys, read markers, cached lists, drafts, review comments, queued messages and remembered models from this \(MobileDevice.name). Your SSH keys and their passphrases stay, for new hosts. Nothing changes on your hosts."
            }
        }
    }

    /// Settings' Remove all data: every host (its session ends, its password goes), every key and Keychain secret, the
    /// trusted host keys, the seen markers and mutes, the cache, drafts and the outbox, the transcripts kept in memory,
    /// the review comments
    /// (`reviews.json`), the remembered agents and models (`chat-models.json`) and Spaces' per-host values (recent space, collapsed hosts, space order: `spaces.json`, and
    /// any left in UserDefaults by an older build); background refresh turns off and its notifications and the badge
    /// go. Appearance, the theme, the fonts and font sizes, the notification switches and Spaces' menu stay. `keepingKeys`: the SSH keys, their Keychain items (private keys and
    /// passphrases) stay too; host passwords still go.
    func removeAllData(keepingKeys: Bool = false) {
        settings.backgroundRefresh = false
        refresh?.schedule()
        refresh?.notifier.removeAll()
        for record in hosts.store.hosts { hosts.remove(record.id) }
        hosts.knownHosts.removeAll()
        if keepingKeys {
            // A key's `moving:` copy too: after a move out of Face ID cut short it can be the key's only copy.
            let kept = Set(hosts.keys.keys.flatMap { [KeyStore.privateAccount($0.id), KeyStore.passphraseAccount($0.id),
                                                      KeyStore.movingPrefix + KeyStore.privateAccount($0.id)] })
            try? hosts.keys.vault.removeAll(keeping: kept.contains)
        } else {
            for key in hosts.keys.keys { hosts.keys.delete(key.id) }
            try? hosts.keys.vault.removeAll()
        }
        conversations.markers.removeAll()
        conversations.outbox.removeAll()
        // Gone with their hosts already (`ChatConversations.remove`); in memory only either way.
        conversations.forgetTranscripts()
        for key in conversations.drafts.buckets.keys { conversations.drafts.remove(key) }
        conversations.drafts.flush()
        cache.removeAll()
        modelMemory.removeAll()
        review.removeAll()
        tabs.removeDeviceState()
        MobileFiles.removeUnreadable()
    }
}
