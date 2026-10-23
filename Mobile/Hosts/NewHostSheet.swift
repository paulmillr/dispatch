import SwiftUI

/// New host (M8a, from Add host in Spaces), and Edit from host detail. Name, host and port, username, and Password or
/// Key file: the key list shows each key's type and SHA256 fingerprint to match against `authorized_keys`, the
/// checked one is used. Create connects once to verify, asking about the host key on first use inside the sheet,
/// and saves only when that connection succeeds; the verified connection becomes the host's session. Below them the
/// multiplexer, the Helper switch and Chat (`HostFeatureDraft`): with Helper off the host is plain SSH (docs/ios.md),
/// the multiplexer and Chat rows go and the words say that nothing is installed.
struct NewHostSheet: View {
    enum Method: Hashable { case password, key }

    let editing: HostRecord?
    /// Called with the saved host (M7a's "New host…" selects it).
    let created: (UUID) -> Void
    @Environment(HostSessions.self) private var sessions
    @Environment(\.dismiss) private var dismiss

    @State private var id: UUID
    @State private var name: String
    @State private var address: String
    @State private var port: String
    @State private var user: String
    @State private var method: Method
    @State private var password = ""
    @State private var keyID: UUID?
    @State private var importingKey = false
    @State private var creatingKey = false
    @State private var features: HostFeatureDraft
    /// The connection Create makes to verify the host; it becomes the host's session when it connects.
    @State private var probe: HostSession?
    @State private var failure: String?
    @FocusState private var focused: Field?

    private enum Field { case name, address, port, user, password }

    @State private var saved = false

    init(editing: HostRecord? = nil, created: @escaping (UUID) -> Void = { _ in }) {
        self.editing = editing
        self.created = created
        _id = State(initialValue: editing?.id ?? UUID())
        _name = State(initialValue: editing?.name ?? "")
        _address = State(initialValue: editing?.address ?? "")
        _port = State(initialValue: String(editing?.port ?? 22))
        _user = State(initialValue: editing?.user ?? "")
        _features = State(initialValue: HostFeatureDraft(editing))
        switch editing?.auth {
        case .key(let key)?:
            _method = State(initialValue: .key)
            _keyID = State(initialValue: key)
        case .password?:
            _method = State(initialValue: .password)
        case nil:
            _method = State(initialValue: .key)
        }
    }

