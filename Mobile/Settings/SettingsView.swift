import SwiftUI

/// Settings (not in the mockup; plan Phase 6): appearance, the terminal's default font size, per host Chat and the
/// multiplexer, background refresh, and Remove all data. Opened from the end of Spaces' edit mode, beside Add host,
/// where hosts are managed: the headers of M2a and M3a stay as the mockup draws them.
struct SettingsView: View {
    let composition: MobileComposition
    @Bindable var settings: MobileSettings
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
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
                    Picker("Font size", selection: $settings.terminalFontSize) {
                        ForEach(settings.fontSizeChoices, id: \.self) { Text(MobileSettings.fontSizeLabel($0)).tag($0) }
                    }
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Terminals open at this size. Pinch a terminal to zoom it; the last size becomes the default.")
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
                                Text(session.host.chat ? "Chat on" : "Chat off")
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

                Section {
                    Button("Remove all data", role: .destructive) { confirmingRemoval = true }
                        .confirmationDialog("Remove all data?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                            Button("Remove all data", role: .destructive) {
                                composition.removeAllData()
                                dismiss()
                            }
                        } message: {
                            Text(MobileComposition.removeAllMessage)
                        }
                } footer: {
                    Text(MobileComposition.removeAllMessage)
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

/// One host's settings: Chat and the multiplexer (the same control as host detail).
struct HostSettingsView: View {
    let hostID: UUID
    @Environment(HostSessions.self) private var sessions

    var body: some View {
        if let session = sessions.session(hostID) {
            Form {
                Section {
                    Toggle("Chat", isOn: Binding(get: { session.host.chat }, set: { chat in
                        var host = session.host
                        host.chat = chat
                        sessions.update(host)
                    }))
                } footer: {
                    Text("Off: Dispatch's helper runs on \(session.host.name) without agent hooks, and its agents show as terminals only. Turning Chat on again reconnects.")
                }
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
            .navigationTitle(session.host.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Color.clear
        }
    }
}

extension MobileComposition {
    static let removeAllMessage = "Removes every host, the keys and passwords in the Keychain, trusted host keys, read markers, cached lists, drafts, queued messages and remembered models from this iPhone. Nothing changes on your hosts."

    /// Settings' Remove all data: every host (its session ends, its password goes), every key and Keychain secret, the
    /// trusted host keys, the seen markers and mutes, the cache, drafts and the outbox, the remembered agents and models
    /// (`chat-models.json`) and Spaces' per-host values (recent space, collapsed hosts, space order: `spaces.json`, and
    /// any left in UserDefaults by an older build); background refresh turns off and its notifications go. Appearance,
    /// the font sizes and Spaces' menu stay.
    func removeAllData() {
        settings.backgroundRefresh = false
        refresh?.schedule()
        refresh?.notifier.removeAll()
        for record in hosts.store.hosts { hosts.remove(record.id) }
        hosts.knownHosts.removeAll()
        for key in hosts.keys.keys { hosts.keys.delete(key.id) }
        try? hosts.keys.vault.removeAll()
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
