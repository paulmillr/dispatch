import Dictation
import SwiftUI

/// Settings (not in the mockup; plan Phase 6): appearance, the terminal's default font size, per host Chat and the
/// multiplexer, background refresh, and Remove all data. Opened from the end of Spaces' edit mode, beside Add host,
/// where hosts are managed: the headers of M2a and M3a stay as the mockup draws them.
struct SettingsView: View {
    let composition: MobileComposition
    @Bindable var settings: MobileSettings
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    /// The removal waiting for confirmation: everything, or everything but the SSH keys.
    @State private var confirmingRemoval: MobileComposition.Removal?
    /// Why background refresh stayed off (notifications not allowed).
    @State private var refreshNote: String?

    init(composition: MobileComposition) {
        self.composition = composition
        settings = composition.settings
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(MobileSettings.Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
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
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Terminals open at this size. Pinch a terminal to zoom it; the last size becomes the default.")
                }

                Section {
                    NavigationLink {
                        DictationSettingsView(settings: settings)
                    } label: {
                        LabeledContent("Dictation") {
                            Text(settings.dictationEngine == .whisper ? "Whisper \(settings.whisperModel.title)" : settings.dictationEngine.title)
                        }
                    }
                } header: {
                    Text("Chat")
                }

                Section {
                    if sessions.ordered.isEmpty {
                        Text("No hosts yet. Add one in Spaces.").foregroundStyle(.secondary)
                    }
                    ForEach(sessions.ordered) { session in
                        NavigationLink {
                            HostSettingsView(hostID: session.id)
                        } label: {
                            LabeledContent(session.host.name) {
                                Text(!session.host.helper ? HostSummary.plainSSH : session.host.chat ? "Chat on" : "Chat off")
                            }
                        }
                    }
                } header: {
                    Text("Hosts")
                }

                Section {
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
                        Text("About every 15 minutes, as iOS allows, Dispatch connects to the hosts with Chat on and notifies you when an agent needs you. Hosts that log in with a key behind Face ID are skipped: iOS shows no Face ID in the background.")
                        if let refreshNote { Text(refreshNote).foregroundStyle(.red) }
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
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

/// One host's settings: Chat and the multiplexer (the same control as host detail).
struct HostSettingsView: View {
    let hostID: UUID
    @Environment(HostSessions.self) private var sessions
    /// The host's stats sheet (W1).
    @State private var statsHost: UUID?

    var body: some View {
        if let session = sessions.session(hostID) {
            Form {
                Section {
                    Button { statsHost = hostID } label: {
                        Label("Stats", systemImage: "chart.xyaxis.line")
                    }
                    .accessibilityHint("Shows CPU, memory, disk and processes of \(session.host.name)")
                }
                Section {
                    Toggle("Chat", isOn: Binding(get: { session.host.chat }, set: { chat in
                        var host = session.host
                        host.chat = chat
                        sessions.update(host)
                    }))
                    // Chat needs the helper (`HostRecord.chat`): host detail's Helper switch turns it back on.
                    .disabled(!session.host.helper)
                } footer: {
                    if session.host.helper {
                        Text("Off: Dispatch's helper runs on \(session.host.name) without agent hooks, and its agents show as terminals only. Turning Chat on again reconnects.")
                    } else {
                        Text("\(session.host.name) uses plain SSH without the helper, so it has no Chat. Turn the helper on in the host's details to use Chat.")
                    }
                }
                // A plain SSH host has no multiplexer's spaces.
                if session.host.helper {
                    Section {
                        if session.multiplexerLine == "none" {
                            LabeledContent("Multiplexer") { Text("none").monospaced() }
                        } else {
                            HostMultiplexerPicker(session: session)
                        }
                    } footer: {
                        Text("Automatic follows herdr while its server runs, else tmux.")
                    }
                }
            }
            .navigationTitle(session.host.name)
            .navigationBarTitleDisplayMode(.inline)
            .hostStatsSheet(host: $statsHost)
        } else {
            Color.clear
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
            case .everything: "Removes every host, the keys and passwords in the Keychain, trusted host keys, read markers, cached lists, drafts, queued messages and remembered models from this \(MobileDevice.name). Nothing changes on your hosts."
            case .keepingKeys: "Removes every host, their passwords, trusted host keys, read markers, cached lists, drafts, queued messages and remembered models from this \(MobileDevice.name). Your SSH keys and their passphrases stay, for new hosts. Nothing changes on your hosts."
            }
        }
    }

    /// Settings' Remove all data: every host (its session ends, its password goes), every key and Keychain secret, the
    /// trusted host keys, the seen markers and mutes, the cache, drafts and the outbox, the remembered agents and models
    /// (`chat-models.json`) and Spaces' per-host values (recent space, collapsed hosts, space order: `spaces.json`, and
    /// any left in UserDefaults by an older build); background refresh turns off and its notifications go. Appearance,
    /// the font sizes and Spaces' menu stay. `keepingKeys`: the SSH keys, their Keychain items (private keys and
    /// passphrases) stay too; host passwords still go.
    func removeAllData(keepingKeys: Bool = false) {
        settings.backgroundRefresh = false
        refresh?.schedule()
        refresh?.notifier.removeAll()
        for record in hosts.store.hosts { hosts.remove(record.id) }
        hosts.knownHosts.removeAll()
        if keepingKeys {
            let kept = Set(hosts.keys.keys.flatMap { [KeyStore.privateAccount($0.id), KeyStore.passphraseAccount($0.id)] })
            try? hosts.keys.vault.removeAll(keeping: kept.contains)
        } else {
            for key in hosts.keys.keys { hosts.keys.delete(key.id) }
            try? hosts.keys.vault.removeAll()
        }
        conversations.markers.removeAll()
        conversations.outbox.removeAll()
        for key in conversations.drafts.buckets.keys { conversations.drafts.remove(key) }
        conversations.drafts.flush()
        cache.removeAll()
        modelMemory.removeAll()
        tabs.removeDeviceState()
        MobileFiles.removeUnreadable()
    }
}