    private var verifying: Bool { probe?.link.isPending == true }

    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { user.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The record the form describes, or nil while it is incomplete.
    private var record: HostRecord? {
        guard !trimmedAddress.isEmpty, !trimmedUser.isEmpty, let port = Int(port), (1...65_535).contains(port) else { return nil }
        let auth: HostRecord.Auth
        switch method {
        case .password:
            // Editing keeps the saved password when the field is left empty.
            guard !password.isEmpty || editing?.auth == .password else { return nil }
            auth = .password
        case .key:
            guard let keyID, sessions.keys.key(keyID) != nil else { return nil }
            auth = .key(keyID)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var record = editing ?? HostRecord(id: id, name: "", address: "", user: "", auth: auth)
        record.name = trimmedName.isEmpty ? String(trimmedAddress.split(separator: ".").first ?? Substring(trimmedAddress)) : trimmedName
        record.address = trimmedAddress
        record.port = port
        record.user = trimmedUser
        record.auth = auth
        features.apply(to: &record)
        return record
    }

    private static let failureRow = "failure"

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                Form {
                    Section {
                        TextField("studio", text: $name)
                            .focused($focused, equals: .name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .onSubmit { focused = .address }
                    } header: {
                        MobileSectionHeader("Name")
                    }
                    Section {
                        HStack(spacing: 12) {
                            TextField("studio.tail3f.ts.net", text: $address)
                                .focused($focused, equals: .address)
                                .monospaced()
                                .keyboardType(.URL)
                                .textContentType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Divider()
                            TextField("22", text: $port)
                                .focused($focused, equals: .port)
                                .monospaced()
                                .keyboardType(.numberPad)
                                .frame(width: 64)
                        }
                    } header: {
                        MobileSectionHeader("Host")
                    } footer: {
                        Text("Hostname or Tailscale name · port")
                    }
                    Section {
                        TextField("alex", text: $user)
                            .focused($focused, equals: .user)
                            .monospaced()
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        MobileSectionHeader("Username")
                    }
                    Section {
                        Picker("Authentication", selection: $method) {
                            Text("Password").tag(Method.password)
                            Text("Key file").tag(Method.key)
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        if method == .password {
                            SecureField(editing?.auth == .password ? "Unchanged" : "Password", text: $password)
                                .focused($focused, equals: .password)
                                .textContentType(.password)
                        } else {
                            KeyList(selection: $keyID)
                            Button("Import key…") { importingKey = true }
                            Button("Create key…") { creatingKey = true }
                        }
                    } header: {
                        MobileSectionHeader("Authentication")
                    } footer: {
                        if method == .key {
                            Text("Private keys stay in the Keychain and unlock with Face ID; Secure Enclave keys are available for P-256.")
                        }
                    }
                    if method == .key, let keyID, let key = sessions.keys.key(keyID) {
                        PublicKeyActions(key: key)
                    }
                    Section {
                        if features.showsHelperRows {
                            Picker("Multiplexer", selection: $features.multiplexer) {
                                ForEach(HostRecord.MultiplexerPreference.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                        }
                        Toggle("Helper", isOn: $features.helper)
                            .accessibilityHint(Self.helperHint)
                        if features.showsHelperRows {
                            Toggle("Chat", isOn: $features.chat)
                        }
                    } header: {
                        MobileSectionHeader("On the host")
                    } footer: {
                        Text(Self.statement(helper: features.helper))
                    }
                    if let failure {
                        Section {
                            Text(failure).foregroundStyle(.red)
                        } footer: {
                            Text("Nothing was saved. Check the address and login, then Create again.")
                        }
                        .id(Self.failureRow)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(editing == nil ? "New host" : "Edit host")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) { cancel() } label: { Image(systemName: "xmark") }
                            .tint(.primary)
                            .accessibilityLabel("Cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if verifying {
                            ProgressView().accessibilityLabel("Connecting")
                        } else {
                            Button(editing == nil ? "Create" : "Save") { submit() }
                                .buttonStyle(.glassProminent)
                                .disabled(record == nil)
                        }
                    }
                }
                .disabled(verifying)
                .sheet(isPresented: $importingKey) {
                    ImportKeySheet { keyID = $0.id }.tint(.dispatchPink)
                }
                .sheet(isPresented: $creatingKey) {
                    CreateKeySheet { keyID = $0.id }.tint(.dispatchPink)
                }
                .onChange(of: probe?.link) { _, link in probeChanged(link) }
                .onAppear {
                    if editing == nil, keyID == nil { keyID = sessions.keys.keys.first?.id }
                }
                // The failure is the form's last section, below the helper's text: brought into view, or a small screen
                // would show only the Create button coming back.
                .onChange(of: failure) { _, failure in
                    if failure != nil { withAnimation { reader.scrollTo(Self.failureRow, anchor: .bottom) } }
                }
            }
        }
        .hostTrustPrompt()
        // M8a draws the sheet's grabber, as New space's and New chat's do.
        .mobileSheetGrabber()
        .interactiveDismissDisabled(verifying)
        // Swiped away after a failed attempt: nothing of the unsaved host stays behind.
        .onDisappear { if !saved, editing == nil { discardProbe() } }
    }

    /// The words under the Helper switch: what the helper does on the host, or with the switch off what plain SSH does.
    static func statement(helper: Bool) -> AttributedString {
        helper ? helperStatement : AttributedString(plainStatement)
    }

    /// With Helper off (docs/ios.md, Plain SSH): a shell over SSH, nothing installed.
    static var plainStatement: String {
        "Without the helper, this \(MobileDevice.name) only opens shells on the host over SSH and installs nothing there. Chat, agents and tmux or herdr spaces need the helper."
    }

    /// VoiceOver's hint on the Helper switch (New host, host detail).
    static let helperHint = "Off: plain SSH, nothing is installed on the host"

    /// What the helper does on the host, linking the details.
    static let helperStatement: AttributedString = {
        var text = AttributedString(HelperGrant.statement)
        var link = AttributedString("What the helper can do")
        link.link = URL(string: "https://github.com/paulmillr/dispatch/blob/main/docs/security.md#ssh-integration")
        text.append(link)
        return text
    }()

    private func submit() {
        guard var record else { return }
        failure = nil
        focused = nil
        if method == .password, !password.isEmpty {
            do { try sessions.keys.setPassword(password, for: record.id) } catch {
                failure = error.localizedDescription
                return
            }
        }
        if editing != nil {
            if method == .key { sessions.keys.removePassword(for: record.id) }
            sessions.update(record)
            dismiss()
            return
        }
        record.order = sessions.store.hosts.count
        let probe = sessions.probe(record)
        self.probe = probe
        probe.connect()
    }

    private func probeChanged(_ link: HostLink?) {
        guard let probe, let link else { return }
        switch link {
        case .connected:
            guard var record else { return }
            if let identity = probe.hello?.identity {
                // Coloured by the machine, as the Mac app colours it; fixed from now on.
                record.tintSeed = identity.host
                record.system = HostSystem(os: identity.os, distribution: identity.distribution, name: identity.os_name)
                record.osLabel = HostRecord.osLabel(identity)
            }
            record.lastConnected = Date()
            save(record, probe: probe)
        case .failed(let reason):
            failure = probe.hostKeyMismatch != nil ? "The host key changed since you trusted it." : reason
        case .reconnecting(_, _, let reason?):
            // A saved host keeps retrying a network failure; verifying a new one stops at the first and says why
            // (a mistyped name, Tailscale off, no signal), instead of spinning.
            failure = probe.problem ?? reason
            discardProbe()
        default:
            break
        }
    }

    private func save(_ record: HostRecord, probe: HostSession) {
        saved = true
        sessions.add(record, probe: probe)
        created(record.id)
        dismiss()
    }

    private func cancel() {
        if editing == nil { discardProbe() }
        dismiss()
    }

    /// Drops the verifying connection and the password stored for it.
    private func discardProbe() {
        probe?.disconnect()
        probe = nil
        sessions.keys.removePassword(for: id)
    }
}

/// New host's multiplexer, Helper and Chat rows (M8a): the sheet's own copy of them. Chat is kept apart from the record,
/// which forces it off without the helper (`HostRecord.helper`): turning Helper off only hides Chat, and turning it on
/// again shows Chat as it was (on, for a host saved without the helper: Chat's default).
struct HostFeatureDraft: Equatable {
    var multiplexer: HostRecord.MultiplexerPreference = .automatic
    var helper = true
    /// What Chat is with the helper; kept while Helper is off.
    var chat = true

    init(_ record: HostRecord? = nil) {
        guard let record else { return }
        multiplexer = record.multiplexer
        helper = record.helper
        chat = record.helper ? record.chat : true
    }

    /// The multiplexer and Chat rows show with the helper only.
    var showsHelperRows: Bool { helper }

    func apply(to record: inout HostRecord) {
        record.multiplexer = multiplexer
        record.helper = helper
        record.chat = helper && chat
    }
}

/// The keys on this phone with type and fingerprint (M8a); the checked one is used. Long-press for Copy, Share and
/// Delete.
struct KeyList: View {
    @Binding var selection: UUID?
    @Environment(HostSessions.self) private var sessions
    @State private var deleting: KeyRecord?

    var body: some View {
        ForEach(sessions.keys.keys) { key in
            Button { selection = key.id } label: { KeyRow(key: key, selected: selection == key.id) }
                .foregroundStyle(.primary)
                .contextMenu {
                    Button("Copy Public Key", systemImage: "doc.on.doc") { UIPasteboard.general.string = key.publicKey }
                    ShareLink("Share Public Key", item: key.publicKey)
                    Button("Delete Key", systemImage: "trash", role: .destructive) { deleting = key }
                }
        }
        .confirmationDialog("Delete \(deleting?.label ?? "key")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { key in
            Button("Delete Key", role: .destructive) {
                if selection == key.id { selection = nil }
                sessions.keys.delete(key.id)
            }
        } message: { key in
            Text(sessions.store.hosts.contains { $0.auth == .key(key.id) }
                 ? "Hosts that use this key can't connect until you choose another."
                 : "The private key is removed from this \(MobileDevice.name).")
        }
    }
}

struct KeyRow: View {
    let key: KeyRecord
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: key.isSecureEnclave ? "lock.shield" : "key.horizontal")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? Color.dispatchPink : .secondary)
                .frame(width: 30, height: 30)
                .background((selected ? Color.dispatchPink : Color.secondary).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(key.label).monospaced().lineLimit(1)
                Text("\(key.typeLabel) · \(key.fingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.dispatchPink)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Copy and Share for the checked key's `authorized_keys` line: the way onto a host (not in the mockup; plan 3.6).
struct PublicKeyActions: View {
    let key: KeyRecord
    @State private var copied = false

    var body: some View {
        Section {
            Button(copied ? "Copied" : "Copy Public Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = key.publicKey
                copied = true
            }
            ShareLink("Share Public Key", item: key.publicKey)
        } footer: {
            Text("Add it to ~/.ssh/authorized_keys on the host.")
        }
        .onChange(of: key.id) { copied = false }
    }
}
